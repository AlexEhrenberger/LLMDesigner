import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerStoriesActions() {
        register(StoriesWorldListAction.self)
        register(StoriesWorldCreateAction.self)
        register(StoriesWorldReadAction.self)
        register(StoriesWorldUpdateAction.self)
        register(StoriesWorldDeleteAction.self)
        register(StoriesPartTreeAction.self)
        register(StoriesPartReadAction.self)
        register(StoriesPartAddAction.self)
        register(StoriesPartUpdateAction.self)
        register(StoriesPartFocusSetAction.self)
        register(StoriesPartDeleteAction.self)
        register(StoriesElementListAction.self)
        register(StoriesElementReadAction.self)
        register(StoriesElementCreateAction.self)
        register(StoriesElementUpdateAction.self)
        register(StoriesElementDeleteAction.self)
        register(StoriesElementUsagesAction.self)
        registerStoriesMoreActions()
    }
}

/// World files have no origin of their own, and agents can write into them. So reading a world counts as reading
/// something foreign: stricter than needed for the person's own worlds, but it needs no change to the file format.
private let worldRead = ActionSecurity.foreignRead

extension AppModel {
    func actionWorld(_ reference: String) throws -> StoryWorld {
        stories.loadIfNeeded()
        if let id = UUID(uuidString: reference), let world = stories.world(id) { return world }
        let found = stories.worlds.filter { $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Romanwelt „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Romanwelten heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }
}

extension StoryWorld {
    /// A part by id or by path of titles (`Buch 1/Akt 2`).
    func actionPart(_ reference: String) throws -> StoryPart {
        if let id = UUID(uuidString: reference), let part = part(id) { return part }
        var level = books
        var found: StoryPart?
        for piece in reference.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let matching = level.filter { $0.title.localizedCaseInsensitiveCompare(piece) == .orderedSame || displayTitle(of: $0).localizedCaseInsensitiveCompare(piece) == .orderedSame }
            guard let first = matching.first else { throw RPCError.notFound("Teil „\(reference)“ gibt es nicht.") }
            guard matching.count == 1 else { throw RPCError.ambiguous("Mehrere Teile heißen „\(piece)“.", candidates: matching.map(\.id.uuidString)) }
            found = first
            level = first.children
        }
        guard let found else { throw RPCError.notFound("Teil „\(reference)“ gibt es nicht.") }
        return found
    }

