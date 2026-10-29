import Foundation

/// Which lines a table has in print, and in the editor as the strong ones (the others show faintly there, so the
/// cells stay visible while writing).
enum WriterTableLines: String, CaseIterable, Identifiable, Sendable {
    /// A line above the table, one below the header row and one below the table, as books set tables.
    case standard
    /// Every cell framed.
    case grid
    /// Lines between all rows, none between the columns.
    case horizontal
    /// A frame around the table and a line below the header row.
    case frame
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Buchsatz"
        case .grid: "Gitter"
        case .horizontal: "Waagrecht"
        case .frame: "Rahmen"
        case .none: "Ohne Linien"
        }
    }

    var detail: String {
        switch self {
        case .standard: "oben, unter dem Kopf, unten"
        case .grid: "alle Zellen umrandet"
        case .horizontal: "zwischen allen Zeilen"
        case .frame: "außen und unter dem Kopf"
        case .none: "keine Linien im Druck"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "tablecells"
        case .grid: "squareshape.split.3x3"
        case .horizontal: "line.3.horizontal"
        case .frame: "square"
        case .none: "square.dashed"
        }
    }

    /// Whether this edge of a cell is a line. `rows`, `columns`: the table's size; the cell spans
    /// `row..<rowEnd` and `column..<columnEnd`.
    func hasLine(_ edge: WriterCellEdge, row: Int, rowEnd: Int, column: Int, columnEnd: Int, rows: Int, columns: Int) -> Bool {
        switch self {
        case .none:
            return false
        case .grid:
            return true
        case .standard:
            switch edge {
            case .top: return row == 0
            case .bottom: return rowEnd == 1 || rowEnd == rows
            case .left, .right: return false
            }
        case .horizontal:
            return edge == .top || edge == .bottom
        case .frame:
            switch edge {
            case .top: return row == 0
            case .bottom: return rowEnd == 1 || rowEnd == rows
            case .left: return column == 0
            case .right: return columnEnd == columns
            }
        }
    }

    /// The heavier lines of a book's table: above and below it.
    func isHeavy(_ edge: WriterCellEdge, row: Int, rowEnd: Int, rows: Int) -> Bool {
        self == .standard && ((edge == .top && row == 0) || (edge == .bottom && rowEnd == rows && rows > 1))
    }
}

enum WriterCellEdge: CaseIterable {
    case top, bottom, left, right
}

/// A cell's place in a table.
struct WriterCellPosition: Hashable, Comparable, Sendable {
    var row: Int
    var column: Int

    static func < (lhs: WriterCellPosition, rhs: WriterCellPosition) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// How many rows and columns a merged cell covers.
struct WriterCellSpan: Hashable, Sendable {
    var rows: Int
    var columns: Int

    var isSingle: Bool { rows <= 1 && columns <= 1 }
}

/// What a table looks like besides its cells: its lines, their weight and the colours of cells. Markdown keeps it
/// in a Pandoc div around the table, `::: {.table lines=grid line-width=1 fill=0.1:FFF2CC,2.0:E2EFDA}` … `:::`; a
/// table with the standard look has none.
struct WriterTableStyle: Hashable, Sendable {
    var lines: WriterTableLines = .standard
    /// The lines' weight in points of print; nil: thin (0.5 pt, booktabs' heavier lines 0.8 pt).
    var lineWidth: Double?
    /// The background of cells (six hex digits as `WriterColors` keeps them), by the cell's place; a merged cell's
    /// colour sits at its first cell.
    var fills: [WriterCellPosition: String] = [:]

    static let lineWidths: [(value: Double?, label: String)] = [(nil, "Dünn"), (1, "Mittel"), (1.6, "Kräftig")]
    static let className = "table"

    init(lines: WriterTableLines = .standard, lineWidth: Double? = nil, fills: [WriterCellPosition: String] = [:]) {
        self.lines = lines
        self.lineWidth = lineWidth
        self.fills = fills
    }

