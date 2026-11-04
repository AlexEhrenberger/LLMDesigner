import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterActions() {
        register(PresenterDeckListAction.self)
        register(PresenterDeckCreateAction.self)
        register(PresenterDeckReadAction.self)
        register(PresenterDeckDeleteAction.self)
        register(PresenterSlidesListAction.self)
        register(PresenterSlideReadAction.self)
        register(PresenterSlideAddAction.self)
        register(PresenterSlideSetTextAction.self)
        register(PresenterSlideSetRoleAction.self)
        register(PresenterSlideMoveAction.self)
        register(PresenterSlideDuplicateAction.self)
        register(PresenterSlideDeleteAction.self)
        register(PresenterSlideRenderAction.self)
        register(PresenterNotesGetAction.self)
        register(PresenterNotesSetAction.self)
        register(PresenterDesignsListAction.self)
        register(PresenterDesignApplyAction.self)
        register(PresenterFieldAddTextAction.self)
        register(PresenterFieldAddImageAction.self)
        register(PresenterFieldMoveAction.self)
        register(PresenterFieldDeleteAction.self)
        register(PresenterExportPDFAction.self)
        register(PresenterAICreateDeckAction.self)
        register(PresenterAIStatusAction.self)
        register(PresenterAICancelAction.self)
        register(PresenterFromDocumentAction.self)
    }
}

private let deckProperty: JSONSchema = .string("Präsentation (ID oder Titel)")
private let slideProperties: [String: JSONSchema] = [
    "deck": deckProperty, "slide": .string("Folie (ID)"), "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1),
]

struct PresenterDeckArgs: Decodable, Sendable {
    var deck: String
}

struct PresenterSlideArgs: Decodable, Sendable {
    var deck: String
    var slide: String?
    var slideIndex: Int?
}

@MainActor
private func deck(_ reference: String, _ app: AppModel) throws -> (WriterDocument, PresentationDeck) {
    let document = try app.actionDocument(reference, presentation: true)
    return (document, document.deck ?? .new())
}

/// A slide as an agent reads it: what is on it, with positions as fractions of the slide.
struct SlideInfo: Encodable, Sendable {
    struct Field: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var source: String?
        var caption: String?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var placement: String
    }
    var id: String
    var index: Int
    var role: String
    var title: String
    var markdown: String?
    var notes: String?
    var fields: [Field]?

    init(_ slide: PresentationSlide, index: Int, full: Bool, withNotes: Bool) {
        id = slide.id.uuidString
        self.index = index + 1
        role = slide.role.rawValue
        title = slide.title
        if full {
            markdown = slide.markdown
            fields = slide.images.map { image in
                Field(id: image.id.uuidString, type: image.isText ? (image.box == nil ? "text" : "box") : "image", text: image.text,
                      source: image.isText ? nil : image.source, caption: image.caption.isEmpty ? nil : image.caption,
                      x: image.x, y: image.y, width: image.width, height: image.height, placement: image.placement.rawValue)
            }
        }
        if withNotes { notes = slide.notes }
    }
}

struct PresenterDeckListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var slides: Int
        var updated: Date
    }
    struct Output: Encodable, Sendable {
        var decks: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.list", summary: "Listet die Präsentationen", kind: .read, security: .plainRead,
        input: .object(["query": .string("Suchtext")]), output: .freeObject(), groups: ["presenter.core"]
    )
    private static func listed(_ args: Args, _ app: AppModel) -> [WriterDocument] {
        app.documents.filter { $0.isPresentation && (args.query.map($0.matches) ?? true) }
    }
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: listed(args, context.app).contains(where: \.isForeign))
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        Output(decks: listed(args, context.app).map {
            Item(id: $0.id.uuidString, title: $0.displayTitle, slides: $0.deck?.slides.count ?? 0, updated: $0.updatedAt)
        })
    }
}

