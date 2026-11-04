import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerChatMoreActions() {
        register(ChatOpenAction.self)
        register(ChatRenameAction.self)
        register(ChatAutoTitleAction.self)
        register(ChatMoveAction.self)
        register(ChatBranchAction.self)
        register(ChatBranchSourceAction.self)
        register(ChatMessageReadAction.self)
        register(ChatOutlineGetAction.self)
        register(ChatSourcesGetAction.self)
        register(ChatStateGetAction.self)
        register(ChatContextUsageAction.self)
        register(ChatRegenerateAction.self)
        register(ChatEditAction.self)
        register(ChatFollowUpsGetAction.self)
        register(ChatFollowUpsSendAction.self)
        register(ChatMessageCopyAction.self)
        register(ChatDraftSetAction.self)
        register(ChatDraftGetAction.self)
        register(ChatModelSetAction.self)
        register(ChatContextLengthSetAction.self)
        register(ChatThinkingSetAction.self)
        register(ChatWebSearchSetAction.self)
        register(ChatWikipediaSetAction.self)
        register(ChatMemorySetAction.self)
        register(ChatPersonaSetAction.self)
        register(ChatSkillsSetAction.self)
        register(ChatBookmarkAddAction.self)
        register(ChatBookmarkRenameAction.self)
        register(ChatBookmarkDeleteAction.self)
        register(ChatBookmarkListAction.self)
        register(ChatJumpAction.self)
        register(ChatExportPdfAction.self)
        register(ChatExportAnswerAction.self)
        register(ChatExportMarkdownAction.self)
        register(ChatToDocumentAction.self)
        register(FolderCreateAction.self)
        register(FolderRenameAction.self)
        register(FolderColorAction.self)
        register(FolderCollapseAction.self)
        register(FolderDeleteAction.self)
        registerChatLibraryActions()
        registerChatDeviceActions()
    }
}

let chatReference: JSONSchema = .string("Chat (ID oder Titel)")
let messageReference: JSONSchema = .string("Nachricht: ID, last oder relativ wie -2")

struct ChatMoreArgs: Decodable, Sendable {
    var chat: String
    var message: String?
    var title: String?
    var folder: String?
    var text: String?
    var index: Int?
    var format: String?
    var value: Bool?
    var model: String?
    var contextLength: Int?
    var persona: String?
    var add: [String]?
    var remove: [String]?
    var selectedText: String?
    var bookmark: String?
    var outlineEntry: String?
    var path: String?
    var overwrite: Bool?
    var messages: [String]?
    var withOutline: Bool?
    var images: [String]?
}

extension AppModel {
    /// A message by id, `last`, or relative to the end (`-1` is the last one).
    func actionMessage(_ reference: String?, in chat: Chat) throws -> ChatMessage {
        guard let reference else {
            guard let last = chat.messages.last else { throw RPCError.notFound("Dieser Chat hat keine Nachrichten.") }
            return last
        }
        if reference == "last" { return try actionMessage(nil, in: chat) }
        if let offset = Int(reference), offset < 0 {
            guard chat.messages.indices.contains(chat.messages.count + offset) else { throw RPCError.notFound("So viele Nachrichten hat der Chat nicht.") }
            return chat.messages[chat.messages.count + offset]
        }
        guard let message = chat.messages.first(where: { $0.id.uuidString == reference }) else { throw RPCError.notFound("Die Nachricht \(reference) gibt es in diesem Chat nicht.") }
        return message
    }
}

extension ActionContext {
    /// A change to a chat's data, with its way back. No selected chat is needed; any chat can be meant.
    func changeChat(_ id: Chat.ID, label: String, _ change: (inout Chat) throws -> Void) rethrows {
        let app = self.app
        guard let before = app.chat(id) else { return }
        var after = before
        try change(&after)
        let done = after
        app.updateChat(id) { $0 = done }
        undoGroup.add(UndoStep(label: label, undo: { app.updateChat(id) { $0 = before } }, redo: { app.updateChat(id) { $0 = done } }))
    }

    /// A new answer: as in `chat.send`, a turn from a program or a marked run gets no action tools.
    func beginTurn(in chat: Chat) throws {
        try checkNoRecursion(into: chat.id)
        guard !app.isGenerating(chat.id) else { throw RPCError.unavailable("In diesem Chat läuft gerade eine Antwort.") }
        if channel != .cli || run.hasReadUntrusted { app.chatsBeingAskedByActions.insert(chat.id) }
    }

