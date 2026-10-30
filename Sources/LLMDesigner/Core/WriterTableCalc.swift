import Foundation

/// Calculations in Writer Studio's tables, as in a spreadsheet: a cell may hold a formula (`=SUMME(B2:B4)`), whose
/// result is the cell's text. Cells are named like in a spreadsheet: the column's letter and the row's number,
/// the header row being row 1 (so `B2` is the second column of the first row below the header).
/// Markdown keeps the formulas in the table's div (`calc-3-1="SUMME(B2:B3)"`, places counted from 0) and the results
/// in the cells, so other programs show the numbers.
enum WriterTableCalc {
    // MARK: Names of cells

    /// "A", "B", …, "Z", "AA" for a column (counted from 0).
    static func columnName(_ column: Int) -> String {
        var number = column + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }

    /// "B3" for the cell in row 2, column 1 (both from 0).
    static func cellName(row: Int, column: Int) -> String {
        columnName(column) + String(row + 1)
    }

    static func column(named letters: String) -> Int? {
        guard !letters.isEmpty, letters.count <= 3 else { return nil }
        var number = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            number = number * 26 + Int(scalar.value - 64)
        }
        return number - 1
    }

    // MARK: Numbers in cells

    /// A number as a cell shows it, with what it tells about how results should look.
    struct Number: Equatable {
        var value: Double
        /// Digits after the decimal mark as written.
        var decimals = 0
        /// Written with a decimal comma (German) rather than a point.
        var usesComma = false
        /// Thousands grouped ("1.234,5").
        var grouped = false
        /// A unit after (or before) the number: "€", "%", "kg".
        var unit = ""
        var unitInFront = false
    }

    /// The number a cell's text is: "12", "-3,5", "1.234,56 €", "12 %", "$ 4.50", "1e3"; nil for anything else.
    static func number(in text: String) -> Number? {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        guard !core.isEmpty, core.count <= 40 else { return nil }
        var unit = ""
        var unitInFront = false
        // A unit is letters or symbols at one end.
        let unitCharacters: (Character) -> Bool = { !$0.isNumber && !"+-.,'() ".contains($0) }
        // In front only currency signs ("$ 4.50", "€ 3"); letters there make a name ("Q1"), not a number.
        if let first = core.first, unitCharacters(first), !first.isLetter {
            unit = String(core.prefix(while: { unitCharacters($0) && !$0.isLetter }))
            core = String(core.dropFirst(unit.count)).trimmingCharacters(in: .whitespaces)
            unitInFront = true
        } else if let last = core.last, unitCharacters(last) {
            let suffix = String(core.reversed().prefix(while: unitCharacters).reversed())
            // "1e3" keeps its exponent.
            if !(suffix.lowercased() == "e" && core.count > 1) {
                unit = suffix
                core = String(core.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard unit.count <= 4 else { return nil }
        var negative = false
        if core.hasPrefix("("), core.hasSuffix(")") {
            negative = true
            core = String(core.dropFirst().dropLast())
        }
        if core.hasPrefix("-") { negative.toggle(); core.removeFirst() } else if core.hasPrefix("+") { core.removeFirst() }
        core = core.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        guard let first = core.first, first.isNumber || first == "." || first == "," else { return nil }

        // Which mark is the decimal one: the last of "." and ",", unless it is a thousands group ("1.234").
        let dots = core.filter { $0 == "." }.count
        let commas = core.filter { $0 == "," }.count
        var decimalMark: Character?
        var grouped = false
        if dots > 0, commas > 0 {
            decimalMark = core.lastIndex(of: ".")! > core.lastIndex(of: ",")! ? "." : ","
            grouped = true
        } else if commas == 1 {
            decimalMark = ","
        } else if dots == 1 {
            // "1.234" with exactly three digits after it is read as a thousand when it has a leading group.
            let after = core.split(separator: ".", omittingEmptySubsequences: false).last ?? ""
            let before = core.split(separator: ".", omittingEmptySubsequences: false).first ?? ""
            if after.count == 3, !before.isEmpty, before != "0", before.count <= 3, text.contains("€") || unit.isEmpty == false && unit != "%" {
                grouped = true
            } else {
                decimalMark = "."
            }
        } else if dots > 1 || commas > 1 {
            grouped = true
        }
        var digits = ""
        var decimals = 0
        var afterMark = false
        var exponent = ""
        for character in core {
            if character.isNumber {
                if exponent.isEmpty { digits.append(character); if afterMark { decimals += 1 } } else { exponent.append(character) }
            } else if character == decimalMark, !afterMark, exponent.isEmpty {
                digits.append(".")
                afterMark = true
            } else if character == "." || character == "," {
                guard grouped, !afterMark else { return nil }
            } else if (character == "e" || character == "E"), exponent.isEmpty {
                exponent = "e"
            } else if (character == "-" || character == "+"), exponent == "e" {
                exponent.append(character)
            } else {
                return nil
            }
        }
        guard let value = Double(digits + exponent), value.isFinite else { return nil }
        return Number(value: negative ? -value : value, decimals: decimals, usesComma: decimalMark == "," || (decimalMark == nil && grouped && dots > 0),
                      grouped: grouped, unit: unit, unitInFront: unitInFront)
    }

    /// A result as a cell shows it, in the style of the numbers it was made from.
    static func format(_ value: Double, like style: Number?) -> String {
        guard value.isFinite else { return "#ZAHL!" }
        let usesComma = style?.usesComma ?? true
        var decimals = style?.decimals ?? 0
        let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        // A result with more digits than its inputs (an average, a share) shows up to two more.
        if abs(rounded - value) > 1e-9 * max(1, abs(value)) {
            decimals = max(decimals, min(decimals + 2, 4))
            if decimals == 0 { decimals = 2 }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = style?.decimals ?? 0
        formatter.maximumFractionDigits = decimals
        formatter.usesGroupingSeparator = style?.grouped ?? false
        formatter.decimalSeparator = usesComma ? "," : "."
        formatter.groupingSeparator = usesComma ? "." : ","
        formatter.minusSign = "−"
        var text = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) ?? String(value)
        if let unit = style?.unit, !unit.isEmpty {
            text = style?.unitInFront == true ? unit + (unit.count > 1 ? " " : "") + text : text + " " + unit
        }
        return text
    }

    // MARK: Formulas

    enum CalcError: Error, Equatable {
        case syntax
        case reference
        case value
        case divisionByZero
        case circular

        /// What the cell shows instead of a result, as spreadsheets write it.
        var display: String {
            switch self {
            case .syntax: "#FORMEL!"
            case .reference: "#BEZUG!"
            case .value: "#WERT!"
            case .divisionByZero: "#DIV/0!"
            case .circular: "#ZIRKEL!"
            }
        }
    }

    /// A cell's place in a formula (from 0).
    struct Reference: Hashable {
        var row: Int
        var column: Int
    }

    indirect enum Expression {
        case number(Double)
        case reference(Reference)
        case range(Reference, Reference)
        case unary(Character, Expression)
        case binary(String, Expression, Expression)
        case percent(Expression)
        case function(String, [Expression])
    }

    /// The functions, German and English names alike.
    static let functions: [String: String] = [
        "SUMME": "SUM", "SUM": "SUM",
        "MITTELWERT": "AVERAGE", "MW": "AVERAGE", "AVERAGE": "AVERAGE", "AVG": "AVERAGE", "DURCHSCHNITT": "AVERAGE",
        "MIN": "MIN", "MAX": "MAX", "MEDIAN": "MEDIAN",
        "ANZAHL": "COUNT", "COUNT": "COUNT",
        "PRODUKT": "PRODUCT", "PRODUCT": "PRODUCT",
        "RUNDEN": "ROUND", "ROUND": "ROUND",
        "ABS": "ABS", "WURZEL": "SQRT", "SQRT": "SQRT",
        "WENN": "IF", "IF": "IF",
    ]

    /// The functions as the formula bar offers them.
    static let functionHelp: [(name: String, example: String, detail: String)] = [
        ("SUMME", "=SUMME(B2:B5)", "Summe eines Bereichs"),
        ("MITTELWERT", "=MITTELWERT(B2:B5)", "Durchschnitt"),
        ("MIN", "=MIN(B2:B5)", "kleinster Wert"),
        ("MAX", "=MAX(B2:B5)", "größter Wert"),
        ("ANZAHL", "=ANZAHL(B2:B5)", "wie viele Zahlen"),
        ("PRODUKT", "=PRODUKT(B2:C2)", "alles malgenommen"),
        ("RUNDEN", "=RUNDEN(B2/3; 2)", "auf Stellen runden"),
        ("WENN", "=WENN(B2>100; 1; 0)", "Bedingung"),
    ]

    private enum Token: Equatable {
        case number(Double)
        case reference(Reference)
        case name(String)
        case symbol(String)
    }

    private static func tokens(_ text: String) throws -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character.isNumber || (character == "." || character == ",") && index + 1 < characters.count && characters[index + 1].isNumber
                && (tokens.last.map { if case .symbol(let s) = $0 { return s != ")" } else { return false } } ?? true) {
                var digits = ""
                var seenMark = false
                while index < characters.count {
                    let current = characters[index]
                    if current.isNumber {
                        digits.append(current)
                    } else if (current == "." || current == ","), !seenMark, index + 1 < characters.count, characters[index + 1].isNumber {
                        digits.append(".")
                        seenMark = true
                    } else {
                        break
                    }
                    index += 1
                }
                guard let value = Double(digits) else { throw CalcError.syntax }
                tokens.append(.number(value))
                continue
            }
            if character.isLetter || character == "$" {
                var word = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "$" || characters[index] == "_" {
                    word.append(characters[index])
                    index += 1
                }
                if let reference = reference(word) {
                    tokens.append(.reference(reference))
                } else {
                    tokens.append(.name(word.uppercased()))
                }
                continue
            }
            let two = index + 1 < characters.count ? String(characters[index...index + 1]) : ""
            if ["<=", ">=", "<>", "!="].contains(two) {
                tokens.append(.symbol(two == "!=" ? "<>" : two))
                index += 2
                continue
            }
            let symbol: String
            switch character {
            case "×", "·": symbol = "*"
            case "÷": symbol = "/"
            case "−": symbol = "-"
            default: symbol = String(character)
            }
            guard "+-*/^(),;:%<>=".contains(symbol) else { throw CalcError.syntax }
            tokens.append(.symbol(symbol))
            index += 1
        }
        return tokens
    }

    /// "B3", "$B$3" → the place; nil for anything else.
    private static func reference(_ word: String) -> Reference? {
        let plain = word.replacingOccurrences(of: "$", with: "").uppercased()
        let letters = plain.prefix(while: { $0.isLetter })
        let digits = plain.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber), let column = column(named: String(letters)),
              let row = Int(digits), row >= 1 else { return nil }
        return Reference(row: row - 1, column: column)
    }

    /// Reads a formula; the leading "=" may be there or not.
    static func parse(_ formula: String) throws -> Expression {
        var text = formula.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        let tokens = try tokens(text)
        guard !tokens.isEmpty else { throw CalcError.syntax }
        var position = 0

        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }
        func take(_ symbol: String) -> Bool {
            if peek() == .symbol(symbol) { position += 1; return true }
            return false
        }
        func comparison() throws -> Expression {
            var left = try additive()
            while let token = peek(), case .symbol(let symbol) = token, ["<", ">", "=", "<=", ">=", "<>"].contains(symbol) {
                position += 1
                left = .binary(symbol, left, try additive())
            }
            return left
        }
        func additive() throws -> Expression {
            var left = try multiplicative()
            while let token = peek(), case .symbol(let symbol) = token, symbol == "+" || symbol == "-" {
                position += 1
                left = .binary(symbol, left, try multiplicative())
            }
            return left
        }
        func multiplicative() throws -> Expression {
            var left = try power()
            while let token = peek(), case .symbol(let symbol) = token, symbol == "*" || symbol == "/" {
                position += 1
                left = .binary(symbol, left, try power())
            }
            return left
        }
        func power() throws -> Expression {
            let base = try unary()
            if take("^") { return .binary("^", base, try unary()) }
            return base
        }
        func unary() throws -> Expression {
            if take("-") { return .unary("-", try unary()) }
            if take("+") { return try unary() }
            var value = try primary()
            while take("%") { value = .percent(value) }
            return value
        }
        func primary() throws -> Expression {
            guard let token = peek() else { throw CalcError.syntax }
            position += 1
            switch token {
            case .number(let value):
                return .number(value)
            case .reference(let start):
                if take(":") {
                    guard case .reference(let end)? = peek() else { throw CalcError.syntax }
                    position += 1
                    return .range(start, end)
                }
                return .reference(start)
            case .name(let name):
                guard let function = functions[name], take("(") else { throw CalcError.syntax }
                var arguments: [Expression] = []
                if !take(")") {
                    repeat { arguments.append(try comparison()) } while take(";") || take(",")
                    guard take(")") else { throw CalcError.syntax }
                }
                return .function(function, arguments)
            case .symbol("("):
                let inner = try comparison()
                guard take(")") else { throw CalcError.syntax }
                return inner
            default:
                throw CalcError.syntax
            }
        }

        let expression = try comparison()
        guard position == tokens.count else { throw CalcError.syntax }
        return expression
    }

    /// Whether a cell's text is meant as a formula ("=…").
    static func isFormulaText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 1 && trimmed.hasPrefix("=")
    }

    /// A formula as stored: without its "=", function names in capitals as typed.
    static func normalized(_ formula: String) -> String {
        var text = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Evaluating a table

    /// The results of all formulas of a table. `cells`: the texts by row and column (header row first).
    static func evaluate(cells: [[String]], formulas: [WriterCellPosition: String]) -> [WriterCellPosition: String] {
        var evaluator = Evaluator(cells: cells, formulas: formulas)
        var results: [WriterCellPosition: String] = [:]
        for place in formulas.keys {
            switch evaluator.value(at: Reference(row: place.row, column: place.column)) {
            case .success(let value): results[place] = format(value.number, like: value.style)
            case .failure(let error): results[place] = error.display
            }
        }
        return results
    }

    /// A value while calculating, with the look of the numbers it came from.
    struct Value {
        var number: Double
        var style: Number?
    }

    private struct Evaluator {
        let cells: [[String]]
        let formulas: [WriterCellPosition: String]
        var memo: [Reference: Result<Value, CalcError>] = [:]
        var visiting = Set<Reference>()

        init(cells: [[String]], formulas: [WriterCellPosition: String]) {
            self.cells = cells
            self.formulas = formulas
        }

        func text(_ reference: Reference) -> String? {
            guard reference.row >= 0, reference.row < cells.count, reference.column >= 0, reference.column < cells[reference.row].count else { return nil }
            return cells[reference.row][reference.column]
        }

        mutating func value(at reference: Reference) -> Result<Value, CalcError> {
            if let known = memo[reference] { return known }
            guard text(reference) != nil else { return .failure(.reference) }
            let place = WriterCellPosition(row: reference.row, column: reference.column)
            let result: Result<Value, CalcError>
            if let formula = formulas[place] {
                guard visiting.insert(reference).inserted else { return .failure(.circular) }
                do {
                    result = .success(try evaluate(try WriterTableCalc.parse(formula)))
                } catch let error as CalcError {
                    result = .failure(error)
                } catch {
                    result = .failure(.syntax)
                }
                visiting.remove(reference)
            } else if let number = WriterTableCalc.number(in: text(reference) ?? "") {
                result = .success(Value(number: number.value, style: number))
            } else if (text(reference) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                result = .success(Value(number: 0, style: nil))
            } else {
                result = .failure(.value)
            }
            memo[reference] = result
            return result
        }

        /// The numbers of a range; text and empty cells are left out, like spreadsheets do in sums.
        mutating func numbers(_ start: Reference, _ end: Reference) throws -> [Value] {
            var values: [Value] = []
            for row in min(start.row, end.row)...max(start.row, end.row) {
                for column in min(start.column, end.column)...max(start.column, end.column) {
                    let reference = Reference(row: row, column: column)
                    guard let text = text(reference) else { throw CalcError.reference }
                    if formulas[WriterCellPosition(row: row, column: column)] != nil {
                        values.append(try value(at: reference).get())
                    } else if let number = WriterTableCalc.number(in: text) {
                        values.append(Value(number: number.value, style: number))
                    }
                }
            }
            return values
        }

        mutating func arguments(_ expressions: [Expression]) throws -> [Value] {
            var values: [Value] = []
            for expression in expressions {
                if case .range(let start, let end) = expression {
                    values += try numbers(start, end)
                } else {
                    values.append(try evaluate(expression))
                }
            }
            return values
        }

        mutating func evaluate(_ expression: Expression) throws -> Value {
            switch expression {
            case .number(let value):
                return Value(number: value, style: nil)
            case .reference(let reference):
                return try value(at: reference).get()
            case .range:
                // A range only stands inside a function.
                throw CalcError.value
            case .unary(_, let inner):
                var value = try evaluate(inner)
                value.number = -value.number
                return value
            case .percent(let inner):
                var value = try evaluate(inner)
                value.number /= 100
                value.style = nil
                return value
            case .binary(let symbol, let leftExpression, let rightExpression):
                let left = try evaluate(leftExpression)
                let right = try evaluate(rightExpression)
                let style = common([left, right], keepsUnit: symbol == "+" || symbol == "-")
                switch symbol {
                case "+": return Value(number: left.number + right.number, style: style)
                case "-": return Value(number: left.number - right.number, style: style)
                case "*": return Value(number: left.number * right.number, style: plain(style))
                case "/":
                    guard right.number != 0 else { throw CalcError.divisionByZero }
                    return Value(number: left.number / right.number, style: plain(style))
                case "^": return Value(number: pow(left.number, right.number), style: plain(style))
                default:
                    let truth: Bool
                    switch symbol {
                    case "<": truth = left.number < right.number
                    case ">": truth = left.number > right.number
                    case "<=": truth = left.number <= right.number
                    case ">=": truth = left.number >= right.number
                    case "<>": truth = left.number != right.number
                    default: truth = abs(left.number - right.number) < 1e-12
                    }
                    return Value(number: truth ? 1 : 0, style: nil)
                }
            case .function(let name, let expressions):
                if name == "IF" {
                    guard expressions.count >= 2 else { throw CalcError.syntax }
                    let condition = try evaluate(expressions[0]).number
                    if condition != 0 { return try evaluate(expressions[1]) }
                    return expressions.count > 2 ? try evaluate(expressions[2]) : Value(number: 0, style: nil)
                }
                if name == "ROUND" {
                    guard let first = expressions.first else { throw CalcError.syntax }
                    let value = try evaluate(first)
                    let places = expressions.count > 1 ? Int(try evaluate(expressions[1]).number) : 0
                    let factor = pow(10, Double(places))
                    var style = value.style ?? Number(value: 0, usesComma: true)
                    style.decimals = max(0, places)
                    return Value(number: (value.number * factor).rounded() / factor, style: style)
                }
                let values = try arguments(expressions)
                let numbers = values.map(\.number)
                switch name {
                case "SUM": return Value(number: numbers.reduce(0, +), style: common(values, keepsUnit: true))
                case "AVERAGE":
                    guard !numbers.isEmpty else { throw CalcError.divisionByZero }
                    return Value(number: numbers.reduce(0, +) / Double(numbers.count), style: common(values, keepsUnit: true))
                case "MIN": return Value(number: numbers.min() ?? 0, style: common(values, keepsUnit: true))
                case "MAX": return Value(number: numbers.max() ?? 0, style: common(values, keepsUnit: true))
                case "MEDIAN":
                    guard !numbers.isEmpty else { throw CalcError.value }
                    let sorted = numbers.sorted()
                    let middle = sorted.count / 2
                    let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
                    return Value(number: median, style: common(values, keepsUnit: true))
                case "COUNT": return Value(number: Double(numbers.count), style: nil)
                case "PRODUCT": return Value(number: numbers.reduce(1, *), style: plain(common(values, keepsUnit: false)))
                case "ABS":
                    guard let first = values.first else { throw CalcError.syntax }
                    return Value(number: abs(first.number), style: first.style)
                case "SQRT":
                    guard let first = values.first, first.number >= 0 else { throw CalcError.value }
                    return Value(number: first.number.squareRoot(), style: plain(first.style))
                default: throw CalcError.syntax
                }
            }
        }

        /// How a result made of these values is written: the most decimals, a comma if any has one, their unit when
        /// they share it (and the operation keeps it).
        func common(_ values: [Value], keepsUnit: Bool) -> Number? {
            let styles = values.compactMap(\.style)
            guard var style = styles.first else { return nil }
            style.decimals = styles.map(\.decimals).max() ?? 0
            style.usesComma = styles.contains(where: \.usesComma) || !styles.contains { $0.decimals > 0 && !$0.usesComma }
            style.grouped = styles.contains(where: \.grouped)
            if !keepsUnit || Set(styles.map(\.unit)).count > 1 {
                style.unit = ""
            }
            return style
        }

        func plain(_ style: Number?) -> Number? {
            guard var style else { return nil }
            style.unit = ""
            return style
        }
    }

    // MARK: Moving references

    /// The formula after a row or column was put in at `index` (`delta` 1) or taken out (`delta` -1): references
    /// behind it move, a range over it grows or shrinks; a reference to a cell that went is an error.
    static func shifting(_ formula: String, at index: Int, isRow: Bool, delta: Int) -> String {
        rewriteReferences(formula) { reference, isRangeEnd in
            var reference = reference
            let position = isRow ? reference.row : reference.column
            if delta > 0 {
                if position >= index { if isRow { reference.row += 1 } else { reference.column += 1 } }
            } else if position > index {
                if isRow { reference.row -= 1 } else { reference.column -= 1 }
            } else if position == index {
                // A range's end that went moves to the cell before it; a single cell that went is lost.
                guard let isRangeEnd else { return nil }
                if isRangeEnd, position > 0 { if isRow { reference.row -= 1 } else { reference.column -= 1 } }
            }
            return reference
        }
    }

    /// The formula with every reference in row `from` pointing to row `to` (a row that was sorted to another place).
    static func movingRow(_ formula: String, from: Int, to: Int) -> String {
        rewriteReferences(formula) { reference, _ in
            reference.row == from ? Reference(row: to, column: reference.column) : reference
        }
    }

    /// The rows a formula reads from (also through ranges).
    static func referencedRows(_ formula: String) -> Set<Int> {
        var rows = Set<Int>()
        var rangeStart: Reference?
        _ = rewriteReferences(formula) { reference, isRangeEnd in
            if isRangeEnd == false { rangeStart = reference }
            if isRangeEnd == true, let start = rangeStart {
                for row in min(start.row, reference.row)...max(start.row, reference.row) { rows.insert(row) }
            } else {
                rows.insert(reference.row)
            }
            return reference
        }
        return rows
    }

    /// Calls `change` for each cell reference (`isRangeEnd`: nil alone, false the start of a range, true its end) and
    /// puts the result in its place; nil writes `#BEZUG!`.
    private static func rewriteReferences(_ formula: String, _ change: (Reference, Bool?) -> Reference?) -> String {
        let pattern = #"(?<![A-Za-z0-9_$])(\$?)([A-Za-z]{1,3})(\$?)([0-9]{1,5})(?![A-Za-z0-9_(])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return formula }
        let text = formula as NSString
        let matches = expression.matches(in: formula, range: NSRange(location: 0, length: text.length))
        var output = ""
        var last = 0
        for match in matches {
            let letters = text.substring(with: match.range(at: 2))
            guard let column = column(named: letters), let row = Int(text.substring(with: match.range(at: 4))), row >= 1 else { continue }
            let before = text.substring(with: NSRange(location: last, length: match.range.location - last))
            output += before
            // A range: "A1:B3"; the colon stands right before or after.
            let isEnd = match.range.location > 0 && text.substring(with: NSRange(location: match.range.location - 1, length: 1)) == ":"
            let isStart = NSMaxRange(match.range) < text.length && text.substring(with: NSRange(location: NSMaxRange(match.range), length: 1)) == ":"
            let role: Bool? = isEnd ? true : isStart ? false : nil
            if let moved = change(Reference(row: row - 1, column: column), role) {
                output += text.substring(with: match.range(at: 1)) + columnName(moved.column) + text.substring(with: match.range(at: 3)) + String(moved.row + 1)
            } else {
                output += CalcError.reference.display
            }
            last = NSMaxRange(match.range)
        }
        output += text.substring(from: last)
        return output
    }

    // MARK: Sorting

    /// How rows compare by one column's text: numbers by value, other text alphabetically; empty cells go last.
    static func ascending(_ a: String, _ b: String) -> Bool? {
        let left = a.trimmingCharacters(in: .whitespaces), right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty != right.isEmpty { return !left.isEmpty }
        if left.isEmpty { return nil }
        if let x = number(in: left)?.value, let y = number(in: right)?.value {
            return x == y ? nil : x < y
        }
        let order = left.localizedStandardCompare(right)
        return order == .orderedSame ? nil : order == .orderedAscending
    }
}
