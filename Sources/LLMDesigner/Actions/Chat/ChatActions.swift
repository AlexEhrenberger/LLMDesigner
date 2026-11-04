import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerChatActions() {
        register(ChatListAction.self)
        register(ChatCreateAction.self)
        register(ChatReadAction.self)
        register(ChatSearchAction.self)
        register(ChatSendAction.self)
        register(ChatWaitAction.self)
        register(ChatAskAction.self)
        register(ChatStatusAction.self)
        register(ChatStopAction.self)
        register(ChatDeleteAction.self)
        register(PersonaListAction.self)
        register(SkillListAction.self)
        register(SkillReadAction.self)
        register(SkillCreateAction.self)
        register(ModelsListAction.self)
        register(MemoryListAction.self)
        register(MemoryProfileGetAction.self)
        register(PersonaFilesSearchAction.self)
        registerChatToolActions()
        registerChatMoreActions()
    }
}

extension AppModel {
    func actionChat(_ reference: String) throws -> Chat {
        if let id = UUID(uuidString: reference) {
            guard let chat = chat(id) else { throw RPCError.notFound("Chat \(reference) gibt es nicht.") }
            return chat
        }
        let found = chats.filter { $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Chat „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Chats heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    func actionPersona(_ reference: String) throws -> Persona {
        if let id = UUID(uuidString: reference), let persona = persona(id) { return persona }
        let found = personas.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Persona „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Personas heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    func actionSkill(_ reference: String) throws -> Skill {
        if let id = UUID(uuidString: reference), let skill = skill(id) { return skill }
        let found = skills.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Skill „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Skills heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    /// What answering in this chat touches: a persona with files or memory means private data, the web means foreign.
    func chatPreflight(_ chat: Chat) -> ActionPreflight {
        let persona = persona(of: chat)
        let isPrivate = chat.memory == .on || persona?.files?.isEmpty == false
            || chat.messages.contains { $0.toolSteps?.contains { $0.kind.isFile } == true }
        let isForeign = chat.webSearch == true || chat.wikipediaSearch == true
            || chat.messages.contains { $0.toolSteps?.contains { !$0.kind.isFile && $0.kind != .action } == true }
        return ActionPreflight(readsUntrusted: isForeign, readsSensitive: isPrivate, target: chat.title)
    }
}

/// A chat must not message itself, directly or round a circle. Each chat that an action is waiting on is noted here;
/// such a chat can't be asked again, and while it is being asked its own action tools stay off.
extension ActionContext {
    func checkNoRecursion(into chat: Chat.ID) throws {
        guard channel == .chat else { return }
        guard run.id != chat.uuidString, !app.chatsBeingAskedByActions.contains(chat) else {
            throw RPCError.denied("Ein Chat kann sich nicht selbst Nachrichten schicken.")
        }
    }
}

struct MessageInfo: Encodable, Sendable {
    struct Step: Encodable, Sendable {
        var kind: String
        var argument: String
        var status: String
    }
    var id: String
    var role: String
    var text: String
    var model: String?
    var time: Date
    var reasoning: String?
    var error: String?
    var images: Int?
    var tools: [Step]?

    init(_ message: ChatMessage, withReasoning: Bool, withTools: Bool) {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.content
        model = message.model
        time = message.createdAt
        reasoning = withReasoning ? message.reasoning : nil
        error = message.error
        images = message.images?.count
        if withTools, let steps = message.toolSteps, !steps.isEmpty {
            tools = steps.map { Step(kind: $0.kind.rawValue, argument: $0.argument, status: $0.status.rawValue) }
        }
    }
}

struct ChatListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
        var persona: String?
        var limit: Int?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var updated: Date
        var messages: Int
        var persona: String?
    }
    struct Output: Encodable, Sendable {
        var chats: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.list", summary: "Listet die Chats", kind: .read, security: .plainRead,
        input: .object(["query": .string("Suchtext im Titel"), "persona": .string("Nur mit dieser Persona"), "limit": .integer("Höchstens so viele", minimum: 1)]),
        output: .freeObject(), groups: ["core", "chat.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let personaID = try args.persona.map { try app.actionPersona($0).id }
        let chats = app.chats
            .filter { (args.query == nil || $0.title.localizedCaseInsensitiveContains(args.query!)) && (personaID == nil || $0.personaID == personaID) }
            .prefix(args.limit ?? 200)
        return Output(chats: chats.map {
            Item(id: $0.id.uuidString, title: $0.title, updated: $0.updatedAt, messages: $0.messages.count, persona: app.persona(of: $0)?.name)
        })
    }
}

struct ChatCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String?
        var persona: String?
        var skills: [String]?
        var model: String?
        var contextLength: Int?
        var memory: Bool?
        var webSearch: Bool?
        var wikipedia: Bool?
        var thinking: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.create", summary: "Legt einen Chat an, ohne ihn zu öffnen", kind: .write, security: .localWrite,
        input: .object([
            "title": .string("Titel"), "persona": .string("Persona (ID oder Name)"), "skills": .array(of: .string(), "Skills (ID oder Name)"),
            "model": .string("Modell"), "contextLength": .integer("8192, 16384 oder 32768"), "memory": .boolean("Gedächtnis der Persona an"),
            "webSearch": .boolean("Websuche an"), "wikipedia": .boolean("Wikipedia an"), "thinking": .boolean("Denkmodus an"),
        ]),
        output: .freeObject(), example: "llmd chat create --title Recherche --json", groups: ["core", "chat.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        var chat = Chat(title: args.title ?? "Neuer Chat", modelId: args.model ?? app.currentModelId)
        chat.hasCustomTitle = args.title != nil
        chat.webSearch = args.webSearch == true ? true : nil
        chat.wikipediaSearch = args.wikipedia == true ? true : nil
        chat.thinking = args.thinking == true ? true : nil
        chat.contextLength = args.contextLength ?? (app.provider.loadsModels ? app.newChatContextLength : nil)
        if let persona = args.persona {
            chat.personaID = try app.actionPersona(persona).id
            if args.memory == true { chat.memory = .on }
        } else if let skills = args.skills {
            chat.skillIDs = try skills.map { try app.actionSkill($0).id }
        }
        let made = chat
        app.addChatFromAction(made)
        context.undoGroup.add(UndoStep(label: "Chat anlegen", undo: { app.deleteChat(made.id) }, redo: { app.addChatFromAction(made) }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct ChatReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String
        var from: Int?
        var limit: Int?
        var withReasoning: Bool?
        var withTools: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var total: Int
        var messages: [MessageInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.read", summary: "Liest die Nachrichten eines Chats", kind: .read, security: .plainRead,
        input: .object(["chat": .string("Chat (ID oder Titel)"), "from": .integer("Ab dieser Nachricht, von 0", minimum: 0), "limit": .integer("Höchstens so viele", minimum: 1),
                        "withReasoning": .boolean("Mit dem Denken des Modells"), "withTools": .boolean("Mit Werkzeugschritten")], required: ["chat"]),
        output: .freeObject(), groups: ["core", "chat.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        context.app.chatPreflight(try context.app.actionChat(args.chat))
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let start = min(args.from ?? 0, chat.messages.count)
        let messages = chat.messages[start...].prefix(args.limit ?? .max)
        return Output(id: chat.id.uuidString, title: chat.title, total: chat.messages.count,
                      messages: messages.map { MessageInfo($0, withReasoning: args.withReasoning == true, withTools: args.withTools == true) })
    }
}

struct ChatSearchAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String
        var limit: Int?
    }
    struct Hit: Encodable, Sendable {
        var chat: String
        var title: String
        var message: String
        var role: String
        var excerpt: String
    }
    struct Output: Encodable, Sendable {
        var hits: [Hit]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.search", summary: "Sucht über alle Chats", kind: .read, security: .foreignRead,
        input: .object(["query": .string("Suchtext"), "limit": .integer("Höchstens so viele", minimum: 1)], required: ["query"]),
        output: .freeObject(), groups: ["core", "chat.core"]
    )
    /// Chats with a persona's private material stay out of a search, which can't ask about each of them.
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var hits: [Hit] = []
        let limit = args.limit ?? 30
        for chat in app.chats where !app.chatPreflight(chat).readsSensitive || context.channel == .ui {
            for message in chat.messages where hits.count < limit {
                guard let excerpt = PowerText.snippet(of: message.content, around: args.query) else { continue }
                hits.append(Hit(chat: chat.id.uuidString, title: chat.title, message: message.id.uuidString, role: message.role.rawValue, excerpt: excerpt))
            }
        }
        return Output(hits: hits)
    }
}

struct ChatTextArgs: Decodable, Sendable {
    var chat: String
    var text: String
    var timeout: Int?
}

/// Starting a turn is the same for `send` and `ask`.
@MainActor
private func startTurn(_ args: ChatTextArgs, context: ActionContext) throws -> (Chat, messageCount: Int) {
    let app = context.app
    let chat = try app.actionChat(args.chat)
    try context.checkNoRecursion(into: chat.id)
    guard !app.isGenerating(chat.id) else { throw RPCError.unavailable("In diesem Chat läuft gerade eine Antwort.") }
    guard let model = app.modelId(for: chat) ?? app.currentModelId else { throw RPCError.unavailable("Es ist kein Modell gewählt.") }
    let count = chat.messages.count
    // A turn from a program or a marked run gets no action tools: otherwise it could have its work done by a chat whose
    // run looks clean. The person at the terminal may use them. It ends with the answer (`finishGeneration`).
    if context.channel != .cli || context.run.hasReadUntrusted { app.chatsBeingAskedByActions.insert(chat.id) }
    app.ask(args.text, images: [], in: chat.id, model: model)
    return (chat, count)
}

@MainActor
private func answer(in chatID: Chat.ID, after count: Int, app: AppModel) -> ChatMessage? {
    app.chat(chatID)?.messages.dropFirst(count).last { $0.role == .assistant }
}

/// Waits for the chat to go quiet. It stays on the main actor only between short naps, so the UI keeps going.
@MainActor
private func waitForAnswer(in chatID: Chat.ID, app: AppModel, timeout: Int) async throws {
    let end = Date().addingTimeInterval(Double(timeout))
    while app.isGenerating(chatID) {
        guard Date() < end else { throw RPCError(code: RPCError.unavailableCode, message: "Die Antwort läuft noch. Später mit chat.wait abholen.") }
        try await Task.sleep(for: .milliseconds(100))
    }
}

private let chatTextSchema: [String: JSONSchema] = ["chat": .string("Chat (ID oder Titel)"), "text": .string("Die Nachricht")]

struct ChatSendAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var chat: String
        var message: String?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.send", summary: "Schickt eine Nachricht; die Antwort läuft im Hintergrund", kind: .write, security: .localWrite,
        input: .object(chatTextSchema, required: ["chat", "text"]), output: .freeObject(), groups: ["chat.core"]
    )
    static func preflight(_ args: ChatTextArgs, context: ActionContext) throws -> ActionPreflight {
        context.app.chatPreflight(try context.app.actionChat(args.chat))
    }
    static func run(_ args: ChatTextArgs, context: ActionContext) async throws -> Output {
        let (chat, count) = try startTurn(args, context: context)
        return Output(chat: chat.id.uuidString, message: answer(in: chat.id, after: count, app: context.app)?.id.uuidString)
    }
}

struct ChatWaitAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String
        var timeout: Int?
    }
    static let defaultTimeout = 300
    static let descriptor = ActionDescriptor(
        id: "chat.wait", summary: "Wartet auf die Antwort und liefert sie", kind: .read, security: .plainRead,
        input: .object(["chat": .string("Chat (ID oder Titel)"), "timeout": .integer("Sekunden; Standard 300", minimum: 1)], required: ["chat"]),
        output: .freeObject(), groups: ["chat.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        context.app.chatPreflight(try context.app.actionChat(args.chat))
    }
    static func run(_ args: Args, context: ActionContext) async throws -> MessageInfo {
        let chat = try context.app.actionChat(args.chat)
        try await waitForAnswer(in: chat.id, app: context.app, timeout: args.timeout ?? defaultTimeout)
        guard let last = context.app.chat(chat.id)?.messages.last(where: { $0.role == .assistant }) else { throw RPCError.notFound("In diesem Chat gibt es keine Antwort.") }
        return MessageInfo(last, withReasoning: false, withTools: true)
    }
}

