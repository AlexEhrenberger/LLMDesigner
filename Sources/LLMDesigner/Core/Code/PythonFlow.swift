import Foundation

/// Flow charts of Python code: the main program and every function (and method) as a chart of its own. The code is
/// read by its indentation, not run: branches, loops, `try`/`except`, returns and raises become the chart's shape.
enum PythonFlow {
    static func graphs(for code: String) -> [FlowGraph] {
        var parser = Parser(lines: logicalLines(code))
        let statements = parser.parseBlock(parentIndent: -1)
        var graphs: [FlowGraph] = []

        // Everything but the definitions is the main program.
        var script: [Statement] = []
        var definitions: [(name: String, parameters: String, body: [Statement])] = []
        func collect(_ statements: [Statement], prefix: String?) {
            for statement in statements {
                switch statement {
                case .function(let name, let parameters, let body):
                    definitions.append(((prefix.map { $0 + "." } ?? "") + name, parameters, body))
                case .classDefinition(let name, let body):
                    collect(body, prefix: (prefix.map { $0 + "." } ?? "") + name)
                default:
                    if prefix == nil { script.append(statement) }
                }
            }
        }
        collect(statements, prefix: nil)

        let meaningful = script.contains { if case .skip = $0 { false } else { true } }
        if meaningful {
            var builder = Builder(title: "Programmablauf", startText: "Programmstart", endText: "Ende")
            graphs.append(builder.build(script))
        }
        for definition in definitions {
            var builder = Builder(
                title: "def \(definition.name)(\(definition.parameters))",
                startText: "\(definition.name)(\(FlowGraph.label(definition.parameters, limit: 40)))",
                endText: "Ende"
            )
            graphs.append(builder.build(definition.body))
        }
        return graphs
    }

    // MARK: Lines

    struct Line {
        let indent: Int
        let text: String
    }

    /// The statements as lines: comments gone, lines inside brackets, triple-quoted strings and after a trailing
    /// backslash joined to the line they belong to.
    static func logicalLines(_ code: String) -> [Line] {
        let units = Array(code.utf16)
        let tokens = CodeHighlighter.tokens(in: code, language: .python)
        let strings = tokens.filter { $0.kind == .string }.map(\.range)
        let comments = tokens.filter { $0.kind == .comment }.map(\.range)

        func isInside(_ ranges: [NSRange], _ position: Int) -> Bool {
            ranges.contains { position >= $0.location && position < NSMaxRange($0) }
        }

        var lines: [Line] = []
        var current: [UInt16] = []
        var depth = 0
        var indent = 0
        func finish() {
            let text = String(utf16CodeUnits: current, count: current.count).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if !text.isEmpty { lines.append(Line(indent: indent, text: text)) }
            current = []
            depth = 0
        }

        var atStart = true      // the next character that is no space begins a statement
        var width = 0
        for index in 0..<units.count {
            if isInside(comments, index) { continue }
            let unit = units[index]
            if atStart {
                if unit == 0x20 { width += 1; continue }
                if unit == 0x09 { width += 4; continue }
                if unit == 0x0A || unit == 0x0D { width = 0; continue }
                indent = width
                atStart = false
            }
            let insideString = isInside(strings, index)
            if !insideString {
                if unit == 0x28 || unit == 0x5B || unit == 0x7B { depth += 1 }
                if unit == 0x29 || unit == 0x5D || unit == 0x7D { depth = max(0, depth - 1) }
            }
            if unit == 0x0A {
                if insideString {
                    current.append(0x20)
                    continue
                }
                let lastNonSpace = current.last { $0 != 0x20 && $0 != 0x09 }
                if depth == 0, lastNonSpace != 0x5C {
                    finish()
                    atStart = true
                    width = 0
                    continue
                }
                // Inside brackets or after a backslash the statement goes on.
                if lastNonSpace == 0x5C, let slash = current.lastIndex(of: 0x5C) { current.remove(at: slash) }
                current.append(0x20)
                continue
            }
            current.append(unit)
        }
        finish()
        return lines
    }

    // MARK: Statements

    indirect enum Statement {
        case simple(String)
        case inputOutput(String)
        case returning(String?)
        case raising(String)
        case breaking
        case continuing
        case branch(condition: String, body: [Statement], elifs: [(condition: String, body: [Statement])], orelse: [Statement]?)
        case loop(header: String, body: [Statement], orelse: [Statement]?)
        case tryBlock(body: [Statement], handlers: [(header: String, body: [Statement])], orelse: [Statement]?, final: [Statement]?)
        case with(header: String, body: [Statement])
        case function(name: String, parameters: String, body: [Statement])
        case classDefinition(name: String, body: [Statement])
        case skip
    }

