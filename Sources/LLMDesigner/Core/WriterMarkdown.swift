import AppKit

/// What a paragraph in Writer Studio is. Stored on every character of the paragraph (`.writerBlock`).
enum WriterBlock: String, CaseIterable, Sendable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, quote, code, rule
    /// The top level of the outline, above Überschrift 1. Markdown: `# Titel {.chapter}`.
    case chapter
    /// A picture on its own paragraph (`WriterImageAttachment`).
    case image
    /// A display formula on its own paragraph (`WriterMathAttachment`). Markdown: `$$ … $$`.
    case math
    /// The table of contents (`WriterTOCAttachment`). Markdown: `[TOC]`, or `[TOC]{.dynamic}` for the model's topics.
    case toc
    /// A table cell: one paragraph per cell, see `WriterTable`.
    case table
    /// Markdown the editor can't show yet (formulas); kept and written back unchanged.
    case raw

    var isList: Bool { self == .bullet || self == .numbered }
    var isHeading: Bool { headingLevel != nil }
    /// Chapter 0, Überschrift 1 to 3: 1 to 3.
    var headingLevel: Int? {
        switch self {
        case .chapter: 0
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: nil
        }
    }
    /// A paragraph that is one object: a picture, a display formula or the table of contents. It is selected,
    /// moved and deleted as a whole, and text is never typed into it.
    var isEmbed: Bool { self == .image || self == .math || self == .toc }
    /// Text that can be aligned on its own (`WriterAlignment`); table cells follow their column.
    var takesAlignment: Bool {
        switch self {
        case .paragraph, .chapter, .heading1, .heading2, .heading3, .quote: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .paragraph: "Text"
        case .heading1: "Überschrift 1"
        case .heading2: "Überschrift 2"
        case .heading3: "Überschrift 3"
        case .chapter: "Kapitel"
        case .bullet: "Aufzählung"
        case .numbered: "Nummerierte Liste"
        case .quote: "Zitat"
        case .code: "Code"
        case .rule: "Trennlinie"
        case .image: "Bild"
        case .math: "Formel"
        case .toc: "Inhaltsverzeichnis"
        case .table: "Tabelle"
        case .raw: "Markdown"
        }
    }
}

/// How a paragraph is set. Stored on every character of the paragraph (`.writerAlignment`); nil is the default
/// (left, or centred on a title slide). Markdown has no alignment: a Pandoc div holds it, `::: {.center}` … `:::`
/// around the paragraphs, which other programs show as text and Pandoc keeps.
enum WriterAlignment: String, CaseIterable, Sendable {
    case left, center, right, justify

    var textAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justify: .justified
        }
    }

    var label: String {
        switch self {
        case .left: "Linksbündig"
        case .center: "Zentriert"
        case .right: "Rechtsbündig"
        case .justify: "Blocksatz"
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }

    /// The alignment a div's class names (`center`, `right`, …); nil for any other class.
    init?(className: String) {
        switch className.lowercased() {
        case "left", "flushleft": self = .left
        case "center", "centre", "centered": self = .center
        case "right", "flushright": self = .right
        case "justify", "justified": self = .justify
        default: return nil
        }
    }

    /// The innermost alignment among a block's div classes.
    static func from(classes: [String]) -> WriterAlignment? {
        classes.reversed().lazy.compactMap(WriterAlignment.init(className:)).first
    }
}

extension NSAttributedString.Key {
    /// `WriterBlock.rawValue` of the paragraph.
    static let writerBlock = NSAttributedString.Key("LLMDesigner.writer.block")
    /// Indentation level of a list item (0 = outermost).
    static let writerListLevel = NSAttributedString.Key("LLMDesigner.writer.level")
    /// Language of a code block, from its opening fence.
    static let writerCodeLanguage = NSAttributedString.Key("LLMDesigner.writer.language")
    static let writerBold = NSAttributedString.Key("LLMDesigner.writer.bold")
    static let writerItalic = NSAttributedString.Key("LLMDesigner.writer.italic")
    static let writerCode = NSAttributedString.Key("LLMDesigner.writer.code")
    /// Dictated words that are still being recognised: shown grey, never saved.
    static let writerDictationPreview = NSAttributedString.Key("LLMDesigner.writer.dictationPreview")
    /// The `WriterTable` a cell belongs to, and the cell's place in it.
    static let writerTable = NSAttributedString.Key("LLMDesigner.writer.table")
    static let writerTableRow = NSAttributedString.Key("LLMDesigner.writer.tableRow")
    static let writerTableColumn = NSAttributedString.Key("LLMDesigner.writer.tableColumn")
    /// A bookmark (`WriterBookmark`) on the marked passage.
    static let writerBookmark = NSAttributedString.Key("LLMDesigner.writer.bookmark")
    /// The passage's own colour (six hex digits, see `WriterColors`) and font (`WriterFont.rawValue`).
    static let writerColor = NSAttributedString.Key("LLMDesigner.writer.color")
    static let writerFont = NSAttributedString.Key("LLMDesigner.writer.font")
    /// The passage's own size in points of the print (a `Double`, see `WriterSpanStyle`).
    static let writerFontSize = NSAttributedString.Key("LLMDesigner.writer.fontSize")
    /// `WriterAlignment.rawValue` of the paragraph, when it isn't the default.
    static let writerAlignment = NSAttributedString.Key("LLMDesigner.writer.alignment")
    /// Raised or lowered text (`true`), Markdown `<sup>…</sup>` and `<sub>…</sub>`.
    static let writerSuperscript = NSAttributedString.Key("LLMDesigner.writer.superscript")
    static let writerSubscript = NSAttributedString.Key("LLMDesigner.writer.subscript")
}

/// A bookmark in a document: a marked passage with a name. In Markdown it is an HTML span around the passage,
/// `<span id="lz-1a2b3c4d" title="Name">…</span>`, so it moves with the text and survives other programs.
final class WriterBookmark: NSObject {
    let id: String
    let title: String

    init(id: String = WriterBookmark.newID(), title: String) {
        self.id = id
        self.title = title
    }

