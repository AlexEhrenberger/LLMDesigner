import AppKit

/// The editing rules of the visual formula editor, in the spirit of MathQuill: typing builds the structure
/// ("/" makes a fraction of what stands before it, "^" a superscript, "(" a pair of brackets that grows with its
/// content), the arrow keys walk through it, and names like "sqrt", "pi" or "sin" turn into what they mean.
final class MathEditingState {
    private(set) var formula: MathFormula
    var cursor: MathCursor
    private var undoStack: [(MathFormula, CursorPath)] = []
    private var redoStack: [(MathFormula, CursorPath)] = []

    init(latex: String) {
        formula = MathFormula(latex: latex)
        let last = formula.lines[formula.lines.count - 1]
        cursor = MathCursor(row: last, index: last.count)
    }

    var latex: String { formula.latex }

    /// Replaces everything (from the LaTeX field).
    func replace(with latex: String) {
        snapshot()
        formula = MathFormula(latex: latex)
        let last = formula.lines[formula.lines.count - 1]
        cursor = MathCursor(row: last, index: last.count)
    }

    var isInText: Bool {
        if case .text = cursor.row.parent?.kind { return true }
        return false
    }

    // MARK: Undo

    /// The caret as a path from the formula's lines, so it survives copying the tree.
    private struct CursorPath {
        var line: Int
        var steps: [(item: Int, slot: Int)]
        var index: Int
    }

    private func path(of cursor: MathCursor) -> CursorPath {
        var steps: [(Int, Int)] = []
        var row = cursor.row
        while let node = row.parent, let parentRow = node.row, let item = parentRow.index(of: node),
              let slot = node.slots.firstIndex(where: { $0 === row }) {
            steps.insert((item, slot), at: 0)
            row = parentRow
        }
        let line = formula.lines.firstIndex { $0 === row } ?? 0
        return CursorPath(line: line, steps: steps, index: cursor.index)
    }

    private func resolve(_ path: CursorPath, in formula: MathFormula) -> MathCursor {
        var row = formula.lines[min(path.line, formula.lines.count - 1)]
        for step in path.steps {
            guard step.item < row.count, step.slot < row.items[step.item].slots.count else { break }
            row = row.items[step.item].slots[step.slot]
        }
        return MathCursor(row: row, index: min(path.index, row.count))
    }

    func snapshot() {
        undoStack.append((formula.copy(), path(of: cursor)))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let (previous, path) = undoStack.popLast() else { return }
        redoStack.append((formula.copy(), self.path(of: cursor)))
        formula = previous
        cursor = resolve(path, in: previous)
    }

    func redo() {
        guard let (next, path) = redoStack.popLast() else { return }
        undoStack.append((formula.copy(), self.path(of: cursor)))
        formula = next
        cursor = resolve(path, in: next)
    }

    // MARK: Typing

    func type(_ character: Character) {
        if isInText {
            snapshot()
            insert(MathNode.symbol(String(character)))
            return
        }
        switch character {
        case " ": return
        case "/": snapshot(); makeFraction()
        case "^": snapshot(); enterScript(superscript: true)
        case "_": snapshot(); enterScript(superscript: false)
        case "(": snapshot(); openGroup(left: "(", right: ")")
        case "[": snapshot(); openGroup(left: "[", right: "]")
        case "{": snapshot(); openGroup(left: "\\{", right: "\\}")
        case "|": snapshot(); openGroup(left: "|", right: "|")
        case ")", "]", "}":
            let right = character == ")" ? ")" : character == "]" ? "]" : "\\}"
            if case .group(_, let groupRight) = cursor.row.parent?.kind, groupRight == right, cursor.index == cursor.row.count {
                exitRight()
            } else {
                snapshot()
                insert(MathNode.symbol(character == "}" ? "\\}" : String(character)))
            }
        case "*": snapshot(); insert(MathNode.symbol("\\cdot"))
        case "°": insert(latex: "^{\\circ}")
        case "&":
            snapshot()
            insert(MathNode.symbol("&"))
            formula.aligned = true
        default:
            snapshot()
            if let command = MathSymbols.unicode[character] {
                insert(MathNode.symbol(command))
            } else if character == "%" || character == "#" || character == "$" {
                insert(MathNode.symbol("\\" + String(character)))
            } else {
                insert(MathNode.symbol(String(character)))
                if character.isLetter, character.isASCII { applyAutoCommand() }
            }
        }
    }

    private func insert(_ node: MathNode) {
        cursor.row.insert(node, at: cursor.index)
        cursor.index += 1
    }

