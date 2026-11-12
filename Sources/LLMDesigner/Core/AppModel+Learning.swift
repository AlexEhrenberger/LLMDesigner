import AppKit
import Foundation

/// What an action or another studio wants Learning Studio to show.
struct LearningStudioCommand: Equatable {
    var discipline: UUID?
    var course: UUID?
    var tab: CourseTab?
    /// Go straight to learning the due cards.
    var review = false
}

/// The tabs of a course page.
enum CourseTab: String, CaseIterable, Identifiable {
    case overview, cards, review, material, quiz, links

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Übersicht"
        case .cards: "Karten"
        case .review: "Lernen"
        case .material: "Material"
        case .quiz: "Abfrage"
        case .links: "Verknüpft"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .cards: "rectangle.stack"
        case .review: "brain.head.profile"
        case .material: "folder"
        case .quiz: "questionmark.bubble"
        case .links: "link"
        }
    }
}

extension AppModel {
    // MARK: Opening

    func openLearningStudio(_ command: LearningStudioCommand? = nil) {
        closeDocument()
        showChats()
        learning.loadIfNeeded()
        notes.loadIfNeeded()
        projects.loadIfNeeded()
        citations.loadIfNeeded()
        if let command { learningStudioCommand = command }
        learningStudioOpen = true
    }

    func closeLearningStudio() {
        learning.saveAll()
        learningStudioOpen = false
    }

    // MARK: Disciplines and courses

    @discardableResult
    func newDiscipline(name: String = "", tree: TreeKind? = nil, color: FolderColor? = nil) -> LearningDiscipline {
        learning.loadIfNeeded()
        let count = learning.state.disciplines.count
        let discipline = LearningDiscipline(name: name, color: color ?? [.green, .pink, .orange, .blue, .purple, .teal][count % 6],
                                            tree: tree ?? TreeKind.allCases[count % TreeKind.allCases.count])
        learning.changeState { $0.disciplines.append(discipline) }
        return discipline
    }

    /// Removes a discipline; its courses stay, without one.
    func deleteDiscipline(_ id: UUID) {
        for course in learning.courses(in: id) { learning.courses.update(course.id) { $0.discipline = nil } }
        learning.changeState { $0.disciplines.removeAll { $0.id == id } }
    }

    @discardableResult
    func newCourse(name: String = "", in disciplineID: UUID?) -> LearningCourse {
        learning.loadIfNeeded()
        var course = LearningCourse(discipline: disciplineID, name: name)
        course.color = learning.discipline(disciplineID)?.color ?? .green
        course.createdAt = Date()
        return learning.courses.add(course)
    }

    // MARK: Material

    /// Copies a PDF into the course's folder (a practice exam too).
    @discardableResult
    func addCourseMaterial(file: URL, to courseID: UUID, kind: LearningMaterial.Kind = .pdf) throws -> LearningMaterial {
        let folder = learning.materialFolder(courseID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = file.lastPathComponent
        var target = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            name = file.deletingPathExtension().lastPathComponent + " \(number)." + file.pathExtension
            target = folder.appendingPathComponent(name)
            number += 1
        }
        try FileManager.default.copyItem(at: file, to: target)
        let material = LearningMaterial(kind: kind, title: file.deletingPathExtension().lastPathComponent, file: name)
        learning.courses.update(courseID) { $0.materials.append(material) }
        return material
    }

    /// A web page or a video; YouTube addresses become videos by themselves.
    @discardableResult
    func addCourseLink(_ address: String, title: String = "", to courseID: UUID) -> LearningMaterial? {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if !address.contains("://") { address = "https://" + address }
        guard URL(string: address) != nil else { return nil }
        let material = LearningMaterial(kind: LearningMaterial.isYouTube(address) ? .youtube : .link, title: title, url: address)
        learning.courses.update(courseID) { $0.materials.append(material) }
        return material
    }

    @discardableResult
    func addCourseSource(_ sourceID: UUID, to courseID: UUID) -> LearningMaterial? {
        guard let source = citations.source(sourceID) else { return nil }
        let material = LearningMaterial(kind: .quelle, title: source.title, url: source.url.isEmpty ? nil : source.url, citekey: source.citekey)
        learning.courses.update(courseID) { $0.materials.append(material) }
        return material
    }

