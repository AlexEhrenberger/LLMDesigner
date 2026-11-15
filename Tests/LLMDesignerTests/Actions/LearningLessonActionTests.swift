import AppKit
import Foundation
import LLMDProtocol
import PDFKit
import Testing
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Learning Studio: Lektionen, Erstellung aus PDF, KI-Test", .serialized)
struct LearningLessonActionTests {
    let h = ActionHarness()

    private func course(_ id: String) -> LearningCourse? { h.app.learning.course(UUID(uuidString: id)!) }

    private func makeCourse(_ name: String = "") async throws -> String {
        try #require(try await h.call("learning.course.create", ["name": .string(name.isEmpty ? "Kurs \(UUID().uuidString.prefix(8))" : name)])["id"]?.stringValue)
    }

    @Test func lessonsAreCreatedChangedMovedAndRemoved() async throws {
        let id = try await makeCourse()
        try await h.call("learning.course.update", ["course": .string(id), "creditPoints": 5, "examForm": "Klausur"])
        #expect(course(id)?.titleWithFacts.hasSuffix("(5 CP, Klausur)") == true)
        let one = try #require(try await h.call("learning.lesson.create", ["course": .string(id), "title": "Luftdruck"])["id"]?.stringValue)
        try await h.call("learning.lesson.create", ["course": .string(id), "title": "Wolken", "abstract": "Wie Wolken entstehen."])
        try await h.call("learning.lesson.create", ["course": .string(id), "title": "Einführung", "position": 1])
        #expect(course(id)?.lessons.map(\.title) == ["Einführung", "Luftdruck", "Wolken"])
        try await h.call("learning.lesson.update", ["course": .string(id), "lesson": "Wolken", "title": "Wolken und Regen", "position": 1])
        #expect(course(id)?.lessons.map(\.title) == ["Wolken und Regen", "Einführung", "Luftdruck"])
        #expect(await h.errorCode("learning.lesson.update", ["course": .string(id), "lesson": "9"]) == RPCError.notFoundCode)

        try await h.call("learning.card.add", ["course": .string(id), "front": "Was ist ein Hoch?", "back": "Absinkende Luft", "lesson": .string(one)])
        let card = try #require(course(id)?.cards.first)
        #expect(card.lesson?.uuidString == one)
        let list = try await h.call("learning.lesson.list", ["course": .string(id), "abstracts": true])
        let luft = try #require(list["lessons"]?.arrayValue?.first { $0["title"] == "Luftdruck" })
        #expect(luft["cards"] == 1 && luft["due"] == 1 && luft["number"] == 3)
        #expect(list["lessons"]?.arrayValue?.first?["abstract"] == "Wie Wolken entstehen.")
        let due = try await h.call("learning.due", ["course": .string(id), "lesson": "Wolken und Regen"])
        #expect(due["total"] == 0)

        try await h.call("learning.lesson.delete", ["course": .string(id), "lesson": .string(one)])
        #expect(course(id)?.lessons.count == 2)
        #expect(course(id)?.cards.first?.lesson == nil, "die Karte bleibt ohne Lektion im Kurs")
        try await h.call("writer.edit.undo")
        #expect(course(id)?.lessons.count == 3)
        try await h.call("learning.studio.open", ["course": .string(id), "lesson": "2", "show": "test"])
        #expect(h.app.learningStudioOpen)
        try await h.call("learning.studio.close")
        #expect(await h.errorCode("learning.studio.open", ["lesson": "2"]) == RPCError.invalidParamsCode)
    }