    /// Settings a chat can't change on itself: its own tools, memory and web access would be a way around the rule.
    func checkOwnSettings(of chat: Chat) throws {
        guard channel == .chat else { return }
        guard run.id != chat.id.uuidString else { throw RPCError.denied("Ein Chat kann seine eigenen Einstellungen nicht ändern.") }
    }

    /// Where an export goes, by the rules of the other exports.
    func exportURL(named name: String, extension fileExtension: String, path: String?, overwrite: Bool?) throws -> URL {
        let folder = ActionExportFolder.url(settings: app.settings)
        let url = path.map(ActionExportFolder.expanded) ?? ActionExportFolder.freeFile(named: name, extension: fileExtension, in: folder)
        guard path == nil || overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.invalidTarget("Die Datei gibt es schon: \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func exportPreflight(path: String?, readsUntrusted: Bool, readsSensitive: Bool, detail: String?) -> ActionPreflight {
        let folder = ActionExportFolder.url(settings: app.settings)
        let inFolder = path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        return ActionPreflight(readsUntrusted: readsUntrusted, readsSensitive: readsSensitive, isInSafePlace: inFolder, target: path ?? folder.path, detail: detail)
    }
}

// MARK: Managing chats

struct ChatOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String
        var window: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.open", summary: "Zeigt einen Chat im Hauptfenster oder im Mini-Chat", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference, "window": .choice(["main", "mini"], "Standard: main")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        if args.window == "mini" {
            app.showInMiniChat(chat.id)
            app.miniChatOpenRequest = UUID()
        } else {
            app.selectChat(chat.id)
        }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatRenameAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.rename", summary: "Benennt einen Chat um", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "title": .string("Neuer Titel")], required: ["chat", "title"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RPCError.invalidParams("Der Titel ist leer.") }
        context.changeChat(chat.id, label: "Umbenennen") {
            $0.title = title
            $0.hasCustomTitle = true
        }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatAutoTitleAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var title: String
    }
    static let descriptor = ActionDescriptor(
        id: "chat.autoTitle", summary: "Der Titel folgt wieder dem Inhalt des Chats, wie das Inhaltsverzeichnis ihn nennt", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let before = chat
        context.app.useAutomaticTitle(chat.id)
        let app = context.app
        let id = chat.id
        if let after = app.chat(id), after != before {
            context.undoGroup.add(UndoStep(label: "Titel", undo: { app.updateChat(id) { $0 = before } }, redo: { app.updateChat(id) { $0 = after } }))
        }
        return Output(title: app.chat(id)?.title ?? "")
    }
}

struct ChatMoveAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.move", summary: "Legt einen Chat in einen Ordner; ohne folder ganz nach oben", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "folder": .string("Ordner (ID oder Name)")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let folder = try args.folder.map { try context.app.actionChatFolder($0).id }
        context.changeChat(chat.id, label: "Verschieben") { $0.folderID = folder }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatBranchAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.branch", summary: "Zweigt von einer Nachricht einen neuen Chat ab, ohne ihn zu öffnen", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "message": messageReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        let message = try app.actionMessage(args.message, in: chat)
        guard let position = chat.messages.firstIndex(where: { $0.id == message.id }) else { throw RPCError.notFound("Die Nachricht gibt es nicht mehr.") }
        let branch = app.makeBranch(of: chat, keeping: position + 1, from: message.id, editedQuestion: false)
        app.addChatFromAction(branch)
        context.undoGroup.add(UndoStep(label: "Abzweigen", undo: { app.deleteChat(branch.id) }, redo: { app.addChatFromAction(branch) }))
        return OKOutput(id: branch.id.uuidString)
    }
}

struct ChatBranchSourceAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var chat: String?
        var title: String?
        var message: String?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.branch.source", summary: "Sagt, aus welchem Chat ein Chat abgezweigt ist", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let branch = try context.app.actionChat(args.chat).branch
        return Output(chat: branch?.sourceChatID.uuidString, title: branch?.sourceTitle, message: branch?.sourceMessageID.uuidString)
    }
}

// MARK: Reading

