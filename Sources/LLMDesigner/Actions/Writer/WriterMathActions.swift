import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterMathActions() {
        register(WriterFormulaInsertAction.self)
        register(WriterFormulaEditAction.self)
        register(WriterFormulaListAction.self)
        register(WriterPlotInsertAction.self)
        register(WriterPlotEditAction.self)
    }
}

struct WriterMathArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var position: String?
    var latex: String?
    var display: String?
    var formula: String?
    var plot: String?
    var expression: String?
    var x: String?
    var y: String?
    var z: String?
    var t: String?
    var u: String?
    var v: String?
    var style: String?
    var grid: Bool?
    var marks: Bool?
    var parameters: [String: Double]?
    var caption: String?
    var width: Int?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        latex = try c.decodeIfPresent(String.self, forKey: .latex)
        display = try c.decodeIfPresent(String.self, forKey: .display)
        formula = try c.decodeIfPresent(String.self, forKey: .formula)
        plot = try c.decodeIfPresent(String.self, forKey: .plot)
        expression = try c.decodeIfPresent(String.self, forKey: .expression)
        x = try c.decodeIfPresent(String.self, forKey: .x)
        y = try c.decodeIfPresent(String.self, forKey: .y)
        z = try c.decodeIfPresent(String.self, forKey: .z)
        t = try c.decodeIfPresent(String.self, forKey: .t)
        u = try c.decodeIfPresent(String.self, forKey: .u)
        v = try c.decodeIfPresent(String.self, forKey: .v)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        grid = try c.decodeIfPresent(Bool.self, forKey: .grid)
        marks = try c.decodeIfPresent(Bool.self, forKey: .marks)
        parameters = try c.decodeIfPresent([String: Double].self, forKey: .parameters)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
    }

    enum Keys: String, CodingKey {
        case position, latex, display, formula, plot, expression, x, y, z, t, u, v, style, grid, marks, parameters, caption, width
    }

    static let plotProperties: [String: JSONSchema] = [
        "x": .string("Bereich, z. B. -5:5"), "y": .string("Bereich der zweiten Achse; auto wählt ihn aus den Werten"),
        "z": .string("Bereich der Werte oder dritten Achse"), "t": .string("Bereich des Parameters einer Kurve"),
        "u": .string("Bereich des ersten Flächenparameters"), "v": .string("Bereich des zweiten Flächenparameters"),
        "style": .choice(PlotStyle.allCases.map(\.rawValue), "Darstellung"),
        "grid": .boolean("Gitterlinien"), "marks": .boolean("Nullstellen und Extrema markieren"),
        "parameters": .freeObject("Werte der freien Buchstaben, z. B. {\"a\": 2}"),
        "caption": .string("Bildunterschrift"), "width": .integer("Breite in Prozent der Spalte; Standard 70", minimum: 5, maximum: 100),
    ]

    @MainActor
    func apply(to spec: inout PlotSpec) throws {
        for (key, value) in [("x", x), ("y", y), ("z", z), ("t", t), ("u", u), ("v", v)] {
            guard let value else { continue }
            // Only y and z may be left to the values.
            guard PlotRange.parse(value) != nil || ((key == "y" || key == "z") && value == "auto") else {
                throw RPCError.invalidParams("„\(value)“ ist kein Bereich. Bitte von:bis angeben, z. B. -5:5.")
            }
            spec.read(key, value)
        }
        if let style { spec.style = PlotStyle(rawValue: style) }
        if let grid { spec.grid = grid }
        if let marks { spec.marks = marks }
        if let parameters { spec.parameters.merge(parameters) { $1 } }
    }
}

/// The formulas of a text in reading order.
@MainActor
enum WriterFormulaAddressing {
    struct Found {
        let block: Int
        /// The place of the attachment in the block as attributed text.
        let location: Int
        let latex: String
        let isDisplay: Bool
    }

    static func all(in markdown: String) -> [Found] {
        var found: [Found] = []
        for chunk in PowerText.chunks(of: markdown) where chunk.kind != .code && chunk.kind != .image {
            let text = WriterMarkdown.attributedString(from: chunk.markdown)
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let formula = value as? WriterMathAttachment else { return }
                let isDisplay = text.attribute(.writerBlock, at: range.location, effectiveRange: nil) as? String == WriterBlock.math.rawValue
                found.append(Found(block: chunk.id, location: range.location, latex: formula.latex, isDisplay: isDisplay))
            }
        }
        return found
    }

    static func find(_ reference: String?, in markdown: String) throws -> Found {
        let chunks = PowerText.chunks(of: markdown)
        return try WriterReference.pick(reference, from: all(in: markdown), label: "Formel", markdown: markdown) { formula, chunk in
            chunks[formula.block].markdown == chunk
        }
    }
}

