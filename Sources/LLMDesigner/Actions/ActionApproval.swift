import AppKit
import LLMDProtocol

/// What the person sees when a call needs consent. Always with the reason: a question without one only trains them to
/// click it away.
struct ApprovalRequest: Sendable, Equatable {
    var action: String
    var summary: String
    var channel: ActionChannel
    var target: String?
    var detail: String?
    var reason: String
}

/// Approval levels per channel and kind of action (in the library's settings), and the dialog.
@MainActor
final class ActionApproval {
    private static let settingsKey = "actionApprovalLevels"
    /// How much of the data a dialog shows.
    static let detailLimit = 400

    /// Answers a request. Replaced in tests; with no one there to answer, "ask" means no.
    var presenter: @MainActor (ApprovalRequest) async -> Bool = ActionApproval.presentAlert

    func level(channel: ActionChannel, kind: ActionKind, settings: LibrarySettings) -> ActionPolicy.Level {
        let stored = settings.string(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([String: ActionPolicy.Level].self, from: Data($0.utf8)) }
        return stored?["\(channel.rawValue).\(kind.rawValue)"] ?? ActionPolicy.defaultLevel(channel: channel, kind: kind)
    }

    func setLevel(_ level: ActionPolicy.Level, channel: ActionChannel, kind: ActionKind, settings: LibrarySettings) {
        var stored = settings.string(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([String: ActionPolicy.Level].self, from: Data($0.utf8)) } ?? [:]
        stored["\(channel.rawValue).\(kind.rawValue)"] = level
        if let data = try? JSONEncoder().encode(stored), let text = String(data: data, encoding: .utf8) {
            settings.set(text, forKey: Self.settingsKey)
        }
    }

    static func abridged(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count > detailLimit ? String(text.prefix(detailLimit)) + " …" : text
    }

    static func presentAlert(_ request: ApprovalRequest) async -> Bool {
        guard NSApp != nil else { return false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(request.channel.label) möchte: \(request.summary)"
        var lines = ["Action: \(request.action)"]
        if let target = request.target { lines.append("Ziel: \(target)") }
        if let detail = abridged(request.detail) { lines.append("Daten: \(detail)") }
        lines.append("")
        lines.append("Grund der Rückfrage: \(request.reason)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Nicht erlauben")
        alert.addButton(withTitle: "Erlauben")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
