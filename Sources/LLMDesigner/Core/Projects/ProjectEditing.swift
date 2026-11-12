import Foundation

// What a project works out from itself: how far it is, what comes next, where a new block goes, and the changes
// the page, the board and the actions share.

// MARK: - Progress

extension Project {
    var doneColumnIDs: Set<UUID> { Set(columns.filter(\.isDone).map(\.id)) }

    func isFinished(_ task: ProjectTask) -> Bool { doneColumnIDs.contains(task.column) }

    func tasks(in column: UUID) -> [ProjectTask] { tasks.filter { $0.column == column } }

    func column(_ id: UUID) -> ProjectColumn? { columns.first { $0.id == id } }
    func task(_ id: UUID) -> ProjectTask? { tasks.first { $0.id == id } }
    func block(_ id: UUID) -> ProjectBlock? { blocks.first { $0.id == id } }
    func todoList(_ id: UUID) -> ProjectTodoList? { todoLists.first { $0.id == id } }
    func milestone(_ id: UUID) -> ProjectMilestone? { milestones.first { $0.id == id } }

    var allTodos: [ProjectTodo] { todoLists.flatMap(\.todos) }

    /// How far the project is by one measure; `list` narrows to-dos to one list.
    func progress(_ measure: ProjectMeasure, list: UUID? = nil) -> NoteProgress {
        switch measure {
        case .tasks, .openTasks:
            return NoteProgress(done: tasks.filter(isFinished).count, total: tasks.count)
        case .criteria:
            let criteria = tasks.flatMap(\.criteria)
            return NoteProgress(done: criteria.filter(\.isMet).count, total: criteria.count)
        case .todos:
            let todos = list.flatMap { todoList($0)?.todos } ?? allTodos
            return NoteProgress(done: todos.filter(\.isDone).count, total: todos.count)
        case .milestones:
            return NoteProgress(done: milestones.filter(\.isDone).count, total: milestones.count)
        case .all, .blocked, .links, .daysLeft, .manual:
            let parts = [progress(.tasks), progress(.todos), progress(.milestones)]
            return NoteProgress(done: parts.reduce(0) { $0 + $1.done }, total: parts.reduce(0) { $0 + $1.total })
        }
    }

    /// The project at a glance, for the sidebar and lists: everything there is to tick off.
    var overallProgress: NoteProgress { progress(.all) }

    /// The milestones by date.
    var sortedMilestones: [ProjectMilestone] { milestones.sorted { $0.date < $1.date } }

    /// The first milestone that isn't reached yet.
    var nextMilestone: ProjectMilestone? { sortedMilestones.first { !$0.isDone } }

    /// A metric's number as the page shows it, with the line under it.
    func metric(_ block: ProjectBlock, now: Date = Date()) -> (value: String, caption: String) {
        switch block.measure {
        case .openTasks:
            return ("\(tasks.filter { !isFinished($0) }.count)", "von \(tasks.count) Aufgaben offen")
        case .tasks:
            let progress = progress(.tasks)
            return ("\(progress.done)", "von \(progress.total) Aufgaben erledigt")
        case .criteria:
            let progress = progress(.criteria)
            return ("\(progress.done)", "von \(progress.total) Kriterien erfüllt")
        case .blocked:
            let blocked = tasks.filter { $0.isBlocked && !isFinished($0) }.count
            return ("\(blocked)", blocked == 1 ? "Aufgabe hat ein Hindernis" : "Aufgaben haben ein Hindernis")
        case .todos:
            let todos = block.listID.flatMap { todoList($0)?.todos } ?? allTodos
            return ("\(todos.filter { !$0.isDone }.count)", "von \(todos.count) ToDos offen")
        case .milestones:
            let progress = progress(.milestones)
            return ("\(progress.done)/\(progress.total)", "Meilensteine erreicht")
        case .links:
            return ("\(allLinks.count)", allLinks.count == 1 ? "Verknüpfung" : "Verknüpfungen")
        case .daysLeft:
            guard let next = nextMilestone else { return ("–", "kein offener Meilenstein") }
            return ("\(ProjectDay.days(until: next.date, from: now))", "Tage bis „\(next.displayTitle)“")
        case .all:
            let progress = overallProgress
            return ("\(progress.percent) %", "\(progress.done) von \(progress.total) erledigt")
        case .manual:
            let value = block.value ?? 0
            let text = value == value.rounded() ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(0...2)))
            return (text, block.text.isEmpty ? "Eigene Zahl" : block.text)
        }
    }

    /// The day a countdown counts to, and what it is.
    func countdownTarget(_ block: ProjectBlock) -> (date: Date, title: String)? {
        if let date = block.date { return (date, block.title.isEmpty ? "Termin" : block.title) }
        guard let next = nextMilestone else { return nil }
        return (next.date, next.displayTitle)
    }
}

// MARK: - Links

