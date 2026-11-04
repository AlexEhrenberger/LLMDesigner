import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterFormatActions() {
        register(WriterFormatBoldAction.self)
        register(WriterFormatItalicAction.self)
        register(WriterFormatUnderlineAction.self)
        register(WriterFormatStrikethroughAction.self)
        register(WriterFormatCodeAction.self)
        register(WriterFormatSuperscriptAction.self)
        register(WriterFormatSubscriptAction.self)
        register(WriterFormatClearAction.self)
    }
}

/// Where marks go in attributed blocks: one stretch, or the whole of the addressed blocks.
@MainActor
enum WriterSelection {
    static func stretches(_ address: WriterAddress, in markdown: String) throws -> [(block: Int, range: NSRange?)] {
        guard !address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, wo: range, block, heading, match oder all.") }
        let chunks = PowerText.chunks(of: markdown)
        switch try WriterAddressing.resolve(address, in: markdown) {
        case .whole:
            return chunks.filter { BlockEditor.holdsText($0.kind) }.map { ($0.id, nil) }
        case .blocks(let range):
            let usable = range.filter { BlockEditor.holdsText(chunks[$0].kind) }
            guard !usable.isEmpty else { throw RPCError.invalidTarget("Dieser Block hat keinen Fließtext (Code, Formel oder Bild).") }
            return usable.map { ($0, nil) }
        case .text(let block, let range):
            return [(block, range)]
        case .source(let range):
            let stretch = try WriterAddressing.textStretch(for: range, in: markdown)
            return [(stretch.block, stretch.range)]
        }
    }
}

/// A character format with `state`: an agent that doesn't know the current state says what it wants; `on` twice is `on`.
@MainActor
protocol WriterMarkAction: WriterEditAction where Args == WriterEditMarkArgs, Output == WriterWriteResult {
    static var mark: WriterInline { get }
}

struct WriterEditMarkArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var state: String?
    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        state = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .state)
    }
    enum Keys: String, CodingKey { case state }
}

@MainActor
extension WriterMarkAction {
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard let attribute = mark.attribute else { throw RPCError.internal("Unbekanntes Format.") }
        var editor = BlockEditor(markdown: markdown)
        let stretches = try WriterSelection.stretches(args.address, in: markdown)

        // A toggle decides once for the whole address: on, unless all of it already has the mark.
        func wholeHasMark() -> Bool {
            stretches.allSatisfy { stretch in
                let text = WriterMarkdown.attributedString(from: editor.blocks[stretch.block])
                let range = stretch.range ?? BlockEditor.fullRange(of: text)
                guard range.length > 0 else { return true }
                var all = true
                text.enumerateAttributes(in: range) { attributes, _, stop in
                    if !WriterInline(attributes).contains(mark) {
                        all = false
                        stop.pointee = true
                    }
                }
                return all
            }
        }
        let turnOn: Bool
        switch args.state ?? "toggle" {
        case "on": turnOn = true
        case "off": turnOn = false
        default: turnOn = !wholeHasMark()
        }

        // From the back, so removing a block can't move the index of the ones still to come.
        for stretch in stretches.reversed() {
            editor.edit(stretch.block) { text in
                let range = stretch.range ?? BlockEditor.fullRange(of: text)
                guard range.length > 0 else { return }
                if turnOn {
                    text.addAttribute(attribute.key, value: attribute.value, range: range)
                    if let opposite = mark.opposite?.attribute { text.removeAttribute(opposite.key, range: range) }
                } else {
                    text.removeAttribute(attribute.key, range: range)
                }
            }
        }
        return editor.markdown
    }
}

private func markDescriptor(_ name: String, _ label: String) -> ActionDescriptor {
    ActionDescriptor(
        id: "writer.format.\(name)", summary: "\(label): an, aus oder umschalten", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["state": .choice(["toggle", "on", "off"], "Standard: toggle")])),
        output: .freeObject(), example: "llmd writer format \(name) --doc X --match Wort --state on",
        // The core set stays small: its schemas go into a client's context with every question.
        groups: name == "bold" || name == "italic" ? ["core", "writer.core"] : ["writer.core"]
    )
}

struct WriterFormatBoldAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.bold
    static let descriptor = markDescriptor("bold", "Fett")
}
struct WriterFormatItalicAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.italic
    static let descriptor = markDescriptor("italic", "Kursiv")
}
struct WriterFormatUnderlineAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.underline
    static let descriptor = markDescriptor("underline", "Unterstrichen")
}
struct WriterFormatStrikethroughAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.strikethrough
    static let descriptor = markDescriptor("strikethrough", "Durchgestrichen")
}
struct WriterFormatCodeAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.code
    static let descriptor = markDescriptor("code", "Code im Text")
}
struct WriterFormatSuperscriptAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.superscript
    static let descriptor = markDescriptor("superscript", "Hochgestellt")
}
struct WriterFormatSubscriptAction: WriterMarkAction {
    typealias Args = WriterEditMarkArgs
    typealias Output = WriterWriteResult
    static let mark = WriterInline.subscript
    static let descriptor = markDescriptor("subscript", "Tiefgestellt")
}

struct WriterFormatClearAction: WriterEditAction {
    typealias Args = WriterEditArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.format.clear", summary: "Entfernt Zeichenformate an der Stelle", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject(), groups: ["writer.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        var editor = BlockEditor(markdown: markdown)
        for stretch in try WriterSelection.stretches(args.address, in: markdown).reversed() {
            editor.edit(stretch.block) { text in
                let range = stretch.range ?? BlockEditor.fullRange(of: text)
                for key in WriterInline.keys + WriterMarkdown.passageKeys { text.removeAttribute(key, range: range) }
            }
        }
        return editor.markdown
    }
}