    /// `figure:Mara` or `figure:<id>`; a name has to be unique.
    func actionElement(_ reference: String) throws -> StoryRef {
        guard let colon = reference.firstIndex(of: ":"), let kind = StoryElementKind(rawValue: String(reference[..<colon])) else {
            throw RPCError.invalidParams("Element als art:name oder art:id angeben, z. B. figure:Mara. Arten: \(StoryElementKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let name = String(reference[reference.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let entries = summaries(of: kind)
        if let id = UUID(uuidString: name), entries.contains(where: { $0.id == id }) { return StoryRef(kind: kind, id: id) }
        let found = entries.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        if found.count == 1 { return StoryRef(kind: kind, id: found[0].id) }
        if found.isEmpty { throw RPCError.notFound("\(kind.title): „\(name)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Einträge heißen „\(name)“.", candidates: found.map(\.id.uuidString))
    }

    // Elements have many fields per kind; they are read and changed through their own JSON, so the actions stay one set.

    private func json<E: StoryElement>(_ type: E.Type, _ id: UUID) -> JSONValue? {
        element(type, id).flatMap { try? JSONValue.encoding($0) }
    }

    func elementJSON(_ ref: StoryRef) -> JSONValue? {
        switch ref.kind {
        case .event: json(StoryEvent.self, ref.id)
        case .figure: json(StoryFigure.self, ref.id)
        case .place: json(StoryPlace.self, ref.id)
        case .reason: json(StoryReason.self, ref.id)
        case .purpose: json(StoryPurpose.self, ref.id)
        case .species: json(StorySpecies.self, ref.id)
        case .fact: json(StoryFact.self, ref.id)
        }
    }

    /// Fields an agent must not set: identity and media, which have their own ways in.
    static let protectedElementFields: Set<String> = ["id", "createdAt", "updatedAt", "images", "videos"]
    /// Fields that are missing from an element's JSON while they are empty, and can be set all the same.
    static let optionalElementFields: [StoryElementKind: Set<String>] = [.figure: ["speciesID"], .place: ["parentID"], .reason: ["holderID"]]

    private mutating func apply<E: StoryElement>(_ type: E.Type, _ id: UUID, fields: [String: JSONValue]) throws {
        guard let current = element(type, id), case .object(var object) = try JSONValue.encoding(current) else { return }
        for (key, value) in fields {
            let isKnown = object[key] != nil || Self.optionalElementFields[E.kind]?.contains(key) == true
            guard isKnown, !Self.protectedElementFields.contains(key) else {
                let known = object.keys.filter { !Self.protectedElementFields.contains($0) }.sorted().joined(separator: ", ")
                throw RPCError.invalidParams("„\(type.kind.rawValue)“ hat kein Feld „\(key)“. Möglich: \(known).")
            }
            object[key] = value
        }
        let updated: E
        do {
            updated = try JSONValue.object(object).decoded(as: E.self)
        } catch {
            throw RPCError.invalidParams("Ein Feld hat den falschen Typ: \(error.localizedDescription)")
        }
        updateElement(type, id) { $0 = updated }
    }

    mutating func updateElementJSON(_ ref: StoryRef, fields: [String: JSONValue]) throws {
        switch ref.kind {
        case .event: try apply(StoryEvent.self, ref.id, fields: fields)
        case .figure: try apply(StoryFigure.self, ref.id, fields: fields)
        case .place: try apply(StoryPlace.self, ref.id, fields: fields)
        case .reason: try apply(StoryReason.self, ref.id, fields: fields)
        case .purpose: try apply(StoryPurpose.self, ref.id, fields: fields)
        case .species: try apply(StorySpecies.self, ref.id, fields: fields)
        case .fact: try apply(StoryFact.self, ref.id, fields: fields)
        }
    }
}

extension ActionContext {
    /// A change to a world with an undo step, as one call.
    func changeWorld(_ id: UUID, label: String, _ change: (inout StoryWorld) throws -> Void) throws {
        let library = app.stories
        guard let before = library.world(id) else { throw RPCError.notFound("Die Romanwelt gibt es nicht mehr.") }
        var world = before
        try change(&world)
        let after = world
        library.update(id) { $0 = after }
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.update(id) { $0 = before } }, redo: { [weak library] in library?.update(id) { $0 = after } }))
        registry.eventSink?(ActionEvent(kind: "world.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
    }
}

private let worldProperty: JSONSchema = .string("Romanwelt (ID oder Titel)")
private let partProperty: JSONSchema = .string("Teil (ID oder Pfad wie Buch 1/Akt 2)")
private let elementProperty: JSONSchema = .string("Element als art:name, z. B. figure:Mara")

struct StoriesWorldArgs: Decodable, Sendable {
    var world: String
}

struct StoriesWorldListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var genre: String
        var logline: String
        var books: Int
        var figures: Int
    }
    struct Output: Encodable, Sendable {
        var worlds: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.world.list", summary: "Listet die Romanwelten", kind: .read, security: worldRead, output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.stories.loadIfNeeded()
        return Output(worlds: context.app.stories.worlds.map {
            Item(id: $0.id.uuidString, title: $0.title, genre: $0.genre, logline: $0.logline, books: $0.books.count, figures: $0.figures.count)
        })
    }
}

struct StoriesWorldCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String?
    }
    static let descriptor = ActionDescriptor(
        id: "stories.world.create", summary: "Legt eine Romanwelt an", kind: .write, security: .localWrite,
        input: .object(["title": .string("Titel")]), output: .freeObject(), example: "llmd stories world create --title Eisland", groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let library = context.app.stories
        let world = library.addWorld(title: args.title ?? "")
        context.undoGroup.add(UndoStep(label: "Romanwelt anlegen", undo: { [weak library] in library?.deleteWorld(world.id) }, redo: {}))
        return OKOutput(id: world.id.uuidString)
    }
}

