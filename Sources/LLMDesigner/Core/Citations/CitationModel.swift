import Foundation

// Citation Studio keeps two kinds of things apart: sources (a book, an article, a web page) and quotes, the
// atomic pieces of knowledge taken from them (a sentence word for word, the user's own paraphrase, a page,
// tags). Quotes belong to exactly one source; they can point at each other.

/// A person (or an institution) as a source names them. Family and given names are kept apart, so styles can
/// write "Müller, A." or "Anna Müller", and sort by family name.
struct PersonName: Codable, Hashable, Sendable {
    var family: String
    var given: String = ""
    /// "von", "van", "de": written before the family name, but not sorted by it.
    var particle: String = ""
    /// An organisation, written as it is ("Statistisches Bundesamt").
    var isInstitution = false

    init(family: String, given: String = "", particle: String = "", isInstitution: Bool = false) {
        self.family = family
        self.given = given
        self.particle = particle
        self.isInstitution = isInstitution
    }

    private static let particles: Set<String> = ["von", "van", "de", "der", "den", "zu", "zur", "vom", "di", "da", "du", "la", "le", "dos", "del", "ter", "ten"]

    /// Reads "Müller, Anna", "Anna Müller", "Johann Wolfgang von Goethe", "Goethe, Johann Wolfgang von" and
    /// "{Statistisches Bundesamt}" (braces or `institution: true` keep a name whole).
    static func parse(_ text: String, institution: Bool = false) -> PersonName {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if institution || (text.hasPrefix("{") && text.hasSuffix("}")) {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            return PersonName(family: text, isInstitution: true)
        }
        if let comma = text.firstIndex(of: ",") {
            let family = text[..<comma].trimmingCharacters(in: .whitespaces)
            var given = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            // "Goethe, Johann Wolfgang von": the particle comes last.
            var particle = ""
            let words = given.split(separator: " ").map(String.init)
            if let last = words.last, words.count > 1, particles.contains(last) {
                particle = last
                given = words.dropLast().joined(separator: " ")
            }
            let familyWords = family.split(separator: " ").map(String.init)
            if familyWords.count > 1, particles.contains(familyWords[0]) {
                return PersonName(family: familyWords.drop { particles.contains($0) }.joined(separator: " "), given: given,
                                  particle: familyWords.prefix { particles.contains($0) }.joined(separator: " "))
            }
            return PersonName(family: family, given: given, particle: particle)
        }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return PersonName(family: text) }
        // The family name is the last word, together with particles right before it.
        var start = words.count - 1
        while start > 1, particles.contains(words[start - 1]) { start -= 1 }
        let particle = words[start..<(words.count - 1)].joined(separator: " ")
        return PersonName(family: words[words.count - 1], given: words[..<start].joined(separator: " "), particle: particle)
    }

    /// "Anna Müller", "Johann Wolfgang von Goethe".
    var displayName: String {
        guard !isInstitution else { return family }
        return [given, particle, family].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Müller, Anna", "Goethe, Johann Wolfgang von".
    var sortName: String {
        guard !isInstitution, !given.isEmpty || !particle.isEmpty else { return family }
        return family + ", " + [given, particle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "von Goethe": what a citation in the text shows.
    var citationName: String {
        isInstitution || particle.isEmpty ? family : particle + " " + family
    }

    /// "A.", "J. W.", "H.-P." for Hans-Peter.
    var initials: String {
        given.split(separator: " ").map { word in
            word.split(separator: "-").compactMap { $0.first.map { "\($0)." } }.joined(separator: "-")
        }.joined(separator: " ")
    }

    var isEmpty: Bool { family.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// What kind of source it is; the citation styles write each kind differently.
enum SourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case book, chapter, article, paper, thesis, report, web, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .book: "Buch"
        case .chapter: "Beitrag im Sammelband"
        case .article: "Zeitschriftenartikel"
        case .paper: "Paper / Preprint"
        case .thesis: "Abschlussarbeit"
        case .report: "Bericht"
        case .web: "Webseite"
        case .other: "Sonstiges"
        }
    }

    var symbol: String {
        switch self {
        case .book: "book.closed"
        case .chapter: "book.pages"
        case .article: "newspaper"
        case .paper: "doc.text"
        case .thesis: "graduationcap"
        case .report: "chart.bar.doc.horizontal"
        case .web: "globe"
        case .other: "doc"
        }
    }

    /// What `container` means for this kind, for the form.
    var containerLabel: String {
        switch self {
        case .chapter: "Sammelband"
        case .article: "Zeitschrift"
        case .paper: "Konferenz / Archiv"
        case .web: "Website"
        case .thesis: "Hochschule"
        default: "Reihe"
        }
    }
}

/// A file that belongs to a source, inside the library (`Zitate/Anhänge/<Quelle>/…`).
struct CitationAttachment: Codable, Hashable, Sendable {
    /// The file name inside the source's attachment folder.
    var fileName: String
    var addedAt = Date()
}

/// A source: everything needed to cite it.
struct CitationSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// The key the text cites it by (`mueller2026`); unique in the library.
    var citekey = ""
    var type: SourceType = .book
    var title = ""
    var subtitle = ""
    var authors: [PersonName] = []
    var editors: [PersonName] = []
    /// nil: no year ("o. J.").
    var year: Int?
    /// A finer date where it matters (newspaper, web page): "2026-10-15" or "2026-10".
    var date = ""
    /// The journal, the edited volume, the conference or the website it appeared in.
    var container = ""
    /// The publisher or the institution.
    var publisher = ""
    /// Place of publication (Verlagsort).
    var place = ""
    var edition = ""
    var volume = ""
    var issue = ""
    /// The pages of an article or chapter: "123–145".
    var pages = ""
    var doi = ""
    var isbn = ""
    var url = ""
    var arxiv = ""
    /// When a web page was read.
    var accessed: Date?
    var language = ""
    var abstract = ""
    var notes = ""
    /// Tags of the whole source; quotes have their own.
    var tags: [String] = []
    var attachments: [CitationAttachment] = []
    var createdAt = Date()
    var updatedAt = Date()

    /// Title and subtitle as one line.
    var fullTitle: String {
        let subtitle = subtitle.trimmingCharacters(in: .whitespaces)
        guard !subtitle.isEmpty else { return title }
        let title = title.trimmingCharacters(in: .whitespaces)
        return title.last.map { ".:?!".contains($0) } == true ? "\(title) \(subtitle)" : "\(title): \(subtitle)"
    }

    /// The people a citation names: the authors, else the editors.
    var creators: [PersonName] { authors.isEmpty ? editors : authors }

    var yearText: String { year.map(String.init) ?? "o. J." }
}

