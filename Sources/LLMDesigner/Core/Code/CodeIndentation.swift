import Foundation

/// How a new line of code is indented: like the line above, one level deeper after a colon (Python) or an opening
/// bracket, one level less after `return`, `pass`, `break`, `continue` and `raise`.
enum CodeIndentation {
    static func nextIndent(after line: String, language: CodeLanguage?) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        guard let language else { return leading }
        // The code without a trailing comment and spaces.
        var code = line
        if let comment = CodeHighlighter.tokens(in: line, language: language).last(where: { $0.kind == .comment }),
           NSMaxRange(comment.range) >= line.utf16.count {
            code = (line as NSString).substring(to: comment.range.location)
        }
        code = code.trimmingCharacters(in: .whitespaces)
        let unit = language.indent
        if code.hasSuffix("(") || code.hasSuffix("[") || code.hasSuffix("{") { return leading + unit }
        switch language {
        case .python:
            if code.hasSuffix(":") { return leading + unit }
            let word = code.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            if ["return", "pass", "break", "continue", "raise"].contains(word), leading.hasSuffix(unit) {
                return String(leading.dropLast(unit.count))
            }
        case .sql:
            break
        }
        return leading
    }

    /// The line with one level of indentation more (`levels` > 0) or less; the level is the language's unit, or four
    /// spaces without a language.
    static func shifted(_ line: String, by levels: Int, unit: String = "    ") -> String {
        if levels > 0 { return String(repeating: unit, count: levels) + line }
        var rest = Substring(line)
        for _ in 0..<(-levels) {
            if rest.hasPrefix("\t") { rest = rest.dropFirst(); continue }
            var removed = 0
            while removed < unit.count, rest.first == " " { rest = rest.dropFirst(); removed += 1 }
        }
        return String(rest)
    }
}
