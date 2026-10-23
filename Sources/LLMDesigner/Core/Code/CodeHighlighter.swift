import AppKit

enum CodeTokenKind: Sendable {
    case plain, keyword, constant, builtin, type, function, string, number, comment, decorator, name

    /// Whether the kind gets a colour of its own.
    var isColoured: Bool { self != .plain }
}

struct CodeToken: Equatable, Sendable {
    /// In UTF-16 units of the code.
    let range: NSRange
    let kind: CodeTokenKind
}

/// Colours of the tokens: for dark paper and slides, and for white paper and print.
enum CodeTheme {
    static func color(_ kind: CodeTokenKind, light: Bool) -> NSColor? {
        guard let value = hex(kind, light: light) else { return nil }
        return NSColor(hex: value)
    }

    static func hex(_ kind: CodeTokenKind, light: Bool) -> UInt32? {
        switch (kind, light) {
        case (.plain, _): nil
        case (.keyword, false): 0xFF7B72
        case (.keyword, true): 0xCF222E
        case (.constant, false), (.number, false): 0x79C0FF
        case (.constant, true), (.number, true): 0x0550AE
        case (.builtin, false): 0xFFA657
        case (.builtin, true): 0x953800
        case (.type, false): 0x7EE787
        case (.type, true): 0x116329
        case (.function, false), (.decorator, false): 0xD2A8FF
        case (.function, true), (.decorator, true): 0x8250DF
        case (.string, false): 0xA5D6FF
        case (.string, true): 0x0A3069
        case (.comment, false): 0x8B949E
        case (.comment, true): 0x6E7781
        case (.name, false): 0xE3B341
        case (.name, true): 0x7D4E00
        }
    }
}

/// Splits code into coloured tokens. It reads what the languages' text looks like (comments, strings, numbers,
/// words); it doesn't parse them, so incomplete code is coloured as far as it goes.
enum CodeHighlighter {
    static func tokens(in code: String, language: CodeLanguage) -> [CodeToken] {
        var scanner = Scanner(units: Array(code.utf16))
        switch language {
        case .python: scanner.python()
        case .sql: scanner.sql()
        }
        return scanner.tokens
    }

