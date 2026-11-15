import Foundation

/// What runs for lesson tests in the background: questions being written and answers being graded.
@MainActor
@Observable
final class LessonTestCenter {
    /// Tests whose questions are still being written.
    var generating: Set<UUID> = []
    /// Answers being graded (item ids).
    var grading: Set<UUID> = []
    /// Tests whose grade and assessment are being made.
    var finishing: Set<UUID> = []
    /// Why something failed, per test.
    var errors: [UUID: String] = [:]
    @ObservationIgnored var generationTasks: [UUID: Task<Void, Never>] = [:]
    /// Grading runs one answer after another, also across tests, so the model isn't asked twice at once.
    @ObservationIgnored var gradingTask: Task<Void, Never>?
}

/// A test of a lesson: at least 15 questions over all its sections, about a third with options, the rest open; the
/// model grades the open answers in the background (the person goes straight on, as in an exam), and at the end the
/// app gives a grade from A to F and the model says where the person stands.
extension AppModel {
    static let lessonTestDefaultCount = 20
    static let lessonTestCounts = 15...40

    /// One request of the test's plan: a few questions about one piece of the lesson.
    struct TestBatch: Hashable, Sendable {
        var section: String
        var text: String
        var slots: [LessonPrompts.QuestionSlot]
    }

    /// What the questions are made from: the study notes piece by piece, else the summary's sections, else the
    /// lesson's abstract and the text of its materials.
    func testSources(_ courseID: UUID, _ lessonID: UUID) async -> [(section: String, text: String)] {
        guard let course = learning.course(courseID), let lesson = course.lesson(lessonID) else { return [] }
        if let notes = learning.lessonNotes(courseID, lesson: lessonID) {
            let pieces = notes.sections.flatMap { section in section.notes.map { (section: section.title, text: $0) } }
            if !pieces.isEmpty { return pieces }
        }
        if let summary = lesson.summaryDocument.flatMap(document) {
            let parts = DocumentDeckPlanner.sections(in: summary.markdown).sections
            var result: [(section: String, text: String)] = []
            var current: (title: String, lines: [String])?
            for part in parts {
                if part.level <= 2 {
                    if let current, !current.lines.isEmpty { result.append((current.title, current.lines.joined(separator: "\n"))) }
                    current = (part.title, part.lines)
                } else {
                    current?.lines += ["### " + part.title] + part.lines
                }
            }
            if let current, !current.lines.isEmpty { result.append((current.title, current.lines.joined(separator: "\n"))) }
            let useful = result.filter { $0.text.count > 300 && $0.section != "Lernziele" }
            if !useful.isEmpty { return useful.map { ($0.section, String($0.text.prefix(8_000))) } }
        }
        var parts: [(section: String, text: String)] = []
        if !lesson.abstract.isEmpty { parts.append((lesson.displayTitle, lesson.abstract)) }
        for material in course.materials where material.lesson == lessonID {
            if let text = await materialText(material, in: courseID, limit: 7_000) { parts.append((material.displayTitle, text)) }
        }
        return parts.filter { $0.text.count > 200 }
    }

    /// How a test's questions spread over the lesson: every piece gets its share by length (at least one question where
    /// there are enough), at most three questions per request.
    nonisolated static func testPlan(sources: [(section: String, text: String)], count: Int) -> [TestBatch] {
        guard !sources.isEmpty, count > 0 else { return [] }
        let total = Double(sources.reduce(0) { $0 + max(1, $1.text.count) })
        var shares = sources.map { Int((Double(count) * Double(max(1, $0.text.count)) / total).rounded(.down)) }
        if count >= sources.count { shares = shares.map { max(1, $0) } }
        // What rounding left over goes to the longest pieces; too many come off the shortest.
        var order = sources.indices.sorted { sources[$0].text.count > sources[$1].text.count }
        var index = 0
        while shares.reduce(0, +) < count {
            shares[order[index % order.count]] += 1
            index += 1
        }
        order.reverse()
        index = 0
        while shares.reduce(0, +) > count, index < order.count * 40 {
            let at = order[index % order.count]
            if shares[at] > (count >= sources.count ? 1 : 0) { shares[at] -= 1 }
            index += 1
        }
        let slots = LessonPrompts.slots(count: count)
        var next = 0
        var batches: [TestBatch] = []
        for (at, source) in sources.enumerated() {
            var left = shares[at]
            while left > 0 {
                let size = min(3, left)
                batches.append(TestBatch(section: source.section, text: source.text, slots: Array(slots[next..<(next + size)])))
                next += size
                left -= size
            }
        }
        return batches
    }