struct StoriesWorldReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var depth: String?
    }
    struct Summary: Encodable, Sendable {
        var id: String
        var name: String
        var subtitle: String
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var genre: String
        var logline: String
        var overview: String?
        var rules: String?
        var themes: String?
        var parts: [StoriesPartTreeAction.Node]
        var elements: [String: [Summary]]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.world.read", summary: "Liest eine Welt; overview liefert nur Namen und Kurzzeilen", kind: .read, security: worldRead,
        input: .object(["world": worldProperty, "depth": .choice(["overview", "full"], "Standard: overview, das spart Kontext")], required: ["world"]),
        output: .freeObject(), example: "llmd stories world read Eisland --depth overview", groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let full = args.depth == "full"
        var elements: [String: [Summary]] = [:]
        for kind in StoryElementKind.listOrder {
            let entries = world.summaries(of: kind)
            if !entries.isEmpty {
                elements[kind.rawValue] = entries.map { Summary(id: $0.id.uuidString, name: $0.name, subtitle: $0.subtitle) }
            }
        }
        return Output(id: world.id.uuidString, title: world.title, genre: world.genre, logline: world.logline,
                      overview: full ? world.overview : nil, rules: full ? world.rules : nil, themes: full ? world.themes : nil,
                      parts: StoriesPartTreeAction.nodes(world.books, in: world), elements: elements)
    }
}

struct StoriesWorldUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var title: String?
        var genre: String?
        var logline: String?
        var overview: String?
        var rules: String?
        var themes: String?
    }
    static let descriptor = ActionDescriptor(
        id: "stories.world.update", summary: "Ändert Felder der Welt", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "title": .string("Titel"), "genre": .string("Genre"), "logline": .string("Prämisse"), "overview": .string("Überblick"), "rules": .string("Regeln der Welt"), "themes": .string("Themen")], required: ["world"]),
        output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let id = try context.app.actionWorld(args.world).id
        try context.changeWorld(id, label: "Welt ändern") { world in
            if let value = args.title { world.title = value }
            if let value = args.genre { world.genre = value }
            if let value = args.logline { world.logline = value }
            if let value = args.overview { world.overview = value }
            if let value = args.rules { world.rules = value }
            if let value = args.themes { world.themes = value }
        }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesWorldDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "stories.world.delete", summary: "Löscht eine Romanwelt endgültig", kind: .destructive, security: .destructive,
        input: .object(["world": worldProperty], required: ["world"]), output: .freeObject()
    )
    static func preflight(_ args: StoriesWorldArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionWorld(args.world).title)
    }
    static func run(_ args: StoriesWorldArgs, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        context.app.stories.deleteWorld(world.id)
        return OKOutput(id: world.id.uuidString)
    }
}

struct StoriesPartTreeAction: LLMDAction {
    struct Node: Encodable, Sendable {
        var id: String
        var level: String
        var title: String
        var status: String
        var children: [Node]?
    }
    struct Output: Encodable, Sendable {
        var parts: [Node]
    }
    static func nodes(_ parts: [StoryPart], in world: StoryWorld) -> [Node] {
        parts.map { part in
            Node(id: part.id.uuidString, level: part.level.rawValue, title: world.displayTitle(of: part), status: part.status.rawValue,
                 children: part.children.isEmpty ? nil : nodes(part.children, in: world))
        }
    }
    static let descriptor = ActionDescriptor(
        id: "stories.part.tree", summary: "Liefert die Gliederung: Bücher, Akte, Kapitel, Abschnitte", kind: .read, security: worldRead,
        input: .object(["world": worldProperty], required: ["world"]), output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: StoriesWorldArgs, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(parts: nodes(world.books, in: world))
    }
}

struct StoriesPartRefArgs: Decodable, Sendable {
    var world: String
    var part: String
}

private let aspects: [String: StoryElementKind] = ["was": .event, "mitWem": .figure, "wo": .place, "warum": .reason, "wozu": .purpose]

struct StoriesPartReadAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var id: String
        var level: String
        var title: String
        var subtitle: String
        var status: String
        var bookKind: String?
        var pov: String?
        var manuscript: String?
        var notes: String
        var focus: [String: String]
        var links: [String: [String]]
        var children: [StoriesPartTreeAction.Node]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.part.read", summary: "Liest einen Teil mit Fokus und Notizen", kind: .read, security: worldRead,
        input: .object(["world": worldProperty, "part": partProperty], required: ["world", "part"]), output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: StoriesPartRefArgs, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let part = try world.actionPart(args.part)
        var focus: [String: String] = [:]
        var links: [String: [String]] = [:]
        for (aspect, kind) in aspects {
            let text = part.focus.text(kind)
            if !text.isEmpty { focus[aspect] = text }
            let names = part.focus.ids(kind).compactMap { world.name(of: StoryRef(kind: kind, id: $0)) }
            if !names.isEmpty { links[aspect] = names }
        }
        return Output(id: part.id.uuidString, level: part.level.rawValue, title: world.displayTitle(of: part), subtitle: part.subtitle,
                      status: part.status.rawValue, bookKind: part.level == .book ? part.bookKind.rawValue : nil,
                      pov: part.povFigureID.flatMap { world.name(of: StoryRef(kind: .figure, id: $0)) },
                      manuscript: part.manuscriptID.flatMap { context.app.document($0) }?.id.uuidString, notes: part.notes,
                      focus: focus, links: links, children: StoriesPartTreeAction.nodes(part.children, in: world))
    }
}