struct ChatAskAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "chat.ask", summary: "Fragt das lokale Modell oder eine Persona und liefert die Antwort", kind: .write, security: .localWrite,
        input: .object(chatTextSchema.merging(["timeout": .integer("Sekunden; Standard 300", minimum: 1)]) { _, new in new }, required: ["chat", "text"]),
        output: .freeObject(), example: "llmd chat ask Recherche 'Fasse das zusammen'", groups: ["core", "chat.core"]
    )
    static func preflight(_ args: ChatTextArgs, context: ActionContext) throws -> ActionPreflight {
        context.app.chatPreflight(try context.app.actionChat(args.chat))
    }
    static func run(_ args: ChatTextArgs, context: ActionContext) async throws -> MessageInfo {
        let app = context.app
        let (chat, count) = try startTurn(args, context: context)
        try await waitForAnswer(in: chat.id, app: app, timeout: args.timeout ?? ChatWaitAction.defaultTimeout)
        guard let last = answer(in: chat.id, after: count, app: app) else { throw RPCError.internal("Es kam keine Antwort.") }
        if let error = last.error { throw RPCError.unavailable("Das Modell antwortet nicht: \(error)") }
        return MessageInfo(last, withReasoning: false, withTools: true)
    }
}

struct ChatRefArgs: Decodable, Sendable {
    var chat: String
}

