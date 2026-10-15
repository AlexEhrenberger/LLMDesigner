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
    case table(header: [String], rows: [[String]], alignments: [Alignment])
    case math(latex: String, complete: Bool)
    case rule
}

/// Small block-level Markdown parser tuned for streamed LLM output (unclosed code fences are fine).
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let (open, close) = displayMathDelimiters(for: trimmed) {
                flushParagraph()
                let afterOpen = String(trimmed.dropFirst(open.count))
                if let end = afterOpen.range(of: close) {
                    blocks.append(.math(latex: afterOpen[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), complete: true))
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
                blocks.append(.math(latex: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), complete: complete))
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
                blocks.append(.math(latex: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), complete: complete))
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
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
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(of: trimmed)
                let alignments = cells(of: lines[index + 1]).map { alignment(of: $0) }
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix("|") else { break }
                    rows.append(cells(of: current))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
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
                blocks.append(.list(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func displayMathDelimiters(for line: String) -> (open: String, close: String)? {
        if line.hasPrefix("$$") { return ("$$", "$$") }
        if line.hasPrefix("\\[") { return ("\\[", "\\]") }
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

    private static func isTableSeparator(_ line: String) -> Bool {
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

    private static func alignment(of separator: String) -> MarkdownBlock.Alignment {
        let left = separator.hasPrefix(":")
        let right = separator.hasSuffix(":")
        return left && right ? .center : right ? .trailing : .leading
    }
}
