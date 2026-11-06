import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

private extension Dictionary where Key == String, Value == String {
    func decoded<T: Decodable>() throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension ActionSuites {
@MainActor
@Suite("Presenter-Actions", .serialized)
struct PresenterActionTests {
    let h = ActionHarness()

    private func deck(_ title: String = "Vortrag \(UUID().uuidString)") async throws -> String {
        try #require(try await h.call("presenter.deck.create", ["title": .string(title)])["id"]?.stringValue)
    }

    private func deckValue(_ id: String) -> PresentationDeck {
        h.app.document(UUID(uuidString: id)!)!.deck!
    }

    @Test func createReadList() async throws {
        let id = try await deck()
        let read = try await h.call("presenter.deck.read", ["deck": .string(id)])
        #expect(read["slides"]?.arrayValue?.count == 1)
        #expect(read["slides"]?.arrayValue?[0]["role"] == "titel")
        let list = try await h.call("presenter.deck.list")
        #expect(list["decks"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == true)
        let docs = try await h.call("writer.doc.list")
        #expect(docs["documents"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == false)
    }

    @Test func slidesCanBeAddedInOneCallMovedAndDeleted() async throws {
        let id = try await deck()
        let added = try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Eins\n\n- Punkt", "notes": "Sag was"])
        #expect(added["index"] == 2)
        try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Zwei"])
        #expect(deckValue(id).slides.dropFirst().map(\.title) == ["Eins", "Zwei"])
        try await h.call("presenter.slide.move", ["deck": .string(id), "slideIndex": 3, "to": 2])
        #expect(deckValue(id).slides.dropFirst().map(\.title) == ["Zwei", "Eins"])
        #expect(deckValue(id).slides[2].notes == "Sag was")
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 2, "markdown": "# Neu"])
        #expect(deckValue(id).slides[1].title == "Neu")
        try await h.call("presenter.slide.setRole", ["deck": .string(id), "slideIndex": 2, "role": "kapitel"])
        #expect(deckValue(id).slides[1].role == .chapter)
        try await h.call("presenter.slide.delete", ["deck": .string(id), "slideIndex": 2])
        #expect(deckValue(id).slides.count == 2)
        #expect(await h.errorCode("presenter.slide.move", ["deck": .string(id), "slideIndex": 1, "to": 9]) == RPCError.invalidParamsCode)
        try await h.call("presenter.slide.delete", ["deck": .string(id), "slideIndex": 2])
        #expect(await h.errorCode("presenter.slide.delete", ["deck": .string(id), "slideIndex": 1]) == RPCError.invalidTargetCode)
    }

    @Test func aChangeCanBeUndone() async throws {
        let id = try await deck()
        try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Eins"])
        #expect(deckValue(id).slides.count == 2)
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(deckValue(id).slides.count == 1)
    }

    @Test func notes() async throws {
        let id = try await deck()
        try await h.call("presenter.notes.set", ["deck": .string(id), "slideIndex": 1, "text": "Hallo"])
        #expect(try await h.call("presenter.notes.get", ["deck": .string(id), "slideIndex": 1])["text"] == "Hallo")
    }

    @Test func fieldsUseFractions() async throws {
        let id = try await deck()
        let field = try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Merke", "x": .double(0.55), "y": .double(0.2), "width": .double(0.4), "box": "merksatz"])
        let fieldID = try #require(field["id"]?.stringValue)
        let image = try #require(deckValue(id).slides[0].images.first)
        #expect(abs(image.x - 0.55) < 0.001)
        #expect(image.box == .merksatz)
        try await h.call("presenter.field.move", ["deck": .string(id), "field": .string(fieldID), "x": .double(0.1)])
        #expect(abs(deckValue(id).slides[0].images[0].x - 0.1) < 0.001)
        #expect(await h.errorCode("presenter.field.move", ["deck": .string(id), "field": .string(fieldID), "x": 5]) == RPCError.invalidParamsCode)
        let read = try await h.call("presenter.slide.read", ["deck": .string(id), "slideIndex": 1])
        #expect(read["fields"]?.arrayValue?.first?["type"] == "box")
        try await h.call("presenter.field.delete", ["deck": .string(id), "field": .string(fieldID)])
        #expect(deckValue(id).slides[0].images.isEmpty)
    }

