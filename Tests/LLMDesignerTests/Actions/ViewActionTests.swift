import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Ansichten und Anhänge", .serialized)
struct ViewActionTests {
    let h = ActionHarness()

    /// A real text view on a document, as the screen connects it. The test holds on to the controller.
    private func open(_ markdown: String) async throws -> (id: String, controller: WriterEditorController, view: WriterTextView) {
        let id = try await h.document(markdown)
        h.app.selectDocument(UUID(uuidString: id)!)
        let view = WriterTextView.make()
        view.load(markdown: markdown, family: .serif, palette: .dark)
        let controller = WriterEditorController()
        controller.textView = view
        controller.app = h.app
        h.app.documentFind = controller.find
        return (id, controller, view)
    }

    private func close() {
        h.app.documentFind = nil
        h.app.closeDocument()
    }

    // MARK: The editor

    @Test func theEditorHasToBeOpen() async throws {
        h.app.closeDocument()
        #expect(await h.errorCode("writer.selection.get") == RPCError.invalidTargetCode)
        #expect(await h.errorCode("writer.select.all") == RPCError.invalidTargetCode)
        #expect(await h.errorCode("writer.view.panel", ["panel": "outline"]) == RPCError.invalidTargetCode)
        let other = try await h.document("Nicht offen")
        let opened = try await open("Offen")
        defer { close() }
        let caret = opened.view.selectedRange()
        #expect(await h.errorCode("writer.caret.set", ["doc": .string(other), "match": "Nicht"]) == RPCError.invalidTargetCode)
        #expect(opened.view.selectedRange() == caret)
    }

    @Test func selectAndCaret() async throws {
        let opened = try await open("# Titel\n\nDas Wort steht hier.\n\nNoch ein Wort.")
        defer { close() }
        let selected = try await h.call("writer.select", ["match": "Wort", "occurrence": 2])
        #expect(selected["text"] == "Wort")
        #expect(opened.view.selectedRange().length == 4)
        let string = opened.view.string as NSString
        #expect(opened.view.selectedRange().location == string.range(of: "ein Wort").location + 4)

        let selection = try await h.call("writer.selection.get", ["doc": .string(opened.id)])
        #expect(selection["text"] == "Wort")
        #expect(selection["block"] == .string(WriterBlock.paragraph.rawValue))

        try await h.call("writer.caret.set", ["heading": "Titel", "edge": "end"])
        #expect(opened.view.selectedRange() == NSRange(location: 5, length: 0))
        try await h.call("writer.select", ["block": .string(try blockID(opened.id, 1))])
        #expect((string.substring(with: opened.view.selectedRange())) == "Das Wort steht hier.")
        let all = try await h.call("writer.select.all")
        #expect(all["length"] == .int(string.length))
        #expect(await h.errorCode("writer.select", ["match": "Fehlt"]) == RPCError.notFoundCode)
    }

    private func blockID(_ id: String, _ index: Int) throws -> String {
        let chunks = PowerText.chunks(of: h.text(id))
        return WriterBlockInfo.id(index: index, in: chunks)
    }

    @Test func aRepeatedBlockIsFoundInItsPlace() async throws {
        let opened = try await open("Gleich\n\nAnders\n\nGleich")
        defer { close() }
        try await h.call("writer.select", ["block": .string(try blockID(opened.id, 2))])
        #expect(opened.view.selectedRange().location == (opened.view.string as NSString).range(of: "Anders").location + 7)
    }

    @Test func findSteps() async throws {
        let opened = try await open("Eins zwei.\n\nEins drei.")
        defer { close() }
        #expect(await h.errorCode("writer.find.next") == RPCError.invalidParamsCode)
        let first = try await h.call("writer.find.next", ["query": "Eins"])
        #expect(first["matches"] == 2)
        let current = first["current"]?.intValue
        let next = try await h.call("writer.find.next")
        #expect(next["current"]?.intValue != current)
        let back = try await h.call("writer.find.previous")
        #expect(back["current"]?.intValue == current)
        _ = opened
    }

