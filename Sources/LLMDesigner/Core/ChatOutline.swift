import Foundation

/// A place in the chat: a message, optionally one of its heading blocks.
struct OutlineTarget: Codable, Hashable, Sendable {
    var messageID: UUID
    var block: Int?

    /// Identifier of the matching view in the message list, used for scrolling.
    var viewID: String { Self.viewID(messageID, block) }

    static func viewID(_ messageID: UUID, _ block: Int?) -> String {
        block.map { "\(messageID.uuidString)#\($0)" } ?? messageID.uuidString
    }
}

struct OutlineItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var target: OutlineTarget
}

struct OutlineSection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var target: OutlineTarget
    var items: [OutlineItem]
}

/// LLM-generated table of contents of a chat.
struct ChatOutline: Codable, Hashable, Sendable {
    /// Short title for the whole chat, suggested by the model.
    var title: String?
    var summary: String
    var sections: [OutlineSection]
    /// Last message the outline covers; anything after it makes the outline outdated.
    var lastMessageID: UUID?
    var generatedAt: Date
    var model: String?
}

/// Builds the request for the model and turns its JSON answer into a `ChatOutline`.
enum OutlineBuilder {
    static let minimumAnswers = 3
    static let minimumCharacters = 6_000
    private static let transcriptBudget = 12_000

    static func isLongEnough(_ chat: Chat) -> Bool {
        let answers = chat.messages.filter { $0.role == .assistant && !$0.content.isEmpty }
        let characters = chat.messages.reduce(0) { $0 + $1.content.count }
        return answers.count >= minimumAnswers || (answers.count >= 1 && characters >= minimumCharacters)
    }

    static func isOutdated(_ chat: Chat) -> Bool {
        guard let outline = chat.outline else { return true }
        return outline.lastMessageID != chat.messages.last(where: { !$0.content.isEmpty })?.id
    }

    /// Blocks of an answer that can be jumped to: headings and lines that are bold as a whole.
    static func anchors(in content: String) -> [(block: Int, title: String)] {
        MarkdownParser.parse(content).enumerated().compactMap { index, block in
            switch block {
            case .heading(_, let text):
                return (index, cleanTitle(text))
            case .paragraph(let text):
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.contains("\n"), line.count < 140, line.hasPrefix("**"),
                      line.hasSuffix("**") || line.hasSuffix("**:") else { return nil }
                return (index, cleanTitle(line))
            default:
                return nil
            }
        }
    }

    // MARK: Request

    static let schemaName = "inhaltsverzeichnis"