/// A piece of knowledge from a source: the exact words, the user's own thought about them, where they are,
/// and tags. Quotes can point at other quotes.
struct CitationQuote: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceID: UUID
    /// The words as they are in the source.
    var exactText = ""
    /// The user's own summary or thought.
    var paraphrase = ""
    /// "12", "12–14", "Kap. 3", "Abschn. 2.1".
    var page = ""
    var tags: [String] = []
    var linkedQuoteIDs: [UUID] = []
    var createdAt = Date()
    var updatedAt = Date()

    /// "S. 12", "S. 12–14"; other places ("Kap. 3") as written.
    var locator: String {
        let page = page.trimmingCharacters(in: .whitespaces)
        guard !page.isEmpty else { return "" }
        let isPages = page.allSatisfy { $0.isNumber || "–-, f.".contains($0) } && page.first?.isNumber == true
        return isPages ? "S. " + page.replacingOccurrences(of: "-", with: "–") : page
    }

    var isEmpty: Bool {
        exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && paraphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Citekeys

enum Citekey {
    /// `mueller2026`: the first author's family name (umlauts spelled out, ASCII only, lower case) and the year;
    /// without a person the first word of the title. `taken` keys get a, b, c, ….
    static func make(for source: CitationSource, taken: Set<String>) -> String {
        let person = source.creators.first
        var base = person.map { fold($0.isInstitution ? ($0.family.split(separator: " ").first.map(String.init) ?? $0.family) : $0.family) } ?? ""
        if base.isEmpty {
            let stop: Set<String> = ["der", "die", "das", "ein", "eine", "the", "a", "an", "on", "of", "uber", "ueber", "zur", "zum"]
            base = source.title.split(separator: " ").map { fold(String($0)) }.first { !$0.isEmpty && !stop.contains($0) } ?? ""
        }
        if base.isEmpty { base = "quelle" }
        if base.first?.isNumber == true { base = "q" + base }
        base = String(base.prefix(24))
        let key = base + (source.year.map(String.init) ?? "")
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(key) else { return key }
        for suffix in "abcdefghijklmnopqrstuvwxyz" where !lowered.contains(key + String(suffix)) {
            return key + String(suffix)
        }
        var number = 2
        while lowered.contains(key + "_\(number)") { number += 1 }
        return key + "_\(number)"
    }

    /// Lower case ASCII letters and digits only; umlauts and ß spelled out, other accents dropped.
    static func fold(_ text: String) -> String {
        var text = text.lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"), ("æ", "ae"), ("ø", "o"), ("œ", "oe")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(text.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Keys can be cited as `[@key]` in Markdown (Pandoc's rules): a letter first, then letters, digits and
    /// `_ - : .`, not ending in punctuation.
    static func isValid(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter, let last = key.last, last.isASCII, last.isLetter || last.isNumber else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-:.".contains($0)) }
    }
}

// MARK: - Coding

// The files are read leniently: a field that is missing (an older file, or one written by hand) takes its
// default, so new fields can be added later. Empty fields are not written.

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

private extension KeyedEncodingContainer {
    mutating func text(_ value: String, _ key: Key) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }

    mutating func list<T: Encodable>(_ value: [T], _ key: Key) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }
}