    static func newID() -> String { "lz-" + UUID().uuidString.prefix(8).lowercased() }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? WriterBookmark else { return false }
        return other.id == id && other.title == title
    }

    override var hash: Int { id.hashValue ^ title.hashValue }

    var openingTag: String {
        "<span id=\"\(Self.escapeAttribute(id))\" title=\"\(Self.escapeAttribute(title))\">"
    }

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func unescapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The attributes of a `<span …>` tag; nil if it has no id (then it is no bookmark).
    static func parseTag(_ tag: String) -> WriterBookmark? {
        var values: [String: String] = [:]
        let pattern = #"([a-zA-Z-]+)\s*=\s*"([^"]*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = tag as NSString
        for match in expression.matches(in: tag, range: NSRange(location: 0, length: text.length)) {
            values[text.substring(with: match.range(at: 1)).lowercased()] = unescapeAttribute(text.substring(with: match.range(at: 2)))
        }
        guard let id = values["id"], !id.isEmpty else { return nil }
        return WriterBookmark(id: id, title: values["title"] ?? "")
    }

    /// Markdown without bookmark spans (for prompts, titles and exports that don't need them).
    static func strip(_ markdown: String) -> String {
        guard markdown.contains("<span") else { return markdown }
        return markdown
            .replacingOccurrences(of: #"<span\s+[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "</span>", with: "")
    }
}

/// A table in the editor. All cells of a table share this object through their attributes; each cell is one
/// paragraph, and its newline carries the cell's place. It never changes: a new column or alignment builds the
/// table anew, so undo brings back the old one.
final class WriterTable: NSObject {
    let columns: Int
    let alignments: [MarkdownBlock.Alignment]
    /// Each column's share of the table's text width (without the cells' padding), adding up to 1; nil: equal columns.
    let widths: [CGFloat]?
    /// Merged cells by their first place. The places they cover have no paragraph (see `WriterTableMerge`).
    let spans: [WriterCellPosition: WriterCellSpan]
    /// Lines, their weight and the cells' colours.
    let style: WriterTableStyle
    /// The places merged cells cover.
    let covered: Set<WriterCellPosition>
    /// The rows when the table was made (for its last line); 0 when unknown.
    let rowCount: Int
    /// AppKit's table, which lays out the cells.
    let textTable: NSTextTable

    /// The narrowest a column gets when its border is dragged.
    static let minimumWidth: CGFloat = 0.06

    init(columns: Int, alignments: [MarkdownBlock.Alignment], widths: [CGFloat]? = nil,
         spans: [WriterCellPosition: WriterCellSpan] = [:], style: WriterTableStyle = WriterTableStyle(), rows: Int = 0) {
        self.columns = max(1, columns)
        self.alignments = (0..<self.columns).map { $0 < alignments.count ? alignments[$0] : .leading }
        self.widths = Self.normalized(widths, columns: self.columns)
        // Spans stay inside the columns; a single cell is no span.
        let columnCount = self.columns
        self.spans = spans.reduce(into: [:]) { result, entry in
            guard entry.key.column < columnCount else { return }
            let span = WriterCellSpan(rows: max(1, entry.value.rows), columns: max(1, min(entry.value.columns, columnCount - entry.key.column)))
            if !span.isSingle { result[entry.key] = span }
        }
        self.style = style
        rowCount = rows
        covered = WriterTableMerge.covered(by: self.spans)
        let table = NSTextTable()
        table.numberOfColumns = self.columns
        // Widths of their own are kept even when a cell's text would want more room.
        table.layoutAlgorithm = self.widths == nil ? .automaticLayoutAlgorithm : .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(16, type: .absoluteValueType, for: .margin, edge: .maxY)
        textTable = table
    }

    func alignment(of column: Int) -> MarkdownBlock.Alignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// How far the cell at this place reaches (one row and column for an ordinary cell).
    func span(row: Int, column: Int) -> WriterCellSpan {
        spans[WriterCellPosition(row: row, column: column)] ?? WriterCellSpan(rows: 1, columns: 1)
    }

    func isCovered(row: Int, column: Int) -> Bool {
        covered.contains(WriterCellPosition(row: row, column: column))
    }

    /// The same table with other merged cells or another look.
    func with(spans: [WriterCellPosition: WriterCellSpan]? = nil, style: WriterTableStyle? = nil, widths: [CGFloat]?? = nil) -> WriterTable {
        WriterTable(columns: columns, alignments: alignments, widths: widths ?? self.widths, spans: spans ?? self.spans, style: style ?? self.style,
                    rows: rowCount)
    }

    /// The share of a column, also for equal columns.
    func width(of column: Int) -> CGFloat {
        guard let widths, column < widths.count else { return 1 / CGFloat(columns) }
        return widths[column]
    }

    /// Shares that add up to 1, none narrower than `minimumWidth`; nil when they are missing, don't fit the columns
    /// or are all the same.
    static func normalized(_ widths: [CGFloat]?, columns: Int) -> [CGFloat]? {
        guard let widths, widths.count == columns, columns > 1, widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var shares = widths.map { max($0, minimumWidth) }
        let total = shares.reduce(0, +)
        shares = shares.map { $0 / total }
        guard let first = shares.first, shares.contains(where: { abs($0 - first) > 0.004 }) else { return nil }
        return shares
    }

    /// The dashes of each column in the Markdown separator line: the percentages, adding up to exactly 100
    /// (`MarkdownParser.widths(of:)` reads them back only then).
    static func dashCounts(_ widths: [CGFloat]) -> [Int] {
        let exact = widths.map { $0 * 100 }
        var counts = exact.map { max(1, Int($0.rounded(.down))) }
        // The largest remainders get the dashes that are missing; a surplus comes off the widest columns.
        var missing = 100 - counts.reduce(0, +)
        let byRemainder = exact.indices.sorted { exact[$0] - exact[$0].rounded(.down) > exact[$1] - exact[$1].rounded(.down) }
        var index = 0
        while missing > 0, !byRemainder.isEmpty {
            counts[byRemainder[index % byRemainder.count]] += 1
            missing -= 1
            index += 1
        }
        while missing < 0, let widest = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[widest] > 1 {
            counts[widest] -= 1
            missing += 1
        }
        return counts
    }
}

/// Where a paragraph sits in a table.
struct WriterTableCell {
    let table: WriterTable
    let row: Int
    let column: Int

    init(table: WriterTable, row: Int, column: Int) {
        self.table = table
        self.row = row
        self.column = column
    }

    init?(_ attributes: [NSAttributedString.Key: Any]) {
        guard let table = attributes[.writerTable] as? WriterTable else { return nil }
        self.init(table: table, row: attributes[.writerTableRow] as? Int ?? 0, column: attributes[.writerTableColumn] as? Int ?? 0)
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.writerBlock: WriterBlock.table.rawValue, .writerListLevel: 0, .writerTable: table, .writerTableRow: row, .writerTableColumn: column]
    }
}

