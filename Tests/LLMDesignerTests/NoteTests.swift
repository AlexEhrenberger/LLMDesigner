import Testing
import Foundation
@testable import LLMDesigner

@Suite("Notes: ToDos, Fortschritt, Speicherformat")
struct NoteTests {
    /// "Webseite" with two main to-dos: Konzept (Zielgruppe, Gliederung) and Design (Farben).
    private func website() -> Note {
        var note = Note(title: "Webseite")
        note.todos = [
            NoteTodo(text: "Konzept", children: [NoteTodo(text: "Zielgruppe"), NoteTodo(text: "Gliederung")]),
            NoteTodo(text: "Design", children: [NoteTodo(text: "Farben")]),
            NoteTodo(text: "Impressum"),
        ]
        // Whole seconds, as the file keeps them.
        note.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        note.updatedAt = Date(timeIntervalSince1970: 1_800_000_060)
        return note
    }

    // MARK: Progress and ticking off

    @Test func progressCountsTheTodosWithoutTodosOfTheirOwn() {
        var note = website()
        #expect(note.progress == NoteProgress(done: 0, total: 4))
        let zielgruppe = note.todos[0].children[0].id
        note.setDone(zielgruppe, true)
        #expect(note.progress.done == 1)
        #expect(note.progress.percent == 25)
        #expect(note.todos[0].progress == NoteProgress(done: 1, total: 2))
        #expect(!note.todos[0].isDone)
        #expect(note.progress.label == "1 von 4 erledigt")
        #expect(Note().progress.label == "Noch keine ToDos")
    }

    @Test func aParentFollowsItsTodos() {
        var note = website()
        let konzept = note.todos[0].id
        note.setDone(note.todos[0].children[0].id, true)
        note.setDone(note.todos[0].children[1].id, true)
        #expect(note.todo(konzept)?.isDone == true)
        // Opening one of them opens the parent again.
        note.setDone(note.todos[0].children[1].id, false)
        #expect(note.todo(konzept)?.isDone == false)
        // Ticking the parent off ticks off everything below it.
        note.setDone(konzept, true)
        #expect(note.todos[0].children.allSatisfy { $0.isDone })
        // A new to-do under a finished one makes it open.
        note.addTodo("Wettbewerb", parent: konzept)
        #expect(note.todo(konzept)?.isDone == false)
        #expect(note.groups.map(\.title) == ["Konzept", "Design"])
    }

    @Test func allDoneIsComplete() {
        var note = website()
        for todo in note.todos { note.setDone(todo.id, true) }
        #expect(note.progress.isComplete)
        #expect(note.progress.label == "Alle 4 ToDos erledigt")
        let removed = note.removeDone()
        #expect(removed == 6)
        #expect(note.todos.isEmpty)
    }

    // MARK: Structure

    @Test func indentOutdentMoveAndReparent() {
        var note = website()
        let design = note.todos[1].id
        let impressum = note.todos[2].id
        let indented = note.indent(impressum)
        #expect(indented)
        #expect(note.todo(design)?.children.map(\.text) == ["Farben", "Impressum"])
        let outdented = note.outdent(impressum)
        #expect(outdented)
        #expect(note.todos.map(\.text) == ["Konzept", "Design", "Impressum"])
        let first = note.todos[0].id
        let firstIndented = note.indent(first)
        #expect(!firstIndented, "Das erste ToDo hat keins davor")
        let firstOutdented = note.outdent(first)
        #expect(!firstOutdented, "Oben geht es nicht weiter hinaus")
        let moved = note.move(impressum, by: -2)
        #expect(moved)
        #expect(note.todos.map(\.text) == ["Impressum", "Konzept", "Design"])
        let movedAgain = note.move(impressum, by: -1)
        #expect(!movedAgain)
        let konzept = note.todos[1].id
        let intoOwn = note.reparent(konzept, to: note.todos[1].children[0].id)
        #expect(!intoOwn, "Nicht unter ein eigenes Unter-ToDo")
        let reparented = note.reparent(konzept, to: design, at: 0)
        #expect(reparented)
        #expect(note.todo(design)?.children.first?.text == "Konzept")
    }

    @Test func rowsAreNumberedAndFoldedOnesHideWhatIsUnderThem() {
        var note = website()
        #expect(note.rows().map(\.number) == ["1", "1.1", "1.2", "2", "2.1", "3"])
        note.updateTodo(note.todos[0].id) { $0.isCollapsed = true }
        #expect(note.rows().map(\.number) == ["1", "2", "2.1", "3"])
        #expect(note.rows(showingCollapsed: true).count == 6)
        #expect(note.todo(atNumber: "2.1")?.text == "Farben")
        #expect(note.todo(atNumber: "4") == nil)
        #expect(note.number(of: note.todos[1].children[0].id) == "2.1")
        // A new to-do under a folded one opens it, so it can be seen.
        note.addTodo("Wettbewerb", parent: note.todos[0].id)
        #expect(note.todos[0].isCollapsed == false)
        let after = note.addTodo("Danach", after: note.todos[0].id)
        #expect(after != nil)
        #expect(note.todos.map(\.text) == ["Konzept", "Danach", "Design", "Impressum"])
    }

    // MARK: Text

    @Test func todosFromATaskList() {
        let todos = Note.todos(fromText: """
        # Webseite
        - [ ] Konzept
          - [x] Zielgruppe
          - [ ] Gliederung
        * Design
        \t- Farben
        1. Impressum

        ☑ Domain
        """)
        #expect(todos.map(\.text) == ["Konzept", "Design", "Impressum", "Domain"])
        #expect(todos[0].children.map(\.text) == ["Zielgruppe", "Gliederung"])
        #expect(todos[0].children[0].isDone == true)
        #expect(todos[1].children.map(\.text) == ["Farben"])
        #expect(todos[3].isDone)
    }

