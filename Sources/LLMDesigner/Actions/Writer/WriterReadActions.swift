import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterReadActions() {
        register(WriterDocReadAction.self)
        register(WriterBlocksListAction.self)
        register(WriterOutlineGetAction.self)
        register(WriterFindAction.self)
        register(WriterStatsAction.self)
        register(WriterStateGetAction.self)
    }
}

extension WriterTarget {
    /// Reading this text marks the run if it is of foreign origin.
    var readPreflight: ActionPreflight {
        ActionPreflight(readsUntrusted: document?.isForeign == true, target: document?.displayTitle, version: version)
    }

    /// For reads that take `ifVersion`: a read of another version than the caller expects is a conflict too, as the
    /// parameter promises.
    func readPreflight(ifVersion: String?) throws -> ActionPreflight {
        try checkVersion(ifVersion)
        return readPreflight
    }
}

/// The properties a Writer action takes to name its text.
private func targetProperties(_ extra: [String: JSONSchema] = [:]) -> [String: JSONSchema] {
    WriterTargetArgs.schemaProperties.merging(extra) { _, new in new }
}

struct WriterDocReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var format: String?
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            format = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .format)
        }
        enum Keys: String, CodingKey { case format }
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var text: String
        var version: String
        var herkunft: String?
    }

    static let descriptor = ActionDescriptor(
        id: "writer.doc.read", summary: "Liest ein Dokument, eine Folie oder einen Teil davon", kind: .read, security: .plainRead,
        input: .object(targetProperties(WriterAddress.schemaProperties.merging(["format": .choice(["markdown", "plain"], "Standard: markdown")]) { _, new in new })),
        output: .freeObject(), example: "llmd writer doc read --doc Bericht --format plain", groups: ["core", "writer.core"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        var part = markdown
        if let heading = args.address.heading {
            let chunks = PowerText.chunks(of: markdown)
            part = PowerText.join(Array(chunks[try WriterAddressing.section(ofHeading: heading, in: markdown)]).map(\.markdown))
        } else if !args.address.isEmpty {
            switch try WriterAddressing.resolve(args.address, in: markdown) {
            case .whole: break
            case .blocks(let range): part = PowerText.join(Array(PowerText.chunks(of: markdown)[range]).map(\.markdown))
            case .source(let range): part = String(markdown[range])
            case .text(let block, let range):
                part = (WriterMarkdown.attributedString(from: PowerText.chunks(of: markdown)[block].markdown).string as NSString).substring(with: range)
            }
        }
        return Output(id: target.documentID.uuidString, title: target.document?.displayTitle ?? "",
                      text: args.format == "plain" ? PowerText.plain(part) : part, version: target.version, herkunft: target.document?.provenance?.rawValue)
    }
}

struct WriterBlocksListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var version: String
        var blocks: [WriterBlockInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.blocks.list", summary: "Listet die Blöcke mit ID, Typ und Kurztext", kind: .read, security: .plainRead,
        input: .object(targetProperties()), output: .freeObject(), groups: ["core", "writer.core"]
    )
    static func preflight(_ args: WriterTargetArgs, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args, app: context.app).readPreflight(ifVersion: args.ifVersion)
    }
    static func run(_ args: WriterTargetArgs, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args, app: context.app)
        return Output(version: target.version, blocks: WriterAddressing.blocks(of: target.markdown))
    }
}

struct WriterOutlineGetAction: LLMDAction {
    struct Heading: Encodable, Sendable {
        var level: Int
        var title: String
        var block: String
    }
    struct Output: Encodable, Sendable {
        var version: String
        var headings: [Heading]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.outline.get", summary: "Liefert den Überschriftenbaum", kind: .read, security: .plainRead,
        input: .object(targetProperties()), output: .freeObject(), groups: ["writer.core"]
    )
    static func preflight(_ args: WriterTargetArgs, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args, app: context.app).readPreflight(ifVersion: args.ifVersion)
    }
    static func run(_ args: WriterTargetArgs, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args, app: context.app)
        let chunks = PowerText.chunks(of: target.markdown)
        let ids = WriterBlockInfo.ids(of: chunks)
        let headings = chunks.compactMap { chunk -> Heading? in
            guard case .heading(let level) = chunk.kind else { return nil }
            return Heading(level: level, title: chunk.plain.trimmingCharacters(in: .whitespacesAndNewlines), block: ids[chunk.id])
        }
        return Output(version: target.version, headings: headings)
    }
}

