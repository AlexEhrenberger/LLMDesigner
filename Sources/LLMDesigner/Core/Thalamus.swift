import Foundation

// The strong memory ("Thalamus"), modelled on how people remember:
//
// - Short term: every message the user writes to a persona with "Gedächtnis: stark" is first sorted by a neutral
//   instance of the loaded model into an impression (`ThalamusEntry`): category, what was said, keywords, the user's
//   feelings and those an AI would have, each from 1 to 10, e.g. (Studium, (Trauer: 6, Angst: 2), (Mitgefühl: 4)).
// - Consolidation: once a chat goes quiet, its impressions are folded into memories (`ThalamusMemory`): topics that
//   grow over many chats ("Statistik-Klausur") with a story, keywords and the course of the feelings. Lasting facts
//   about the user go into the profile (`ThalamusFact`). Then the impressions are gone; trivial ones are forgotten.
// - Long term: memories are never deleted on their own; less important ones move back in the order (`importance`).
//   The profile and the memories of the latest chats are always in the context; older memories come back when a word
//   of the new message triggers one of their keywords.

struct ThalamusEmotion: Codable, Hashable, Sendable {
    var name: String
    /// 1 (very weak) … 10 (very strong).
    var intensity: Int

    var label: String { "\(name) \(intensity)" }
}

struct ThalamusEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var chatID: Chat.ID
    /// The user's message the entry was made from.
    var messageID: ChatMessage.ID
    var category: String
    /// What the user said, in one sentence ("Der Nutzer ist durch die Klausur gefallen.").
    var summary: String
    var keywords: [String]
    /// How the user felt, as far as the message shows.
    var userEmotions: [ThalamusEmotion]
    /// How an AI conversation partner would feel about it.
    var aiEmotions: [ThalamusEmotion]
    /// The message itself, shortened.
    var text: String
    var model: String?

    /// The key as the user described it: (Studium, (Trauer: 6, Angst: 2), (Mitgefühl: 4)).
    var key: String {
        func list(_ emotions: [ThalamusEmotion]) -> String {
            "(" + emotions.map { "\($0.name): \($0.intensity)" }.joined(separator: ", ") + ")"
        }
        return "(\(category), \(list(userEmotions)), \(list(aiEmotions)))"
    }

    var strongestFeeling: Int {
        (userEmotions + aiEmotions).map(\.intensity).max() ?? 0
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || category.localizedStandardContains(query) || summary.localizedStandardContains(query)
            || text.localizedStandardContains(query) || keywords.contains { $0.localizedStandardContains(query) }
            || (userEmotions + aiEmotions).contains { $0.name.localizedStandardContains(query) }
    }
}

/// One point in the course of a memory's feelings: how both sides felt at the time of one chat.
struct ThalamusFeelingPoint: Codable, Hashable, Sendable {
    var date: Date
    var user: [ThalamusEmotion]
    var ai: [ThalamusEmotion]
}

/// A topic of the user's life or interests that grows over many chats.
struct ThalamusMemory: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var category: String
    /// A few sentences, in the order things happened, that make clear who said what.
    var summary: String
    var keywords: [String]
    /// The course of the feelings, one point per consolidated chat.
    var feelings: [ThalamusFeelingPoint]
    var firstDate: Date
    var lastDate: Date
    /// How many impressions went into the memory.
    var mentions: Int
    var chatIDs: [Chat.ID]
    var updatedAt = Date()

    static let maxFeelingPoints = 8
    static let maxKeywords = 14

    /// 0…1: strong feelings stick, frequent topics matter, and everything fades a little with time
    /// (it moves back in the order but is never deleted on its own).
    func importance(now: Date = Date()) -> Double {
        let peak = Double(feelings.flatMap { $0.user + $0.ai }.map(\.intensity).max() ?? 0) / 10
        let frequency = min(1, log2(Double(mentions) + 1) / 4)
        let days = max(0, now.timeIntervalSince(lastDate) / 86_400)
        return 0.45 * peak + 0.25 * frequency + 0.3 * exp(-days / 90)
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || category.localizedStandardContains(query)
            || summary.localizedStandardContains(query) || keywords.contains { $0.localizedStandardContains(query) }
            || feelings.contains { ($0.user + $0.ai).contains { $0.name.localizedStandardContains(query) } }
    }
}

