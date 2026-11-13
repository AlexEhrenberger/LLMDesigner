import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterTableActions() {
        register(WriterTableInsertAction.self)
        register(WriterTableReadAction.self)
        register(WriterTableCellSetAction.self)
        register(WriterTableRowInsertAction.self)
        register(WriterTableColumnInsertAction.self)
        register(WriterTableRowDeleteAction.self)
        register(WriterTableColumnDeleteAction.self)
        register(WriterTableCellsMergeAction.self)
        register(WriterTableCellSplitAction.self)
        register(WriterTableAlignAction.self)
        register(WriterTableColumnsEqualizeAction.self)
        register(WriterTableColumnsSetWidthsAction.self)
        register(WriterTableStyleAction.self)
        register(WriterTableFormulaSetAction.self)
        register(WriterTableSumRowAction.self)
        register(WriterTableSortAction.self)
        register(WriterTableRecalculateAction.self)
        register(WriterTableToChartAction.self)
        register(WriterTableDeleteAction.self)
    }
}

/// Everything table actions take. Each action's schema says which of these it accepts.
struct WriterTableArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var table: String?
    var cell: String?
    var row: Int?
    var column: Int?
    var from: String?
    var to: String?
    var at: Int?
    var position: String?
    var direction: String?
    var text: String?
    var markdown: String?
    var alignment: String?
    var widths: [Double]?
    var lines: String?
    var lineWidth: Double?
    var fill: String?
    var formula: String?
    var ascending: Bool?
    var kind: String?
    var title: String?
    var caption: String?
    var rows: Int?
    var columns: Int?
    var header: [String]?
    var data: [[String]]?
    var asMarkdown: Bool?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        table = try c.decodeIfPresent(String.self, forKey: .table)
        cell = try c.decodeIfPresent(String.self, forKey: .cell)
        row = try c.decodeIfPresent(Int.self, forKey: .row)
        column = try c.decodeIfPresent(Int.self, forKey: .column)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        at = try c.decodeIfPresent(Int.self, forKey: .at)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        alignment = try c.decodeIfPresent(String.self, forKey: .alignment)
        widths = try c.decodeIfPresent([Double].self, forKey: .widths)
        lines = try c.decodeIfPresent(String.self, forKey: .lines)
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth)
        fill = try c.decodeIfPresent(String.self, forKey: .fill)
        formula = try c.decodeIfPresent(String.self, forKey: .formula)
        ascending = try c.decodeIfPresent(Bool.self, forKey: .ascending)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        rows = try c.decodeIfPresent(Int.self, forKey: .rows)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
        header = try c.decodeIfPresent([String].self, forKey: .header)
        data = try c.decodeIfPresent([[String]].self, forKey: .data)
        asMarkdown = try c.decodeIfPresent(Bool.self, forKey: .asMarkdown)
    }

    enum Keys: String, CodingKey {
        case table, cell, row, column, from, to, at, position, direction, text, markdown, alignment, widths, lines, lineWidth, fill, formula,
             ascending, kind, title, caption, rows, columns, header, data, asMarkdown
    }

    static let cellProperties: [String: JSONSchema] = [
        "cell": .string("Zelle wie in Formeln: A1 ist links oben, Zeile 1 die Kopfzeile"),
        "row": .integer("Zeile ab 1, mit column", minimum: 1),
        "column": .integer("Spalte ab 1, mit row", minimum: 1),
    ]

    /// The properties of a table action: the text, the table, and what it adds.
    static func properties(_ extra: [String: JSONSchema] = [:]) -> [String: JSONSchema] {
        WriterTargetArgs.schemaProperties
            .merging(["table": .string("Tabelle: Nummer im Text ab 1, Block-ID oder tab-Name; ohne Angabe die einzige")]) { _, new in new }
            .merging(extra) { _, new in new }
    }

    /// The addressed cell of this table.
    @MainActor
    func place(in table: MarkdownTable) throws -> WriterCellPosition {
        if let cell { return try table.place(named: cell) }
        guard let row, let column else { throw RPCError.invalidParams("Bitte cell angeben (z. B. B2), oder row und column.") }
        return try table.place(row: row - 1, column: column - 1)
    }

    @MainActor
    var cellMarkdown: String? {
        if let text { return MarkdownTable.cell(text: text) }
        return markdown.map { MarkdownTable.cell(markdown: $0) }
    }
}

/// A change to an existing table: only its block changes, and formulas and charts that hang on it follow.
@MainActor
protocol WriterTableChangeAction: LLMDAction where Args == WriterTableArgs, Output == WriterWriteResult {
    /// false: the table goes away as a whole.
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool
}

