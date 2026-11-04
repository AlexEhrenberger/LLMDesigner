import Foundation

/// The lookup tools the model may call while answering. Which ones it gets depends on the buttons
/// the user switched on in the composer: the globe offers `web_search` (DuckDuckGo) and `open_page`,
/// the W offers `wikipedia_search` and `wikipedia_article`.
enum WebTools {
    struct Sources: OptionSet, Sendable {
        let rawValue: Int
        static let web = Sources(rawValue: 1)
        static let wikipedia = Sources(rawValue: 2)
    }

    static let searchName = "web_search"
    static let openPageName = "open_page"
    static let wikiSearchName = "wikipedia_search"
    static let wikiArticleName = "wikipedia_article"

    /// Rounds in which the model may call tools; after that it has to answer with what it found.
    static let maxRounds = 5
    /// Calls per round that are carried out; further ones are answered with a short refusal.
    static let maxCallsPerRound = 3
    static let resultsPerSearch = 6

    static func definitions(for sources: Sources) -> [ToolDefinition] {
        var tools: [ToolDefinition] = []
        if sources.contains(.wikipedia) {
            tools += [
                ToolDefinition(
                    name: wikiSearchName,
                    description: "Search Wikipedia. Returns matching article titles with a short excerpt.",
                    parameters: [
                        "query": .init(type: "string", description: "Search terms or the name of the topic."),
                        "language": .init(type: "string", description: "Wikipedia edition, e.g. \"de\" or \"en\". Default: \"\(WikipediaClient.defaultLanguage)\"."),
                    ],
                    required: ["query"]
                ),
                ToolDefinition(
                    name: wikiArticleName,
                    description: "Read a Wikipedia article as plain text. Without `section` you get the beginning of the article "
                        + "and the list of its sections; with `section` you get that section.",
                    parameters: [
                        "title": .init(type: "string", description: "Exact article title, usually one from wikipedia_search."),
                        "language": .init(type: "string", description: "Wikipedia edition, e.g. \"de\" or \"en\". Default: \"\(WikipediaClient.defaultLanguage)\"."),
                        "section": .init(type: "string", description: "Optional: title of the section to read, e.g. \"Geschichte\"."),
                    ],
                    required: ["title"]
                ),
            ]
        }
        if sources.contains(.web) {
            tools += [
                ToolDefinition(
                    name: searchName,
                    description: "Search the web. Returns the top results with title, URL, date and a short excerpt. "
                        + "Use it for current events, news, prices, versions, dates and facts you are not sure about.",
                    parameters: [
                        "query": .init(type: "string", description: "Search terms, short and specific, in the language that will find the best sources."),
                    ]
                ),
                ToolDefinition(
                    name: openPageName,
                    description: "Open a web page or PDF and return its main text. Use it when the search excerpts are not enough.",
                    parameters: [
                        "url": .init(type: "string", description: "Full address of the page, exactly as it appears in a search result or in the person's message. Other addresses are refused."),
                    ]
                ),
            ]
        }
        return tools
    }

    /// Added to the system prompt when tools are offered; small models need the date to judge what is "current".
    static func systemHint(for sources: Sources, now: Date = Date()) -> String {
        let date = now.formatted(date: .complete, time: .omitted)
        let time = now.formatted(date: .omitted, time: .shortened)
        var lines = ["Heute ist \(date), \(time) Uhr.", "Du kannst nachschlagen:"]
        if sources.contains(.wikipedia) {
            lines.append("- \(wikiSearchName)(query, language): sucht Artikel in Wikipedia (Standard \"\(WikipediaClient.defaultLanguage)\", für internationale Themen auch \"en\").")
            lines.append("- \(wikiArticleName)(title, language, section): liest einen Artikel; ohne section kommen der Anfang und die Liste der Abschnitte, mit section ein bestimmter Abschnitt.")
        }
        if sources.contains(.web) {
            lines.append("- \(searchName)(query): Websuche, liefert Titel, Adresse und Ausschnitt der besten Treffer.")
            lines.append("- \(openPageName)(url): liest eine Seite oder ein PDF als Text.")
        }
        switch sources {
        case .wikipedia:
            lines.append("Die Person hat ausdrücklich die Wikipedia-Suche eingeschaltet: Schlage Sachfragen in Wikipedia nach, bevor du antwortest, und lies den passenden Artikel. Für Begrüßungen, Rechnen, Schreiben oder Code brauchst du keine Suche.")
        case .web:
            lines.append("Suche, wenn die Frage aktuelle Ereignisse, Preise, Versionen, Termine oder Fakten betrifft, bei denen du dir nicht sicher bist. Für allgemeines Wissen, Rechnen, Schreiben oder Code brauchst du keine Suche.")
            lines.append("Reichen die Ausschnitte nicht, öffne die ein bis zwei vielversprechendsten Treffer mit \(openPageName).")
        default:
            lines.append("Für Begriffe, Personen, Orte, Geschichte und Wissenschaft nimm Wikipedia, für Aktuelles wie Nachrichten, Preise und Versionen die Websuche. Für Rechnen, Schreiben oder Code brauchst du keine Suche.")
        }
        lines.append("Stütze die Antwort auf das Gefundene und nenne die genutzten Quellen als Markdown-Links, z. B. [Wikipedia: Berlin](https://de.wikipedia.org/wiki/Berlin).")
        return lines.joined(separator: "\n")
    }

