import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterMoreActions() {
        register(PresenterDeckOpenAction.self)
        register(PresenterDeckCloseAction.self)
        register(PresenterDeckRenameAction.self)
        register(PresenterDeckMoveAction.self)
        register(PresenterDeckDuplicateAction.self)
        register(PresenterBackgroundsGetAction.self)
        register(PresenterStateGetAction.self)
        register(PresenterFindAction.self)
        register(PresenterSlideAddFromTextAction.self)
        register(PresenterSlideAddAgendaAction.self)
        register(PresenterSlideRestoreAction.self)
        register(PresenterSlideSelectAction.self)
        register(PresenterSlideSetTitleAction.self)
        register(PresenterTextAreaSetAction.self)
        register(PresenterTextAreaResetAction.self)
        registerPresenterFieldActions()
        registerPresenterStyleActions()
        registerPresenterFitActions()
        registerPresenterPlayActions()
    }
}

let presenterDeckProperty: JSONSchema = .string("Präsentation (ID oder Titel)")
let presenterSlideProperties: [String: JSONSchema] = [
    "deck": presenterDeckProperty, "slide": .string("Folie (ID)"), "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1),
]

struct PresenterMoreArgs: Decodable, Sendable {
    var deck: String
    var slide: String?
    var slideIndex: Int?
    var after: String?
    var title: String?
    var folder: String?
    var query: String?
    var text: String?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
}

/// A slide's title in its text: the first line when it is a heading, otherwise a new heading above the text.
enum PresenterTitle {
    @MainActor
    static func setting(_ title: String, in slide: PresentationSlide) -> String {
        var blocks = PowerText.chunks(of: slide.markdown).map(\.markdown)
        let isChapterRole = slide.role != .content
        let line = "# " + WriterMarkdown.escape(title, atLineStart: false) + (isChapterRole ? " {.chapter}" : "")
        if let first = PowerText.chunks(of: slide.markdown).first, case .heading = first.kind {
            blocks[0] = line
        } else {
            blocks.insert(line, at: 0)
        }
        return PowerText.join(blocks)
    }
}

struct PresenterDeckOpenAction: LLMDAction {
    typealias Args = PresenterDeckArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.open", summary: "Öffnet eine Präsentation", kind: .read, security: .plainRead,
        input: .object(["deck": presenterDeckProperty], required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.selectDocument(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

struct PresenterDeckCloseAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.close", summary: "Schließt die offene Präsentation", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        guard context.app.selectedDocument?.isPresentation == true else { throw RPCError.invalidTarget("Es ist keine Präsentation offen.") }
        context.app.closeDocument()
        return OKOutput()
    }
}

struct PresenterDeckRenameAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.rename", summary: "Benennt eine Präsentation um", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "title": .string("Neuer Titel")], required: ["deck", "title"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.renameDocument(document.id, to: args.title ?? "")
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: document.id.uuidString)
    }
}

struct PresenterDeckMoveAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.move", summary: "Legt eine Präsentation in einen Ordner; ohne folder ganz nach oben", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "folder": .string("Ordner (ID oder Name)")], required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        context.app.moveDocument(document.id, to: try args.folder.map { try context.app.actionChatFolder($0).id }, reveal: false)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: document.id.uuidString)
    }
}

struct PresenterDeckDuplicateAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.deck.duplicate", summary: "Kopiert eine Präsentation", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "title": .string("Titel der Kopie")], required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var copy = try app.actionDocument(args.deck, presentation: true)
        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.title = args.title ?? copy.displayTitle + " (Kopie)"
        copy.hasCustomTitle = true
        copy.provenance = context.mergedProvenance(copy.provenance)
        app.reinsertDocumentForActionRedo(copy)
        let made = copy
        context.undoGroup.add(UndoStep(label: "Präsentation kopieren", undo: { app.removeDocumentForActionUndo(made.id) }, redo: { app.reinsertDocumentForActionRedo(made) }))
        return OKOutput(id: copy.id.uuidString)
    }
}