    @Test func markdownIsATaskList() {
        var note = website()
        note.setDone(note.todos[0].children[0].id, true)
        note.text = "Hosting klären"
        let markdown = note.markdown
        #expect(markdown.hasPrefix("# Webseite\n\n- [ ] Konzept\n  - [x] Zielgruppe\n  - [ ] Gliederung\n- [ ] Design"))
        #expect(markdown.contains("Hosting klären"))
        // And back: the free text below the list stays text.
        let back = Note.todos(fromText: markdown)
        #expect(back.flatMap(\.all).count == 6)
        #expect(back[0].children[0].isDone == true)
        // Plain lines without any list are to-dos each.
        #expect(Note.todos(fromText: "Brot\nMilch\n\nEier").map(\.text) == ["Brot", "Milch", "Eier"])
    }

    // MARK: Format

    @Test func theFileHasGermanKeysAndLeavesOutWhatIsEmpty() throws {
        var note = website()
        note.style = .glass
        let document = UUID()
        note.owners = [.document(document), .story(world: UUID(), part: nil)]
        note.todos[0].documents = [document]
        note.todos[1].isCollapsed = true
        let data = try NoteStore.encoder.encode(NoteStore.Record(note: note))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? Int == 1)
        let object = try #require(json["note"] as? [String: Any])
        #expect(Set(object.keys) == ["id", "titel", "anzeige", "gehoertZu", "todos", "erstellt", "geaendert"])
        #expect(object["anzeige"] as? String == "glas")
        let owners = try #require(object["gehoertZu"] as? [[String: Any]])
        #expect(owners[0]["art"] as? String == "dokument")
        #expect(owners[1]["art"] as? String == "romanwelt")
        #expect(owners[1]["teil"] == nil)
        let todos = try #require(object["todos"] as? [[String: Any]])
        #expect(Set(todos[0].keys) == ["id", "text", "erledigt", "dokumente", "unter"])
        #expect(todos[1]["zu"] as? Bool == true)
        #expect(Set(todos[2].keys) == ["id", "text", "erledigt"])

        let back = try NoteStore.decoder.decode(NoteStore.Record.self, from: data).note
        #expect(back == note)
    }

    @Test func readingIsLenient() throws {
        let json = """
        {"format": 1, "note": {"titel": "Alt", "anzeige": "laserschwert", "zukunft": true,
          "gehoertZu": [{"art": "kalender", "id": "x"}, {"art": "dokument", "id": "3BC48041-12EC-4B73-87B7-BAA02A0AC3A3"}],
          "todos": [{"text": "Eins"}, {"text": 5}, {"text": "Zwei", "erledigt": true, "unter": [{"text": "Zwei.Eins", "erledigt": "ja"}]}]}}
        """
        let note = try NoteStore.decoder.decode(NoteStore.Record.self, from: Data(json.utf8)).note
        #expect(note.title == "Alt")
        #expect(note.style == .bar)
        #expect(note.owners == [.document(UUID(uuidString: "3BC48041-12EC-4B73-87B7-BAA02A0AC3A3")!)])
        #expect(note.todos.count == 3)
        #expect(note.todos[1].text == "")
        #expect(note.todos[2].children.first?.isDone == false)
    }

    @Test func theStoreKeepsNotesAndPutsDeletedOnesInTheTrash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Notizen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        let note = website()
        try store.save(note)
        #expect(store.loadAll() == [note])
        store.delete(note.id)
        #expect(store.loadAll().isEmpty)
    }

    // MARK: Library

    @MainActor
    @Test func typedTextGoesInBeforeTheNextChangeAndUndoBringsItBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Notizen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = NoteLibrary(store: NoteStore(directory: folder))
        let note = library.addNote(title: "Liste", todos: [NoteTodo(text: "A")])
        let todo = note.todos[0].id
        // Typing stays a draft …
        library.todoBinding(note.id, todo).wrappedValue = "A geändert"
        #expect(library.note(note.id)?.todos[0].text == "A")
        #expect(library.todoBinding(note.id, todo).wrappedValue == "A geändert")
        // … and goes in first when something else changes.
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        library.change(note.id, "ToDo abhaken", undo: undo) { $0.setDone(todo, true) }
        undo.endUndoGrouping()
        #expect(library.note(note.id)?.todos[0].text == "A geändert")
        #expect(library.note(note.id)?.todos[0].isDone == true)
        undo.undo()
        #expect(library.note(note.id)?.todos[0].isDone == false)
        #expect(library.note(note.id)?.todos[0].text == "A geändert")
        undo.redo()
        #expect(library.note(note.id)?.todos[0].isDone == true)

        // Deleting goes to the Trash; undo puts the note back.
        undo.beginUndoGrouping()
        library.delete(note.id, undo: undo)
        undo.endUndoGrouping()
        #expect(library.note(note.id) == nil)
        undo.undo()
        #expect(library.note(note.id)?.title == "Liste")

        library.saveAll()
        #expect(NoteStore(directory: folder).loadAll().first?.todos.first?.text == "A geändert")
    }

    @MainActor
    @Test func notesOfAnOwnerAreInTheOrderTheyWereMade() {
        let library = NoteLibrary(store: NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Notizen-\(UUID().uuidString)")))
        let owner = NoteOwner.story(world: UUID(), part: UUID())
        let first = library.addNote(title: "Eins", owners: [owner])
        _ = library.addNote(title: "Fremd")
        let second = library.addNote(title: "Zwei", owners: [owner])
        #expect(library.notes(for: owner).map(\.id) == [first.id, second.id])
    }
}
