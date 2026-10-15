import Foundation

/// A formula as the visual editor sees it: rows of items, where structures (fractions, roots, scripts, brackets,
/// matrices, …) hold rows of their own. It is stored and drawn as LaTeX; `MathLaTeXParser` reads LaTeX back.
final class MathRow {
    private(set) var items: [MathNode] = []
    weak var parent: MathNode?

    init(_ items: [MathNode] = []) {
        for item in items { append(item) }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    func append(_ node: MathNode) {
        insert(node, at: items.count)
    }

    func insert(_ node: MathNode, at index: Int) {
        node.row = self
        items.insert(node, at: max(0, min(index, items.count)))
    }

    @discardableResult
    func remove(at index: Int) -> MathNode {
        let node = items.remove(at: index)
        node.row = nil
        return node
    }

    func removeSubrange(_ range: Range<Int>) -> [MathNode] {
        let nodes = Array(items[range])
        items.removeSubrange(range)
        nodes.forEach { $0.row = nil }
        return nodes
    }

    func index(of node: MathNode) -> Int? {
        items.firstIndex { $0 === node }
    }

    func copy() -> MathRow {
        MathRow(items.map { $0.copy() })
    }

    /// Rows from the outside in: this row's structure, its row, and so on.
    var depth: Int {
        var depth = 0
        var node = parent
        while let current = node {
            depth += 1
            node = current.row?.parent
        }
        return depth
    }
}

final class MathNode {
    enum Kind: Equatable {
        /// One token: "x", "2", "+", "\\alpha", "\\leq", "&" (alignment).
        case symbol(String)
        /// An operator name: "\\sin", "\\ln", "\\operatorname{sgn}".
        case function(String)
        /// Sums, integrals, limits; their bounds are the scripts after them.
        case largeOperator(String)
        /// [numerator, denominator]
        case fraction
        /// [top, bottom]
        case binomial
        /// [radicand]
        case root
        /// [degree, radicand]
        case nthRoot
        /// [superscript?, subscript?], attached to the item before.
        case scripts(superscript: Bool, subscript: Bool)
        /// [content] between delimiters; "{" "}" are invisible braces.
        case group(left: String, right: String)
        /// "\\vec", "\\hat", "\\overline", … [content]
        case accent(String)
        /// "\\mathbb", "\\mathbf", "\\mathrm", "\\mathcal" [content]
        case style(String)
        /// [content], whose items are single characters.
        case text
        /// Cells row by row.
        case matrix(environment: String, rows: Int, columns: Int)
        /// LaTeX the editor can't take apart; edited only in the source field.
        case raw(String)
    }

    var kind: Kind
    private(set) var slots: [MathRow]
    weak var row: MathRow?

    init(_ kind: Kind, slots: [MathRow] = []) {
        self.kind = kind
        self.slots = []
        for slot in slots { addSlot(slot) }
    }

    static func symbol(_ token: String) -> MathNode { MathNode(.symbol(token)) }

    static func empty(_ kind: Kind, slots count: Int) -> MathNode {
        MathNode(kind, slots: (0..<count).map { _ in MathRow() })
    }

    func addSlot(_ slot: MathRow, at index: Int? = nil) {
        slot.parent = self
        slots.insert(slot, at: index ?? slots.count)
    }

    func copy() -> MathNode {
        MathNode(kind, slots: slots.map { $0.copy() })
    }

    var superscript: MathRow? {
        if case .scripts(let hasSuperscript, _) = kind, hasSuperscript { return slots.first }
        return nil
    }

    var `subscript`: MathRow? {
        if case .scripts(let hasSuperscript, let hasSubscript) = kind, hasSubscript { return slots[hasSuperscript ? 1 : 0] }
        return nil
    }

    var isScripts: Bool {
        if case .scripts = kind { return true }
        return false
    }

    /// Adds the missing script slot and returns it.
    func ensureScript(superscript wantsSuperscript: Bool) -> MathRow {
        guard case .scripts(let hasSuperscript, let hasSubscript) = kind else { return MathRow() }
        if wantsSuperscript {
            if let row = superscript { return row }
            kind = .scripts(superscript: true, subscript: hasSubscript)
            let row = MathRow()
            addSlot(row, at: 0)
            return row
        }
        if let row = self.subscript { return row }
        kind = .scripts(superscript: hasSuperscript, subscript: true)
        let row = MathRow()
        addSlot(row)
        return row
    }

