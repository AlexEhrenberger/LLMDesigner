import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerStoriesMoreActions() {
        register(StoriesWorldCalendarAction.self)
        register(StoriesWorldExportAction.self)
        register(StoriesPartBookKindAction.self)
        register(StoriesPartStatusAction.self)
        register(StoriesPartFocusLinkAction.self)
        register(StoriesPartFocusUnlinkAction.self)
        register(StoriesPartPovAction.self)
        register(StoriesPartMoveAction.self)
        register(StoriesPartReparentAction.self)
        register(StoriesOutlineCreateAction.self)
        register(StoriesElementCreateFromTextAction.self)
        register(StoriesElementFactsAction.self)
        register(StoriesElementSearchAction.self)
        register(StoriesElementPinsAction.self)
        register(StoriesFigurePersonalityAction.self)
        register(StoriesFigureRelationAddAction.self)
        register(StoriesFigureRelationUpdateAction.self)
        register(StoriesFigureRelationRemoveAction.self)
        register(StoriesFigureRelationsIncomingAction.self)
        register(StoriesFigureSceneAddAction.self)
        register(StoriesFigureSceneUpdateAction.self)
        register(StoriesFigureSceneRemoveAction.self)
        register(StoriesFigureImageAddAction.self)
        register(StoriesFigureImageRemoveAction.self)
        register(StoriesFigureVideoAddAction.self)
        register(StoriesFigureVideoRemoveAction.self)
        register(StoriesPlaceParentAction.self)
        register(StoriesPlacePossibleParentsAction.self)
        register(StoriesPlaceSubplacesAction.self)
        register(StoriesPlaceResidentsAction.self)
        register(StoriesPlaceImageAddAction.self)
        register(StoriesPlaceImageRemoveAction.self)
        register(StoriesEventPlacesAction.self)
        register(StoriesEventFiguresAction.self)
        register(StoriesEventCauseAddAction.self)
        register(StoriesEventCauseRemoveAction.self)
        register(StoriesEventCausesAction.self)
        register(StoriesEventFollowersAction.self)
        register(StoriesEventConsequenceAddAction.self)
        register(StoriesEventConsequenceUpdateAction.self)
        register(StoriesEventConsequenceRemoveAction.self)
        register(StoriesEventKnowledgeAction.self)
        register(StoriesReasonAssumptionAddAction.self)
        register(StoriesReasonPremiseAddAction.self)
        register(StoriesReasonStatementUpdateAction.self)
        register(StoriesReasonStatementRemoveAction.self)
        register(StoriesPurposeSetupAction.self)
        register(StoriesPurposePayoffAction.self)
        register(StoriesPurposeOpenPromisesAction.self)
        register(StoriesSpeciesHabitatAction.self)
        register(StoriesSpeciesMembersAction.self)
        register(StoriesSpeciesImageAddAction.self)
        register(StoriesSpeciesImageRemoveAction.self)
        register(StoriesFactTagAction.self)
        register(StoriesFactLinkAction.self)
        register(StoriesFactUnlinkAction.self)
        register(StoriesFactImageAddAction.self)
        register(StoriesFactImageRemoveAction.self)
        register(StoriesFactFilterAction.self)
        register(StoriesTimelineReadAction.self)
        register(StoriesTimelinePinAction.self)
        register(StoriesTimelineUpdateAction.self)
        register(StoriesTimelineUnpinAction.self)
        register(StoriesTimelineScaleAction.self)
        register(StoriesGalleryAddAction.self)
        register(StoriesGalleryUpdateAction.self)
        register(StoriesGalleryRemoveAction.self)
        register(StoriesGalleryListAction.self)
        register(StoriesImageGenerateAction.self)
        register(StoriesStudioOpenAction.self)
        register(StoriesStudioCloseAction.self)
    }
}

/// Everything these actions take; each schema says what it accepts.
struct StoriesArgs: Decodable, Sendable {
    var world: String
    var part: String?
    var parent: String?
    var element: String?
    var figure: String?
    var place: String?
    var event: String?
    var reason: String?
    var purpose: String?
    var species: String?
    var fact: String?
    var kind: String?
    var value: String?
    var aspect: String?
    var by: Int?
    var title: String?
    var text: String?
    var query: String?
    var note: String?
    var label: String?
    var attitude: Int?
    var target: String?
    var relation: String?
    var scene: String?
    var consequence: String?
    var statement: String?
    var entry: String?
    var area: String?
    var reach: String?
    var affected: [String]?
    var followEvent: String?
    var add: [String]?
    var remove: [String]?
    var tags: [String]?
    var file: String?
    var caption: String?
    var unit: String?
    var suffix: String?
    var start: Double?
    var end: Double?
    var knowledge: String?
    var knownBy: [String]?
    var validity: String?
    var energy: Double?
    var perception: Double?
    var decisions: Double?
    var lifestyle: Double?
    var energyNote: String?
    var perceptionNote: String?
    var decisionsNote: String?
    var lifestyleNote: String?
    var neuroticism: Double?
    var stressNote: String?
    var format: String?
    var path: String?
    var overwrite: Bool?
    var outline: [StoriesOutlineNode]?
    var prompt: String?
    var includesChildren: Bool?
}

struct StoriesOutlineNode: Decodable, Sendable {
    var level: String?
    var title: String
    var subtitle: String?
    var status: String?
    var was: String?
    var mitWem: String?
    var wo: String?
    var warum: String?
    var wozu: String?
    var children: [StoriesOutlineNode]?
}

private let worldSchema: [String: JSONSchema] = ["world": .string("Romanwelt (ID oder Titel)")]
private let partSchema: JSONSchema = .string("Teil (ID oder Pfad wie Buch 1/Akt 2)")
private let elementSchema: JSONSchema = .string("Element als art:name, z. B. figure:Mara")
private func named(_ kind: String) -> JSONSchema { .string("\(kind): Name oder ID") }
private let addRemove: [String: JSONSchema] = ["add": .array(of: .string(), "Hinzu"), "remove": .array(of: .string(), "Weg")]
private let ownerSchema: [String: JSONSchema] = ["part": .string("Teil, dessen Zeitleiste; ohne Angabe die der Welt")]
private let imageNameSchema: JSONSchema = .string("Dateiname des Bildes; ohne Angabe das einzige")

private func schema(_ properties: [String: JSONSchema], required: [String] = []) -> JSONSchema {
    .object(worldSchema.merging(properties) { _, new in new }, required: ["world"] + required)
}

private let plainStories = ActionSecurity.foreignRead

extension StoryWorld {
    /// A reference that knows its kind: `Mara` as well as `figure:Mara` or an id.
    func actionRef(_ kind: StoryElementKind, _ text: String?) throws -> StoryRef {
        guard let text, !text.isEmpty else { throw RPCError.invalidParams("Bitte \(kind.singular) angeben.") }
        let reference = text.hasPrefix(kind.rawValue + ":") ? text : kind.rawValue + ":" + text
        return try actionElement(reference)
    }

    func actionIDs(_ kind: StoryElementKind, _ names: [String]?) throws -> [UUID] {
        try (names ?? []).map { try actionRef(kind, $0).id }
    }

    func resolvedOwner(_ part: String?) throws -> TimelineOwner {
        guard let part else { return .world }
        let found = try actionPart(part)
        guard found.level.hasTimeline else { throw RPCError.invalidTarget("Abschnitte haben keine Zeitleiste.") }
        return .part(found.id)
    }

    /// An element's name for a result.
    func label(_ ref: StoryRef) -> String { name(of: ref) ?? "" }
}

/// An id list with what a call adds and takes away; order stays.
private func merged(_ list: [UUID], add: [UUID], remove: [UUID]) -> [UUID] {
    var result = list
    for id in add where !result.contains(id) { result.append(id) }
    return result.filter { !remove.contains($0) }
}