extension MarkdownBlock.Alignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    /// The column's separator in a Markdown table; the number of dashes says its width (see `WriterTable.dashCounts`).
    func separator(dashes: Int = 3) -> String {
        let line = String(repeating: "-", count: max(1, dashes))
        switch self {
        case .leading: return line
        case .center: return ":" + line + ":"
        case .trailing: return line + ":"
        }
    }
}

/// Inline marks of a stretch of text. Underline, strikethrough and links use the standard attributes.
struct WriterInline: OptionSet, Hashable {
    let rawValue: Int
    static let bold = WriterInline(rawValue: 1 << 0)
    static let italic = WriterInline(rawValue: 1 << 1)
    static let underline = WriterInline(rawValue: 1 << 2)
    static let strikethrough = WriterInline(rawValue: 1 << 3)
    static let code = WriterInline(rawValue: 1 << 4)
    static let superscript = WriterInline(rawValue: 1 << 5)
    static let `subscript` = WriterInline(rawValue: 1 << 6)

    /// The marks that are stored as keys of their own (and taken along when text is typed).
    static let keys: [NSAttributedString.Key] = [.writerBold, .writerItalic, .writerCode, .underlineStyle, .strikethroughStyle, .writerSuperscript, .writerSubscript]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ attributes: [NSAttributedString.Key: Any]) {
        var marks: WriterInline = []
        if attributes[.writerBold] as? Bool == true { marks.insert(.bold) }
        if attributes[.writerItalic] as? Bool == true { marks.insert(.italic) }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { marks.insert(.underline) }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { marks.insert(.strikethrough) }
        if attributes[.writerCode] as? Bool == true { marks.insert(.code) }
        if attributes[.writerSuperscript] as? Bool == true { marks.insert(.superscript) }
        if attributes[.writerSubscript] as? Bool == true { marks.insert(.subscript) }
        self = marks
    }

    /// The attribute that carries this single mark, and its "on" value.
    var attribute: (key: NSAttributedString.Key, value: Any)? {
        switch self {
        case .bold: (.writerBold, true)
        case .italic: (.writerItalic, true)
        case .underline: (.underlineStyle, NSUnderlineStyle.single.rawValue)
        case .strikethrough: (.strikethroughStyle, NSUnderlineStyle.single.rawValue)
        case .code: (.writerCode, true)
        case .superscript: (.writerSuperscript, true)
        case .subscript: (.writerSubscript, true)
        default: nil
        }
    }

    /// Raised and lowered text exclude each other: setting one takes the other away.
    var opposite: WriterInline? {
        switch self {
        case .superscript: .subscript
        case .subscript: .superscript
        default: nil
        }
    }
}

/// A horizontal line on its own paragraph (Markdown `---`). The editor draws it; see `WriterRuleCell`.
class WriterRuleAttachment: NSTextAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterRuleCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterRuleCell()
    }
}

/// A page break on its own paragraph (Markdown `\newpage`). It is a line like `WriterRuleAttachment` in the editor,
/// drawn as a dashed line with its name (`WriterPageBreakCell`); the pages count from it, and print begins a new page.
final class WriterPageBreakAttachment: WriterRuleAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterPageBreakCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterPageBreakCell()
    }
}

/// Converts between the Markdown a document is stored as and the text the editor shows. The text carries only
/// the meaning (block, list level, inline marks); `WriterStyler` adds fonts and colours from it.
enum WriterMarkdown {
    static let lineSeparator: Character = "\u{2028}"
    /// The attributes that say what a paragraph is; text inserted into a paragraph takes these along.
    static let paragraphKeys: Set<NSAttributedString.Key> = Set([.writerBlock, .writerListLevel, .writerTable, .writerTableRow, .writerTableColumn,
                                                                 .writerBox, .writerColumns] + WriterParagraphFormat.keys)
    /// What a paragraph stands in besides its format: a box, a section in columns.
    static let containerKeys: [NSAttributedString.Key] = [.writerBox, .writerColumns]
    static let tableKeys: [NSAttributedString.Key] = [.writerTable, .writerTableRow, .writerTableColumn]
    /// What a passage carries besides the inline marks: its colour, font and size.
    static let passageKeys: [NSAttributedString.Key] = [.writerColor, .writerFont, .writerFontSize]

    // MARK: Markdown → text