    /// The style a div's attributes describe.
    init(attributes: [String: String]) {
        lines = attributes["lines"].flatMap(WriterTableLines.init(rawValue:)) ?? .standard
        lineWidth = attributes["line-width"].flatMap { Double($0.replacingOccurrences(of: "pt", with: "")) }.map { min(max($0, 0.2), 4) }
        for entry in (attributes["fill"] ?? "").split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let color = WriterColors.parse("#" + parts[1]) else { continue }
            let place = parts[0].split(separator: ".").compactMap { Int($0) }
            guard place.count == 2, place[0] >= 0, place[1] >= 0 else { continue }
            fills[WriterCellPosition(row: place[0], column: place[1])] = color
        }
    }

    var isStandard: Bool { lines == .standard && lineWidth == nil && fills.isEmpty }

    /// The div that holds the style; nil for the standard look.
    var divOpening: String? {
        guard !isStandard else { return nil }
        var parts = ["." + Self.className]
        if lines != .standard { parts.append("lines=" + lines.rawValue) }
        if let lineWidth { parts.append("line-width=" + WriterParagraphFormat.number(lineWidth)) }
        if !fills.isEmpty {
            parts.append("fill=" + fills.sorted { $0.key < $1.key }.map { "\($0.key.row).\($0.key.column):\($0.value)" }.joined(separator: ","))
        }
        return "::: {" + parts.joined(separator: " ") + "}"
    }

    /// The weight of a line in print, in points.
    func printWidth(heavy: Bool) -> Double {
        lineWidth ?? (heavy ? 0.8 : 0.5)
    }
}

/// Merged cells. Markdown's tables have none, so a cell that another one covers says so: `<<` merges it with the cell
/// on its left, `^^` with the cell above. Other programs show the marks; Writer Studio and its LaTeX read them back.
enum WriterTableMerge {
    static let leftMarker = "<<"
    static let upMarker = "^^"