private func mediaPreflight(_ file: String?, channel: ActionChannel) -> ActionPreflight {
    var check = ActionPreflight(target: file)
    // A model or a client names a path: shown afterwards, that would show it any picture on this Mac.
    if channel == .chat || channel == .mcp {
        check.needsConsent = "Eine Datei von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer sichtbar."
    }
    return check
}

/// A reference by name to an element, in a short form for results.
struct StoriesElementInfo: Encodable, Sendable {
    var ref: String
    var name: String
    var subtitle: String?
}

private extension StoryElement {
    var info: StoriesElementInfo { StoriesElementInfo(ref: "\(Self.kind.rawValue):\(id.uuidString)", name: displayName, subtitle: subtitle.isEmpty ? nil : subtitle) }
}

struct StoriesListOutput: Encodable, Sendable {
    var items: [StoriesElementInfo]
}

// MARK: World

struct StoriesWorldCalendarAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.world.calendar", summary: "Setzt den Kalender der Welt, z. B. Jahr und n. d. F.", kind: .write, security: .localWrite,
        input: schema(["unit": .string("Zeiteinheit"), "suffix": .string("Nachsatz")], required: ["unit"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        try context.changeWorld(world.id, label: "Kalender") { $0.calendar = TimelineScale(unit: args.unit ?? "Jahr", suffix: args.suffix ?? "") }
        return OKOutput(id: world.id.uuidString)
    }
}