struct PresenterDeckCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var firstSlide: String?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.create", summary: "Legt eine Präsentation mit Titelfolie an", kind: .write, security: .localWrite,
        input: .object(["title": .string("Titel")]), output: .freeObject(), example: "llmd presenter deck create --title Vortrag --json",
        groups: ["core", "presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var document = WriterDocument.newPresentation()
        if let title = args.title, !title.isEmpty {
            document.title = title
            document.hasCustomTitle = true
        }
        document.provenance = context.mergedProvenance(nil)
        app.reinsertDocumentForActionRedo(document)
        let made = document
        context.undoGroup.documents.insert(made.id)
        context.undoGroup.add(UndoStep(label: "Präsentation anlegen", undo: { app.removeDocumentForActionUndo(made.id) }, redo: { app.reinsertDocumentForActionRedo(made) }))
        return Output(id: made.id.uuidString, title: made.displayTitle, firstSlide: made.deck?.slides.first?.id.uuidString)
    }
}

struct PresenterDeckReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var withNotes: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var version: String
        var slides: [SlideInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.read", summary: "Liest alle Folien einer Präsentation", kind: .read, security: .plainRead,
        input: .object(["deck": deckProperty, "withNotes": .boolean("Mit Moderatorenkarten")], required: ["deck"]),
        output: .freeObject(), example: "llmd presenter deck read Vortrag --with-notes --json", groups: ["core", "presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (document, deck) = try deck(args.deck, context.app)
        return Output(id: document.id.uuidString, title: document.displayTitle, version: ActionVersion.of(deck.serialized),
                      slides: deck.slides.enumerated().map { SlideInfo($1, index: $0, full: true, withNotes: args.withNotes == true) })
    }
}

struct PresenterDeckDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.delete", summary: "Löscht eine Präsentation endgültig", kind: .destructive, security: .destructive,
        input: .object(["deck": deckProperty], required: ["deck"]), output: .freeObject()
    )
    static func preflight(_ args: PresenterDeckArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionDocument(args.deck, presentation: true).displayTitle)
    }
    static func run(_ args: PresenterDeckArgs, context: ActionContext) async throws -> OKOutput {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.deleteDocument(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

struct PresenterSlidesListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var slides: [SlideInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slides.list", summary: "Listet die Folien kurz: ID, Position, Rolle, Titel", kind: .read, security: .plainRead,
        input: .object(["deck": deckProperty], required: ["deck"]), output: .freeObject(), groups: ["presenter.core"]
    )
    static func preflight(_ args: PresenterDeckArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: PresenterDeckArgs, context: ActionContext) async throws -> Output {
        let (_, deck) = try deck(args.deck, context.app)
        return Output(slides: deck.slides.enumerated().map { SlideInfo($1, index: $0, full: false, withNotes: false) })
    }
}

struct PresenterSlideReadAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.read", summary: "Liest eine Folie mit Karte und Elementen", kind: .read, security: .plainRead,
        input: .object(slideProperties, required: ["deck"]), output: .freeObject(), groups: ["presenter.core"]
    )
    static func preflight(_ args: PresenterSlideArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: PresenterSlideArgs, context: ActionContext) async throws -> SlideInfo {
        let (_, deck) = try deck(args.deck, context.app)
        let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
        return SlideInfo(slide, index: deck.index(of: slide.id) ?? 0, full: true, withNotes: true)
    }
}

/// A change to a deck with undo, origin and event.
@MainActor
private func changeDeck(_ reference: String, context: ActionContext, _ change: (inout PresentationDeck) throws -> Void) throws -> WriterDocument {
    let document = try context.app.actionDocument(reference, presentation: true)
    var failure: Error?
    context.app.modifyDeck(document.id) { deck in
        do {
            try change(&deck)
            return true
        } catch {
            failure = error
            return false
        }
    }
    if let failure { throw failure }
    context.noteChange(of: document.id, before: document)
    return document
}

