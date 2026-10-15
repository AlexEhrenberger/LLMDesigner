import AppKit

/// A formula in the editor. On a paragraph of its own (block `.math`) it is a display formula, inside text an
/// inline one; the cell decides by the paragraph it stands in. Never changed in place: an edit puts a new
/// attachment there, so undo restores the old one.
final class WriterMathAttachment: NSTextAttachment {
    private(set) var latex = ""

    convenience init(latex: String) {
        self.init(data: nil, ofType: nil)
        self.latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterMathCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterMathCell()
    }

    /// As a display formula: `$$` on lines of their own around the LaTeX.
    var blockMarkdown: String { "$$\n" + latex + "\n$$" }
}

/// The table of contents in the text (block `.toc`): built from the chapters and headings, or the model's topics
/// (the dynamic table of contents of the side panel). The cell draws the current entries; the Markdown is only
/// the marker, `[TOC]` or `[TOC]{.dynamic}`. Never changed in place: switching puts a new attachment there.
final class WriterTOCAttachment: NSTextAttachment {
    static let marker = "[TOC]"
    static let dynamicMarker = "[TOC]{.dynamic}"

    private(set) var isDynamic = false

    convenience init(dynamic: Bool) {
        self.init(data: nil, ofType: nil)
        isDynamic = dynamic
    }

    var markdown: String { isDynamic ? Self.dynamicMarker : Self.marker }

    /// A line that is a table of contents, and which kind (nil: none).
    static func kind(of line: String) -> Bool? {
        switch line.trimmingCharacters(in: .whitespaces) {
        case marker: false
        case dynamicMarker: true
        default: nil
        }
    }

    static func isMarker(_ line: String) -> Bool { kind(of: line) != nil }

    /// The table of contents of a stored document: nil none, false from the headings, true dynamic.
    static func kind(in markdown: String) -> Bool? {
        for line in markdown.components(separatedBy: "\n") {
            if let kind = kind(of: line) { return kind }
        }
        return nil
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterTOCCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterTOCCell()
    }
}

/// A chapter or heading of a document, in order.
struct WriterHeading: Equatable, Hashable, Identifiable {
    /// Position among the document's headings; jumps use it.
    let index: Int
    /// 0 chapter, 1 to 3 Überschrift 1 to 3.
    let level: Int
    /// Inline Markdown (may contain formulas), without the chapter mark.
    let title: String
    /// "2.1" when the document is numbered (it has a table of contents), else nil.
    let number: String?

    var id: Int { index }
}

enum WriterHeadings {
    /// A document with a table of contents is a formal one: its chapters and headings are numbered, in the
    /// editor as in the export.
    static func isFormal(_ markdown: String) -> Bool {
        markdown.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == WriterTOCAttachment.marker }
    }

    static func hasChapters(_ markdown: String) -> Bool {
        MarkdownParser.parse(markdown).contains { block in
            if case .heading(1, let text) = block { return WriterMarkdown.headingAttributes(text).classes.contains("chapter") }
            return false
        }
    }

    /// The headings of a stored document.
    static func headings(in markdown: String) -> [WriterHeading] {
        var levels: [Int] = []
        var titles: [String] = []
        for block in MarkdownParser.parse(markdown) {
            guard case .heading(let level, let text) = block else { continue }
            let (title, classes) = WriterMarkdown.headingAttributes(text)
            levels.append(level == 1 && classes.contains("chapter") ? 0 : min(level, 3))
            titles.append(WriterBookmark.strip(title))
        }
        let numbers = isFormal(markdown) ? self.numbers(for: levels) : Array(repeating: nil, count: levels.count)
        return levels.indices.map { WriterHeading(index: $0, level: levels[$0], title: titles[$0], number: numbers[$0]) }
    }

    /// LaTeX's numbering: with chapters "1", "1.1", "1.1.1", "1.1.1.1"; without "1", "1.1", "1.1.1". A level
    /// that is skipped counts as 0, as in LaTeX.
    static func numbers(for levels: [Int]) -> [String?] {
        let top = levels.contains(0) ? 0 : 1
        var counters = [0, 0, 0, 0]
        return levels.map { level in
            guard level >= top else { return nil }
            counters[level] += 1
            for deeper in (level + 1)..<4 { counters[deeper] = 0 }
            return counters[top...level].map(String.init).joined(separator: ".")
        }
    }

    /// Plain text of a heading's Markdown for places without rich text (formulas stay as LaTeX).
    static func plainTitle(_ title: String) -> String {
        var text = title
        for token in ["**", "~~", "<u>", "</u>", "`"] { text = text.replacingOccurrences(of: token, with: "") }
        text = text.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!<>~$|])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// A bookmark as the side panel lists it.
struct WriterBookmarkEntry: Identifiable, Equatable {
    let id: String
    let title: String
    /// The marked text, plain.
    let excerpt: String
    /// The heading the bookmark is under, if any.
    let section: String?
}

extension WriterBookmark {
    /// The bookmarks of a stored document in text order.
    static func entries(in markdown: String) -> [WriterBookmarkEntry] {
        guard markdown.contains("<span"),
              let expression = try? NSRegularExpression(pattern: #"<span\s+([^>]*)>(.*?)</span>"#, options: [.dotMatchesLineSeparators]) else { return [] }
        let text = markdown as NSString
        var entries: [WriterBookmarkEntry] = []
        var seen = Set<String>()
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            guard let bookmark = parseTag("<span " + text.substring(with: match.range(at: 1)) + ">"), seen.insert(bookmark.id).inserted else { continue }
            let excerpt = WriterHeadings.plainTitle(text.substring(with: match.range(at: 2)))
            // The last heading before it.
            let before = text.substring(to: match.range.location)
            let section = before.components(separatedBy: "\n").last { $0.hasPrefix("#") }.map { line in
                WriterHeadings.plainTitle(strip(WriterMarkdown.headingAttributes(String(line.drop { $0 == "#" || $0 == " " })).text))
            }
            entries.append(WriterBookmarkEntry(id: bookmark.id, title: bookmark.title.isEmpty ? excerpt : bookmark.title, excerpt: excerpt, section: section))
        }
        return entries
    }
}
