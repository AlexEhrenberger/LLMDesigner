import AppKit

/// What the table menu (toolbar and context menu) can do with the table at the caret.
enum WriterTableAction: Hashable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case deleteRow, deleteColumn, deleteTable
    case align(MarkdownBlock.Alignment)
    /// Every column as wide as the others again (their widths were dragged).
    case equalizeColumns
    /// One cell of the selected ones (their texts one after the other), or of the cell and the one beside or below it.
    case mergeCells, mergeRight, mergeDown
    /// The merged cell at the caret becomes single cells again.
    case splitCell
    /// The background of the selected cells; nil takes it away.
    case fill(String?)
    /// The table's lines in print, and their weight (nil: thin).
    case lines(WriterTableLines)
    case lineWidth(Double?)
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
        // Merged cells may reach below the last row that has a paragraph of its own.
        let rows = max((cells.keys.max() ?? 0) + 1, table.spans.map { $0.key.row + $0.value.rows }.max() ?? 0)
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
        let table = WriterTable(columns: columns, alignments: [], widths: nil, rows: max(1, rows))
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
        var index = cell.row * columns + cell.column
        // Places that a merged cell covers are passed over.
        repeat {
            index += forward ? 1 : -1
            if index < 0 { return }
            if index >= model.rows * columns {
                performTableAction(.insertRowBelow)
                return
            }
        } while model.cells[index / columns][index % columns].location == NSNotFound
        selectCell(row: index / columns, column: index % columns, of: model, selectingText: true)
    }

    /// Return: the cell below; in the last row the caret leaves the table.
    func moveToCellBelow() {
        guard let storage = textStorage, let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return }
        let below = cell.row + model.table.span(row: cell.row, column: cell.column).rows
        if below < model.rows {
            // Below lies a cell of its own or the merged cell that covers the place.
            let target = WriterTableMerge.cell(at: WriterCellPosition(row: below, column: cell.column), in: model.table.spans).start
            selectCell(row: target.row, column: target.column, of: model, selectingText: false)
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
        // The columns' shares; a new column gets an average one, the rest make room.
        var widths = model.table.widths
        var spans = model.table.spans
        var style = model.table.style
        var caret = (row: cell.row, column: cell.column)
        let span = model.table.span(row: cell.row, column: cell.column)
        let empty = NSAttributedString()

        switch action {
        case .insertRowAbove, .insertRowBelow:
            let row = action == .insertRowAbove ? cell.row : cell.row + span.rows
            contents.insert(Array(repeating: empty, count: model.table.columns), at: row)
            (spans, style.fills) = WriterTableMerge.inserting(at: row, isRow: true, spans: spans, fills: style.fills)
            caret = (row, action == .insertRowBelow && cell.column == model.table.columns - 1 && row == model.rows ? 0 : cell.column)
        case .insertColumnLeft, .insertColumnRight:
            let column = action == .insertColumnLeft ? cell.column : cell.column + span.columns
            for row in contents.indices { contents[row].insert(empty, at: column) }
            alignments.insert(.leading, at: column)
            widths?.insert(1 / CGFloat(model.table.columns), at: column)
            (spans, style.fills) = WriterTableMerge.inserting(at: column, isRow: false, spans: spans, fills: style.fills)
            caret = (cell.row, column)
        case .deleteRow:
            guard model.rows > 1 else { return deleteTable(model) }
            // A merged cell that begins in this row and goes on keeps its text in the row that moves up.
            for (start, merged) in spans where start.row == cell.row && merged.rows > 1 && start.row + 1 < contents.count {
                contents[start.row + 1][start.column] = contents[start.row][start.column]
            }
            contents.remove(at: cell.row)
            (spans, style.fills) = WriterTableMerge.removing(at: cell.row, isRow: true, spans: spans, fills: style.fills)
            caret = (min(cell.row, contents.count - 1), cell.column)
        case .deleteColumn:
            guard model.table.columns > 1 else { return deleteTable(model) }
            for (start, merged) in spans where start.column == cell.column && merged.columns > 1 && start.column + 1 < model.table.columns {
                contents[start.row][start.column + 1] = contents[start.row][start.column]
            }
            for row in contents.indices { contents[row].remove(at: cell.column) }
            alignments.remove(at: cell.column)
            widths?.remove(at: cell.column)
            (spans, style.fills) = WriterTableMerge.removing(at: cell.column, isRow: false, spans: spans, fills: style.fills)
            caret = (cell.row, min(cell.column, alignments.count - 1))
        case .deleteTable:
            return deleteTable(model)
        case .align(let alignment):
            guard alignments[cell.column] != alignment else { return }
            alignments[cell.column] = alignment
        case .equalizeColumns:
            guard widths != nil else { return }
            return setColumnWidths(nil, of: model)
        case .mergeCells, .mergeRight, .mergeDown:
            let first = WriterCellPosition(row: cell.row, column: cell.column)
            var last = WriterCellPosition(row: cell.row + span.rows - 1, column: cell.column + span.columns - 1)
            switch action {
            case .mergeRight:
                guard last.column + 1 < model.table.columns else { return }
                last.column += 1
            case .mergeDown:
                guard last.row + 1 < model.rows else { return }
                last.row += 1
            default:
                let selected = selectedCellPositions(in: model)
                guard selected.count > 1, let top = selected.min(), let bottom = selected.max() else { return }
                return merge(model, from: WriterCellPosition(row: top.row, column: selected.map(\.column).min() ?? top.column),
                             to: WriterCellPosition(row: bottom.row, column: selected.map(\.column).max() ?? bottom.column),
                             contents: contents, alignments: alignments, widths: widths, style: style)
            }
            return merge(model, from: first, to: last, contents: contents, alignments: alignments, widths: widths, style: style)
        case .splitCell:
            guard !span.isSingle else { return }
            spans[WriterCellPosition(row: cell.row, column: cell.column)] = nil
        case .fill(let color):
            let places = selectedCellPositions(in: model)
            let targets = places.isEmpty ? [WriterCellPosition(row: cell.row, column: cell.column)] : places
            for place in targets { style.fills[place] = color }
            return setTableStyle(style, of: model)
        case .lines(let lines):
            guard style.lines != lines else { return }
            style.lines = lines
            return setTableStyle(style, of: model)
        case .lineWidth(let width):
            guard style.lineWidth != width else { return }
            style.lineWidth = width
            return setTableStyle(style, of: model)
        }
        rebuild(model, contents: contents, alignments: alignments, widths: widths, spans: spans, style: style, caret: caret)
    }

    /// The places of the cells the selection touches (merged cells by their first place); empty without a selection.
    func selectedCellPositions(in model: TableModel) -> [WriterCellPosition] {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return [] }
        var places: [WriterCellPosition] = []
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: NSIntersectionRange(range, model.range)) {
            guard let cell = paragraph.cell, cell.table === model.table else { continue }
            places.append(WriterCellPosition(row: cell.row, column: cell.column))
        }
        return places
    }

    /// Merges the cells from `first` to `last` (grown so no merged cell sticks out) into one: its text is theirs one
    /// after the other, its colour the first one's.
    private func merge(_ model: TableModel, from first: WriterCellPosition, to last: WriterCellPosition, contents: [[NSAttributedString]],
                       alignments: [MarkdownBlock.Alignment], widths: [CGFloat]?, style: WriterTableStyle) {
        let area = WriterTableMerge.enclosingRectangle(first, last, spans: model.table.spans)
        guard area.bottom > area.top || area.right > area.left else { return }
        var contents = contents
        var style = style
        var spans = model.table.spans.filter { start, _ in
            !((area.top...area.bottom).contains(start.row) && (area.left...area.right).contains(start.column))
        }
        let anchor = WriterCellPosition(row: area.top, column: area.left)
        spans[anchor] = WriterCellSpan(rows: area.bottom - area.top + 1, columns: area.right - area.left + 1)
        let joined = NSMutableAttributedString()
        var fill: String?
        for row in area.top...area.bottom {
            for column in area.left...area.right {
                let place = WriterCellPosition(row: row, column: column)
                fill = fill ?? style.fills[place]
                if place != anchor { style.fills[place] = nil }
                let text = contents[row][column]
                guard text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }
                if joined.length > 0 { joined.append(NSAttributedString(string: " ", attributes: text.attributes(at: 0, effectiveRange: nil))) }
                joined.append(text)
                contents[row][column] = NSAttributedString()
            }
        }
        contents[anchor.row][anchor.column] = joined
        style.fills[anchor] = fill
        rebuild(model, contents: contents, alignments: alignments, widths: widths, spans: spans, style: style, caret: (anchor.row, anchor.column))
    }

    /// Gives the table another look in one undoable step; the text and the caret stay.
    func setTableStyle(_ style: WriterTableStyle, of model: TableModel) {
        replaceTable(model, with: model.table.with(style: style))
    }

    /// Replaces the cells of a table with these, in one undoable step, and puts the caret at the end of the text of
    /// the cell `caret`. Places that merged cells cover get no paragraph.
    private func rebuild(_ model: TableModel, contents: [[NSAttributedString]], alignments: [MarkdownBlock.Alignment], widths: [CGFloat]?,
                         spans: [WriterCellPosition: WriterCellSpan], style: WriterTableStyle, caret: (row: Int, column: Int)) {
        let table = WriterTable(columns: alignments.count, alignments: alignments, widths: widths, spans: spans, style: style, rows: contents.count)
        let text = NSMutableAttributedString()
        var caretLocation = model.range.location
        for (row, cells) in contents.enumerated() {
            for (column, content) in cells.enumerated() where !table.isCovered(row: row, column: column) {
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
        let span = model.table.span(row: cell.row, column: cell.column)
        let style = model.table.style
        return State.TableState(row: cell.row, column: cell.column, rows: model.rows, columns: model.table.columns,
                                alignment: model.table.alignment(of: cell.column), hasOwnWidths: model.table.widths != nil,
                                selectedCells: selectedCellPositions(in: model).count, isMerged: !span.isSingle,
                                canMergeRight: cell.column + span.columns < model.table.columns, canMergeDown: cell.row + span.rows < model.rows,
                                fill: style.fills[WriterCellPosition(row: cell.row, column: cell.column)], lines: style.lines, lineWidth: style.lineWidth)
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

    // MARK: Column widths

    /// A border between two columns: the table, the column on its left and every column's edges in the view (the
    /// left edge of each column, then the table's right edge), with the width of the text of all cells of a row.
    struct ColumnBorder {
        let model: TableModel
        let column: Int
        let edges: [CGFloat]
        let textWidth: CGFloat
    }

    /// The border between two columns at this point of the view (within a few points).
    func columnBorder(at point: NSPoint) -> ColumnBorder? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length, let model = tableModel(at: character), model.table.columns > 1,
              // The columns' edges come from a row of single cells; merged ones reach over them.
              let first = (0..<model.rows).lazy.compactMap({ self.cellBounds(model, row: $0) }).first else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: model.range, actualCharacterRange: nil)
        let whole = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        guard inContainer.y >= whole.minY - 2, inContainer.y <= whole.maxY + 2 else { return nil }
        let edges = first.map { $0.bounds.minX + origin.x } + [(first.last?.bounds.maxX ?? 0) + origin.x]
        let textWidth = first.map(\.content.width).reduce(0, +)
        for column in 0..<(model.table.columns - 1) where abs(point.x - edges[column + 1]) <= 4 {
            return ColumnBorder(model: model, column: column, edges: edges, textWidth: textWidth)
        }
        return nil
    }

    /// The boxes of a row's cells in the text container: the whole cell and its text.
    private func cellBounds(_ model: TableModel, row: Int) -> [(bounds: NSRect, content: NSRect)]? {
        guard let layoutManager, let storage = textStorage, row < model.rows else { return nil }
        var result: [(bounds: NSRect, content: NSRect)] = []
        for column in 0..<model.table.columns {
            let content = model.cells[row][column]
            guard content.location != NSNotFound, content.location < storage.length, model.table.span(row: row, column: column).columns == 1,
                  let style = storage.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.last as? NSTextTableBlock else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: content.location, length: min(content.length + 1, storage.length - content.location)),
                                                  actualCharacterRange: nil)
            result.append((layoutManager.boundsRect(for: block, glyphRange: glyphs), layoutManager.layoutRect(for: block, glyphRange: glyphs)))
        }
        return result
    }

    /// Drags the border: the two columns beside it share their width anew while the mouse moves (shown at once, not
    /// saved), and the result is one undoable step when the button comes up.
    func dragColumnBorder(_ border: ColumnBorder, from event: NSEvent) {
        guard let window, let storage = textStorage, border.textWidth > 0 else { return }
        let model = border.model
        let start = convert(event.locationInWindow, from: nil).x
        let shares = (0..<model.table.columns).map { model.table.width(of: $0) }
        let left = border.column, right = border.column + 1
        let pair = shares[left] + shares[right]
        var current = shares
        var moved = false

        func show(_ widths: [CGFloat]?, table: WriterTable? = nil) {
            let shown = table ?? model.table.with(widths: .some(widths))
            storage.beginEditing()
            storage.addAttribute(.writerTable, value: shown, range: model.range)
            storage.endEditing()
        }

        NSCursor.resizeLeftRight.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let delta = (convert(next.locationInWindow, from: nil).x - start) / border.textWidth
            let share = min(max(shares[left] + delta, WriterTable.minimumWidth), pair - WriterTable.minimumWidth)
            current[left] = share
            current[right] = pair - share
            moved = true
            show(current)
        }
        guard moved else { return }
        // Back to the table as it was, then the change itself, so undo returns to it.
        show(nil, table: model.table)
        setColumnWidths(current, of: model)
    }

    /// Gives the table these column shares (nil: equal columns) in one undoable step; the text and the caret stay.
    func setColumnWidths(_ widths: [CGFloat]?, of model: TableModel) {
        replaceTable(model, with: model.table.with(widths: .some(widths)))
    }

    /// Puts another `WriterTable` (same cells, other widths or look) on every cell in one undoable step.
    private func replaceTable(_ model: TableModel, with table: WriterTable) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        guard shouldChangeText(in: model.range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.writerTable, value: table, range: model.range)
        storage.endEditing()
        didChangeText()
        setSelectedRange(selection)
        resetTypingAttributes()
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
        item("Spalten gleich breit", "rectangle.split.3x1", .equalizeColumns, enabled: state.hasOwnWidths)
        menu.addItem(.separator())
        if state.selectedCells > 1 {
            item("Zellen verbinden", "rectangle.compress.vertical", .mergeCells)
        } else {
            item("Mit Zelle rechts verbinden", "arrow.right.to.line.compact", .mergeRight, enabled: state.canMergeRight)
            item("Mit Zelle darunter verbinden", "arrow.down.to.line.compact", .mergeDown, enabled: state.canMergeDown)
        }
        item("Verbindung aufheben", "rectangle.split.2x1", .splitCell, enabled: state.isMerged)
        let lines = NSMenu()
        for option in WriterTableLines.allCases {
            let entry = ClosureMenuItem(title: option.label) { [weak self] in self?.performTableAction(.lines(option)) }
            entry.state = state.lines == option ? .on : .off
            lines.addItem(entry)
        }
        let linesItem = NSMenuItem(title: "Linien im Druck", action: nil, keyEquivalent: "")
        linesItem.image = NSImage(systemSymbolName: "squareshape.split.3x3", accessibilityDescription: nil)
        linesItem.submenu = lines
        menu.addItem(linesItem)
        let fills = NSMenu()
        let none = ClosureMenuItem(title: "Keine") { [weak self] in self?.performTableAction(.fill(nil)) }
        none.state = state.fill == nil ? .on : .off
        fills.addItem(none)
        for entry in WriterColors.cellPalette {
            let item = ClosureMenuItem(title: entry.name) { [weak self] in self?.performTableAction(.fill(entry.printHex)) }
            item.image = Self.swatchImage(NSColor(hex: entry.print))
            item.state = state.fill == entry.printHex ? .on : .off
            fills.addItem(item)
        }
        let fillItem = NSMenuItem(title: "Zellfarbe", action: nil, keyEquivalent: "")
        fillItem.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)
        fillItem.submenu = fills
        menu.addItem(fillItem)
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

extension WriterTextView {
    /// A small round swatch for a menu entry.
    static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
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