struct PresenterBackgroundsGetAction: LLMDAction {
    typealias Args = PresenterDeckArgs
    struct Own: Encodable, Sendable {
        var slide: String
        var index: Int
        var background: SlideBackground
    }
    struct Output: Encodable, Sendable {
        var titel: SlideBackground?
        var kapitel: SlideBackground?
        var folie: SlideBackground?
        var slides: [Own]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.backgrounds.get", summary: "Zeigt die Hintergründe nach Art der Folie und die eigenen einzelner Folien", kind: .read, security: .plainRead,
        input: .object(["deck": presenterDeckProperty], required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        guard let deck = document.deck else { throw RPCError.invalidTarget("„\(document.displayTitle)“ hat keine Folien.") }
        return Output(titel: deck.backgrounds.titel, kapitel: deck.backgrounds.kapitel, folie: deck.backgrounds.folie,
                      slides: deck.slides.enumerated().compactMap { index, slide in
                          slide.background.map { Own(slide: slide.id.uuidString, index: index + 1, background: $0) }
                      })
    }
}

struct PresenterStateGetAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var deck: String?
        var title: String?
        var slide: String?
        var slideIndex: Int?
        var field: String?
        var writingNotes: Int
        var generating: Bool
        var playing: PresenterPlayStatusAction.Output
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.state.get", summary: "Zeigt offene Präsentation, aktuelle Folie, laufende KI-Aufgaben und den Vortrag", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        let open = app.selectedDocument?.isPresentation == true ? app.selectedDocument : nil
        let slide = open.flatMap { app.currentSlideID(in: $0) }
        return Output(deck: open?.id.uuidString, title: open?.displayTitle, slide: slide?.uuidString,
                      slideIndex: slide.flatMap { open?.deck?.index(of: $0) }.map { $0 + 1 }, field: app.editingSlideFieldID?.uuidString,
                      writingNotes: app.notesWriting.count, generating: app.deckGeneration?.isRunning == true,
                      playing: PresenterPlayStatusAction.status(app))
    }
}

struct PresenterFindAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    struct Hit: Encodable, Sendable {
        var slide: String
        var index: Int
        var place: String
        var field: String?
        var excerpt: String
    }
    struct Output: Encodable, Sendable {
        var hits: [Hit]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.find", summary: "Sucht in Folien, Moderatorenkarten und Textfeldern", kind: .read, security: .plainRead,
        input: .object(["deck": presenterDeckProperty, "query": .string("Suchtext")], required: ["deck", "query"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        let query = args.query ?? ""
        guard !query.isEmpty else { throw RPCError.invalidParams("Leerer Suchtext.") }
        var hits: [Hit] = []
        func look(in text: String, slide: PresentationSlide, index: Int, place: String, field: String? = nil) {
            let string = text as NSString
            var start = 0
            while start < string.length {
                let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
                guard found.location != NSNotFound else { break }
                let from = max(0, found.location - 30), to = min(string.length, NSMaxRange(found) + 30)
                hits.append(Hit(slide: slide.id.uuidString, index: index + 1, place: place, field: field,
                                excerpt: string.substring(with: NSRange(location: from, length: to - from)).replacingOccurrences(of: "\n", with: " ")))
                start = NSMaxRange(found)
            }
        }
        for (index, slide) in (document.deck?.slides ?? []).enumerated() {
            look(in: slide.markdown, slide: slide, index: index, place: "text")
            look(in: slide.notes, slide: slide, index: index, place: "notes")
            for field in slide.images {
                if let text = field.text { look(in: text, slide: slide, index: index, place: "field", field: field.id.uuidString) }
            }
        }
        return Output(hits: hits)
    }
}

struct PresenterSlideAddFromTextAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.addFromText", summary: "Macht aus Text eine Folie: die erste Zeile wird Titel, der Rest Stichpunkte", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "after": .string("Hinter dieser Folie (ID); sonst am Ende"), "text": .string("Der Text")], required: ["deck", "text"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let markdown = AppModel.slideMarkdown(from: args.text ?? "")
        guard !markdown.isEmpty else { throw RPCError.invalidParams("Der Text ist leer.") }
        let slide = PresentationSlide(role: .content, markdown: markdown)
        _ = try changeDeck(args.deck, context: context) { deck in
            let index = try args.after.map { try deck.index(of: deck.actionSlide(id: $0, index: nil).id).map { $0 + 1 } ?? deck.slides.count } ?? deck.slides.count
            deck.slides.insert(slide, at: index)
        }
        return OKOutput(id: slide.id.uuidString, fit: SlideFit.report(slideID: slide.id, in: try context.app.actionDocument(args.deck, presentation: true)))
    }
}

struct PresenterSlideAddAgendaAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.addAgenda", summary: "Fügt eine Agenda aus den Kapitelfolien ein", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "after": .string("Hinter dieser Folie (ID); sonst am Ende")], required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        let before = document.deck?.slides.map(\.id) ?? []
        let after = try args.after.map { try document.deck?.actionSlide(id: $0, index: nil).id } ?? document.deck?.slides.last?.id
        app.insertAgendaSlide(document.id, after: after)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: app.document(document.id)?.deck?.slides.first { !before.contains($0.id) }?.id.uuidString)
    }
}

struct PresenterSlideRestoreAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.restore", summary: "Holt die zuletzt gelöschte Folie zurück, solange es geht", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        guard let deleted = app.deletedSlide else { throw RPCError.notFound("Es gibt keine gelöschte Folie mehr.") }
        let before = app.document(deleted.documentID)
        app.restoreDeletedSlide()
        context.noteChange(of: deleted.documentID, before: before)
        return OKOutput(id: deleted.slide.id.uuidString)
    }
}

struct PresenterSlideSelectAction: LLMDAction {
    typealias Args = PresenterSlideArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.select", summary: "Zeigt eine Folie in der offenen Präsentation; ist sie zu, öffnet sie sich", kind: .read, security: .plainRead,
        input: .object(presenterSlideProperties, required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        guard let slide = try document.deck?.actionSlide(id: args.slide, index: args.slideIndex) else { throw RPCError.invalidTarget("Diese Präsentation hat keine Folien.") }
        if context.app.selectedDocumentID != document.id { context.app.selectDocument(document.id) }
        context.app.selectSlide(slide.id)
        return OKOutput(id: slide.id.uuidString)
    }
}

struct PresenterSlideSetTitleAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.setTitle", summary: "Setzt den Titel einer Folie: ihre erste Überschrift", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties.merging(["title": .string("Der Titel")]) { _, new in new }, required: ["deck", "title"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var made: UUID?
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            deck.slides[deck.index(of: slide.id)!].markdown = PresenterTitle.setting(args.title ?? "", in: slide)
            made = slide.id
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterTextAreaSetAction: LLMDAction {
    typealias Args = PresenterMoreArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.textArea.set", summary: "Legt den Textbereich einer Folie fest, als Anteile der Folie", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties.merging([
            "x": .number("Linke Kante 0–1", minimum: 0, maximum: 1), "y": .number("Obere Kante 0–1", minimum: 0, maximum: 1),
            "width": .number("Breite 0–1", minimum: 0.05, maximum: 1), "height": .number("Höhe 0–1", minimum: 0.05, maximum: 1),
        ]) { _, new in new }, required: ["deck", "x", "y", "width", "height"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            let canvas = SlideImage.canvas
            deck.slides[deck.index(of: slide.id)!].textArea = SlideArea(frame: CGRect(x: (args.x ?? 0) * canvas.width, y: (args.y ?? 0) * canvas.height,
                                                                                     width: (args.width ?? 1) * canvas.width, height: (args.height ?? 1) * canvas.height))
        }
        return OKOutput()
    }
}

struct PresenterTextAreaResetAction: LLMDAction {
    typealias Args = PresenterSlideArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.textArea.reset", summary: "Gibt einer Folie den normalen Textbereich zurück", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties, required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            deck.slides[deck.index(of: slide.id)!].textArea = nil
        }
        return OKOutput()
    }
}
