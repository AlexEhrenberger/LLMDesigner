import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterTextActions() {
        register(WriterTextInsertAction.self)
        register(WriterTextInsertMarkdownAction.self)
        register(WriterTextReplaceAction.self)
        register(WriterTextDeleteAction.self)
        register(WriterTextReplaceAllAction.self)
        register(WriterParagraphNewAction.self)
        register(WriterBlockMoveAction.self)
        register(WriterHeadingInsertAction.self)
        register(WriterEditUndoAction.self)
        register(WriterEditRedoAction.self)
    }
}

/// Target plus address, the parameters most Writer actions share.
struct WriterEditArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var text: String?
    var markdown: String?
    var position: String?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        position = try container.decodeIfPresent(String.self, forKey: .position)
    }
    enum Keys: String, CodingKey { case text, markdown, position }

    static func properties(_ extra: [String: JSONSchema] = [:]) -> [String: JSONSchema] {
        WriterTargetArgs.schemaProperties.merging(WriterAddress.schemaProperties) { _, new in new }.merging(extra) { _, new in new }
    }
}

/// Writer changes are all alike: resolve the target, compute the new text, write it as one step.
@MainActor
protocol WriterEditAction: LLMDAction where Output == WriterWriteResult {
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String
    static func target(of args: Args) -> WriterTargetArgs
}

@MainActor
extension WriterEditAction {
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(self.target(of: args), app: context.app)
        try target.checkVersion(self.target(of: args).ifVersion)
        return ActionPreflight(target: target.document?.displayTitle)
    }

    static func run(_ args: Args, context: ActionContext) async throws -> WriterWriteResult {
        let target = try WriterTarget(self.target(of: args), app: context.app)
        let markdown = target.markdown
        return try target.replaceText(with: try edit(args, markdown: markdown, context: context), ifVersion: self.target(of: args).ifVersion, context: context)
    }
}

/// Plain text as Markdown that reads as that text. Line breaks become paragraphs.
func writerEscaped(_ text: String) -> String {
    text.components(separatedBy: "\n\n").map { paragraph in
        paragraph.components(separatedBy: "\n").map { WriterMarkdown.escape($0, atLineStart: true) }.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

@MainActor
private func isSingleLineInline(_ markdown: String) -> Bool {
    let chunks = PowerText.chunks(of: markdown)
    return chunks.count == 1 && chunks[0].kind == .paragraph && !markdown.trimmingCharacters(in: .newlines).contains("\n")
}

/// `text` with the paragraph attributes of the place it goes to.
@MainActor
private func insert(_ fragment: NSAttributedString, into text: NSMutableAttributedString, at location: Int) {
    let piece = NSMutableAttributedString(attributedString: fragment)
    if text.length > 0 {
        let source = min(max(0, location - (location > 0 ? 1 : 0)), text.length - 1)
        let paragraphAttributes = text.attributes(at: source, effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }
        piece.addAttributes(paragraphAttributes, range: NSRange(location: 0, length: piece.length))
    }
    text.insert(piece, at: location)
}

struct WriterTextInsertAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.text.insert", summary: "Fügt Text ein, ohne Markdown zu deuten", kind: .write, security: .localWrite,
        input: .object(Args.properties(["text": .string("Der Text"), "position": .choice(["before", "after"], "Vor oder nach der Adresse; Standard: after")]), required: ["text"]),
        output: .freeObject(), example: "llmd writer text insert --doc X --match Wort --text ' und mehr'", groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let text = args.text ?? ""
        let before = args.position == "before"
        guard !args.address.isEmpty else { return PowerText.inserting(writerEscaped(text), at: .max, into: markdown) }
        var editor = BlockEditor(markdown: markdown)
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .whole:
            return PowerText.inserting(writerEscaped(text), at: before ? 0 : .max, into: markdown)
        case .blocks(let range):
            try editor.edit(range.lowerBound) { attributed in
                insert(NSAttributedString(string: text), into: attributed, at: before ? 0 : BlockEditor.fullRange(of: attributed).length)
            }
        case .text(let block, let range):
            editor.edit(block) { attributed in
                let location = before ? range.location : NSMaxRange(range)
                let mark = attributed.attributes(at: min(max(0, before ? location : location - 1), attributed.length - 1), effectiveRange: nil)
                attributed.insert(NSAttributedString(string: text, attributes: mark), at: location)
            }
        case .source(let range):
            var result = markdown
            result.insert(contentsOf: WriterMarkdown.escape(text, atLineStart: false), at: before ? range.lowerBound : range.upperBound)
            return result
        }
        return editor.markdown
    }
}

struct WriterTextInsertMarkdownAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.text.insertMarkdown", summary: "Fügt Markdown ein: Überschriften, Listen, Fettdruck in einem Aufruf", kind: .write, security: .localWrite,
        input: .object(Args.properties(["markdown": .string("Der Markdown-Text"), "position": .choice(["before", "after", "replace"], "Bezug zur Adresse; Standard: after; ohne Adresse ans Ende")]), required: ["markdown"]),
        output: .freeObject(), example: "llmd writer text insert-markdown --doc X --markdown '# Titel'", groups: ["core", "writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let new = args.markdown ?? ""
        let position = args.position ?? "after"
        guard !args.address.isEmpty else { return PowerText.inserting(new, at: .max, into: markdown) }
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .whole:
            switch position {
            case "before": return PowerText.inserting(new, at: 0, into: markdown)
            case "replace": return new
            default: return PowerText.inserting(new, at: .max, into: markdown)
            }
        case .blocks(let range):
            switch position {
            case "before": return PowerText.inserting(new, at: range.lowerBound, into: markdown)
            case "replace": return PowerText.replacing(range.lowerBound, with: new, in: markdown)
            default: return PowerText.inserting(new, at: range.upperBound, into: markdown)
            }
        case .text(let block, let range):
            guard isSingleLineInline(new) else {
                // Blocks can't go inside a paragraph; they go next to it.
                guard position != "replace" else {
                    throw RPCError.invalidTarget("Mehrere Blöcke können keinen Text mitten im Absatz ersetzen. Bitte block als Adresse nehmen.")
                }
                return PowerText.inserting(new, at: position == "before" ? block : block + 1, into: markdown)
            }
            var editor = BlockEditor(markdown: markdown)
            editor.edit(block) { attributed in
                let fragment = WriterMarkdown.inline(new.trimmingCharacters(in: .newlines))
                switch position {
                case "before": insert(fragment, into: attributed, at: range.location)
                case "replace":
                    attributed.deleteCharacters(in: range)
                    insert(fragment, into: attributed, at: range.location)
                default: insert(fragment, into: attributed, at: NSMaxRange(range))
                }
            }
            return editor.markdown
        case .source(let range):
            var result = markdown
            if position == "replace" { result.replaceSubrange(range, with: new) }
            else { result.insert(contentsOf: new, at: position == "before" ? range.lowerBound : range.upperBound) }
            return result
        }
    }
}

