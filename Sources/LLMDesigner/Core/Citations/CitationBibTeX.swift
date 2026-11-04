import Foundation

/// BibTeX and CSL-JSON, to exchange sources with LaTeX, Zotero and Citavi. Only the fields both sides know; a source
/// keeps what doesn't fit (its notes, tags and attachments) here.
enum CitationBibTeX {
    private static let entryTypes: [SourceType: String] = [
        .book: "book", .chapter: "incollection", .article: "article", .paper: "misc", .thesis: "phdthesis", .report: "techreport", .web: "online", .other: "misc",
    ]

    // MARK: Writing

    static func export(_ sources: [CitationSource]) -> String {
        sources.map(entry).joined(separator: "\n\n") + "\n"
    }

    private static func entry(_ source: CitationSource) -> String {
        var fields: [(String, String)] = []
        func add(_ name: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { fields.append((name, value)) }
        }
        add("author", names(source.authors))
        add("editor", names(source.editors))
        add("title", source.fullTitle)
        add("year", source.year.map(String.init) ?? "")
        add("date", source.date)
        switch source.type {
        case .article: add("journal", source.container)
        case .chapter: add("booktitle", source.container)
        default: add("howpublished", source.container)
        }
        add("publisher", source.publisher)
        add("address", source.place)
        add("edition", source.edition)
        add("volume", source.volume)
        add("number", source.issue)
        add("pages", source.pages.replacingOccurrences(of: "–", with: "--"))
        add("doi", source.doi)
        add("isbn", source.isbn)
        add("url", source.url)
        add("eprint", source.arxiv)
        add("language", source.language)
        add("abstract", source.abstract)
        let lines = fields.map { "  \($0.0) = {\(escape($0.1))}" }
        return "@\(entryTypes[source.type] ?? "misc"){\(source.citekey),\n" + lines.joined(separator: ",\n") + "\n}"
    }

    private static func names(_ people: [PersonName]) -> String {
        people.map { person in
            if person.isInstitution { return "{" + person.family + "}" }
            let family = (person.particle.isEmpty ? "" : person.particle + " ") + person.family
            return person.given.isEmpty ? family : family + ", " + person.given
        }.joined(separator: " and ")
    }

