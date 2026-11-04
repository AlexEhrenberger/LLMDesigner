import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Stories: Struktur, Elemente, Zeitleisten, Galerien", .serialized)
struct StoriesMoreActionTests {
    let h = ActionHarness()

    private func make() async throws -> String {
        try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
    }

    private func world(_ id: String) -> StoryWorld { h.app.stories.world(UUID(uuidString: id)!)! }

    @discardableResult
    private func element(_ id: String, _ kind: String, _ name: String) async throws -> String {
        try #require(try await h.call("stories.element.create", ["world": .string(id), "kind": .string(kind), "name": .string(name)])["id"]?.stringValue)
    }

    private func pictureFile() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func items(_ value: JSONValue) -> [String] {
        (value["items"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    // MARK: World and structure

    @Test func calendarAndExport() async throws {
        let id = try await make()
        try await h.call("stories.world.calendar", ["world": .string(id), "unit": "Zeitalter", "suffix": "n. d. F."])
        #expect(world(id).calendar.unit == "Zeitalter")
        try await h.call("stories.world.update", ["world": .string(id), "logline": "Eine Reise"])
        try await element(id, "figure", "Mara")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bibel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("bibel.md")
        try await h.call("stories.world.export", ["world": .string(id), "path": .string(target.path)])
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("Eine Reise"))
        #expect(text.contains("### Mara"))
        #expect(await h.errorCode("stories.world.export", ["world": .string(id), "path": .string(target.path)]) == RPCError.invalidTargetCode)
        let json = folder.appendingPathComponent("welt.json")
        try await h.call("stories.world.export", ["world": .string(id), "format": "json", "path": .string(json.path)])
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) is [String: Any])
    }

    @Test func outlineInOneCall() async throws {
        let id = try await make()
        let made = try await h.call("stories.outline.create", ["world": .string(id), "outline": [[
            "title": "Buch", "children": [["title": "Akt", "children": [["title": "Kapitel", "was": "Sie reist", "status": "draft"]]]],
        ]]])
        #expect(made["created"] == 3)
        let chapter = try #require(world(id).books.first?.children.first?.children.first)
        #expect(chapter.level == .chapter)
        #expect(chapter.status == .draft)
        #expect(chapter.focus.text(.event) == "Sie reist")
        #expect(await h.errorCode("stories.outline.create", ["world": .string(id), "parent": "Buch/Akt/Kapitel", "outline": [["title": "A", "children": [["title": "B"]]]]]) == RPCError.invalidParamsCode)
        #expect(world(id).books.first?.children.first?.children.first?.children.isEmpty == true)
    }

    @Test func partsChange() async throws {
        let id = try await make()
        try await h.call("stories.outline.create", ["world": .string(id), "outline": [
            ["title": "Eins", "children": [["title": "A1", "children": [["title": "K1"], ["title": "K2"]]]]],
            ["title": "Zwei", "children": [["title": "A2"]]],
        ]])
        try await h.call("stories.part.bookKind", ["world": .string(id), "part": "Zwei", "value": "novella"])
        #expect(world(id).books[1].bookKind == .novella)
        #expect(await h.errorCode("stories.part.bookKind", ["world": .string(id), "part": "Eins/A1", "value": "main"]) == RPCError.invalidTargetCode)
        try await h.call("stories.part.status", ["world": .string(id), "part": "Eins/A1/K1", "value": "done"])
        #expect(world(id).books[0].children[0].children[0].status == .done)

        try await element(id, "figure", "Mara")
        try await h.call("stories.part.pov", ["world": .string(id), "part": "Eins/A1/K1", "figure": "Mara"])
        #expect(world(id).books[0].children[0].children[0].povFigureID != nil)
        try await h.call("stories.part.pov", ["world": .string(id), "part": "Eins/A1/K1"])
        #expect(world(id).books[0].children[0].children[0].povFigureID == nil)
        #expect(await h.errorCode("stories.part.pov", ["world": .string(id), "part": "Eins", "figure": "Mara"]) == RPCError.invalidTargetCode)

        try await h.call("stories.part.focus.link", ["world": .string(id), "part": "Eins", "aspect": "mitWem", "element": "Mara"])
        #expect(world(id).books[0].focus.ids(.figure).count == 1)
        try await h.call("stories.part.focus.unlink", ["world": .string(id), "part": "Eins", "aspect": "mitWem", "element": "Mara"])
        #expect(world(id).books[0].focus.ids(.figure).isEmpty)

        try await h.call("stories.part.move", ["world": .string(id), "part": "Eins/A1/K2", "by": -1])
        #expect(world(id).books[0].children[0].children.map(\.title) == ["K2", "K1"])
        #expect(await h.errorCode("stories.part.move", ["world": .string(id), "part": "Eins/A1/K2", "by": -1]) == RPCError.invalidTargetCode)

        try await h.call("stories.part.reparent", ["world": .string(id), "part": "Eins/A1/K2", "parent": "Zwei/A2"])
        #expect(world(id).books[1].children[0].children.map(\.title) == ["K2"])
        #expect(world(id).books[0].children[0].children.map(\.title) == ["K1"])
        #expect(await h.errorCode("stories.part.reparent", ["world": .string(id), "part": "Eins/A1/K1", "parent": "Zwei"]) == RPCError.invalidTargetCode)
        try await h.call("writer.edit.undo")
        #expect(world(id).books[0].children[0].children.map(\.title) == ["K2", "K1"])
    }