/// A lasting fact about the user ("Der Nutzer heißt Alex."), always in the persona's context.
struct ThalamusFact: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var since: Date
    var updatedAt: Date
}

/// What Thalamus did for one answer: how it sorted the question and which moments the persona remembered.
struct ThalamusTrace: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, done, failed
    }

    var status: Status
    var entry: ThalamusEntry?
    /// False for small talk, which is sorted but not kept.
    var stored: Bool?
    /// Impressions recalled before consolidation existed (older chats show them).
    var recalled: [ThalamusEntry]?
    /// Memories the message reminded the persona of.
    var memories: [ThalamusMemory]?
    var error: String?
}

/// The database of one persona, saved as `thalamus.json` in its folder.
struct ThalamusLibrary: Codable, Sendable {
    static let currentVersion = 2

    /// Nil for files from before consolidation existed.
    var version: Int?
    /// Short-term impressions that are not consolidated yet.
    var entries: [ThalamusEntry] = []
    var memories: [ThalamusMemory]?
    var profile: [ThalamusFact]?
    /// When each chat last added an impression (keys are chat IDs); decides which chats are "the latest".
    var chatActivity: [String: Date]?
    /// Messages that are not sorted again: their impression was deleted or already consolidated.
    var forgottenMessageIDs: [ChatMessage.ID] = []