    /// The step shown in the chat for a call, or nil when the model asked for a tool it wasn't given.
    static func step(for call: ToolCall, allowed: Sources) -> ToolStep? {
        let values = arguments(call.function.arguments)
        let isWikipedia = call.function.name == wikiSearchName || call.function.name == wikiArticleName
        guard allowed.contains(isWikipedia ? .wikipedia : .web) else { return nil }
        switch call.function.name {
        case searchName:
            return ToolStep(kind: .search, argument: values.main("query"))
        case openPageName:
            return ToolStep(kind: .openPage, argument: values.main("url"))
        case wikiSearchName:
            return ToolStep(kind: .wikiSearch, argument: values.main("query"), language: WikipediaClient.language(values["language"]))
        case wikiArticleName:
            let section = values["section"].flatMap { $0.isEmpty ? nil : $0 }
            return ToolStep(kind: .wikiArticle, argument: values.main("title"), language: WikipediaClient.language(values["language"]), section: section)
        default:
            return nil
        }
    }

    static func unknownToolOutput(_ call: ToolCall, available tools: [ToolDefinition]) -> String {
        let names = tools.map(\.function.name).joined(separator: ", ")
        return "Fehler: Das Werkzeug „\(call.function.name)“ gibt es nicht. Verfügbar sind: \(names)."
    }

    static let skippedOutput = "Übersprungen: zu viele Aufrufe auf einmal. Rufe höchstens \(maxCallsPerRound) Werkzeuge gleichzeitig auf."
    static let budgetExhaustedOutput = "Nicht ausgeführt: Der Kontext des Modells ist mit Suchergebnissen gefüllt. Antworte jetzt mit dem, was du gefunden hast."

    /// Carries out a step. Returns the finished step for the chat and the text that goes back to the model,
    /// cut to `limit` characters.
    static func execute(_ step: ToolStep, limit: Int, readerFallback: Bool) async -> (ToolStep, String) {
        var step = step
        guard !step.argument.isEmpty else {
            step.status = .failed
            step.error = "Leere Anfrage"
            let missing = switch step.kind {
            case .search, .wikiSearch, .fileSearch: "Suchanfrage"
            case .openPage: "Adresse"
            case .wikiArticle: "Artikeltitel"
            case .fileRead: "Dateiname"
            case .action: "Action"
            }
            return (step, "Fehler: Der Aufruf enthielt keine \(missing).")
        }
        do {
            let output: String
            switch step.kind {
            case .search:
                let results = try await DuckDuckGoSearch().search(step.argument, limit: resultsPerSearch)
                step.sources = results
                output = searchOutput(query: step.argument, results: results)
            case .openPage:
                let page = try await PageReader(useReaderFallback: readerFallback).read(step.argument)
                step.sources = [WebSource(title: page.title ?? page.url, url: page.url)]
                output = pageOutput(page)
            case .wikiSearch:
                let language = step.language ?? WikipediaClient.defaultLanguage
                let result = try await WikipediaClient().search(step.argument, language: language, limit: resultsPerSearch)
                step.sources = result.hits
                output = wikiSearchOutput(query: step.argument, language: language, result: result)
            case .wikiArticle:
                let article = try await WikipediaClient().article(step.argument, language: step.language ?? WikipediaClient.defaultLanguage)
                let (source, text) = wikiArticleOutput(article, section: step.section)
                step.sources = [source]
                output = text
            case .fileSearch, .fileRead, .action:
                // Files are read by `PersonaFileTools`, actions by `ChatActionTools`; such steps never come here.
                output = ""
            }
            step.status = .done
            return (step, truncate(output, limit: limit))
        } catch {
            step.status = .failed
            step.error = Task.isCancelled ? "Abgebrochen" : error.localizedDescription
            var output = "Fehler: \(step.error ?? "unbekannt")"
            if step.kind == .wikiArticle { output += " Suche den genauen Titel mit \(wikiSearchName)." }
            return (step, output)
        }
    }

