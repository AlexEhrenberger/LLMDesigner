import AppKit

/// What a paragraph in Writer Studio is. Stored on every character of the paragraph (`.writerBlock`).
enum WriterBlock: String, CaseIterable, Sendable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, quote, code, rule
    /// Markdown the editor can't show yet (tables, formulas); kept and written back unchanged.
    case raw

    var isList: Bool { self == .bullet || self == .numbered }
    var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }

    var label: String {
        switch self {
        case .paragraph: "Text"
        case .heading1: "Überschrift 1"
        case .heading2: "Überschrift 2"
        case .heading3: "Überschrift 3"
        case .bullet: "Aufzählung"
        case .numbered: "Nummerierte Liste"
        case .quote: "Zitat"
        case .code: "Code"
        case .rule: "Trennlinie"
        case .raw: "Markdown"
        }
    }
}

extension NSAttributedString.Key {
    /// `WriterBlock.rawValue` of the paragraph.
    static let writerBlock = NSAttributedString.Key("LLMDesigner.writer.block")
    /// Indentation level of a list item (0 = outermost).
    static let writerListLevel = NSAttributedString.Key("LLMDesigner.writer.level")
    /// Language of a code block, from its opening fence.
    static let writerCodeLanguage = NSAttributedString.Key("LLMDesigner.writer.language")
    static let writerBold = NSAttributedString.Key("LLMDesigner.writer.bold")
    static let writerItalic = NSAttributedString.Key("LLMDesigner.writer.italic")
    static let writerCode = NSAttributedString.Key("LLMDesigner.writer.code")
    /// Dictated words that are still being recognised: shown grey, never saved.
    static let writerDictationPreview = NSAttributedString.Key("LLMDesigner.writer.dictationPreview")
}

/// Inline marks of a stretch of text. Underline, strikethrough and links use the standard attributes.
struct WriterInline: OptionSet, Hashable {
    let rawValue: Int
    static let bold = WriterInline(rawValue: 1 << 0)
    static let italic = WriterInline(rawValue: 1 << 1)
    static let underline = WriterInline(rawValue: 1 << 2)
    static let strikethrough = WriterInline(rawValue: 1 << 3)
    static let code = WriterInline(rawValue: 1 << 4)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ attributes: [NSAttributedString.Key: Any]) {
        var marks: WriterInline = []
        if attributes[.writerBold] as? Bool == true { marks.insert(.bold) }
        if attributes[.writerItalic] as? Bool == true { marks.insert(.italic) }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { marks.insert(.underline) }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { marks.insert(.strikethrough) }
        if attributes[.writerCode] as? Bool == true { marks.insert(.code) }
        self = marks
    }

    /// The attribute that carries this single mark, and its "on" value.
    var attribute: (key: NSAttributedString.Key, value: Any)? {
        switch self {
        case .bold: (.writerBold, true)
        case .italic: (.writerItalic, true)
        case .underline: (.underlineStyle, NSUnderlineStyle.single.rawValue)
        case .strikethrough: (.strikethroughStyle, NSUnderlineStyle.single.rawValue)
        case .code: (.writerCode, true)
        default: nil
        }
    }
}

/// A horizontal line on its own paragraph (Markdown `---`). The editor draws it; see `WriterRuleCell`.
final class WriterRuleAttachment: NSTextAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterRuleCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterRuleCell()
    }
}

/// Converts between the Markdown a document is stored as and the text the editor shows. The text carries only
/// the meaning (block, list level, inline marks); `WriterStyler` adds fonts and colours from it.
enum WriterMarkdown {
    static let lineSeparator: Character = "\u{2028}"

    // MARK: Markdown → text

    static func attributedString(from markdown: String) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var previous: [NSAttributedString.Key: Any]?