struct ChatStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var state: String
        var message: String?
    }
    static let descriptor = ActionDescriptor(
        id: "chat.status", summary: "Zeigt, ob ein Chat gerade antwortet", kind: .read, security: .plainRead,
        input: .object(["chat": .string("Chat (ID oder Titel)")], required: ["chat"]), output: .freeObject(), groups: ["chat.core"]
    )
    static func run(_ args: ChatRefArgs, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        guard context.app.isGenerating(chat.id) else { return Output(state: "idle") }
        let message = chat.messages.last
        if message?.toolSteps?.contains(where: { $0.status == .running }) == true { return Output(state: "werkzeug", message: message?.id.uuidString) }
        return Output(state: "schreibt", message: message?.id.uuidString)
    }
}

struct ChatStopAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "chat.stop", summary: "Bricht die laufende Antwort ab", kind: .write, security: .localWrite,
        input: .object(["chat": .string("Chat (ID oder Titel)")], required: ["chat"]), output: .freeObject(), groups: ["chat.core"]
    )
    static func run(_ args: ChatRefArgs, context: ActionContext) async throws -> OKOutput {
        context.app.stopGeneration(in: try context.app.actionChat(args.chat).id)
        return OKOutput()
    }
}

struct ChatDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "chat.delete", summary: "Löscht einen Chat endgültig", kind: .destructive, security: .destructive,
        input: .object(["chat": .string("Chat (ID oder Titel)")], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: ChatRefArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionChat(args.chat).title)
    }
    static func run(_ args: ChatRefArgs, context: ActionContext) async throws -> OKOutput {
        let chat = try context.app.actionChat(args.chat)
        try context.checkNoRecursion(into: chat.id)
        context.app.deleteChat(chat.id)
        return OKOutput(id: chat.id.uuidString)
    }
}

