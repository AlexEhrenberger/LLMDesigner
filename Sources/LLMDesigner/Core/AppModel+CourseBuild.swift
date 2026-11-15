import Foundation
import PDFKit

/// The automatic creation of a course's lessons from a PDF, one lesson after another in the background.
@MainActor
@Observable
final class CourseBuildCenter {
    struct Job: Identifiable, Equatable, Sendable {
        var course: UUID
        var lesson: UUID
        var id: UUID { lesson }
    }

    /// Lessons still to come, in order.
    var queue: [Job] = []
    var current: Job?
    var step: LessonBuildStep?
    /// What the model is doing right now, for the lesson's row ("Liest „1.1 Definitionen“, Stück 2 von 6").
    var detail = ""
    /// 0…1 within the current step.
    var fraction = 0.0
    /// Why a lesson's creation stopped.
    var errors: [UUID: String] = [:]
    /// The whole creation stopped (the model isn't reachable); shown above the course.
    var stopped: String?
    @ObservationIgnored var task: Task<Void, Never>?

    var isRunning: Bool { current != nil || !queue.isEmpty }

    func isBuilding(course: UUID) -> Bool { current?.course == course || queue.contains { $0.course == course } }

    func isWaiting(_ lesson: UUID) -> Bool { queue.contains { $0.lesson == lesson } }
}

/// The structure found in a course's PDF.
struct CourseOutlineResult: Sendable {
    var lessons: [DetectedLesson]
    var source: CourseOutline.Source
    var title: String?
    var pageCount: Int
}

/// Learning Studio's automatic course creation. The structure comes from the PDF's bookmarks or headings, without the
/// model. Then, lesson by lesson: the model reads each section in pieces of a few pages and writes study notes; from
/// the notes come the summary (a Writer document), the cards and the test questions; from the summary come the
/// content analysis and a presentation with speaker cards. Each step is kept as soon as it is done, so a stopped
/// creation goes on where it was.
extension AppModel {
    // MARK: Structure