    static let schema: [String: Any] = {
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["titel": ["type": "string"], "ziel": ["type": "string"]],
            "required": ["titel", "ziel"],
        ]
        let section: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "titel": ["type": "string"],
                "ziel": ["type": "string"],
                "unterpunkte": ["type": "array", "items": item],
            ],
            "required": ["titel", "ziel", "unterpunkte"],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "properties": [
                "chattitel": ["type": "string"],
                "zusammenfassung": ["type": "string"],
                "themen": ["type": "array", "items": section],
            ],
            "required": ["chattitel", "zusammenfassung", "themen"],
        ]
    }()

    static func requestMessages(for chat: Chat) -> [ChatPayloadMessage] {
        let system = """
        Du erstellst ein Inhaltsverzeichnis für einen Chatverlauf zwischen einer Person („Du“) und einem Assistenten.
        - Gliedere den Verlauf chronologisch in 2 bis 7 Hauptthemen mit kurzen, aussagekräftigen Titeln (höchstens 6 Wörter).
        - Jedes Thema hat 0 bis 6 Unterpunkte für die wichtigsten Teilaspekte.
        - „ziel“ ist immer genau ein Verweis aus den eckigen Klammern im Verlauf, z. B. "3" für Nachricht 3 oder "4.5" für einen Abschnitt in Nachricht 4. Bevorzuge Abschnitte, wenn es passende gibt.
        - Ein Thema verweist auf die Nachricht, in der es beginnt, meist die Frage.
        - Unterpunkte liegen im Verlauf nach dem Beginn ihres Themas und vor dem nächsten Thema.
        - Titel enthalten keine Verweise oder Nummern in Klammern.
        - Reiner Smalltalk wie Begrüßung oder Dank wird kein eigenes Thema.
        - „chattitel“: prägnanter Titel für den ganzen Chat mit 2 bis 6 Wörtern, der den Inhalt beschreibt (keine Anführungszeichen).
        - „zusammenfassung“: ein Satz, worum es im Chat geht.
        - Schreibe auf Deutsch.
        """
        // Deliberately no previous outline in the prompt: small models copy its mistakes into every update.
        return [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: transcript(for: chat)),
        ]
    }

    /// Condensed chat: numbered messages, shortened to fit the model's context, plus the jump targets of each answer.
    private static func transcript(for chat: Chat) -> String {
        let count = max(chat.messages.filter { !$0.content.isEmpty }.count, 1)
        let perMessage = max(160, transcriptBudget / count)
        var lines: [String] = []
        for (index, message) in chat.messages.enumerated() where !message.content.isEmpty && message.role != .system {
            let number = index + 1
            let speaker = message.role == .user ? "Du" : "Assistent"
            lines.append("[\(number)] \(speaker): \(excerpt(message.content, limit: perMessage))")
            if message.role == .assistant {
                let anchors = anchors(in: message.content).prefix(16)
                if !anchors.isEmpty {
                    lines.append("    Abschnitte: " + anchors.map { "[\(number).\($0.block)] \($0.title.prefix(80))" }.joined(separator: " | "))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func excerpt(_ content: String, limit: Int) -> String {
        let withoutCode = content.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " [Code] ", options: .regularExpression)
        let collapsed = withoutCode.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + " …" : collapsed
    }

    // MARK: Response

    private struct Response: Decodable {
        struct Topic: Decodable {
            let titel: String
            let ziel: String
            let unterpunkte: [Point]
        }
        struct Point: Decodable {
            let titel: String
            let ziel: String
        }
        let chattitel: String?
        let zusammenfassung: String
        let themen: [Topic]
    }

    /// Parses the model's answer. References are resolved against `chat`, the snapshot the request was built from.
    static func parse(_ answer: String, chat: Chat, model: String?) throws -> ChatOutline {
        var json = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}") {
            json = String(json[start...end])
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))

        // Small models mix up order and grouping. A topic covers the chat from its start to the next topic,
        // so topics are sorted by position and every point goes to the topic whose range contains it.
        func position(_ target: OutlineTarget) -> (Int, Int) {
            (chat.messages.firstIndex { $0.id == target.messageID } ?? .max, target.block ?? -1)
        }
        var points: [OutlineItem] = []
        var drafts: [(section: OutlineSection, points: [OutlineItem])] = response.themen.compactMap { topic in
            let topicPoints = topic.unterpunkte.compactMap { point in
                resolve(point.ziel, in: chat).map { OutlineItem(title: cleanTitle(point.titel), target: $0) }
            }
            guard let target = resolve(topic.ziel, in: chat) ?? topicPoints.first?.target else { return nil }
            return (OutlineSection(title: cleanTitle(topic.titel), target: target, items: []), topicPoints)
        }
        .sorted { position($0.section.target) < position($1.section.target) }

        // Two topics starting at the same place would leave the first one empty: the later one starts at its first own point.
        for index in drafts.indices.dropFirst() where position(drafts[index].section.target) <= position(drafts[index - 1].section.target) {
            let previousStart = position(drafts[index - 1].section.target)
            if let start = drafts[index].points.filter({ position($0.target) > previousStart }).min(by: { position($0.target) < position($1.target) }) {
                drafts[index].section.target = start.target
                drafts[index].points.removeAll { $0.target == start.target }
            }
        }
        drafts.forEach { points += $0.points }
        var sections = drafts.map(\.section).sorted { position($0.target) < position($1.target) }

        var seen = Set<String>()
        for point in points.sorted(by: { position($0.target) < position($1.target) }) {
            guard !sections.isEmpty, seen.insert("\(point.target.viewID)|\(point.title)").inserted else { continue }
            let owner = sections.lastIndex { position($0.target) <= position(point.target) } ?? 0
            sections[owner].items.append(point)
        }
        guard !sections.isEmpty else { throw LLMError.server("Das Modell hat kein verwertbares Inhaltsverzeichnis geliefert.") }

        let title = response.chattitel.map { raw in
            String(cleanTitle(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”‚‘’«»").union(.whitespaces)).prefix(70))
        }
        return ChatOutline(
            title: title?.isEmpty == false ? title : nil,
            summary: repairLaTeXEscapes(response.zusammenfassung).trimmingCharacters(in: .whitespacesAndNewlines),
            sections: sections,
            lastMessageID: chat.messages.last(where: { !$0.content.isEmpty })?.id,
            generatedAt: Date(),
            model: model
        )
    }

    /// Models often write LaTeX like `\\neq` into JSON unescaped, which JSON reads as a line break plus "eq".
    /// Inside text with formulas such control characters can only be broken commands, so turn them back.
    private static func repairLaTeXEscapes(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\(") else { return text }
        let repairs: [Character: String] = ["\n": "\\n", "\t": "\\t", "\r": "\\r", "\u{08}": "\\b", "\u{0C}": "\\f"]
        return String(text.flatMap { repairs[$0] ?? String($0) })
    }

    /// Accepts "4", "4.5", "[4.5]" or "[4.1] / [4.4]" (first reference wins).
    private static func resolve(_ reference: String, in chat: Chat) -> OutlineTarget? {
        guard let digitsStart = reference.firstIndex(where: \.isNumber) else { return nil }
        let rest = reference[digitsStart...]
        let numberText = rest.prefix(while: \.isNumber)
        let afterNumber = rest.dropFirst(numberText.count)
        let blockText = afterNumber.first == "." ? afterNumber.dropFirst().prefix(while: \.isNumber) : ""

        guard let number = Int(numberText), chat.messages.indices.contains(number - 1) else { return nil }
        let message = chat.messages[number - 1]
        guard !message.content.isEmpty else { return nil }
        var block = Int(blockText)
        if let candidate = block, !anchors(in: message.content).contains(where: { $0.block == candidate }) {
            block = nil
        }
        return OutlineTarget(messageID: message.id, block: block)
    }

    private static func cleanTitle(_ text: String) -> String {
        var title = repairLaTeXEscapes(text)
            .replacingOccurrences(of: "**", with: "")
            // References the model copied into the title, e.g. "[4.1 - 4.49]" or "(Nachricht 3)".
            .replacingOccurrences(of: #"\s*[\[(]\s*(Nachricht\s*)?\d+(\.\d+)?(\s*[-–,/]\s*\d+(\.\d+)?)*\s*[\])]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix(":") { title.removeLast() }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
