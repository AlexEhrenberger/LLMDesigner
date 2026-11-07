import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Presenter: leere Folien, Platzhalter, Bildbeschnitt, Rahmen, Textboxen", .serialized)
struct PresenterSlideToolsTests {
    let h = ActionHarness()

    private func deck() async throws -> String {
        try #require(try await h.call("presenter.deck.create", ["title": .string("Vortrag \(UUID().uuidString)")])["id"]?.stringValue)
    }

    private func deckValue(_ id: String) -> PresentationDeck { h.app.document(UUID(uuidString: id)!)!.deck! }

    /// A neutral 200 × 100 picture.
    private func pictureFile() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func aBlankSlideHasNoHintAndTheHintCanGo() async throws {
        let id = try await deck()
        let added = try await h.call("presenter.slide.add", ["deck": .string(id), "blank": true])
        #expect(deckValue(id).slides[1].hidesPlaceholder)
        #expect(WriterTextView.SlideLayout(slide: deckValue(id).slides[1]).placeholder.isEmpty)
        #expect(!WriterTextView.SlideLayout(slide: deckValue(id).slides[0]).placeholder.isEmpty)
        try await h.call("presenter.slide.placeholder", ["deck": .string(id), "slideIndex": 1, "visible": false])
        #expect(deckValue(id).slides[0].hidesPlaceholder)
        try await h.call("presenter.slide.placeholder", ["deck": .string(id), "slide": added["id"]!, "visible": true])
        #expect(!deckValue(id).slides[1].hidesPlaceholder)

        // The flag survives the file.
        var deck = deckValue(id)
        deck.slides[1].hidesPlaceholder = true
        let read = PresentationDeck.parse(deck.serialized)
        #expect(read.slides.map(\.hidesPlaceholder) == [true, true])
    }

    @Test func theModelUndoesTheHintsRemoval() throws {
        let app = h.app
        var document = WriterDocument.newPresentation()
        document.title = "Platzhalter \(UUID().uuidString)"
        app.reinsertDocumentForActionRedo(document)
        defer { app.removeDocumentForActionUndo(document.id) }
        let slideID = try #require(document.deck?.slides.first?.id)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        app.setSlidePlaceholderHidden(document.id, slideID, true, undoManager: undo)
        undo.endUndoGrouping()
        #expect(app.document(document.id)?.deck?.slide(slideID)?.hidesPlaceholder == true)
        undo.undo()
        #expect(app.document(document.id)?.deck?.slide(slideID)?.hidesPlaceholder == false)
        let blank = try #require(app.addSlide(to: document.id, after: slideID, blank: true))
        #expect(app.document(document.id)?.deck?.slide(blank)?.hidesPlaceholder == true)
    }

    @Test func picturesCanBeCutFramedAndShadowed() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await deck()
        let added = try await h.call("presenter.field.addImage", ["deck": .string(id), "slideIndex": 1, "file": .string(file.path), "width": .double(0.4)])
        let field = try #require(added["id"]?.stringValue)
        func picture() -> SlideImage { deckValue(id).slides[0].images.first { $0.id.uuidString == field }! }

        try await h.call("presenter.field.crop", ["deck": .string(id), "field": .string(field), "aspect": "1:1"])
        let square = try #require(picture().crop)
        #expect(abs(square.left - 0.25) < 0.001 && abs(square.right - 0.25) < 0.001 && square.top == 0)
        // The frame took the square shape (720 × 405 canvas).
        let frame = picture().frame
        #expect(abs(frame.width - frame.height) < 0.5)

        try await h.call("presenter.field.pictureStyle", ["deck": .string(id), "field": .string(field), "border": 4, "borderColor": "C9A227", "shadow": true])
        #expect(picture().borderWidth == 4)
        #expect(picture().borderColor == 0xC9A227)
        #expect(picture().shadow)
        #expect(await h.errorCode("presenter.field.pictureStyle", ["deck": .string(id), "field": .string(field), "borderColor": "lila"]) == RPCError.invalidParamsCode)

        // It all survives the file, and the slide still draws.
        let read = PresentationDeck.parse(deckValue(id).serialized).slides[0].images[0]
        let current = picture()
        #expect(read.crop == current.crop && read.borderWidth == 4 && read.borderColor == 0xC9A227 && read.shadow)
        let render = try await h.call("presenter.slide.render", ["deck": .string(id), "slideIndex": 1])
        #expect(render["width"] == 720)

        try await h.call("presenter.field.crop", ["deck": .string(id), "field": .string(field), "reset": true])
        #expect(picture().crop == nil)
        let text = try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Frei"])
        #expect(await h.errorCode("presenter.field.crop", ["deck": .string(id), "field": text["id"]!, "left": .double(0.1)]) == RPCError.invalidTargetCode)
    }

    @Test func aCutKeepsSomethingOfThePicture() {
        let crop = SlideCrop(left: 0.7, top: -1, right: 0.7, bottom: 2).clamped
        #expect(crop.left + crop.right <= 1 - SlideCrop.minimumKept + 0.0001)
        #expect(crop.top == 0)
        #expect(crop.top + crop.bottom <= 1 - SlideCrop.minimumKept + 0.0001)
        #expect(SlideCrop.centered(aspect: 2, of: 1).top == 0.25)
        #expect(SlideCrop.centered(aspect: 1.5, of: 1.5).isEmpty)
        let kept = SlideCrop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4).kept(in: CGSize(width: 100, height: 100))
        #expect(kept.integral == CGRect(x: 10, y: 20, width: 60, height: 40))

        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.gray.setFill()
            rect.fill()
            return true
        }
        let cut = SlideImageCache.cropped(image, SlideCrop(left: 0.25, right: 0.25))
        #expect(cut?.size == CGSize(width: 100, height: 100))
    }

    @Test func aTextBoxGoesOnTheOpenSlideReadyToWrite() async throws {
        let id = try await deck()
        let app = h.app
        app.selectDocument(UUID(uuidString: id)!)
        defer { app.endSlideFieldEditing(); app.closeDocument() }
        let before = deckValue(id).slides[0].images.count
        app.addTextBoxToOpenSlide()
        app.addTextBoxToOpenSlide(box: .hinweis)
        let fields = deckValue(id).slides[0].images
        #expect(fields.count == before + 2)
        #expect(fields.allSatisfy { $0.isText })
        #expect(fields.last?.box == .hinweis)
        // Two boxes in a row don't lie on top of each other, and the last one is open for writing.
        #expect(fields[fields.count - 1].frame.origin != fields[fields.count - 2].frame.origin)
        #expect(app.editingSlideFieldID == fields.last?.id)
    }
}
}
