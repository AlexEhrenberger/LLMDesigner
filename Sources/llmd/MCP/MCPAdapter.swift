import Foundation
import LLMDProtocol

/// What the adapter needs from the app. A protocol so tests can use recorded messages without a socket.
protocol MCPBackend: AnyObject {
    func run(_ action: String, args: JSONValue) throws -> JSONValue
}

extension LLMDClient: MCPBackend {
    func run(_ action: String, args: JSONValue) throws -> JSONValue {
        try run(action, args: args, run: nil)
    }
}

enum MCPProfile {
    static let names = ["core", "writer", "presenter", "citation", "stories", "chat", "full"]

    /// Whether an action belongs to a profile. Private groups never do: the app refuses them on this channel anyway,
    /// and a tool that can only fail just costs a small model context.
    static func contains(_ action: ActionDescriptor, profile: String) -> Bool {
        guard !action.security.sensitive, action.module != "actions" else { return false }
        switch profile {
        case "full": return true
        case "core": return action.groups.contains("core")
        default: return action.module == profile || action.groups.contains("\(profile).core")
                || (profile == "chat" && ["persona", "skill", "models"].contains(action.module))
        }
    }
}

/// MCP in front of the registry, without any protocol knowledge in the app. It serves revision 2026-07-28 (every
/// request carries its version in `_meta`) and the earlier handshake, which many clients still start with.
final class MCPAdapter {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let supportedVersions = [modernVersion] + legacyVersions
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"
    static let unsupportedVersionCode = -32022
    static let searchTool = "llmd_search_actions"
    static let runTool = "llmd_run_action"

    /// A tool list changes only with a new app version.
    static let toolListTTL = 300_000
    static let instructions = """
    LLM Designer: Dokumente, Präsentationen, Quellen, Romanwelten und Chats mit dem lokalen Modell. \
    Lesen liefert eine version; Schreiben nimmt sie als ifVersion, damit nichts überschrieben wird. \
    Heikles fragt die App den Menschen, und private Daten sind über diesen Weg gesperrt. \
    llmd_search_actions findet weitere Actions, llmd_run_action führt sie aus.
    """

    private let backend: MCPBackend
    private let profile: String
    private var isLegacy = false
    private var descriptors: [ActionDescriptor]?
    private let serverVersion: String
    /// Open `subscriptions/listen` requests and what each asked for.
    private var subscriptions: [(id: RPCID, filter: JSONValue)] = []
    private let lock = NSLock()

    var hasSubscriptions: Bool { lock.withLock { !subscriptions.isEmpty } }

    init(backend: MCPBackend, profile: String, serverVersion: String = "dev") {
        self.backend = backend
        self.profile = profile
        self.serverVersion = serverVersion
    }

    private var serverInfo: JSONValue {
        ["name": "llmd", "title": "LLM Designer", "version": .string(serverVersion)]
    }

    private static let capabilities: JSONValue = ["tools": [:], "resources": ["subscribe": true, "listChanged": true], "prompts": [:]]

    // MARK: Messages

    /// The answers to one message, in order. A notification gets none.
    func handle(_ message: RPCMessage) -> [RPCMessage] {
        guard let method = message.method else { return [] }
        guard let id = message.id else {
            if method == "notifications/cancelled", let cancelled = message.params?["requestId"] { cancel(cancelled) }
            return []
        }
        let params = message.params ?? .object([:])
        do {
            switch method {
            case "initialize":
                return [RPCMessage(id: id, result: initialize(params))]
            case "ping":
                return [RPCMessage(id: id, result: .object([:]))]
            case "server/discover":
                return [RPCMessage(id: id, result: finished(discover(), cacheable: (Self.toolListTTL, "public")))]
            default:
                break
            }
            if let refusal = versionRefusal(params) { return [RPCMessage(id: id, error: refusal)] }
            switch method {
            case "subscriptions/listen":
                return listen(id: id, params: params)
            case "tools/list":
                return [RPCMessage(id: id, result: finished(["tools": .array(try tools())], cacheable: (Self.toolListTTL, "public")))]
            case "tools/call":
                return [RPCMessage(id: id, result: finished(try callTool(params)))]
            case "resources/list":
                return [RPCMessage(id: id, result: finished(["resources": .array(try resources())], cacheable: (0, "private")))]
            case "resources/templates/list":
                return [RPCMessage(id: id, result: finished(["resourceTemplates": .array(Self.templates)], cacheable: (Self.toolListTTL, "public")))]
            case "resources/read":
                return [RPCMessage(id: id, result: finished(try readResource(params), cacheable: (0, "private")))]
            case "prompts/list":
                return [RPCMessage(id: id, result: finished(["prompts": .array(try prompts())], cacheable: (0, "private")))]
            case "prompts/get":
                return [RPCMessage(id: id, result: finished(try prompt(params)))]
            default:
                return [RPCMessage(id: id, error: RPCError(code: RPCError.methodNotFoundCode, message: "Unbekannte Methode: \(method)"))]
            }
        } catch let error as RPCError {
            return [RPCMessage(id: id, error: error)]
        } catch {
            return [RPCMessage(id: id, error: RPCError(code: RPCError.internalErrorCode, message: error.localizedDescription))]
        }
    }