struct ChatMessageReadAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var message: MessageInfo
        var followUps: [String]?
        var sources: [String]?
        var stopped: Bool?
        var promptTokens: Int?
        var completionTokens: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.message.read", summary: "Liest eine Nachricht vollständig: Fehler, Folgefragen, Quellen, Statistik", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference, "message": messageReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let message = try context.app.actionMessage(args.message, in: chat)
        let sources = message.toolSteps?.flatMap { $0.sources ?? [] }.map(\.url)
        return Output(message: MessageInfo(message, withReasoning: true, withTools: true), followUps: message.followUps, sources: sources?.isEmpty == true ? nil : sources,
                      stopped: message.stopped, promptTokens: message.stats?.promptTokens, completionTokens: message.stats?.completionTokens)
    }
}

struct ChatOutlineGetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Item: Encodable, Sendable {
        var title: String
        var message: String
    }
    struct Section: Encodable, Sendable {
        var title: String
        var message: String
        var items: [Item]
    }
    struct Output: Encodable, Sendable {
        var title: String?
        var summary: String?
        var sections: [Section]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.outline.get", summary: "Liest das Inhaltsverzeichnis eines Chats, soweit es erstellt ist", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let outline = try context.app.actionChat(args.chat).outline
        return Output(title: outline?.title, summary: outline?.summary, sections: (outline?.sections ?? []).map { section in
            Section(title: section.title, message: section.target.messageID.uuidString, items: section.items.map { Item(title: $0.title, message: $0.target.messageID.uuidString) })
        })
    }
}

struct ChatSourcesGetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Source: Encodable, Sendable {
        var title: String
        var url: String
        var message: String
    }
    struct Output: Encodable, Sendable {
        var sources: [Source]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.sources.get", summary: "Listet die Web-, Wikipedia- und Datei-Quellen aller Antworten", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        var seen = Set<String>()
        var sources: [Source] = []
        for message in chat.messages {
            for step in message.toolSteps ?? [] {
                for source in step.sources ?? [] where seen.insert(source.url).inserted {
                    sources.append(Source(title: source.title, url: source.url, message: message.id.uuidString))
                }
            }
        }
        return Output(sources: sources)
    }
}

struct ChatStateGetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String?
    }
    struct Output: Encodable, Sendable {
        var chat: String?
        var title: String?
        var model: String?
        var contextLength: Int?
        var persona: String?
        var skills: [String]
        var memory: Bool
        var webSearch: Bool
        var wikipedia: Bool
        var thinking: Bool
        var generating: Bool
        var locked: Bool
        var usedTokens: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.state.get", summary: "Zeigt Modell, Kontext, Persona, Skills, Schalter und ob ein Chat antwortet; ohne chat den offenen", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        guard let chat = try args.chat.map({ try app.actionChat($0) }) ?? app.selectedChat else {
            return Output(skills: [], memory: false, webSearch: false, wikipedia: false, thinking: false, generating: false, locked: false)
        }
        return Output(chat: chat.id.uuidString, title: chat.title, model: app.modelId(for: chat), contextLength: app.contextLength(of: chat),
                      persona: app.persona(of: chat)?.displayName, skills: app.skills(of: chat).map(\.displayName), memory: chat.memory == .on,
                      webSearch: chat.webSearch == true, wikipedia: chat.wikipediaSearch == true, thinking: chat.thinking == true,
                      generating: app.isGenerating(chat.id), locked: !chat.messages.isEmpty, usedTokens: app.contextUsage(for: chat).parts.reduce(0) { $0 + $1.tokens })
    }
}

struct ChatContextUsageAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Part: Encodable, Sendable {
        var label: String
        var tokens: Int
    }
    struct Output: Encodable, Sendable {
        var used: Int
        var available: Int
        var parts: [Part]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.context.usage", summary: "Zeigt, wie viele Token ein Chat belegt und zur Verfügung hat, geschätzt", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let usage = context.app.contextUsage(for: chat)
        return Output(used: usage.parts.reduce(0) { $0 + $1.tokens }, available: context.app.contextLength(of: chat), parts: usage.parts.map { Part(label: $0.label, tokens: $0.tokens) })
    }
}

// MARK: Messages

