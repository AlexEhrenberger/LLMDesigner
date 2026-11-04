import AppKit
import LLMDProtocol

/// The connection to the running app.
final class LLMDClient {
    enum Failure: Error, LocalizedError {
        case appNotRunning(launchTried: Bool)
        case closed

        var errorDescription: String? {
            switch self {
            case .appNotRunning(let tried):
                tried ? "LLM Designer ließ sich nicht starten oder antwortet nicht." : "LLM Designer läuft nicht (--no-launch)."
            case .closed: "Die Verbindung zur App wurde beendet."
            }
        }
    }

    private let descriptor: Int32
    private var reader: LineReader
    private var nextID = 1

    /// Connects and logs in. Without a socket the app is started, unless `launch` is false.
    init(paths: SocketPaths = SocketPaths(), channel: String = "cli", launch: Bool = true) throws {
        var connected = try? UnixSocket.connect(path: paths.socket.path)
        if connected == nil {
            guard launch else { throw Failure.appNotRunning(launchTried: false) }
            Self.launchApp()
            // A library with many documents needs a moment.
            for _ in 0..<120 where connected == nil {
                Thread.sleep(forTimeInterval: 0.25)
                connected = try? UnixSocket.connect(path: paths.socket.path)
            }
        }
        guard let connected else { throw Failure.appNotRunning(launchTried: launch) }
        descriptor = connected
        reader = LineReader(descriptor: connected)
        let token = (try? String(contentsOf: paths.token, encoding: .utf8)) ?? ""
        _ = try request(RPCMethod.auth, params: ["token": .string(token), "channel": .string(channel)])
    }

    deinit {
        close(descriptor)
    }

    /// The app around this binary (`Contents/Helpers/llmd`), else whatever is registered under the bundle id.
    private static func launchApp() {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // A test instance needs to find the same socket as the client that started it.
        configuration.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("LLMD_") }
        let appURL = bundle.pathExtension == "app" ? bundle
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.llmdesigner.LLMDesigner")
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
    }

    func request(_ method: String, params: JSONValue = .object([:])) throws -> JSONValue {
        let id = nextID
        nextID += 1
        guard UnixSocket.writeAll(try RPCMessage(id: .int(id), method: method, params: params).line(), to: descriptor) else { throw Failure.closed }
        while let line = reader.next() {
            guard let message = try? JSONDecoder().decode(RPCMessage.self, from: line) else { continue }
            // Events can come in between.
            guard message.id == .int(id) else { continue }
            if let error = message.error { throw error }
            return message.result ?? .null
        }
        throw Failure.closed
    }

    func run(_ action: String, args: JSONValue = .object([:]), run: String? = nil) throws -> JSONValue {
        var params: [String: JSONValue] = ["id": .string(action), "args": args]
        if let run { params["run"] = .string(run) }
        return try request(RPCMethod.run, params: .object(params))
    }

    /// Hands each event to `body` until the connection ends.
    func listen(_ body: (ActionEvent) -> Void) {
        while let line = reader.next() {
            guard let message = try? JSONDecoder().decode(RPCMessage.self, from: line), message.method == RPCMethod.event,
                  let event = try? message.params?.decoded(as: ActionEvent.self) else { continue }
            body(event)
        }
    }
}
