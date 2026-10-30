import AppKit
import SwiftUI

/// Tables that calculate: formulas in cells (`WriterTableCalc`), sorting by a column and a row of sums. The results
/// are the cells' text, so they are written into the cells right after every edit of the table (in the same undo
/// step); while undoing nothing is calculated, the old results come back with the old text.
extension WriterTextView {
    // MARK: Calculating

    /// The restyler reports every edit; the tables there are calculated once the edit is done.
    func noteEdit(in range: NSRange) {
        guard !isRecalculating else { return }
        pendingCalcRange = pendingCalcRange.map { NSUnionRange($0, range) } ?? range
        if let cell = lastTableCell, let storage = textStorage, storage.length > 0,
           let edited = tableCell(at: min(range.location, storage.length - 1)),
           edited.table === cell.table, edited.row == cell.row, edited.column == cell.column {
            lastTableCellEdited = true
        }
    }

    /// Calculates the tables with formulas that the last edit touched, and tells charts made from tables.
    func recalculateTablesIfNeeded() {
        guard let range = pendingCalcRange, let storage = textStorage else { return }
        pendingCalcRange = nil
        guard !isRecalculating, storage.length > 0 else { return }
        let scan = NSIntersectionRange(NSRange(location: max(0, range.location - 1), length: range.length + 2),
                                       NSRange(location: 0, length: storage.length))
        var tables: [WriterTable] = []
        storage.enumerateAttribute(.writerTable, in: scan) { value, _, _ in
            if let table = value as? WriterTable, !tables.contains(where: { $0 === table }) { tables.append(table) }
        }
        guard !tables.isEmpty else { return }
        let undoing = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        for table in tables {
            if !undoing, !table.style.formulas.isEmpty { recalculate(table) }
            if let id = table.style.id { tableChanged(id) }
        }
    }

