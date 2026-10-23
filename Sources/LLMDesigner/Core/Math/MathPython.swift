import Foundation

/// A formula as Python code, ready for a code block.
struct PythonCode: Equatable {
    var text: String
    /// The functions it defines, in order.
    var functions: [String]
}

enum MathPythonError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): "Diese Formel lässt sich nicht in Python übersetzen: \(reason)"
        }
    }
}

/// Translates a formula into readable Python: one function per equation, named like the left side, with the free
/// letters as parameters. Sums, products, integrals (scipy's `quad`), piecewise functions and ± are understood. The
/// formula's text only appears in the docstring, never as code, so anything not understood is an error.
///
/// What a line means: `f(x) = …` defines `f`; `E = m c^2` defines `E` with `m` and `c` as parameters; several such lines
/// become the steps of one function (each result that a later line doesn't read is returned); `x^2 + y^2 = 1` becomes
/// a function that returns the left side minus the right; `x \le 3` returns whether it holds; a bare expression
/// becomes `formel(…)`.
enum MathPythonTranslator {
    static func translate(latex: String) throws -> PythonCode {
        let formula = MathFormula(latex: latex)
        var generator = PyGenerator()
        var any = false
        for line in formula.lines where !line.isEmpty {
            let written = line.items.filter { $0.kind != .symbol("&") }
            let nodes = PlotTranslator.normalized(written)
            guard !nodes.isEmpty else { continue }
            any = true
            try generator.add(nodes, latex: MathLaTeXWriter(caret: nil, placeholders: false).row(MathRow(written.map { $0.copy() })))
        }
        guard any else { throw MathPythonError.unsupported("Die Formel ist leer.") }
        return try generator.finish()
    }

    // MARK: Names

    private static let reserved: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
        "pass", "raise", "return", "try", "while", "with", "yield", "math", "quad", "sum", "max", "min", "abs", "round", "len",
        "range", "int", "float", "str", "list", "dict", "set", "tuple", "type", "id", "input", "print", "pow", "all", "any",
    ]

    /// A Python name from a formula's: Greek letters without the backslash, only ASCII letters, digits and "_".
    static func identifier(_ name: String) -> String {
        var text = ""
        for character in name where character != "\\" {
            text.append(character.isASCII && (character.isLetter || character.isNumber) ? character : "_")
        }
        while text.contains("__") { text = text.replacingOccurrences(of: "__", with: "_") }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if text.isEmpty { text = "x" }
        if text.first?.isNumber == true { text = "x_" + text }
        return reserved.contains(text) ? text + "_" : text
    }

    /// A subscript as part of a name: letters, digits and commas (`x_{1,2}`).
    static func subscriptName(_ row: MathRow) -> String? {
        var text = ""
        for node in row.items {
            guard case .symbol(let token) = node.kind else { return nil }
            if token == "," { text += "_" } else if token.hasPrefix("\\") { text += String(token.dropFirst()) } else { text += token }
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return text
    }
}

// MARK: - Terms

/// A piece of an expression and how tightly it binds: 0 comparison, 1 sum, 2 product, 3 sign, 4 power, 5 atom.
fileprivate struct PyExpr {
    var text: String
    var level: Int

    static func atom(_ text: String) -> PyExpr { PyExpr(text: text, level: 5) }

    func wrapped(below level: Int) -> String { self.level < level ? "(\(text))" : text }
}

fileprivate enum PyPiece {
    case operand(PyExpr)
    case operation(String)
}

/// What the translator knows while it reads one function.
fileprivate final class PyScope {
    var parameters: [String] = []
    /// Letters assigned in earlier lines of the same function (their Python names).
    var locals: [String: String] = [:]
    /// Functions from earlier lines.
    var functions: [String: (python: String, arity: Int)] = [:]
    var bound: [String: String] = [:]
    var imports: Set<String> = []
    /// ± reads as + in the first variant and as − in the second.
    var minusVariant = false
    var usesPlusMinus = false

    func parameter(_ python: String) {
        if !parameters.contains(python) { parameters.append(python) }
    }
}

