import Foundation
import LLMDProtocol

/// The tools of one model step, cut for a small model (Qwen 3.5 9B with 16 to 32K of context): only what the step
/// chose, schemas without the rarely used parameters, and one tool to say the step is done. The rules stay in the
/// registry; nothing here decides what is allowed.
@MainActor
struct AgentToolbox {
    static let finishName = "schritt_fertig"
    static let webGroup = "web"
    /// Groups a step can choose. Private data (memory, persona files) is not among them: no one is there to watch.
    static var groups: [(id: String, label: String)] {
        ChatToolGroups.labels.filter { $0.id != "chat.private" } + [(webGroup, "Web und Wikipedia: suchen und Seiten lesen")]
    }
    static let webTools = [WebTools.searchName, WebTools.openPageName, WebTools.wikiSearchName, WebTools.wikiArticleName]
    /// Calls per round that run; a small model asked for six at once sometimes and lost track of them.
    static let maxCallsPerRound = 3
    static let resultLimit = 4_000

    let actions: [ActionDescriptor]
    let web: WebTools.Sources

    /// `selection` holds group ids and single action ids. Actions of AgentSteps itself are never tools: an agent
    /// starting agents would be a loop no one asked for.
    init(registry: ActionRegistry, selection: [String]) {
        var wanted: Set<String> = []
        var web: WebTools.Sources = []
        for entry in selection {
            if entry == Self.webGroup {
                web = [.web, .wikipedia]
            } else if entry != "chat.private", let members = ChatToolGroups.members[entry] {
                wanted.formUnion(members)
            } else if registry.descriptor(entry) != nil {
                wanted.insert(entry)
            }
        }
        actions = registry.descriptors.filter { wanted.contains($0.id) && $0.module != "agents" && !$0.security.sensitive }
        self.web = web
    }

    var isEmpty: Bool { actions.isEmpty && web.isEmpty }

    static func toolName(_ actionID: String) -> String { ChatActionTools.toolName(actionID) }

    func action(forTool name: String) -> ActionDescriptor? {
        actions.first { Self.toolName($0.id) == name }
    }

    var definitions: [ToolDefinition] {
        var tools = actions.map { action in
            ToolDefinition(name: Self.toolName(action.id), description: action.summary, schema: (try? JSONValue.encoding(Self.compact(action.input))) ?? .object([:]))
        }
        tools += WebTools.definitions(for: web)
        tools.append(ToolDefinition(
            name: Self.finishName,
            description: "Beendet diesen Schritt. Rufe es auf, sobald der Schritt erledigt ist oder sich nicht erledigen lässt.",
            schema: .object([
                "type": "object",
                "properties": .object([
                    "ergebnis": .object(["type": "string", "description": "Alles, was spätere Schritte von diesem wissen müssen: die gefundenen oder angelegten Dinge selbst (Namen, Titel, IDs, Listen), nicht nur ihre Anzahl. Oder warum es nicht ging."]),
                    "erfolg": .object(["type": "boolean", "description": "true, wenn der Schritt erledigt ist; false, wenn nicht."]),
                ]),
                "required": .array(["ergebnis"]),
            ])
        ))
        return tools
    }

    /// Every parameter costs context with every round; these are rarely what a step needs.
    static let droppedParameters: Set<String> = ["range", "ifVersion"]

    static func compact(_ schema: JSONSchema) -> JSONSchema {
        var schema = schema
        schema.properties = schema.properties?.filter { !droppedParameters.contains($0.key) }
        schema.required = schema.required?.filter { !droppedParameters.contains($0) }
        return schema
    }

    /// What the model reads about the parameters when a call didn't fit, so it can try again right.
    static func parameterHint(_ action: ActionDescriptor) -> String {
        let schema = compact(action.input)
        let required = Set(schema.required ?? [])
        let parts = (schema.properties ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            let type = value.type ?? "Wert"
            return "\(key) (\(type)\(required.contains(key) ? ", Pflicht" : ""))"
        }
        return parts.isEmpty ? "keine Parameter" : parts.joined(separator: ", ")
    }

    /// The system prompt of a model step: short rules in plain German, one per line, because a 9B model follows a
    /// numbered list better than prose.
    func systemPrompt(now: Date = Date()) -> String {
        var lines = [
            "Du bist ein Agent in der App LLM Designer. Du erledigst genau einen Schritt eines größeren Auftrags.",
            "Heute ist \(now.formatted(date: .complete, time: .omitted)).",
            "Regeln:",
            "1. Handle nur mit den Werkzeugen. Rufe pro Antwort höchstens \(Self.maxCallsPerRound) Werkzeuge auf.",
            "2. Lies zuerst, was du ändern willst. Verwende IDs aus den Ergebnissen, nicht geratene.",
            "3. Mach nur, was dein Schritt verlangt. Spätere Schritte erledigen den Rest.",
            "4. Bist du fertig, rufe \(Self.finishName) auf. Spätere Schritte sehen nur dieses Ergebnis: Schreibe die Dinge selbst hinein (Namen, Titel, IDs, Listen), nicht nur, wie viele es sind.",
            "5. Geht es nicht, rufe \(Self.finishName) mit erfolg=false und dem Grund auf. Erfinde keine Ergebnisse.",
            "6. Wird ein Aufruf abgelehnt, versuche es nicht auf anderem Weg.",
            "7. Schreibe Inhalte auf Deutsch, außer der Auftrag verlangt etwas anderes.",
        ]
        if !web.isEmpty {
            lines.append("8. Öffne nur Adressen aus Suchergebnissen oder aus dem Auftrag.")
            lines.append(ForeignFrame.hint)
        }
        return lines.joined(separator: "\n")
    }
}

