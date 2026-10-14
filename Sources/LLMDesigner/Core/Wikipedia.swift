import Foundation

enum WikipediaError: LocalizedError {
    case notFound(String)
    case http(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notFound(let title): "Kein Wikipedia-Artikel mit dem Titel „\(title)“."
        case .http(let status): "Wikipedia antwortet mit Status \(status)."
        case .unexpectedResponse: "Wikipedia hat eine unerwartete Antwort geliefert."
        }
    }
}

/// Wikipedia through the official MediaWiki API, which needs no key: full-text search and articles
/// as plain text (TextExtracts), split into sections so a small context can read one part at a time.
struct WikipediaClient: Sendable {
    struct SearchResult: Sendable {
        var hits: [WebSource]
        /// "Did you mean" from Wikipedia when the query looks misspelled.
        var suggestion: String?
    }

    struct Section: Sendable {
        var level: Int
        var title: String
        var text: String
    }

    struct Article: Sendable {
        var title: String
        var url: String
        var language: String
        /// The lead section has level 1 and an empty title.
        var sections: [Section]
    }

    /// Wikimedia asks API clients to identify themselves.
    private static let userAgent = "LLMDesigner/1.0 (macOS chat app for local language models)"

    static var defaultLanguage: String { Locale.current.language.languageCode?.identifier ?? "en" }

    /// The edition to use: the model's choice if it looks like a language code ("de", "en", "simple"), else the system language.
    static func language(_ requested: String?) -> String {
        let value = requested?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let valid = (2...12).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }
        return valid ? value : defaultLanguage
    }

    static func articleURL(title: String, language: String, section: String? = nil) -> String {
        func slug(_ text: String) -> String {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#")
            let underscored = text.replacingOccurrences(of: " ", with: "_")
            return underscored.addingPercentEncoding(withAllowedCharacters: allowed) ?? underscored
        }
        var url = "https://\(language).wikipedia.org/wiki/\(slug(title))"
        if let section, !section.isEmpty { url += "#" + slug(section) }
        return url
    }

    func search(_ query: String, language: String, limit: Int) async throws -> SearchResult {
        struct Response: Decodable {
            struct Query: Decodable {
                struct Info: Decodable { let suggestion: String? }
                struct Hit: Decodable {
                    let title: String
                    let snippet: String?
                }
                let searchinfo: Info?
                let search: [Hit]
            }
            let query: Query?
        }
        let data = try await request(language: language, [
            "action": "query", "list": "search", "srsearch": query,
            "srlimit": String(limit), "srprop": "snippet",
        ])
        guard let query = try JSONDecoder().decode(Response.self, from: data).query else { throw WikipediaError.unexpectedResponse }
        let hits = query.search.map { hit in
            let snippet = hit.snippet.map(HTMLText.plainText)
            return WebSource(
                title: hit.title,
                url: Self.articleURL(title: hit.title, language: language),
                snippet: snippet?.isEmpty == false ? snippet : nil
            )
        }
        return SearchResult(hits: hits, suggestion: query.searchinfo?.suggestion)
    }

    /// The whole article; redirects (e.g. "LLM" → "Large Language Model") are followed.
    func article(_ title: String, language: String) async throws -> Article {
        struct Response: Decodable {
            struct Query: Decodable {
                struct Page: Decodable {
                    let title: String
                    let extract: String?
                    let fullurl: String?
                    let missing: Bool?
                    let invalid: Bool?
                }
                let pages: [Page]
            }
            let query: Query?
        }
        let data = try await request(language: language, [
            "action": "query", "prop": "extracts|info", "inprop": "url", "redirects": "1",
            "explaintext": "1", "exsectionformat": "wiki", "titles": title,
        ])
        guard let page = try JSONDecoder().decode(Response.self, from: data).query?.pages.first else {
            throw WikipediaError.unexpectedResponse
        }
        guard page.missing != true, page.invalid != true, let extract = page.extract, !extract.isEmpty else {
            throw WikipediaError.notFound(title)
        }
        return Article(
            title: page.title,
            url: page.fullurl ?? Self.articleURL(title: page.title, language: language),
            language: language,
            sections: Self.sections(from: extract)
        )
    }

    /// Splits a TextExtracts plain text at its "== Heading ==" lines.
    static func sections(from extract: String) -> [Section] {
        var sections = [Section(level: 1, title: "", text: "")]
        var lines: [Substring] = []
        func closeSection() {
            sections[sections.count - 1].text = HTMLText.tidyLines(lines.joined(separator: "\n"))
            lines = []
        }
        for line in extract.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let level = trimmed.prefix { $0 == "=" }.count
            if level >= 2, trimmed.hasSuffix(String(repeating: "=", count: level)), trimmed.count > level * 2 {
                closeSection()
                let title = trimmed.dropFirst(level).dropLast(level).trimmingCharacters(in: .whitespaces)
                sections.append(Section(level: level, title: title, text: ""))
            } else {
                lines.append(line)
            }
        }
        closeSection()
        return sections
    }

    private func request(language: String, _ parameters: [String: String]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(language).wikipedia.org"
        components.path = "/w/api.php"
        components.queryItems = (parameters.merging(["format": "json", "formatversion": "2"]) { $1 })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, but MediaWiki would read it as a space ("C++").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw WikipediaError.unexpectedResponse }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw WikipediaError.http(status)
        }
        return data
    }
}

extension WikipediaClient.Article {
    /// Section titles of the article, indented by level, for the model to pick from.
    var outline: [String] {
        sections.dropFirst().map { String(repeating: "  ", count: max($0.level - 2, 0)) + $0.title }
    }

    /// The section that best matches `name` together with its subsections, or nil.
    func section(named name: String) -> (title: String, text: String)? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        let index = sections.indices.dropFirst().first { sections[$0].title.lowercased() == wanted }
            ?? sections.indices.dropFirst().first { sections[$0].title.lowercased().contains(wanted) }
            ?? sections.indices.dropFirst().first { wanted.contains(sections[$0].title.lowercased()) }
        guard let index else { return nil }
        let level = sections[index].level
        var parts = [sections[index].text]
        for next in sections[(index + 1)...] {
            if next.level <= level { break }
            parts.append("\(String(repeating: "#", count: next.level)) \(next.title)\n\n\(next.text)")
        }
        return (sections[index].title, parts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// The whole article as Markdown-like text; headings of empty sections (e.g. "Weblinks") are left out.
    var fullText: String {
        sections.enumerated().compactMap { index, section in
            if index == 0 { return section.text.isEmpty ? nil : section.text }
            let hasContent = !section.text.isEmpty
                || sections[(index + 1)...].prefix { $0.level > section.level }.contains { !$0.text.isEmpty }
            guard hasContent else { return nil }
            let heading = "\(String(repeating: "#", count: section.level)) \(section.title)"
            return section.text.isEmpty ? heading : heading + "\n\n" + section.text
        }
        .joined(separator: "\n\n")
    }
}
