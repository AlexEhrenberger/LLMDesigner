import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerChatDocumentActions() {
        register(ChatDocumentAttachAction.self)
        register(ChatDocumentRemoveDraftAction.self)
        register(ChatDocumentListAction.self)
        register(ChatDocumentReadAction.self)
        register(ChatDocumentDescribeAction.self)
    }
}

/// An attached document's text was mostly written by others, and the document itself is the person's: reading it
/// counts as both. Over MCP such reads are refused (rule 2), as for a persona's files.
extension ActionSecurity {
    static let documentRead = ActionSecurity(readsUntrusted: true, sensitive: true, effect: .none)
}

struct ChatDocumentArgs: Decodable, Sendable {
    var chat: String?
    var files: [String]?
    var document: String?
    var part: Int?
    var again: Bool?
}

/// What an action tells about a document, without its text.
struct DocumentInfo: Encodable, Sendable {
    var id: String
    var name: String
    var pages: Int?
    var characters: Int
    var recognizedPages: [Int]?
    var figures: Int
    var describedFigures: Int
    /// The question it hangs on; nil while it waits in the composer.
    var message: String?

    init(_ document: DocumentAttachment, message: ChatMessage.ID?) {
        id = document.id.uuidString
        name = document.name
        pages = document.pageCount
        characters = document.characterCount
        recognizedPages = document.recognizedPages
        figures = document.figures?.count ?? 0
        describedFigures = document.figures?.filter { $0.description != nil }.count ?? 0
        self.message = message?.uuidString
    }
}

