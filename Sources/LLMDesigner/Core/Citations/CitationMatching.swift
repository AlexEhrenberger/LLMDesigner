import Foundation

/// A DOI, ISBN, arXiv ID or web address, recognised in whatever the user pastes into the import field.
enum CitationIdentifier: Equatable, Sendable {
    case doi(String)
    case isbn(String)
    case arxiv(String)
    case url(String)

    /// "10.1000/xyz", "doi:10.1000/xyz", "https://doi.org/10.1000/xyz", "978-3-16-148410-0", "arXiv:2401.01234v2",
    /// "https://arxiv.org/abs/2401.01234", "https://…".
    static func detect(_ text: String) -> CitationIdentifier? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let doi = normalizedDOI(text), !doi.isEmpty { return .doi(doi) }
        if let arxiv = normalizedArXiv(text) { return .arxiv(arxiv) }
        if let isbn = normalizedISBN(text) { return .isbn(isbn) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return .url(text)
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host?.contains(".") == true {
            return .url("https://" + text)
        }
        return nil
    }

    /// A DOI in lower case without its prefix ("https://doi.org/", "doi:"); nil if the text isn't one.
    static func normalizedDOI(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:", "DOI:", "DOI "] where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard text.hasPrefix("10."), let slash = text.firstIndex(of: "/"), slash < text.index(before: text.endIndex),
              text[text.index(text.startIndex, offsetBy: 3)..<slash].allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }

    /// An ISBN as 13 digits (an ISBN-10 is converted); nil if the check digit doesn't fit.
    static func normalizedISBN(_ text: String) -> String? {
        var text = text.uppercased()
        if text.hasPrefix("ISBN") { text = String(text.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: ":- ")) }
        guard text.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " || $0 == "X" }) else { return nil }
        let characters = text.filter { $0.isNumber || $0 == "X" }
        if characters.count == 13, characters.allSatisfy(\.isNumber) {
            let digits = characters.compactMap(\.wholeNumberValue)
            let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0 ? String(characters) : nil
        }
        if characters.count == 10 {
            let values = characters.enumerated().compactMap { index, character -> Int? in
                character == "X" ? (index == 9 ? 10 : nil) : character.wholeNumberValue
            }
            guard values.count == 10 else { return nil }
            let sum = values.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) }
            guard sum % 11 == 0 else { return nil }
            let body = "978" + String(characters.prefix(9))
            let digits = body.compactMap(\.wholeNumberValue)
            let check = (10 - digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) } % 10) % 10
            return body + String(check)
        }
        return nil
    }

    /// "2401.01234" or "hep-th/9901001", without version; nil if the text isn't an arXiv ID.
    static func normalizedArXiv(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "arxiv.org/abs/", "arXiv:", "arxiv:"] where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".pdf") { text = String(text.dropLast(4)) }
        if let version = text.range(of: #"v\d+$"#, options: .regularExpression) { text = String(text[..<version.lowerBound]) }
        let modern = text.range(of: #"^\d{4}\.\d{4,5}$"#, options: .regularExpression) != nil
        let old = text.range(of: #"^[a-z\-]+(\.[A-Z]{2})?/\d{7}$"#, options: .regularExpression) != nil
        return modern || old ? text : nil
    }

    /// A web address for comparing: without scheme, "www.", fragment and trailing slash, host in lower case.
    static func normalizedURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host?.lowercased(), host.contains(".") else { return nil }
        components.fragment = nil
        let path = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path + query
    }
}

/// A source that may already be in the library.
struct CitationDuplicate: Equatable, Sendable {
    enum Reason: String, Sendable {
        case doi, isbn, arxiv, url, citekey, title

        var label: String {
            switch self {
            case .doi: "gleiche DOI"
            case .isbn: "gleiche ISBN"
            case .arxiv: "gleiche arXiv-ID"
            case .url: "gleiche Adresse"
            case .citekey: "gleicher Zitierschlüssel"
            case .title: "gleicher Titel und gleiches Jahr"
            }
        }
    }