struct PresenterSlideAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var after: String?
        var role: String?
        var markdown: String?
        var notes: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var index: Int
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.add", summary: "Fügt eine Folie hinzu, mit Text in einem Aufruf", kind: .write, security: .localWrite,
        input: .object([
            "deck": deckProperty, "after": .string("Hinter dieser Folie (ID); sonst am Ende"),
            "role": .choice(SlideRole.allCases.map(\.rawValue), "Standard: folie"), "markdown": .string("Text der Folie"), "notes": .string("Moderatorenkarte"),
        ], required: ["deck"]),
        output: .freeObject(), example: "llmd presenter slide add Vortrag --markdown '# Titel\n- Punkt'", groups: ["core", "presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var slide = PresentationSlide(role: args.role.flatMap(SlideRole.init(rawValue:)) ?? .content, markdown: args.markdown ?? "")
        slide.notes = args.notes ?? ""
        let made = slide
        var position = 0
        _ = try changeDeck(args.deck, context: context) { deck in
            if let after = args.after {
                guard let found = deck.slides.firstIndex(where: { $0.id.uuidString == after }) else { throw RPCError.notFound("Folie \(after) gibt es nicht.") }
                position = found + 1
            } else {
                position = deck.slides.count
            }
            deck.slides.insert(made, at: position)
        }
        return Output(id: made.id.uuidString, index: position + 1)
    }
}

struct PresenterSlideSetTextAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var markdown: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.setText", summary: "Setzt den ganzen Text einer Folie", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(["markdown": .string("Text der Folie")]) { _, new in new }, required: ["deck", "markdown"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            deck.slides[deck.index(of: slide.id)!].markdown = args.markdown
        }
        return OKOutput()
    }
}

struct PresenterSlideSetRoleAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var role: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.setRole", summary: "Setzt die Rolle einer Folie", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(["role": .choice(SlideRole.allCases.map(\.rawValue), "Rolle")]) { _, new in new }, required: ["deck", "role"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            deck.slides[deck.index(of: slide.id)!].role = SlideRole(rawValue: args.role) ?? .content
        }
        return OKOutput()
    }
}

struct PresenterSlideMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var to: Int
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.move", summary: "Verschiebt eine Folie an eine Position", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(["to": .integer("Neue Position, ab 1", minimum: 1)]) { _, new in new }, required: ["deck", "to"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            guard args.to <= deck.slides.count else { throw RPCError.invalidParams("Position \(args.to) gibt es nicht (\(deck.slides.count) Folien).") }
            let moving = deck.slides.remove(at: deck.index(of: slide.id)!)
            deck.slides.insert(moving, at: args.to - 1)
        }
        return OKOutput()
    }
}

struct PresenterSlideDuplicateAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.duplicate", summary: "Kopiert eine Folie", kind: .write, security: .localWrite,
        input: .object(slideProperties, required: ["deck"]), output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: PresenterSlideArgs, context: ActionContext) async throws -> OKOutput {
        var made: UUID?
        _ = try changeDeck(args.deck, context: context) { deck in
            var copy = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            let index = deck.index(of: copy.id)!
            copy.id = UUID()
            made = copy.id
            deck.slides.insert(copy, at: index + 1)
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterSlideDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.delete", summary: "Entfernt eine Folie; rückgängig machbar", kind: .write, security: .localWrite,
        input: .object(slideProperties, required: ["deck"]), output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: PresenterSlideArgs, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            guard deck.slides.count > 1 else { throw RPCError.invalidTarget("Die letzte Folie bleibt.") }
            deck.slides.remove(at: deck.index(of: slide.id)!)
        }
        return OKOutput()
    }
}

struct PresenterSlideRenderAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var scale: Double?
    }
    struct Output: Encodable, Sendable {
        var mimeType = "image/png"
        var width: Int
        var height: Int
        var imageBase64: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.render", summary: "Zeichnet eine Folie als PNG, damit eine KI ihr Layout prüfen kann", kind: .read, security: .plainRead,
        input: .object(slideProperties.merging(["scale": .number("Vielfaches der Leinwand von 720 × 405; Standard 1", minimum: 0.25, maximum: 4)]) { _, new in new }, required: ["deck"]),
        output: .freeObject(), example: "llmd presenter slide render Vortrag --slide-index 2 --json", groups: ["core", "presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (document, deck) = try deck(args.deck, context.app)
        let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
        let scale = args.scale ?? 1
        context.app.citations.loadIfNeeded()
        guard let data = await SlidePrinter.png(slide: slide, in: deck, family: document.font, citations: context.app.citations, scale: scale) else {
            throw RPCError.internal("Die Folie ließ sich nicht zeichnen.")
        }
        return Output(width: Int(SlidePrinter.canvas.width * scale), height: Int(SlidePrinter.canvas.height * scale), imageBase64: data.base64EncodedString())
    }
}