        /// Appends a paragraph. Its newline comes with the next paragraph but carries this paragraph's
        /// attributes, so empty paragraphs keep their block too.
        func add(_ paragraph: NSAttributedString, block: WriterBlock, level: Int = 0, language: String? = nil) {
            if let previous { result.append(NSAttributedString(string: "\n", attributes: previous)) }
            var attributes: [NSAttributedString.Key: Any] = [.writerBlock: block.rawValue, .writerListLevel: level]
            if let language, !language.isEmpty { attributes[.writerCodeLanguage] = language }
            let start = result.length
            result.append(paragraph)
            result.addAttributes(attributes, range: NSRange(location: start, length: result.length - start))
            previous = attributes
        }

        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .paragraph(let text):
                add(inline(text.replacingOccurrences(of: "\n", with: String(lineSeparator))), block: .paragraph)
            case .heading(let level, let text):
                let block: WriterBlock = level <= 1 ? .heading1 : level == 2 ? .heading2 : .heading3
                add(inline(text), block: block)
            case .code(let language, let code):
                for line in code.components(separatedBy: "\n") {
                    add(NSAttributedString(string: line), block: .code, language: language)
                }
            case .list(let items):
                for item in items {
                    let text = item.text.replacingOccurrences(of: "\n", with: String(lineSeparator))
                    add(inline(text), block: item.marker == nil ? .bullet : .numbered, level: min(item.level, 5))
                }
            case .quote(let text):
                for line in text.components(separatedBy: "\n") {
                    add(inline(line), block: .quote)
                }
            case .rule:
                let attachment = WriterRuleAttachment()
                add(NSAttributedString(attachment: attachment), block: .rule)
            case .table(let header, let rows):
                let lines = [row(header), row(header.map { _ in "---" })] + rows.map(row)
                for line in lines { add(NSAttributedString(string: line), block: .raw) }
            case .math(let latex, _):
                let lines = latex.hasPrefix("\\begin") ? [latex] : ["$$", latex, "$$"]
                for line in lines.joined(separator: "\n").components(separatedBy: "\n") {
                    add(NSAttributedString(string: line), block: .raw)
                }
            }
        }
        return result
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    /// Inline Markdown: `**bold**`, `*italic*`, `<u>underlined</u>`, `~~struck~~`, `` `code` `` and `[links](url)`.
    static func inline(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendInline(Array(text), marks: [], link: nil, to: result)
        return result
    }

    private static func appendInline(_ characters: [Character], marks initial: WriterInline, link: String?, to result: NSMutableAttributedString) {
        var marks = initial
        var buffer = ""
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: attributes(marks, link: link)))
            buffer = ""
        }
        func matches(_ token: String, at position: Int) -> Bool {
            let token = Array(token)
            guard position + token.count <= characters.count else { return false }
            return Array(characters[position..<position + token.count]) == token
        }
        /// Position of the next unescaped `token` after `position`.
        func closing(_ token: String, after position: Int) -> Int? {
            var scan = position
            while scan < characters.count {
                if characters[scan] == "\\" { scan += 2; continue }
                if matches(token, at: scan) { return scan }
                scan += 1
            }
            return nil
        }
        /// A closing mark follows text, not a space ("3 * 4" has no emphasis).
        func canClose(at position: Int) -> Bool {
            position > 0 && !characters[position - 1].isWhitespace
        }
        func toggle(_ mark: WriterInline, token: String) -> Bool {
            if marks.contains(mark) {
                guard canClose(at: index) else { return false }
                flush()
                marks.remove(mark)
                index += token.count
                return true
            }
            // Opens only before text and when it is closed later, so a lone "*" stays a star.
            let after = index + token.count
            guard after < characters.count, !characters[after].isWhitespace else { return false }
            var search = after
            var end: Int?
            while let candidate = closing(token, after: search) {
                if candidate > after, canClose(at: candidate) { end = candidate; break }
                search = candidate + 1
            }
            guard end != nil else { return false }
            flush()
            marks.insert(mark)
            index += token.count
            return true
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count, characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`" {
                var fence = 0
                while index + fence < characters.count, characters[index + fence] == "`" { fence += 1 }
                let token = String(repeating: "`", count: fence)
                if let end = closing(token, after: index + fence) {
                    flush()
                    var code = String(characters[(index + fence)..<end])
                    if fence > 1, code.hasPrefix(" "), code.hasSuffix(" "), code.count >= 2 {
                        code = String(code.dropFirst().dropLast())
                    }
                    result.append(NSAttributedString(string: code, attributes: attributes(marks.union(.code), link: link)))
                    index = end + fence
                    continue
                }
            }
            if matches("**", at: index), toggle(.bold, token: "**") { continue }
            if matches("__", at: index), toggle(.bold, token: "__") { continue }
            if matches("~~", at: index), toggle(.strikethrough, token: "~~") { continue }
            if matches("<u>", at: index), !marks.contains(.underline), closing("</u>", after: index + 3) != nil {
                flush()
                marks.insert(.underline)
                index += 3
                continue
            }
            if matches("</u>", at: index), marks.contains(.underline) {
                flush()
                marks.remove(.underline)
                index += 4
                continue
            }
            if character == "*", toggle(.italic, token: "*") { continue }
            if character == "_" {
                // Underscores inside words (snake_case) are no emphasis.
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + 1 < characters.count ? characters[index + 1] : " "
                let inWord = (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
                if !inWord, toggle(.italic, token: "_") { continue }
            }
            if character == "[", link == nil, let (text, url, end) = linkSyntax(in: characters, at: index) {
                flush()
                appendInline(text, marks: marks, link: url, to: result)
                index = end
                continue
            }
            buffer.append(character)
            index += 1
        }
        flush()
    }

    /// `[text](url)` starting at `position`: the text, the address and the position after it.
    private static func linkSyntax(in characters: [Character], at position: Int) -> ([Character], String, Int)? {
        var depth = 0
        var scan = position
        var closeBracket: Int?
        while scan < characters.count {
            switch characters[scan] {
            case "\\": scan += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { closeBracket = scan }
            default: break
            }
            if closeBracket != nil { break }
            scan += 1
        }
        guard let closeBracket, closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(",
              let closeParen = characters[(closeBracket + 2)...].firstIndex(of: ")") else { return nil }
        let url = String(characters[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        return (Array(characters[(position + 1)..<closeBracket]), url, closeParen + 1)
    }

    private static func attributes(_ marks: WriterInline, link: String?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        for mark in [WriterInline.bold, .italic, .underline, .strikethrough, .code] where marks.contains(mark) {
            if let attribute = mark.attribute { attributes[attribute.key] = attribute.value }
        }
        if let link { attributes[.link] = link }
        return attributes
    }

    // MARK: Text → Markdown

    struct Paragraph {
        let range: NSRange
        /// Without the newline at the end.
        let contentRange: NSRange
        let block: WriterBlock
        let level: Int
        let language: String?
    }

    static func paragraphs(of text: NSAttributedString, in range: NSRange? = nil) -> [Paragraph] {
        let string = text.string as NSString
        let limit = range ?? NSRange(location: 0, length: string.length)
        var result: [Paragraph] = []
        var location = string.paragraphRange(for: NSRange(location: limit.location, length: 0)).location
        let end = NSMaxRange(limit)
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let attributes = paragraph.length > 0 ? text.attributes(at: paragraph.location, effectiveRange: nil) : [:]
            result.append(Paragraph(
                range: paragraph,
                contentRange: content,
                block: (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph,
                level: attributes[.writerListLevel] as? Int ?? 0,
                language: attributes[.writerCodeLanguage] as? String
            ))
            location = NSMaxRange(paragraph)
        } while location < end && location < string.length
        return result
    }

    static func markdown(from text: NSAttributedString) -> String {
        var blocks: [String] = []
        var pending: [String] = []
        var pendingKind: WriterBlock?
        var listCounters: [Int] = []
        var currentLanguage: String?

        func flush() {
            guard let kind = pendingKind, !pending.isEmpty else { pendingKind = nil; return }
            switch kind {
            case .code:
                let language = currentLanguage ?? ""
                blocks.append("```\(language)\n" + pending.joined(separator: "\n") + "\n```")
            default:
                blocks.append(pending.joined(separator: "\n"))
            }
            pending = []
            pendingKind = nil
            listCounters = []
        }

        for paragraph in paragraphs(of: text) {
            let content = text.attributedSubstring(from: paragraph.contentRange)
            let group: WriterBlock = paragraph.block.isList ? .bullet : paragraph.block
            let grouped: Set<WriterBlock> = [.bullet, .quote, .code, .raw]
            if pendingKind != group || !grouped.contains(group) { flush() }

            switch paragraph.block {
            case .code:
                if pendingKind == nil { currentLanguage = paragraph.language }
                pending.append(plainString(content).replacingOccurrences(of: String(lineSeparator), with: "\n"))
            case .raw:
                pending.append(plainString(content))
            case .rule:
                pending.append("---")
            case .bullet, .numbered:
                let line = inlineMarkdown(content)
                guard !line.isEmpty else { continue }
                let level = paragraph.level
                if listCounters.count <= level { listCounters += Array(repeating: 0, count: level + 1 - listCounters.count) }
                listCounters = Array(listCounters.prefix(level + 1))
                // A bullet between numbered items starts the count again.
                if paragraph.block == .bullet { listCounters[level] = 0 } else { listCounters[level] += 1 }
                let indent = String(repeating: "  ", count: level)
                let marker = paragraph.block == .numbered ? "\(listCounters[level])." : "-"
                pending.append(indent + marker + " " + line.replacingOccurrences(of: "\n", with: "\n" + indent + "  "))
            case .quote:
                let line = inlineMarkdown(content)
                pending.append(line.isEmpty ? ">" : "> " + line.replacingOccurrences(of: "\n", with: "\n> "))
            case .heading1, .heading2, .heading3:
                let line = inlineMarkdown(content).replacingOccurrences(of: "\n", with: " ")
                guard !line.isEmpty else { continue }
                let hashes = paragraph.block == .heading1 ? "#" : paragraph.block == .heading2 ? "##" : "###"
                pending.append(hashes + " " + line)
            case .paragraph:
                let line = inlineMarkdown(content)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                pending.append(line)
            }
            pendingKind = group
        }
        flush()
        // Drop quote lines that were only empty and trailing "> " noise.
        return blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != ">" }
            .joined(separator: "\n\n") + "\n"
    }

    /// The text without dictation that is still being recognised.
    private static func plainString(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.writerDictationPreview, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { result += (text.string as NSString).substring(with: range) }
        }
        return result
    }

    /// One paragraph's text with its inline marks as Markdown. Line breaks inside it become "\n".
    static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var output = ""
        // Marks currently open, outermost first; a link is kept separately as the outermost one.
        var open: [WriterInline] = []
        var openLink: String?
        var pendingSpace = ""
        let order: [WriterInline] = [.bold, .italic, .underline, .strikethrough]

        func closeAll() {
            for mark in open.reversed() { output += closingToken(mark) }
            open = []
            if openLink != nil {
                output += "](\(openLink!))"
                openLink = nil
            }
        }

        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard attributes[.attachment] == nil, attributes[.writerDictationPreview] == nil else { return }
            let raw = (text.string as NSString).substring(with: range)
            let marks = WriterInline(attributes)
            let link: String? = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String

            let leading = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            let rest = raw.dropFirst(leading.count)
            let trailing = String(rest.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            let core = String(rest.dropLast(trailing.count))
            guard !core.isEmpty else {
                pendingSpace += raw
                return
            }

            // Close what this stretch doesn't have, from the inside out.
            if openLink != link {
                closeAll()
            } else if let keep = open.firstIndex(where: { !marks.contains($0) }) {
                for mark in open[keep...].reversed() { output += closingToken(mark) }
                open = Array(open[..<keep])
            }
            output += pendingSpace + leading
            pendingSpace = ""
            if let link, openLink == nil {
                output += "["
                openLink = link
            }
            for mark in order where marks.contains(mark) && !open.contains(mark) {
                output += openingToken(mark)
                open.append(mark)
            }
            if marks.contains(.code) {
                let fence = core.contains("`") ? "`` " : "`"
                output += fence + core + String(fence.reversed())
            } else {
                output += escape(core, atLineStart: output.isEmpty || output.last == "\n")
            }
            pendingSpace = trailing
        }
        closeAll()
        output += pendingSpace
        return output.replacingOccurrences(of: String(lineSeparator), with: "\n")
    }

    private static func openingToken(_ mark: WriterInline) -> String {
        switch mark {
        case .bold: "**"
        case .italic: "*"
        case .underline: "<u>"
        case .strikethrough: "~~"
        default: ""
        }
    }

    private static func closingToken(_ mark: WriterInline) -> String {
        mark == .underline ? "</u>" : openingToken(mark)
    }

    /// Backslashes before characters that would otherwise start Markdown.
    static func escape(_ text: String, atLineStart: Bool) -> String {
        var output = ""
        var lineStart = atLineStart
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if "\\*_`[]<~".contains(character) {
                output += "\\" + String(character)
            } else if lineStart, "#>".contains(character) {
                output += "\\" + String(character)
            } else if lineStart, "-+".contains(character), index + 1 < characters.count, characters[index + 1] == " " {
                output += "\\" + String(character)
            } else if character == ".", index + 1 < characters.count, characters[index + 1] == " ",
                      startsNumberedLine(characters, before: index, atLineStart: atLineStart) {
                output += "\\."
            } else {
                output.append(character)
            }
            lineStart = character == lineSeparator || character == "\n"
        }
        return output
    }

    /// Whether only digits stand between the start of the line and `index` ("1. " would start a list).
    private static func startsNumberedLine(_ characters: [Character], before index: Int, atLineStart: Bool) -> Bool {
        var scan = index - 1
        while scan >= 0, characters[scan].isNumber { scan -= 1 }
        guard scan < index - 1 else { return false }
        if scan < 0 { return atLineStart }
        return characters[scan] == lineSeparator || characters[scan] == "\n"
    }
}
