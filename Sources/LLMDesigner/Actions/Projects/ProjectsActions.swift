import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerProjectsActions() {
        register(ProjectsProjectListAction.self)
        register(ProjectsProjectCreateAction.self)
        register(ProjectsProjectReadAction.self)
        register(ProjectsProjectUpdateAction.self)
        register(ProjectsProjectDeleteAction.self)
        register(ProjectsProjectProgressAction.self)
        register(ProjectsLinkAddAction.self)
        register(ProjectsLinkRemoveAction.self)
        register(ProjectsLinkFindAction.self)
        register(ProjectsBlockListAction.self)
        register(ProjectsBlockAddAction.self)
        register(ProjectsBlockUpdateAction.self)
        register(ProjectsBlockMoveAction.self)
        register(ProjectsBlockDeleteAction.self)
        register(ProjectsBlockEntriesAction.self)
        register(ProjectsStylesListAction.self)
        register(ProjectsStudioOpenAction.self)
        register(ProjectsStudioCloseAction.self)
        registerProjectsBoardActions()
    }
}

/// Projects have no origin of their own, and agents can write into them: reading one counts as reading something
/// foreign, as with notes and novel worlds.
let projectRead = ActionSecurity.foreignRead

let projectProperty: JSONSchema = .string("Projekt (ID oder Titel)")

/// The arguments that name something to link: exactly one of chat, doc, note or world (with part or element).
let projectRefProperties: [String: JSONSchema] = [
    "chat": .string("Chat (ID oder Titel)"),
    "doc": .string("Writer-Dokument oder Präsentation (ID oder Titel)"),
    "note": .string("Note (ID oder Titel)"),
    "world": .string("Romanwelt (ID oder Titel)"),
    "part": .string("Teil der Romanwelt (ID oder Pfad wie Buch 1/Akt 2), mit world"),
    "element": .string("Element der Romanwelt als art:name, z. B. figure:Mara, mit world"),
]

protocol ProjectRefArguments {
    var chat: String? { get }
    var doc: String? { get }
    var note: String? { get }
    var world: String? { get }
    var part: String? { get }
    var element: String? { get }
}

extension ProjectRefArguments {
    var namesRef: Bool { chat != nil || doc != nil || note != nil || world != nil }
}

// MARK: - Finding

extension AppModel {
    func actionProject(_ reference: String) throws -> Project {
        projects.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let project = projects.project(id) else { throw RPCError.notFound("Projekt \(reference) gibt es nicht.") }
            return project
        }
        let found = projects.projects.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Projekt „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Projekte heißen „\(reference)“. Bitte die ID verwenden.", candidates: found.map(\.id.uuidString))
    }

    /// The thing a call names, or nil when it names none.
    func actionProjectRef(_ args: ProjectRefArguments) throws -> ProjectRef? {
        let named = [args.chat, args.doc, args.note, args.world].compactMap { $0 }
        guard !named.isEmpty else {
            if args.part != nil || args.element != nil { throw RPCError.invalidParams("Für part oder element bitte auch world angeben.") }
            return nil
        }
        guard named.count == 1 else { throw RPCError.invalidParams("Nur eines angeben: chat, doc, note oder world.") }
        if let chat = args.chat { return .chat(try actionChat(chat).id) }
        if let doc = args.doc { return .document(try actionDocumentOrDeck(doc).id) }
        if let note = args.note { return .note(try actionNote(note).id) }
        guard let reference = args.world else { return nil }
        let world = try actionWorld(reference)
        guard args.part == nil || args.element == nil else { throw RPCError.invalidParams("Entweder part oder element angeben, nicht beides.") }
        return .story(world: world.id, part: try args.part.map { try world.actionPart($0).id }, element: try args.element.map { try world.actionElement($0) })
    }

    /// Like `actionProjectRef`, but a thing that was deleted is found among the project's links by its id.
    func actionProjectRef(_ args: ProjectRefArguments, in project: Project) throws -> ProjectRef {
        for id in [args.chat, args.doc, args.note].compactMap({ $0 }).compactMap(UUID.init(uuidString:)) {
            if let known = project.linkUses.map(\.ref).first(where: { $0.targetID == id }) { return known }
        }
        guard let ref = try actionProjectRef(args) else { throw RPCError.invalidParams("chat, doc, note oder world angeben.") }
        return ref
    }

    func actionRefOutput(_ ref: ProjectRef) -> ProjectRefOutput {
        var output = ProjectRefOutput(kind: ref.art, id: ref.targetID.uuidString, title: projectRefTitle(ref), exists: projectRefExists(ref))
        if case .document(let id) = ref, document(id)?.isPresentation == true { output.kind = "praesentation" }
        if case .story(let world, let part, let element) = ref {
            output.world = world.uuidString
            output.part = part?.uuidString
            output.element = element.map { "\($0.kind.rawValue):\($0.id.uuidString)" }
        }
        return output
    }
}

/// Finds things within a project by id, by number (1-based, as the outputs show them) or by a unique title.
private func pick<T>(_ items: [T], _ reference: String, what: String, id: (T) -> UUID, title: (T) -> String) throws -> T {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let uuid = UUID(uuidString: reference), let found = items.first(where: { id($0) == uuid }) { return found }
    if let number = Int(reference), number >= 1, number <= items.count { return items[number - 1] }
    let matching = items.filter { title($0).trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(reference) == .orderedSame }
    if matching.count == 1 { return matching[0] }
    if matching.isEmpty { throw RPCError.notFound("\(what) „\(reference)“ gibt es nicht.") }
    throw RPCError.ambiguous("Mehrere heißen „\(reference)“. Bitte die ID verwenden.", candidates: matching.map { id($0).uuidString })
}

