import Foundation

/// The id of a request; JSON-RPC allows numbers and strings.
public enum RPCID: Hashable, Sendable, Codable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .int(value) } else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// One line on the socket. Without an id it is a notification (the server sends events this way).
public struct RPCMessage: Codable, Sendable, Hashable {
    public var jsonrpc = "2.0"
    public var id: RPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(id: RPCID?, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: RPCID?, error: RPCError) {
        self.id = id
        self.error = error
    }

    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

public struct RPCError: Error, Codable, Sendable, Hashable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    // JSON-RPC's own.
    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603
    // Our own.
    public static let unauthorizedCode = -32001
    /// The safety rule or the person said no.
    public static let deniedCode = -32010
    public static let notFoundCode = -32020
    public static let ambiguousCode = -32021
    public static let invalidTargetCode = -32022
    public static let versionConflictCode = -32030
    public static let unavailableCode = -32040

    public static func methodNotFound(_ name: String) -> RPCError {
        RPCError(code: methodNotFoundCode, message: "Unbekannte Action „\(name)“. `llmd actions` listet alle.")
    }
    public static func invalidParams(_ message: String) -> RPCError { RPCError(code: invalidParamsCode, message: message) }
    public static func denied(_ message: String) -> RPCError { RPCError(code: deniedCode, message: message) }
    public static func notFound(_ message: String) -> RPCError { RPCError(code: notFoundCode, message: message) }
    public static func ambiguous(_ message: String, candidates: [String] = []) -> RPCError {
        RPCError(code: ambiguousCode, message: message, data: candidates.isEmpty ? nil : .array(candidates.map { .string($0) }))
    }
    public static func invalidTarget(_ message: String) -> RPCError { RPCError(code: invalidTargetCode, message: message) }
    public static func versionConflict(current: String) -> RPCError {
        RPCError(code: versionConflictCode, message: "Dokument wurde inzwischen geändert.", data: .object(["version": .string(current)]))
    }
    public static func unavailable(_ message: String) -> RPCError { RPCError(code: unavailableCode, message: message) }
    public static func `internal`(_ message: String) -> RPCError { RPCError(code: internalErrorCode, message: message) }
}

/// The methods the socket knows besides the actions themselves.
public enum RPCMethod {
    /// First message on every connection: `{token, channel: "cli"|"mcp"}`.
    public static let auth = "auth"
    /// `{id, args?, run?}`.
    public static let run = "action.run"
    /// `{steps: [{id, args?}], run?}`: one undo group, stops at the first error and takes everything back.
    public static let batch = "action.batch"
    /// Events arrive as notifications with this method until the connection closes.
    public static let subscribe = "events.subscribe"
    public static let event = "event"
}

/// What `events.subscribe` delivers.
public struct ActionEvent: Codable, Sendable, Hashable {
    public var kind: String
    public var action: String?
    public var channel: String?
    public var run: String?
    public var target: String?
    public var time: Date

    public init(kind: String, action: String? = nil, channel: String? = nil, run: String? = nil, target: String? = nil, time: Date = Date()) {
        self.kind = kind
        self.action = action
        self.channel = channel
        self.run = run
        self.target = target
        self.time = time
    }

    public static let documentChanged = "document.changed"
    public static let actionExecuted = "action.executed"
}