struct PresenterNotesGetAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.notes.get", summary: "Liest die Moderatorenkarte", kind: .read, security: .plainRead,
        input: .object(slideProperties, required: ["deck"]), output: .freeObject(), groups: ["presenter.core"]
    )
    static func preflight(_ args: PresenterSlideArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: PresenterSlideArgs, context: ActionContext) async throws -> Output {
        let (_, deck) = try deck(args.deck, context.app)
        return Output(text: try deck.actionSlide(id: args.slide, index: args.slideIndex).notes)
    }
}

struct PresenterNotesSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.notes.set", summary: "Setzt die Moderatorenkarte", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(["text": .string("Text der Karte")]) { _, new in new }, required: ["deck", "text"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            deck.slides[deck.index(of: slide.id)!].notes = args.text
        }
        return OKOutput()
    }
}

struct PresenterDesignsListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var name: String
        var summary: String
        var builtIn: Bool
    }
    struct Output: Encodable, Sendable {
        var designs: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.designs.list", summary: "Listet die Folien-Designs", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(designs: SlideDesignLibrary.shared.all.map { Item(id: $0.id, name: $0.name, summary: $0.summary, builtIn: $0.isBuiltIn) })
    }
}

struct PresenterDesignApplyAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var design: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.design.apply", summary: "Gibt der ganzen Präsentation ein Design", kind: .write, security: .localWrite,
        input: .object(["deck": deckProperty, "design": .string("Design, z. B. aurora; presenter.designs.list zeigt alle")], required: ["deck", "design"]),
        output: .freeObject(), example: "llmd presenter design apply Vortrag aurora", groups: ["core", "presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        guard SlideDesignLibrary.shared.design(args.design) != nil else {
            let names = SlideDesignLibrary.shared.all.map(\.id).joined(separator: ", ")
            throw RPCError.notFound("Design „\(args.design)“ gibt es nicht. Vorhanden: \(names).")
        }
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.setPresentationBackground(document.id, .design(args.design))
        context.noteChange(of: document.id, before: document)
        return OKOutput()
    }
}

private let frameProperties: [String: JSONSchema] = [
    "x": .number("Linke Kante, Anteil der Folie 0–1", minimum: 0, maximum: 1),
    "y": .number("Obere Kante, Anteil der Folie 0–1", minimum: 0, maximum: 1),
    "width": .number("Breite, Anteil der Folie", minimum: 0.04, maximum: 1),
    "height": .number("Höhe, Anteil der Folie", minimum: 0.02, maximum: 1),
]

