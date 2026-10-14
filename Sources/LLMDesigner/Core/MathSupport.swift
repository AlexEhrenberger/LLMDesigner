import AppKit
import SwiftMath

enum InlineSegment: Equatable {
    case text(String)
    case math(String)
}

/// Finds inline formulas (`$…$`, `\(…\)`, `$$…$$` inside a line) in Markdown text.
/// Code spans are left untouched, and the opening/closing rules for `$` follow Pandoc so that
/// amounts like "$5 und $10" stay plain text.
enum MathTokenizer {
    static func segments(_ source: String) -> [InlineSegment] {
        guard source.contains("$") || source.contains("\\(") else { return [.text(source)] }

        let chars = Array(source)
        var result: [InlineSegment] = []
        var buffer = ""
        var index = 0

        func flush() {
            if !buffer.isEmpty { result.append(.text(buffer)) }
            buffer = ""
        }
        func emitMath(_ range: Range<Int>) {
            let latex = String(chars[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return }
            flush()
            result.append(.math(latex))
        }

        while index < chars.count {
            let char = chars[index]

            if char == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                let fence = Array(repeating: Character("`"), count: run)
                if let close = find(fence, in: chars, from: index + run) {
                    buffer += String(chars[index..<(close + run)])
                    index = close + run
                } else {
                    buffer += String(fence)
                    index += run
                }
                continue
            }

            if char == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "(", let close = find(["\\", ")"], in: chars, from: index + 2) {
                    emitMath((index + 2)..<close)
                    index = close + 2
                    continue
                }
                if next == "[", let close = find(["\\", "]"], in: chars, from: index + 2) {
                    emitMath((index + 2)..<close)
                    index = close + 2
                    continue
                }
                buffer.append(char)
                buffer.append(next)
                index += 2
                continue
            }

            if char == "$" {
                if index + 1 < chars.count, chars[index + 1] == "$" {
                    if let close = find(["$", "$"], in: chars, from: index + 2), close > index + 2 {
                        emitMath((index + 2)..<close)
                        index = close + 2
                    } else {
                        buffer += "$$"
                        index += 2
                    }
                    continue
                }
                if index + 1 < chars.count, !chars[index + 1].isWhitespace,
                   let close = inlineDollarClose(in: chars, from: index + 1) {
                    emitMath((index + 1)..<close)
                    index = close + 1
                    continue
                }
            }

            buffer.append(char)
            index += 1
        }
        flush()
        return result
    }

    /// As in TeX, only the next unescaped `$` can close the formula. It needs a non-space character
    /// before it and must not be followed by a digit; otherwise the opening `$` is just a dollar sign
    /// ("$5 und $10"). A code span or blank line before it also ends the search.
    private static func inlineDollarClose(in chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            let char = chars[index]
            if char == "\\" { index += 2; continue }
            if char == "`" { return nil }
            if char == "\n", index + 1 < chars.count, chars[index + 1] == "\n" { return nil }
            if char == "$" {
                let followedByDigit = index + 1 < chars.count && chars[index + 1].isNumber
                let valid = index > start && !chars[index - 1].isWhitespace && !followedByDigit
                return valid ? index : nil
            }
            index += 1
        }
        return nil
    }

    private static func find(_ pattern: [Character], in chars: [Character], from start: Int) -> Int? {
        guard !pattern.isEmpty, chars.count >= pattern.count, start <= chars.count - pattern.count else { return nil }
        var index = start
        while index <= chars.count - pattern.count {
            if chars[index] == pattern[0] && Array(chars[index..<(index + pattern.count)]) == pattern { return index }
            index += 1
        }
        return nil
    }
}

/// Renders LaTeX via SwiftMath into images that can sit inline on a text baseline.
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        /// Offset that puts the formula's baseline onto the surrounding text baseline.
        let baselineOffset: CGFloat
    }

    private final class Entry {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 500
        return cache
    }()

    static func render(_ latex: String, fontSize: CGFloat, display: Bool, color: NSColor) -> Rendered? {
        let key = "\(display ? "D" : "T")|\(fontSize)|\(color.hashValue)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }

        var math = MathImage(
            latex: normalize(latex),
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        let (error, image, layout) = math.asImage()
        var rendered: Rendered?
        if error == nil, let image, let layout, image.size.width > 0, image.size.height > 0 {
            // Mirrors SwiftMath's vertical centering to find where the baseline sits in the image.
            let height = max(layout.ascent + layout.descent, fontSize / 2)
            let baselineFromBottom = (image.size.height - height) / 2 + layout.descent
            rendered = Rendered(image: image, baselineOffset: -baselineFromBottom)
        }
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    /// Maps common LaTeX that LLMs emit onto what SwiftMath understands.
    static func normalize(_ latex: String) -> String {
        var result = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        let environments: [(from: String, to: String?)] = [
            ("equation*", nil), ("equation", nil), ("displaymath", nil),
            ("align*", "aligned"), ("align", "aligned"), ("alignat*", "aligned"), ("alignat", "aligned"),
            ("flalign*", "aligned"), ("flalign", "aligned"),
            ("gather*", "gather"), ("gathered", "gather"), ("multline*", "gather"), ("multline", "gather"),
            ("eqnarray*", "eqnarray"), ("dcases", "cases"),
        ]
        for (from, to) in environments {
            result = result.replacingOccurrences(of: "\\begin{\(from)}", with: to.map { "\\begin{\($0)}" } ?? "")
            result = result.replacingOccurrences(of: "\\end{\(from)}", with: to.map { "\\end{\($0)}" } ?? "")
        }

        let replacements: [(String, String)] = [
            ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\cfrac", "\\frac"),
            ("\\dbinom", "\\binom"), ("\\tbinom", "\\binom"),
            ("\\operatorname*", "\\mathrm"), ("\\operatorname", "\\mathrm"),
            ("\\textbf", "\\mathbf"), ("\\textit", "\\mathit"), ("\\textrm", "\\text"),
            ("\\mathrm{d}", "d"), ("\\boxed", ""), ("\\displaystyle", ""), ("\\textstyle", ""),
            ("\\nonumber", ""), ("\\notag", ""), ("\\quad", "\\;\\;"), ("\\qquad", "\\;\\;\\;\\;"),
            ("\\lvert", "|"), ("\\rvert", "|"), ("\\lVert", "\\|"), ("\\rVert", "\\|"),
            ("\\le ", "\\leq "), ("\\ge ", "\\geq "), ("\\ne ", "\\neq "),
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        result = result.replacingOccurrences(of: #"\\tag\*?\{[^}]*\}"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\\label\{[^}]*\}"#, with: "", options: .regularExpression)

        // Line breaks outside an environment only work inside one.
        if result.contains("\\\\") && !result.contains("\\begin{") {
            result = "\\begin{gather}" + result + "\\end{gather}"
        }
        return result
    }
}