extension Project {
    func actionTask(_ reference: String) throws -> ProjectTask {
        try pick(tasks, reference, what: "Aufgabe", id: \.id, title: \.title)
    }

    func actionColumn(_ reference: String) throws -> ProjectColumn {
        try pick(columns, reference, what: "Spalte", id: \.id, title: \.displayTitle)
    }

    func actionBlock(_ reference: String) throws -> ProjectBlock {
        try pick(blocks, reference, what: "Baustein", id: \.id, title: \.headline)
    }

    func actionTodoList(_ reference: String) throws -> ProjectTodoList {
        try pick(todoLists, reference, what: "ToDo-Liste", id: \.id, title: \.displayTitle)
    }

    func actionTodo(_ reference: String, list: String? = nil) throws -> ProjectTodo {
        let todos = try list.map { try actionTodoList($0).todos } ?? allTodos
        return try pick(todos, reference, what: "ToDo", id: \.id, title: \.text)
    }

    func actionMilestone(_ reference: String) throws -> ProjectMilestone {
        try pick(sortedMilestones, reference, what: "Meilenstein", id: \.id, title: \.displayTitle)
    }
}

extension ProjectTask {
    func actionCriterion(_ reference: String) throws -> ProjectCriterion {
        try pick(criteria, reference, what: "Kriterium", id: \.id, title: \.text)
    }

    func actionImpediment(_ reference: String) throws -> ProjectImpediment {
        try pick(impediments, reference, what: "Hindernis", id: \.id, title: \.text)
    }
}

extension ActionContext {
    /// A change to a project with an undo step, as one call.
    @discardableResult
    func changeProject(_ id: UUID, label: String, _ change: (inout Project) throws -> Void) throws -> Project {
        let library = app.projects
        library.commitDrafts(of: id)
        guard let before = library.project(id) else { throw RPCError.notFound("Das Projekt gibt es nicht mehr.") }
        var project = before
        try change(&project)
        let wanted = project
        library.update(id) { $0 = wanted }
        let after = library.project(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.update(id) { $0 = before } }, redo: { [weak library] in library?.update(id) { $0 = after } }))
        registry.eventSink?(ActionEvent(kind: "project.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
        return after
    }
}

// MARK: - Parsing

enum ProjectArgs {
    /// "2026-11-20"; an empty text clears the day.
    static func day(_ text: String?, _ name: String) throws -> Date?? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let date = ProjectDay.date(trimmed) else { throw RPCError.invalidParams("\(name) als Datum wie 2026-11-20 angeben.") }
        return .some(date)
    }

    static func color(_ text: String?) throws -> FolderColor?? {
        guard let text else { return nil }
        if text.isEmpty || text == "standard" { return .some(nil) }
        guard let color = FolderColor(rawValue: text) else {
            throw RPCError.invalidParams("Farbe „\(text)“ gibt es nicht. Möglich: \(FolderColor.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return .some(color)
    }

    static func choice<T>(_ text: String?, _ all: [T], raw: (T) -> String, _ name: String) throws -> T? {
        guard let text else { return nil }
        guard let found = all.first(where: { raw($0) == text }) else {
            throw RPCError.invalidParams("\(name) „\(text)“ gibt es nicht. Möglich: \(all.map(raw).joined(separator: ", ")).")
        }
        return found
    }

    static let colorSchema: JSONSchema = .choice(["standard"] + FolderColor.allCases.map(\.rawValue), "Farbe")
}

// MARK: - Output

struct ProjectRefOutput: Encodable, Sendable {
    var kind: String
    var id: String
    var world: String?
    var part: String?
    var element: String?
    var title: String?
    var exists: Bool
}

struct ProjectSummaryOutput: Encodable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var status: String
    var color: String
    var progress: NoteProgressOutput
    var openTasks: Int
    var tasks: Int
    var nextMilestone: String?
    var updated: String
}

struct ProjectBlockOutput: Encodable, Sendable {
    struct Chart: Encodable, Sendable {
        var kind: String
        var source: String
        var entries: Int
    }
    var id: String
    var number: Int
    var kind: String
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var title: String?
    var headline: String
    var text: String?
    var measure: String?
    var display: String?
    var list: String?
    var chart: Chart?
    var date: String?
    var color: String?
    var value: Double?
    var style: ProjectTextStyle?
}

extension Project {
    func actionSummary() -> ProjectSummaryOutput {
        ProjectSummaryOutput(id: id.uuidString, title: displayTitle, subtitle: subtitle.isEmpty ? nil : subtitle, status: status.rawValue, color: color.rawValue,
                             progress: NoteProgressOutput(overallProgress), openTasks: tasks.filter { !isFinished($0) }.count, tasks: tasks.count,
                             nextMilestone: nextMilestone.map { "\($0.displayTitle) (\(ProjectDay.string($0.date)), \(ProjectDay.countdown($0.date)))" },
                             updated: updatedAt.formatted(.iso8601))
    }