fileprivate struct PyReader {
    let scope: PyScope

    static let ignored: Set<String> = ["\\,", "\\;", "\\:", "\\!", "\\quad", "\\qquad", "&", "\\left.", "\\right."]
    static let relations: Set<String> = ["=", "<", ">", "\\le", "\\leq", "\\leqslant", "\\ge", "\\geq", "\\geqslant", "\\neq", "\\ne"]
    static let comparisons: [String: String] = [
        "<": "<", ">": ">", "\\le": "<=", "\\leq": "<=", "\\leqslant": "<=", "\\ge": ">=", "\\geq": ">=", "\\geqslant": ">=",
        "=": "==", "\\neq": "!=", "\\ne": "!=",
    ]
    static let functions: [String: String] = [
        "\\sin": "math.sin", "\\cos": "math.cos", "\\tan": "math.tan", "\\arcsin": "math.asin", "\\arccos": "math.acos",
        "\\arctan": "math.atan", "\\sinh": "math.sinh", "\\cosh": "math.cosh", "\\tanh": "math.tanh", "\\ln": "math.log",
        "\\lg": "math.log10", "\\log": "math.log10", "\\exp": "math.exp", "\\operatorname{arsinh}": "math.asinh",
        "\\operatorname{arcosh}": "math.acosh", "\\operatorname{artanh}": "math.atanh", "\\gcd": "math.gcd",
        "\\operatorname{gcd}": "math.gcd", "\\operatorname{lcm}": "math.lcm",
    ]
    static let reciprocal: [String: String] = ["\\cot": "math.tan", "\\sec": "math.cos", "\\csc": "math.sin", "\\coth": "math.tanh"]

    func expression(_ items: [MathNode]) throws -> PyExpr {
        var pieces: [PyPiece] = []
        func operand(_ expr: PyExpr) {
            if case .operand = pieces.last { pieces.append(.operation("*")) }
            pieces.append(.operand(expr))
        }
        var index = 0
        while index < items.count {
            let node = items[index]
            switch node.kind {
            case .symbol(let token):
                if token.first?.isNumber == true || token == "." {
                    var literal = ""
                    while index < items.count, case .symbol(let digit) = items[index].kind {
                        if digit.first?.isNumber == true { literal += digit }
                        else if (digit == "." || digit == ","), index + 1 < items.count, case .symbol(let next) = items[index + 1].kind,
                                next.first?.isNumber == true, !literal.contains(".") { literal += "." }
                        else { break }
                        index += 1
                    }
                    guard Double(literal) != nil else { throw MathPythonError.unsupported("„\(literal)“ ist keine Zahl.") }
                    operand(.atom(literal))
                    continue
                }
                switch token {
                case "+", "-": pieces.append(.operation(token))
                case "\\cdot", "\\times", "*": pieces.append(.operation("*"))
                case "/", "\\div": pieces.append(.operation("/"))
                case "\\pm", "\\mp":
                    scope.usesPlusMinus = true
                    let minus = (token == "\\pm") == scope.minusVariant
                    pieces.append(.operation(minus ? "-" : "+"))
                case "(", "[":
                    let close = token == "(" ? ")" : "]"
                    guard let end = matching(items, from: index, open: token, close: close) else {
                        throw MathPythonError.unsupported("Eine Klammer ist nicht geschlossen.")
                    }
                    operand(.atom("(" + (try expression(Array(items[(index + 1)..<end]))).text + ")"))
                    index = end
                case "|":
                    guard let end = items[(index + 1)...].firstIndex(where: { $0.kind == .symbol("|") }) else {
                        throw MathPythonError.unsupported("Ein Betragsstrich ist nicht geschlossen.")
                    }
                    operand(.atom("abs(" + (try expression(Array(items[(index + 1)..<end]))).text + ")"))
                    index = end
                case _ where Self.ignored.contains(token): break
                case "!":
                    guard case .operand(let base) = pieces.last else { throw MathPythonError.unsupported("Ein ! ohne Zahl davor.") }
                    scope.imports.insert("import math")
                    pieces[pieces.count - 1] = .operand(.atom("math.factorial(\(base.text))"))
                case "'", "\\prime": throw MathPythonError.unsupported("Ableitungen (f') werden nicht in Code übersetzt.")
                case "\\infty":
                    scope.imports.insert("import math")
                    operand(.atom("math.inf"))
                case "\\pi":
                    scope.imports.insert("import math")
                    operand(.atom("math.pi"))
                default:
                    let isGreek = MathSymbols.greek.contains(token)
                    guard (token.count == 1 && token.first!.isLetter && token.first!.isASCII) || isGreek else {
                        throw MathPythonError.unsupported("„\(token)“ kann nicht gerechnet werden.")
                    }
                    // A subscript is part of the name: a_1, f_2.
                    var key = token
                    var next = index + 1
                    var power: MathRow?
                    if next < items.count, let sub = items[next].subscript {
                        guard let suffix = MathPythonTranslator.subscriptName(sub) else {
                            throw MathPythonError.unsupported("Ein Index taugt nicht als Name.")
                        }
                        key += "_" + suffix
                        power = items[next].superscript
                        next += 1
                    } else if token == "e", next < items.count, items[next].superscript != nil {
                        // e^x is Euler's number; a bare e is a letter.
                        scope.imports.insert("import math")
                        operand(.atom("math.e"))
                        index += 1
                        continue
                    }
                    if let function = scope.functions[key] {
                        operand(try call(function, items, from: &next))
                        index = next
                        continue
                    }
                    let python = resolve(key)
                    if let power {
                        operand(PyExpr(text: "\(python) ** \(try expression(power.items).wrapped(below: 5))", level: 4))
                    } else {
                        operand(.atom(python))
                    }
                    index = next
                    continue
                }
            case .function(let name):
                var power: PyExpr?
                var base: PyExpr?
                if index + 1 < items.count, items[index + 1].isScripts {
                    if let sup = items[index + 1].superscript { power = try expression(sup.items) }
                    if let sub = items[index + 1].subscript { base = try expression(sub.items) }
                    index += 1
                }
                let (arguments, last) = try self.arguments(items, after: index)
                index = last
                var result = try functionCall(name, arguments, base: base)
                if let power { result = PyExpr(text: "\(result.wrapped(below: 5)) ** \(power.wrapped(below: 5))", level: 4) }
                operand(result)
            case .largeOperator(let name):
                switch name {
                case "\\sum", "\\prod":
                    operand(try bigOperator(name, items, at: &index))
                    continue
                case "\\int":
                    operand(try integral(items, at: &index))
                    continue
                case "\\max", "\\min":
                    guard index + 1 < items.count, case .group = items[index + 1].kind else {
                        throw MathPythonError.unsupported("max und min brauchen ihre Werte in Klammern: \\max(a, b).")
                    }
                    let values = try PlotTranslator.splitArguments(items[index + 1].slots[0].items).map { try expression($0).text }
                    guard values.count >= 2 else { throw MathPythonError.unsupported("max und min brauchen mindestens zwei Werte.") }
                    operand(.atom("\(name == "\\max" ? "max" : "min")(\(values.joined(separator: ", ")))"))
                    index += 1
                default:
                    throw MathPythonError.unsupported("Grenzwerte und Mehrfachintegrale werden nicht übersetzt.")
                }
            case .fraction:
                let numerator = try expression(node.slots[0].items)
                let denominator = try expression(node.slots[1].items)
                operand(PyExpr(text: "\(numerator.wrapped(below: 2)) / \(denominator.wrapped(below: 3))", level: 2))
            case .binomial:
                scope.imports.insert("import math")
                operand(.atom("math.comb(\(try expression(node.slots[0].items).text), \(try expression(node.slots[1].items).text))"))
            case .root:
                scope.imports.insert("import math")
                operand(.atom("math.sqrt(\(try expression(node.slots[0].items).text))"))
            case .nthRoot:
                let degree = try expression(node.slots[0].items)
                let radicand = try expression(node.slots[1].items)
                if let value = Double(degree.text), value == value.rounded(), Int(value) % 2 == 1 {
                    // An odd root of a negative number is negative, which `**` doesn't give.
                    scope.imports.insert("import math")
                    operand(.atom("math.copysign(abs(\(radicand.text)) ** (1 / \(degree.text)), \(radicand.text))"))
                } else {
                    operand(PyExpr(text: "\(radicand.wrapped(below: 5)) ** (1 / \(degree.wrapped(below: 3)))", level: 4))
                }
            case .scripts:
                guard let sup = node.superscript else { throw MathPythonError.unsupported("Ein Index ohne Bedeutung zum Rechnen.") }
                guard case .operand(let base) = pieces.last else { throw MathPythonError.unsupported("Eine Hochzahl ohne Basis.") }
                let exponent = try expression(sup.items)
                pieces[pieces.count - 1] = .operand(PyExpr(text: "\(base.wrapped(below: 5)) ** \(exponent.wrapped(below: 5))", level: 4))
            case .group(let left, _):
                if PlotTranslator.splitArguments(node.slots[0].items).count > 1, left == "(" || left == "[" {
                    throw MathPythonError.unsupported("Ein Vektor oder ein Zahlenpaar lässt sich nicht als Zahl rechnen.")
                }
                let inner = try expression(node.slots[0].items)
                switch left {
                case "|", "\\|", "\\vert", "\\Vert", "\\lvert": operand(.atom("abs(\(inner.text))"))
                case "\\lfloor":
                    scope.imports.insert("import math")
                    operand(.atom("math.floor(\(inner.text))"))
                case "\\lceil":
                    scope.imports.insert("import math")
                    operand(.atom("math.ceil(\(inner.text))"))
                default: operand(.atom("(\(inner.text))"))
                }
            case .matrix(let environment, let rows, let columns) where environment == "cases":
                operand(.atom("(" + (try cases(node, rows: rows, columns: columns)) + ")"))
            case .style(let name) where ["\\mathrm", "\\text", "\\textrm"].contains(name) && node.slots[0].items.count == 1 && node.slots[0].items[0].kind == .symbol("e"):
                scope.imports.insert("import math")
                operand(.atom("math.e"))
            case .accent, .style, .text, .matrix, .raw:
                throw MathPythonError.unsupported("Matrizen, Vektoren, Text und Akzente werden nicht übersetzt.")
            }
            index += 1
        }
        return try fold(pieces)
    }

    // MARK: Precedence

    /// Sums of products of operands; unary signs bind to the operand after them.
    private func fold(_ pieces: [PyPiece]) throws -> PyExpr {
        var index = 0

        func factor() throws -> PyExpr {
            guard index < pieces.count else { throw MathPythonError.unsupported("Die Formel ist unvollständig.") }
            switch pieces[index] {
            case .operation(let symbol) where symbol == "-":
                index += 1
                let inner = try factor()
                return PyExpr(text: "-" + inner.wrapped(below: 4), level: 3)
            case .operation(let symbol) where symbol == "+":
                index += 1
                return try factor()
            case .operation:
                throw MathPythonError.unsupported("Die Formel ist unvollständig.")
            case .operand(let expr):
                index += 1
                return expr
            }
        }
        func term() throws -> PyExpr {
            var left = try factor()
            while index < pieces.count, case .operation(let symbol) = pieces[index], symbol == "*" || symbol == "/" {
                index += 1
                let right = try factor()
                left = PyExpr(text: "\(left.wrapped(below: 2)) \(symbol) \(right.wrapped(below: 3))", level: 2)
            }
            return left
        }
        guard !pieces.isEmpty else { throw MathPythonError.unsupported("Ein Teil der Formel ist leer.") }
        var result = try term()
        while index < pieces.count, case .operation(let symbol) = pieces[index], symbol == "+" || symbol == "-" {
            index += 1
            let right = try term()
            result = PyExpr(text: "\(result.text) \(symbol) \(right.text)", level: 1)
        }
        guard index == pieces.count else { throw MathPythonError.unsupported("Die Formel ist nicht eindeutig.") }
        return result
    }

    // MARK: Pieces

    /// A letter that isn't a function: a bound index, an earlier result, or a parameter.
    private func resolve(_ key: String) -> String {
        if let bound = scope.bound[key] { return bound }
        if let local = scope.locals[key] { return local }
        let python = MathPythonTranslator.identifier(key)
        scope.parameter(python)
        return python
    }

    private func functionCall(_ name: String, _ arguments: [PyExpr], base: PyExpr?) throws -> PyExpr {
        guard !arguments.isEmpty else { throw MathPythonError.unsupported("Einer Funktion fehlt ihr Argument.") }
        let joined = arguments.map(\.text).joined(separator: ", ")
        switch name {
        case "\\operatorname{abs}": return .atom("abs(\(joined))")
        case "\\operatorname{sgn}", "\\operatorname{sign}":
            let value = arguments[0].wrapped(below: 2)
            return .atom("((\(value) > 0) - (\(value) < 0))")
        default: break
        }
        if let function = Self.functions[name] {
            scope.imports.insert("import math")
            if name == "\\log", let base { return .atom("math.log(\(joined), \(base.text))") }
            return .atom("\(function)(\(joined))")
        }
        if let function = Self.reciprocal[name] {
            scope.imports.insert("import math")
            return PyExpr(text: "1 / \(function)(\(joined))", level: 2)
        }
        throw MathPythonError.unsupported("„\(name)“ wird nicht übersetzt.")
    }

    /// `f(x - 1)`, `g(x, 2)` for a function from an earlier line.
    private func call(_ function: (python: String, arity: Int), _ items: [MathNode], from next: inout Int) throws -> PyExpr {
        guard next < items.count, case .group(let open, _) = items[next].kind, open == "(" else {
            throw MathPythonError.unsupported("„\(function.python)“ braucht ein Argument, z. B. \(function.python)(x).")
        }
        let arguments = try PlotTranslator.splitArguments(items[next].slots[0].items).map { try expression($0).text }
        guard arguments.count == function.arity else {
            throw MathPythonError.unsupported("„\(function.python)“ hat \(function.arity) Variable\(function.arity == 1 ? "" : "n").")
        }
        next += 1
        return .atom("\(function.python)(\(arguments.joined(separator: ", ")))")
    }

    /// A function's argument(s): a bracket right after it, else everything up to the next + or − (or function).
    private func arguments(_ items: [MathNode], after index: Int) throws -> ([PyExpr], Int) {
        let start = index + 1
        guard start < items.count else { throw MathPythonError.unsupported("Einer Funktion fehlt ihr Argument.") }
        if case .group = items[start].kind {
            return (try PlotTranslator.splitArguments(items[start].slots[0].items).map { try expression($0) }, start)
        }
        if items[start].kind == .symbol("("), let end = matching(items, from: start, open: "(", close: ")") {
            return (try PlotTranslator.splitArguments(Array(items[(start + 1)..<end])).map { try expression($0) }, end)
        }
        var end = start
        while end < items.count {
            if case .symbol(let token) = items[end].kind, MathSymbols.operators.contains(token) { break }
            if case .function = items[end].kind, end > start { break }
            end += 1
        }
        guard end > start else { throw MathPythonError.unsupported("Einer Funktion fehlt ihr Argument.") }
        return ([try expression(Array(items[start..<end]))], end - 1)
    }

    /// `\sum_{k=1}^{n} …` or `\prod`: the term runs to the next + or −.
    private func bigOperator(_ name: String, _ items: [MathNode], at index: inout Int) throws -> PyExpr {
        guard index + 1 < items.count, let sub = items[index + 1].subscript, let sup = items[index + 1].superscript else {
            throw MathPythonError.unsupported("Summen und Produkte brauchen Grenzen, z. B. k = 1 bis n.")
        }
        let lowerItems = sub.items
        guard lowerItems.count >= 3, case .symbol(let variable) = lowerItems[0].kind, PlotTranslator.isLetter(variable),
              lowerItems[1].kind == .symbol("=") else {
            throw MathPythonError.unsupported("Unter dem Summenzeichen steht der Laufindex mit Start, z. B. k = 1.")
        }
        let lower = try expression(Array(lowerItems[2...]))
        let upper = try expression(sup.items)
        guard !upper.text.contains("math.inf") else { throw MathPythonError.unsupported("Unendliche Summen lassen sich nicht ausrechnen.") }
        var end = index + 2
        while end < items.count {
            if case .symbol(let token) = items[end].kind, token == "+" || token == "-" { break }
            end += 1
        }
        guard end > index + 2 else { throw MathPythonError.unsupported("Der Summe fehlt ihr Term.") }
        let python = MathPythonTranslator.identifier(variable)
        let saved = scope.bound[variable]
        scope.bound[variable] = python
        defer { scope.bound[variable] = saved }
        let term = try expression(Array(items[(index + 2)..<end]))
        index = end
        let range = "range(\(lower.text), \(upper.wrapped(below: 2)) + 1)"
        if name == "\\sum" { return .atom("sum(\(term.text) for \(python) in \(range))") }
        scope.imports.insert("import math")
        return .atom("math.prod(\(term.text) for \(python) in \(range))")
    }

    /// `\int_a^b … dt` with scipy's `quad`.
    private func integral(_ items: [MathNode], at index: inout Int) throws -> PyExpr {
        guard index + 1 < items.count, let sub = items[index + 1].subscript, let sup = items[index + 1].superscript else {
            throw MathPythonError.unsupported("Ein Integral braucht Grenzen, z. B. von 0 bis x.")
        }
        let lower = try expression(sub.items)
        let upper = try expression(sup.items)
        var position = index + 2
        var differential: (index: Int, variable: String)?
        while position + 1 < items.count {
            if Self.isDifferential(items[position]), case .symbol(let variable) = items[position + 1].kind, PlotTranslator.isLetter(variable) {
                differential = (position, variable)
                break
            }
            position += 1
        }
        guard let differential else { throw MathPythonError.unsupported("Am Ende des Integrals fehlt das d mit der Variablen, z. B. dt.") }
        let term = items[(index + 2)..<differential.index].filter { node in
            if case .symbol(let token) = node.kind { return !Self.ignored.contains(token) }
            return true
        }
        guard !term.isEmpty else { throw MathPythonError.unsupported("Dem Integral fehlt sein Term.") }
        let python = MathPythonTranslator.identifier(differential.variable)
        let saved = scope.bound[differential.variable]
        scope.bound[differential.variable] = python
        defer { scope.bound[differential.variable] = saved }
        let integrand = try expression(Array(term))
        index = differential.index + 2
        scope.imports.insert("from scipy.integrate import quad")
        return .atom("quad(lambda \(python): \(integrand.text), \(lower.text), \(upper.text))[0]")
    }

    private static func isDifferential(_ node: MathNode) -> Bool {
        switch node.kind {
        case .symbol(let token): return token == "d"
        case .style, .text: return node.slots.first?.items.count == 1 && node.slots[0].items[0].kind == .symbol("d")
        case .function(let name): return name == "\\operatorname{d}"
        default: return false
        }
    }

    /// A piecewise function: each row a value and its condition; the row without one is the else.
    private func cases(_ node: MathNode, rows: Int, columns: Int) throws -> String {
        var branches: [(value: String, condition: String?)] = []
        for row in 0..<rows {
            let value = node.slots[row * columns].items.filter { $0.kind != .symbol(",") }
            let condition = columns > 1 ? node.slots[row * columns + 1].items : []
            guard !value.isEmpty else { continue }
            branches.append((try expression(value).text, try self.condition(condition)))
        }
        guard !branches.isEmpty else { throw MathPythonError.unsupported("Die Fallunterscheidung ist leer.") }
        // The row without a condition ends the chain; without one the result is "not a number".
        var result = branches.last(where: { $0.condition == nil })?.value ?? "float('nan')"
        for branch in branches.reversed() {
            guard let condition = branch.condition else { continue }
            result = "\(branch.value) if \(condition) else \(result)"
        }
        return result
    }

    /// `x < 0`, `0 \le x < 1` as a Python condition; words (`\text{für}`, `\text{sonst}`) are left out; none: nil.
    func condition(_ items: [MathNode]) throws -> String? {
        let items = items.filter { node in
            switch node.kind {
            case .text: return false
            case .symbol(let token): return token != "," && !Self.ignored.contains(token)
            default: return true
            }
        }
        guard !items.isEmpty else { return nil }
        var pieces: [[MathNode]] = [[]]
        var operators: [String] = []
        for node in items {
            if case .symbol(let token) = node.kind, let comparison = Self.comparisons[token] {
                operators.append(comparison)
                pieces.append([])
            } else {
                pieces[pieces.count - 1].append(node)
            }
        }
        guard !operators.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
            throw MathPythonError.unsupported("Bedingungen schreiben sich wie x < 0 oder 0 \\le x < 1.")
        }
        let terms = try pieces.map { try expression($0).wrapped(below: 1) }
        var text = terms[0]
        for (number, symbol) in operators.enumerated() { text += " \(symbol) \(terms[number + 1])" }
        return text
    }

    private func matching(_ items: [MathNode], from index: Int, open: String, close: String) -> Int? {
        var depth = 0
        for position in index..<items.count {
            if items[position].kind == .symbol(open) { depth += 1 }
            if items[position].kind == .symbol(close) {
                depth -= 1
                if depth == 0 { return position }
            }
        }
        return nil
    }
}

