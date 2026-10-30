import AppKit

/// What kind of box a box is: it gives the colour and the title it starts with.
enum WriterBoxKind: String, CaseIterable, Identifiable, Sendable {
    case definition, merksatz, beispiel, hinweis, achtung, eigener

    var id: String { rawValue }

    var label: String {
        switch self {
        case .definition: "Definition"
        case .merksatz: "Merksatz"
        case .beispiel: "Beispiel"
        case .hinweis: "Hinweis"
        case .achtung: "Achtung"
        case .eigener: "Kasten"
        }
    }

    var symbol: String {
        switch self {
        case .definition: "book.closed"
        case .merksatz: "lightbulb"
        case .beispiel: "list.bullet.rectangle"
        case .hinweis: "info.circle"
        case .achtung: "exclamationmark.triangle"
        case .eigener: "square.text.square"
        }
    }

    /// The colour as printed (a Writer palette colour, so it brightens on the dark sheet).
    var color: String {
        switch self {
        case .definition: "1F5FBF"
        case .merksatz: "B7791F"
        case .beispiel: "1E8449"
        case .hinweis: "7B3FC4"
        case .achtung: "C0392B"
        case .eigener: "6B6B76"
        }
    }
}

/// How a box looks and where it stands. Markdown keeps it in the div around the box's paragraphs:
/// `::: {.box kind=definition title="Satz 1" position=right width=40 wrap=true color=1F5FBF frame=outline}` … `:::`.
struct WriterBoxStyle: Hashable, Sendable {
    enum Position: String, CaseIterable, Identifiable, Sendable {
        case full, left, center, right
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: "Ganze Breite"
            case .left: "Links"
            case .center: "Mitte"
            case .right: "Rechts"
            }
        }
        var symbol: String {
            switch self {
            case .full: "rectangle"
            case .left: "rectangle.lefthalf.inset.filled"
            case .center: "rectangle.center.inset.filled"
            case .right: "rectangle.righthalf.inset.filled"
            }
        }
    }

    enum Frame: String, CaseIterable, Identifiable, Sendable {
        /// A bar on the left and a light tint.
        case bar
        /// A thin line around, a lighter tint.
        case outline
        /// A stronger tint, no line.
        case filled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bar: "Leiste"
            case .outline: "Rahmen"
            case .filled: "Fläche"
            }
        }
    }

    var kind: WriterBoxKind = .definition
    /// nil: the kind's name; empty: no title.
    var title: String?
    var position: Position = .full
    /// Text flows around a box on the left or right.
    var wraps = false
    /// Percent of the column (not for the full width).
    var width = 45
    /// Its own colour (six hex digits as printed); nil: the kind's.
    var color: String?
    var frame: Frame = .bar

    static let className = "box"
    static let widths = [30, 40, 45, 50, 60, 75]

    init(kind: WriterBoxKind = .definition) {
        self.kind = kind
    }

    init(attributes: [String: String]) {
        kind = attributes["kind"].flatMap(WriterBoxKind.init(rawValue:)) ?? .eigener
        title = attributes["title"]
        position = attributes["position"].flatMap(Position.init(rawValue:)) ?? .full
        wraps = attributes["wrap"] == "true"
        width = attributes["width"].flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }.map { min(90, max(20, $0)) } ?? 45
        color = attributes["color"].flatMap { WriterColors.parse("#" + $0.replacingOccurrences(of: "#", with: "")) }
        frame = attributes["frame"].flatMap(Frame.init(rawValue:)) ?? .bar
    }

    var effectiveTitle: String { title ?? kind.label }
    var printColor: String { color ?? kind.color }
    /// Whether the text beside it flows around it.
    var floats: Bool { wraps && (position == .left || position == .right) }
    /// The share of the column the box takes.
    var share: CGFloat { position == .full ? 1 : CGFloat(width) / 100 }

    var divOpening: String {
        var parts = ["." + Self.className, "kind=" + kind.rawValue]
        if let title { parts.append("title=\"" + title.replacingOccurrences(of: "\"", with: "'") + "\"") }
        if position != .full {
            parts.append("position=" + position.rawValue)
            parts.append("width=" + String(width))
        }
        if floats { parts.append("wrap=true") }
        if let color { parts.append("color=" + color) }
        if frame != .bar { parts.append("frame=" + frame.rawValue) }
        return "::: {" + parts.joined(separator: " ") + "}"
    }

    /// The box's left edge and width in a column of this width.
    func horizontal(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let boxWidth = (width * share).rounded()
        switch position {
        case .full: return (0, width)
        case .left: return (0, boxWidth)
        case .center: return (((width - boxWidth) / 2).rounded(), boxWidth)
        case .right: return (width - boxWidth, boxWidth)
        }
    }

    // MARK: The editor's measures

    static let paddingLeft: CGFloat = 18
    static let paddingRight: CGFloat = 14
    static let paddingTop: CGFloat = 10
    static let paddingBottom: CGFloat = 10
    static let titleHeight: CGFloat = 22
    static let marginTop: CGFloat = 10
    static let marginBottom: CGFloat = 12
    /// The room between a floating box and the text beside it.
    static let gap: CGFloat = 16

    var hasTitle: Bool { !effectiveTitle.isEmpty }
}