struct PresenterFieldAddTextAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var markdown: String
        var box: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addText", summary: "Legt ein freies Textfeld oder einen Kasten auf die Folie", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(frameProperties) { _, new in new }.merging([
            "markdown": .string("Text des Felds"), "box": .choice(WriterBoxKind.allCases.map(\.rawValue), "Als Kasten dieser Art"),
        ]) { _, new in new }, required: ["deck", "markdown"]),
        output: .freeObject(), example: "llmd presenter field add-text Vortrag --slide-index 2 --markdown Merke --x 0.55 --y 0.2 --width 0.4",
        groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        var made: UUID?
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            let canvas = SlideImage.canvas
            let frame = CGRect(x: (args.x ?? 0.1) * canvas.width, y: (args.y ?? 0.3) * canvas.height,
                               width: (args.width ?? 0.4) * canvas.width, height: (args.height ?? 0.25) * canvas.height)
            let field = SlideImage(text: args.markdown, box: args.box.flatMap(WriterBoxKind.init(rawValue:)), frame: frame)
            made = field.id
            deck.slides[deck.index(of: slide.id)!].images.append(field)
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterFieldAddImageAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
        var file: String
        var caption: String?
        var x: Double?
        var y: Double?
        var width: Double?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addImage", summary: "Legt ein Bild aus einer Datei auf die Folie", kind: .write, security: .localWrite,
        input: .object(slideProperties.merging(frameProperties) { _, new in new }.merging([
            "file": .string("Pfad der Bilddatei"), "caption": .string("Beschreibung"),
        ]) { _, new in new }.filter { $0.key != "height" }, required: ["deck", "file"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        // A path an agent names: the file comes into the library, so the person sees which one.
        ActionPreflight(target: args.file)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let url = ActionExportFolder.expanded(args.file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        let stored = try WriterImageStore.importImage(.file(url))
        let size = WriterImageStore.url(for: stored).flatMap(WriterImageStore.naturalSize(of:))
        let aspect = size.map { Double($0.width / max(1, $0.height)) } ?? 1.5
        var made: UUID?
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            var frame = SlideImage.defaultFrame(aspect: aspect)
            let canvas = SlideImage.canvas
            if let width = args.width {
                frame.size = CGSize(width: width * canvas.width, height: width * canvas.width / aspect)
            }
            if let x = args.x { frame.origin.x = x * canvas.width }
            if let y = args.y { frame.origin.y = y * canvas.height }
            let image = SlideImage(source: stored, caption: args.caption ?? "", frame: frame)
            made = image.id
            deck.slides[deck.index(of: slide.id)!].images.append(image)
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterFieldMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var field: String
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.field.move", summary: "Verschiebt ein Element oder ändert seine Größe", kind: .write, security: .localWrite,
        input: .object(frameProperties.merging(["deck": deckProperty, "field": .string("Element (ID)")]) { _, new in new }, required: ["deck", "field"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            for slide in deck.slides.indices {
                guard let index = deck.slides[slide].images.firstIndex(where: { $0.id.uuidString == args.field }) else { continue }
                if let x = args.x { deck.slides[slide].images[index].x = x }
                if let y = args.y { deck.slides[slide].images[index].y = y }
                if let width = args.width { deck.slides[slide].images[index].width = width }
                if let height = args.height { deck.slides[slide].images[index].height = height }
                return
            }
            throw RPCError.notFound("Element \(args.field) gibt es nicht.")
        }
        return OKOutput()
    }
}

struct PresenterFieldDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var field: String
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.field.delete", summary: "Entfernt ein Element von der Folie", kind: .write, security: .localWrite,
        input: .object(["deck": deckProperty, "field": .string("Element (ID)")], required: ["deck", "field"]),
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        _ = try changeDeck(args.deck, context: context) { deck in
            for slide in deck.slides.indices {
                guard let index = deck.slides[slide].images.firstIndex(where: { $0.id.uuidString == args.field }) else { continue }
                deck.slides[slide].images.remove(at: index)
                return
            }
            throw RPCError.notFound("Element \(args.field) gibt es nicht.")
        }
        return OKOutput()
    }
}

struct PresenterExportPDFAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var path: String?
        var overwrite: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.export.pdf", summary: "Exportiert die Folien als PDF", kind: .destructive, security: .outbound,
        input: .object(["deck": deckProperty, "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen")], required: ["deck"]),
        output: .freeObject(), example: "llmd presenter export pdf Vortrag", groups: ["core", "presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let inFolder = args.path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        return ActionPreflight(readsUntrusted: document.isForeign, isInSafePlace: inFolder, target: args.path ?? folder.path, detail: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> WriterExportAction.Output {
        let app = context.app
        let (document, deck) = try deck(args.deck, app)
        let folder = ActionExportFolder.url(settings: app.settings)
        let url = args.path.map(ActionExportFolder.expanded) ?? ActionExportFolder.freeFile(named: document.displayTitle, extension: "pdf", in: folder)
        guard args.path == nil || args.overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.invalidTarget("Die Datei gibt es schon: \(url.path)")
        }
        app.citations.loadIfNeeded()
        guard let data = await SlidePrinter.pdf(deck: deck, title: document.displayTitle, family: document.font, citations: app.citations) else {
            throw RPCError.internal("Die Folien ließen sich nicht als PDF zeichnen.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return WriterExportAction.Output(path: url.path, bytes: data.count)
    }
}