    @Test func aPictureComesOnTheSlide() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        let id = try await deck()
        try await h.call("presenter.field.addImage", ["deck": .string(id), "slideIndex": 1, "file": .string(file.path), "caption": "Blau", "width": .double(0.5)])
        let placed = try #require(deckValue(id).slides[0].images.first)
        #expect(placed.caption == "Blau")
        #expect(abs(placed.width - 0.5) < 0.001)
        #expect(abs(placed.height - 0.25 * 720 / 405) < 0.01)
        #expect(await h.errorCode("presenter.field.addImage", ["deck": .string(id), "slideIndex": 1, "file": "/gibt/es/nicht.png"]) == RPCError.notFoundCode)
    }

    @Test func writerActionsWorkOnSlides() async throws {
        let id = try await deck()
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "Der Wasserkreislauf"])
        try await h.call("writer.format.bold", ["deck": .string(id), "slideIndex": 1, "match": "Wasserkreislauf", "state": "on"])
        #expect(deckValue(id).slides[0].markdown.contains("**Wasserkreislauf**"))
        try await h.call("writer.text.insertMarkdown", ["deck": .string(id), "slideIndex": 1, "markdown": "- Verdunstung"])
        #expect(deckValue(id).slides[0].markdown.contains("- Verdunstung"))
        try await h.call("writer.text.insert", ["deck": .string(id), "slideIndex": 1, "notes": true, "text": "Karte"])
        #expect(deckValue(id).slides[0].notes.contains("Karte"))
        let field = try await h.call("presenter.field.addText", ["deck": .string(id), "slideIndex": 1, "markdown": "Im Feld"])
        try await h.call("writer.format.italic", ["deck": .string(id), "slideIndex": 1, "field": field["id"]!, "match": "Feld", "state": "on"])
        #expect(deckValue(id).slides[0].images[0].text?.contains("*Feld*") == true)
        #expect(await h.errorCode("writer.format.bold", ["deck": .string(id), "slideIndex": 9, "all": true]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "all": true]) == RPCError.notFoundCode)
    }

    @Test func designApply() async throws {
        let folder = SlideDesignLibrary.userFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "/* name: Test */ body { background: red; }".write(to: folder.appendingPathComponent("testdesign.css"), atomically: true, encoding: .utf8)
        let list = try await h.call("presenter.designs.list")
        #expect(list["designs"]?.arrayValue?.contains { $0["id"] == "testdesign" } == true)
        let id = try await deck()
        try await h.call("presenter.design.apply", ["deck": .string(id), "design": "testdesign"])
        #expect(deckValue(id).backgrounds.folie?.design == "testdesign")
        #expect(await h.errorCode("presenter.design.apply", ["deck": .string(id), "design": "gibtsnicht"]) == RPCError.notFoundCode)
    }

    @Test func aSlideCanBeSeen() async throws {
        let id = try await deck()
        try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": "# Sichtbar"])
        let render = try await h.call("presenter.slide.render", ["deck": .string(id), "slideIndex": 1])
        #expect(render["mimeType"] == "image/png")
        #expect(render["width"] == 720)
        let data = try #require(render["imageBase64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        #expect(NSImage(data: data)?.isValid == true)
    }

    @Test func pdfExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await deck()
        let result = try await h.call("presenter.export.pdf", ["deck": .string(id)])
        #expect((result["bytes"]?.intValue ?? 0) > 100)
        #expect(FileManager.default.fileExists(atPath: result["path"]?.stringValue ?? ""))
    }

    @Test func aiStatusWithoutARunSaysSo() async throws {
        #expect(try await h.call("presenter.ai.status")["phase"]?.stringValue != nil)
    }
}

