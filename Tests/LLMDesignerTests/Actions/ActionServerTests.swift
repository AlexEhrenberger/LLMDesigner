import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("llmd-Socket")
struct ActionServerTests {
    private func start() throws -> (ActionHub, SocketPaths) {
        // Short: a socket path has at most 103 bytes.
        let directory = URL(fileURLWithPath: "/tmp/llmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = SocketPaths(directory: directory)
        let registry = ActionRegistry()
        registry.registerAppActions()
        registry.register(EchoAction.self)
        registry.register(FailingAction.self)
        registry.register(SendAction.self)
        registry.approval.presenter = { _ in false }
        let hub = ActionHub(registry: registry) { TestApp.model() }
        try hub.start(paths: paths)
        return (hub, paths)
    }

    /// A request on its own thread, because the answer needs this main actor.
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

    private func login(_ token: String, channel: String = "cli") -> RPCMessage {
        RPCMessage(id: .int(0), method: RPCMethod.auth, params: ["token": .string(token), "channel": .string(channel)])
    }

    private func token(_ paths: SocketPaths) throws -> String {
        try String(contentsOf: paths.token, encoding: .utf8)
    }

    @Test func socketAndTokenBelongToTheUser() throws {
        let (hub, paths) = try start()
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let manager = FileManager.default
        #expect((try manager.attributesOfItem(atPath: paths.directory.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try manager.attributesOfItem(atPath: paths.socket.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try manager.attributesOfItem(atPath: paths.token.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aCallWorksAfterLogin() async throws {
        let (hub, paths) = try start()
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let answers = await exchange(paths.socket.path, [
            login(try token(paths)),
            RPCMessage(id: .int(1), method: RPCMethod.run, params: ["id": "test.echo", "args": ["text": "hi"]]),
            RPCMessage(id: .int(2), method: RPCMethod.run, params: ["id": "app.status"]),
        ])
        #expect(answers.count == 3)
        #expect(answers[0].result?["ok"] == true)
        #expect(answers[1].result?["text"] == "hi")
        #expect(answers[2].result?["library"] == "Test")
    }

    @Test func wrongTokenIsRefusedAndNothingRuns() async throws {
        let (hub, paths) = try start()
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let answers = await exchange(paths.socket.path, [
            login("falsch"),
            RPCMessage(id: .int(1), method: RPCMethod.run, params: ["id": "app.status"]),
        ])
        #expect(answers.map(\.error?.code) == [RPCError.unauthorizedCode, RPCError.unauthorizedCode])
    }

    @Test func aSocketClientCannotClaimToBeTheUI() async throws {
        let (hub, paths) = try start()
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        let good = try token(paths)
        for channel in ["ui", "chat"] {
            let answers = await exchange(paths.socket.path, [login(good, channel: channel)])
            #expect(answers.first?.error?.code == RPCError.unauthorizedCode)
        }
    }

    @Test func mcpSessionIsOneRunWhateverItClaims() async throws {
        let (hub, paths) = try start()
        defer { hub.stop(); try? FileManager.default.removeItem(at: paths.directory) }
        var seen: [ApprovalRequest] = []
        hub.registry.approval.presenter = { seen.append($0); return false }
        let answers = await exchange(paths.socket.path, [
            login(try token(paths), channel: "mcp"),
            RPCMessage(id: .int(1), method: RPCMethod.run, params: ["id": "test.send", "run": "frisch"]),
        ])
        #expect(answers.last?.error?.code == RPCError.deniedCode)
        #expect(seen.first?.channel == .mcp)
        #expect(seen.first?.reason.contains("fremde") == true)
    }

    @Test func aStaleSocketIsReplacedAndRemovedOnStop() async throws {
        let directory = URL(fileURLWithPath: "/tmp/llmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = SocketPaths(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("alt".utf8).write(to: paths.socket)
        let hub = ActionHub(registry: ActionRegistry()) { TestApp.model() }
        try hub.start(paths: paths)
        #expect(try UnixSocket.connect(path: paths.socket.path) >= 0)
        hub.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.socket.path))
        #expect(!FileManager.default.fileExists(atPath: paths.token.path))
    }

    @Test func connectionComparesTokensExactly() {
        #expect(ActionConnection.constantTimeEqual("abc", "abc"))
        #expect(!ActionConnection.constantTimeEqual("abc", "abd"))
        #expect(!ActionConnection.constantTimeEqual("abc", "abcd"))
    }
}
}