    func removeCourseMaterial(_ materialID: UUID, from courseID: UUID) {
        guard let material = learning.course(courseID)?.material(materialID) else { return }
        if let url = learning.materialURL(material, in: courseID) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        learning.courses.update(courseID) { course in
            course.materials.removeAll { $0.id == materialID }
            for index in course.cards.indices where course.cards[index].material == materialID { course.cards[index].material = nil }
        }
    }

    func openCourseMaterial(_ material: LearningMaterial, in courseID: UUID) {
        if let url = learning.materialURL(material, in: courseID) {
            NSWorkspace.shared.open(url)
        } else if let address = material.url, let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        } else if let key = material.citekey, let source = citations.sources.first(where: { $0.citekey == key }) {
            openCitationStudio(showing: source.id)
        }
    }

    /// The text of a material for the model: a PDF's text layer, the abstract and notes of a source, own text.
    func materialText(_ material: LearningMaterial, in courseID: UUID, limit: Int) async -> String? {
        switch material.kind {
        case .pdf, .probeklausur:
            guard let url = learning.materialURL(material, in: courseID) else { return material.text.isEmpty ? nil : material.text }
            return await StudioPDF.text(of: url, limit: limit)
        case .quelle:
            guard let key = material.citekey, let source = citations.sources.first(where: { $0.citekey == key }) else { return nil }
            let quotes = citations.quotes(of: source.id).map { "- „\($0.exactText)“ \($0.locator)" }.joined(separator: "\n")
            let text = [source.title, source.abstract, quotes].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return text.isEmpty ? nil : String(text.prefix(limit))
        case .text:
            return material.text.isEmpty ? nil : String(material.text.prefix(limit))
        case .link, .youtube:
            return material.text.isEmpty ? nil : String(material.text.prefix(limit))
        }
    }

    // MARK: Links

    func linkToCourse(_ ref: ProjectRef, courseID: UUID) {
        learning.courses.update(courseID) { if !$0.links.contains(ref) { $0.links.append(ref) } }
    }

    func linkProjectToCourse(_ projectID: UUID, courseID: UUID) {
        learning.courses.update(courseID) { if !$0.projects.contains(projectID) { $0.projects.append(projectID) } }
    }

    // MARK: The model's help

    /// A study sheet from a material (or the whole course): the most important points as a Writer document that
    /// belongs to the course.
    @discardableResult
    func makeStudySheet(courseID: UUID, material materialID: UUID?, open: Bool = true) async throws -> WriterDocument {
        guard let course = learning.course(courseID) else { throw LLMError.server("Den Kurs gibt es nicht mehr.") }
        let (text, title) = try await courseMaterialForModel(course, material: materialID)
        let answer = try await studioComplete(system: LearningPrompts.sheetSystem, user: LearningPrompts.sheetRequest(course: course.displayName, title: title, material: text),
                                              temperature: 0.3, maxTokens: 4_000)
        guard !answer.isEmpty else { throw LLMError.server("Das Modell hat keinen Lernzettel geschrieben.") }
        var document = WriterDocument()
        document.title = "Lernzettel: \(title)"
        document.hasCustomTitle = true
        document.markdown = answer.hasPrefix("#") ? answer : "# Lernzettel: \(title)\n\n" + answer
        // Made from PDFs and sources that came from outside.
        document.provenance = .foreign
        documents.insert(document, at: 0)
        saveDocument(document.id)
        linkToCourse(.document(document.id), courseID: courseID)
        if open { selectDocument(document.id) }
        return document
    }

    /// New cards from a material: question on the front, a short answer on the back.
    @discardableResult
    func makeCards(courseID: UUID, material materialID: UUID?, count: Int = 12) async throws -> [LearningCard] {
        guard let course = learning.course(courseID) else { throw LLMError.server("Den Kurs gibt es nicht mehr.") }
        let (text, title) = try await courseMaterialForModel(course, material: materialID)
        let existing = course.cards.suffix(60).map(\.front)
        let answer = try await studioComplete(system: LearningPrompts.cardsSystem,
                                              user: LearningPrompts.cardsRequest(course: course.displayName, title: title, material: text, count: count, existing: existing),
                                              temperature: 0.4, maxTokens: 4_000)
        let cards = LearningPrompts.parseCards(answer, material: materialID)
        guard !cards.isEmpty else { throw LLMError.server("Aus der Antwort ließen sich keine Karten lesen.") }
        learning.courses.update(courseID) { $0.cards += cards }
        return cards
    }

    /// The next question of a quiz about the material, the practice exam and the cards.
    func nextQuizQuestion(courseID: UUID, session sessionID: UUID) async throws -> QuizItem {
        guard let course = learning.course(courseID), let session = course.quizzes.first(where: { $0.id == sessionID }) else {
            throw LLMError.server("Die Abfrage gibt es nicht mehr.")
        }
        let (text, _) = try await courseMaterialForModel(course, material: session.material, allowCardsOnly: true)
        let asked = session.items.map(\.question)
        let answer = try await studioComplete(system: LearningPrompts.quizSystem,
                                              user: LearningPrompts.quizQuestion(course: course.displayName, material: text, asked: asked),
                                              temperature: 0.7, maxTokens: 600)
        let question = answer.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“ \n"))
        guard !question.isEmpty else { throw LLMError.server("Das Modell hat keine Frage gestellt.") }
        let item = QuizItem(question: question)
        learning.courses.update(courseID) { course in
            if let index = course.quizzes.firstIndex(where: { $0.id == sessionID }) { course.quizzes[index].items.append(item) }
        }
        return item
    }

    /// The model checks an answer against the material: right, partly, wrong, why, and what a full answer says.
    func gradeQuizAnswer(courseID: UUID, session sessionID: UUID, item itemID: UUID, answer: String) async throws {
        guard let course = learning.course(courseID), let session = course.quizzes.first(where: { $0.id == sessionID }),
              let item = session.items.first(where: { $0.id == itemID }) else { throw LLMError.server("Die Frage gibt es nicht mehr.") }
        let (text, _) = try await courseMaterialForModel(course, material: session.material, allowCardsOnly: true)
        let reply = try await studioComplete(system: LearningPrompts.quizSystem,
                                             user: LearningPrompts.quizGrade(question: item.question, answer: answer, material: text),
                                             temperature: 0.2, maxTokens: 900)
        let parsed = StudioJSON.object(in: reply)
        let verdict = (parsed?["bewertung"] as? String).flatMap { QuizItem.Verdict(rawValue: $0.lowercased()) } ?? .teilweise
        learning.courses.update(courseID) { course in
            guard let s = course.quizzes.firstIndex(where: { $0.id == sessionID }), let i = course.quizzes[s].items.firstIndex(where: { $0.id == itemID }) else { return }
            course.quizzes[s].items[i].answer = answer
            course.quizzes[s].items[i].verdict = verdict
            course.quizzes[s].items[i].feedback = (parsed?["rueckmeldung"] as? String) ?? (parsed == nil ? reply : "")
            course.quizzes[s].items[i].solution = (parsed?["loesung"] as? String) ?? ""
        }
    }

    func startQuiz(courseID: UUID, material: UUID?) -> UUID {
        let session = QuizSession(material: material)
        learning.courses.update(courseID) { $0.quizzes.append(session) }
        return session.id
    }

    /// The material as the model reads it, within its budget: one material, or all of the course's, or its cards.
    private func courseMaterialForModel(_ course: LearningCourse, material materialID: UUID?, allowCardsOnly: Bool = false) async throws -> (String, String) {
        let budget = studioTextBudget
        if let materialID, let material = course.material(materialID) {
            guard let text = await materialText(material, in: course.id, limit: budget) else {
                throw LLMError.server("„\(material.displayTitle)“ hat keinen lesbaren Text (bei einem Video oder Link fehlt der Inhalt; füge ihn als Text oder PDF hinzu).")
            }
            return (StudioJSON.framed(text, title: material.displayTitle), material.displayTitle)
        }
        var parts: [String] = []
        let readable = course.materials.filter { $0.kind != .link && $0.kind != .youtube || !$0.text.isEmpty }
        // Practice exams first: their questions show what matters.
        let ordered = readable.filter { $0.kind == .probeklausur } + readable.filter { $0.kind != .probeklausur }
        let share = ordered.isEmpty ? budget : max(2_000, budget / ordered.count)
        for material in ordered {
            if let text = await materialText(material, in: course.id, limit: share) { parts.append(StudioJSON.framed(text, title: material.displayTitle)) }
        }
        if parts.isEmpty || allowCardsOnly {
            let cards = course.cards.prefix(80).map { "F: \($0.front)\nA: \($0.back)" }.joined(separator: "\n\n")
            if !cards.isEmpty { parts.append(StudioJSON.framed(cards, title: "Karteikarten des Kurses")) }
        }
        guard !parts.isEmpty else { throw LLMError.server("Der Kurs hat noch kein lesbares Material und keine Karten.") }
        return (String(parts.joined(separator: "\n\n").prefix(budget)), course.displayName)
    }
}

