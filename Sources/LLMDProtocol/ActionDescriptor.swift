import Foundation

/// How an action counts for approvals: reading, a change that can be undone, or something destructive or sensitive.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    case read, write, destructive

    public var label: String {
        switch self {
        case .read: "lesen"
        case .write: "schreiben"
        case .destructive: "destruktiv"
        }
    }
}

/// What an action does to the world beyond its result.
public enum ActionEffect: String, Codable, Sendable, CaseIterable {
    case none, local, destructive, outbound
}

/// The three properties the safety rule looks at. There is no default on purpose: a new action has to say.
public struct ActionSecurity: Codable, Sendable, Hashable {
    /// A: It reads content that doesn't come from the person. An action can also report this per call.
    public var readsUntrusted: Bool
    /// B: It reads private data.
    public var sensitive: Bool
    /// C: What it does.
    public var effect: ActionEffect

    public init(readsUntrusted: Bool, sensitive: Bool, effect: ActionEffect) {
        self.readsUntrusted = readsUntrusted
        self.sensitive = sensitive
        self.effect = effect
    }
}

/// Everything known about an action without running it. It describes the CLI command and the MCP tool as well.
public struct ActionDescriptor: Codable, Sendable, Hashable {
    /// With namespace, e.g. `writer.format.bold`.
    public var id: String
    public var summary: String
    public var kind: ActionKind
    public var security: ActionSecurity
    public var input: JSONSchema
    public var output: JSONSchema?
    public var example: String?
    /// Tool groups and MCP profiles it belongs to, e.g. `core`, `writer.core`.
    public var groups: [String]

    public init(id: String, summary: String, kind: ActionKind, security: ActionSecurity, input: JSONSchema = .object(),
                output: JSONSchema? = nil, example: String? = nil, groups: [String] = []) {
        self.id = id
        self.summary = summary
        self.kind = kind
        self.security = security
        self.input = input
        self.output = output
        self.example = example
        self.groups = groups
    }

    public var module: String { String(id.prefix { $0 != "." }) }

    /// A problem that makes the descriptor unfit to register, or nil. A read that changes something, or a change filed
    /// as a mere read, would slip past the approvals.
    public var inconsistency: String? {
        guard id.range(of: #"^[a-z]+(\.[a-zA-Z]+)+$"#, options: .regularExpression) != nil else {
            return "Ungültige Action-ID „\(id)“."
        }
        guard !summary.isEmpty else { return "„\(id)“ hat keine Zusammenfassung." }
        switch kind {
        case .read where security.effect != .none:
            return "„\(id)“: Lese-Actions haben keine Wirkung."
        case .write where security.effect == .destructive || security.effect == .outbound:
            return "„\(id)“: Destruktive oder nach außen wirkende Actions müssen Art „destruktiv“ haben."
        case .destructive where security.effect == .none && !security.sensitive:
            return "„\(id)“: Art „destruktiv“ braucht eine Wirkung oder sensible Daten."
        default:
            return nil
        }
    }
}