    func actionBlocks() -> [ProjectBlockOutput] {
        blocks.enumerated().map { index, block in
            let usesMeasure = block.kind == .progress || block.kind == .metric
            return ProjectBlockOutput(id: block.id.uuidString, number: index + 1, kind: block.kind.rawValue, x: block.frame.x, y: block.frame.y,
                                      width: block.frame.width, height: block.frame.height, title: block.title.isEmpty ? nil : block.title, headline: block.headline,
                                      text: block.text.isEmpty ? nil : block.text, measure: usesMeasure ? block.measure.rawValue : nil,
                                      display: block.kind == .progress ? block.progressStyle.rawValue : nil, list: block.listID?.uuidString,
                                      chart: block.chart.map { .init(kind: $0.kind.rawValue, source: $0.source.rawValue, entries: $0.entries.count) },
                                      date: block.date.map(ProjectDay.string), color: block.tint?.rawValue, value: block.value,
                                      style: block.style.isPlain ? nil : block.style)
        }
    }
}

// MARK: - Projects

struct ProjectsProjectListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
        var status: String?
    }
    struct Output: Encodable, Sendable {
        var projects: [ProjectSummaryOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.project.list", summary: "Listet die Projekte mit Status, Fortschritt, offenen Aufgaben und nächstem Meilenstein",
        kind: .read, security: projectRead,
        input: .object(["query": .string("Suche in Titel, Untertitel, Aufgaben und Texten"), "status": .choice(ProjectStatus.allCases.map(\.rawValue), "Nur Projekte mit diesem Status")]),
        output: .freeObject(), example: "llmd projects project list --status laeuft", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.projects.loadIfNeeded()
        let status = try ProjectArgs.choice(args.status, ProjectStatus.allCases, raw: \.rawValue, "Status")
        let shown = app.projects.projects.filter { ($0.status == status || status == nil) && $0.matches(args.query ?? "") }
        return Output(projects: shown.map { $0.actionSummary() })
    }
}

struct ProjectsProjectCreateAction: LLMDAction {
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var title: String?
        var subtitle: String?
        var status: String?
        var color: String?
        var symbol: String?
        var empty: Bool?
        var columns: [String]?
        var open: Bool?
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var blocks: Int
        var columns: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.project.create", summary: "Legt ein Projekt an: mit einer Startseite (Text, Fortschritt, Countdown, ToDos, Meilensteine, Board) oder leer; auf Wunsch mit eigenen Spalten und einer ersten Verknüpfung",
        kind: .write, security: .localWrite,
        input: .object([
            "title": .string("Titel"), "subtitle": .string("Untertitel oder Ziel"), "status": .choice(ProjectStatus.allCases.map(\.rawValue), "Status (Vorgabe laeuft)"),
            "color": ProjectArgs.colorSchema, "symbol": .string("SF-Symbol, z. B. graduationcap"), "empty": .boolean("Ohne Startseite: keine Bausteine"),
            "columns": .array(of: .string(), "Eigene Spalten des Boards; die letzte zählt als erledigt"), "open": .boolean("Gleich öffnen"),
        ].merging(projectRefProperties) { $1 }),
        output: .freeObject(), example: "llmd projects project create --title \"Hausarbeit Statistik\" --columns Offen --columns \"In Arbeit\" --columns Fertig",
        groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let ref = try app.actionProjectRef(args)
        let status = try ProjectArgs.choice(args.status, ProjectStatus.allCases, raw: \.rawValue, "Status")
        let color = try ProjectArgs.color(args.color)
        var project = Project.starter(title: args.title ?? "")
        project.color = (color ?? nil) ?? FolderColor.allCases[app.projects.projects.count % FolderColor.allCases.count]
        if let subtitle = args.subtitle { project.subtitle = subtitle }
        if let status { project.status = status }
        if let symbol = args.symbol, !symbol.isEmpty { project.symbol = symbol }
        if args.empty == true {
            project.blocks = []
        }
        if let columns = args.columns?.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }), !columns.isEmpty {
            project.columns = columns.enumerated().map { index, title in
                ProjectColumn(title: title, color: Project.chartColors[index % Project.chartColors.count], isDone: index == columns.count - 1)
            }
        }
        if let ref { project.links = [ref] }
        let made = app.projects.add(project)
        let library = app.projects
        context.undoGroup.add(UndoStep(label: "Projekt anlegen", undo: { [weak library] in library?.deleteProject(made.id) }, redo: { [weak library] in library?.restore(made) }))
        if args.open == true { app.openProject(made.id, tab: .page) }
        return Output(id: made.id.uuidString, title: made.displayTitle, blocks: made.blocks.count, columns: made.columns.map(\.displayTitle))
    }
}

struct ProjectsProjectArgs: Decodable, Sendable {
    var project: String
}