    /// Removes an empty script; the node itself goes away when it has none left (the caller checks `slots`).
    func removeScript(_ slot: MathRow) {
        guard case .scripts(var hasSuperscript, var hasSubscript) = kind, let index = slots.firstIndex(where: { $0 === slot }) else { return }
        if slot === superscript { hasSuperscript = false } else { hasSubscript = false }
        slots.remove(at: index)
        kind = .scripts(superscript: hasSuperscript, subscript: hasSubscript)
    }

    /// The slot the caret enters first from the left and from the right.
    var entrySlotFromLeft: MathRow? {
        switch kind {
        case .nthRoot: return slots.last
        default: return slots.first
        }
    }

    var entrySlotFromRight: MathRow? {
        switch kind {
        case .scripts: return slots.first
        default: return slots.last
        }
    }

    /// Order in which the right arrow walks through the slots.
    var slotOrder: [MathRow] {
        switch kind {
        case .nthRoot: return slots.count == 2 ? [slots[0], slots[1]] : slots
        default: return slots
        }
    }
}

/// A place in a formula: before `index` in `row`.
struct MathCursor {
    var row: MathRow
    var index: Int
}

/// A whole formula: one or more lines (gathered, or aligned at "&").
final class MathFormula {
    var lines: [MathRow]
    var aligned: Bool

    init(lines: [MathRow] = [MathRow()], aligned: Bool = false) {
        self.lines = lines.isEmpty ? [MathRow()] : lines
        self.aligned = aligned
    }

    convenience init(latex: String) {
        if let parsed = MathLaTeXParser.parse(latex) {
            self.init(lines: parsed.lines, aligned: parsed.aligned)
        } else {
            let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(lines: [MathRow(trimmed.isEmpty ? [] : [MathNode(.raw(trimmed))])])
        }
    }

    func copy() -> MathFormula {
        MathFormula(lines: lines.map { $0.copy() }, aligned: aligned)
    }

    var isEmpty: Bool { lines.allSatisfy(\.isEmpty) }

    /// The LaTeX that is stored.
    var latex: String {
        MathLaTeXWriter(caret: nil, placeholders: false).formula(self)
    }

    /// Every caret position in reading order (for clicks and Tab).
    var positions: [MathCursor] {
        var result: [MathCursor] = []
        func walk(_ row: MathRow) {
            for index in 0...row.count {
                result.append(MathCursor(row: row, index: index))
                if index < row.count { row.items[index].slotOrder.forEach(walk) }
            }
        }
        lines.forEach(walk)
        return result
    }
}

// MARK: - Writing LaTeX

/// Turns the tree into LaTeX. For the editor it can mark the caret and show empty slots as grey boxes.
struct MathLaTeXWriter {
    var caret: MathCursor?
    var placeholders: Bool
    var caretColor = "A996FF"
    var placeholderColor = "8A8A92"

    func formula(_ formula: MathFormula) -> String {
        // LaTeX the editor couldn't take apart stays exactly as it was.
        if caret == nil, formula.lines.count == 1, formula.lines[0].count == 1, case .raw(let latex) = formula.lines[0].items[0].kind {
            return latex
        }
        let lines = formula.lines.map(row)
        guard lines.count > 1 else { return lines.first ?? "" }
        let environment = formula.aligned ? "aligned" : "gathered"
        return "\\begin{\(environment)}\n" + lines.joined(separator: " \\\\\n") + "\n\\end{\(environment)}"
    }

    private var caretMark: String { "\\!\\color{#\(caretColor)}{|}\\!" }
    private var placeholderMark: String { "\\color{#\(placeholderColor)}{\\square}" }

    func row(_ row: MathRow) -> String {
        if row.isEmpty {
            if let caret, caret.row === row { return caretMark }
            return placeholders ? placeholderMark : ""
        }
        var tokens: [String] = []
        for (index, item) in row.items.enumerated() {
            if let caret, caret.row === row, caret.index == index { tokens.append(caretMark) }
            // Scripts need something to sit on.
            if item.isScripts, index == 0 || (caret?.row === row && caret?.index == index) { tokens.append("{}") }
            tokens.append(node(item))
        }
        if let caret, caret.row === row, caret.index == row.count { tokens.append(caretMark) }
        return Self.join(tokens)
    }

