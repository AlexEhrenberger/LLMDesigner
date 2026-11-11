import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerNotesActions() {
        register(NotesNoteListAction.self)
        register(NotesNoteCreateAction.self)
        register(NotesNoteReadAction.self)
        register(NotesNoteUpdateAction.self)
        register(NotesNoteDeleteAction.self)
        register(NotesNoteAttachAction.self)
        register(NotesNoteDetachAction.self)
        register(NotesNoteProgressAction.self)
        register(NotesNoteRemoveDoneAction.self)
        register(NotesTodoAddAction.self)
        register(NotesTodoAddManyAction.self)
        register(NotesTodoUpdateAction.self)
        register(NotesTodoCheckAction.self)
        register(NotesTodoDeleteAction.self)
        register(NotesTodoMoveAction.self)
        register(NotesTodoIndentAction.self)
        register(NotesTodoCollapseAction.self)
        register(NotesTodoLinkAction.self)
        register(NotesTodoUnlinkAction.self)
        register(NotesStylesListAction.self)
        register(NotesStudioOpenAction.self)
        register(NotesStudioCloseAction.self)
    }
}

/// Notes have no origin of their own, and agents can write into them: reading one counts as reading something foreign,
/// as with novel worlds.
private let noteRead = ActionSecurity.foreignRead

private let noteProperty: JSONSchema = .string("Note (ID oder Titel)")
private let todoProperty: JSONSchema = .string("ToDo: ID, Nummer wie 2.1 oder Text (Pfad wie Webseite/Startseite)")
private let docProperty: JSONSchema = .string("Writer-Dokument oder Präsentation (ID oder Titel)")
private let worldProperty: JSONSchema = .string("Romanwelt (ID oder Titel)")
private let partProperty: JSONSchema = .string("Teil der Romanwelt (ID oder Pfad wie Buch 1/Akt 2); ohne: die ganze Welt")

// MARK: - Finding

extension AppModel {
    func actionNote(_ reference: String) throws -> Note {
        notes.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let note = notes.note(id) else { throw RPCError.notFound("Note \(reference) gibt es nicht.") }
            return note
        }
        let found = notes.notes.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Note „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Notes heißen „\(reference)“. Bitte die ID verwenden.", candidates: found.map(\.id.uuidString))
    }

    /// The owner a call names: a document (`doc`) or a novel world with or without a part. Nil when it names none.
    func actionNoteOwner(doc: String?, world: String?, part: String?) throws -> NoteOwner? {
        if let doc {
            guard world == nil, part == nil else { throw RPCError.invalidParams("Entweder doc oder world (mit part) angeben, nicht beides.") }
            return .document(try actionDocumentOrDeck(doc).id)
        }
        guard let world else {
            if part != nil { throw RPCError.invalidParams("Für part bitte auch world angeben.") }
            return nil
        }
        let found = try actionWorld(world)
        return .story(world: found.id, part: try part.map { try found.actionPart($0).id })
    }
}

extension Note {
    /// A to-do by id, by number ("2.1"), by a path of texts ("Webseite/Startseite") or by a text that only one has.
    func actionTodo(_ reference: String) throws -> NoteTodo {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let todo = todo(id) { return todo }
        if reference.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil {
            guard let todo = todo(atNumber: reference) else { throw RPCError.notFound("ToDo \(reference) gibt es nicht.") }
            return todo
        }
        func same(_ todo: NoteTodo, _ text: String) -> Bool {
            todo.text.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(text) == .orderedSame
        }
        if reference.contains("/") {
            var level = todos
            var found: NoteTodo?
            for piece in reference.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let matching = level.filter { same($0, piece) }
                guard let first = matching.first else { throw RPCError.notFound("ToDo „\(reference)“ gibt es nicht.") }
                guard matching.count == 1 else { throw RPCError.ambiguous("Mehrere ToDos heißen „\(piece)“.", candidates: matching.map(\.id.uuidString)) }
                found = first
                level = first.children
            }
            if let found { return found }
        }
        let matching = allTodos.filter { same($0, reference) }
        if matching.count == 1 { return matching[0] }
        if matching.isEmpty { throw RPCError.notFound("ToDo „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere ToDos heißen „\(reference)“. Bitte Nummer oder ID verwenden.", candidates: matching.map(\.id.uuidString))
    }
}