    /// Inserts nodes (from the palette or a pasted formula) and puts the caret into the first empty place among
    /// them, else after them.
    func insert(_ nodes: [MathNode]) {
        guard !nodes.isEmpty else { return }
        snapshot()
        let row = cursor.row
        var index = cursor.index
        for node in nodes {
            // A script after a script would be a double script; it merges into the one before.
            if node.isScripts, index > 0, row.items[index - 1].isScripts {
                let target = row.items[index - 1]
                if let sup = node.superscript { moveItems(from: sup, to: target.ensureScript(superscript: true)) }
                if let sub = node.subscript { moveItems(from: sub, to: target.ensureScript(superscript: false)) }
                continue
            }
            row.insert(node, at: index)
            index += 1
        }
        cursor = MathCursor(row: row, index: index)
        if let empty = nodes.lazy.compactMap({ Self.firstEmptySlot(in: $0) }).first {
            cursor = MathCursor(row: empty, index: 0)
        }
    }

    private func moveItems(from source: MathRow, to target: MathRow) {
        for item in source.removeSubrange(0..<source.count) { target.append(item) }
    }

    func insert(latex: String) {
        guard let parsed = MathLaTeXParser.parse(latex) else {
            insert([MathNode(.raw(latex))])
            return
        }
        // Several lines go in one after another.
        insert(parsed.lines.flatMap { line in line.removeSubrange(0..<line.count) })
    }

    private static func firstEmptySlot(in node: MathNode) -> MathRow? {
        for slot in node.slotOrder {
            if slot.isEmpty { return slot }
            for item in slot.items { if let empty = firstEmptySlot(in: item) { return empty } }
        }
        return nil
    }

    /// "/" turns what stands right before the caret (up to an operator) into the numerator.
    func makeFraction() {
        let row = cursor.row
        var start = cursor.index
        while start > 0, !MathSymbols.breaksOperand(row.items[start - 1]) { start -= 1 }
        let taken = row.removeSubrange(start..<cursor.index)
        let fraction = MathNode(.fraction, slots: [MathRow(taken), MathRow()])
        row.insert(fraction, at: start)
        cursor = MathCursor(row: fraction.slots[taken.isEmpty ? 0 : 1], index: 0)
    }

    func enterScript(superscript: Bool) {
        let row = cursor.row
        if cursor.index > 0, row.items[cursor.index - 1].isScripts {
            let slot = row.items[cursor.index - 1].ensureScript(superscript: superscript)
            cursor = MathCursor(row: slot, index: slot.count)
        } else if cursor.index < row.count, row.items[cursor.index].isScripts {
            let slot = row.items[cursor.index].ensureScript(superscript: superscript)
            cursor = MathCursor(row: slot, index: 0)
        } else {
            let node = MathNode(.scripts(superscript: false, subscript: false))
            let slot = node.ensureScript(superscript: superscript)
            row.insert(node, at: cursor.index)
            cursor = MathCursor(row: slot, index: 0)
        }
    }

    func openGroup(left: String, right: String) {
        let group = MathNode(.group(left: left, right: right), slots: [MathRow()])
        cursor.row.insert(group, at: cursor.index)
        cursor = MathCursor(row: group.slots[0], index: 0)
    }

    /// A new line below (Shift-Return): the line with the caret is split after the item the caret is in.
    func newLine() {
        snapshot()
        var row = cursor.row
        var index = cursor.index
        while let node = row.parent, let parentRow = node.row, let position = parentRow.index(of: node) {
            row = parentRow
            index = position + 1
        }
        guard let line = formula.lines.firstIndex(where: { $0 === row }) else { return }
        let moved = row.removeSubrange(index..<row.count)
        let next = MathRow(moved)
        formula.lines.insert(next, at: line + 1)
        cursor = MathCursor(row: next, index: 0)
    }

    /// Letters that spell a known name become it: "sqrt" a root, "pi" π, "sin" the sine, "sum" a sum with bounds.
    private func applyAutoCommand() {
        let row = cursor.row
        var letters = ""
        var start = cursor.index
        while start > 0, cursor.index - start < 8, case .symbol(let token) = row.items[start - 1].kind,
              token.count == 1, let character = token.first, character.isLetter, character.isASCII {
            letters = token + letters
            start -= 1
        }
        guard letters.count >= 2 else { return }
        for length in stride(from: letters.count, through: 2, by: -1) {
            let name = String(letters.suffix(length))
            guard MathSymbols.autoCommands.contains(name), let nodes = MathSymbols.nodes(forCommand: name) else { continue }
            let from = cursor.index - length
            _ = row.removeSubrange(from..<cursor.index)
            cursor.index = from
            var index = from
            for node in nodes {
                row.insert(node, at: index)
                index += 1
            }
            cursor.index = index
            if let empty = nodes.lazy.compactMap({ Self.firstEmptySlot(in: $0) }).first {
                cursor = MathCursor(row: empty, index: 0)
            }
            return
        }
    }

