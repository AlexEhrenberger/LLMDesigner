import Testing
import Foundation
@testable import LLMDesigner

@Suite("Projekte: Format, Raster, Fortschritt, Diagramme")
struct ProjectTests {
    /// A project with an own board, two tasks (one done), a to-do list and two milestones.
    private func sample() -> Project {
        var project = Project(title: "Hausarbeit")
        let open = ProjectColumn(title: "Offen")
        let done = ProjectColumn(title: "Erledigt", isDone: true)
        project.columns = [open, done]
        var first = ProjectTask(title: "Gliederung", column: done.id)
        first.criteria = [ProjectCriterion(text: "Abgestimmt", isMet: true)]
        var second = ProjectTask(title: "Kapitel 3", column: open.id)
        second.criteria = [ProjectCriterion(text: "Quellen geprüft", isMet: true), ProjectCriterion(text: "Korrektur gelesen")]
        second.impediments = [ProjectImpediment(text: "Daten fehlen", solution: "Beim Institut anfragen")]
        second.due = ProjectDay.date("2026-11-15")
        second.tags = ["Schreiben"]
        project.tasks = [first, second]
        project.todoLists = [ProjectTodoList(title: "Nächstes", todos: [ProjectTodo(text: "Mail", isDone: true), ProjectTodo(text: "Drucken")])]
        project.milestones = [ProjectMilestone(title: "Abgabe", date: ProjectDay.date("2026-11-20")!), ProjectMilestone(title: "Exposé", date: ProjectDay.date("2026-11-01")!, isDone: true)]
        // Whole seconds, as the file keeps them.
        for index in project.tasks.indices {
            project.tasks[index].createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            project.tasks[index].updatedAt = Date(timeIntervalSince1970: 1_800_000_030)
        }
        project.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        project.updatedAt = Date(timeIntervalSince1970: 1_800_000_060)
        return project
    }

    // MARK: Format

    @Test func roundTripKeepsEverythingWithGermanKeys() throws {
        var project = sample()
        project.links = [.document(UUID()), .note(UUID()), .chat(UUID()), .story(world: UUID(), part: UUID(), element: nil),
                         .story(world: UUID(), part: nil, element: StoryRef(kind: .figure, id: UUID()))]
        project.tasks[1].links = [project.links[0]]
        project.todoLists[0].todos[1].link = project.links[1]
        project.todoLists[0].todos[1].due = ProjectDay.date("2026-11-18")
        project.addBlock(.progress)
        project.addChart(.gantt, source: .milestones)
        var text = ProjectBlock(kind: .text, frame: ProjectGridFrame(x: 2, y: 9, width: 8, height: 2))
        text.text = "Ziel"
        text.style = ProjectTextStyle(font: .didot, size: 22, color: .blue, bold: true, italic: true, alignment: .center)
        project.blocks.append(text)
        project.design = ProjectDesign(font: .georgia, accent: .teal, background: .paper)
        project.recordHistory(now: Date(timeIntervalSince1970: 1_800_000_000))

        let data = try NoteStore.encoder.encode(ProjectStore.Record(projekt: project))
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["\"projekt\"", "\"titel\"", "\"bausteine\"", "\"verknuepft\"", "\"todoListen\"", "\"meilensteine\"", "\"spalten\"", "\"aufgaben\"",
                    "\"akzeptanz\"", "\"hindernisse\"", "\"loesung\"", "\"verlauf\"", "\"gestaltung\"", "\"schrift\" : \"georgia\"", "\"faellig\" : \"2026-11-15\"",
                    "\"art\" : \"romanwelt\"", "\"teil\"", "\"element\"", "\"fett\" : true", "\"ausrichtung\" : \"mitte\"", "\"anzeige\"", "\"diagramm\""] {
            #expect(json.contains(key), "\(key) fehlt")
        }
        let decoded = try NoteStore.decoder.decode(ProjectStore.Record.self, from: data).projekt
        #expect(decoded == project)
    }

