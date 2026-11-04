import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterPassageActions() {
        register(WriterFormatFontAction.self)
        register(WriterFormatFontSizeAction.self)
        register(WriterFormatColorAction.self)
        register(WriterLinkSetAction.self)
        register(WriterLinkRemoveAction.self)
        register(WriterParagraphIndentAction.self)
        register(WriterParagraphLineSpacingAction.self)
        register(WriterParagraphClearFormatAction.self)
    }
}

/// Target, address and what a passage or paragraph action sets.
struct WriterPassageArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var font: String?
    var size: Double?
    var step: Int?
    var color: String?
    var url: String?
    var left: Double?
    var right: Double?
    var firstLine: Double?
    var value: Double?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        font = try c.decodeIfPresent(String.self, forKey: .font)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        step = try c.decodeIfPresent(Int.self, forKey: .step)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        left = try c.decodeIfPresent(Double.self, forKey: .left)
        right = try c.decodeIfPresent(Double.self, forKey: .right)
        firstLine = try c.decodeIfPresent(Double.self, forKey: .firstLine)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
    }
    enum Keys: String, CodingKey { case font, size, step, color, url, left, right, firstLine, value }
}

/// A change to the addressed passages in their blocks.
@MainActor
private func editPassages(_ address: WriterAddress, in markdown: String, _ change: (NSMutableAttributedString, NSRange) throws -> Void) throws -> String {
    var editor = BlockEditor(markdown: markdown)
    for stretch in try WriterSelection.stretches(address, in: markdown).reversed() {
        try editor.edit(stretch.block) { text in try change(text, stretch.range ?? BlockEditor.fullRange(of: text)) }
    }
    return editor.markdown
}

struct WriterFormatFontAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.format.font", summary: "Setzt die Schrift einer Stelle; none nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["font": .choice(WriterFont.allCases.map(\.rawValue) + ["none"], "Die Schrift")]), required: ["font"]),
        output: .freeObject(), example: "llmd writer format font --doc X --match Wort --font georgia"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editPassages(args.address, in: markdown) { text, range in
            if args.font == "none" { text.removeAttribute(.writerFont, range: range) } else { text.addAttribute(.writerFont, value: args.font ?? "", range: range) }
        }
    }
}

struct WriterFormatFontSizeAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.format.fontSize", summary: "Setzt die Schriftgröße einer Stelle, fest oder in Schritten; 0 nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties([
            "size": .number("Größe in Punkt wie gedruckt; 0 nimmt sie weg", minimum: 0, maximum: WriterSpanStyle.sizeRange.upperBound),
            "step": .integer("Größer (1) oder kleiner (-1), ab der Größe, die jede Stelle hat", minimum: -1, maximum: 1),
        ])),
        output: .freeObject(), example: "llmd writer format font-size --doc X --match Wort --size 14"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard args.size != nil || args.step != nil else { throw RPCError.invalidParams("Bitte size oder step angeben.") }
        let family = try WriterTarget(args.target, app: context.app).document?.font ?? .serif
        return try editPassages(args.address, in: markdown) { text, range in
            if let size = args.size {
                if size == 0 { text.removeAttribute(.writerFontSize, range: range); return }
                text.addAttribute(.writerFontSize, value: min(WriterSpanStyle.sizeRange.upperBound, max(WriterSpanStyle.sizeRange.lowerBound, size)), range: range)
                return
            }
            // Every stretch from the size it has, so headings stay larger than text.
            let step = args.step ?? 0
            var changes: [(NSRange, Double)] = []
            text.enumerateAttributes(in: range) { attributes, run, _ in
                let block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
                let size = WriterStyler.printedSize(of: attributes, block: block, family: family, palette: .dark)
                let steps = WriterTextView.fontSizeSteps
                let next = step > 0 ? steps.first { $0 > size + 0.01 } ?? min(WriterSpanStyle.sizeRange.upperBound, size + 8)
                                    : steps.last { $0 < size - 0.01 } ?? max(WriterSpanStyle.sizeRange.lowerBound, size - 1)
                changes.append((run, next))
            }
            for (run, size) in changes { text.addAttribute(.writerFontSize, value: size, range: run) }
        }
    }
}

struct WriterFormatColorAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.format.color", summary: "Setzt die Textfarbe einer Stelle; none nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["color": .string("Sechs Hex-Ziffern oder ein Name wie \(WriterColors.palette[0].name); none nimmt sie weg")]), required: ["color"]),
        output: .freeObject(), example: "llmd writer format color --doc X --match Wort --color Blau"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let color = args.color == "none" ? nil : try actionColor(args.color ?? "")
        return try editPassages(args.address, in: markdown) { text, range in
            if let color { text.addAttribute(.writerColor, value: color, range: range) } else { text.removeAttribute(.writerColor, range: range) }
        }
    }
}