struct ProjectsProjectReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var include: String?
    }
    struct Output: Encodable, Sendable {
        var project: ProjectSummaryOutput
        var design: [String: String]?
        var links: [ProjectRefOutput]?
        var blocks: [ProjectBlockOutput]?
        var columns: [ProjectColumnOutput]?
        var tasks: [ProjectTaskOutput]?
        var todoLists: [ProjectTodoListOutput]?
        var milestones: [ProjectMilestoneOutput]?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.project.read", summary: "Liest ein Projekt: Verknüpfungen, Bausteine der Seite, Spalten und Aufgaben mit Akzeptanzkriterien und Hindernissen, ToDo-Listen, Meilensteine",
        kind: .read, security: projectRead,
        input: .object(["project": projectProperty, "include": .choice(["alles", "seite", "board", "kurz"], "Was mitkommt (Vorgabe alles)")], required: ["project"]),
        output: .freeObject(), example: "llmd projects project read --project \"Hausarbeit Statistik\" --include board", groups: ["projects.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionProject(args.project).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let project = try app.actionProject(args.project)
        let include = args.include ?? "alles"
        guard ["alles", "seite", "board", "kurz"].contains(include) else { throw RPCError.invalidParams("include: alles, seite, board oder kurz.") }
        let page = include == "alles" || include == "seite"
        let board = include == "alles" || include == "board"
        var output = Output(project: project.actionSummary())
        guard include != "kurz" else { return output }
        output.links = project.links.map { app.actionRefOutput($0) }
        if page {
            output.design = ["schrift": project.design.font.rawValue, "hintergrund": project.design.background.rawValue, "akzent": project.accent.rawValue]
            output.blocks = project.actionBlocks()
            output.todoLists = project.todoLists.map { app.actionTodoListOutput($0) }
            output.milestones = project.sortedMilestones.map(ProjectMilestoneOutput.init)
        }
        if board {
            output.columns = project.columns.map { ProjectColumnOutput($0, in: project) }
            output.tasks = project.tasks.map { app.actionTaskOutput($0, in: project) }
        }
        return output
    }
}

struct ProjectsProjectUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var title: String?
        var subtitle: String?
        var status: String?
        var color: String?
        var symbol: String?
        var font: String?
        var background: String?
        var accent: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.project.update", summary: "Ändert Titel, Untertitel, Status, Farbe, Symbol oder die Gestaltung der Seite (Schrift, Hintergrund, Akzent)",
        kind: .write, security: .localWrite,
        input: .object([
            "project": projectProperty, "title": .string("Neuer Titel"), "subtitle": .string("Untertitel oder Ziel"),
            "status": .choice(ProjectStatus.allCases.map(\.rawValue), "Status"), "color": ProjectArgs.colorSchema, "symbol": .string("SF-Symbol"),
            "font": .choice(WriterFont.allCases.map(\.rawValue), "Schrift der Seite"), "background": .choice(ProjectBackground.allCases.map(\.rawValue), "Hintergrund der Seite"),
            "accent": ProjectArgs.colorSchema,
        ], required: ["project"]),
        output: .freeObject(), example: "llmd projects project update --project Hausarbeit --status pausiert --background papier", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let status = try ProjectArgs.choice(args.status, ProjectStatus.allCases, raw: \.rawValue, "Status")
        let color = try ProjectArgs.color(args.color)
        let accent = try ProjectArgs.color(args.accent)
        let font = try ProjectArgs.choice(args.font, WriterFont.allCases, raw: \.rawValue, "Schrift")
        let background = try ProjectArgs.choice(args.background, ProjectBackground.allCases, raw: \.rawValue, "Hintergrund")
        guard args.title != nil || args.subtitle != nil || status != nil || color != nil || args.symbol != nil || font != nil || background != nil || accent != nil else {
            throw RPCError.invalidParams("Nichts zu ändern.")
        }
        try context.changeProject(project.id, label: "Projekt ändern") { project in
            if let title = args.title { project.title = title }
            if let subtitle = args.subtitle { project.subtitle = subtitle }
            if let status { project.status = status }
            if let color, let value = color { project.color = value }
            if let symbol = args.symbol, !symbol.isEmpty { project.symbol = symbol }
            if let font { project.design.font = font }
            if let background { project.design.background = background }
            if let accent { project.design.accent = accent }
        }
        return OKOutput(id: project.id.uuidString)
    }
}

struct ProjectsProjectDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.project.delete", summary: "Legt ein Projekt in den Papierkorb; was es verknüpft, bleibt unberührt", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty], required: ["project"]), output: .freeObject()
    )
    static func preflight(_ args: ProjectsProjectArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionProject(args.project).displayTitle)
    }
    static func run(_ args: ProjectsProjectArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        if app.openProjectID == project.id { app.closeProject() }
        let library = app.projects
        library.deleteProject(project.id)
        context.undoGroup.add(UndoStep(label: "Projekt löschen", undo: { [weak library] in library?.restore(project) }, redo: { [weak library] in library?.deleteProject(project.id) }))
        return OKOutput(id: project.id.uuidString)
    }
}

