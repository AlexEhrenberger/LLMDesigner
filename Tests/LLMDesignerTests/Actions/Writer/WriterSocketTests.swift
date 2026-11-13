import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// T8: an agent session over the real socket, as `llmd` and the MCP adapter speak to the app, on the throwaway library.
extension ActionSuites {
@MainActor
@Suite("Writer über den Socket (T8)", .serialized)
struct WriterSocketTests {
    private final class Requests {
        var list: [ApprovalRequest] = []
    }

    private func start(answer: Bool) throws -> (ActionHub, SocketPaths, Requests) {
        let directory = URL(fileURLWithPath: "/tmp/llmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = SocketPaths(directory: directory)
        let registry = ActionRegistry.standard()
        let requests = Requests()
        registry.approval.presenter = { request in
            requests.list.append(request)
            return answer
        }
        let hub = ActionHub(registry: registry) { TestApp.model() }
        try hub.start(paths: paths)
        return (hub, paths, requests)
    }

    /// The messages one after the other on one connection, on its own thread, because the answers need this main actor.
    nonisolated private func exchange(_ path: String, _ messages: [RPCMessage]) async -> [RPCMessage] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let descriptor = try? UnixSocket.connect(path: path) else {
                    continuation.resume(returning: [])
                    return
                }
                defer { close(descriptor) }
                var reader = LineReader(descriptor: descriptor)
                var answers: [RPCMessage] = []
                for message in messages {
                    guard let line = try? message.line(), UnixSocket.writeAll(line, to: descriptor), let answer = reader.next(),
                          let decoded = try? JSONDecoder().decode(RPCMessage.self, from: answer) else { break }
                    answers.append(decoded)
                }
                continuation.resume(returning: answers)
            }
        }
    }

    private func login(_ paths: SocketPaths, channel: String) throws -> RPCMessage {
        RPCMessage(id: .int(0), method: RPCMethod.auth, params: ["token": .string(try String(contentsOf: paths.token, encoding: .utf8)), "channel": .string(channel)])
    }

    private func run(_ number: Int, _ action: String, _ args: JSONValue) -> RPCMessage {
        RPCMessage(id: .int(number), method: RPCMethod.run, params: ["id": .string(action), "args": args])
    }

    @Test func anAgentWritesADocumentOverMCP() async throws {
        let (hub, paths, requests) = try start(answer: false)
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let title = "Socket \(UUID().uuidString)"
        let created = await exchange(paths.socket.path, [
            try login(paths, channel: "mcp"),
            run(1, "writer.doc.create", ["title": .string(title), "markdown": "# Bericht\n\nErster Absatz."]),
        ])
        let id = try #require(created.last?.result?["id"]?.stringValue)
        let doc = JSONValue.string(id)
        let answers = await exchange(paths.socket.path, [
            try login(paths, channel: "mcp"),
            run(2, "writer.text.insertMarkdown", ["doc": doc, "markdown": "## Teil\n\n- eins\n- zwei"]),
            run(3, "writer.format.bold", ["doc": doc, "match": "Erster", "state": "on"]),
            run(4, "writer.doc.read", ["doc": doc]),
            run(5, "writer.format.bold", ["doc": doc, "match": "gibtsnicht", "state": "on"]),
            run(6, "writer.format.bold", ["doc": doc, "tippfehler": true]),
            run(7, "writer.export", ["doc": doc, "format": "markdown"]),
            run(8, "writer.doc.delete", ["doc": doc]),
            RPCMessage(id: .int(9), method: RPCMethod.batch, params: ["steps": [
                ["id": "writer.text.insert", "args": ["doc": doc, "text": "Stapel"]],
                ["id": "writer.format.bold", "args": ["doc": doc, "match": "fehlt", "state": "on"]],
            ]]),
        ])
        #expect(answers.count == 9)
        #expect(answers[1].error == nil && answers[2].error == nil)
        let text = try #require(answers[3].result?["text"]?.stringValue)
        #expect(text.contains("**Erster** Absatz.") && text.contains("## Teil"))
        #expect(answers[3].result?["herkunft"]?.stringValue == DocumentProvenance.foreign.rawValue)
        #expect(answers[4].error?.code == RPCError.notFoundCode)
        #expect(answers[5].error?.code == RPCError.invalidParamsCode)
        // Export and delete ask the person; the person says no.
        #expect(answers[6].error?.code == RPCError.deniedCode)
        #expect(answers[7].error?.code == RPCError.deniedCode)
        #expect(requests.list.map(\.action) == ["writer.export", "writer.doc.delete"])
        #expect(requests.list.allSatisfy { $0.channel == .mcp })
        // The failed batch took its first step back.
        #expect(answers[8].error != nil)
        #expect(!(TestApp.model().document(UUID(uuidString: id)!)?.markdown.contains("Stapel") ?? true))
        #expect(TestApp.model().document(UUID(uuidString: id)!) != nil)
    }

    @Test func withoutTheTokenNothingIsWritten() async throws {
        let (hub, paths, _) = try start(answer: true)
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let title = "Ohne Token \(UUID().uuidString)"
        let answers = await exchange(paths.socket.path, [
            RPCMessage(id: .int(0), method: RPCMethod.auth, params: ["token": "falsch", "channel": "cli"]),
            run(1, "writer.doc.create", ["title": .string(title)]),
        ])
        #expect(answers.first?.error?.code == RPCError.unauthorizedCode)
        #expect(answers.last?.error?.code == RPCError.unauthorizedCode)
        #expect(!TestApp.model().documents.contains { $0.displayTitle == title })
    }
}
}