    @Test func manuscripts() async throws {
        let id = try await make()
        try await h.call("stories.outline.create", ["world": .string(id), "outline": [["title": "Buch", "children": [["title": "Akt", "children": [["title": "Kapitel"]]]]]]])
        let part = "Buch/Akt/Kapitel"
        let first = try await h.call("stories.part.manuscript", ["world": .string(id), "part": .string(part)])
        #expect(first["created"] == true)
        let doc = try #require(first["doc"]?.stringValue)
        #expect(h.trimmed(doc).hasSuffix("Kapitel"))
        #expect(h.app.selectedDocumentID?.uuidString != doc)
        #expect((try await h.call("stories.part.read", ["world": .string(id), "part": .string(part)]))["manuscript"] == .string(doc))

        // The second time it is the same document, with what has been written.
        try await h.call("writer.text.insertMarkdown", ["doc": .string(doc), "markdown": "Es war einmal."])
        let second = try await h.call("stories.part.manuscript", ["world": .string(id), "part": .string(part), "open": true])
        #expect(second["created"] == false)
        #expect(second["doc"] == .string(doc))
        #expect(h.app.selectedDocumentID?.uuidString == doc)
        h.app.closeDocument()

        // Deleting the part leaves the text alone.
        try await h.call("stories.part.delete", ["world": .string(id), "part": .string(part)])
        #expect(h.text(doc).contains("Es war einmal."))

        // A deleted document gets a new one; undo takes it back and the link with it.
        try await h.call("stories.outline.create", ["world": .string(id), "parent": "Buch/Akt", "outline": [["title": "Neu"]]])
        let made = try #require(try await h.call("stories.part.manuscript", ["world": .string(id), "part": "Buch/Akt/Neu"])["doc"]?.stringValue)
        try await h.call("writer.doc.delete", ["doc": .string(made)])
        let again = try await h.call("stories.part.manuscript", ["world": .string(id), "part": "Buch/Akt/Neu"])
        #expect(again["created"] == true)
        #expect(again["doc"] != .string(made))
        try await h.call("writer.edit.undo")
        #expect(world(id).books[0].children[0].children.first { $0.title == "Neu" }?.manuscriptID?.uuidString == made)
        #expect(h.app.document(UUID(uuidString: try #require(again["doc"]?.stringValue))!) == nil)
    }