/// What Learning Studio asks the model; small models get short, firm rules and an example of the form.
enum LearningPrompts {
    static let sheetSystem = """
    Du bist ein sorgfältiger Tutor. Du schreibst Lernzettel auf Deutsch in Markdown: kurz, klar gegliedert, nur was im Material steht. \
    Du erfindest nichts dazu. \(StudioJSON.materialHint)
    """

    static func sheetRequest(course: String, title: String, material: String) -> String {
        """
        Kurs: \(course)

        Schreibe einen Lernzettel zu „\(title)“. Aufbau:
        # Lernzettel: \(title)
        ## Das Wichtigste in fünf Sätzen
        ## Begriffe (Begriff – Erklärung in einem Satz)
        ## Zusammenhänge und Formeln
        ## Typische Prüfungsfragen (mit kurzer Antwort)
        ## Merksätze

        \(material)
        """
    }

    static let cardsSystem = """
    Du erstellst Karteikarten auf Deutsch. Eine Karte fragt genau eine Sache; die Antwort ist kurz (ein bis drei Sätze). \
    Nur was im Material steht. Antworte nur mit einer JSON-Liste. \(StudioJSON.materialHint)
    """

    static func cardsRequest(course: String, title: String, material: String, count: Int, existing: [String]) -> String {
        let known = existing.isEmpty ? "" : "\nDiese Fragen gibt es schon, wiederhole sie nicht:\n" + existing.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return """
        Kurs: \(course). Material: „\(title)“.
        Erstelle \(count) Karteikarten. Form genau so:
        [{"vorne": "Was besagt …?", "hinten": "…"}, {"vorne": "…", "hinten": "…"}]
        \(known)
        \(material)
        """
    }