    var categories: [String] {
        var counts: [String: Int] = [:]
        for memory in memories ?? [] { counts[memory.category, default: 0] += memory.mentions }
        for entry in entries { counts[entry.category, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    mutating func noteActivity(_ chatID: Chat.ID, at date: Date) {
        var activity = chatActivity ?? [:]
        activity[chatID.uuidString] = max(activity[chatID.uuidString] ?? .distantPast, date)
        chatActivity = activity
    }

    /// The latest chats (by activity) other than `chatID`, newest first.
    func latestChats(excluding chatID: Chat.ID?, count: Int) -> [Chat.ID] {
        var activity = chatActivity ?? [:]
        for entry in entries { activity[entry.chatID.uuidString] = max(activity[entry.chatID.uuidString] ?? .distantPast, entry.date) }
        return activity.sorted { $0.value > $1.value }
            .compactMap { UUID(uuidString: $0.key) }
            .filter { $0 != chatID }
            .prefix(count)
            .map { $0 }
    }
}

extension PersonaStore {
    static func thalamusURL(of personaID: Persona.ID) -> URL {
        folder(for: personaID).appendingPathComponent("thalamus.json")
    }

    static func loadThalamus(of personaID: Persona.ID) -> ThalamusLibrary {
        let url = thalamusURL(of: personaID)
        guard FileManager.default.fileExists(atPath: url.path) else { return ThalamusLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ThalamusLibrary.self, from: Data(contentsOf: url))
        } catch {
            // Keep the unreadable file, so the next save doesn't overwrite what is in it.
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            print("LLMDesigner: thalamus.json von \(personaID) konnte nicht gelesen werden: \(error)")
            return ThalamusLibrary()
        }
    }

    static func saveThalamus(_ library: ThalamusLibrary, of personaID: Persona.ID) {
        let url = thalamusURL(of: personaID)
        // The first save in the new format keeps the old file, in case the consolidation goes wrong.
        if library.version == ThalamusLibrary.currentVersion, FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("thalamus-vor-verdichtung.json")
            if !FileManager.default.fileExists(atPath: backup.path),
               let data = try? Data(contentsOf: url), !String(decoding: data, as: UTF8.self).contains("\"version\"") {
                try? data.write(to: backup)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(library).write(to: url, options: .atomic)
        } catch {
            print("LLMDesigner: thalamus.json von \(personaID) konnte nicht gespeichert werden: \(error)")
        }
    }
}

// MARK: Sorting a message

/// A user message to sort, with what the classifier needs to understand it.
struct ThalamusJob: Sendable {
    let personaID: Persona.ID
    let chatID: Chat.ID
    let question: ChatMessage
    /// The persona's answer right before the message, so short replies ("ja, leider") make sense.
    let previousAnswer: String?
    let model: String
    /// The chat's context length; it decides how many entries of the latest chats are in the context.
    let contextLength: Int
}

/// The neutral instance: sorts a message without the persona's system prompt.
enum ThalamusClassifier {
    static let schemaName = "thalamus"

    /// Offered so the categories of a persona stay consistent; the persona's own categories come first.
    static let suggestedCategories = [
        "Studium", "Arbeit", "Familie", "Freundschaft", "Liebe", "Gesundheit", "Psychologie", "Freizeit",
        "Wohnen", "Finanzen", "Technik", "Wissen", "Alltag",
    ]

    static let schema: [String: Any] = {
        let emotion: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["gefuehl": ["type": "string"], "staerke": ["type": "integer"]],
            "required": ["gefuehl", "staerke"],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "properties": [
                "kategorie": ["type": "string"],
                "inhalt": ["type": "string"],
                "schlagworte": ["type": "array", "items": ["type": "string"]],
                "gefuehle_nutzer": ["type": "array", "items": emotion],
                "gefuehle_ki": ["type": "array", "items": emotion],
                "merkenswert": ["type": "boolean"],
            ],
            "required": ["kategorie", "inhalt", "schlagworte", "gefuehle_nutzer", "gefuehle_ki", "merkenswert"],
        ]
    }()

    static func requestMessages(for job: ThalamusJob, knownCategories: [String]) -> [ChatPayloadMessage] {
        var categories = knownCategories
        for suggestion in suggestedCategories where !categories.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }) {
            categories.append(suggestion)
        }
        let system = """
        Du bist ein neutrales Analysewerkzeug für ein Gedächtnissystem. Du bekommst eine Nachricht, die ein Nutzer an einen KI-Gesprächspartner geschrieben hat, und ordnest sie ein.
        - „kategorie“: das Lebens- oder Wissensgebiet, um das es geht, ein bis zwei Wörter. Nimm nach Möglichkeit eine dieser Kategorien: \(categories.prefix(30).joined(separator: ", ")). Nur wenn keine passt, eine neue.
        - „inhalt“: ein Satz, was der Nutzer gesagt oder erzählt hat, in der dritten Person, z. B. „Der Nutzer ist durch die Statistik-Klausur gefallen.“ Übernimm Namen, Zahlen und Orte genau und erfinde nichts dazu.
        - „schlagworte“: 2 bis 6 Schlagwörter zum Inhalt, Substantive in der Grundform, z. B. „Klausur“, „Statistik“.
        - „gefuehle_nutzer“: 0 bis 3 Gefühle, die der Nutzer in der Nachricht zeigt oder sehr wahrscheinlich hat, aus seiner Sicht. „staerke“ von 1 (sehr schwach) bis 10 (sehr stark). Keine Gefühle erfinden, wo keine erkennbar sind.
        - „gefuehle_ki“: 0 bis 3 Gefühle, die ein einfühlsamer KI-Gesprächspartner beim Lesen hätte, wenn er Gefühle hätte, ebenfalls mit Stärke 1 bis 10.
        - Gefühle als einzelnes Substantiv, z. B. Freude, Trauer, Angst, Wut, Scham, Stolz, Sorge, Hoffnung, Erleichterung, Frustration, Einsamkeit, Neugier, Begeisterung, Dankbarkeit, Liebe, Mitgefühl, Überraschung, Gelassenheit.
        - „merkenswert“: false, wenn die Nachricht nichts Neues über den Nutzer, sein Leben oder ein Thema enthält: Dank, Begrüßung, Zustimmung, kurze Reaktionen wie „danke dir“, „ok cool“, „hallo Mira“, „ja genau“, „haha“ und Fragen an den Gesprächspartner selbst („wie geht es dir?“, „weißt du noch, worüber wir gesprochen haben?“). Sonst true.
        - Schreibe auf Deutsch.
        """
        var user = ""
        if let previous = job.previousAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            user += "Zum Verständnis, die letzte Antwort des Gesprächspartners: „\(excerpt(previous, limit: 500))“\n\n"
        }
        user += "Nachricht des Nutzers:\n„\(excerpt(job.question.content, limit: 2_500))“"
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    /// The entry for the message, and whether it is worth keeping.
    static func parse(_ answer: String, job: ThalamusJob, knownCategories: [String]) throws -> (entry: ThalamusEntry, memorable: Bool) {
        struct Feeling: Decodable {
            let gefuehl: String
            let staerke: Double
        }
        struct Response: Decodable {
            let kategorie: String
            let inhalt: String
            let schlagworte: [String]
            let gefuehle_nutzer: [Feeling]
            let gefuehle_ki: [Feeling]
            let merkenswert: Bool?
        }
        var json = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}") {
            json = String(json[start...end])
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))

        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“”#*").union(.whitespacesAndNewlines))
        }
        func feelings(_ list: [Feeling]) -> [ThalamusEmotion] {
            var seen: Set<String> = []
            return list.compactMap { feeling in
                let name = clean(feeling.gefuehl)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                let capitalized = name.prefix(1).uppercased() + name.dropFirst()
                return ThalamusEmotion(name: capitalized, intensity: min(10, max(1, Int(feeling.staerke.rounded()))))
            }
            .prefix(3)
            .map { $0 }
        }

        // Spelling of a known category wins ("studium" → "Studium").
        var category = clean(response.kategorie)
        if let known = (knownCategories + suggestedCategories).first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
            category = known
        }
        if category.isEmpty { category = "Allgemein" }
        var seenKeywords: Set<String> = []
        let keywords = response.schlagworte.map(clean).filter { !$0.isEmpty && seenKeywords.insert($0.lowercased()).inserted }

        let entry = ThalamusEntry(
            date: job.question.createdAt,
            chatID: job.chatID,
            messageID: job.question.id,
            category: String(category.prefix(40)),
            summary: clean(response.inhalt),
            keywords: Array(keywords.prefix(6)),
            userEmotions: feelings(response.gefuehle_nutzer),
            aiEmotions: feelings(response.gefuehle_ki),
            text: excerpt(job.question.content, limit: 600),
            model: job.model
        )
        return (entry, response.merkenswert ?? true)
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + " …" : collapsed
    }
}