    /// Modern requests name their version; a legacy session agreed on one in its handshake.
    private func versionRefusal(_ params: JSONValue) -> RPCError? {
        let requested = params["_meta"]?[Self.versionKey]?.stringValue
        if let requested {
            guard Self.supportedVersions.contains(requested) else {
                return RPCError(code: Self.unsupportedVersionCode, message: "Unsupported protocol version",
                                data: ["supported": .array(Self.supportedVersions.map { .string($0) }), "requested": .string(requested)])
            }
            return nil
        }
        return isLegacy ? nil : RPCError(code: RPCError.invalidParamsCode, message: "Dem Aufruf fehlt _meta.\(Self.versionKey).")
    }

    /// The standard fields of a result. An old client doesn't know them, and they mean nothing to it.
    private func finished(_ fields: JSONValue, cacheable: (ttl: Int, scope: String)? = nil) -> JSONValue {
        guard !isLegacy, case .object(var object) = fields else { return fields }
        object["resultType"] = "complete"
        var meta = object["_meta"]?.objectValue ?? [:]
        meta[Self.serverInfoKey] = serverInfo
        object["_meta"] = .object(meta)
        if let cacheable {
            object["ttlMs"] = .int(cacheable.ttl)
            object["cacheScope"] = .string(cacheable.scope)
        }
        return .object(object)
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        isLegacy = true
        let requested = params["protocolVersion"]?.stringValue ?? ""
        return [
            "protocolVersion": .string(Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]),
            // Without a stream of its own a legacy session gets no change notifications.
            "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
            "serverInfo": serverInfo,
            "instructions": .string(Self.instructions),
        ]
    }

    private func discover() -> JSONValue {
        [
            "supportedVersions": .array(Self.supportedVersions.map { .string($0) }),
            "capabilities": Self.capabilities,
            "_meta": .object([Self.serverInfoKey: serverInfo]),
            "instructions": .string(Self.instructions),
        ]
    }

    // MARK: Tools

    static func toolName(_ actionID: String) -> String {
        actionID.replacingOccurrences(of: ".", with: "_")
    }

    private func allActions() throws -> [ActionDescriptor] {
        if let descriptors { return descriptors }
        let list = try backend.run("actions.list", args: .object([:]))["actions"]?.decoded(as: [ActionDescriptor].self) ?? []
        descriptors = list
        return list
    }

    /// The fixed order is part of the deal: it keeps a client's prompt cache valid.
    func tools() throws -> [JSONValue] {
        let actions = try allActions().filter { MCPProfile.contains($0, profile: profile) }.sorted { $0.id < $1.id }
        return Self.metaTools + actions.map(Self.tool)
    }

    static func tool(_ action: ActionDescriptor) -> JSONValue {
        var tool: [String: JSONValue] = [
            "name": .string(toolName(action.id)),
            "description": .string(action.summary),
            "inputSchema": action.input.document,
            "annotations": [
                "title": .string(action.summary),
                "readOnlyHint": .bool(action.kind == .read),
                "destructiveHint": .bool(action.security.effect == .destructive || action.security.effect == .outbound),
                "openWorldHint": .bool(action.security.effect == .outbound),
            ],
        ]
        if let output = action.output { tool["outputSchema"] = output.document }
        return .object(tool)
    }

    private static let metaTools: [JSONValue] = [
        [
            "name": .string(searchTool),
            "description": "Findet weitere Actions dieser App, nach Stichwort oder Modul, mit Parametern",
            "inputSchema": JSONSchema.object(["query": .string("Stichwort"), "module": .string("Modul: writer, presenter, citation, stories, chat")]).document,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": .string(runTool),
            "description": "Führt eine Action nach ID aus, z. B. eine, die llmd_search_actions gefunden hat",
            "inputSchema": JSONSchema.object(["id": .string("ID der Action"), "args": .freeObject("Ihre Parameter")], required: ["id"]).document,
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
        ],
    ]

    private func callTool(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("„name“ fehlt.") }
        let arguments = params["arguments"] ?? .object([:])
        if name == Self.searchTool { return try searchActions(arguments) }
        let action: String
        var args = arguments
        if name == Self.runTool {
            guard let id = arguments["id"]?.stringValue else { return Self.failure("„id“ fehlt.") }
            action = id
            args = arguments["args"] ?? .object([:])
            // A tool outside the profile is fine here; the app's rules stay the same.
            guard try allActions().contains(where: { $0.id == id }) else { return Self.failure("Unbekannte Action „\(id)“.") }
        } else {
            guard let found = try allActions().first(where: { Self.toolName($0.id) == name && MCPProfile.contains($0, profile: profile) }) else {
                throw RPCError.invalidParams("Unknown tool: \(name)")
            }
            action = found.id
        }
        do {
            return Self.success(try backend.run(action, args: args))
        } catch let error as RPCError {
            // Execution errors go to the model, which can correct itself.
            return Self.failure(error.message)
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    private func searchActions(_ arguments: JSONValue) throws -> JSONValue {
        let query = arguments["query"]?.stringValue?.lowercased()
        let module = arguments["module"]?.stringValue
        let found = try allActions().filter { action in
            !action.security.sensitive && action.module != "actions" && (module == nil || action.module == module)
                && (query == nil || action.id.lowercased().contains(query!) || action.summary.lowercased().contains(query!))
        }
        let list: [JSONValue] = found.prefix(40).map { action in
            ["id": .string(action.id), "summary": .string(action.summary), "kind": .string(action.kind.rawValue), "input": (try? JSONValue.encoding(action.input)) ?? .null]
        }
        return Self.success(["actions": .array(list)])
    }

    /// Structured data plus the same as text for clients that only show text; a picture goes as a picture.
    static func success(_ result: JSONValue) -> JSONValue {
        var structured = result
        var content: [JSONValue] = []
        if case .object(var object) = result, let image = object["imageBase64"], let mime = object["mimeType"] {
            content.append(["type": "image", "data": image, "mimeType": mime])
            object["imageBase64"] = nil
            structured = .object(object)
        }
        content.append(["type": "text", "text": .string(structured.jsonLine())])
        var fields: [String: JSONValue] = ["content": .array(content), "isError": false]
        if case .object = structured { fields["structuredContent"] = structured }
        return .object(fields)
    }

    static func failure(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    // MARK: Resources

    private static let templates: [JSONValue] = [
        ["uriTemplate": "llmd://writer/doc/{id}", "name": "Dokument", "mimeType": "text/markdown"],
        ["uriTemplate": "llmd://presenter/deck/{id}", "name": "Präsentation", "mimeType": "application/json"],
        ["uriTemplate": "llmd://citation/source/{key}", "name": "Quelle", "mimeType": "application/json"],
        ["uriTemplate": "llmd://stories/world/{id}", "name": "Romanwelt", "mimeType": "application/json"],
    ]

    func resources() throws -> [JSONValue] {
        func entries(_ action: String, list: String, prefix: String, key: String, name: String, mime: String) throws -> [JSONValue] {
            (try backend.run(action, args: .object([:]))[list]?.arrayValue ?? []).compactMap { item in
                guard let id = item[key]?.stringValue else { return nil }
                return ["uri": .string(prefix + id), "name": .string(item[name]?.stringValue ?? id), "mimeType": .string(mime)]
            }
        }
        return try entries("writer.doc.list", list: "documents", prefix: "llmd://writer/doc/", key: "id", name: "title", mime: "text/markdown")
            + entries("presenter.deck.list", list: "decks", prefix: "llmd://presenter/deck/", key: "id", name: "title", mime: "application/json")
            + entries("citation.source.list", list: "sources", prefix: "llmd://citation/source/", key: "citekey", name: "title", mime: "application/json")
            + entries("stories.world.list", list: "worlds", prefix: "llmd://stories/world/", key: "id", name: "title", mime: "application/json")
    }

    private func readResource(_ params: JSONValue) throws -> JSONValue {
        guard let uri = params["uri"]?.stringValue else { throw RPCError.invalidParams("„uri“ fehlt.") }
        guard let (kind, id) = Self.parse(uri) else { throw Self.resourceNotFound(uri) }
        do {
            switch kind {
            case "writer/doc":
                let text = try backend.run("writer.doc.read", args: ["doc": .string(id)])["text"]?.stringValue ?? ""
                return ["contents": [["uri": .string(uri), "mimeType": "text/markdown", "text": .string(text)]]]
            case "presenter/deck":
                return Self.jsonContents(uri, try backend.run("presenter.deck.read", args: ["deck": .string(id), "withNotes": true]))
            case "citation/source":
                return Self.jsonContents(uri, try backend.run("citation.source.read", args: ["source": .string(id)]))
            case "stories/world":
                return Self.jsonContents(uri, try backend.run("stories.world.read", args: ["world": .string(id), "depth": "full"]))
            default:
                throw Self.resourceNotFound(uri)
            }
        } catch let error as RPCError where error.code == RPCError.notFoundCode {
            throw Self.resourceNotFound(uri)
        }
    }

    private static func jsonContents(_ uri: String, _ value: JSONValue) -> JSONValue {
        ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(value.jsonLine())]]]
    }

    private static func resourceNotFound(_ uri: String) -> RPCError {
        RPCError(code: RPCError.invalidParamsCode, message: "Resource not found", data: ["uri": .string(uri)])
    }

    /// `llmd://writer/doc/ID` → ("writer/doc", "ID").
    static func parse(_ uri: String) -> (kind: String, id: String)? {
        guard uri.hasPrefix("llmd://") else { return nil }
        let parts = uri.dropFirst(7).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[2].isEmpty else { return nil }
        return ("\(parts[0])/\(parts[1])", parts[2].removingPercentEncoding ?? parts[2])
    }

    // MARK: Prompts

    /// Skills. A foreign skill is a stranger's system prompt: it isn't offered, and asking for it by name goes
    /// through the person in the app.
    func prompts() throws -> [JSONValue] {
        (try backend.run("skill.list", args: .object([:]))["skills"]?.arrayValue ?? []).compactMap { skill in
            guard skill["herkunft"]?.stringValue != "fremd", let name = skill["name"]?.stringValue else { return nil }
            return ["name": .string(name), "description": skill["summary"] ?? ""]
        }
    }

    private func prompt(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("„name“ fehlt.") }
        let skill: JSONValue
        do {
            skill = try backend.run("skill.read", args: ["skill": .string(name)])
        } catch let error as RPCError where error.code == RPCError.notFoundCode {
            throw RPCError.invalidParams("Prompt „\(name)“ gibt es nicht.")
        }
        return [
            "description": skill["summary"] ?? "",
            "messages": [["role": "user", "content": ["type": "text", "text": skill["instructions"] ?? ""]]],
        ]
    }

    // MARK: Subscriptions

    private func listen(id: RPCID, params: JSONValue) -> [RPCMessage] {
        let wanted = params["notifications"] ?? .object([:])
        // Only what this server can tell. Tools and prompts don't change while it runs.
        var agreed: [String: JSONValue] = [:]
        if wanted["resourcesListChanged"] == true { agreed["resourcesListChanged"] = true }
        if let uris = wanted["resourceSubscriptions"] { agreed["resourceSubscriptions"] = uris }
        lock.withLock { subscriptions.append((id, .object(agreed))) }
        let fields: JSONValue = ["_meta": .object([Self.subscriptionKey: Self.json(id)]), "notifications": .object(agreed)]
        return [RPCMessage(id: nil, method: "notifications/subscriptions/acknowledged", params: fields)]
    }

    private func cancel(_ requestID: JSONValue) {
        lock.withLock { subscriptions.removeAll { Self.json($0.id) == requestID } }
    }

    private static func json(_ id: RPCID) -> JSONValue {
        switch id {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }

    /// The notifications one event of the app causes.
    func notifications(for event: ActionEvent) -> [RPCMessage] {
        let open = lock.withLock { subscriptions }
        var messages: [RPCMessage] = []
        for subscription in open {
            let meta: JSONValue = .object([Self.subscriptionKey: Self.json(subscription.id)])
            var uris: [String] = []
            switch event.kind {
            case ActionEvent.documentChanged:
                if let target = event.target { uris = ["llmd://writer/doc/\(target)", "llmd://presenter/deck/\(target)"] }
            case "world.changed":
                if let target = event.target { uris = ["llmd://stories/world/\(target)"] }
            default:
                break
            }
            let watched = subscription.filter["resourceSubscriptions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for uri in uris where watched.contains(uri) {
                messages.append(RPCMessage(id: nil, method: "notifications/resources/updated", params: ["_meta": meta, "uri": .string(uri)]))
            }
            if subscription.filter["resourcesListChanged"] == true, event.kind == ActionEvent.actionExecuted,
               let action = event.action, action.hasSuffix(".create") || action.hasSuffix(".delete") || action.hasSuffix(".duplicate") || action.hasSuffix(".import") {
                messages.append(RPCMessage(id: nil, method: "notifications/resources/list_changed", params: ["_meta": meta]))
            }
        }
        return messages
    }

    /// At the end of the session: the graceful end of every open stream.
    func closingMessages() -> [RPCMessage] {
        lock.withLock { subscriptions }.map { subscription in
            RPCMessage(id: subscription.id, result: ["resultType": "complete", "_meta": .object([Self.subscriptionKey: Self.json(subscription.id)])])
        }
    }
}