    static func attributedString(from markdown: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var previous: [NSAttributedString.Key: Any]?
        /// The paragraph format of the div the current Markdown block stands in.
        var format = WriterParagraphFormat()
        /// The box and the section in columns it stands in; each div becomes one object.
        var box: WriterBox?
        var section: WriterColumnSection?
        var boxes: [Int: WriterBox] = [:]
        var sections: [Int: WriterColumnSection] = [:]

        /// Appends a paragraph. Its newline comes with the next paragraph but carries this paragraph's
        /// attributes, so empty paragraphs keep their block too.
        func add(_ paragraph: NSAttributedString, block: WriterBlock, level: Int = 0, language: String? = nil, cell: WriterTableCell? = nil) {
            if let previous { result.append(NSAttributedString(string: "\n", attributes: previous)) }
            var attributes: [NSAttributedString.Key: Any] = cell?.attributes ?? [.writerBlock: block.rawValue, .writerListLevel: level]
            if let language, !language.isEmpty { attributes[.writerCodeLanguage] = language }
            if cell == nil { attributes.merge(format.applying(to: block).attributes) { $1 } }
            if cell == nil, let box, WriterBox.holds(block) { attributes[.writerBox] = box }
            if cell == nil, let section, WriterColumnSection.holds(block) { attributes[.writerColumns] = section }
            let start = result.length
            result.append(paragraph)
            result.addAttributes(attributes, range: NSRange(location: start, length: result.length - start))
            previous = attributes
        }

        var endsWithTable = false
        var previousWasCode = false
        for annotated in MarkdownParser.parseAnnotated(markdown) {
            let block = annotated.block
            format = WriterParagraphFormat(classes: annotated.formatClasses, attributes: annotated.formatAttributes)
            box = annotated.div(WriterBoxStyle.className).map { div in
                if let known = boxes[div.serial] { return known }
                let made = WriterBox(style: WriterBoxStyle(attributes: div.attributes))
                boxes[div.serial] = made
                return made
            }
            section = annotated.div(WriterColumnStyle.className).map { div in
                if let known = sections[div.serial] { return known }
                let made = WriterColumnSection(style: WriterColumnStyle(attributes: div.attributes))
                sections[div.serial] = made
                return made
            }
            endsWithTable = false
            let followsCode = previousWasCode
            previousWasCode = false
            switch block {
            case .paragraph(let text):
                // A line that is only a picture becomes a picture of its own.
                var lines: [String] = []
                func addText() {
                    guard !lines.isEmpty else { return }
                    add(inline(lines.joined(separator: String(lineSeparator))), block: .paragraph)
                    lines = []
                }
                for line in text.components(separatedBy: "\n") {
                    if let image = WriterImageReference.parse(line) {
                        addText()
                        add(NSAttributedString(attachment: WriterImageAttachment(reference: image)), block: .image)
                    } else if let dynamic = WriterTOCAttachment.kind(of: line) {
                        addText()
                        add(NSAttributedString(attachment: WriterTOCAttachment(dynamic: dynamic)), block: .toc)
                    } else if WriterBibliographyAttachment.isMarker(line) {
                        addText()
                        add(NSAttributedString(attachment: WriterBibliographyAttachment()), block: .toc)
                    } else {
                        lines.append(line)
                    }
                }
                addText()
            case .heading(let level, let text):
                let (title, classes) = headingAttributes(text)
                var block: WriterBlock = level <= 1 ? .heading1 : level == 2 ? .heading2 : .heading3
                if classes.contains("chapter") { block = .chapter }
                add(inline(title), block: block)
            case .code(let language, let code):
                // Two code blocks in a row stay two: an empty paragraph keeps them apart (consecutive code paragraphs are
                // one block, with one language).
                if followsCode { add(NSAttributedString(), block: .paragraph) }
                for line in code.components(separatedBy: "\n") {
                    add(NSAttributedString(string: line), block: .code, language: language)
                }
                previousWasCode = true
            case .list(let items):
                for item in items {
                    let text = item.text.replacingOccurrences(of: "\n", with: String(lineSeparator))
                    add(inline(text), block: item.marker == nil ? .bullet : .numbered, level: min(item.level, 5))
                }
            case .quote(let text):
                for line in text.components(separatedBy: "\n") {
                    add(inline(line), block: .quote)
                }
            case .rule:
                let attachment = WriterRuleAttachment()
                add(NSAttributedString(attachment: attachment), block: .rule)
            case .pageBreak:
                add(NSAttributedString(attachment: WriterPageBreakAttachment()), block: .rule)
            case .columnBreak:
                add(NSAttributedString(attachment: WriterColumnBreakAttachment()), block: .rule)
            case .table(let header, let rows, let alignments, let widths):
                let columns = max(header.count, rows.map(\.count).max() ?? 0, 1)
                let all = [header] + rows
                // Merged cells and the look come with the cells' marks and the div around the table.
                let style = annotated.div(WriterTableStyle.className).map { WriterTableStyle(attributes: $0.attributes) } ?? WriterTableStyle()
                let table = WriterTable(columns: columns, alignments: alignments, widths: widths?.map { CGFloat($0) },
                                        spans: WriterTableMerge.spans(in: all, columns: columns), style: style, rows: all.count)
                for (index, cells) in all.enumerated() {
                    for column in 0..<columns where !table.isCovered(row: index, column: column) {
                        let text = column < cells.count ? cells[column] : ""
                        add(inline(cellText(text)), block: .table, cell: WriterTableCell(table: table, row: index, column: column))
                    }
                }
                endsWithTable = true
            case .math(let latex, let complete):
                if complete, !latex.isEmpty {
                    add(NSAttributedString(attachment: WriterMathAttachment(latex: latex)), block: .math)
                    break
                }
                // A formula without its closing `$$` stays Markdown.
                let lines = latex.hasPrefix("\\begin") ? [latex] : ["$$", latex]
                for line in lines.joined(separator: "\n").components(separatedBy: "\n") {
                    add(NSAttributedString(string: line), block: .raw)
                }
            }
        }
        // Every cell ends with its newline, the last one too: text after the table is never part of a cell.
        if endsWithTable, let previous { result.append(NSAttributedString(string: "\n", attributes: previous)) }
        return result
    }

