import Foundation
import LLMDProtocol

enum MCPProfile {
    static let names = ["core", "writer", "presenter", "citation", "stories", "chat", "full"]
}

/// Placeholder replaced in phase 5.
final class MCPServer {
    init(client: LLMDClient, profile: String) {}
    func serve() {}
}