struct PersonaListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var name: String
        var files: Int
    }
    struct Output: Encodable, Sendable {
        var personas: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "persona.list", summary: "Listet die Personas: Name und Anzahl der Dateien, kein Inhalt", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["core", "chat.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(personas: context.app.personas.map { Item(id: $0.id.uuidString, name: $0.name, files: $0.files?.count ?? 0) })
    }
}

struct SkillListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var name: String
        var summary: String
        var folder: String?
        var herkunft: String?
    }
    struct Output: Encodable, Sendable {
        var skills: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "skill.list", summary: "Listet die Skills", kind: .read, security: .plainRead, output: .freeObject(), groups: ["core", "chat.core"]
    )
    static func preflight(_ args: NoArgs, context: ActionContext) throws -> ActionPreflight {
        // Names and summaries are text too.
        ActionPreflight(readsUntrusted: context.app.skills.contains { $0.provenance == .foreign })
    }
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        return Output(skills: app.skills.map {
            Item(id: $0.id.uuidString, name: $0.displayName, summary: $0.summary, folder: app.folderName($0.folderID), herkunft: $0.provenance?.rawValue)
        })
    }
}

struct SkillReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var skill: String
    }
    struct Output: Encodable, Sendable {
        var id: String
        var name: String
        var summary: String
        var instructions: String
        var herkunft: String?
    }
    static let descriptor = ActionDescriptor(
        id: "skill.read", summary: "Liest einen Skill mit seinen Anweisungen", kind: .read, security: .plainRead,
        input: .object(["skill": .string("Skill (ID oder Name)")], required: ["skill"]), output: .freeObject(), groups: ["chat.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let skill = try context.app.actionSkill(args.skill)
        var check = ActionPreflight(readsUntrusted: skill.provenance == .foreign, target: skill.displayName)
        // Its text ends up as a system prompt: from a stranger, that takes the person's word.
        if skill.provenance == .foreign {
            check.needsConsent = "Dieser Skill stammt aus fremder Quelle; sein Text würde als Anweisung an ein Modell gehen."
            check.detail = skill.instructions
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let skill = try context.app.actionSkill(args.skill)
        return Output(id: skill.id.uuidString, name: skill.displayName, summary: skill.summary, instructions: skill.instructions, herkunft: skill.provenance?.rawValue)
    }
}

struct SkillCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var summary: String?
        var instructions: String
    }
    static let descriptor = ActionDescriptor(
        id: "skill.create", summary: "Legt einen Skill an", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "summary": .string("Eine Zeile für die Liste"), "instructions": .string("Anweisungen für den System-Prompt")], required: ["name", "instructions"]),
        output: .freeObject(), groups: ["chat.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        var skill = Skill(name: args.name, summary: args.summary ?? "", instructions: args.instructions)
        skill.provenance = context.mergedProvenance(nil)
        app.skills.insert(skill, at: 0)
        app.saveSkillLibrary()
        let made = skill
        context.undoGroup.add(UndoStep(label: "Skill anlegen", undo: { app.deleteSkill(made.id) }, redo: {
            app.skills.insert(made, at: 0)
            app.saveSkillLibrary()
        }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct ModelsListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var loaded: Bool
        var contextLength: Int?
        var tools: Bool
        var vision: Bool
    }
    struct Output: Encodable, Sendable {
        var provider: String
        var current: String?
        var models: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "models.list", summary: "Listet die lokalen Modelle mit Ladezustand", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["core", "chat.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        return Output(provider: app.provider.rawValue, current: app.currentModelId, models: app.chatModels.map {
            Item(id: $0.id, loaded: $0.state == "loaded", contextLength: $0.loadedContextLength, tools: $0.acceptsTools, vision: $0.isVision)
        })
    }
}