struct ChatRegenerateAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.regenerate", summary: "Lässt die letzte Antwort neu schreiben; läuft im Hintergrund", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        guard chat.messages.last?.role == .assistant else { throw RPCError.invalidTarget("Es gibt keine Antwort zum Neuschreiben.") }
        try context.beginTurn(in: chat)
        context.app.regenerate(chat.id)
        return OKOutput(id: chat.id.uuidString, message: "Läuft. Ergebnis: chat.wait")
    }
}

struct ChatEditAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.edit", summary: "Stellt eine Frage anders: als neuer Zweig; der Chat bleibt, wie er ist", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "message": messageReference, "text": .string("Die neue Frage")], required: ["chat", "message", "text"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        let message = try app.actionMessage(args.message, in: chat)
        guard message.role == .user, let position = chat.messages.firstIndex(where: { $0.id == message.id }) else { throw RPCError.invalidTarget("Nur Fragen lassen sich bearbeiten.") }
        let text = (args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError.invalidParams("Die Frage ist leer.") }
        try context.checkNoRecursion(into: chat.id)
        var branch = app.makeBranch(of: chat, keeping: position, from: message.id, editedQuestion: true)
        if position == 0, !chat.isTitleCustom { branch.title = AppModel.title(for: text) }
        branch.messages.append(ChatMessage(role: .user, content: text))
        app.addChatFromAction(branch)
        try context.beginTurn(in: branch)
        app.generate(in: branch.id)
        return OKOutput(id: branch.id.uuidString, message: "Neuer Zweig. Ergebnis: chat.wait")
    }
}

struct ChatFollowUpsGetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var followUps: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.followUps.get", summary: "Liest die vorgeschlagenen Folgefragen einer Antwort", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference, "message": messageReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        return Output(followUps: try context.app.actionMessage(args.message, in: chat).followUps ?? [])
    }
}

struct ChatFollowUpsSendAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.followUps.send", summary: "Stellt eine vorgeschlagene Folgefrage; läuft im Hintergrund", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "index": .integer("Welche Folgefrage der letzten Antwort, ab 1", minimum: 1), "text": .string("Oder eine eigene")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        var question = args.text
        if question == nil, let index = args.index {
            let suggested = chat.messages.last { $0.role == .assistant }?.followUps ?? []
            guard suggested.indices.contains(index - 1) else { throw RPCError.notFound("Folgefrage \(index) gibt es nicht (\(suggested.count) vorhanden).") }
            question = suggested[index - 1]
        }
        guard let question, !question.isEmpty else { throw RPCError.invalidParams("Bitte index oder text angeben.") }
        guard let model = app.modelId(for: chat) ?? app.currentModelId else { throw RPCError.unavailable("Es ist kein Modell gewählt.") }
        try context.beginTurn(in: chat)
        app.ask(question, images: [], in: chat.id, model: model)
        return OKOutput(id: chat.id.uuidString, message: "Läuft. Ergebnis: chat.wait")
    }
}

struct ChatMessageCopyAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "chat.message.copy", summary: "Liefert den Text einer Nachricht als Markdown oder reinen Text", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference, "message": messageReference, "format": .choice(["markdown", "plain"], "Standard: markdown")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let content = try context.app.actionMessage(args.message, in: chat).content
        return Output(text: args.format == "plain" ? PowerText.plain(content) : content)
    }
}

struct ChatDraftSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.draft.set", summary: "Schreibt in das Eingabefeld eines Chats, ohne zu senden", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "text": .string("Der Text")], required: ["chat", "text"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat).id
        let before = app.draftText(of: id), text = args.text ?? ""
        app.setDraftText(text, of: id)
        context.undoGroup.add(UndoStep(label: "Entwurf", undo: { app.setDraftText(before, of: id) }, redo: { app.setDraftText(text, of: id) }))
        return OKOutput(id: id.uuidString)
    }
}

struct ChatDraftGetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Output: Encodable, Sendable {
        var text: String
        var images: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.draft.get", summary: "Liest das Eingabefeld eines Chats", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let id = try context.app.actionChat(args.chat).id
        return Output(text: context.app.draftText(of: id), images: context.app.draftImages(of: id).map(\.id.uuidString))
    }
}

// MARK: Settings

/// Settings that are fixed once a chat has begun, as in the app. The action says so instead of doing nothing.
@MainActor
private func checkNotStarted(_ chat: Chat) throws {
    guard chat.messages.isEmpty else { throw RPCError.invalidTarget("Das geht nur vor der ersten Nachricht. Dieser Chat hat schon begonnen.") }
}