/// Tool calls a model wrote into its text instead of the tool field: LM Studio passes Qwen's markup through when its
/// parser doesn't match. Without this, a 9B model's step "ended" with a call nobody ran.
enum AgentCallParser {
    static func calls(in text: String) -> [ToolCall] {
        var calls: [ToolCall] = []
        for block in blocks(in: text) {
            if let call = jsonCall(block, index: calls.count) ?? xmlCall(block, index: calls.count) { calls.append(call) }
        }
        return calls
    }

    /// The pieces between `<tool_call>` and `</tool_call>`; a missing end counts as the end of the text.
    private static func blocks(in text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "<tool_call>") {
            let after = rest[start.upperBound...]
            if let end = after.range(of: "</tool_call>") {
                result.append(String(after[..<end.lowerBound]))
                rest = after[end.upperBound...]
            } else {
                result.append(String(after))
                break
            }
        }
        // `<function=…>` without the outer tags.
        if result.isEmpty, text.contains("<function=") { result.append(text) }
        return result
    }

    /// `{"name": "…", "arguments": {…}}`
    private static func jsonCall(_ block: String, index: Int) -> ToolCall? {
        guard let start = block.firstIndex(of: "{"), let end = block.lastIndex(of: "}"), start < end,
              let value = try? JSONValue.parse(String(block[start...end])), let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        let arguments: String
        switch value["arguments"] ?? value["parameters"] {
        case .string(let text)?: arguments = text
        case let object?: arguments = object.jsonLine()
        case nil: arguments = "{}"
        }
        return ToolCall(id: "text_call_\(index)", function: .init(name: name, arguments: arguments))
    }

    /// `<function=name><parameter=key>value</parameter>…</function>`
    private static func xmlCall(_ block: String, index: Int) -> ToolCall? {
        guard let nameStart = block.range(of: "<function=") else { return nil }
        let afterName = block[nameStart.upperBound...]
        guard let close = afterName.firstIndex(of: ">") else { return nil }
        let name = afterName[..<close].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var arguments: [String: JSONValue] = [:]
        var rest = afterName[afterName.index(after: close)...]
        while let open = rest.range(of: "<parameter=") {
            let tail = rest[open.upperBound...]
            guard let keyEnd = tail.firstIndex(of: ">") else { break }
            let key = tail[..<keyEnd].trimmingCharacters(in: .whitespaces)
            let valueStart = tail.index(after: keyEnd)
            let valueEnd = tail[valueStart...].range(of: "</parameter>")
            let raw = String(tail[valueStart..<(valueEnd?.lowerBound ?? tail.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Numbers, booleans, lists and quoted text come as their JSON; everything else is plain text.
            arguments[key] = (try? JSONValue.parse(raw)) ?? .string(raw)
            guard let valueEnd else { break }
            rest = tail[valueEnd.upperBound...]
        }
        return ToolCall(id: "text_call_\(index)", function: .init(name: name, arguments: JSONValue.object(arguments).jsonLine()))
    }
}

/// `{{schritt2.id}}`, `{{vorher.title}}`, `{{ziel}}`, `{{heute}}` in an action step's parameters. A string that is
/// only a placeholder takes the value as it is (a number stays a number).
enum AgentPlaceholders {
    static func resolve(_ value: JSONValue, steps: [AgentRunStep], current: Int, goal: String, now: Date = Date()) -> JSONValue {
        switch value {
        case .string(let text):
            return resolve(text, steps: steps, current: current, goal: goal, now: now)
        case .array(let items):
            return .array(items.map { resolve($0, steps: steps, current: current, goal: goal, now: now) })
        case .object(let object):
            return .object(object.mapValues { resolve($0, steps: steps, current: current, goal: goal, now: now) })
        default:
            return value
        }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([a-zA-ZäöüÄÖÜ]+)(\d*)(?:\.([a-zA-Z_]+))?\s*\}\}"#)

    private static func resolve(_ text: String, steps: [AgentRunStep], current: Int, goal: String, now: Date) -> JSONValue {
        let whole = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: whole)
        guard !matches.isEmpty else { return .string(text) }
        func value(of match: NSTextCheckingResult) -> JSONValue? {
            let name = Range(match.range(at: 1), in: text).map { String(text[$0]).lowercased() } ?? ""
            let number = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
            let field = Range(match.range(at: 3), in: text).map { String(text[$0]) }
            switch name {
            case "ziel": return .string(goal)
            case "heute": return .string(now.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()))
            case "jetzt": return .string(now.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute()))
            case "datum": return .string(ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate]))
            case "schritt", "vorher":
                let index = name == "vorher" ? current - 1 : (number ?? 0) - 1
                guard steps.indices.contains(index), index < current else { return nil }
                let step = steps[index]
                guard let field else { return step.summary.map(JSONValue.string) }
                if field == "satz" { return step.summary.map(JSONValue.string) }
                return step.output?[field]
            default:
                return nil
            }
        }
        if matches.count == 1, matches[0].range == whole, let found = value(of: matches[0]) { return found }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), let found = value(of: match) else { continue }
            let replacement = found.stringValue ?? (found == .null ? "" : found.jsonLine())
            result.replaceSubrange(range, with: replacement)
        }
        return .string(result)
    }

    /// The small values of a result (ids, titles, counts), for later placeholders and the step's record. Long texts
    /// stay out: they may be the person's writing, and the record is no copy of it.
    static func smallValues(of result: JSONValue) -> [String: JSONValue] {
        guard let object = result.objectValue else { return [:] }
        return object.filter { _, value in
            switch value {
            case .string(let text): text.count <= 200
            case .int, .double, .bool: true
            default: false
            }
        }
    }
}