struct ProjectsProjectProgressAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
    }
    struct Output: Encodable, Sendable {
        var overall: NoteProgressOutput
        var tasks: NoteProgressOutput
        var criteria: NoteProgressOutput
        var todos: NoteProgressOutput
        var milestones: NoteProgressOutput
        var blocked: Int
        var acceptable: Int
        var columns: [ProjectColumnOutput]
        var nextMilestone: ProjectMilestoneOutput?
        var history: [ProjectHistoryOutput]
    }
    struct ProjectHistoryOutput: Encodable, Sendable {
        var day: String
        var open: Int
        var done: Int
    }
    static let descriptor = ActionDescriptor(
        id: "projects.project.progress", summary: "Wie weit ein Projekt ist: Aufgaben, Akzeptanzkriterien, ToDos und Meilensteine, Hindernisse, Spalten und der Verlauf je Tag",
        kind: .read, security: projectRead, input: .object(["project": projectProperty], required: ["project"]), output: .freeObject(),
        example: "llmd projects project progress --project Hausarbeit", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        let open = project.tasks.filter { !project.isFinished($0) }
        return Output(overall: NoteProgressOutput(project.overallProgress), tasks: NoteProgressOutput(project.progress(.tasks)),
                      criteria: NoteProgressOutput(project.progress(.criteria)), todos: NoteProgressOutput(project.progress(.todos)),
                      milestones: NoteProgressOutput(project.progress(.milestones)), blocked: open.filter(\.isBlocked).count,
                      acceptable: open.filter(\.isAcceptable).count, columns: project.columns.map { ProjectColumnOutput($0, in: project) },
                      nextMilestone: project.nextMilestone.map(ProjectMilestoneOutput.init),
                      history: project.history.map { ProjectHistoryOutput(day: $0.day, open: $0.open, done: $0.done) })
    }
}

// MARK: - Links

struct ProjectsLinkArgs: Decodable, Sendable, ProjectRefArguments {
    var project: String
    var chat: String?
    var doc: String?
    var note: String?
    var world: String?
    var part: String?
    var element: String?
}

private let linkInput: JSONSchema = .object(["project": projectProperty].merging(projectRefProperties) { $1 }, required: ["project"])

struct ProjectsLinkAddAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.link.add", summary: "Verknüpft einen Chat, ein Dokument, eine Präsentation, ein Note oder eine Romanwelt (Teil, Element) mit dem Projekt; das Verknüpfte bleibt, wo es ist",
        kind: .write, security: .localWrite, input: linkInput, output: .freeObject(),
        example: "llmd projects link add --project Hausarbeit --doc Gliederung", groups: ["projects.core"]
    )
    static func run(_ args: ProjectsLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        guard let ref = try app.actionProjectRef(args) else { throw RPCError.invalidParams("chat, doc, note oder world angeben.") }
        guard !project.links.contains(ref) else { return OKOutput(id: project.id.uuidString, message: "War schon verknüpft.") }
        try context.changeProject(project.id, label: "Mit Projekt verknüpfen") { $0.links.append(ref) }
        return OKOutput(id: project.id.uuidString)
    }
}

struct ProjectsLinkRemoveAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.link.remove", summary: "Löst eine Verknüpfung überall im Projekt (Projekt, Aufgaben, ToDos); das Verknüpfte bleibt. Gelöschtes lässt sich über seine ID lösen",
        kind: .write, security: .localWrite, input: linkInput, output: .freeObject()
    )
    static func run(_ args: ProjectsLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        let ref = try app.actionProjectRef(args, in: project)
        guard project.refers(to: ref) else { throw RPCError.invalidTarget("Das ist nicht mit dem Projekt verknüpft.") }
        try context.changeProject(project.id, label: "Verknüpfung lösen") { $0.removeLinkEverywhere(ref) }
        return OKOutput(id: project.id.uuidString)
    }
}

struct ProjectsLinkFindAction: LLMDAction {
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
    }
    struct Item: Encodable, Sendable {
        var project: String
        var title: String
        var asProject: Bool
        var tasks: [String]
        var todos: [String]
    }
    struct Output: Encodable, Sendable {
        var projects: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.link.find", summary: "Zu welchen Projekten, Aufgaben und ToDos ein Chat, Dokument, Note oder eine Romanwelt gehört",
        kind: .read, security: projectRead, input: .object(projectRefProperties), output: .freeObject(),
        example: "llmd projects link find --doc Bachelorarbeit", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.projects.loadIfNeeded()
        guard let ref = try app.actionProjectRef(args) else { throw RPCError.invalidParams("chat, doc, note oder world angeben.") }
        return Output(projects: app.projects.projects(referring: ref).map { project in
            Item(project: project.id.uuidString, title: project.displayTitle, asProject: project.links.contains(ref),
                 tasks: project.tasks(referring: ref).map(\.displayTitle), todos: project.allTodos.filter { $0.link == ref }.map(\.text))
        })
    }
}

// MARK: - Blocks

struct ProjectsBlockListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var blocks: [ProjectBlockOutput]
        var rows: Int
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.list", summary: "Listet die Bausteine der Projektseite mit Art, Platz im Raster (x, y, Breite, Höhe; 12 Spalten) und Einstellungen",
        kind: .read, security: projectRead, input: .object(["project": projectProperty], required: ["project"]), output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: ProjectsProjectArgs, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        return Output(blocks: project.actionBlocks(), rows: ProjectLayout.rows(of: project.blocks))
    }
}

/// What `block.add` and `block.update` can set besides the place.
struct ProjectBlockSettings: Decodable, Sendable {
    var title: String?
    var text: String?
    var measure: String?
    var display: String?
    var list: String?
    var chart: String?
    var source: String?
    var date: String?
    var color: String?
    var value: Double?
    var font: String?
    var size: Double?
    var textColor: String?
    var bold: Bool?
    var italic: Bool?
    var align: String?