private let switchProperties: [String: JSONSchema] = ["chat": chatReference, "value": .boolean("An oder aus")]

struct ChatModelSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.model.set", summary: "Setzt das Modell eines Chats", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "model": .string("Modell aus models.list")], required: ["chat", "model"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        guard context.app.models.contains(where: { $0.id == args.model }) else { throw RPCError.notFound("Das Modell „\(args.model ?? "")“ gibt es nicht. models.list zeigt sie.") }
        context.changeChat(chat.id, label: "Modell") { $0.modelId = args.model }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatContextLengthSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let lengths = [8192, 16384, 32768]
    static let descriptor = ActionDescriptor(
        id: "chat.contextLength.set", summary: "Setzt die Kontextlänge eines Chats vor der ersten Nachricht: 8192, 16384 oder 32768; das Modell lädt beim Senden neu", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "contextLength": .integer("Token", minimum: 8192, maximum: 32768)], required: ["chat", "contextLength"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try checkNotStarted(chat)
        guard let length = args.contextLength, lengths.contains(length) else { throw RPCError.invalidParams("Möglich sind 8192, 16384 oder 32768.") }
        context.changeChat(chat.id, label: "Kontextlänge") { $0.contextLength = length }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatThinkingSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.thinking.set", summary: "Schaltet den Denkmodus eines Chats", kind: .write, security: .localWrite, input: .object(switchProperties, required: ["chat", "value"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        context.changeChat(chat.id, label: "Denkmodus") { $0.thinking = args.value == true ? true : nil }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatWebSearchSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.webSearch.set", summary: "Schaltet die Websuche eines Chats; ein Chat kann das nicht bei sich selbst", kind: .write, security: .localWrite, input: .object(switchProperties, required: ["chat", "value"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try context.checkOwnSettings(of: chat)
        context.changeChat(chat.id, label: "Websuche") { $0.webSearch = args.value == true ? true : nil }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatWikipediaSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.wikipedia.set", summary: "Schaltet die Wikipedia-Suche eines Chats; ein Chat kann das nicht bei sich selbst", kind: .write, security: .localWrite, input: .object(switchProperties, required: ["chat", "value"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try context.checkOwnSettings(of: chat)
        context.changeChat(chat.id, label: "Wikipedia") { $0.wikipediaSearch = args.value == true ? true : nil }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatMemorySetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.memory.set", summary: "Schaltet das Gedächtnis eines Chats vor der ersten Nachricht; er braucht eine Persona", kind: .write,
        security: ActionSecurity(readsUntrusted: false, sensitive: true, effect: .local),
        input: .object(switchProperties, required: ["chat", "value"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try context.checkOwnSettings(of: chat)
        try checkNotStarted(chat)
        if args.value == true, chat.personaID == nil { throw RPCError.invalidTarget("Gedächtnis gibt es nur mit einer Persona.") }
        context.changeChat(chat.id, label: "Gedächtnis") { $0.memory = args.value == true ? .on : nil }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatPersonaSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.persona.set", summary: "Setzt die Persona eines Chats vor der ersten Nachricht; ohne persona keine", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "persona": .string("Persona (ID oder Name)")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try context.checkOwnSettings(of: chat)
        try checkNotStarted(chat)
        let persona = try args.persona.map { try context.app.actionPersona($0).id }
        context.changeChat(chat.id, label: "Persona") { chat in
            chat.personaID = persona
            if persona != nil { chat.skillIDs = nil } else { chat.memory = nil }
        }
        return OKOutput(id: chat.id.uuidString)
    }
}

struct ChatSkillsSetAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.skills.set", summary: "Ändert die Skills eines Chats vor der ersten Nachricht", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "add": .array(of: .string(), "Hinzu"), "remove": .array(of: .string(), "Weg")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        try context.checkOwnSettings(of: chat)
        try checkNotStarted(chat)
        guard chat.personaID == nil else { throw RPCError.invalidTarget("Ein Chat mit Persona hat keine Skills.") }
        let add = try (args.add ?? []).map { try context.app.actionSkill($0).id }, remove = try (args.remove ?? []).map { try context.app.actionSkill($0).id }
        context.changeChat(chat.id, label: "Skills") { chat in
            var skills = chat.skillIDs ?? []
            for id in add where !skills.contains(id) { skills.append(id) }
            skills.removeAll { remove.contains($0) }
            chat.skillIDs = skills.isEmpty ? nil : skills
        }
        return OKOutput(id: chat.id.uuidString)
    }
}

// MARK: Bookmarks

struct ChatBookmarkAddAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.bookmark.add", summary: "Setzt ein Lesezeichen auf eine Nachricht oder eine Stelle darin", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "message": messageReference, "selectedText": .string("Die Stelle in der Nachricht")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let message = try context.app.actionMessage(args.message, in: chat)
        let selection = args.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excerpt = selection.isEmpty ? message.content : selection
        let target = BookmarkLocator.target(for: selection, in: message) ?? OutlineTarget(messageID: message.id, block: nil)
        let bookmark = Bookmark(title: BookmarkLocator.title(from: excerpt), excerpt: String(excerpt.prefix(500)), target: target)
        context.changeChat(chat.id, label: "Lesezeichen") { $0.bookmarks = ($0.bookmarks ?? []) + [bookmark] }
        return OKOutput(id: bookmark.id.uuidString)
    }
}