    @Test func aMarkedRunMakesAForeignManuscript() async throws {
        let id = try await make()
        try await h.call("stories.outline.create", ["world": .string(id), "outline": [["title": "Buch"]]])
        // Reading a world marks the run.
        try await h.call("stories.world.read", ["world": .string(id)], run: "manuskript-lauf")
        let made = try await h.call("stories.part.manuscript", ["world": .string(id), "part": "Buch"], run: "manuskript-lauf")
        let doc = try #require(made["doc"]?.stringValue)
        #expect(h.app.document(UUID(uuidString: doc)!)?.provenance == .foreign)
    }

    @Test func aPartWithAManuscriptSurvivesTheFile() throws {
        var part = StoryPart(level: .chapter, title: "Eins")
        part.manuscriptID = UUID()
        let data = try JSONEncoder().encode(part)
        #expect(try JSONDecoder().decode(StoryPart.self, from: data).manuscriptID == part.manuscriptID)
        // Files from before this field stay readable.
        let id = UUID().uuidString
        let old = try JSONDecoder().decode(StoryPart.self, from: Data("{\"id\":\"\(id)\",\"level\":\"chapter\",\"title\":\"Alt\"}".utf8))
        #expect(old.title == "Alt")
        #expect(old.manuscriptID == nil)
    }

    // MARK: Elements

    @Test func elementsFromTextAndSearch() async throws {
        let id = try await make()
        try await h.call("stories.element.createFromText", ["world": .string(id), "kind": "figure", "text": "Mara\nSie wuchs am Meer auf."])
        #expect(world(id).figures.first?.name == "Mara")
        #expect(world(id).figures.first?.biography == "Sie wuchs am Meer auf.")
        #expect(await h.errorCode("stories.element.createFromText", ["world": .string(id), "kind": "figure", "text": " "]) == RPCError.invalidParamsCode)
        try await h.call("stories.element.createFromText", ["world": .string(id), "kind": "place", "text": "Hafen"])
        let hits = try await h.call("stories.element.search", ["world": .string(id), "query": "Meer"], run: "suche")
        #expect(items(hits) == ["Mara"])
        #expect(h.registry.runState(id: "suche", channel: .cli).hasReadUntrusted)
    }

    @Test func figuresAndTheirRelations() async throws {
        let id = try await make()
        try await element(id, "figure", "Mara")
        try await element(id, "figure", "Nora")
        try await h.call("stories.figure.personality", ["world": .string(id), "figure": "Mara", "energy": .double(0.5), "energyNote": "still", "neuroticism": .double(0.8), "stressNote": "zieht sich zurück"])
        let profile = try #require(world(id).figures.first { $0.name == "Mara" }?.personality)
        #expect(profile.values[.energy] == 0.5)
        #expect(profile.notes[.energy] == "still")
        #expect(profile.stressNote == "zieht sich zurück")

        let relation = try #require(try await h.call("stories.figure.relation.add", ["world": .string(id), "figure": "Mara", "target": "figure:Nora", "attitude": 2, "label": "Schwester"])["id"]?.stringValue)
        let incoming = try await h.call("stories.figure.relations.incoming", ["world": .string(id), "element": "figure:Nora"])
        #expect(incoming["relations"]?.arrayValue?.first?["figure"] == "Mara")
        #expect(incoming["relations"]?.arrayValue?.first?["attitude"] == 2)
        try await h.call("stories.figure.relation.update", ["world": .string(id), "figure": "Mara", "relation": .string(relation), "attitude": -1])
        #expect(world(id).figures.first { $0.name == "Mara" }?.relations.first?.attitude == -1)
        try await h.call("stories.figure.relation.remove", ["world": .string(id), "figure": "Mara", "relation": .string(relation)])
        #expect(world(id).figures.first { $0.name == "Mara" }?.relations.isEmpty == true)
        #expect(await h.errorCode("stories.figure.relation.remove", ["world": .string(id), "figure": "Mara", "relation": .string(relation)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("stories.figure.relation.add", ["world": .string(id), "figure": "Mara", "target": "Nora"]) == RPCError.invalidParamsCode)

        let scene = try #require(try await h.call("stories.figure.scene.add", ["world": .string(id), "figure": "Mara", "kind": "quote", "text": "Niemals."])["id"]?.stringValue)
        try await h.call("stories.figure.scene.update", ["world": .string(id), "figure": "Mara", "scene": .string(scene), "text": "Immer."])
        #expect(world(id).figures.first { $0.name == "Mara" }?.scenes.first?.text == "Immer.")
        try await h.call("stories.figure.scene.remove", ["world": .string(id), "figure": "Mara", "scene": .string(scene)])
        #expect(world(id).figures.first { $0.name == "Mara" }?.scenes.isEmpty == true)
        #expect(await h.errorCode("stories.figure.scene.update", ["world": .string(id), "figure": "Mara", "scene": .string(scene)]) == RPCError.notFoundCode)
    }