struct StoriesPartAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var level: String
        var parent: String?
        var title: String?
    }
    static let descriptor = ActionDescriptor(
        id: "stories.part.add", summary: "Fügt ein Buch, einen Akt, ein Kapitel oder einen Abschnitt hinzu", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "level": .choice(StoryPartLevel.allCases.map(\.rawValue), "Stufe"), "parent": partProperty, "title": .string("Titel")], required: ["world", "level"]),
        output: .freeObject(), example: "llmd stories part add Eisland book --title 'Buch 1'", groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let parent = try args.parent.map { try world.actionPart($0).id }
        var made: UUID?
        try context.changeWorld(world.id, label: "Teil hinzufügen") { world in
            guard let level = StoryPartLevel(rawValue: args.level), let part = world.addPart(level, under: parent, title: args.title ?? "") else {
                throw RPCError.invalidTarget("„\(args.level)“ passt hier nicht: Ein Buch steht oben, darunter Akt, Kapitel, Abschnitt.")
            }
            made = part.id
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct StoriesPartUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var part: String
        var title: String?
        var subtitle: String?
        var notes: String?
        var status: String?
        var bookKind: String?
    }
    static let descriptor = ActionDescriptor(
        id: "stories.part.update", summary: "Ändert Titel, Notizen oder Status eines Teils", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "part": partProperty, "title": .string("Titel"), "subtitle": .string("Untertitel"), "notes": .string("Notizen"),
                        "status": .choice(DraftStatus.allCases.map(\.rawValue), "Stand"), "bookKind": .choice(BookKind.allCases.map(\.rawValue), "Art des Buchs")], required: ["world", "part"]),
        output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let id = try world.actionPart(args.part).id
        try context.changeWorld(world.id, label: "Teil ändern") { world in
            world.updatePart(id) { part in
                if let value = args.title { part.title = value }
                if let value = args.subtitle { part.subtitle = value }
                if let value = args.notes { part.notes = value }
                if let value = args.status.flatMap(DraftStatus.init(rawValue:)) { part.status = value }
                if let value = args.bookKind.flatMap(BookKind.init(rawValue:)) { part.bookKind = value }
            }
        }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesPartFocusSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var part: String
        var aspect: String
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "stories.part.focus.set", summary: "Setzt einen Fokus: Was, Mit wem, Wo, Warum, Wozu", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "part": partProperty, "aspect": .choice(["was", "mitWem", "wo", "warum", "wozu"], "Die Frage"), "text": .string("Antwort")], required: ["world", "part", "aspect", "text"]),
        output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let id = try world.actionPart(args.part).id
        guard let kind = aspects[args.aspect] else { throw RPCError.invalidParams("Unbekannter Aspekt.") }
        try context.changeWorld(world.id, label: "Fokus setzen") { world in
            world.updatePart(id) { $0.focus.setText(args.text, for: kind) }
        }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesPartDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "stories.part.delete", summary: "Löscht einen Teil mit allem darunter", kind: .destructive, security: .destructive,
        input: .object(["world": worldProperty, "part": partProperty], required: ["world", "part"]), output: .freeObject()
    )
    static func preflight(_ args: StoriesPartRefArgs, context: ActionContext) throws -> ActionPreflight {
        let world = try context.app.actionWorld(args.world)
        return ActionPreflight(target: world.displayTitle(of: try world.actionPart(args.part)))
    }
    static func run(_ args: StoriesPartRefArgs, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let id = try world.actionPart(args.part).id
        try context.changeWorld(world.id, label: "Teil löschen") { $0.removePart(id) }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesElementListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var kind: String?
        var query: String?
    }
    struct Item: Encodable, Sendable {
        var kind: String
        var id: String
        var name: String
        var subtitle: String
    }
    struct Output: Encodable, Sendable {
        var elements: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.element.list", summary: "Listet Elemente, kurz: Figuren, Orte, Events …", kind: .read, security: worldRead,
        input: .object(["world": worldProperty, "kind": .choice(StoryElementKind.allCases.map(\.rawValue), "Nur diese Art"), "query": .string("Suchtext im Namen")], required: ["world"]),
        output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let kinds = args.kind.flatMap(StoryElementKind.init(rawValue:)).map { [$0] } ?? StoryElementKind.listOrder
        return Output(elements: kinds.flatMap { kind in
            world.summaries(of: kind)
                .filter { args.query == nil || $0.name.localizedCaseInsensitiveContains(args.query!) }
                .map { Item(kind: kind.rawValue, id: $0.id.uuidString, name: $0.name, subtitle: $0.subtitle) }
        })
    }
}