extension ActionContext {
    /// A change to a note with an undo step, as one call.
    @discardableResult
    func changeNote(_ id: UUID, label: String, _ change: (inout Note) throws -> Void) throws -> Note {
        let library = app.notes
        library.commitDrafts(of: id)
        guard let before = library.note(id) else { throw RPCError.notFound("Das Note gibt es nicht mehr.") }
        var note = before
        try change(&note)
        let wanted = note
        library.update(id) { $0 = wanted }
        let after = library.note(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.update(id) { $0 = before } }, redo: { [weak library] in library?.update(id) { $0 = after } }))
        registry.eventSink?(ActionEvent(kind: "note.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
        return after
    }
}

// MARK: - Output

struct NoteOwnerOutput: Encodable, Sendable {
    var kind: String
    var id: String
    var world: String?
    var part: String?
    var title: String?
}

struct NoteTodoOutput: Encodable, Sendable {
    var id: String
    var number: String
    var text: String
    var done: Bool
    var collapsed: Bool?
    var progress: String?
    var documents: [String]?
    var children: [NoteTodoOutput]?
}

struct NoteProgressOutput: Encodable, Sendable {
    var done: Int
    var total: Int
    var percent: Int
}

extension NoteProgressOutput {
    init(_ progress: NoteProgress) {
        self.init(done: progress.done, total: progress.total, percent: progress.percent)
    }
}

@MainActor
extension AppModel {
    func actionOwnerOutput(_ owner: NoteOwner) -> NoteOwnerOutput {
        switch owner {
        case .document(let id):
            NoteOwnerOutput(kind: document(id)?.isPresentation == true ? "praesentation" : "dokument", id: id.uuidString, title: noteOwnerTitle(owner))
        case .story(let world, let part):
            NoteOwnerOutput(kind: "romanwelt", id: (part ?? world).uuidString, world: world.uuidString, part: part?.uuidString, title: noteOwnerTitle(owner))
        }
    }
}

extension Note {
    func actionTodos() -> [NoteTodoOutput] {
        func convert(_ list: [NoteTodo], prefix: String) -> [NoteTodoOutput] {
            list.enumerated().map { index, todo in
                let number = prefix.isEmpty ? "\(index + 1)" : "\(prefix).\(index + 1)"
                let progress = todo.progress
                return NoteTodoOutput(id: todo.id.uuidString, number: number, text: todo.text, done: todo.isDone,
                                      collapsed: todo.isCollapsed ? true : nil,
                                      progress: todo.children.isEmpty ? nil : "\(progress.done)/\(progress.total)",
                                      documents: todo.documents.isEmpty ? nil : todo.documents.map(\.uuidString),
                                      children: todo.children.isEmpty ? nil : convert(todo.children, prefix: number))
            }
        }
        return convert(todos, prefix: "")
    }
}

/// To-dos an agent hands over as JSON: `[{"text": "…", "done": false, "children": [...]}]`.
struct NoteTodoInput: Decodable, Sendable {
    var text: String
    var done: Bool?
    var children: [NoteTodoInput]?

    var todo: NoteTodo {
        NoteTodo(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isDone: done ?? false, children: (children ?? []).map(\.todo))
    }
}

private func styleProperty() -> JSONSchema {
    .choice(NoteProgressStyle.allCases.map(\.rawValue), "Fortschrittsanzeige")
}

private func parseStyle(_ value: String?) throws -> NoteProgressStyle? {
    guard let value else { return nil }
    guard let style = NoteProgressStyle(rawValue: value) else {
        throw RPCError.invalidParams("Anzeige „\(value)“ gibt es nicht. Möglich: \(NoteProgressStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return style
}

// MARK: - Notes

struct NotesNoteListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
        var doc: String?
        var world: String?
        var part: String?
        var general: Bool?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var style: String
        var progress: NoteProgressOutput
        var owners: [NoteOwnerOutput]
        var updated: String
    }
    struct Output: Encodable, Sendable {
        var notes: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "notes.note.list", summary: "Listet Notes mit Fortschritt; auf Wunsch nur die eines Dokuments, einer Romanwelt oder eines Teils, oder nur allgemeine",
        kind: .read, security: noteRead,
        input: .object(["query": .string("Suche in Titel, ToDos und Notizen"), "doc": docProperty, "world": worldProperty, "part": partProperty,
                        "general": .boolean("Nur Notes, die zu nichts gehören")]),
        output: .freeObject(), example: "llmd notes note list --doc Bachelorarbeit", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.notes.loadIfNeeded()
        let owner = try app.actionNoteOwner(doc: args.doc, world: args.world, part: args.part)
        let notes = app.notes.notes.filter { note in
            (owner.map { note.belongs(to: $0) } ?? true) && (args.general == true ? note.owners.isEmpty : true) && note.matches(args.query ?? "")
        }
        return Output(notes: notes.map { note in
            Item(id: note.id.uuidString, title: note.displayTitle, style: note.style.rawValue, progress: NoteProgressOutput(note.progress),
                 owners: note.owners.map { app.actionOwnerOutput($0) }, updated: note.updatedAt.formatted(.iso8601))
        })
    }
}

