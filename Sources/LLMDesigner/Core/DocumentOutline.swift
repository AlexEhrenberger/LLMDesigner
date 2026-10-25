import Foundation

/// How the contents panel of a document lists it.
enum WriterTOCMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Topics the model finds in the text, kept up to date like the chat's outline.
    case dynamic
    /// The document's own chapters and headings.
    case headings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dynamic: "Dynamisch"
        case .headings: "Überschriften"
        }
    }
}

/// A place in a document for the dynamic table of contents. Paragraphs move while the user writes, so the
/// place is found again by the beginning of its text; the block number only breaks ties.
struct DocumentAnchor: Codable, Hashable, Sendable {
    var block: Int
    /// Letters and digits of the paragraph's beginning, lower case.
    var key: String
}

struct DocumentOutlineItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var anchor: DocumentAnchor
}

struct DocumentOutlineSection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var anchor: DocumentAnchor
    var items: [DocumentOutlineItem]
}

/// The model's table of contents of a document, stored with the document.
struct DocumentOutline: Codable, Hashable, Sendable {
    var summary: String
    var sections: [DocumentOutlineSection]
    /// The text it was made from: its length and a checksum, to tell how much changed since.
    var sourceLength: Int
    var sourceChecksum: UInt64
    var generatedAt: Date
    var model: String?
}

/// Builds the request for the dynamic table of contents of a document and reads the answer.
enum DocumentOutlineBuilder {
    static let minimumWords = 150
    /// Changed characters after which the outline is made anew by itself (while the panel is open).
    static let refreshThreshold = 280
    private static let textBudget = 12_000

    static func wordCount(_ markdown: String) -> Int {
        WriterMarkdown.removingDivFences(WriterBookmark.strip(markdown)).split { $0.isWhitespace || $0.isNewline }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    static func isLongEnough(_ markdown: String) -> Bool {
        wordCount(markdown) >= minimumWords
    }

    /// FNV-1a over the text; stable between launches (Swift's `hashValue` is not).
    static func checksum(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// The checksum of what the outline is about: the text of the paragraphs, without bookmarks, pictures or the
    /// table of contents marker, so switching those doesn't make the outline look outdated.
    static func contentChecksum(_ markdown: String) -> UInt64 {
        checksum(blocks(of: markdown).map(\.text).joined(separator: "\n"))
    }

    static func isOutdated(_ document: WriterDocument) -> Bool {
        guard let outline = document.outline else { return true }
        return outline.sourceChecksum != contentChecksum(document.markdown)
    }

    /// Changed enough to make the outline anew without being asked: a good piece of text, or other headings.
    static func needsRefresh(_ document: WriterDocument) -> Bool {
        guard isLongEnough(document.markdown) else { return false }
        guard let outline = document.outline else { return true }
        guard outline.sourceChecksum != contentChecksum(document.markdown) else { return false }
        return abs(document.markdown.count - outline.sourceLength) >= refreshThreshold
    }

    // MARK: Blocks

    struct Block {
        let index: Int
        let text: String
        let isHeading: Bool
        var key: String { searchKey(text) }
    }

    /// The document's paragraphs as plain text, numbered like Markdown blocks. Pictures, lines and the table of
    /// contents are left out.
    static func blocks(of markdown: String) -> [Block] {
        MarkdownParser.parse(WriterBookmark.strip(markdown)).enumerated().compactMap { index, block in
            let text: String
            var isHeading = false
            switch block {
            case .paragraph(let paragraph):
                text = paragraph.components(separatedBy: "\n")
                    .filter { WriterImageReference.parse($0) == nil && !WriterTOCAttachment.isMarker($0) }
                    .joined(separator: " ")
            case .heading(_, let heading):
                text = WriterMarkdown.headingAttributes(heading).text
                isHeading = true
            case .list(let items): text = items.map(\.text).joined(separator: " · ")
            case .quote(let quote): text = quote
            case .table(let header, let rows, _, _): text = (header + rows.flatMap { $0 }).joined(separator: " | ")
            case .code: text = "[Code]"
            case .math(let latex, _): text = "[Formel: \(latex)]"
            case .rule: return nil
            }
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : Block(index: index, text: plain, isHeading: isHeading)
        }
    }

    /// Letters and digits only, lower case, at most 40: rendered text and Markdown match although markup differs.
    static func searchKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(40))
    }

    /// Whether a paragraph with this key is the anchored one: one key starts the other and they share enough.
    static func matches(_ key: String, anchor: String) -> Bool {
        guard !key.isEmpty, !anchor.isEmpty else { return false }
        let shorter = min(key.count, anchor.count)
        guard shorter >= min(8, anchor.count) else { return false }
        return key.hasPrefix(anchor) || anchor.hasPrefix(key)
    }

    /// The Markdown block a place is in now: the one that begins like it, the nearest to its old number when several do.
    static func blockIndex(of anchor: DocumentAnchor, in markdown: String) -> Int? {
        blocks(of: markdown).filter { matches($0.key, anchor: anchor.key) }
            .min { abs($0.index - anchor.block) < abs($1.index - anchor.block) }?.index
    }

