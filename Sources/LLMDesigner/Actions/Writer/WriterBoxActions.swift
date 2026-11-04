import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterBoxActions() {
        register(WriterBoxInsertAction.self)
        register(WriterBoxStyleAction.self)
        register(WriterBoxRemoveAction.self)
        register(WriterColumnsSetAction.self)
        register(WriterColumnsBreakAction.self)
        register(WriterColumnsRemoveAction.self)
    }
}

struct WriterContainerArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var box: String?
    var section: String?
    var kind: String?
    var title: String?
    var markdown: String?
    var around: Bool?
    var count: Int?
    var position: String?
    var frame: String?
    var width: Int?
    var wrap: Bool?
    var color: String?
    var keepText: Bool?
    var columns: Int?
    var gap: Double?
    var rule: Bool?
    var after: Int?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        box = try c.decodeIfPresent(String.self, forKey: .box)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        around = try c.decodeIfPresent(Bool.self, forKey: .around)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        keepText = try c.decodeIfPresent(Bool.self, forKey: .keepText)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
        gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        rule = try c.decodeIfPresent(Bool.self, forKey: .rule)
        after = try c.decodeIfPresent(Int.self, forKey: .after)
    }

    enum Keys: String, CodingKey {
        case box, section, kind, title, markdown, around, count, position, frame, width, wrap, color, keepText, columns, gap, rule, after
    }

    static let boxReference: [String: JSONSchema] = ["box": .string("Kasten: Nummer im Text ab 1 oder Block-ID; ohne Angabe der einzige")]
    static let sectionReference: [String: JSONSchema] = ["section": .string("Abschnitt mit Spalten: Nummer im Text ab 1 oder Block-ID; ohne Angabe der einzige")]
}

private extension WriterContainerArgs {
    /// Text with one div's lines changed.
    @MainActor
    static func div(_ className: String, reference: String?, in markdown: String, label: String) throws -> (lines: [String], div: WriterLines.Div) {
        let lines = markdown.components(separatedBy: "\n")
        let divs = WriterLines.divs(in: lines).filter { $0.classes.contains(className) }
        let hit = try WriterReference.pick(reference, from: divs, label: label, markdown: markdown) { div, chunk in
            lines[div.open...div.close].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) == chunk
        }
        return (lines, hit)
    }
}

struct WriterBoxInsertAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.box.insert", summary: "Fügt einen Kasten ein, oder legt ihn um vorhandene Blöcke", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging([
            "kind": .choice(WriterBoxKind.allCases.map(\.rawValue), "Art des Kastens"),
            "title": .string("Titel; ohne Angabe der Name der Art, leer: keiner"),
            "markdown": .string("Inhalt als Markdown"),
            "around": .boolean("Um die adressierten Blöcke legen statt neu einfügen"),
            "count": .integer("Mit around: wie viele Blöcke ab der Adresse; Standard 1", minimum: 1),
        ]) { _, new in new }, required: ["kind"]),
        output: .freeObject(), example: "llmd writer box insert --doc X --kind merksatz --markdown 'Wasser ist nass.'"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var style = WriterBoxStyle(kind: WriterBoxKind(rawValue: args.kind ?? "") ?? .definition)
        style.title = args.title
        func box(_ content: String) throws -> String {
            let written = WriterReference.editorForm(style.divOpening + "\n" + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n:::")
            guard written.hasPrefix(":::") else {
                throw RPCError.invalidTarget("Tabellen, Code und Kapitel können nicht in einen Kasten – nur Text, Listen, Formeln und Bilder.")
            }
            return written
        }
        if args.around == true {
            let range = try WriterReference.blockRange(args.address, count: args.count, in: markdown)
            guard !range.isEmpty else { throw RPCError.invalidTarget("Hier gibt es keine Blöcke.") }
            var blocks = PowerText.chunks(of: markdown).map(\.markdown)
            let new = try box(blocks[range].joined(separator: "\n\n"))
            blocks.replaceSubrange(range, with: [new])
            return (PowerText.join(blocks), range.lowerBound)
        }
        guard let content = args.markdown, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.invalidParams("Bitte markdown angeben, oder around mit einer Adresse. Ein leerer Kasten bliebe nicht im Text.")
        }
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        return (PowerText.inserting(try box(content), at: index, into: markdown), index)
    }
}

struct WriterBoxStyleAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.box.style", summary: "Ändert Art, Titel, Platz und Aussehen eines Kastens", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.boxReference) { _, new in new }.merging([
            "kind": .choice(WriterBoxKind.allCases.map(\.rawValue), "Art"),
            "title": .string("Titel; leer: keiner"),
            "position": .choice(WriterBoxStyle.Position.allCases.map(\.rawValue), "Platz"),
            "frame": .choice(WriterBoxStyle.Frame.allCases.map(\.rawValue), "Rahmen"),
            "width": .integer("Breite in Prozent der Spalte", minimum: 20, maximum: 90),
            "wrap": .boolean("Text fließt um einen Kasten links oder rechts"),
            "color": .string("Eigene Farbe; none nimmt sie weg"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer box style --doc X --position right --frame outline"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var (lines, div) = try Args.div(WriterBoxStyle.className, reference: args.box, in: markdown, label: "Kasten")
        var style = WriterBoxStyle(attributes: div.attributes)
        if let kind = args.kind, let value = WriterBoxKind(rawValue: kind) {
            style.kind = value
            // A new kind brings its name along, as in the editor.
            if args.title == nil { style.title = nil }
        }
        if let title = args.title { style.title = title }
        if let position = args.position, let value = WriterBoxStyle.Position(rawValue: position) { style.position = value }
        if let frame = args.frame, let value = WriterBoxStyle.Frame(rawValue: frame) { style.frame = value }
        if let width = args.width { style.width = width }
        if let wrap = args.wrap { style.wraps = wrap }
        if let color = args.color { style.color = color == "none" ? nil : try actionColor(color) }
        lines[div.open] = style.divOpening
        return (WriterLines.normalized(lines), nil)
    }
}