struct NotesNoteCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String?
        var style: String?
        var text: String?
        var todos: [NoteTodoInput]?
        var markdown: String?
        var doc: String?
        var world: String?
        var part: String?
        var open: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.note.create", summary: "Legt ein Note an, auf Wunsch mit ToDos und zugehörig zu einem Dokument, einer Romanwelt oder einem Teil",
        kind: .write, security: .localWrite,
        input: .object([
            "title": .string("Titel; ohne Titel bei einer Zuordnung der Name des Dokuments oder Teils"), "style": styleProperty(), "text": .string("Freie Notizen"),
            "todos": .array(of: .freeObject("{text, done, children}"), "ToDos als JSON, verschachtelt über children"),
            "markdown": .string("ToDos als Aufgabenliste: - [ ] offen, - [x] erledigt, Einrücken für Unter-ToDos"),
            "doc": docProperty, "world": worldProperty, "part": partProperty, "open": .boolean("Im Notes-Studio öffnen"),
        ]),
        output: .freeObject(), example: "llmd notes note create --title Webseite --markdown \"- [ ] Konzept\\n  - [ ] Zielgruppe\"", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let owner = try app.actionNoteOwner(doc: args.doc, world: args.world, part: args.part)
        let style = try parseStyle(args.style)
        var todos = (args.todos ?? []).map(\.todo)
        if let markdown = args.markdown { todos += Note.todos(fromText: markdown) }
        var note = app.newNote(title: args.title, for: owner, todos: todos)
        let library = app.notes
        if style != nil || args.text != nil {
            library.update(note.id) { made in
                if let style { made.style = style }
                if let text = args.text { made.text = text }
            }
            note = library.note(note.id) ?? note
        }
        let made = note
        context.undoGroup.add(UndoStep(label: "Note anlegen", undo: { [weak library] in library?.deleteNote(made.id) }, redo: { [weak library] in library?.restore(made) }))
        if args.open == true { app.openNotesStudio(showing: made.id) }
        return Output(id: made.id.uuidString, title: made.displayTitle, todos: made.allTodos.count, progress: NoteProgressOutput(made.progress))
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var todos: Int
        var progress: NoteProgressOutput
    }
}

struct NotesNoteArgs: Decodable, Sendable {
    var note: String
}

struct NotesNoteReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var format: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var style: String
        var progress: NoteProgressOutput
        var owners: [NoteOwnerOutput]
        var todos: [NoteTodoOutput]?
        var text: String?
        var markdown: String?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.note.read", summary: "Liest ein Note: ToDos mit Nummern, Unter-ToDos, Verknüpfungen, Notizen und Fortschritt",
        kind: .read, security: noteRead,
        input: .object(["note": noteProperty, "format": .choice(["json", "markdown"], "json (Vorgabe) oder markdown als Aufgabenliste")], required: ["note"]),
        output: .freeObject(), example: "llmd notes note read --note Webseite", groups: ["notes.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionNote(args.note).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let note = try app.actionNote(args.note)
        let asMarkdown = args.format == "markdown"
        return Output(id: note.id.uuidString, title: note.displayTitle, style: note.style.rawValue, progress: NoteProgressOutput(note.progress),
                      owners: note.owners.map { app.actionOwnerOutput($0) }, todos: asMarkdown ? nil : note.actionTodos(),
                      text: asMarkdown || note.text.isEmpty ? nil : note.text, markdown: asMarkdown ? note.markdown : nil)
    }
}

