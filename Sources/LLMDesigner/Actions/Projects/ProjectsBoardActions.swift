import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerProjectsBoardActions() {
        register(ProjectsTodoListAddAction.self)
        register(ProjectsTodoListDeleteAction.self)
        register(ProjectsTodoAddAction.self)
        register(ProjectsTodoCheckAction.self)
        register(ProjectsTodoUpdateAction.self)
        register(ProjectsTodoDeleteAction.self)
        register(ProjectsMilestoneAddAction.self)
        register(ProjectsMilestoneUpdateAction.self)
        register(ProjectsMilestoneDeleteAction.self)
        register(ProjectsColumnAddAction.self)
        register(ProjectsColumnUpdateAction.self)
        register(ProjectsColumnDeleteAction.self)
        register(ProjectsTaskListAction.self)
        register(ProjectsTaskAddAction.self)
        register(ProjectsTaskReadAction.self)
        register(ProjectsTaskUpdateAction.self)
        register(ProjectsTaskMoveAction.self)
        register(ProjectsTaskDeleteAction.self)
        register(ProjectsCriterionAddAction.self)
        register(ProjectsCriterionCheckAction.self)
        register(ProjectsCriterionDeleteAction.self)
        register(ProjectsImpedimentAddAction.self)
        register(ProjectsImpedimentUpdateAction.self)
        register(ProjectsImpedimentDeleteAction.self)
        register(ProjectsTaskLinkAction.self)
        register(ProjectsTaskUnlinkAction.self)
    }
}

private let taskProperty: JSONSchema = .string("Aufgabe (ID, Nummer oder Titel)")
private let columnProperty: JSONSchema = .string("Spalte (ID, Nummer oder Titel)")
private let todoProperty: JSONSchema = .string("ToDo (ID, Nummer oder Text)")
private let listProperty: JSONSchema = .string("ToDo-Liste (ID, Nummer oder Titel); ohne: die erste")
private let milestoneProperty: JSONSchema = .string("Meilenstein (ID, Nummer nach Datum oder Titel)")
private let dayProperty = { (text: String) in JSONSchema.string("\(text) als 2026-11-20; leer entfernt") }

// MARK: - Output

struct ProjectColumnOutput: Encodable, Sendable {
    var id: String
    var number: Int
    var title: String
    var color: String?
    var done: Bool
    var limit: Int?
    var tasks: Int
}

extension ProjectColumnOutput {
    init(_ column: ProjectColumn, in project: Project) {
        self.init(id: column.id.uuidString, number: (project.columns.firstIndex(of: column) ?? 0) + 1, title: column.displayTitle,
                  color: column.color?.rawValue, done: column.isDone, limit: column.limit, tasks: project.tasks(in: column.id).count)
    }
}

struct ProjectTaskOutput: Encodable, Sendable {
    struct Criterion: Encodable, Sendable {
        var id: String
        var number: Int
        var text: String
        var met: Bool
    }
    struct Impediment: Encodable, Sendable {
        var id: String
        var number: Int
        var text: String
        var solution: String?
        var resolved: Bool
    }
    var id: String
    var number: Int
    var title: String
    var column: String
    var columnTitle: String
    var done: Bool
    var priority: String
    var start: String?
    var due: String?
    var tags: [String]?
    var details: String?
    var criteria: [Criterion]
    var impediments: [Impediment]
    var links: [ProjectRefOutput]
    var acceptable: Bool
    var blocked: Bool
}

struct ProjectTodoListOutput: Encodable, Sendable {
    struct Todo: Encodable, Sendable {
        var id: String
        var number: Int
        var text: String
        var done: Bool
        var due: String?
        var link: ProjectRefOutput?
    }
    var id: String
    var title: String
    var progress: NoteProgressOutput
    var todos: [Todo]
}

struct ProjectMilestoneOutput: Encodable, Sendable {
    var id: String
    var title: String
    var date: String
    var done: Bool
    var color: String?
    var countdown: String
}

extension ProjectMilestoneOutput {
    init(_ milestone: ProjectMilestone) {
        self.init(id: milestone.id.uuidString, title: milestone.displayTitle, date: ProjectDay.string(milestone.date), done: milestone.isDone,
                  color: milestone.color?.rawValue, countdown: ProjectDay.countdown(milestone.date))
    }
}