    @Test func readsLenientlyAndRepairsTheBoard() throws {
        let column = UUID()
        let json = """
        {"format": 1, "projekt": {"id": "\(UUID().uuidString)", "titel": "Alt", "status": "unbekannt",
          "bausteine": [{"art": "zauberei", "x": 0, "y": 0, "b": 4, "h": 2}, {"art": "text", "x": 20, "y": 1, "b": 30, "h": 0, "text": "Hallo"}],
          "spalten": [{"id": "\(column.uuidString)", "titel": "Offen"}],
          "aufgaben": [{"titel": "Ohne Spalte", "spalte": "\(UUID().uuidString)"}, {"titel": "Kaputt", "akzeptanz": "kein Array"}],
          "meilensteine": [{"titel": "Abgabe", "datum": "2026-11-20T08:00:00Z"}]}}
        """
        let project = try NoteStore.decoder.decode(ProjectStore.Record.self, from: Data(json.utf8)).projekt
        #expect(project.status == .running)
        #expect(project.blocks.count == 1)
        #expect(project.blocks[0].frame == ProjectGridFrame(x: 0, y: 1, width: 12, height: 1))
        #expect(project.tasks.count == 2)
        #expect(project.tasks.allSatisfy { $0.column == column })
        #expect(project.tasks[1].criteria.isEmpty)
        #expect(ProjectDay.string(project.milestones[0].date) == "2026-11-20")

        let empty = try NoteStore.decoder.decode(Project.self, from: Data(#"{"titel": "Leer"}"#.utf8))
        #expect(empty.columns.map(\.title) == ProjectColumn.defaults.map(\.title))
        #expect(empty.columns.last?.isDone == true)
    }

    @Test func storeSavesLoadsAndTrashes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectStore-\(UUID().uuidString)")
        let store = ProjectStore(directory: folder)
        let project = sample()
        try store.save(project)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(project.id.uuidString).json").path))
        #expect(store.loadAll() == [project])
        store.delete(project.id)
        #expect(store.loadAll().isEmpty)
    }

    // MARK: Grid

    @Test func movingABlockPushesTheOthersDownWithoutOverlaps() {
        var project = Project(title: "Raster")
        let a = project.addBlock(.metric)
        let b = project.addBlock(.metric)
        let c = project.addBlock(.text)
        #expect(a.frame == ProjectGridFrame(x: 0, y: 0, width: 3, height: 3))
        #expect(b.frame == ProjectGridFrame(x: 3, y: 0, width: 3, height: 3))
        #expect(c.frame.y == 3)
        // B goes onto A's place: A gives way downwards, and the text below A follows.
        project.updateBlock(b.id) { $0.frame = ProjectGridFrame(x: 0, y: 0, width: 4, height: 3) }
        let frames = Dictionary(uniqueKeysWithValues: project.blocks.map { ($0.id, $0.frame) })
        #expect(frames[b.id] == ProjectGridFrame(x: 0, y: 0, width: 4, height: 3))
        #expect(frames[a.id]?.y == 3)
        #expect(frames[c.id]?.y == 6)
        for one in project.blocks {
            for other in project.blocks where other.id != one.id {
                #expect(!one.frame.overlaps(other.frame))
            }
        }
        // Gaps the person left stay.
        project.updateBlock(c.id) { $0.frame.y = 20 }
        #expect(project.block(c.id)?.frame.y == 20)
        #expect(ProjectLayout.rows(of: project.blocks) == 22)
    }

    @Test func gridFrameStaysOnTheGrid() {
        #expect(ProjectGridFrame(x: 11, y: -2, width: 4, height: 0) == ProjectGridFrame(x: 8, y: 0, width: 4, height: 1))
        #expect(ProjectGridFrame(x: 0, y: 0, width: 40, height: 2).width == 12)
        let blocks = [ProjectBlock(kind: .text, frame: ProjectGridFrame(x: 0, y: 0, width: 6, height: 2))]
        #expect(ProjectLayout.freeFrame(width: 6, height: 2, in: blocks) == ProjectGridFrame(x: 6, y: 0, width: 6, height: 2))
        #expect(ProjectLayout.freeFrame(width: 12, height: 1, in: blocks) == ProjectGridFrame(x: 0, y: 2, width: 12, height: 1))
    }

    @Test func starterPageHasItsBlocksAndAList() {
        let project = Project.starter(title: "Neu")
        #expect(project.blocks.count == 8)
        #expect(project.blocks.first { $0.kind == .todos }?.listID == project.todoLists.first?.id)
        #expect(Set(project.blocks.map(\.kind)).isSuperset(of: [.text, .progress, .countdown, .milestones, .board]))
    }

    // MARK: Progress

    @Test func progressByMeasure() {
        let project = sample()
        #expect(project.progress(.tasks) == NoteProgress(done: 1, total: 2))
        #expect(project.progress(.criteria) == NoteProgress(done: 2, total: 3))
        #expect(project.progress(.todos) == NoteProgress(done: 1, total: 2))
        #expect(project.progress(.milestones) == NoteProgress(done: 1, total: 2))
        #expect(project.overallProgress == NoteProgress(done: 3, total: 6))
        #expect(project.nextMilestone?.title == "Abgabe")
        #expect(project.tasks[1].isBlocked)
        #expect(!project.tasks[1].isAcceptable)
        #expect(project.tasks[0].isAcceptable)

        var block = ProjectBlock(kind: .metric, frame: ProjectGridFrame(x: 0, y: 0, width: 3, height: 3))
        block.measure = .blocked
        #expect(project.metric(block).value == "1")
        block.measure = .daysLeft
        #expect(project.metric(block, now: ProjectDay.date("2026-11-12")!).value == "8")
        block.measure = .manual
        block.value = 3.5
        block.text = "Seiten"
        #expect(project.metric(block) == ("3,5", "Seiten") || project.metric(block) == ("3.5", "Seiten"))
    }

    @Test func historyKeepsOneEntryPerDay() {
        var project = sample()
        let day1 = ProjectDay.date("2026-11-10")!.addingTimeInterval(3600)
        let day2 = ProjectDay.date("2026-11-11")!.addingTimeInterval(3600)
        project.recordHistory(now: day1)
        project.updateTodo(project.todoLists[0].todos[1].id) { $0.isDone = true }
        project.recordHistory(now: day1)
        #expect(project.history == [ProjectHistoryDay(day: "2026-11-10", open: 1, done: 3)])
        project.recordHistory(now: day2)
        // Nothing changed on the next day: no new entry.
        #expect(project.history.count == 1)
        project.moveTask(project.tasks[1].id, to: project.columns[1].id)
        project.recordHistory(now: day2)
        #expect(project.history.last == ProjectHistoryDay(day: "2026-11-11", open: 0, done: 4))
    }

    // MARK: Board

    @Test func tasksMoveAndColumnsGo() {
        var project = sample()
        let open = project.columns[0].id
        let done = project.columns[1].id
        let third = ProjectTask(title: "Literatur", column: open)
        project.tasks.append(third)
        project.moveTask(third.id, to: open, before: project.tasks[1].id)
        #expect(project.tasks(in: open).map(\.title) == ["Literatur", "Kapitel 3"])
        project.moveTask(third.id, to: done)
        #expect(project.tasks(in: done).map(\.title) == ["Gliederung", "Literatur"])
        project.removeColumn(done)
        #expect(project.columns.count == 1)
        #expect(project.tasks.allSatisfy { $0.column == open })
        project.removeColumn(open)
        #expect(project.columns.count == 1, "Die letzte Spalte bleibt")
    }

    @Test func linksAreFoundAndRemovedEverywhere() {
        var project = sample()
        let doc = ProjectRef.document(UUID())
        project.links = [doc]
        project.tasks[0].links = [doc]
        project.todoLists[0].todos[0].link = doc
        #expect(project.refers(to: doc))
        #expect(project.allLinks == [doc])
        #expect(project.linkUses.count == 3)
        #expect(project.tasks(referring: doc).map(\.title) == ["Gliederung"])
        project.removeLinkEverywhere(doc)
        #expect(!project.refers(to: doc))
    }

    // MARK: Charts and displays

    @Test func chartDataComesFromTheProject() {
        let project = sample()
        let byColumn = project.chartSlices(ProjectChart(kind: .pie, source: .columns))
        #expect(byColumn.map(\.title) == ["Offen", "Erledigt"])
        #expect(byColumn.map(\.value) == [1, 1])
        let byTag = project.chartSlices(ProjectChart(kind: .bars, source: .tags))
        #expect(byTag.map(\.title) == ["Schreiben", "Ohne Etikett"])
        let gantt = project.ganttBars(ProjectChart(kind: .gantt, source: .tasks))
        #expect(gantt.contains { $0.title == "Kapitel 3" && !$0.isMilestone })
        #expect(gantt.filter(\.isMilestone).count == 2)
        let stretches = project.ganttBars(ProjectChart(kind: .gantt, source: .milestones))
        #expect(stretches.map(\.title) == ["Exposé", "Abgabe"])
        #expect(stretches[1].start == ProjectDay.date("2026-11-01"))
        let flow = project.flowNodes(ProjectChart(kind: .flow, source: .columns))
        #expect(flow.map(\.title) == ["Offen", "Erledigt"])
        #expect(flow.last?.shape == .terminal)
        var manual = ProjectChart(kind: .flow, source: .manual)
        manual.entries = [ProjectChartEntry(title: "Idee"), ProjectChartEntry(title: "Prüfen")]
        manual.entries[1].shape = .decision
        #expect(project.flowNodes(manual).map(\.shape) == [.step, .decision])
        #expect(project.courseDays.last?.total == 4)
    }

    @Test func progressStylesKeepTheirNames() {
        #expect(ProjectProgressStyle.allCases.count == NoteProgressStyle.allCases.count + 4)
        for style in ProjectProgressStyle.allCases {
            #expect(ProjectProgressStyle(rawValue: style.rawValue) == style)
        }
        #expect(ProjectProgressStyle(rawValue: "glas") == .classic(.glass))
        #expect(ProjectProgressStyle(rawValue: "laserschwert") == nil)
    }

    @Test func daysAndCountdowns() {
        let now = ProjectDay.date("2026-11-12")!.addingTimeInterval(20 * 3600)
        #expect(ProjectDay.countdown(ProjectDay.date("2026-11-12")!, from: now) == "heute")
        #expect(ProjectDay.countdown(ProjectDay.date("2026-11-13")!, from: now) == "morgen")
        #expect(ProjectDay.countdown(ProjectDay.date("2026-11-21")!, from: now) == "noch 9 Tage")
        #expect(ProjectDay.countdown(ProjectDay.date("2026-11-10")!, from: now) == "seit 2 Tagen")
        #expect(ProjectDay.date("kein Datum") == nil)
    }
}