@MainActor
extension WriterTableChangeAction {
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        var found = try WriterTableAddressing.find(args.table, in: markdown)
        let keeps = try change(&found.table, args: args, context: context)
        guard keeps else {
            return try target.replaceText(with: PowerText.replacing(found.block, with: "", in: markdown), ifVersion: args.target.ifVersion, context: context)
        }
        found.table.recalculate()
        let text = PowerText.replacing(found.block, with: found.table.markdown, in: markdown)
        let result = try target.replaceBlocks(with: text, block: found.block, ifVersion: args.target.ifVersion, context: context)
        WriterChartLink.refresh(table: found.table, in: text, family: target.document?.font ?? .serif)
        return result
    }
}

/// Charts made from a table follow its numbers, also when the document isn't open.
@MainActor
enum WriterChartLink {
    static func refresh(table: MarkdownTable, in markdown: String, family: WriterFont) {
        guard let id = table.style.id else { return }
        for chunk in PowerText.chunks(of: markdown) where chunk.kind == .image {
            guard let reference = WriterImageReference.parse(chunk.markdown), reference.figure == .chart,
                  var chart = WriterChart.decode(WriterImageStore.recipe(for: reference)), chart.table == id else { continue }
            let before = chart
            chart.takeData(from: table.plainCells, formulas: table.style.formulas)
            guard chart != before, let images = WriterFigureRenderer.images(of: chart, family: family) else { continue }
            try? WriterImageStore.write(images, to: reference.source)
            if let url = WriterImageStore.targetURL(for: WriterImageStore.recipeVariant(of: reference.source, kind: .chart)) { try? chart.json.write(to: url, options: .atomic) }
        }
    }
}

struct WriterTableInsertAction: LLMDAction {
    typealias Args = WriterTableArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.table.insert", summary: "Fügt eine Tabelle ein, leer oder mit Inhalt; die erste Zeile ist die Kopfzeile", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging([
            "rows": .integer("Zeilen samt Kopfzeile", minimum: 1, maximum: 200),
            "columns": .integer("Spalten", minimum: 1, maximum: 30),
            "header": .array(of: .string(), "Kopfzeile"),
            "data": .array(of: .array(of: .string()), "Zeilen als Listen von Zellen; =SUMME(B2:B5) wird Formel"),
            "asMarkdown": .boolean("Die Zellen sind Markdown statt reiner Text"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer table insert --doc X --rows 3 --columns 2"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        var content = (args.header.map { [$0] } ?? []) + (args.data ?? [])
        let width = max(args.columns ?? 0, content.map(\.count).max() ?? 0)
        guard width > 0 else { throw RPCError.invalidParams("Bitte columns angeben oder Inhalt in header oder data.") }
        if let rows = args.rows, rows > content.count { content += Array(repeating: [], count: rows - content.count) }
        if content.isEmpty { content = [[]] }
        content = content.map { $0 + Array(repeating: "", count: width - $0.count) }
        var table = MarkdownTable(cells: content.map { $0.map { args.asMarkdown == true ? MarkdownTable.cell(markdown: $0) : MarkdownTable.cell(text: $0) } })
        for (row, values) in content.enumerated() {
            for (column, value) in values.enumerated() where WriterTableCalc.isFormulaText(value) {
                table.setFormula(value, at: WriterCellPosition(row: row, column: column))
            }
        }
        table.recalculate()
        return try target.insertBlocks(table.markdown, at: args.address, position: args.position, ifVersion: args.target.ifVersion, context: context)
    }
}