struct WriterBoxRemoveAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.box.remove", summary: "Löst einen Kasten auf; der Text bleibt, außer mit keepText false", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.boxReference) { _, new in new }.merging([
            "keepText": .boolean("Den Inhalt behalten; Standard: true"),
        ]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var (lines, div) = try Args.div(WriterBoxStyle.className, reference: args.box, in: markdown, label: "Kasten")
        if args.keepText == false {
            lines.removeSubrange(div.open...div.close)
        } else {
            lines.remove(at: div.close)
            lines.remove(at: div.open)
        }
        return (WriterLines.normalized(lines), nil)
    }
}

struct WriterColumnsSetAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.columns.set", summary: "Setzt Blöcke in Spalten oder ändert einen Abschnitt mit Spalten", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterAddress.schemaProperties) { _, new in new }.merging(Args.sectionReference) { _, new in new }.merging([
            "columns": .integer("Anzahl der Spalten", minimum: 2, maximum: 3),
            "gap": .number("Abstand in Zentimetern", minimum: 0.2, maximum: 3),
            "rule": .boolean("Linie zwischen den Spalten"),
            "count": .integer("Wie viele Blöcke ab der Adresse; Standard 1, eine Überschrift steht für ihren Abschnitt", minimum: 1),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer columns set --doc X --heading Einleitung --columns 2"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    private static func style(_ args: Args, from old: WriterColumnStyle) -> WriterColumnStyle {
        var style = old
        if let columns = args.columns { style.count = columns }
        if let gap = args.gap { style.gap = gap }
        if let rule = args.rule { style.rule = rule }
        return style
    }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        if args.section != nil {
            var (lines, div) = try Args.div(WriterColumnStyle.className, reference: args.section, in: markdown, label: "Abschnitt mit Spalten")
            lines[div.open] = style(args, from: WriterColumnStyle(attributes: div.attributes)).divOpening
            return (WriterLines.normalized(lines), nil)
        }
        let range = try WriterReference.blockRange(args.address, count: args.count, in: markdown)
        guard !range.isEmpty else { throw RPCError.invalidTarget("Hier gibt es keine Blöcke.") }
        var blocks = PowerText.chunks(of: markdown).map(\.markdown)
        // An address on a section that already has columns changes it.
        if range.count == 1, MarkdownParser.divOpening(blocks[range.lowerBound].components(separatedBy: "\n")[0])?.contains(WriterColumnStyle.className) == true {
            var lines = blocks[range.lowerBound].components(separatedBy: "\n")
            lines[0] = style(args, from: WriterColumnStyle(attributes: MarkdownParser.divAttributes(lines[0]))).divOpening
            blocks[range.lowerBound] = lines.joined(separator: "\n")
            return (PowerText.join(blocks), range.lowerBound)
        }
        let new = WriterReference.editorForm(style(args, from: WriterColumnStyle()).divOpening + "\n" + blocks[range].joined(separator: "\n\n") + "\n:::")
        guard new.contains(WriterColumnStyle.className) else {
            throw RPCError.invalidTarget("Tabellen, Kapitel und Inhaltsverzeichnisse bleiben einspaltig.")
        }
        blocks.replaceSubrange(range, with: [new])
        return (PowerText.join(blocks), range.lowerBound)
    }
}

struct WriterColumnsBreakAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.columns.break", summary: "Fügt in einem Abschnitt mit Spalten einen Spaltenumbruch ein", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.sectionReference) { _, new in new }.merging([
            "after": .integer("Nach dem wievielten Block des Abschnitts; ohne Angabe in der Mitte", minimum: 1),
        ]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let (lines, div) = try Args.div(WriterColumnStyle.className, reference: args.section, in: markdown, label: "Abschnitt mit Spalten")
        var inner = PowerText.chunks(of: lines[(div.open + 1)..<div.close].joined(separator: "\n")).map(\.markdown)
        guard !inner.isEmpty else { throw RPCError.invalidTarget("Der Abschnitt ist leer.") }
        let after = args.after ?? max(1, inner.count / 2)
        guard after <= inner.count else { throw RPCError.notFound("Der Abschnitt hat nur \(inner.count) Blöcke.") }
        inner.insert(MarkdownParser.columnBreakCommand, at: after)
        var result = lines
        result.replaceSubrange((div.open + 1)..<div.close, with: inner.joined(separator: "\n\n").components(separatedBy: "\n"))
        return (WriterLines.normalized(result), nil)
    }
}

struct WriterColumnsRemoveAction: WriterTargetedAction {
    typealias Args = WriterContainerArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.columns.remove", summary: "Setzt einen Abschnitt wieder einspaltig; der Text bleibt", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.sectionReference) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var (lines, div) = try Args.div(WriterColumnStyle.className, reference: args.section, in: markdown, label: "Abschnitt mit Spalten")
        // Column breaks mean nothing without columns.
        for index in stride(from: div.close, through: div.open, by: -1) where index == div.open || index == div.close
            || lines[index].trimmingCharacters(in: .whitespaces) == MarkdownParser.columnBreakCommand {
            lines.remove(at: index)
        }
        return (WriterLines.normalized(lines), nil)
    }
}
