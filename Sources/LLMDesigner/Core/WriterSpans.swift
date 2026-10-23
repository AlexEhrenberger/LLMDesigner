import AppKit

/// What Markdown can't say about a passage: its colour and its font. A document stores it as an HTML span,
/// `<span style="color:#C0392B;font-family:'Georgia'">…</span>`: other programs show it, and the Markdown export
/// can leave it out (`WriterSpans.strippingStyles`).
struct WriterSpanStyle: Hashable {
    /// Six hex digits, upper case, without "#". For the palette colours this is the colour on white paper.
    var color: String?
    var font: WriterFont?

    init(color: String? = nil, font: WriterFont? = nil) {
        self.color = color
        self.font = font
    }

    /// The style a stretch of text carries (`.writerColor`, `.writerFont`).
    init(_ attributes: [NSAttributedString.Key: Any]) {
        color = attributes[.writerColor] as? String
        font = (attributes[.writerFont] as? String).flatMap(WriterFont.init(rawValue:))
    }

    var isEmpty: Bool { color == nil && font == nil }

    /// The meaning attributes of this style.
    var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color { attributes[.writerColor] = color }
        if let font { attributes[.writerFont] = font.rawValue }
        return attributes
    }

    var openingTag: String {
        var parts: [String] = []
        if let color { parts.append("color:#\(color)") }
        if let font { parts.append("font-family:\(font.cssFamily)") }
        return "<span style=\"\(parts.joined(separator: ";"))\">"
    }

    /// The style in a `<span style="…">` tag; nil if the tag has none (a bookmark, or an unknown span).
    init?(tag: String) {
        guard let style = WriterSpans.attributes(of: tag)["style"] else { return nil }
        var parsed = WriterSpanStyle()
        for declaration in style.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch property {
            case "color": parsed.color = WriterColors.parse(value)
            case "font-family": parsed.font = WriterFont.fromCSS(value)
            default: break
            }
        }
        guard !parsed.isEmpty else { return nil }
        self = parsed
    }

    /// This style on top of an outer one: what it sets wins.
    func over(_ outer: WriterSpanStyle?) -> WriterSpanStyle {
        WriterSpanStyle(color: color ?? outer?.color, font: font ?? outer?.font)
    }
}

/// The colours Writer Studio offers. Each exists twice: as ink on white paper (and in print), and brighter for dark
/// paper and dark slides. The document stores the first; the editor shows the second where the background is dark,
/// so a colour stays readable when the paper is switched.
enum WriterColors {
    struct Entry: Identifiable, Hashable {
        let name: String
        let print: UInt32
        let dark: UInt32
        var id: String { name }
        var printHex: String { WriterColors.string(print) }
    }

    static let palette: [Entry] = [
        Entry(name: "Rot", print: 0xC0392B, dark: 0xFF7B72),
        Entry(name: "Orange", print: 0xD35400, dark: 0xFFA657),
        Entry(name: "Gold", print: 0xB7791F, dark: 0xE3B341),
        Entry(name: "Grün", print: 0x1E8449, dark: 0x56D364),
        Entry(name: "Türkis", print: 0x148F8F, dark: 0x39D0D0),
        Entry(name: "Blau", print: 0x1F5FBF, dark: 0x79B8FF),
        Entry(name: "Violett", print: 0x7B3FC4, dark: 0xC3A6FF),
        Entry(name: "Rosa", print: 0xC2185B, dark: 0xFF7EB6),
        Entry(name: "Grau", print: 0x6B6B76, dark: 0xA1A1A9),
    ]

    static func string(_ value: UInt32) -> String {
        String(format: "%06X", value & 0xFFFFFF)
    }

    /// The colour as it is shown: a palette colour brightens on a dark background, any other stays as chosen.
    static func display(_ hex: String, onDark: Bool) -> NSColor? {
        guard let value = UInt32(hex, radix: 16), hex.count == 6 else { return nil }
        if onDark, let entry = palette.first(where: { $0.print == value }) { return NSColor(hex: entry.dark) }
        return NSColor(hex: value)
    }

    /// The colour in the toolbar and the picker (the UI is always dark).
    static func swatch(_ hex: String) -> NSColor {
        display(hex, onDark: true) ?? .white
    }