struct WriterFindAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var query: String
        var caseSensitive: Bool?
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            query = try container.decode(String.self, forKey: .query)
            caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive)
        }
        enum Keys: String, CodingKey { case query, caseSensitive }
    }
    struct Hit: Encodable, Sendable {
        var block: String
        /// The text as it stands there, and which place of it this is: `match` and `occurrence` hit exactly this one.
        /// In code, formulas and pictures `match` doesn't look, so only the block names the place.
        var match: String?
        var occurrence: Int?
        var excerpt: String
    }
    struct Output: Encodable, Sendable {
        var version: String
        var count: Int
        var hits: [Hit]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.find", summary: "Sucht im Text; jeder Treffer nennt match und occurrence, die genau ihn adressieren", kind: .read, security: .plainRead,
        input: .object(targetProperties(["query": .string("Suchtext"), "caseSensitive": .boolean("Groß-/Kleinschreibung beachten; Standard: nein")]), required: ["query"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        guard !args.query.isEmpty else { throw RPCError.invalidParams("Leerer Suchtext.") }
        let chunks = PowerText.chunks(of: target.markdown)
        let ids = WriterBlockInfo.ids(of: chunks)
        let options: NSString.CompareOptions = args.caseSensitive == true ? [] : [.caseInsensitive, .diacriticInsensitive]
        // Each exact text found, with the places `match` counts for it.
        var places: [String: [(block: Int, location: Int)]] = [:]
        func occurrence(of text: String, block: Int, location: Int) -> Int? {
            if places[text] == nil {
                places[text] = WriterAddressing.hits(of: text, in: chunks).map { ($0.block, $0.range.location) }
            }
            return places[text]?.firstIndex { $0.block == block && $0.location == location }.map { $0 + 1 }
        }
        func excerpt(_ string: NSString, around found: NSRange) -> String {
            let lower = max(0, found.location - 30)
            let piece = string.substring(with: NSRange(location: lower, length: min(string.length - lower, found.length + 60)))
            return piece.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ")
        }
        var hits: [Hit] = []
        for chunk in chunks {
            // Running text as the editor shows it; code and formulas as they are written, so a search finds them too.
            let searched = WriterAddressing.isSearched(chunk.kind)
            let string = searched ? WriterAddressing.visibleText(of: chunk.markdown) : chunk.plain as NSString
            var start = 0
            while start < string.length {
                let found = string.range(of: args.query, options: options, range: NSRange(location: start, length: string.length - start))
                guard found.location != NSNotFound else { break }
                let text = string.substring(with: found)
                hits.append(Hit(block: ids[chunk.id], match: searched ? text : nil,
                                occurrence: searched ? occurrence(of: text, block: chunk.id, location: found.location) : nil,
                                excerpt: excerpt(string, around: found)))
                start = NSMaxRange(found)
            }
        }
        return Output(version: target.version, count: hits.count, hits: hits)
    }
}

struct WriterStatsAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var words: Int
        var characters: Int
        var blocks: Int
        var pages: Int
        var version: String
    }
    /// A page of running text; only an estimate, the real count comes from the typesetter.
    static let wordsPerPage = 350
    static let descriptor = ActionDescriptor(
        id: "writer.doc.stats", summary: "Zählt Wörter, Zeichen und ungefähre Seiten", kind: .read, security: .plainRead,
        input: .object(targetProperties()), output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: WriterTargetArgs, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args, app: context.app)
        // Counts carry no words of the text, so reading them doesn't mark the run; the version is checked all the same.
        try target.checkVersion(args.ifVersion)
        let plain = PowerText.plain(target.markdown)
        let words = plain.split(whereSeparator: \.isWhitespace).count
        return Output(words: words, characters: plain.count, blocks: PowerText.chunks(of: target.markdown).count,
                      pages: max(1, Int((Double(words) / Double(wordsPerPage)).rounded(.up))), version: target.version)
    }
}

struct WriterStateGetAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var openDocument: String?
        var title: String?
        var isPresentation: Bool
        var version: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.state.get", summary: "Zeigt, welches Dokument gerade offen ist", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let document = context.app.selectedDocument
        return Output(openDocument: document?.id.uuidString, title: document?.displayTitle, isPresentation: document?.isPresentation == true,
                      version: document.map { ActionVersion.of($0.markdown) })
    }
}
