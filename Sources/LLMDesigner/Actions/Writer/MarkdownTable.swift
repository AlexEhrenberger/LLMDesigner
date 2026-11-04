import AppKit
import LLMDProtocol

/// A table as its Markdown says it: the cells' Markdown by row and column, the columns' alignment and width, merged
/// cells and the look from the div around it. The editor's `WriterTable` needs a text view around it; actions work on
/// documents that may not be open, and go through the same rules (`WriterTableMerge`, `WriterTableStyle`,
/// `WriterTableCalc`) and the same writer, so a change comes out as if it had been made in the editor.
@MainActor
struct MarkdownTable {
    /// Header row first. Places that a merged cell covers are empty here; their marks come back when written.
    var cells: [[String]]
    var alignments: [MarkdownBlock.Alignment]
    var widths: [Double]?
    var spans: [WriterCellPosition: WriterCellSpan]
    var style: WriterTableStyle

    var rows: Int { cells.count }
    var columns: Int { alignments.count }

    init(cells: [[String]]) {
        let columns = max(1, cells.map(\.count).max() ?? 1)
        self.cells = cells.map { $0 + Array(repeating: "", count: columns - $0.count) }
        alignments = Array(repeating: .leading, count: columns)
        spans = [:]
        style = WriterTableStyle()
    }

    /// nil unless this Markdown is one table and nothing else (with or without the div of its look).
    init?(markdown: String) {
        let blocks = MarkdownParser.parseAnnotated(markdown)
        guard blocks.count == 1, case .table(let header, let rows, let alignments, let widths) = blocks[0].block,
              blocks[0].divs.allSatisfy({ $0.classes.contains(WriterTableStyle.className) }) else { return nil }
        let columns = max(header.count, rows.map(\.count).max() ?? 0, 1)
        let all = ([header] + rows).map { $0 + Array(repeating: "", count: columns - $0.count) }
        self.alignments = (0..<columns).map { $0 < alignments.count ? alignments[$0] : .leading }
        self.widths = widths
        spans = WriterTableMerge.spans(in: all, columns: columns)
        style = blocks[0].div(WriterTableStyle.className).map { WriterTableStyle(attributes: $0.attributes) } ?? WriterTableStyle()
        let covered = WriterTableMerge.covered(by: spans)
        cells = all.enumerated().map { row, values in
            values.enumerated().map { covered.contains(WriterCellPosition(row: row, column: $0)) ? "" : $1 }
        }
    }