struct WriterTextReplaceAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.text.replace", summary: "Ersetzt die Stelle durch Text oder Markdown", kind: .write, security: .localWrite,
        input: .object(Args.properties(["text": .string("Neuer Text ohne Markup"), "markdown": .string("Neuer Text als Markdown")])),
        output: .freeObject(), example: "llmd writer text replace --doc X --match alt --text neu", groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard args.text != nil || args.markdown != nil else { throw RPCError.invalidParams("Bitte text oder markdown angeben.") }
        guard !args.address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, was ersetzt werden soll: range, block, heading, match oder all.") }
        let new = args.markdown ?? writerEscaped(args.text ?? "")
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .whole:
            return new
        case .blocks(let range):
            if args.address.heading != nil, let text = args.text {
                // A heading keeps its level when only its words change.
                var editor = BlockEditor(markdown: markdown)
                editor.edit(range.lowerBound) { attributed in
                    let whole = BlockEditor.fullRange(of: attributed)
                    let marks = attributed.attributes(at: 0, effectiveRange: nil)
                    attributed.replaceCharacters(in: whole, with: NSAttributedString(string: text, attributes: marks))
                }
                return editor.markdown
            }
            return PowerText.replacing(range.lowerBound, with: new, in: markdown)
        case .text(let block, let range):
            var editor = BlockEditor(markdown: markdown)
            try editor.edit(block) { attributed in
                if let text = args.text {
                    let marks = attributed.attributes(at: min(range.location, attributed.length - 1), effectiveRange: nil)
                    attributed.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: marks))
                } else {
                    guard isSingleLineInline(new) else {
                        throw RPCError.invalidTarget("Mehrere Blöcke können keinen Text mitten im Absatz ersetzen. Bitte block als Adresse nehmen.")
                    }
                    attributed.deleteCharacters(in: range)
                    insert(WriterMarkdown.inline(new.trimmingCharacters(in: .newlines)), into: attributed, at: range.location)
                }
            }
            return editor.markdown
        case .source(let range):
            var result = markdown
            result.replaceSubrange(range, with: new)
            return result
        }
    }
}

struct WriterTextDeleteAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.text.delete", summary: "Löscht die Stelle; rückgängig machbar", kind: .write, security: .localWrite,
        input: .object(Args.properties()), output: .freeObject(), example: "llmd writer text delete --doc X --match Wort", groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard !args.address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, was gelöscht werden soll: range, block, heading, match oder all.") }
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .whole:
            return ""
        case .blocks(let range):
            return PowerText.replacing(range.lowerBound, with: "", in: markdown)
        case .text(let block, let range):
            var editor = BlockEditor(markdown: markdown)
            editor.edit(block) { $0.deleteCharacters(in: range) }
            return editor.markdown
        case .source(let range):
            var result = markdown
            result.removeSubrange(range)
            return result
        }
    }
}

struct WriterTextReplaceAllAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var find: String
        var replace: String
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            find = try container.decode(String.self, forKey: .find)
            replace = try container.decode(String.self, forKey: .replace)
        }
        enum Keys: String, CodingKey { case find, replace }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.text.replaceAll", summary: "Ersetzt alle Vorkommen eines Texts", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(["find": .string("Gesuchter Text"), "replace": .string("Ersatz")]) { _, new in new }, required: ["find", "replace"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard !args.find.isEmpty else { throw RPCError.invalidParams("Leerer Suchtext.") }
        guard markdown.contains(args.find) else { throw RPCError.notFound("„\(args.find)“ kommt im Text nicht vor.") }
        return markdown.replacingOccurrences(of: args.find, with: args.replace)
    }
}

struct WriterParagraphNewAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.paragraph.new", summary: "Beginnt einen neuen Absatz, an der Adresse oder am Ende", kind: .write, security: .localWrite,
        input: .object(Args.properties(["text": .string("Text des neuen Absatzes; mit match wird dort geteilt")])),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let text = writerEscaped(args.text ?? "")
        if args.address.isEmpty {
            guard !text.isEmpty else { throw RPCError.invalidParams("Ein leerer Absatz hat in Markdown keine Form. Bitte text angeben.") }
            return PowerText.inserting(text, at: .max, into: markdown)
        }
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .text(let block, let range) where text.isEmpty:
            // Splits the paragraph behind the hit.
            var editor = BlockEditor(markdown: markdown)
            var rest = ""
            editor.edit(block) { attributed in
                let cut = NSMaxRange(range)
                let tail = NSRange(location: cut, length: BlockEditor.fullRange(of: attributed).length - cut)
                rest = WriterMarkdown.markdown(from: attributed.attributedSubstring(from: tail)).trimmingCharacters(in: .whitespacesAndNewlines)
                attributed.deleteCharacters(in: tail)
            }
            if !rest.isEmpty { editor.blocks.insert(rest, at: block + 1) }
            return editor.markdown
        case .text(let block, _):
            return PowerText.inserting(text, at: block + 1, into: markdown)
        case .blocks(let range):
            guard !text.isEmpty else { throw RPCError.invalidParams("Bitte text angeben.") }
            return PowerText.inserting(text, at: range.upperBound, into: markdown)
        case .whole, .source:
            throw RPCError.invalidParams("Bitte match, block oder heading als Adresse nehmen.")
        }
    }
}