    /// Whether a row holds fractions, sums, matrices or the like, which brackets should grow around.
    static func isTall(_ row: MathRow) -> Bool {
        row.items.contains { node in
            switch node.kind {
            case .fraction, .binomial, .matrix, .largeOperator: return true
            case .group(let left, _) where left != "{": return isTall(node.slots[0]) || node.slots[0].items.contains { if case .group = $0.kind { return true } else { return false } }
            default: return node.slots.contains(where: isTall)
            }
        }
    }

    /// A control word ("\alpha") needs a space before a letter that follows it.
    static func join(_ tokens: [String]) -> String {
        var output = ""
        for token in tokens where !token.isEmpty {
            if let first = token.first, first.isLetter, output.range(of: #"\\[A-Za-z]+$"#, options: .regularExpression) != nil {
                output += " "
            }
            output += token
        }
        return output
    }

    private func argument(_ row: MathRow) -> String {
        "{" + self.row(row) + "}"
    }

    /// A script of one plain character goes without braces: `x^2`.
    private func script(_ row: MathRow) -> String {
        if caret?.row !== row, row.count == 1, case .symbol(let token) = row.items[0].kind, token.count == 1,
           token.first.map({ $0.isLetter || $0.isNumber }) == true {
            return token
        }
        return argument(row)
    }

