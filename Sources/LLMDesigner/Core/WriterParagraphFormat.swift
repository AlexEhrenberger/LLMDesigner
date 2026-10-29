import AppKit

/// How a paragraph is set besides its block: its alignment, its line spacing and how far it is indented. Stored on
/// every character of the paragraph (`.writerAlignment`, `.writerLineSpacing`, `.writerIndent`,
/// `.writerRightIndent`, `.writerFirstLineIndent`). Markdown keeps it in a Pandoc div around the paragraphs,
/// `::: {.center line-spacing=1.5 indent=1cm first-line=-0.5cm}` … `:::`; consecutive paragraphs that are set alike
/// share one div.
struct WriterParagraphFormat: Hashable {
    var alignment: WriterAlignment?
    /// Times the normal distance of the lines (1.5: one and a half lines).
    var lineSpacing: Double?
    /// From the left and the right margin, in centimetres of print.
    var indent: Double?
    var rightIndent: Double?
    /// The first line's indent in centimetres; negative: a hanging indent (the other lines start further in).
    var firstLine: Double?

    static let lineSpacingRange: ClosedRange<Double> = 0.8...4
    static let indentRange: ClosedRange<Double> = 0...12
    static let firstLineRange: ClosedRange<Double> = -6...6
    /// What the indent buttons and ⌘] / ⌘[ add or take away.
    static let indentStep = 1.25

    init(alignment: WriterAlignment? = nil, lineSpacing: Double? = nil, indent: Double? = nil, rightIndent: Double? = nil, firstLine: Double? = nil) {
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.indent = indent
        self.rightIndent = rightIndent
        self.firstLine = firstLine
        normalize()
    }

    /// The format a paragraph's text carries.
    init(_ attributes: [NSAttributedString.Key: Any]) {
        self.init(
            alignment: (attributes[.writerAlignment] as? String).flatMap(WriterAlignment.init(rawValue:)),
            lineSpacing: attributes[.writerLineSpacing] as? Double,
            indent: attributes[.writerIndent] as? Double,
            rightIndent: attributes[.writerRightIndent] as? Double,
            firstLine: attributes[.writerFirstLineIndent] as? Double
        )
    }

    /// The format of a div's classes (`.center`) and attributes (`line-spacing=1.5`, `indent=1cm`).
    init(classes: [String], attributes: [String: String]) {
        self.init(
            alignment: WriterAlignment.from(classes: classes),
            lineSpacing: attributes["line-spacing"].flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            indent: attributes["indent"].flatMap(Self.parseLength),
            rightIndent: attributes["right-indent"].flatMap(Self.parseLength),
            firstLine: attributes["first-line"].flatMap(Self.parseLength)
        )
    }

    static let keys: [NSAttributedString.Key] = [.writerAlignment, .writerLineSpacing, .writerIndent, .writerRightIndent, .writerFirstLineIndent]

    var isEmpty: Bool { alignment == nil && lineSpacing == nil && indent == nil && rightIndent == nil && firstLine == nil }

