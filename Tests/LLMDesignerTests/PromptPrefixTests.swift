import Foundation
import Testing
import LLMDProtocol
@testable import LLMDesigner

/// The beginning of a chat's request must stay the same from turn to turn, or the server's prefix cache misses and
/// the model reads the whole chat again (see `ChatPayloadBuilder`).
@Suite("Präfix-Cache: stabiler Anfang der Anfrage")
struct PromptPrefixTests {
    private func at(_ hour: Int, _ minute: Int, day: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func webHintHasTheDateButNotTheTime() {
        let morning = WebTools.systemHint(for: [.web, .wikipedia], now: at(9, 5))
        let evening = WebTools.systemHint(for: [.web, .wikipedia], now: at(21, 47))
        #expect(morning == evening)
        #expect(!morning.contains("Uhr"))
        #expect(morning.contains("2026"))
        #expect(morning != WebTools.systemHint(for: [.web, .wikipedia], now: at(9, 5, day: 8)))
    }

    @Test func memoriesCountCalendarDays() {
        let now = at(18, 30)
        #expect(ThalamusRecall.relative(at(18, 10), now: now) == "heute")
        #expect(ThalamusRecall.relative(at(0, 5), now: now) == "heute")
        #expect(ThalamusRecall.relative(at(23, 50, day: 6), now: now) == "gestern")
        #expect(ThalamusRecall.relative(at(12, 0, day: 5), now: now) == "vorgestern")
        #expect(ThalamusRecall.relative(at(12, 0, day: 1), now: now) == "vor 6 Tagen")
        #expect(ThalamusRecall.relative(now.addingTimeInterval(-21 * 86_400), now: now) == "vor 3 Wochen")
        #expect(ThalamusRecall.relative(now.addingTimeInterval(-90 * 86_400), now: now) == "vor 3 Monaten")
        #expect(ThalamusRecall.relative(now.addingTimeInterval(-800 * 86_400), now: now) == "vor 2 Jahren")
        // The block in the system prompt reads the same twenty minutes later.
        let entry = ThalamusEntry(date: at(17, 0), chatID: UUID(), messageID: UUID(), category: "Natur", summary: "Es ging um Vulkane.",
                                  keywords: ["Vulkane"], userEmotions: [], aiEmotions: [], text: "Vulkane")
        #expect(ThalamusRecall.line(for: entry, now: at(17, 20)) == ThalamusRecall.line(for: entry, now: at(17, 41)))
    }

    /// Turn n and turn n+1 with other notes (recalled memories, spoken or typed) must agree byte for byte up to the
    /// question of turn n; only the end may differ.
    @Test func turnsShareTheirBeginning() throws {
        let history = [
            ChatPayloadMessage(role: "user", content: "Wie entstehen Wolken?"),
            ChatPayloadMessage(role: "assistant", content: "Durch Abkühlung feuchter Luft."),
            ChatPayloadMessage(role: "user", content: "Und Regen?"),
        ]
        func turn(_ history: [ChatPayloadMessage], notes: [String]) -> [ChatPayloadMessage] {
            let messages = ChatPayloadBuilder.messages(system: "Du bist hilfreich.", hints: [WebTools.systemHint(for: [.web])], thinkToken: false, history: history)
            return ChatPayloadBuilder.adding(notes: notes, toNewestOf: messages)
        }
        let first = turn(history, notes: ["## Woran du dich gerade erinnerst\nAn den Ausflug.", ConversationSession.systemHint])
        let next = turn(history + [
            ChatPayloadMessage(role: "assistant", content: "Tropfen werden zu schwer."),
            ChatPayloadMessage(role: "user", content: "Und Schnee?"),
        ], notes: ["## Woran du dich gerade erinnerst\nAn den Winter."])

        let shared = first.count - 1
        #expect(try LLMClient.requestBody(Array(first.prefix(shared))) == LLMClient.requestBody(Array(next.prefix(shared))))
        #expect(!first[0].content.contains("erinnerst") && !first[0].content.contains("gesprochenes Gespräch"))

        // The notes go in front of the newest question only, framed as the app's.
        let newest = try #require(first.last?.content)
        #expect(newest.hasPrefix(ChatPayloadBuilder.noteStart))
        #expect(newest.hasSuffix(ChatPayloadBuilder.noteEnd + "\n\nUnd Regen?"))
        #expect(newest.contains("An den Ausflug.") && newest.contains("gesprochenes Gespräch"))
        #expect(next.last?.content.hasSuffix("Und Schnee?") == true)
        #expect(next[next.count - 3].content == "Und Regen?")
        #expect(turn(history, notes: []).last?.content == "Und Regen?")
    }

    @Test func notesWithoutAQuestionGoToTheSystemPrompt() {
        let messages = ChatPayloadBuilder.adding(notes: ["Hinweis"], toNewestOf: [ChatPayloadMessage(role: "system", content: "Basis")])
        #expect(messages.count == 1 && messages[0].content == "Basis\n\nHinweis")
        #expect(ChatPayloadBuilder.adding(notes: ["Hinweis"], toNewestOf: []).first?.content == "Hinweis")
    }

    @Test func thinkTokenOpensTheSystemPrompt() {
        let messages = ChatPayloadBuilder.messages(system: "", hints: [], thinkToken: true, history: [ChatPayloadMessage(role: "user", content: "Hallo")])
        #expect(messages.first?.role == "system" && messages.first?.content == "<|think|>")
        #expect(ChatPayloadBuilder.messages(system: "", hints: [], thinkToken: false, history: []).isEmpty)
    }

    /// `JSONEncoder` writes keys in the process's hash order, which changes with every launch; sorted, the tools are
    /// the same characters after a restart.
    @Test func toolsAreWrittenInSortedOrder() throws {
        var forward: [String: ToolDefinition.Parameter] = [:]
        var backward: [String: ToolDefinition.Parameter] = [:]
        let names = ["zeta", "doc", "markdown", "alpha", "occurrence", "heading", "block", "match"]
        for name in names { forward[name] = .init(type: "string", description: name) }
        for name in names.reversed() { backward[name] = .init(type: "string", description: name) }
        let one = try LLMClient.requestBody([ToolDefinition(name: "werkzeug", description: "Tut etwas", parameters: forward)])
        let two = try LLMClient.requestBody([ToolDefinition(name: "werkzeug", description: "Tut etwas", parameters: backward)])
        #expect(one == two)
        let text = String(decoding: one, as: UTF8.self)
        let positions = names.sorted().map { text.range(of: "\"\($0)\":")!.lowerBound }
        #expect(positions == positions.sorted())

        let schema = try JSONValue.parse(#"{"type":"object","properties":{"zeta":{"type":"string"},"alpha":{"type":"string"}}}"#)
        let json = String(decoding: try LLMClient.requestBody([ToolDefinition(name: "x", description: "y", schema: schema)]), as: UTF8.self)
        #expect(json.range(of: "\"alpha\"")!.lowerBound < json.range(of: "\"zeta\"")!.lowerBound)
    }

    /// A schema given as text keeps its order although the rest of the body is sorted: small models write the
    /// properties in that order.
    @Test func orderedSchemaKeepsItsOrder() async throws {
        let server = try FakeLLMServer()
        defer { server.stop() }
        server.completions = [#"{"zeta":"z","alpha":"a"}"#]
        let client = try LLMClient(provider: .lmStudio, endpoint: server.endpoint, apiKey: nil)
        let schema = #"{"type":"object","properties":{"zeta":{"type":"string"},"alpha":{"type":"string"}},"required":["zeta","alpha"]}"#
        _ = try await client.complete(model: "fake", messages: [ChatPayloadMessage(role: "user", content: "Hallo")], temperature: 0, maxTokens: 10,
                                      orderedSchema: ("antwort", schema))
        let raw = try #require(server.rawCompletions.first)
        #expect(raw.contains(schema))
        #expect(raw.range(of: "\"max_tokens\"")!.lowerBound < raw.range(of: "\"messages\"")!.lowerBound)
    }
}
