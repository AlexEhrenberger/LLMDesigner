import Foundation
import LLMDProtocol

/// The ways an action can be reached.
enum ActionChannel: String, Codable, Sendable, CaseIterable {
    case ui, cli, mcp, chat

    var label: String {
        switch self {
        case .ui: "Oberfläche"
        case .cli: "Terminal"
        case .mcp: "MCP"
        case .chat: "Chat"
        }
    }
}

/// One thing the app can do, reachable from the terminal, MCP and the chat. Actions are thin wrappers around what
/// `AppModel` already does. `Args` and `Output` are plain Codable types; the schema in the descriptor is what is
/// checked and published, so it decides what comes in.
protocol LLMDAction {
    associatedtype Args: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    static var descriptor: ActionDescriptor { get }

    /// What the safety rule has to know before the action runs. The default adds nothing.
    @MainActor static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight

    @MainActor static func run(_ args: Args, context: ActionContext) async throws -> Output
}

extension LLMDAction {
    @MainActor static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { ActionPreflight() }
}

/// What only a look at the concrete call can tell.
struct ActionPreflight: Sendable {
    /// This call reads content of foreign origin, even if the action in general doesn't.
    var readsUntrusted = false
    /// The call needs the person's consent whatever the rule says, for this reason.
    var needsConsent: String?
    /// The call stays where the person said it may: a file in the export folder. The level of "write" applies then
    /// instead of "destructive". The rules about foreign and private data still hold.
    var isInSafePlace = false
    /// For the dialog and the log: what the call is about.
    var target: String?
    /// For the dialog: an excerpt of the data.
    var detail: String?
}

/// No parameters.
struct NoArgs: Decodable, Sendable {}

/// Everything an action may use.
@MainActor
struct ActionContext {
    let app: AppModel
    let channel: ActionChannel
    let run: RunState
    let undoGroup: UndoGroup
    let registry: ActionRegistry

    /// The editor's pending text in the model, so an action sees what the person sees.
    func flushEditor() {
        app.writerFlush?()
    }
}