@MainActor
extension AppModel {
    func actionTaskOutput(_ task: ProjectTask, in project: Project) -> ProjectTaskOutput {
        ProjectTaskOutput(
            id: task.id.uuidString, number: (project.tasks.firstIndex { $0.id == task.id } ?? 0) + 1, title: task.displayTitle,
            column: task.column.uuidString, columnTitle: project.column(task.column)?.displayTitle ?? "", done: project.isFinished(task),
            priority: task.priority.rawValue, start: task.start.map(ProjectDay.string), due: task.due.map(ProjectDay.string),
            tags: task.tags.isEmpty ? nil : task.tags, details: task.details.isEmpty ? nil : task.details,
            criteria: task.criteria.enumerated().map { .init(id: $1.id.uuidString, number: $0 + 1, text: $1.text, met: $1.isMet) },
            impediments: task.impediments.enumerated().map { .init(id: $1.id.uuidString, number: $0 + 1, text: $1.text, solution: $1.solution.isEmpty ? nil : $1.solution, resolved: $1.isResolved) },
            links: task.links.map { actionRefOutput($0) }, acceptable: task.isAcceptable, blocked: task.isBlocked)
    }

    func actionTodoListOutput(_ list: ProjectTodoList) -> ProjectTodoListOutput {
        ProjectTodoListOutput(id: list.id.uuidString, title: list.displayTitle, progress: NoteProgressOutput(NoteProgress(done: list.done, total: list.todos.count)),
                              todos: list.todos.enumerated().map { index, todo in
                                  .init(id: todo.id.uuidString, number: index + 1, text: todo.text, done: todo.isDone, due: todo.due.map(ProjectDay.string),
                                        link: todo.link.map { actionRefOutput($0) })
                              })
    }
}

// MARK: - To-do lists

struct ProjectsTodoListAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var title: String?
        var block: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var block: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todolist.add", summary: "Legt eine ToDo-Liste im Projekt an, auf Wunsch gleich mit einem Baustein auf der Seite", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "title": .string("Name der Liste"), "block": .boolean("Auch einen Baustein auf der Seite anlegen")], required: ["project"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        let list = ProjectTodoList(title: args.title ?? "ToDos")
        var blockID: UUID?
        try context.changeProject(project.id, label: "ToDo-Liste anlegen") { project in
            project.todoLists.append(list)
            if args.block == true {
                var block = project.addBlock(.todos)
                block.listID = list.id
                let made = block
                project.updateBlock(block.id) { $0 = made }
                blockID = block.id
            }
        }
        return Output(id: list.id.uuidString, block: blockID?.uuidString)
    }
}

struct ProjectsTodoListDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var list: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todolist.delete", summary: "Löscht eine ToDo-Liste mit ihren ToDos; Bausteine, die sie zeigen, bleiben leer stehen", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "list": listProperty], required: ["project", "list"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let list = try project.actionTodoList(args.list)
        try context.changeProject(project.id, label: "ToDo-Liste löschen") { project in
            project.todoLists.removeAll { $0.id == list.id }
            for index in project.blocks.indices where project.blocks[index].listID == list.id { project.blocks[index].listID = nil }
        }
        return OKOutput(id: list.id.uuidString)
    }
}

// MARK: - To-dos