    /// A command typed after a backslash; false if it is unknown.
    @discardableResult
    func insertCommand(_ name: String) -> Bool {
        guard let nodes = MathSymbols.nodes(forCommand: name) else { return false }
        insert(nodes)
        return true
    }

    // MARK: Moving

    func moveRight() {
        let row = cursor.row
        if cursor.index < row.count {
            let item = row.items[cursor.index]
            if let entry = item.entrySlotFromLeft {
                cursor = MathCursor(row: entry, index: 0)
            } else {
                cursor.index += 1
            }
            return
        }
        guard let node = row.parent else {
            if let line = formula.lines.firstIndex(where: { $0 === row }), line + 1 < formula.lines.count {
                cursor = MathCursor(row: formula.lines[line + 1], index: 0)
            }
            return
        }
        let order = node.slotOrder
        if !node.isScripts, let position = order.firstIndex(where: { $0 === row }), position + 1 < order.count {
            cursor = MathCursor(row: order[position + 1], index: 0)
        } else {
            exitRight()
        }
    }

    func moveLeft() {
        let row = cursor.row
        if cursor.index > 0 {
            let item = row.items[cursor.index - 1]
            if let entry = item.entrySlotFromRight {
                cursor = MathCursor(row: entry, index: entry.count)
            } else {
                cursor.index -= 1
            }
            return
        }
        guard let node = row.parent else {
            if let line = formula.lines.firstIndex(where: { $0 === row }), line > 0 {
                let previous = formula.lines[line - 1]
                cursor = MathCursor(row: previous, index: previous.count)
            }
            return
        }
        let order = node.slotOrder
        if !node.isScripts, let position = order.firstIndex(where: { $0 === row }), position > 0 {
            cursor = MathCursor(row: order[position - 1], index: order[position - 1].count)
        } else {
            exitLeft()
        }
    }

    private func exitRight() {
        guard let node = cursor.row.parent, let parentRow = node.row, let index = parentRow.index(of: node) else { return }
        cursor = MathCursor(row: parentRow, index: index + 1)
    }

    private func exitLeft() {
        guard let node = cursor.row.parent, let parentRow = node.row, let index = parentRow.index(of: node) else { return }
        cursor = MathCursor(row: parentRow, index: index)
    }

    /// Up and down: numerator and denominator, superscript and subscript, matrix rows, lines.
    func moveVertically(up: Bool) {
        var row = cursor.row
        while let node = row.parent {
            if let target = verticalNeighbour(of: row, in: node, up: up) {
                let keep = cursor.row === row ? cursor.index : Int.max
                cursor = MathCursor(row: target, index: min(keep, target.count))
                return
            }
            guard let parentRow = node.row else { break }
            row = parentRow
        }
        if let line = formula.lines.firstIndex(where: { $0 === row }) {
            let target = line + (up ? -1 : 1)
            if formula.lines.indices.contains(target) {
                cursor = MathCursor(row: formula.lines[target], index: min(cursor.index, formula.lines[target].count))
            }
        }
    }

    private func verticalNeighbour(of row: MathRow, in node: MathNode, up: Bool) -> MathRow? {
        guard let index = node.slots.firstIndex(where: { $0 === row }) else { return nil }
        switch node.kind {
        case .fraction, .binomial:
            return up ? (index == 1 ? node.slots[0] : nil) : (index == 0 ? node.slots[1] : nil)
        case .scripts:
            if up, row === node.subscript { return node.superscript }
            if !up, row === node.superscript { return node.subscript }
            return nil
        case .nthRoot:
            return up ? (index == 1 ? node.slots[0] : nil) : (index == 0 ? node.slots[1] : nil)
        case .matrix(_, _, let columns):
            let target = index + (up ? -columns : columns)
            return node.slots.indices.contains(target) ? node.slots[target] : nil
        default:
            return nil
        }
    }

    func moveToStart() {
        cursor = MathCursor(row: formula.lines[0], index: 0)
    }

    func moveToEnd() {
        let last = formula.lines[formula.lines.count - 1]
        cursor = MathCursor(row: last, index: last.count)
    }