    @Test func picturesAndVideosOfElements() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await make()
        for (kind, name) in [("figure", "Mara"), ("place", "Hafen"), ("species", "Elben"), ("fact", "Wahrheit")] { try await element(id, kind, name) }
        for (kind, name) in [("figure", "Mara"), ("place", "Hafen"), ("species", "Elben"), ("fact", "Wahrheit")] {
            let added = try await h.call("stories.\(kind).image.add", .object(["world": .string(id), kind: .string(name), "file": .string(file.path), "caption": "Bild"]))
            #expect(added["id"]?.stringValue?.isEmpty == false)
            try await h.call("stories.\(kind).image.remove", .object(["world": .string(id), kind: .string(name)]))
            #expect(await h.errorCode("stories.\(kind).image.remove", .object(["world": .string(id), kind: .string(name)])) == RPCError.notFoundCode)
        }
        #expect(await h.errorCode("stories.figure.image.add", ["world": .string(id), "figure": "Mara", "file": "/gibt/es/nicht.png"]) == RPCError.notFoundCode)
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("stories.figure.image.add", ["world": .string(id), "figure": "Mara", "file": .string(file.path)], channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("stories.figure.video.add", ["world": .string(id), "figure": "Mara", "file": .string(file.path)], channel: .chat) == RPCError.deniedCode)
    }

    @Test func videosAreOnlyVideos() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await make()
        try await element(id, "figure", "Mara")
        #expect(await h.errorCode("stories.figure.video.add", ["world": .string(id), "figure": "Mara", "file": "/gibt/es/nicht.mov"]) == RPCError.notFoundCode)
        var figure = try #require(world(id).figures.first)
        figure.videos = [StoryVideo(fileName: "a.mov")]
        let edited = figure
        h.app.stories.update(UUID(uuidString: id)!) { $0.updateElement(StoryFigure.self, edited.id) { $0 = edited } }
        try await h.call("stories.figure.video.remove", ["world": .string(id), "figure": "Mara"])
        #expect(world(id).figures.first?.videos.isEmpty == true)
    }

    @Test func places() async throws {
        let id = try await make()
        try await element(id, "place", "Land")
        try await element(id, "place", "Stadt")
        try await element(id, "figure", "Mara")
        try await h.call("stories.place.parent", ["world": .string(id), "place": "Stadt", "parent": "Land"])
        #expect(items(try await h.call("stories.place.subplaces", ["world": .string(id), "place": "Land"])) == ["Stadt"])
        // A place can't lie in what lies in it.
        #expect(await h.errorCode("stories.place.parent", ["world": .string(id), "place": "Land", "parent": "Stadt"]) == RPCError.invalidTargetCode)
        #expect(!items(try await h.call("stories.place.possibleParents", ["world": .string(id), "place": "Land"])).contains("Stadt"))
        try await h.call("stories.place.parent", ["world": .string(id), "place": "Stadt"])
        #expect(world(id).places.first { $0.name == "Stadt" }?.parentID == nil)

        try await h.call("stories.place.residents", ["world": .string(id), "place": "Stadt", "add": ["Mara"]])
        #expect(world(id).places.first { $0.name == "Stadt" }?.residentIDs.count == 1)
        try await h.call("stories.place.residents", ["world": .string(id), "place": "Stadt", "remove": ["Mara"]])
        #expect(world(id).places.first { $0.name == "Stadt" }?.residentIDs.isEmpty == true)
        #expect(await h.errorCode("stories.place.residents", ["world": .string(id), "place": "Stadt", "add": ["Fehlt"]]) == RPCError.notFoundCode)
    }

    @Test func events() async throws {
        let id = try await make()
        try await element(id, "event", "Krieg")
        try await element(id, "event", "Frieden")
        try await element(id, "place", "Hafen")
        try await element(id, "figure", "Mara")
        try await h.call("stories.event.places", ["world": .string(id), "event": "Krieg", "add": ["Hafen"]])
        try await h.call("stories.event.figures", ["world": .string(id), "event": "Krieg", "add": ["Mara"]])
        let war = try #require(world(id).events.first { $0.name == "Krieg" })
        #expect(war.placeIDs.count == 1)
        #expect(war.figureIDs.count == 1)

        try await h.call("stories.event.cause.add", ["world": .string(id), "event": "Frieden", "target": "Krieg"])
        #expect(items(try await h.call("stories.event.causes", ["world": .string(id), "event": "Frieden"])) == ["Krieg"])
        #expect(items(try await h.call("stories.event.followers", ["world": .string(id), "event": "Krieg"])) == ["Frieden"])
        #expect(await h.errorCode("stories.event.cause.add", ["world": .string(id), "event": "Krieg", "target": "Krieg"]) == RPCError.invalidParamsCode)
        try await h.call("stories.event.cause.remove", ["world": .string(id), "event": "Frieden", "target": "Krieg"])
        #expect(items(try await h.call("stories.event.causes", ["world": .string(id), "event": "Frieden"])) == [])

        let consequence = try #require(try await h.call("stories.event.consequence.add", ["world": .string(id), "event": "Krieg", "area": "war", "reach": "long", "text": "Hunger", "affected": ["figure:Mara"], "followEvent": "Frieden"])["id"]?.stringValue)
        var first = try #require(world(id).events.first { $0.name == "Krieg" }?.consequences.first)
        #expect(first.area == .war)
        #expect(first.affected.first?.kind == .figure)
        #expect(first.followEventID != nil)
        try await h.call("stories.event.consequence.update", ["world": .string(id), "event": "Krieg", "consequence": .string(consequence), "text": "Not", "reach": "medium"])
        first = try #require(world(id).events.first { $0.name == "Krieg" }?.consequences.first)
        #expect(first.text == "Not")
        #expect(first.reach == .medium)
        try await h.call("stories.event.consequence.remove", ["world": .string(id), "event": "Krieg", "consequence": .string(consequence)])
        #expect(await h.errorCode("stories.event.consequence.remove", ["world": .string(id), "event": "Krieg", "consequence": .string(consequence)]) == RPCError.notFoundCode)

        try await h.call("stories.event.knowledge", ["world": .string(id), "event": "Krieg", "knowledge": "secret", "knownBy": ["Mara"]])
        let known = try #require(world(id).events.first { $0.name == "Krieg" })
        #expect(known.knowledge == .secret)
        #expect(known.knownByIDs.count == 1)
    }

    @Test func reasonsAndPurposes() async throws {
        let id = try await make()
        try await element(id, "reason", "Warum")
        let assumption = try #require(try await h.call("stories.reason.assumption.add", ["world": .string(id), "reason": "Warum", "text": "Alle lügen", "validity": "mistaken"])["id"]?.stringValue)
        let premise = try #require(try await h.call("stories.reason.premise.add", ["world": .string(id), "reason": "Warum", "text": "Sie war dort"])["id"]?.stringValue)
        var reason = try #require(world(id).reasons.first)
        #expect(reason.assumptions.first?.validity == .mistaken)
        #expect(reason.premises.first?.text == "Sie war dort")
        try await h.call("stories.reason.statement.update", ["world": .string(id), "reason": "Warum", "statement": .string(premise), "validity": "holds"])
        reason = try #require(world(id).reasons.first)
        #expect(reason.premises.first?.validity == .holds)
        try await h.call("stories.reason.statement.remove", ["world": .string(id), "reason": "Warum", "statement": .string(assumption)])
        reason = try #require(world(id).reasons.first)
        #expect(reason.assumptions.isEmpty)
        #expect(await h.errorCode("stories.reason.statement.remove", ["world": .string(id), "reason": "Warum", "statement": .string(assumption)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("stories.reason.statement.update", ["world": .string(id), "reason": "Warum", "statement": .string(assumption), "text": "x"]) == RPCError.notFoundCode)

        try await h.call("stories.outline.create", ["world": .string(id), "outline": [["title": "Buch"], ["title": "Zwei"]]])
        try await element(id, "purpose", "Spannung")
        try await h.call("stories.purpose.setup", ["world": .string(id), "purpose": "Spannung", "add": ["Buch"]])
        #expect(items(try await h.call("stories.purpose.openPromises", ["world": .string(id)])) == ["Spannung"])
        try await h.call("stories.purpose.payoff", ["world": .string(id), "purpose": "Spannung", "add": ["Zwei"]])
        #expect(items(try await h.call("stories.purpose.openPromises", ["world": .string(id)])) == [])
    }

    @Test func speciesAndFacts() async throws {
        let id = try await make()
        let species = try await element(id, "species", "Elben")
        try await element(id, "place", "Wald")
        try await element(id, "figure", "Mara")
        try await h.call("stories.species.habitat", ["world": .string(id), "species": "Elben", "add": ["Wald"]])
        #expect(world(id).species.first?.habitatPlaceIDs.count == 1)
        try await h.call("stories.element.update", ["world": .string(id), "element": "figure:Mara", "fields": ["speciesID": .string(species)]])
        #expect(items(try await h.call("stories.species.members", ["world": .string(id), "species": "Elben"])) == ["Mara"])

        try await element(id, "fact", "Alter")
        try await element(id, "fact", "Größe")
        try await h.call("stories.fact.tag", ["world": .string(id), "fact": "Alter", "add": ["#Leben", "Zahl"]])
        try await h.call("stories.fact.tag", ["world": .string(id), "fact": "Alter", "remove": ["Zahl"]])
        #expect(world(id).facts.first { $0.name == "Alter" }?.tags == ["Leben"])
        try await h.call("stories.fact.link", ["world": .string(id), "fact": "Alter", "element": "figure:Mara"])
        #expect(items(try await h.call("stories.element.facts", ["world": .string(id), "element": "figure:Mara"])) == ["Alter"])
        try await h.call("stories.fact.unlink", ["world": .string(id), "fact": "Alter", "element": "figure:Mara"])
        #expect(items(try await h.call("stories.element.facts", ["world": .string(id), "element": "figure:Mara"])) == [])
        #expect(items(try await h.call("stories.fact.filter", ["world": .string(id), "tags": ["leben"]])) == ["Alter"])
        #expect(items(try await h.call("stories.fact.filter", ["world": .string(id), "query": "Größe"])) == ["Größe"])
    }

    // MARK: Timelines and galleries

    @Test func timelines() async throws {
        let id = try await make()
        try await element(id, "event", "Krieg")
        let entry = try #require(try await h.call("stories.timeline.pin", ["world": .string(id), "element": "event:Krieg", "start": 10, "end": 20, "note": "lang"])["id"]?.stringValue)
        var read = try await h.call("stories.timeline.read", ["world": .string(id)])
        #expect(read["entries"]?.arrayValue?.first?["name"] == "Krieg")
        #expect(read["entries"]?.arrayValue?.first?["note"] == "lang")
        let pins = try await h.call("stories.element.pins", ["world": .string(id), "element": "event:Krieg"])
        #expect(pins["pins"]?.arrayValue?.first?["entry"] == .string(entry))

        try await h.call("stories.timeline.update", ["world": .string(id), "entry": .string(entry), "start": 12])
        #expect(world(id).timeline.entries.first?.start == 12)
        try await h.call("stories.timeline.unpin", ["world": .string(id), "entry": .string(entry)])
        #expect(world(id).timeline.entries.isEmpty)
        #expect(await h.errorCode("stories.timeline.unpin", ["world": .string(id), "entry": .string(entry)]) == RPCError.notFoundCode)

        try await h.call("stories.outline.create", ["world": .string(id), "outline": [["title": "Buch", "children": [["title": "Akt", "children": [["title": "Kap", "children": [["title": "Stück"]]]]]]]]])
        try await h.call("stories.timeline.scale", ["world": .string(id), "part": "Buch", "unit": "Tag"])
        #expect(world(id).books.first?.timeline.scale?.unit == "Tag")
        try await h.call("stories.timeline.pin", ["world": .string(id), "part": "Buch", "element": "event:Krieg", "start": 1])
        read = try await h.call("stories.timeline.read", ["world": .string(id), "part": "Buch"])
        #expect(read["unit"] == "Tag")
        #expect(await h.errorCode("stories.timeline.read", ["world": .string(id), "part": "Buch/Akt/Kap/Stück"]) == RPCError.invalidTargetCode)
        try await h.call("stories.timeline.scale", ["world": .string(id), "unit": "Mond"])
        #expect(world(id).calendar.unit == "Mond")
    }

    @Test func galleries() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await make()
        try await h.call("stories.outline.create", ["world": .string(id), "outline": [["title": "Buch", "children": [["title": "Akt"]]]]])
        try await h.call("stories.gallery.add", ["world": .string(id), "file": .string(file.path), "caption": "Karte"])
        #expect(world(id).gallery.first?.caption == "Karte")
        try await h.call("stories.gallery.update", ["world": .string(id), "caption": "Landkarte"])
        #expect((try await h.call("stories.gallery.list", ["world": .string(id)]))["images"]?.arrayValue?.first?["caption"] == "Landkarte")
        try await h.call("stories.gallery.remove", ["world": .string(id)])
        #expect(world(id).gallery.isEmpty)
        #expect(await h.errorCode("stories.gallery.remove", ["world": .string(id)]) == RPCError.notFoundCode)

        try await h.call("stories.gallery.add", ["world": .string(id), "part": "Buch/Akt", "file": .string(file.path)])
        // A book's list holds what its acts have.
        #expect((try await h.call("stories.gallery.list", ["world": .string(id), "part": "Buch"]))["images"]?.arrayValue?.count == 1)
    }

    @Test func aGeneratedPictureNeedsDrawThings() async throws {
        let id = try await make()
        try await element(id, "reason", "Warum")
        #expect(await h.errorCode("stories.image.generate", ["world": .string(id), "prompt": " "]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("stories.image.generate", ["world": .string(id), "prompt": "x", "element": "reason:Warum"]) == RPCError.invalidTargetCode)
        let center = h.app.imageGeneration
        let address = center.address
        // A port where nothing listens, so a running Draw Things isn't bothered.
        center.address = "http://127.0.0.1:9"
        defer { center.address = address }
        #expect(await h.errorCode("stories.image.generate", ["world": .string(id), "prompt": "a lighthouse"]) == RPCError.unavailableCode)
        #expect(world(id).gallery.isEmpty)
    }

    @Test func studio() async throws {
        let id = try await make()
        let mara = try await element(id, "figure", "Mara")
        defer { h.app.closeStoriesStudio() }
        #expect(await h.errorCode("stories.studio.open", ["element": "figure:Mara"]) == RPCError.invalidParamsCode)
        try await h.call("stories.studio.open", ["world": .string(id), "element": "figure:Mara"])
        #expect(h.app.storiesStudioOpen)
        let command = try #require(h.app.storiesStudioCommand)
        #expect(command.world.uuidString == id)
        #expect(command.element?.id.uuidString == mara)
        let model = StoriesStudioModel()
        model.apply(command, library: h.app.stories)
        #expect(model.worldID?.uuidString == id)
        #expect(model.page == .elements(.figure))
        #expect(model.selected[.figure]?.uuidString == mara)
        try await h.call("stories.studio.close")
        #expect(!h.app.storiesStudioOpen)
    }
}
}