struct WriterTableReadAction: LLMDAction {
    typealias Args = WriterTableArgs
    struct Merged: Encodable, Sendable {
        var cell: String
        var rows: Int
        var columns: Int
    }
    struct Output: Encodable, Sendable {
        var block: String
        var number: Int
        var name: String?
        var rows: Int
        var columns: Int
        var cells: [[String]]
        var markdown: [[String]]
        var alignments: [String]
        var widths: [Double]?
        var merged: [Merged]
        var formulas: [String: String]
        var fills: [String: String]
        var lines: String
        var lineWidth: Double?
        var version: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.table.read", summary: "Liest eine Tabelle: Zellen, Formeln, verbundene Zellen und Aussehen", kind: .read, security: .plainRead,
        input: .object(Args.properties()), output: .freeObject(), example: "llmd writer table read --doc X --table 1"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        let found = try WriterTableAddressing.find(args.table, in: markdown)
        let table = found.table
        func name(_ place: WriterCellPosition) -> String { WriterTableCalc.cellName(row: place.row, column: place.column) }
        return Output(
            block: WriterBlockInfo.id(index: found.block, in: PowerText.chunks(of: markdown)),
            number: found.number, name: table.style.id, rows: table.rows, columns: table.columns, cells: table.plainCells, markdown: table.cells,
            alignments: table.alignments.map { $0 == .center ? "center" : $0 == .trailing ? "right" : "left" },
            widths: table.widths,
            merged: table.spans.sorted { $0.key < $1.key }.map { Merged(cell: name($0.key), rows: $0.value.rows, columns: $0.value.columns) },
            formulas: Dictionary(uniqueKeysWithValues: table.style.formulas.map { (name($0.key), "=" + $0.value) }),
            fills: Dictionary(uniqueKeysWithValues: table.style.fills.map { (name($0.key), $0.value) }),
            lines: table.style.lines.rawValue, lineWidth: table.style.lineWidth, version: target.version
        )
    }
}

struct WriterTableCellSetAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.cell.set", summary: "Setzt den Inhalt einer Zelle; =… wird Formel", kind: .write, security: .localWrite,
        input: .object(Args.properties(Args.cellProperties.merging(["text": .string("Text ohne Markup"), "markdown": .string("Text als Markdown")]) { _, new in new })),
        output: .freeObject(), example: "llmd writer table cell set --doc X --cell B2 --text 42"
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let place = try args.place(in: table)
        guard let content = args.cellMarkdown else { throw RPCError.invalidParams("Bitte text oder markdown angeben.") }
        if let text = args.text, WriterTableCalc.isFormulaText(text) {
            table.setFormula(text, at: place)
        } else {
            table.setCell(place, markdown: content)
        }
        return true
    }
}

struct WriterTableRowInsertAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.row.insert", summary: "Fügt eine Zeile ein", kind: .write, security: .localWrite,
        input: .object(Args.properties(["at": .integer("Zeile ab 1; Standard: die letzte", minimum: 1), "position": .choice(["above", "below"], "Standard: below")])),
        output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let row = (args.at ?? table.rows) - 1
        _ = try table.place(row: row, column: 0)
        table.insertRow(at: args.position == "above" ? row : row + 1)
        return true
    }
}

struct WriterTableColumnInsertAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.column.insert", summary: "Fügt eine Spalte ein", kind: .write, security: .localWrite,
        input: .object(Args.properties(["at": .integer("Spalte ab 1; Standard: die letzte", minimum: 1), "position": .choice(["left", "right"], "Standard: right")])),
        output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let column = (args.at ?? table.columns) - 1
        _ = try table.place(row: 0, column: column)
        table.insertColumn(at: args.position == "left" ? column : column + 1)
        return true
    }
}

struct WriterTableRowDeleteAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.row.delete", summary: "Löscht eine Zeile; die letzte verbliebene nimmt die Tabelle mit", kind: .write, security: .localWrite,
        input: .object(Args.properties(["at": .integer("Zeile ab 1", minimum: 1)]), required: ["at"]), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let row = (args.at ?? 1) - 1
        _ = try table.place(row: row, column: 0)
        guard table.rows > 1 else { return false }
        table.deleteRow(at: row)
        return true
    }
}

struct WriterTableColumnDeleteAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.column.delete", summary: "Löscht eine Spalte; die letzte verbliebene nimmt die Tabelle mit", kind: .write, security: .localWrite,
        input: .object(Args.properties(["at": .integer("Spalte ab 1", minimum: 1)]), required: ["at"]), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let column = (args.at ?? 1) - 1
        _ = try table.place(row: 0, column: column)
        guard table.columns > 1 else { return false }
        table.deleteColumn(at: column)
        return true
    }
}

struct WriterTableCellsMergeAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.cells.merge", summary: "Verbindet Zellen: ein Rechteck, oder eine Zelle mit der rechts oder unter ihr", kind: .write, security: .localWrite,
        input: .object(Args.properties(Args.cellProperties.merging([
            "from": .string("Erste Zelle des Rechtecks, z. B. A1"), "to": .string("Letzte Zelle des Rechtecks, z. B. B2"),
            "direction": .choice(["right", "down"], "Mit der Nachbarzelle, zusammen mit cell oder row und column"),
        ]) { _, new in new })),
        output: .freeObject(), example: "llmd writer table cells merge --doc X --from A1 --to B1"
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        if let from = args.from, let to = args.to {
            try table.merge(from: try table.place(named: from), to: try table.place(named: to))
            return true
        }
        guard let direction = args.direction else { throw RPCError.invalidParams("Bitte from und to angeben, oder eine Zelle und direction.") }
        let cell = WriterTableMerge.cell(at: try args.place(in: table), in: table.spans)
        var last = WriterCellPosition(row: cell.start.row + cell.span.rows - 1, column: cell.start.column + cell.span.columns - 1)
        if direction == "right" { last.column += 1 } else { last.row += 1 }
        try table.merge(from: cell.start, to: try table.place(row: last.row, column: last.column))
        return true
    }
}

