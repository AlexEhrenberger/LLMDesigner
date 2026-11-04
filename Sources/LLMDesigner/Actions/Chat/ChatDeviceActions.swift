import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerChatDeviceActions() {
        register(ChatImageAttachAction.self)
        register(ChatImageRemoveDraftAction.self)
        register(ChatImageGenerateAction.self)
        register(ChatImageCancelAction.self)
        register(ChatScreenGlanceAction.self)
        register(ChatSpeakAction.self)
        register(ChatSpeakStopAction.self)
        register(ChatConversationStartAction.self)
        register(ChatConversationStopAction.self)
        register(ChatDictationStartAction.self)
        register(ChatDictationStopAction.self)
        register(MiniChatOpenAction.self)
        register(MiniChatPinAction.self)
        register(MiniChatToMainWindowAction.self)
        register(ViewSidebarAction.self)
        register(ViewPanelAction.self)
        register(ModelsRefreshAction.self)
        register(ModelsLoadAction.self)
        register(ConnectionGetAction.self)
        register(ConnectionSetAction.self)
        register(LibraryListAction.self)
        register(LibraryOpenAction.self)
        register(LibraryCreateAction.self)
    }
}

private let microphoneConsent = "Das Mikrofon geht an und nimmt auf, was im Raum gesprochen wird."

// MARK: Pictures

struct ChatImageArgs: Decodable, Sendable {
    var chat: String?
    var files: [String]?
    var image: String?
    var prompt: String?
    var generation: String?
    var all: Bool?
}

struct ChatImageAttachAction: LLMDAction {
    typealias Args = ChatImageArgs
    struct Output: Encodable, Sendable {
        var images: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "chat.image.attach", summary: "Legt Bilder aus Dateien ins Eingabefeld eines Chats, höchstens 1600 Pixel", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "files": .array(of: .string(), "Pfade der Bilder")], required: ["chat", "files"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.files?.first)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Bild von dieser Stelle der Festplatte würde dem Modell gezeigt."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat ?? "").id
        var added: [ImageAttachment] = []
        for path in args.files ?? [] {
            let url = ActionExportFolder.expanded(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
            do {
                added.append(try AttachmentStore.importImage(.file(url)))
            } catch {
                throw RPCError.invalidTarget(error.localizedDescription)
            }
        }
        app.setDraftImages(app.draftImages(of: id) + added, of: id)
        return Output(images: added.map(\.id.uuidString))
    }
}

struct ChatImageRemoveDraftAction: LLMDAction {
    typealias Args = ChatImageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.image.removeDraft", summary: "Nimmt ein Bild aus dem Eingabefeld eines Chats", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "image": .string("Bild (ID)")], required: ["chat", "image"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat ?? "").id
        let images = app.draftImages(of: id)
        guard images.contains(where: { $0.id.uuidString == args.image }) else { throw RPCError.notFound("Dieses Bild liegt nicht im Eingabefeld.") }
        app.setDraftImages(images.filter { $0.id.uuidString != args.image }, of: id)
        return OKOutput()
    }
}

/// The pictures made for chats, so cancelling all of them leaves those of documents alone.
@MainActor
enum ChatImageJobs {
    static var running: Set<String> = []
}

struct ChatImageGenerateAction: LLMDAction {
    typealias Args = ChatImageArgs
    struct Output: Encodable, Sendable {
        var image: String
    }
    static let descriptor = ActionDescriptor(
        id: "chat.image.generate", summary: "Lässt Draw Things ein Bild machen und legt es ins Eingabefeld eines Chats; wartet, bis es da ist", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "prompt": .string("Englischer Prompt")], required: ["chat", "prompt"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try app.actionChat(args.chat ?? "").id
        let prompt = (args.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        let center = app.imageGeneration
        var info = center.defaults
        info.prompt = prompt
        info.seed = nil
        let source = WriterImageStore.newGeneratedSource()
        ChatImageJobs.running.insert(source)
        defer { ChatImageJobs.running.remove(source) }
        center.generate(source: source, info: info)
        while let phase = center.phase(for: source) {
            if case .failed(let message) = phase {
                center.cancel(source)
                throw RPCError.unavailable(message)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let url = WriterImageStore.url(for: source) else { throw RPCError.unavailable("Es kam kein Bild; vielleicht wurde es abgebrochen.") }
        let attachment = try AttachmentStore.importImage(.file(url))
        app.setDraftImages(app.draftImages(of: id) + [attachment], of: id)
        return Output(image: attachment.id.uuidString)
    }
}

struct ChatImageCancelAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var cancelled: Int
    }
    static let descriptor = ActionDescriptor(
        id: "chat.image.cancel", summary: "Bricht das Generieren von Bildern für Chats ab", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let running = ChatImageJobs.running
        for source in running { context.app.imageGeneration.cancel(source) }
        return Output(cancelled: running.count)
    }
}

struct ChatScreenGlanceAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.screen.glance", summary: "Legt ein Bildschirmfoto ins Eingabefeld des Mini-Chats; fragt immer nach", kind: .destructive,
        security: ActionSecurity(readsUntrusted: false, sensitive: true, effect: .local), output: .freeObject()
    )
    static func preflight(_ args: NoArgs, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight()
        if context.channel != .ui { check.needsConsent = "Ein Bildschirmfoto kann persönliche Inhalte zeigen." }
        return check
    }
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        guard context.app.miniChat.isOpen else { throw RPCError.invalidTarget("Der Mini-Chat ist nicht offen. minichat.open öffnet ihn.") }
        context.app.glanceAtScreen()
        return OKOutput()
    }
}

