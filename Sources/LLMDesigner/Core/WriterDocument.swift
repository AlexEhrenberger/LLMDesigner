import Foundation

/// A document written in Writer Studio. It lives in the sidebar next to the chats and is stored as Markdown.
struct WriterDocument: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    /// Set once the user renames the document; otherwise the title follows the first line of the text.
    var hasCustomTitle = false
    var createdAt = Date()
    var updatedAt = Date()
    var folderID: Folder.ID?
    var font: WriterFont = .serif
    var markdown = ""
    /// How the contents panel lists the document; nil: by its headings if it has any, else dynamically.
    var tocMode: WriterTOCMode?
    /// The model's table of contents (dynamic mode).
    var outline: DocumentOutline?
    /// Set for a presentation (Presenter Studio): its slides. `markdown` then holds the slides' text one after the
    /// other (see `PresentationDeck.plainMarkdown`), so search, citations and the content analysis work on it.
    var deck: PresentationDeck? {
        didSet { if let deck { markdown = deck.plainMarkdown } }
    }

    var isPresentation: Bool { deck != nil }

    static func newPresentation() -> WriterDocument {
        var document = WriterDocument()
        document.deck = .new()
        document.font = .sans
        return document
    }

    var effectiveTOCMode: WriterTOCMode {
        tocMode ?? (markdown.contains("\n#") || markdown.hasPrefix("#") ? .headings : .dynamic)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (isPresentation ? "Unbenannte Präsentation" : "Unbenanntes Dokument") : trimmed
    }

    var isEmpty: Bool {
        if let deck { return deck.slides.allSatisfy(\.isEmpty) && deck.slides.count <= 1 }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || displayTitle.localizedStandardContains(query) || markdown.localizedStandardContains(query)
            || deck?.slides.contains { $0.notes.localizedStandardContains(query) } == true
    }

    /// The first line of the text without Markdown marks, as the automatic title.
    static func makeTitle(from markdown: String) -> String {
        // Pictures, tables, formulas and the table of contents don't make a title; the first line of text does.
        let line = WriterBookmark.strip(markdown).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && WriterImageReference.parse($0) == nil
                && !$0.hasPrefix("$$") && !$0.hasPrefix("\\begin") && !WriterTOCAttachment.isMarker($0)
                && !$0.allSatisfy { "-*_ ".contains($0) } }
            .map { WriterMarkdown.headingAttributes($0).text } ?? ""
        var text = line.drop { "#>-*+ ".contains($0) }
        if let digits = text.firstIndex(where: { !$0.isNumber }), digits != text.startIndex,
           text[digits] == ".", text[text.index(after: digits)...].first == " " {
            text = text[text.index(digits, offsetBy: 2)...]
        }
        let plain = String(text)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "<u>", with: "")
            .replacingOccurrences(of: "</u>", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard plain.count > 60 else { return plain }
        return String(plain.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The typeface of a whole document. Markdown has no fonts per passage, so the choice belongs to the document.
enum WriterFont: String, CaseIterable, Identifiable, Sendable {
    case serif, sans, rounded, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "New York (Serifen)"
        case .sans: "SF Pro"
        case .rounded: "SF Pro Rounded"
        case .mono: "SF Mono"
        }
    }
}

/// Every document is a Markdown file with a short header (front matter) in the library's `Documents` folder.
struct WriterDocumentStore {
    let directory: URL

    static var defaultDirectory: URL {
        AppLibrary.current.folder("Documents")
    }

    init() {
        directory = Self.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() -> [WriterDocument] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> WriterDocument? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    print("LLMDesigner: Dokument \(url.lastPathComponent) konnte nicht gelesen werden")
                    return nil
                }
                return Self.decode(text, fallbackID: UUID(uuidString: url.deletingPathExtension().lastPathComponent))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ document: WriterDocument) {
        do {
            try Self.encode(document).write(to: url(for: document.id), atomically: true, encoding: .utf8)
        } catch {
            print("LLMDesigner: Dokument \(document.id) konnte nicht gespeichert werden: \(error)")
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    // MARK: Front matter

    private static let dateFormat = Date.ISO8601FormatStyle()

    static func encode(_ document: WriterDocument) -> String {
        var header = [
            "id: \(document.id.uuidString)",
            "title: \(document.title.replacingOccurrences(of: "\n", with: " "))",
            "customTitle: \(document.hasCustomTitle)",
            "created: \(document.createdAt.formatted(dateFormat))",
            "updated: \(document.updatedAt.formatted(dateFormat))",
            "font: \(document.font.rawValue)",
        ]
        if let folderID = document.folderID { header.append("folder: \(folderID.uuidString)") }
        if let deck = document.deck {
            header.append("kind: presentation")
            header.append("backgrounds: \(deck.backgroundsLine)")
        }
        if let mode = document.tocMode { header.append("toc: \(mode.rawValue)") }
        // One line of JSON, which is also valid YAML.
        if let outline = document.outline, let data = try? JSONEncoder.outline.encode(outline), let json = String(data: data, encoding: .utf8) {
            header.append("outline: \(json)")
        }
        return "---\n" + header.joined(separator: "\n") + "\n---\n\n" + (document.deck?.serialized ?? document.markdown)
    }

    static func decode(_ text: String, fallbackID: UUID?) -> WriterDocument? {
        var document = WriterDocument()
        var body = Substring(text)
        var isPresentation = false
        var backgrounds: RoleBackgrounds?
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "id": document.id = UUID(uuidString: value) ?? document.id
                case "title": document.title = value
                case "customTitle": document.hasCustomTitle = value == "true"
                case "created": document.createdAt = (try? dateFormat.parse(value)) ?? document.createdAt
                case "updated": document.updatedAt = (try? dateFormat.parse(value)) ?? document.updatedAt
                case "font": document.font = WriterFont(rawValue: value) ?? .serif
                case "folder": document.folderID = UUID(uuidString: value)
                case "toc": document.tocMode = WriterTOCMode(rawValue: value)
                case "outline": document.outline = try? JSONDecoder.outline.decode(DocumentOutline.self, from: Data(value.utf8))
                case "kind": isPresentation = value == "presentation"
                case "backgrounds": backgrounds = PresentationDeck.backgrounds(from: value)
                default: break
                }
            }
            body = text[end.upperBound...]
            if body.hasPrefix("\n") { body = body.dropFirst() }
        } else if let fallbackID {
            // A plain Markdown file someone put into the folder.
            document.id = fallbackID
        } else {
            return nil
        }
        if isPresentation {
            var deck = PresentationDeck.parse(String(body))
            if let backgrounds { deck.backgrounds = backgrounds }
            document.deck = deck
        } else {
            document.markdown = String(body)
        }
        if document.title.isEmpty { document.title = WriterDocument.makeTitle(from: document.markdown) }
        return document
    }
}

private extension JSONEncoder {
    static let outline: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

private extension JSONDecoder {
    static let outline: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