    static let schema: [String: JSONSchema] = [
        "title": .string("Überschrift"), "text": .string("Text (Text, Haftnotiz) oder Beschriftung einer eigenen Kennzahl"),
        "measure": .choice(ProjectMeasure.allCases.map(\.rawValue), "Was Fortschritt oder Kennzahl zählt"),
        "display": .choice(ProjectProgressStyle.allCases.map(\.rawValue), "Fortschrittsanzeige"),
        "list": .string("ToDo-Liste (ID, Nummer oder Titel)"), "chart": .choice(ProjectChartKind.allCases.map(\.rawValue), "Diagrammart"),
        "source": .choice(ProjectChartSource.allCases.map(\.rawValue), "Daten des Diagramms"), "date": .string("Datum des Countdowns (2026-11-20, leer: nächster Meilenstein)"),
        "color": ProjectArgs.colorSchema, "value": .number("Zahl einer eigenen Kennzahl"),
        "font": .choice(["seite"] + WriterFont.allCases.map(\.rawValue), "Schrift (seite: wie die Seite)"), "size": .number("Schriftgröße in Punkt", minimum: 8, maximum: 96),
        "textColor": ProjectArgs.colorSchema, "bold": .boolean("Fett"), "italic": .boolean("Kursiv"),
        "align": .choice(ProjectTextAlignment.allCases.map(\.rawValue), "Ausrichtung"),
    ]

    var isEmpty: Bool {
        [title, text, measure, display, list, chart, source, date, color, font, textColor, align].allSatisfy { $0 == nil } && value == nil && size == nil && bold == nil && italic == nil
    }

    /// Checks everything first, so a wrong value changes nothing.
    func apply(to block: inout ProjectBlock, in project: Project) throws {
        let measure = try ProjectArgs.choice(self.measure, ProjectMeasure.allCases, raw: \.rawValue, "Zählweise")
        let display = try display.map { value -> ProjectProgressStyle in
            guard let style = ProjectProgressStyle(rawValue: value) else { throw RPCError.invalidParams("Anzeige „\(value)“ gibt es nicht. Möglich: \(ProjectProgressStyle.allCases.map(\.rawValue).joined(separator: ", ")).") }
            return style
        }
        let list = try self.list.map { try project.actionTodoList($0).id }
        let chartKind = try ProjectArgs.choice(chart, ProjectChartKind.allCases, raw: \.rawValue, "Diagramm")
        let source = try ProjectArgs.choice(self.source, ProjectChartSource.allCases, raw: \.rawValue, "Daten")
        let date = try ProjectArgs.day(self.date, "date")
        let color = try ProjectArgs.color(self.color)
        let textColor = try ProjectArgs.color(self.textColor)
        let font: WriterFont?? = try self.font.map { value in
            if value == "seite" { return nil }
            guard let font = WriterFont(rawValue: value) else { throw RPCError.invalidParams("Schrift „\(value)“ gibt es nicht.") }
            return font
        }
        let align = try ProjectArgs.choice(self.align, ProjectTextAlignment.allCases, raw: \.rawValue, "Ausrichtung")
        if chartKind != nil || source != nil, block.kind != .chart { throw RPCError.invalidParams("chart und source gibt es nur bei Diagrammen.") }

        if let title { block.title = title }
        if let text { block.text = text }
        if let measure { block.measure = measure }
        if let display { block.progressStyle = display }
        if let list { block.listID = list }
        if let chartKind {
            var chart = ProjectChart(kind: chartKind, source: source)
            chart.entries = block.chart?.entries ?? []
            block.chart = chart
        }
        if let source {
            let kind = block.chart?.kind ?? .pie
            guard kind.sources.contains(source) else {
                throw RPCError.invalidParams("Ein Diagramm „\(kind.rawValue)“ nimmt: \(kind.sources.map(\.rawValue).joined(separator: ", ")).")
            }
            block.chart?.source = source
        }
        if let date { block.date = date }
        if let color { block.tint = color }
        if let value { block.value = value }
        if let font { block.style.font = font }
        if let size { block.style.size = min(max(size, 8), 96) }
        if let textColor { block.style.color = textColor }
        if let bold { block.style.bold = bold }
        if let italic { block.style.italic = italic }
        if let align { block.style.alignment = align }
    }
}