// MARK: Speech

struct ChatSpeakAction: LLMDAction {
    typealias Args = ChatMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.speak", summary: "Liest eine Nachricht vor", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference, "message": messageReference], required: ["chat"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { context.app.chatPreflight(try context.app.actionChat(args.chat)) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let chat = try context.app.actionChat(args.chat)
        let message = try context.app.actionMessage(args.message, in: chat)
        guard !SpeakableText.from(markdown: message.content).isEmpty else { throw RPCError.invalidTarget("Hier gibt es nichts vorzulesen.") }
        context.app.toggleSpeaking(message.id)
        return OKOutput(id: message.id.uuidString)
    }
}

struct ChatSpeakStopAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.speak.stop", summary: "Hört auf vorzulesen", kind: .write, security: .localWrite, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.speechReader.stop()
        return OKOutput()
    }
}

struct ChatConversationStartAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.conversation.start", summary: "Startet den Gesprächsmodus in einem Chat; das Mikrofon geht an, darum fragt es immer", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.chat)
        if context.channel != .ui { check.needsConsent = microphoneConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        if let reference = args.chat { app.selectChat(try app.actionChat(reference).id) }
        guard app.canStartConversation else { throw RPCError.unavailable("Der Gesprächsmodus lässt sich gerade nicht starten.") }
        app.startConversation()
        return OKOutput()
    }
}

struct ChatConversationStopAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.conversation.stop", summary: "Beendet den Gesprächsmodus", kind: .write, security: .localWrite, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.endConversation()
        return OKOutput()
    }
}

struct ChatDictationStartAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "chat.dictation.start", summary: "Startet das Diktat ins Eingabefeld eines Chats; fragt immer", kind: .write, security: .localWrite,
        input: .object(["chat": chatReference]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.chat)
        if context.channel != .ui { check.needsConsent = microphoneConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        if let reference = args.chat { app.selectChat(try app.actionChat(reference).id) }
        if !app.isDictating { app.toggleDictation() }
        return OKOutput()
    }
}

struct ChatDictationStopAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "chat.dictation.stop", summary: "Beendet das Diktat", kind: .write, security: .localWrite, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        await context.app.stopDictation()
        return OKOutput()
    }
}

// MARK: Mini chat and view

struct MiniChatOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var chat: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "minichat.open", summary: "Öffnet den Mini-Chat mit einem Chat; ohne chat mit einem neuen", kind: .read, security: .plainRead,
        input: .object(["chat": chatReference]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let id = try args.chat.map { try app.actionChat($0).id }
        app.showInMiniChat(id)
        app.miniChatOpenRequest = UUID()
        return OKOutput(id: id?.uuidString)
    }
}

struct MiniChatPinAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var on: Bool
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "minichat.pin", summary: "Hält den Mini-Chat vor allen Fenstern oder nicht", kind: .read, security: .plainRead,
        input: .object(["on": .boolean("Vor allen Fenstern")], required: ["on"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        context.app.miniChat.floats = args.on
        return OKOutput()
    }
}

struct MiniChatToMainWindowAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "minichat.toMainWindow", summary: "Zeigt den Chat des Mini-Chats im Hauptfenster", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        guard let id = context.app.currentMiniChat?.id else { throw RPCError.invalidTarget("Im Mini-Chat ist noch kein Chat.") }
        context.app.openMiniChatInMainWindow()
        return OKOutput(id: id.uuidString)
    }
}

struct ViewSidebarAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var show: Bool
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "view.sidebar", summary: "Zeigt oder verbirgt die Seitenleiste links", kind: .read, security: .plainRead,
        input: .object(["show": .boolean("Zeigen")], required: ["show"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let shown = app.sidebarCollapsed ? app.sidebarOverlay : app.sidebarVisible
        if shown != args.show { app.toggleSidebar() }
        return OKOutput()
    }
}

struct ViewPanelAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var show: Bool?
        var panel: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "view.panel", summary: "Zeigt oder verbirgt die Seitenleiste rechts und wählt ihren Inhalt", kind: .read, security: .plainRead,
        input: .object(["show": .boolean("Zeigen; Standard: true"), "panel": .choice(["contents", "bookmarks", "sources", "power"], "Inhalt")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        switch args.panel {
        case "power": if !app.power.isOn { app.togglePower() }
        case "contents": app.sidePanelTab = .contents
        case "bookmarks": app.sidePanelTab = .bookmarks
        case "sources": app.sidePanelTab = .sources
        default: break
        }
        let show = args.show ?? true
        if app.isPanelShown != show { app.toggleOutlinePanel() }
        return OKOutput()
    }
}

// MARK: Models, connection, library

