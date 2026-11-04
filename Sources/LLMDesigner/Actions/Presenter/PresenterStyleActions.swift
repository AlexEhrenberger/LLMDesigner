import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterStyleActions() {
        register(PresenterBackgroundSetAction.self)
        register(PresenterBackgroundClearAction.self)
        register(PresenterBackgroundImageAction.self)
        register(PresenterBackgroundGenerateAction.self)
        register(PresenterDesignRevealFolderAction.self)
        register(PresenterDesignCreateAction.self)
        register(PresenterNotesGenerateAction.self)
        register(PresenterNotesCancelAction.self)
        register(PresenterAIUndoGenerationAction.self)
        register(PresenterAIIntentAction.self)
        register(PresenterFromDocumentPlanAction.self)
        register(PresenterToHandoutAction.self)
        register(PresenterToHandoutCancelAction.self)
    }
}

struct PresenterBackgroundArgs: Decodable, Sendable {
    var deck: String
    var slide: String?
    var slideIndex: Int?
    var role: String?
    var kind: String?
    var design: String?
    var colors: [String]?
    var angle: Double?
    var radial: Bool?
    var file: String?
    var dim: Double?
    var description: String?
    var style: String?
    var tone: String?
    var roles: [String]?
    var resolution: String?

    static let target: [String: JSONSchema] = presenterSlideProperties.merging([
        "role": .choice(SlideRole.allCases.map(\.rawValue), "Alle Folien dieser Art; ohne role und slide die ganze Präsentation"),
    ]) { _, new in new }

    /// Sets the background where this call says: on a slide, a kind of slides, or all.
    @MainActor
    func apply(_ background: SlideBackground, context: ActionContext) throws {
        let app = context.app
        let document = try app.actionDocument(deck, presentation: true)
        guard let presentation = document.deck else { throw RPCError.invalidTarget("„\(document.displayTitle)“ hat keine Folien.") }
        if slide != nil || slideIndex != nil {
            app.setSlideBackground(document.id, try presentation.actionSlide(id: slide, index: slideIndex).id, background)
        } else if let role = role.flatMap(SlideRole.init(rawValue:)) {
            app.setRoleBackground(document.id, role, background)
        } else {
            app.setPresentationBackground(document.id, background)
        }
        context.noteChange(of: document.id, before: document)
    }
}

struct PresenterBackgroundSetAction: LLMDAction {
    typealias Args = PresenterBackgroundArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.background.set", summary: "Setzt einen Hintergrund: Design, Farbe oder Verlauf", kind: .write, security: .localWrite,
        input: .object(Args.target.merging([
            "kind": .choice(["design", "color", "gradient"], "Art"),
            "design": .string("Design aus presenter.designs.list"),
            "colors": .array(of: .string(), "Eine Farbe, beim Verlauf mehrere"),
            "angle": .number("Winkel des Verlaufs"), "radial": .boolean("Runder Verlauf"),
        ]) { _, new in new }, required: ["deck", "kind"]),
        output: .freeObject(), example: "llmd presenter background set Vortrag --kind color --colors 1F5FBF"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let background: SlideBackground
        switch args.kind {
        case "design":
            guard let id = args.design, SlideDesignLibrary.shared.design(id) != nil else { throw RPCError.notFound("Das Design „\(args.design ?? "")“ gibt es nicht. presenter.designs.list zeigt sie.") }
            background = .design(id)
        case "color":
            guard let color = args.colors?.first else { throw RPCError.invalidParams("Bitte colors angeben.") }
            background = .color(try actionColor(color))
        default:
            let colors = try (args.colors ?? []).map(actionColor)
            guard colors.count >= 2 else { throw RPCError.invalidParams("Ein Verlauf braucht mindestens zwei Farben.") }
            background = .gradient(colors, angle: args.angle ?? 135, radial: args.radial ?? false)
        }
        try args.apply(background, context: context)
        return OKOutput()
    }
}

struct PresenterBackgroundClearAction: LLMDAction {
    typealias Args = PresenterSlideArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.background.clear", summary: "Eine Folie nimmt wieder den Hintergrund ihrer Art", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties, required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        guard let slide = try document.deck?.actionSlide(id: args.slide, index: args.slideIndex) else { throw RPCError.invalidTarget("Diese Präsentation hat keine Folien.") }
        context.app.setSlideBackground(document.id, slide.id, nil)
        context.noteChange(of: document.id, before: document)
        return OKOutput()
    }
}

struct PresenterBackgroundImageAction: LLMDAction {
    typealias Args = PresenterBackgroundArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.background.image", summary: "Nimmt ein Bild aus einer Datei als Hintergrund", kind: .write, security: .localWrite,
        input: .object(Args.target.merging(["file": .string("Pfad der Bilddatei"), "dim": .number("Abdunkeln 0–1; Standard 0,25", minimum: 0, maximum: 1)]) { _, new in new }, required: ["deck", "file"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.file)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Bild von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer sichtbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        let source = try WriterImageStore.importImage(.file(url))
        var background = SlideBackground.image(source, dim: args.dim ?? 0.25)
        background.tone = SlideImageTone.tone(of: source)
        try args.apply(background, context: context)
        return OKOutput(id: source)
    }
}

