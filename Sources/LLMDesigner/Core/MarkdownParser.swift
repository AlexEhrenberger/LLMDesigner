import Foundation

enum MarkdownBlock: Hashable {
    struct ListItem: Hashable {
        let marker: String?   // nil = bullet, otherwise "1." etc.
        let level: Int
        let text: String
    }

    /// How a table column is aligned, from its separator (`:--`, `:-:`, `--:`).
    enum Alignment: Hashable, Sendable {
        case leading, center, trailing
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, code: String)
    case list([ListItem])
    case quote(String)
    /// `widths`: each column's share of the table's text width (they add up to 1), or nil for equal columns.
    case table(header: [String], rows: [[String]], alignments: [Alignment], widths: [Double]?)
    case math(latex: String, complete: Bool)
    case rule
    /// A line of its own that is only `\newpage` (also `\pagebreak`, `\clearpage`): the text goes on on a new page.
    case pageBreak
    /// A line of its own that is only `\columnbreak`: in a section in columns, the text goes on in the next column.
    case columnBreak
}

/// One Pandoc div a block stands in: its classes, its `key=value` attributes (an `#id` as `id`) and which opening line
/// it was, so blocks of the same div can be told from blocks of the next one with the same classes.
struct MarkdownDiv: Hashable {
    let serial: Int
    let classes: [String]
    let attributes: [String: String]
}

/// A block and the classes of the Pandoc divs it stands in (`::: {.center}` … `:::`), outermost first, and their
/// attributes (`::: {.table lines=grid}`); an inner div's value wins.
struct AnnotatedMarkdownBlock: Hashable {
    let block: MarkdownBlock
    let classes: [String]
    var attributes: [String: String] = [:]
    /// The divs one by one, outermost first.
    var divs: [MarkdownDiv] = []

    /// The innermost div with this class.
    func div(_ className: String) -> MarkdownDiv? {
        divs.last { $0.classes.contains(className) }
    }

    /// The classes and attributes of the divs that only set the paragraph (not a box or a column section around it).
    var formatClasses: [String] { divs.filter { !MarkdownDiv.structuralClasses.contains(where: $0.classes.contains) }.flatMap(\.classes) }
    var formatAttributes: [String: String] {
        divs.filter { !MarkdownDiv.structuralClasses.contains(where: $0.classes.contains) }
            .reduce(into: [String: String]()) { result, div in result.merge(div.attributes) { $1 } }
    }
}

extension MarkdownDiv {
    /// Divs that hold whole blocks together instead of formatting them: a box and a section in columns.
    static let structuralClasses = ["box", "columns"]
}

/// Small block-level Markdown parser tuned for streamed LLM output (unclosed code fences are fine).
enum MarkdownParser {
    /// The blocks; the fence lines of divs are no blocks (see `parseAnnotated`).
    static func parse(_ text: String) -> [MarkdownBlock] {
        parseAnnotated(text).map(\.block)
    }

