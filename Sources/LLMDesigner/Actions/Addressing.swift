import AppKit
import LLMDProtocol

/// Where in a text an action works. A person has a caret; an agent names the place. All forms are checked against
/// the current text, and a form that isn't clear is an error, not a guess.
struct WriterAddress: Decodable, Sendable, Equatable {
    /// `start:length` in characters of the Markdown, as `writer.doc.read` returns it.
    var range: String?
    /// A block id from `writer.blocks.list`.
    var block: String?
    /// The heading's path, e.g. `Kapitel 2/Einleitung`.
    var heading: String?
    /// A text; with several hits, `occurrence` (from 1) says which.
    var match: String?
    var occurrence: Int?
    var all: Bool?

    var isEmpty: Bool { range == nil && block == nil && heading == nil && match == nil && all != true }

    static let schemaProperties: [String: JSONSchema] = [
        "range": .string("Zeichenbereich im Markdown: start:länge, z. B. 120:15"),
        "block": .string("Block-ID aus writer.blocks.list"),
        "heading": .string("Pfad der Überschrift, z. B. Kapitel 2/Einleitung"),
        "match": .string("Text, der gefunden werden soll"),
        "occurrence": .integer("Welcher Treffer, ab 1", minimum: 1),
        "all": .boolean("Der ganze Text"),
    ]
}

/// A block of the text with an id. The id holds the place and a fingerprint of the content, so it is good until that
/// block changes; a stale id is an error instead of landing in the wrong place. It is not stored anywhere.
struct WriterBlockInfo: Sendable, Encodable, Equatable {
    var id: String
    var type: String
    var text: String
    var level: Int?

    /// The id of the block at `index`. Equal blocks (two rules, a repeated line) are told apart by how many equal ones
    /// come before: otherwise, after a block above them goes, the id of the first would fit the second.
    static func id(index: Int, in chunks: [PowerChunk]) -> String {
        let markdown = chunks[index].markdown
        let earlier = chunks[..<index].filter { $0.markdown == markdown }.count
        return id(index: index, markdown: markdown, equalBefore: earlier)
    }

    /// All ids at once, for a whole list.
    static func ids(of chunks: [PowerChunk]) -> [String] {
        var seen: [String: Int] = [:]
        return chunks.map { chunk in
            let earlier = seen[chunk.markdown, default: 0]
            seen[chunk.markdown] = earlier + 1
            return id(index: chunk.id, markdown: chunk.markdown, equalBefore: earlier)
        }
    }

    private static func id(index: Int, markdown: String, equalBefore: Int) -> String {
        // A block without an equal one before it keeps the id it always had.
        "b\(index)-\(ActionVersion.of(equalBefore == 0 ? markdown : markdown + "\u{1F}\(equalBefore)").prefix(6))"
    }

    static func typeName(_ kind: PowerChunk.Kind) -> String {
        switch kind {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .list: "list"
        case .quote: "quote"
        case .code: "code"
        case .table: "table"
        case .math: "math"
        case .image: "image"
        case .box: "box"
        case .other: "other"
        }
    }
}

/// The result of resolving an address.
enum ResolvedAddress: Equatable {
    case whole
    /// One or more whole blocks.
    case blocks(Range<Int>)
    /// A stretch in a block's text as attributed string.
    case text(block: Int, range: NSRange)
    /// A stretch of the Markdown source.
    case source(Range<String.Index>)
}

@MainActor
enum WriterAddressing {
    static func blocks(of markdown: String) -> [WriterBlockInfo] {
        let chunks = PowerText.chunks(of: markdown)
        let ids = WriterBlockInfo.ids(of: chunks)
        return chunks.map { chunk in
            var level: Int?
            if case .heading(let depth) = chunk.kind { level = depth }
            let plain = chunk.plain
            return WriterBlockInfo(id: ids[chunk.id], type: WriterBlockInfo.typeName(chunk.kind),
                                   text: plain.count > 80 ? String(plain.prefix(80)) + "…" : plain, level: level)
        }
    }

    static func resolve(_ address: WriterAddress, in markdown: String) throws -> ResolvedAddress {
        let forms = [address.range != nil, address.block != nil, address.heading != nil, address.match != nil, address.all == true].filter { $0 }.count
        guard forms <= 1 else {
            throw RPCError.invalidParams("Bitte nur eine Adresse angeben: range, block, heading, match oder all.")
        }
        let chunks = PowerText.chunks(of: markdown)
        if address.all == true { return .whole }
        if let block = address.block { return .blocks(try index(ofBlock: block, in: chunks)..<(try index(ofBlock: block, in: chunks) + 1)) }
        if let heading = address.heading {
            let index = try self.index(ofHeading: heading, in: chunks)
            return .blocks(index..<(index + 1))
        }
        if let match = address.match {
            return try find(match, occurrence: address.occurrence, in: chunks)
        }
        if let range = address.range {
            return .source(try sourceRange(range, in: markdown))
        }
        throw RPCError.invalidParams("Diese Action braucht eine Adresse: range, block, heading, match oder all.")
    }