struct PresenterBackgroundGenerateAction: LLMDAction {
    typealias Args = PresenterBackgroundArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.background.generate", summary: "Lässt das Modell Prompts schreiben und Draw Things textfreie Hintergründe machen", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties.merging([
            "description": .string("Was zu sehen sein soll"),
            "style": .choice(ImageStyle.allCases.map(\.rawValue), "Stil"),
            "tone": .choice(["light", "dark"], "Farbe des Texts darauf"),
            "roles": .array(of: .choice(SlideRole.allCases.map(\.rawValue)), "Arten von Folien; ohne Angabe alle"),
            "resolution": .choice(ImageResolution.allCases.map(\.rawValue), "Auflösung"),
        ]) { _, new in new }, required: ["deck", "description"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        let slide = args.slide != nil || args.slideIndex != nil ? try document.deck?.actionSlide(id: args.slide, index: args.slideIndex).id : nil
        let defaults = app.imageGeneration.defaults
        let request = SlideBackgroundRequest(
            description: args.description ?? "", style: args.style.flatMap(ImageStyle.init(rawValue:)) ?? defaults.style,
            tone: args.tone.flatMap(SlideTone.init(rawValue:)) ?? .dark,
            roles: args.roles?.compactMap(SlideRole.init(rawValue:)) ?? SlideRole.allCases, slideID: slide,
            resolution: args.resolution.flatMap(ImageResolution.init(rawValue:)) ?? defaults.resolution
        )
        do {
            try await app.generateSlideBackgrounds(document.id, request) { _ in }
        } catch {
            throw RPCError.unavailable(error.localizedDescription)
        }
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: document.id.uuidString, message: "Die Bilder sind in der Warteschlange von Draw Things.")
    }
}

struct PresenterDesignRevealFolderAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var show: Bool?
    }
    struct Output: Encodable, Sendable {
        var path: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.design.revealFolder", summary: "Sagt, wo eigene CSS-Designs liegen, und zeigt den Ordner im Finder", kind: .read, security: .plainRead,
        input: .object(["show": .boolean("Im Finder zeigen; Standard: true")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        if args.show != false { SlideDesignLibrary.shared.revealUserFolder() }
        return Output(path: SlideDesignLibrary.userFolder.path)
    }
}

struct PresenterDesignCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var css: String
    }
    struct Output: Encodable, Sendable {
        var id: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.design.create", summary: "Legt ein eigenes CSS-Design an; Adressen aus dem Netz werden nicht geladen", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "css": .string("Das CSS")], required: ["name", "css"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let id = args.name.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !id.isEmpty else { throw RPCError.invalidParams("Dieser Name geht nicht als Dateiname.") }
        let folder = SlideDesignLibrary.userFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(id + ".css")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RPCError.invalidTarget("Ein Design „\(id)“ gibt es schon.") }
        let hasHeader = args.css.contains("@name")
        let text = (hasHeader ? "" : "/*\n * @name \(args.name.replacingOccurrences(of: "*/", with: ""))\n */\n") + args.css
        try text.write(to: url, atomically: true, encoding: .utf8)
        SlideDesignLibrary.shared.reloadIfNeeded()
        context.undoGroup.add(UndoStep(label: "Design anlegen", undo: { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }, redo: { try? text.write(to: url, atomically: true, encoding: .utf8) }))
        return Output(id: id)
    }
}

// MARK: Speaker notes and the model's work

struct PresenterNotesGenerateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slides: [String]?
        var all: Bool?
        var anew: Bool?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.notes.generate", summary: "Das Modell schreibt Moderatorenkarten im Hintergrund: für bestimmte Folien, sonst die fehlenden", kind: .write, security: .localWrite,
        input: .object([
            "deck": presenterDeckProperty, "slides": .array(of: .string(), "Folien (IDs)"),
            "all": .boolean("Alle Folien"), "anew": .boolean("Vorhandene neu schreiben"),
        ], required: ["deck"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard app.client != nil, app.currentModelId != nil else { throw RPCError.unavailable("Kein Sprachmodell gewählt.") }
        if let slides = args.slides {
            let ids = try slides.compactMap { try document.deck?.actionSlide(id: $0, index: nil).id }
            app.writeSpeakerNotes(document.id, slides: ids)
        } else {
            app.writeAllSpeakerNotes(document.id, anew: args.anew == true || args.all == true && args.anew != false)
        }
        return OKOutput(id: document.id.uuidString, message: "Läuft. Stand: presenter.state.get, Text: presenter.notes.get")
    }
}

struct PresenterNotesCancelAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.notes.cancel", summary: "Bricht das Schreiben der Moderatorenkarten ab", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.cancelSpeakerNotes()
        return OKOutput()
    }
}

struct PresenterAIUndoGenerationAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.ai.undoGeneration", summary: "Bringt die Folien von vor der Folienerzeugung zurück", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        guard let generation = app.deckGeneration else { throw RPCError.notFound("Es gibt keine Folienerzeugung zum Zurücknehmen.") }
        guard !generation.isRunning else { throw RPCError.invalidTarget("Die Folienerzeugung läuft noch. presenter.ai.cancel bricht sie ab.") }
        let before = app.document(generation.documentID)
        app.undoDeckGeneration()
        context.noteChange(of: generation.documentID, before: before)
        return OKOutput(id: generation.documentID.uuidString)
    }
}

struct PresenterAIIntentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var text: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.ai.intent", summary: "Versteht eine Anweisung wie im Eingabefeld: Folien erstellen, Karten schreiben oder vortragen", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "text": .string("Die Anweisung")], required: ["deck", "text"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        var check = ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
        // Presenting takes the whole screen and speaks aloud.
        if context.channel != .ui, PresenterIntent.detect(args.text)?.presents == true || PresenterIntent.detect(args.text)?.kind == .present {
            check.needsConsent = "Ein Vortrag nimmt den ganzen Bildschirm ein und spricht laut."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let intent = PresenterIntent.detect(args.text) else {
            throw RPCError.invalidParams("Aus dieser Anweisung wird nicht klar, was geschehen soll. presenter.ai.createDeck, presenter.notes.generate und presenter.play.withAI sagen es genau.")
        }
        guard app.client != nil, app.currentModelId != nil else { throw RPCError.unavailable("Kein Sprachmodell gewählt.") }
        guard app.deckGeneration?.isRunning != true else { throw RPCError.unavailable("Es läuft schon eine Folienerzeugung.") }
        app.runPresenterIntent(intent, instruction: args.text, in: document.id)
        return OKOutput(id: document.id.uuidString, message: "Läuft: \(intent.kind)")
    }
}

struct PresenterFromDocumentPlanAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    struct Slide: Encodable, Sendable {
        var title: String
    }
    struct Chapter: Encodable, Sendable {
        var title: String?
        var slides: [Slide]
    }
    struct Output: Encodable, Sendable {
        var title: String?
        var chapters: [Chapter]
        /// The headings say too little: the model would divide the text when the presentation is made.
        var needsModel: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.fromDocument.plan", summary: "Zeigt die Gliederung, die ein Dokument als Präsentation ergäbe, ohne etwas anzulegen", kind: .read, security: .plainRead,
        input: .object(["doc": .string("Dokument (ID oder Titel)")], required: ["doc"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.doc)
        guard let plan = DocumentDeckPlanner.plan(for: context.app.deckMaterial(from: document)) else {
            return Output(title: document.displayTitle, chapters: [], needsModel: true)
        }
        return Output(title: plan.title, chapters: plan.chapters.map { chapter in
            Chapter(title: chapter.title, slides: chapter.slides.map { Slide(title: $0.title) })
        }, needsModel: false)
    }
}

struct PresenterToHandoutAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var tableOfContents: Bool?
        var speakerNotes: Bool?
        var slidePictures: Bool?
        var expand: Bool?
        var length: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.toHandout", summary: "Macht aus den Folien ein Handout als neues Dokument und öffnet es", kind: .write, security: .localWrite,
        input: .object([
            "deck": presenterDeckProperty, "tableOfContents": .boolean("Mit Inhaltsverzeichnis"), "speakerNotes": .boolean("Mit Moderatorenkarten"),
            "slidePictures": .boolean("Mit Bildern der Folien"), "expand": .boolean("Das Modell schreibt die Stichpunkte als Text aus"),
            "length": .choice(HandoutLength.allCases.map(\.rawValue), "Länge beim Ausschreiben"),
        ], required: ["deck"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        var options = HandoutOptions()
        if let value = args.tableOfContents { options.tableOfContents = value }
        if let value = args.speakerNotes { options.speakerNotes = value }
        if let value = args.slidePictures { options.slidePictures = value }
        if let value = args.expand { options.expand = value }
        if let value = args.length.flatMap(HandoutLength.init(rawValue:)) { options.length = value }
        if options.expand, app.client == nil || app.currentModelId == nil { throw RPCError.unavailable("Kein Sprachmodell gewählt.") }
        await app.createHandout(from: document.id, options: options)
        guard let id = app.selectedDocumentID, id != document.id else { throw RPCError.internal("Das Handout wurde nicht angelegt.") }
        if let made = app.document(id), let origin = context.mergedProvenance(document.provenance) {
            var marked = made
            marked.provenance = origin
            app.restoreDocument(marked)
        }
        return OKOutput(id: id.uuidString, message: options.expand ? "Das Modell schreibt im Hintergrund weiter." : nil)
    }
}

struct PresenterToHandoutCancelAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.toHandout.cancel", summary: "Bricht das Ausschreiben des Handouts ab", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.stopHandoutGeneration()
        return OKOutput()
    }
}