    func detectLessons(material materialID: UUID, in courseID: UUID) async throws -> CourseOutlineResult {
        guard let course = learning.course(courseID), let material = course.material(materialID), let url = learning.materialURL(material, in: courseID) else {
            throw LLMError.server("Die PDF des Kurses gibt es nicht mehr.")
        }
        let result: CourseOutlineResult? = await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { return nil }
            let title = CourseOutline.title(of: document)
            guard let found = CourseOutline.detect(in: document) else {
                return CourseOutlineResult(lessons: [], source: .headings, title: title, pageCount: document.pageCount)
            }
            return CourseOutlineResult(lessons: found.lessons, source: found.source, title: title, pageCount: document.pageCount)
        }.value
        guard let result else { throw LLMError.server("„\(material.displayTitle)“ lässt sich nicht als PDF öffnen.") }
        return result
    }

    /// Makes the detected lessons part of the course: a lesson of the same name gets the pages and sections, others
    /// are added in order. The learning goals are read off each lesson's first pages.
    @discardableResult
    func addDetectedLessons(_ detected: [DetectedLesson], material materialID: UUID, to courseID: UUID) async -> [UUID] {
        guard let course = learning.course(courseID), let material = course.material(materialID) else { return [] }
        let url = learning.materialURL(material, in: courseID)
        var ids: [UUID] = []
        var lessons = course.lessons
        for found in detected where found.included {
            var goals: [String] = []
            if let url {
                let pages = await LessonText.pages(of: url, first: found.firstPage, last: min(found.lastPage, found.firstPage + 1))
                goals = CourseOutline.goals(in: pages.map(\.text).joined(separator: "\n"))
            }
            let title = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var lesson = lessons.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame } ?? LearningLesson(title: title)
            lesson.material = materialID
            lesson.firstPage = found.firstPage
            lesson.lastPage = found.lastPage
            // Sections keep their ids where the title stays, so the study notes still belong to them.
            lesson.sections = found.sections.map { section in
                var kept = lesson.sections.first { $0.title == section.title } ?? LessonSection(title: section.title)
                kept.firstPage = section.firstPage
                kept.lastPage = section.lastPage
                return kept
            }
            if !goals.isEmpty { lesson.goals = goals }
            if let index = lessons.firstIndex(where: { $0.id == lesson.id }) { lessons[index] = lesson } else { lessons.append(lesson) }
            ids.append(lesson.id)
        }
        learning.courses.update(courseID) { $0.lessons = lessons }
        return ids
    }

    /// "1.2 Bedingte Wahrscheinlichkeiten": the title with its number when the PDF's bookmark had none.
    func sectionLabel(_ section: LessonSection, index: Int, lessonNumber: Int?) -> String {
        let title = section.title.trimmingCharacters(in: .whitespaces)
        if let first = title.first, first.isNumber { return title }
        guard let lessonNumber else { return title }
        return "\(lessonNumber).\(index + 1) \(title)"
    }

    // MARK: Running

    /// Puts lessons into the creation queue (it starts unless it runs already).
    func buildLessons(_ lessonIDs: [UUID], in courseID: UUID, options: CourseBuildOptions) {
        learning.courses.update(courseID) { $0.buildOptions = options }
        let build = courseBuild
        build.stopped = nil
        for id in lessonIDs where build.current?.lesson != id && !build.isWaiting(id) {
            build.errors[id] = nil
            build.queue.append(CourseBuildCenter.Job(course: courseID, lesson: id))
        }
        guard build.task == nil, !build.queue.isEmpty else { return }
        build.task = Task { [weak self] in
            await self?.runCourseBuild()
        }
    }

    /// Stops the creation (of one course, or all); what is done stays.
    func cancelCourseBuild(course courseID: UUID? = nil) {
        let build = courseBuild
        if let courseID {
            build.queue.removeAll { $0.course == courseID }
            if build.current?.course == courseID { build.task?.cancel() }
        } else {
            build.queue.removeAll()
            build.task?.cancel()
        }
    }

    private func runCourseBuild() async {
        let build = courseBuild
        while !Task.isCancelled, !build.queue.isEmpty {
            let job = build.queue.removeFirst()
            build.current = job
            build.fraction = 0
            do {
                try await buildLesson(job)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { break }
                build.errors[job.lesson] = error.localizedDescription
                // Without the model nothing else can be made either.
                if let urlError = error as? URLError, [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(urlError.code) {
                    build.stopped = "Das Modell ist nicht erreichbar. Die Erstellung ist angehalten; „Fortsetzen“ macht dort weiter."
                    build.queue.removeAll()
                }
            }
        }
        if Task.isCancelled { build.queue.removeAll { $0.course == build.current?.course } }
        build.current = nil
        build.step = nil
        build.detail = ""
        build.fraction = 0
        build.task = nil
        learning.saveAll()
        // Lessons queued while this one was being stopped start again.
        if !build.queue.isEmpty {
            build.task = Task { [weak self] in await self?.runCourseBuild() }
        }
    }

    private func buildLesson(_ job: CourseBuildCenter.Job) async throws {
        guard let course = learning.course(job.course), course.lesson(job.lesson) != nil else { return }
        let options = course.buildOptions ?? CourseBuildOptions()
        for step in options.steps {
            guard let lesson = learning.course(job.course)?.lesson(job.lesson) else { return }
            if lesson.built.contains(step), stepResultExists(step, lesson: lesson) { continue }
            try Task.checkCancellation()
            courseBuild.step = step
            courseBuild.fraction = 0
            courseBuild.detail = step.label
            switch step {
            case .reading: try await readLesson(job.course, job.lesson)
            case .summary: try await writeLessonSummary(job.course, job.lesson)
            case .cards: try await makeLessonCards(job.course, job.lesson, perSection: options.cardsPerSection)
            case .analysis: try await analyzeLesson(job.course, job.lesson)
            case .presentation: try await makeLessonPresentation(job.course, job.lesson, speakerNotes: options.speakerNotes)
            }
            learning.courses.update(job.course) { $0.updateLesson(job.lesson) { $0.built.insert(step) } }
        }
    }

    /// A step counts as done while what it made is still there (a deleted summary is made again).
    private func stepResultExists(_ step: LessonBuildStep, lesson: LearningLesson) -> Bool {
        switch step {
        case .summary: lesson.summaryDocument.flatMap(document) != nil
        case .presentation: lesson.presentation.flatMap(document) != nil
        default: true
        }
    }

    private func report(_ detail: String, _ done: Int, _ total: Int) {
        courseBuild.detail = detail
        courseBuild.fraction = total == 0 ? 0 : Double(done) / Double(total)
    }

    /// One answer from the model; an answer that repeats itself (a small model can loop) is asked for once more.
    private func lessonComplete(system: String, user: String, temperature: Double, maxTokens: Int) async throws -> String {
        var answer = try await studioComplete(system: system, user: user, temperature: temperature, maxTokens: maxTokens)
        if LessonPrompts.isRepetitive(answer) {
            answer = try await studioComplete(system: system, user: user, temperature: min(0.9, temperature + 0.3), maxTokens: maxTokens)
        }
        try Task.checkCancellation()
        return answer
    }

    // MARK: Reading

    /// The parts the model reads: the sections with their pages, with text before the first section as an
    /// introduction when there is enough of it; a lesson without sections is read as a whole.
    private func readingParts(_ lesson: LearningLesson, number: Int?) -> [(id: UUID?, title: String, first: Int, last: Int)] {
        guard let first = lesson.firstPage else { return [] }
        let last = max(first, lesson.lastPage ?? first)
        let sections = lesson.sections.filter { $0.firstPage != nil }
        guard !sections.isEmpty else { return [(nil, lesson.displayTitle, first, last)] }
        var parts: [(id: UUID?, title: String, first: Int, last: Int)] = []
        if let start = sections[0].firstPage, start > first + 1 {
            parts.append((nil, "Einführung", first, start - 1))
        }
        for (index, section) in lesson.sections.enumerated() {
            guard let from = section.firstPage else { continue }
            parts.append((section.id, sectionLabel(section, index: index, lessonNumber: number), from, max(from, min(last, section.lastPage ?? last))))
        }
        return parts
    }

    private func readLesson(_ courseID: UUID, _ lessonID: UUID) async throws {
        guard let course = learning.course(courseID), let lesson = course.lesson(lessonID) else { return }
        guard let materialID = lesson.material, let material = course.material(materialID), let url = learning.materialURL(material, in: courseID) else {
            throw LLMError.server("„\(lesson.displayTitle)“ hat keine PDF-Seiten. Lege sie in den Kurseinstellungen fest oder erstelle den Kurs aus einer PDF.")
        }
        let number = course.lessonNumber(lessonID)
        let lessonTitle = (number.map { "Lektion \($0): " } ?? "") + lesson.displayTitle
        let limit = min(7_000, max(3_000, studioTextBudget / 3))
        var notes = learning.lessonNotes(courseID, lesson: lessonID) ?? LessonNotes(lesson: lessonID)
        let parts = readingParts(lesson, number: number)
        var readable = 0
        for (index, part) in parts.enumerated() {
            if let done = notes.section(part.id), done.isComplete, done.title == part.title {
                readable += 1
                continue
            }
            let pages = await LessonText.pages(of: url, first: part.first, last: part.last)
            // The introduction before the first section only counts with real text (not just the learning goals).
            let text = LessonText.clean(pages)
            if part.id == nil, parts.count > 1, text.count < 1_500 { continue }
            let pieces = LessonText.pieces(text, limit: limit)
            guard !pieces.isEmpty else { continue }
            readable += 1
            var entry = notes.section(part.id).flatMap { $0.pieces == pieces.count ? $0 : nil }
                ?? LessonNotes.Section(section: part.id, title: part.title, pieces: pieces.count, notes: [])
            entry.title = part.title
            for (number, piece) in pieces.enumerated() where number >= entry.notes.count {
                report("Liest „\(part.title)“" + (pieces.count > 1 ? " (Stück \(number + 1) von \(pieces.count))" : ""), index, parts.count)
                let answer = try await lessonComplete(
                    system: LessonPrompts.notesSystem,
                    user: LessonPrompts.notesRequest(course: course.displayName, lesson: lessonTitle, section: part.title, piece: number + 1, of: pieces.count, text: piece),
                    temperature: 0.3, maxTokens: 1_800
                )
                let note = LessonPrompts.cleanNotes(answer)
                guard !note.isEmpty else { throw LLMError.server("Das Modell hat zu „\(part.title)“ nichts notiert.") }
                entry.notes.append(note)
                if let at = notes.sections.firstIndex(where: { $0.section == part.id }) { notes.sections[at] = entry } else { notes.sections.append(entry) }
                // Kept after every piece: a stop loses at most the piece being read.
                try learning.saveLessonNotes(notes, course: courseID)
            }
        }
        guard readable > 0 else {
            throw LLMError.server("Auf den Seiten von „\(lesson.displayTitle)“ steht kein lesbarer Text (eine eingescannte PDF braucht erst eine Texterkennung).")
        }
        // Sections that are no longer part of the lesson leave the notes.
        let kept = Set(parts.map(\.id))
        notes.sections.removeAll { !kept.contains($0.section) }
        notes.sections.sort { a, b in (parts.firstIndex { $0.id == a.section } ?? 0) < (parts.firstIndex { $0.id == b.section } ?? 0) }
        try learning.saveLessonNotes(notes, course: courseID)
    }

    // MARK: Summary

    private func writeLessonSummary(_ courseID: UUID, _ lessonID: UUID) async throws {
        guard let course = learning.course(courseID), let lesson = course.lesson(lessonID) else { return }
        guard let notes = learning.lessonNotes(courseID, lesson: lessonID), !notes.sections.isEmpty else {
            throw LLMError.server("Für die Zusammenfassung fehlen die Lernnotizen von „\(lesson.displayTitle)“.")
        }
        let number = course.lessonNumber(lessonID)
        let lessonTitle = (number.map { "Lektion \($0): " } ?? "") + lesson.displayTitle
        let sections = notes.sections.filter { !$0.notes.isEmpty }
        let budget = max(6_000, studioTextBudget - 4_000)
        var parts: [(title: String, body: String)] = []
        for (index, section) in sections.enumerated() {
            report("Fasst „\(section.title)“ zusammen", index, sections.count + 1)
            let answer = try await lessonComplete(
                system: LessonPrompts.summarySystem,
                user: LessonPrompts.sectionRequest(lesson: lessonTitle, section: section.title, notes: String(section.text.prefix(budget))),
                temperature: 0.3, maxTokens: 3_000
            )
            let body = LessonPrompts.cleanSection(answer)
            if !body.isEmpty { parts.append((section.title, body)) }
        }
        guard !parts.isEmpty else { throw LLMError.server("Das Modell hat keine Zusammenfassung geschrieben.") }

        report("Schreibt den Abstract", sections.count, sections.count + 1)
        let outline = parts.map { "## \($0.title)\n" + LessonPrompts.outline(of: $0.body) }.joined(separator: "\n\n")
        let abstract = LessonPrompts.cleanAbstract(try await lessonComplete(
            system: LessonPrompts.summarySystem, user: LessonPrompts.abstractRequest(lesson: lessonTitle, outline: String(outline.prefix(budget))),
            temperature: 0.3, maxTokens: 800
        ))

        var markdown = "# \(lessonTitle)\n\n"
        markdown += "*Zusammenfassung zu „\(course.displayName)“" + (lesson.pageLabel.map { ", \($0) des Skripts" } ?? "") + ".*\n\n"
        if !lesson.goals.isEmpty {
            markdown += "## Lernziele\n\n" + lesson.goals.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        }
        markdown += parts.map { "## \($0.title)\n\n\($0.body)" }.joined(separator: "\n\n")
        if !abstract.isEmpty { markdown += "\n\n## Das Wichtigste in Kürze\n\n" + abstract }

        let folder = courseDocumentFolder(courseID)
        var document = WriterDocument()
        document.title = (number.map { "Lektion \($0) – " } ?? "") + lesson.displayTitle
        document.hasCustomTitle = true
        document.markdown = markdown + "\n"
        document.folderID = folder
        // Made from a PDF that came from outside.
        document.provenance = .foreign
        // A summary made before (deleted or made again) gives way to the new one.
        let old = lesson.summaryDocument.flatMap(self.document)
        documents.insert(document, at: 0)
        saveDocument(document.id)
        learning.courses.update(courseID) { course in
            course.updateLesson(lessonID) { lesson in
                lesson.summaryDocument = document.id
                if lesson.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || old != nil { lesson.abstract = abstract }
            }
            if !course.links.contains(.document(document.id)) { course.links.append(.document(document.id)) }
        }
    }

    /// The sidebar folder for the course's documents, made the first time it is needed.
    @discardableResult
    func courseDocumentFolder(_ courseID: UUID) -> Folder.ID? {
        guard let course = learning.course(courseID) else { return nil }
        if let id = course.documentFolder, chatFolders.contains(where: { $0.id == id }) { return id }
        var folder = Folder(name: Self.uniqueName(course.displayName, among: chatFolders.filter { $0.parentID == nil }.map(\.name)))
        folder.color = course.color
        chatFolders.append(folder)
        library.saveChatFolders(chatFolders)
        learning.courses.update(courseID) { $0.documentFolder = folder.id }
        return folder.id
    }

    // MARK: Cards

    private func makeLessonCards(_ courseID: UUID, _ lessonID: UUID, perSection: Int) async throws {
        guard let course = learning.course(courseID), let lesson = course.lesson(lessonID) else { return }
        guard let notes = learning.lessonNotes(courseID, lesson: lessonID) else {
            throw LLMError.server("Für die Karteikarten fehlen die Lernnotizen von „\(lesson.displayTitle)“.")
        }
        let sections = notes.sections.filter { !$0.notes.isEmpty }
        let budget = max(6_000, studioTextBudget - 3_000)
        var fronts = Set(course.cards.map { $0.front.lowercased() })
        var asked = course.cards(of: lessonID).map(\.front)
        for (index, section) in sections.enumerated() {
            // Cards of this section made before (a stopped creation) count.
            let have = course.cards(of: lessonID).filter { $0.tags.contains(section.title) }.count
            guard have < perSection else { continue }
            report("Karteikarten zu „\(section.title)“", index, sections.count)
            let answer = try await lessonComplete(
                system: LessonPrompts.cardsSystem,
                user: LessonPrompts.cardsRequest(lesson: lesson.displayTitle, section: section.title, notes: String(section.text.prefix(budget)),
                                                 count: perSection - have, existing: asked),
                temperature: 0.4, maxTokens: 2_000
            )
            let cards = LearningPrompts.parseCards(answer, material: lesson.material).prefix(perSection - have).compactMap { card -> LearningCard? in
                guard fronts.insert(card.front.lowercased()).inserted else { return nil }
                var card = card
                card.lesson = lessonID
                card.tags = [section.title]
                return card
            }
            asked += cards.map(\.front)
            if !cards.isEmpty { learning.courses.update(courseID) { $0.cards += cards } }
        }
    }

    // MARK: Analysis and presentation

    private func analyzeLesson(_ courseID: UUID, _ lessonID: UUID) async throws {
        guard let lesson = learning.course(courseID)?.lesson(lessonID), let documentID = lesson.summaryDocument, document(documentID) != nil else {
            throw LLMError.server("Für die Inhaltsanalyse fehlt die Zusammenfassung der Lektion.")
        }
        report("Inhaltsanalyse: Themen und Zusammenhänge", 0, 1)
        analyzeDocument(documentID, adding: .structure)
        await withTaskCancellationHandler {
            await analysisTasks[documentID]?.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAnalysis(documentID) }
        }
        try Task.checkCancellation()
        if let errors = analysisErrors[documentID], let error = errors[.overview] ?? errors[.structure] {
            throw LLMError.server("Inhaltsanalyse: \(error)")
        }
    }

    private func makeLessonPresentation(_ courseID: UUID, _ lessonID: UUID, speakerNotes: Bool) async throws {
        guard let course = learning.course(courseID), let lesson = course.lesson(lessonID),
              let summaryID = lesson.summaryDocument, let summary = document(summaryID) else {
            throw LLMError.server("Für die Präsentation fehlt die Zusammenfassung der Lektion.")
        }
        let (client, model) = try studioModel()
        let number = course.lessonNumber(lessonID)
        var deckID = lesson.presentation.flatMap(document)?.id
        // A presentation that has its slides only lacks speaker cards (a stopped creation); otherwise it is made.
        let hasSlides = deckID.flatMap { document($0)?.deck?.slides.count }.map { $0 >= 3 } ?? false
        if !hasSlides {
            if deckID == nil {
                var deck = WriterDocument.newPresentation()
                deck.title = (number.map { "Lektion \($0) – " } ?? "") + lesson.displayTitle + " (Präsentation)"
                deck.hasCustomTitle = true
                deck.folderID = courseDocumentFolder(courseID)
                deck.provenance = .foreign
                documents.insert(deck, at: 0)
                saveDocument(deck.id)
                deckID = deck.id
                learning.courses.update(courseID) { course in
                    course.updateLesson(lessonID) { $0.presentation = deck.id }
                    if !course.links.contains(.document(deck.id)) { course.links.append(.document(deck.id)) }
                }
            }
            guard let deckID else { return }
            report("Präsentation: Gliederung", 0, 1)
            try await fillDeck(deckID, from: deckMaterial(from: summary), options: DeckSourceOptions(notes: false, carriesObjects: true, presents: false),
                               client: client, model: model.id, contextLength: model.workingContextLength ?? 8_192,
                               progress: { [weak self] done, total in self?.report("Präsentation: Folie \(min(done + 1, total)) von \(total)", done, total) })
            saveDocument(deckID)
        }
        guard speakerNotes, let deckID, let slides = document(deckID)?.deck?.slides else { return }
        let missing = slides.filter { $0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (index, slide) in missing.enumerated() {
            try Task.checkCancellation()
            report("Moderatorenkarte \(index + 1) von \(missing.count)", index, missing.count)
            _ = try await generateNotes(deckID, slide.id)
        }
        saveDocument(deckID)
    }
}