// MARK: - Lines and functions

fileprivate enum PyLine {
    /// `f(x) = …`
    case definition(name: String, arguments: [String], right: [MathNode], latex: String)
    /// `E = …`: a letter on the left.
    case assignment(name: String, right: [MathNode], latex: String)
    /// `x^2 + y^2 = 1`
    case equation(left: [MathNode], right: [MathNode], latex: String)
    /// `x \le 3`
    case comparison(nodes: [MathNode], latex: String)
    case expression(nodes: [MathNode], latex: String)
}

fileprivate struct PyGenerator {
    var imports: Set<String> = []
    /// Finished top-level functions in order.
    var functions: [String] = []
    var functionNames: [String] = []
    /// Function definitions that later lines may call.
    var known: [String: (python: String, arity: Int)] = [:]
    /// Plain assignments waiting to become one function.
    var steps: [PyLine] = []

    mutating func add(_ nodes: [MathNode], latex: String) throws {
        let line = try Self.classify(nodes, latex: latex)
        switch line {
        case .definition(let name, let arguments, let right, let latex):
            try flushSteps()
            let scope = PyScope()
            scope.functions = known
            for argument in arguments { scope.parameter(MathPythonTranslator.identifier(argument)) }
            let python = MathPythonTranslator.identifier(name)
            let result = try expressions(of: right, scope: scope)
            emit(name: python, scope: scope, docstring: [latex], statements: [], returns: result.joined(separator: ", "))
            known[name] = (python, arguments.count)
        case .assignment:
            steps.append(line)
        default:
            try flushSteps()
            try single(line)
        }
    }

    mutating func finish() throws -> PythonCode {
        try flushSteps()
        // `import …` first, then `from … import …`.
        let header = imports.sorted { lhs, rhs in
            let left = (lhs.hasPrefix("import") ? 0 : 1, lhs), right = (rhs.hasPrefix("import") ? 0 : 1, rhs)
            return left < right
        }
        let text = (header.isEmpty ? "" : header.joined(separator: "\n") + "\n\n\n") + functions.joined(separator: "\n\n\n")
        return PythonCode(text: text, functions: functionNames)
    }

    // MARK: Classifying

    private static func classify(_ nodes: [MathNode], latex: String) throws -> PyLine {
        var pieces: [[MathNode]] = [[]]
        var operators: [String] = []
        for node in nodes {
            if case .symbol(let token) = node.kind, PyReader.relations.contains(token) {
                operators.append(token)
                pieces.append([])
            } else {
                pieces[pieces.count - 1].append(node)
            }
        }
        guard !operators.isEmpty else { return .expression(nodes: nodes, latex: latex) }
        guard pieces.allSatisfy({ !$0.isEmpty }) else { throw MathPythonError.unsupported("Die Formel ist unvollständig.") }
        guard operators.allSatisfy({ $0 == "=" }) else { return .comparison(nodes: nodes, latex: latex) }
        // f(x) = … = …: the left of the first and the right of the last.
        let left = pieces[0]
        let right = pieces.last ?? []
        if let declaration = PlotTranslator.declaration(left), let name = declaration.name {
            return .definition(name: name, arguments: declaration.arguments, right: right, latex: latex)
        }
        if let name = assignedName(left) { return .assignment(name: name, right: right, latex: latex) }
        return .equation(left: left, right: right, latex: latex)
    }

    /// `E`, `x_1`, `x_{1,2}`, `\Delta`: a name that can be assigned.
    private static func assignedName(_ left: [MathNode]) -> String? {
        guard let first = left.first, case .symbol(let token) = first.kind, PlotTranslator.isLetter(token) else { return nil }
        if left.count == 1 { return token }
        guard left.count == 2, let sub = left[1].subscript, left[1].superscript == nil,
              let suffix = MathPythonTranslator.subscriptName(sub) else { return nil }
        return token + "_" + suffix
    }

    // MARK: Reading

    /// The Python expression of a right side, or two (the ± variants).
    private mutating func expressions(of right: [MathNode], scope: PyScope) throws -> [String] {
        scope.usesPlusMinus = false
        scope.minusVariant = false
        let reader = PyReader(scope: scope)
        let first = try reader.expression(right)
        var results = [first.text]
        if scope.usesPlusMinus {
            scope.minusVariant = true
            results.append(try reader.expression(right).text)
            scope.minusVariant = false
        }
        imports.formUnion(scope.imports)
        return results
    }

    private mutating func single(_ line: PyLine) throws {
        let scope = PyScope()
        scope.functions = known
        switch line {
        case .equation(let left, let right, let latex):
            let reader = PyReader(scope: scope)
            let lhs = try reader.expression(left)
            let rhs = try reader.expression(right)
            emit(name: "gleichung", scope: scope,
                 docstring: [latex, "Gibt die linke Seite minus die rechte zurück: 0, wenn die Gleichung gilt."],
                 statements: [], returns: "\(lhs.text) - \(rhs.wrapped(below: 2))")
        case .comparison(let nodes, let latex):
            let reader = PyReader(scope: scope)
            guard let condition = try reader.condition(nodes) else { throw MathPythonError.unsupported("Die Aussage ist leer.") }
            emit(name: "bedingung", scope: scope, docstring: [latex, "Gibt zurück, ob die Aussage gilt."], statements: [], returns: condition)
        case .expression(let nodes, let latex):
            let result = try expressions(of: nodes, scope: scope)
            emit(name: "formel", scope: scope, docstring: [latex], statements: [], returns: result.joined(separator: ", "))
        default:
            break
        }
    }

    /// The collected assignments as one function: one statement each, returning what no later statement reads.
    private mutating func flushSteps() throws {
        guard !steps.isEmpty else { return }
        let lines = steps
        steps = []
        let scope = PyScope()
        scope.functions = known
        var statements: [(python: String, expression: String)] = []
        var docstring: [String] = []
        for line in lines {
            guard case .assignment(let name, let right, let latex) = line else { continue }
            docstring.append(latex)
            let python = MathPythonTranslator.identifier(name)
            let results = try expressions(of: right, scope: scope)
            if results.count == 2 {
                // x = (-b ± …) / …: two results, x_1 and x_2.
                let names = Self.pairNames(python)
                statements.append((names.0, results[0]))
                statements.append((names.1, results[1]))
                scope.locals[name] = names.0
            } else {
                statements.append((python, results[0]))
                scope.locals[name] = python
            }
        }
        var outputs: [String] = []
        for (index, statement) in statements.enumerated() {
            let readLater = statements.dropFirst(index + 1).contains { Self.reads($0.expression, name: statement.python) }
            if !readLater { outputs.append(statement.python) }
        }
        if outputs.isEmpty, let last = statements.last { outputs = [last.python] }

        if statements.count == 1, let only = statements.first {
            // One assignment is just a return.
            emit(name: only.python, scope: scope, docstring: docstring, statements: [], returns: only.expression)
        } else if lines.count == 1, statements.count == 2 {
            // One line with ±: a function with two results.
            emit(name: Self.pairBase(statements[0].python), scope: scope, docstring: docstring, statements: [],
                 returns: statements.map(\.expression).joined(separator: ", "))
        } else {
            let name = outputs.count == 1 ? outputs[0] : (statements.last?.python ?? "ergebnis")
            emit(name: name, scope: scope, docstring: docstring,
                 statements: statements.map { "\($0.python) = \($0.expression)" }, returns: outputs.joined(separator: ", "))
        }
    }

    /// x → (x_1, x_2); x_1_2 → (x_1, x_2); otherwise name_plus, name_minus.
    private static func pairNames(_ python: String) -> (String, String) {
        if python.hasSuffix("_1_2") {
            let base = String(python.dropLast(4))
            return (base + "_1", base + "_2")
        }
        return (python + "_plus", python + "_minus")
    }

    private static func pairBase(_ python: String) -> String {
        if python.hasSuffix("_plus") { return String(python.dropLast(5)) }
        if python.hasSuffix("_1") { return String(python.dropLast(2)) }
        return python
    }

    private static func reads(_ expression: String, name: String) -> Bool {
        expression.range(of: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])", options: .regularExpression) != nil
    }

    /// Writes the function. Parameters are the free letters in the order they appeared.
    private mutating func emit(name: String, scope: PyScope, docstring: [String], statements: [String], returns: String) {
        var lines = ["def \(name)(\(scope.parameters.joined(separator: ", "))):"]
        let safe = docstring.map { text -> String in
            var line = text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
            while line.hasSuffix("\\") { line.removeLast() }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if safe.count == 1 {
            lines.append("    r\"\"\"\(safe[0])\"\"\"")
        } else if !safe.isEmpty {
            lines.append("    r\"\"\"")
            lines += safe.map { "    " + $0 }
            lines.append("    \"\"\"")
        }
        lines += statements.map { "    " + $0 }
        lines.append("    return " + returns)
        functions.append(lines.joined(separator: "\n"))
        functionNames.append(name)
        imports.formUnion(scope.imports)
    }
}
