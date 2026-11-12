import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Rechercherista: Actions", .serialized)
struct ResearchActionTests {
    let h = ActionHarness()

    @Test func researchesAreListedReadAndChanged() async throws {
        let question = "Frage \(UUID().uuidString.prefix(6))"
        let made = h.app.newResearch(question: question, open: false)
        h.app.research.records.update(made.id) { item in
            let root = ResearchNode(question: question)
            item.nodes = [root, ResearchNode(parent: root.id, question: "Teil?", status: .fertig, summary: "Text [1]", sources: [])]
            item.sources = [ResearchSource(number: 1, kind: .web, title: "Quelle", url: "https://example.org")]
            item.phase = .fertig
            item.report = "# Bericht\n\nText [1]\n"
        }
        let list = try await h.call("research.list", ["query": .string(question)])
        #expect(list["researches"]?.arrayValue?.first?["id"]?.stringValue == made.id.uuidString)
        let read = try await h.call("research.read", ["research": .string(made.id.uuidString)])
        #expect(read["tree"]?.arrayValue?.count == 2)
        #expect(read["sources"]?.arrayValue?.first?["number"] == 1)
        #expect(await h.errorCode("research.read", ["research": .string(made.id.uuidString), "include": "zu viel"]) == RPCError.invalidParamsCode)

        try await h.call("research.source.set", ["research": .string(made.id.uuidString), "number": 1, "accepted": false])
        #expect(h.app.research.research(made.id)?.sources.first?.accepted == false)
        try await h.call("writer.edit.undo")
        #expect(h.app.research.research(made.id)?.sources.first?.accepted == nil)

        let report = try await h.call("research.report", ["research": .string(made.id.uuidString)])
        #expect(report["report"]?.stringValue?.hasPrefix("# Bericht") == true)
        let doc = try await h.call("research.toDocument", ["research": .string(made.id.uuidString)])
        let docID = try #require(doc["id"]?.stringValue)
        #expect(h.app.document(UUID(uuidString: docID)!)?.provenance == .foreign)
        #expect(await h.errorCode("research.answer", ["research": .string(made.id.uuidString), "answer": "x"]) == RPCError.invalidTargetCode)

        try await h.call("research.delete", ["research": .string(made.id.uuidString)])
        #expect(h.app.research.research(made.id) == nil)
        try await h.call("writer.edit.undo")
        #expect(h.app.research.research(made.id)?.report.isEmpty == false)
    }

    @Test func startNeedsAQuestionAndSaysWhyItCannotRun() async throws {
        #expect(await h.errorCode("research.start") == RPCError.invalidParamsCode)
        #expect(await h.errorCode("research.start", ["question": "X", "sources": ["bibliothek"]]) == RPCError.invalidParamsCode)
        // Searching counts as acting outwards.
        #expect(h.registry.descriptor("research.start")?.security.effect == .outbound)
        #expect(h.registry.descriptor("research.read")?.security.readsUntrusted == true)
    }
}
}

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
