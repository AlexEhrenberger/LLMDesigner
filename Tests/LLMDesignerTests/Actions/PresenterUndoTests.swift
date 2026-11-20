import Testing
import AppKit
@testable import LLMDesigner

/// ⌘Z in Presenter Studio: the slides' own operations can be taken back, and going to another slide doesn't throw
/// away what ⌘Z could still take back.
extension ActionSuites {
@MainActor
@Suite("Presenter: ⌘Z", .serialized)
struct PresenterUndoTests {
    let h = ActionHarness()

    @Test func goingToAnotherSlideKeepsWhatCanBeTakenBack() throws {
        // A window that is never shown, for its undo manager, as the editor has it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = WriterTextView.make()
        window.contentView = textView
        let undo = try #require(textView.undoManager)
        undo.groupsByEvent = false
        defer { undo.removeAllActions() }
        // Something of the presentation, say a picture moved on the slide before.
        var undone = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: h.app) { _ in undone = true }
        undo.endUndoGrouping()
        // The editor shows the next slide.
        textView.load(markdown: "# Nächste Folie", family: .sans, palette: .slide(tone: .light, accent: nil, alignment: .natural))
        #expect(undo.canUndo)
        undo.undo()
        #expect(undone)
    }

    // MARK: The slides' operations

    private func threeSlides() -> (WriterDocument.ID, [PresentationSlide.ID]) {
        var document = WriterDocument.newPresentation()
        document.title = "Rückgängig \(UUID().uuidString)"
        document.hasCustomTitle = true
        document.deck = PresentationDeck(slides: [
            PresentationSlide(role: .title, markdown: "# Titel {.chapter}"),
            PresentationSlide(role: .content, markdown: "# Eins"),
            PresentationSlide(role: .content, markdown: "# Zwei"),
        ])
        h.app.documents.insert(document, at: 0)
        return (document.id, document.deck!.slides.map(\.id))
    }

    private func ids(_ id: WriterDocument.ID) -> [PresentationSlide.ID] { h.app.document(id)?.deck?.slides.map(\.id) ?? [] }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private func manager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    @Test func deletingMovingDuplicatingAndAddingCanBeTakenBack() {
        let (id, slides) = threeSlides()
        let undo = manager()

        step(undo) { h.app.deleteSlide(id, slides[1], undoManager: undo) }
        #expect(ids(id) == [slides[0], slides[2]])
        undo.undo()
        #expect(ids(id) == slides)
        undo.redo()
        #expect(ids(id) == [slides[0], slides[2]])
        undo.undo()

        step(undo) { h.app.moveSlide(id, slides[0], to: 3, undoManager: undo) }
        #expect(ids(id) == [slides[1], slides[2], slides[0]])
        undo.undo()
        #expect(ids(id) == slides)

        step(undo) { h.app.duplicateSlide(id, slides[1], undoManager: undo) }
        #expect(ids(id).count == 4)
        undo.undo()
        #expect(ids(id) == slides)

        step(undo) { _ = h.app.addSlide(to: id, after: slides[2], undoManager: undo) }
        #expect(ids(id).count == 4)
        undo.undo()
        #expect(ids(id) == slides)
    }

    @Test func rolesAndBackgroundsCanBeTakenBack() throws {
        let (id, slides) = threeSlides()
        let undo = manager()
        h.app.setSlideBackground(id, slides[1], .color("#123456"))
        let before = try #require(h.app.document(id)?.deck?.backgrounds)

        // A background for every content slide takes the slide's own away; ⌘Z gives both back.
        step(undo) { h.app.setRoleBackground(id, .content, .gradient(["#000000", "#FFFFFF"]), undoManager: undo) }
        #expect(h.app.document(id)?.deck?.slide(slides[1])?.background == nil)
        undo.undo()
        #expect(h.app.document(id)?.deck?.slide(slides[1])?.background == .color("#123456"))
        #expect(h.app.document(id)?.deck?.backgrounds == before)

        step(undo) { h.app.setPresentationBackground(id, .color("#FFFFFF"), undoManager: undo) }
        undo.undo()
        #expect(h.app.document(id)?.deck?.backgrounds == before)
        #expect(h.app.document(id)?.deck?.slide(slides[1])?.background == .color("#123456"))

        step(undo) { h.app.setSlideRole(id, slides[2], .chapter, undoManager: undo) }
        #expect(h.app.document(id)?.deck?.slide(slides[2])?.role == .chapter)
        undo.undo()
        #expect(h.app.document(id)?.deck?.slide(slides[2])?.role == .content)
    }
}
}