    @Test func jumps() async throws {
        let opened = try await open("# Kapitel\n\nText mit Stelle.")
        defer { close() }
        try await h.call("writer.jump.heading", ["heading": "Kapitel"])
        #expect(opened.view.selectedRange().location == 0)
        #expect(await h.errorCode("writer.jump.heading", ["heading": "Fehlt"]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.jump.bookmark", ["bookmark": "lz-fehlt"]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.jump.comment", ["comment": "k-fehlt"]) == RPCError.notFoundCode)

        let range = (opened.view.string as NSString).range(of: "Stelle")
        opened.view.setSelectedRange(range)
        let comment = try #require(opened.view.addComment(text: "Hm"))
        opened.view.setSelectedRange(NSRange(location: 0, length: 0))
        try await h.call("writer.jump.comment", ["comment": .string(comment)])
        #expect(opened.view.selectedRange().location == range.location)
        let selection = try await h.call("writer.selection.get")
        #expect(selection["comment"] == .string(comment))

        let bookmarked = try await open("Davor. \(WriterBookmark(title: "Merker").openingTag)Hier</span> danach.")
        defer { close() }
        try await h.call("writer.jump.bookmark", ["bookmark": "Merker"])
        #expect((bookmarked.view.string as NSString).substring(with: bookmarked.view.selectedRange()) == "Hier")
    }

    @Test func revealAndHighlightLeaveTheCaret() async throws {
        let opened = try await open("Eins\n\nZwei")
        defer { close() }
        opened.view.setSelectedRange(NSRange(location: 2, length: 0))
        try await h.call("writer.view.reveal", ["match": "Zwei"])
        try await h.call("writer.view.highlight", ["match": "Zwei"])
        #expect(opened.view.selectedRange().location == 2)
        #expect(await h.errorCode("writer.view.highlight", ["match": "Fehlt"]) == RPCError.notFoundCode)
    }

    @Test func tabsAndPanels() async throws {
        _ = try await open("Text")
        defer { close() }
        try await h.call("writer.view.tab", ["tab": "analysis"])
        #expect(h.app.writerTab == .analysis)
        try await h.call("writer.view.tab", ["tab": "document"])
        #expect(h.app.writerTab == .document)

        try await h.call("writer.view.panel", ["panel": "comments"])
        #expect(h.app.documentPanelTab == .comments)
        #expect(h.app.isPanelShown)
        try await h.call("writer.view.panel", ["panel": "power"])
        #expect(h.app.power.isOn)
        try await h.call("writer.view.panel", ["panel": "bookmarks"])
        #expect(h.app.documentPanelTab == .bookmarks)
        #expect(!h.app.power.isOn)
        try await h.call("writer.view.panel", ["panel": "analysis"])
        #expect(h.app.writerTab == .analysis)
        h.app.writerTab = .document
    }

    // MARK: Attachments

    /// A neutral PDF with a line of text.
    private func pdfFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testartikel-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 20, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func source() async throws -> String {
        let made = try await h.call("citation.source.create", ["type": "article", "title": .string("Artikel \(UUID().uuidString)"), "authors": ["Muster, Erika"], "year": 2020])
        return try #require(made["citekey"]?.stringValue)
    }

    @Test func attachmentsAreAddedReadAndRemoved() async throws {
        let file = try pdfFile("Wasser fliesst bergab")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = try await source()
        #expect(await h.errorCode("citation.attachment.read", ["source": .string(key)]) == RPCError.notFoundCode)

        let added = try await h.call("citation.attachment.add", ["source": .string(key), "file": .string(file.path)])
        let name = try #require(added["id"]?.stringValue)
        let list = try await h.call("citation.attachment.list", ["source": .string(key)])
        #expect(list["attachments"]?.arrayValue?.first?["file"] == .string(name))
        #expect((list["attachments"]?.arrayValue?.first?["bytes"]?.intValue ?? 0) > 0)

        let read = try await h.call("citation.attachment.read", ["source": .string(key)], run: "anhang-lauf")
        #expect(read["text"]?.stringValue?.contains("Wasser fliesst bergab") == true)
        #expect(read["nextStart"] == nil)
        // Whatever a PDF says is foreign.
        #expect(h.registry.runState(id: "anhang-lauf", channel: .cli).hasReadUntrusted)

        let part = try await h.call("citation.attachment.read", ["source": .string(key), "limit": 6])
        #expect(part["text"] == "Wasser")
        #expect(part["nextStart"] == 6)
        let rest = try await h.call("citation.attachment.read", ["source": .string(key), "start": 7, "limit": 7])
        #expect(rest["text"] == "fliesst")

        #expect(await h.errorCode("citation.attachment.read", ["source": .string(key), "file": "fehlt.pdf"]) == RPCError.notFoundCode)
        try await h.call("citation.attachment.remove", ["source": .string(key), "file": .string(name)])
        #expect((try await h.call("citation.attachment.list", ["source": .string(key)]))["attachments"] == [])
    }