struct ProjectsBlockAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var kind: String
        var x: Int?
        var y: Int?
        var width: Int?
        var height: Int?
        var title: String?
        var text: String?
        var measure: String?
        var display: String?
        var list: String?
        var chart: String?
        var source: String?
        var date: String?
        var color: String?
        var value: Double?
        var font: String?
        var size: Double?
        var textColor: String?
        var bold: Bool?
        var italic: Bool?
        var align: String?

        var settings: ProjectBlockSettings {
            ProjectBlockSettings(title: title, text: text, measure: measure, display: display, list: list, chart: chart, source: source, date: date, color: color,
                                 value: value, font: font, size: size, textColor: textColor, bold: bold, italic: italic, align: align)
        }
    }
    struct Output: Encodable, Sendable {
        var id: String
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.add", summary: "Fügt der Projektseite einen Baustein hinzu (Text, Fortschritt, ToDos, Meilensteine, Diagramm, Verknüpfungen, Kennzahl, Countdown, Haftnotiz, Hindernisse, Board); ohne Platz dort, wo frei ist",
        kind: .write, security: .localWrite,
        input: .object([
            "project": projectProperty, "kind": .choice(ProjectBlockKind.allCases.map(\.rawValue), "Art des Bausteins"),
            "x": .integer("Spalte 0–11", minimum: 0, maximum: 11), "y": .integer("Zeile ab 0", minimum: 0),
            "width": .integer("Breite in Spalten 1–12", minimum: 1, maximum: 12), "height": .integer("Höhe in Zeilen", minimum: 1, maximum: 40),
        ].merging(ProjectBlockSettings.schema) { $1 }, required: ["project", "kind"]),
        output: .freeObject(), example: "llmd projects block add --project Hausarbeit --kind diagramm --chart kreis --source spalten", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        guard let kind = ProjectBlockKind(rawValue: args.kind) else {
            throw RPCError.invalidParams("Baustein „\(args.kind)“ gibt es nicht. Möglich: \(ProjectBlockKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        var made: ProjectBlock?
        let after = try context.changeProject(project.id, label: "Baustein hinzufügen") { project in
            var block: ProjectBlock
            if kind == .chart {
                let chart = try ProjectArgs.choice(args.chart, ProjectChartKind.allCases, raw: \.rawValue, "Diagramm") ?? .pie
                block = project.addChart(chart)
            } else {
                block = project.addBlock(kind)
            }
            var settings = args.settings
            if kind == .chart { settings.chart = nil }
            try settings.apply(to: &block, in: project)
            if args.x != nil || args.y != nil || args.width != nil || args.height != nil {
                block.frame = ProjectGridFrame(x: args.x ?? block.frame.x, y: args.y ?? block.frame.y, width: args.width ?? block.frame.width, height: args.height ?? block.frame.height)
            }
            let final = block
            project.updateBlock(block.id) { $0 = final }
            project.blocks = ProjectLayout.place(project.blocks, moving: block.id)
            made = final
        }
        guard let id = made?.id, let block = after.block(id) else { throw RPCError.internal("Der Baustein fehlt.") }
        return Output(id: id.uuidString, x: block.frame.x, y: block.frame.y, width: block.frame.width, height: block.frame.height)
    }
}

struct ProjectsBlockUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var block: String
        var title: String?
        var text: String?
        var measure: String?
        var display: String?
        var list: String?
        var chart: String?
        var source: String?
        var date: String?
        var color: String?
        var value: Double?
        var font: String?
        var size: Double?
        var textColor: String?
        var bold: Bool?
        var italic: Bool?
        var align: String?

        var settings: ProjectBlockSettings {
            ProjectBlockSettings(title: title, text: text, measure: measure, display: display, list: list, chart: chart, source: source, date: date, color: color,
                                 value: value, font: font, size: size, textColor: textColor, bold: bold, italic: italic, align: align)
        }
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.update", summary: "Ändert einen Baustein: Überschrift, Text, Schrift, Größe, Farbe, fett, kursiv, Ausrichtung, Zählweise, Anzeige, Liste, Diagramm, Datum",
        kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "block": .string("Baustein (ID, Nummer oder Überschrift)")].merging(ProjectBlockSettings.schema) { $1 },
                       required: ["project", "block"]),
        output: .freeObject(), example: "llmd projects block update --project Hausarbeit --block 1 --font didot --size 22 --bold true", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let block = try project.actionBlock(args.block)
        guard !args.settings.isEmpty else { throw RPCError.invalidParams("Nichts zu ändern.") }
        try context.changeProject(project.id, label: "Baustein ändern") { project in
            var changed = block
            try args.settings.apply(to: &changed, in: project)
            project.updateBlock(block.id) { $0 = changed }
        }
        return OKOutput(id: block.id.uuidString)
    }
}

struct ProjectsBlockMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var block: String
        var x: Int?
        var y: Int?
        var width: Int?
        var height: Int?
    }
    struct Output: Encodable, Sendable {
        var blocks: [ProjectBlockOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.move", summary: "Setzt einen Baustein an einen Platz im Raster oder ändert seine Größe; was im Weg ist, rückt nach unten",
        kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "block": .string("Baustein (ID, Nummer oder Überschrift)"),
                        "x": .integer("Spalte 0–11", minimum: 0, maximum: 11), "y": .integer("Zeile ab 0", minimum: 0),
                        "width": .integer("Breite in Spalten 1–12", minimum: 1, maximum: 12), "height": .integer("Höhe in Zeilen", minimum: 1, maximum: 40)],
                       required: ["project", "block"]),
        output: .freeObject(), example: "llmd projects block move --project Hausarbeit --block 3 --x 6 --y 0 --width 6", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let project = try context.app.actionProject(args.project)
        let block = try project.actionBlock(args.block)
        guard args.x != nil || args.y != nil || args.width != nil || args.height != nil else { throw RPCError.invalidParams("x, y, width oder height angeben.") }
        let frame = ProjectGridFrame(x: args.x ?? block.frame.x, y: args.y ?? block.frame.y, width: args.width ?? block.frame.width, height: args.height ?? block.frame.height)
        let after = try context.changeProject(project.id, label: "Baustein verschieben") { $0.updateBlock(block.id) { $0.frame = frame } }
        return Output(blocks: after.actionBlocks())
    }
}