    /// Where a table is now (nil when it is no longer in the text).
    func location(of table: WriterTable) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.writerTable, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? WriterTable) === table {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    /// The cells' texts by row and column (empty for places merged cells cover).
    func cellTexts(of model: TableModel) -> [[String]] {
        let string = (textStorage?.string ?? "") as NSString
        return model.cells.map { row in
            row.map { range in
                range.location == NSNotFound ? "" : string.substring(with: range)
                    .replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ")
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
    }

    /// Writes the results of a table's formulas into their cells. The cell with the caret is left alone: the user may
    /// be typing over its result.
    func recalculate(_ table: WriterTable, includingCaretCell: Bool = false) {
        guard let storage = textStorage, let location = location(of: table), let model = tableModel(at: location) else { return }
        let results = WriterTableCalc.evaluate(cells: cellTexts(of: model), formulas: table.style.formulas)
        let caret = tableCellAtCaret
        var changes: [(range: NSRange, text: String)] = []
        let string = storage.string as NSString
        for (place, result) in results {
            guard place.row < model.rows, place.column < table.columns else { continue }
            let range = model.cells[place.row][place.column]
            guard range.location != NSNotFound else { continue }
            if !includingCaretCell, let caret, caret.table === table, caret.row == place.row, caret.column == place.column { continue }
            if string.substring(with: range) != result { changes.append((range, result)) }
        }
        guard !changes.isEmpty else { return }
        isRecalculating = true
        defer { isRecalculating = false }
        var selection = selectedRange()
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            var attributes = storage.attributes(at: change.range.location < storage.length ? change.range.location : max(0, change.range.location - 1),
                                                effectiveRange: nil)
            // The newline carries the cell; the text gets its place and no marks of its own.
            let cellAttributes = storage.attributes(at: NSMaxRange(change.range), effectiveRange: nil)
            attributes = cellAttributes.filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            performStructureEdit(in: change.range, with: NSAttributedString(string: change.text, attributes: attributes))
            let delta = (change.text as NSString).length - change.range.length
            if selection.location >= NSMaxRange(change.range) { selection.location += delta }
        }
        setSelectedRange(NSRange(location: min(selection.location, storage.length), length: min(selection.length, max(0, storage.length - selection.location))))
        needsDisplay = true
    }

    // MARK: Formulas typed into a cell

    /// The caret moved: a cell it left may now hold a formula ("=…" typed) or have lost one (its result typed over).
    func tableCaretMoved() {
        let current = tableCellAtCaret
        guard let previous = lastTableCell else {
            lastTableCell = current
            lastTableCellEdited = false
            return
        }
        if let current, current.table === previous.table, current.row == previous.row, current.column == previous.column { return }
        let edited = lastTableCellEdited
        lastTableCell = current
        lastTableCellEdited = false
        guard edited else { return }
        DispatchQueue.main.async { [weak self] in self?.commitCell(previous) }
    }

    private func commitCell(_ cell: WriterTableCell) {
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let location = location(of: cell.table), let model = tableModel(at: location),
              cell.row < model.rows, cell.column < cell.table.columns else { return }
        let range = model.cells[cell.row][cell.column]
        guard range.location != NSNotFound else { return }
        let text = ((textStorage?.string ?? "") as NSString).substring(with: range)
        let place = WriterCellPosition(row: cell.row, column: cell.column)
        if WriterTableCalc.isFormulaText(text) {
            setFormula(text, at: place, in: model)
        } else if cell.table.style.formulas[place] != nil {
            // The result was typed over: the cell keeps what was typed.
            let result = WriterTableCalc.evaluate(cells: cellTexts(of: model), formulas: cell.table.style.formulas)[place]
            if result != text { setFormula(nil, at: place, in: model) }
        }
    }

    /// Gives a cell a formula (nil or empty: none; the cell keeps its value) as one undoable step.
    func setFormula(_ formula: String?, at place: WriterCellPosition, in model: TableModel) {
        var style = model.table.style
        let normalized = formula.map(WriterTableCalc.normalized) ?? ""
        style.formulas[place] = normalized.isEmpty ? nil : normalized
        guard style != model.table.style else {
            recalculate(model.table, includingCaretCell: true)
            return
        }
        let selection = selectedRange()
        undoManager?.beginUndoGrouping()
        replaceTable(model, with: model.table.with(style: style))
        if let location = location(ofTableAt: model.range.location), let table = tableModel(at: location)?.table {
            recalculate(table, includingCaretCell: true)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(normalized.isEmpty ? "Formel entfernen" : "Formel")
        setSelectedRange(NSRange(location: min(selection.location, textStorage?.length ?? 0), length: 0))
        onStateChange?()
    }

    private func location(ofTableAt location: Int) -> Int? {
        guard let storage = textStorage, location < storage.length, storage.attribute(.writerTable, at: location, effectiveRange: nil) != nil else { return nil }
        return location
    }

    /// The formula bar: a formula for the cell with the caret.
    func setFormulaAtCaret(_ formula: String?) {
        guard let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return }
        setFormula(formula, at: WriterCellPosition(row: cell.row, column: cell.column), in: model)
    }

    /// A formula for the caret's cell that sums up (or averages, …) the numbers above it in its column.
    func formulaOverColumn(_ function: String) -> String? {
        guard let cell = tableCellAtCaret, cell.row >= 2 else { return nil }
        let column = WriterTableCalc.columnName(cell.column)
        return "\(function)(\(column)2:\(column)\(cell.row))"
    }

    // MARK: Sorting

    /// Sorts the rows below the header by a column. Rows at the end with sums of other rows stay where they are, and
    /// a row's formulas move with it.
    func sortTable(_ model: TableModel, column: Int, ascending: Bool, contents: [[NSAttributedString]]) {
        let table = model.table
        let texts = cellTexts(of: model)
        var last = model.rows - 1
        // Rows at the end that calculate over others (a row of sums) stay at the end.
        while last > 1, table.style.formulas.contains(where: { place, formula in
            place.row == last && WriterTableCalc.referencedRows(formula).contains(where: { $0 != last })
        }) { last -= 1 }
        guard last >= 2 else {
            onNotice?("Zum Sortieren braucht die Tabelle unter der Kopfzeile mindestens zwei Zeilen.")
            return
        }
        if table.spans.contains(where: { start, span in start.row + span.rows - 1 >= 1 && start.row <= last }) {
            onNotice?("Tabellen mit verbundenen Zellen lassen sich nicht sortieren – erst die Verbindung aufheben.")
            return
        }
        let rows = Array(1...last)
        let order = rows.enumerated().sorted { a, b in
            let left = texts[a.element][column], right = texts[b.element][column]
            let leftEmpty = left.trimmingCharacters(in: .whitespaces).isEmpty, rightEmpty = right.trimmingCharacters(in: .whitespaces).isEmpty
            // Empty cells go last both ways; equal ones keep their order.
            if leftEmpty != rightEmpty { return !leftEmpty }
            guard let isAscending = WriterTableCalc.ascending(left, right) else { return a.offset < b.offset }
            return ascending ? isAscending : !isAscending
        }.map(\.element)
        guard order != rows else { return }
        var sorted = contents
        var style = table.style
        var fills = style.fills.filter { $0.key.row == 0 || $0.key.row > last }
        var formulas = style.formulas.filter { $0.key.row == 0 || $0.key.row > last }
        for (offset, oldRow) in order.enumerated() {
            let newRow = offset + 1
            sorted[newRow] = contents[oldRow]
            for (place, color) in style.fills where place.row == oldRow { fills[WriterCellPosition(row: newRow, column: place.column)] = color }
            for (place, formula) in style.formulas where place.row == oldRow {
                formulas[WriterCellPosition(row: newRow, column: place.column)] = WriterTableCalc.movingRow(formula, from: oldRow, to: newRow)
            }
        }
        style.fills = fills
        style.formulas = formulas
        let caretRow = tableCellAtCaret.map { cell in order.firstIndex(of: cell.row).map { $0 + 1 } ?? cell.row } ?? 0
        rebuild(model, contents: sorted, alignments: table.alignments, widths: table.widths, spans: table.spans, style: style,
                caret: (caretRow, column))
        undoManager?.setActionName("Sortieren")
    }

    // MARK: Sums

    /// A row at the end with the sums of every column with numbers; the first column says "Summe" if it holds text.
    func addSumRow(_ model: TableModel, contents: [[NSAttributedString]]) {
        let table = model.table
        let texts = cellTexts(of: model)
        guard model.rows >= 2 else { return }
        let bodyRows = 1..<model.rows
        var style = table.style
        let newRow = model.rows
        var row = Array(repeating: NSAttributedString(), count: table.columns)
        var anySum = false
        for column in 0..<table.columns {
            let numbers = bodyRows.filter { WriterTableCalc.number(in: texts[$0][column]) != nil || style.formulas[WriterCellPosition(row: $0, column: column)] != nil }
            guard !numbers.isEmpty else { continue }
            let name = WriterTableCalc.columnName(column)
            style.formulas[WriterCellPosition(row: newRow, column: column)] = "SUMME(\(name)2:\(name)\(model.rows))"
            anySum = true
        }
        guard anySum else {
            onNotice?("In der Tabelle stehen keine Zahlen zum Summieren.")
            return
        }
        if style.formulas[WriterCellPosition(row: newRow, column: 0)] == nil {
            row[0] = NSAttributedString(string: "Summe", attributes: [.writerBold: true])
        }
        rebuild(model, contents: contents + [row], alignments: table.alignments, widths: table.widths, spans: table.spans, style: style,
                caret: (newRow, 0))
        undoManager?.setActionName("Summenzeile")
    }

    // MARK: Showing formulas

    /// A small corner in each cell that calculates, so formulas can be told from typed numbers.
    func drawFormulaMarks(in characters: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let range = NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.writerTable, in: range) { value, run, _ in
            guard let table = value as? WriterTable, !table.style.formulas.isEmpty else { return }
            for paragraph in WriterMarkdown.paragraphs(of: storage, in: run) {
                guard let cell = paragraph.cell, cell.table === table,
                      table.style.formulas[WriterCellPosition(row: cell.row, column: cell.column)] != nil,
                      let style = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle,
                      let block = style.textBlocks.last else { continue }
                let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph.range, actualCharacterRange: nil)
                let bounds = layoutManager.boundsRect(for: block, glyphRange: glyphs)
                guard !bounds.isEmpty else { continue }
                let corner = NSBezierPath()
                let right = origin.x + bounds.maxX - 1, top = origin.y + bounds.minY + 1
                corner.move(to: NSPoint(x: right - 7, y: top))
                corner.line(to: NSPoint(x: right, y: top))
                corner.line(to: NSPoint(x: right, y: top + 7))
                corner.close()
                palette.accent.withAlphaComponent(0.7).setFill()
                corner.fill()
            }
        }
    }

    // MARK: The bar over the table

    /// Shows the formula bar over the table with the caret, or hides it.
    func updateTableBar() {
        guard window != nil, let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location),
              let layoutManager, let container = textContainer, textStorage?.editedMask.isEmpty != false else {
            tableBarHost?.isHidden = true
            onTableBar?(nil)
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: model.range, actualCharacterRange: nil)
        let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let place = WriterCellPosition(row: cell.row, column: cell.column)
        let bar = WriterTableBar(
            cellName: WriterTableCalc.cellName(row: cell.row, column: cell.column),
            formula: model.table.style.formulas[place],
            canSumAbove: cell.row >= 2,
            onFormula: { [weak self] formula in
                self?.window?.makeFirstResponder(self)
                self?.setFormulaAtCaret(formula)
            },
            onQuickFormula: { [weak self] function in
                guard let self, let formula = self.formulaOverColumn(function) else { return }
                self.window?.makeFirstResponder(self)
                self.setFormulaAtCaret(formula)
            },
            onSort: { [weak self] in self?.performTableAction(.sort(ascending: $0)) },
            onSumRow: { [weak self] in self?.performTableAction(.sumRow) },
            onChart: { [weak self] in self?.makeChartFromTable() }
        )
        // On a slide (magnified, maybe a small text field) the bar stands outside the canvas.
        if slideLayout != nil, let onTableBar {
            onTableBar(bar)
            return
        }
        let host: NSHostingView<WriterTableBarHost>
        if let existing = tableBarHost as? NSHostingView<WriterTableBarHost> {
            host = existing
            host.rootView = WriterTableBarHost(bar: bar)
        } else {
            host = NSHostingView(rootView: WriterTableBarHost(bar: bar))
            tableBarHost = host
        }
        if host.superview !== self { addSubview(host) }
        host.isHidden = false
        let size = host.fittingSize
        // Above the table at its right edge; below it when the top is out of sight.
        var y = frame.minY - size.height - 4
        if y < visibleRect.minY + 4 { y = frame.maxY + 2 }
        let x = min(max(frame.maxX - size.width, 8), bounds.width - size.width - 8)
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The bar for one cell: another cell or formula starts it afresh, so its field never shows an old formula.
struct WriterTableBarHost: View {
    let bar: WriterTableBar

