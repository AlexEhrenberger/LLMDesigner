import Foundation
import LLMDProtocol

/// A sequence of actions that belong together. It remembers what it has seen (A: something foreign, B: something
/// sensitive); that is what makes the third step of an attack visible.
@MainActor
final class RunState {
    let id: String
    let channel: ActionChannel
    private(set) var hasReadUntrusted: Bool
    private(set) var hasReadSensitive = false
    var lastUsed = Date()

    init(id: String = UUID().uuidString, channel: ActionChannel) {
        self.id = id
        self.channel = channel
        // A client behind MCP is a program we know nothing about: whatever it sends counts as foreign from the start.
        hasReadUntrusted = channel == .mcp
    }

    func markUntrusted() { hasReadUntrusted = true }
    func markSensitive() { hasReadSensitive = true }
}

/// The safety rule (`docs/plan/Sicherheitskonzept-Prompt-Injection.md`, 4.2) as a pure function, so all combinations
/// can be tested in a table. What it says holds whatever a model was told or tells.
enum ActionPolicy {
    enum Decision: Equatable, Sendable {
        case allow
        case ask(reason: String)
        case deny(reason: String)

        var label: String {
            switch self {
            case .allow: "erlaubt"
            case .ask: "gefragt"
            case .deny: "verweigert"
            }
        }
    }

    /// The approval level of a channel and kind of action, as far as the person can set it.
    enum Level: String, Codable, Sendable, CaseIterable {
        case allow, ask, deny

        var label: String {
            switch self {
            case .allow: "Erlauben"
            case .ask: "Fragen"
            case .deny: "Verweigern"
            }
        }
    }

    struct Input: Sendable, Hashable {
        var channel: ActionChannel
        var runHasUntrusted: Bool
        var runHasSensitive: Bool
        var security: ActionSecurity
        var kind: ActionKind
    }

    static let triangleReason = "Dieser Lauf hat fremde Inhalte und private Daten gelesen und würde jetzt nach außen wirken oder etwas zerstören."

    static func decide(_ input: Input, level: Level) -> Decision {
        // The person at the app's own controls.
        if input.channel == .ui { return .allow }

        let security = input.security
        if input.channel == .mcp, security.sensitive {
            return .deny(reason: "Private Daten (Gedächtnis, Persona-Dateien) sind über MCP gesperrt.")
        }
        let untrusted = input.runHasUntrusted || input.channel == .mcp || security.readsUntrusted
        let sensitive = input.runHasSensitive || security.sensitive
        let reaches = security.effect == .outbound || security.effect == .destructive

        if untrusted, sensitive, reaches { return .ask(reason: triangleReason) }
        if security.effect == .outbound, untrusted {
            return .ask(reason: "Dieser Lauf hat fremde Inhalte gelesen und würde Daten nach außen geben.")
        }
        if security.effect == .outbound, sensitive {
            return .ask(reason: "Dieser Lauf hat private Daten gelesen und würde Daten nach außen geben.")
        }
        if security.effect == .destructive, untrusted {
            return .ask(reason: "Dieser Lauf hat fremde Inhalte gelesen und würde etwas unwiderruflich ändern.")
        }
        if security.sensitive, untrusted {
            return .ask(reason: "Dieser Lauf hat fremde Inhalte gelesen und möchte jetzt private Daten lesen.")
        }

        // What is left is the person's setting. The levels of kind D start at "ask" (`defaultLevel`).
        switch level {
        case .allow:
            return .allow
        case .ask:
            return .ask(reason: "Für \(input.channel.label) ist bei „\(input.kind.label)“ eine Freigabe eingestellt.")
        case .deny:
            return .deny(reason: "Für \(input.channel.label) ist „\(input.kind.label)“ gesperrt.")
        }
    }

    /// The level until the person changes it.
    static func defaultLevel(channel: ActionChannel, kind: ActionKind) -> Level {
        switch (channel, kind) {
        case (.ui, _): .allow
        case (_, .read): .allow
        case (.chat, .write): .ask
        case (_, .write): .allow
        case (_, .destructive): .ask
        }
    }
}
