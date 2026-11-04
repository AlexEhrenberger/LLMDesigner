import Foundation
import LLMDProtocol

/// Exit codes of `llmd`; scripts decide by them (`docs/plan/CLI-Konzept.md`, 6).
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let unreachable: Int32 = 3
    static let denied: Int32 = 4
    static let notFound: Int32 = 5
    static let conflict: Int32 = 6

    static func of(_ error: Error) -> Int32 {
        if error is LLMDClient.Failure { return unreachable }
        if error is UsageError { return usage }
        guard let error = error as? RPCError else { return failure }
        switch error.code {
        case RPCError.methodNotFoundCode, RPCError.invalidParamsCode: return usage
        case RPCError.deniedCode, RPCError.unauthorizedCode: return denied
        case RPCError.notFoundCode, RPCError.ambiguousCode, RPCError.invalidTargetCode: return notFound
        case RPCError.versionConflictCode: return conflict
        default: return failure
        }
    }
}

struct UsageError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Output {
    /// A result for people: text fields as they are, flat objects line by line, everything else as JSON.
    static func human(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return text
        case .bool, .int, .double: return value.jsonLine()
        case .array(let items):
            return items.map { item in
                if case .object = item { return summaryLine(item) }
                return human(item)
            }.joined(separator: "\n")
        case .object(let object):
            // A text result is the point of the call: print it after its metadata.
            if let text = object["text"]?.stringValue {
                let rest = object.filter { $0.key != "text" }
                return (rest.isEmpty ? "" : lines(rest) + "\n\n") + text
            }
            // A single list is the result: print the list.
            if object.count <= 2, let (_, list) = object.first(where: { if case .array = $0.value { return true } else { return false } }) {
                return human(list)
            }
            return lines(object)
        }
    }

    private static func lines(_ object: [String: JSONValue]) -> String {
        object.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            // A picture in Base64 is of no use on the terminal.
            case .string(let text) where text.count > 2_000 && key.lowercased().contains("base64"): "\(key): (\(text.count) Zeichen; --json zeigt alles)"
            case .string(let text): "\(key): \(text)"
            case .array, .object: "\(key): \(value.jsonLine())"
            default: "\(key): \(value.jsonLine())"
            }
        }.joined(separator: "\n")
    }

    private static func summaryLine(_ item: JSONValue) -> String {
        guard let object = item.objectValue else { return human(item) }
        let leading = ["id", "key", "index", "title", "name", "summary", "text"].compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return value.stringValue ?? value.jsonLine()
        }
        return leading.isEmpty ? item.jsonLine() : leading.joined(separator: "\t")
    }
}