    var markdown: String {
        let table = WriterTable(columns: columns, alignments: alignments, widths: widths?.map { CGFloat($0) }, spans: spans, style: style, rows: rows)
        var map: [Int: [Int: String]] = [:]
        for (row, values) in cells.enumerated() {
            map[row] = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0, $1) })
        }
        let body = WriterMarkdown.tableMarkdown(table, cells: map)
        guard let div = style.divOpening else { return body }
        return div + "\n" + body + "\n:::"
    }

    // MARK: Text

    /// A plain text as a cell's Markdown: `|` would end the cell and a line break the row.
    static func cell(text: String) -> String {
        WriterMarkdown.escape(text, atLineStart: false)
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Markdown as a cell's Markdown: `|` that isn't escaped yet is, a line break becomes `<br>`.
    static func cell(markdown: String) -> String {
        var result = ""
        var escaped = false
        for character in markdown.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character == "|", !escaped { result.append("\\") }
            if character == "\n" { result += "<br>" } else { result.append(character) }
            escaped = character == "\\" && !escaped
        }
        return result
    }

    /// The cells as they read, as the formulas and charts of the editor see them (`WriterTextView.cellTexts`).
    var plainCells: [[String]] {
        cells.map { row in
            row.map { cell in
                let breaks = cell.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
                return WriterMarkdown.inline(breaks).string.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
    }

    // MARK: Places

    func isCovered(_ place: WriterCellPosition) -> Bool {
        WriterTableMerge.covered(by: spans).contains(place)
    }

    /// `B2`, as formulas name cells.
    func place(named name: String) throws -> WriterCellPosition {
        let letters = name.prefix { $0.isLetter }
        guard let row = Int(name.dropFirst(letters.count)), let column = WriterTableCalc.column(named: letters.uppercased()), row >= 1 else {
            throw RPCError.invalidParams("„\(name)“ ist keine Zelle. Zellen heißen wie in Formeln: A1 ist links oben.")
        }
        return try place(row: row - 1, column: column)
    }

    /// A place by index from 0, checked against the table.
    func place(row: Int, column: Int) throws -> WriterCellPosition {
        guard row >= 0, row < rows else { throw RPCError.notFound("Zeile \(row + 1) gibt es nicht (\(rows) Zeilen).") }
        guard column >= 0, column < columns else { throw RPCError.notFound("Spalte \(column + 1) gibt es nicht (\(columns) Spalten).") }
        return WriterCellPosition(row: row, column: column)
    }

    // MARK: Changes

    mutating func insertRow(at row: Int) {
        cells.insert(Array(repeating: "", count: columns), at: row)
        (spans, style.fills) = WriterTableMerge.inserting(at: row, isRow: true, spans: spans, fills: style.fills)
        style.formulas = style.formulasShifted(at: row, isRow: true, delta: 1)
    }

    mutating func insertColumn(at column: Int) {
        // A new column gets an average share; the others make room when written.
        let share = 1 / Double(columns)
        widths?.insert(share, at: column)
        for row in cells.indices { cells[row].insert("", at: column) }
        alignments.insert(.leading, at: column)
        (spans, style.fills) = WriterTableMerge.inserting(at: column, isRow: false, spans: spans, fills: style.fills)
        style.formulas = style.formulasShifted(at: column, isRow: false, delta: 1)
    }

    mutating func deleteRow(at row: Int) {
        // A merged cell that begins in this row and goes on keeps its text in the row that moves up.
        for (start, merged) in spans where start.row == row && merged.rows > 1 && row + 1 < rows {
            cells[row + 1][start.column] = cells[row][start.column]
        }
        cells.remove(at: row)
        (spans, style.fills) = WriterTableMerge.removing(at: row, isRow: true, spans: spans, fills: style.fills)
        style.formulas = style.formulasShifted(at: row, isRow: true, delta: -1)
    }

    mutating func deleteColumn(at column: Int) {
        for (start, merged) in spans where start.column == column && merged.columns > 1 && column + 1 < columns {
            cells[start.row][column + 1] = cells[start.row][column]
        }
        for row in cells.indices { cells[row].remove(at: column) }
        alignments.remove(at: column)
        widths?.remove(at: column)
        (spans, style.fills) = WriterTableMerge.removing(at: column, isRow: false, spans: spans, fills: style.fills)
        style.formulas = style.formulasShifted(at: column, isRow: false, delta: -1)
    }

    /// One cell of the rectangle from `first` to `last`, grown so no merged cell sticks out: its text is theirs one
    /// after the other, its colour the first one's.
    mutating func merge(from first: WriterCellPosition, to last: WriterCellPosition) throws {
        let area = WriterTableMerge.enclosingRectangle(first, last, spans: spans)
        guard area.bottom > area.top || area.right > area.left else {
            throw RPCError.invalidTarget("Zum Verbinden braucht es mehr als eine Zelle.")
        }
        spans = spans.filter { start, _ in !((area.top...area.bottom).contains(start.row) && (area.left...area.right).contains(start.column)) }
        let anchor = WriterCellPosition(row: area.top, column: area.left)
        spans[anchor] = WriterCellSpan(rows: area.bottom - area.top + 1, columns: area.right - area.left + 1)
        var texts: [String] = []
        var fill: String?
        for row in area.top...area.bottom {
            for column in area.left...area.right {
                let place = WriterCellPosition(row: row, column: column)
                fill = fill ?? style.fills[place]
                if place != anchor { style.fills[place] = nil }
                if !cells[row][column].trimmingCharacters(in: .whitespaces).isEmpty { texts.append(cells[row][column]) }
                cells[row][column] = ""
            }
        }
        cells[anchor.row][anchor.column] = texts.joined(separator: " ")
        style.fills[anchor] = fill
    }

    /// The merged cell at this place becomes single cells again; its text stays in the first.
    mutating func split(at place: WriterCellPosition) throws {
        let cell = WriterTableMerge.cell(at: place, in: spans)
        guard !cell.span.isSingle else { throw RPCError.invalidTarget("Diese Zelle ist nicht verbunden.") }
        spans[cell.start] = nil
    }

    /// Text typed into a cell: a cell of a merged one goes to its first place, a formula's result is gone, and text
    /// that starts with `=` is a formula, as when typing in the editor.
    mutating func setCell(_ place: WriterCellPosition, markdown: String) {
        let start = WriterTableMerge.cell(at: place, in: spans).start
        cells[start.row][start.column] = markdown
        style.formulas[start] = nil
    }

    mutating func setFormula(_ formula: String?, at place: WriterCellPosition) {
        let start = WriterTableMerge.cell(at: place, in: spans).start
        let normalized = formula.map(WriterTableCalc.normalized) ?? ""
        style.formulas[start] = normalized.isEmpty ? nil : normalized
    }

    /// The formulas' results as the cells' text.
    mutating func recalculate() {
        let results = WriterTableCalc.evaluate(cells: plainCells, formulas: style.formulas)
        let covered = WriterTableMerge.covered(by: spans)
        for (place, result) in results where place.row < rows && place.column < columns && !covered.contains(place) {
            cells[place.row][place.column] = Self.cell(text: result)
        }
    }

    mutating func sort(column: Int, ascending: Bool) throws {
        let plan: (order: [Int], style: WriterTableStyle)?
        do {
            plan = try WriterTableArrange.sorted(texts: plainCells, style: style, spans: spans, column: column, ascending: ascending)
        } catch let problem as WriterTableArrange.SortProblem {
            throw RPCError.invalidTarget(problem.message)
        }
        guard let plan else { return }
        let before = cells
        for (offset, oldRow) in plan.order.enumerated() { cells[offset + 1] = before[oldRow] }
        style = plan.style
    }

    mutating func addSumRow() throws {
        guard let sums = WriterTableArrange.sumFormulas(texts: plainCells, style: style, columns: columns) else {
            throw RPCError.invalidTarget(WriterTableArrange.noNumbersMessage)
        }
        style.formulas.merge(sums) { $1 }
        var row = Array(repeating: "", count: columns)
        if style.formulas[WriterCellPosition(row: rows, column: 0)] == nil { row[0] = "**Summe**" }
        cells.append(row)
    }
}

/// Finding a table in a text. Only tables that are a block of their own count; one in a box or a column section is
/// inside that block.
@MainActor
enum WriterTableAddressing {
    struct Found {
        let block: Int
        let number: Int
        var table: MarkdownTable
    }

    static func tables(in markdown: String) -> [Found] {
        var found: [Found] = []
        for chunk in PowerText.chunks(of: markdown) where chunk.kind == .table {
            guard let table = MarkdownTable(markdown: chunk.markdown) else { continue }
            found.append(Found(block: chunk.id, number: found.count + 1, table: table))
        }
        return found
    }

    /// A table by its number in the text, its block id or its name (`tab-…`). Without a reference, the only one.
    static func find(_ reference: String?, in markdown: String) throws -> Found {
        let all = tables(in: markdown)
        guard let reference else {
            guard let first = all.first else { throw RPCError.notFound("In diesem Text steht keine Tabelle.") }
            guard all.count == 1 else {
                throw RPCError.ambiguous("Hier stehen \(all.count) Tabellen. Bitte table angeben: die Nummer ab 1 oder die Block-ID.",
                                         candidates: all.map { String($0.number) })
            }
            return first
        }
        if let number = Int(reference) {
            guard all.indices.contains(number - 1) else { throw RPCError.notFound("Tabelle \(number) gibt es nicht (\(all.count) Tabellen).") }
            return all[number - 1]
        }
        if let named = all.first(where: { $0.table.style.id == reference }) { return named }
        if reference.hasPrefix("tab-") { throw RPCError.notFound("Eine Tabelle \(reference) gibt es nicht.") }
        guard case .blocks(let range) = try WriterAddressing.resolve(WriterAddress(block: reference), in: markdown),
              let hit = all.first(where: { $0.block == range.lowerBound }) else {
            throw RPCError.invalidTarget("Block \(reference) ist keine Tabelle.")
        }
        return hit
    }
}
