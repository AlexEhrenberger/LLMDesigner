import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Learning Studio: Actions", .serialized)
struct LearningActionTests {
    let h = ActionHarness()

    private func course(_ id: String) -> LearningCourse? { h.app.learning.course(UUID(uuidString: id)!) }

    private func make(_ extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["name": .string("Kurs \(UUID().uuidString.prefix(8))")]
        args.merge(extra) { $1 }
        return try #require(try await h.call("learning.course.create", .object(args))["id"]?.stringValue)
    }

    @Test func coursesCardsAndReviews() async throws {
        let discipline = "Disziplin \(UUID().uuidString.prefix(6))"
        let id = try await make(["discipline": .string(discipline), "exam": "2027-02-10"])
        #expect(h.app.learning.discipline(course(id)?.discipline)?.name == discipline)
        #expect(course(id)?.examDate.map(ProjectDay.string) == "2027-02-10")

        try await h.call("learning.card.add", ["course": .string(id), "front": "Was ist Varianz?", "back": "Mittlere quadratische Abweichung"])
        let many = try await h.call("learning.card.addMany", ["course": .string(id), "text": "A ; 1\nB ; 2", "cards": [["front": "C", "back": "3"]]])
        #expect(many["added"] == 3)
        #expect(course(id)?.cards.count == 4)

        let due = try await h.call("learning.due", ["course": .string(id)])
        #expect(due["total"] == 4)
        #expect(due["due"]?.arrayValue?.first?["card"]?["back"] == nil, "ohne answers keine Rückseite")
        let first = try #require(due["due"]?.arrayValue?.first?["card"]?["id"]?.stringValue)
        let reviewed = try await h.call("learning.review", ["course": .string(id), "card": .string(first), "rating": "gut"])
        #expect(reviewed["state"] == "lernen")
        #expect(await h.errorCode("learning.review", ["course": .string(id), "card": .string(first), "rating": "super"]) == RPCError.invalidParamsCode)
        try await h.call("writer.edit.undo")
        #expect(course(id)?.card(UUID(uuidString: first)!)?.state == .new)

        let stats = try await h.call("learning.stats", ["course": .string(id)])
        #expect(stats["stats"]?["new"] == 4)
        let overview = try await h.call("learning.overview")
        #expect(overview["disciplines"]?.arrayValue?.contains { $0["name"]?.stringValue == discipline } == true)

        try await h.call("learning.card.update", ["course": .string(id), "card": "2", "suspended": true])
        #expect(course(id)?.cards[1].suspended == true)
        try await h.call("learning.card.delete", ["course": .string(id), "card": "C"])
        #expect(course(id)?.cards.count == 3)
        try await h.call("learning.course.delete", ["course": .string(id)])
        #expect(course(id) == nil)
        try await h.call("writer.edit.undo")
        #expect(course(id)?.cards.count == 3)
    }

    @Test func aPauseHoldsCardsAndMovesThemOn() async throws {
        let id = try await make()
        try await h.call("learning.card.addMany", ["course": .string(id), "text": "A ; 1\nB ; 2"])
        let courseID = UUID(uuidString: id)!
        let library = h.app.learning
        // Both cards learned and due in three days.
        let now = Date()
        for card in course(id)!.cards {
            library.answer(card.id, in: courseID, .easy, at: now.addingTimeInterval(-86_400 * 10))
        }
        library.courses.update(courseID) { course in for i in course.cards.indices { course.cards[i].due = now.addingTimeInterval(86_400 * 3) } }
        let due = course(id)!.cards[0].due

        try await h.call("learning.pause", ["course": .string(id), "reason": "Urlaub"])
        #expect(library.activePause(for: course(id)!) != nil)
        #expect(library.queue(courseID, at: now.addingTimeInterval(86_400 * 5)).isEmpty, "während der Pause kommt nichts")
        let pause = try #require(library.activePauses.first { $0.covers(course(id)!) })
        // Ten days later the pause ends: the cards move on by its length.
        library.endPause(pause.id, at: pause.start.addingTimeInterval(86_400 * 10))
        let moved = course(id)!.cards[0].due
        #expect(abs(moved.timeIntervalSince(due) - 86_400 * 10) < 5)
        let resumed = try await h.call("learning.resume")
        #expect(resumed["message"]?.stringValue?.isEmpty == false)
    }

    @Test func newCardsKeepToTheDailyLimit() async throws {
        let id = try await make()
        let text = (1...30).map { "Frage \($0) ; Antwort \($0)" }.joined(separator: "\n")
        try await h.call("learning.card.addMany", ["course": .string(id), "text": .string(text)])
        let before = h.app.learning.settings.newPerDay
        try await h.call("learning.settings", ["newPerDay": 5])
        #expect(h.app.learning.queue(UUID(uuidString: id)!).count == 5)
        try await h.call("learning.settings", ["newPerDay": .int(before)])
        #expect(await h.errorCode("learning.settings", ["algorithm": "leitner"]) == RPCError.invalidParamsCode)
    }
}
}