struct StoriesElementRefArgs: Decodable, Sendable {
    var world: String
    var element: String
}

struct StoriesElementReadAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "stories.element.read", summary: "Liest ein Element mit allen Feldern", kind: .read, security: worldRead,
        input: .object(["world": worldProperty, "element": elementProperty], required: ["world", "element"]), output: .freeObject(),
        example: "llmd stories element read Eisland figure:Mara", groups: ["stories.core"]
    )
    static func run(_ args: StoriesElementRefArgs, context: ActionContext) async throws -> JSONValue {
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionElement(args.element)
        return world.elementJSON(ref) ?? .null
    }
}

struct StoriesElementCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var kind: String
        var name: String
        var fields: [String: JSONValue]?
    }
    static let descriptor = ActionDescriptor(
        id: "stories.element.create", summary: "Legt ein Element an: Figur, Ort, Event, Reason, Purpose, Spezies, Fakt", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "kind": .choice(StoryElementKind.allCases.map(\.rawValue), "Art"), "name": .string("Name"), "fields": .freeObject("Weitere Felder, z. B. biography")], required: ["world", "kind", "name"]),
        output: .freeObject(), example: #"llmd stories element create Eisland figure Mara --fields '{"biography":"…"}'"#, groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let id = try context.app.actionWorld(args.world).id
        guard let kind = StoryElementKind(rawValue: args.kind) else { throw RPCError.invalidParams("Unbekannte Art.") }
        var made: UUID?
        try context.changeWorld(id, label: "Element anlegen") { world in
            let ref = world.addElement(kind, name: args.name)
            if let fields = args.fields { try world.updateElementJSON(ref, fields: fields) }
            made = ref.id
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct StoriesElementUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String
        var element: String
        var fields: [String: JSONValue]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.element.update", summary: "Ändert Felder eines Elements", kind: .write, security: .localWrite,
        input: .object(["world": worldProperty, "element": elementProperty, "fields": .freeObject("Die Felder, z. B. {\"biography\": \"…\"}")], required: ["world", "element", "fields"]),
        output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionElement(args.element)
        try context.changeWorld(world.id, label: "Element ändern") { try $0.updateElementJSON(ref, fields: args.fields) }
        return OKOutput(id: ref.id.uuidString)
    }
}

struct StoriesElementDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "stories.element.delete", summary: "Löscht ein Element; Verweise werden überall entfernt", kind: .destructive, security: .destructive,
        input: .object(["world": worldProperty, "element": elementProperty], required: ["world", "element"]), output: .freeObject()
    )
    static func preflight(_ args: StoriesElementRefArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: args.element)
    }
    static func run(_ args: StoriesElementRefArgs, context: ActionContext) async throws -> OKOutput {
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionElement(args.element)
        try context.changeWorld(world.id, label: "Element löschen") { $0.removeElement(ref) }
        return OKOutput(id: ref.id.uuidString)
    }
}

struct StoriesElementUsagesAction: LLMDAction {
    struct Usage: Encodable, Sendable {
        var part: String?
        var title: String?
        var role: String
    }
    struct Output: Encodable, Sendable {
        var usages: [Usage]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.element.usages", summary: "Zeigt, wo ein Element verwendet wird", kind: .read, security: worldRead,
        input: .object(["world": worldProperty, "element": elementProperty], required: ["world", "element"]), output: .freeObject(), groups: ["stories.core"]
    )
    static func run(_ args: StoriesElementRefArgs, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionElement(args.element)
        return Output(usages: world.usages(of: ref).map { usage in
            Usage(part: usage.partID?.uuidString, title: usage.partID.flatMap { world.part($0) }.map(world.displayTitle(of:)), role: String(describing: usage.role))
        })
    }
}