    let sourceID: UUID
    let reasons: [Reason]
}

enum CitationMatching {
    /// Sources in `library` that look like `candidate` (itself excluded), with why.
    static func duplicates(of candidate: CitationSource, in library: [CitationSource]) -> [CitationDuplicate] {
        let doi = CitationIdentifier.normalizedDOI(candidate.doi)
        let isbn = CitationIdentifier.normalizedISBN(candidate.isbn)
        let arxiv = CitationIdentifier.normalizedArXiv(candidate.arxiv)
        let url = CitationIdentifier.normalizedURL(candidate.url)
        let key = candidate.citekey.lowercased()
        let title = titleKey(candidate)
        return library.compactMap { source in
            guard source.id != candidate.id else { return nil }
            var reasons: [CitationDuplicate.Reason] = []
            if let doi, doi == CitationIdentifier.normalizedDOI(source.doi) { reasons.append(.doi) }
            if let isbn, isbn == CitationIdentifier.normalizedISBN(source.isbn) { reasons.append(.isbn) }
            if let arxiv, arxiv == CitationIdentifier.normalizedArXiv(source.arxiv) { reasons.append(.arxiv) }
            if let url, url == CitationIdentifier.normalizedURL(source.url) { reasons.append(.url) }
            if !key.isEmpty, key == source.citekey.lowercased() { reasons.append(.citekey) }
            if let title, title == titleKey(source) { reasons.append(.title) }
            return reasons.isEmpty ? nil : CitationDuplicate(sourceID: source.id, reasons: reasons)
        }
    }

    /// Title and year without case, accents and punctuation; nil for a short or missing title.
    private static func titleKey(_ source: CitationSource) -> String? {
        let words = source.fullTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { Citekey.fold(String($0)) }.filter { !$0.isEmpty }
        guard words.joined().count >= 8 else { return nil }
        return words.joined(separator: " ") + "|" + (source.year.map(String.init) ?? "")
    }
}

// MARK: - Search

/// What the search field means: words (all must appear), `#tag`, `@autor`, a year (`2021`) or a range
/// (`2010-2020`), and `typ:buch`.
struct CitationQuery: Equatable, Sendable {
    var words: [String] = []
    var tags: [String] = []
    var authors: [String] = []
    var years: ClosedRange<Int>?
    var type: SourceType?

    init(_ text: String) {
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("#"), token.count > 1 {
                tags.append(Self.fold(String(token.dropFirst())))
            } else if token.hasPrefix("@"), token.count > 1 {
                authors.append(Self.fold(String(token.dropFirst())))
            } else if token.lowercased().hasPrefix("typ:") {
                let name = Self.fold(String(token.dropFirst(4)))
                type = SourceType.allCases.first { Self.fold($0.label).hasPrefix(name) || $0.rawValue.hasPrefix(name) }
            } else if let year = Int(token), (1000...2999).contains(year) {
                years = year...year
            } else if let range = token.range(of: #"^\d{4}[-–]\d{4}$"#, options: .regularExpression), range.lowerBound == token.startIndex,
                      let low = Int(token.prefix(4)), let high = Int(token.suffix(4)), low <= high {
                years = low...high
            } else {
                let word = Self.fold(token)
                if !word.isEmpty { words.append(word) }
            }
        }
    }

    var isEmpty: Bool { words.isEmpty && tags.isEmpty && authors.isEmpty && years == nil && type == nil }

    /// Lower case without accents; umlauts stay comparable both ways ("müller" finds "Müller" and "Mueller").
    static func fold(_ text: String) -> String {
        Citekey.fold(text)
    }
}

/// Folded text of sources and quotes, made once per change, so searching thousands of entries stays instant.
struct CitationSearchIndex: Sendable {
    struct SourceEntry: Sendable {
        let text: String
        let authors: [String]
        let tags: [String]
        let year: Int?
        let type: SourceType
    }

