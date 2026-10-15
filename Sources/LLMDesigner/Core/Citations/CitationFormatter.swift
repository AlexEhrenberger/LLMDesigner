import Foundation

/// Text with italic stretches, so one formatted reference can become rich text, LaTeX or Markdown.
struct StyledText: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        var text: String
        var italic: Bool
    }

    var runs: [Run] = []

    mutating func append(_ text: String, italic: Bool = false) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.italic == italic {
            runs[runs.count - 1].text += text
        } else {
            runs.append(Run(text: text, italic: italic))
        }
    }

    var plain: String { runs.map(\.text).joined() }

    /// `*kursiv*`, with Markdown's special characters escaped.
    var markdown: String {
        runs.map { run in
            let text = WriterMarkdown.escape(run.text, atLineStart: false)
            return run.italic ? "*\(text)*" : text
        }.joined()
    }

    func latex(_ escape: (String) -> String) -> String {
        runs.map { $0.italic ? "\\emph{\(escape($0.text))}" : escape($0.text) }.joined()
    }
}

/// A citation in the text, as Pandoc writes it: `[@key]`, `[@key, S. 12]`, `[siehe @a; @b, Kap. 2]`, `[-@key]`
/// (only the year).
struct CitationItem: Equatable, Hashable, Sendable {
    var key: String
    var locator = ""
    var prefix = ""
    var suppressAuthor = false
}

enum CitationMarkup {
    /// The inside of `[…]` as citation items; nil when it isn't one (every part needs an `@key`).
    static func parse(_ inner: String) -> [CitationItem]? {
        let parts = inner.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var items: [CitationItem] = []
        for part in parts {
            guard let at = part.firstIndex(of: "@") else { return nil }
            var item = CitationItem(key: "")
            var prefix = String(part[..<at])
            if prefix.hasSuffix("-") {
                item.suppressAuthor = true
                prefix.removeLast()
            }
            item.prefix = prefix.trimmingCharacters(in: .whitespaces)
            let rest = part[part.index(after: at)...]
            let key = rest.prefix { $0.isLetter || $0.isNumber || "_-:.".contains($0) }
            // A key ends before punctuation that closes it ("@a." in a sentence).
            var trimmedKey = String(key)
            while let last = trimmedKey.last, ".:-".contains(last) { trimmedKey.removeLast() }
            guard Citekey.isValid(trimmedKey) else { return nil }
            item.key = trimmedKey
            var locator = rest.dropFirst(trimmedKey.count).trimmingCharacters(in: .whitespaces)
            if locator.hasPrefix(",") { locator = String(locator.dropFirst()).trimmingCharacters(in: .whitespaces) }
            item.locator = locator
            items.append(item)
        }
        return items
    }

    static func markdown(_ items: [CitationItem]) -> String {
        "[" + items.map { item in
            var text = item.prefix.isEmpty ? "" : item.prefix + " "
            text += (item.suppressAuthor ? "-@" : "@") + item.key
            if !item.locator.isEmpty { text += ", " + item.locator }
            return text
        }.joined(separator: "; ") + "]"
    }

    /// The keys cited in a Markdown text, in the order they first appear.
    static func keys(in markdown: String) -> [String] {
        guard markdown.contains("@"), let expression = try? NSRegularExpression(pattern: #"(?<!\\)\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()"#) else { return [] }
        let text = markdown as NSString
        var keys: [String] = []
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            for item in parse(text.substring(with: match.range(at: 1))) ?? [] where !keys.contains(where: { $0.caseInsensitiveCompare(item.key) == .orderedSame }) {
                keys.append(item.key)
            }
        }
        return keys
    }

    /// "436" → "S. 436"; "Kap. 2" stays.
    static func locator(_ text: String) -> String {
        var quote = CitationQuote(sourceID: UUID())
        quote.page = text
        return quote.locator
    }
}

/// APA 7 in German: (Müller & Kaiser, 2026, S. 12) in the text, and the reference list with initials, "u. a.",
/// "Hrsg.", "Aufl.", italic titles and DOIs as addresses.
struct CitationStyle {
    private let sources: [String: CitationSource]
    /// "2015a", "2015b" when the same people have several cited works in a year.
    private let yearLabels: [UUID: String]

