import AppKit

/// What the table menu (toolbar and context menu) can do with the table at the caret.
enum WriterTableAction: Hashable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case deleteRow, deleteColumn, deleteTable
    case align(MarkdownBlock.Alignment)
}

/// Tables in the editor. Every cell is a paragraph whose attributes name its `WriterTable`, row and column
/// (see `WriterMarkdown`); AppKit's `NSTextTable` lays them out. Changes to the structure rebuild the whole
/// table in one undoable step; ordinary editing is checked so it never merges or splits cells.
extension WriterTextView {
    /// A table in the text: its whole range (all cells with their newlines) and each cell's text.
    struct TableModel {
        let table: WriterTable
        let range: NSRange
        /// Content ranges (without the newline) by row and column; NSNotFound for a missing cell.
        let cells: [[NSRange]]

        var rows: Int { cells.count }
    }

    // MARK: Finding tables

    /// The cell of the paragraph that contains `location`; nil outside tables and at the very end.
    func tableCell(at location: Int) -> WriterTableCell? {
        guard let storage = textStorage, location < storage.length else { return nil }
        return WriterMarkdown.paragraphs(of: storage, in: NSRange(location: location, length: 0)).first?.cell
    }

    var tableCellAtCaret: WriterTableCell? { tableCell(at: selectedRange().location) }