@MainActor
private func chatDocument(_ args: ChatDocumentArgs, context: ActionContext) throws -> (Chat, DocumentAttachment) {
    let chat = try context.app.actionChat(args.chat ?? "")
    let wanted = (args.document ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let all = chat.messages.flatMap { $0.documents ?? [] } + context.app.draftDocuments(of: chat.id)
    guard let document = all.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? all.first(where: { $0.name == wanted }) else {
        throw RPCError.notFound("Einen Anhang „\(wanted)“ gibt es in diesem Chat nicht. chat.document.list zeigt sie.")
    }
    return (chat, document)
}

struct ChatDocumentAttachAction: LLMDAction {
    typealias Args = ChatDocumentArgs
    struct Output: Encodable, Sendable {
        var documents: [DocumentInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.document.attach",
        summary: "Liest Dokumente (PDF, Word, Text) ins Eingabefeld eines Chats: Text Seite für Seite, Scans erkannt, Abbildungen ausgeschnitten",
        kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "files": .array(of: .string(), "Pfade der Dokumente")], required: ["chat", "files"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.files?.first)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Dokument von dieser Stelle der Festplatte würde dem Modell gezeigt."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat ?? "").id
        var added: [DocumentAttachment] = []
        for path in args.files ?? [] {
            let url = ActionExportFolder.expanded(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
            guard DocumentStore.accepts(url) else { throw RPCError.invalidTarget("„\(url.lastPathComponent)“ ist kein Dokument, das die App liest. Bilder gehen mit chat.image.attach.") }
            do {
                added.append(try await DocumentStore.importDocument(url))
            } catch {
                throw RPCError.invalidTarget(error.localizedDescription)
            }
        }
        app.setDraftDocuments(app.draftDocuments(of: id) + added, of: id)
        return Output(documents: added.map { DocumentInfo($0, message: nil) })
    }
}

struct ChatDocumentRemoveDraftAction: LLMDAction {
    typealias Args = ChatDocumentArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.document.removeDraft", summary: "Nimmt ein Dokument aus dem Eingabefeld eines Chats", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "document": .string("Dokument (ID)")], required: ["chat", "document"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat ?? "").id
        let documents = app.draftDocuments(of: id)
        guard documents.contains(where: { $0.id.uuidString == args.document }) else { throw RPCError.notFound("Dieses Dokument liegt nicht im Eingabefeld.") }
        app.setDraftDocuments(documents.filter { $0.id.uuidString != args.document }, of: id)
        return OKOutput()
    }
}

struct ChatDocumentListAction: LLMDAction {
    typealias Args = ChatDocumentArgs
    struct Output: Encodable, Sendable {
        var documents: [DocumentInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.document.list", summary: "Listet die Dokumente eines Chats: an Nachrichten und im Eingabefeld", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject(), groups: ["chat.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        context.app.chatPreflight(try context.app.actionChat(args.chat ?? ""))
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat ?? "")
        let sent = chat.messages.flatMap { message in (message.documents ?? []).map { DocumentInfo($0, message: message.id) } }
        let waiting = context.app.draftDocuments(of: chat.id).map { DocumentInfo($0, message: nil) }
        return Output(documents: sent + waiting)
    }
}

struct ChatDocumentReadAction: LLMDAction {
    typealias Args = ChatDocumentArgs
    struct Output: Encodable, Sendable {
        var document: String
        var part: Int
        var parts: Int
        var text: String
    }
    static let partLength = 12_000
    static let descriptor = ActionDescriptor(
        id: "chat.document.read",
        summary: "Liest den Text eines Anhangs, wie das Modell ihn bekommt (Seitenmarken, Abbildungen als Platzhalter), in Teilen",
        kind: .read, security: .documentRead,
        input: .object(["chat": chatReference, "document": .string("Dokument (ID oder Dateiname)"), "part": .integer("Teil, von 1", minimum: 1)],
                       required: ["chat", "document"]),
        output: .freeObject(), groups: ["chat.private"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let (chat, document) = try chatDocument(args, context: context)
        var check = context.app.chatPreflight(chat)
        check.target = document.name
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (_, document) = try chatDocument(args, context: context)
        let text = DocumentPrompt.fullText(of: document)
        let parts = PersonaFileTools.segments(of: text, maxLength: partLength)
        let number = min(max(args.part ?? 1, 1), max(parts.count, 1))
        let piece = parts.isEmpty ? "" : String(text[parts[number - 1]])
        return Output(document: document.name, part: number, parts: max(parts.count, 1), text: ForeignFrame.wrap(piece))
    }
}

struct ChatDocumentDescribeAction: LLMDAction {
    typealias Args = ChatDocumentArgs
    struct Output: Encodable, Sendable {
        var described: Int
        var model: String
    }
    static let descriptor = ActionDescriptor(
        id: "chat.document.describe",
        summary: "Lässt ein Modell, das Bilder versteht, die Abbildungen eines Anhangs einmal beschreiben; danach gehen sie als Text mit",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: true, effect: .local),
        input: .object(["chat": chatReference, "document": .string("Dokument (ID oder Dateiname)"), "again": .boolean("Auch schon beschriebene neu")],
                       required: ["chat", "document"]),
        output: .freeObject(), groups: ["chat.private"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let (chat, document) = try chatDocument(args, context: context)
        var check = context.app.chatPreflight(chat)
        check.target = document.name
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (chat, document) = try chatDocument(args, context: context)
        guard chat.messages.contains(where: { $0.documents?.contains { $0.id == document.id } == true }) else {
            throw RPCError.invalidTarget("Das Dokument liegt noch im Eingabefeld. Beschrieben wird es, wenn es mit einer Nachricht gesendet ist.")
        }
        guard document.figures?.isEmpty == false else { throw RPCError.invalidTarget("In „\(document.name)“ wurden keine Abbildungen gefunden.") }
        guard let model = context.app.describingModel(for: chat) else { throw RPCError.unavailable("Es ist kein Modell geladen, das Bilder versteht.") }
        do {
            let count = try await context.app.describeFigures(of: document.id, in: chat.id, again: args.again == true)
            return Output(described: count, model: model)
        } catch {
            throw RPCError.unavailable(error.localizedDescription)
        }
    }
}
