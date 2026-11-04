import Foundation

/// What sorting a table and adding a row of sums come to, apart from where the cells live: the editor keeps attributed
/// text and the actions Markdown, and both must do the same.
enum WriterTableArrange {
    enum SortProblem: Error, Equatable {
        case tooFewRows, mergedCells

        var message: String {
            switch self {
            case .tooFewRows: "Zum Sortieren braucht die Tabelle unter der Kopfzeile mindestens zwei Zeilen."
            case .mergedCells: "Tabellen mit verbundenen Zellen lassen sich nicht sortieren – erst die Verbindung aufheben."
            }
        }
    }

    /// The rows below the header in the order of a column: `order[n]` is the row that comes to place `n + 1`, and the
    /// look and formulas that went with it. Rows at the end with sums of other rows stay there. nil: already in order.
    static func sorted(texts: [[String]], style: WriterTableStyle, spans: [WriterCellPosition: WriterCellSpan],
                       column: Int, ascending: Bool) throws -> (order: [Int], style: WriterTableStyle)? {
        var last = texts.count - 1
        // Rows at the end that calculate over others (a row of sums) stay at the end.
        while last > 1, style.formulas.contains(where: { place, formula in
            place.row == last && WriterTableCalc.referencedRows(formula).contains(where: { $0 != last })
        }) { last -= 1 }
        guard last >= 2 else { throw SortProblem.tooFewRows }
        if spans.contains(where: { start, span in start.row + span.rows - 1 >= 1 && start.row <= last }) { throw SortProblem.mergedCells }
        let rows = Array(1...last)
        let order = rows.enumerated().sorted { a, b in
            let left = texts[a.element][column], right = texts[b.element][column]
            let leftEmpty = left.trimmingCharacters(in: .whitespaces).isEmpty, rightEmpty = right.trimmingCharacters(in: .whitespaces).isEmpty
            // Empty cells go last both ways; equal ones keep their order.
            if leftEmpty != rightEmpty { return !leftEmpty }
            guard let isAscending = WriterTableCalc.ascending(left, right) else { return a.offset < b.offset }
            return ascending ? isAscending : !isAscending
        }.map(\.element)
        guard order != rows else { return nil }
        var result = style
        var fills = style.fills.filter { $0.key.row == 0 || $0.key.row > last }
        var formulas = style.formulas.filter { $0.key.row == 0 || $0.key.row > last }
        for (offset, oldRow) in order.enumerated() {
            let newRow = offset + 1
            for (place, color) in style.fills where place.row == oldRow { fills[WriterCellPosition(row: newRow, column: place.column)] = color }
            for (place, formula) in style.formulas where place.row == oldRow {
                formulas[WriterCellPosition(row: newRow, column: place.column)] = WriterTableCalc.movingRow(formula, from: oldRow, to: newRow)
            }
        }
        result.fills = fills
        result.formulas = formulas
        return (order, result)
    }

    /// The formulas of a new row of sums at the end, one for every column with numbers; nil when there are no numbers.
    static func sumFormulas(texts: [[String]], style: WriterTableStyle, columns: Int) -> [WriterCellPosition: String]? {
        guard texts.count >= 2 else { return nil }
        let newRow = texts.count
        var sums: [WriterCellPosition: String] = [:]
        for column in 0..<columns {
            let hasNumbers = (1..<texts.count).contains {
                WriterTableCalc.number(in: texts[$0][column]) != nil || style.formulas[WriterCellPosition(row: $0, column: column)] != nil
            }
            guard hasNumbers else { continue }
            let name = WriterTableCalc.columnName(column)
            sums[WriterCellPosition(row: newRow, column: column)] = "SUMME(\(name)2:\(name)\(texts.count))"
        }
        return sums.isEmpty ? nil : sums
    }

    static let noNumbersMessage = "In der Tabelle stehen keine Zahlen zum Summieren."
}