// MARK: Remembering

enum ThalamusRecall {
    /// Older memories a single message may bring back.
    static let limit = 3
    /// How many of the persona's latest chats stay in the context with their memories.
    static let recentChats = 3
    /// Share of the chat's context the latest chats may take; beyond it the oldest drop out.
    static let recentShare = 0.15
    /// Share of the context for the profile.
    static let profileShare = 0.05

    static func budget(_ share: Double, contextLength: Int) -> Int {
        Int(Double(contextLength) * share * 3.5)
    }

    // MARK: Triggered by the new message

    /// Memories the new message reminds of. A memory's keywords and title are triggered by the new impression's
    /// keywords or by any word of the message, also by a word they start with ("Fit" and "Fitness" trigger
    /// "Fitnesszentrum"). The same category, more triggered words and a higher importance rank a memory higher.
    /// Memories in `excluded` are in the context anyway.
    static func matches(
        for entry: ThalamusEntry, in memories: [ThalamusMemory], excluding excluded: Set<ThalamusMemory.ID> = [], now: Date = Date()
    ) -> [ThalamusMemory] {
        let probes = probes(for: entry)
        guard !probes.isEmpty else { return [] }
        let scored = memories.compactMap { memory -> (ThalamusMemory, Double)? in
            guard !excluded.contains(memory.id) else { return nil }
            let shared = (memory.keywords + [memory.title]).filter { term in probes.contains { triggers($0, term) } }.count
            guard shared >= 1 else { return nil }
            let sameCategory = memory.category.caseInsensitiveCompare(entry.category) == .orderedSame
            return (memory, Double(shared) * 2 + (sameCategory ? 1.5 : 0) + memory.importance(now: now) * 2)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// What can trigger a memory: the entry's keywords and the words of the message (at least three letters,
    /// without small words like "ich" or "heute").
    static func probes(for entry: ThalamusEntry) -> [String] {
        let words = entry.text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen: Set<String> = []
        return (entry.keywords + words).compactMap { term -> String? in
            let folded = fold(term)
            guard folded.count >= 3, !stopWords.contains(folded), seen.insert(folded).inserted else { return nil }
            return folded
        }
    }

    /// Whether a probe (folded) triggers a stored keyword: equal, the beginning of the keyword or of one of its words
    /// ("fit" → "Fitnesszentrum", "woche" → "nächste Woche"), or, from five letters on, contained in it ("zentrum").
    /// A longer probe also triggers a shorter keyword it starts with ("klausuren" → "Klausur").
    static func triggers(_ probe: String, _ keyword: String) -> Bool {
        let folded = fold(keyword)
        // Words of a keyword like "nächste Woche" count on their own, small and time words excepted.
        let parts = [folded] + folded.split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }
        return parts.contains { part in
            part == probe || part.hasPrefix(probe) || (probe.count >= 5 && part.contains(probe))
                || (part.count >= 4 && probe.hasPrefix(part))
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words of three letters or more that say nothing about a topic.
    private static let stopWords: Set<String> = [
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mich", "dich", "sich", "mir", "dir", "uns", "euch", "und", "oder",
        "aber", "doch", "denn", "weil", "dass", "wenn", "als", "wie", "was", "wer", "wo", "wann", "warum", "der", "die",
        "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "kein", "keine", "nicht", "nur",
        "auch", "noch", "schon", "sehr", "mal", "ganz", "heute", "gestern", "morgen", "jetzt", "hier", "dort", "bin",
        "bist", "ist", "sind", "war", "waren", "habe", "hab", "hast", "hat", "haben", "hatte", "hatten", "wird", "werde",
        "werden", "kann", "kannst", "muss", "musst", "will", "willst", "soll", "mit", "von", "fur", "auf", "aus", "bei",
        "nach", "uber", "unter", "vor", "zum", "zur", "bis", "durch", "gegen", "ohne", "mein", "meine", "meinen",
        "meinem", "meiner", "dein", "deine", "deinen", "sein", "seine", "ihre", "ihren", "unser", "unsere", "euer",
        "diese", "dieser", "dieses", "diesen", "man", "etwas", "alles", "viel", "mehr", "gut", "echt", "einfach",
        "gerade", "immer", "wieder", "dann", "also", "eben", "halt", "ja", "nein", "okay", "danke", "hallo", "weisst",
        "weiss", "glaube", "denke", "finde", "mache", "machen", "gehe", "geht", "gibt", "richtig", "wirklich", "bisschen",
        "woche", "wochen", "tag", "tage", "tagen", "monat", "monate", "jahr", "jahre", "jahren", "zeit", "uhr", "leute",
        "sache", "sachen", "ding", "dinge", "frage", "antwort", "nachste", "nachsten", "letzte", "letzten", "erste",
        "ersten", "neue", "neuen", "andere", "anderen",
        "the", "and", "you", "for", "that", "this", "with",
    ]

    // MARK: Always in the context

    /// The facts of the profile that fit into `budget` characters, the most recently confirmed first.
    static func profile(in library: ThalamusLibrary, budget: Int) -> [ThalamusFact] {
        var used = 0
        var kept: [ThalamusFact] = []
        for fact in (library.profile ?? []).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard used + fact.text.count + 3 <= budget else { break }
            kept.append(fact)
            used += fact.text.count + 3
        }
        return kept.sorted { $0.since < $1.since }
    }

    /// What the persona has from its latest chats (other than the one being written): their impressions that are not
    /// consolidated yet, then their memories, newest first, as far as `budget` characters allow. The oldest drop out.
    static func recent(
        in library: ThalamusLibrary, excludingChat chatID: Chat.ID?, budget: Int, now: Date = Date()
    ) -> (memories: [ThalamusMemory], impressions: [ThalamusEntry]) {
        let chats = Set(library.latestChats(excluding: chatID, count: recentChats))
        var used = 0
        var impressions: [ThalamusEntry] = []
        for entry in library.entries.filter({ chats.contains($0.chatID) }).sorted(by: { $0.date > $1.date }) {
            let cost = line(for: entry, now: now).count + 1
            guard used + cost <= budget else { break }
            impressions.append(entry)
            used += cost
        }
        var memories: [ThalamusMemory] = []
        for memory in (library.memories ?? []).filter({ !chats.isDisjoint(with: $0.chatIDs) }).sorted(by: { $0.lastDate > $1.lastDate }) {
            let cost = text(of: memory, now: now).count + 2
            guard used + cost <= budget else { break }
            memories.append(memory)
            used += cost
        }
        return (memories, impressions.sorted { $0.date < $1.date })
    }

    // MARK: Text

    static func profileBlock(_ facts: [ThalamusFact]) -> String? {
        guard !facts.isEmpty else { return nil }
        return "## Was du über dein Gegenüber weißt\n" + facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// The latest chats for the system prompt: their memories, and what is not consolidated yet.
    static func recentBlock(memories: [ThalamusMemory], impressions: [ThalamusEntry], now: Date = Date()) -> String? {
        guard !memories.isEmpty || !impressions.isEmpty else { return nil }
        var parts = memories.map { text(of: $0, now: now) }
        if !impressions.isEmpty {
            parts.append("### Frisch aus den letzten Gesprächen\n" + impressions.map { line(for: $0, now: now) }.joined(separator: "\n"))
        }
        return """
        ## Deine letzten Gespräche
        Das weißt du aus euren letzten Gesprächen, mit den Gefühlen von damals. Du kannst dich jederzeit direkt darauf beziehen, so wie sich ein Mensch an die letzten Gespräche erinnert. \(feelingsRule)
        """ + "\n\n" + parts.joined(separator: "\n\n")
    }

    /// The memories a message brought back, for the system prompt of that one answer.
    static func block(_ memories: [ThalamusMemory], now: Date = Date()) -> String? {
        guard !memories.isEmpty else { return nil }
        return """
        ## Woran du dich gerade erinnerst
        Die neue Nachricht deines Gegenübers erinnert dich an frühere Gespräche. Greif darauf zurück, wenn es passt, und erinnere dich auch an die Gefühle von damals, so wie ein Mensch sagt: „Ich weiß noch, wie traurig du warst, als …“. Erfinde nichts dazu. \(feelingsRule)
        """ + "\n\n" + memories.map { text(of: $0, now: now) }.joined(separator: "\n\n")
    }

    /// A memory for the prompt: title, topic, when, the story and how the feelings went.
    static func text(of memory: ThalamusMemory, now: Date = Date()) -> String {
        var text = "### \(memory.title) (Thema \(memory.category), zuletzt \(relative(memory.lastDate, now: now)))\n\(memory.summary)"
        if let user = arc(memory.feelings.map(\.user)) { text += "\nGefühle deines Gegenübers im Verlauf: \(user)." }
        if let ai = arc(memory.feelings.map(\.ai)) { text += "\nDeine Gefühle im Verlauf: \(ai)." }
        return text
    }

    /// The strongest feeling of each point, in words: "Angst (sehr stark) → Erleichterung (stark)".
    private static func arc(_ points: [[ThalamusEmotion]]) -> String? {
        var steps: [String] = []
        for point in points {
            guard let strongest = point.max(by: { $0.intensity < $1.intensity }) else { continue }
            let step = feeling(strongest)
            if steps.last != step { steps.append(step) }
        }
        return steps.isEmpty ? nil : steps.joined(separator: " → ")
    }

    /// One entry as a line: when, topic, what was said and how both sides felt.
    static func line(for entry: ThalamusEntry, now: Date = Date(), withDate: Bool = true) -> String {
        var line = "- "
        if withDate {
            let when = relative(entry.date, now: now)
            line += "\(when.prefix(1).uppercased() + when.dropFirst()) (\(entry.date.formatted(.dateTime.day().month(.wide).year()))), "
        }
        line += "Thema \(entry.category): \(entry.summary)"
        if !entry.userEmotions.isEmpty {
            line += " Gefühle deines Gegenübers: " + entry.userEmotions.map(feeling).joined(separator: ", ") + "."
        }
        if !entry.aiEmotions.isEmpty {
            line += " Deine Gefühle: " + entry.aiEmotions.map(feeling).joined(separator: ", ") + "."
        }
        return line
    }

    /// Strengths as words for the prompt: the persona repeats numbers like "Freude 9/10" literally.
    private static func feeling(_ emotion: ThalamusEmotion) -> String {
        let strength = switch emotion.intensity {
        case ...2: "leicht"
        case 3...4: "mäßig"
        case 5...6: "deutlich"
        case 7...8: "stark"
        default: "sehr stark"
        }
        return "\(emotion.name) (\(strength))"
    }

    /// The persona should show feelings, not report them.
    private static let feelingsRule = "Die Gefühle und ihre Stärke sind nur für dich: Nenne nie Zahlen, Skalen oder Stärkeangaben, sondern lass sie in deine eigenen Worte einfließen (z. B. „Du warst so stolz!“)."

    /// In calendar days, never minutes or hours: these lines sit in the system prompt, and "vor 20 Minuten" turning
    /// into "vor 21 Minuten" made the server read the whole chat again instead of taking it from its prefix cache
    /// (see `ChatPayloadBuilder`). The exact date is written next to it anyway.
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "heute"
        case 1: return "gestern"
        case 2: return "vorgestern"
        case 3..<14: return "vor \(days) Tagen"
        case 14..<60: return "vor \(days / 7) Wochen"
        case 60..<730: return "vor \(days / 30) Monaten"
        default: return "vor \(days / 365) Jahren"
        }
    }
}
