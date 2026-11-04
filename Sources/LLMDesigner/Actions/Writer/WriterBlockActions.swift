import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterBlockActions() {
        register(WriterBlockSetAction.self)
        register(WriterListLevelAction.self)
        register(WriterParagraphAlignAction.self)
        register(WriterInsertRuleAction.self)
        register(WriterInsertPageBreakAction.self)
    }
}

/// The paragraphs of the addressed blocks, with a change applied to each.
@MainActor
private func editParagraphs(_ address: WriterAddress, in markdown: String, _ change: (NSMutableAttributedString, WriterMarkdown.Paragraph) throws -> Void) throws -> String {
    var editor = BlockEditor(markdown: markdown)
    for stretch in try WriterSelection.stretches(address, in: markdown).reversed() {
        try editor.edit(stretch.block) { text in
            for paragraph in WriterMarkdown.paragraphs(of: text, in: stretch.range) {
                try change(text, paragraph)
            }
        }
    }
    return editor.markdown
}

struct WriterBlockSetAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var type: String
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            type = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .type)
        }
        enum Keys: String, CodingKey { case type }
    }
    typealias Output = WriterWriteResult
    static let types = ["paragraph", "heading1", "heading2", "heading3", "chapter", "bullet", "numbered", "quote", "code"]
    static let descriptor = ActionDescriptor(
        id: "writer.block.set", summary: "Setzt den Blocktyp der Absätze", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["type": .choice(types, "Der neue Typ")]), required: ["type"]),
        output: .freeObject(), example: "llmd writer block set --doc X --match Einleitung --type heading1", groups: ["core", "writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard let block = WriterBlock(rawValue: args.type) else { throw RPCError.invalidParams("Unbekannter Blocktyp „\(args.type)“.") }
        return try editParagraphs(args.address, in: markdown) { text, paragraph in
            guard paragraph.cell == nil, !paragraph.block.isEmbed else {
                throw RPCError.invalidTarget("Tabellenzellen, Bilder und Formeln haben keinen wählbaren Blocktyp.")
            }
            text.addAttribute(.writerBlock, value: block.rawValue, range: paragraph.range)
            if !block.isList { text.removeAttribute(.writerListLevel, range: paragraph.range) }
            if block != .code { text.removeAttribute(.writerCodeLanguage, range: paragraph.range) }
        }
    }
}

struct WriterListLevelAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var step: Int
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            step = try decoder.container(keyedBy: Keys.self).decode(Int.self, forKey: .step)
        }
        enum Keys: String, CodingKey { case step }
    }
    typealias Output = WriterWriteResult
    static let maxLevel = 8
    static let descriptor = ActionDescriptor(
        id: "writer.list.level", summary: "Rückt Listenpunkte ein oder aus", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["step": .integer("+1 ein, -1 aus", minimum: -8, maximum: 8)]), required: ["step"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editParagraphs(args.address, in: markdown) { text, paragraph in
            guard paragraph.block.isList else { throw RPCError.invalidTarget("Das ist kein Listenpunkt.") }
            let level = min(maxLevel, max(0, paragraph.level + args.step))
            text.addAttribute(.writerListLevel, value: level, range: paragraph.range)
        }
    }
}

struct WriterParagraphAlignAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var alignment: String
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            alignment = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .alignment)
        }
        enum Keys: String, CodingKey { case alignment }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.paragraph.align", summary: "Richtet Absätze aus", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["alignment": .choice(WriterAlignment.allCases.map(\.rawValue), "Ausrichtung")]), required: ["alignment"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try editParagraphs(args.address, in: markdown) { text, paragraph in
            guard paragraph.block.takesAlignment else { throw RPCError.invalidTarget("„\(paragraph.block.label)“ lässt sich nicht ausrichten.") }
            // Left is the default: no attribute, so no div in the Markdown.
            if args.alignment == WriterAlignment.left.rawValue {
                text.removeAttribute(.writerAlignment, range: paragraph.range)
            } else {
                text.addAttribute(.writerAlignment, value: args.alignment, range: paragraph.range)
            }
        }
    }
}

@MainActor
private func insertBlock(_ line: String, args: WriterEditArgs, markdown: String) throws -> String {
    guard !args.address.isEmpty else { return PowerText.inserting(line, at: .max, into: markdown) }
    switch try WriterAddressing.resolve(args.address, in: markdown) {
    case .blocks(let range): return PowerText.inserting(line, at: range.upperBound, into: markdown)
    case .text(let block, _): return PowerText.inserting(line, at: block + 1, into: markdown)
    case .whole, .source: return PowerText.inserting(line, at: .max, into: markdown)
    }
}

struct WriterInsertRuleAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.insert.rule", summary: "Fügt eine Trennlinie ein", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try insertBlock("---", args: args, markdown: markdown)
    }
}

struct WriterInsertPageBreakAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.insert.pageBreak", summary: "Fügt einen Seitenumbruch ein", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        try insertBlock("\\newpage", args: args, markdown: markdown)
    }
}
