import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterPlayActions() {
        register(PresenterPlayStartAction.self)
        register(PresenterPlayWithAIAction.self)
        register(PresenterPlayNextAction.self)
        register(PresenterPlayPreviousAction.self)
        register(PresenterPlayGoToAction.self)
        register(PresenterPlayPauseAction.self)
        register(PresenterPlayResumeAction.self)
        register(PresenterPlayStopAction.self)
        register(PresenterPlayReadNotesAction.self)
        register(PresenterPlayInterruptAction.self)
        register(PresenterPlayLoopAction.self)
        register(PresenterPlayStatusAction.self)
    }
}

/// The player the running presentation has; these actions go nowhere without one.
@MainActor
private func preparedPlayer(_ app: AppModel) throws -> PresentationPlayer {
    guard app.presentationPlayer.documentID != nil, app.presentationPlayer.deck != nil else {
        throw RPCError.invalidTarget("Es läuft kein Vortrag. presenter.play.start beginnt einen.")
    }
    return app.presentationPlayer
}

private let fullScreenConsent = "Ein Vortrag im Vollbild nimmt den ganzen Bildschirm ein."
let speakingConsent = "Der Vortrag nimmt den ganzen Bildschirm ein und spricht laut."

struct PresenterPlayStartAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var from: Int?
        var fullScreen: Bool?
    }
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.start", summary: "Zeigt eine Präsentation im Reiter Vortrag; Vollbild fragt nach", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "from": .integer("Ab welcher Folie, ab 1", minimum: 1), "fullScreen": .boolean("Im Vollbild")], required: ["deck"]),
        output: .freeObject(), example: "llmd presenter play start Vortrag --from 2"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: try context.app.actionDocument(args.deck, presentation: true).displayTitle)
        if args.fullScreen == true, context.channel != .ui { check.needsConsent = fullScreenConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let deck = document.deck, !deck.slides.isEmpty else { throw RPCError.invalidTarget("Diese Präsentation hat keine Folien.") }
        if app.selectedDocumentID != document.id { app.selectDocument(document.id) }
        app.showWriterTab(.play)
        let player = app.presentationPlayer
        player.app = app
        let start = try args.from.map { try deck.actionSlide(id: nil, index: $0).id }
        player.prepare(document.id, at: start)
        if let start, let index = deck.index(of: start) { player.go(to: index) }
        if args.fullScreen == true { player.enterFullScreen() }
        return PresenterPlayStatusAction.status(app)
    }
}

struct PresenterPlayWithAIAction: LLMDAction {
    typealias Args = PresenterDeckArgs
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.withAI", summary: "Das Modell trägt von der ersten Folie an im Vollbild vor; fragt nach", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty], required: ["deck"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        var check = ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
        if context.channel != .ui { check.needsConsent = speakingConsent }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        context.app.presentWithAI(try context.app.actionDocument(args.deck, presentation: true).id)
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayNextAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.next", summary: "Blättert im Vortrag eine Folie weiter", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        try preparedPlayer(context.app).next()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayPreviousAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.previous", summary: "Blättert im Vortrag eine Folie zurück", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        try preparedPlayer(context.app).previous()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayGoToAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var slide: String?
        var slideIndex: Int?
    }
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.goTo", summary: "Springt im Vortrag zu einer Folie", kind: .write, security: .localWrite,
        input: .object(["slide": .string("Folie (ID)"), "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1)]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let player = try preparedPlayer(context.app)
        guard let deck = player.deck else { throw RPCError.invalidTarget("Es läuft kein Vortrag.") }
        let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
        if let index = deck.index(of: slide.id) { player.go(to: index) }
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayPauseAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.pause", summary: "Hält den Vortrag des Modells an", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        try preparedPlayer(context.app).pause()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayResumeAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.resume", summary: "Das Modell trägt von der aktuellen Folie an weiter vor; fragt nach", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func preflight(_ args: NoArgs, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight()
        if context.channel != .ui { check.needsConsent = "Der Vortrag spricht laut." }
        return check
    }
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        try preparedPlayer(context.app).present()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayStopAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.stop", summary: "Beendet den Vortrag und das Vollbild", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let player = context.app.presentationPlayer
        player.stop()
        player.exitFullScreen()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayReadNotesAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.readNotes", summary: "Liest die Moderatorenkarte der aktuellen Folie einmal vor", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let player = try preparedPlayer(context.app)
        guard player.currentSlide?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw RPCError.invalidTarget("Diese Folie hat noch keine Moderatorenkarte.")
        }
        player.readCurrentNotes()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayInterruptAction: LLMDAction {
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.interrupt", summary: "Unterbricht das Vorlesen; die Folie bleibt", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        try preparedPlayer(context.app).pause()
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayLoopAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var on: Bool
    }
    typealias Output = PresenterPlayStatusAction.Output
    static let descriptor = ActionDescriptor(
        id: "presenter.play.loop", summary: "Der Vortrag des Modells beginnt am Ende wieder von vorn", kind: .write, security: .localWrite,
        input: .object(["on": .boolean("An oder aus")], required: ["on"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        context.app.presentationPlayer.repeats = args.on
        return PresenterPlayStatusAction.status(context.app)
    }
}

struct PresenterPlayStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var deck: String?
        var phase: String
        var slide: String?
        var slideIndex: Int?
        var presenting: Bool
        var fullScreen: Bool
        var repeats: Bool
        var error: String?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.play.status", summary: "Zeigt den Stand des Vortrags: Phase, Folie, Vollbild", kind: .read, security: .plainRead, output: .freeObject()
    )
    @MainActor
    static func status(_ app: AppModel) -> Output {
        let player = app.presentationPlayer
        let phase: String
        switch player.phase {
        case .idle: phase = "bereit"
        case .writing: phase = "schreibt"
        case .speaking: phase = "spricht"
        case .turning: phase = "blättert"
        case .finished: phase = "fertig"
        }
        return Output(deck: player.documentID?.uuidString, phase: phase, slide: player.currentSlide?.id.uuidString,
                      slideIndex: player.currentSlide == nil ? nil : player.index + 1, presenting: player.isPresenting,
                      fullScreen: player.isFullScreen, repeats: player.repeats, error: player.error)
    }
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output { status(context.app) }
}