struct WriterTableCellSplitAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.cell.split", summary: "Hebt die Verbindung einer Zelle auf", kind: .write, security: .localWrite,
        input: .object(Args.properties(Args.cellProperties)), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        try table.split(at: try args.place(in: table))
        return true
    }
}

struct WriterTableAlignAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.align", summary: "Richtet Spalten aus; Markdown kennt die Ausrichtung nur je Spalte", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "column": .integer("Spalte ab 1; ohne Angabe alle", minimum: 1),
            "alignment": .choice(["left", "center", "right"], "Ausrichtung"),
        ]), required: ["alignment"]),
        output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let alignment: MarkdownBlock.Alignment = args.alignment == "center" ? .center : args.alignment == "right" ? .trailing : .leading
        if let column = args.column {
            _ = try table.place(row: 0, column: column - 1)
            table.alignments[column - 1] = alignment
        } else {
            table.alignments = Array(repeating: alignment, count: table.columns)
        }
        return true
    }
}

struct WriterTableColumnsEqualizeAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.columns.equalize", summary: "Macht alle Spalten gleich breit", kind: .write, security: .localWrite,
        input: .object(Args.properties()), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        table.widths = nil
        return true
    }
}

struct WriterTableColumnsSetWidthsAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.columns.setWidths", summary: "Setzt die Spaltenbreiten als Anteile, z. B. 2, 1, 1", kind: .write, security: .localWrite,
        input: .object(Args.properties(["widths": .array(of: .number(minimum: 0), "Eine Zahl je Spalte")]), required: ["widths"]), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let widths = args.widths ?? []
        guard widths.count == table.columns else { throw RPCError.invalidParams("Die Tabelle hat \(table.columns) Spalten, nicht \(widths.count).") }
        guard widths.allSatisfy({ $0 > 0 }) else { throw RPCError.invalidParams("Spaltenbreiten müssen größer als 0 sein.") }
        table.widths = WriterTable.normalized(widths.map { CGFloat($0) }, columns: table.columns)?.map { Double($0) }
        return true
    }
}

struct WriterTableStyleAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.style", summary: "Setzt Linien, Linienstärke und die Farbe von Zellen", kind: .write, security: .localWrite,
        input: .object(Args.properties(Args.cellProperties.merging([
            "lines": .choice(WriterTableLines.allCases.map(\.rawValue), "Linien im Druck"),
            "lineWidth": .number("Stärke in Punkt; 0 ist dünn", minimum: 0, maximum: 4),
            "fill": .string("Farbe der Zelle oder des Bereichs; none nimmt sie weg"),
            "from": .string("Erste Zelle des Bereichs"), "to": .string("Letzte Zelle des Bereichs"),
        ]) { _, new in new })),
        output: .freeObject(), example: "llmd writer table style --doc X --lines grid --cell A1 --fill FFF2CC"
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        guard args.lines != nil || args.lineWidth != nil || args.fill != nil else { throw RPCError.invalidParams("Bitte lines, lineWidth oder fill angeben.") }
        if let lines = args.lines { table.style.lines = WriterTableLines(rawValue: lines) ?? .standard }
        if let width = args.lineWidth { table.style.lineWidth = width == 0 ? nil : width }
        if let fill = args.fill {
            let color = fill == "none" ? nil : try actionColor(fill)
            let first: WriterCellPosition, last: WriterCellPosition
            if let from = args.from, let to = args.to {
                first = try table.place(named: from)
                last = try table.place(named: to)
            } else {
                first = try args.place(in: table)
                last = first
            }
            // A merged cell's colour sits at its first place.
            for row in min(first.row, last.row)...max(first.row, last.row) {
                for column in min(first.column, last.column)...max(first.column, last.column) {
                    table.style.fills[WriterTableMerge.cell(at: WriterCellPosition(row: row, column: column), in: table.spans).start] = color
                }
            }
        }
        return true
    }
}