struct ProjectsTodoAddAction: LLMDAction {
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var project: String
        var list: String?
        var text: String?
        var texts: [String]?
        var due: String?
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
    }
    struct Output: Encodable, Sendable {
        var ids: [String]
        var list: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todo.add", summary: "Fügt einer ToDo-Liste des Projekts ToDos hinzu, auf Wunsch mit Fälligkeit und Verknüpfung (gibt es keine Liste, entsteht eine)",
        kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "list": listProperty, "text": .string("Ein ToDo"), "texts": .array(of: .string(), "Mehrere ToDos"),
                        "due": dayProperty("Fällig")].merging(projectRefProperties) { $1 }, required: ["project"]),
        output: .freeObject(), example: "llmd projects todo add --project Hausarbeit --text \"Literatur sichten\" --due 2026-11-15", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let project = try app.actionProject(args.project)
        let texts = ([args.text].compactMap { $0 } + (args.texts ?? [])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { throw RPCError.invalidParams("text oder texts angeben.") }
        let due = try ProjectArgs.day(args.due, "due") ?? nil
        let ref = try app.actionProjectRef(args)
        let listID = try args.list.map { try project.actionTodoList($0).id }
        let todos = texts.map { ProjectTodo(text: $0, due: due, link: ref) }
        var target = listID ?? project.todoLists.first?.id ?? UUID()
        try context.changeProject(project.id, label: "ToDo hinzufügen") { project in
            if project.todoList(target) == nil {
                let list = ProjectTodoList(title: "ToDos")
                project.todoLists.append(list)
                target = list.id
            }
            if let index = project.todoLists.firstIndex(where: { $0.id == target }) { project.todoLists[index].todos += todos }
        }
        return Output(ids: todos.map(\.id.uuidString), list: target.uuidString)
    }
}

struct ProjectsTodoCheckAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var todo: String
        var list: String?
        var done: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todo.check", summary: "Hakt ein ToDo des Projekts ab (done: false öffnet es wieder)", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "todo": todoProperty, "list": listProperty, "done": .boolean("Erledigt (Vorgabe true)")], required: ["project", "todo"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let todo = try project.actionTodo(args.todo, list: args.list)
        try context.changeProject(project.id, label: args.done == false ? "ToDo wieder öffnen" : "ToDo abhaken") { $0.updateTodo(todo.id) { $0.isDone = args.done ?? true } }
        return OKOutput(id: todo.id.uuidString)
    }
}

struct ProjectsTodoUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var project: String
        var todo: String
        var list: String?
        var text: String?
        var due: String?
        var unlink: Bool?
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todo.update", summary: "Ändert Text, Fälligkeit oder Verknüpfung eines ToDos im Projekt", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "todo": todoProperty, "list": listProperty, "text": .string("Neuer Text"), "due": dayProperty("Fällig"),
                        "unlink": .boolean("Verknüpfung entfernen")].merging(projectRefProperties) { $1 }, required: ["project", "todo"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        let todo = try project.actionTodo(args.todo, list: args.list)
        let due = try ProjectArgs.day(args.due, "due")
        let ref = try app.actionProjectRef(args)
        guard args.text != nil || due != nil || ref != nil || args.unlink == true else { throw RPCError.invalidParams("Nichts zu ändern.") }
        try context.changeProject(project.id, label: "ToDo ändern") { project in
            project.updateTodo(todo.id) { todo in
                if let text = args.text { todo.text = text }
                if let due { todo.due = due }
                if let ref { todo.link = ref }
                if args.unlink == true { todo.link = nil }
            }
        }
        return OKOutput(id: todo.id.uuidString)
    }
}

struct ProjectsTodoDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var todo: String
        var list: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.todo.delete", summary: "Löscht ein ToDo des Projekts", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "todo": todoProperty, "list": listProperty], required: ["project", "todo"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let todo = try project.actionTodo(args.todo, list: args.list)
        try context.changeProject(project.id, label: "ToDo löschen") { project in
            for index in project.todoLists.indices { project.todoLists[index].todos.removeAll { $0.id == todo.id } }
        }
        return OKOutput(id: todo.id.uuidString)
    }
}

// MARK: - Milestones

