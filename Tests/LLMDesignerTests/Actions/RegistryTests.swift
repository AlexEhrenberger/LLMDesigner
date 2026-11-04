import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// Actions only tests need.
struct EchoAction: LLMDAction {
    struct Args: Decodable, Sendable { var text: String }
    struct Output: Encodable, Sendable { var text: String }
    static let descriptor = ActionDescriptor(
        id: "test.echo", summary: "Echo", kind: .read, security: .plainRead, input: .object(["text": .string()], required: ["text"])
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output { Output(text: args.text) }
}

struct ForeignAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "test.foreign", summary: "Fremdes lesen", kind: .read, security: .foreignRead)
    static func run(_ args: NoArgs, context: ActionContext) async throws -> [String: String] { [:] }
}

struct SensitiveAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "test.sensitive", summary: "Privates lesen", kind: .destructive, security: .sensitiveRead)
    static func run(_ args: NoArgs, context: ActionContext) async throws -> [String: String] { [:] }
}

struct SendAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "test.send", summary: "Senden", kind: .destructive, security: .outbound)
    static func run(_ args: NoArgs, context: ActionContext) async throws -> [String: String] { ["sent": "ja"] }
}

struct FailingAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "test.fail", summary: "Scheitert", kind: .write, security: .localWrite)
    static func run(_ args: NoArgs, context: ActionContext) async throws -> [String: String] { throw RPCError.notFound("weg") }
}

@MainActor
@Suite("Action-Registry")
struct RegistryTests {
    private func registry() -> ActionRegistry {
        let registry = ActionRegistry()
        registry.registerAppActions()
        registry.register(EchoAction.self)
        registry.register(ForeignAction.self)
        registry.register(SensitiveAction.self)
        registry.register(SendAction.self)
        registry.register(FailingAction.self)
        return registry
    }

    private func code(of body: () async throws -> Void) async -> Int? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? RPCError)?.code
        }
    }

    @Test func runsAnAction() async throws {
        let result = try await registry().run("test.echo", args: ["text": "hallo"], app: TestApp.model(), channel: .cli)
        #expect(result["text"] == "hallo")
    }

    @Test func unknownActionIsMethodNotFound() async {
        let registry = registry()
        #expect(await code { try await registry.run("gibt.es.nicht", app: TestApp.model(), channel: .cli) } == RPCError.methodNotFoundCode)
    }

    @Test func wrongParametersAreInvalidParams() async {
        let registry = registry()
        let app = TestApp.model()
        #expect(await code { try await registry.run("test.echo", args: ["text": 3], app: app, channel: .cli) } == RPCError.invalidParamsCode)
        #expect(await code { try await registry.run("test.echo", args: [:], app: app, channel: .cli) } == RPCError.invalidParamsCode)
        #expect(await code { try await registry.run("test.echo", args: ["text": "a", "x": 1], app: app, channel: .cli) } == RPCError.invalidParamsCode)
    }

    @Test func nullArgsMeanNone() async throws {
        try await registry().run("app.status", args: .null, app: TestApp.model(), channel: .cli)
    }

    @Test func statusAndListWork() async throws {
        let registry = registry()
        let status = try await registry.run("app.status", app: TestApp.model(), channel: .cli)
        #expect(status["library"] == "Test")
        let list = try await registry.run("actions.list", args: ["module": "test"], app: TestApp.model(), channel: .cli)
        #expect(list["actions"]?.arrayValue?.count == 5)
        let described = try await registry.run("actions.describe", args: ["id": "test.echo"], app: TestApp.model(), channel: .cli)
        #expect(described["security"]?["effect"] == "none")
    }

    @Test func standardRegistryIsConsistent() {
        let registry = ActionRegistry.standard()
        #expect(registry.descriptors.count > 3)
        for descriptor in registry.descriptors {
            #expect(descriptor.inconsistency == nil)
            // An option named like a global one could never be set from the terminal.
            for name in ["json", "quiet", "stdin", "run", "stdinTo", "noLaunch", "args"] {
                #expect(descriptor.input.properties?[name] == nil, "\(descriptor.id): \(name)")
            }
        }
    }

    // The run remembers what it has seen, and the third step of the triangle asks.

    @Test func theRunRemembersAcrossCalls() async throws {
        let registry = registry()
        let app = TestApp.model()
        var requests: [ApprovalRequest] = []
        registry.approval.presenter = { requests.append($0); return true }
        try await registry.run("test.foreign", app: app, channel: .cli, run: "r1")
        try await registry.run("test.sensitive", app: app, channel: .cli, run: "r1")
        try await registry.run("test.send", app: app, channel: .cli, run: "r1")
        #expect(requests.count == 2)
        #expect(requests[0].reason.contains("private Daten"))
        #expect(requests[1].reason == ActionPolicy.triangleReason)
        #expect(requests[1].channel == .cli)
    }

    @Test func refusedApprovalIsDenied() async {
        let registry = registry()
        let app = TestApp.model()
        registry.approval.presenter = { _ in false }
        #expect(await code { try await registry.run("test.send", app: app, channel: .cli) } == RPCError.deniedCode)
        #expect(registry.log.entries.last?.decision == "abgelehnt")
    }

    @Test func withoutARunIdEachCallStandsAlone() async throws {
        let registry = registry()
        let app = TestApp.model()
        var asked = 0
        registry.approval.presenter = { _ in asked += 1; return true }
        try await registry.run("test.foreign", app: app, channel: .cli)
        // The sensitive read has kind D, so it asks by level, but not with the reason of a foreign run.
        try await registry.run("test.sensitive", app: app, channel: .cli)
        #expect(asked == 1)
        #expect(registry.runState(id: nil, channel: .cli).hasReadUntrusted == false)
    }

    @Test func mcpCannotReadSensitive() async {
        let registry = registry()
        let app = TestApp.model()
        registry.approval.presenter = { _ in true }
        #expect(await code { try await registry.run("test.sensitive", app: app, channel: .mcp) } == RPCError.deniedCode)
    }

    @Test func aClosedDoorSaysNothingAboutWhatIsBehindIt() async {
        let registry = ActionRegistry.standard()
        let app = TestApp.model()
        registry.approval.presenter = { _ in true }
        #expect(await code { try await registry.run("memory.list", args: ["persona": "Gibt es nicht"], app: app, channel: .mcp) } == RPCError.deniedCode)
    }

    @Test func aCliRunCannotTakeOverAnMcpRun() {
        let registry = registry()
        #expect(registry.runState(id: "x", channel: .mcp).hasReadUntrusted)
        #expect(!registry.runState(id: "x", channel: .cli).hasReadUntrusted)
    }

    @Test func theLogKeepsDecisionsButNoData() async throws {
        let registry = registry()
        let app = TestApp.model()
        try await registry.run("test.echo", args: ["text": "geheimer Text"], app: app, channel: .cli)
        let entry = try #require(registry.log.entries.last)
        #expect(entry.action == "test.echo")
        #expect(entry.decision == "erlaubt")
        #expect(entry.error == nil)
        #expect(!"\(entry)".contains("geheimer Text"))
        _ = await code { try await registry.run("test.fail", app: app, channel: .cli) }
        #expect(registry.log.entries.last?.error == "weg")
    }
}
