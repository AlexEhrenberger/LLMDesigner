import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Unterordner, Stapel, Folien-Passung, Verknüpfungen", .serialized)
struct SidebarAndSlideFitTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    private func chat() async throws -> String {
        try #require(try await h.call("chat.create", ["title": .string("Chat \(UUID().uuidString)")])["id"]?.stringValue)
    }

    private func folder(_ id: String) -> Folder? { h.app.chatFolders.first { $0.id.uuidString == id } }

    private func deck() async throws -> String {
        try #require(try await h.call("presenter.deck.create", ["title": .string("Vortrag \(UUID().uuidString)")])["id"]?.stringValue)
    }

    private func deckValue(_ id: String) -> PresentationDeck { h.app.document(UUID(uuidString: id)!)!.deck! }

    // MARK: Subfolders

    @Test func subfoldersGoOneLevelDeep() async throws {
        let parentName = "Roman \(UUID().uuidString)"
        let parent = try #require(try await h.call("folder.create", ["section": "chats", "name": .string(parentName)])["id"]?.stringValue)
        let child = try #require(try await h.call("folder.create", ["section": "chats", "name": "Kapitel", "parent": .string(parent)])["id"]?.stringValue)
        #expect(folder(child)?.parentID?.uuidString == parent)
        // Nothing goes into a subfolder, and skill folders don't nest.
        #expect(await h.errorCode("folder.create", ["section": "chats", "name": "Tiefer", "parent": .string(child)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("folder.create", ["section": "skills", "name": "S", "parent": .string(parent)]) == RPCError.invalidParamsCode)
        // The app's own path puts a subfolder's subfolder beside it.
        let beside = h.app.createFolder(for: .chats, parent: UUID(uuidString: child))
        h.app.renamingID = nil
        #expect(h.app.chatFolders.first { $0.id == beside }?.parentID?.uuidString == parent)
        h.app.deleteFolder(beside, includingContents: false)

        let inside = try await chat()
        try await h.call("chat.move", ["chat": .string(inside), "folder": .string("\(parentName)/Kapitel")])
        #expect(h.app.chat(UUID(uuidString: inside)!)?.folderID?.uuidString == child)
        let sections = h.app.chatFolderSections
        let section = try #require(sections.first { $0.folder.id.uuidString == parent })
        #expect(section.children.map(\.folder.id.uuidString) == [child])
        #expect(section.totalCount == 1)
        #expect(!sections.contains { $0.folder.id.uuidString == child })
        let list = try await h.call("folder.list")
        #expect(list["folders"]?.arrayValue?.first { $0["id"]?.stringValue == child }?["parent"]?.stringValue == parent)

        // A folder with subfolders stays at the top.
        let other = try #require(try await h.call("folder.create", ["section": "chats", "name": .string("Andere \(UUID().uuidString)")])["id"]?.stringValue)
        #expect(await h.errorCode("folder.move", ["folder": .string(parent), "parent": .string(other)]) == RPCError.invalidTargetCode)
        try await h.call("folder.move", ["folder": .string(child), "parent": .string(other)])
        #expect(folder(child)?.parentID?.uuidString == other)
        try await h.call("folder.move", ["folder": .string(child), "parent": .string(parent)])

        // Deleting the subfolder keeps its chat in the parent; deleting the parent makes subfolders top-level.
        let second = try #require(try await h.call("folder.create", ["section": "chats", "name": "Zweites", "parent": .string(parent)])["id"]?.stringValue)
        try await h.call("folder.delete", ["folder": .string(child)])
        #expect(h.app.chat(UUID(uuidString: inside)!)?.folderID?.uuidString == parent)
        try await h.call("folder.delete", ["folder": .string(parent)])
        #expect(folder(second)?.parentID == nil)
        #expect(h.app.chat(UUID(uuidString: inside)!)?.folderID == nil)
        try await h.call("folder.delete", ["folder": .string(second)])
        try await h.call("folder.delete", ["folder": .string(other)])
    }

    // MARK: Stacks

    private func entry(_ title: String, presentation: Bool? = nil, updated: Date = Date()) -> SidebarEntry {
        guard let presentation else {
            var chat = Chat(title: title)
            chat.updatedAt = updated
            return .chat(chat)
        }
        var document = presentation ? WriterDocument.newPresentation() : WriterDocument()
        document.title = title
        document.updatedAt = updated
        return .document(document)
    }

    @Test func stacksByType() {
        let stacks = SidebarStacking.byType([entry("A"), entry("B", presentation: false), entry("C", presentation: true), entry("D")])
        #expect(stacks.map(\.title) == ["Dokumente", "Präsentationen", "Chats"])
        #expect(stacks.map(\.entries.count) == [1, 1, 2])
        #expect(SidebarStacking.byType([entry("A")]).map(\.title) == ["Chats"])
    }

    @Test func stacksByRelevance() {
        let calendar = Calendar.current
        let now = Date()
        func ago(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }
        let busy = entry("Viel", updated: ago(1))
        let once = entry("Einmal", updated: ago(10))
        let resting = entry("Ruht", updated: ago(60))
        let old = entry("Alt", updated: ago(400))
        // Opened on three days in the last two weeks.
        let activity = [busy.id.uuidString: [ago(5), ago(3)].map { SidebarStacking.day($0) }]
        let stacks = SidebarStacking.byRelevance([old, resting, once, busy], activity: activity, now: now)
        #expect(stacks.map(\.title) == ["Gerade in Arbeit", "Ab und zu", "Ruht seit Wochen", "Seit Ewigkeiten unberührt"])
        #expect(stacks.map { $0.entries.map(\.id) } == [[busy.id], [once.id], [resting.id], [old.id]])

        var file = SidebarStackFile()
        let id = UUID()
        #expect(SidebarStacking.note(id, on: now, in: &file))
        #expect(!SidebarStacking.note(id, on: now, in: &file))
        #expect(SidebarStacking.note(id, on: calendar.date(byAdding: .day, value: 61, to: now)!, in: &file))
        // Days older than two months drop out.
        #expect(file.activity[id.uuidString]?.count == 1)
    }

    @Test func topicStacksFromTheModelsAnswer() throws {
        let entries = [entry("Steuer 2025"), entry("Steuer 2026", presentation: false), entry("Drache", presentation: false), entry("Neu")]
        let items = entries.map { TopicStackPrompt.Item(id: $0.id, kind: "Chat", title: "", snippet: "") }
        let old = TopicStack(name: "Steuern", itemIDs: [])
        let answer = try JSONDecoder().decode(TopicStackPrompt.Answer.self, from: Data("""
        {"stapel":[{"name":"steuern","eintraege":[1,2,2,9]},{"name":"Fantasy","eintraege":[3,1]},{"name":"Leer","eintraege":[]}]}
        """.utf8))
        let topics = TopicStackPrompt.stacks(from: answer, items: items, previous: [old], merging: false)
        // The old name and id stay; a number is used once; unknown numbers and empty stacks drop out.
        #expect(topics.map(\.name) == ["Steuern", "Fantasy"])
        #expect(topics[0].id == old.id)
        #expect(topics[0].itemIDs == [entries[0].id, entries[1].id])
        #expect(topics[1].itemIDs == [entries[2].id])
        let stacks = SidebarStacking.byTopic(entries, topics: topics)
        #expect(stacks.map(\.title) == ["Fantasy", "Steuern", "Noch nicht einsortiert"])
        #expect(stacks.last?.entries.map(\.id) == [entries[3].id])

        // Merging adds the new item to an existing stack.
        let more = try JSONDecoder().decode(TopicStackPrompt.Answer.self, from: Data(#"{"stapel":[{"name":"Fantasy","eintraege":[1]}]}"#.utf8))
        let merged = TopicStackPrompt.stacks(from: more, items: [items[3]], previous: topics, merging: true)
        #expect(merged.first { $0.name == "Fantasy" }?.itemIDs == [entries[2].id, entries[3].id])
        #expect(merged.count == 2)
    }

    @Test func theArrangementIsKeptInTheLibrary() {
        let app = h.app
        let before = (app.sidebarArrangement, app.stackMode)
        defer { app.setSidebarArrangement(before.0, mode: before.1) }
        app.setSidebarArrangement(.stacks, mode: .relevance)
        #expect(app.settings.string(forKey: "sidebarArrangement") == "stacks")
        #expect(app.settings.string(forKey: "sidebarStackMode") == "relevance")
        app.toggleStack("relevance.0")
        #expect(app.isStackExpanded("relevance.0"))
        app.toggleStack("relevance.0")
        #expect(!app.isStackExpanded("relevance.0"))
    }

    // MARK: Backgrounds

    @Test func aBackgroundCanBeWishedForAsLightOrDark() async throws {
        let light = try await h.call("presenter.designs.list", ["background": "hell"])
        let lights = light["designs"]?.arrayValue ?? []
        #expect(!lights.isEmpty)
        #expect(lights.allSatisfy { $0["background"] == "hell" })

        let made = try await h.call("presenter.deck.create", ["title": .string("Hell \(UUID().uuidString)"), "background": "hell"])
        let id = try #require(made["id"]?.stringValue)
        let design = try #require(made["design"]?.stringValue)
        #expect(SlideDesignLibrary.shared.design(design)?.backgroundBrightness == "hell")
        #expect(deckValue(id).backgrounds.folie?.design == design)

        let dark = try await h.call("presenter.design.apply", ["deck": .string(id), "background": "dunkel"])
        let darkDesign = try #require(dark["id"]?.stringValue)
        #expect(SlideDesignLibrary.shared.design(darkDesign)?.backgroundBrightness == "dunkel")
        #expect(await h.errorCode("presenter.design.apply", ["deck": .string(id)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("presenter.deck.create", ["design": "gibtsnicht"]) == RPCError.notFoundCode)
    }

    @Test func presentingAfterTheModelWroteTheSlidesIsOneCall() throws {
        let descriptor = try #require(h.registry.descriptor("presenter.ai.createDeck"))
        #expect(descriptor.input.properties?["present"] != nil)
        #expect(descriptor.input.properties?["withNotes"] != nil)
        #expect(descriptor.input.properties?["background"] != nil)
    }

    // MARK: Fit

    private let longSlide = "# Viel zu viel\n\n" + (1...16).map { "- Punkt \($0) mit einem Satz, der schon für sich allein recht lang ist" }.joined(separator: "\n")

    @Test func anOverfullSlideIsReportedAndCanBeSplit() async throws {
        let id = try await deck()
        let short = try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": "# Kurz\n\n- Eins\n- Zwei"])
        #expect(short["fit"]?["fits"] == true)

        let long = try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": .string(longSlide)])
        #expect(long["fit"]?["fits"] == false)
        #expect((long["fit"]?["overflowPercent"]?.intValue ?? 0) > 0)
        #expect(long["fit"]?["hint"]?.stringValue?.isEmpty == false)
        let longID = try #require(long["id"]?.stringValue)
        let check = try await h.call("presenter.slides.checkFit", ["deck": .string(id)])
        #expect(check["allFit"] == false)
        #expect(check["overflowing"]?.arrayValue?.map { $0["id"]?.stringValue } == [longID])

        let split = try await h.call("presenter.slide.split", ["deck": .string(id), "slide": .string(longID)])
        #expect(split["fit"]?["fits"] == true)
        let slides = deckValue(id).slides
        #expect(slides.count >= 4)
        #expect(slides.dropFirst(3).allSatisfy { $0.markdown.hasPrefix("# Viel zu viel (Forts.)") })
        // No point is lost.
        let points = slides.flatMap { $0.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- Punkt") } }
        #expect(points.count == 16)
        #expect(try await h.call("presenter.slides.checkFit", ["deck": .string(id)])["allFit"] == true)
        #expect(await h.errorCode("presenter.slide.split", ["deck": .string(id), "slideIndex": 1]) == nil)
    }

    @Test func settingTextCanSplitAtOnce() async throws {
        let id = try await deck()
        let result = try await h.call("presenter.slide.setText", ["deck": .string(id), "slideIndex": 1, "markdown": .string(longSlide), "splitOverflow": true])
        #expect(result["fit"]?["fits"] == true)
        #expect(deckValue(id).slides.count > 1)
        let added = try await h.call("presenter.slide.add", ["deck": .string(id), "markdown": .string(longSlide), "splitOverflow": true])
        #expect((added["continuations"]?.arrayValue?.count ?? 0) > 0)
    }

    // MARK: Stories

    @Test func documentsCanBelongToAnyPartOfAWorld() async throws {
        let world = try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("stories.outline.create", ["world": .string(world), "outline": [["title": "Buch", "children": [["title": "Akt", "children": [["title": "Kapitel", "children": [["title": "Szene"]]]]]]]]])
        let doc = try await h.document("# Recherche")
        let talk = try await deck()
        try await h.call("stories.documents.link", ["world": .string(world), "part": "Buch/Akt/Kapitel/Szene", "doc": .string(doc)])
        try await h.call("stories.documents.link", ["world": .string(world), "part": "Buch/Akt/Kapitel/Szene", "doc": .string(doc)])
        try await h.call("stories.documents.link", ["world": .string(world), "doc": .string(talk)])
        let value = h.app.stories.world(UUID(uuidString: world)!)!
        let scene = try value.actionPart("Buch/Akt/Kapitel/Szene")
        #expect(scene.linkedDocuments.map(\.uuidString) == [doc])
        #expect(value.linkedDocuments.map(\.uuidString) == [talk])

        let all = try await h.call("stories.documents.list", ["world": .string(world)])
        #expect(all["documents"]?.arrayValue?.compactMap { $0["id"]?.stringValue }.sorted() == [doc, talk].sorted())
        let inBook = try await h.call("stories.documents.list", ["world": .string(world), "part": "Buch"])
        #expect(inBook["documents"]?.arrayValue?.first?["linkedAt"]?.stringValue?.hasSuffix("Szene") == true)
        #expect(try await h.call("stories.part.read", ["world": .string(world), "part": "Buch/Akt/Kapitel/Szene"])["documents"] == [.string(doc)])

        try await h.call("stories.documents.unlink", ["world": .string(world), "part": "Buch/Akt/Kapitel/Szene", "doc": .string(doc)])
        #expect(try h.app.stories.world(UUID(uuidString: world)!)!.actionPart("Buch/Akt/Kapitel/Szene").linkedDocuments.isEmpty)
        #expect(await h.errorCode("stories.documents.link", ["world": .string(world), "doc": "Gibt es nicht"]) == RPCError.notFoundCode)
    }

    @Test func linksSurviveTheFile() throws {
        var part = StoryPart(level: .section, title: "S")
        part.linkedDocuments = [UUID()]
        let decoded = try JSONDecoder().decode(StoryPart.self, from: JSONEncoder().encode(part))
        #expect(decoded.linkedDocuments == part.linkedDocuments)
        // Older files without the field still load.
        let old = try JSONDecoder().decode(StoryPart.self, from: Data(#"{"id":"\#(UUID().uuidString)","level":"act"}"#.utf8))
        #expect(old.linkedDocuments.isEmpty)
    }

    // MARK: Catalog

    @Test func theCatalogShowsTheCommandOfAnAction() throws {
        let descriptor = try #require(h.registry.descriptor("presenter.slides.checkFit"))
        let plain = ActionDescriptor(id: "presenter.slides.checkFit", summary: "x", kind: .read, security: descriptor.security, input: descriptor.input)
        #expect(ActionCatalogDetail.command(plain) == "llmd presenter slides check-fit <deck>")
        #expect(ActionCatalogView.matches(descriptor, "über den Rand"))
        #expect(!ActionCatalogView.matches(descriptor, "Zauberei"))
        #expect(ActionCatalogView.moduleTitle("stories") == "Stories Studio")
    }
}
}