    init(sources library: [CitationSource], cited keys: [String]) {
        var byKey: [String: CitationSource] = [:]
        for source in library { byKey[source.citekey.lowercased()] = source }
        sources = byKey
        let cited = keys.compactMap { byKey[$0.lowercased()] }
        var labels: [UUID: String] = [:]
        let groups = Dictionary(grouping: cited, by: { Citekey.fold($0.shortAuthors) + "|" + $0.yearText })
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for (index, source) in sorted.enumerated() where index < 26 {
                labels[source.id] = source.yearText + String(UnicodeScalar(UInt8(97 + index)))
            }
        }
        yearLabels = labels
    }

    func source(_ key: String) -> CitationSource? { sources[key.lowercased()] }

    private func year(_ source: CitationSource) -> String { yearLabels[source.id] ?? source.yearText }

    // MARK: In the text

    /// "(LeCun u. a., 2015, S. 436; Hesse, 1995)"; an unknown key shows as "@key?".
    func inText(_ items: [CitationItem]) -> String {
        "(" + items.map { item in
            var parts: [String] = []
            if let source = source(item.key) {
                // Without people, APA names the work: („Leuchtturm“, o. J.).
                if !item.suppressAuthor { parts.append(source.creators.isEmpty ? "„\(Self.shortTitle(source))“" : source.shortAuthors) }
                parts.append(year(source))
            } else {
                parts.append("@\(item.key)?")
            }
            if !item.locator.isEmpty { parts.append(item.locator) }
            let text = parts.joined(separator: ", ")
            return item.prefix.isEmpty ? text : item.prefix + " " + text
        }.joined(separator: "; ") + ")"
    }

    // MARK: Reference list

    /// The cited sources, sorted by family name, year and title; unknown keys are left out.
    func bibliography(_ keys: [String]) -> [(source: CitationSource, text: StyledText)] {
        var seen = Set<UUID>()
        let cited = keys.compactMap { source($0) }.filter { seen.insert($0.id).inserted }
        return cited.sorted { first, second in
            let a = Citekey.fold(first.creators.first?.sortName ?? first.title)
            let b = Citekey.fold(second.creators.first?.sortName ?? second.title)
            if a != b { return a < b }
            if year(first) != year(second) { return year(first) < year(second) }
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }.map { ($0, reference($0)) }
    }

    func reference(_ source: CitationSource) -> StyledText {
        var text = StyledText()
        let authors = source.authors
        let editorsOnly = authors.isEmpty && !source.editors.isEmpty
        if !authors.isEmpty {
            text.append(Self.names(authors))
        } else if editorsOnly {
            text.append(Self.names(source.editors) + " (Hrsg.)")
        }
        let date = dateText(source)
        if text.runs.isEmpty {
            // Without people the title comes first.
            appendTitle(source, to: &text)
            text.append(" (\(date)).")
        } else {
            if !text.plain.hasSuffix(".") { text.append(".") }
            text.append(" (\(date)). ")
            appendTitle(source, to: &text)
        }
        switch source.type {
        case .article:
            if !source.container.isEmpty {
                text.append(" ")
                text.append(source.container, italic: true)
                if !source.volume.isEmpty {
                    text.append(", ")
                    text.append(source.volume, italic: true)
                }
                if !source.issue.isEmpty { text.append("(\(source.issue))") }
                if !source.pages.isEmpty { text.append(", " + source.pages.replacingOccurrences(of: "-", with: "–")) }
                text.append(".")
            }
        case .chapter:
            if !source.container.isEmpty || !source.editors.isEmpty {
                text.append(" In ")
                if !source.editors.isEmpty {
                    text.append(Self.editorNames(source.editors) + " (Hrsg.), ")
                }
                text.append(source.container.isEmpty ? "[Sammelband]" : source.container, italic: true)
                var details: [String] = []
                if !source.edition.isEmpty { details.append(Self.edition(source.edition)) }
                if !source.pages.isEmpty { details.append("S. " + source.pages.replacingOccurrences(of: "-", with: "–")) }
                if !details.isEmpty { text.append(" (" + details.joined(separator: ", ") + ")") }
                text.append(".")
            }
            if !source.publisher.isEmpty { text.append(" " + source.publisher + ".") }
        case .web:
            if !source.container.isEmpty, !source.creators.contains(where: { $0.citationName == source.container }) {
                text.append(" " + source.container + ".")
            }
        case .paper:
            if !source.container.isEmpty { text.append(" " + source.container + ".") }
        case .thesis, .book, .report, .other:
            if source.type == .other, !source.container.isEmpty { text.append(" " + source.container + ".") }
            // A publisher that is also the author isn't named twice.
            if !source.publisher.isEmpty, !source.creators.contains(where: { $0.citationName == source.publisher }) {
                text.append(" " + source.publisher + ".")
            }
        }
        if let link = link(source) {
            if source.type == .web, let accessed = source.accessed {
                text.append(" Abgerufen am \(Self.longDate(accessed)), von \(link)")
            } else {
                text.append(" " + link)
            }
        }
        return text
    }

    /// The title in italics where it stands alone (books, reports, web pages), upright for articles and
    /// chapters; with edition and kind in brackets.
    private func appendTitle(_ source: CitationSource, to text: inout StyledText) {
        let italic = ![.article, .chapter].contains(source.type)
        let title = source.fullTitle.isEmpty ? "[Ohne Titel]" : source.fullTitle
        text.append(title, italic: italic)
        var details: [String] = []
        if source.type == .book, !source.edition.isEmpty { details.append(Self.edition(source.edition)) }
        if source.type == .thesis { details.append(["Abschlussarbeit", source.container].filter { !$0.isEmpty }.joined(separator: ", ")) }
        if source.type == .paper, !source.arxiv.isEmpty { details.append("arXiv:\(source.arxiv)") }
        if !details.isEmpty {
            text.append(source.type == .thesis ? " [" + details.joined(separator: ", ") + "]" : " (" + details.joined(separator: ", ") + ")")
        }
        if let last = text.plain.last, !".?!".contains(last) { text.append(".") }
    }

    private func dateText(_ source: CitationSource) -> String {
        let year = year(source)
        guard source.type == .web || source.type == .article && source.volume.isEmpty, source.date.count >= 7 else { return year }
        let parts = source.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]) else { return year }
        let month = Self.months[parts[1] - 1]
        return parts.count >= 3 ? "\(year), \(parts[2]). \(month)" : "\(year), \(month)"
    }

    private func link(_ source: CitationSource) -> String? {
        if !source.doi.isEmpty { return "https://doi.org/" + source.doi }
        if !source.url.isEmpty { return source.url }
        if !source.arxiv.isEmpty { return "https://arxiv.org/abs/" + source.arxiv }
        return nil
    }

    // MARK: Names

    /// "Müller, A., Kaiser, B., & Weber, C."; from 21 people on, the first 19, "…" and the last.
    static func names(_ people: [PersonName]) -> String {
        var written = people.map(referenceName)
        if written.count > 20 {
            written = Array(written.prefix(19)) + ["…", written.last!]
            return written.joined(separator: ", ")
        }
        switch written.count {
        case 0: return ""
        case 1: return written[0]
        default: return written.dropLast().joined(separator: ", ") + ", & " + written.last!
        }
    }

    /// "Müller, A. B.", "van Gogh, V.", "Statistisches Bundesamt".
    static func referenceName(_ person: PersonName) -> String {
        guard !person.isInstitution, !person.initials.isEmpty else { return person.citationName }
        return person.citationName + ", " + person.initials
    }

    /// Editors in a chapter: "A. Müller & B. Kaiser".
    static func editorNames(_ people: [PersonName]) -> String {
        let written = people.map { person in
            person.isInstitution || person.initials.isEmpty ? person.citationName : person.initials + " " + person.citationName
        }
        switch written.count {
        case 0: return ""
        case 1: return written[0]
        case 2: return written[0] + " & " + written[1]
        default: return written.dropLast().joined(separator: ", ") + " & " + written.last!
        }
    }

    static func edition(_ edition: String) -> String {
        let trimmed = edition.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return Int(trimmed) != nil ? "\(trimmed). Aufl." : edition
    }

    /// The first words of a title, for a work without people.
    static func shortTitle(_ source: CitationSource) -> String {
        let words = source.title.split(separator: " ")
        return words.count > 4 ? words.prefix(4).joined(separator: " ") + " …" : source.title
    }

    static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    static func longDate(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: date)
        return "\(parts.day ?? 1). \(months[(parts.month ?? 1) - 1]) \(parts.year ?? 2000)"
    }
}