struct PresenterAICreateDeckAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var instruction: String
        var withNotes: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.ai.createDeck", summary: "Lässt das lokale Modell Folien schreiben; läuft im Hintergrund", kind: .write, security: .localWrite,
        input: .object(["deck": deckProperty, "instruction": .string("Auftrag, z. B. Predictive Coding, 8 Folien"), "withNotes": .boolean("Auch Moderatorenkarten")], required: ["deck", "instruction"]),
        output: .freeObject(), example: "llmd presenter ai create-deck Vortrag 'Predictive Coding, 8 Folien'", groups: ["presenter.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard app.deckGeneration?.isRunning != true else { throw RPCError.unavailable("Es läuft schon eine Folienerzeugung.") }
        // The model works on what the run told it: its text counts as the run's, so the origin carries over now.
        if let origin = context.mergedProvenance(document.provenance), origin != document.provenance {
            var marked = document
            marked.provenance = origin
            app.restoreDocument(marked)
        }
        app.generatePresentation(document.id, instruction: args.instruction, withNotes: args.withNotes == true, presents: false)
        return OKOutput(id: document.id.uuidString, message: "Läuft. Stand: presenter.ai.status")
    }
}

struct PresenterAIStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var running: Bool
        var phase: String
        var done: Int?
        var total: Int?
        var error: String?
        var deck: String?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.ai.status", summary: "Zeigt den Stand der Folienerzeugung", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        guard let generation = context.app.deckGeneration else { return Output(running: false, phase: "keine") }
        var output = Output(running: generation.isRunning, phase: "", deck: generation.documentID.uuidString)
        switch generation.phase {
        case .outlining: output.phase = "gliedert"
        case .filling(let done, let total):
            output.phase = "schreibt"
            output.done = done
            output.total = total
        case .finished: output.phase = "fertig"
        case .stopped: output.phase = "abgebrochen"
        case .failed(let message):
            output.phase = "fehlgeschlagen"
            output.error = message
        }
        return output
    }
}

struct PresenterAICancelAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "presenter.ai.cancel", summary: "Bricht die Folienerzeugung ab", kind: .write, security: .localWrite, output: .freeObject(), groups: ["presenter.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.stopDeckGeneration()
        return OKOutput()
    }
}

struct PresenterFromDocumentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var notes: Bool?
        var carryObjects: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.fromDocument", summary: "Macht aus einem Dokument eine Präsentation; läuft im Hintergrund und öffnet sie", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument (ID oder Titel)"), "notes": .boolean("Moderatorenkarten; Standard an"), "carryObjects": .boolean("Formeln, Code, Tabellen, Bilder übernehmen; Standard an")], required: ["doc"]),
        output: .freeObject(), example: "llmd presenter from-document Bericht", groups: ["core", "presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let document = try app.actionDocument(args.doc)
        guard app.deckGeneration?.isRunning != true else { throw RPCError.unavailable("Es läuft schon eine Folienerzeugung.") }
        var options = DeckSourceOptions()
        options.notes = args.notes ?? true
        options.carriesObjects = args.carryObjects ?? true
        app.createPresentation(from: app.deckMaterial(from: document), options: options)
        // `createPresentation` opens the new deck, which is how we learn its id.
        guard let id = app.selectedDocumentID else { throw RPCError.internal("Die Präsentation wurde nicht angelegt.") }
        if let made = app.document(id), let origin = context.mergedProvenance(document.provenance) {
            var marked = made
            marked.provenance = origin
            app.restoreDocument(marked)
        }
        return OKOutput(id: id.uuidString, message: "Läuft. Stand: presenter.ai.status")
    }
}