struct NotesNoteUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var title: String?
        var text: String?
        var appendText: String?
        var style: String?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.note.update", summary: "Ändert Titel, Notizen oder Fortschrittsanzeige eines Notes", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "title": .string("Neuer Titel"), "text": .string("Notizen ersetzen"), "appendText": .string("An die Notizen anhängen"),
                        "style": styleProperty()], required: ["note"]),
        output: .freeObject(), example: "llmd notes note update --note Webseite --style rakete", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let note = try context.app.actionNote(args.note)
        let style = try parseStyle(args.style)
        guard args.title != nil || args.text != nil || args.appendText != nil || style != nil else { throw RPCError.invalidParams("Nichts zu ändern: title, text, appendText oder style angeben.") }
        try context.changeNote(note.id, label: "Note ändern") { note in
            if let title = args.title { note.title = title }
            if let text = args.text { note.text = text }
            if let more = args.appendText { note.text = note.text.isEmpty ? more : note.text + "\n" + more }
            if let style { note.style = style }
        }
        return OKOutput(id: note.id.uuidString)
    }
}

struct NotesNoteDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.note.delete", summary: "Legt ein Note in den Papierkorb", kind: .destructive, security: .destructive,
        input: .object(["note": noteProperty], required: ["note"]), output: .freeObject()
    )
    static func preflight(_ args: NotesNoteArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionNote(args.note).displayTitle)
    }
    static func run(_ args: NotesNoteArgs, context: ActionContext) async throws -> OKOutput {
        let library = context.app.notes
        let note = try context.app.actionNote(args.note)
        library.deleteNote(note.id)
        context.undoGroup.add(UndoStep(label: "Note löschen", undo: { [weak library] in library?.restore(note) }, redo: { [weak library] in library?.deleteNote(note.id) }))
        return OKOutput(id: note.id.uuidString)
    }
}

struct NotesOwnerArgs: Decodable, Sendable {
    var note: String
    var doc: String?
    var world: String?
    var part: String?
}

private let ownerInput: JSONSchema = .object(["note": noteProperty, "doc": docProperty, "world": worldProperty, "part": partProperty], required: ["note"])

struct NotesNoteAttachAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.note.attach", summary: "Ordnet ein Note einem Dokument, einer Präsentation, einer Romanwelt oder einem ihrer Teile zu", kind: .write, security: .localWrite,
        input: ownerInput, output: .freeObject(), example: "llmd notes note attach --note Fortschritt --doc Bachelorarbeit", groups: ["notes.core"]
    )
    static func run(_ args: NotesOwnerArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let note = try app.actionNote(args.note)
        guard let owner = try app.actionNoteOwner(doc: args.doc, world: args.world, part: args.part) else { throw RPCError.invalidParams("doc oder world angeben.") }
        guard !note.belongs(to: owner) else { return OKOutput(id: note.id.uuidString, message: "Gehörte schon dazu.") }
        try context.changeNote(note.id, label: "Note zuordnen") { $0.owners.append(owner) }
        return OKOutput(id: note.id.uuidString)
    }
}

struct NotesNoteDetachAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.note.detach", summary: "Löst ein Note von einem Dokument oder Teil; das Note bleibt", kind: .write, security: .localWrite,
        input: ownerInput, output: .freeObject()
    )
    static func run(_ args: NotesOwnerArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let note = try app.actionNote(args.note)
        guard let owner = try app.actionNoteOwner(doc: args.doc, world: args.world, part: args.part) else { throw RPCError.invalidParams("doc oder world angeben.") }
        guard note.belongs(to: owner) else { throw RPCError.invalidTarget("Das Note gehört nicht dazu.") }
        try context.changeNote(note.id, label: "Zuordnung lösen") { $0.owners.removeAll { $0 == owner } }
        return OKOutput(id: note.id.uuidString)
    }
}

struct NotesNoteProgressAction: LLMDAction {
    struct Group: Encodable, Sendable {
        var number: String
        var text: String
        var progress: NoteProgressOutput
    }
    struct Output: Encodable, Sendable {
        var title: String
        var progress: NoteProgressOutput
        var label: String
        var groups: [Group]
        var nextOpen: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "notes.note.progress", summary: "Wie weit ein Note ist: erledigt, offen, je Hauptaufgabe und die nächsten offenen ToDos", kind: .read, security: noteRead,
        input: .object(["note": noteProperty], required: ["note"]), output: .freeObject(), groups: ["notes.core"]
    )
    static func run(_ args: NotesNoteArgs, context: ActionContext) async throws -> Output {
        let note = try context.app.actionNote(args.note)
        let groups = note.todos.enumerated().filter { !$0.element.children.isEmpty }.map { index, todo in
            Group(number: "\(index + 1)", text: todo.text, progress: NoteProgressOutput(todo.progress))
        }
        let open = note.rows(showingCollapsed: true).filter { !$0.todo.isDone && $0.todo.children.isEmpty }.prefix(5).map { "\($0.number) \($0.todo.text)" }
        return Output(title: note.displayTitle, progress: NoteProgressOutput(note.progress), label: note.progress.label, groups: groups, nextOpen: Array(open))
    }
}

struct NotesNoteRemoveDoneAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.note.removeDone", summary: "Entfernt alle erledigten ToDos eines Notes", kind: .destructive, security: .destructive,
        input: .object(["note": noteProperty], required: ["note"]), output: .freeObject()
    )
    static func preflight(_ args: NotesNoteArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionNote(args.note).displayTitle)
    }
    static func run(_ args: NotesNoteArgs, context: ActionContext) async throws -> OKOutput {
        let note = try context.app.actionNote(args.note)
        var removed = 0
        try context.changeNote(note.id, label: "Erledigte entfernen") { removed = $0.removeDone() }
        return OKOutput(id: note.id.uuidString, message: removed == 1 ? "1 ToDo entfernt." : "\(removed) ToDos entfernt.")
    }
}

// MARK: - To-dos

struct NotesTodoArgs: Decodable, Sendable {
    var note: String
    var todo: String
}

private let todoInput: JSONSchema = .object(["note": noteProperty, "todo": todoProperty], required: ["note", "todo"])

struct NotesTodoOutput: Encodable, Sendable {
    var id: String
    var number: String?
    var progress: NoteProgressOutput
}

struct NotesTodoAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var text: String
        var parent: String?
        var after: String?
        var done: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.add", summary: "Legt ein ToDo an: am Ende, unter einem anderen (parent) oder gleich nach einem (after)", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "text": .string("Text des ToDos"), "parent": .string("Unter diesem ToDo (Unter-ToDo)"), "after": .string("Direkt nach diesem ToDo"),
                        "done": .boolean("Gleich als erledigt")], required: ["note", "text"]),
        output: .freeObject(), example: "llmd notes todo add --note Webseite --text Impressum --parent 2", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> NotesTodoOutput {
        let note = try context.app.actionNote(args.note)
        guard args.parent == nil || args.after == nil else { throw RPCError.invalidParams("Entweder parent oder after angeben.") }
        let parent = try args.parent.map { try note.actionTodo($0).id }
        let after = try args.after.map { try note.actionTodo($0).id }
        var made: UUID?
        let changed = try context.changeNote(note.id, label: "ToDo anlegen") { note in
            made = note.addTodo(args.text.trimmingCharacters(in: .whitespacesAndNewlines), parent: parent, after: after)
            if let made, args.done == true { note.setDone(made, true) }
        }
        guard let made else { throw RPCError.invalidTarget("Das ToDo ließ sich dort nicht anlegen.") }
        return NotesTodoOutput(id: made.uuidString, number: changed.number(of: made), progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoAddManyAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todos: [NoteTodoInput]?
        var markdown: String?
        var parent: String?
    }
    struct Output: Encodable, Sendable {
        var created: Int
        var ids: [String]
        var progress: NoteProgressOutput
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.addMany", summary: "Legt mehrere ToDos mit Unter-ToDos auf einmal an (JSON oder Aufgabenliste)", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todos": .array(of: .freeObject("{text, done, children}"), "ToDos als JSON"),
                        "markdown": .string("- [ ] offen, - [x] erledigt, Einrücken für Unter-ToDos"), "parent": .string("Alles unter dieses ToDo")], required: ["note"]),
        output: .freeObject(), example: "llmd notes todo add-many --note Webseite --markdown \"- [ ] Design\\n  - [ ] Farben\"", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let note = try context.app.actionNote(args.note)
        var todos = (args.todos ?? []).map(\.todo)
        if let markdown = args.markdown { todos += Note.todos(fromText: markdown) }
        guard !todos.isEmpty else { throw RPCError.invalidParams("Keine ToDos: todos oder markdown angeben.") }
        let parent = try args.parent.map { try note.actionTodo($0).id }
        let changed = try context.changeNote(note.id, label: "ToDos anlegen") { note in
            for todo in todos { note.insert(todo, parent: parent) }
        }
        return Output(created: todos.flatMap(\.all).count, ids: todos.map(\.id.uuidString), progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todo: String
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.update", summary: "Ändert den Text eines ToDos", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "text": .string("Neuer Text")], required: ["note", "todo", "text"]),
        output: .freeObject(), groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let note = try context.app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        try context.changeNote(note.id, label: "ToDo ändern") { $0.updateTodo(todo.id) { $0.text = args.text } }
        return OKOutput(id: todo.id.uuidString)
    }
}