    struct QuoteEntry: Sendable {
        let sourceID: UUID
        let text: String
        let tags: [String]
    }

    private(set) var sources: [UUID: SourceEntry] = [:]
    private(set) var quotes: [UUID: QuoteEntry] = [:]

    init(sources: [CitationSource], quotes: [CitationQuote]) {
        for source in sources { update(source) }
        for quote in quotes { update(quote) }
    }

    mutating func update(_ source: CitationSource) {
        let people = (source.authors + source.editors)
        let text = ([source.citekey, source.fullTitle, source.container, source.publisher, source.place, source.notes, source.abstract, source.doi, source.isbn, source.url]
                    + people.map(\.displayName) + source.tags + [source.year.map(String.init) ?? ""])
            .map(Self.searchable).joined(separator: " ")
        sources[source.id] = SourceEntry(text: text, authors: people.map { Self.searchable($0.displayName) },
                                         tags: source.tags.map(Citekey.fold), year: source.year, type: source.type)
    }

    mutating func update(_ quote: CitationQuote) {
        let text = [quote.exactText, quote.paraphrase, quote.page].map(Self.searchable).joined(separator: " ") + " " + quote.tags.map(Citekey.fold).joined(separator: " ")
        quotes[quote.id] = QuoteEntry(sourceID: quote.sourceID, text: text, tags: quote.tags.map(Citekey.fold))
    }

    mutating func removeSource(_ id: UUID) { sources[id] = nil }
    mutating func removeQuote(_ id: UUID) { quotes[id] = nil }

    /// Words folded and joined without punctuation, so "Müller-Lüdenscheidt" finds "lüdenscheidt".
    static func searchable(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { Citekey.fold(String($0)) }.joined(separator: " ")
    }

    struct Result: Equatable, Sendable {
        /// Sources that match themselves (or whose quotes match).
        var sourceIDs: [UUID]
        /// Quotes that match, by their source.
        var quoteIDs: [UUID]
    }

    /// A source matches when its own data contains every word; a quote when the quote (or its source) does.
    /// Tags must be on the quote or the source, authors and years on the source.
    func search(_ query: CitationQuery, order: [UUID], quoteOrder: [UUID]) -> Result {
        guard !query.isEmpty else { return Result(sourceIDs: order, quoteIDs: quoteOrder) }
        func sourceFits(_ entry: SourceEntry) -> Bool {
            if let years = query.years, !(entry.year.map(years.contains) ?? false) { return false }
            if let type = query.type, entry.type != type { return false }
            return query.authors.allSatisfy { author in entry.authors.contains { $0.contains(author) } }
        }
        var matchingQuotes: [UUID] = []
        var sourcesWithQuotes = Set<UUID>()
        for id in quoteOrder {
            guard let quote = quotes[id], let source = sources[quote.sourceID], sourceFits(source) else { continue }
            let tagsFit = query.tags.allSatisfy { tag in quote.tags.contains { $0.hasPrefix(tag) } || source.tags.contains { $0.hasPrefix(tag) } }
            // Words may be spread over the quote and its source ("müller nachts"), but at least one must be in the
            // quote itself, or every quote of a matching source would show up.
            let wordsFit = query.words.allSatisfy { quote.text.contains($0) || source.text.contains($0) }
                && (query.words.isEmpty || query.words.contains { quote.text.contains($0) })
            if tagsFit, wordsFit {
                matchingQuotes.append(id)
                sourcesWithQuotes.insert(quote.sourceID)
            }
        }
        let matchingSources = order.filter { id in
            guard let source = sources[id], sourceFits(source) else { return false }
            if sourcesWithQuotes.contains(id) { return true }
            let tagsFit = query.tags.allSatisfy { tag in source.tags.contains { $0.hasPrefix(tag) } }
            return tagsFit && query.words.allSatisfy { source.text.contains($0) }
        }
        return Result(sourceIDs: matchingSources, quoteIDs: matchingQuotes)
    }
}
