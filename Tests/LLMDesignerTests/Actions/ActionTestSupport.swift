import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// A registry with all actions on the test library, and small helpers for its calls.
@MainActor
struct ActionHarness {
    let registry = ActionRegistry.standard()
    let app = TestApp.model()

    init() {
        registry.approval.presenter = { _ in true }
    }

    @discardableResult
    func call(_ id: String, _ args: JSONValue = [:], channel: ActionChannel = .cli, run: String? = nil) async throws -> JSONValue {
        try await registry.run(id, args: args, app: app, channel: channel, run: run)
    }

    /// A new document; its title is unique, so tests don't meet each other's.
    func document(_ markdown: String) async throws -> String {
        let result = try await call("writer.doc.create", ["title": .string("Test \(UUID().uuidString)"), "markdown": .string(markdown)])
        return try #require(result["id"]?.stringValue)
    }

    func text(_ id: String) -> String {
        app.document(UUID(uuidString: id)!)?.markdown ?? "<weg>"
    }

    func trimmed(_ id: String) -> String {
        text(id).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func errorCode(_ id: String, _ args: JSONValue = [:], channel: ActionChannel = .cli, run: String? = nil) async -> Int? {
        do {
            try await call(id, args, channel: channel, run: run)
            return nil
        } catch {
            return (error as? RPCError)?.code
        }
    }
}