/// The story bible as Markdown: what is known about the world, with its structure and elements.
enum StoriesBible {
    static func markdown(of world: StoryWorld) -> String {
        var lines = ["# " + world.displayTitle]
        func section(_ title: String, _ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            lines += ["", "**\(title):** " + text]
        }
        section("Genre", world.genre)
        section("Logline", world.logline)
        section("Überblick", world.overview)
        section("Regeln", world.rules)
        section("Themen", world.themes)
        func walk(_ parts: [StoryPart], depth: Int) {
            for part in parts {
                lines += ["", String(repeating: "#", count: min(6, depth)) + " " + world.displayTitle(of: part)]
                for kind in [StoryElementKind.event, .figure, .place, .reason, .purpose] {
                    let text = part.focus.text(kind)
                    if !text.isEmpty { lines += ["", "**\(kind.question)** " + text] }
                }
                if !part.notes.isEmpty { lines += ["", part.notes] }
                walk(part.children, depth: depth + 1)
            }
        }
        if !world.books.isEmpty {
            lines += ["", "## Struktur"]
            walk(world.books, depth: 3)
        }
        for kind in StoryElementKind.allCases {
            let entries = world.summaries(of: kind)
            guard !entries.isEmpty else { continue }
            lines += ["", "## " + kind.title]
            for entry in entries {
                lines += ["", "### " + entry.name]
                if !entry.subtitle.isEmpty { lines += ["", entry.subtitle] }
                if case .object(let fields)? = world.elementJSON(StoryRef(kind: kind, id: entry.id)) {
                    for key in fields.keys.sorted() where !["id", "name", "createdAt", "updatedAt"].contains(key) {
                        if let text = fields[key]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty, UUID(uuidString: text) == nil {
                            lines += ["", "**\(key):** " + text]
                        }
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct StoriesWorldExportAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "stories.world.export", summary: "Schreibt eine Welt als Story-Bible in eine Datei", kind: .destructive, security: .outbound,
        input: schema(["format": .choice(["markdown", "json"], "Standard: markdown"), "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen")]),
        output: .freeObject(), example: "llmd stories world export --world Saga"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let world = try context.app.actionWorld(args.world)
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let inFolder = args.path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        // World files have no origin of their own (see the other world actions), so they count as foreign here too.
        return ActionPreflight(readsUntrusted: true, isInSafePlace: inFolder, target: args.path ?? folder.path, detail: world.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let isJSON = args.format == "json"
        let data: Data
        if isJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(world)
        } else {
            data = Data(StoriesBible.markdown(of: world).utf8)
        }
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let url = args.path.map(ActionExportFolder.expanded) ?? ActionExportFolder.freeFile(named: world.displayTitle, extension: isJSON ? "json" : "md", in: folder)
        guard args.path == nil || args.overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.invalidTarget("Die Datei gibt es schon: \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: data.count)
    }
}

// MARK: Parts

private let aspectKinds: [String: StoryElementKind] = ["was": .event, "mitWem": .figure, "wo": .place, "warum": .reason, "wozu": .purpose]

@MainActor
private func changePart(_ args: StoriesArgs, label: String, context: ActionContext, _ change: (inout StoryPart, StoryWorld) throws -> Void) throws -> OKOutput {
    let world = try context.app.actionWorld(args.world)
    let id = try world.actionPart(args.part ?? "").id
    var failure: Error?
    try context.changeWorld(world.id, label: label) { world in
        let snapshot = world
        world.updatePart(id) { part in
            do { try change(&part, snapshot) } catch { failure = error }
        }
    }
    if let failure { throw failure }
    return OKOutput(id: id.uuidString)
}

struct StoriesPartBookKindAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.bookKind", summary: "Setzt die Art eines Buchs", kind: .write, security: .localWrite,
        input: schema(["part": partSchema, "value": .choice(BookKind.allCases.map(\.rawValue), "Die Art")], required: ["part", "value"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changePart(args, label: "Buchart", context: context) { part, _ in
            guard part.level == .book else { throw RPCError.invalidTarget("Eine Art haben nur Bücher.") }
            part.bookKind = args.value.flatMap(BookKind.init(rawValue:)) ?? part.bookKind
        }
    }
}

struct StoriesPartStatusAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.status", summary: "Setzt den Stand eines Teils", kind: .write, security: .localWrite,
        input: schema(["part": partSchema, "value": .choice(DraftStatus.allCases.map(\.rawValue), "Der Stand")], required: ["part", "value"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changePart(args, label: "Stand", context: context) { part, _ in part.status = args.value.flatMap(DraftStatus.init(rawValue:)) ?? part.status }
    }
}

private let focusSchema: [String: JSONSchema] = [
    "part": partSchema, "aspect": .choice(["was", "mitWem", "wo", "warum", "wozu"], "Die Frage"), "element": .string("Element: Name oder art:name; die Art folgt aus der Frage"),
]

struct StoriesPartFocusLinkAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.focus.link", summary: "Verknüpft einen Fokus mit einem Element", kind: .write, security: .localWrite,
        input: schema(focusSchema, required: ["part", "aspect", "element"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let kind = aspectKinds[args.aspect ?? ""] else { throw RPCError.invalidParams("Unbekannte Frage.") }
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionRef(kind, args.element)
        return try changePart(args, label: "Fokus verknüpfen", context: context) { part, _ in part.focus.link(ref.id, as: kind) }
    }
}

struct StoriesPartFocusUnlinkAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.focus.unlink", summary: "Löst die Verknüpfung eines Fokus", kind: .write, security: .localWrite,
        input: schema(focusSchema, required: ["part", "aspect", "element"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let kind = aspectKinds[args.aspect ?? ""] else { throw RPCError.invalidParams("Unbekannte Frage.") }
        let world = try context.app.actionWorld(args.world)
        let ref = try world.actionRef(kind, args.element)
        return try changePart(args, label: "Fokus lösen", context: context) { part, _ in part.focus.unlink(ref.id, as: kind) }
    }
}

struct StoriesPartPovAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.pov", summary: "Setzt die Erzählperspektive eines Kapitels oder Abschnitts; ohne figure keine", kind: .write, security: .localWrite,
        input: schema(["part": partSchema, "figure": named("Figur")], required: ["part"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let figure = try args.figure.map { try world.actionRef(.figure, $0).id }
        return try changePart(args, label: "Perspektive", context: context) { part, _ in
            guard part.level.hasPointOfView else { throw RPCError.invalidTarget("Eine Perspektive haben nur Kapitel und Abschnitte.") }
            part.povFigureID = figure
        }
    }
}

struct StoriesPartMoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.move", summary: "Rückt einen Teil unter seinen Geschwistern vor oder zurück", kind: .write, security: .localWrite,
        input: schema(["part": partSchema, "by": .integer("-1 nach vorn, 1 nach hinten", minimum: -1, maximum: 1)], required: ["part", "by"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let id = try world.actionPart(args.part ?? "").id
        let offset = args.by ?? 0
        guard world.canMovePart(id, by: offset) else { throw RPCError.invalidTarget("Dorthin lässt sich der Teil nicht rücken.") }
        try context.changeWorld(world.id, label: "Teil verschieben") { $0.movePart(id, by: offset) }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesPartReparentAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.part.reparent", summary: "Hängt einen Teil unter einen anderen, eine Ebene über ihm; sein Inhalt wandert mit", kind: .write, security: .localWrite,
        input: schema(["part": partSchema, "parent": .string("Neuer übergeordneter Teil")], required: ["part", "parent"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let part = try world.actionPart(args.part ?? "")
        let parent = try world.actionPart(args.parent ?? "")
        guard parent.level.child == part.level else {
            throw RPCError.invalidTarget("\(part.level.label) gehört nicht unter \(parent.level.label).")
        }
        guard parent.id != part.id, !world.path(to: parent.id).contains(where: { $0.id == part.id }) else {
            throw RPCError.invalidTarget("Ein Teil kann nicht unter sich selbst hängen.")
        }
        try context.changeWorld(world.id, label: "Teil umhängen") { world in
            func take(_ parts: inout [StoryPart]) {
                parts.removeAll { $0.id == part.id }
                for index in parts.indices { take(&parts[index].children) }
            }
            take(&world.books)
            world.updatePart(parent.id) { $0.children.append(part) }
        }
        return OKOutput(id: part.id.uuidString)
    }
}

struct StoriesOutlineCreateAction: LLMDAction {
    typealias Args = StoriesArgs
    struct Output: Encodable, Sendable {
        var created: Int
    }
    private static let node: JSONSchema = .object([
        "level": .choice(StoryPartLevel.allCases.map(\.rawValue), "Standard: die Ebene unter dem übergeordneten Teil"),
        "title": .string("Titel"), "subtitle": .string("Untertitel"), "status": .choice(DraftStatus.allCases.map(\.rawValue), "Stand"),
        "was": .string("Was"), "mitWem": .string("Mit wem"), "wo": .string("Wo"), "warum": .string("Warum"), "wozu": .string("Wozu"),
        "children": .array(of: .freeObject(), "Unterteile in derselben Form"),
    ], required: ["title"])
    static let descriptor = ActionDescriptor(
        id: "stories.outline.create", summary: "Legt eine ganze Gliederung in einem Aufruf an: Bücher, Akte, Kapitel mit Fokus", kind: .write, security: .localWrite,
        input: schema(["parent": .string("Darunter; ohne Angabe als neue Bücher"), "outline": .array(of: node, "Die Teile")], required: ["outline"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let parent = try args.parent.map { try world.actionPart($0) }
        var created = 0
        try context.changeWorld(world.id, label: "Gliederung anlegen") { world in
            func add(_ nodes: [StoriesOutlineNode], under parent: StoryPart?) throws {
                for node in nodes {
                    guard let level = node.level.flatMap(StoryPartLevel.init(rawValue:)) ?? (parent == nil ? .book : parent?.level.child) else {
                        throw RPCError.invalidParams("Unter „\(parent?.title ?? "")“ gibt es keine Ebene mehr.")
                    }
                    guard let made = world.addPart(level, under: parent?.id, title: node.title) else {
                        throw RPCError.invalidParams("\(level.label) „\(node.title)“ passt hier nicht hin.")
                    }
                    created += 1
                    world.updatePart(made.id) { part in
                        if let subtitle = node.subtitle { part.subtitle = subtitle }
                        if let status = node.status.flatMap(DraftStatus.init(rawValue:)) { part.status = status }
                        for (text, kind) in [(node.was, StoryElementKind.event), (node.mitWem, .figure), (node.wo, .place), (node.warum, .reason), (node.wozu, .purpose)] {
                            if let text { part.focus.setText(text, for: kind) }
                        }
                    }
                    if let children = node.children, !children.isEmpty { try add(children, under: world.part(made.id)) }
                }
            }
            try add(args.outline ?? [], under: parent)
        }
        return Output(created: created)
    }
}

// MARK: Elements in general

/// The field of a kind that holds its main text.
private func mainField(_ kind: StoryElementKind) -> String {
    switch kind {
    case .figure: "biography"
    case .place: "atmosphere"
    case .event: "course"
    case .reason: "conclusion"
    case .purpose: "intent"
    case .species: "appearance"
    case .fact: "text"
    }
}

struct StoriesElementCreateFromTextAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.element.createFromText", summary: "Legt ein Element aus Text an: die erste Zeile wird Name, der Rest Haupttext", kind: .write, security: .localWrite,
        input: schema(["kind": .choice(StoryElementKind.allCases.map(\.rawValue), "Art"), "text": .string("Der Text")], required: ["kind", "text"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let kind = args.kind.flatMap(StoryElementKind.init(rawValue:)) else { throw RPCError.invalidParams("Unbekannte Art.") }
        let lines = (args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let name = lines.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { throw RPCError.invalidParams("Der Text ist leer.") }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let world = try context.app.actionWorld(args.world)
        var made: StoryRef?
        try context.changeWorld(world.id, label: "Element anlegen") { world in
            let ref = world.addElement(kind, name: name)
            if !body.isEmpty { try world.updateElementJSON(ref, fields: [mainField(kind): .string(body)]) }
            made = ref
        }
        return OKOutput(id: made?.id.uuidString)
    }
}

struct StoriesElementFactsAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(
        id: "stories.element.facts", summary: "Listet die Fakten zu einem Element", kind: .read, security: plainStories,
        input: schema(["element": elementSchema], required: ["element"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.facts(about: try world.actionElement(args.element ?? "")).map(\.info))
    }
}

struct StoriesElementSearchAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(
        id: "stories.element.search", summary: "Sucht in Namen und Texten aller Elemente einer Welt", kind: .read, security: plainStories,
        input: schema(["query": .string("Suchtext")], required: ["query"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let query = args.query ?? ""
        guard !query.isEmpty else { throw RPCError.invalidParams("Leerer Suchtext.") }
        var items: [StoriesElementInfo] = []
        for kind in StoryElementKind.allCases {
            for entry in world.summaries(of: kind) {
                let ref = StoryRef(kind: kind, id: entry.id)
                let text = world.elementJSON(ref)?.jsonLine() ?? ""
                if entry.name.localizedStandardContains(query) || text.localizedStandardContains(query) {
                    items.append(StoriesElementInfo(ref: "\(kind.rawValue):\(entry.id.uuidString)", name: entry.name, subtitle: entry.subtitle.isEmpty ? nil : entry.subtitle))
                }
            }
        }
        return Output(items: items)
    }
}

struct StoriesElementPinsAction: LLMDAction {
    typealias Args = StoriesArgs
    struct Pin: Encodable, Sendable {
        var entry: String
        var timeline: String
        var part: String?
        var start: Double
        var end: Double?
        var note: String
    }
    struct Output: Encodable, Sendable {
        var pins: [Pin]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.element.pins", summary: "Zeigt alle Einträge eines Elements auf den Zeitleisten", kind: .read, security: plainStories,
        input: schema(["element": elementSchema], required: ["element"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(pins: world.pins(of: try world.actionElement(args.element ?? "")).map { pin in
            var part: String?
            if case .part(let id) = pin.owner { part = id.uuidString }
            return Pin(entry: pin.entry.id.uuidString, timeline: world.title(of: pin.owner), part: part, start: pin.entry.start, end: pin.entry.end, note: pin.entry.note)
        })
    }
}

// MARK: Figures

@MainActor
private func changeElement<E: StoryElement>(_ type: E.Type, reference: String?, world worldName: String, label: String, context: ActionContext, _ change: (inout E, StoryWorld) throws -> Void) throws -> OKOutput {
    let world = try context.app.actionWorld(worldName)
    let id = try world.actionRef(E.kind, reference).id
    var failure: Error?
    try context.changeWorld(world.id, label: label) { world in
        let snapshot = world
        world.updateElement(type, id) { element in
            do { try change(&element, snapshot) } catch { failure = error }
        }
    }
    if let failure { throw failure }
    return OKOutput(id: id.uuidString)
}

struct StoriesFigurePersonalityAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    private static func axis(_ text: String) -> JSONSchema { .number(text, minimum: -1, maximum: 1) }
    static let descriptor = ActionDescriptor(
        id: "stories.figure.personality", summary: "Setzt das Persönlichkeitsprofil einer Figur", kind: .write, security: .localWrite,
        input: schema([
            "figure": named("Figur"),
            "energy": axis("Energie: negativ E, positiv I"), "perception": axis("Wahrnehmung: negativ S, positiv N"),
            "decisions": axis("Entscheidungen: negativ T, positiv F"), "lifestyle": axis("Lebensstil: negativ J, positiv P"),
            "energyNote": .string("Notiz"), "perceptionNote": .string("Notiz"), "decisionsNote": .string("Notiz"), "lifestyleNote": .string("Notiz"),
            "neuroticism": .number("0 gelassen bis 1 neurotisch", minimum: 0, maximum: 1), "stressNote": .string("Verhalten unter Druck"),
        ], required: ["figure"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Persönlichkeit", context: context) { figure, _ in
            var profile = figure.personality
            for (axis, value, note) in [(PersonalityProfile.Axis.energy, args.energy, args.energyNote), (.perception, args.perception, args.perceptionNote),
                                        (.decisions, args.decisions, args.decisionsNote), (.lifestyle, args.lifestyle, args.lifestyleNote)] {
                if let value { profile.values[axis] = value }
                if let note { profile.notes[axis] = note }
            }
            if let value = args.neuroticism { profile.neuroticism = value }
            if let note = args.stressNote { profile.stressNote = note }
            figure.personality = profile
        }
    }
}

private let relationTarget: JSONSchema = .string("Wozu: art:name, z. B. figure:Nora oder place:Burg")

struct StoriesFigureRelationAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.relation.add", summary: "Gibt einer Figur eine Haltung zu einer Figur, einem Ereignis oder Ort", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "target": relationTarget, "attitude": .integer("-2 feindlich bis 2 loyal", minimum: -2, maximum: 2), "label": .string("z. B. Bruder"), "note": .string("Notiz")], required: ["figure", "target"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let target = try world.actionElement(args.target ?? "")
        let relation = StoryRelation(target: target, attitude: args.attitude ?? 0, label: args.label ?? "", note: args.note ?? "")
        _ = try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Beziehung", context: context) { figure, _ in figure.relations.append(relation) }
        return OKOutput(id: relation.id.uuidString)
    }
}

struct StoriesFigureRelationUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.relation.update", summary: "Ändert eine Beziehung", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "relation": .string("Beziehung (ID)"), "attitude": .integer("-2 bis 2", minimum: -2, maximum: 2), "label": .string("Bezeichnung"), "note": .string("Notiz")], required: ["figure", "relation"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Beziehung", context: context) { figure, _ in
            guard let index = figure.relations.firstIndex(where: { $0.id.uuidString == args.relation }) else { throw RPCError.notFound("Diese Beziehung gibt es nicht.") }
            if let attitude = args.attitude { figure.relations[index].attitude = attitude }
            if let label = args.label { figure.relations[index].label = label }
            if let note = args.note { figure.relations[index].note = note }
        }
    }
}

struct StoriesFigureRelationRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.relation.remove", summary: "Entfernt eine Beziehung", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "relation": .string("Beziehung (ID)")], required: ["figure", "relation"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Beziehung", context: context) { figure, _ in
            guard figure.relations.contains(where: { $0.id.uuidString == args.relation }) else { throw RPCError.notFound("Diese Beziehung gibt es nicht.") }
            figure.relations.removeAll { $0.id.uuidString == args.relation }
        }
    }
}

struct StoriesFigureRelationsIncomingAction: LLMDAction {
    typealias Args = StoriesArgs
    struct Item: Encodable, Sendable {
        var figure: String
        var relation: String
        var attitude: Int
        var label: String
        var note: String
    }
    struct Output: Encodable, Sendable {
        var relations: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.figure.relations.incoming", summary: "Zeigt, wer wie zu einer Figur oder einem Element steht", kind: .read, security: plainStories,
        input: schema(["element": elementSchema], required: ["element"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(relations: world.incomingRelations(to: try world.actionElement(args.element ?? "")).map {
            Item(figure: $0.figure.displayName, relation: $0.relation.id.uuidString, attitude: $0.relation.attitude, label: $0.relation.label, note: $0.relation.note)
        })
    }
}

struct StoriesFigureSceneAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.scene.add", summary: "Trägt ein Zitat, eine Beispielszene oder ein Vorkommnis ins Szenenbuch einer Figur ein", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "kind": .choice(SceneNote.Kind.allCases.map(\.rawValue), "Art"), "text": .string("Der Text"), "part": partSchema], required: ["figure", "kind", "text"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        var note = SceneNote(kind: args.kind.flatMap(SceneNote.Kind.init(rawValue:)) ?? .scene)
        note.text = args.text ?? ""
        note.partID = try args.part.map { try world.actionPart($0).id }
        let made = note
        _ = try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Szenenbuch", context: context) { figure, _ in figure.scenes.append(made) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct StoriesFigureSceneUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.scene.update", summary: "Ändert einen Eintrag im Szenenbuch", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "scene": .string("Eintrag (ID)"), "kind": .choice(SceneNote.Kind.allCases.map(\.rawValue), "Art"), "text": .string("Der Text"), "part": partSchema], required: ["figure", "scene"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let part = try args.part.map { try world.actionPart($0).id }
        return try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Szenenbuch", context: context) { figure, _ in
            guard let index = figure.scenes.firstIndex(where: { $0.id.uuidString == args.scene }) else { throw RPCError.notFound("Diesen Eintrag gibt es nicht.") }
            if let kind = args.kind.flatMap(SceneNote.Kind.init(rawValue:)) { figure.scenes[index].kind = kind }
            if let text = args.text { figure.scenes[index].text = text }
            if let part { figure.scenes[index].partID = part }
        }
    }
}

struct StoriesFigureSceneRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.figure.scene.remove", summary: "Entfernt einen Eintrag aus dem Szenenbuch", kind: .write, security: .localWrite,
        input: schema(["figure": named("Figur"), "scene": .string("Eintrag (ID)")], required: ["figure", "scene"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Szenenbuch", context: context) { figure, _ in
            guard figure.scenes.contains(where: { $0.id.uuidString == args.scene }) else { throw RPCError.notFound("Diesen Eintrag gibt es nicht.") }
            figure.scenes.removeAll { $0.id.uuidString == args.scene }
        }
    }
}

// MARK: Media

/// A picture from a file, in the world's folder.
@MainActor
private func importedImage(_ args: StoriesArgs, world: StoryWorld, context: ActionContext) throws -> StoryImage {
    let url = ActionExportFolder.expanded(args.file ?? "")
    guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
    guard var image = context.app.stories.importImages([url], into: world.id).first else { throw RPCError.invalidTarget("Das ist kein Bild.") }
    image.caption = args.caption ?? ""
    return image
}

/// Which of these pictures a call means. The file stays in the library: the step can be taken back.
private func imageIndex(_ images: [StoryImage], _ name: String?) throws -> Int {
    guard let name else {
        guard images.count == 1 else { throw images.isEmpty ? RPCError.notFound("Hier gibt es keine Bilder.") : RPCError.ambiguous("Hier gibt es \(images.count) Bilder. Bitte file angeben.", candidates: images.map(\.fileName)) }
        return 0
    }
    guard let index = images.firstIndex(where: { $0.fileName == name }) else { throw RPCError.notFound("Das Bild „\(name)“ gibt es hier nicht.") }
    return index
}

private func imageAdd(_ kind: String) -> [String: JSONSchema] { [kind: named(kind.capitalized), "file": .string("Pfad der Bilddatei"), "caption": .string("Bildunterschrift")] }
private func imageRemove(_ kind: String) -> [String: JSONSchema] { [kind: named(kind.capitalized), "file": imageNameSchema] }

struct StoriesFigureImageAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.figure.image.add", summary: "Gibt einer Figur ein Bild", kind: .write, security: .localWrite, input: schema(imageAdd("figure"), required: ["figure", "file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let image = try importedImage(args, world: try context.app.actionWorld(args.world), context: context)
        _ = try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Bild", context: context) { $0.images.append(image); _ = $1 }
        return OKOutput(id: image.fileName)
    }
}