@MainActor
@Suite("Citation-Actions", .serialized)
struct CitationActionTests {
    let h = ActionHarness()

    private func source(_ key: String = "test\(UUID().uuidString.prefix(6).lowercased())") async throws -> String {
        let result = try await h.call("citation.source.create", [
            "title": .string("Titel \(key)"), "authors": ["Müller, Anna"], "year": 2020, "citekey": .string(key), "type": "book", "publisher": "Verlag", "tags": ["lernen"],
        ])
        return try #require(result["citekey"]?.stringValue)
    }

    @Test func aSourceFromCreateToFormat() async throws {
        let key = try await source()
        let read = try await h.call("citation.source.read", ["source": .string(key)])
        #expect(read["source"]?["authors"] == ["Müller"])
        #expect(try await h.call("citation.format.inText", ["items": [["key": .string(key), "page": "12"]]])["text"]?.stringValue?.contains("Müller") == true)
        #expect(try await h.call("citation.format.reference", ["source": .string(key)])["text"]?.stringValue?.contains("Verlag") == true)
        #expect(try await h.call("citation.format.bibliography", ["keys": [.string(key)]])["entries"]?.arrayValue?.count == 1)
        #expect(await h.errorCode("citation.format.inText", ["items": [["key": "gibtsnicht"]]]) == RPCError.notFoundCode)
    }

    @Test func searchUsesTheSyntaxAndUmlautsFold() async throws {
        let key = try await source()
        let found = try await h.call("citation.search", ["query": "@mueller #lernen 2020", "shelf": "sources"])
        #expect(found["sources"]?.arrayValue?.contains { $0["citekey"]?.stringValue == key } == true)
        let none = try await h.call("citation.search", ["query": "@mueller 1900"])
        #expect(none["sources"]?.arrayValue?.contains { $0["citekey"]?.stringValue == key } == false)
    }

    @Test func duplicatesAreStopped() async throws {
        let key = try await source()
        let title = try await h.call("citation.source.read", ["source": .string(key)])["source"]?["title"]
        #expect(await h.errorCode("citation.source.create", ["title": title ?? "", "year": 2020, "authors": ["Müller, Anna"]]) == RPCError.ambiguousCode)
    }

    @Test func quotes() async throws {
        let key = try await source()
        let added = try await h.call("citation.quote.add", ["source": .string(key), "exactText": "Ein Satz.", "paraphrase": "Mein Gedanke", "page": "12", "tags": ["a"]])
        let id = try #require(added["id"]?.stringValue)
        #expect(try await h.call("citation.quote.read", ["quote": .string(id)])["exactText"] == "Ein Satz.")
        try await h.call("citation.quote.update", ["quote": .string(id), "page": "13"])
        #expect(try await h.call("citation.quote.read", ["quote": .string(id)])["page"] == "13")
        #expect(try await h.call("citation.quote.list", ["source": .string(key)])["quotes"]?.arrayValue?.count == 1)
        #expect(await h.errorCode("citation.quote.add", ["source": .string(key)]) == RPCError.invalidParamsCode)
        try await h.call("citation.quote.delete", ["quote": .string(id)])
        #expect(await h.errorCode("citation.quote.read", ["quote": .string(id)]) == RPCError.notFoundCode)
    }