private func plotError(_ error: Error) -> RPCError {
    if case PlotError.noPython = error { return .unavailable(error.localizedDescription) }
    return .invalidTarget(error.localizedDescription)
}

/// Draws a formula's plot and stores it. It takes a while: Python runs.
@MainActor
private func drawPlot(latex: String, spec: PlotSpec, caption: String, width: Int?) async throws -> WriterImageReference {
    do {
        let program = try PlotTranslator.program(for: latex)
        var spec = spec
        spec.parameters = spec.parameters.filter { program.parameters.contains($0.key) }
        for name in program.parameters where spec.parameters[name] == nil { spec.parameters[name] = 1 }
        let output = try await PlotRenderer.shared.render(program, spec: spec)
        let source = try WriterImageStore.storePlot(output)
        return WriterImageReference(source: source, caption: caption, width: width, plot: spec)
    } catch {
        throw plotError(error)
    }
}

struct WriterFormulaInsertAction: WriterTargetedAction {
    typealias Args = WriterMathArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.formula.insert", summary: "Fügt eine Formel ein, als eigenen Block oder im Text", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging([
            "latex": .string("Die Formel in LaTeX, ohne Dollarzeichen"),
            "display": .choice(["block", "inline"], "Standard: block; inline braucht eine Stelle im Text"),
        ]) { _, new in new }, required: ["latex"]),
        output: .freeObject(), example: "llmd writer formula insert --doc X --latex 'E = mc^2'"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let latex = (args.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty else { throw RPCError.invalidParams("Die Formel ist leer.") }
        guard args.display == "inline" else {
            let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
            return (PowerText.inserting(WriterMathAttachment(latex: latex).blockMarkdown, at: index, into: markdown), index)
        }
        guard !args.address.isEmpty else { throw RPCError.invalidParams("Eine Formel im Text braucht eine Stelle: match, block oder range.") }
        let block: Int
        var location: Int?
        switch try WriterAddressing.resolve(args.address, in: markdown) {
        case .whole: throw RPCError.invalidParams("Eine Formel im Text braucht eine Stelle: match, block oder range.")
        case .blocks(let range): block = range.lowerBound
        case .text(let found, let range):
            block = found
            location = args.position == "before" ? range.location : NSMaxRange(range)
        case .source(let range):
            let stretch = try WriterAddressing.textStretch(for: range, in: markdown)
            block = stretch.block
            location = args.position == "before" ? stretch.range.location : NSMaxRange(stretch.range)
        }
        guard BlockEditor.holdsText(PowerText.chunks(of: markdown)[block].kind) else { throw RPCError.invalidTarget("Dieser Block hat keinen Fließtext.") }
        var editor = BlockEditor(markdown: markdown)
        editor.edit(block) { text in
            let place = location ?? BlockEditor.fullRange(of: text).length
            let formula = NSMutableAttributedString(attachment: WriterMathAttachment(latex: latex))
            if text.length > 0 {
                let attributes = text.attributes(at: min(max(0, place - 1), text.length - 1), effectiveRange: nil).filter { key, _ in
                    WriterMarkdown.paragraphKeys.contains(key)
                }
                formula.addAttributes(attributes, range: NSRange(location: 0, length: formula.length))
            }
            text.insert(formula, at: place)
        }
        return (editor.markdown, block)
    }
}

struct WriterFormulaEditAction: WriterTargetedAction {
    typealias Args = WriterMathArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.formula.edit", summary: "Ändert eine Formel; leer nimmt sie mit ihrem Plot weg", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging([
            "formula": .string("Formel: Nummer aus writer.formula.list oder Block-ID; ohne Angabe die einzige"),
            "latex": .string("Die neue Formel in LaTeX"),
        ]) { _, new in new }, required: ["latex"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let found = try WriterFormulaAddressing.find(args.formula, in: markdown)
        let latex = (args.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var editor = BlockEditor(markdown: markdown)
        let chunks = PowerText.chunks(of: markdown)
        // An emptied display formula goes with the plot below it.
        if latex.isEmpty, found.isDisplay, chunks.indices.contains(found.block + 1),
           WriterImageReference.parse(chunks[found.block + 1].markdown)?.plot != nil {
            editor.blocks.remove(at: found.block + 1)
        }
        editor.edit(found.block) { text in
            let range = NSRange(location: found.location, length: 1)
            if latex.isEmpty {
                text.deleteCharacters(in: range)
            } else {
                text.addAttribute(.attachment, value: WriterMathAttachment(latex: latex), range: range)
            }
        }
        return (editor.markdown, latex.isEmpty ? nil : found.block)
    }
}