    func tableModel(at location: Int) -> TableModel? {
        guard let storage = textStorage, location < storage.length,
              let table = storage.attribute(.writerTable, at: location, effectiveRange: nil) as? WriterTable else { return nil }
        let range = tableRange(of: table, at: location)
        var cells: [Int: [Int: NSRange]] = [:]
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: range) {
            guard let cell = paragraph.cell, cell.table === table else { continue }
            cells[cell.row, default: [:]][cell.column] = paragraph.contentRange
        }
        let rows = (cells.keys.max() ?? 0) + 1
        let grid = (0..<rows).map { row in
            (0..<table.columns).map { cells[row]?[$0] ?? NSRange(location: NSNotFound, length: 0) }
        }
        return TableModel(table: table, range: range, cells: grid)
    }

    private func tableRange(of table: WriterTable, at location: Int) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: location, length: 0) }
        var range = NSRange()
        storage.attribute(.writerTable, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        return range
    }

    // MARK: Inserting

    /// Puts an empty table below the current paragraph and the caret into its first cell.
    func insertTable(rows: Int, columns: Int) {
        let table = WriterTable(columns: columns, alignments: [])
        let text = NSMutableAttributedString()
        for row in 0..<max(1, rows) {
            for column in 0..<table.columns {
                text.append(NSAttributedString(string: "\n", attributes: WriterTableCell(table: table, row: row, column: column).attributes))
            }
        }
        guard let start = insertBlock(text) else { return }
        setSelectedRange(NSRange(location: start, length: 0))
        resetTypingAttributes()
        onStateChange?()
    }

    // MARK: Moving between cells

    /// Tab and shift-tab: the next or previous cell, its text selected. Tab in the last cell adds a row.
    func moveToAdjacentCell(forward: Bool) {
        guard let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return }
        let columns = model.table.columns
        let index = cell.row * columns + cell.column + (forward ? 1 : -1)
        if index < 0 { return }
        if index >= model.rows * columns {
            performTableAction(.insertRowBelow)
            return
        }
        selectCell(row: index / columns, column: index % columns, of: model, selectingText: true)
    }

    /// Return: the cell below; in the last row the caret leaves the table.
    func moveToCellBelow() {
        guard let storage = textStorage, let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return }
        if cell.row + 1 < model.rows {
            selectCell(row: cell.row + 1, column: cell.column, of: model, selectingText: false)
            return
        }
        let end = NSMaxRange(model.range)
        // Below the table there must be a paragraph for text; a picture or another table doesn't count.
        if end < storage.length, [.table, .rule].contains(WriterStyler.block(in: storage, at: end)) || WriterStyler.block(in: storage, at: end).isEmbed {
            let empty = NSAttributedString(string: "\n", attributes: [.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0])
            performStructureEdit(in: NSRange(location: end, length: 0), with: empty)
        }
        setSelectedRange(NSRange(location: end, length: 0))
        typingAttributes = WriterStyler.typingAttributes(block: .paragraph, level: 0, semantic: [:], family: family, palette: palette)
        onStateChange?()
    }

    private func selectCell(row: Int, column: Int, of model: TableModel, selectingText: Bool) {
        guard row < model.rows, column < model.table.columns else { return }
        let content = model.cells[row][column]
        guard content.location != NSNotFound else { return }
        setSelectedRange(selectingText ? content : NSRange(location: NSMaxRange(content), length: 0))
        scrollRangeToVisible(content)
    }

    // MARK: Changing the structure

    func performTableAction(_ action: WriterTableAction) {
        guard let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location), let storage = textStorage else { return }
        var contents = model.cells.map { row in
            row.map { $0.location == NSNotFound ? NSAttributedString() : storage.attributedSubstring(from: $0) }
        }
        var alignments = model.table.alignments
        var caret = (row: cell.row, column: cell.column)
        let empty = NSAttributedString()

        switch action {
        case .insertRowAbove, .insertRowBelow:
            let row = action == .insertRowAbove ? cell.row : cell.row + 1
            contents.insert(Array(repeating: empty, count: model.table.columns), at: row)
            caret = (row, action == .insertRowBelow && cell.column == model.table.columns - 1 && cell.row == model.rows - 1 ? 0 : cell.column)
        case .insertColumnLeft, .insertColumnRight:
            let column = action == .insertColumnLeft ? cell.column : cell.column + 1
            for row in contents.indices { contents[row].insert(empty, at: column) }
            alignments.insert(.leading, at: column)
            caret = (cell.row, column)
        case .deleteRow:
            guard model.rows > 1 else { return deleteTable(model) }
            contents.remove(at: cell.row)
            caret = (min(cell.row, contents.count - 1), cell.column)
        case .deleteColumn:
            guard model.table.columns > 1 else { return deleteTable(model) }
            for row in contents.indices { contents[row].remove(at: cell.column) }
            alignments.remove(at: cell.column)
            caret = (cell.row, min(cell.column, alignments.count - 1))
        case .deleteTable:
            return deleteTable(model)
        case .align(let alignment):
            guard alignments[cell.column] != alignment else { return }
            alignments[cell.column] = alignment
        }
        rebuild(model, contents: contents, alignments: alignments, caret: caret)
    }

    /// Replaces the table with a new one of these cells, in one undoable step, and puts the caret at the end
    /// of the text of the cell `caret`.
    private func rebuild(_ model: TableModel, contents: [[NSAttributedString]], alignments: [MarkdownBlock.Alignment], caret: (row: Int, column: Int)) {
        let table = WriterTable(columns: alignments.count, alignments: alignments)
        let text = NSMutableAttributedString()
        var caretLocation = model.range.location
        for (row, cells) in contents.enumerated() {
            for (column, content) in cells.enumerated() {
                let start = text.length
                text.append(content)
                text.append(NSAttributedString(string: "\n"))
                text.addAttributes(WriterTableCell(table: table, row: row, column: column).attributes, range: NSRange(location: start, length: text.length - start))
                if row == caret.row, column == caret.column { caretLocation = model.range.location + start + content.length }
            }
        }
        performStructureEdit(in: model.range, with: text)
        setSelectedRange(NSRange(location: min(caretLocation, textStorage?.length ?? 0), length: 0))
        resetTypingAttributes()
        onStateChange?()
    }

    private func deleteTable(_ model: TableModel) {
        performStructureEdit(in: model.range, with: NSAttributedString())
        setSelectedRange(NSRange(location: min(model.range.location, textStorage?.length ?? 0), length: 0))
        resetTypingAttributes()
        onStateChange?()
    }

    /// The table at the caret for the toolbar.
    var tableState: State.TableState? {
        guard let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return nil }
        return State.TableState(row: cell.row, column: cell.column, rows: model.rows, columns: model.table.columns,
                                alignment: model.table.alignment(of: cell.column))
    }

    /// An edit of the table's structure (or of text around it) that is already safe: undoable, one step, and
    /// not checked by `shouldChangeText`.
    func performStructureEdit(in range: NSRange, with text: NSAttributedString) {
        guard let storage = textStorage else { return }
        isEditingStructure = true
        defer { isEditingStructure = false }
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: text.string) {
            storage.replaceCharacters(in: range, with: text)
            didChangeText()
        }
        breakUndoCoalescing()
    }

    // MARK: Keeping tables whole

    /// Every edit passes here: one that would merge, split or tear apart cells of a table that stays is done
    /// in a safe way instead (cells keep their places, only their text changes).
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard !isEditingStructure, let replacementStrings, replacementStrings.count == affectedRanges.count else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let edits = zip(affectedRanges.map(\.rangeValue), replacementStrings)
        guard edits.contains(where: { editBreaksTable($0.0, $0.1) }) else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            performTableSafeEdit(range, replacement)
        }
        return false
    }

    private static func isParagraphBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }

    /// Tables that lie completely inside `range`; they may go away as a whole.
    private func tablesCovered(by range: NSRange) -> Set<ObjectIdentifier> {
        guard let storage = textStorage, range.length > 0 else { return [] }
        var covered = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.writerTable, in: range) { value, run, _ in
            guard let table = value as? WriterTable else { return }
            let whole = tableRange(of: table, at: run.location)
            if NSIntersectionRange(whole, range) == whole { covered.insert(ObjectIdentifier(table)) }
        }
        return covered
    }

    private func editBreaksTable(_ range: NSRange, _ replacement: String) -> Bool {
        guard let storage = textStorage, storage.length > 0, NSMaxRange(range) <= storage.length else { return false }
        let covered = tablesCovered(by: range)
        func stays(_ cell: WriterTableCell?) -> Bool { cell.map { !covered.contains(ObjectIdentifier($0.table)) } ?? false }

        let replacementBreaks = replacement.utf16.contains(where: Self.isParagraphBreak)
        // A new paragraph inside a cell would be a cell too many.
        if replacementBreaks, stays(tableCell(at: range.location)) { return true }

        let string = storage.string as NSString
        for index in range.location..<NSMaxRange(range) where Self.isParagraphBreak(string.character(at: index)) {
            // The newline of a cell.
            if let table = storage.attribute(.writerTable, at: index, effectiveRange: nil) as? WriterTable,
               !covered.contains(ObjectIdentifier(table)) { return true }
            // The newline in front of a table: without it the paragraph above would run into the first cell.
            if index + 1 < storage.length, stays(tableCell(at: index + 1)) {
                let suppliesBreak = NSMaxRange(range) == index + 1 && replacement.utf16.last.map(Self.isParagraphBreak) == true
                if !suppliesBreak { return true }
            }
        }
        return false
    }

    /// Removes the text in `range` but keeps the newlines that hold tables together, and puts `replacement`
    /// at the start (on one line when that is inside a cell).
    private func performTableSafeEdit(_ range: NSRange, _ replacement: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let string = storage.string as NSString
        let covered = tablesCovered(by: range)

        let kept = NSMutableAttributedString()
        for index in range.location..<NSMaxRange(range) where Self.isParagraphBreak(string.character(at: index)) {
            let ownTable = storage.attribute(.writerTable, at: index, effectiveRange: nil) as? WriterTable
            let nextTable = index + 1 < storage.length ? tableCell(at: index + 1)?.table : nil
            let keeps = ownTable.map { !covered.contains(ObjectIdentifier($0)) }
                ?? nextTable.map { !covered.contains(ObjectIdentifier($0)) }
                ?? false
            if keeps { kept.append(storage.attributedSubstring(from: NSRange(location: index, length: 1))) }
        }

        var text = replacement
        var attributes = typingAttributes
        if let cell = tableCell(at: range.location), !covered.contains(ObjectIdentifier(cell.table)) {
            text = text.replacingOccurrences(of: "\r\n", with: " ")
                .components(separatedBy: CharacterSet(charactersIn: "\n\r\u{2029}")).joined(separator: " ")
            attributes.merge(cell.attributes) { $1 }
        } else {
            for key in WriterMarkdown.tableKeys { attributes.removeValue(forKey: key) }
            if attributes[.writerBlock] as? String == WriterBlock.table.rawValue { attributes[.writerBlock] = WriterBlock.paragraph.rawValue }
        }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        result.append(kept)
        let caret = range.location + (text as NSString).length

        if result.string != string.substring(with: range) {
            performStructureEdit(in: range, with: result)
        }
        // The text view may still set its own selection after `shouldChangeText` said no; ours comes last.
        setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        DispatchQueue.main.async { [weak self] in
            guard let self, let length = self.textStorage?.length else { return }
            self.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        }
        onStateChange?()
    }

    // MARK: Menu

    /// The table's entries for the context menu.
    func tableMenu() -> NSMenuItem? {
        guard let state = tableState else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: WriterTableAction, enabled: Bool = true, on: Bool = false) {
            let entry = ClosureMenuItem(title: title) { [weak self] in self?.performTableAction(action) }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            entry.isEnabled = enabled
            entry.state = on ? .on : .off
            menu.addItem(entry)
        }
        item("Zeile darüber einfügen", "arrow.up.to.line", .insertRowAbove)
        item("Zeile darunter einfügen", "arrow.down.to.line", .insertRowBelow)
        item("Spalte links einfügen", "arrow.left.to.line", .insertColumnLeft)
        item("Spalte rechts einfügen", "arrow.right.to.line", .insertColumnRight)
        menu.addItem(.separator())
        item("Spalte linksbündig", "text.alignleft", .align(.leading), on: state.alignment == .leading)
        item("Spalte zentriert", "text.aligncenter", .align(.center), on: state.alignment == .center)
        item("Spalte rechtsbündig", "text.alignright", .align(.trailing), on: state.alignment == .trailing)
        menu.addItem(.separator())
        item("Zeile löschen", "minus.square", .deleteRow)
        item("Spalte löschen", "minus.rectangle.portrait", .deleteColumn)
        item("Tabelle löschen", "trash", .deleteTable)
        let entry = NSMenuItem(title: "Tabelle", action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        entry.submenu = menu
        return entry
    }
}

/// A menu entry that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