    var body: some View {
        bar.id(bar.cellName + "|" + (bar.formula ?? ""))
    }
}

/// The bar over a table with the caret: the cell's name and formula, quick formulas, sorting, a row of sums and a chart.
struct WriterTableBar: View {
    let cellName: String
    let formula: String?
    let canSumAbove: Bool
    let onFormula: (String?) -> Void
    let onQuickFormula: (String) -> Void
    let onSort: (Bool) -> Void
    let onSumRow: () -> Void
    let onChart: () -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(cellName)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 26)
                .padding(.leading, 6)
            Text("fx")
                .font(.system(size: 11.5, weight: .semibold, design: .serif).italic())
                .foregroundStyle(formula == nil ? Theme.textTertiary : Theme.accent)
            TextField("Formel: =…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 170)
                .focused($focused)
                .onSubmit {
                    let value = text.trimmingCharacters(in: .whitespaces)
                    onFormula(value.isEmpty || value == "=" ? nil : value)
                    focused = false
                }
                .help("Formel der Zelle: = und dann z. B. SUMME(B2:B4), MITTELWERT, MIN, MAX, ANZAHL, RUNDEN, WENN; B2*C2; Argumente mit ; trennen. Leer und ↩ entfernt die Formel. Auch direkt in die Zelle tippen: =…")
            Menu {
                Section("Über der Zelle") {
                    Button("Summe") { onQuickFormula("SUMME") }
                    Button("Mittelwert") { onQuickFormula("MITTELWERT") }
                    Button("Minimum") { onQuickFormula("MIN") }
                    Button("Maximum") { onQuickFormula("MAX") }
                    Button("Anzahl") { onQuickFormula("ANZAHL") }
                }
                .disabled(!canSumAbove)
                Section("Funktionen") {
                    ForEach(WriterTableCalc.functionHelp, id: \.name) { entry in
                        Button("\(entry.example)  – \(entry.detail)") { text = entry.example; focused = true }
                    }
                }
                Divider()
                Button("Summenzeile anfügen", systemImage: "sum") { onSumRow() }
            } label: {
                Image(systemName: "sum")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rechnen: Summe, Mittelwert … der Zahlen darüber, Funktionen, Summenzeile")
            divider
            icon("arrow.up", help: "Nach dieser Spalte sortieren – aufsteigend (A–Z, 1–9)") { onSort(true) }
            icon("arrow.down", help: "Nach dieser Spalte sortieren – absteigend (Z–A, 9–1)") { onSort(false) }
            divider
            icon("chart.bar.xaxis", help: "Diagramm aus der Tabelle – folgt ihr, wenn sich die Zahlen ändern", action: onChart)
        }
        .padding(3)
        .background(Capsule().fill(Color(hex: 0x1C1C20).opacity(0.97)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onAppear { text = formula.map { "=" + $0 } ?? "" }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 2)
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}