struct ChatBookmarkRenameAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.bookmark.rename", summary: "Benennt ein Lesezeichen um", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "bookmark": .string("Lesezeichen (ID)"), "title": .string("Neuer Titel")], required: ["chat", "bookmark", "title"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RPCError.invalidParams("Der Titel ist leer.") }
        guard chat.bookmarks?.contains(where: { $0.id.uuidString == args.bookmark }) == true else { throw RPCError.notFound("Dieses Lesezeichen gibt es nicht.") }
        context.changeChat(chat.id, label: "Lesezeichen") { chat in
            guard let index = chat.bookmarks?.firstIndex(where: { $0.id.uuidString == args.bookmark }) else { return }
            chat.bookmarks?[index].title = title
        }
        return OKOutput()
    }
}

struct ChatBookmarkDeleteAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.bookmark.delete", summary: "Löscht ein Lesezeichen", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "bookmark": .string("Lesezeichen (ID)")], required: ["chat", "bookmark"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        guard chat.bookmarks?.contains(where: { $0.id.uuidString == args.bookmark }) == true else { throw RPCError.notFound("Dieses Lesezeichen gibt es nicht.") }
        context.changeChat(chat.id, label: "Lesezeichen") { $0.bookmarks?.removeAll { $0.id.uuidString == args.bookmark } }
        return OKOutput()
    }
}

struct ChatBookmarkListAction: LLMDAction {
    typealias Args = ChatMoreArgs
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var excerpt: String
        var message: String
    }
    struct Output: Encodable, Sendable {
        var bookmarks: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.bookmark.list", summary: "Listet die Lesezeichen eines Chats", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        Output(bookmarks: (try context.app.actionChat(args.chat).bookmarks ?? []).map {
            Item(id: $0.id.uuidString, title: $0.title, excerpt: $0.excerpt, message: $0.target.messageID.uuidString)
        })
    }
}

struct ChatJumpAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.jump", summary: "Öffnet einen Chat an einer Nachricht, einem Lesezeichen oder Eintrag des Inhaltsverzeichnisses", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference, "message": messageReference, "bookmark": .string("Lesezeichen (ID)"), "outlineEntry": .string("Eintrag (ID)")], required: ["chat"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        let target: OutlineTarget
        if let reference = args.bookmark {
            guard let bookmark = chat.bookmarks?.first(where: { $0.id.uuidString == reference }) else { throw RPCError.notFound("Dieses Lesezeichen gibt es nicht.") }
            target = bookmark.target
        } else if let reference = args.outlineEntry {
            let sections = chat.outline?.sections ?? []
            let entries = sections.map { ($0.id, $0.target) } + sections.flatMap(\.items).map { ($0.id, $0.target) }
            guard let entry = entries.first(where: { $0.0.uuidString == reference }) else { throw RPCError.notFound("Diesen Eintrag gibt es nicht.") }
            target = entry.1
        } else {
            target = OutlineTarget(messageID: try app.actionMessage(args.message, in: chat).id, block: nil)
        }
        if app.selectedChatID != chat.id { app.selectChat(chat.id) }
        app.jump(to: target)
        return OKOutput(id: chat.id.uuidString)
    }
}