    /// The meaning attributes of this format.
    var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let alignment { attributes[.writerAlignment] = alignment.rawValue }
        if let lineSpacing { attributes[.writerLineSpacing] = lineSpacing }
        if let indent { attributes[.writerIndent] = indent }
        if let rightIndent { attributes[.writerRightIndent] = rightIndent }
        if let firstLine { attributes[.writerFirstLineIndent] = firstLine }
        return attributes
    }

    /// What of the format a block takes: text and quotes all of it, headings their alignment, lists their line
    /// spacing (their indent is their level); code, pictures and tables nothing.
    func applying(to block: WriterBlock) -> WriterParagraphFormat {
        var format = self
        if !block.takesAlignment { format.alignment = nil }
        if !(block.takesAlignment || block.isList) || block.isHeading { format.lineSpacing = nil }
        if block != .paragraph, block != .quote {
            format.indent = nil
            format.rightIndent = nil
            format.firstLine = nil
        }
        return format
    }

    /// The div that holds this format; nil when there is nothing to hold.
    var divOpening: String? {
        var parts: [String] = []
        if let alignment { parts.append("." + alignment.rawValue) }
        if let lineSpacing { parts.append("line-spacing=" + Self.number(lineSpacing)) }
        if let indent { parts.append("indent=" + Self.number(indent) + "cm") }
        if let rightIndent { parts.append("right-indent=" + Self.number(rightIndent) + "cm") }
        if let firstLine { parts.append("first-line=" + Self.number(firstLine) + "cm") }
        return parts.isEmpty ? nil : "::: {" + parts.joined(separator: " ") + "}"
    }

    /// Values outside their range are brought into it; zero and single spacing are the default and stored as none.
    private mutating func normalize() {
        if let value = lineSpacing {
            let clamped = Self.round(min(max(value, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound))
            lineSpacing = abs(clamped - 1) < 0.001 ? nil : clamped
        }
        func clean(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let value, value.isFinite else { return nil }
            let clamped = Self.round(min(max(value, range.lowerBound), range.upperBound))
            return abs(clamped) < 0.001 ? nil : clamped
        }
        indent = clean(indent, Self.indentRange)
        rightIndent = clean(rightIndent, Self.indentRange)
        firstLine = clean(firstLine, Self.firstLineRange)
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// "1.5", "1.25", "2": without needless decimals, with a point (Pandoc and LaTeX read it so).
    static func number(_ value: Double) -> String {
        let rounded = round(value)
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// A length in centimetres from `1cm`, `10mm`, `0.5in`, `12pt` or a bare number (centimetres).
    static func parseLength(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        let units: [(String, Double)] = [("cm", 1), ("mm", 0.1), ("in", 2.54), ("pt", 2.54 / 72.27), ("em", 0.39)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).map { $0 * factor }
        }
        return Double(text)
    }

    /// "1,25 cm" for the controls.
    static func label(cm value: Double) -> String {
        number(value).replacingOccurrences(of: ".", with: ",") + " cm"
    }

    // MARK: Line spacing

    /// The spacings the menus offer, as word processors name them.
    static let lineSpacingSteps: [(value: Double, label: String)] = [
        (1, "Einfach"), (1.15, "1,15"), (1.5, "1,5 Zeilen"), (2, "Doppelt"), (2.5, "2,5"), (3, "Dreifach"),
    ]

    static func lineSpacingLabel(_ value: Double?) -> String {
        let value = value ?? 1
        return lineSpacingSteps.first { abs($0.value - value) < 0.001 }?.label ?? number(value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: LaTeX

    /// The switches that set a paragraph in this format in LaTeX: line spacing (times the document's own) and the
    /// indents, added to what the alignment set. The first-line indent replaces the paragraph's own.
    func latexSwitches(baseLineSpacing: Double) -> [String] {
        var switches: [String] = []
        if let lineSpacing {
            switches.append("\\linespread{\(Self.number(lineSpacing * baseLineSpacing))}\\selectfont")
        }
        let hanging = max(0, -(firstLine ?? 0))
        if (indent ?? 0) + hanging > 0 {
            switches.append("\\advance\\leftskip \(Self.number((indent ?? 0) + hanging))cm")
        }
        if let rightIndent { switches.append("\\advance\\rightskip \(Self.number(rightIndent))cm") }
        if let firstLine { switches.append("\\parindent=\(Self.number(firstLine))cm") }
        return switches
    }

    // MARK: Editor

    /// Points on the screen per centimetre of print.
    static func screenPoints(cm value: Double, scale: CGFloat) -> CGFloat {
        CGFloat(value) * 72 / 2.54 * scale
    }

    /// The indents on the paragraph style, on top of the block's own (a quote's bar), and the line spacing.
    func apply(to style: NSMutableParagraphStyle, scale: CGFloat) {
        let indent = Self.screenPoints(cm: indent ?? 0, scale: scale)
        let first = Self.screenPoints(cm: firstLine ?? 0, scale: scale)
        style.headIndent += indent + max(0, -first)
        style.firstLineHeadIndent += indent + max(0, first)
        if let rightIndent { style.tailIndent -= Self.screenPoints(cm: rightIndent, scale: scale) }
        if let lineSpacing {
            if style.minimumLineHeight > 0 {
                style.minimumLineHeight = (style.minimumLineHeight * CGFloat(lineSpacing)).rounded()
            } else {
                style.lineHeightMultiple = (style.lineHeightMultiple == 0 ? 1 : style.lineHeightMultiple) * CGFloat(lineSpacing)
            }
        }
    }
}

extension NSAttributedString.Key {
    /// The paragraph's line spacing (a `Double`, times the normal), see `WriterParagraphFormat`.
    static let writerLineSpacing = NSAttributedString.Key("LLMDesigner.writer.lineSpacing")
    /// The paragraph's indents in centimetres of print (`Double`s); the first line's may be negative.
    static let writerIndent = NSAttributedString.Key("LLMDesigner.writer.indent")
    static let writerRightIndent = NSAttributedString.Key("LLMDesigner.writer.rightIndent")
    static let writerFirstLineIndent = NSAttributedString.Key("LLMDesigner.writer.firstLineIndent")
}
