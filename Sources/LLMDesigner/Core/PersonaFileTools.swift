import Foundation

/// The tools a persona with files gets: `search_files` finds the best passages, `read_file` reads a file in parts.
/// Files are not put into the system prompt; the model looks things up when a question needs them.
struct PersonaFileTools: Sendable {
    static let searchName = "search_files"
    static let readName = "read_file"
    static let names: Set<String> = [searchName, readName]

    /// One part of `read_file`; search hits say which part they are in, so the model can read around them.
    static let partLength = 3_000
    /// Passages a search compares and returns.
    static let passageLength = 700
    static let hitsPerSearch = 4

    /// A file the model can search and read: one of the persona's, or a document attached to the chat.
    struct Entry: Sendable {
        let name: String
        /// Shown as the source of a step.
        let url: String
        let isAttachment: Bool
        let text: @Sendable () -> String
    }

    let files: [Entry]

    init?(persona: Persona) {
        self.init(persona: persona, documents: [])
    }

    /// The persona's files and the chat's documents that don't fit into the chat whole.
    init?(persona: Persona?, documents: [DocumentAttachment]) {
        var entries: [Entry] = []
        if let persona {
            let personaID = persona.id
            for file in persona.files ?? [] {
                entries.append(Entry(name: file.name, url: PersonaStore.fileURL(file, of: personaID).absoluteString, isAttachment: false) {
                    PersonaStore.text(of: file, personaID: personaID)
                })
            }
        }
        for document in documents {
            entries.append(Entry(name: document.name, url: DocumentStore.originalURL(of: document).absoluteString, isAttachment: true) {
                DocumentPrompt.fullText(of: document)
            })
        }
        guard !entries.isEmpty else { return nil }
        files = entries
    }

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.searchName,
                description: "Search your files and the documents attached to this chat. Returns the best matching passages with file name and part number.",
                parameters: [
                    "query": .init(type: "string", description: "A few search terms: names, topics or words that should appear in the passage."),
                ]
            ),
            ToolDefinition(
                name: Self.readName,
                description: "Read one of your files or attached documents. Long files come in parts; without `part` you get part 1 and the number of parts.",
                parameters: [
                    "name": .init(type: "string", description: "File name, as listed in the system prompt or in search results."),
                    "part": .init(type: "integer", description: "Optional: which part to read, starting at 1."),
                ],
                required: ["name"]
            ),
        ]
    }

    /// Added to the system prompt, so the model knows the files exist and when to look into them.
    var systemHint: String {
        let own = files.filter { !$0.isAttachment }.map { "„\($0.name)“" }
        let attached = files.filter(\.isAttachment).map { "„\($0.name)“" }
        var lines: [String] = []
        if !own.isEmpty { lines.append("Zu dir gehören Dateien, in denen du nachschauen kannst: \(own.joined(separator: ", ")).") }
        if !attached.isEmpty {
            lines.append("Im Chat hängen Dokumente, von denen nur der Anfang mitkommt: \(attached.joined(separator: ", ")). Den Rest findest du mit diesen Werkzeugen.")
        }
        lines.append("- \(Self.searchName)(query): durchsucht diese Dateien und liefert die passendsten Stellen.")
        lines.append("- \(Self.readName)(name, part): liest eine Datei; lange Dateien kommen in Teilen.")
        lines.append(own.isEmpty
            ? "Schau in den Dokumenten nach, wenn eine Frage sie betreffen könnte, statt etwas zu erfinden."
            : "Schau in deinen Dateien nach, wenn eine Frage sie betreffen könnte, statt etwas zu erfinden. Erzähl dann ganz natürlich, was darin steht.")
        return lines.joined(separator: "\n")
    }

    /// The step shown in the chat for a call, or nil if it is not one of the file tools.
    func step(for call: ToolCall) -> ToolStep? {
        let values = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
        func string(_ key: String) -> String {
            if let text = values[key] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let number = values[key] as? NSNumber { return number.stringValue }
            return ""
        }
        switch call.function.name {
        case Self.searchName:
            let query = string("query")
            return ToolStep(kind: .fileSearch, argument: query.isEmpty ? (values.values.first as? String ?? "") : query)
        case Self.readName:
            let part = string("part")
            return ToolStep(kind: .fileRead, argument: string("name"), section: part.isEmpty ? nil : part)
        default:
            return nil
        }
    }

    /// Carries out a step. Returns the finished step for the chat and the text for the model, cut to `limit` characters.
    func execute(_ step: ToolStep, limit: Int) async -> (ToolStep, String) {
        let tools = self
        return await Task.detached(priority: .userInitiated) {
            tools.run(step, limit: limit)
        }.value
    }

    private func run(_ step: ToolStep, limit: Int) -> (ToolStep, String) {
        var step = step
        guard !step.argument.isEmpty else {
            step.status = .failed
            step.error = "Leere Anfrage"
            return (step, step.kind == .fileSearch ? "Fehler: Der Aufruf enthielt keine Suchbegriffe." : "Fehler: Der Aufruf enthielt keinen Dateinamen. Verfügbar: \(fileList).")
        }
        switch step.kind {
        case .fileSearch:
            let hits = search(step.argument)
            step.status = .done
            step.sources = hits.map { hit in
                WebSource(title: "\(hit.file.name) · Teil \(hit.part)", url: fileURL(hit.file), snippet: String(hit.text.prefix(240)))
            }
            guard !hits.isEmpty else {
                return (step, "Keine Stelle in deinen Dateien passt zu „\(step.argument)“. Versuche andere Begriffe oder lies eine Datei mit \(Self.readName). Verfügbar: \(fileList).")
            }
            let entries = hits.enumerated().map { index, hit in
                "[\(index + 1)] \(hit.file.name), Teil \(hit.part) von \(hit.partCount)\n\(hit.text)"
            }
            let output = "Stellen in deinen Dateien zu „\(step.argument)“:\n\n" + entries.joined(separator: "\n\n")
                + "\n\nMehr Zusammenhang liefert \(Self.readName)(name, part)."
            return (step, Self.truncate(output, limit: limit))
        case .fileRead:
            guard let file = file(named: step.argument) else {
                step.status = .failed
                step.error = "Keine Datei „\(step.argument)“"
                return (step, "Fehler: Eine Datei „\(step.argument)“ gibt es nicht. Verfügbar: \(fileList).")
            }
            let text = file.text()
            let parts = Self.segments(of: text, maxLength: Self.partLength)
            let requested = Int(step.section ?? "") ?? 1
            let number = min(max(requested, 1), max(parts.count, 1))
            step.argument = file.name
            step.section = parts.count > 1 ? String(number) : nil
            step.status = .done
            step.sources = [WebSource(title: parts.count > 1 ? "\(file.name) · Teil \(number) von \(parts.count)" : file.name, url: fileURL(file))]
            guard !parts.isEmpty else { return (step, "Die Datei „\(file.name)“ ist leer.") }
            var header = "Datei: \(file.name)"
            if parts.count > 1 { header += " · Teil \(number) von \(parts.count)" }
            if requested > parts.count { header += " (einen Teil \(requested) gibt es nicht)" }
            return (step, Self.truncate(header + "\n\n" + String(text[parts[number - 1]]), limit: limit))
        default:
            step.status = .failed
            return (step, "Fehler: unbekanntes Werkzeug.")
        }
    }

    // MARK: Search

    private struct Hit {
        let file: Entry
        let text: String
        let part: Int
        let partCount: Int
        let score: Double
    }

    /// Ranks passages by how often and how many of the search terms they contain (rare terms count more).
    /// Terms also match inside longer words, which suits German compounds ("Haus" finds "Gartenhaus").
    private func search(_ query: String) -> [Hit] {
        let terms = Self.terms(of: query)
        guard !terms.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        struct Passage {
            let file: Entry
            let text: String
            let lowered: String
            let part: Int
            let partCount: Int
        }
        var passages: [Passage] = []
        for file in files {
            let text = file.text()
            let parts = Self.segments(of: text, maxLength: Self.partLength)
            for range in Self.segments(of: text, maxLength: Self.passageLength) {
                let part = (parts.firstIndex { $0.contains(range.lowerBound) } ?? 0) + 1
                let passage = String(text[range])
                passages.append(Passage(file: file, text: passage, lowered: passage.lowercased(), part: part, partCount: parts.count))
            }
        }
        guard !passages.isEmpty else { return [] }

        let documentFrequency = terms.map { term in Double(passages.filter { $0.lowered.contains(term) }.count) }
        let count = Double(passages.count)
        let hits = passages.compactMap { passage -> Hit? in
            var score = 0.0
            var found = 0
            for (term, frequency) in zip(terms, documentFrequency) {
                let occurrences = passage.lowered.components(separatedBy: term).count - 1
                guard occurrences > 0 else { continue }
                found += 1
                score += log(1 + count / frequency) * (1 + log(Double(occurrences)))
            }
            guard score > 0 else { return nil }
            if found == terms.count && terms.count > 1 { score *= 1.5 }
            if phrase.count > 3, passage.lowered.contains(phrase) { score += 2 }
            return Hit(file: passage.file, text: passage.text, part: passage.part, partCount: passage.partCount, score: score)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(Self.hitsPerSearch))
    }

    private static let stopWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines", "einem", "einen", "und", "oder", "aber",
        "mit", "von", "für", "auf", "aus", "bei", "nach", "über", "unter", "vor", "zum", "zur", "ist", "sind", "war", "wie",
        "was", "wer", "wann", "warum", "the", "and", "for", "with", "from", "that", "this", "what", "who", "when",
    ]

    private static func terms(of query: String) -> [String] {
        var seen: Set<String> = []
        return query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Files

    private var fileList: String {
        files.map { "„\($0.name)“" }.joined(separator: ", ")
    }

    /// The file the model means: exact name, then without case, then a name containing what it wrote.
    private func file(named name: String) -> Entry? {
        let wanted = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“ "))
        if let exact = files.first(where: { $0.name == wanted }) { return exact }
        if let folded = files.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return folded }
        let stem = (wanted as NSString).deletingPathExtension
        return files.first { $0.name.localizedStandardContains(stem) } ?? files.first { stem.localizedStandardContains(($0.name as NSString).deletingPathExtension) }
    }

    private func fileURL(_ file: Entry) -> String {
        file.url
    }

    /// Splits text into pieces of at most `maxLength` characters, at paragraph or line boundaries where possible.
    static func segments(of text: String, maxLength: Int) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let limit = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex), limit < text.endIndex else {
                result.append(start..<text.endIndex)
                break
            }
            let window = text[start..<limit]
            // Prefer a blank line, then a line break, then a sentence end in the second half of the window.
            let half = text.index(start, offsetBy: maxLength / 2)
            var end = limit
            if let paragraph = window.range(of: "\n\n", options: .backwards), paragraph.lowerBound > half {
                end = paragraph.upperBound
            } else if let line = window.lastIndex(of: "\n"), line > half {
                end = text.index(after: line)
            } else if let sentence = window.range(of: ". ", options: .backwards), sentence.lowerBound > half {
                end = sentence.upperBound
            }
            result.append(start..<end)
            start = end
        }
        return result.filter { !text[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[… gekürzt]"
    }
}