    func node(_ node: MathNode) -> String {
        switch node.kind {
        case .symbol(let token): return token
        case .function(let name): return name
        case .largeOperator(let name): return name
        case .fraction: return "\\frac" + argument(node.slots[0]) + argument(node.slots[1])
        case .binomial: return "\\binom" + argument(node.slots[0]) + argument(node.slots[1])
        case .root: return "\\sqrt" + argument(node.slots[0])
        case .nthRoot: return "\\sqrt[" + row(node.slots[0]) + "]" + argument(node.slots[1])
        case .scripts:
            var output = ""
            if let sub = node.subscript { output += "_" + script(sub) }
            if let sup = node.superscript { output += "^" + script(sup) }
            return output
        case .group(let left, let right):
            if left == "{" && right == "}" { return argument(node.slots[0]) }
            // Brackets only grow (\left … \right) around something tall; f(x) stays f(x), without the gap \left leaves.
            if Self.isTall(node.slots[0]) == false, ["(", "[", "|", "\\{"].contains(left), [")", "]", "|", "\\}"].contains(right) {
                return left + row(node.slots[0]) + right
            }
            return "\\left" + left + " " + row(node.slots[0]) + " \\right" + right
        case .accent(let name), .style(let name):
            return name + argument(node.slots[0])
        case .text:
            let text = node.slots[0].items.map { item -> String in
                if case .symbol(let character) = item.kind { return character }
                return ""
            }.joined()
            if let caret, caret.row === node.slots[0] {
                let before = node.slots[0].items.prefix(caret.index).map { item -> String in
                    if case .symbol(let character) = item.kind { return character }
                    return ""
                }.joined()
                let after = String(text.dropFirst(before.count))
                return Self.join(["\\text{\(before)}", caretMark, "\\text{\(after)}"])
            }
            return "\\text{" + (text.isEmpty && placeholders ? "…" : text) + "}"
        case .matrix(let environment, let rows, let columns):
            var lines: [String] = []
            for rowIndex in 0..<rows {
                let cells = (0..<columns).map { column -> String in
                    let index = rowIndex * columns + column
                    // An empty cell is "{}", so a matrix of empty rows keeps its rows.
                    let text = index < node.slots.count ? row(node.slots[index]) : ""
                    return text.isEmpty ? "{}" : text
                }
                lines.append(cells.joined(separator: " & "))
            }
            return "\\begin{\(environment)}" + lines.joined(separator: " \\\\ ") + "\\end{\(environment)}"
        case .raw(let latex):
            return "{" + latex + "}"
        }
    }
}

// MARK: - Reading LaTeX

/// Reads the LaTeX of a formula into the tree. Returns nil for LaTeX it can't take apart; the editor then keeps
/// the formula as one piece that is edited in the source field.
enum MathLaTeXParser {
    struct Result {
        var lines: [MathRow]
        var aligned: Bool
    }

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "ln", "log", "lg", "exp", "det", "dim", "ker", "deg", "arg", "gcd", "Pr", "hom",
    ]
    static let largeOperators: Set<String> = [
        "sum", "prod", "coprod", "int", "iint", "iiint", "oint", "bigcup", "bigcap", "bigoplus", "bigotimes",
        "lim", "liminf", "limsup", "max", "min", "sup", "inf",
    ]
    static let accents: Set<String> = ["vec", "hat", "bar", "dot", "ddot", "tilde", "overline", "underline", "widehat", "widetilde", "check", "breve", "acute", "grave"]
    static let styles: Set<String> = ["mathbb", "mathbf", "mathrm", "mathcal", "mathit", "mathsf", "mathtt", "mathfrak", "boldsymbol"]
    static let matrixEnvironments: Set<String> = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "cases"]
    private static let lineEnvironments: Set<String> = ["aligned", "align", "align*", "gathered", "gather", "gather*", "split", "eqnarray", "eqnarray*", "multline", "multline*", "equation", "equation*", "displaymath"]
    /// Delimiters after `\left`/`\right` and the `\big` family.
    private static let delimiterCommands: Set<String> = ["{", "}", "|", "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "lvert", "rvert", "lVert", "rVert", "vert", "Vert"]
    private static let sizeCommands: Set<String> = ["big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr"]

    static func parse(_ latex: String) -> Result? {
        var trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Result(lines: [MathRow()], aligned: false) }
        // Labels and tags don't belong to the formula.
        trimmed = trimmed.replacingOccurrences(of: #"\\(label|tag)\*?\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\nonumber", with: "").replacingOccurrences(of: "\\notag", with: "")
        var parser = Parser(Array(trimmed))
        var aligned = false
        // A whole formula in one line environment: its lines.
        if let environment = parser.peekEnvironment(), lineEnvironments.contains(environment) {
            aligned = environment.hasPrefix("align") || environment == "split" || environment.hasPrefix("eqnarray")
            parser.skipBegin()
            guard let lines = try? parser.lines(until: environment), parser.atEnd else { return nil }
            return Result(lines: lines, aligned: aligned)
        }
        guard let lines = try? parser.lines(until: nil), parser.atEnd else { return nil }
        aligned = lines.contains { $0.items.contains { $0.kind == .symbol("&") } }
        return Result(lines: lines, aligned: aligned)
    }

    private struct ParseError: Error {}

    private struct Parser {
        let characters: [Character]
        var position = 0

        init(_ characters: [Character]) { self.characters = characters }

        var atEnd: Bool {
            var scan = position
            while scan < characters.count, characters[scan].isWhitespace { scan += 1 }
            return scan >= characters.count
        }

        mutating func skipSpaces() {
            while position < characters.count, characters[position].isWhitespace { position += 1 }
        }

        func peekEnvironment() -> String? {
            var copy = self
            copy.skipSpaces()
            guard copy.consume("\\begin{") else { return nil }
            return copy.readUntil("}")
        }

        mutating func skipBegin() {
            skipSpaces()
            guard consume("\\begin{"), let name = readUntil("}") else { return }
            position += name.count + 1
        }

        mutating func consume(_ text: String) -> Bool {
            let pattern = Array(text)
            guard position + pattern.count <= characters.count, Array(characters[position..<(position + pattern.count)]) == pattern else { return false }
            position += pattern.count
            return true
        }

        func readUntil(_ terminator: Character) -> String? {
            var scan = position
            var text = ""
            while scan < characters.count, characters[scan] != terminator {
                text.append(characters[scan])
                scan += 1
            }
            return scan < characters.count ? text : nil
        }

        /// A command name after a backslash: letters, or one other character.
        mutating func command() -> String {
            guard position < characters.count else { return "" }
            if characters[position].isLetter {
                var name = ""
                while position < characters.count, characters[position].isLetter, characters[position].isASCII {
                    name.append(characters[position])
                    position += 1
                }
                if position < characters.count, characters[position] == "*" {
                    name.append("*")
                    position += 1
                }
                return name
            }
            let name = String(characters[position])
            position += 1
            return name
        }

        /// Lines separated by `\\` until `\end{environment}` (or the end).
        mutating func lines(until environment: String?) throws -> [MathRow] {
            var lines: [MathRow] = []
            while true {
                let (row, stop) = try self.row(stopAtLineBreak: true, environment: environment)
                lines.append(row)
                switch stop {
                case .lineBreak: continue
                case .end, .endEnvironment: return lines
                case .closingBrace, .rightDelimiter, .closingBracket, .cellBreak: throw ParseError()
                }
            }
        }

        enum Stop: Equatable {
            case end, closingBrace, closingBracket, lineBreak, cellBreak, endEnvironment, rightDelimiter(String)
        }

        /// One row up to what ends it.
        mutating func row(stopAtLineBreak: Bool = false, stopAtCell: Bool = false, environment: String? = nil, stopAtBracket: Bool = false) throws -> (MathRow, Stop) {
            let row = MathRow()
            while true {
                skipSpaces()
                guard position < characters.count else { return (row, .end) }
                let character = characters[position]
                switch character {
                case "}":
                    position += 1
                    return (row, .closingBrace)
                case "]" where stopAtBracket:
                    position += 1
                    return (row, .closingBracket)
                case "{":
                    position += 1
                    let (inner, stop) = try self.row()
                    guard stop == .closingBrace else { throw ParseError() }
                    if inner.count == 1, !inner.items[0].isScripts {
                        row.append(inner.remove(at: 0))
                    } else if !inner.isEmpty {
                        row.append(MathNode(.group(left: "{", right: "}"), slots: [inner]))
                    }
                case "^", "_":
                    position += 1
                    let argument = try self.argument()
                    attachScript(argument, superscript: character == "^", to: row)
                case "&":
                    position += 1
                    if stopAtCell { return (row, .cellBreak) }
                    row.append(.symbol("&"))
                case "\\":
                    position += 1
                    let name = command()
                    if name == "\\" {
                        if stopAtLineBreak || stopAtCell { return (row, .lineBreak) }
                        throw ParseError()
                    }
                    if name == "end" {
                        guard consume("{"), let env = readUntil("}") else { throw ParseError() }
                        position += env.count + 1
                        return (row, .endEnvironment)
                    }
                    if name == "right" {
                        return (row, .rightDelimiter(try delimiter()))
                    }
                    try command(name, into: row)
                case "'":
                    position += 1
                    row.append(.symbol("'"))
                default:
                    position += 1
                    if character == "*" {
                        row.append(.symbol("\\cdot"))
                    } else {
                        row.append(.symbol(String(character)))
                    }
                }
            }
        }

        /// The argument of ^, _ or a command: a braced row, or one token.
        mutating func argument() throws -> MathRow {
            skipSpaces()
            guard position < characters.count else { throw ParseError() }
            if characters[position] == "{" {
                position += 1
                let (inner, stop) = try row()
                guard stop == .closingBrace else { throw ParseError() }
                return inner
            }
            let single = MathRow()
            if characters[position] == "\\" {
                position += 1
                let name = command()
                try command(name, into: single)
            } else {
                single.append(.symbol(String(characters[position])))
                position += 1
            }
            return single
        }

        mutating func delimiter() throws -> String {
            skipSpaces()
            guard position < characters.count else { throw ParseError() }
            if characters[position] == "\\" {
                position += 1
                let name = command()
                return "\\" + name
            }
            let character = characters[position]
            position += 1
            return String(character)
        }

        private func attachScript(_ argument: MathRow, superscript: Bool, to row: MathRow) {
            let node: MathNode
            if let last = row.items.last, last.isScripts, superscript ? last.superscript == nil : last.subscript == nil {
                node = last
            } else {
                node = MathNode(.scripts(superscript: false, subscript: false))
                row.append(node)
            }
            let slot = node.ensureScript(superscript: superscript)
            for item in argument.removeSubrange(0..<argument.count) { slot.append(item) }
        }

        mutating func command(_ name: String, into row: MathRow) throws {
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                row.append(MathNode(.fraction, slots: [try argument(), try argument()]))
            case "binom", "dbinom", "tbinom":
                row.append(MathNode(.binomial, slots: [try argument(), try argument()]))
            case "sqrt":
                skipSpaces()
                if position < characters.count, characters[position] == "[" {
                    position += 1
                    let (degree, stop) = try self.row(stopAtBracket: true)
                    guard stop == .closingBracket else { throw ParseError() }
                    row.append(MathNode(.nthRoot, slots: [degree, try argument()]))
                } else {
                    row.append(MathNode(.root, slots: [try argument()]))
                }
            case "left":
                let left = try delimiter()
                let (inner, stop) = try self.row()
                guard case .rightDelimiter(let right) = stop else { throw ParseError() }
                row.append(MathNode(.group(left: left, right: right), slots: [inner]))
            case "begin":
                guard consume("{"), let environment = readUntil("}") else { throw ParseError() }
                position += environment.count + 1
                guard MathLaTeXParser.matrixEnvironments.contains(environment) else { throw ParseError() }
                var cells: [[MathRow]] = [[]]
                func finish() {
                    let columns = max(1, cells.map(\.count).max() ?? 1)
                    var slots: [MathRow] = []
                    for line in cells {
                        for column in 0..<columns { slots.append(column < line.count ? line[column] : MathRow()) }
                    }
                    row.append(MathNode(.matrix(environment: environment, rows: cells.count, columns: columns), slots: slots))
                }
                while true {
                    let (cell, stop) = try self.row(stopAtCell: true)
                    cells[cells.count - 1].append(cell)
                    switch stop {
                    case .cellBreak: continue
                    case .lineBreak:
                        // A "\\" right before \end ends the last row instead of starting one.
                        var lookahead = self
                        lookahead.skipSpaces()
                        if lookahead.consume("\\end{"), let name = lookahead.readUntil("}") {
                            position = lookahead.position + name.count + 1
                            finish()
                            return
                        }
                        cells.append([])
                    case .endEnvironment:
                        finish()
                        return
                    default: throw ParseError()
                    }
                }
            case "text", "textrm", "mbox", "textit", "textbf", "textnormal":
                skipSpaces()
                guard consume("{") else { throw ParseError() }
                var depth = 0
                var text = ""
                while position < characters.count {
                    let character = characters[position]
                    if character == "{" { depth += 1 }
                    if character == "}" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    text.append(character)
                    position += 1
                }
                guard position < characters.count else { throw ParseError() }
                position += 1
                row.append(MathNode(.text, slots: [MathRow(text.map { MathNode.symbol(String($0)) })]))
            case "operatorname", "operatorname*":
                skipSpaces()
                guard consume("{"), let operatorName = readUntil("}") else { throw ParseError() }
                position += operatorName.count + 1
                row.append(MathNode(.function("\\operatorname{\(operatorName)}")))
            case _ where MathLaTeXParser.functions.contains(name):
                row.append(MathNode(.function("\\" + name)))
            case _ where MathLaTeXParser.largeOperators.contains(name):
                row.append(MathNode(.largeOperator("\\" + name)))
            case _ where MathLaTeXParser.accents.contains(name):
                row.append(MathNode(.accent("\\" + name), slots: [try argument()]))
            case _ where MathLaTeXParser.styles.contains(name):
                row.append(MathNode(.style("\\" + name), slots: [try argument()]))
            case _ where MathLaTeXParser.sizeCommands.contains(name):
                // Size commands only make the delimiter bigger; the delimiter stays.
                let delimiter = try self.delimiter()
                row.append(.symbol(delimiter))
            case "displaystyle", "textstyle", "limits", "nolimits", "nonumber", "notag":
                break
            case "color", "textcolor", "colorbox", "boxed", "phantom", "overbrace", "underbrace", "stackrel", "overset", "underset", "substack", "mathop":
                // Commands with arguments the editor doesn't model: keep them as one piece.
                var latex = "\\" + name
                for _ in 0..<(["color", "textcolor", "colorbox", "stackrel", "overset", "underset"].contains(name) ? 2 : 1) {
                    skipSpaces()
                    guard consume("{") else { throw ParseError() }
                    var depth = 0
                    var inner = ""
                    while position < characters.count {
                        let character = characters[position]
                        if character == "{" { depth += 1 }
                        if character == "}" {
                            if depth == 0 { break }
                            depth -= 1
                        }
                        inner.append(character)
                        position += 1
                    }
                    guard position < characters.count else { throw ParseError() }
                    position += 1
                    latex += "{" + inner + "}"
                }
                row.append(MathNode(.raw(latex)))
            default:
                row.append(.symbol("\\" + name))
            }
        }
    }
}