/// A link and where in the project it comes from (the project itself, a task or a to-do).
struct ProjectLinkUse: Hashable, Identifiable {
    enum Place: Hashable {
        case project
        case task(UUID)
        case todo(list: UUID, todo: UUID)
    }

    let ref: ProjectRef
    let place: Place
    var id: String { "\(ref.art)|\(ref.targetID)|\(place)" }
}

extension Project {
    /// Everything the project points to, the project's own links first, each thing once.
    var allLinks: [ProjectRef] {
        var seen: Set<ProjectRef> = []
        return linkUses.map(\.ref).filter { seen.insert($0).inserted }
    }

    var linkUses: [ProjectLinkUse] {
        links.map { ProjectLinkUse(ref: $0, place: .project) }
            + tasks.flatMap { task in task.links.map { ProjectLinkUse(ref: $0, place: .task(task.id)) } }
            + todoLists.flatMap { list in list.todos.compactMap { todo in todo.link.map { ProjectLinkUse(ref: $0, place: .todo(list: list.id, todo: todo.id)) } } }
    }

    /// Whether the project points to this thing anywhere (itself, a task, a to-do).
    func refers(to ref: ProjectRef) -> Bool {
        linkUses.contains { $0.ref == ref }
    }

    /// The tasks that point to this thing.
    func tasks(referring ref: ProjectRef) -> [ProjectTask] {
        tasks.filter { $0.links.contains(ref) }
    }
}

// MARK: - Layout

enum ProjectLayout {
    /// Puts `moved` where it was asked to go and pushes every block it would cover further down, and the blocks
    /// those cover in turn. Blocks never overlap; gaps the person left stay, so the page stays as freely arranged.
    static func place(_ blocks: [ProjectBlock], moving movedID: UUID? = nil) -> [ProjectBlock] {
        var placed: [ProjectBlock] = []
        if let movedID, let moved = blocks.first(where: { $0.id == movedID }) { placed.append(moved) }
        let others = blocks.filter { $0.id != movedID }.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        for var block in others {
            while let blocker = placed.first(where: { $0.frame.overlaps(block.frame) }) {
                block.frame.y = blocker.frame.maxY
            }
            placed.append(block)
        }
        // The file keeps the order of the page, top to bottom, which is also the order of the stacked layout.
        return placed.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
    }

    /// The first place a block of this size fits, from the top, left to right.
    static func freeFrame(width: Int, height: Int, in blocks: [ProjectBlock]) -> ProjectGridFrame {
        let width = min(max(width, 1), ProjectGridFrame.columns)
        let bottom = blocks.map(\.frame.maxY).max() ?? 0
        for y in 0...bottom {
            for x in 0...(ProjectGridFrame.columns - width) {
                let frame = ProjectGridFrame(x: x, y: y, width: width, height: height)
                if !blocks.contains(where: { $0.frame.overlaps(frame) }) { return frame }
            }
        }
        return ProjectGridFrame(x: 0, y: bottom, width: width, height: height)
    }

    /// The rows the page needs.
    static func rows(of blocks: [ProjectBlock]) -> Int { blocks.map(\.frame.maxY).max() ?? 0 }
}

// MARK: - Changes

extension Project {
    /// A new project's page: a short welcome, its progress, its open to-dos, milestones and board at a glance.
    static func starter(title: String) -> Project {
        var project = Project(title: title)
        project.columns = ProjectColumn.defaults
        let list = ProjectTodoList(title: "Nächste Schritte")
        project.todoLists = [list]
        var intro = ProjectBlock(kind: .text, frame: ProjectGridFrame(x: 0, y: 0, width: 8, height: 2))
        intro.text = "Worum es geht – ein, zwei Sätze zum Ziel."
        intro.style.size = 17
        var progress = ProjectBlock(kind: .progress, frame: ProjectGridFrame(x: 8, y: 0, width: 4, height: 4))
        progress.measure = .all
        progress.progressStyle = .journey
        let countdown = ProjectBlock(kind: .countdown, frame: ProjectGridFrame(x: 0, y: 2, width: 4, height: 2))
        let metric = ProjectBlock(kind: .metric, frame: ProjectGridFrame(x: 4, y: 2, width: 4, height: 2))
        var todos = ProjectBlock(kind: .todos, frame: ProjectGridFrame(x: 0, y: 4, width: 6, height: 5))
        todos.listID = list.id
        let milestones = ProjectBlock(kind: .milestones, frame: ProjectGridFrame(x: 6, y: 4, width: 6, height: 3))
        let links = ProjectBlock(kind: .links, frame: ProjectGridFrame(x: 6, y: 7, width: 6, height: 2))
        let board = ProjectBlock(kind: .board, frame: ProjectGridFrame(x: 0, y: 9, width: 12, height: 3))
        project.blocks = [intro, progress, countdown, metric, todos, milestones, links, board]
        return project
    }

