import Foundation
import LLMDProtocol

/// The stdio side of MCP: one JSON message per line on stdin and stdout. Nothing else may go to stdout, so anything
/// said for people goes to stderr.
final class MCPServer {
    private let adapter: MCPAdapter
    private let launch: Bool
    private let writeLock = NSLock()
    private let queue = DispatchQueue(label: "llmd.mcp")
    private var eventClient: LLMDClient?

    init(client: LLMDClient, profile: String, launch: Bool) {
        let status = try? client.run("app.status")
        adapter = MCPAdapter(backend: client, profile: profile, serverVersion: status?["version"]?.stringValue ?? "dev")
        self.launch = launch
    }

    private func write(_ messages: [RPCMessage]) {
        writeLock.withLock {
            for message in messages {
                if let line = try? message.line() { _ = UnixSocket.writeAll(line, to: STDOUT_FILENO) }
            }
        }
    }

    /// Runs until stdin ends. Calls are handled one after the other on a queue, so stdin stays read while one runs.
    func serve() {
        var reader = LineReader(descriptor: STDIN_FILENO)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(RPCMessage.self, from: line) else {
                write([RPCMessage(id: nil, error: RPCError(code: RPCError.parseErrorCode, message: "Parse error"))])
                continue
            }
            queue.async { [self] in
                write(adapter.handle(message))
                if adapter.hasSubscriptions { startEvents() }
            }
        }
        queue.sync { write(adapter.closingMessages()) }
    }

    /// Events have a connection of their own: the first one is busy while a long call runs.
    private func startEvents() {
        guard eventClient == nil, let client = try? LLMDClient(channel: "mcp", launch: launch) else { return }
        eventClient = client
        _ = try? client.request(RPCMethod.subscribe)
        Thread.detachNewThread { [self] in
            client.listen { event in self.write(self.adapter.notifications(for: event)) }
        }
    }
}
