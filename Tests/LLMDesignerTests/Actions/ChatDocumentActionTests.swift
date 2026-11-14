import Foundation
import LLMDProtocol
import Testing
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Chat: Dokumente als Anhang", .serialized)
struct ChatDocumentActionTests {
    let h = ActionHarness()

    private func chat() async throws -> String {
        try #require(try await h.call("chat.create", ["title": .string("Dokumente \(UUID().uuidString)")])["id"]?.stringValue)
    }

    private func withServer(_ script: [FakeLLMServer.Turn] = [], vision: Bool = false, _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer(script: script)
        if vision { server.modelType = "vlm" }
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    @Test func attachListReadAndRemove() async throws {
        let pdf = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: pdf) }
        let id = try await chat()

        let added = try await h.call("chat.document.attach", ["chat": .string(id), "files": .array([.string(pdf.path)])])
        let info = try #require(added["documents"]?.arrayValue?.first)
        let document = try #require(info["id"]?.stringValue)
        #expect(info["pages"] == 2)
        #expect(info["figures"] == 1)
        #expect(info["recognizedPages"] == [2])
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["documents"]?.arrayValue?.count == 1)

        let listed = try await h.call("chat.document.list", ["chat": .string(id)])
        #expect(listed["documents"]?.arrayValue?.first?["message"] == nil)

        let read = try await h.call("chat.document.read", ["chat": .string(id), "document": .string(pdf.lastPathComponent)])
        let text = try #require(read["text"]?.stringValue)
        #expect(text.contains("Leuchttürme") && text.contains("[Abbildung 1, Seite 1") && text.hasPrefix("<fremd-"))

        try await h.call("chat.document.removeDraft", ["chat": .string(id), "document": .string(document)])
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["documents"] == [])
        #expect(await h.errorCode("chat.document.removeDraft", ["chat": .string(id), "document": .string(document)]) == RPCError.notFoundCode)
    }

    @Test func picturesAreNotDocuments() async throws {
        let id = try await chat()
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("Bild-\(UUID().uuidString.prefix(6)).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }
        #expect(await h.errorCode("chat.document.attach", ["chat": .string(id), "files": .array([.string(picture.path)])]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("chat.document.attach", ["chat": .string(id), "files": ["/nicht/da.pdf"]]) == RPCError.notFoundCode)
    }

    @Test func attachingFromAChatOrMCPAsks() async throws {
        let text = try TestDocuments.text("Inhalt.")
        defer { try? FileManager.default.removeItem(at: text) }
        let id = try await chat()
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("chat.document.attach", ["chat": .string(id), "files": .array([.string(text.path)])], channel: .mcp) == RPCError.deniedCode)
    }

    @Test func sentDocumentReachesTheModelTheSameWayEachTime() async throws {
        let pdf = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: pdf) }
        try await withServer([.text("Es geht um Leuchttürme."), .text("Fünf Balken.")]) { server in
            let id = try await chat()
            h.app.updateChat(UUID(uuidString: id)!) {
                $0.modelId = "fake"
                $0.contextLength = 16384
            }
            try await h.call("chat.document.attach", ["chat": .string(id), "files": .array([.string(pdf.path)])])
            try await h.call("chat.send", ["chat": .string(id), "text": "Worum geht es?", "withDraft": true])
            _ = try await h.call("chat.wait", ["chat": .string(id)])
            #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["documents"] == [])

            let first = try #require(server.requests.last?["messages"]?.arrayValue?.first { $0["role"] == "user" }?["content"]?.stringValue)
            #expect(first.hasPrefix("Die Person hat die Datei „\(pdf.lastPathComponent)“ angehängt (2 Seiten, 1 davon als Bild erkannt, 1 Abbildung)"))
            #expect(first.contains("Leuchttürme an der Küste") && first.contains("[Abbildung 1, Seite 1: „Abb. 1: Testbalken der Messreihe“]"))
            #expect(first.hasSuffix("Worum geht es?"))

            let read = try await h.call("chat.read", ["chat": .string(id)])
            #expect(read["messages"]?.arrayValue?.first?["documents"] == [.string(pdf.lastPathComponent)])

            try await h.call("chat.send", ["chat": .string(id), "text": "Und die Abbildung?"])
            _ = try await h.call("chat.wait", ["chat": .string(id)])
            let again = try #require(server.requests.last?["messages"]?.arrayValue?.first { $0["role"] == "user" }?["content"]?.stringValue)
            #expect(again == first, "Der Anhang geht unverändert mit, damit der Präfix-Cache greift")
        }
    }

    @Test func documentsMarkTheRunAndStayPrivateOverMCP() async throws {
        let text = try TestDocuments.text("Geheime Zahlen: 4711.")
        defer { try? FileManager.default.removeItem(at: text) }
        let id = try await chat()
        let chatID = UUID(uuidString: id)!
        let document = try await DocumentStore.importDocument(text)
        h.app.updateChat(chatID) { $0.messages = [ChatMessage(role: .user, content: "Lies das.", documents: [document])] }
        let chat = try #require(h.app.chat(chatID))

        h.app.actionRegistryOverride = h.registry
        defer { h.app.actionRegistryOverride = nil }
        h.app.prepareActionRun(for: chat)
        let run = h.registry.runState(id: id, channel: .chat)
        #expect(run.hasReadUntrusted && run.hasReadSensitive)
        #expect(h.app.chatPreflight(chat).readsSensitive && h.app.chatPreflight(chat).readsUntrusted)

        #expect(await h.errorCode("chat.document.read", ["chat": .string(id), "document": .string(document.id.uuidString)], channel: .mcp) == RPCError.deniedCode)
        let read = try await h.call("chat.document.read", ["chat": .string(id), "document": .string(document.id.uuidString)])
        #expect(read["text"]?.stringValue?.contains("4711") == true)
    }

    @Test func figuresAreDescribedOnceAndGoAlongAsText() async throws {
        let pdf = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: pdf) }
        try await withServer([.text("Gut.")], vision: true) { server in
            let id = try await chat()
            h.app.updateChat(UUID(uuidString: id)!) {
                $0.modelId = "fake"
                $0.contextLength = 16384
            }
            let added = try await h.call("chat.document.attach", ["chat": .string(id), "files": .array([.string(pdf.path)])])
            let document = try #require(added["documents"]?.arrayValue?.first?["id"]?.stringValue)
            #expect(await h.errorCode("chat.document.describe", ["chat": .string(id), "document": .string(document)]) == RPCError.invalidTargetCode)

            try await h.call("chat.send", ["chat": .string(id), "text": "Was zeigt die Abbildung?", "withDraft": true])
            _ = try await h.call("chat.wait", ["chat": .string(id)])
            // Follow-up questions after the answer also ask without streaming; each request gets the same text.
            server.completions = Array(repeating: "Fünf graue Balken, die nach rechts ansteigen.", count: 8)
            let result = try await h.call("chat.document.describe", ["chat": .string(id), "document": .string(document)])
            #expect(result["described"] == 1)
            #expect(result["model"] == "fake")

            let request = try #require(server.seenCompletions.last?["messages"]?.arrayValue?.first?["content"]?.arrayValue)
            #expect(request.contains { $0["type"] == "image_url" })
            let read = try await h.call("chat.document.read", ["chat": .string(id), "document": .string(document)])
            let described = read["text"]?.stringValue ?? ""
            #expect(described.contains("Beschreibung von Abbildung 1, erstellt von fake, nicht geprüft: Fünf graue Balken"), "\(described)")
            #expect((try await h.call("chat.document.list", ["chat": .string(id)]))["documents"]?.arrayValue?.first?["describedFigures"] == 1)
            // Already described: nothing more to do unless asked again.
            #expect((try await h.call("chat.document.describe", ["chat": .string(id), "document": .string(document)]))["described"] == 0)
        }
    }
}
}