struct StoriesFigureImageRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.figure.image.remove", summary: "Nimmt einer Figur ein Bild", kind: .write, security: .localWrite, input: schema(imageRemove("figure"), required: ["figure"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Bild", context: context) { element, _ in element.images.remove(at: try imageIndex(element.images, args.file)) }
    }
}

struct StoriesFigureVideoAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.figure.video.add", summary: "Gibt einer Figur eine Videocard", kind: .write, security: .localWrite, input: schema(["figure": named("Figur"), "file": .string("Pfad der Videodatei"), "caption": .string("Unterschrift")], required: ["figure", "file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        guard var video = context.app.stories.importVideos([url], into: world.id).first else { throw RPCError.invalidTarget("Das ist kein Video.") }
        video.caption = args.caption ?? ""
        let made = video
        _ = try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Video", context: context) { figure, _ in figure.videos.append(made) }
        return OKOutput(id: made.fileName)
    }
}

struct StoriesFigureVideoRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.figure.video.remove", summary: "Nimmt einer Figur eine Videocard", kind: .write, security: .localWrite, input: schema(["figure": named("Figur"), "file": .string("Dateiname des Videos; ohne Angabe das einzige")], required: ["figure"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFigure.self, reference: args.figure, world: args.world, label: "Video", context: context) { figure, _ in
            let found = args.file.map { name in figure.videos.filter { $0.fileName == name } } ?? figure.videos
            guard found.count == 1 else { throw found.isEmpty ? RPCError.notFound("Dieses Video gibt es hier nicht.") : RPCError.ambiguous("Hier gibt es mehrere Videos. Bitte file angeben.", candidates: found.map(\.fileName)) }
            figure.videos.removeAll { $0.fileName == found[0].fileName }
        }
    }
}