struct NotesTodoCheckAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todo: String
        var done: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.check", summary: "Hakt ein ToDo mit seinen Unter-ToDos ab (done false öffnet es wieder)", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "done": .boolean("Erledigt (Vorgabe) oder wieder offen")], required: ["note", "todo"]),
        output: .freeObject(), example: "llmd notes todo check --note Webseite --todo 1.2", groups: ["notes.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> NotesTodoOutput {
        let note = try context.app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        let changed = try context.changeNote(note.id, label: args.done == false ? "ToDo öffnen" : "ToDo abhaken") { $0.setDone(todo.id, args.done ?? true) }
        return NotesTodoOutput(id: todo.id.uuidString, number: changed.number(of: todo.id), progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.todo.delete", summary: "Löscht ein ToDo mit seinen Unter-ToDos", kind: .destructive, security: .destructive,
        input: todoInput, output: .freeObject(), groups: ["notes.core"]
    )
    static func preflight(_ args: NotesTodoArgs, context: ActionContext) throws -> ActionPreflight {
        let note = try context.app.actionNote(args.note)
        return ActionPreflight(target: "\(note.displayTitle): \(try note.actionTodo(args.todo).text)")
    }
    static func run(_ args: NotesTodoArgs, context: ActionContext) async throws -> NotesTodoOutput {
        let note = try context.app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        let changed = try context.changeNote(note.id, label: "ToDo löschen") { $0.removeTodo(todo.id) }
        return NotesTodoOutput(id: todo.id.uuidString, progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todo: String
        var by: Int?
        var parent: String?
        var top: Bool?
        var index: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.move", summary: "Verschiebt ein ToDo: um by Plätze, unter ein anderes (parent) oder nach oben (top), an index ab 1",
        kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "by": .integer("Plätze nach unten (negativ: nach oben)"), "parent": .string("Unter dieses ToDo"),
                        "top": .boolean("Auf die oberste Ebene"), "index": .integer("Platz ab 1 auf der neuen Ebene", minimum: 1)], required: ["note", "todo"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> NotesTodoOutput {
        let note = try context.app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        let parent = try args.parent.map { try note.actionTodo($0).id }
        guard (args.by != nil) != (parent != nil || args.top == true) else { throw RPCError.invalidParams("Entweder by oder parent/top angeben.") }
        let changed = try context.changeNote(note.id, label: "ToDo verschieben") { note in
            if let by = args.by {
                guard note.move(todo.id, by: by) else { throw RPCError.invalidTarget("Dorthin geht es nicht: Das ToDo steht schon am Rand seiner Ebene.") }
            } else {
                guard note.reparent(todo.id, to: args.top == true ? nil : parent, at: args.index.map { $0 - 1 }) else {
                    throw RPCError.invalidTarget("Ein ToDo kann nicht unter sich selbst oder eines seiner Unter-ToDos.")
                }
            }
        }
        return NotesTodoOutput(id: todo.id.uuidString, number: changed.number(of: todo.id), progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoIndentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todo: String
        var direction: String?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.indent", summary: "Rückt ein ToDo ein (wird Unter-ToDo des vorigen) oder aus", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "direction": .choice(["in", "out"], "in (Vorgabe) oder out")], required: ["note", "todo"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> NotesTodoOutput {
        let note = try context.app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        let outward = args.direction == "out"
        let changed = try context.changeNote(note.id, label: outward ? "Ausrücken" : "Einrücken") { note in
            guard outward ? note.outdent(todo.id) : note.indent(todo.id) else {
                throw RPCError.invalidTarget(outward ? "Das ToDo steht schon oben." : "Es gibt kein ToDo davor, unter das es rücken könnte.")
            }
        }
        return NotesTodoOutput(id: todo.id.uuidString, number: changed.number(of: todo.id), progress: NoteProgressOutput(changed.progress))
    }
}

struct NotesTodoCollapseAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String
        var todo: String?
        var collapsed: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.todo.collapse", summary: "Klappt die Unter-ToDos eines ToDos (ohne todo: aller) zu oder auf", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "collapsed": .boolean("Zu (Vorgabe) oder auf")], required: ["note"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let note = try context.app.actionNote(args.note)
        let collapsed = args.collapsed ?? true
        let targets = try args.todo.map { [try note.actionTodo($0)] } ?? note.allTodos.filter { !$0.children.isEmpty }
        if let only = targets.first, args.todo != nil, only.children.isEmpty { throw RPCError.invalidTarget("Das ToDo hat keine Unter-ToDos.") }
        try context.changeNote(note.id, label: collapsed ? "Zuklappen" : "Aufklappen") { note in
            for todo in targets { note.updateTodo(todo.id) { $0.isCollapsed = collapsed } }
        }
        return OKOutput(id: note.id.uuidString)
    }
}

struct NotesTodoLinkArgs: Decodable, Sendable {
    var note: String
    var todo: String
    var doc: String
}

struct NotesTodoLinkAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.todo.link", summary: "Verknüpft ein ToDo mit einem Writer-Dokument oder einer Präsentation", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "doc": docProperty], required: ["note", "todo", "doc"]),
        output: .freeObject(), example: "llmd notes todo link --note Webseite --todo \"Konzept ausarbeiten\" --doc Konzept", groups: ["notes.core"]
    )
    static func run(_ args: NotesTodoLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let note = try app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        let document = try app.actionDocumentOrDeck(args.doc)
        guard !todo.documents.contains(document.id) else { return OKOutput(id: todo.id.uuidString, message: "War schon verknüpft.") }
        try context.changeNote(note.id, label: "Dokument verknüpfen") { $0.updateTodo(todo.id) { $0.documents.append(document.id) } }
        return OKOutput(id: todo.id.uuidString)
    }
}