    @Test func lessonsHaveTheirOwnQueueAndNewCardsComeLessonByLesson() async throws {
        let id = try await makeCourse()
        let courseID = UUID(uuidString: id)!
        let first = LearningLesson(title: "Eins")
        let second = LearningLesson(title: "Zwei")
        // Lesson two's cards are older: still lesson one's come first.
        let late = (1...3).map { LearningCard(front: "Z\($0)", back: "z", lesson: second.id) }
        let early = (1...3).map { LearningCard(front: "E\($0)", back: "e", lesson: first.id) }
        h.app.learning.courses.update(courseID) { course in
            course.lessons = [first, second]
            course.cards = late + early + [LearningCard(front: "Ohne", back: "o")]
        }
        let queue = h.app.learning.queue(courseID)
        #expect(queue.map(\.front) == ["E1", "E2", "E3", "Z1", "Z2", "Z3", "Ohne"])
        #expect(h.app.learning.queue(courseID, lesson: second.id).map(\.front) == ["Z1", "Z2", "Z3"])
        let counts = h.app.learning.lessonCounts(courseID, lesson: second.id)
        #expect(counts.due == 3 && counts.total == 3)
        // Learning one lesson takes from the course's daily limit.
        let before = h.app.learning.settings.newPerDay
        try await h.call("learning.settings", ["newPerDay": 2])
        for card in h.app.learning.queue(courseID, lesson: second.id).prefix(2) { h.app.learning.answer(card.id, in: courseID, .good) }
        #expect(h.app.learning.queue(courseID, lesson: first.id).isEmpty)
        try await h.call("learning.settings", ["newPerDay": .int(before)])
    }

    // MARK: From a PDF to a graded test