extension PersonName {
    private enum CodingKeys: String, CodingKey { case family, given, particle, institution }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: container.value(.family, ""), given: container.value(.given, ""),
                  particle: container.value(.particle, ""), isInstitution: container.value(.institution, false))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(family, forKey: .family)
        try container.text(given, .given)
        try container.text(particle, .particle)
        if isInstitution { try container.encode(true, forKey: .institution) }
    }
}

extension CitationSource {
    private enum CodingKeys: String, CodingKey {
        case id, citekey, type, title, subtitle, authors, editors, year, date, container, publisher, place, edition, volume, issue,
             pages, doi, isbn, url, arxiv, accessed, language, abstract, notes, tags, attachments, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        citekey = c.value(.citekey, "")
        type = c.value(.type, SourceType.other)
        title = c.value(.title, "")
        subtitle = c.value(.subtitle, "")
        authors = c.value(.authors, [])
        editors = c.value(.editors, [])
        year = c.value(.year, Int?.none)
        date = c.value(.date, "")
        container = c.value(.container, "")
        publisher = c.value(.publisher, "")
        place = c.value(.place, "")
        edition = c.value(.edition, "")
        volume = c.value(.volume, "")
        issue = c.value(.issue, "")
        pages = c.value(.pages, "")
        doi = c.value(.doi, "")
        isbn = c.value(.isbn, "")
        url = c.value(.url, "")
        arxiv = c.value(.arxiv, "")
        accessed = c.value(.accessed, Date?.none)
        language = c.value(.language, "")
        abstract = c.value(.abstract, "")
        notes = c.value(.notes, "")
        tags = c.value(.tags, [])
        attachments = c.value(.attachments, [])
        createdAt = c.value(.createdAt, Date())
        updatedAt = c.value(.updatedAt, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(citekey, forKey: .citekey)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.text(subtitle, .subtitle)
        try c.list(authors, .authors)
        try c.list(editors, .editors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.text(date, .date)
        try c.text(container, .container)
        try c.text(publisher, .publisher)
        try c.text(place, .place)
        try c.text(edition, .edition)
        try c.text(volume, .volume)
        try c.text(issue, .issue)
        try c.text(pages, .pages)
        try c.text(doi, .doi)
        try c.text(isbn, .isbn)
        try c.text(url, .url)
        try c.text(arxiv, .arxiv)
        try c.encodeIfPresent(accessed, forKey: .accessed)
        try c.text(language, .language)
        try c.text(abstract, .abstract)
        try c.text(notes, .notes)
        try c.list(tags, .tags)
        try c.list(attachments, .attachments)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

extension CitationQuote {
    private enum CodingKeys: String, CodingKey { case id, sourceID, exactText, paraphrase, page, tags, linkedQuoteIDs, createdAt, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceID: c.value(.sourceID, UUID()))
        id = try c.decode(UUID.self, forKey: .id)
        exactText = c.value(.exactText, "")
        paraphrase = c.value(.paraphrase, "")
        page = c.value(.page, "")
        tags = c.value(.tags, [])
        linkedQuoteIDs = c.value(.linkedQuoteIDs, [])
        createdAt = c.value(.createdAt, Date())
        updatedAt = c.value(.updatedAt, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.text(exactText, .exactText)
        try c.text(paraphrase, .paraphrase)
        try c.text(page, .page)
        try c.list(tags, .tags)
        try c.list(linkedQuoteIDs, .linkedQuoteIDs)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