    /// An earlier answer as it goes into the next request: the text plus the addresses it was based on,
    /// so the model can open them again in a follow-up question. The full results are not repeated.
    static func historyContent(of message: ChatMessage) -> String {
        // A persona's files are offered again with every question anyway.
        let sources = (message.toolSteps ?? []).filter { !$0.kind.isFile && $0.kind != .action }.flatMap { step in
            step.kind.readsPage ? (step.sources ?? []) : Array((step.sources ?? []).prefix(3))
        }
        var seen: Set<String> = []
        let lines = sources.filter { seen.insert($0.url).inserted }.prefix(8).map { "- \($0.title): \($0.url)" }
        guard !lines.isEmpty else { return message.content }
        return message.content + "\n\n(Nachgeschlagene Quellen zu dieser Antwort:\n" + lines.joined(separator: "\n") + ")"
    }

    // MARK: - Private

    /// The arguments as strings. Small models sometimes pick another key or skip the JSON altogether;
    /// `main` then falls back to any other string value or the raw text.
    private struct Arguments {
        var values: [String: String]
        var raw: String

        subscript(key: String) -> String? { values[key] }

        func main(_ key: String) -> String {
            if let value = values[key] { return value }
            let others = values.filter { $0.key != "language" && $0.key != "section" }
            if let value = others.values.first { return value }
            return raw.hasPrefix("{") ? "" : raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
    }

    private static func arguments(_ json: String) -> Arguments {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String: String] = [:]
        if let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String { values[key] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return Arguments(values: values, raw: trimmed)
    }

    private static func searchOutput(query: String, results: [WebSource]) -> String {
        guard !results.isEmpty else {
            return "Keine Treffer für „\(query)“. Versuche andere oder allgemeinere Suchbegriffe."
        }
        let entries = results.enumerated().map { index, result in
            var lines = ["[\(index + 1)] \(result.title)", "URL: \(result.url)"]
            if let date = result.date { lines.append("Datum: \(date)") }
            if let snippet = result.snippet { lines.append(snippet) }
            return lines.joined(separator: "\n")
        }
        return "Suchergebnisse für „\(query)“:\n\n" + entries.joined(separator: "\n\n")
    }

    private static func pageOutput(_ page: PageReader.Page) -> String {
        var header = "Seite: \(page.url)"
        if let title = page.title { header += "\nTitel: \(title)" }
        return header + "\n\n" + page.text
    }

    private static func wikiSearchOutput(query: String, language: String, result: WikipediaClient.SearchResult) -> String {
        guard !result.hits.isEmpty else {
            var text = "Keine Wikipedia-Artikel (\(language)) für „\(query)“."
            if let suggestion = result.suggestion { text += " Wikipedia schlägt „\(suggestion)“ vor." }
            return text + " Versuche andere Suchbegriffe oder language \"en\"."
        }
        let entries = result.hits.enumerated().map { index, hit in
            ["[\(index + 1)] \(hit.title)", hit.snippet].compactMap { $0 }.joined(separator: "\n")
        }
        return "Wikipedia-Artikel (\(language)) für „\(query)“:\n\n" + entries.joined(separator: "\n\n")
            + "\n\nLies einen Artikel mit \(wikiArticleName)(title)."
    }

    private static func wikiArticleOutput(_ article: WikipediaClient.Article, section: String?) -> (WebSource, String) {
        var header = "Wikipedia-Artikel: \(article.title) (\(article.language))\nURL: \(article.url)"
        if let section, let part = article.section(named: section) {
            let url = WikipediaClient.articleURL(title: article.title, language: article.language, section: part.title)
            header += "\nAbschnitt: \(part.title)"
            let source = WebSource(title: "\(article.title) › \(part.title)", url: url)
            return (source, header + "\n\n" + (part.text.isEmpty ? "(Der Abschnitt enthält keinen Text.)" : part.text))
        }

        let outline = article.outline
        if !outline.isEmpty {
            header += "\nAbschnitte (einzeln lesbar mit section):\n" + outline.joined(separator: "\n")
        }
        if let section {
            header += "\n\nEinen Abschnitt „\(section)“ gibt es nicht; hier der Anfang des Artikels."
        }
        return (WebSource(title: article.title, url: article.url), header + "\n\n" + article.fullText)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        // End at a line or sentence boundary when one is close.
        let boundary = cut.lastIndex(of: "\n").flatMap { cut.distance(from: $0, to: cut.endIndex) < 600 ? $0 : nil }
        let kept = cut[..<(boundary ?? cut.endIndex)]
        return kept + "\n\n[… gekürzt, \(text.count - kept.count) weitere Zeichen]"
    }
}
