import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Projekte: Seite, Board, Verknüpfungen", .serialized)
struct ProjectsActionTests {
    let h = ActionHarness()

    /// A new project with a unique title, so tests don't meet each other's.
    private func make(_ extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["title": .string("Projekt \(UUID().uuidString)")]
        args.merge(extra) { $1 }
        return try #require(try await h.call("projects.project.create", .object(args))["id"]?.stringValue)
    }

    private func project(_ id: String) -> Project? { h.app.projects.project(UUID(uuidString: id)!) }

    // MARK: Projects

    @Test func createReadUpdateProgressAndDelete() async throws {
        let id = try await make(["subtitle": "Regression", "color": "teal", "columns": ["Offen", "Dran", "Fertig"]])
        let made = try #require(project(id))
        #expect(made.subtitle == "Regression")
        #expect(made.color == .teal)
        #expect(made.columns.map(\.title) == ["Offen", "Dran", "Fertig"])
        #expect(made.columns.last?.isDone == true)
        #expect(made.blocks.count == 8, "Startseite")
        let empty = try await make(["empty": true])
        #expect(project(empty)?.blocks.isEmpty == true)

        let list = try await h.call("projects.project.list", ["query": .string(made.title)])
        #expect(list["projects"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [id])
        let byStatus = try await h.call("projects.project.list", ["status": "pausiert"])
        #expect(byStatus["projects"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == false)

        try await h.call("projects.project.update", ["project": .string(id), "status": "pausiert", "background": "papier", "font": "didot", "accent": "pink"])
        #expect(project(id)?.status == .paused)
        #expect(project(id)?.design == ProjectDesign(font: .didot, accent: .pink, background: .paper))
        #expect(await h.errorCode("projects.project.update", ["project": .string(id)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("projects.project.update", ["project": .string(id), "color": "mauve"]) == RPCError.invalidParamsCode)
        try await h.call("writer.edit.undo")
        #expect(project(id)?.status == .running)

        let read = try await h.call("projects.project.read", ["project": .string(made.title)])
        #expect(read["project"]?["id"] == .string(id))
        #expect(read["blocks"]?.arrayValue?.count == 8)
        #expect(read["columns"]?.arrayValue?.count == 3)
        let short = try await h.call("projects.project.read", ["project": .string(id), "include": "kurz"])
        #expect(short["blocks"] == nil)
        #expect(await h.errorCode("projects.project.read", ["project": .string(id), "include": "alles und mehr"]) == RPCError.invalidParamsCode)

        let progress = try await h.call("projects.project.progress", ["project": .string(id)])
        #expect(progress["overall"]?["total"] == 0)
        #expect(progress["columns"]?.arrayValue?.count == 3)

        try await h.call("projects.project.delete", ["project": .string(id)])
        #expect(project(id) == nil)
        #expect(await h.errorCode("projects.project.read", ["project": .string(id)]) == RPCError.notFoundCode)
        try await h.call("writer.edit.undo")
        #expect(project(id)?.columns.count == 3)
    }

    // MARK: Links

    @Test func linksToDocumentsNotesAndWorlds() async throws {
        let doc = try await h.document("# Gliederung\n")
        let note = try #require(try await h.call("notes.note.create", ["title": .string("Note \(UUID().uuidString)")])["id"]?.stringValue)
        let world = try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("stories.outline.create", ["world": .string(world), "outline": [["title": "Buch", "children": [["title": "Akt"]]]]])
        let id = try await make(["doc": .string(doc)])
        #expect(project(id)?.links == [.document(UUID(uuidString: doc)!)])

        try await h.call("projects.link.add", ["project": .string(id), "note": .string(note)])
        try await h.call("projects.link.add", ["project": .string(id), "world": .string(world), "part": "Buch/Akt"])
        let again = try await h.call("projects.link.add", ["project": .string(id), "note": .string(note)])
        #expect(again["message"] == "War schon verknüpft.")
        #expect(project(id)?.links.count == 3)
        #expect(await h.errorCode("projects.link.add", ["project": .string(id), "doc": .string(doc), "note": .string(note)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("projects.link.add", ["project": .string(id), "part": "Buch"]) == RPCError.invalidParamsCode)

        let read = try await h.call("projects.project.read", ["project": .string(id), "include": "kurz"])
        #expect(read["links"] == nil)
        let full = try await h.call("projects.project.read", ["project": .string(id)])
        #expect(full["links"]?[2]?["kind"] == "romanwelt")
        #expect(full["links"]?[2]?["title"]?.stringValue?.hasSuffix("› Akt") == true)

        let found = try await h.call("projects.link.find", ["note": .string(note)])
        #expect(found["projects"]?[0]?["project"] == .string(id))
        #expect(found["projects"]?[0]?["asProject"] == true)

        try await h.call("projects.link.remove", ["project": .string(id), "note": .string(note)])
        #expect(project(id)?.links.count == 2)
        #expect(await h.errorCode("projects.link.remove", ["project": .string(id), "note": .string(note)]) == RPCError.invalidTargetCode)

        // A deleted document leaves its link behind, marked as gone, and is removed by its id.
        h.app.deleteDocument(UUID(uuidString: doc)!)
        let gone = try await h.call("projects.project.read", ["project": .string(id)])
        #expect(gone["links"]?[0]?["exists"] == false)
        try await h.call("projects.link.remove", ["project": .string(id), "doc": .string(doc)])
        #expect(project(id)?.links.count == 1)
    }

