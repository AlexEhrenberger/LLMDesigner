import Foundation

/// The impressions of one chat, to be folded into a persona's memories and profile.
struct ThalamusConsolidationJob: Sendable {
    let personaName: String
    let chatID: Chat.ID
    let impressions: [ThalamusEntry]
    /// Memories the impressions may belong to (see `ThalamusConsolidator.candidates`).
    let memories: [ThalamusMemory]
    let profile: [ThalamusFact]
    let categories: [String]
}

/// Consolidation: a neutral instance of the model reads a chat's impressions next to the memories they may belong to
/// and decides what extends a known topic, what becomes a new one, what is a lasting fact about the user, and what is
/// not worth keeping. The app then updates the memories, adds the course of the feelings and removes the impressions.
enum ThalamusConsolidator {
    static let schemaName = "verdichtung"
    /// Memories shown to the model next to the impressions; more would crowd out an 8K context.
    static let candidateLimit = 8

    static let schema: [String: Any] = {
        let memory: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "ziel": ["type": "string"],
                "titel": ["type": "string"],
                "kategorie": ["type": "string"],
                "inhalt": ["type": "string"],
                "schlagworte": ["type": "array", "items": ["type": "string"]],
                "eindruecke": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["ziel", "titel", "kategorie", "inhalt", "schlagworte", "eindruecke"],
        ]
        let fact: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["fakt": ["type": "string"], "ersetzt": ["type": "string"]],
            "required": ["fakt", "ersetzt"],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "properties": [
                "verworfen": ["type": "array", "items": ["type": "string"]],
                "erinnerungen": ["type": "array", "items": memory],
                "profil": ["type": "array", "items": fact],
            ],
            "required": ["verworfen", "erinnerungen", "profil"],
        ]
    }()

    /// The memories the impressions may belong to: those of the same category already holding this chat, then those
    /// whose keywords or title the impressions trigger, then those of the same category, more important ones first.
    static func candidates(for impressions: [ThalamusEntry], chatID: Chat.ID, in memories: [ThalamusMemory]) -> [ThalamusMemory] {
        let probes = Set(impressions.flatMap(ThalamusRecall.probes(for:)))
        let categories = Set(impressions.map { $0.category.lowercased() })
        let scored = memories.map { memory -> (ThalamusMemory, Double) in
            var score = memory.importance()
            let sameCategory = categories.contains(memory.category.lowercased())
            if sameCategory && memory.chatIDs.contains(chatID) { score += 10 }
            score += Double((memory.keywords + [memory.title]).filter { term in probes.contains { ThalamusRecall.triggers($0, term) } }.count) * 2
            if sameCategory { score += 1 }
            return (memory, score)
        }
        return scored.filter { $0.1 >= 1 }.sorted { $0.1 > $1.1 }.prefix(candidateLimit).map(\.0)
    }

    static func requestMessages(for job: ThalamusConsolidationJob) -> [ChatPayloadMessage] {
        let name = job.personaName
        let system = """
        Du bist das Langzeitgedächtnis von \(name), einer KI-Persona, und verdichtest frische Eindrücke aus einem Gespräch mit dem Nutzer zu dauerhaften Erinnerungen.
        Eine Erinnerung ist ein Thema aus dem Leben oder den Interessen des Nutzers (z. B. „Statistik-Klausur“, „Umzug nach Leipzig“, „Schwester Lotte“), das über viele Gespräche wächst.
        - Gehören Eindrücke zu einer vorhandenen Erinnerung (E1, E2 …), ergänze sie: „ziel“ ist ihre Kennung, „inhalt“ der vollständige neue Text. Er behält alles Wichtige aus dem bisherigen Inhalt und ergänzt das Neue in zeitlicher Reihenfolge.
        - Gehören Eindrücke zu keinem vorhandenen Thema, lege eine neue Erinnerung an: „ziel“ ist "neu".
        - Eine Erinnerung hat genau ein Thema. Eindrücke zum selben Thema gehören zusammen; verschiedene Themen (z. B. eine Prüfung und ein Umzug) kommen in getrennte Erinnerungen, auch wenn sie im selben Gespräch vorkommen. Gib vorhandene Erinnerungen nur aus, wenn du sie ergänzt, und behalte ihren Titel, solange er noch passt.
        - „inhalt“: 2 bis 6 Sätze in der dritten Person. Mach klar, wer was gesagt hat („Der Nutzer hat erzählt …“, „\(name) hat vorgeschlagen …“). Übernimm Namen, Zahlen, Orte und Termine genau und erfinde nichts. Ein Datum nur, wenn es für den Verlauf wichtig ist, keine Uhrzeiten.
        - „titel“: das Thema in 2 bis 5 Wörtern.
        - „eindruecke“: die Kennungen der Eindrücke, die in diese Erinnerung eingeflossen sind, z. B. ["#1", "#3"].
        - „schlagworte“: 3 bis 10 Substantive, unter denen man das Thema wiederfindet, auch Oberbegriffe und Synonyme.
        - „kategorie“: nach Möglichkeit eine dieser Kategorien: \(job.categories.prefix(30).joined(separator: ", ")).
        - „profil“: neue, dauerhafte Fakten über das Leben des Nutzers (Name, Alter, Wohnort, Beruf, wichtige Menschen, Haustiere, feste Vorlieben), ein Satz pro Fakt. Keine Beschreibungen, wie er sich im Gespräch verhält (nicht „Der Nutzer ist neugierig“). Ersetzt ein Fakt einen vorhandenen (F1, F2 …), etwa einen neuen Wohnort, steht dessen Kennung in „ersetzt“, sonst "". Bekannte Fakten nicht wiederholen.
        - „verworfen“: zuerst die Kennungen aller Eindrücke ohne bleibenden Wert, z. B. ["#2"]: Smalltalk und Fragen an \(name) selbst (wie es \(name) geht, ob \(name) sich an etwas erinnert). Verworfene Eindrücke kommen weder in eine Erinnerung noch ins Profil.
        - Schreibe auf Deutsch.
        """

        var user = ""
        if !job.profile.isEmpty {
            user += "## Profil (bekannte Fakten)\n"
            user += job.profile.enumerated().map { "F\($0.offset + 1): \($0.element.text)" }.joined(separator: "\n") + "\n\n"
        }
        if !job.memories.isEmpty {
            user += "## Vorhandene Erinnerungen\n"
            user += job.memories.enumerated().map { index, memory in
                "E\(index + 1): \(memory.title) (Thema \(memory.category))\nInhalt: \(memory.summary)\nSchlagworte: \(memory.keywords.joined(separator: ", "))"
            }.joined(separator: "\n\n") + "\n\n"
        }
        // Only the day: with times, small models write "um 14:04 Uhr" into every memory.
        let dateFormat = Date.FormatStyle().day().month(.abbreviated).year()
        user += "## Frische Eindrücke aus dem Gespräch\n"
        user += job.impressions.enumerated().map { index, entry in
            var line = "#\(index + 1) (\(entry.date.formatted(dateFormat))) Thema \(entry.category): \(entry.summary)"
            let feelings = entry.userEmotions.map(\.name)
            if !feelings.isEmpty { line += " (Gefühle des Nutzers: \(feelings.joined(separator: ", ")))" }
            let text = entry.text.count > 240 ? String(entry.text.prefix(240)) + " …" : entry.text
            return line + "\n   Wortlaut: „\(text)“"
        }.joined(separator: "\n")
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    /// Impressions about the conversation itself ("Der Nutzer fragt den Gesprächspartner, ob er sich erinnert …"),
    /// which small models file as content. The neutral classifier always calls the persona "Gesprächspartner".
    static func isAboutConversation(_ entry: ThalamusEntry, personaName: String) -> Bool {
        let summary = entry.summary.lowercased()
        let addressed = summary.contains("gesprächspartner") || summary.range(of: #"\bki\b"#, options: .regularExpression) != nil
            || (!personaName.isEmpty && summary.contains(personaName.lowercased()))
        let asking = ["fragt", "befinden", "erinnert", "begrüßt", "bedankt"].contains { summary.contains($0) }
        return addressed && asking
    }

    /// What a consolidation changed, for the editor.
    struct Outcome: Sendable {
        var updated = 0
        var created = 0
        var facts = 0
        var dropped = 0
    }

    /// Applies the model's answer to `library`: updates and adds memories, adds the course of the feelings, updates
    /// the profile and removes the consolidated impressions. Throws, without changing anything, if the answer is
    /// unusable or keeps nothing at all (the impressions then wait for the next attempt).
    static func apply(_ answer: String, job: ThalamusConsolidationJob, to library: inout ThalamusLibrary) throws -> Outcome {
        struct Memory: Decodable {
            let ziel: String
            let titel: String
            let kategorie: String
            let inhalt: String
            let schlagworte: [String]
            let eindruecke: [String]
        }
        struct Fact: Decodable {
            let fakt: String
            let ersetzt: String?
        }
        struct Response: Decodable {
            let verworfen: [String]?
            let erinnerungen: [Memory]
            let profil: [Fact]
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
        /// "E2", "#2", "2" or "Eindruck 2" → index 1. A "#" or letter prefix wins over other numbers (a date, say).
        func reference(_ text: String) -> Int? {
            let marked = text.range(of: #"(?:#|[EF])\s*(\d+)"#, options: .regularExpression).map { String(text[$0]) } ?? text
            return Int(marked.drop { !$0.isNumber }.prefix(while: \.isNumber)).map { $0 - 1 }
        }

        var outcome = Outcome()
        var memories = library.memories ?? []
        var used: Set<Int> = []
        let now = Date()
        let discarded = Set((response.verworfen ?? []).compactMap(reference))

        for item in response.erinnerungen {
            let assigned = item.eindruecke.compactMap(reference)
                .filter { job.impressions.indices.contains($0) && !discarded.contains($0) }
            let impressions = Set(assigned).sorted().map { job.impressions[$0] }
            let summary = clean(item.inhalt)
            let target = item.ziel.uppercased().hasPrefix("E") ? reference(item.ziel).flatMap { job.memories.indices.contains($0) ? job.memories[$0] : nil } : nil
            // A memory without any impression would be made up.
            guard !impressions.isEmpty, summary.count >= 20 else { continue }
            used.formUnion(assigned)

            var category = clean(item.kategorie)
            if let known = job.categories.first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) { category = known }
            if category.isEmpty { category = impressions[0].category }
            let point = feelingPoint(of: impressions)

            if let target, let index = memories.firstIndex(where: { $0.id == target.id }) {
                var memory = memories[index]
                let title = clean(item.titel)
                if !title.isEmpty { memory.title = String(title.prefix(60)) }
                memory.category = String(category.prefix(40))
                memory.summary = summary
                memory.keywords = mergedKeywords(
                    item.schlagworte.map(clean) + memory.keywords + impressions.flatMap(\.keywords), feelings: impressions, category: category
                )
                if let point { memory.feelings = Array((memory.feelings + [point]).suffix(ThalamusMemory.maxFeelingPoints)) }
                memory.firstDate = min(memory.firstDate, impressions.map(\.date).min() ?? memory.firstDate)
                memory.lastDate = max(memory.lastDate, impressions.map(\.date).max() ?? memory.lastDate)
                memory.mentions += impressions.count
                if !memory.chatIDs.contains(job.chatID) { memory.chatIDs.append(job.chatID) }
                memory.updatedAt = now
                memories[index] = memory
                outcome.updated += 1
            } else {
                let title = clean(item.titel)
                memories.append(ThalamusMemory(
                    title: String((title.isEmpty ? impressions[0].keywords.first ?? "Erinnerung" : title).prefix(60)),
                    category: String(category.prefix(40)),
                    summary: summary,
                    keywords: mergedKeywords(item.schlagworte.map(clean) + impressions.flatMap(\.keywords), feelings: impressions, category: category),
                    feelings: point.map { [$0] } ?? [],
                    firstDate: impressions.map(\.date).min() ?? now,
                    lastDate: impressions.map(\.date).max() ?? now,
                    mentions: impressions.count,
                    chatIDs: [job.chatID]
                ))
                outcome.created += 1
            }
        }

        var profile = library.profile ?? []
        for item in response.profil {
            let text = clean(item.fakt)
            guard text.count >= 8, isLifeFact(text, personaName: job.personaName) else { continue }
            let replaced = item.ersetzt.flatMap(reference).flatMap { job.profile.indices.contains($0) ? job.profile[$0] : nil }
            if let replaced, let index = profile.firstIndex(where: { $0.id == replaced.id }) {
                profile[index].text = text
                profile[index].updatedAt = now
                outcome.facts += 1
            } else if !profile.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                let date = job.impressions.map(\.date).max() ?? now
                profile.append(ThalamusFact(text: text, since: date, updatedAt: now))
                outcome.facts += 1
            }
        }

        // A replaced fact may now say the same as another one; keep the older.
        var seenFacts: Set<String> = []
        profile = profile.sorted { $0.since < $1.since }.filter { seenFacts.insert($0.text.lowercased()).inserted }

        guard outcome.updated + outcome.created + outcome.facts > 0 else {
            throw LLMError.server("Das Modell hat aus den Eindrücken nichts verdichtet.")
        }
        outcome.dropped = job.impressions.count - used.count

        let consolidated = Set(job.impressions.map(\.id))
        library.version = ThalamusLibrary.currentVersion
        library.memories = memories
        library.profile = profile
        for entry in job.impressions { library.noteActivity(entry.chatID, at: entry.date) }
        library.entries.removeAll { consolidated.contains($0.id) }
        library.forgottenMessageIDs += job.impressions.map(\.messageID)
        return outcome
    }

    /// How both sides felt in these impressions: the strongest strength of each feeling, at most three per side.
    private static func feelingPoint(of impressions: [ThalamusEntry]) -> ThalamusFeelingPoint? {
        func strongest(_ emotions: [ThalamusEmotion]) -> [ThalamusEmotion] {
            var best: [String: ThalamusEmotion] = [:]
            for emotion in emotions where emotion.intensity > (best[emotion.name.lowercased()]?.intensity ?? 0) {
                best[emotion.name.lowercased()] = emotion
            }
            return best.values.sorted { $0.intensity > $1.intensity }.prefix(3).map { $0 }
        }
        let user = strongest(impressions.flatMap(\.userEmotions))
        let ai = strongest(impressions.flatMap(\.aiEmotions))
        guard !user.isEmpty || !ai.isEmpty else { return nil }
        return ThalamusFeelingPoint(date: impressions.map(\.date).max() ?? Date(), user: user, ai: ai)
    }

    /// Keywords without words about the conversation itself, feelings, dates or the category: "Freude" or "Alltag" as a
    /// keyword would bring the memory back with every happy or everyday message.
    private static func mergedKeywords(_ keywords: [String], feelings impressions: [ThalamusEntry], category: String) -> [String] {
        let feelingNames = Set(impressions.flatMap { $0.userEmotions + $0.aiEmotions }.map { $0.name.lowercased() })
        var seen: Set<String> = [category.lowercased()]
        return keywords.filter { keyword in
            let lowered = keyword.lowercased()
            return !keyword.isEmpty && !keyword.contains(where: \.isNumber) && !metaWords.contains(lowered)
                && !feelingNames.contains(lowered) && seen.insert(lowered).inserted
        }
        .prefix(ThalamusMemory.maxKeywords).map { $0 }
    }

    private static let metaWords: Set<String> = [
        "gespräch", "gespräche", "gesprächsverlauf", "gesprächspartner", "unterhaltung", "chat", "nachricht", "frage", "fragen",
        "antwort", "thema", "themen", "erinnerung", "erinnerungen", "interaktion", "zustand", "befinden", "ki", "nutzer",
    ]

    /// Facts about the user's life only: small models also file how the user behaves in the chat
    /// ("Der Nutzer ist neugierig auf die Gesprächsgeschichte").
    private static func isLifeFact(_ text: String, personaName: String) -> Bool {
        let lowered = text.lowercased()
        let conversation = ["gespräch", "unterhaltung", "interaktion", "chat", "gesprächspartner", "erinnert sich", "fragt nach"]
        return !conversation.contains { lowered.contains($0) } && lowered.range(of: #"\bki\b"#, options: .regularExpression) == nil
            && (personaName.isEmpty || !lowered.contains(personaName.lowercased()))
    }
}