struct WriterBlockMoveAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var block: String
        var before: String?
        var after: String?
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            block = try container.decode(String.self, forKey: .block)
            before = try container.decodeIfPresent(String.self, forKey: .before)
            after = try container.decodeIfPresent(String.self, forKey: .after)
        }
        enum Keys: String, CodingKey { case block, before, after }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.block.move", summary: "Verschiebt einen Block vor oder hinter einen anderen", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(["block": .string("Zu verschiebender Block"), "before": .string("Vor diesen Block"), "after": .string("Hinter diesen Block")]) { _, new in new }, required: ["block"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        func index(_ id: String) throws -> Int {
            guard case .blocks(let range) = try WriterAddressing.resolve(WriterAddress(block: id), in: markdown) else { return 0 }
            return range.lowerBound
        }
        let source = try index(args.block)
        if let before = args.before { return PowerText.moving(source, to: try index(before), in: markdown) }
        if let after = args.after { return PowerText.moving(source, to: try index(after) + 1, in: markdown) }
        throw RPCError.invalidParams("Bitte before oder after angeben.")
    }
}

struct WriterHeadingInsertAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var level: Int
        var text: String
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            level = try container.decode(Int.self, forKey: .level)
            text = try container.decode(String.self, forKey: .text)
        }
        enum Keys: String, CodingKey { case level, text }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.heading.insert", summary: "Fügt eine Überschrift ein (Stufe 0 ist Kapitel)", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["level": .integer("0 Kapitel, 1 bis 3 Überschrift", minimum: 0, maximum: 3), "text": .string("Text der Überschrift")]), required: ["level", "text"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let line = args.level == 0 ? "# \(args.text) {.chapter}" : String(repeating: "#", count: args.level) + " " + args.text
        guard !args.address.isEmpty else { return PowerText.inserting(line, at: .max, into: markdown) }
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .blocks(let range): return PowerText.inserting(line, at: range.upperBound, into: markdown)
        case .text(let block, _): return PowerText.inserting(line, at: block + 1, into: markdown)
        case .whole, .source: return PowerText.inserting(line, at: .max, into: markdown)
        }
    }
}

// MARK: Undo

struct WriterUndoArgs: Decodable, Sendable {
    var doc: String?
}

struct WriterEditUndoAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var undone: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.edit.undo", summary: "Nimmt die letzte Action zurück", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Nur in diesem Dokument")]), output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: WriterUndoArgs, context: ActionContext) async throws -> Output {
        let id = try args.doc.map { try context.app.actionAnyDocument($0).id }
        let undone = context.registry.undoStack.undo { id == nil || $0.documents.contains(id!) }
        guard let undone else { throw RPCError.notFound("Es gibt nichts zurückzunehmen.") }
        return Output(undone: undone)
    }
}

struct WriterEditRedoAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var redone: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.edit.redo", summary: "Stellt die zuletzt zurückgenommene Action wieder her", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Nur in diesem Dokument")]), output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: WriterUndoArgs, context: ActionContext) async throws -> Output {
        let id = try args.doc.map { try context.app.actionAnyDocument($0).id }
        let redone = context.registry.undoStack.redo { id == nil || $0.documents.contains(id!) }
        guard let redone else { throw RPCError.notFound("Es gibt nichts wiederherzustellen.") }
        return Output(redone: redone)
    }
}

extension WriterAddress {
    init(block: String) {
        self.block = block
    }
}

extension AppModel {
    /// A document or a presentation.
    func actionAnyDocument(_ reference: String) throws -> WriterDocument {
        if let document = try? actionDocument(reference, presentation: true) { return document }
        return try actionDocument(reference)
    }
}