    // MARK: Blocks

    @Test func blocksAreAddedStyledMovedAndRemoved() async throws {
        let id = try await make(["empty": true])
        let text = try await h.call("projects.block.add", ["project": .string(id), "kind": "text", "text": "Ziel", "font": "georgia", "size": 24, "bold": true,
                                                            "italic": true, "textColor": "blue", "align": "mitte", "width": 8])
        let textID = try #require(text["id"]?.stringValue)
        #expect(text["width"] == 8)
        var block = try #require(project(id)?.block(UUID(uuidString: textID)!))
        #expect(block.style == ProjectTextStyle(font: .georgia, size: 24, color: .blue, bold: true, italic: true, alignment: .center))

        let chart = try await h.call("projects.block.add", ["project": .string(id), "kind": "diagramm", "chart": "kreis", "source": "prioritaet"])
        let chartID = try #require(chart["id"]?.stringValue)
        #expect(project(id)?.block(UUID(uuidString: chartID)!)?.chart?.source == .priorities)
        #expect(await h.errorCode("projects.block.add", ["project": .string(id), "kind": "diagramm", "chart": "kreis", "source": "verlauf"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("projects.block.add", ["project": .string(id), "kind": "zauberei"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("projects.block.add", ["project": .string(id), "kind": "text", "chart": "kreis"]) == RPCError.invalidParamsCode)

        let progress = try await h.call("projects.block.add", ["project": .string(id), "kind": "fortschritt", "display": "sternbild", "measure": "akzeptanz"])
        let progressID = try #require(progress["id"]?.stringValue)
        #expect(project(id)?.block(UUID(uuidString: progressID)!)?.progressStyle == .constellation)

        try await h.call("projects.block.update", ["project": .string(id), "block": .string(textID), "font": "seite", "text": "Neues Ziel"])
        block = try #require(project(id)?.block(UUID(uuidString: textID)!))
        #expect(block.style.font == nil)
        #expect(block.text == "Neues Ziel")
        try await h.call("projects.block.update", ["project": .string(id), "block": .string(chartID), "chart": "balken"])
        #expect(project(id)?.block(UUID(uuidString: chartID)!)?.chart?.kind == .bars)
        #expect(await h.errorCode("projects.block.update", ["project": .string(id), "block": .string(textID)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("projects.block.update", ["project": .string(id), "block": .string(progressID), "display": "laserschwert"]) == RPCError.invalidParamsCode)

        // The chart goes onto the text's place; the text moves down and nothing overlaps.
        let moved = try await h.call("projects.block.move", ["project": .string(id), "block": .string(chartID), "x": 0, "y": 0])
        #expect(moved["blocks"]?.arrayValue?.count == 3)
        let frames = try #require(project(id)?.blocks.map(\.frame))
        for (index, one) in frames.enumerated() {
            for other in frames[(index + 1)...] { #expect(!one.overlaps(other)) }
        }
        #expect(project(id)?.block(UUID(uuidString: chartID)!)?.frame.y == 0)

        try await h.call("projects.block.entries", ["project": .string(id), "block": .string(chartID), "entries": [["title": "Lesen", "value": 3, "color": "green"], ["title": "Schreiben", "value": 5]]])
        let entries = try #require(project(id)?.block(UUID(uuidString: chartID)!)?.chart)
        #expect(entries.source == .manual)
        #expect(entries.entries.map(\.title) == ["Lesen", "Schreiben"])
        #expect(await h.errorCode("projects.block.entries", ["project": .string(id), "block": .string(textID), "entries": []]) == RPCError.invalidTargetCode)

        let listed = try await h.call("projects.block.list", ["project": .string(id)])
        #expect(listed["blocks"]?.arrayValue?.count == 3)
        #expect(listed["blocks"]?[0]?["kind"] == "diagramm")

        try await h.call("projects.block.delete", ["project": .string(id), "block": .string(textID)])
        #expect(project(id)?.blocks.count == 2)
        try await h.call("writer.edit.undo")
        #expect(project(id)?.blocks.count == 3)
    }

    // MARK: To-dos and milestones

    @Test func todoListsTodosAndMilestones() async throws {
        let id = try await make(["empty": true])
        let doc = try await h.document("# Kapitel\n")
        let list = try await h.call("projects.todolist.add", ["project": .string(id), "title": "Recherche", "block": true])
        let listID = try #require(list["id"]?.stringValue)
        #expect(list["block"]?.stringValue != nil)
        #expect(project(id)?.blocks.first?.listID?.uuidString == listID)

        try await h.call("projects.todo.add", ["project": .string(id), "list": "Recherche", "texts": ["Bibliothek", "Datenbank"], "due": "2026-11-15"])
        try await h.call("projects.todo.add", ["project": .string(id), "list": .string(listID), "text": "Kapitel lesen", "doc": .string(doc)])
        let todos = try #require(project(id)?.todoList(UUID(uuidString: listID)!)?.todos)
        #expect(todos.map(\.text) == ["Bibliothek", "Datenbank", "Kapitel lesen"])
        #expect(todos[0].due == ProjectDay.date("2026-11-15"))
        #expect(todos[2].link == .document(UUID(uuidString: doc)!))
        #expect(await h.errorCode("projects.todo.add", ["project": .string(id), "text": "x", "due": "morgen"]) == RPCError.invalidParamsCode)

        try await h.call("projects.todo.check", ["project": .string(id), "todo": "Bibliothek"])
        #expect(project(id)?.progress(.todos) == NoteProgress(done: 1, total: 3))
        try await h.call("projects.todo.check", ["project": .string(id), "todo": "1", "done": false])
        #expect(project(id)?.progress(.todos).done == 0)
        try await h.call("projects.todo.update", ["project": .string(id), "todo": "Kapitel lesen", "unlink": true, "due": ""])
        #expect(project(id)?.todo(todos[2].id)?.link == nil)
        try await h.call("projects.todo.delete", ["project": .string(id), "todo": "Datenbank"])
        #expect(project(id)?.allTodos.count == 2)

        // Without a list the first one takes it; a project without lists gets one.
        let bare = try await make(["empty": true])
        try await h.call("projects.todo.add", ["project": .string(bare), "text": "Erstes"])
        #expect(project(bare)?.todoLists.count == 1)
        let general = try #require(project(id)?.todoLists.first { $0.title != "Recherche" })
        try await h.call("projects.todolist.delete", ["project": .string(id), "list": .string(general.id.uuidString)])
        #expect(project(id)?.todoLists.map(\.title) == ["Recherche"])
        try await h.call("projects.todolist.delete", ["project": .string(id), "list": "Recherche"])
        #expect(project(id)?.blocks.first?.listID == nil)

        try await h.call("projects.milestone.add", ["project": .string(id), "title": "Abgabe", "date": "2026-11-20", "color": "red"])
        try await h.call("projects.milestone.add", ["project": .string(id), "title": "Exposé", "date": "2026-11-01"])
        #expect(project(id)?.sortedMilestones.map(\.title) == ["Exposé", "Abgabe"])
        try await h.call("projects.milestone.update", ["project": .string(id), "milestone": "1", "done": true])
        #expect(project(id)?.nextMilestone?.title == "Abgabe")
        #expect(await h.errorCode("projects.milestone.add", ["project": .string(id), "title": "x", "date": "bald"]) == RPCError.invalidParamsCode)
        try await h.call("projects.milestone.delete", ["project": .string(id), "milestone": "Abgabe"])
        #expect(project(id)?.milestones.count == 1)
    }

    // MARK: Board

    @Test func columnsAndTasksWithCriteriaAndImpediments() async throws {
        let id = try await make(["columns": ["Offen", "In Arbeit", "Fertig"]])
        try await h.call("projects.column.add", ["project": .string(id), "title": "Review", "limit": 2])
        #expect(project(id)?.columns.map(\.title) == ["Offen", "In Arbeit", "Review", "Fertig"], "Vor den erledigten Spalten")
        try await h.call("projects.column.update", ["project": .string(id), "column": "Review", "position": 1, "color": "pink", "limit": 0])
        #expect(project(id)?.columns.first?.title == "Review")
        #expect(project(id)?.columns.first?.limit == nil)
        #expect(project(id)?.columns.first?.color == .pink)

        let task = try await h.call("projects.task.add", ["project": .string(id), "title": "Kapitel 3", "column": "Offen", "priority": "hoch", "due": "2026-11-15",
                                                          "tags": ["Schreiben"], "criteria": ["Quellen geprüft", "Korrektur gelesen"],
                                                          "impediments": [["text": "Daten fehlen", "solution": "Institut fragen"]]])
        let taskID = try #require(task["id"]?.stringValue)
        #expect(task["column"] == "Offen")
        let second = try await h.call("projects.task.add", ["project": .string(id), "title": "Gliederung"])
        #expect(second["column"] == "Review", "Ohne Spalte: die erste, die nicht als erledigt zählt")

        let read = try await h.call("projects.task.read", ["project": .string(id), "task": "Kapitel 3"])
        #expect(read["priority"] == "hoch")
        #expect(read["criteria"]?.arrayValue?.count == 2)
        #expect(read["blocked"] == true)
        #expect(read["impediments"]?[0]?["solution"] == "Institut fragen")

        try await h.call("projects.task.update", ["project": .string(id), "task": .string(taskID), "appendDetails": "Mit Tabellen", "tags": ["Schreiben", "Statistik"]])
        #expect(project(id)?.task(UUID(uuidString: taskID)!)?.details == "Mit Tabellen")
        #expect(project(id)?.task(UUID(uuidString: taskID)!)?.tags == ["Schreiben", "Statistik"])

        try await h.call("projects.task.criterion.add", ["project": .string(id), "task": "Kapitel 3", "text": "Abbildungen beschriftet"])
        var check = try await h.call("projects.task.criterion.check", ["project": .string(id), "task": "Kapitel 3", "criterion": "1"])
        #expect(check["met"] == 1)
        #expect(check["acceptable"] == false)
        try await h.call("projects.task.criterion.delete", ["project": .string(id), "task": "Kapitel 3", "criterion": "Abbildungen beschriftet"])
        check = try await h.call("projects.task.criterion.check", ["project": .string(id), "task": "Kapitel 3", "criterion": "Korrektur gelesen"])
        #expect(check["acceptable"] == true)

        try await h.call("projects.task.impediment.add", ["project": .string(id), "task": "Kapitel 3", "text": "Drucker kaputt"])
        try await h.call("projects.task.impediment.update", ["project": .string(id), "task": "Kapitel 3", "impediment": "Daten fehlen", "resolved": true])
        let blocked = try await h.call("projects.task.list", ["project": .string(id), "blocked": true])
        #expect(blocked["tasks"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [taskID])
        try await h.call("projects.task.impediment.delete", ["project": .string(id), "task": "Kapitel 3", "impediment": "Drucker kaputt"])
        #expect(project(id)?.task(UUID(uuidString: taskID)!)?.isBlocked == false)

        let moved = try await h.call("projects.task.move", ["project": .string(id), "task": "Kapitel 3", "column": "Fertig"])
        #expect(moved["done"] == true)
        #expect(project(id)?.progress(.tasks) == NoteProgress(done: 1, total: 2))
        try await h.call("projects.task.move", ["project": .string(id), "task": "Kapitel 3", "column": "Review", "before": "Gliederung"])
        #expect(project(id)?.tasks(in: project(id)!.columns[0].id).map(\.title) == ["Kapitel 3", "Gliederung"])
        #expect(await h.errorCode("projects.task.move", ["project": .string(id), "task": "Kapitel 3", "column": "Offen", "before": "Gliederung"]) == RPCError.invalidParamsCode)
        let open = try await h.call("projects.task.list", ["project": .string(id), "open": true, "column": "Review"])
        #expect(open["tasks"]?.arrayValue?.count == 2)

        try await h.call("projects.column.delete", ["project": .string(id), "column": "In Arbeit"])
        #expect(project(id)?.columns.count == 3)
        try await h.call("projects.task.delete", ["project": .string(id), "task": "Gliederung"])
        #expect(project(id)?.tasks.count == 1)
        try await h.call("writer.edit.undo")
        #expect(project(id)?.tasks.count == 2)
    }

    @Test func tasksLinkToStudiosThings() async throws {
        let id = try await make()
        let doc = try await h.document("# Kapitel\n")
        let world = try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("stories.element.create", ["world": .string(world), "kind": "figure", "name": "Mara"])
        let task = try #require(try await h.call("projects.task.add", ["project": .string(id), "title": "Überarbeiten", "doc": .string(doc)])["id"]?.stringValue)
        try await h.call("projects.task.link", ["project": .string(id), "task": .string(task), "world": .string(world), "element": "figure:Mara"])
        let links = try #require(project(id)?.task(UUID(uuidString: task)!)?.links)
        #expect(links.count == 2)
        guard case .story(_, nil, let element) = links[1] else { Issue.record("Kein Element verknüpft"); return }
        #expect(element?.kind == .figure)
        #expect(h.app.projectRefTitle(links[1])?.hasSuffix("› Mara") == true)

        let found = try await h.call("projects.link.find", ["doc": .string(doc)])
        #expect(found["projects"]?[0]?["tasks"]?[0] == "Überarbeiten")
        #expect(found["projects"]?[0]?["asProject"] == false)

        try await h.call("projects.task.unlink", ["project": .string(id), "task": .string(task), "doc": .string(doc)])
        #expect(project(id)?.task(UUID(uuidString: task)!)?.links.count == 1)
        #expect(await h.errorCode("projects.task.unlink", ["project": .string(id), "task": .string(task), "doc": .string(doc)]) == RPCError.invalidTargetCode)
    }

    // MARK: Studio, kinds, rules

    @Test func studioStylesAndSecurity() async throws {
        let styles = try await h.call("projects.styles.list")
        #expect(styles["blocks"]?.arrayValue?.count == ProjectBlockKind.allCases.count)
        #expect(styles["displays"]?.arrayValue?.count == ProjectProgressStyle.allCases.count)
        #expect(styles["displays"]?[0]?["id"] == "reise")
        #expect(styles["charts"]?.arrayValue?.count == ProjectChartKind.allCases.count)

        let id = try await make()
        let task = try #require(try await h.call("projects.task.add", ["project": .string(id), "title": "Lesen"])["id"]?.stringValue)
        try await h.call("projects.studio.open", ["project": .string(id), "task": "Lesen"])
        #expect(h.app.openProjectID?.uuidString == id)
        #expect(h.app.activeApplication == .projects)
        #expect(h.app.projectTab == .board)
        #expect(h.app.projectCommand?.task?.uuidString == task)
        try await h.call("projects.studio.open", ["project": .string(id), "tab": "seite"])
        #expect(h.app.projectTab == .page)
        #expect(await h.errorCode("projects.studio.open", ["project": .string(id), "tab": "keller"]) == RPCError.invalidParamsCode)
        try await h.call("projects.studio.close")
        #expect(h.app.openProjectID == nil)
        h.app.projectCommand = nil

        // Agents can write into projects, so reading one counts as foreign; deleting is destructive.
        #expect(h.registry.descriptor("projects.project.read")?.security.readsUntrusted == true)
        for destructive in ["projects.project.delete", "projects.block.delete", "projects.todo.delete", "projects.todolist.delete", "projects.milestone.delete",
                            "projects.column.delete", "projects.task.delete", "projects.task.criterion.delete", "projects.task.impediment.delete"] {
            #expect(h.registry.descriptor(destructive)?.kind == .destructive, "\(destructive)")
        }
        for member in ChatToolGroups.members["projects.core"] ?? [] {
            #expect(h.registry.descriptor(member) != nil, "\(member) fehlt in der Registry")
        }
    }
}
}

/// `result["tasks"]?[0]?["id"]`: reading nested results the way they look.
private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