/// Citations in exported documents.
enum CitationExport {
    /// `[@key, S. 12]` → "(Autor, Jahr, S. 12)" as Markdown text, for LaTeX and PDF.
    static func resolve(_ markdown: String, style: CitationStyle) -> String {
        guard markdown.contains("@"), let expression = try? NSRegularExpression(pattern: #"(?<!\\)\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()"#) else { return markdown }
        let text = markdown as NSString
        var output = ""
        var position = 0
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            guard let items = CitationMarkup.parse(text.substring(with: match.range(at: 1))) else { continue }
            output += text.substring(with: NSRange(location: position, length: match.range.location - position))
            output += WriterMarkdown.escape(style.inText(items), atLineStart: false)
            position = match.range.location + match.range.length
        }
        return output + text.substring(from: position)
    }

    /// The `[Literatur]` line → a heading and the entries (Markdown with *italic* titles).
    static func expandBibliography(in markdown: String, entries: [StyledText]) -> String {
        guard markdown.components(separatedBy: "\n").contains(where: WriterBibliographyAttachment.isMarker) else { return markdown }
        let block = "## Literatur\n\n" + (entries.isEmpty ? "*Keine Quellenangaben im Dokument.*" : entries.map(\.markdown).joined(separator: "\n\n"))
        return markdown.components(separatedBy: "\n").map { WriterBibliographyAttachment.isMarker($0) ? block : $0 }.joined(separator: "\n")
    }
}