// MARK: Export

struct ChatExportPdfAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "chat.export.pdf", summary: "Schreibt einen Chat als PDF", kind: .destructive, security: .outbound,
        input: .object(["chat": chatReference, "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen"), "withOutline": .boolean("Mit Inhaltsverzeichnis")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let chat = try context.app.actionChat(args.chat)
        let check = context.app.chatPreflight(chat)
        return context.exportPreflight(path: args.path, readsUntrusted: check.readsUntrusted, readsSensitive: check.readsSensitive, detail: chat.title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        guard let engine = LaTeXEngine.locate() else { throw RPCError.unavailable(PDFExportError.noEngine.localizedDescription) }
        let url = try context.exportURL(named: chat.title, extension: "pdf", path: args.path, overwrite: args.overwrite)
        let parts = app.exportParts(of: chat, outline: args.withOutline == true ? chat.outline : nil)
        let pdf = try await engine.makePDF(parts: parts.parts, outline: parts.outline, paper: app.pdfPaperSize)
        try pdf.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: pdf.count)
    }
}

struct ChatExportAnswerAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "chat.export.answer", summary: "Schreibt eine einzelne Antwort als PDF", kind: .destructive, security: .outbound,
        input: .object(["chat": chatReference, "message": messageReference, "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let chat = try context.app.actionChat(args.chat)
        let check = context.app.chatPreflight(chat)
        return context.exportPreflight(path: args.path, readsUntrusted: check.readsUntrusted, readsSensitive: check.readsSensitive, detail: chat.title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let chat = try app.actionChat(args.chat)
        let message = try app.actionMessage(args.message, in: chat)
        guard !message.content.isEmpty else { throw RPCError.invalidTarget("Diese Nachricht hat keinen Text.") }
        guard let engine = LaTeXEngine.locate() else { throw RPCError.unavailable(PDFExportError.noEngine.localizedDescription) }
        let url = try context.exportURL(named: chat.title + " – Antwort", extension: "pdf", path: args.path, overwrite: args.overwrite)
        let label = app.pdfSpeakerLineEnabled ? LaTeXWriter.speakerLine(template: app.pdfSpeakerTemplate, model: message.model, name: app.persona(of: chat)?.displayName) : nil
        let pdf = try await engine.makePDF(parts: [LaTeXWriter.Part(label: label, text: message.content)], outline: nil, paper: app.pdfPaperSize)
        try pdf.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: pdf.count)
    }
}

struct ChatExportMarkdownAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "chat.export.markdown", summary: "Schreibt einen Chat als Markdown-Datei", kind: .destructive, security: .outbound,
        input: .object(["chat": chatReference, "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let chat = try context.app.actionChat(args.chat)
        let check = context.app.chatPreflight(chat)
        return context.exportPreflight(path: args.path, readsUntrusted: check.readsUntrusted, readsSensitive: check.readsSensitive, detail: chat.title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let url = try context.exportURL(named: chat.title, extension: "md", path: args.path, overwrite: args.overwrite)
        let data = Data((context.app.transcript(of: chat) + "\n").utf8)
        try data.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: data.count)
    }
}

struct ChatToDocumentAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.toDocument", summary: "Macht aus einem Chat oder einzelnen Nachrichten ein neues Writer-Dokument", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "messages": .array(of: .string(), "Nur diese Nachrichten"), "title": .string("Titel")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var chat = try app.actionChat(args.chat)
        if let references = args.messages {
            let wanted = try references.map { try app.actionMessage($0, in: chat).id }
            chat.messages = chat.messages.filter { wanted.contains($0.id) }
        }
        let markdown = app.transcript(of: chat)
        guard !markdown.isEmpty else { throw RPCError.invalidTarget("Hier gibt es keinen Text.") }
        // What a chat found on the web or read from someone else's text stays foreign in its new place.
        let origin = context.mergedProvenance(app.chatPreflight(chat).readsUntrusted ? .foreign : nil)
        let made = app.createDocumentForAction(title: args.title ?? chat.title, folderID: nil, markdown: markdown, provenance: origin)
        let id = made.id
        context.undoGroup.add(UndoStep(label: "Dokument anlegen", undo: { app.removeDocumentForActionUndo(id) }, redo: { app.reinsertDocumentForActionRedo(made) }))
        return OKOutput(id: id.uuidString)
    }
}