// MARK: Private data

struct PersonaRefArgs: Decodable, Sendable {
    var persona: String
}

struct MemoryListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var persona: String
        var kind: String?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var kind: String
        var text: String
    }
    struct Output: Encodable, Sendable {
        var impressions: [String]?
        var memories: [String]?
        var facts: [String]?
        /// The same with ids, for `memory.delete`.
        var items: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "memory.list", summary: "Liest das Gedächtnis einer Persona", kind: .destructive, security: .sensitiveRead,
        input: .object(["persona": .string("Persona (ID oder Name)"), "kind": .choice(["impressions", "memories", "facts"], "Nur diese Art")], required: ["persona"]),
        output: .freeObject(), groups: ["chat.private"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona).name)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.thalamus[try context.app.actionPersona(args.persona).id] ?? ThalamusLibrary()
        let wanted = args.kind
        return Output(
            impressions: wanted == nil || wanted == "impressions" ? library.entries.map(\.category) : nil,
            memories: wanted == nil || wanted == "memories" ? library.memories?.map { "\($0.title): \($0.summary)" } ?? [] : nil,
            facts: wanted == nil || wanted == "facts" ? library.profile?.map(\.text) ?? [] : nil,
            items: (wanted == nil || wanted == "impressions" ? library.entries.map { Item(id: $0.id.uuidString, kind: "impression", text: $0.category) } : [])
                + (wanted == nil || wanted == "memories" ? (library.memories ?? []).map { Item(id: $0.id.uuidString, kind: "memory", text: "\($0.title): \($0.summary)") } : [])
                + (wanted == nil || wanted == "facts" ? (library.profile ?? []).map { Item(id: $0.id.uuidString, kind: "fact", text: $0.text) } : [])
        )
    }
}

struct MemoryProfileGetAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var facts: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "memory.profile.get", summary: "Liest, was eine Persona über den Nutzer weiß", kind: .destructive, security: .sensitiveRead,
        input: .object(["persona": .string("Persona (ID oder Name)")], required: ["persona"]), output: .freeObject(), groups: ["chat.private"]
    )
    static func preflight(_ args: PersonaRefArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona).name)
    }
    static func run(_ args: PersonaRefArgs, context: ActionContext) async throws -> Output {
        Output(facts: context.app.thalamus[try context.app.actionPersona(args.persona).id]?.profile?.map(\.text) ?? [])
    }
}

struct PersonaFilesSearchAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var persona: String
        var query: String
    }
    struct Output: Encodable, Sendable {
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "persona.files.search", summary: "Durchsucht die privaten Dateien einer Persona", kind: .destructive, security: .sensitiveRead,
        input: .object(["persona": .string("Persona (ID oder Name)"), "query": .string("Suchbegriffe")], required: ["persona", "query"]), output: .freeObject(), groups: ["chat.private"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona).name, detail: args.query)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona)
        guard let tools = PersonaFileTools(persona: persona) else { throw RPCError.notFound("\(persona.name) hat keine Dateien.") }
        let (_, output) = await tools.execute(ToolStep(kind: .fileSearch, argument: args.query), limit: 8_000)
        return Output(text: output)
    }
}
