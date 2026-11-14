import Foundation

/// The pieces of the library's text formats that comparing and merging both need. Kept free of AppKit, so `llmd`
/// can merge as git's merge driver without the app.
public enum MergeText {
    /// Markdown split into blocks at blank lines; code fences, formulas and `:::` boxes stay whole.
    public static func blocks(of markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var fence: String?
        var divDepth = 0
        func close() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(text) }
            current = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                current.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                current.append(line)
                continue
            }
            if trimmed == "$$" || (trimmed.hasPrefix("$$") && !trimmed.dropFirst(2).contains("$$")) {
                fence = "$$"
                current.append(line)
                continue
            }
            if trimmed.hasPrefix(":::") {
                if trimmed.count > 3 { divDepth += 1 } else { divDepth = max(0, divDepth - 1) }
                current.append(line)
                if divDepth == 0 && trimmed.count == 3 { close() }
                continue
            }
            if trimmed.isEmpty && divDepth == 0 {
                close()
            } else {
                current.append(line)
            }
        }
        close()
        return blocks
    }

    /// Words, spaces and punctuation as their own tokens.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord: Bool?
        for character in text {
            let isWord = character.isLetter || character.isNumber
            if isWord, currentIsWord == true {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: Front matter

    /// The header of a document: its lines in order, with key and the value exactly as written.
    public struct Header: Equatable, Sendable {
        public var entries: [(key: String, value: String)]

        public static func == (lhs: Header, rhs: Header) -> Bool {
            lhs.entries.map(\.key) == rhs.entries.map(\.key) && lhs.entries.map(\.value) == rhs.entries.map(\.value)
        }

        public subscript(key: String) -> String? {
            entries.first { $0.key == key }?.value
        }

        public var dictionary: [String: String] {
            Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        var text: String {
            entries.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    /// Header and body of a document file; a file without a header has an empty one.
    public static func split(_ text: String) -> (header: Header?, body: String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return (nil, text)
        }
        var entries: [(key: String, value: String)] = []
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
            entries.append((key, String(value)))
        }
        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (Header(entries: entries), body)
    }

    /// The same layout the app writes: `---`, the lines, `---`, a blank line, the body.
    public static func join(header: Header?, body: String) -> String {
        guard let header else { return body }
        return "---\n" + header.text + "\n---\n\n" + body
    }

    // MARK: Slides

    /// One slide of a presentation file.
    public struct Slide: Sendable {
        public var id: String
        /// The JSON in `<!-- folie {…} -->`, as written.
        public var metaLine: String
        public var text: String
        public var notes: String
        public var raw: String

        public var meta: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(metaLine.utf8))) as? [String: Any] ?? [:]
        }

        /// The first heading, without attributes; "Folie n" when there is none.
        public func title(at index: Int) -> String {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("#") }) else { return "Folie \(index + 1)" }
            let stripped = String(line.drop { $0 == "#" || $0 == " " })
            return stripped.replacingOccurrences(of: #"\s*\{[^}]*\}\s*$"#, with: "", options: .regularExpression)
        }

        /// The slide as `PresentationDeck.serialized` writes it.
        public static func assemble(metaLine: String, text: String, notes: String) -> String {
            var parts = ["<!-- folie \(metaLine) -->"]
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { parts.append("<!-- moderation\n" + notes.replacingOccurrences(of: "-->", with: "-- >") + "\n-->") }
            return parts.joined(separator: "\n\n")
        }
    }

    /// Splits a presentation's body at its `<!-- folie {…} -->` lines. Text before the first marker is a slide of its own.
    public static func slides(of body: String) -> [Slide] {
        var chunks: [[Substring]] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("<!-- folie") {
                chunks.append([line])
            } else if chunks.isEmpty {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { chunks.append([line]) }
            } else {
                chunks[chunks.count - 1].append(line)
            }
        }
        return chunks.enumerated().map { index, lines in
            let raw = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            var metaLine = "{}"
            var content = lines[...]
            if let first = lines.first, first.hasPrefix("<!-- folie"), let open = first.firstIndex(of: "{"), let close = first.lastIndex(of: "}") {
                metaLine = String(first[open...close])
                content = lines.dropFirst()
            }
            var textLines: [Substring] = []
            var noteLines: [Substring] = []
            var inNotes = false
            for line in content {
                if line.hasPrefix("<!-- moderation") {
                    inNotes = true
                    continue
                }
                if inNotes {
                    if line.hasPrefix("-->") { inNotes = false } else { noteLines.append(line) }
                    continue
                }
                textLines.append(line)
            }
            let meta = (try? JSONSerialization.jsonObject(with: Data(metaLine.utf8))) as? [String: Any]
            let id = (meta?["id"] as? String) ?? "folie-\(index)"
            return Slide(id: id, metaLine: metaLine,
                         text: textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                         notes: noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                         raw: raw)
        }
    }

    /// A short preview of a text for labels.
    public static func preview(_ text: String?, _ limit: Int = 40) -> String {
        guard let text else { return "" }
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        let plain = line.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*+ "))
        return plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
    }
}