// MARK: Folders

struct FolderArgs: Decodable, Sendable {
    var section: String?
    var folder: String?
    var name: String?
    var color: String?
    var collapsed: Bool?
    var includingContents: Bool?
}

extension AppModel {
    func actionAnyFolder(_ reference: String) throws -> Folder {
        let all = chatFolders + skillFolders
        if let id = UUID(uuidString: reference), let folder = all.first(where: { $0.id == id }) { return folder }
        let found = all.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Ordner „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Ordner heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }
}

struct FolderCreateAction: LLMDAction {
    typealias Args = FolderArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "folder.create", summary: "Legt einen Ordner für Chats oder Skills an", kind: .write, security: .localWrite,
        input: .object(["section": .choice(["chats", "skills"], "Wofür"), "name": .string("Name"), "color": .choice(FolderColor.allCases.map(\.rawValue), "Farbe")], required: ["section", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = app.createFolder(for: args.section == "skills" ? .skills : .chats)
        // The new folder isn't waiting for someone to type its name.
        app.renamingID = nil
        app.renameFolder(id, to: args.name ?? "")
        if let color = args.color.flatMap(FolderColor.init(rawValue:)) { app.setFolderColor(id, to: color) }
        context.undoGroup.add(UndoStep(label: "Ordner anlegen", undo: { app.deleteFolder(id, includingContents: false) }, redo: {
            let again = app.createFolder(for: args.section == "skills" ? .skills : .chats)
            app.renamingID = nil
            app.renameFolder(again, to: args.name ?? "")
        }))
        return OKOutput(id: id.uuidString)
    }
}

struct FolderRenameAction: LLMDAction {
    typealias Args = FolderArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "folder.rename", summary: "Benennt einen Ordner um", kind: .write, security: .localWrite,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "name": .string("Neuer Name")], required: ["folder", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let folder = try app.actionAnyFolder(args.folder ?? "")
        let name = args.name ?? ""
        app.renameFolder(folder.id, to: name)
        context.undoGroup.add(UndoStep(label: "Ordner umbenennen", undo: { app.renameFolder(folder.id, to: folder.name) }, redo: { app.renameFolder(folder.id, to: name) }))
        return OKOutput(id: folder.id.uuidString)
    }
}

struct FolderColorAction: LLMDAction {
    typealias Args = FolderArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "folder.color", summary: "Gibt einem Ordner eine Farbe; none nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "color": .choice(FolderColor.allCases.map(\.rawValue) + ["none"], "Farbe")], required: ["folder", "color"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let folder = try app.actionAnyFolder(args.folder ?? "")
        let color = args.color.flatMap(FolderColor.init(rawValue:))
        app.setFolderColor(folder.id, to: color)
        context.undoGroup.add(UndoStep(label: "Ordnerfarbe", undo: { app.setFolderColor(folder.id, to: folder.color) }, redo: { app.setFolderColor(folder.id, to: color) }))
        return OKOutput(id: folder.id.uuidString)
    }
}

struct FolderCollapseAction: LLMDAction {
    typealias Args = FolderArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "folder.collapse", summary: "Klappt einen Ordner zu oder auf", kind: .write, security: .localWrite,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "collapsed": .boolean("Zu oder auf")], required: ["folder", "collapsed"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let folder = try context.app.actionAnyFolder(args.folder ?? "")
        if (folder.isCollapsed == true) != (args.collapsed == true) { context.app.toggleFolderCollapsed(folder.id) }
        return OKOutput(id: folder.id.uuidString)
    }
}

struct FolderDeleteAction: LLMDAction {
    typealias Args = FolderArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "folder.delete", summary: "Löscht einen Ordner; sein Inhalt bleibt, außer mit includingContents", kind: .destructive, security: .destructive,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "includingContents": .boolean("Chats oder Skills darin mitlöschen")], required: ["folder"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionAnyFolder(args.folder ?? "").name, detail: args.includingContents == true ? "samt Inhalt" : nil)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let folder = try context.app.actionAnyFolder(args.folder ?? "")
        context.app.deleteFolder(folder.id, includingContents: args.includingContents == true)
        return OKOutput(id: folder.id.uuidString)
    }
}
