import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Presenter: Verwaltung, Elemente, Hintergründe, Vortrag", .serialized)
struct PresenterMoreActionTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_MERMAID_JS", root.appendingPathComponent("Resources/Mermaid/mermaid.min.js").path, 1)
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    private func make(_ title: String = "Vortrag \(UUID().uuidString)") async throws -> String {
        try #require(try await h.call("presenter.deck.create", ["title": .string(title)])["id"]?.stringValue)
    }

    private func deck(_ id: String) -> PresentationDeck { h.app.document(UUID(uuidString: id)!)!.deck! }

    private func pictureFile() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    // MARK: Decks

    @Test func openRenameMoveDuplicateClose() async throws {
        let id = try await make()
        try await h.call("presenter.deck.open", ["deck": .string(id)])
        #expect(h.app.selectedDocumentID?.uuidString == id)
        let state = try await h.call("presenter.state.get")
        #expect(state["deck"] == .string(id))
        #expect(state["slideIndex"] == 1)
        try await h.call("presenter.deck.close")
        #expect(h.app.selectedDocumentID == nil)
        #expect(await h.errorCode("presenter.deck.close") == RPCError.invalidTargetCode)

        let title = "Anders \(UUID().uuidString)"
        try await h.call("presenter.deck.rename", ["deck": .string(id), "title": .string(title)])
        #expect(h.app.document(UUID(uuidString: id)!)?.displayTitle == title)
        let copy = try await h.call("presenter.deck.duplicate", ["deck": .string(title), "title": "Kopie X"])
        let copyID = UUID(uuidString: try #require(copy["id"]?.stringValue))!
        #expect(h.app.document(copyID)?.isPresentation == true)
        try await h.call("writer.edit.undo")
        #expect(h.app.document(copyID) == nil)
        try await h.call("presenter.deck.move", ["deck": .string(id)])
        #expect(await h.errorCode("presenter.deck.move", ["deck": .string(id), "folder": "Gibt es nicht"]) == RPCError.notFoundCode)
    }

    @Test func findAcrossSlides() async throws {
        let id = try await make()
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "Der Wasserkreislauf"])
        try await h.call("presenter.notes.set", ["deck": .string(id), "slideIndex": 1, "text": "Wasser erklären"])
        try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Viel wasser"])
        let found = try await h.call("presenter.find", ["deck": .string(id), "query": "wasser"])
        #expect(found["hits"]?.arrayValue?.map { $0["place"]?.stringValue } == ["text", "notes", "field"])
        #expect(await h.errorCode("presenter.find", ["deck": .string(id), "query": ""]) == RPCError.invalidParamsCode)
    }

    // MARK: Slides

    @Test func slidesFromTextAgendaTitleRestore() async throws {
        let id = try await make()
        try await h.call("presenter.slide.add", ["deck": .string(id), "role": "kapitel", "markdown": "# Erstes Kapitel {.chapter}"])
        let made = try await h.call("presenter.slide.addFromText", ["deck": .string(id), "text": "Titel\nPunkt eins\nPunkt zwei"])
        #expect(deck(id).slides.last?.markdown == "# Titel\n\n- Punkt eins\n- Punkt zwei")
        #expect(deck(id).slides.last?.id.uuidString == made["id"]?.stringValue)
        #expect(await h.errorCode("presenter.slide.addFromText", ["deck": .string(id), "text": "  "]) == RPCError.invalidParamsCode)

        let agenda = try await h.call("presenter.slide.addAgenda", ["deck": .string(id), "after": .string(deck(id).slides[0].id.uuidString)])
        #expect(deck(id).slides[1].id.uuidString == agenda["id"]?.stringValue)
        #expect(deck(id).slides[1].markdown.hasPrefix("# Agenda"))
        #expect(deck(id).slides[1].markdown.contains("Erstes Kapitel"))

        try await h.call("presenter.slide.setTitle", ["deck": .string(id), "slideIndex": 4, "title": "Neuer Titel"])
        #expect(deck(id).slides[3].markdown.trimmingCharacters(in: .newlines) == "# Neuer Titel\n\n- Punkt eins\n- Punkt zwei")
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 4, "markdown": "Nur Text"])
        try await h.call("presenter.slide.setTitle", ["deck": .string(id), "slideIndex": 4, "title": "Oben"])
        #expect(deck(id).slides[3].markdown.trimmingCharacters(in: .newlines) == "# Oben\n\nNur Text")

        let count = deck(id).slides.count
        let gone = deck(id).slides[1].id
        try await h.call("presenter.slide.delete", ["deck": .string(id), "slide": .string(gone.uuidString)])
        #expect(deck(id).slides.count == count - 1)
        try await h.call("presenter.slide.restore")
        #expect(deck(id).slides[1].id == gone)
        #expect(await h.errorCode("presenter.slide.restore") == RPCError.notFoundCode)

        h.app.closeDocument()
        try await h.call("presenter.slide.select", ["deck": .string(id), "slideIndex": 2])
        #expect(h.app.selectedSlideID == deck(id).slides[1].id)
        h.app.closeDocument()
    }

    @Test func textArea() async throws {
        let id = try await make()
        try await h.call("presenter.textArea.set", ["deck": .string(id), "slideIndex": 1, "x": .double(0.1), "y": .double(0.2), "width": .double(0.5), "height": .double(0.6)])
        let area = try #require(deck(id).slides[0].textArea)
        #expect(abs(area.x - 0.1) < 0.001)
        #expect(abs(area.width - 0.5) < 0.001)
        try await h.call("presenter.textArea.reset", ["deck": .string(id), "slideIndex": 1])
        #expect(deck(id).slides[0].textArea == nil)
    }

    // MARK: Free elements

    private func field(_ id: String, _ fieldID: String) throws -> SlideImage {
        try #require(deck(id).slides.flatMap(\.images).first { $0.id.uuidString == fieldID })
    }

    @Test func boxesTablesCode() async throws {
        let id = try await make()
        let box = try #require(try await h.call("presenter.field.addBox", ["deck": .string(id), "slideIndex": 1, "kind": "merksatz", "markdown": "Merke", "x": .double(0.1)])["id"]?.stringValue)
        #expect(try field(id, box).box == .merksatz)
        #expect(abs(try field(id, box).x - 0.1) < 0.001)
        try await h.call("presenter.field.box", ["deck": .string(id), "field": .string(box), "kind": "achtung", "frame": "outline"])
        #expect(try field(id, box).box == .achtung)
        #expect(try field(id, box).boxFrame == .outline)
        try await h.call("presenter.field.box", ["deck": .string(id), "field": .string(box), "kind": "none"])
        #expect(try field(id, box).box == nil)

        let table = try #require(try await h.call("presenter.field.addTable", ["deck": .string(id), "slideIndex": 1, "header": ["A", "B"], "data": [["1", "2"]]])["id"]?.stringValue)
        #expect(try field(id, table).text?.contains("| A | B |") == true)
        // A table in a field works with the writer actions, as the catalog promises.
        try await h.call("writer.table.cell.set", ["deck": .string(id), "slideIndex": 1, "field": .string(table), "cell": "B2", "text": "9"])
        #expect(try field(id, table).text?.contains("| 1 | 9 |") == true)

        let empty = try #require(try await h.call("presenter.field.addTable", ["deck": .string(id), "slideIndex": 1])["id"]?.stringValue)
        #expect(MarkdownTable(markdown: try field(id, empty).text ?? "")?.rows == 3)

        let code = try #require(try await h.call("presenter.field.addCode", ["deck": .string(id), "slideIndex": 1, "language": "python", "code": "print(1)"])["id"]?.stringValue)
        #expect(try field(id, code).text == "```python\nprint(1)\n```")
    }

    @Test func figuresInFields() async throws {
        let id = try await make()
        let chart = try #require(try await h.call("presenter.field.addFigure", [
            "deck": .string(id), "slideIndex": 1, "figureKind": "chart", "categories": ["A"], "series": [["name": "X", "values": [1]]],
        ])["id"]?.stringValue)
        #expect(WriterImageReference.parse(try field(id, chart).text ?? "")?.figure == .chart)
        let mermaid = try #require(try await h.call("presenter.field.addFigure", ["deck": .string(id), "slideIndex": 1, "figureKind": "mermaid", "code": "flowchart TD\n  A-->B"])["id"]?.stringValue)
        #expect(WriterImageReference.parse(try field(id, mermaid).text ?? "")?.figure == .mermaid)
        let drawing = try #require(try await h.call("presenter.field.addFigure", [
            "deck": .string(id), "slideIndex": 1, "figureKind": "drawing", "elements": [["kind": "line", "points": [[0, 0], [9, 9]]]],
        ])["id"]?.stringValue)
        #expect(WriterImageReference.parse(try field(id, drawing).text ?? "")?.figure == .drawing)
        #expect(await h.errorCode("presenter.field.addFigure", ["deck": .string(id), "slideIndex": 1, "figureKind": "mermaid"]) == RPCError.invalidParamsCode)
    }

    @Test func generatedPictureOnASlide() async throws {
        // A port where nothing listens, so a running Draw Things isn't bothered.
        let address = h.app.imageGeneration.address
        h.app.imageGeneration.address = "http://127.0.0.1:9"
        defer { h.app.imageGeneration.address = address }
        let id = try await make()
        let made = try #require(try await h.call("presenter.field.generateImage", ["deck": .string(id), "slideIndex": 1, "prompt": "a lighthouse"])["id"]?.stringValue)
        let image = try field(id, made)
        #expect(image.generated)
        #expect(WriterImageStore.generationInfo(for: image.source)?.prompt == "a lighthouse")
        h.app.imageGeneration.cancel(image.source)
        try await h.call("presenter.field.regenerateImage", ["deck": .string(id), "field": .string(made), "prompt": "a harbour"])
        let again = try field(id, made)
        #expect(WriterImageStore.generationInfo(for: again.source)?.prompt == "a harbour")
        h.app.imageGeneration.cancel(again.source)
        #expect(await h.errorCode("presenter.field.generateImage", ["deck": .string(id), "slideIndex": 1, "prompt": " "]) == RPCError.invalidParamsCode)
    }

    @Test func detachMovesTextOut() async throws {
        let id = try await make()
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "# Titel\n\nDieser Absatz geht weg.\n\nDieser bleibt."])
        let chunks = PowerText.chunks(of: deck(id).slides[0].markdown)
        let block = WriterBlockInfo.id(index: 1, markdown: chunks[1].markdown)
        let made = try #require(try await h.call("presenter.field.detachSelection", ["deck": .string(id), "slideIndex": 1, "block": .string(block)])["id"]?.stringValue)
        #expect(try field(id, made).text == "Dieser Absatz geht weg.")
        #expect(deck(id).slides[0].markdown.trimmingCharacters(in: .newlines) == "# Titel\n\nDieser bleibt.")
        #expect(await h.errorCode("presenter.field.detachSelection", ["deck": .string(id), "slideIndex": 1]) == RPCError.invalidParamsCode)
    }

    @Test func placeAndOrderOfElements() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await make()
        let picture = try #require(try await h.call("presenter.field.addImage", ["deck": .string(id), "slideIndex": 1, "file": .string(file.path)])["id"]?.stringValue)
        let text = try #require(try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Zeile eins\n\nZeile zwei\n\nZeile drei"])["id"]?.stringValue)

        try await h.call("presenter.field.resize", ["deck": .string(id), "field": .string(picture), "width": .double(0.5), "height": .double(0.5)])
        #expect(abs(try field(id, picture).width - 0.5) < 0.001)
        try await h.call("presenter.field.restoreAspect", ["deck": .string(id), "field": .string(picture)])
        #expect(abs(try field(id, picture).frame.height - (try field(id, picture).frame.width) / 2) < 0.5)
        #expect(await h.errorCode("presenter.field.restoreAspect", ["deck": .string(id), "field": .string(text)]) == RPCError.invalidTargetCode)

        try await h.call("presenter.field.resize", ["deck": .string(id), "field": .string(text), "height": .double(0.05)])
        try await h.call("presenter.field.resize", ["deck": .string(id), "field": .string(text), "fitText": true])
        #expect(try field(id, text).height > 0.05)
        #expect(await h.errorCode("presenter.field.resize", ["deck": .string(id), "field": .string(picture), "fitText": true]) == RPCError.invalidTargetCode)

        try await h.call("presenter.field.align", ["deck": .string(id), "field": .string(picture), "edge": "center"])
        #expect(abs(try field(id, picture).x - 0.25) < 0.001)
        try await h.call("presenter.field.align", ["deck": .string(id), "field": .string(picture), "edge": "right"])
        #expect(abs(try field(id, picture).x - 0.5) < 0.001)
        try await h.call("presenter.field.align", ["deck": .string(id), "field": .string(picture), "edge": "top"])
        #expect(try field(id, picture).y == 0)

        try await h.call("presenter.field.placement", ["deck": .string(id), "field": .string(picture), "placement": "hinten"])
        #expect(try field(id, picture).placement == .behind)
        try await h.call("presenter.field.caption", ["deck": .string(id), "field": .string(picture), "caption": "Ein Bild"])
        #expect(try field(id, picture).caption == "Ein Bild")

        func order() -> [String] { deck(id).slides[0].images.map(\.id.uuidString) }
        #expect(order() == [picture, text])
        try await h.call("presenter.field.order", ["deck": .string(id), "field": .string(picture), "order": "front"])
        #expect(order() == [text, picture])
        try await h.call("presenter.field.order", ["deck": .string(id), "field": .string(picture), "order": "backward"])
        #expect(order() == [picture, text])
        try await h.call("presenter.field.order", ["deck": .string(id), "field": .string(picture), "order": "forward"])
        try await h.call("presenter.field.order", ["deck": .string(id), "field": .string(picture), "order": "back"])
        #expect(order() == [picture, text])
        #expect(await h.errorCode("presenter.field.order", ["deck": .string(id), "field": "fehlt", "order": "back"]) == RPCError.notFoundCode)
    }

    @Test func editingAField() async throws {
        let id = try await make()
        let text = try #require(try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Text"])["id"]?.stringValue)
        try await h.call("presenter.field.edit", ["deck": .string(id), "field": .string(text)])
        #expect(h.app.editingSlideFieldID?.uuidString == text)
        #expect(h.app.selectedDocumentID?.uuidString == id)
        try await h.call("presenter.field.endEdit")
        #expect(h.app.editingSlideFieldID == nil)
        h.app.closeDocument()
    }

    @Test func aPictureFromADocument() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let doc = try await h.document("Text")
        try await h.call("writer.image.insert", ["doc": .string(doc), "file": .string(file.path)])
        let id = try await make()
        let made = try await h.call("presenter.field.toSlide", ["doc": .string(doc), "deck": .string(id), "slideIndex": 1])
        #expect(deck(id).slides[0].images.first?.id.uuidString == made["id"]?.stringValue)
    }

    // MARK: Backgrounds and designs

    @Test func backgrounds() async throws {
        let id = try await make()
        try await h.call("presenter.background.set", ["deck": .string(id), "slideIndex": 1, "kind": "color", "colors": ["Blau"]])
        #expect(deck(id).slides[0].background == .color("1F5FBF"))
        var read = try await h.call("presenter.backgrounds.get", ["deck": .string(id)])
        #expect(read["slides"]?.arrayValue?.first?["index"] == 1)
        try await h.call("presenter.background.clear", ["deck": .string(id), "slideIndex": 1])
        #expect(deck(id).slides[0].background == nil)

        try await h.call("presenter.background.set", ["deck": .string(id), "role": "kapitel", "kind": "gradient", "colors": ["112233", "445566"], "angle": 90])
        #expect(deck(id).backgrounds.kapitel?.kind == .gradient)
        #expect(deck(id).backgrounds.kapitel?.angle == 90)
        read = try await h.call("presenter.backgrounds.get", ["deck": .string(id)])
        #expect(read["kapitel"]?["kind"] == "gradient")

        let design = try #require(SlideDesignLibrary.shared.all.first?.id)
        try await h.call("presenter.background.set", ["deck": .string(id), "kind": "design", "design": .string(design)])
        #expect(deck(id).backgrounds.folie?.design == design)
        #expect(await h.errorCode("presenter.background.set", ["deck": .string(id), "kind": "design", "design": "gibtsnicht"]) == RPCError.notFoundCode)
        #expect(await h.errorCode("presenter.background.set", ["deck": .string(id), "kind": "gradient", "colors": ["112233"]]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("presenter.background.set", ["deck": .string(id), "kind": "color"]) == RPCError.invalidParamsCode)
    }

    @Test func backgroundFromAFile() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await make()
        try await h.call("presenter.background.image", ["deck": .string(id), "slideIndex": 1, "file": .string(file.path), "dim": .double(0.5)])
        #expect(deck(id).slides[0].background?.kind == .image)
        #expect(deck(id).slides[0].background?.dim == 0.5)
        #expect(deck(id).slides[0].background?.tone != nil)
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("presenter.background.image", ["deck": .string(id), "file": .string(file.path)], channel: .mcp) == RPCError.deniedCode)
    }

    @Test func generatedBackgroundsNeedAModel() async throws {
        let id = try await make()
        let old = h.app.endpoint
        h.app.endpoint = "keine adresse"
        defer { h.app.endpoint = old }
        #expect(await h.errorCode("presenter.background.generate", ["deck": .string(id), "description": "Ein Wald"]) == RPCError.unavailableCode)
    }

    @Test func designs() async throws {
        let name = "Probe \(UUID().uuidString.prefix(6))"
        let result = try await h.call("presenter.design.create", ["name": .string(name), "css": "body { background: #123456; background-image: url(https://example.org/spur.png); }"])
        let id = try #require(result["id"]?.stringValue)
        let design = try #require(SlideDesignLibrary.shared.design(id))
        #expect(design.name == name)
        #expect(!design.css.contains("example.org"))
        #expect(await h.errorCode("presenter.design.create", ["name": .string(name), "css": "x"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("presenter.design.create", ["name": "!!!", "css": "x"]) == RPCError.invalidParamsCode)
        let path = try await h.call("presenter.design.revealFolder", ["show": false])
        #expect(path["path"]?.stringValue?.hasSuffix("Designs") == true)
        try await h.call("writer.edit.undo")
        #expect(SlideDesignLibrary.shared.design(id) == nil || !FileManager.default.fileExists(atPath: SlideDesignLibrary.userFolder.appendingPathComponent(id + ".css").path))
    }

    // MARK: The model's work

    private func withServer(completions: [String] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer()
        server.completions = completions
        server.fallback = "Karte der Folie."
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    @Test func notesAreWrittenInTheBackground() async throws {
        try await withServer(completions: ["Das ist die Karte."]) { _ in
            let id = try await make()
            try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "# Wasser"])
            try await h.call("presenter.notes.generate", ["deck": .string(id)])
            await h.app.notesTask?.value
            #expect(deck(id).slides[0].notes.isEmpty == false)
            #expect(h.app.notesWriting.isEmpty)
            try await h.call("presenter.notes.generate", ["deck": .string(id), "slides": .array([.string(deck(id).slides[0].id.uuidString)])])
            try await h.call("presenter.notes.cancel")
            #expect(h.app.notesWriting.isEmpty)
            #expect(await h.errorCode("presenter.notes.generate", ["deck": .string(id), "slides": ["fehlt"]]) == RPCError.notFoundCode)
        }
    }

    @Test func intentAndUndoOfAGeneration() async throws {
        #expect(await h.errorCode("presenter.ai.undoGeneration") != nil)
        try await withServer { _ in
            let id = try await make()
            #expect(await h.errorCode("presenter.ai.intent", ["deck": .string(id), "text": "Guten Tag"]) == RPCError.invalidParamsCode)
            h.registry.approval.presenter = { _ in false }
            defer { h.registry.approval.presenter = { _ in true } }
            // Speaking in full screen is the person's call.
            #expect(await h.errorCode("presenter.ai.intent", ["deck": .string(id), "text": "Trag die Präsentation vor"], channel: .chat) == RPCError.deniedCode)
        }
    }

    @Test func thePlanOfADocumentCreatesNothing() async throws {
        let id = try await h.document("# Kapitel eins\n\n## Abschnitt A\n\nText hier.\n\n## Abschnitt B\n\nMehr Text.\n\n# Kapitel zwei\n\n## Abschnitt C\n\nNoch mehr.")
        let count = h.app.documents.count
        let plan = try await h.call("presenter.fromDocument.plan", ["doc": .string(id)])
        #expect(plan["needsModel"] == false)
        #expect((plan["chapters"]?.arrayValue?.count ?? 0) >= 2)
        #expect(h.app.documents.count == count)
        let flat = try await h.document("Nur ein Absatz ohne Gliederung.")
        #expect((try await h.call("presenter.fromDocument.plan", ["doc": .string(flat)]))["needsModel"] == true)
    }

    @Test func handout() async throws {
        let id = try await make()
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "# Wasser\n\n- Fließt"])
        let result = try await h.call("presenter.toHandout", ["deck": .string(id), "tableOfContents": false])
        let handoutID = try #require(result["id"]?.stringValue)
        let handout = try #require(h.app.document(UUID(uuidString: handoutID)!))
        #expect(handout.markdown.contains("Fließt"))
        #expect(!handout.isPresentation)
        try await h.call("presenter.toHandout.cancel")
        h.app.closeDocument()
    }

    // MARK: Playing (without speaking and without full screen; that would take the screen during tests)

    @Test func playingMovesThroughSlides() async throws {
        let player = h.app.presentationPlayer
        player.stop()
        let id = try await make()
        try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Zwei"])
        try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Drei"])
        let started = try await h.call("presenter.play.start", ["deck": .string(id), "from": 2])
        #expect(started["slideIndex"] == 2)
        #expect(started["phase"] == "bereit")
        #expect(h.app.writerTab == .play)
        #expect((try await h.call("presenter.play.next"))["slideIndex"] == 3)
        #expect((try await h.call("presenter.play.previous"))["slideIndex"] == 2)
        #expect((try await h.call("presenter.play.goTo", ["slideIndex": 1]))["slideIndex"] == 1)
        #expect(await h.errorCode("presenter.play.goTo", ["slideIndex": 9]) == RPCError.notFoundCode)

        #expect(await h.errorCode("presenter.play.readNotes") == RPCError.invalidTargetCode)
        try await h.call("presenter.play.pause")
        try await h.call("presenter.play.interrupt")
        #expect((try await h.call("presenter.play.loop", ["on": true]))["repeats"] == true)
        try await h.call("presenter.play.loop", ["on": false])
        #expect((try await h.call("presenter.play.status"))["deck"] == .string(id))
        #expect((try await h.call("presenter.play.stop"))["presenting"] == false)
        h.app.writerTab = .document
        h.app.closeDocument()
    }

    @Test func fullScreenAndSpeakingAsk() async throws {
        let id = try await make()
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("presenter.play.start", ["deck": .string(id), "fullScreen": true]) == RPCError.deniedCode)
        #expect(await h.errorCode("presenter.play.withAI", ["deck": .string(id)]) == RPCError.deniedCode)
        #expect(await h.errorCode("presenter.play.resume") == RPCError.deniedCode)
    }
}
}