    static func isMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed == leftMarker || trimmed == upMarker
    }

    /// The merged cells of a table from its cells' Markdown (header row first): each merged cell's first place and
    /// how far it reaches. A merged cell reaches right over the `<<` cells beside it and down over the `^^` cells
    /// below it.
    static func spans(in rows: [[String]], columns: Int) -> [WriterCellPosition: WriterCellSpan] {
        func text(_ row: Int, _ column: Int) -> String {
            row < rows.count && column < rows[row].count ? rows[row][column].trimmingCharacters(in: .whitespaces) : ""
        }
        var spans: [WriterCellPosition: WriterCellSpan] = [:]
        var covered = Set<WriterCellPosition>()
        for row in rows.indices {
            for column in 0..<columns where !covered.contains(WriterCellPosition(row: row, column: column)) && !isMarker(text(row, column)) {
                var width = 1
                while column + width < columns, text(row, column + width) == leftMarker,
                      !covered.contains(WriterCellPosition(row: row, column: column + width)) { width += 1 }
                var height = 1
                while row + height < rows.count, text(row + height, column) == upMarker { height += 1 }
                guard width > 1 || height > 1 else { continue }
                spans[WriterCellPosition(row: row, column: column)] = WriterCellSpan(rows: height, columns: width)
                for r in row..<(row + height) {
                    for c in column..<(column + width) where r != row || c != column { covered.insert(WriterCellPosition(row: r, column: c)) }
                }
            }
        }
        return spans
    }

    /// The places that merged cells cover (not their first places).
    static func covered(by spans: [WriterCellPosition: WriterCellSpan]) -> Set<WriterCellPosition> {
        var covered = Set<WriterCellPosition>()
        for (start, span) in spans {
            for row in start.row..<(start.row + span.rows) {
                for column in start.column..<(start.column + span.columns) where row != start.row || column != start.column {
                    covered.insert(WriterCellPosition(row: row, column: column))
                }
            }
        }
        return covered
    }

    /// What a covered place holds in Markdown: `<<` beside the merged cell's first column, `^^` below it.
    static func marker(for position: WriterCellPosition, in spans: [WriterCellPosition: WriterCellSpan]) -> String? {
        for (start, span) in spans where (start.row..<(start.row + span.rows)).contains(position.row)
            && (start.column..<(start.column + span.columns)).contains(position.column) && position != start {
            return position.column == start.column ? upMarker : leftMarker
        }
        return nil
    }

    /// The merged cell that contains this place: its first place and span (a single cell for an ordinary one).
    static func cell(at position: WriterCellPosition, in spans: [WriterCellPosition: WriterCellSpan]) -> (start: WriterCellPosition, span: WriterCellSpan) {
        for (start, span) in spans where (start.row..<(start.row + span.rows)).contains(position.row)
            && (start.column..<(start.column + span.columns)).contains(position.column) {
            return (start, span)
        }
        return (position, WriterCellSpan(rows: 1, columns: 1))
    }

    /// The rectangle from `first` to `last` grown until no merged cell sticks out of it.
    static func enclosingRectangle(_ first: WriterCellPosition, _ last: WriterCellPosition,
                                   spans: [WriterCellPosition: WriterCellSpan]) -> (top: Int, left: Int, bottom: Int, right: Int) {
        var top = min(first.row, last.row), bottom = max(first.row, last.row)
        var left = min(first.column, last.column), right = max(first.column, last.column)
        var grew = true
        while grew {
            grew = false
            for (start, span) in spans {
                let rowEnd = start.row + span.rows - 1, columnEnd = start.column + span.columns - 1
                let meets = start.row <= bottom && rowEnd >= top && start.column <= right && columnEnd >= left
                guard meets else { continue }
                if start.row < top { top = start.row; grew = true }
                if rowEnd > bottom { bottom = rowEnd; grew = true }
                if start.column < left { left = start.column; grew = true }
                if columnEnd > right { right = columnEnd; grew = true }
            }
        }
        return (top, left, bottom, right)
    }

    // MARK: Rows and columns that come and go

    /// The merged cells and colours after a new row or column at `index` (`isRow`): what lies behind it moves on, a
    /// merged cell it falls into grows.
    static func inserting(at index: Int, isRow: Bool, spans: [WriterCellPosition: WriterCellSpan],
                          fills: [WriterCellPosition: String]) -> ([WriterCellPosition: WriterCellSpan], [WriterCellPosition: String]) {
        var newSpans: [WriterCellPosition: WriterCellSpan] = [:]
        for (start, span) in spans {
            var start = start, span = span
            let position = isRow ? start.row : start.column
            let length = isRow ? span.rows : span.columns
            if position >= index {
                if isRow { start.row += 1 } else { start.column += 1 }
            } else if position + length > index {
                if isRow { span.rows += 1 } else { span.columns += 1 }
            }
            newSpans[start] = span
        }
        var newFills: [WriterCellPosition: String] = [:]
        for (place, color) in fills {
            var place = place
            if isRow, place.row >= index { place.row += 1 }
            if !isRow, place.column >= index { place.column += 1 }
            newFills[place] = color
        }
        return (newSpans, newFills)
    }

    /// The merged cells and colours after the row or column at `index` went: a merged cell that reached over it
    /// shrinks (one that started there now starts at what follows), what lay behind it moves back.
    static func removing(at index: Int, isRow: Bool, spans: [WriterCellPosition: WriterCellSpan],
                         fills: [WriterCellPosition: String]) -> ([WriterCellPosition: WriterCellSpan], [WriterCellPosition: String]) {
        var newSpans: [WriterCellPosition: WriterCellSpan] = [:]
        var keptFills = Set<WriterCellPosition>()
        for (start, span) in spans {
            var start = start, span = span
            let position = isRow ? start.row : start.column
            let length = isRow ? span.rows : span.columns
            if position > index {
                if isRow { start.row -= 1 } else { start.column -= 1 }
            } else if position + length > index {
                guard length > 1 else { continue }
                if isRow { span.rows -= 1 } else { span.columns -= 1 }
                if position == index { keptFills.insert(start) }
            }
            if !span.isSingle { newSpans[start] = span }
        }
        var newFills: [WriterCellPosition: String] = [:]
        for (place, color) in fills {
            var place = place
            let position = isRow ? place.row : place.column
            if position == index, !keptFills.contains(place) { continue }
            if position > index {
                if isRow { place.row -= 1 } else { place.column -= 1 }
            }
            newFills[place] = color
        }
        return (newSpans, newFills)
    }
}