    // MARK: Starting

    @discardableResult
    func startLessonTest(courseID: UUID, lessonID: UUID, count: Int = AppModel.lessonTestDefaultCount) async throws -> UUID {
        guard let lesson = learning.course(courseID)?.lesson(lessonID) else { throw LLMError.server("Die Lektion gibt es nicht mehr.") }
        guard !(await testSources(courseID, lessonID)).isEmpty else {
            throw LLMError.server("Für einen Test braucht „\(lesson.displayTitle)“ Lernnotizen oder eine Zusammenfassung. Erstelle die Lektion aus der PDF oder verknüpfe Material.")
        }
        let session = QuizSession(lesson: lessonID, planned: min(Self.lessonTestCounts.upperBound, max(Self.lessonTestCounts.lowerBound, count)))
        learning.courses.update(courseID) { $0.quizzes.append(session) }
        continueLessonTest(courseID: courseID, sessionID: session.id)
        return session.id
    }

    /// Writes the questions still missing (after a restart too) and grades answers still waiting.
    func continueLessonTest(courseID: UUID, sessionID: UUID) {
        guard let session = learning.course(courseID)?.quizzes.first(where: { $0.id == sessionID }), session.isTest, session.finishedAt == nil else { return }
        if session.items.count < session.planned, lessonTests.generationTasks[sessionID] == nil {
            lessonTests.generating.insert(sessionID)
            lessonTests.errors[sessionID] = nil
            lessonTests.generationTasks[sessionID] = Task { [weak self] in
                await self?.writeTestQuestions(courseID: courseID, sessionID: sessionID)
                self?.lessonTests.generating.remove(sessionID)
                self?.lessonTests.generationTasks[sessionID] = nil
            }
        }
        if session.items.contains(where: { $0.isAnswered && $0.verdict == nil }) { gradeTestAnswers(courseID: courseID, sessionID: sessionID) }
    }

