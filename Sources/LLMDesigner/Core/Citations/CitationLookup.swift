import Foundation

enum CitationLookupError: LocalizedError {
    case unrecognized
    case notFound(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized: "Das ist keine DOI, ISBN, arXiv-ID oder Web-Adresse."
        case .notFound(let what): "Zu \(what) wurde nichts gefunden."
        case .network(let message): "Die Abfrage ging nicht durch: \(message)"
        }
    }
}

/// Fills a source from a DOI (Crossref), an ISBN (Deutsche Nationalbibliothek, Open Library, Google Books), an
/// arXiv ID (arXiv's API) or a web page (its citation and Open Graph tags). Only the identifier leaves the Mac.
enum CitationLookup {
    static func lookup(_ identifier: CitationIdentifier) async throws -> CitationSource {
        switch identifier {
        case .doi(let doi): return try await crossref(doi)
        case .isbn(let isbn): return try await book(isbn)
        case .arxiv(let id): return try await arxiv(id)
        case .url(let url): return try await webPage(url)
        }
    }

    // MARK: DOI

    static func crossref(_ doi: String) async throws -> CitationSource {
        let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/" + path) else { throw CitationLookupError.unrecognized }
        let data = try await fetch(url, notFound: "DOI \(doi)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let work = json["message"] as? [String: Any] else {
            throw CitationLookupError.notFound("DOI \(doi)")
        }
        return crossrefSource(work, doi: doi)
    }

    static func crossrefSource(_ work: [String: Any], doi: String) -> CitationSource {
        var source = CitationSource()
        source.doi = doi
        source.type = switch work["type"] as? String ?? "" {
        case "journal-article": .article
        case "book-chapter", "book-section", "book-part", "reference-entry": .chapter
        case "book", "monograph", "edited-book", "reference-book", "book-set": .book
        case "proceedings-article", "posted-content": .paper
        case "dissertation": .thesis
        case "report", "report-component", "standard": .report
        default: .other
        }
        source.title = clean((work["title"] as? [String])?.first ?? "")
        source.subtitle = clean((work["subtitle"] as? [String])?.first ?? "")
        source.authors = people(work["author"])
        source.editors = people(work["editor"])
        source.container = clean((work["container-title"] as? [String])?.first ?? "")
        source.publisher = clean(work["publisher"] as? String ?? "")
        source.place = clean(work["publisher-location"] as? String ?? "")
        source.volume = work["volume"] as? String ?? ""
        source.issue = work["issue"] as? String ?? ""
        source.pages = (work["page"] as? String ?? "").replacingOccurrences(of: "-", with: "–")
        source.edition = work["edition-number"] as? String ?? ""
        source.isbn = (work["ISBN"] as? [String])?.first ?? ""
        source.url = work["URL"] as? String ?? ""
        source.language = work["language"] as? String ?? ""
        source.abstract = stripTags(work["abstract"] as? String ?? "")
        for key in ["issued", "published-print", "published-online", "created"] {
            if let parts = ((work[key] as? [String: Any])?["date-parts"] as? [[Any]])?.first, let year = parts.first as? Int {
                source.year = year
                if parts.count >= 2, let month = parts[1] as? Int {
                    source.date = String(format: "%04d-%02d", year, month) + (parts.count >= 3 ? String(format: "-%02d", parts[2] as? Int ?? 1) : "")
                }
                break
            }
        }
        return source
    }

    private static func people(_ value: Any?) -> [PersonName] {
        (value as? [[String: Any]] ?? []).compactMap { person in
            if let family = person["family"] as? String {
                var name = PersonName(family: clean(family), given: clean(person["given"] as? String ?? ""))
                if let particle = person["non-dropping-particle"] as? String { name.particle = particle }
                return name
            }
            if let name = person["name"] as? String { return PersonName(family: clean(name), isInstitution: true) }
            return nil
        }
    }

    // MARK: ISBN

