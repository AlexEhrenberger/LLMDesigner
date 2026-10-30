import Foundation

/// A comment on a passage of a Writer Studio document: a short thread of entries by the user or the model, which can
/// be marked as done. It sits on the passage's characters (`.writerComment`) and never changes: a reply or "done"
/// puts a new comment there, so undo brings the old one back. Markdown keeps it in an HTML span around the passage,
/// `<span class="comment" data-comment="k-1a2b3c4d" data-thread="…">passage</span>`; other programs show the passage,
/// and exports leave the comment out.
final class WriterComment: NSObject, @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// "Ich", or the model's name.
        var author: String
        var isAI: Bool
        var date: Date
        var text: String
    }

    let id: String
    let entries: [Entry]
    let isResolved: Bool

    init(id: String = WriterComment.newID(), entries: [Entry], isResolved: Bool = false) {
        self.id = id
        self.entries = entries
        self.isResolved = isResolved
    }

    static func newID() -> String { "k-" + UUID().uuidString.prefix(8).lowercased() }

    /// The user's name in comments.
    static let userName = "Ich"

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? WriterComment else { return false }
        return other.id == id && other.entries == entries && other.isResolved == isResolved
    }

    override var hash: Int { id.hashValue }

    func with(entries: [Entry]? = nil, isResolved: Bool? = nil) -> WriterComment {
        WriterComment(id: id, entries: entries ?? self.entries, isResolved: isResolved ?? self.isResolved)
    }

    /// Still empty: just made, nothing written yet.
    var isEmpty: Bool { entries.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    // MARK: Markdown

    private struct Stored: Codable {
        var entries: [Entry]
        var done: Bool?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var openingTag: String {
        let stored = Stored(entries: entries, done: isResolved ? true : nil)
        let json = (try? Self.encoder.encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"entries\":[]}"
        let thread = WriterBookmark.escapeAttribute(json.replacingOccurrences(of: "\n", with: "\\n"))
        return "<span class=\"comment\" data-comment=\"\(id)\" data-thread=\"\(thread)\">"
    }

    /// The comment of a `<span class="comment" …>` tag; nil for any other span.
    static func parseTag(_ tag: String) -> WriterComment? {
        let attributes = WriterSpans.attributes(of: tag)
        guard attributes["class"]?.split(separator: " ").contains("comment") == true, let id = attributes["data-comment"], !id.isEmpty else { return nil }
        let stored = attributes["data-thread"].flatMap { try? decoder.decode(Stored.self, from: Data($0.utf8)) }
        return WriterComment(id: id, entries: stored?.entries ?? [], isResolved: stored?.done ?? false)
    }

    static func isCommentTag(_ tag: String) -> Bool {
        WriterSpans.attributes(of: tag)["class"]?.split(separator: " ").contains("comment") == true
    }

    /// Markdown without comment spans (the passages stay).
    static func strip(_ markdown: String) -> String {
        let tokens = WriterSpans.tokens(in: markdown)
        guard tokens.contains(where: { $0.isOpening && isCommentTag($0.tag) }) else { return markdown }
        var stack: [Bool] = []
        var remove: [NSRange] = []
        for token in tokens {
            if token.isOpening {
                let isComment = isCommentTag(token.tag)
                stack.append(isComment)
                if isComment { remove.append(token.range) }
            } else if let isComment = stack.popLast(), isComment {
                remove.append(token.range)
            }
        }
        let result = NSMutableString(string: markdown)
        for range in remove.sorted(by: { $0.location > $1.location }) { result.deleteCharacters(in: range) }
        return result as String
    }

    /// How many open comments a stored document has.
    static func openCount(in markdown: String) -> Int {
        var seen = Set<String>()
        for token in WriterSpans.tokens(in: markdown) where token.isOpening {
            guard let comment = parseTag(token.tag), !comment.isResolved else { continue }
            seen.insert(comment.id)
        }
        return seen.count
    }
}

extension NSAttributedString.Key {
    /// The comment (`WriterComment`) on the passage.
    static let writerComment = NSAttributedString.Key("LLMDesigner.writer.comment")
}

/// A comment as the side panel lists it.
struct WriterCommentEntry: Identifiable, Equatable {
    let comment: WriterComment
    /// The commented text, plain.
    let excerpt: String
    let location: Int
    var id: String { comment.id }
}