struct ProjectsMilestoneAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var title: String
        var date: String
        var done: Bool?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.milestone.add", summary: "Legt einen Meilenstein an (Abgabe, Referat, Probedruck …)", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "title": .string("Name"), "date": .string("Datum als 2026-11-20"), "done": .boolean("Schon erreicht"),
                        "color": ProjectArgs.colorSchema], required: ["project", "title", "date"]),
        output: .freeObject(), example: "llmd projects milestone add --project Hausarbeit --title Abgabe --date 2026-11-20", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        guard let date = try ProjectArgs.day(args.date, "date") ?? nil else { throw RPCError.invalidParams("date angeben.") }
        var milestone = ProjectMilestone(title: args.title, date: date, isDone: args.done ?? false)
        milestone.color = try ProjectArgs.color(args.color) ?? nil
        let made = milestone
        try context.changeProject(project.id, label: "Meilenstein anlegen") { $0.milestones.append(made) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct ProjectsMilestoneUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var milestone: String
        var title: String?
        var date: String?
        var done: Bool?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.milestone.update", summary: "Ändert einen Meilenstein oder hakt ihn ab (done)", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "milestone": milestoneProperty, "title": .string("Name"), "date": .string("Datum als 2026-11-20"),
                        "done": .boolean("Erreicht"), "color": ProjectArgs.colorSchema], required: ["project", "milestone"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let milestone = try project.actionMilestone(args.milestone)
        let date = try ProjectArgs.day(args.date, "date")
        let color = try ProjectArgs.color(args.color)
        guard args.title != nil || date != nil || args.done != nil || color != nil else { throw RPCError.invalidParams("Nichts zu ändern.") }
        try context.changeProject(project.id, label: "Meilenstein ändern") { project in
            project.updateMilestone(milestone.id) { milestone in
                if let title = args.title { milestone.title = title }
                if let date, let day = date { milestone.date = day }
                if let done = args.done { milestone.isDone = done }
                if let color { milestone.color = color }
            }
        }
        return OKOutput(id: milestone.id.uuidString)
    }
}

struct ProjectsMilestoneDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var milestone: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.milestone.delete", summary: "Löscht einen Meilenstein", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "milestone": milestoneProperty], required: ["project", "milestone"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let milestone = try project.actionMilestone(args.milestone)
        try context.changeProject(project.id, label: "Meilenstein löschen") { $0.milestones.removeAll { $0.id == milestone.id } }
        return OKOutput(id: milestone.id.uuidString)
    }
}

// MARK: - Columns

struct ProjectsColumnAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var title: String
        var color: String?
        var done: Bool?
        var limit: Int?
        var position: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.column.add", summary: "Legt eine Spalte im Aufgaben-Board an; done: Aufgaben darin gelten als erledigt, limit: höchstens so viele Aufgaben",
        kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "title": .string("Name"), "color": ProjectArgs.colorSchema, "done": .boolean("Zählt als erledigt"),
                        "limit": .integer("WIP-Limit", minimum: 0), "position": .integer("Platz ab 1; ohne: vor den erledigten Spalten", minimum: 1)],
                       required: ["project", "title"]),
        output: .freeObject(), example: "llmd projects column add --project Hausarbeit --title Review --limit 2", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let color = try ProjectArgs.color(args.color) ?? nil
        let column = ProjectColumn(title: args.title, color: color ?? Project.chartColors[project.columns.count % Project.chartColors.count],
                                   isDone: args.done ?? false, limit: args.limit.flatMap { $0 > 0 ? $0 : nil })
        try context.changeProject(project.id, label: "Spalte anlegen") { project in
            let index = args.position.map { min(max($0 - 1, 0), project.columns.count) } ?? (project.columns.firstIndex(where: \.isDone) ?? project.columns.count)
            project.columns.insert(column, at: index)
        }
        return OKOutput(id: column.id.uuidString)
    }
}

struct ProjectsColumnUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var column: String
        var title: String?
        var color: String?
        var done: Bool?
        var limit: Int?
        var position: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.column.update", summary: "Ändert eine Spalte: Name, Farbe, ob sie als erledigt zählt, WIP-Limit (0 entfernt), Platz", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "column": columnProperty, "title": .string("Name"), "color": ProjectArgs.colorSchema,
                        "done": .boolean("Zählt als erledigt"), "limit": .integer("WIP-Limit, 0 entfernt", minimum: 0), "position": .integer("Platz ab 1", minimum: 1)],
                       required: ["project", "column"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let column = try project.actionColumn(args.column)
        let color = try ProjectArgs.color(args.color)
        guard args.title != nil || color != nil || args.done != nil || args.limit != nil || args.position != nil else { throw RPCError.invalidParams("Nichts zu ändern.") }
        try context.changeProject(project.id, label: "Spalte ändern") { project in
            guard var index = project.columns.firstIndex(where: { $0.id == column.id }) else { return }
            if let title = args.title { project.columns[index].title = title }
            if let color { project.columns[index].color = color }
            if let done = args.done { project.columns[index].isDone = done }
            if let limit = args.limit { project.columns[index].limit = limit > 0 ? limit : nil }
            if let position = args.position {
                let moved = project.columns.remove(at: index)
                index = min(max(position - 1, 0), project.columns.count)
                project.columns.insert(moved, at: index)
            }
        }
        return OKOutput(id: column.id.uuidString)
    }
}