    struct Parser {
        var lines: [Line]
        var position = 0

        init(lines: [Line]) { self.lines = lines }

        mutating func parseBlock(parentIndent: Int) -> [Statement] {
            guard position < lines.count, lines[position].indent > parentIndent else { return [] }
            let blockIndent = lines[position].indent
            var result: [Statement] = []
            while position < lines.count, lines[position].indent >= blockIndent {
                let line = lines[position]
                position += 1
                result.append(statement(for: line))
            }
            return result
        }

        /// The header of a compound statement without its colon, and a statement written after the colon.
        private func split(_ text: String) -> (header: String, inline: String?) {
            var depth = 0
            var quote: Character?
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                if let open = quote {
                    if character == open { quote = nil }
                    continue
                }
                switch character {
                case "\"", "'": quote = character
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case ":" where depth == 0:
                    // Not a walrus or a slice; a lambda's colon comes before the header's own, so give up there.
                    if index + 1 < characters.count, characters[index + 1] == "=" { continue }
                    if String(characters[..<index]).contains("lambda ") { continue }
                    let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                    return (String(characters[..<index]).trimmingCharacters(in: .whitespaces), rest.isEmpty ? nil : rest)
                default: break
                }
            }
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }

        private mutating func body(of line: Line, inline: String?) -> [Statement] {
            if let inline { return [statement(for: Line(indent: line.indent + 1, text: inline))] }
            return parseBlock(parentIndent: line.indent)
        }

        /// The next line at this indent that continues a compound statement (`elif`, `else`, `except`, `finally`).
        private func peek(_ keywords: [String], indent: Int) -> Line? {
            guard position < lines.count, lines[position].indent == indent else { return nil }
            let text = lines[position].text
            for keyword in keywords where text == keyword + ":" || text.hasPrefix(keyword + " ") || text.hasPrefix(keyword + ":") {
                return lines[position]
            }
            return nil
        }

        private static func word(_ text: String, _ keyword: String) -> Bool {
            text == keyword || text.hasPrefix(keyword + " ") || text.hasPrefix(keyword + ":") || text.hasPrefix(keyword + "(")
        }

