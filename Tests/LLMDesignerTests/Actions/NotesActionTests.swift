import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Notes: Notes, ToDos, Zuordnungen", .serialized)
struct NotesActionTests {
    let h = ActionHarness()

    /// A new note with a unique title, so tests don't meet each other's.
    private func make(_ markdown: String? = nil, extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["title": .string("Note \(UUID().uuidString)")]
        if let markdown { args["markdown"] = .string(markdown) }
        args.merge(extra) { $1 }
        return try #require(try await h.call("notes.note.create", .object(args))["id"]?.stringValue)
    }

    private func note(_ id: String) -> Note? { h.app.notes.note(UUID(uuidString: id)!) }

    private let website = """
    - [ ] Konzept
      - [ ] Zielgruppe
      - [x] Gliederung
    - [ ] Design
    - [ ] Impressum
    """

    // MARK: Notes

    @Test func createReadUpdateAndDelete() async throws {
        let id = try await make(website, extra: ["style": "glas", "text": "Hosting klären"])
        #expect(note(id)?.style == .glass)
        #expect(note(id)?.progress == NoteProgress(done: 1, total: 4))

        let read = try await h.call("notes.note.read", ["note": .string(id)])
        #expect(read["progress"]?["percent"] == 25)
        #expect(read["todos"]?[0]?["text"] == "Konzept")
        #expect(read["todos"]?[0]?["progress"] == "1/2")
        #expect(read["todos"]?[0]?["children"]?[1]?["number"] == "1.2")
        #expect(read["text"] == "Hosting klären")
        let markdown = try await h.call("notes.note.read", ["note": .string(id), "format": "markdown"])
        #expect(markdown["markdown"]?.stringValue?.contains("  - [x] Gliederung") == true)
        #expect(markdown["todos"] == nil)

        let title = try #require(note(id)?.title)
        #expect(try await h.call("notes.note.read", ["note": .string(title)])["id"] == .string(id))

        try await h.call("notes.note.update", ["note": .string(id), "style": "rakete", "appendText": "Domain"])
        #expect(note(id)?.style == .rocket)
        #expect(note(id)?.text == "Hosting klären\nDomain")
        #expect(await h.errorCode("notes.note.update", ["note": .string(id), "style": "laserschwert"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("notes.note.update", ["note": .string(id)]) == RPCError.invalidParamsCode)
        try await h.call("writer.edit.undo")
        #expect(note(id)?.style == .glass)

        try await h.call("notes.note.delete", ["note": .string(id)])
        #expect(note(id) == nil)
        #expect(await h.errorCode("notes.note.read", ["note": .string(id)]) == RPCError.notFoundCode)
        try await h.call("writer.edit.undo")
        #expect(note(id)?.todos.count == 3)
    }

