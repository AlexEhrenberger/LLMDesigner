import Foundation

/// Tidies code for its language: Python's indentation and blank lines, SQL's keywords and line breaks. Strings and
/// comments are never touched.
enum CodeFormatter {
    static func format(_ code: String, language: CodeLanguage) -> String {
        switch language {
        case .python: python(code)
        case .sql: sql(code)
        }
    }

    // MARK: Python

    /// Tabs become spaces, trailing spaces go, every block is indented by multiples of four spaces, and no more than
    /// two blank lines follow each other. Lines inside brackets and multi-line strings keep their own indentation.
    static func python(_ code: String) -> String {
        let tokens = CodeHighlighter.tokens(in: code, language: .python)
        let strings = tokens.filter { $0.kind == .string }.map(\.range)
        let units = Array(code.utf16)
        let comments = tokens.filter { $0.kind == .comment }.map(\.range)

        func isInside(_ ranges: [NSRange], _ position: Int) -> Bool {
            ranges.contains { position > $0.location && position < NSMaxRange($0) }
        }

        // Bracket depth at the start of each line, outside strings and comments.
        var depthAtLine: [Int] = []
        var depth = 0
        var lineStarts: [Int] = []
        var index = 0
        var lineStart = 0
        lineStarts.append(0)
        depthAtLine.append(0)
        while index < units.count {
            let unit = units[index]
            if !isInside(strings, index) && !strings.contains(where: { $0.location == index }) && !comments.contains(where: { $0.location <= index && index < NSMaxRange($0) }) {
                if unit == 0x28 || unit == 0x5B || unit == 0x7B { depth += 1 }
                if unit == 0x29 || unit == 0x5D || unit == 0x7D { depth = max(0, depth - 1) }
            }
            if unit == 0x0A {
                lineStart = index + 1
                lineStarts.append(lineStart)
                depthAtLine.append(depth)
            }
            index += 1
        }

        let lines = code.components(separatedBy: "\n")
        var output: [String] = []
        var stack = [0]
        var blank = 0
        for (number, original) in lines.enumerated() {
            let start = lineStarts[number]
            let endOfLine = start + original.utf16.count
            // A line that begins inside a multi-line string is part of the string.
            if isInside(strings, start) {
                output.append(original)
                blank = 0
                continue
            }
            var line = original
            // Leading tabs
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            line = String(leading).replacingOccurrences(of: "\t", with: "    ") + line.dropFirst(leading.count)
            // A string that goes on into the next line owns the end of this one.
            if !isInside(strings, endOfLine) || endOfLine >= units.count {
                while line.last == " " || line.last == "\t" { line.removeLast() }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blank += 1
                if blank <= 2, !output.isEmpty { output.append("") }
                continue
            }
            blank = 0
            if depthAtLine[number] > 0 {
                output.append(line)
                continue
            }
            let width = line.prefix { $0 == " " }.count
            let isComment = trimmed.hasPrefix("#")
            if isComment {
                // A comment takes the level of the code it stands in front of, without changing the levels.
                let level = stack.lastIndex { $0 <= width } ?? 0
                output.append(String(repeating: "    ", count: level) + trimmed)
                continue
            }
            if width > stack[stack.count - 1] {
                stack.append(width)
            } else {
                while stack.count > 1, stack[stack.count - 1] > width { stack.removeLast() }
                if stack[stack.count - 1] < width { stack.append(width) }
            }
            // Only the indentation changes; the end of the line may belong to a string.
            output.append(String(repeating: "    ", count: stack.count - 1) + line.drop { $0 == " " })
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    // MARK: SQL

    struct Atom {
        enum Kind { case word, string, number, lineComment, blockComment, punctuation, op }
        var text: String
        var kind: Kind

        var upper: String { text.uppercased() }
        var isWord: Bool { kind == .word }
    }

    static func sqlAtoms(of code: String) -> [Atom] {
        let units = Array(code.utf16)
        var atoms: [Atom] = []
        var index = 0
        func text(_ start: Int, _ end: Int) -> String { String(utf16CodeUnits: Array(units[start..<end]), count: end - start) }
        func isWordUnit(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) || unit == 0x5F || unit > 0x7F
        }
        while index < units.count {
            let unit = units[index]
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
                index += 1
            } else if unit == 0x2D, index + 1 < units.count, units[index + 1] == 0x2D {
                var end = index
                while end < units.count, units[end] != 0x0A { end += 1 }
                atoms.append(Atom(text: text(index, end).trimmingCharacters(in: .whitespaces), kind: .lineComment))
                index = end
            } else if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                var end = index + 2
                while end + 1 < units.count, !(units[end] == 0x2A && units[end + 1] == 0x2F) { end += 1 }
                end = min(end + 2, units.count)
                atoms.append(Atom(text: text(index, end), kind: .blockComment))
                index = end
            } else if unit == 0x27 {
                var end = index + 1
                while end < units.count {
                    if units[end] == 0x27 {
                        if end + 1 < units.count, units[end + 1] == 0x27 { end += 2; continue }
                        end += 1
                        break
                    }
                    end += 1
                }
                atoms.append(Atom(text: text(index, end), kind: .string))
                index = end
            } else if unit == 0x22 || unit == 0x60 {
                var end = index + 1
                while end < units.count, units[end] != unit { end += 1 }
                end = min(end + 1, units.count)
                atoms.append(Atom(text: text(index, end), kind: .string))
                index = end
            } else if (unit == 0x3A || unit == 0x40 || unit == 0x24), index + 1 < units.count, isWordUnit(units[index + 1]),
                      !(unit == 0x3A && index > 0 && units[index - 1] == 0x3A) {
                var end = index + 1
                while end < units.count, isWordUnit(units[end]) { end += 1 }
                atoms.append(Atom(text: text(index, end), kind: .number))
                index = end
            } else if isWordUnit(unit) {
                var end = index
                while end < units.count, isWordUnit(units[end]) { end += 1 }
                let value = text(index, end)
                atoms.append(Atom(text: value, kind: unit >= 0x30 && unit <= 0x39 ? .number : .word))
                index = end
            } else if "(),;.".utf16.contains(unit) {
                atoms.append(Atom(text: text(index, index + 1), kind: .punctuation))
                index += 1
            } else {
                var end = index
                while end < units.count, "<>=!+-*/%|&^~:".utf16.contains(units[end]) { end += 1 }
                if end == index { end = index + 1 }
                atoms.append(Atom(text: text(index, end), kind: .op))
                index = end
            }
        }
        return atoms
    }

    /// Keywords start lines and are written in capitals; the layout follows the usual style:
    /// `SELECT` items one per line when there are several, `FROM`, joins, `WHERE` and `GROUP BY` on lines of their own,
    /// `AND` and `OR` indented, subqueries in brackets indented.
    static func sql(_ code: String) -> String {
        var formatter = SQLFormatter()
        return formatter.format(sqlAtoms(of: code))
    }

    private struct SQLFormatter {
        private static let majorClauses: Set<String> = ["SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "SET", "VALUES", "RETURNING", "WINDOW", "QUALIFY"]
        private static let statementStarters: Set<String> = ["INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TRUNCATE", "MERGE", "WITH", "EXPLAIN"]
        private static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "MINUS"]
        private static let joinModifiers: Set<String> = ["INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER", "LATERAL"]
        /// Keywords that stand before a bracket with a space; any other word before a bracket is a call.
        private static let keywordsBeforeBracket: Set<String> = CodeHighlighter.sqlKeywords.subtracting(["LEFT", "RIGHT", "REPLACE", "FIRST", "NEXT", "ROW", "ROWS"])

        mutating func format(_ atoms: [Atom]) -> String {
            var lines = lines(of: atoms, level: 0)
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }

        private func indent(_ level: Int) -> String { String(repeating: "    ", count: level) }

        /// The text of one atom: keywords, types and functions in capitals.
        private func written(_ atom: Atom, next: Atom?) -> String {
            guard atom.isWord else { return atom.text }
            let upper = atom.upper
            if CodeHighlighter.sqlKeywords.contains(upper) || CodeHighlighter.sqlConstants.contains(upper) || CodeHighlighter.sqlTypes.contains(upper) { return upper }
            if CodeHighlighter.sqlFunctions.contains(upper), next?.text == "(" { return upper }
            return atom.text
        }

        private func needsSpace(before atom: Atom, after previous: Atom?) -> Bool {
            guard let previous else { return false }
            if [",", ";", ")", "."].contains(atom.text) || previous.text == "." || previous.text == "(" { return false }
            if atom.text == "::" || previous.text == "::" { return false }
            if atom.text == "(" {
                // A call has no space; a keyword in front of a bracket has one.
                if previous.isWord { return Self.keywordsBeforeBracket.contains(previous.upper) }
                if previous.kind == .string { return false }
                return previous.text != "("
            }
            // A star in `COUNT(*)` or `t.*` belongs to what is in front of it.
            if atom.text == "*", previous.text == "(" || previous.text == "." { return false }
            return true
        }

        /// Whether the atoms between a clause keyword and the next clause keyword (outside brackets) have a comma.
        private func hasTopLevelComma(_ atoms: [Atom], from start: Int) -> Bool {
            var depth = 0
            var index = start
            while index < atoms.count {
                let atom = atoms[index]
                if atom.text == "(" { depth += 1 }
                if atom.text == ")" { depth -= 1; if depth < 0 { return false } }
                if depth == 0 {
                    if atom.text == "," { return true }
                    if atom.isWord, Self.majorClauses.contains(atom.upper) || Self.setOperators.contains(atom.upper) || atom.upper == "GROUP" || atom.upper == "ORDER" { return false }
                    if atom.text == ";" { return false }
                }
                index += 1
            }
            return false
        }

        private func matchingBracket(_ atoms: [Atom], from open: Int) -> Int? {
            var depth = 0
            for index in open..<atoms.count {
                if atoms[index].text == "(" { depth += 1 }
                if atoms[index].text == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            return nil
        }

        /// Everything between brackets on one line (keywords in capitals, commas followed by a space).
        private func inline(_ atoms: [Atom]) -> String {
            var text = ""
            var previous: Atom?
            for (index, atom) in atoms.enumerated() {
                if atom.kind == .lineComment { continue }
                if needsSpace(before: atom, after: previous) { text += " " }
                text += written(atom, next: index + 1 < atoms.count ? atoms[index + 1] : nil)
                previous = atom
            }
            return text
        }

        private func lines(of atoms: [Atom], level: Int) -> [String] {
            var lines: [String] = []
            var current = ""
            var currentIndent = level
            var previous: Atom?
            var clause = ""
            var isBetween = false
            var caseDepth = 0
            var breakBeforeNext = false
            var itemsPerLine = false

            func flush() {
                let text = current.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { lines.append(indent(currentIndent) + text) }
                current = ""
            }
            func start(at indentLevel: Int) {
                flush()
                currentIndent = indentLevel
                previous = nil
            }
            func append(_ text: String, atom: Atom, forceSpace: Bool = false) {
                if forceSpace || needsSpace(before: atom, after: previous) { current += " " }
                current += text
                previous = atom
            }

            var index = 0
            while index < atoms.count {
                let atom = atoms[index]
                let next = index + 1 < atoms.count ? atoms[index + 1] : nil
                let upper = atom.upper
                defer { index += 1 }

                if breakBeforeNext {
                    // After `SELECT` (and `DISTINCT`): the items start on a line of their own.
                    if atom.isWord, upper == "DISTINCT" || upper == "ALL" || upper == "TOP" {
                        append(written(atom, next: next), atom: atom)
                        continue
                    }
                    if previous?.upper == "TOP", atom.kind == .number {
                        append(atom.text, atom: atom)
                        continue
                    }
                    breakBeforeNext = false
                    start(at: level + 1)
                }

                switch atom.kind {
                case .lineComment:
                    append(atom.text, atom: atom)
                    flush()
                    previous = nil
                    continue
                case .blockComment, .string, .number, .op:
                    append(written(atom, next: next), atom: atom)
                    continue
                case .punctuation:
                    switch atom.text {
                    case ",":
                        append(",", atom: atom)
                        if itemsPerLine, caseDepth == 0 { start(at: level + 1) }
                        else if clause == "WITH" { start(at: level) }
                    case ";":
                        append(";", atom: atom)
                        flush()
                        lines.append("")
                        currentIndent = level
                        previous = nil
                        clause = ""
                        itemsPerLine = false
                    case "(":
                        guard let close = matchingBracket(atoms, from: index) else {
                            append("(", atom: atom)
                            continue
                        }
                        let inner = Array(atoms[(index + 1)..<close])
                        if let first = inner.first, first.isWord, first.upper == "SELECT" || first.upper == "WITH" {
                            // A subquery: its lines go one level deeper, between the brackets.
                            append("(", atom: atom)
                            flush()
                            lines += self.lines(of: inner, level: level + 1).filter { !$0.isEmpty }
                            currentIndent = level
                            current = ")"
                            previous = Atom(text: ")", kind: .punctuation)
                        } else {
                            // `INSERT INTO t (a, b)` and `CREATE TABLE t (…)`: the column list stands apart from the name.
                            let isColumnList = (clause == "INSERT" || clause == "CREATE") && previous?.isWord == true
                            append("(" + inline(inner) + ")", atom: atom, forceSpace: isColumnList)
                            previous = Atom(text: ")", kind: .punctuation)
                        }
                        index = close
                    default:
                        append(atom.text, atom: atom)
                    }
                    continue
                case .word:
                    break
                }

                // Words
                if Self.statementStarters.contains(upper), previous == nil || previous?.text == ";" || (upper == "WITH" && lines.isEmpty && current.isEmpty) {
                    start(at: level)
                    clause = upper
                    append(upper, atom: atom)
                    itemsPerLine = false
                    continue
                }
                if Self.statementStarters.contains(upper), clause.isEmpty {
                    start(at: level)
                    clause = upper
                    append(upper, atom: atom)
                    continue
                }
                if upper == "FROM", previous?.upper == "DELETE" {
                    append("FROM", atom: atom)
                    clause = "FROM"
                    continue
                }
                if Self.majorClauses.contains(upper), !(upper == "SET" && previous?.upper == "ON") {
                    start(at: level)
                    clause = upper
                    append(upper, atom: atom)
                    itemsPerLine = (upper == "SELECT" || upper == "SET") && hasTopLevelComma(atoms, from: index + 1)
                    breakBeforeNext = itemsPerLine
                    continue
                }
                if upper == "GROUP" || upper == "ORDER", next?.upper == "BY" {
                    start(at: level)
                    clause = upper
                    itemsPerLine = false
                    append(upper, atom: atom)
                    continue
                }
                if Self.setOperators.contains(upper) {
                    start(at: level)
                    clause = upper
                    append(upper, atom: atom)
                    itemsPerLine = false
                    continue
                }
                let isModifier = Self.joinModifiers.contains(upper) && next?.text != "("
                if isModifier || upper == "JOIN" {
                    // A new line at the first word of the join: `LEFT OUTER JOIN`, `JOIN`.
                    let continuesJoin = previous.map { Self.joinModifiers.contains($0.upper) } ?? false
                    if !continuesJoin { start(at: level) }
                    clause = "JOIN"
                    append(upper, atom: atom)
                    continue
                }
                if upper == "BETWEEN" { isBetween = true }
                if upper == "CASE" { caseDepth += 1 }
                if upper == "END", caseDepth > 0 { caseDepth -= 1 }
                if (upper == "AND" || upper == "OR"), caseDepth == 0 {
                    if upper == "AND", isBetween {
                        isBetween = false
                    } else if ["WHERE", "HAVING", "JOIN", "ON"].contains(clause) {
                        start(at: level + 1)
                    }
                }
                if upper == "ON" { clause = "ON" }
                append(written(atom, next: next), atom: atom)
            }
            flush()
            return lines
        }
    }
}