struct WriterLinkSetAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.link.set", summary: "Macht aus einer Stelle einen Link", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["url": .string("Die Adresse")]), required: ["url"]),
        output: .freeObject(), example: "llmd writer link set --doc X --match Wort --url https://example.org"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let address = (args.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(" "), !address.contains(")") else { throw RPCError.invalidParams("„\(address)“ ist keine Adresse.") }
        return try editPassages(args.address, in: markdown) { text, range in text.addAttribute(.link, value: address, range: range) }
    }
}

struct WriterLinkRemoveAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.link.remove", summary: "Nimmt Links von einer Stelle; der Text bleibt", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editPassages(args.address, in: markdown) { text, range in text.removeAttribute(.link, range: range) }
    }
}

/// The format of the paragraphs at an address; what a block doesn't take is left out, as in the editor.
@MainActor
private func editParagraphFormat(_ address: WriterAddress, in markdown: String, _ change: (WriterParagraphFormat) -> WriterParagraphFormat) throws -> String {
    var editor = BlockEditor(markdown: markdown)
    var touched = false
    for stretch in try WriterSelection.stretches(address, in: markdown).reversed() {
        editor.edit(stretch.block) { text in
            for paragraph in WriterMarkdown.paragraphs(of: text, in: stretch.range) where (paragraph.block.takesAlignment || paragraph.block.isList) && paragraph.cell == nil && paragraph.range.length > 0 {
                let format = change(WriterParagraphFormat(text.attributes(at: paragraph.range.location, effectiveRange: nil))).applying(to: paragraph.block)
                for key in WriterParagraphFormat.keys { text.removeAttribute(key, range: paragraph.range) }
                text.addAttributes(format.attributes, range: paragraph.range)
                touched = true
            }
        }
    }
    guard touched else { throw RPCError.invalidTarget("Hier gibt es keine Absätze mit Einzug oder Zeilenabstand.") }
    return editor.markdown
}

struct WriterParagraphIndentAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.paragraph.indent", summary: "Setzt die Einzüge von Absätzen in Zentimetern, oder rückt sie schrittweise ein", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties([
            "step": .integer("Eine Stufe (1,25 cm) weiter hinein (1) oder zurück (-1)", minimum: -1, maximum: 1),
            "left": .number("Von links", minimum: WriterParagraphFormat.indentRange.lowerBound, maximum: WriterParagraphFormat.indentRange.upperBound),
            "right": .number("Von rechts", minimum: WriterParagraphFormat.indentRange.lowerBound, maximum: WriterParagraphFormat.indentRange.upperBound),
            "firstLine": .number("Erste Zeile; negativ hängend", minimum: WriterParagraphFormat.firstLineRange.lowerBound, maximum: WriterParagraphFormat.firstLineRange.upperBound),
        ])),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard args.step != nil || args.left != nil || args.right != nil || args.firstLine != nil else { throw RPCError.invalidParams("Bitte step, left, right oder firstLine angeben.") }
        return try editParagraphFormat(args.address, in: markdown) { format in
            let stepped = args.step.map { max(0, (format.indent ?? 0) + Double($0) * WriterParagraphFormat.indentStep) }
            return WriterParagraphFormat(alignment: format.alignment, lineSpacing: format.lineSpacing, indent: args.left ?? stepped ?? format.indent,
                                         rightIndent: args.right ?? format.rightIndent, firstLine: args.firstLine ?? format.firstLine)
        }
    }
}

struct WriterParagraphLineSpacingAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.paragraph.lineSpacing", summary: "Setzt den Zeilenabstand von Absätzen; 1,5 sind anderthalb Zeilen, 0 nimmt ihn weg", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["value": .number("Vielfaches der normalen Zeile", minimum: 0, maximum: WriterParagraphFormat.lineSpacingRange.upperBound)]), required: ["value"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editParagraphFormat(args.address, in: markdown) { format in
            WriterParagraphFormat(alignment: format.alignment, lineSpacing: args.value == 0 ? nil : args.value, indent: format.indent,
                                  rightIndent: format.rightIndent, firstLine: format.firstLine)
        }
    }
}

struct WriterParagraphClearFormatAction: WriterEditAction {
    typealias Args = WriterPassageArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.paragraph.clearFormat", summary: "Nimmt Absätzen Einzüge und Zeilenabstand; die Ausrichtung bleibt", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editParagraphFormat(args.address, in: markdown) { WriterParagraphFormat(alignment: $0.alignment) }
    }
}