    private func writeTestQuestions(courseID: UUID, sessionID: UUID) async {
        guard let course = learning.course(courseID), let session = course.quizzes.first(where: { $0.id == sessionID }),
              let lessonID = session.lesson, let lesson = course.lesson(lessonID) else { return }
        let batches = Self.testPlan(sources: await testSources(courseID, lessonID), count: session.planned)
        var made = session.items.count
        var position = 0
        for batch in batches {
            defer { position += batch.slots.count }
            // Batches already asked (before a restart) are skipped.
            guard position + batch.slots.count > made else { continue }
            if Task.isCancelled { return }
            let asked = learning.course(courseID)?.quizzes.first { $0.id == sessionID }?.items.map(\.question) ?? []
            do {
                var items = try await testQuestions(course: course.displayName, lesson: lesson.displayTitle, batch: batch, asked: asked)
                // Fewer than asked for: once more for the rest.
                if items.count < batch.slots.count {
                    let more = try await testQuestions(course: course.displayName, lesson: lesson.displayTitle,
                                                       batch: TestBatch(section: batch.section, text: batch.text, slots: Array(batch.slots.dropFirst(items.count))),
                                                       asked: asked + items.map(\.question))
                    items += more
                }
                let fresh = Self.withoutRepeats(items, asked: asked)
                made += fresh.count
                learning.courses.update(courseID) { course in
                    guard let index = course.quizzes.firstIndex(where: { $0.id == sessionID }) else { return }
                    course.quizzes[index].items += fresh
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                lessonTests.errors[sessionID] = error.localizedDescription
                break
            }
        }
        // Fewer questions than planned (the model couldn't make more): the test ends with those it has.
        learning.courses.update(courseID) { course in
            guard let index = course.quizzes.firstIndex(where: { $0.id == sessionID }) else { return }
            if course.quizzes[index].items.count < course.quizzes[index].planned, lessonTests.errors[sessionID] == nil {
                course.quizzes[index].planned = course.quizzes[index].items.count
            }
        }
    }

    private func testQuestions(course: String, lesson: String, batch: TestBatch, asked: [String]) async throws -> [QuizItem] {
        let request = LessonPrompts.questionRequest(course: course, lesson: lesson, section: batch.section, notes: batch.text, slots: batch.slots, asked: asked)
        var answer = try await studioComplete(system: LessonPrompts.questionSystem, user: request, temperature: 0.6, maxTokens: 1_600)
        if LessonPrompts.isRepetitive(answer) {
            answer = try await studioComplete(system: LessonPrompts.questionSystem, user: request, temperature: 0.8, maxTokens: 1_600)
        }
        let parsed = LessonPrompts.parseQuestions(answer)
        return zip(parsed.prefix(batch.slots.count), batch.slots).map { LessonPrompts.item(from: $0, slot: $1, section: batch.section) }
    }

    /// Questions that were asked already (the same words) are dropped.
    nonisolated static func withoutRepeats(_ items: [QuizItem], asked: [String]) -> [QuizItem] {
        func key(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 })
        }
        var seen = asked.map(key)
        return items.filter { item in
            let words = key(item.question)
            let repeated = seen.contains { other in
                let union = words.union(other).count
                return union > 0 && Double(words.intersection(other).count) / Double(union) > 0.75
            }
            if !repeated { seen.append(words) }
            return !repeated
        }
    }

    // MARK: Answering

    /// Keeps an answer; one with options is graded at once, an open one by the model in the background.
    func answerTestItem(courseID: UUID, sessionID: UUID, itemID: UUID, answer: String, choice: Int? = nil) {
        learning.courses.update(courseID) { course in
            guard let s = course.quizzes.firstIndex(where: { $0.id == sessionID }), let i = course.quizzes[s].items.firstIndex(where: { $0.id == itemID }) else { return }
            var item = course.quizzes[s].items[i]
            item.answeredAt = Date()
            item.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            item.chosenOption = choice
            if item.kind == .choice {
                let right = choice != nil && choice == item.correctOption
                item.verdict = right ? .richtig : .falsch
                item.feedback = right ? "" : (choice == nil ? "Keine Antwort gewählt. " : "") + "Richtig ist: „\(item.correctText ?? "")“."
            } else if item.answer.isEmpty {
                item.verdict = .falsch
                item.feedback = "Keine Antwort."
            }
            course.quizzes[s].items[i] = item
        }
        gradeTestAnswers(courseID: courseID, sessionID: sessionID)
    }

    /// Grades the open answers still waiting, one after another, after whatever is being graded now.
    func gradeTestAnswers(courseID: UUID, sessionID: UUID) {
        let previous = lessonTests.gradingTask
        lessonTests.gradingTask = Task { [weak self] in
            await previous?.value
            await self?.gradeWaiting(courseID: courseID, sessionID: sessionID)
        }
    }

    private func gradeWaiting(courseID: UUID, sessionID: UUID) async {
        while !Task.isCancelled {
            guard let session = learning.course(courseID)?.quizzes.first(where: { $0.id == sessionID }),
                  let item = session.items.first(where: { $0.isAnswered && $0.verdict == nil && !lessonTests.grading.contains($0.id) }) else { return }
            lessonTests.grading.insert(item.id)
            defer { lessonTests.grading.remove(item.id) }
            do {
                let reply = try await studioComplete(system: LessonPrompts.gradeSystem,
                                                     user: LessonPrompts.gradeRequest(question: item.question, solution: item.solution, expected: item.expected, answer: item.answer),
                                                     temperature: 0.1, maxTokens: 400)
                let (verdict, feedback) = LessonPrompts.parseGrade(reply)
                learning.courses.update(courseID) { course in
                    guard let s = course.quizzes.firstIndex(where: { $0.id == sessionID }), let i = course.quizzes[s].items.firstIndex(where: { $0.id == item.id }) else { return }
                    course.quizzes[s].items[i].verdict = verdict
                    course.quizzes[s].items[i].feedback = feedback
                }
            } catch {
                if !Task.isCancelled { lessonTests.errors[sessionID] = "Bewerten: " + error.localizedDescription }
                return
            }
        }
    }

    // MARK: Finishing

    /// Grades what is still waiting, gives the grade and lets the model write its assessment. Questions not answered
    /// (a test ended early) don't count.
    func finishLessonTest(courseID: UUID, sessionID: UUID) async throws {
        guard let course = learning.course(courseID), course.quizzes.contains(where: { $0.id == sessionID }) else { throw LLMError.server("Den Test gibt es nicht mehr.") }
        lessonTests.finishing.insert(sessionID)
        lessonTests.errors[sessionID] = nil
        defer { lessonTests.finishing.remove(sessionID) }
        lessonTests.generationTasks[sessionID]?.cancel()
        await lessonTests.gradingTask?.value
        await gradeWaiting(courseID: courseID, sessionID: sessionID)
        guard let session = learning.course(courseID)?.quizzes.first(where: { $0.id == sessionID }) else { return }
        if session.items.contains(where: { $0.isAnswered && $0.verdict == nil }) {
            throw LLMError.server(lessonTests.errors[sessionID] ?? "Nicht alle Antworten ließen sich bewerten.")
        }
        guard let score = session.score else { throw LLMError.server("Es ist noch keine Frage beantwortet.") }
        let grade = LessonGrade(score: score)
        let answered = session.items.filter { $0.verdict != nil }
        let sections = Self.sectionScores(answered)
        let lessonTitle = session.lesson.flatMap { course.lesson($0)?.displayTitle } ?? "Lektion"
        // The grade stands before the model writes: a failed assessment doesn't cost it.
        learning.courses.update(courseID) { course in
            guard let index = course.quizzes.firstIndex(where: { $0.id == sessionID }) else { return }
            course.quizzes[index].grade = grade
            course.quizzes[index].finishedAt = Date()
        }
        let assessment = try await studioComplete(
            system: LessonPrompts.assessmentSystem,
            user: LessonPrompts.assessmentRequest(course: course.displayName, lesson: lessonTitle, grade: grade, score: score, answered: answered.count,
                                                  planned: max(session.planned, session.items.count), sections: sections, items: answered),
            temperature: 0.5, maxTokens: 1_000
        )
        learning.courses.update(courseID) { course in
            guard let index = course.quizzes.firstIndex(where: { $0.id == sessionID }) else { return }
            course.quizzes[index].assessment = assessment.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// How each section went, in the order the questions came.
    nonisolated static func sectionScores(_ items: [QuizItem]) -> [(title: String, score: Double, count: Int)] {
        var order: [String] = []
        var points: [String: (sum: Double, count: Int)] = [:]
        for item in items {
            guard let verdict = item.verdict else { continue }
            let title = item.section.isEmpty ? "Allgemein" : item.section
            if points[title] == nil { order.append(title) }
            points[title, default: (0, 0)].sum += verdict.points
            points[title, default: (0, 0)].count += 1
        }
        return order.map { title in (title, points[title]!.sum / Double(points[title]!.count), points[title]!.count) }
    }

    /// The questions answered wrong or partly become cards of the lesson (question on the front, the model answer
    /// on the back), so the gaps come up again.
    @discardableResult
    func cardsFromTestMistakes(courseID: UUID, sessionID: UUID) -> Int {
        guard let course = learning.course(courseID), let session = course.quizzes.first(where: { $0.id == sessionID }) else { return 0 }
        var fronts = Set(course.cards.map { $0.front.lowercased() })
        let cards = session.items.filter { $0.verdict != nil && $0.verdict != .richtig }.compactMap { item -> LearningCard? in
            guard fronts.insert(item.question.lowercased()).inserted else { return nil }
            let back = item.kind == .choice ? [item.correctText, item.solution == item.correctText ? nil : item.solution].compactMap { $0 }.joined(separator: " – ") : item.solution
            return LearningCard(front: item.question, back: back.isEmpty ? item.feedback : back, tags: [item.section, "Test"].filter { !$0.isEmpty }, lesson: session.lesson)
        }
        if !cards.isEmpty { learning.courses.update(courseID) { $0.cards += cards } }
        return cards.count
    }
}
