import Foundation

/// A document as the power access shows it: blocks of Markdown one after the other (a heading, a paragraph, a list,
/// a table, a code block, a box …). Each can be dragged out whole; text dropped between two becomes blocks of its own.
/// Nothing is lost: joining the blocks gives the document back (up to the blank lines between them).
struct PowerChunk: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case heading(Int)
        case paragraph, list, quote, code, table, math, image, box, other
    }

    /// The block's place in the document.
    let id: Int
    let markdown: String
    let kind: Kind

    /// The text without Markdown, for showing and for other programs.
    var plain: String { PowerText.plain(markdown) }
}

enum PowerText {
    /// The blocks of a document: split at blank lines, but fenced code, display formulas and Pandoc divs (boxes,
    /// columns, alignment) stay whole.
    static func chunks(of markdown: String) -> [PowerChunk] {
        var chunks: [PowerChunk] = []
        var current: [String] = []
        var fence: String?
        /// While in display math: the delimiter that ends it.
        var mathClose: String?
        var divDepth = 0

        func close() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            current = []
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            chunks.append(PowerChunk(id: chunks.count, markdown: text, kind: kind(of: text)))
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                current.append(line)
                if MarkdownParser.closesFence(trimmed, open) { fence = nil }
                continue
            }
            if let close = mathClose {
                current.append(line)
                // As in `MarkdownParser`: the math ends on the first line that holds its closing delimiter.
                if line.contains(close) { mathClose = nil }
                continue
            }
            if let open = MarkdownParser.fenceOpening(trimmed) {
                if divDepth == 0 { close() }
                fence = open
                current.append(line)
                continue
            }
            if let (open, close) = MarkdownParser.displayMathDelimiters(for: trimmed) {
                current.append(line)
                // Math that closes on its own line is done there; otherwise it takes the lines up to its close.
                if !trimmed.dropFirst(open.count).contains(close) { mathClose = close }
                continue
            }
            if MarkdownParser.divOpening(line) != nil {
                if divDepth == 0 { close() }
                divDepth += 1
                current.append(line)
                continue
            }
            if divDepth > 0, MarkdownParser.isDivClosing(line) {
                divDepth -= 1
                current.append(line)
                if divDepth == 0 { close() }
                continue
            }
            if trimmed.isEmpty, divDepth == 0 {
                close()
                continue
            }
            current.append(line)
        }
        close()
        return chunks
    }

    private static func kind(of markdown: String) -> PowerChunk.Kind {
        let first = markdown.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if MarkdownParser.divOpening(first) != nil { return first.contains(".box") ? .box : first.contains(".\(WriterTableStyle.className)") ? .table : .other }
        if MarkdownParser.fenceOpening(first) != nil { return .code }
        if MarkdownParser.displayMathDelimiters(for: first) != nil { return .math }
        if first.hasPrefix("#") {
            let level = first.prefix { $0 == "#" }.count
            if level <= 6, first.dropFirst(level).first == " " { return .heading(level) }
        }
        if first.hasPrefix("|"), let second = markdown.components(separatedBy: "\n").dropFirst().first, MarkdownParser.isTableSeparator(second) { return .table }
        if first.hasPrefix(">") { return .quote }
        if WriterImageReference.parse(first) != nil { return .image }
        if first.hasPrefix("- ") || first.hasPrefix("* ") || first.hasPrefix("+ ")
            || first.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil { return .list }
        return .paragraph
    }

    // MARK: Changing

    /// The document with `markdown` put in as blocks of its own before block `index` (at the end when it is past the last).
    static func inserting(_ markdown: String, at index: Int, into document: String) -> String {
        var blocks = chunks(of: document).map(\.markdown)
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return document }
        blocks.insert(text, at: min(max(0, index), blocks.count))
        return join(blocks)
    }

    static func replacing(_ index: Int, with markdown: String, in document: String) -> String {
        var blocks = chunks(of: document).map(\.markdown)
        guard blocks.indices.contains(index) else { return document }
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { blocks.remove(at: index) } else { blocks[index] = text }
        return join(blocks)
    }

    static func moving(_ index: Int, to destination: Int, in document: String) -> String {
        var blocks = chunks(of: document).map(\.markdown)
        guard blocks.indices.contains(index) else { return document }
        let block = blocks.remove(at: index)
        blocks.insert(block, at: min(max(0, destination > index ? destination - 1 : destination), blocks.count))
        return join(blocks)
    }

    static func join(_ blocks: [String]) -> String {
        blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    // MARK: Plain text

    /// Markdown as plain text: no marks, no fences, no attributes; pictures by their caption, list items with a dot.
    static func plain(_ markdown: String) -> String {
        // Blocks are what repeats; a whole long text is neither looked up nor kept (`utf8.count` doesn't walk it).
        let isBlock = markdown.utf8.count < 20_000
        if isBlock, let cached = plainCache.object(forKey: markdown as NSString) { return cached as String }
        let lines = plainLines(markdown)
        let text = markdown.contains("\\") ? restoreEscapes(lines) : lines
        if isBlock { plainCache.setObject(text as NSString, forKey: markdown as NSString) }
        return text
    }

    /// Blocks are converted again and again (lists, searches, addresses); a block that didn't change gives the same.
    nonisolated(unsafe) private static let plainCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 20_000
        return cache
    }()

    /// What a backslash escapes is text: it is set aside as a character of its own while the marks go, so no pattern
    /// takes it for a mark (`\*Stern\*`, `\<span…>`, `\$5`), and comes back at the end.
    private static let escapeBase: UInt32 = 0xF0000

    static func protectEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var scalars = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let scalar = pending {
            let next = iterator.next()
            if scalar == "\\", let escaped = next, (33...126).contains(escaped.value),
               !CharacterSet.alphanumerics.contains(escaped), let placeholder = UnicodeScalar(escapeBase + escaped.value) {
                scalars.append(placeholder)
                pending = iterator.next()
                continue
            }
            scalars.append(scalar)
            pending = next
        }
        return String(scalars)
    }

    static func restoreEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= escapeBase && $0.value < escapeBase + 128 }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= escapeBase, scalar.value < escapeBase + 128, let original = UnicodeScalar(scalar.value - escapeBase) {
                scalars.append(original)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func plainLines(_ markdown: String) -> String {
        var lines: [String] = []
        var fence: String?
        for raw in markdown.components(separatedBy: "\n") {
            let bare = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                // In code a backslash is a backslash.
                if MarkdownParser.closesFence(bare, open) { fence = nil } else { lines.append(raw) }
                continue
            }
            if let open = MarkdownParser.fenceOpening(bare) {
                fence = open
                continue
            }
            var line = WriterBookmark.strip(protectEscapes(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if MarkdownParser.divOpening(trimmed) != nil || MarkdownParser.isDivClosing(trimmed) { continue }
            if let image = WriterImageReference.parse(trimmed) {
                lines.append(image.caption.isEmpty ? "[Bild]" : "[Bild: \(image.caption)]")
                continue
            }
            // A table's separator line.
            if trimmed.contains("|"), trimmed.contains("--"), trimmed.allSatisfy({ "|-: ".contains($0) }) { continue }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                lines.append(cells.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "  ·  "))
                continue
            }
            if trimmed.hasPrefix("#") {
                line = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                // `{.chapter}` and other attributes after a heading.
                if let brace = line.range(of: #"\s*\{[^}]*\}\s*$"#, options: .regularExpression) { line.removeSubrange(brace) }
                lines.append(inline(line))
                continue
            }
            if trimmed.hasPrefix(">") {
                lines.append(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let marker = trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                let indent = String(repeating: "  ", count: (line.prefix { $0 == " " }.count) / 2)
                let number = trimmed[marker].trimmingCharacters(in: .whitespaces)
                let bullet = number.first?.isNumber == true ? number : "•"
                lines.append(indent + bullet + " " + inline(String(trimmed[marker.upperBound...])))
                continue
            }
            lines.append(inline(trimmed))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The marks of a line: bold, italics, underline, code, links, spans; citations stay as they are.
    static func inline(_ text: String) -> String {
        var text = text
        let patterns: [(String, String)] = [
            (#"<span[^>]*>"#, ""), (#"</span>"#, ""), (#"</?u>"#, ""), (#"</?su[bp]>"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)(\{[^}]*\})?"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"), (#"__([^_]+)__"#, "$1"),
            (#"(?<![\w*])\*([^*\s][^*]*)\*(?!\w)"#, "$1"), (#"(?<!\w)_([^_\s][^_]*)_(?!\w)"#, "$1"),
            (#"~~([^~]+)~~"#, "$1"), (#"`([^`]+)`"#, "$1"),
            (#"\\([\\`*_{}\[\]()#+\-.!:|])"#, "$1"),
        ]
        for (pattern, template) in patterns {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// Plain text dropped into a document or onto a slide: paragraphs stay paragraphs; lines that look like a list
    /// stay a list. Markdown from Writer Studio comes in as it is.
    static func markdown(fromPlain text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("• ") || trimmed.hasPrefix("· ") { return "- " + trimmed.dropFirst(2) }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a search finds the query, case and accents ignored.
    static func matches(_ text: String, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A short piece of `text` around the first place of `query`, for the result list.
    static func snippet(of text: String, around query: String, radius: Int = 60) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
    }
}
