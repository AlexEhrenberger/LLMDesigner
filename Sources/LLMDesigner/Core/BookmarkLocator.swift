import Foundation

/// Finds where a passage the user marked in the chat lives: which message and which Markdown block.
enum BookmarkLocator {
    /// The marked passage inside `message`, or nil if the selection is not part of this message.
    static func target(for selection: String, in message: ChatMessage) -> OutlineTarget? {
        // Formulas are images in the text view; their spot shows up as U+FFFC. Search with the longest text piece.
        let pieces = selection.components(separatedBy: "\u{FFFC}").map(searchKey).sorted { $0.count > $1.count }
        guard let needle = pieces.first.map({ String($0.prefix(40)) }), !needle.isEmpty, !message.content.isEmpty else {
            return nil
        }
        if message.role == .user {
            return searchKey(message.content).contains(needle) ? OutlineTarget(messageID: message.id, block: nil) : nil
        }
        for (index, block) in MarkdownParser.parse(message.content).enumerated()
        where searchKey(source(of: block)).contains(needle) {
            return OutlineTarget(messageID: message.id, block: index)
        }
        return nil
    }

    /// Bookmark title from the marked text: one line, at most 70 characters.
    static func title(from text: String) -> String {
        let line = text.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return "Lesezeichen" }
        return line.count > 70 ? String(line.prefix(70)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Letters and digits only: rendered text and Markdown source match even though markup differs.
    private static func searchKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func source(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let text), .quote(let text): text
        case .heading(_, let text): text
        case .code(_, let code): code
        case .list(let items): items.map(\.text).joined(separator: " ")
        case .table(let header, let rows, _, _): (header + rows.flatMap { $0 }).joined(separator: " ")
        case .math(let latex, _): latex
        case .rule: ""
        }
    }
}