// MARK: Places

struct StoriesPlaceParentAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.place.parent", summary: "Legt einen Ort in einen anderen; ohne parent steht er für sich", kind: .write, security: .localWrite, input: schema(["place": named("Ort"), "parent": named("Übergeordneter Ort")], required: ["place"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let place = try world.actionRef(.place, args.place)
        let parent = try args.parent.map { try world.actionRef(.place, $0).id }
        if let parent, !world.possibleParents(of: place.id).contains(where: { $0.id == parent }) {
            throw RPCError.invalidTarget("Ein Ort kann nicht in sich selbst oder einem seiner Teile liegen.")
        }
        return try changeElement(StoryPlace.self, reference: args.place, world: args.world, label: "Ort einordnen", context: context) { element, _ in element.parentID = parent }
    }
}

struct StoriesPlacePossibleParentsAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.place.possibleParents", summary: "Listet die Orte, in denen ein Ort liegen kann", kind: .read, security: plainStories, input: schema(["place": named("Ort")], required: ["place"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.possibleParents(of: try world.actionRef(.place, args.place).id).map(\.info))
    }
}

struct StoriesPlaceSubplacesAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.place.subplaces", summary: "Listet die Orte in einem Ort", kind: .read, security: plainStories, input: schema(["place": named("Ort")], required: ["place"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.subplaces(of: try world.actionRef(.place, args.place).id).map(\.info))
    }
}

struct StoriesPlaceResidentsAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.place.residents", summary: "Ändert, welche Figuren an einem Ort leben", kind: .write, security: .localWrite, input: schema(["place": named("Ort")].merging(addRemove) { _, new in new }, required: ["place"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try world.actionIDs(.figure, args.add), remove = try world.actionIDs(.figure, args.remove)
        return try changeElement(StoryPlace.self, reference: args.place, world: args.world, label: "Bewohner", context: context) { place, _ in place.residentIDs = merged(place.residentIDs, add: add, remove: remove) }
    }
}

struct StoriesPlaceImageAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.place.image.add", summary: "Gibt einem Ort ein Bild", kind: .write, security: .localWrite, input: schema(imageAdd("place"), required: ["place", "file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let image = try importedImage(args, world: try context.app.actionWorld(args.world), context: context)
        _ = try changeElement(StoryPlace.self, reference: args.place, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(image) }
        return OKOutput(id: image.fileName)
    }
}

struct StoriesPlaceImageRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.place.image.remove", summary: "Nimmt einem Ort ein Bild", kind: .write, security: .localWrite, input: schema(imageRemove("place"), required: ["place"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryPlace.self, reference: args.place, world: args.world, label: "Bild", context: context) { element, _ in element.images.remove(at: try imageIndex(element.images, args.file)) }
    }
}

// MARK: Events

struct StoriesEventPlacesAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.places", summary: "Ändert die Orte eines Ereignisses", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis")].merging(addRemove) { _, new in new }, required: ["event"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try world.actionIDs(.place, args.add), remove = try world.actionIDs(.place, args.remove)
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Orte", context: context) { event, _ in event.placeIDs = merged(event.placeIDs, add: add, remove: remove) }
    }
}

struct StoriesEventFiguresAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.figures", summary: "Ändert die Figuren eines Ereignisses", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis")].merging(addRemove) { _, new in new }, required: ["event"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try world.actionIDs(.figure, args.add), remove = try world.actionIDs(.figure, args.remove)
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Figuren", context: context) { event, _ in event.figureIDs = merged(event.figureIDs, add: add, remove: remove) }
    }
}

struct StoriesEventCauseAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.cause.add", summary: "Nennt ein Ereignis als Ursache eines anderen", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis"), "target": named("Ursache")], required: ["event", "target"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let event = try world.actionRef(.event, args.event).id, cause = try world.actionRef(.event, args.target).id
        guard event != cause else { throw RPCError.invalidParams("Ein Ereignis kann nicht seine eigene Ursache sein.") }
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Ursache", context: context) { element, _ in element.causeEventIDs = merged(element.causeEventIDs, add: [cause], remove: []) }
    }
}

struct StoriesEventCauseRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.cause.remove", summary: "Nimmt eine Ursache von einem Ereignis", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis"), "target": named("Ursache")], required: ["event", "target"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let cause = try world.actionRef(.event, args.target).id
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Ursache", context: context) { element, _ in element.causeEventIDs.removeAll { $0 == cause } }
    }
}

struct StoriesEventCausesAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.event.causes", summary: "Listet die Ereignisse, die zu einem führen", kind: .read, security: plainStories, input: schema(["event": named("Ereignis")], required: ["event"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.causes(of: try world.actionRef(.event, args.event).id).map(\.info))
    }
}

struct StoriesEventFollowersAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.event.followers", summary: "Listet die Ereignisse, die aus einem folgen", kind: .read, security: plainStories, input: schema(["event": named("Ereignis")], required: ["event"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.followers(of: try world.actionRef(.event, args.event).id).map(\.info))
    }
}