struct ProjectsBlockDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var block: String
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.delete", summary: "Nimmt einen Baustein von der Seite; ToDo-Listen und Meilensteine des Projekts bleiben", kind: .destructive, security: .destructive,
        input: .object(["project": projectProperty, "block": .string("Baustein (ID, Nummer oder Überschrift)")], required: ["project", "block"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let block = try project.actionBlock(args.block)
        try context.changeProject(project.id, label: "Baustein entfernen") { $0.blocks.removeAll { $0.id == block.id } }
        return OKOutput(id: block.id.uuidString)
    }
}

struct ProjectsBlockEntriesAction: LLMDAction {
    struct Entry: Decodable, Sendable {
        var title: String
        var value: Double?
        var color: String?
        var start: String?
        var end: String?
        var done: Bool?
        var shape: String?
    }
    struct Args: Decodable, Sendable {
        var project: String
        var block: String
        var entries: [Entry]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.block.entries", summary: "Setzt die eigenen Werte eines Diagramms (Kreis, Balken: title+value; Gantt: title+start+end; Ablauf: title+shape+done) und stellt es auf eigene Werte",
        kind: .write, security: .localWrite,
        input: .object(["project": projectProperty, "block": .string("Diagramm-Baustein (ID, Nummer oder Überschrift)"),
                        "entries": .array(of: .freeObject("{title, value, color, start, end, done, shape}"), "Werte in ihrer Reihenfolge")],
                       required: ["project", "block", "entries"]),
        output: .freeObject(), example: "llmd projects block entries --project Hausarbeit --block 4 --entries '[{\"title\":\"Lesen\",\"value\":3}]'", groups: ["projects.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let project = try context.app.actionProject(args.project)
        let block = try project.actionBlock(args.block)
        guard block.kind == .chart, let chart = block.chart else { throw RPCError.invalidTarget("Der Baustein ist kein Diagramm.") }
        guard chart.kind.sources.contains(.manual) else { throw RPCError.invalidTarget("Ein Verlauf hat keine eigenen Werte.") }
        let entries = try args.entries.map { input -> ProjectChartEntry in
            var entry = ProjectChartEntry(title: input.title, value: input.value ?? 1)
            entry.color = try ProjectArgs.color(input.color) ?? nil
            entry.start = try ProjectArgs.day(input.start, "start") ?? nil
            entry.end = try ProjectArgs.day(input.end, "end") ?? nil
            entry.isDone = input.done ?? false
            entry.shape = try ProjectArgs.choice(input.shape, ProjectFlowShape.allCases, raw: \.rawValue, "Form") ?? .step
            if chart.kind == .gantt, entry.start == nil, entry.end == nil { throw RPCError.invalidParams("Gantt-Zeilen brauchen start oder end.") }
            return entry
        }
        try context.changeProject(project.id, label: "Diagrammwerte setzen") { project in
            project.updateBlock(block.id) { block in
                block.chart?.source = .manual
                block.chart?.entries = entries
            }
        }
        return OKOutput(id: block.id.uuidString)
    }
}

// MARK: - Kinds and studio

struct ProjectsStylesListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var description: String?
    }
    struct Output: Encodable, Sendable {
        var blocks: [Item]
        var displays: [Item]
        var charts: [Item]
        var sources: [Item]
        var measures: [Item]
        var backgrounds: [Item]
        var colors: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "projects.styles.list", summary: "Listet Bausteine, Fortschrittsanzeigen, Diagrammarten, Datenquellen, Zählweisen, Hintergründe und Farben der Projektseite",
        kind: .read, security: .plainRead, output: .freeObject(), groups: ["projects.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(blocks: ProjectBlockKind.allCases.map { Item(id: $0.rawValue, title: $0.title, description: $0.tagline) },
               displays: ProjectProgressStyle.allCases.map { Item(id: $0.rawValue, title: $0.title, description: $0.tagline) },
               charts: ProjectChartKind.allCases.map { Item(id: $0.rawValue, title: $0.title, description: "Daten: " + $0.sources.map(\.rawValue).joined(separator: ", ")) },
               sources: ProjectChartSource.allCases.map { Item(id: $0.rawValue, title: $0.title) },
               measures: ProjectMeasure.allCases.map { Item(id: $0.rawValue, title: $0.title) },
               backgrounds: ProjectBackground.allCases.map { Item(id: $0.rawValue, title: $0.title) },
               colors: FolderColor.allCases.map(\.rawValue))
    }
}

struct ProjectsStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var project: String
        var tab: String?
        var task: String?
    }
    static let descriptor = ActionDescriptor(
        id: "projects.studio.open", summary: "Öffnet ein Projekt: die Projektseite oder das Aufgaben-Board, auf Wunsch bei einer Aufgabe", kind: .read, security: .plainRead,
        input: .object(["project": projectProperty, "tab": .choice(["seite", "aufgaben"], "Projektseite oder Aufgaben"), "task": .string("Aufgabe, die im Board aufgeht")], required: ["project"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let project = try app.actionProject(args.project)
        let task = try args.task.map { try project.actionTask($0).id }
        let tab: ProjectTab? = switch args.tab {
        case "seite": .page
        case "aufgaben": .board
        case nil: task == nil ? nil : .board
        default: throw RPCError.invalidParams("tab: seite oder aufgaben.")
        }
        app.openProject(project.id, tab: tab, task: task)
        return OKOutput(id: project.id.uuidString)
    }
}

struct ProjectsStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "projects.studio.close", summary: "Schließt das offene Projekt", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeProject()
        return OKOutput()
    }
}