    static func parseCards(_ text: String, material: UUID?) -> [LearningCard] {
        if let array = StudioJSON.array(in: text) {
            return array.compactMap { item in
                let front = ((item["vorne"] ?? item["frage"] ?? item["front"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let back = ((item["hinten"] ?? item["antwort"] ?? item["back"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !front.isEmpty, !back.isEmpty else { return nil }
                return LearningCard(front: front, back: back, material: material)
            }
        }
        return LearningCardText.parse(text).map { LearningCard(front: $0.front, back: $0.back, material: material) }
    }

    static let quizSystem = """
    Du bist ein fairer Prüfer. Du fragst und bewertest auf Deutsch und nur auf Grundlage des Materials. \(StudioJSON.materialHint)
    """

    static func quizQuestion(course: String, material: String, asked: [String]) -> String {
        let before = asked.isEmpty ? "" : "\nSchon gefragt (nicht wiederholen):\n" + asked.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return """
        Kurs: \(course).
        Stelle genau eine Prüfungsfrage zum Material, die Verständnis prüft (nicht nur Auswendiggelerntes). Gib nur die Frage aus, ohne Antwort.
        \(before)
        \(material)
        """
    }

    static func quizGrade(question: String, answer: String, material: String) -> String {
        """
        Frage: \(question)
        Antwort der lernenden Person: \(answer.isEmpty ? "(keine Antwort)" : answer)

        Bewerte die Antwort anhand des Materials. Antworte nur mit JSON in dieser Form:
        {"bewertung": "richtig" | "teilweise" | "falsch", "rueckmeldung": "Was stimmt, was fehlt – zwei bis vier Sätze, freundlich.", "loesung": "Eine vollständige Musterantwort."}

        \(material)
        """
    }
}

/// Cards from plain text: "Frage ; Antwort", "Frage – Antwort", "Frage\tAntwort" per line, or "F: … / A: …" pairs.
enum LearningCardText {
    static func parse(_ text: String) -> [(front: String, back: String)] {
        var result: [(String, String)] = []
        var pendingQuestion: String?
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("f:") || lower.hasPrefix("frage:") || lower.hasPrefix("q:") {
                pendingQuestion = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            if lower.hasPrefix("a:") || lower.hasPrefix("antwort:"), let question = pendingQuestion {
                result.append((question, line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)))
                pendingQuestion = nil
                continue
            }
            for separator in ["\t", " ; ", ";", " – ", " — ", " -> ", " = "] {
                if let range = line.range(of: separator) {
                    let front = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let back = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !front.isEmpty, !back.isEmpty { result.append((front, back)) }
                    break
                }
            }
        }
        return result
    }
}