    /// A new block of a kind, where there is room; a to-do list block gets a list of its own if there is none.
    @discardableResult
    mutating func addBlock(_ kind: ProjectBlockKind, at frame: ProjectGridFrame? = nil) -> ProjectBlock {
        let size = kind.defaultSize
        var block = ProjectBlock(kind: kind, frame: frame ?? ProjectLayout.freeFrame(width: size.width, height: size.height, in: blocks))
        if kind == .todos {
            if todoLists.isEmpty { todoLists.append(ProjectTodoList(title: "ToDos")) }
            block.listID = todoLists.first { list in !blocks.contains { $0.listID == list.id } }?.id ?? todoLists[0].id
        }
        blocks.append(block)
        blocks = ProjectLayout.place(blocks, moving: block.id)
        return block
    }

    /// A chart block; the wide kinds (Gantt, course, flow) take the whole width.
    @discardableResult
    mutating func addChart(_ kind: ProjectChartKind, source: ProjectChartSource? = nil) -> ProjectBlock {
        let size: (Int, Int) = switch kind {
        case .gantt, .course: (12, 5)
        case .flow: (12, 4)
        default: ProjectBlockKind.chart.defaultSize
        }
        var block = ProjectBlock(kind: .chart, frame: ProjectLayout.freeFrame(width: size.0, height: size.1, in: blocks))
        block.chart = ProjectChart(kind: kind, source: source)
        blocks.append(block)
        blocks = ProjectLayout.place(blocks, moving: block.id)
        return block
    }

    mutating func updateBlock(_ id: UUID, _ change: (inout ProjectBlock) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let before = blocks[index].frame
        change(&blocks[index])
        if blocks[index].frame != before { blocks = ProjectLayout.place(blocks, moving: id) }
    }

    mutating func updateTask(_ id: UUID, _ change: (inout ProjectTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        tasks[index].updatedAt = Date()
    }

    mutating func updateTodo(_ id: UUID, _ change: (inout ProjectTodo) -> Void) {
        for list in todoLists.indices {
            if let index = todoLists[list].todos.firstIndex(where: { $0.id == id }) {
                change(&todoLists[list].todos[index])
                return
            }
        }
    }

    mutating func updateMilestone(_ id: UUID, _ change: (inout ProjectMilestone) -> Void) {
        guard let index = milestones.firstIndex(where: { $0.id == id }) else { return }
        change(&milestones[index])
        milestones[index].date = ProjectDay.normalized(milestones[index].date)
    }

    /// The list a to-do is in.
    func list(containing todoID: UUID) -> ProjectTodoList? {
        todoLists.first { $0.todos.contains { $0.id == todoID } }
    }

    func todo(_ id: UUID) -> ProjectTodo? {
        allTodos.first { $0.id == id }
    }

    /// Moves a task into a column, before `before` or at the column's end.
    mutating func moveTask(_ id: UUID, to column: UUID, before: UUID? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), self.column(column) != nil, before != id else { return }
        var task = tasks.remove(at: index)
        task.column = column
        task.updatedAt = Date()
        if let before, let target = tasks.firstIndex(where: { $0.id == before }) {
            tasks.insert(task, at: target)
        } else if let last = tasks.lastIndex(where: { $0.column == column }) {
            tasks.insert(task, at: last + 1)
        } else {
            tasks.append(task)
        }
    }

    /// Removes a column; its tasks go to the column beside it. The last column stays.
    mutating func removeColumn(_ id: UUID) {
        guard columns.count > 1, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns.remove(at: index)
        let fallback = columns[max(0, index - 1)].id
        for task in tasks.indices where tasks[task].column == id { tasks[task].column = fallback }
    }

    /// Takes a link out everywhere in the project (the thing was deleted, or the person asked for it).
    mutating func removeLinkEverywhere(_ ref: ProjectRef) {
        links.removeAll { $0 == ref }
        for index in tasks.indices { tasks[index].links.removeAll { $0 == ref } }
        for list in todoLists.indices {
            for todo in todoLists[list].todos.indices where todoLists[list].todos[todo].link == ref {
                todoLists[list].todos[todo].link = nil
            }
        }
    }

    /// Today's numbers into the history; one entry per day, changed in place while the day lasts.
    mutating func recordHistory(now: Date = Date()) {
        let day = ProjectDay.string(now)
        let tasksDone = tasks.filter(isFinished).count
        let todosDone = allTodos.filter(\.isDone).count
        let entry = ProjectHistoryDay(day: day, open: tasks.count - tasksDone + allTodos.count - todosDone, done: tasksDone + todosDone)
        if let last = history.last, last.day == day {
            history[history.count - 1] = entry
        } else if history.last.map({ $0.open != entry.open || $0.done != entry.done }) ?? (entry.open + entry.done > 0) {
            history.append(entry)
        }
        // About a year is plenty for the chart, and keeps the file small.
        if history.count > 400 { history.removeFirst(history.count - 400) }
    }
}