        mutating func statement(for line: Line) -> Statement {
            let text = line.text
            if text.hasPrefix("@") { return .skip }
            if Self.word(text, "if") {
                let (header, inline) = split(String(text.dropFirst(2)))
                let main = body(of: line, inline: inline)
                var elifs: [(condition: String, body: [Statement])] = []
                var orelse: [Statement]?
                while let next = peek(["elif"], indent: line.indent) {
                    position += 1
                    let (condition, inlineBody) = split(String(next.text.dropFirst(4)))
                    elifs.append((condition, body(of: next, inline: inlineBody)))
                }
                if let next = peek(["else"], indent: line.indent) {
                    position += 1
                    orelse = body(of: next, inline: split(String(next.text.dropFirst(4))).inline.map { $0 })
                }
                return .branch(condition: header, body: main, elifs: elifs, orelse: orelse)
            }
            if Self.word(text, "for") || Self.word(text, "async for") || Self.word(text, "while") {
                let isAsync = text.hasPrefix("async ")
                let source = isAsync ? String(text.dropFirst(6)) : text
                let (header, inline) = split(source)
                let main = body(of: line, inline: inline)
                var orelse: [Statement]?
                if let next = peek(["else"], indent: line.indent) {
                    position += 1
                    orelse = body(of: next, inline: split(String(next.text.dropFirst(4))).inline.map { $0 })
                }
                return .loop(header: header, body: main, orelse: orelse)
            }
            if Self.word(text, "try") {
                let main = body(of: line, inline: split(String(text.dropFirst(3))).inline)
                var handlers: [(header: String, body: [Statement])] = []
                var orelse: [Statement]?
                var final: [Statement]?
                while true {
                    if let next = peek(["except"], indent: line.indent) {
                        position += 1
                        let (header, inline) = split(next.text)
                        handlers.append((header, body(of: next, inline: inline)))
                    } else if let next = peek(["else"], indent: line.indent), !handlers.isEmpty, orelse == nil {
                        position += 1
                        orelse = body(of: next, inline: split(String(next.text.dropFirst(4))).inline)
                    } else if let next = peek(["finally"], indent: line.indent) {
                        position += 1
                        final = body(of: next, inline: split(String(next.text.dropFirst(7))).inline)
                    } else {
                        break
                    }
                }
                return .tryBlock(body: main, handlers: handlers, orelse: orelse, final: final)
            }
            if Self.word(text, "with") || Self.word(text, "async with") {
                let (header, inline) = split(text)
                return .with(header: header, body: body(of: line, inline: inline))
            }
            if Self.word(text, "def") || Self.word(text, "async def") {
                let source = text.hasPrefix("async ") ? String(text.dropFirst(6)) : text
                let (header, inline) = split(source)
                let rest = header.dropFirst(4)
                let name = String(rest.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
                var parameters = ""
                if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
                    parameters = String(rest[rest.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                }
                return .function(name: name, parameters: parameters, body: body(of: line, inline: inline))
            }
            if Self.word(text, "class") {
                let (header, inline) = split(text)
                let name = String(header.dropFirst(6).prefix { $0 != "(" && $0 != ":" }).trimmingCharacters(in: .whitespaces)
                return .classDefinition(name: name, body: body(of: line, inline: inline))
            }
            if Self.word(text, "return") {
                let value = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                return .returning(value.isEmpty ? nil : value)
            }
            if Self.word(text, "raise") { return .raising(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            if text == "break" { return .breaking }
            if text == "continue" { return .continuing }
            if text == "pass" || Self.word(text, "import") || (Self.word(text, "from") && text.contains(" import ")) || Self.word(text, "global") || Self.word(text, "nonlocal") {
                return .skip
            }
            // A docstring or a bare string is no step.
            if let first = text.first, first == "\"" || first == "'", text.last == first || text.hasSuffix("\"\"\"") || text.hasSuffix("'''") { return .skip }
            if Self.word(text, "print") { return .inputOutput("Ausgabe: " + Self.arguments(of: text)) }
            if text.contains("input("), let range = text.range(of: "input(") {
                // `wert = int(input("…"))`: the name before the first `=` receives it.
                var target = ""
                if let equals = text.firstIndex(of: "="), equals < range.lowerBound, text[text.index(after: equals)] != "=" {
                    target = text[..<equals].trimmingCharacters(in: .whitespaces)
                }
                return .inputOutput("Eingabe" + (target.isEmpty ? "" : " → \(target)"))
            }
            if Self.word(text, "yield") { return .simple("liefere " + String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            if Self.word(text, "assert") { return .simple("prüfe " + String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
            if Self.word(text, "del") { return .simple("lösche " + String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)) }
            return .simple(text)
        }

        /// The text inside the call's brackets: `print("a", b)` → `"a", b`.
        private static func arguments(of call: String) -> String {
            guard let open = call.firstIndex(of: "("), let close = call.lastIndex(of: ")"), open < close else { return call }
            return String(call[call.index(after: open)..<close])
        }
    }

    // MARK: The chart

    private struct Dangling {
        var node: String
        var label: String?
    }

    private struct Builder {
        var graph: FlowGraph
        let endText: String
        var endID = "nEnd"
        var loops: [(head: String, breaks: [Dangling])] = []

        init(title: String, startText: String, endText: String) {
            graph = FlowGraph(title: title, language: .python)
            self.endText = endText
            _ = graph.addNode(FlowGraph.label(startText), .terminal, id: "nStart")
        }

        mutating func build(_ statements: [Statement]) -> FlowGraph {
            _ = graph.addNode(endText, .terminal, id: endID)
            let rest = sequence(statements, from: [Dangling(node: "nStart", label: nil)])
            for item in rest { graph.connect(item.node, endID, label: item.label) }
            return graph
        }

        /// Connects what is open to a new node and returns the node as the new open end.
        private mutating func attach(_ id: String, to open: [Dangling]) -> [Dangling] {
            for item in open { graph.connect(item.node, id, label: item.label) }
            return [Dangling(node: id, label: nil)]
        }

        private mutating func sequence(_ statements: [Statement], from entry: [Dangling]) -> [Dangling] {
            var open = entry
            var pending: [String] = []

            func flush(_ builder: inout Builder) {
                guard !pending.isEmpty else { return }
                let id = builder.graph.addNode(FlowGraph.label(pending.joined(separator: "\n")), .process)
                open = builder.attach(id, to: open)
                pending = []
            }

            for statement in statements {
                if open.isEmpty { break }   // code after a return or raise is never reached
                switch statement {
                case .skip:
                    continue
                case .simple(let text):
                    pending.append(text)
                    if pending.count >= 4 { flush(&self) }
                    continue
                default:
                    flush(&self)
                }
                switch statement {
                case .inputOutput(let text):
                    open = attach(graph.addNode(FlowGraph.label(text), .inputOutput), to: open)
                case .returning(let value):
                    let id = graph.addNode(value.map { "Rückgabe: " + FlowGraph.label($0, limit: 48) } ?? "Rückgabe", .terminal)
                    _ = attach(id, to: open)
                    graph.connect(id, endID)
                    open = []
                case .raising(let value):
                    let id = graph.addNode(value.isEmpty ? "Fehler erneut auslösen" : "Fehler: " + FlowGraph.label(value, limit: 48), .error)
                    _ = attach(id, to: open)
                    graph.connect(id, endID)
                    open = []
                case .breaking:
                    if !loops.isEmpty { loops[loops.count - 1].breaks += open }
                    open = []
                case .continuing:
                    if let last = loops.last { for item in open { graph.connect(item.node, last.head, label: item.label ?? "weiter") } }
                    open = []
                case .branch(let condition, let body, let elifs, let orelse):
                    open = branch(condition, body, elifs, orelse, from: open)
                case .loop(let header, let body, let orelse):
                    open = loop(header, body, orelse, from: open)
                case .tryBlock(let body, let handlers, let orelse, let final):
                    open = tryBlock(body, handlers, orelse, final, from: open)
                case .with(let header, let body):
                    let id = graph.addNode(FlowGraph.label(header), .process)
                    open = sequence(body, from: attach(id, to: open))
                case .function(let name, _, _):
                    // A function inside a function: the chart of its own isn't made; a step says it is defined.
                    open = attach(graph.addNode("definiere \(name)()", .process), to: open)
                case .classDefinition(let name, _):
                    open = attach(graph.addNode("definiere Klasse \(name)", .process), to: open)
                case .simple, .skip:
                    break
                }
            }
            flush(&self)
            return open
        }

        private mutating func branch(_ condition: String, _ body: [Statement], _ elifs: [(condition: String, body: [Statement])],
                                     _ orelse: [Statement]?, from entry: [Dangling]) -> [Dangling] {
            var result: [Dangling] = []
            var decision = graph.addNode(FlowGraph.label(condition, limit: 50) + " ?", .decision)
            _ = attach(decision, to: entry)
            result += sequence(body, from: [Dangling(node: decision, label: "ja")])
            for item in elifs {
                let next = graph.addNode(FlowGraph.label(item.condition, limit: 50) + " ?", .decision)
                graph.connect(decision, next, label: "nein")
                decision = next
                result += sequence(item.body, from: [Dangling(node: decision, label: "ja")])
            }
            if let orelse {
                result += sequence(orelse, from: [Dangling(node: decision, label: "nein")])
            } else {
                result.append(Dangling(node: decision, label: "nein"))
            }
            return result
        }

        private mutating func loop(_ header: String, _ body: [Statement], _ orelse: [Statement]?, from entry: [Dangling]) -> [Dangling] {
            var text = header
            if header.hasPrefix("for "), let range = header.range(of: " in ") {
                text = "für jedes \(header[header.index(header.startIndex, offsetBy: 4)..<range.lowerBound]) in \(header[range.upperBound...])"
            } else if header.hasPrefix("while ") {
                text = "solange " + header.dropFirst(6)
            }
            let head = graph.addNode(FlowGraph.label(text, limit: 52), .loop)
            _ = attach(head, to: entry)
            loops.append((head, []))
            let end = sequence(body, from: [Dangling(node: head, label: "ja")])
            for item in end { graph.connect(item.node, head, label: item.label) }
            let broken = loops.removeLast().breaks
            var exits: [Dangling] = [Dangling(node: head, label: "fertig")]
            if let orelse { exits = sequence(orelse, from: exits) }
            return exits + broken
        }

        private mutating func tryBlock(_ body: [Statement], _ handlers: [(header: String, body: [Statement])], _ orelse: [Statement]?,
                                       _ final: [Statement]?, from entry: [Dangling]) -> [Dangling] {
            let before = Set(graph.nodes.map(\.id))
            var open = sequence(body, from: entry)
            let inside = graph.nodes.map(\.id).filter { !before.contains($0) }
            var result: [Dangling] = []
            if let orelse { open = sequence(orelse, from: open) }
            result += open
            if !inside.isEmpty {
                let group = graph.addGroup("try", nodes: inside)
                for handler in handlers {
                    // `except ValueError as fehler:` → the kind of error.
                    var reason = handler.header.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if let alias = reason.range(of: " as ") { reason = String(reason[..<alias.lowerBound]) }
                    let label = reason.isEmpty ? "Fehler" : "Fehler: " + FlowGraph.label(reason, limit: 36)
                    result += sequence(handler.body.isEmpty ? [.skip] : handler.body, from: [Dangling(node: group, label: label)])
                }
            }
            if let final {
                // `finally` runs after everything: all the open ends flow into it.
                result = sequence(final, from: result.isEmpty ? [] : result)
            }
            return result
        }
    }
}
