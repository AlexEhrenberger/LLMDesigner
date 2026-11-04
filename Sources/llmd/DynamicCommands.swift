import Foundation
import LLMDProtocol

/// Turns command lines into action calls, using nothing but the schemas: `llmd writer format bold --doc X` finds
/// `writer.format.bold` and checks `--doc` against its parameters.
enum DynamicCommand {
    /// `doNotTrack` → `do-not-track`.
    static func kebab(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `do-not-track` → `doNotTrack`.
    static func camel(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard let first = parts.first else { return name }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// The action the leading words name: the longest match wins, so `writer doc` can't shadow `writer doc read`.
    /// Words are compared in kebab case: `insert-markdown` is `insertMarkdown`.
    static func resolve(words: [String], actions: [ActionDescriptor]) -> (ActionDescriptor, [String])? {
        let leading = words.prefix { !$0.hasPrefix("-") }
        var best: (ActionDescriptor, Int)?
        for action in actions {
            let parts = action.id.split(separator: ".").map { kebab(String($0)) }
            guard parts.count <= leading.count, Array(leading.prefix(parts.count)) == parts else { continue }
            if parts.count > (best?.1 ?? 0) { best = (action, parts.count) }
        }
        guard let best else { return nil }
        return (best.0, Array(words.dropFirst(best.1)))
    }

    /// Options and the words between them. `schema` types the values; without it they stay text.
    static func options(_ arguments: [String], schema: JSONSchema?) throws -> ([String: JSONValue], [String]) {
        var options: [String: JSONValue] = [:]
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positional.append(argument)
                index += 1
                continue
            }
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if name == "args" {
                index += 1
                let text = value ?? (index < arguments.count ? arguments[index] : "")
                guard let object = (try? JSONValue.parse(text))?.objectValue else { throw UsageError(message: "--args braucht ein JSON-Objekt.") }
                options.merge(object) { _, new in new }
                index += 1
                continue
            }
            let key = camel(name)
            if let schema, schema.properties?[key] == nil {
                let known = (schema.properties ?? [:]).keys.sorted().map { "--" + kebab($0) }.joined(separator: ", ")
                throw UsageError(message: "Unbekannte Option --\(name). Möglich: \(known.isEmpty ? "keine" : known).")
            }
            let property = schema?.properties?[key]
            if property?.type == "boolean", value == nil {
                // `--flag` alone means true; `--flag false` stays possible.
                if index + 1 < arguments.count, arguments[index + 1] == "true" || arguments[index + 1] == "false" {
                    index += 1
                    options[key] = .bool(arguments[index] == "true")
                } else {
                    options[key] = .bool(true)
                }
                index += 1
                continue
            }
            if value == nil {
                index += 1
                guard index < arguments.count else { throw UsageError(message: "--\(name) braucht einen Wert.") }
                value = arguments[index]
            }
            options[key] = try typed(value ?? "", schema: property, option: name)
            index += 1
        }
        return (options, positional)
    }

    static func typed(_ text: String, schema: JSONSchema?, option: String) throws -> JSONValue {
        switch schema?.type {
        case "integer":
            guard let number = Int(text) else { throw UsageError(message: "--\(option) braucht eine ganze Zahl.") }
            return .int(number)
        case "number":
            guard let number = Double(text) else { throw UsageError(message: "--\(option) braucht eine Zahl.") }
            return .double(number)
        case "boolean":
            guard text == "true" || text == "false" else { throw UsageError(message: "--\(option) braucht true oder false.") }
            return .bool(text == "true")
        case "array", "object":
            guard let value = try? JSONValue.parse(text) else { throw UsageError(message: "--\(option) braucht JSON.") }
            return value
        default:
            return .string(text)
        }
    }

    /// The arguments for an action: options by name, then the remaining words fill the required parameters in order.
    /// With `--stdin` the standard input goes into the longest text parameter (or the one `--stdin-to` names).
    static func arguments(_ words: [String], descriptor: ActionDescriptor, globals: LLMDCommandLine.Globals,
                          readInput: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }) throws -> JSONValue {
        var (options, positional) = try options(words, schema: descriptor.input)
        if globals.stdin {
            let target = try globals.stdinTo.map(camel) ?? stdinParameter(of: descriptor)
            guard descriptor.input.properties?[target] != nil else { throw UsageError(message: "„\(descriptor.id)“ hat keinen Parameter „\(target)“.") }
            options[target] = .string(readInput())
        }
        for name in descriptor.input.required ?? [] where options[name] == nil {
            guard !positional.isEmpty else { break }
            options[name] = try typed(positional.removeFirst(), schema: descriptor.input.properties?[name], option: kebab(name))
        }
        if let extra = positional.first {
            throw UsageError(message: "Unerwartetes Argument „\(extra)“. `llmd describe \(descriptor.id)` zeigt die Parameter.")
        }
        return .object(options)
    }

    /// Where standard input goes by default: the parameter that holds the body of a text.
    static func stdinParameter(of descriptor: ActionDescriptor) throws -> String {
        let preferred = ["markdown", "text", "code", "instruction", "content"]
        guard let name = preferred.first(where: { descriptor.input.properties?[$0] != nil }) else {
            throw UsageError(message: "„\(descriptor.id)“ nimmt keinen Text von der Standardeingabe. Mit --stdin-to NAME wählen.")
        }
        return name
    }

    static func batchSteps(from text: String) throws -> [JSONValue] {
        var steps: [JSONValue] = []
        for (number, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let step = try? JSONValue.parse(String(line)), step["id"]?.stringValue != nil else {
                throw UsageError(message: "Zeile \(number + 1): Erwartet wird {\"id\": \"…\", \"args\": {…}}.")
            }
            steps.append(step)
        }
        guard !steps.isEmpty else { throw UsageError(message: "Der Stapel ist leer.") }
        return steps
    }
}

/// The action list, kept per app version so that each `llmd writer …` doesn't transfer the whole catalog again.
enum SchemaCache {
    static func descriptors(client: LLMDClient) throws -> [ActionDescriptor] {
        let status = try client.run("app.status")
        // Count in the key: a debug build has no version of its own but may have other actions.
        let version = (status["version"]?.stringValue ?? "dev") + "-" + (status["build"]?.stringValue ?? "0") + "-" + (status["actions"]?.jsonLine() ?? "0")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LLMDesigner", isDirectory: true)
        let file = caches.appendingPathComponent("llmd-actions-\(version).json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([ActionDescriptor].self, from: data) {
            return cached
        }
        guard let list = try client.run("actions.list")["actions"] else { return [] }
        let actions = try list.decoded(as: [ActionDescriptor].self)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try? JSONEncoder().encode(actions).write(to: file, options: .atomic)
        return actions
    }

    static func descriptor(_ id: String, client: LLMDClient) throws -> ActionDescriptor {
        guard let found = try descriptors(client: client).first(where: { $0.id == id }) else { throw RPCError.methodNotFound(id) }
        return found
    }
}
