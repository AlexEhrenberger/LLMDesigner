import Foundation

enum Role: String, Codable, Sendable {
    case system, user, assistant
}

struct GenerationStats: Codable, Hashable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var tokensPerSecond: Double?
    var timeToFirstToken: Double?
    var reasoningSeconds: Double?
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: Role
    var content: String
    var reasoning: String?
    var model: String?
    var createdAt: Date = Date()
    var stats: GenerationStats?
    var error: String?
    var stopped: Bool?
    /// Questions the user might ask next, suggested by the model after the answer.
    var followUps: [String]?
    /// Web searches and pages the model looked at while answering.
    var toolSteps: [ToolStep]?
    /// Pictures the user attached to a question.
    var images: [ImageAttachment]?
    /// How the strong memory sorted the question before this answer, and what the persona remembered.
    var thalamus: ThalamusTrace?

    var hasImages: Bool { !(images ?? []).isEmpty }
    /// Whether the message has anything to show or send.
    var hasContent: Bool { !content.isEmpty || hasImages }
}

/// A picture attached to a message. The file lives in the attachments folder (`AttachmentStore`),
/// so chats that branched off each other share it.
struct ImageAttachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var fileName: String
    var width: Int
    var height: Int
}

/// A web lookup the model made while answering: a search or a page it read.
struct ToolStep: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case search, openPage, wikiSearch, wikiArticle
        /// A persona searching or reading one of its files.
        case fileSearch, fileRead
        /// An action of the app (`ChatActionTools`): `argument` is its id, `section` what it worked on.
        case action

        var isWikipedia: Bool { self == .wikiSearch || self == .wikiArticle }
        var isFile: Bool { self == .fileSearch || self == .fileRead }
        var readsPage: Bool { self == .openPage || self == .wikiArticle }
    }
    enum Status: String, Codable, Sendable {
        case running, done, failed
    }

    var id = UUID()
    var kind: Kind
    /// Search query, page address, article or file name.
    var argument: String
    /// Wikipedia edition, e.g. "de".
    var language: String?
    /// Part of a Wikipedia article the model asked for, or the part number of a file.
    var section: String?
    var status: Status = .running
    /// Search hits, or the page that was read.
    var sources: [WebSource]?
    var error: String?
}

struct WebSource: Codable, Hashable, Sendable {
    var title: String
    var url: String
    var snippet: String?
    /// Publication date as reported by the search engine (yyyy-MM-dd).
    var date: String?

    var host: String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct Chat: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var modelId: String?
    var messages: [ChatMessage] = []
    var outline: ChatOutline?
    /// Set once the user renames the chat; from then on the outline no longer retitles it.
    var hasCustomTitle: Bool?
    var bookmarks: [Bookmark]?
    /// The user switched on the web search for this chat (globe button in the composer).
    var webSearch: Bool?
    /// The user switched on the Wikipedia search for this chat (W button in the composer).
    var wikipediaSearch: Bool?
    /// The user switched on the thinking mode for this chat (brain button in the composer).
    var thinking: Bool?
    /// Set when this chat was branched off another one.
    var branch: ChatBranch?
    /// Folder in the sidebar; nil for chats outside any folder.
    var folderID: Folder.ID?
    /// Skills switched on for this chat, in the order they go into the system prompt.
    var skillIDs: [Skill.ID]?
    /// The persona the user talks to in this chat. Chosen when the chat starts; a chat with a persona has no skills.
    var personaID: Persona.ID?
    /// Whether the persona's memory (Thalamus) is on in this chat; chosen when the chat starts. Nil without a persona.
    var memory: MemoryLevel?
    /// Context length the model runs with for this chat (8K, 16K or 32K); chosen when the chat starts.
    /// Nil for chats from before the setting existed: they use whatever the model is loaded with.
    var contextLength: Int?
    /// Tool groups of the studios this chat may use (`ChatToolGroups`).
    var actionGroups: [String]?
    /// How much it may do with them without asking. Nil: everything is asked.
    var actionApproval: ChatToolApproval?

    /// Whether the user chose the title. Chats from before `hasCustomTitle` existed count as renamed
    /// when their title differs from the one derived from the first message.
    var isTitleCustom: Bool {
        if let hasCustomTitle { return hasCustomTitle }
        guard let first = messages.first(where: { $0.role == .user }) else { return false }
        return title != Self.makeTitle(from: first.content)
    }

    static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return "Neuer Chat" }
        guard collapsed.count > 60 else { return collapsed }
        return String(collapsed.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Whether the persona's memory (Thalamus) is on in a chat.
enum MemoryLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, on

    var id: String { rawValue }
    var label: String { self == .on ? "ein" : "aus" }

    /// Before there was only on and off, chats stored "weak" or "strong"; both meant the memory was on.
    init(stored raw: String) {
        self = raw == "off" ? .off : .on
    }

    init(from decoder: Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The context lengths a chat can choose from.
enum ContextChoice {
    static let lengths = [8_192, 16_384, 32_768]
    static let defaultLength = 8_192

    static func label(for length: Int) -> String {
        switch length {
        case ..<12_000: "Kurzes Gespräch"
        case ..<24_000: "Mittleres Gespräch"
        default: "Langes Gespräch"
        }
    }
}

/// Where a chat branched off: the chat it was copied from and the message the branch starts at.
struct ChatBranch: Codable, Hashable, Sendable {
    var sourceChatID: UUID
    /// Title of the source chat when the branch was made, shown if that chat is gone.
    var sourceTitle: String
    /// Message in the source chat the branch starts at (the answer, or the question that was edited).
    var sourceMessageID: UUID
    /// Last message copied into the branch; the divider sits below it. Nil when nothing was copied.
    var lastCopiedMessageID: UUID?
    /// The branch was made by editing a question.
    var editedQuestion: Bool?
}

/// A personal mark the user set on a passage of the chat.
struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    /// The marked text, kept for display and to show what the bookmark refers to.
    var excerpt: String
    var target: OutlineTarget
    var createdAt = Date()
}

/// Splits the thinking that some models write inline from the visible answer: `<think>…</think>`
/// (Qwen and others) or Gemma 4's thought channel `<|channel>thought…<channel|>`.
enum ThinkingSplitter {
    private static let markers: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<|channel>thought", "<channel|>"),
    ]

    static func split(_ raw: String) -> (reasoning: String, content: String) {
        let trimmed = String(raw.drop(while: \.isWhitespace))
        // Nothing yet, or an opening marker that is still arriving.
        if trimmed.isEmpty || markers.contains(where: { $0.open.hasPrefix(trimmed) }) { return ("", "") }
        guard let marker = markers.first(where: { trimmed.hasPrefix($0.open) }) else { return ("", trimmed) }

        let body = trimmed.dropFirst(marker.open.count)
        guard let end = body.range(of: marker.close) else {
            // While streaming, the closing marker may be half there; it must not flash up in the thoughts.
            var open = Substring(body)
            if let partial = (1..<marker.close.count).reversed().first(where: { open.hasSuffix(marker.close.prefix($0)) }) {
                open = open.dropLast(partial)
            }
            return (open.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let reasoning = body[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String(body[end.upperBound...].drop(while: \.isWhitespace))
        return (reasoning, content)
    }
}