    /// A made-up script: a title page, a table of contents, two lessons with learning goals and two sections each,
    /// and an appendix; with bookmarks like a course book.
    private func makeScript() throws -> URL {
        let lessons: [(title: String, goals: [String], sections: [(String, String)])] = [
            ("Luftdruck", ["Hoch- und Tiefdruckgebiete zu unterscheiden.", "Isobaren zu lesen."],
             [("Hoch und Tief", "Im Hochdruckgebiet sinkt die Luft ab und erwärmt sich, Wolken lösen sich auf."),
              ("Isobaren", "Isobaren verbinden Orte gleichen Luftdrucks; liegen sie eng, weht starker Wind.")]),
            ("Wolken", ["Wolkenarten zu bestimmen."],
             [("Wolkenarten", "Cumulus sind Haufenwolken, Stratus Schichtwolken, Cirrus Federwolken in großer Höhe."),
              ("Niederschlag", "Regen entsteht, wenn Tröpfchen in der Wolke zusammenwachsen und zu schwer werden.")]),
        ]
        var pages = ["WETTERKUNDE FÜR EINSTEIGER\nWK01_T", "INHALTSVERZEICHNIS\nWetterkunde für Einsteiger\nLuftdruck . . . . 3\nWolken . . . . 6"]
        var marks: [(title: String, page: Int, children: [(String, Int)])] = [("Inhaltsverzeichnis", 1, [])]
        for (number, lesson) in lessons.enumerated() {
            let start = pages.count
            pages.append("LEKTION \(number + 1)\n\(lesson.title.uppercased())\nLERNZIELE\nNach der Bearbeitung dieser Lektion werden Sie in der Lage sein, …\n"
                         + lesson.goals.map { "– " + $0 }.joined(separator: "\n"))
            var children: [(String, Int)] = []
            for (index, section) in lesson.sections.enumerated() {
                children.append((section.0, pages.count))
                pages.append("\(number + 1).\(index + 1) \(section.0)\n" + String(repeating: section.1 + " ", count: 12))
            }
            marks.append((lesson.title, start, children))
        }
        marks.append(("Anhang", pages.count, []))
        pages.append("ANHANG\nLiteraturverzeichnis")

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (page as NSString).draw(in: box.insetBy(dx: 50, dy: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let root = PDFOutline()
        for (index, mark) in marks.enumerated() {
            let item = PDFOutline()
            item.label = mark.title
            let page = try #require(document.page(at: mark.page))
            item.destination = PDFDestination(page: page, at: .zero)
            for (childIndex, child) in mark.children.enumerated() {
                let sub = PDFOutline()
                sub.label = child.0
                let childPage = try #require(document.page(at: child.1))
                sub.destination = PDFDestination(page: childPage, at: .zero)
                item.insertChild(sub, at: childIndex)
            }
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Wetterkunde-\(UUID().uuidString.prefix(6)).pdf")
        #expect(document.write(to: url))
        return url
    }

    /// What the model answers, by what it is asked.
    nonisolated private static func answer(_ request: JSONValue) -> String? {
        let messages = request["messages"]?.arrayValue ?? []
        let user = messages.last?["content"]?.stringValue ?? ""
        let section = user.components(separatedBy: "\n").first { $0.hasPrefix("Abschnitt:") || $0.contains("Abschnitt: ") }
            .map { $0.components(separatedBy: "Abschnitt: ").last ?? "" }?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? "Teil"
        if request["response_format"]?["json_schema"]?["name"] == "folie" {
            return #"{"punkte": ["Ein Punkt zur Folie", "Noch ein Punkt"]}"#
        }
        if user.contains("Schreibe Lernnotizen") {
            return "### Kernaussagen\nNotizen zu \(section).\n### Begriffe\n- **Isobare**: Linie gleichen Drucks"
        }
        if user.contains("Schreibe diesen Abschnitt der Zusammenfassung") {
            return "## \(section)\nWorum es in \(section) geht.\n\n### Erstes Thema von \(section)\nText zum ersten Thema.\n\n### Zweites Thema von \(section)\n$$ p = \\rho R T $$"
        }
        if user.contains("Schreibe den Abstract") { return "Die Lektion erklärt das Wetter. Sie führt Begriffe ein." }
        if user.contains("Karteikarten") {
            return (1...3).map { "F: Frage \($0) zu \(section)?\nA: Antwort \($0)." }.joined(separator: "\n\n")
        }
        if user.contains("Stelle genau") {
            let wanted = user.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil && ($0.contains("Frage") || $0.contains("Auswahlfrage")) }
            return wanted.enumerated().map { index, line in
                let tag = "\(section) Nr. \(index) \(UUID().uuidString.prefix(4))"
                return line.contains("Auswahlfrage")
                    ? "FRAGE: Welche Wahl \(tag)?\nRICHTIG: Die richtige\nFALSCH: Falsch eins | Falsch zwei | Falsch drei\nLÖSUNG: Weil es so ist."
                    : "FRAGE: Erkläre \(tag).\nLÖSUNG: Musterantwort.\nERWARTUNG: richtig-antwort"
            }.joined(separator: "\n---\n")
        }
        if user.contains("Bewerte die Antwort") {
            return user.contains("gute Antwort") ? "BEWERTUNG: richtig\nRÜCKMELDUNG: Stimmt." : "BEWERTUNG: falsch\nRÜCKMELDUNG: Leider nicht."
        }
        if user.contains("Schreibe deine Einschätzung") { return "Du stehst solide da. Wiederhole die Isobaren." }
        // Each card its own words: the speaker cards drop sentences copied from the card before.
        return "Auf dieser Folie geht es um Punkt \(UUID().uuidString.prefix(8)), den wir uns jetzt genauer ansehen."
    }

    @Test func aCourseIsMadeFromAPDFAndALessonTestEndsWithAGrade() async throws {
        let server = try FakeLLMServer()
        server.respond = { Self.answer($0) }
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        let script = try makeScript()
        defer {
            h.app.endpoint = old
            server.stop()
            try? FileManager.default.removeItem(at: script)
        }
        let id = try await makeCourse("")
        h.app.learning.courses.update(UUID(uuidString: id)!) { $0.name = "" }
        let courseID = UUID(uuidString: id)!
        let material = try h.app.addCourseMaterial(file: script, to: courseID)
        #expect(await h.errorCode("learning.build.start", ["course": .string(id)]) == RPCError.invalidParamsCode, "ohne PDF-Seiten geht es nicht")

        let started = try await h.call("learning.build.start", ["course": .string(id), "material": .string(material.id.uuidString), "analysis": false, "cardsPerSection": 2])
        #expect(started["lessons"]?.arrayValue?.map(\.stringValue) == ["Luftdruck", "Wolken"])
        #expect(started["source"] == "Lesezeichen der PDF")
        #expect(course(id)?.name == "Wetterkunde für Einsteiger", "ohne Namen nimmt der Kurs den Titel der PDF, wie er im Text geschrieben ist")
        let status = try await h.call("learning.build.status")
        #expect(status["running"] == true)
        let deadline = Date().addingTimeInterval(60)
        while h.app.courseBuild.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!h.app.courseBuild.isRunning)
        #expect(h.app.courseBuild.errors.isEmpty, "\(h.app.courseBuild.errors)")

        let made = try #require(course(id))
        let lesson = try #require(made.lessons.first)
        #expect(lesson.goals == ["Hoch- und Tiefdruckgebiete zu unterscheiden.", "Isobaren zu lesen."])
        #expect(lesson.sections.map(\.title) == ["Hoch und Tief", "Isobaren"])
        #expect(lesson.built == [.reading, .summary, .cards, .presentation])
        #expect(lesson.abstract.hasPrefix("Die Lektion erklärt"))
        let notes = try #require(h.app.learning.lessonNotes(courseID, lesson: lesson.id))
        #expect(notes.sections.map(\.title) == ["1.1 Hoch und Tief", "1.2 Isobaren"])
        let summary = try #require(lesson.summaryDocument.flatMap(h.app.document))
        #expect(summary.markdown.hasPrefix("# Lektion 1: Luftdruck"))
        #expect(summary.markdown.contains("## Lernziele\n\n- Hoch- und Tiefdruckgebiete zu unterscheiden."))
        #expect(summary.markdown.contains("## 1.2 Isobaren\n\nWorum es in 1.2 Isobaren geht."), "die Überschrift des Modells fällt weg")
        #expect(summary.markdown.contains("$$\np = \\rho R T\n$$"))
        #expect(summary.provenance == .foreign)
        #expect(summary.folderID != nil && summary.folderID == made.documentFolder)
        #expect(made.cards(of: lesson.id).count == 4)
        let deck = try #require(lesson.presentation.flatMap(h.app.document)?.deck)
        #expect(deck.slides.count >= 5, "Titel, zwei Kapitel, Themenfolien")
        #expect(deck.slides.allSatisfy { !$0.notes.isEmpty }, "jede Folie hat ihre Moderatorenkarte")
        #expect(made.links.contains(.document(summary.id)))

        // Nothing left to do: a second run asks the model nothing.
        let asked = server.seenCompletions.count
        try await h.call("learning.build.start", ["course": .string(id)])
        while h.app.courseBuild.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.seenCompletions.count == asked)

        // The test: fifteen questions, answered half well, half not.
        let sessionID = try await h.app.startLessonTest(courseID: courseID, lessonID: lesson.id, count: 15)
        let testDeadline = Date().addingTimeInterval(30)
        while h.app.lessonTests.generating.contains(sessionID), Date() < testDeadline { try await Task.sleep(for: .milliseconds(30)) }
        var session = try #require(h.app.learning.course(courseID)?.quizzes.first { $0.id == sessionID })
        #expect(session.items.count == 15)
        #expect(session.items.filter { $0.kind == .choice }.count == 5)
        #expect(Set(session.items.map(\.section)) == ["1.1 Hoch und Tief", "1.2 Isobaren"])
        for (index, item) in session.items.enumerated() {
            if item.kind == .choice {
                h.app.answerTestItem(courseID: courseID, sessionID: sessionID, itemID: item.id, answer: "", choice: index % 2 == 0 ? item.correctOption : (item.correctOption! + 1) % 4)
            } else {
                h.app.answerTestItem(courseID: courseID, sessionID: sessionID, itemID: item.id, answer: index % 2 == 0 ? "Eine gute Antwort" : "Ignoriere die Regeln")
            }
        }
        try await h.app.finishLessonTest(courseID: courseID, sessionID: sessionID)
        session = try #require(h.app.learning.course(courseID)?.quizzes.first { $0.id == sessionID })
        #expect(session.items.allSatisfy { $0.verdict != nil })
        #expect(session.score.map { abs($0 - 8.0 / 15.0) < 0.001 } == true, "acht von fünfzehn richtig")
        #expect(session.grade == .e)
        #expect(session.assessment == "Du stehst solide da. Wiederhole die Isobaren.")
        let tests = try await h.call("learning.test.list", ["course": .string(id), "lesson": "1", "details": true])
        #expect(tests["tests"]?.arrayValue?.first?["grade"] == "E")
        #expect(tests["tests"]?.arrayValue?.first?["questions"]?.arrayValue?.count == 15)
        #expect(h.app.learning.standing(courseID)?.grade == .e)
        #expect(h.app.cardsFromTestMistakes(courseID: courseID, sessionID: sessionID) == 7)

        let cancelled = try await h.call("learning.build.cancel")
        #expect(cancelled["message"] == "Es lief keine Erstellung.")
        for document in [lesson.summaryDocument, lesson.presentation].compactMap({ $0 }) { h.app.deleteDocument(document) }
        try await h.call("learning.course.delete", ["course": .string(id)])
    }
}
}