    /// Six hex digits for a CSS colour: `#RRGGBB`, `#RGB`, `rgb(r, g, b)` or a common name.
    static func parse(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            var digits = String(text.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
            return digits.uppercased()
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") {
            let numbers = text[text.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
            guard numbers.count >= 3 else { return nil }
            return String(format: "%02X%02X%02X", min(255, max(0, numbers[0])), min(255, max(0, numbers[1])), min(255, max(0, numbers[2])))
        }
        let names: [String: UInt32] = [
            "red": 0xC0392B, "orange": 0xD35400, "gold": 0xB7791F, "green": 0x1E8449, "teal": 0x148F8F, "blue": 0x1F5FBF,
            "purple": 0x7B3FC4, "violet": 0x7B3FC4, "pink": 0xC2185B, "gray": 0x6B6B76, "grey": 0x6B6B76,
            "black": 0x000000, "white": 0xFFFFFF,
        ]
        return names[text].map(string)
    }

    /// Six hex digits of any colour (in sRGB).
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
        return string(byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent))
    }
}

/// Reading the `<span>` tags of a stored document. A span is a bookmark (`id`), a style (`style`) or both nested.
enum WriterSpans {
    struct Token {
        let range: NSRange
        let isOpening: Bool
        let tag: String
    }

    private static let tagExpression = try! NSRegularExpression(pattern: #"<span\b[^>]*>|</span\s*>"#, options: [.caseInsensitive])
    private static let attributeExpression = try! NSRegularExpression(pattern: #"([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    /// The opening and closing span tags of the text, in order.
    static func tokens(in text: String) -> [Token] {
        guard text.contains("<span") || text.contains("<SPAN") else { return [] }
        let string = text as NSString
        return tagExpression.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            let tag = string.substring(with: match.range)
            return Token(range: match.range, isOpening: !tag.hasPrefix("</"), tag: tag)
        }
    }

    /// The attributes of a tag, names in lower case, values unescaped.
    static func attributes(of tag: String) -> [String: String] {
        let string = tag as NSString
        var values: [String: String] = [:]
        for match in attributeExpression.matches(in: tag, range: NSRange(location: 0, length: string.length)) {
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            guard valueRange.location != NSNotFound else { continue }
            values[string.substring(with: match.range(at: 1)).lowercased()] = WriterBookmark.unescapeAttribute(string.substring(with: valueRange))
        }
        return values
    }

    /// The position of the `</span>` that closes the span whose content starts at `start` (a span in the text may
    /// contain others).
    static func closing(in characters: [Character], from start: Int) -> Int? {
        var depth = 1
        var index = start
        let open = Array("<span"), close = Array("</span>")
        while index < characters.count {
            if characters[index] == "<" {
                if matches(close, in: characters, at: index) {
                    depth -= 1
                    if depth == 0 { return index }
                    index += close.count
                    continue
                }
                if matches(open, in: characters, at: index), index + open.count < characters.count,
                   characters[index + open.count] == " " || characters[index + open.count] == ">" {
                    depth += 1
                }
            }
            index += 1
        }
        return nil
    }

    private static func matches(_ pattern: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index + pattern.count <= characters.count else { return false }
        for offset in 0..<pattern.count where characters[index + offset] != pattern[offset] { return false }
        return true
    }

    /// The fonts the spans of a document set (for the LaTeX preamble).
    static func fonts(in markdown: String) -> [WriterFont] {
        var seen: [WriterFont] = []
        for token in tokens(in: markdown) where token.isOpening {
            if let font = WriterSpanStyle(tag: token.tag)?.font, !seen.contains(font) { seen.append(font) }
        }
        return seen
    }

    static func hasStyles(_ markdown: String) -> Bool {
        tokens(in: markdown).contains { $0.isOpening && WriterSpanStyle(tag: $0.tag) != nil }
    }

    /// Markdown without the colour and font spans (bookmark spans stay): plain Markdown for programs that only know
    /// Markdown.
    static func strippingStyles(_ markdown: String) -> String {
        let tokens = tokens(in: markdown)
        guard !tokens.isEmpty else { return markdown }
        // Which opening tags are styles; a closing tag belongs to the opening tag it matches.
        var stack: [Bool] = []
        var remove: [NSRange] = []
        for token in tokens {
            if token.isOpening {
                let isStyle = WriterSpanStyle(tag: token.tag) != nil && WriterSpans.attributes(of: token.tag)["id"] == nil
                stack.append(isStyle)
                if isStyle { remove.append(token.range) }
            } else if let isStyle = stack.popLast(), isStyle {
                remove.append(token.range)
            }
        }
        let result = NSMutableString(string: markdown)
        for range in remove.sorted(by: { $0.location > $1.location }) { result.deleteCharacters(in: range) }
        return result as String
    }
}
