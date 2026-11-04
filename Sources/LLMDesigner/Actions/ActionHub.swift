import Foundation
import LLMDProtocol

/// Registry and socket for the running app. The model comes from `appProvider` at every call, so the actions always
/// work on the library that is open right now.
@MainActor
final class ActionHub {
    static var shared: ActionHub?

    let registry: ActionRegistry
    private let appProvider: @MainActor () -> AppModel?
    private var server: ActionServer?

    init(registry: ActionRegistry? = nil, appProvider: @escaping @MainActor () -> AppModel?) {
        self.registry = registry ?? .standard()
        self.appProvider = appProvider
    }

    func start(paths: SocketPaths = SocketPaths()) throws {
        let server = ActionServer(paths: paths) { [weak self] message, connection in
            await self?.handle(message, connection: connection)
        }
        try server.start()
        self.server = server
        registry.eventSink = { [weak server] event in server?.broadcast(event) }
    }

    func stop() {
        registry.eventSink = nil
        server?.stop()
        server = nil
    }

    func handle(_ message: RPCMessage, connection: ActionConnection) async -> RPCMessage? {
        guard let method = message.method else { return nil }
        if method == RPCMethod.auth {
            let channel = message.params?["channel"]?.stringValue.flatMap(ActionChannel.init(rawValue:)) ?? .cli
            // "ui" and "chat" stand for the person at the app and for the app's own chat; nothing on a socket is either.
            guard channel == .cli || channel == .mcp,
                  connection.authenticate(token: message.params?["token"]?.stringValue ?? "", channel: channel) else {
                return RPCMessage(id: message.id, error: RPCError(code: RPCError.unauthorizedCode, message: "Anmeldung abgelehnt."))
            }
            return RPCMessage(id: message.id, result: .object(["ok": true, "run": .string(connection.sessionRun)]))
        }
        guard let channel = connection.channel else {
            return RPCMessage(id: message.id, error: RPCError(code: RPCError.unauthorizedCode, message: "Bitte zuerst anmelden."))
        }
        guard let app = appProvider() else {
            return RPCMessage(id: message.id, error: .unavailable("Die App ist noch nicht bereit."))
        }
        let params = message.params ?? .object([:])
        // An MCP session is one run, whatever its client claims: the state of a run must not be shed by leaving out an id.
        let run = channel == .mcp ? connection.sessionRun : params["run"]?.stringValue
        do {
            switch method {
            case RPCMethod.run:
                guard let id = params["id"]?.stringValue else { throw RPCError.invalidParams("„id“ fehlt.") }
                let result = try await registry.run(id, args: params["args"] ?? .object([:]), app: app, channel: channel, run: run)
                return RPCMessage(id: message.id, result: result)
            case RPCMethod.batch:
                guard let list = params["steps"]?.arrayValue else { throw RPCError.invalidParams("„steps“ fehlt.") }
                let steps = try list.map { step -> (id: String, args: JSONValue) in
                    guard let id = step["id"]?.stringValue else { throw RPCError.invalidParams("Ein Schritt hat keine „id“.") }
                    return (id, step["args"] ?? .object([:]))
                }
                let results = try await registry.runBatch(steps, app: app, channel: channel, run: run)
                return RPCMessage(id: message.id, result: .object(["results": .array(results)]))
            case RPCMethod.subscribe:
                connection.subscribe()
                return RPCMessage(id: message.id, result: .object(["ok": true]))
            default:
                throw RPCError(code: RPCError.methodNotFoundCode, message: "Unbekannte Methode „\(method)“.")
            }
        } catch let error as RPCError {
            return RPCMessage(id: message.id, error: error)
        } catch {
            return RPCMessage(id: message.id, error: .internal(error.localizedDescription))
        }
    }
}