    @Test func listFiltersByOwner() async throws {
        let doc = try await h.document("# Bachelorarbeit\n")
        let world = try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("stories.outline.create", ["world": .string(world), "outline": [["title": "Buch", "children": [["title": "Akt"]]]]])

        let ofDoc = try await make(extra: ["doc": .string(doc)])
        let ofPart = try await make(extra: ["world": .string(world), "part": "Buch/Akt"])
        let general = try await make()

        let byDoc = try await h.call("notes.note.list", ["doc": .string(doc)])
        #expect(byDoc["notes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [ofDoc])
        #expect(byDoc["notes"]?[0]?["owners"]?[0]?["kind"] == "dokument")
        let byPart = try await h.call("notes.note.list", ["world": .string(world), "part": "Buch/Akt"])
        #expect(byPart["notes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [ofPart])
        #expect(byPart["notes"]?[0]?["owners"]?[0]?["title"]?.stringValue?.hasSuffix("› Akt") == true)
        let byWorld = try await h.call("notes.note.list", ["world": .string(world)])
        #expect(byWorld["notes"]?.arrayValue?.isEmpty == true, "Die ganze Welt ist ein eigener Besitzer")
        let generalOnes = try await h.call("notes.note.list", ["general": true])
        let generalIDs = generalOnes["notes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(generalIDs.contains(general))
        #expect(!generalIDs.contains(ofDoc))
        #expect(await h.errorCode("notes.note.list", ["doc": .string(doc), "world": .string(world)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("notes.note.list", ["part": "Buch"]) == RPCError.invalidParamsCode)

        // A note made for a document takes the document's name when it has none of its own.
        let named = try #require(try await h.call("notes.note.create", ["doc": .string(doc)])["title"]?.stringValue)
        #expect(named == h.app.document(UUID(uuidString: doc)!)?.displayTitle)
    }

    @Test func attachAndDetach() async throws {
        let id = try await make()
        let doc = try await h.document("# Konzept\n")
        try await h.call("notes.note.attach", ["note": .string(id), "doc": .string(doc)])
        #expect(note(id)?.owners == [.document(UUID(uuidString: doc)!)])
        let again = try await h.call("notes.note.attach", ["note": .string(id), "doc": .string(doc)])
        #expect(again["message"] == "Gehörte schon dazu.")
        #expect(h.app.notes.notes(for: .document(UUID(uuidString: doc)!)).map(\.id.uuidString) == [id])
        try await h.call("notes.note.detach", ["note": .string(id), "doc": .string(doc)])
        #expect(note(id)?.owners.isEmpty == true)
        #expect(await h.errorCode("notes.note.detach", ["note": .string(id), "doc": .string(doc)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("notes.note.attach", ["note": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func progressAndRemovingWhatIsDone() async throws {
        let id = try await make(website)
        let progress = try await h.call("notes.note.progress", ["note": .string(id)])
        #expect(progress["label"] == "1 von 4 erledigt")
        #expect(progress["groups"]?[0]?["progress"]?["done"] == 1)
        #expect(progress["nextOpen"]?[0] == "1.1 Zielgruppe")
        let removed = try await h.call("notes.note.removeDone", ["note": .string(id)])
        #expect(removed["message"] == "1 ToDo entfernt.")
        #expect(note(id)?.progress == NoteProgress(done: 0, total: 3))
    }

    // MARK: To-dos

    @Test func addAndAddMany() async throws {
        let id = try await make(website)
        let made = try await h.call("notes.todo.add", ["note": .string(id), "text": "Wettbewerb", "parent": "1"])
        #expect(made["number"] == "1.3")
        let after = try await h.call("notes.todo.add", ["note": .string(id), "text": "Domain", "after": "Design", "done": true])
        #expect(after["number"] == "3")
        #expect(note(id)?.todos.map(\.text) == ["Konzept", "Design", "Domain", "Impressum"])
        #expect(note(id)?.todos[2].isDone == true)
        #expect(await h.errorCode("notes.todo.add", ["note": .string(id), "text": "X", "parent": "1", "after": "2"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("notes.todo.add", ["note": .string(id), "text": "X", "parent": "9"]) == RPCError.notFoundCode)

        let many = try await h.call("notes.todo.addMany", ["note": .string(id), "parent": "Design",
                                                           "todos": [["text": "Farben", "children": [["text": "Grün", "done": true]]], ["text": "Schrift"]]])
        #expect(many["created"] == 3)
        #expect(note(id)?.todo(atNumber: "2")?.children.map(\.text) == ["Farben", "Schrift"])
        #expect(note(id)?.todo(atNumber: "2.1.1")?.isDone == true)
        try await h.call("notes.todo.addMany", ["note": .string(id), "markdown": "- [ ] Start\n  - [ ] Live"])
        #expect(note(id)?.todos.last?.children.first?.text == "Live")
        #expect(await h.errorCode("notes.todo.addMany", ["note": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func updateCheckAndDelete() async throws {
        let id = try await make(website)
        try await h.call("notes.todo.update", ["note": .string(id), "todo": "Impressum", "text": "Impressum und Datenschutz"])
        #expect(note(id)?.todos[2].text == "Impressum und Datenschutz")

        let checked = try await h.call("notes.todo.check", ["note": .string(id), "todo": "Konzept/Zielgruppe"])
        #expect(checked["progress"]?["done"] == 2)
        #expect(note(id)?.todos[0].isDone == true, "Beide Unter-ToDos erledigt: das Konzept auch")
        try await h.call("notes.todo.check", ["note": .string(id), "todo": "1", "done": false])
        #expect(note(id)?.progress.done == 0)
        try await h.call("notes.todo.check", ["note": .string(id), "todo": "Konzept"])
        #expect(note(id)?.progress.done == 2)

        let deleted = try await h.call("notes.todo.delete", ["note": .string(id), "todo": "1"])
        #expect(deleted["progress"]?["total"] == 2)
        #expect(note(id)?.todos.map(\.text) == ["Design", "Impressum und Datenschutz"])
        try await h.call("writer.edit.undo")
        #expect(note(id)?.todos.count == 3)
        #expect(await h.errorCode("notes.todo.check", ["note": .string(id), "todo": "Gibt es nicht"]) == RPCError.notFoundCode)
    }

    @Test func todosAreFoundByTextOnlyWhenItIsUnique() async throws {
        let id = try await make("- [ ] Prüfen\n  - [ ] Prüfen\n- [ ] Anders")
        #expect(await h.errorCode("notes.todo.check", ["note": .string(id), "todo": "Prüfen"]) == RPCError.ambiguousCode)
        try await h.call("notes.todo.check", ["note": .string(id), "todo": "Prüfen/Prüfen"])
        #expect(note(id)?.todos[0].isDone == true)
        let todo = try #require(note(id)?.todos[1].id.uuidString)
        try await h.call("notes.todo.check", ["note": .string(id), "todo": .string(todo)])
        #expect(note(id)?.progress.isComplete == true)
    }

    @Test func moveIndentAndCollapse() async throws {
        let id = try await make(website)
        try await h.call("notes.todo.move", ["note": .string(id), "todo": "Impressum", "by": -1])
        #expect(note(id)?.todos.map(\.text) == ["Konzept", "Impressum", "Design"])
        #expect(await h.errorCode("notes.todo.move", ["note": .string(id), "todo": "Konzept", "by": -1]) == RPCError.invalidTargetCode)
        try await h.call("notes.todo.move", ["note": .string(id), "todo": "Design", "parent": "Konzept", "index": 1])
        #expect(note(id)?.todos[0].children.map(\.text) == ["Design", "Zielgruppe", "Gliederung"])
        #expect(await h.errorCode("notes.todo.move", ["note": .string(id), "todo": "Konzept", "parent": "Konzept/Design"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("notes.todo.move", ["note": .string(id), "todo": "Konzept"]) == RPCError.invalidParamsCode)
        try await h.call("notes.todo.move", ["note": .string(id), "todo": "Konzept/Design", "top": true])
        #expect(note(id)?.todos.map(\.text) == ["Konzept", "Impressum", "Design"])

        try await h.call("notes.todo.indent", ["note": .string(id), "todo": "Design"])
        #expect(note(id)?.todos[1].children.map(\.text) == ["Design"])
        try await h.call("notes.todo.indent", ["note": .string(id), "todo": "Impressum/Design", "direction": "out"])
        #expect(note(id)?.todos.count == 3)
        #expect(await h.errorCode("notes.todo.indent", ["note": .string(id), "todo": "Konzept"]) == RPCError.invalidTargetCode)

        try await h.call("notes.todo.collapse", ["note": .string(id), "todo": "Konzept"])
        #expect(note(id)?.todos[0].isCollapsed == true)
        try await h.call("notes.todo.collapse", ["note": .string(id), "collapsed": false])
        #expect(note(id)?.todos[0].isCollapsed == false)
        #expect(await h.errorCode("notes.todo.collapse", ["note": .string(id), "todo": "Design"]) == RPCError.invalidTargetCode)
    }

    @Test func todosLinkToDocumentsAndPresentations() async throws {
        let id = try await make("- [ ] Konzept ausarbeiten\n- [ ] Vortrag")
        let doc = try await h.document("# Konzept\n")
        try await h.call("notes.todo.link", ["note": .string(id), "todo": "Konzept ausarbeiten", "doc": .string(doc)])
        #expect(note(id)?.todos[0].documents == [UUID(uuidString: doc)!])
        let read = try await h.call("notes.note.read", ["note": .string(id)])
        #expect(read["todos"]?[0]?["documents"]?[0] == .string(doc))
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Vortrag \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("notes.todo.link", ["note": .string(id), "todo": "2", "doc": .string(deck)])
        #expect(note(id)?.todos[1].documents.count == 1)
        try await h.call("notes.todo.unlink", ["note": .string(id), "todo": "1", "doc": .string(doc)])
        #expect(note(id)?.todos[0].documents.isEmpty == true)
        #expect(await h.errorCode("notes.todo.unlink", ["note": .string(id), "todo": "1", "doc": .string(doc)]) == RPCError.invalidTargetCode)
    }

    // MARK: Displays, studio, rules

    @Test func stylesStudioAndSecurity() async throws {
        let styles = try await h.call("notes.styles.list")
        #expect(styles["styles"]?.arrayValue?.count == NoteProgressStyle.allCases.count)
        #expect(styles["styles"]?[2]?["id"] == "glas")

        let id = try await make(website)
        try await h.call("notes.studio.open", ["note": .string(id), "todo": "Design"])
        #expect(h.app.notesStudioOpen)
        #expect(h.app.activeApplication == .notes)
        #expect(h.app.notesStudioCommand?.note?.uuidString == id)
        #expect(h.app.notesStudioCommand?.focusTodo == note(id)?.todos[1].id)
        try await h.call("notes.studio.close")
        #expect(!h.app.notesStudioOpen)
        h.app.notesStudioCommand = nil
        #expect(await h.errorCode("notes.studio.open", ["todo": "1"]) == RPCError.invalidParamsCode)

        // Notes can be written by agents, so reading one counts as foreign; deleting is destructive.
        #expect(h.registry.descriptor("notes.note.read")?.security.readsUntrusted == true)
        #expect(h.registry.descriptor("notes.note.delete")?.kind == .destructive)
        #expect(h.registry.descriptor("notes.todo.delete")?.kind == .destructive)
        for member in ChatToolGroups.members["notes.core"] ?? [] {
            #expect(h.registry.descriptor(member) != nil, "\(member) fehlt in der Registry")
        }
    }
}
}

/// `result["todos"]?[0]?["text"]`: reading nested results the way they look.
private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