struct ModelsRefreshAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var models: Int
        var error: String?
    }
    static let descriptor = ActionDescriptor(id: "models.refresh", summary: "Fragt den Modellserver neu nach seinen Modellen", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        await context.app.refreshModels()
        var failure: String?
        if case .failed(let message) = context.app.connection { failure = message }
        return Output(models: context.app.chatModels.count, error: failure)
    }
}

struct ModelsLoadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var model: String
        var contextLength: Int
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "models.load", summary: "Lädt ein Modell in LM Studio mit einer Kontextlänge", kind: .write, security: .localWrite,
        input: .object(["model": .string("Modell aus models.list"), "contextLength": .integer("Token", minimum: 1024)], required: ["model", "contextLength"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        guard app.provider.loadsModels else { throw RPCError.invalidTarget("\(app.provider.label) lädt keine Modelle auf Anfrage.") }
        guard app.models.contains(where: { $0.id == args.model }) else { throw RPCError.notFound("Das Modell „\(args.model)“ gibt es nicht. models.list zeigt sie.") }
        do {
            try await app.loadModel(args.model, contextLength: args.contextLength)
        } catch {
            throw RPCError.unavailable(error.localizedDescription)
        }
        return OKOutput(id: args.model)
    }
}

struct ConnectionGetAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var provider: String
        var endpoint: String
        var hasKey: Bool
        var connected: Bool
    }
    static let descriptor = ActionDescriptor(id: "connection.get", summary: "Zeigt Anbieter und Adresse des Modellservers; nie den Schlüssel", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        var connected = false
        if case .connected = app.connection { connected = true }
        return Output(provider: app.provider.rawValue, endpoint: app.endpoint, hasKey: !app.apiKey.isEmpty, connected: connected)
    }
}

struct ConnectionSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var provider: String?
        var endpoint: String?
        var apiKey: String?
    }
    typealias Output = ConnectionGetAction.Output
    static let descriptor = ActionDescriptor(
        id: "connection.set", summary: "Stellt den Modellserver um; alles, was die Modelle lesen, geht künftig dorthin, darum fragt es immer", kind: .destructive, security: .outbound,
        input: .object([
            "provider": .choice(LLMProvider.allCases.map(\.rawValue), "Anbieter"), "endpoint": .string("Adresse"),
            "apiKey": .string("Schlüssel; erscheint nirgends in Ergebnissen oder im Protokoll"),
        ]),
        output: .freeObject()
    )
    /// The target is what the dialog shows; the key never is.
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.endpoint ?? args.provider)
        if context.channel != .ui { check.needsConsent = "Der Modellserver bekommt alles, was Chats und Dokumente ihm schicken." }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        if let provider = args.provider.flatMap(LLMProvider.init(rawValue:)) { app.provider = provider }
        if let endpoint = args.endpoint { app.endpoint = endpoint }
        if let key = args.apiKey { app.apiKey = key }
        await app.refreshModels()
        return try await ConnectionGetAction.run(NoArgs(), context: context)
    }
}

struct LibraryListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var name: String
        var path: String
        var available: Bool
    }
    struct Output: Encodable, Sendable {
        var current: String
        var libraries: [Item]
    }
    static let descriptor = ActionDescriptor(id: "library.list", summary: "Listet die zuletzt geöffneten Bibliotheken", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(current: AppLibrary.current.url.path, libraries: LibraryRegistry.entries.map {
            Item(name: AppLibrary.name(of: $0.url), path: $0.url.path, available: $0.isAvailable)
        })
    }
}

/// A switch ends everything running and swaps all content; it's not something a model or client decides.
private let libraryConsent = "Ein Wechsel der Bibliothek beendet alle laufenden Arbeiten und tauscht den ganzen Inhalt aus."

struct LibraryOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var path: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "library.open", summary: "Wechselt zu einer anderen Bibliothek; fragt immer", kind: .destructive, security: .destructive,
        input: .object(["path": .string("Pfad der Bibliothek")], required: ["path"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.path)
        if context.channel != .ui { check.needsConsent = libraryConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let url = ActionExportFolder.expanded(args.path)
        guard AppLibrary.isLibrary(url) else { throw RPCError.notFound("\(url.path) ist keine Bibliothek.") }
        guard let session = LibrarySession.shared else { throw RPCError.unavailable("Die Bibliothek lässt sich hier nicht wechseln.") }
        await session.open(url)
        return OKOutput(id: url.path)
    }
}

struct LibraryCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "library.create", summary: "Legt eine neue Bibliothek an und wechselt zu ihr; fragt immer", kind: .destructive, security: .destructive,
        input: .object(["name": .string("Name")], required: ["name"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.name)
        if context.channel != .ui { check.needsConsent = libraryConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let session = LibrarySession.shared else { throw RPCError.unavailable("Die Bibliothek lässt sich hier nicht wechseln.") }
        try FileManager.default.createDirectory(at: AppLibrary.defaultFolder, withIntermediateDirectories: true)
        let url = AppLibrary.freeURL(named: args.name, in: AppLibrary.defaultFolder)
        _ = try AppLibrary.create(at: url)
        await session.open(url)
        return OKOutput(id: url.path)
    }
}