struct NotesTodoUnlinkAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.todo.unlink", summary: "Löst die Verknüpfung eines ToDos mit einem Dokument; das Dokument bleibt", kind: .write, security: .localWrite,
        input: .object(["note": noteProperty, "todo": todoProperty, "doc": docProperty], required: ["note", "todo", "doc"]), output: .freeObject()
    )
    static func run(_ args: NotesTodoLinkArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let note = try app.actionNote(args.note)
        let todo = try note.actionTodo(args.todo)
        // A deleted document can still be unlinked by its id.
        let id = try UUID(uuidString: args.doc) ?? app.actionDocumentOrDeck(args.doc).id
        guard todo.documents.contains(id) else { throw RPCError.invalidTarget("Das ToDo ist damit nicht verknüpft.") }
        try context.changeNote(note.id, label: "Verknüpfung lösen") { $0.updateTodo(todo.id) { $0.documents.removeAll { $0 == id } } }
        return OKOutput(id: todo.id.uuidString)
    }
}

// MARK: - Displays and studio

struct NotesStylesListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var description: String
    }
    struct Output: Encodable, Sendable {
        var styles: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "notes.styles.list", summary: "Listet die Fortschrittsanzeigen (Balken, Ringe, Glas, Pflanze, Rakete …)", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(styles: NoteProgressStyle.allCases.map { Item(id: $0.rawValue, title: $0.title, description: $0.tagline) })
    }
}

struct NotesStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var note: String?
        var todo: String?
    }
    static let descriptor = ActionDescriptor(
        id: "notes.studio.open", summary: "Öffnet das Notes-Studio, wenn gewünscht bei einem Note und einem ToDo", kind: .read, security: .plainRead,
        input: .object(["note": noteProperty, "todo": todoProperty]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        if args.note == nil, args.todo != nil { throw RPCError.invalidParams("Für todo bitte auch note angeben.") }
        let note = try args.note.map { try app.actionNote($0) }
        let todo = try args.todo.flatMap { reference in try note?.actionTodo(reference) }
        app.openNotesStudio()
        if let note { app.notesStudioCommand = NotesStudioCommand(note: note.id, focusTodo: todo?.id) }
        return OKOutput(id: note?.id.uuidString)
    }
}

struct NotesStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "notes.studio.close", summary: "Schließt das Notes-Studio", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeNotesStudio()
        return OKOutput()
    }
}