private let consequenceFields: [String: JSONSchema] = [
    "area": .choice(EventConsequence.Area.allCases.map(\.rawValue), "Bereich"), "reach": .choice(EventConsequence.Reach.allCases.map(\.rawValue), "Reichweite"),
    "text": .string("Die Folge"), "affected": .array(of: .string(), "Betroffene als art:name"), "followEvent": named("Folgeereignis"),
]

struct StoriesEventConsequenceAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.consequence.add", summary: "Trägt eine Folge eines Ereignisses ein", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis")].merging(consequenceFields) { _, new in new }, required: ["event", "text"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        var consequence = EventConsequence()
        if let area = args.area.flatMap(EventConsequence.Area.init(rawValue:)) { consequence.area = area }
        if let reach = args.reach.flatMap(EventConsequence.Reach.init(rawValue:)) { consequence.reach = reach }
        consequence.text = args.text ?? ""
        consequence.affected = try (args.affected ?? []).map { try world.actionElement($0) }
        consequence.followEventID = try args.followEvent.map { try world.actionRef(.event, $0).id }
        let made = consequence
        _ = try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Folge", context: context) { event, _ in event.consequences.append(made) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct StoriesEventConsequenceUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.consequence.update", summary: "Ändert eine Folge", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis"), "consequence": .string("Folge (ID)")].merging(consequenceFields) { _, new in new }, required: ["event", "consequence"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let affected = try args.affected?.map { try world.actionElement($0) }
        let follow = try args.followEvent.map { try world.actionRef(.event, $0).id }
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Folge", context: context) { event, _ in
            guard let index = event.consequences.firstIndex(where: { $0.id.uuidString == args.consequence }) else { throw RPCError.notFound("Diese Folge gibt es nicht.") }
            if let area = args.area.flatMap(EventConsequence.Area.init(rawValue:)) { event.consequences[index].area = area }
            if let reach = args.reach.flatMap(EventConsequence.Reach.init(rawValue:)) { event.consequences[index].reach = reach }
            if let text = args.text { event.consequences[index].text = text }
            if let affected { event.consequences[index].affected = affected }
            if let follow { event.consequences[index].followEventID = follow }
        }
    }
}

struct StoriesEventConsequenceRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.consequence.remove", summary: "Entfernt eine Folge", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis"), "consequence": .string("Folge (ID)")], required: ["event", "consequence"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Folge", context: context) { event, _ in
            guard event.consequences.contains(where: { $0.id.uuidString == args.consequence }) else { throw RPCError.notFound("Diese Folge gibt es nicht.") }
            event.consequences.removeAll { $0.id.uuidString == args.consequence }
        }
    }
}

struct StoriesEventKnowledgeAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.event.knowledge", summary: "Sagt, wer von einem Ereignis weiß: offen, Gerücht oder Geheimnis", kind: .write, security: .localWrite, input: schema(["event": named("Ereignis"), "knowledge": .choice(EventKnowledge.allCases.map(\.rawValue), "Wie bekannt"), "knownBy": .array(of: .string(), "Figuren, die es wissen; ersetzt die bisherigen")], required: ["event", "knowledge"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let known = try args.knownBy.map { try world.actionIDs(.figure, $0) }
        return try changeElement(StoryEvent.self, reference: args.event, world: args.world, label: "Wissen", context: context) { event, _ in
            event.knowledge = args.knowledge.flatMap(EventKnowledge.init(rawValue:)) ?? event.knowledge
            if let known { event.knownByIDs = known }
        }
    }
}

// MARK: Reasons

private let statementFields: [String: JSONSchema] = ["reason": named("Begründung"), "text": .string("Der Satz"), "validity": .choice(ReasonStatement.Validity.allCases.map(\.rawValue), "Standard: open")]

struct StoriesReasonAssumptionAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.reason.assumption.add", summary: "Fügt einer Begründung eine Annahme hinzu", kind: .write, security: .localWrite, input: schema(statementFields, required: ["reason", "text"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var statement = ReasonStatement(text: args.text ?? "")
        statement.validity = args.validity.flatMap(ReasonStatement.Validity.init(rawValue:)) ?? .open
        let made = statement
        _ = try changeElement(StoryReason.self, reference: args.reason, world: args.world, label: "Annahme", context: context) { reason, _ in reason.assumptions.append(made) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct StoriesReasonPremiseAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.reason.premise.add", summary: "Fügt einer Begründung eine Prämisse hinzu", kind: .write, security: .localWrite, input: schema(statementFields, required: ["reason", "text"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var statement = ReasonStatement(text: args.text ?? "")
        statement.validity = args.validity.flatMap(ReasonStatement.Validity.init(rawValue:)) ?? .open
        let made = statement
        _ = try changeElement(StoryReason.self, reference: args.reason, world: args.world, label: "Prämisse", context: context) { reason, _ in reason.premises.append(made) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct StoriesReasonStatementUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.reason.statement.update", summary: "Ändert eine Annahme oder Prämisse", kind: .write, security: .localWrite, input: schema(statementFields.merging(["statement": .string("Satz (ID)")]) { _, new in new }, required: ["reason", "statement"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryReason.self, reference: args.reason, world: args.world, label: "Satz", context: context) { reason, _ in
            func apply(_ list: inout [ReasonStatement]) -> Bool {
                guard let index = list.firstIndex(where: { $0.id.uuidString == args.statement }) else { return false }
                if let text = args.text { list[index].text = text }
                if let validity = args.validity.flatMap(ReasonStatement.Validity.init(rawValue:)) { list[index].validity = validity }
                return true
            }
            guard apply(&reason.assumptions) || apply(&reason.premises) else { throw RPCError.notFound("Diesen Satz gibt es nicht.") }
        }
    }
}

struct StoriesReasonStatementRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.reason.statement.remove", summary: "Entfernt eine Annahme oder Prämisse", kind: .write, security: .localWrite, input: schema(["reason": named("Begründung"), "statement": .string("Satz (ID)")], required: ["reason", "statement"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryReason.self, reference: args.reason, world: args.world, label: "Satz", context: context) { reason, _ in
            let before = reason.assumptions.count + reason.premises.count
            reason.assumptions.removeAll { $0.id.uuidString == args.statement }
            reason.premises.removeAll { $0.id.uuidString == args.statement }
            guard reason.assumptions.count + reason.premises.count < before else { throw RPCError.notFound("Diesen Satz gibt es nicht.") }
        }
    }
}

// MARK: Purposes

struct StoriesPurposeSetupAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.purpose.setup", summary: "Ändert die Teile, in denen etwas angelegt wird", kind: .write, security: .localWrite, input: schema(["purpose": named("Zweck")].merging(addRemove) { _, new in new }, required: ["purpose"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try (args.add ?? []).map { try world.actionPart($0).id }, remove = try (args.remove ?? []).map { try world.actionPart($0).id }
        return try changeElement(StoryPurpose.self, reference: args.purpose, world: args.world, label: "Setup", context: context) { purpose, _ in purpose.setupPartIDs = merged(purpose.setupPartIDs, add: add, remove: remove) }
    }
}

struct StoriesPurposePayoffAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.purpose.payoff", summary: "Ändert die Teile, in denen es eingelöst wird", kind: .write, security: .localWrite, input: schema(["purpose": named("Zweck")].merging(addRemove) { _, new in new }, required: ["purpose"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try (args.add ?? []).map { try world.actionPart($0).id }, remove = try (args.remove ?? []).map { try world.actionPart($0).id }
        return try changeElement(StoryPurpose.self, reference: args.purpose, world: args.world, label: "Payoff", context: context) { purpose, _ in purpose.payoffPartIDs = merged(purpose.payoffPartIDs, add: add, remove: remove) }
    }
}

struct StoriesPurposeOpenPromisesAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.purpose.openPromises", summary: "Listet Versprechen ohne Einlösung: Setups ohne Payoff", kind: .read, security: plainStories, input: schema([:]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        Output(items: try context.app.actionWorld(args.world).purposes.filter(\.isOpenPromise).map(\.info))
    }
}

// MARK: Species and facts

struct StoriesSpeciesHabitatAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.species.habitat", summary: "Ändert, wo eine Spezies lebt", kind: .write, security: .localWrite, input: schema(["species": named("Spezies")].merging(addRemove) { _, new in new }, required: ["species"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let add = try world.actionIDs(.place, args.add), remove = try world.actionIDs(.place, args.remove)
        return try changeElement(StorySpecies.self, reference: args.species, world: args.world, label: "Lebensraum", context: context) { species, _ in species.habitatPlaceIDs = merged(species.habitatPlaceIDs, add: add, remove: remove) }
    }
}

struct StoriesSpeciesMembersAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.species.members", summary: "Listet die Figuren einer Spezies", kind: .read, security: plainStories, input: schema(["species": named("Spezies")], required: ["species"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        return Output(items: world.figures(ofSpecies: try world.actionRef(.species, args.species).id).map(\.info))
    }
}

struct StoriesSpeciesImageAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.species.image.add", summary: "Gibt einer Spezies ein Bild", kind: .write, security: .localWrite, input: schema(imageAdd("species"), required: ["species", "file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let image = try importedImage(args, world: try context.app.actionWorld(args.world), context: context)
        _ = try changeElement(StorySpecies.self, reference: args.species, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(image) }
        return OKOutput(id: image.fileName)
    }
}

struct StoriesSpeciesImageRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.species.image.remove", summary: "Nimmt einer Spezies ein Bild", kind: .write, security: .localWrite, input: schema(imageRemove("species"), required: ["species"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StorySpecies.self, reference: args.species, world: args.world, label: "Bild", context: context) { element, _ in element.images.remove(at: try imageIndex(element.images, args.file)) }
    }
}

struct StoriesFactTagAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.tag", summary: "Gibt einem Fakt Schlagworte oder nimmt sie weg", kind: .write, security: .localWrite, input: schema(["fact": named("Fakt")].merging(addRemove) { _, new in new }, required: ["fact"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFact.self, reference: args.fact, world: args.world, label: "Schlagworte", context: context) { fact, _ in
            for tag in (args.add ?? []).map(StoryFact.normalizedTag) where !tag.isEmpty && !fact.tags.contains(tag) { fact.tags.append(tag) }
            let gone = (args.remove ?? []).map(StoryFact.normalizedTag)
            fact.tags.removeAll { gone.contains($0) }
        }
    }
}

struct StoriesFactLinkAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.link", summary: "Verknüpft einen Fakt mit einem Element", kind: .write, security: .localWrite, input: schema(["fact": named("Fakt"), "element": elementSchema], required: ["fact", "element"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let ref = try context.app.actionWorld(args.world).actionElement(args.element ?? "")
        return try changeElement(StoryFact.self, reference: args.fact, world: args.world, label: "Fakt verknüpfen", context: context) { fact, _ in
            if !fact.links.contains(ref) { fact.links.append(ref) }
        }
    }
}

struct StoriesFactUnlinkAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.unlink", summary: "Löst die Verknüpfung eines Fakts", kind: .write, security: .localWrite, input: schema(["fact": named("Fakt"), "element": elementSchema], required: ["fact", "element"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let ref = try context.app.actionWorld(args.world).actionElement(args.element ?? "")
        return try changeElement(StoryFact.self, reference: args.fact, world: args.world, label: "Fakt lösen", context: context) { fact, _ in fact.links.removeAll { $0 == ref } }
    }
}

struct StoriesFactImageAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.image.add", summary: "Gibt einem Fakt ein Bild", kind: .write, security: .localWrite, input: schema(imageAdd("fact"), required: ["fact", "file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let image = try importedImage(args, world: try context.app.actionWorld(args.world), context: context)
        _ = try changeElement(StoryFact.self, reference: args.fact, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(image) }
        return OKOutput(id: image.fileName)
    }
}

struct StoriesFactImageRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.image.remove", summary: "Nimmt einem Fakt ein Bild", kind: .write, security: .localWrite, input: schema(imageRemove("fact"), required: ["fact"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeElement(StoryFact.self, reference: args.fact, world: args.world, label: "Bild", context: context) { element, _ in element.images.remove(at: try imageIndex(element.images, args.file)) }
    }
}

struct StoriesFactFilterAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = StoriesListOutput
    static let descriptor = ActionDescriptor(id: "stories.fact.filter", summary: "Filtert Fakten nach Schlagworten und Text; ein Fakt muss alle Schlagworte haben", kind: .read, security: plainStories, input: schema(["tags": .array(of: .string(), "Schlagworte"), "query": .string("Suchtext")]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let tags = (args.tags ?? []).map(StoryFact.normalizedTag)
        return Output(items: world.facts.filter { fact in
            tags.allSatisfy { tag in fact.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                && (args.query.map { fact.name.localizedStandardContains($0) || fact.text.localizedStandardContains($0) } ?? true)
        }.map(\.info))
    }
}

// MARK: Timelines

struct StoriesTimelineReadAction: LLMDAction {
    typealias Args = StoriesArgs
    struct Entry: Encodable, Sendable {
        var entry: String
        var element: String
        var name: String
        var start: Double
        var end: Double?
        var note: String
    }
    struct Output: Encodable, Sendable {
        var title: String
        var unit: String
        var suffix: String
        var entries: [Entry]
    }
    static let descriptor = ActionDescriptor(id: "stories.timeline.read", summary: "Liest eine Zeitleiste", kind: .read, security: plainStories, input: schema(ownerSchema), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let owner = try world.resolvedOwner(args.part)
        let scale = world.scale(of: owner)
        return Output(title: world.title(of: owner), unit: scale.unit, suffix: scale.suffix, entries: (world.timeline(of: owner)?.entries ?? []).map {
            Entry(entry: $0.id.uuidString, element: "\($0.ref.kind.rawValue):\($0.ref.id.uuidString)", name: world.label($0.ref), start: $0.start, end: $0.end, note: $0.note)
        })
    }
}

struct StoriesTimelinePinAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.timeline.pin", summary: "Setzt ein Element auf eine Zeitleiste, als Punkt oder Spanne", kind: .write, security: .localWrite, input: schema(ownerSchema.merging(["element": elementSchema, "start": .number("Beginn"), "end": .number("Ende"), "note": .string("Notiz")]) { _, new in new }, required: ["element", "start"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let owner = try world.resolvedOwner(args.part)
        let entry = TimelineEntry(ref: try world.actionElement(args.element ?? ""), start: args.start ?? 0, end: args.end, note: args.note ?? "")
        try context.changeWorld(world.id, label: "Zeitleiste") { $0.updateTimeline(owner) { $0.entries.append(entry) } }
        return OKOutput(id: entry.id.uuidString)
    }
}

struct StoriesTimelineUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.timeline.update", summary: "Ändert einen Eintrag einer Zeitleiste", kind: .write, security: .localWrite, input: schema(ownerSchema.merging(["entry": .string("Eintrag (ID)"), "start": .number("Beginn"), "end": .number("Ende"), "note": .string("Notiz")]) { _, new in new }, required: ["entry"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let owner = try world.resolvedOwner(args.part)
        guard world.timeline(of: owner)?.entries.contains(where: { $0.id.uuidString == args.entry }) == true else { throw RPCError.notFound("Diesen Eintrag gibt es auf dieser Zeitleiste nicht.") }
        try context.changeWorld(world.id, label: "Zeitleiste") { world in
            world.updateTimeline(owner) { timeline in
                guard let index = timeline.entries.firstIndex(where: { $0.id.uuidString == args.entry }) else { return }
                if let start = args.start { timeline.entries[index].start = start }
                if let end = args.end { timeline.entries[index].end = end }
                if let note = args.note { timeline.entries[index].note = note }
            }
        }
        return OKOutput(id: args.entry)
    }
}

struct StoriesTimelineUnpinAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.timeline.unpin", summary: "Nimmt einen Eintrag von einer Zeitleiste", kind: .write, security: .localWrite, input: schema(ownerSchema.merging(["entry": .string("Eintrag (ID)")]) { _, new in new }, required: ["entry"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let owner = try world.resolvedOwner(args.part)
        guard world.timeline(of: owner)?.entries.contains(where: { $0.id.uuidString == args.entry }) == true else { throw RPCError.notFound("Diesen Eintrag gibt es auf dieser Zeitleiste nicht.") }
        try context.changeWorld(world.id, label: "Zeitleiste") { $0.updateTimeline(owner) { $0.entries.removeAll { $0.id.uuidString == args.entry } } }
        return OKOutput(id: args.entry)
    }
}

struct StoriesTimelineScaleAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.timeline.scale", summary: "Gibt einer Zeitleiste eine eigene Zeiteinheit", kind: .write, security: .localWrite, input: schema(ownerSchema.merging(["unit": .string("Zeiteinheit"), "suffix": .string("Nachsatz")]) { _, new in new }, required: ["unit"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let owner = try world.resolvedOwner(args.part)
        let scale = TimelineScale(unit: args.unit ?? "Jahr", suffix: args.suffix ?? "")
        try context.changeWorld(world.id, label: "Zeitleiste") { world in
            if case .world = owner { world.calendar = scale } else { world.updateTimeline(owner) { $0.scale = scale } }
        }
        return OKOutput()
    }
}

// MARK: Galleries

@MainActor
private func changeGallery(_ args: StoriesArgs, context: ActionContext, _ change: (inout [StoryImage]) throws -> Void) throws {
    let world = try context.app.actionWorld(args.world)
    let part = try args.part.map { try world.actionPart($0).id }
    var failure: Error?
    try context.changeWorld(world.id, label: "Galerie") { world in
        if let part {
            world.updatePart(part) { part in
                do { try change(&part.gallery) } catch { failure = error }
            }
        } else {
            try change(&world.gallery)
        }
    }
    if let failure { throw failure }
}

private let galleryOwner: [String: JSONSchema] = ["part": .string("Teil; ohne Angabe die Galerie der Welt")]

struct StoriesGalleryAddAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.gallery.add", summary: "Legt ein Bild in eine Galerie", kind: .write, security: .localWrite, input: schema(galleryOwner.merging(["file": .string("Pfad der Bilddatei"), "caption": .string("Bildunterschrift")]) { _, new in new }, required: ["file"]), output: .freeObject())
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { mediaPreflight(args.file, channel: context.channel) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let image = try importedImage(args, world: try context.app.actionWorld(args.world), context: context)
        try changeGallery(args, context: context) { $0.append(image) }
        return OKOutput(id: image.fileName)
    }
}

struct StoriesGalleryUpdateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.gallery.update", summary: "Ändert die Unterschrift eines Galeriebilds", kind: .write, security: .localWrite, input: schema(galleryOwner.merging(["file": imageNameSchema, "caption": .string("Bildunterschrift")]) { _, new in new }, required: ["caption"]), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeGallery(args, context: context) { gallery in gallery[try imageIndex(gallery, args.file)].caption = args.caption ?? "" }
        return OKOutput()
    }
}

struct StoriesGalleryRemoveAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(id: "stories.gallery.remove", summary: "Nimmt ein Bild aus einer Galerie", kind: .write, security: .localWrite, input: schema(galleryOwner.merging(["file": imageNameSchema]) { _, new in new }), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeGallery(args, context: context) { gallery in gallery.remove(at: try imageIndex(gallery, args.file)) }
        return OKOutput()
    }
}

struct StoriesGalleryListAction: LLMDAction {
    typealias Args = StoriesArgs
    struct Item: Encodable, Sendable {
        var file: String
        var caption: String
    }
    struct Output: Encodable, Sendable {
        var images: [Item]
    }
    static let descriptor = ActionDescriptor(id: "stories.gallery.list", summary: "Listet die Bilder einer Galerie, bei einem Teil samt Unterteilen", kind: .read, security: plainStories, input: schema(galleryOwner), output: .freeObject())
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let world = try context.app.actionWorld(args.world)
        let images = try args.part.map { world.galleryImages(within: try world.actionPart($0).id) } ?? world.gallery
        return Output(images: images.map { Item(file: $0.fileName, caption: $0.caption) })
    }
}

// MARK: Pictures from Draw Things

struct StoriesImageGenerateAction: LLMDAction {
    typealias Args = StoriesArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.image.generate", summary: "Lässt Draw Things ein Bild machen und gibt es einem Element oder einer Galerie; wartet, bis es da ist", kind: .write, security: .localWrite,
        input: schema([
            "element": .string("Figur, Ort, Spezies oder Fakt als art:name; ohne Angabe die Galerie"),
            "part": .string("Galerie dieses Teils; ohne Angabe die der Welt"),
            "prompt": .string("Englischer Prompt"), "caption": .string("Bildunterschrift"),
        ], required: ["prompt"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let world = try app.actionWorld(args.world)
        let prompt = (args.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        let target = try args.element.map { try world.actionElement($0) }
        if let target, ![.figure, .place, .species, .fact].contains(target.kind) { throw RPCError.invalidTarget("\(target.kind.title) haben keine Bilder.") }
        let center = app.imageGeneration
        var info = center.defaults
        info.prompt = prompt
        info.seed = nil
        let source = WriterImageStore.newGeneratedSource()
        center.generate(source: source, info: info)
        // The picture comes in the background, one after the other; a world has no placeholder for it, so this waits.
        while let phase = center.phase(for: source) {
            if case .failed(let message) = phase { center.cancel(source); throw RPCError.unavailable(message) }
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let url = WriterImageStore.url(for: source) else { throw RPCError.unavailable("Draw Things hat kein Bild geliefert.") }
        guard var image = app.stories.importImages([url], into: world.id).first else { throw RPCError.internal("Das Bild ließ sich nicht übernehmen.") }
        image.caption = args.caption ?? ""
        let made = image
        if let target {
            let name = target.id.uuidString
            switch target.kind {
            case .figure: _ = try changeElement(StoryFigure.self, reference: name, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(made) }
            case .place: _ = try changeElement(StoryPlace.self, reference: name, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(made) }
            case .species: _ = try changeElement(StorySpecies.self, reference: name, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(made) }
            default: _ = try changeElement(StoryFact.self, reference: name, world: args.world, label: "Bild", context: context) { element, _ in element.images.append(made) }
            }
        } else {
            try changeGallery(args, context: context) { $0.append(made) }
        }
        return OKOutput(id: made.fileName)
    }
}

// MARK: Studio

struct StoriesStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var world: String?
        var element: String?
        var part: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.studio.open", summary: "Öffnet das Stories Studio, wenn gewünscht bei einer Welt, einem Teil oder Element", kind: .read, security: .plainRead,
        input: .object(["world": .string("Romanwelt (ID oder Titel)"), "element": elementSchema, "part": partSchema]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        if args.world == nil, args.element != nil || args.part != nil { throw RPCError.invalidParams("Für element oder part bitte auch world angeben.") }
        if let name = args.world {
            let world = try app.actionWorld(name)
            let ref = try args.element.map { try world.actionElement($0) }
            let part = try args.part.map { try world.actionPart($0).id }
            app.storiesStudioCommand = StoriesStudioCommand(world: world.id, element: ref, part: part)
        }
        app.openStoriesStudio()
        return OKOutput()
    }
}

struct StoriesStudioCloseAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.studio.close", summary: "Schließt das Stories Studio", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.closeStoriesStudio()
        return OKOutput()
    }
}