    /// German ISBNs (978-3) ask the Deutsche Nationalbibliothek first; then Open Library and Google Books.
    static func book(_ isbn: String) async throws -> CitationSource {
        let services: [(String) async throws -> CitationSource?] = isbn.hasPrefix("9783")
            ? [dnb, openLibrary, googleBooks] : [openLibrary, googleBooks, dnb]
        var found: CitationSource?
        var lastError: Error?
        for service in services {
            do {
                guard let result = try await service(isbn), !result.title.isEmpty else { continue }
                if var current = found {
                    // A second service fills what the first one left out.
                    if current.publisher.isEmpty { current.publisher = result.publisher }
                    if current.place.isEmpty { current.place = result.place }
                    if current.year == nil { current.year = result.year }
                    if current.authors.isEmpty { current.authors = result.authors }
                    found = current
                    break
                }
                found = result
                if !result.publisher.isEmpty, !result.place.isEmpty, result.year != nil, !result.authors.isEmpty { break }
            } catch {
                lastError = error
            }
        }
        if var found {
            found.type = .book
            found.isbn = isbn
            return found
        }
        if let lastError, !(lastError is CitationLookupError) { throw lastError }
        throw CitationLookupError.notFound("ISBN \(isbn)")
    }

    static func openLibrary(_ isbn: String) async throws -> CitationSource? {
        guard let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data") else { return nil }
        let data = try await fetch(url, notFound: "ISBN \(isbn)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let book = json["ISBN:\(isbn)"] as? [String: Any] else { return nil }
        var source = CitationSource()
        source.title = clean(book["title"] as? String ?? "")
        source.subtitle = clean(book["subtitle"] as? String ?? "")
        source.authors = (book["authors"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String).map { PersonName.parse($0) } }
        source.publisher = ((book["publishers"] as? [[String: Any]])?.first?["name"] as? String).map(clean) ?? ""
        source.place = ((book["publish_places"] as? [[String: Any]])?.first?["name"] as? String).map(clean) ?? ""
        source.year = year(in: book["publish_date"] as? String ?? "")
        source.url = book["url"] as? String ?? ""
        return source
    }

    static func googleBooks(_ isbn: String) async throws -> CitationSource? {
        guard let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)") else { return nil }
        let data = try await fetch(url, notFound: "ISBN \(isbn)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (json["items"] as? [[String: Any]])?.first?["volumeInfo"] as? [String: Any] else { return nil }
        var source = CitationSource()
        source.title = clean(info["title"] as? String ?? "")
        source.subtitle = clean(info["subtitle"] as? String ?? "")
        source.authors = (info["authors"] as? [String] ?? []).map { PersonName.parse($0) }
        source.publisher = clean(info["publisher"] as? String ?? "")
        source.year = year(in: info["publishedDate"] as? String ?? "")
        source.language = info["language"] as? String ?? ""
        source.abstract = clean(info["description"] as? String ?? "")
        return source
    }

    /// The Deutsche Nationalbibliothek's SRU interface in Dublin Core: "Titel : Untertitel / Autor",
    /// "Hesse, Hermann [Verfasser]", "Frankfurt am Main : Suhrkamp".
    static func dnb(_ isbn: String) async throws -> CitationSource? {
        guard let url = URL(string: "https://services.dnb.de/sru/dnb?version=1.1&operation=searchRetrieve&query=isbn%3D\(isbn)&recordSchema=oai_dc&maximumRecords=1") else { return nil }
        let data = try await fetch(url, notFound: "ISBN \(isbn)")
        let fields = DublinCoreReader.read(data)
        guard var title = fields["title"]?.first else { return nil }
        var source = CitationSource()
        if let slash = title.range(of: " / ") { title = String(title[..<slash.lowerBound]) }
        let parts = title.components(separatedBy: " : ")
        source.title = clean(parts[0])
        if parts.count > 1 { source.subtitle = clean(parts.dropFirst().joined(separator: ": ")) }
        source.authors = (fields["creator"] ?? []).map { creator in
            let name = creator.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            return PersonName.parse(name)
        }
        if let publisher = fields["publisher"]?.first {
            let parts = publisher.components(separatedBy: " : ")
            if parts.count > 1 {
                source.place = clean(parts[0])
                source.publisher = clean(parts.dropFirst().joined(separator: " : "))
            } else {
                source.publisher = clean(publisher)
            }
        }
        source.year = (fields["date"] ?? []).compactMap(year(in:)).first
        source.language = fields["language"]?.first ?? ""
        return source
    }

    // MARK: arXiv

    static func arxiv(_ id: String) async throws -> CitationSource {
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)") else { throw CitationLookupError.unrecognized }
        let data = try await fetch(url, notFound: "arXiv \(id)")
        let entry = AtomEntryReader.read(data)
        guard let title = entry["title"]?.first, !title.isEmpty, !title.lowercased().hasPrefix("error") else {
            throw CitationLookupError.notFound("arXiv \(id)")
        }
        var source = CitationSource()
        source.type = .paper
        source.title = clean(title)
        source.authors = (entry["name"] ?? []).map { PersonName.parse($0) }
        source.year = (entry["published"]?.first).flatMap(year(in:))
        source.date = String((entry["published"]?.first ?? "").prefix(10))
        source.abstract = clean(entry["summary"]?.first ?? "")
        source.container = "arXiv"
        source.arxiv = id
        source.url = "https://arxiv.org/abs/\(id)"
        source.doi = entry["arxiv:doi"]?.first ?? ""
        return source
    }