    /// Tab: the next empty place (or the next matrix cell); at the end, out to the end of the line.
    func moveToNextField(backwards: Bool = false) {
        let positions = formula.positions
        guard let current = positions.firstIndex(where: { $0.row === cursor.row && $0.index == cursor.index }) else { return }
        let candidates = backwards ? Array(positions[..<current].reversed()) : Array(positions[(current + 1)...])
        if let empty = candidates.first(where: { $0.row.isEmpty && $0.row !== cursor.row }) {
            cursor = empty
            return
        }
        if case .matrix = cursor.row.parent?.kind, let node = cursor.row.parent, let index = node.slots.firstIndex(where: { $0 === cursor.row }) {
            let next = index + (backwards ? -1 : 1)
            if node.slots.indices.contains(next) {
                cursor = MathCursor(row: node.slots[next], index: backwards ? node.slots[next].count : 0)
                return
            }
        }
        backwards ? moveToStart() : moveToEnd()
    }

    // MARK: Deleting

    func deleteBackward() {
        snapshot()
        let row = cursor.row
        if cursor.index > 0 {
            let item = row.items[cursor.index - 1]
            if item.slots.isEmpty || item.slots.allSatisfy(\.isEmpty) || isTextNode(item) && item.slots[0].isEmpty {
                row.remove(at: cursor.index - 1)
                cursor.index -= 1
            } else if let entry = item.entrySlotFromRight {
                // Into the structure, at its end: the next backspace deletes inside it.
                cursor = MathCursor(row: entry, index: entry.count)
            }
            return
        }
        guard let node = row.parent, let parentRow = node.row, let position = parentRow.index(of: node) else {
            // At the start of a line: join it with the line above.
            if let line = formula.lines.firstIndex(where: { $0 === row }), line > 0 {
                let previous = formula.lines[line - 1]
                let index = previous.count
                for item in row.removeSubrange(0..<row.count) { previous.append(item) }
                formula.lines.remove(at: line)
                cursor = MathCursor(row: previous, index: index)
            }
            return
        }
        if node.isScripts {
            if row.isEmpty {
                node.removeScript(row)
                if node.slots.isEmpty {
                    parentRow.remove(at: position)
                    cursor = MathCursor(row: parentRow, index: position)
                } else {
                    cursor = MathCursor(row: parentRow, index: position + 1)
                }
            } else {
                cursor = MathCursor(row: parentRow, index: position)
            }
            return
        }
        let order = node.slotOrder
        if node.slots.allSatisfy(\.isEmpty) {
            parentRow.remove(at: position)
            cursor = MathCursor(row: parentRow, index: position)
        } else if let slotIndex = order.firstIndex(where: { $0 === row }), slotIndex > 0, !isTextNode(node) {
            cursor = MathCursor(row: order[slotIndex - 1], index: order[slotIndex - 1].count)
        } else {
            // At the start of the first slot: the structure dissolves, its content stays.
            let content = order.flatMap { $0.removeSubrange(0..<$0.count) }
            parentRow.remove(at: position)
            var index = position
            for item in isTextNode(node) ? [] : content {
                parentRow.insert(item, at: index)
                index += 1
            }
            cursor = MathCursor(row: parentRow, index: position)
        }
    }

    func deleteForward() {
        let row = cursor.row
        guard cursor.index < row.count else { return }
        snapshot()
        let item = row.items[cursor.index]
        if item.slots.isEmpty || item.slots.allSatisfy(\.isEmpty) {
            row.remove(at: cursor.index)
        } else if let entry = item.entrySlotFromLeft {
            cursor = MathCursor(row: entry, index: 0)
        }
    }

    func clear() {
        snapshot()
        formula = MathFormula()
        cursor = MathCursor(row: formula.lines[0], index: 0)
    }

    private func isTextNode(_ node: MathNode) -> Bool {
        if case .text = node.kind { return true }
        return false
    }
}

/// What the editor knows about symbols and commands.
enum MathSymbols {
    /// Names that turn into their command as soon as they are typed.
    static let autoCommands: Set<String> = [
        "sqrt", "pi", "alpha", "beta", "gamma", "delta", "epsilon", "theta", "lambda", "mu", "sigma", "tau", "phi", "omega", "rho",
        "Gamma", "Delta", "Theta", "Lambda", "Sigma", "Phi", "Omega", "Pi",
        "sin", "cos", "tan", "ln", "log", "exp", "lim", "sum", "prod", "int", "infty",
    ]

    static let greek: Set<String> = [
        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\varepsilon", "\\zeta", "\\eta", "\\theta", "\\vartheta",
        "\\iota", "\\kappa", "\\lambda", "\\mu", "\\nu", "\\xi", "\\rho", "\\varrho", "\\sigma", "\\tau", "\\upsilon",
        "\\phi", "\\varphi", "\\chi", "\\psi", "\\omega", "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi", "\\Sigma",
        "\\Upsilon", "\\Phi", "\\Psi", "\\Omega",
    ]