struct WriterTableFormulaSetAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.formula.set", summary: "Gibt einer Zelle eine Formel; leer nimmt sie weg, der Wert bleibt", kind: .write, security: .localWrite,
        input: .object(Args.properties(Args.cellProperties.merging(["formula": .string("z. B. =SUMME(B2:B5)")]) { _, new in new }), required: ["formula"]),
        output: .freeObject(), example: "llmd writer table formula set --doc X --cell B6 --formula '=SUMME(B2:B5)'"
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let formula = WriterTableCalc.normalized(args.formula ?? "")
        if !formula.isEmpty {
            do {
                _ = try WriterTableCalc.parse(formula)
            } catch {
                throw RPCError.invalidParams("Die Formel „\(formula)“ lässt sich nicht lesen.")
            }
        }
        table.setFormula(formula, at: try args.place(in: table))
        return true
    }
}

struct WriterTableSumRowAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.sumRow", summary: "Fügt am Ende eine Zeile mit den Summen aller Zahlenspalten an", kind: .write, security: .localWrite,
        input: .object(Args.properties()), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        try table.addSumRow()
        return true
    }
}

struct WriterTableSortAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.sort", summary: "Sortiert die Zeilen unter der Kopfzeile nach einer Spalte", kind: .write, security: .localWrite,
        input: .object(Args.properties(["column": .integer("Spalte ab 1", minimum: 1), "ascending": .boolean("Aufsteigend; Standard: true")]), required: ["column"]),
        output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool {
        let column = (args.column ?? 1) - 1
        _ = try table.place(row: 0, column: column)
        try table.sort(column: column, ascending: args.ascending ?? true)
        return true
    }
}

struct WriterTableRecalculateAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.recalculate", summary: "Rechnet die Formeln einer Tabelle neu", kind: .write, security: .localWrite,
        input: .object(Args.properties()), output: .freeObject()
    )
    /// Every change recalculates anyway; this is the change that only does that.
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool { true }
}

struct WriterTableDeleteAction: WriterTableChangeAction {
    static let descriptor = ActionDescriptor(
        id: "writer.table.delete", summary: "Löscht eine Tabelle", kind: .write, security: .localWrite,
        input: .object(Args.properties()), output: .freeObject()
    )
    static func change(_ table: inout MarkdownTable, args: Args, context: ActionContext) throws -> Bool { false }
}

struct WriterTableToChartAction: LLMDAction {
    typealias Args = WriterTableArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.table.toChart", summary: "Macht aus einer Tabelle ein Diagramm darunter, das ihren Zahlen folgt", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "kind": .choice(WriterChart.Kind.allCases.map(\.rawValue), "Diagrammart; ohne Angabe passend zu den Daten"),
            "title": .string("Titel im Diagramm"), "caption": .string("Bildunterschrift"),
        ])),
        output: .freeObject(), example: "llmd writer table to-chart --doc X --kind column"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        var found = try WriterTableAddressing.find(args.table, in: markdown)
        let id = found.table.style.id ?? WriterTableStyle.newID()
        var chart = WriterChart()
        chart.table = id
        chart.takeData(from: found.table.plainCells, formulas: found.table.style.formulas)
        guard !chart.series.isEmpty else {
            throw RPCError.invalidTarget("In der Tabelle stehen keine Zahlen für ein Diagramm – die erste Zeile benennt die Reihen, die erste Spalte die Kategorien.")
        }
        chart.kind = args.kind.flatMap(WriterChart.Kind.init(rawValue:)) ?? (chart.categories.count > 8 && chart.series.count == 1 ? .line : .column)
        chart.title = args.title ?? ""
        let reference = try WriterFigureActions.store(chart, caption: args.caption ?? "", width: 80, family: target.document?.font ?? .serif)
        found.table.style.id = id
        var blocks = PowerText.chunks(of: markdown).map(\.markdown)
        blocks[found.block] = found.table.markdown
        blocks.insert(reference.markdown, at: found.block + 1)
        return try target.replaceBlocks(with: PowerText.join(blocks), block: found.block + 1, ifVersion: args.target.ifVersion, context: context)
    }
}

/// Figures as files next to the document; the editors make them the same way.
@MainActor
enum WriterFigureActions {
    static func store(_ chart: WriterChart, caption: String, width: Int?, family: WriterFont) throws -> WriterImageReference {
        guard let images = WriterFigureRenderer.images(of: chart, family: family) else { throw RPCError.internal("Das Diagramm ließ sich nicht zeichnen.") }
        let source = try WriterImageStore.storeFigure(.chart, images: images, recipe: chart.json)
        return WriterImageReference(source: source, caption: caption, width: width, figure: .chart)
    }
}