    /// Braces stay balanced, so a value can't end its field; LaTeX's special characters count as text.
    private static func escape(_ text: String) -> String {
        var depth = 0
        var result = ""
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" {
                guard depth > 0 else { result += "\\}"; continue }
                depth -= 1
            }
            result.append(character)
        }
        return result + String(repeating: "}", count: depth)
    }

    // MARK: Reading

    struct ParseResult {
        var sources: [CitationSource] = []
        /// Entries it couldn't read, by what stands at their start.
        var skipped: [String] = []
    }

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "@" else { index += 1; continue }
            let start = index
            index += 1
            var kind = ""
            while index < characters.count, characters[index].isLetter { kind.append(characters[index]); index += 1 }
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] == "{" || characters[index] == "(" else { continue }
            // To the brace that closes the entry; one that never closes ends the file.
            let open = characters[index]
            let close: Character = open == "{" ? "}" : ")"
            var depth = 0
            var end = index
            var isClosed = false
            while end < characters.count {
                if characters[end] == open { depth += 1 }
                if characters[end] == close {
                    depth -= 1
                    if depth == 0 { isClosed = true; break }
                }
                end += 1
            }
            let body = isClosed ? String(characters[(index + 1)..<end]) : ""
            index = isClosed ? end + 1 : characters.count
            guard !["comment", "string", "preamble"].contains(kind.lowercased()) else { continue }
            guard isClosed, let source = source(kind: kind.lowercased(), body: body) else {
                result.skipped.append(String(characters[start..<min(start + 40, characters.count)]))
                continue
            }
            result.sources.append(source)
        }
        return result
    }

    private static func source(kind: String, body: String) -> CitationSource? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        var source = CitationSource()
        source.citekey = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        source.type = entryTypes.first { $0.value == kind }?.key ?? (kind == "inproceedings" || kind == "inbook" ? .chapter : kind == "mastersthesis" ? .thesis : kind == "misc" ? .other : .other)
        let fields = fields(in: String(body[body.index(after: comma)...]))
        guard let title = fields["title"], !title.isEmpty else { return nil }
        source.title = title
        func people(_ value: String?) -> [PersonName] {
            (value ?? "").components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { name in
                // Braces around all of a name keep it whole (an institution); inside it they only protect letters.
                PersonName.parse(name.hasPrefix("{") && name.hasSuffix("}") ? name : name.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))
            }
        }
        source.authors = people(fields["author"])
        source.editors = people(fields["editor"])
        source.year = (fields["year"]).flatMap { Int($0.prefix(4)) } ?? fields["date"].flatMap { Int($0.prefix(4)) }
        source.date = fields["date"] ?? ""
        source.container = fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] ?? fields["howpublished"] ?? ""
        source.publisher = fields["publisher"] ?? fields["institution"] ?? fields["school"] ?? ""
        source.place = fields["address"] ?? fields["location"] ?? ""
        source.edition = fields["edition"] ?? ""
        source.volume = fields["volume"] ?? ""
        source.issue = fields["number"] ?? fields["issue"] ?? ""
        source.pages = (fields["pages"] ?? "").replacingOccurrences(of: "--", with: "–")
        source.doi = fields["doi"] ?? ""
        source.isbn = fields["isbn"] ?? ""
        source.url = fields["url"] ?? ""
        source.arxiv = fields["eprint"] ?? ""
        source.language = fields["language"] ?? ""
        source.abstract = fields["abstract"] ?? ""
        return source
    }

    /// The `name = {value}` or `name = "value"` or `name = 2020` of an entry, names in lower case.
    private static func fields(in body: String) -> [String: String] {
        var fields: [String: String] = [:]
        let characters = Array(body)
        var index = 0
        func skipSeparators() {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," { index += 1 }
        }
        while true {
            skipSeparators()
            guard index < characters.count else { break }
            var name = ""
            while index < characters.count, characters[index] != "=", !characters[index].isNewline { name.append(characters[index]); index += 1 }
            guard index < characters.count, characters[index] == "=" else { continue }
            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            var value = ""
            if characters[index] == "{" {
                var depth = 0
                repeat {
                    if characters[index] == "{" { depth += 1 } else if characters[index] == "}" { depth -= 1 }
                    if depth > 0, !(depth == 1 && characters[index] == "{") { value.append(characters[index]) }
                    index += 1
                } while depth > 0 && index < characters.count
            } else if characters[index] == "\"" {
                index += 1
                while index < characters.count, characters[index] != "\"" { value.append(characters[index]); index += 1 }
                index += 1
            } else {
                while index < characters.count, characters[index] != ",", !characters[index].isNewline { value.append(characters[index]); index += 1 }
            }
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = clean(value, keepsBraces: key == "author" || key == "editor")
        }
        return fields
    }

    /// A value as text: without the braces LaTeX uses to keep case, and with its accents.
    private static func clean(_ value: String, keepsBraces: Bool) -> String {
        var text = value
        for (latex, plain) in [("\\\"a", "ä"), ("\\\"o", "ö"), ("\\\"u", "ü"), ("\\\"A", "Ä"), ("\\\"O", "Ö"), ("\\\"U", "Ü"), ("\\ss", "ß"), ("\\&", "&"), ("\\%", "%"), ("\\_", "_")] {
            text = text.replacingOccurrences(of: latex, with: plain)
        }
        if !keepsBraces { text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

/// CSL-JSON, as Zotero and others read it.
enum CitationCSL {
    private static let types: [SourceType: String] = [
        .book: "book", .chapter: "chapter", .article: "article-journal", .paper: "article", .thesis: "thesis", .report: "report", .web: "webpage", .other: "document",
    ]

    static func export(_ sources: [CitationSource]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: sources.map(item), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func item(_ source: CitationSource) -> [String: Any] {
        var item: [String: Any] = ["id": source.citekey, "type": types[source.type] ?? "document", "title": source.fullTitle]
        func add(_ key: String, _ value: String) { if !value.isEmpty { item[key] = value } }
        func people(_ names: [PersonName]) -> [[String: String]] {
            names.map { person in
                if person.isInstitution { return ["literal": person.family] }
                var name = ["family": person.family]
                if !person.given.isEmpty { name["given"] = person.given }
                if !person.particle.isEmpty { name["non-dropping-particle"] = person.particle }
                return name
            }
        }
        if !source.authors.isEmpty { item["author"] = people(source.authors) }
        if !source.editors.isEmpty { item["editor"] = people(source.editors) }
        if let year = source.year { item["issued"] = ["date-parts": [[year]]] }
        add("container-title", source.container)
        add("publisher", source.publisher)
        add("publisher-place", source.place)
        add("edition", source.edition)
        add("volume", source.volume)
        add("issue", source.issue)
        add("page", source.pages)
        add("DOI", source.doi)
        add("ISBN", source.isbn)
        add("URL", source.url)
        add("language", source.language)
        add("abstract", source.abstract)
        return item
    }
}