struct WriterFormulaListAction: LLMDAction {
    typealias Args = WriterMathArgs
    struct Item: Encodable, Sendable {
        var number: Int
        var latex: String
        var display: String
        var block: String
    }
    struct Output: Encodable, Sendable {
        var formulas: [Item]
        var version: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.formula.list", summary: "Listet die Formeln eines Textes in Lesereihenfolge", kind: .read, security: .plainRead,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        let chunks = PowerText.chunks(of: markdown)
        let items = WriterFormulaAddressing.all(in: markdown).enumerated().map { index, found in
            Item(number: index + 1, latex: found.latex, display: found.isDisplay ? "block" : "inline",
                 block: WriterBlockInfo.id(index: found.block, in: chunks))
        }
        return Output(formulas: items, version: target.version)
    }
}

struct WriterPlotInsertAction: WriterTargetedAction {
    typealias Args = WriterMathArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.plot.insert", summary: "Zeichnet den Plot einer Formel und setzt ihn darunter; ein alter Plot wird ersetzt", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging(Args.plotProperties) { _, new in new }.merging([
            "formula": .string("Eine Formel im Text: Nummer aus writer.formula.list oder Block-ID"),
            "expression": .string("Eine neue Formel in LaTeX; sie kommt samt Plot an die Stelle der Adresse"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer plot insert --doc X --expression 'f(x) = x^2' --x -3:3"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var spec = PlotSpec()
        try args.apply(to: &spec)
        if let expression = args.expression?.trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty {
            let reference = try await drawPlot(latex: expression, spec: spec, caption: args.caption ?? "", width: args.width ?? 70)
            // The person may have typed while Python ran.
            let current = target.markdown
            let index = try WriterPlacement.index(args.address, position: args.position, in: current)
            let new = WriterMathAttachment(latex: expression).blockMarkdown + "\n\n" + reference.markdown
            return (PowerText.inserting(new, at: index, into: current), index)
        }
        let found = try WriterFormulaAddressing.find(args.formula, in: markdown)
        guard found.isDisplay else { throw RPCError.invalidTarget("Einen Plot bekommen nur Formeln als eigener Block.") }
        let reference = try await drawPlot(latex: found.latex, spec: spec, caption: args.caption ?? "", width: args.width ?? 70)
        let current = target.markdown
        let again = try WriterFormulaAddressing.find(args.formula, in: current)
        guard again.latex == found.latex else { throw RPCError.versionConflict(current: target.version) }
        var blocks = PowerText.chunks(of: current).map(\.markdown)
        if blocks.indices.contains(again.block + 1), WriterImageReference.parse(blocks[again.block + 1])?.plot != nil {
            blocks[again.block + 1] = reference.markdown
        } else {
            blocks.insert(reference.markdown, at: again.block + 1)
        }
        return (PowerText.join(blocks), again.block + 1)
    }
}

struct WriterPlotEditAction: WriterTargetedAction {
    typealias Args = WriterMathArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.plot.edit", summary: "Zeichnet einen Plot mit anderen Bereichen neu oder ändert Unterschrift und Breite", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.plotProperties) { _, new in new }.merging([
            "plot": .string("Plot: Nummer unter den Plots ab 1 oder Block-ID; ohne Angabe der einzige"),
        ]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let before = try WriterImageAddressing.find(args.plot, in: markdown, label: "Plot") { $0.plot != nil }
        var reference = before.reference
        var spec = reference.plot ?? PlotSpec()
        try args.apply(to: &spec)
        if spec != reference.plot {
            // The plot's formula is the block above it.
            let chunks = PowerText.chunks(of: markdown)
            guard let index = chunks.firstIndex(where: { $0.kind == .image && WriterImageReference.parse($0.markdown)?.source == reference.source }),
                  index > 0, let formula = WriterFormulaAddressing.all(in: markdown).last(where: { $0.block == index - 1 && $0.isDisplay }) else {
                throw RPCError.invalidTarget("Über diesem Plot steht keine Formel.")
            }
            reference = try await drawPlot(latex: formula.latex, spec: spec, caption: reference.caption, width: reference.width)
        }
        reference.caption = args.caption ?? reference.caption
        reference.width = args.width ?? reference.width
        let found = try WriterImageAddressing.find(args.plot, in: target.markdown, label: "Plot") { $0.plot != nil }
        guard found.reference.source == before.reference.source else { throw RPCError.versionConflict(current: target.version) }
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}