    @Test func aDocumentCites() async throws {
        let key = try await source()
        let quote = try await h.call("citation.quote.add", ["source": .string(key), "exactText": "Kurzes Zitat.", "page": "5"])
        let id = try await h.document("Ein Satz hier.")
        try await h.call("writer.citation.insert", ["doc": .string(id), "match": "Satz hier", "key": .string(key), "page": "12"])
        #expect(h.trimmed(id).contains("[@\(key), S. 12]"))
        try await h.call("writer.quote.insert", ["doc": .string(id), "quote": quote["id"]!])
        #expect(h.trimmed(id).contains("„Kurzes Zitat.“ [@\(key), S. 5]"))
        try await h.call("writer.bibliography.insert", ["doc": .string(id)])
        #expect(h.trimmed(id).hasSuffix("[Literatur]"))
        #expect(await h.errorCode("writer.bibliography.insert", ["doc": .string(id)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("writer.citation.insert", ["doc": .string(id), "key": "gibtsnicht"]) == RPCError.notFoundCode)
        let bibliography = try await h.call("citation.format.bibliography", ["doc": .string(id)])
        #expect(bibliography["entries"]?.arrayValue?.count == 1)
    }

    @Test func undoAddingASource() async throws {
        let key = try await source()
        try await h.call("writer.edit.undo")
        #expect(await h.errorCode("citation.source.read", ["source": .string(key)]) == RPCError.notFoundCode)
    }

    // Security: what comes from sources is foreign, and what goes to the net is checked.

    @Test func readingSourcesMarksTheRun() async throws {
        let key = try await source()
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("citation.source.read", ["source": .string(key)], run: run)
        #expect(h.registry.runState(id: run, channel: .cli).hasReadUntrusted)
    }

    @Test func aKnownIdentifierDoesNotAskButAnAddressDoes() throws {
        let context = ActionContext(app: h.app, channel: .cli, run: RunState(channel: .cli), undoGroup: UndoGroup(label: "t"), registry: h.registry)
        #expect(try CitationSourceImportAction.preflight(try ["identifier": "10.1000/xyz"].decoded(), context: context).isInSafePlace)
        #expect(try !CitationSourceImportAction.preflight(try ["identifier": "https://evil.example/?d=1"].decoded(), context: context).isInSafePlace)
    }

    @Test func aFreeAddressAsksBeforeAnythingLeaves() async {
        var seen: [ApprovalRequest] = []
        h.registry.approval.presenter = { seen.append($0); return false }
        #expect(await h.errorCode("citation.source.lookup", ["identifier": "https://evil.example/?d=geheim"]) == RPCError.deniedCode)
        #expect(seen.first?.target == "https://evil.example/?d=geheim")
    }

    @Test func nonsenseIsNoIdentifier() async {
        #expect(await h.errorCode("citation.source.import", ["identifier": "irgendwas"]) == RPCError.invalidParamsCode)
    }
}


@MainActor
@Suite("Stories-Actions", .serialized)
struct StoriesActionTests {
    let h = ActionHarness()

    private func world(_ title: String = "Welt \(UUID().uuidString)") async throws -> String {
        try #require(try await h.call("stories.world.create", ["title": .string(title)])["id"]?.stringValue)
    }

    @Test func aWorldWithParts() async throws {
        let id = try await world()
        try await h.call("stories.world.update", ["world": .string(id), "genre": "Fantasy", "logline": "Eine Reise", "overview": "Langer Überblick"])
        let book = try await h.call("stories.part.add", ["world": .string(id), "level": "book", "title": "Buch 1"])
        let act = try await h.call("stories.part.add", ["world": .string(id), "level": "act", "parent": book["id"]!, "title": "Akt 1"])
        try await h.call("stories.part.add", ["world": .string(id), "level": "chapter", "parent": act["id"]!, "title": "Anfang"])
        #expect(await h.errorCode("stories.part.add", ["world": .string(id), "level": "chapter", "parent": book["id"]!]) == RPCError.invalidTargetCode)

        let tree = try await h.call("stories.part.tree", ["world": .string(id)])
        #expect(tree["parts"]?.arrayValue?.first?["children"]?.arrayValue?.first?["children"]?.arrayValue?.count == 1)

        try await h.call("stories.part.focus.set", ["world": .string(id), "part": "Buch 1/Akt 1", "aspect": "warum", "text": "Weil es muss"])
        try await h.call("stories.part.update", ["world": .string(id), "part": "Buch 1/Akt 1", "status": "draft", "notes": "Notiz"])
        let part = try await h.call("stories.part.read", ["world": .string(id), "part": "Buch 1/Akt 1"])
        #expect(part["focus"]?["warum"] == "Weil es muss")
        #expect(part["status"] == "draft")
        #expect(await h.errorCode("stories.part.read", ["world": .string(id), "part": "Buch 9"]) == RPCError.notFoundCode)
    }

