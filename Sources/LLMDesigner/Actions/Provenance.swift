import Foundation
import LLMDProtocol

/// Where a document's content comes from. Only "foreign" has consequences (safety concept, 4.1): reading it marks the
/// run, and whatever a marked run writes becomes foreign too. No entry in a file means the person's own, which holds
/// for everything from before there were actions.
enum DocumentProvenance: String, Codable, Sendable, CaseIterable {
    /// Written by the person.
    case own = "eigen"
    /// Made by the app or the local model from the person's own material.
    case `internal` = "intern"
    /// From the web, an import, an MCP client, or a run that had read something foreign.
    case foreign = "fremd"
}

extension ActionContext {
    /// The origin of what this run writes.
    var writeProvenance: DocumentProvenance {
        if run.hasReadUntrusted || channel == .mcp { return .foreign }
        return channel == .chat ? .internal : .own
    }

    /// What a document's origin becomes after this run wrote to it: foreign stays foreign and passes on; otherwise
    /// the run's own origin only replaces it if that is the weaker one, so a CLI edit doesn't launder anything.
    func mergedProvenance(_ current: DocumentProvenance?) -> DocumentProvenance? {
        if current == .foreign || writeProvenance == .foreign { return .foreign }
        if current == .internal || writeProvenance == .internal { return .internal }
        return current
    }
}

extension WriterDocument {
    var isForeign: Bool { provenance == .foreign }
}
