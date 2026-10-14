import Foundation

/// Asks the model for follow-up questions the user might want to ask next (shown under the latest answer).
enum FollowUpBuilder {
    static let schemaName = "folgefragen"

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": ["fragen": ["type": "array", "items": ["type": "string"]]],
        "required": ["fragen"],
    ]

    private static let contextBudget = 5_000

    static func requestMessages(for chat: Chat, answer: ChatMessage) -> [ChatPayloadMessage] {
        let system = """
        Du schlägst Folgefragen für einen Chat vor. Formuliere genau drei kurze Fragen mit höchstens 12 Wörtern, \
        die die Person als Nächstes an den Assistenten stellen könnte.
        - Aus Sicht der Person formuliert, z. B. „Wie viel kostet das Studium?“, nicht an die Person gerichtet.
        - Nichts fragen, was die letzte Antwort schon beantwortet.
        - Drei verschiedene Richtungen: vertiefen, Praxis/Beispiel, angrenzendes Thema.
        - In der Sprache der letzten Frage der Person.
        """

        // The latest exchange matters most; earlier messages only as short context.
        guard let answerIndex = chat.messages.firstIndex(where: { $0.id == answer.id }) else {
            return [ChatPayloadMessage(role: "system", content: system)]
        }
        var lines: [String] = []
        var budget = contextBudget
        for message in chat.messages[...answerIndex].reversed() where !message.content.isEmpty && message.role != .system {
            let speaker = message.role == .user ? "Du" : "Assistent"
            let limit = message.id == answer.id ? min(budget, 3_000) : min(budget, 600)
            guard limit > 80 else { break }
            let text = excerpt(message.content, limit: limit)
            lines.insert("\(speaker): \(text)", at: 0)
            budget -= text.count
        }
        return [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n\n")),
        ]
    }

    static func parse(_ answer: String) -> [String] {
        struct Response: Decodable { let fragen: [String] }
        var json = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}") {
            json = String(json[start...end])
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else { return [] }

        var seen = Set<String>()
        return response.fragen
            .map(clean)
            .filter { !$0.isEmpty && $0.count <= 160 && seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    /// Drops numbering, bullets and quotes the model sometimes adds.
    private static func clean(_ question: String) -> String {
        var text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”«»").union(.whitespaces))
    }

    private static func excerpt(_ content: String, limit: Int) -> String {
        let withoutCode = content.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " [Code] ", options: .regularExpression)
        let collapsed = withoutCode.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + " …" : collapsed
    }
}