    // MARK: Request

    static let schemaName = "dokument_inhaltsverzeichnis"

    static let schema: [String: Any] = {
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["titel": ["type": "string"], "ziel": ["type": "string"]],
            "required": ["titel", "ziel"],
        ]
        let section: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "titel": ["type": "string"],
                "ziel": ["type": "string"],
                "unterpunkte": ["type": "array", "items": item],
            ],
            "required": ["titel", "ziel", "unterpunkte"],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "properties": [
                "zusammenfassung": ["type": "string"],
                "themen": ["type": "array", "items": section],
            ],
            "required": ["zusammenfassung", "themen"],
        ]
    }()

    static func requestMessages(for markdown: String) -> [ChatPayloadMessage] {
        let system = """
        Du erstellst ein Inhaltsverzeichnis für ein Dokument, das jemand gerade schreibt.
        - Gliedere das Dokument der Reihe nach in 2 bis 8 Hauptthemen mit kurzen, aussagekräftigen Titeln (höchstens 6 Wörter).
        - Jedes Thema hat 0 bis 6 Unterpunkte für wichtige Teilaspekte.
        - „ziel“ ist immer genau eine Absatznummer aus den eckigen Klammern, z. B. "7".
        - Ein Thema verweist auf den Absatz, in dem es beginnt. Ist dort eine Überschrift, nimm sie.
        - Unterpunkte liegen nach dem Beginn ihres Themas und vor dem nächsten Thema.
        - Titel enthalten keine Nummern oder Verweise in Klammern.
        - „zusammenfassung“: ein Satz, worum es im Dokument geht.
        - Schreibe auf Deutsch.
        """
        return [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: numberedText(markdown)),
        ]
    }

    private static func numberedText(_ markdown: String) -> String {
        let blocks = blocks(of: markdown)
        let perBlock = max(140, textBudget / max(blocks.count, 1))
        return blocks.map { block in
            let collapsed = block.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let text = collapsed.count > perBlock ? String(collapsed.prefix(perBlock)) + " …" : collapsed
            return "[\(block.index)] " + (block.isHeading ? "Überschrift: " : "") + text
        }.joined(separator: "\n")
    }

    // MARK: Response

    private struct Response: Decodable {
        struct Topic: Decodable {
            let titel: String
            let ziel: String
            let unterpunkte: [Point]
        }
        struct Point: Decodable {
            let titel: String
            let ziel: String
        }
        let zusammenfassung: String
        let themen: [Topic]
    }

    /// Reads the model's answer; the places are resolved against `markdown`, the text the request was made from.
    static func parse(_ answer: String, markdown: String, model: String?) throws -> DocumentOutline {
        var json = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}") {
            json = String(json[start...end])
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        let blocks = Dictionary(blocks(of: markdown).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        func anchor(_ reference: String) -> DocumentAnchor? {
            guard let digits = reference.firstIndex(where: \.isNumber),
                  let number = Int(reference[digits...].prefix(while: \.isNumber)), let block = blocks[number] else { return nil }
            return DocumentAnchor(block: number, key: block.key)
        }

        // Topics in text order; every point goes to the topic it follows (small models mix up the grouping).
        var sections: [DocumentOutlineSection] = []
        var points: [DocumentOutlineItem] = []
        for topic in response.themen {
            let topicPoints = topic.unterpunkte.compactMap { point in
                anchor(point.ziel).map { DocumentOutlineItem(title: cleanTitle(point.titel), anchor: $0) }
            }
            guard let start = anchor(topic.ziel) ?? topicPoints.first?.anchor else { continue }
            guard !sections.contains(where: { $0.anchor.block == start.block }) else {
                points += topicPoints
                continue
            }
            sections.append(DocumentOutlineSection(title: cleanTitle(topic.titel), anchor: start, items: []))
            points += topicPoints
        }
        sections.sort { $0.anchor.block < $1.anchor.block }
        guard !sections.isEmpty else { throw LMStudioError.server("Das Modell hat kein verwertbares Inhaltsverzeichnis geliefert.") }

        var seen = Set<String>()
        for point in points.sorted(by: { $0.anchor.block < $1.anchor.block }) {
            guard seen.insert("\(point.anchor.block)|\(point.title)").inserted else { continue }
            let owner = sections.lastIndex { $0.anchor.block <= point.anchor.block } ?? 0
            // A point on the topic's own paragraph adds nothing.
            if sections[owner].anchor.block == point.anchor.block, sections[owner].items.isEmpty, point.title == sections[owner].title { continue }
            sections[owner].items.append(point)
        }

        return DocumentOutline(
            summary: response.zusammenfassung.trimmingCharacters(in: .whitespacesAndNewlines),
            sections: sections,
            sourceLength: markdown.count,
            sourceChecksum: contentChecksum(markdown),
            generatedAt: Date(),
            model: model
        )
    }

    private static func cleanTitle(_ text: String) -> String {
        var title = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\s*[\[(]\s*(Absatz\s*)?\d+(\s*[-–,/]\s*\d+)*\s*[\])]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix(":") { title.removeLast() }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