    @Test func overviewSavesContext() async throws {
        let id = try await world()
        try await h.call("stories.world.update", ["world": .string(id), "overview": "Sehr langer Überblick"])
        try await h.call("stories.element.create", ["world": .string(id), "kind": "figure", "name": "Mara", "fields": ["biography": "Lange Geschichte"]])
        let overview = try await h.call("stories.world.read", ["world": .string(id)])
        #expect(overview["overview"] == nil || overview["overview"] == .null)
        #expect(overview["elements"]?["figure"]?.arrayValue?.first?["name"] == "Mara")
        #expect(!overview.jsonLine().contains("Lange Geschichte"))
        #expect(try await h.call("stories.world.read", ["world": .string(id), "depth": "full"])["overview"] == "Sehr langer Überblick")
    }

    @Test(arguments: StoryElementKind.allCases)
    func everyKindOfElement(_ kind: StoryElementKind) async throws {
        let id = try await world()
        let made = try await h.call("stories.element.create", ["world": .string(id), "kind": .string(kind.rawValue), "name": "Eintrag"])
        let reference = "\(kind.rawValue):Eintrag"
        #expect(try await h.call("stories.element.read", ["world": .string(id), "element": .string(reference)])["id"] == made["id"])
        let list = try await h.call("stories.element.list", ["world": .string(id), "kind": .string(kind.rawValue)])
        #expect(list["elements"]?.arrayValue?.count == 1)
        try await h.call("stories.element.update", ["world": .string(id), "element": .string(reference), "fields": ["name": "Anders"]])
        #expect(await h.errorCode("stories.element.read", ["world": .string(id), "element": .string(reference)]) == RPCError.notFoundCode)
        try await h.call("stories.element.delete", ["world": .string(id), "element": .string("\(kind.rawValue):Anders")])
        #expect(try await h.call("stories.element.list", ["world": .string(id)])["elements"]?.arrayValue?.isEmpty == true)
    }

    @Test func fieldsAreCheckedAndIdentityIsProtected() async throws {
        let id = try await world()
        try await h.call("stories.element.create", ["world": .string(id), "kind": "figure", "name": "Mara"])
        try await h.call("stories.element.update", ["world": .string(id), "element": "figure:Mara", "fields": ["biography": "Ihr Leben", "role": "protagonist"]])
        let read = try await h.call("stories.element.read", ["world": .string(id), "element": "figure:Mara"])
        #expect(read["biography"] == "Ihr Leben")
        #expect(read["role"] == "protagonist")
        #expect(await h.errorCode("stories.element.update", ["world": .string(id), "element": "figure:Mara", "fields": ["wolke": "x"]]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("stories.element.update", ["world": .string(id), "element": "figure:Mara", "fields": ["id": "x"]]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("stories.element.read", ["world": .string(id), "element": "wolke:Mara"]) == RPCError.invalidParamsCode)
    }

    @Test func usages() async throws {
        let id = try await world()
        let figure = try await h.call("stories.element.create", ["world": .string(id), "kind": "figure", "name": "Mara"])
        let book = try await h.call("stories.part.add", ["world": .string(id), "level": "book", "title": "Buch"])
        let worldID = UUID(uuidString: id)!
        let partID = UUID(uuidString: book["id"]!.stringValue!)!
        let figureID = UUID(uuidString: figure["id"]!.stringValue!)!
        h.app.stories.update(worldID) { world in
            world.updatePart(partID) { $0.focus.link(figureID, as: .figure) }
        }
        let usages = try await h.call("stories.element.usages", ["world": .string(id), "element": "figure:Mara"])
        #expect(usages["usages"]?.arrayValue?.first?["part"]?.stringValue == partID.uuidString)
    }