struct ProjectsColumnDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var column: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.column.delete", summary: "Löscht eine Spalte; ihre Aufgaben kommen in die Spalte davor. Die letzte Spalte bleibt", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "column": columnProperty], required: ["project", "column"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let column = try project.actionColumn(args.column)
        guard project.columns.count > 1 else { throw RPCError.invalidTarget("Das Board braucht mindestens eine Spalte.") }
        try context.changeProject(project.id, label: "Spalte löschen") { $0.removeColumn(column.id) }
        return OKOutput(id: column.id.uuidString)
    }
}

// MARK: - Tasks

struct ProjectsTaskListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var column: String?
        var query: String?
        var blocked: Bool?
        var open: Bool?
    }
    struct Output: Encodable, Sendable {
        var columns: [ProjectColumnOutput]
        var tasks: [ProjectTaskOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.list", summary: "Listet die Aufgaben des Boards, auf Wunsch einer Spalte, nur offene oder nur die mit Hindernis",
        kind: .read, security: projectRead,
        input: .object(["project": projectProperty, "column": columnProperty, "query": .string("Suche in Titel, Beschreibung, Etiketten"),
                        "blocked": .boolean("Nur mit offenem Hindernis"), "open": .boolean("Nur nicht erledigte")], required: ["project"]),
        output: .freeObject(), example: "llmd projects task list --project Hausarbeit --blocked true", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let project = try app.actionProject(args.project)
        let column = try args.column.map { try project.actionColumn($0).id }
        let tasks = project.tasks.filter { task in
            (column.map { task.column == $0 } ?? true) && task.matches(args.query ?? "")
                && (args.blocked != true || task.isBlocked) && (args.open != true || !project.isFinished(task))
        }
        return Output(columns: project.columns.map { ProjectColumnOutput($0, in: project) }, tasks: tasks.map { app.actionTaskOutput($0, in: project) })
    }
}

struct ProjectsTaskAddAction: LLMDAction {
    struct ImpedimentInput: Decodable, Sendable {
        var text: String
        var solution: String?
    }
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var project: String
        var title: String
        var column: String?
        var details: String?
        var priority: String?
        var start: String?
        var due: String?
        var tags: [String]?
        var criteria: [String]?
        var impediments: [ImpedimentInput]?
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var column: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.add", summary: "Legt eine Aufgabe im Board an: Spalte, Beschreibung, Priorität, Start, Fälligkeit, Etiketten, Akzeptanzkriterien, Hindernisse und eine Verknüpfung",
        kind: .write, security: .localWrite,
        input: .object([
            "project": projectProperty, "title": .string("Titel"), "column": .string("Spalte (ohne: die erste, die nicht als erledigt zählt)"),
            "details": .string("Beschreibung"), "priority": .choice(ProjectPriority.allCases.map(\.rawValue), "Priorität (Vorgabe mittel)"),
            "start": dayProperty("Start"), "due": dayProperty("Fällig"), "tags": .array(of: .string(), "Etiketten"),
            "criteria": .array(of: .string(), "Akzeptanzkriterien: woran man erkennt, dass die Aufgabe abgenommen werden kann"),
            "impediments": .array(of: .freeObject("{text, solution}"), "Hindernisse und wie sie sich beheben lassen"),
        ].merging(projectRefProperties) { $1 }, required: ["project", "title"]),
        output: .freeObject(), example: "llmd projects task add --project Hausarbeit --title \"Kapitel 3\" --criteria \"Quellen geprüft\" --doc Hausarbeit",
        groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let project = try app.actionProject(args.project)
        let column = try args.column.map { try project.actionColumn($0) } ?? project.columns.first { !$0.isDone } ?? project.columns[0]
        var task = ProjectTask(title: args.title, column: column.id)
        task.details = args.details ?? ""
        task.priority = try ProjectArgs.choice(args.priority, ProjectPriority.allCases, raw: \.rawValue, "Priorität") ?? .normal
        task.start = try ProjectArgs.day(args.start, "start") ?? nil
        task.due = try ProjectArgs.day(args.due, "due") ?? nil
        task.tags = (args.tags ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        task.criteria = (args.criteria ?? []).map { ProjectCriterion(text: $0) }
        task.impediments = (args.impediments ?? []).map { ProjectImpediment(text: $0.text, solution: $0.solution ?? "") }
        if let ref = try app.actionProjectRef(args) { task.links = [ref] }
        let made = task
        try context.changeProject(project.id, label: "Aufgabe anlegen") { $0.tasks.append(made) }
        return Output(id: made.id.uuidString, column: column.displayTitle)
    }
}