/// Results as sentences, for the log and for the next step.
enum AgentWords {
    static func sentence(for action: ActionDescriptor, result: JSONValue) -> String {
        let values = AgentPlaceholders.smallValues(of: result)
        let named = ["title", "titel", "name"].compactMap { values[$0]?.stringValue }.first
        var sentence = action.summary
        if let named { sentence += ": „\(named)“" }
        if let id = values["id"]?.stringValue { sentence += " (ID \(id))" }
        if let message = values["message"]?.stringValue { sentence += ". " + message }
        return sentence
    }

    /// What a run made, from a call's result: an id with a create-like action.
    static func result(of action: ActionDescriptor, args: JSONValue, output: JSONValue) -> AgentResult? {
        guard let id = output["id"]?.stringValue, action.kind != .read else { return nil }
        let creates = [".create", ".add", ".new", ".import", ".fromDocument", ".toDocument", "createDeck"].contains { action.id.contains($0) }
        guard creates else { return nil }
        let title = output["title"]?.stringValue ?? args["title"]?.stringValue ?? args["name"]?.stringValue
        return AgentResult(kind: action.module, id: id, title: title)
    }

    static func excerpt(_ text: String, limit: Int = 180) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + " …" : flat
    }
}

/// Parameters as a small model writes them, fitted to the action's schema before the registry checks them: Qwen 9B
/// sent `"general": "true"` and could not make sense of "muss true oder false sein" (2026-11-15). Only types are
/// changed and unknown keys dropped; what a value means stays, and the registry still checks everything.
enum AgentArguments {
    static func coerce(_ args: JSONValue, schema: JSONSchema) -> (args: JSONValue, dropped: [String]) {
        guard case .object(let object) = args, let properties = schema.properties else { return (args, []) }
        var result: [String: JSONValue] = [:]
        var dropped: [String] = []
        for (key, value) in object {
            guard let property = properties[key] else {
                dropped.append(key)
                continue
            }
            if value == .null, !(schema.required ?? []).contains(key) { continue }
            result[key] = coerce(value, to: property)
        }
        return (.object(result), dropped.sorted())
    }

    static func coerce(_ value: JSONValue, to schema: JSONSchema) -> JSONValue {
        switch (schema.type, value) {
        case ("boolean", .string(let text)):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "ja", "yes", "1": return .bool(true)
            case "false", "nein", "no", "0": return .bool(false)
            default: return value
            }
        case ("integer", .string(let text)):
            return Int(text.trimmingCharacters(in: .whitespaces)).map(JSONValue.int) ?? value
        case ("integer", .double(let number)) where number == number.rounded():
            return .int(Int(number))
        case ("number", .string(let text)):
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).map(JSONValue.double) ?? value
        case ("string", .int(let number)):
            return .string(String(number))
        case ("string", .double(let number)):
            return .string(number == number.rounded() ? String(Int(number)) : String(number))
        case ("string", .bool(let flag)):
            return .string(flag ? "true" : "false")
        case ("array", .string(let text)):
            if let parsed = try? JSONValue.parse(text), case .array = parsed { return coerce(parsed, to: schema) }
            return .array([coerce(value, to: schema.items ?? .string())])
        case ("array", .array(let items)):
            return .array(items.map { coerce($0, to: schema.items ?? JSONSchema()) })
        case ("object", .string(let text)):
            if let parsed = try? JSONValue.parse(text), case .object = parsed { return parsed }
            return value
        default:
            return value
        }
    }
}