    /// The blocks with the divs around them. Writer Studio keeps how paragraphs are aligned in divs.
    static func parseAnnotated(_ text: String) -> [AnnotatedMarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [AnnotatedMarkdownBlock] = []
        var paragraph: [String] = []
        var divs: [MarkdownDiv] = []
        var serial = 0
        var index = 0

        func append(_ block: MarkdownBlock) {
            let attributes = divs.reduce(into: [String: String]()) { result, div in result.merge(div.attributes) { $1 } }
            blocks.append(AnnotatedMarkdownBlock(block: block, classes: divs.flatMap(\.classes), attributes: attributes, divs: divs))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceOpening(trimmed) {
                flushParagraph()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    if closesFence(lines[index].trimmingCharacters(in: .whitespaces), fence) {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                append(.code(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // A div's fences: `::: {.center}` opens one, `:::` closes the innermost (and is text when none is open).
            if let classes = divOpening(trimmed) {
                flushParagraph()
                serial += 1
                divs.append(MarkdownDiv(serial: serial, classes: classes, attributes: divAttributes(trimmed)))
                index += 1
                continue
            }
            if !divs.isEmpty, isDivClosing(trimmed) {
                flushParagraph()
                divs.removeLast()
                index += 1
                continue
            }

            if let (open, close) = displayMathDelimiters(for: trimmed) {
                flushParagraph()
                let afterOpen = String(trimmed.dropFirst(open.count))
                if let end = afterOpen.range(of: close) {
                    append(.math(latex: afterOpen[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), complete: true))
                    let rest = afterOpen[end.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { paragraph.append(rest) }
                    index += 1
                    continue
                }
                var body = [afterOpen]
                var complete = false
                index += 1
                while index < lines.count {
                    if let end = lines[index].range(of: close) {
                        body.append(String(lines[index][..<end.lowerBound]))
                        complete = true
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                append(.math(latex: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), complete: complete))
                continue
            }

            if let environment = mathEnvironment(in: trimmed) {
                flushParagraph()
                let end = "\\end{\(environment)}"
                var body: [String] = []
                var complete = false
                while index < lines.count {
                    body.append(lines[index])
                    index += 1
                    if body.last?.contains(end) == true {
                        complete = true
                        break
                    }
                }
                append(.math(latex: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), complete: complete))
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                append(.rule)
                index += 1
                continue
            }

            if pageBreakCommands.contains(trimmed) {
                flushParagraph()
                append(.pageBreak)
                index += 1
                continue
            }
            if trimmed == columnBreakCommand {
                flushParagraph()
                append(.columnBreak)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quote.append(String(current.dropFirst().drop(while: { $0 == " " })))
                    index += 1
                }
                append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(of: trimmed)
                let separators = cells(of: lines[index + 1])
                let alignments = separators.map { alignment(of: $0) }
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix("|") else { break }
                    rows.append(cells(of: current))
                    index += 1
                }
                append(.table(header: header, rows: rows, alignments: alignments, widths: widths(of: separators)))
                continue
            }

            if listItem(in: line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count {
                    if let item = listItem(in: lines[index]) {
                        items.append(item)
                        index += 1
                    } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              index + 1 < lines.count, listItem(in: lines[index + 1]) != nil {
                        index += 1   // loose list: blank line between items
                    } else if let last = items.last, lines[index].hasPrefix("  "),
                              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        // Indented continuation line belongs to the previous item.
                        let continuation = lines[index].trimmingCharacters(in: .whitespaces)
                        items[items.count - 1] = .init(marker: last.marker, level: last.level, text: last.text + "\n" + continuation)
                        index += 1
                    } else {
                        break
                    }
                }
                append(.list(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// The fence a (trimmed) line opens: three or more backticks or tildes, all of the run. A longer fence holds code
    /// that has a shorter one in it, as in a block that shows Markdown.
    static func fenceOpening(_ trimmed: String) -> String? {
        guard let mark = trimmed.first, mark == "`" || mark == "~" else { return nil }
        let run = trimmed.prefix { $0 == mark }
        return run.count >= 3 ? String(run) : nil
    }

    /// Whether a (trimmed) line closes `fence`: at least as many of the same mark and nothing after them.
    static func closesFence(_ trimmed: String, _ fence: String) -> Bool {
        guard let mark = fence.first else { return false }
        let run = trimmed.prefix { $0 == mark }
        return run.count >= fence.count && trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace)
    }

    /// A fence for `code`: longer than any fence inside it, so the code can't close it.
    static func fence(for code: String) -> String {
        let longest = code.components(separatedBy: "\n").compactMap { fenceOpening($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.first == "`" }.map(\.count).max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// The delimiters of display math that a (trimmed) line opens. Shared with `PowerText`, so both cut the text alike.
    static func displayMathDelimiters(for line: String) -> (open: String, close: String)? {
        if line.hasPrefix("$$") { return ("$$", "$$") }
        if line.hasPrefix("\\[") {
            // `\[1\] Müller` is an escaped bracket, as earlier versions wrote "[1] Müller" at the start of a line:
            // display math that closes on its line stands there alone.
            if let end = line.range(of: "\\]", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex),
               !line[end.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
            return ("\\[", "\\]")
        }
        return nil
    }

    private static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "aligned", "alignat", "alignat*", "flalign", "flalign*",
        "gather", "gather*", "gathered", "multline", "multline*", "eqnarray", "eqnarray*", "displaymath",
        "split", "cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
    ]

    /// Name of a math environment (`\begin{align}` …) that starts this line, if any.
    private static func mathEnvironment(in line: String) -> String? {
        guard line.hasPrefix("\\begin{"), let close = line.firstIndex(of: "}") else { return nil }
        let name = String(line[line.index(line.startIndex, offsetBy: 7)..<close])
        return mathEnvironments.contains(name) ? name : nil
    }

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = line.dropFirst(indent)
        let level = indent / 2

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .init(marker: nil, level: level, text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = rest.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")", afterDigits.dropFirst().first == " " {
                return .init(marker: "\(digits).", level: level, text: String(afterDigits.dropFirst(2)))
            }
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// The cells of a table row. An escaped `\|` stays in its cell (and keeps its backslash for the inline parser).
    private static func cells(of line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|") { content.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in content {
            if character == "|", !escaped {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The columns' widths from the dashes of the separator line, as Pandoc reads them. Only when the dashes add up to
    /// exactly 100 (Writer Studio writes them as percentages): a table from elsewhere keeps equal columns.
    static func widths(of separators: [String]) -> [Double]? {
        let dashes = separators.map { $0.filter { $0 == "-" }.count }
        guard dashes.count > 1, dashes.allSatisfy({ $0 > 0 }), dashes.reduce(0, +) == 100 else { return nil }
        return dashes.map { Double($0) / 100 }
    }

    /// The lines that break the page: LaTeX's commands, which Pandoc passes on to LaTeX.
    static let pageBreakCommands: Set<String> = ["\\newpage", "\\pagebreak", "\\clearpage"]
    /// The line that breaks a column: LaTeX's command in `multicols`.
    static let columnBreakCommand = "\\columnbreak"

    /// The classes of a line that opens a div: `::: {.center}`, `::: {.note #id}` or `::: note`.
    static func divOpening(_ line: String) -> [String]? {
        guard let core = divCore(line) else { return nil }
        if core.hasPrefix("{"), core.hasSuffix("}") {
            return attributeTokens(String(core.dropFirst().dropLast())).filter { $0.hasPrefix(".") }.map { String($0.dropFirst()) }
        }
        guard core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return [core]
    }

    /// The `key=value` attributes of a line that opens a div (`::: {.center line-spacing=1.5}`), keys in lower case,
    /// values without their quotes.
    static func divAttributes(_ line: String) -> [String: String] {
        guard let core = divCore(line), core.hasPrefix("{"), core.hasSuffix("}") else { return [:] }
        var attributes: [String: String] = [:]
        for token in attributeTokens(String(core.dropFirst().dropLast())) {
            if token.hasPrefix("#"), token.count > 1 {
                attributes["id"] = String(token.dropFirst())
                continue
            }
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { continue }
            var value = String(token[token.index(after: equals)...])
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            attributes[token[..<equals].lowercased()] = value
        }
        return attributes
    }

    /// What stands after the colons of a div's opening line.
    private static func divCore(_ line: String) -> String? {
        guard line.hasPrefix(":::") else { return nil }
        // Pandoc allows colons after the attributes, too.
        let core = line.drop(while: { $0 == ":" }).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return core.isEmpty ? nil : core
    }

    /// The tokens of an attribute list, split at spaces outside quotes.
    private static func attributeTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == " " {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                if character == "\"" || character == "'" { quote = character }
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func isDivClosing(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == ":" }
    }

    private static func alignment(of separator: String) -> MarkdownBlock.Alignment {
        let left = separator.hasPrefix(":")
        let right = separator.hasSuffix(":")
        return left && right ? .center : right ? .trailing : .leading
    }
}