    /// The whole section of a heading: from it up to the next heading of the same or a higher level.
    static func section(ofHeading path: String, in markdown: String) throws -> Range<Int> {
        let chunks = PowerText.chunks(of: markdown)
        let start = try index(ofHeading: path, in: chunks)
        guard case .heading(let level) = chunks[start].kind else { return start..<(start + 1) }
        let end = chunks[(start + 1)...].first { chunk in
            if case .heading(let other) = chunk.kind { return other <= level }
            return false
        }?.id ?? chunks.count
        return start..<end
    }

    private static func index(ofBlock id: String, in chunks: [PowerChunk]) throws -> Int {
        guard id.hasPrefix("b"), let number = Int(id.dropFirst().prefix { $0.isNumber }) else {
            throw RPCError.invalidParams("„\(id)“ ist keine Block-ID.")
        }
        guard chunks.indices.contains(number), WriterBlockInfo.id(index: number, in: chunks) == id else {
            throw RPCError(code: RPCError.versionConflictCode, message: "Block \(id) gibt es so nicht mehr. Bitte writer.blocks.list neu aufrufen.")
        }
        return number
    }

    private static func headingText(_ chunk: PowerChunk) -> String {
        let line = chunk.markdown.components(separatedBy: "\n").first ?? ""
        return WriterMarkdown.headingAttributes(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)).text
            .trimmingCharacters(in: .whitespaces)
    }

    /// Walks the path through the levels: `Kapitel 2/Einleitung` is the first "Einleitung" under "Kapitel 2".
    private static func index(ofHeading path: String, in chunks: [PowerChunk]) throws -> Int {
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { throw RPCError.invalidParams("Leerer Überschriften-Pfad.") }
        var candidates: [(index: Int, level: Int)] = chunks.compactMap { chunk in
            guard case .heading(let level) = chunk.kind else { return nil }
            return (chunk.id, level)
        }
        var scope = 0..<chunks.count
        var found: Int?
        for part in parts {
            let matching = candidates.filter { scope.contains($0.index) && headingText(chunks[$0.index]).localizedCaseInsensitiveCompare(part) == .orderedSame }
            guard let first = matching.first else { throw RPCError.notFound("Überschrift „\(path)“ gibt es nicht.") }
            if part == parts.last, matching.count > 1 {
                throw RPCError.ambiguous("Mehrere Überschriften passen zu „\(path)“. Bitte den Pfad verlängern oder eine Block-ID nehmen.",
                                         candidates: matching.map { WriterBlockInfo.id(index: $0.index, in: chunks) })
            }
            found = first.index
            let end = candidates.first { $0.index > first.index && $0.level <= first.level }?.index ?? chunks.count
            scope = (first.index + 1)..<end
        }
        candidates = []
        return found!
    }

    /// Searches the text as it reads, so a word finds its place even where marks run through it.
    /// Whether `match` looks into a block: not into code, formulas and pictures, whose text isn't running text.
    static func isSearched(_ kind: PowerChunk.Kind) -> Bool {
        kind != .code && kind != .math && kind != .image
    }

    /// The places of a text, counted as `match` with `occurrence` counts them: in the text as it reads, block by block,
    /// one after the other. `writer.find` numbers its hits with the same count, so its numbers can be used here.
    static func hits(of query: String, in chunks: [PowerChunk], options: NSString.CompareOptions = []) -> [(block: Int, range: NSRange)] {
        var hits: [(block: Int, range: NSRange)] = []
        for chunk in chunks where isSearched(chunk.kind) {
            let string = visibleText(of: chunk.markdown)
            var start = 0
            while start < string.length {
                let found = string.range(of: query, options: options, range: NSRange(location: start, length: string.length - start))
                guard found.location != NSNotFound else { break }
                hits.append((chunk.id, found))
                start = NSMaxRange(found)
            }
        }
        return hits
    }

    private static func find(_ query: String, occurrence: Int?, in chunks: [PowerChunk]) throws -> ResolvedAddress {
        guard !query.isEmpty else { throw RPCError.invalidParams("Leerer Suchtext.") }
        let hits = hits(of: query, in: chunks)
        guard !hits.isEmpty else { throw RPCError.notFound("„\(query)“ kommt im Text nicht vor.") }
        if let occurrence {
            guard hits.indices.contains(occurrence - 1) else {
                throw RPCError.notFound("„\(query)“ kommt nur \(hits.count)-mal vor, nicht \(occurrence)-mal.")
            }
            let hit = hits[occurrence - 1]
            return .text(block: hit.block, range: hit.range)
        }
        guard hits.count == 1 else {
            throw RPCError.ambiguous("„\(query)“ kommt \(hits.count)-mal vor. Bitte occurrence angeben.")
        }
        return .text(block: hits[0].block, range: hits[0].range)
    }

    /// The text of a block as the editor shows it. Converting a block is the slow part of finding a word, and an
    /// agent finds many in the same text: a block that didn't change is converted once.
    static func visibleText(of block: String) -> NSString {
        if let cached = visibleTexts.object(forKey: block as NSString) { return cached }
        let text = WriterMarkdown.attributedString(from: block).string as NSString
        visibleTexts.setObject(text, forKey: block as NSString)
        return text
    }

    private static let visibleTexts: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 20_000
        return cache
    }()

    private static func sourceRange(_ text: String, in markdown: String) throws -> Range<String.Index> {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let start = Int(parts[0]), let length = Int(parts[1]), start >= 0, length >= 0 else {
            throw RPCError.invalidParams("Bereich als start:länge angeben, z. B. 120:15.")
        }
        guard let lower = markdown.index(markdown.startIndex, offsetBy: start, limitedBy: markdown.endIndex),
              let upper = markdown.index(lower, offsetBy: length, limitedBy: markdown.endIndex) else {
            throw RPCError.invalidParams("Der Bereich \(text) liegt außerhalb des Texts (\(markdown.count) Zeichen).")
        }
        return lower..<upper
    }

    /// An address made for `old`, for the text as it is now. While a model wrote or a dialog was open, the person may
    /// have typed: a range then moves with the text before it, or is a conflict when the change reaches into it; the
    /// n-th hit of a word is a conflict, because nobody can tell which one is meant now. Blocks carry their
    /// fingerprint, headings and single hits are found by their content anyway.
    static func rebase(_ address: WriterAddress, from old: String, to new: String) throws -> WriterAddress {
        guard old != new else { return address }
        let conflict = RPCError(code: RPCError.versionConflictCode, message: "Der Text hat sich an dieser Stelle geändert, während die Action lief. Bitte neu lesen.",
                                data: .object(["version": .string(ActionVersion.of(new))]))
        if address.match != nil, address.occurrence != nil { throw conflict }
        guard let range = address.range else { return address }
        let parts = range.split(separator: ":")
        guard parts.count == 2, let start = Int(parts[0]), let length = Int(parts[1]) else { return address }
        // The changed stretch: what lies between the common beginning and the common end of both texts.
        let oldCharacters = Array(old), newCharacters = Array(new)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count), oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldCharacters.count, newCharacters.count) - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] { suffix += 1 }
        var moved = address
        if start + length <= prefix {
            return address
        } else if start >= oldCharacters.count - suffix {
            moved.range = "\(start + newCharacters.count - oldCharacters.count):\(length)"
            return moved
        }
        throw conflict
    }

    /// The block and text stretch a source range lies in, for changes that work on attributed text.
    static func textStretch(for range: Range<String.Index>, in markdown: String) throws -> (block: Int, range: NSRange) {
        let slice = String(markdown[range]).trimmingCharacters(in: .newlines)
        let plain = WriterMarkdown.attributedString(from: slice).string.trimmingCharacters(in: .newlines)
        guard !plain.isEmpty else { throw RPCError.invalidTarget("Der Bereich enthält keinen Text.") }
        // Which block: walk the blocks through the source.
        var position = markdown.startIndex
        for chunk in PowerText.chunks(of: markdown) {
            guard let place = markdown.range(of: chunk.markdown, range: position..<markdown.endIndex) else { continue }
            position = place.upperBound
            guard place.contains(range.lowerBound) else { continue }
            guard range.upperBound <= place.upperBound else {
                throw RPCError.invalidTarget("Der Bereich läuft über mehrere Blöcke. Bitte block oder match verwenden.")
            }
            let string = WriterMarkdown.attributedString(from: chunk.markdown).string as NSString
            // Hits before this one in the same block, so a repeated word finds the right place.
            let before = String(markdown[place.lowerBound..<range.lowerBound])
            let earlier = WriterMarkdown.attributedString(from: before).string.trimmingCharacters(in: .newlines)
            let found = string.range(of: plain, options: [], range: NSRange(location: min((earlier as NSString).length, string.length),
                                                                            length: string.length - min((earlier as NSString).length, string.length)))
            let any = found.location != NSNotFound ? found : string.range(of: plain)
            guard any.location != NSNotFound else {
                throw RPCError.invalidTarget("Der Bereich schneidet Formatmarken. Bitte block oder match verwenden.")
            }
            return (chunk.id, any)
        }
        throw RPCError.invalidTarget("Der Bereich liegt zwischen den Blöcken.")
    }
}
