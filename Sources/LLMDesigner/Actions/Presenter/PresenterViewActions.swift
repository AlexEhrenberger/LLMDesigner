import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterViewActions() {
        register(PresenterExportSlideImageAction.self)
        register(PresenterPrintAction.self)
        register(PresenterViewPanelAction.self)
        register(PresenterViewBackgroundPickerAction.self)
    }
}

struct PresenterExportSlideImageAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var path: String?
        var overwrite: Bool?
        var scale: Double?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.export.slideImage", summary: "Speichert eine Folie als PNG-Datei", kind: .destructive, security: .outbound,
        input: .object([
            "deck": .string("Präsentation (ID oder Titel)"),
            "slide": .string("Folie (ID)"),
            "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1),
            "path": .string("Zieldatei; ohne Angabe im Exportordner"),
            "overwrite": .boolean("Eine vorhandene Datei ersetzen"),
            "scale": .number("Vielfaches der Leinwand von 720 × 405; Standard 2", minimum: 0.25, maximum: 4),
        ], required: ["deck"]),
        output: .freeObject(), example: "llmd presenter export slide-image Vortrag --slide-index 2"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let inFolder = args.path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        return ActionPreflight(readsUntrusted: document.isForeign, isInSafePlace: inFolder, target: args.path ?? folder.path, detail: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> WriterExportAction.Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let deck = document.deck else { throw RPCError.invalidTarget("„\(document.displayTitle)“ hat keine Folien.") }
        let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
        let folder = ActionExportFolder.url(settings: app.settings)
        let number = (deck.index(of: slide.id) ?? 0) + 1
        let url = args.path.map(ActionExportFolder.expanded) ?? ActionExportFolder.freeFile(named: "\(document.displayTitle) Folie \(number)", extension: "png", in: folder)
        guard args.path == nil || args.overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.invalidTarget("Die Datei gibt es schon: \(url.path)")
        }
        app.citations.loadIfNeeded()
        guard let data = await SlidePrinter.png(slide: slide, in: deck, family: document.font, citations: app.citations, scale: args.scale ?? 2) else {
            throw RPCError.internal("Die Folie ließ sich nicht zeichnen.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return WriterExportAction.Output(path: url.path, bytes: data.count)
    }
}

struct PresenterPrintAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.print", summary: "Öffnet den Druckdialog für die Folien; drucken muss die Person selbst", kind: .destructive, security: .outbound,
        input: .object(["deck": .string("Präsentation (ID oder Titel)")], required: ["deck"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.printPresentation(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

struct PresenterViewPanelAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var panel: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.view.panel", summary: "Zeigt eine Seitenleiste der offenen Präsentation", kind: .read, security: .plainRead,
        input: .object(["panel": .choice(["outline", "bookmarks", "sources", "analysis", "power"], "Die Seitenleiste; outline ist die Folienliste")], required: ["panel"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard context.app.selectedDocument?.isPresentation == true else { throw RPCError.invalidTarget("Es ist keine Präsentation offen.") }
        try context.app.showDocumentPanel(args.panel)
        return OKOutput()
    }
}

struct PresenterViewBackgroundPickerAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var open: Bool?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.view.backgroundPicker", summary: "Öffnet oder schließt die Auswahl der Hintergründe", kind: .read, security: .plainRead,
        input: .object(["open": .boolean("Standard: true")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard context.app.selectedDocument?.isPresentation == true else { throw RPCError.invalidTarget("Es ist keine Präsentation offen.") }
        context.app.presenterBackgroundPickerOpen = args.open ?? true
        return OKOutput()
    }
}
