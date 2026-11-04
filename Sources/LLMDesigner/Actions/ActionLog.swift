import Foundation
import Observation
import LLMDProtocol

/// One action as the activity panel shows it. It holds no parameters or results, because those may hold private text.
struct ActionLogEntry: Identifiable, Sendable, Hashable {
    let id = UUID()
    var time = Date()
    var channel: ActionChannel
    var run: String
    var action: String
    var target: String?
    var hadUntrusted: Bool
    var hadSensitive: Bool
    var decision: String
    /// Nil when it worked; otherwise the error message.
    var error: String?
}

/// The most recent actions, in memory only: the protocol of a session, not a record about the person.
@MainActor
@Observable
final class ActionLog {
    static let capacity = 500
    private(set) var entries: [ActionLogEntry] = []

    func append(_ entry: ActionLogEntry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func clear() {
        entries = []
    }
}