    /// The Markdown without the fence lines of divs (the alignment of paragraphs): for the model, which needn't see
    /// them, and for text that is laid out anew elsewhere (slides from a document, a handout from slides).
    static func removingDivFences(_ markdown: String) -> String {
        guard markdown.contains(":::") else { return markdown }
        return markdown.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return MarkdownParser.divOpening(trimmed) == nil && !MarkdownParser.isDivClosing(trimmed)
        }.joined(separator: "\n")
    }

    /// Text that changes its kind of page: without alignment, and without the sizes of passages, which are points of
    /// the print in a document and points of the canvas on a slide.
    static func forOtherLayout(_ markdown: String) -> String {
        WriterSpans.strippingSizes(removingDivFences(markdown))
    }

    /// A heading's text without Pandoc's trailing attributes (`Titel {.chapter}`), and the classes in them.
    static func headingAttributes(_ text: String) -> (text: String, classes: Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("}"), let open = trimmed.range(of: " {", options: .backwards) else { return (trimmed, []) }
        let inner = trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)]
        let tokens = inner.split(separator: " ")
        guard !tokens.isEmpty, tokens.allSatisfy({ $0.hasPrefix(".") || $0.hasPrefix("#") || $0.contains("=") }) else { return (trimmed, []) }
        let classes = Set(tokens.filter { $0.hasPrefix(".") }.map { String($0.dropFirst()) })
        return (String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces), classes)
    }

    /// A Markdown cell's text: `<br>` is a line break in the cell.
    private static func cellText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<br\s*/?>"#, with: String(lineSeparator), options: [.regularExpression, .caseInsensitive])
    }

    /// Inline Markdown: `**bold**`, `*italic*`, `<u>underlined</u>`, `~~struck~~`, `` `code` `` and `[links](url)`.
    static func inline(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendInline(Array(text), marks: [], link: nil, bookmark: nil, comment: nil, style: nil, to: result)
        return result
    }

    private static func appendInline(_ characters: [Character], marks initial: WriterInline, link: String?, bookmark: WriterBookmark?,
                                     comment: WriterComment?, style: WriterSpanStyle?, to result: NSMutableAttributedString) {
        var marks = initial
        var buffer = ""
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: attributes(marks, link: link, bookmark: bookmark, comment: comment, style: style)))
            buffer = ""
        }
        /// An inline formula becomes a picture in the text that carries the marks around it.
        func appendFormula(_ latex: String) {
            let latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return }
            flush()
            let formula = NSMutableAttributedString(attachment: WriterMathAttachment(latex: latex))
            formula.addAttributes(attributes(marks, link: link, bookmark: bookmark, comment: comment, style: style), range: NSRange(location: 0, length: formula.length))
            result.append(formula)
        }
        func matches(_ token: String, at position: Int) -> Bool {
            let token = Array(token)
            guard position + token.count <= characters.count else { return false }
            return Array(characters[position..<position + token.count]) == token
        }
        /// Position of the next unescaped `token` after `position`.
        func closing(_ token: String, after position: Int) -> Int? {
            var scan = position
            while scan < characters.count {
                if characters[scan] == "\\" { scan += 2; continue }
                if matches(token, at: scan) { return scan }
                scan += 1
            }
            return nil
        }
        /// A closing mark follows text, not a space ("3 * 4" has no emphasis).
        func canClose(at position: Int) -> Bool {
            position > 0 && !characters[position - 1].isWhitespace
        }
        /// `<sup>` and `<sub>` open only when they are closed later, like `<u>`.
        func toggleTag(_ name: String, _ mark: WriterInline) -> Bool {
            if !marks.contains(mark), matches("<\(name)>", at: index), closing("</\(name)>", after: index + name.count + 2) != nil {
                flush()
                marks.insert(mark)
                index += name.count + 2
                return true
            }
            if marks.contains(mark), matches("</\(name)>", at: index) {
                flush()
                marks.remove(mark)
                index += name.count + 3
                return true
            }
            return false
        }
        func toggle(_ mark: WriterInline, token: String) -> Bool {
            if marks.contains(mark) {
                guard canClose(at: index) else { return false }
                flush()
                marks.remove(mark)
                index += token.count
                return true
            }
            // Opens only before text and when it is closed later, so a lone "*" stays a star.
            let after = index + token.count
            guard after < characters.count, !characters[after].isWhitespace else { return false }
            var search = after
            var end: Int?
            while let candidate = closing(token, after: search) {
                if candidate > after, canClose(at: candidate) { end = candidate; break }
                search = candidate + 1
            }
            guard end != nil else { return false }
            flush()
            marks.insert(mark)
            index += token.count
            return true
        }

        while index < characters.count {
            let character = characters[index]

            // Formulas: `$…$` (Pandoc's rules, so "5 $ und 10 $" stays text), `$$…$$` and `\(…\)`.
            if character == "$" {
                if index + 1 < characters.count, characters[index + 1] == "$",
                   let close = find(["$", "$"], in: characters, from: index + 2), close > index + 2 {
                    appendFormula(String(characters[(index + 2)..<close]))
                    index = close + 2
                    continue
                }
                if index + 1 < characters.count, !characters[index + 1].isWhitespace, characters[index + 1] != "$",
                   let close = MathTokenizer.inlineDollarClose(in: characters, from: index + 1) {
                    appendFormula(String(characters[(index + 1)..<close]))
                    index = close + 1
                    continue
                }
            }
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "(",
               let close = find(["\\", ")"], in: characters, from: index + 2) {
                appendFormula(String(characters[(index + 2)..<close]))
                index = close + 2
                continue
            }
            // A span: a bookmark (`<span id="…" title="…">`) or a colour and font (`<span style="color:#C0392B">`),
            // which may contain each other.
            if character == "<", matches("<span", at: index), let tagEnd = characters[index...].firstIndex(of: ">"),
               let close = WriterSpans.closing(in: characters, from: tagEnd + 1) {
                flush()
                let tag = String(characters[index...tagEnd])
                let inner = Array(characters[(tagEnd + 1)..<close])
                let mark = bookmark ?? WriterBookmark.parseTag(tag)
                let innerComment = WriterComment.parseTag(tag) ?? comment
                let innerStyle = WriterSpanStyle(tag: tag).map { $0.over(style) } ?? style
                appendInline(inner, marks: marks, link: link, bookmark: mark, comment: innerComment, style: innerStyle, to: result)
                index = close + 7
                continue
            }

            if character == "\\", index + 1 < characters.count, characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`" {
                var fence = 0
                while index + fence < characters.count, characters[index + fence] == "`" { fence += 1 }
                let token = String(repeating: "`", count: fence)
                if let end = closing(token, after: index + fence) {
                    flush()
                    var code = String(characters[(index + fence)..<end])
                    if fence > 1, code.hasPrefix(" "), code.hasSuffix(" "), code.count >= 2 {
                        code = String(code.dropFirst().dropLast())
                    }
                    result.append(NSAttributedString(string: code, attributes: attributes(marks.union(.code), link: link, bookmark: bookmark, comment: comment, style: style)))
                    index = end + fence
                    continue
                }
            }
            if matches("**", at: index), toggle(.bold, token: "**") { continue }
            if matches("__", at: index), toggle(.bold, token: "__") { continue }
            if matches("~~", at: index), toggle(.strikethrough, token: "~~") { continue }
            if matches("<u>", at: index), !marks.contains(.underline), closing("</u>", after: index + 3) != nil {
                flush()
                marks.insert(.underline)
                index += 3
                continue
            }
            if matches("</u>", at: index), marks.contains(.underline) {
                flush()
                marks.remove(.underline)
                index += 4
                continue
            }
            if toggleTag("sup", .superscript) || toggleTag("sub", .subscript) { continue }
            if character == "*", toggle(.italic, token: "*") { continue }
            if character == "_" {
                // Underscores inside words (snake_case) are no emphasis.
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + 1 < characters.count ? characters[index + 1] : " "
                let inWord = (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
                if !inWord, toggle(.italic, token: "_") { continue }
            }
            // A citation: `[@key, S. 12]`, `[vgl. @a; @b]` (Pandoc), but not a link `[…](…)`.
            if character == "[", let close = characters[(index + 1)...].firstIndex(where: { $0 == "]" || $0 == "[" || $0 == "\n" }),
               characters[close] == "]", close + 1 >= characters.count || characters[close + 1] != "(",
               characters[(index + 1)..<close].contains("@"), let items = CitationMarkup.parse(String(characters[(index + 1)..<close])) {
                flush()
                let citation = NSMutableAttributedString(attachment: WriterCitationAttachment(items: items))
                citation.addAttributes(attributes(marks, link: link, bookmark: bookmark, comment: comment, style: style), range: NSRange(location: 0, length: citation.length))
                result.append(citation)
                index = close + 1
                continue
            }
            if character == "[", link == nil, let (text, url, end) = linkSyntax(in: characters, at: index) {
                flush()
                appendInline(text, marks: marks, link: url, bookmark: bookmark, comment: comment, style: style, to: result)
                index = end
                continue
            }
            buffer.append(character)
            index += 1
        }
        flush()
    }

    private static func find(_ pattern: [Character], in characters: [Character], from start: Int) -> Int? {
        guard !pattern.isEmpty, start >= 0, characters.count >= pattern.count, start <= characters.count - pattern.count else { return nil }
        var index = start
        while index <= characters.count - pattern.count {
            if characters[index] == pattern[0], Array(characters[index..<(index + pattern.count)]) == pattern { return index }
            index += 1
        }
        return nil
    }

    /// `[text](url)` starting at `position`: the text, the address and the position after it.
    private static func linkSyntax(in characters: [Character], at position: Int) -> ([Character], String, Int)? {
        var depth = 0
        var scan = position
        var closeBracket: Int?
        while scan < characters.count {
            switch characters[scan] {
            case "\\": scan += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { closeBracket = scan }
            default: break
            }
            if closeBracket != nil { break }
            scan += 1
        }
        guard let closeBracket, closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(",
              let closeParen = characters[(closeBracket + 2)...].firstIndex(of: ")") else { return nil }
        let url = String(characters[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        return (Array(characters[(position + 1)..<closeBracket]), url, closeParen + 1)
    }

    private static func attributes(_ marks: WriterInline, link: String?, bookmark: WriterBookmark?, comment: WriterComment?,
                                   style: WriterSpanStyle?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = style?.attributes ?? [:]
        for mark in [WriterInline.bold, .italic, .underline, .strikethrough, .code, .superscript, .subscript] where marks.contains(mark) {
            if let attribute = mark.attribute { attributes[attribute.key] = attribute.value }
        }
        if let link { attributes[.link] = link }
        if let bookmark { attributes[.writerBookmark] = bookmark }
        if let comment { attributes[.writerComment] = comment }
        return attributes
    }

    // MARK: Text → Markdown

    struct Paragraph {
        let range: NSRange
        /// Without the newline at the end.
        let contentRange: NSRange
        let block: WriterBlock
        let level: Int
        let language: String?
        /// Set for a table cell. A paragraph is a cell when its newline belongs to a table; text typed or pasted
        /// in front of a cell can't make another paragraph one.
        let cell: WriterTableCell?
        /// Its own format (from its first character): what of it the block takes.
        let format: WriterParagraphFormat
        /// The box and the section in columns it stands in (from its first character).
        var box: WriterBox? = nil
        var section: WriterColumnSection? = nil

        /// Its own alignment, for blocks that take one.
        var alignment: WriterAlignment? { format.alignment }
    }

    static func paragraphs(of text: NSAttributedString, in range: NSRange? = nil) -> [Paragraph] {
        let string = text.string as NSString
        let limit = range ?? NSRange(location: 0, length: string.length)
        var result: [Paragraph] = []
        var location = string.paragraphRange(for: NSRange(location: limit.location, length: 0)).location
        let end = NSMaxRange(limit)
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let attributes = paragraph.length > 0 ? text.attributes(at: paragraph.location, effectiveRange: nil) : [:]
            let cell = content.length < paragraph.length
                ? WriterTableCell(text.attributes(at: NSMaxRange(paragraph) - 1, effectiveRange: nil))
                : nil
            var block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            if cell != nil { block = .table } else if block == .table { block = .paragraph }
            result.append(Paragraph(
                range: paragraph,
                contentRange: content,
                block: block,
                level: attributes[.writerListLevel] as? Int ?? 0,
                language: attributes[.writerCodeLanguage] as? String,
                cell: cell,
                format: cell == nil ? WriterParagraphFormat(attributes).applying(to: block) : WriterParagraphFormat(),
                box: cell == nil && WriterBox.holds(block) ? attributes[.writerBox] as? WriterBox : nil,
                section: cell == nil && WriterColumnSection.holds(block) ? attributes[.writerColumns] as? WriterColumnSection : nil
            ))
            location = NSMaxRange(paragraph)
        } while location < end && location < string.length
        return result
    }

    static func markdown(from text: NSAttributedString) -> String {
        // Each block with the opening line of the div around it (its format, or a table's look), and the box and section
        // in columns it stands in.
        var blocks: [OutputBlock] = []
        var pending: [String] = []
        var pendingKind: WriterBlock?
        var pendingFormat = WriterParagraphFormat()
        var pendingBox: WriterBox?
        var pendingSection: WriterColumnSection?
        var listCounters: [Int] = []
        var currentLanguage: String?
        var currentTable: WriterTable?
        var tableCells: [Int: [Int: String]] = [:]

        func flush() {
            defer {
                pending = []
                pendingKind = nil
                pendingFormat = WriterParagraphFormat()
                pendingBox = nil
                pendingSection = nil
                listCounters = []
                currentTable = nil
                tableCells = [:]
            }
            if pendingKind == .table, let table = currentTable {
                blocks.append(OutputBlock(text: tableMarkdown(table, cells: tableCells), div: table.style.divOpening, section: pendingSection))
                return
            }
            guard let kind = pendingKind, !pending.isEmpty else { return }
            switch kind {
            case .code:
                let language = currentLanguage ?? ""
                blocks.append(OutputBlock(text: "```\(language)\n" + pending.joined(separator: "\n") + "\n```", div: nil, box: pendingBox, section: pendingSection))
            default:
                blocks.append(OutputBlock(text: pending.joined(separator: "\n"), div: pendingFormat.divOpening, box: pendingBox, section: pendingSection))
            }
        }

        for paragraph in paragraphs(of: text) {
            let content = text.attributedSubstring(from: paragraph.contentRange)
            let group: WriterBlock = paragraph.block.isList ? .bullet : paragraph.block
            let grouped: Set<WriterBlock> = [.bullet, .quote, .code, .raw, .table]
            if pendingKind != group || !grouped.contains(group) || (group == .table && paragraph.cell?.table !== currentTable)
                || paragraph.format != pendingFormat || paragraph.box !== pendingBox || paragraph.section !== pendingSection { flush() }

            switch paragraph.block {
            case .table:
                guard let cell = paragraph.cell else { continue }
                currentTable = cell.table
                tableCells[cell.row, default: [:]][cell.column] = inlineMarkdown(content)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>")
            case .image:
                guard let image = images(in: content).first else { continue }
                pending.append(image.markdown)
            case .math:
                guard let formula = formulas(in: content).first else { continue }
                pending.append(formula.blockMarkdown)
            case .toc:
                var toc: WriterTOCAttachment?
                var bibliography = false
                content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
                    if let value = value as? WriterTOCAttachment { toc = value }
                    if value is WriterBibliographyAttachment { bibliography = true }
                }
                pending.append(bibliography ? WriterBibliographyAttachment.marker : toc?.markdown ?? WriterTOCAttachment.marker)
            case .code:
                if pendingKind == nil { currentLanguage = paragraph.language }
                pending.append(plainString(content).replacingOccurrences(of: String(lineSeparator), with: "\n"))
            case .raw:
                pending.append(plainString(content))
            case .rule:
                let attachment = text.attribute(.attachment, at: paragraph.range.location, effectiveRange: nil)
                pending.append(attachment is WriterPageBreakAttachment ? "\\newpage" : attachment is WriterColumnBreakAttachment ? MarkdownParser.columnBreakCommand : "---")
            case .bullet, .numbered:
                let line = inlineMarkdown(content)
                guard !line.isEmpty else { continue }
                let level = paragraph.level
                if listCounters.count <= level { listCounters += Array(repeating: 0, count: level + 1 - listCounters.count) }
                listCounters = Array(listCounters.prefix(level + 1))
                // A bullet between numbered items starts the count again.
                if paragraph.block == .bullet { listCounters[level] = 0 } else { listCounters[level] += 1 }
                let indent = String(repeating: "  ", count: level)
                let marker = paragraph.block == .numbered ? "\(listCounters[level])." : "-"
                pending.append(indent + marker + " " + line.replacingOccurrences(of: "\n", with: "\n" + indent + "  "))
            case .quote:
                let line = inlineMarkdown(content)
                pending.append(line.isEmpty ? ">" : "> " + line.replacingOccurrences(of: "\n", with: "\n> "))
            case .heading1, .heading2, .heading3:
                let line = inlineMarkdown(content).replacingOccurrences(of: "\n", with: " ")
                guard !line.isEmpty else { continue }
                let hashes = paragraph.block == .heading1 ? "#" : paragraph.block == .heading2 ? "##" : "###"
                pending.append(hashes + " " + line)
            case .chapter:
                let line = inlineMarkdown(content).replacingOccurrences(of: "\n", with: " ")
                guard !line.isEmpty else { continue }
                pending.append("# " + line + " {.chapter}")
            case .paragraph:
                let line = inlineMarkdown(content)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { pending.append(line) }
            }
            pendingKind = group
            pendingFormat = paragraph.format
            pendingBox = paragraph.box
            pendingSection = paragraph.cell == nil ? paragraph.section : (text.attribute(.writerColumns, at: paragraph.range.location, effectiveRange: nil) as? WriterColumnSection)
            // A picture that ended up inside text (after joining paragraphs) is kept as a paragraph of its own.
            if !paragraph.block.isEmbed, paragraph.block != .table {
                let inlineImages = images(in: content)
                if !inlineImages.isEmpty {
                    let box = paragraph.box, section = paragraph.section
                    flush()
                    blocks += inlineImages.map { OutputBlock(text: $0.markdown, div: nil, box: box, section: section) }
                }
            }
        }
        flush()
        // Drop quote lines that were only empty and trailing "> " noise.
        let kept = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text != ">" }
        // Blocks of one section in columns share its div, those of one box inside it the box's, and paragraphs in a row
        // that are set alike one div inside that.
        func wrap<Key>(_ items: ArraySlice<OutputBlock>, by key: (OutputBlock) -> Key?, same: (Key?, Key?) -> Bool, opening: (Key) -> String,
                       inner: (ArraySlice<OutputBlock>) -> [String]) -> [String] {
            var output: [String] = []
            var index = items.startIndex
            while index < items.endIndex {
                let current = key(items[index])
                var end = index
                while end < items.endIndex, same(key(items[end]), current) { end += 1 }
                let content = inner(items[index..<end])
                if let current {
                    output.append(opening(current) + "\n" + content.joined(separator: "\n\n") + "\n:::")
                } else {
                    output += content
                }
                index = end
            }
            return output
        }
        let output = wrap(kept[...], by: \.section, same: { $0 === $1 }, opening: { $0.style.divOpening }) { sectionItems in
            wrap(sectionItems, by: \.box, same: { $0 === $1 }, opening: { $0.style.divOpening }) { boxItems in
                wrap(boxItems, by: \.div, same: { $0 == $1 }, opening: { $0 }) { divItems in divItems.map(\.text) }
            }
        }
        return output.joined(separator: "\n\n") + "\n"
    }

    /// A block of the Markdown being written, with what stands around it.
    private struct OutputBlock {
        let text: String
        let div: String?
        var box: WriterBox? = nil
        var section: WriterColumnSection? = nil
    }

    private static func formulas(in text: NSAttributedString) -> [WriterMathAttachment] {
        var formulas: [WriterMathAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let formula = value as? WriterMathAttachment { formulas.append(formula) }
        }
        return formulas
    }

    private static func images(in text: NSAttributedString) -> [WriterImageReference] {
        var references: [WriterImageReference] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let image = value as? WriterImageAttachment { references.append(image.reference) }
        }
        return references
    }

    private static func tableMarkdown(_ table: WriterTable, cells: [Int: [Int: String]]) -> String {
        let rows = max((cells.keys.max() ?? 0) + 1, table.spans.map { $0.key.row + $0.value.rows }.max() ?? 0)
        var lines: [String] = []
        for row in 0..<rows {
            let values = (0..<table.columns).map { column -> String in
                if let marker = WriterTableMerge.marker(for: WriterCellPosition(row: row, column: column), in: table.spans) { return marker }
                let value = cells[row]?[column] ?? ""
                // A cell that only says "^^" would merge with the one above.
                return value.trimmingCharacters(in: .whitespaces) == WriterTableMerge.upMarker ? "\\^\\^" : value
            }
            lines.append("| " + values.joined(separator: " | ") + " |")
            if row == 0 {
                let dashes = table.widths.map(WriterTable.dashCounts) ?? Array(repeating: 3, count: table.columns)
                lines.append("| " + zip(table.alignments, dashes).map { $0.separator(dashes: $1) }.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The text without dictation that is still being recognised.
    private static func plainString(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.writerDictationPreview, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { result += (text.string as NSString).substring(with: range) }
        }
        return result
    }

    /// One paragraph's text with its inline marks as Markdown. Line breaks inside it become "\n".
    static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var output = ""
        // Marks currently open, outermost first; a link is kept separately around them, a bookmark around all.
        var open: [WriterInline] = []
        var openLink: String?
        var openBookmark: WriterBookmark?
        var openComment: WriterComment?
        var openStyle: WriterSpanStyle?
        var pendingSpace = ""
        let order: [WriterInline] = [.bold, .italic, .underline, .strikethrough, .superscript, .subscript]

        func closeMarks() {
            for mark in open.reversed() { output += closingToken(mark) }
            open = []
            if let link = openLink {
                output += "](\(link))"
                openLink = nil
            }
        }

        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard attributes[.writerDictationPreview] == nil else { return }
            // Pictures and lines are paragraphs of their own; an inline formula is written as `$…$`, a citation as
            // `[@key, S. 12]`.
            let formula = attributes[.attachment] as? WriterMathAttachment
            let citation = attributes[.attachment] as? WriterCitationAttachment
            guard attributes[.attachment] == nil || formula != nil || citation != nil else { return }
            let raw = formula.map { "$" + $0.latex + "$" } ?? citation?.markdown ?? (text.string as NSString).substring(with: range)
            let isObject = formula != nil || citation != nil
            let marks = WriterInline(attributes)
            let link: String? = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let bookmark = attributes[.writerBookmark] as? WriterBookmark
            let comment = attributes[.writerComment] as? WriterComment
            let spanStyle = WriterSpanStyle(attributes)
            let style: WriterSpanStyle? = spanStyle.isEmpty ? nil : spanStyle

            let leading = isObject ? "" : String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            let rest = raw.dropFirst(leading.count)
            let trailing = isObject ? "" : String(rest.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            let core = String(rest.dropLast(trailing.count))
            guard !core.isEmpty else {
                pendingSpace += raw
                return
            }

            // Close what this stretch doesn't have, from the inside out: marks, link, colour and font, bookmark, comment.
            if openComment != comment {
                closeMarks()
                if openStyle != nil { output += "</span>" }
                openStyle = nil
                if openBookmark != nil { output += "</span>" }
                openBookmark = nil
                if openComment != nil { output += "</span>" }
                openComment = nil
            } else if openBookmark != bookmark {
                closeMarks()
                if openStyle != nil { output += "</span>" }
                openStyle = nil
                if openBookmark != nil { output += "</span>" }
                openBookmark = nil
            } else if openStyle != style {
                closeMarks()
                if openStyle != nil { output += "</span>" }
                openStyle = nil
            } else if openLink != link {
                closeMarks()
            } else if let keep = open.firstIndex(where: { !marks.contains($0) }) {
                for mark in open[keep...].reversed() { output += closingToken(mark) }
                open = Array(open[..<keep])
            }
            output += pendingSpace + leading
            pendingSpace = ""
            if let comment, openComment == nil {
                output += comment.openingTag
                openComment = comment
            }
            if let bookmark, openBookmark == nil {
                output += bookmark.openingTag
                openBookmark = bookmark
            }
            if let style, openStyle == nil {
                output += style.openingTag
                openStyle = style
            }
            if let link, openLink == nil {
                output += "["
                openLink = link
            }
            for mark in order where marks.contains(mark) && !open.contains(mark) {
                output += openingToken(mark)
                open.append(mark)
            }
            if isObject {
                output += core
            } else if marks.contains(.code) {
                let fence = core.contains("`") ? "`` " : "`"
                output += fence + core + String(fence.reversed())
            } else {
                output += escape(core, atLineStart: output.isEmpty || output.last == "\n")
            }
            pendingSpace = trailing
        }
        closeMarks()
        if openStyle != nil { output += "</span>" }
        if openBookmark != nil { output += "</span>" }
        if openComment != nil { output += "</span>" }
        output += pendingSpace
        return output.replacingOccurrences(of: String(lineSeparator), with: "\n")
    }

    private static func openingToken(_ mark: WriterInline) -> String {
        switch mark {
        case .bold: "**"
        case .italic: "*"
        case .underline: "<u>"
        case .strikethrough: "~~"
        case .superscript: "<sup>"
        case .subscript: "<sub>"
        default: ""
        }
    }

    private static func closingToken(_ mark: WriterInline) -> String {
        switch mark {
        case .underline: "</u>"
        case .superscript: "</sup>"
        case .subscript: "</sub>"
        default: openingToken(mark)
        }
    }

    /// Backslashes before characters that would otherwise start Markdown.
    static func escape(_ text: String, atLineStart: Bool) -> String {
        var output = ""
        var lineStart = atLineStart
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if "\\*_`[]<~$".contains(character) {
                output += "\\" + String(character)
            } else if lineStart, "#>".contains(character) {
                output += "\\" + String(character)
            } else if lineStart, character == ":", index + 2 < characters.count, characters[index + 1] == ":", characters[index + 2] == ":" {
                // ":::" would open or close a div.
                output += "\\:"
            } else if lineStart, "-+".contains(character), index + 1 < characters.count, characters[index + 1] == " " {
                output += "\\" + String(character)
            } else if character == ".", index + 1 < characters.count, characters[index + 1] == " ",
                      startsNumberedLine(characters, before: index, atLineStart: atLineStart) {
                output += "\\."
            } else {
                output.append(character)
            }
            lineStart = character == lineSeparator || character == "\n"
        }
        return output
    }

    /// Whether only digits stand between the start of the line and `index` ("1. " would start a list).
    private static func startsNumberedLine(_ characters: [Character], before index: Int, atLineStart: Bool) -> Bool {
        var scan = index - 1
        while scan >= 0, characters[scan].isNumber { scan -= 1 }
        guard scan < index - 1 else { return false }
        if scan < 0 { return atLineStart }
        return characters[scan] == lineSeparator || characters[scan] == "\n"
    }
}