struct ProjectsTaskArgs: Decodable, Sendable {
    var project: String
    var task: String
}

private let taskInput: JSONSchema = .object(["project": projectProperty, "task": taskProperty], required: ["project", "task"])

struct ProjectsTaskReadAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.task.read", summary: "Liest eine Aufgabe mit Beschreibung, Akzeptanzkriterien, Hindernissen und Verknüpfungen", kind: .read, security: projectRead,
        input: taskInput, output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: ProjectsTaskArgs, context: ActionContext) async throws -> ProjectTaskOutput {
        let project = try context.app.actionProject(args.project)
        return context.app.actionTaskOutput(try project.actionTask(args.task), in: project)
    }
}

struct ProjectsTaskUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var title: String?
        var details: String?
        var appendDetails: String?
        var priority: String?
        var start: String?
        var due: String?
        var tags: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.update", summary: "Ändert Titel, Beschreibung, Priorität, Start, Fälligkeit oder Etiketten einer Aufgabe", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "task": taskProperty, "title": .string("Titel"), "details": .string("Beschreibung ersetzen"),
                        "appendDetails": .string("An die Beschreibung anhängen"), "priority": .choice(ProjectPriority.allCases.map(\.rawValue), "Priorität"),
                        "start": dayProperty("Start"), "due": dayProperty("Fällig"), "tags": .array(of: .string(), "Etiketten (ersetzt)")],
                       required: ["project", "task"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let priority = try ProjectArgs.choice(args.priority, ProjectPriority.allCases, raw: \.rawValue, "Priorität")
        let start = try ProjectArgs.day(args.start, "start")
        let due = try ProjectArgs.day(args.due, "due")
        guard args.title != nil || args.details != nil || args.appendDetails != nil || priority != nil || start != nil || due != nil || args.tags != nil else {
            throw RPCError.invalidParams("Nichts zu ändern.")
        }
        try context.changeProject(project.id, label: "Aufgabe ändern") { project in
            project.updateTask(task.id) { task in
                if let title = args.title { task.title = title }
                if let details = args.details { task.details = details }
                if let more = args.appendDetails { task.details = task.details.isEmpty ? more : task.details + "\n" + more }
                if let priority { task.priority = priority }
                if let start { task.start = start }
                if let due { task.due = due }
                if let tags = args.tags { task.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }
        }
        return OKOutput(id: task.id.uuidString)
    }
}

struct ProjectsTaskMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var column: String
        var before: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var column: String
        var done: Bool
        var acceptable: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.move", summary: "Zieht eine Aufgabe in eine Spalte, ans Ende oder vor eine andere Aufgabe", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "task": taskProperty, "column": columnProperty, "before": .string("Aufgabe, vor die sie kommt")],
                       required: ["project", "task", "column"]),
        output: .freeObject(), example: "llmd projects task move --project Hausarbeit --task \"Kapitel 3\" --column Erledigt", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let column = try project.actionColumn(args.column)
        let before = try args.before.map { try project.actionTask($0) }
        if let before, before.column != column.id { throw RPCError.invalidParams("Die Aufgabe in before steht in einer anderen Spalte.") }
        let after = try context.changeProject(project.id, label: "Aufgabe verschieben") { $0.moveTask(task.id, to: column.id, before: before?.id) }
        let moved = after.task(task.id) ?? task
        return Output(id: task.id.uuidString, column: column.displayTitle, done: after.isFinished(moved), acceptable: moved.isAcceptable)
    }
}