    // MARK: Words

    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
        "while", "with", "yield",
    ]
    static let pythonConstants: Set<String> = ["True", "False", "None", "NotImplemented", "Ellipsis", "__name__", "__file__"]
    static let pythonBuiltins: Set<String> = [
        "print", "len", "range", "int", "float", "str", "bool", "list", "dict", "set", "tuple", "type", "isinstance", "issubclass",
        "sum", "min", "max", "abs", "round", "sorted", "reversed", "enumerate", "zip", "map", "filter", "open", "input", "super",
        "iter", "next", "any", "all", "pow", "divmod", "hash", "id", "repr", "format", "getattr", "setattr", "hasattr", "delattr",
        "callable", "chr", "ord", "bin", "hex", "oct", "bytes", "bytearray", "frozenset", "object", "property", "staticmethod",
        "classmethod", "vars", "dir", "help", "exec", "eval", "compile", "slice", "complex", "self", "cls",
        "Exception", "ValueError", "TypeError", "KeyError", "IndexError", "RuntimeError", "StopIteration", "AttributeError",
        "ImportError", "OSError", "ZeroDivisionError", "NameError", "FileNotFoundError", "NotImplementedError",
    ]

    static let sqlKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "ON", "USING", "AS",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "NEXT", "ROWS", "ROW", "ONLY", "UNION", "ALL",
        "INTERSECT", "EXCEPT", "MINUS", "DISTINCT", "TOP", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
        "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "TRUNCATE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "CHECK",
        "UNIQUE", "DEFAULT", "NOT", "AND", "OR", "IN", "IS", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "ANY", "SOME", "CASE", "WHEN",
        "THEN", "ELSE", "END", "WITH", "RECURSIVE", "OVER", "PARTITION", "ASC", "DESC", "NULLS", "BEGIN", "COMMIT", "ROLLBACK",
        "TRANSACTION", "IF", "ADD", "COLUMN", "RENAME", "TO", "RETURNING", "MERGE", "MATCHED", "TEMPORARY", "TEMP", "CASCADE",
        "DATABASE", "SCHEMA", "GRANT", "REVOKE", "EXPLAIN", "ANALYZE", "REPLACE", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT",
        "RANGE", "WINDOW", "LATERAL", "FOR", "ESCAPE", "COLLATE", "INTERVAL", "ZONE",
    ]
    static let sqlConstants: Set<String> = ["NULL", "TRUE", "FALSE", "UNKNOWN"]
    static let sqlTypes: Set<String> = [
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "VARCHAR", "CHAR", "TEXT", "NVARCHAR", "DATE", "TIME", "TIMESTAMP",
        "DATETIME", "BOOLEAN", "BOOL", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL", "SERIAL", "BIGSERIAL", "UUID", "JSON",
        "JSONB", "BLOB", "BYTEA", "MONEY", "ARRAY",
    ]
    static let sqlFunctions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "CONVERT", "ROUND", "FLOOR", "CEIL", "CEILING", "ABS",
        "LOWER", "UPPER", "LENGTH", "LEN", "SUBSTRING", "SUBSTR", "TRIM", "LTRIM", "RTRIM", "CONCAT", "REPLACE", "NOW", "CURRENT_DATE",
        "CURRENT_TIMESTAMP", "EXTRACT", "DATE_TRUNC", "DATEADD", "DATEDIFF", "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG",
        "LEAD", "FIRST_VALUE", "LAST_VALUE", "STRING_AGG", "ARRAY_AGG", "GROUP_CONCAT", "IFNULL", "ISNULL", "GREATEST", "LEAST",
        "POWER", "SQRT", "MOD", "RANDOM", "TO_CHAR", "TO_DATE", "POSITION", "REGEXP_REPLACE", "STDDEV", "VARIANCE",
    ]

    // MARK: Scanner

    private struct Scanner {
        let units: [UInt16]
        var tokens: [CodeToken] = []
        var index = 0

        init(units: [UInt16]) { self.units = units }

        private var count: Int { units.count }

        private func peek(_ offset: Int = 0) -> UInt16? {
            let position = index + offset
            return position >= 0 && position < count ? units[position] : nil
        }

        private static func isIdentifierStart(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit > 0x7F
        }

        private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        private static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }

        private mutating func add(_ start: Int, _ end: Int, _ kind: CodeTokenKind) {
            guard end > start else { return }
            tokens.append(CodeToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        private func text(_ start: Int, _ end: Int) -> String {
            String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
        }

        private func endOfLine(from position: Int) -> Int {
            var end = position
            while end < count, units[end] != 0x0A { end += 1 }
            return end
        }

        /// The next non-space unit after `position` on the same line.
        private func nextNonSpace(after position: Int) -> UInt16? {
            var scan = position
            while scan < count, units[scan] == 0x20 || units[scan] == 0x09 { scan += 1 }
            return scan < count ? units[scan] : nil
        }

        private mutating func number() {
            let start = index
            // 0x1F, 0b101, 0o7, 1_000, 3.14, .5, 1e-9, 2j
            if units[index] == 0x30, let next = peek(1), "xXbBoO".utf16.contains(next) {
                index += 2
                while index < count, Self.isIdentifier(units[index]) { index += 1 }
            } else {
                while index < count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
                if index < count, units[index] == 0x2E, index + 1 >= count || Self.isDigit(units[index + 1]) || !Self.isIdentifierStart(units[index + 1]) {
                    index += 1
                    while index < count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
                }
                if index < count, units[index] == 0x65 || units[index] == 0x45 {
                    var scan = index + 1
                    if scan < count, units[scan] == 0x2B || units[scan] == 0x2D { scan += 1 }
                    if scan < count, Self.isDigit(units[scan]) {
                        index = scan
                        while index < count, Self.isDigit(units[index]) { index += 1 }
                    }
                }
                if index < count, units[index] == 0x6A || units[index] == 0x4A || units[index] == 0x6C || units[index] == 0x4C { index += 1 }
            }
            add(start, index, .number)
        }

        // MARK: Python

        mutating func python() {
            var previousWord = ""
            while index < count {
                let unit = units[index]
                if unit == 0x23 {                                   // # comment
                    let end = endOfLine(from: index)
                    add(index, end, .comment)
                    index = end
                } else if unit == 0x22 || unit == 0x27 {
                    pythonString(start: index, quote: unit, quoteAt: index)
                } else if Self.isDigit(unit) || (unit == 0x2E && (peek(1).map(Self.isDigit) ?? false)) {
                    number()
                } else if unit == 0x40, atLineStart(index) {         // @decorator
                    var end = index + 1
                    while end < count, Self.isIdentifier(units[end]) || units[end] == 0x2E { end += 1 }
                    add(index, end, .decorator)
                    index = end
                } else if Self.isIdentifierStart(unit) {
                    let start = index
                    while index < count, Self.isIdentifier(units[index]) { index += 1 }
                    let word = text(start, index)
                    // A string prefix: r"…", f'…', rb"…"
                    if index < count, units[index] == 0x22 || units[index] == 0x27, word.count <= 2,
                       ["r", "u", "b", "f", "br", "rb", "fr", "rf", "ur"].contains(word.lowercased()) {
                        pythonString(start: start, quote: units[index], quoteAt: index)
                        previousWord = ""
                        continue
                    }
                    if start > 0, units[start - 1] == 0x2E, !(start > 1 && units[start - 2] == 0x2E) {
                        // An attribute (`frame.max`, `obj.print`) is no keyword or built-in; a call is a function.
                        if nextNonSpace(after: index) == 0x28 { add(start, index, .function) }
                    } else if CodeHighlighter.pythonKeywords.contains(word) {
                        add(start, index, .keyword)
                    } else if CodeHighlighter.pythonConstants.contains(word) {
                        add(start, index, .constant)
                    } else if previousWord == "def" {
                        add(start, index, .function)
                    } else if previousWord == "class" {
                        add(start, index, .type)
                    } else if CodeHighlighter.pythonBuiltins.contains(word) {
                        add(start, index, .builtin)
                    } else if nextNonSpace(after: index) == 0x28 {
                        add(start, index, .function)
                    }
                    previousWord = word
                    continue
                } else {
                    index += 1
                    // Spaces between `def` and the name don't forget the keyword.
                    if unit == 0x20 || unit == 0x09 { continue }
                }
                previousWord = ""
            }
        }

        private func atLineStart(_ position: Int) -> Bool {
            var scan = position - 1
            while scan >= 0, units[scan] == 0x20 || units[scan] == 0x09 { scan -= 1 }
            return scan < 0 || units[scan] == 0x0A
        }

        private mutating func pythonString(start: Int, quote: UInt16, quoteAt: Int) {
            let triple = quoteAt + 2 < count && units[quoteAt + 1] == quote && units[quoteAt + 2] == quote
            var scan = quoteAt + (triple ? 3 : 1)
            while scan < count {
                let unit = units[scan]
                if unit == 0x5C { scan += 2; continue }
                if triple {
                    if unit == quote, scan + 2 < count, units[scan + 1] == quote, units[scan + 2] == quote { scan += 3; break }
                } else {
                    if unit == quote { scan += 1; break }
                    if unit == 0x0A { break }   // an unfinished string ends with its line
                }
                scan += 1
            }
            let end = min(scan, count)
            add(start, end, .string)
            index = end
        }

        // MARK: SQL

        mutating func sql() {
            while index < count {
                let unit = units[index]
                if unit == 0x2D, peek(1) == 0x2D {                  // -- comment
                    let end = endOfLine(from: index)
                    add(index, end, .comment)
                    index = end
                } else if unit == 0x2F, peek(1) == 0x2A {           // /* comment */
                    var end = index + 2
                    while end < count, !(units[end] == 0x2A && end + 1 < count && units[end + 1] == 0x2F) { end += 1 }
                    end = min(end + 2, count)
                    add(index, end, .comment)
                    index = end
                } else if unit == 0x27 {                            // 'string' with '' inside
                    var end = index + 1
                    while end < count {
                        if units[end] == 0x27 {
                            if end + 1 < count, units[end + 1] == 0x27 { end += 2; continue }
                            end += 1
                            break
                        }
                        end += 1
                    }
                    add(index, end, .string)
                    index = end
                } else if unit == 0x22 || unit == 0x60 {            // "name" or `name`
                    var end = index + 1
                    while end < count, units[end] != unit { end += 1 }
                    end = min(end + 1, count)
                    add(index, end, .name)
                    index = end
                } else if Self.isDigit(unit) || (unit == 0x2E && (peek(1).map(Self.isDigit) ?? false)) {
                    number()
                } else if (unit == 0x3A || unit == 0x40 || unit == 0x24), let next = peek(1), Self.isIdentifier(next), peek(-1) != 0x3A {
                    // :param, @variable, $1
                    var end = index + 1
                    while end < count, Self.isIdentifier(units[end]) { end += 1 }
                    add(index, end, .constant)
                    index = end
                } else if Self.isIdentifierStart(unit) {
                    let start = index
                    while index < count, Self.isIdentifier(units[index]) { index += 1 }
                    let word = text(start, index).uppercased()
                    let isCall = nextNonSpace(after: index) == 0x28
                    if start > 0, units[start - 1] == 0x2E {
                        // A column after a dot (`k.alter`) is a name, whatever it is called.
                        if isCall { add(start, index, .function) }
                    } else if CodeHighlighter.sqlConstants.contains(word) {
                        add(start, index, .constant)
                    } else if CodeHighlighter.sqlTypes.contains(word) {
                        add(start, index, .type)
                    } else if CodeHighlighter.sqlFunctions.contains(word), isCall {
                        add(start, index, .builtin)
                    } else if CodeHighlighter.sqlKeywords.contains(word) {
                        add(start, index, .keyword)
                    } else if isCall {
                        add(start, index, .function)
                    }
                } else {
                    index += 1
                }
            }
        }
    }
}