/// A box in the editor: all its paragraphs share this object (`.writerBox`). It never changes; another look puts a new
/// box on the paragraphs, so undo brings the old one back.
final class WriterBox: NSObject, @unchecked Sendable {
    let style: WriterBoxStyle

    init(style: WriterBoxStyle) {
        self.style = style
    }

    func with(_ style: WriterBoxStyle) -> WriterBox { WriterBox(style: style) }

    /// The blocks a box can hold: text, headings, lists, quotes, formulas and pictures.
    static func holds(_ block: WriterBlock) -> Bool {
        switch block {
        case .paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .quote, .math, .image: true
        default: false
        }
    }
}

/// A section of the text set in columns. Markdown keeps it in a div around its blocks,
/// `::: {.columns count=2 gap=0.8cm rule=true}` … `:::`; a `\columnbreak` line inside starts the next column.
struct WriterColumnStyle: Hashable, Sendable {
    var count = 2
    /// The room between the columns in centimetres of print.
    var gap: Double = 0.8
    /// A thin line between the columns.
    var rule = false

    static let className = "columns"
    static let gaps: [Double] = [0.5, 0.8, 1.2, 1.6]

    init(count: Int = 2, gap: Double = 0.8, rule: Bool = false) {
        self.count = count
        self.gap = gap
        self.rule = rule
    }

    init(attributes: [String: String]) {
        count = attributes["count"].flatMap(Int.init).map { min(3, max(2, $0)) } ?? 2
        gap = attributes["gap"].flatMap(WriterParagraphFormat.parseLength).map { min(3, max(0.2, $0)) } ?? 0.8
        rule = attributes["rule"] == "true"
    }

    var divOpening: String {
        var parts = ["." + Self.className, "count=\(count)"]
        if abs(gap - 0.8) > 0.001 { parts.append("gap=" + WriterParagraphFormat.number(gap) + "cm") }
        if rule { parts.append("rule=true") }
        return "::: {" + parts.joined(separator: " ") + "}"
    }
}

/// A section in columns in the editor: all its paragraphs share this object (`.writerColumns`).
final class WriterColumnSection: NSObject, @unchecked Sendable {
    let style: WriterColumnStyle

    init(style: WriterColumnStyle) {
        self.style = style
    }

    /// The blocks a section can hold: everything but tables, the table of contents and chapters.
    static func holds(_ block: WriterBlock) -> Bool {
        ![.table, .toc, .chapter].contains(block)
    }
}

extension NSAttributedString.Key {
    /// The box (`WriterBox`) the paragraph stands in.
    static let writerBox = NSAttributedString.Key("LLMDesigner.writer.box")
    /// The section in columns (`WriterColumnSection`) the paragraph stands in.
    static let writerColumns = NSAttributedString.Key("LLMDesigner.writer.columns")
}

/// A column break on its own paragraph (Markdown `\columnbreak`): the text goes on in the next column. The editor
/// draws a dashed line with its name.
final class WriterColumnBreakAttachment: WriterRuleAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterColumnBreakCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterColumnBreakCell()
    }
}

/// Draws a column break: a short dashed line with "Spaltenumbruch".
final class WriterColumnBreakCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { NSSize(width: 200, height: 18) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -4, width: max(40, lineFrag.width - 4), height: 18)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let palette = (controlView as? WriterTextView)?.palette ?? .dark
        let label = "Spaltenumbruch" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: palette.tertiaryText]
        let size = label.size(withAttributes: attributes)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: cellFrame.minX, y: cellFrame.midY))
        line.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.midY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        palette.rule.setStroke()
        line.stroke()
        let labelRect = NSRect(x: cellFrame.midX - size.width / 2 - 6, y: cellFrame.midY - size.height / 2, width: size.width + 12, height: size.height)
        palette.page.setFill()
        labelRect.fill()
        label.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY), withAttributes: attributes)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