    /// Typed Unicode characters and their commands.
    static let unicode: [Character: String] = [
        "·": "\\cdot", "×": "\\times", "÷": "\\div", "±": "\\pm", "∓": "\\mp", "≤": "\\leq", "≥": "\\geq", "≠": "\\neq",
        "≈": "\\approx", "≡": "\\equiv", "∞": "\\infty", "→": "\\to", "⇒": "\\Rightarrow", "⇔": "\\Leftrightarrow",
        "∈": "\\in", "∉": "\\notin", "⊂": "\\subset", "⊆": "\\subseteq", "∪": "\\cup", "∩": "\\cap", "∀": "\\forall",
        "∃": "\\exists", "∂": "\\partial", "∇": "\\nabla", "π": "\\pi", "α": "\\alpha", "β": "\\beta",
        "γ": "\\gamma", "δ": "\\delta", "λ": "\\lambda", "μ": "\\mu", "σ": "\\sigma", "φ": "\\varphi", "ω": "\\omega",
        "Δ": "\\Delta", "Σ": "\\Sigma", "Ω": "\\Omega", "‰": "\\permil",
    ]

    /// Symbols that end the operand before "/" and around which a function's argument stops.
    static let operators: Set<String> = [
        "+", "-", "=", "<", ">", ",", ";", ":", "&", "\\cdot", "\\times", "\\div", "\\pm", "\\mp", "\\leq", "\\geq",
        "\\le", "\\ge", "\\neq", "\\ne", "\\approx", "\\equiv", "\\sim", "\\simeq", "\\propto", "\\to", "\\rightarrow",
        "\\leftarrow", "\\Rightarrow", "\\Leftarrow", "\\Leftrightarrow", "\\iff", "\\implies", "\\mapsto", "\\in",
        "\\notin", "\\subset", "\\subseteq", "\\supset", "\\supseteq", "\\cup", "\\cap", "\\setminus", "\\land", "\\lor",
        "\\wedge", "\\vee", "\\ll", "\\gg", "\\quad", "\\qquad", "\\,", "\\;", "\\:", "\\!",
    ]

    static func breaksOperand(_ node: MathNode) -> Bool {
        switch node.kind {
        case .symbol(let token): return operators.contains(token)
        case .function, .largeOperator: return true
        default: return false
        }
    }

    /// The nodes a command stands for, or nil when it is unknown.
    static func nodes(forCommand name: String) -> [MathNode]? {
        func parsed(_ latex: String) -> [MathNode]? {
            guard let result = MathLaTeXParser.parse(latex), let line = result.lines.first else { return nil }
            return line.removeSubrange(0..<line.count)
        }
        switch name {
        case "sqrt": return [MathNode.empty(.root, slots: 1)]
        case "nthroot", "root": return [MathNode.empty(.nthRoot, slots: 2)]
        case "frac": return [MathNode.empty(.fraction, slots: 2)]
        case "binom": return [MathNode.empty(.binomial, slots: 2)]
        case "sum", "prod", "coprod", "bigcup", "bigcap":
            return parsed("\\\(name)_{}^{}")
        case "lim", "max", "min", "sup", "inf", "liminf", "limsup":
            return parsed("\\\(name)_{}")
        case "int", "iint", "iiint", "oint":
            return [MathNode(.largeOperator("\\" + name))]
        case "text": return [MathNode(.text, slots: [MathRow()])]
        case "abs": return parsed("\\left| \\right|")
        case "norm": return parsed("\\left\\| \\right\\|")
        case "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix":
            return parsed("\\begin{\(name)} & \\\\ & \\end{\(name)}")
        case "cases": return parsed("\\begin{cases} & \\\\ & \\end{cases}")
        case "R", "N", "Z", "Q", "C": return parsed("\\mathbb{\(name)}")
        default: break
        }
        if MathLaTeXParser.functions.contains(name) { return [MathNode(.function("\\" + name))] }
        if MathLaTeXParser.largeOperators.contains(name) { return [MathNode(.largeOperator("\\" + name))] }
        if MathLaTeXParser.accents.contains(name) || MathLaTeXParser.styles.contains(name) {
            return parsed("\\\(name){}")
        }
        // Any other symbol SwiftMath can draw.
        guard name.allSatisfy({ $0.isLetter && $0.isASCII }), MathRenderer.render("\\" + name, fontSize: 12, display: false, color: .white) != nil else { return nil }
        return [MathNode.symbol("\\" + name)]
    }
}
