import AppKit
import LLMDProtocol

/// What text an action works on: a document, or on a presentation a slide, one of its text fields or its speaker
/// card. That is why the `writer.*` actions also work on slides, as the Presenter catalog asks for.
struct WriterTargetArgs: Decodable, Sendable {
    var doc: String?
    var deck: String?
    var slide: String?
    var slideIndex: Int?
    var field: String?
    var notes: Bool?
    var ifVersion: String?

    static let schemaProperties: [String: JSONSchema] = [
        "doc": .string("Dokument (ID oder Titel)"),
        "deck": .string("Präsentation (ID oder Titel), mit slide"),
        "slide": .string("Folie (ID)"),
        "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1),
        "field": .string("Freies Element auf der Folie (ID)"),
        "notes": .boolean("Die Moderatorenkarte der Folie"),
        "ifVersion": .string("Nur ausführen, wenn der Text noch diese Version hat"),
    ]
}

@MainActor
struct WriterTarget {
    enum Part: Equatable {
        case document
        case slide(UUID)
        case field(slide: UUID, field: UUID)
        case notes(UUID)
    }

    let documentID: UUID
    let part: Part
    let app: AppModel

    init(_ args: WriterTargetArgs, app: AppModel) throws {
        self.app = app
        if let reference = args.deck ?? (args.slide != nil || args.slideIndex != nil ? args.doc : nil) {
            let document = try app.actionDocument(reference, presentation: true)
            documentID = document.id
            let deck = document.deck ?? PresentationDeck.new()
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            if let field = args.field {
                guard let image = slide.images.first(where: { $0.id.uuidString == field }) else { throw RPCError.notFound("Element \(field) gibt es auf dieser Folie nicht.") }
                guard image.isText else { throw RPCError.invalidTarget("Element \(field) ist ein Bild und hat keinen Text.") }
                part = .field(slide: slide.id, field: image.id)
            } else if args.notes == true {
                part = .notes(slide.id)
            } else {
                part = .slide(slide.id)
            }
        } else if let reference = args.doc {
            let document = try app.actionDocument(reference)
            documentID = document.id
            part = .document
        } else {
            throw RPCError.invalidParams("Bitte doc angeben, oder deck mit slide.")
        }
    }

    var document: WriterDocument? { app.document(documentID) }

    var markdown: String {
        guard let document else { return "" }
        switch part {
        case .document:
            return document.markdown
        case .slide(let slide):
            return document.deck?.slides.first { $0.id == slide }?.markdown ?? ""
        case .field(let slide, let field):
            return document.deck?.slides.first { $0.id == slide }?.images.first { $0.id == field }?.text ?? ""
        case .notes(let slide):
            return document.deck?.slides.first { $0.id == slide }?.notes ?? ""
        }
    }

    var version: String { ActionVersion.of(markdown) }

    /// Writes the text through the same functions the editor uses, so an open editor reloads.
    private func store(_ text: String) {
        switch part {
        case .document: app.updateDocument(documentID, markdown: text)
        case .slide(let slide): app.updateSlide(documentID, slide, markdown: text)
        case .field(_, let field): app.updateSlide(documentID, field, markdown: text)
        case .notes(let slide): app.setSlideNotes(documentID, slide, text)
        }
    }

    /// The change as one undoable step, with the origin carried over and the event sent.
    func replaceText(with text: String, ifVersion: String?, context: ActionContext) throws -> WriterWriteResult {
        try checkVersion(ifVersion)
        let before = document
        store(text)
        context.noteChange(of: documentID, before: before)
        return WriterWriteResult(doc: documentID.uuidString, version: version, block: nil, source: nil)
    }

    func checkVersion(_ wanted: String?) throws {
        if let wanted, wanted != version { throw RPCError.versionConflict(current: version) }
    }
}

/// What a change returns: enough to go on without reading again.
struct WriterWriteResult: Encodable, Sendable {
    var doc: String
    var version: String
    var block: String?
    /// The file of a picture the change made.
    var source: String?
}

extension ActionContext {
    /// Registers a document's change: origin, undo step, highlight and event.
    func noteChange(of id: UUID, before: WriterDocument?, label: String? = nil) {
        guard var after = app.document(id) else { return }
        let origin = mergedProvenance(before?.provenance)
        if after.provenance != origin {
            after.provenance = origin
            app.restoreDocument(after)
        }
        if let before, before != after {
            let app = self.app
            undoGroup.documents.insert(id)
            undoGroup.add(UndoStep(label: label ?? undoGroup.label, undo: { app.restoreDocument(before) }, redo: { app.restoreDocument(after) }))
        }
        app.highlightActionChange(in: id, channel: channel)
        registry.eventSink?(ActionEvent(kind: ActionEvent.documentChanged, action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
    }
}

extension PresentationDeck {
    /// A slide by id or position.
    func actionSlide(id: String?, index: Int?) throws -> PresentationSlide {
        if let id {
            guard let slide = slides.first(where: { $0.id.uuidString == id }) else { throw RPCError.notFound("Folie \(id) gibt es nicht.") }
            return slide
        }
        if let index {
            guard slides.indices.contains(index - 1) else { throw RPCError.notFound("Folie \(index) gibt es nicht (\(slides.count) Folien).") }
            return slides[index - 1]
        }
        throw RPCError.invalidParams("Bitte slide oder slideIndex angeben.")
    }
}

/// Changes to one block go through attributed text, using the same attributes the editor sets. Only that block is
/// converted: the rest of the document stays as it was written.
@MainActor
struct BlockEditor {
    var blocks: [String]

    init(markdown: String) {
        blocks = PowerText.chunks(of: markdown).map(\.markdown)
    }

    var markdown: String { PowerText.join(blocks) }

    mutating func edit(_ index: Int, _ change: (NSMutableAttributedString) throws -> Void) rethrows {
        let text = WriterMarkdown.attributedString(from: blocks[index])
        try change(text)
        let result = WriterMarkdown.markdown(from: text).trimmingCharacters(in: .newlines)
        if result.trimmingCharacters(in: .whitespaces).isEmpty { blocks.remove(at: index) } else { blocks[index] = result }
    }

    /// The whole text of an attributed block, without the final newline.
    static func fullRange(of text: NSAttributedString) -> NSRange {
        var length = text.length
        let string = text.string as NSString
        while length > 0, string.character(at: length - 1) == 0x0A { length -= 1 }
        return NSRange(location: 0, length: length)
    }

    /// Blocks with no running text: marks make no sense in them.
    static func holdsText(_ kind: PowerChunk.Kind) -> Bool {
        switch kind {
        case .code, .math, .image: false
        default: true
        }
    }
}