struct ProjectsTaskDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.task.delete", summary: "Löscht eine Aufgabe; was sie verknüpft, bleibt", kind: .destructive, security: .destructive,
        input: taskInput, output: .freeObject()
    )
    static func preflight(_ args: ProjectsTaskArgs, context: ActionContext) throws -> ActionPreflight {
        let project = try context.app.actionProject(args.project)
        return ActionPreflight(target: "\(project.displayTitle) › \(try project.actionTask(args.task).displayTitle)")
    }
    static func run(_ args: ProjectsTaskArgs, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        try context.changeProject(project.id, label: "Aufgabe löschen") { $0.tasks.removeAll { $0.id == task.id } }
        return OKOutput(id: task.id.uuidString)
    }
}

// MARK: - Acceptance criteria

struct ProjectsCriterionAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var text: String?
        var texts: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.criterion.add", summary: "Fügt einer Aufgabe Akzeptanzkriterien hinzu: woran man erkennt, dass sie abgenommen werden kann", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "task": taskProperty, "text": .string("Ein Kriterium"), "texts": .array(of: .string(), "Mehrere Kriterien")], required: ["project", "task"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let texts = ([args.text].compactMap { $0 } + (args.texts ?? [])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { throw RPCError.invalidParams("text oder texts angeben.") }
        try context.changeProject(project.id, label: "Kriterium hinzufügen") { $0.updateTask(task.id) { $0.criteria += texts.map { ProjectCriterion(text: $0) } } }
        return OKOutput(id: task.id.uuidString)
    }
}

struct ProjectsCriterionArgs: Decodable, Sendable {
    var project: String
    var task: String
    var criterion: String
    var met: Bool?
}

private let criterionInput: JSONSchema = .object(["project": projectProperty, "task": taskProperty, "criterion": .string("Kriterium (ID, Nummer oder Text)"),
                                                  "met": .boolean("Erfüllt (Vorgabe true)")], required: ["project", "task", "criterion"])

struct ProjectsCriterionCheckAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var id: String
        var met: Int
        var total: Int
        var acceptable: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.criterion.check", summary: "Hakt ein Akzeptanzkriterium ab (met: false öffnet es wieder); sagt, ob die Aufgabe abnahmebereit ist", kind: .write, security: .localWrite,
        input: criterionInput, output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: ProjectsCriterionArgs, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let criterion = try task.actionCriterion(args.criterion)
        let after = try context.changeProject(project.id, label: args.met == false ? "Kriterium offen" : "Kriterium erfüllt") { project in
            project.updateTask(task.id) { task in
                if let index = task.criteria.firstIndex(where: { $0.id == criterion.id }) { task.criteria[index].isMet = args.met ?? true }
            }
        }
        let changed = after.task(task.id) ?? task
        return Output(id: criterion.id.uuidString, met: changed.criteriaMet, total: changed.criteria.count, acceptable: changed.isAcceptable)
    }
}

struct ProjectsCriterionDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.task.criterion.delete", summary: "Entfernt ein Akzeptanzkriterium", kind: .destructive, security: .destructive,
        input: criterionInput, output: .freeObject()
    )
    static func run(_ args: ProjectsCriterionArgs, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let criterion = try task.actionCriterion(args.criterion)
        try context.changeProject(project.id, label: "Kriterium entfernen") { $0.updateTask(task.id) { $0.criteria.removeAll { $0.id == criterion.id } } }
        return OKOutput(id: criterion.id.uuidString)
    }
}

// MARK: - Impediments

struct ProjectsImpedimentAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var text: String
        var solution: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.impediment.add", summary: "Hält ein Hindernis einer Aufgabe fest, auf Wunsch mit dem Weg, es zu beheben", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "task": taskProperty, "text": .string("Was aufhält"), "solution": .string("Wie es sich beheben lässt")],
                       required: ["project", "task", "text"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let impediment = ProjectImpediment(text: args.text, solution: args.solution ?? "")
        try context.changeProject(project.id, label: "Hindernis hinzufügen") { $0.updateTask(task.id) { $0.impediments.append(impediment) } }
        return OKOutput(id: impediment.id.uuidString)
    }
}