    @Test func aFileFromAModelNeedsConsent() async throws {
        let file = try pdfFile("Geheim")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = try await source()
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("citation.attachment.add", ["source": .string(key), "file": .string(file.path)], channel: .chat) == RPCError.deniedCode)
        #expect((try await h.call("citation.attachment.list", ["source": .string(key)]))["attachments"] == [])
    }

    @Test func openingAnAttachmentNeedsConsent() async throws {
        let file = try pdfFile("Text")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = try await source()
        try await h.call("citation.attachment.add", ["source": .string(key), "file": .string(file.path)])
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("citation.attachment.open", ["source": .string(key)]) == RPCError.deniedCode)
    }

    // MARK: Citation Studio

    @Test func studioViews() async throws {
        let key = try await source()
        let library = h.app.citations
        let id = try #require(library.source(citekey: key)?.id)
        defer { h.app.closeCitationStudio() }

        try await h.call("citation.studio.open", ["source": .string(key)])
        #expect(h.app.citationStudioOpen)
        #expect(h.app.citationStudioRequest == id)

        try await h.call("citation.view.shelf", ["shelf": "quotes"])
        #expect(h.app.citationStudioCommand == .shelf(.quotes))
        let model = CitationStudioModel()
        model.apply(.shelf(.quotes), library: library)
        #expect(model.mode == .quotes)

        try await h.call("citation.view.filterTags", ["tags": ["#lernen", "gedächtnis"]])
        #expect(h.app.citationStudioCommand == .filterTags(["lernen", "gedächtnis"]))
        model.apply(.filterTags(["lernen", "gedächtnis"]), library: library)
        #expect(model.searchText == "#lernen #gedächtnis")

        try await h.call("citation.view.select", ["source": .string(key)])
        #expect(h.app.citationStudioCommand == .select(source: id))
        model.apply(.select(source: id), library: library)
        #expect(model.mode == .sources)
        #expect(model.selectedSourceID == id)
        #expect(await h.errorCode("citation.view.select") == RPCError.invalidParamsCode)

        let quote = try await h.call("citation.quote.add", ["source": .string(key), "exactText": "Ein Satz."])
        try await h.call("citation.view.select", ["quote": .string(try #require(quote["id"]?.stringValue))])
        #expect(h.app.citationStudioCommand == .select(source: id))

        try await h.call("citation.studio.close")
        #expect(!h.app.citationStudioOpen)
        // A view that needs the studio opens it.
        try await h.call("citation.view.shelf", ["shelf": "sources"])
        #expect(h.app.citationStudioOpen)
    }

    // MARK: Presenter

    @Test func slideImageGoesToTheExportFolder() async throws {
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Bilder \(UUID().uuidString)")])["id"]?.stringValue)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("folie.png")
        let result = try await h.call("presenter.export.slideImage", ["deck": .string(deck), "slideIndex": 1, "path": .string(target.path), "scale": 1])
        #expect(result["path"] == .string(target.path))
        #expect(NSImage(contentsOf: target) != nil)
        #expect(await h.errorCode("presenter.export.slideImage", ["deck": .string(deck), "slideIndex": 1, "path": .string(target.path)]) == RPCError.invalidTargetCode)
        try await h.call("presenter.export.slideImage", ["deck": .string(deck), "slideIndex": 1, "path": .string(target.path), "overwrite": true])
        #expect(await h.errorCode("presenter.export.slideImage", ["deck": .string(deck), "slideIndex": 9]) == RPCError.notFoundCode)
    }

    @Test func printingAsksFirst() async throws {
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Druck \(UUID().uuidString)")])["id"]?.stringValue)
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("presenter.print", ["deck": .string(deck)]) == RPCError.deniedCode)
    }

    @Test func presenterPanels() async throws {
        h.app.closeDocument()
        #expect(await h.errorCode("presenter.view.panel", ["panel": "outline"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("presenter.view.backgroundPicker") == RPCError.invalidTargetCode)
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Panel \(UUID().uuidString)")])["id"]?.stringValue)
        h.app.selectDocument(UUID(uuidString: deck)!)
        defer { h.app.closeDocument() }
        try await h.call("presenter.view.panel", ["panel": "bookmarks"])
        #expect(h.app.documentPanelTab == .bookmarks)
        try await h.call("presenter.view.backgroundPicker")
        #expect(h.app.presenterBackgroundPickerOpen)
        try await h.call("presenter.view.backgroundPicker", ["open": false])
        #expect(!h.app.presenterBackgroundPickerOpen)
    }
}
}