    // MARK: Web pages

    /// A web page: the tags scholarly sites set for citation managers (`citation_title`, `citation_author`, …),
    /// else Open Graph and the page title. A page that names its DOI is looked up at Crossref instead.
    static func webPage(_ address: String) async throws -> CitationSource {
        guard let url = URL(string: address) else { throw CitationLookupError.unrecognized }
        // Publishers' addresses often hold the DOI (…/doi/10.1002/…): Crossref knows more than the page.
        if let range = address.range(of: #"10\.\d{4,9}/[^\s?#&]+"#, options: .regularExpression),
           let doi = CitationIdentifier.normalizedDOI(String(address[range])), var source = try? await crossref(doi) {
            source.url = address
            return source
        }
        let data = try await fetch(url, notFound: address, browserLike: true)
        let html = String(decoding: data.prefix(600_000), as: UTF8.self)
        let meta = metaTags(in: html)
        func first(_ keys: String...) -> String {
            keys.lazy.compactMap { meta[$0]?.first }.first { !$0.isEmpty } ?? ""
        }
        if let doi = CitationIdentifier.normalizedDOI(first("citation_doi", "dc.identifier", "prism.doi")), let source = try? await crossref(doi) {
            var source = source
            if source.url.isEmpty || source.url.contains("doi.org") { source.url = address }
            return source
        }
        var source = CitationSource()
        source.type = meta["citation_journal_title"] != nil ? .article : .web
        source.url = address
        source.accessed = Date()
        var title = first("citation_title", "og:title", "dc.title", "twitter:title")
        if title.isEmpty, let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(html[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        source.title = clean(decodeEntities(title))
        let blocked = ["client challenge", "just a moment", "attention required", "access denied", "are you a robot", "captcha"]
        if blocked.contains(where: source.title.lowercased().contains) {
            throw CitationLookupError.network("Die Seite lässt sich nicht automatisch lesen (Schutz vor Programmen). Gib die DOI ein oder trage die Angaben selbst ein.")
        }
        let authors = (meta["citation_author"] ?? meta["dc.creator"] ?? meta["author"] ?? []).filter { !$0.hasPrefix("http") }
        source.authors = authors.map { PersonName.parse(decodeEntities($0)) }
        let date = first("citation_publication_date", "citation_date", "article:published_time", "dc.date", "date", "pubdate")
        source.year = year(in: date)
        if date.count >= 7 { source.date = String(date.prefix(10)).replacingOccurrences(of: "/", with: "-") }
        source.container = clean(decodeEntities(first("citation_journal_title", "og:site_name", "application-name")))
        // "Leuchtturm – Wikipedia": the site's name goes where it belongs.
        for separator in [" – ", " — ", " | ", " - "] {
            guard let range = source.title.range(of: separator, options: .backwards) else { continue }
            let suffix = String(source.title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard suffix.count <= 40, source.container.isEmpty || source.container.caseInsensitiveCompare(suffix) == .orderedSame else { continue }
            source.container = suffix
            source.title = String(source.title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }
        source.publisher = clean(decodeEntities(first("citation_publisher", "dc.publisher")))
        source.volume = first("citation_volume")
        source.issue = first("citation_issue")
        let firstPage = first("citation_firstpage")
        let lastPage = first("citation_lastpage")
        source.pages = [firstPage, lastPage].filter { !$0.isEmpty }.joined(separator: "–")
        source.language = first("citation_language", "dc.language")
        source.abstract = clean(decodeEntities(first("citation_abstract", "description", "og:description")))
        guard !source.title.isEmpty else { throw CitationLookupError.notFound(address) }
        return source
    }

    /// `<meta name|property="…" content="…">` in any attribute order, keys in lower case.
    static func metaTags(in html: String) -> [String: [String]] {
        var tags: [String: [String]] = [:]
        guard let tagPattern = try? NSRegularExpression(pattern: #"<meta\s[^>]*>"#, options: [.caseInsensitive]),
              let attributePattern = try? NSRegularExpression(pattern: #"([A-Za-z_:.\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
        let text = html as NSString
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range) as NSString
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let name = tag.substring(with: attribute.range(at: 1)).lowercased()
                let valueRange = attribute.range(at: 2).location != NSNotFound ? attribute.range(at: 2) : attribute.range(at: 3)
                attributes[name] = valueRange.location != NSNotFound ? tag.substring(with: valueRange) : ""
            }
            guard let key = (attributes["name"] ?? attributes["property"])?.lowercased(), let content = attributes["content"] else { continue }
            tags[key, default: []].append(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return tags
    }

    // MARK: Helpers

    private static func fetch(_ url: URL, notFound: String, browserLike: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // No e-mail address and nothing else about the user; just which program asks.
        request.setValue(browserLike ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
                                     : "LLMDesigner/1.0 (Literaturverwaltung)", forHTTPHeaderField: "User-Agent")
        request.setValue(browserLike ? "text/html,application/xhtml+xml" : "application/json, application/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CitationLookupError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw CitationLookupError.notFound(notFound) }
            guard (200..<300).contains(http.statusCode) else { throw CitationLookupError.network("HTTP \(http.statusCode)") }
        }
        return data
    }

    static func year(in text: String) -> Int? {
        guard let range = text.range(of: #"(1[5-9]|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// One line, single spaces, without the trailing punctuation catalogues like to leave.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:;,")))
    }

    /// Crossref abstracts come as JATS XML.
    static func stripTags(_ text: String) -> String {
        clean(decodeEntities(text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)))
            .replacingOccurrences(of: #"^Abstract\s+"#, with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
                                    ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"), ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß"),
                                    ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        guard let pattern = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return result }
        let nsResult = result as NSString
        var output = ""
        var position = 0
        for match in pattern.matches(in: result, range: NSRange(location: 0, length: nsResult.length)) {
            output += nsResult.substring(with: NSRange(location: position, length: match.range.location - position))
            let isHex = nsResult.substring(with: match.range(at: 1)) == "x"
            let digits = nsResult.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else {
                output += nsResult.substring(with: match.range)
            }
            position = match.range.location + match.range.length
        }
        output += nsResult.substring(from: position)
        return output
    }
}

/// Collects the text of `dc:…` elements (Dublin Core in the DNB's SRU answers), by local name.
private final class DublinCoreReader: NSObject, XMLParserDelegate {
    private var fields: [String: [String]] = [:]
    private var current: String?
    private var text = ""

    static func read(_ data: Data) -> [String: [String]] {
        let reader = DublinCoreReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.fields
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName.hasPrefix("dc:") {
            current = String(elementName.dropFirst(3))
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let current, elementName == "dc:" + current else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { fields[current, default: []].append(value) }
        self.current = nil
    }
}

/// The first `<entry>` of an Atom feed (arXiv's API): title, summary, published, author names, arxiv:doi.
private final class AtomEntryReader: NSObject, XMLParserDelegate {
    private var fields: [String: [String]] = [:]
    private var inEntry = false
    private var done = false
    private var text = ""

    static func read(_ data: Data) -> [String: [String]] {
        let reader = AtomEntryReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.fields
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "entry", !done { inEntry = true }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard inEntry else { return }
        if elementName == "entry" {
            inEntry = false
            done = true
            return
        }
        if ["title", "summary", "published", "name", "arxiv:doi", "arxiv:journal_ref"].contains(elementName) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { fields[elementName, default: []].append(value) }
        }
        text = ""
    }
}