struct ProjectsImpedimentUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var impediment: String
        var text: String?
        var solution: String?
        var resolved: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.impediment.update", summary: "Ändert ein Hindernis, trägt die Lösung ein oder markiert es als behoben (resolved)", kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "task": taskProperty, "impediment": .string("Hindernis (ID, Nummer oder Text)"), "text": .string("Was aufhält"),
                        "solution": .string("Wie es sich beheben lässt"), "resolved": .boolean("Behoben")], required: ["project", "task", "impediment"]),
        output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let impediment = try task.actionImpediment(args.impediment)
        guard args.text != nil || args.solution != nil || args.resolved != nil else { throw RPCError.invalidParams("Nichts zu ändern.") }
        try context.changeProject(project.id, label: args.resolved == true ? "Hindernis behoben" : "Hindernis ändern") { project in
            project.updateTask(task.id) { task in
                guard let index = task.impediments.firstIndex(where: { $0.id == impediment.id }) else { return }
                if let text = args.text { task.impediments[index].text = text }
                if let solution = args.solution { task.impediments[index].solution = solution }
                if let resolved = args.resolved { task.impediments[index].isResolved = resolved }
            }
        }
        return OKOutput(id: impediment.id.uuidString)
    }
}

struct ProjectsImpedimentDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var task: String
        var impediment: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.task.impediment.delete", summary: "Entfernt ein Hindernis", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "task": taskProperty, "impediment": .string("Hindernis (ID, Nummer oder Text)")], required: ["project", "task", "impediment"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let impediment = try task.actionImpediment(args.impediment)
        try context.changeProject(project.id, label: "Hindernis entfernen") { $0.updateTask(task.id) { $0.impediments.removeAll { $0.id == impediment.id } } }
        return OKOutput(id: impediment.id.uuidString)
    }
}

// MARK: - Task links

struct ProjectsTaskLinkArgs: Decodable, Sendable, ProjectRefArguments {
    var project: String
    var task: String
    var chat: String?
    var doc: String?
    var note: String?
    var world: String?
    var part: String?
    var element: String?
}

private let taskLinkInput: JSONSchema = .object(["project": projectProperty, "task": taskProperty].merging(projectRefProperties) { $1 }, required: ["project", "task"])

struct ProjectsTaskLinkAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.task.link", summary: "Verknüpft eine Aufgabe mit einem Chat, Dokument, einer Präsentation, einem Note oder einer Romanwelt (Teil, Element)",
        kind: .write, security: .localWrite, input: taskLinkInput, output: .freeObject(),
        example: "llmd projects task link --project Roman --task Überarbeitung --world Eisland --part \"Buch 1/Kapitel 3\"", groups: ["projects.core"]
    )
    static func run(_ args: ProjectsTaskLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        guard let ref = try app.actionProjectRef(args) else { throw RPCError.invalidParams("chat, doc, note oder world angeben.") }
        guard !task.links.contains(ref) else { return OKOutput(id: task.id.uuidString, message: "War schon verknüpft.") }
        try context.changeProject(project.id, label: "Mit Aufgabe verknüpfen") { $0.updateTask(task.id) { $0.links.append(ref) } }
        return OKOutput(id: task.id.uuidString)
    }
}

struct ProjectsTaskUnlinkAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.task.unlink", summary: "Löst eine Verknüpfung der Aufgabe; das Verknüpfte bleibt. Gelöschtes lässt sich über seine ID lösen",
        kind: .write, security: .localWrite, input: taskLinkInput, output: .freeObject()
    )
    static func run(_ args: ProjectsTaskLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        let task = try project.actionTask(args.task)
        let ref = try app.actionProjectRef(args, in: project)
        guard task.links.contains(ref) else { throw RPCError.invalidTarget("Die Aufgabe ist damit nicht verknüpft.") }
        try context.changeProject(project.id, label: "Verknüpfung lösen") { $0.updateTask(task.id) { $0.links.removeAll { $0 == ref } } }
        return OKOutput(id: task.id.uuidString)
    }
}