    @Test func undoAndDelete() async throws {
        let id = try await world()
        try await h.call("stories.world.update", ["world": .string(id), "genre": "Krimi"])
        try await h.call("writer.edit.undo")
        #expect(h.app.stories.world(UUID(uuidString: id)!)?.genre == "")
        try await h.call("stories.world.delete", ["world": .string(id)])
        #expect(h.app.stories.world(UUID(uuidString: id)!) == nil)
    }
}

@MainActor
@Suite("Chat-Actions", .serialized)
struct ChatActionTests {
    let h = ActionHarness()

    private func withServer(_ script: [FakeLLMServer.Turn] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer(script: script)
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    private func chat(_ extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["title": .string("Chat \(UUID().uuidString)"), "model": "fake", "contextLength": 16384]
        args.merge(extra) { _, new in new }
        return try #require(try await h.call("chat.create", .object(args))["id"]?.stringValue)
    }

    @Test func askReturnsTheAnswer() async throws {
        try await withServer([.text("Die Antwort.")]) { server in
            let id = try await chat()
            let answer = try await h.call("chat.ask", ["chat": .string(id), "text": "Die Frage?"])
            #expect(answer["text"] == "Die Antwort.")
            #expect(answer["role"] == "assistant")
            let read = try await h.call("chat.read", ["chat": .string(id)])
            #expect(read["messages"]?.arrayValue?.map { $0["text"]?.stringValue } == ["Die Frage?", "Die Antwort."])
            #expect(server.requests.count >= 1)
        }
    }

    @Test func sendThenWait() async throws {
        try await withServer([.text("Später.")]) { _ in
            let id = try await chat()
            try await h.call("chat.send", ["chat": .string(id), "text": "Frage"])
            let answer = try await h.call("chat.wait", ["chat": .string(id), "timeout": 20])
            #expect(answer["text"] == "Später.")
            #expect(try await h.call("chat.status", ["chat": .string(id)])["state"] == "idle")
        }
    }

    @Test func listSearchDelete() async throws {
        try await withServer([.text("Ein seltenes Wort: Quetzal.")]) { _ in
            let id = try await chat()
            try await h.call("chat.ask", ["chat": .string(id), "text": "Frage"])
            let list = try await h.call("chat.list")
            #expect(list["chats"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == true)
            let found = try await h.call("chat.search", ["query": "Quetzal"])
            #expect(found["hits"]?.arrayValue?.contains { $0["chat"]?.stringValue == id } == true)
            try await h.call("chat.delete", ["chat": .string(id)])
            #expect(await h.errorCode("chat.read", ["chat": .string(id)]) == RPCError.notFoundCode)
        }
    }

    @Test func aNewChatDoesNotTakeTheScreen() async throws {
        let before = h.app.selectedChatID
        _ = try await chat()
        #expect(h.app.selectedChatID == before)
    }

    @Test func modelsAndSkillsAndPersonas() async throws {
        try await withServer { _ in
            let models = try await h.call("models.list")
            #expect(models["models"]?.arrayValue?.first?["id"] == "fake")
            #expect(models["models"]?.arrayValue?.first?["tools"] == true)
        }
        let name = "Skill \(UUID().uuidString)"
        try await h.call("skill.create", ["name": .string(name), "instructions": "Antworte kurz."])
        #expect(try await h.call("skill.read", ["skill": .string(name)])["instructions"] == "Antworte kurz.")
        #expect(try await h.call("skill.list")["skills"]?.arrayValue?.contains { $0["name"]?.stringValue == name } == true)
        #expect(try await h.call("persona.list")["personas"]?.arrayValue != nil)
    }

    @Test func connectionDataHoldsNoKey() async throws {
        h.app.apiKey = "geheimer-schluessel-123"
        defer { h.app.apiKey = "" }
        for id in ["app.status", "models.list", "actions.list"] {
            #expect(!(try await h.call(id)).jsonLine().contains("geheimer-schluessel-123"))
        }
    }

    // The recursion guard.

    @Test func aChatCannotMessageItself() async throws {
        try await withServer { _ in
            let id = try await chat()
            let code = await h.errorCode("chat.ask", ["chat": .string(id), "text": "Hallo ich"], channel: .chat, run: id)
            #expect(code == RPCError.deniedCode)
            #expect(h.app.chat(UUID(uuidString: id)!)?.messages.isEmpty == true)
        }
    }

    @Test func aChatCanAskAnother() async throws {
        h.registry.approval.setLevel(.allow, channel: .chat, kind: .write, settings: h.app.settings)
        defer { h.registry.approval.setLevel(.ask, channel: .chat, kind: .write, settings: h.app.settings) }
        try await withServer([.text("Von nebenan.")]) { _ in
            let me = try await chat()
            let other = try await chat()
            let answer = try await h.call("chat.ask", ["chat": .string(other), "text": "Frage"], channel: .chat, run: me)
            #expect(answer["text"] == "Von nebenan.")
            #expect(h.app.chatsBeingAskedByActions.isEmpty)
        }
    }

    // Private data.

    private func persona(files: Bool = true) throws -> Persona {
        var persona = Persona(name: "Test \(UUID().uuidString)", biography: "", behavior: "")
        if files {
            persona.files = [PersonaFile(name: "tagebuch.txt", storedName: "tagebuch.txt", byteCount: 0, characterCount: 0)]
        }
        h.app.personas.append(persona)
        return persona
    }

    @Test func privateGroupsAreClosedToMCP() async throws {
        let persona = try persona()
        h.registry.approval.presenter = { _ in true }
        for (action, args) in [
            ("memory.list", ["persona": JSONValue.string(persona.name)]),
            ("memory.profile.get", ["persona": .string(persona.name)]),
            ("persona.files.search", ["persona": .string(persona.name), "query": "x"]),
        ] {
            #expect(await h.errorCode(action, .object(args), channel: .mcp) == RPCError.deniedCode, "\(action)")
        }
    }

    @Test func privateGroupsAskElsewhere() async throws {
        let persona = try persona()
        var asked = 0
        h.registry.approval.presenter = { _ in asked += 1; return true }
        try await h.call("memory.profile.get", ["persona": .string(persona.name)])
        #expect(asked == 1)
    }

    @Test func aChatWithPrivateFilesIsClosedToMCP() async throws {
        let persona = try persona()
        let id = try await chat(["persona": .string(persona.name)])
        #expect(await h.errorCode("chat.ask", ["chat": .string(id), "text": "Was steht im Tagebuch?"], channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.read", ["chat": .string(id)], channel: .mcp) == RPCError.deniedCode)
        #expect(h.app.chat(UUID(uuidString: id)!)?.messages.isEmpty == true)
    }

    @Test func aPlainChatIsOpenToMCP() async throws {
        try await withServer([.text("Hallo.")]) { _ in
            let id = try await chat()
            #expect(try await h.call("chat.ask", ["chat": .string(id), "text": "Hi"], channel: .mcp)["text"] == "Hallo.")
        }
    }

    @Test func aPersonaWithoutFilesIsOpen() async throws {
        try await withServer([.text("Hallo.")]) { _ in
            let plain = try persona(files: false)
            let id = try await chat(["persona": .string(plain.name)])
            #expect(try await h.call("chat.ask", ["chat": .string(id), "text": "Hi"], channel: .mcp)["text"] == "Hallo.")
        }
    }
}
}
