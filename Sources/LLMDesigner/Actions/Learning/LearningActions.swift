import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerLearningActions() {
        register(LearningOverviewAction.self)
        register(LearningDisciplineCreateAction.self)
        register(LearningDisciplineUpdateAction.self)
        register(LearningDisciplineDeleteAction.self)
        register(LearningCourseListAction.self)
        register(LearningCourseCreateAction.self)
        register(LearningCourseReadAction.self)
        register(LearningCourseUpdateAction.self)
        register(LearningCourseDeleteAction.self)
        register(LearningCardAddAction.self)
        register(LearningCardAddManyAction.self)
        register(LearningCardUpdateAction.self)
        register(LearningCardDeleteAction.self)
        register(LearningDueAction.self)
        register(LearningReviewAction.self)
        register(LearningStatsAction.self)
        register(LearningPauseAction.self)
        register(LearningResumeAction.self)
        register(LearningSettingsAction.self)
        register(LearningMaterialAddAction.self)
        register(LearningLinkAddAction.self)
        register(LearningAICardsAction.self)
        register(LearningAISheetAction.self)
        register(LearningStudioOpenAction.self)
        register(LearningStudioCloseAction.self)
    }
}

/// Cards and material can be written by agents and come from PDFs: reading a course counts as foreign, like notes.
let learningRead = ActionSecurity.foreignRead
let courseProperty: JSONSchema = .string("Kurs (ID oder Name)")
let disciplineProperty: JSONSchema = .string("Disziplin (ID oder Name)")

extension AppModel {
    func actionCourse(_ reference: String) throws -> LearningCourse {
        learning.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let course = learning.course(id) else { throw RPCError.notFound("Kurs \(reference) gibt es nicht.") }
            return course
        }
        let found = learning.courses.records.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let partial = learning.courses.records.filter { $0.displayName.localizedCaseInsensitiveContains(reference) }
        if found.isEmpty, partial.count == 1 { return partial[0] }
        if found.isEmpty, partial.isEmpty { throw RPCError.notFound("Kurs „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Kurse passen zu „\(reference)“. Bitte die ID verwenden.", candidates: (found.isEmpty ? partial : found).map(\.id.uuidString))
    }

    func actionDiscipline(_ reference: String) throws -> LearningDiscipline {
        learning.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let found = learning.discipline(id) { return found }
        let found = learning.state.disciplines.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Disziplin „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Disziplinen heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }
}

extension LearningCourse {
    func actionCard(_ reference: String) throws -> LearningCard {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let card = card(id) { return card }
        if let number = Int(reference), number >= 1, number <= cards.count { return cards[number - 1] }
        let found = cards.filter { $0.front.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        throw RPCError.notFound("Karte „\(reference)“ gibt es in „\(displayName)“ nicht.")
    }
}

extension ActionContext {
    @discardableResult
    func changeCourse(_ id: UUID, label: String, _ change: (inout LearningCourse) throws -> Void) throws -> LearningCourse {
        let library = app.learning.courses
        guard let before = library.record(id) else { throw RPCError.notFound("Den Kurs gibt es nicht mehr.") }
        var course = before
        try change(&course)
        let wanted = course
        library.update(id) { $0 = wanted }
        let after = library.record(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.restore(before) }, redo: { [weak library] in library?.restore(after) }))
        registry.eventSink?(ActionEvent(kind: "learning.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
        return after
    }
}

// MARK: - Output

struct CourseStatsOutput: Encodable, Sendable {
    var total: Int
    var new: Int
    var learning: Int
    var young: Int
    var mature: Int
    var dueNow: Int
    var reviewsToday: Int
    var retention: Int?
    var progress: Int
    var quizScore: Int?

    init(_ stats: CourseStats) {
        total = stats.total
        new = stats.new
        learning = stats.learning
        young = stats.young
        mature = stats.mature
        dueNow = stats.dueNow
        reviewsToday = stats.reviewsToday
        retention = stats.retention.map { Int(($0 * 100).rounded()) }
        progress = Int((stats.progress * 100).rounded())
        quizScore = stats.quizScore.map { Int(($0 * 100).rounded()) }
    }
}

struct CourseSummaryOutput: Encodable, Sendable {
    var id: String
    var name: String
    var discipline: String?
    var stats: CourseStatsOutput
    var exam: String?
    var finished: Bool
    var paused: Bool
}

struct CardOutput: Encodable, Sendable {
    var id: String
    var number: Int
    var front: String
    var back: String?
    var state: String
    var due: String
    var lapses: Int
    var suspended: Bool?
}

extension AppModel {
    func actionCourseSummary(_ course: LearningCourse) -> CourseSummaryOutput {
        CourseSummaryOutput(id: course.id.uuidString, name: course.displayName, discipline: learning.discipline(course.discipline)?.displayName,
                            stats: CourseStatsOutput(learning.stats(course.id)), exam: course.examDate.map(ProjectDay.string), finished: course.finished,
                            paused: learning.activePause(for: course) != nil)
    }
}

extension LearningCourse {
    func actionCards(withBack: Bool = true) -> [CardOutput] {
        cards.enumerated().map { index, card in
            CardOutput(id: card.id.uuidString, number: index + 1, front: card.front, back: withBack ? card.back : nil, state: card.state.rawValue,
                       due: card.state == .new ? "neu" : card.due.formatted(.iso8601), lapses: card.lapses, suspended: card.suspended ? true : nil)
        }
    }
}

// MARK: - Overview and disciplines

struct LearningOverviewAction: LLMDAction {
    struct Discipline: Encodable, Sendable {
        var id: String
        var name: String
        var tree: String
        var growth: Int
        var courses: [CourseSummaryOutput]
    }
    struct Output: Encodable, Sendable {
        var streak: Int
        var dueNow: Int
        var disciplines: [Discipline]
        var withoutDiscipline: [CourseSummaryOutput]
        var pauses: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "learning.overview", summary: "Lernfortschritt im Überblick: Disziplinen mit Wachstum ihres Baums, Kurse mit fälligen und gelernten Karten, Tage in Folge, Pausen",
        kind: .read, security: learningRead, output: .freeObject(), example: "llmd learning overview", groups: ["learning.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        let library = app.learning
        library.loadIfNeeded()
        let disciplines = library.state.disciplines.map { discipline in
            Discipline(id: discipline.id.uuidString, name: discipline.displayName, tree: discipline.tree.rawValue,
                       growth: Int((library.growth(of: discipline.id).stage * 100).rounded()),
                       courses: library.courses(in: discipline.id).map { app.actionCourseSummary($0) })
        }
        let due = library.courses.records.reduce(0) { $0 + library.queue($1.id).count }
        let pauses = library.activePauses.map { "seit \(ProjectDay.string($0.start))" + ($0.end.map { " bis \(ProjectDay.string($0))" } ?? "") + ($0.reason.isEmpty ? "" : " (\($0.reason))") }
        return Output(streak: library.streak(), dueNow: due, disciplines: disciplines,
                      withoutDiscipline: library.courses(in: nil).map { app.actionCourseSummary($0) }, pauses: pauses)
    }
}

struct LearningDisciplineCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var tree: String?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.discipline.create", summary: "Legt eine Disziplin an (ein Baum im Garten), z. B. Psychologie", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "tree": .choice(TreeKind.allCases.map(\.rawValue), "Baumart"), "color": ProjectArgs.colorSchema], required: ["name"]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let tree = try ProjectArgs.choice(args.tree, TreeKind.allCases, raw: \.rawValue, "Baum")
        let color = try ProjectArgs.color(args.color) ?? nil
        let made = app.newDiscipline(name: args.name, tree: tree, color: color)
        let library = app.learning
        context.undoGroup.add(UndoStep(label: "Disziplin anlegen", undo: { [weak library] in library?.changeState { $0.disciplines.removeAll { $0.id == made.id } } },
                                       redo: { [weak library] in library?.changeState { $0.disciplines.append(made) } }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct LearningDisciplineUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var discipline: String
        var name: String?
        var tree: String?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.discipline.update", summary: "Ändert Name, Baumart oder Farbe einer Disziplin", kind: .write, security: .localWrite,
        input: .object(["discipline": disciplineProperty, "name": .string("Name"), "tree": .choice(TreeKind.allCases.map(\.rawValue), "Baumart"), "color": ProjectArgs.colorSchema],
                       required: ["discipline"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let discipline = try app.actionDiscipline(args.discipline)
        let tree = try ProjectArgs.choice(args.tree, TreeKind.allCases, raw: \.rawValue, "Baum")
        let color = try ProjectArgs.color(args.color)
        let before = app.learning.state
        app.learning.changeState { state in
            guard let index = state.disciplines.firstIndex(where: { $0.id == discipline.id }) else { return }
            if let name = args.name { state.disciplines[index].name = name }
            if let tree { state.disciplines[index].tree = tree }
            if let color, let color { state.disciplines[index].color = color }
        }
        let library = app.learning
        context.undoGroup.add(UndoStep(label: "Disziplin ändern", undo: { [weak library] in library?.changeState { $0 = before } }, redo: {}))
        return OKOutput(id: discipline.id.uuidString)
    }
}

struct LearningDisciplineDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var discipline: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.discipline.delete", summary: "Entfernt eine Disziplin; ihre Kurse bleiben ohne Disziplin erhalten", kind: .destructive, security: .destructive,
        input: .object(["discipline": disciplineProperty], required: ["discipline"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let discipline = try app.actionDiscipline(args.discipline)
        let members = app.learning.courses(in: discipline.id).map(\.id)
        app.deleteDiscipline(discipline.id)
        let library = app.learning
        context.undoGroup.add(UndoStep(label: "Disziplin entfernen", undo: { [weak library] in
            library?.changeState { $0.disciplines.append(discipline) }
            for id in members { library?.courses.update(id) { $0.discipline = discipline.id } }
        }, redo: {}))
        return OKOutput(id: discipline.id.uuidString)
    }
}

// MARK: - Courses

struct LearningCourseListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var discipline: String?
        var query: String?
    }
    struct Output: Encodable, Sendable {
        var courses: [CourseSummaryOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "learning.course.list", summary: "Listet Kurse mit Karten, Fälligen, Fortschritt und Prüfungstermin", kind: .read, security: learningRead,
        input: .object(["discipline": disciplineProperty, "query": .string("Suche in Namen, Karten und Material")]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.learning.loadIfNeeded()
        let discipline = try args.discipline.map { try app.actionDiscipline($0).id }
        let shown = app.learning.courses.records.filter { (discipline == nil || $0.discipline == discipline) && $0.matches(args.query ?? "") }
        return Output(courses: shown.map { app.actionCourseSummary($0) })
    }
}

struct LearningCourseCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var discipline: String?
        var summary: String?
        var exam: String?
        var open: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.course.create", summary: "Legt einen Kurs an, auf Wunsch in einer Disziplin (die es noch nicht gibt, entsteht) und mit Prüfungstermin",
        kind: .write, security: .localWrite,
        input: .object(["name": .string("Name, z. B. Statistik 2"), "discipline": disciplineProperty, "summary": .string("Worum es geht"),
                        "exam": .string("Prüfungstermin wie 2026-12-15"), "open": .boolean("Gleich öffnen")], required: ["name"]),
        output: .freeObject(), example: "llmd learning course create --name \"Statistik 2\" --discipline Psychologie --exam 2027-02-10", groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        app.learning.loadIfNeeded()
        var disciplineID: UUID?
        if let reference = args.discipline {
            disciplineID = (try? app.actionDiscipline(reference))?.id ?? app.newDiscipline(name: reference).id
        }
        let exam = try ProjectArgs.day(args.exam, "exam") ?? nil
        var made = app.newCourse(name: args.name, in: disciplineID)
        made = try context.changeCourse(made.id, label: "Kurs anlegen") { course in
            if let summary = args.summary { course.summary = summary }
            course.examDate = exam
        }
        let library = app.learning.courses
        let id = made.id
        context.undoGroup.add(UndoStep(label: "Kurs anlegen", undo: { [weak library] in library?.remove(id) }, redo: {}))
        if args.open == true { app.openLearningStudio(LearningStudioCommand(course: made.id)) }
        return OKOutput(id: made.id.uuidString)
    }
}

struct LearningCourseReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var cards: Bool?
    }
    struct Material: Encodable, Sendable {
        var id: String
        var kind: String
        var title: String
        var url: String?
    }
    struct Output: Encodable, Sendable {
        var course: CourseSummaryOutput
        var summary: String
        var materials: [Material]
        var links: [ProjectRefOutput]
        var projects: [String]
        var cards: [CardOutput]?
        var quizzes: Int
    }
    static let descriptor = ActionDescriptor(
        id: "learning.course.read", summary: "Liest einen Kurs: Statistik, Material, Verknüpfungen und (mit cards) die Karten", kind: .read, security: learningRead,
        input: .object(["course": courseProperty, "cards": .boolean("Karten mitliefern")], required: ["course"]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let course = try app.actionCourse(args.course)
        return Output(course: app.actionCourseSummary(course), summary: course.summary,
                      materials: course.materials.map { Material(id: $0.id.uuidString, kind: $0.kind.rawValue, title: $0.displayTitle, url: $0.url) },
                      links: course.links.map { app.actionRefOutput($0) }, projects: course.projects.compactMap { app.projects.project($0)?.displayTitle },
                      cards: args.cards == true ? course.actionCards() : nil, quizzes: course.quizzes.count)
    }
}

struct LearningCourseUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var name: String?
        var summary: String?
        var discipline: String?
        var exam: String?
        var finished: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.course.update", summary: "Ändert Name, Beschreibung, Disziplin, Prüfungstermin oder Abschluss eines Kurses", kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "name": .string("Name"), "summary": .string("Beschreibung"), "discipline": disciplineProperty,
                        "exam": .string("Prüfungstermin wie 2026-12-15, leer entfernt ihn"), "finished": .boolean("Abgeschlossen")], required: ["course"]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let discipline = try args.discipline.map { try app.actionDiscipline($0).id }
        let exam = try ProjectArgs.day(args.exam, "exam")
        try context.changeCourse(course.id, label: "Kurs ändern") { course in
            if let name = args.name { course.name = name }
            if let summary = args.summary { course.summary = summary }
            if let discipline { course.discipline = discipline }
            if let exam { course.examDate = exam }
            if let finished = args.finished { course.finished = finished }
        }
        return OKOutput(id: course.id.uuidString)
    }
}

struct LearningCourseDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.course.delete", summary: "Legt einen Kurs mit Karten und Material in den Papierkorb", kind: .destructive, security: .destructive,
        input: .object(["course": courseProperty], required: ["course"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let course = try context.app.actionCourse(args.course)
        return ActionPreflight(target: course.displayName, detail: "\(course.cards.count) Karten, \(course.materials.count) Material")
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let library = context.app.learning.courses
        library.remove(course.id)
        context.undoGroup.add(UndoStep(label: "Kurs löschen", undo: { [weak library] in library?.restore(course) }, redo: { [weak library] in library?.remove(course.id) }))
        return OKOutput(id: course.id.uuidString)
    }
}

// MARK: - Cards

struct LearningCardAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var front: String
        var back: String
        var tags: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.card.add", summary: "Legt eine Karteikarte an (Vorderseite: Frage, Rückseite: Antwort)", kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "front": .string("Frage"), "back": .string("Antwort"), "tags": .array(of: .string(), "Schlagwörter")],
                       required: ["course", "front", "back"]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        guard !args.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError.invalidParams("front ist leer.") }
        let card = LearningCard(front: args.front, back: args.back, tags: args.tags ?? [])
        try context.changeCourse(course.id, label: "Karte anlegen") { $0.cards.append(card) }
        return OKOutput(id: card.id.uuidString)
    }
}

struct LearningCardAddManyAction: LLMDAction {
    struct Pair: Decodable, Sendable {
        var front: String
        var back: String
    }
    struct Args: Decodable, Sendable {
        var course: String
        var cards: [Pair]?
        var text: String?
    }
    struct Output: Encodable, Sendable {
        var added: Int
    }
    static let descriptor = ActionDescriptor(
        id: "learning.card.addMany", summary: "Legt viele Karten an: als Liste {front, back} oder als Text mit einer Karte je Zeile (Frage ; Antwort)",
        kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "cards": .array(of: .object(["front": .string(), "back": .string()], required: ["front", "back"]), "Karten"),
                        "text": .string("Eine Karte je Zeile: Frage ; Antwort")], required: ["course"]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let course = try context.app.actionCourse(args.course)
        var cards = (args.cards ?? []).filter { !$0.front.isEmpty }.map { LearningCard(front: $0.front, back: $0.back) }
        cards += LearningCardText.parse(args.text ?? "").map { LearningCard(front: $0.front, back: $0.back) }
        guard !cards.isEmpty else { throw RPCError.invalidParams("Keine Karten: cards oder text angeben.") }
        try context.changeCourse(course.id, label: "Karten anlegen") { $0.cards += cards }
        return Output(added: cards.count)
    }
}

struct LearningCardUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var card: String
        var front: String?
        var back: String?
        var suspended: Bool?
        var reset: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.card.update", summary: "Ändert eine Karte, stellt sie zurück (suspended) oder setzt ihren Lernstand zurück (reset)", kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "card": .string("Karte (ID, Nummer oder Vorderseite)"), "front": .string(), "back": .string(),
                        "suspended": .boolean("Zurückstellen"), "reset": .boolean("Als neu lernen")], required: ["course", "card"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let card = try course.actionCard(args.card)
        try context.changeCourse(course.id, label: "Karte ändern") { course in
            course.updateCard(card.id) { card in
                if args.reset == true { card = LearningCard(front: card.front, back: card.back, tags: card.tags, material: card.material).with(id: card.id) }
                if let front = args.front { card.front = front }
                if let back = args.back { card.back = back }
                if let suspended = args.suspended { card.suspended = suspended }
            }
        }
        return OKOutput(id: card.id.uuidString)
    }
}

struct LearningCardDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var card: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.card.delete", summary: "Löscht eine Karte mit ihrem Lernverlauf", kind: .destructive, security: .destructive,
        input: .object(["course": courseProperty, "card": .string("Karte (ID, Nummer oder Vorderseite)")], required: ["course", "card"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let card = try course.actionCard(args.card)
        try context.changeCourse(course.id, label: "Karte löschen") { $0.cards.removeAll { $0.id == card.id } }
        return OKOutput(id: card.id.uuidString)
    }
}

struct LearningDueAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String?
        var limit: Int?
        var answers: Bool?
    }
    struct Item: Encodable, Sendable {
        var course: String
        var courseID: String
        var card: CardOutput
    }
    struct Output: Encodable, Sendable {
        var due: [Item]
        var total: Int
    }
    static let descriptor = ActionDescriptor(
        id: "learning.due", summary: "Was jetzt zu lernen ist (in Reihenfolge); ohne answers nur die Vorderseiten, so kann der Chat abfragen und dann mit learning.review bewerten",
        kind: .read, security: learningRead,
        input: .object(["course": courseProperty, "limit": .integer("Höchstens so viele (Vorgabe 10)", minimum: 1, maximum: 200), "answers": .boolean("Rückseiten mitliefern")]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.learning.loadIfNeeded()
        let courses = try args.course.map { [try app.actionCourse($0)] } ?? app.learning.courses.records
        var items: [Item] = []
        var total = 0
        for course in courses {
            let queue = app.learning.queue(course.id)
            total += queue.count
            let numbers = Dictionary(uniqueKeysWithValues: course.cards.enumerated().map { ($1.id, $0 + 1) })
            for card in queue {
                items.append(Item(course: course.displayName, courseID: course.id.uuidString,
                                  card: CardOutput(id: card.id.uuidString, number: numbers[card.id] ?? 0, front: card.front, back: args.answers == true ? card.back : nil,
                                                   state: card.state.rawValue, due: card.due.formatted(.iso8601), lapses: card.lapses)))
            }
        }
        return Output(due: Array(items.prefix(args.limit ?? 10)), total: total)
    }
}

struct LearningReviewAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var card: String
        var rating: String
    }
    struct Output: Encodable, Sendable {
        var card: String
        var next: String
        var nextIn: String
        var state: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.review", summary: "Bewertet die Antwort auf eine Karte (nochmal, schwer, gut, leicht oder 1–4) und plant sie neu",
        kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "card": .string("Karte (ID oder Nummer)"), "rating": .choice(["nochmal", "schwer", "gut", "leicht", "1", "2", "3", "4"], "Bewertung")],
                       required: ["course", "card", "rating"]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let card = try course.actionCard(args.card)
        guard let rating = CardRating.parse(args.rating) else { throw RPCError.invalidParams("rating: nochmal, schwer, gut oder leicht.") }
        let before = course
        guard let next = app.learning.answer(card.id, in: course.id, rating) else { throw RPCError.notFound("Die Karte gibt es nicht mehr.") }
        let library = app.learning.courses
        context.undoGroup.add(UndoStep(label: "Karte bewerten", undo: { [weak library] in library?.restore(before) }, redo: {}))
        return Output(card: card.id.uuidString, next: next.due.formatted(.iso8601), nextIn: LearningScheduler.label(next.due.timeIntervalSinceNow), state: next.state.rawValue)
    }
}

struct LearningStatsAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
    }
    struct Output: Encodable, Sendable {
        var stats: CourseStatsOutput
        var history: [Int]
        var forecast: [Int]
    }
    static let descriptor = ActionDescriptor(
        id: "learning.stats", summary: "Statistik eines Kurses: Karten je Stand, Behaltensrate, Antworten der letzten 30 Tage, Fälligkeiten der nächsten 14",
        kind: .read, security: learningRead, input: .object(["course": courseProperty], required: ["course"]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let course = try context.app.actionCourse(args.course)
        let stats = context.app.learning.stats(course.id)
        return Output(stats: CourseStatsOutput(stats), history: stats.history, forecast: stats.forecast)
    }
}

struct LearningPauseAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String?
        var discipline: String?
        var from: String?
        var until: String?
        var reason: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.pause", summary: "Plant eine Lernpause (Urlaub) für alles, eine Disziplin oder einen Kurs; danach rücken die Karten um die Pausenlänge weiter",
        kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "discipline": disciplineProperty, "from": .string("Beginn wie 2026-12-20 (Vorgabe jetzt)"),
                        "until": .string("Ende wie 2027-01-06 (ohne: bis learning.resume)"), "reason": .string("Grund")]),
        output: .freeObject(), example: "llmd learning pause --until 2026-12-28 --reason Urlaub", groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        app.learning.loadIfNeeded()
        let scope: LearningPause.Scope
        if let course = args.course { scope = .course(try app.actionCourse(course).id) }
        else if let discipline = args.discipline { scope = .discipline(try app.actionDiscipline(discipline).id) }
        else { scope = .all }
        let from = (try ProjectArgs.day(args.from, "from") ?? nil) ?? Date()
        let until = try ProjectArgs.day(args.until, "until") ?? nil
        if let until, until <= from { throw RPCError.invalidParams("until muss nach from liegen.") }
        let pause = app.learning.startPause(scope: scope, start: from, end: until.map { $0.addingTimeInterval(LearningScheduler.day) }, reason: args.reason ?? "")
        let library = app.learning
        context.undoGroup.add(UndoStep(label: "Lernpause", undo: { [weak library] in library?.changeState { $0.pauses.removeAll { $0.id == pause.id } } }, redo: {}))
        return OKOutput(id: pause.id.uuidString)
    }
}

struct LearningResumeAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "learning.resume", summary: "Beendet alle laufenden Lernpausen jetzt; die Karten rücken um die Pausenlänge weiter", kind: .write, security: .localWrite,
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        let library = context.app.learning
        library.loadIfNeeded()
        let active = library.activePauses
        for pause in active { library.endPause(pause.id) }
        return OKOutput(message: active.isEmpty ? "Es lief keine Pause." : "\(active.count) Pause(n) beendet.")
    }
}

struct LearningSettingsAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var algorithm: String?
        var retention: Double?
        var newPerDay: Int?
        var reviewsPerDay: Int?
        var maxInterval: Double?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.settings", summary: "Zeigt oder ändert den Lernalgorithmus (fsrs, sm2), die Behaltensrate und die Tagesgrenzen", kind: .write, security: .localWrite,
        input: .object(["algorithm": .choice(LearningSettings.Algorithm.allCases.map(\.rawValue), "Algorithmus"), "retention": .number("Behaltensrate", minimum: 0.7, maximum: 0.99),
                        "newPerDay": .integer("Neue Karten pro Tag und Kurs", minimum: 0, maximum: 500), "reviewsPerDay": .integer("Wiederholungen pro Tag", minimum: 1, maximum: 5_000),
                        "maxInterval": .number("Längstes Intervall in Tagen", minimum: 1, maximum: 36_500)]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> LearningSettings {
        let library = context.app.learning
        library.loadIfNeeded()
        let algorithm = try ProjectArgs.choice(args.algorithm, LearningSettings.Algorithm.allCases, raw: \.rawValue, "Algorithmus")
        let before = library.state
        library.changeState { state in
            if let algorithm { state.settings.algorithm = algorithm }
            if let retention = args.retention { state.settings.retention = retention }
            if let value = args.newPerDay { state.settings.newPerDay = value }
            if let value = args.reviewsPerDay { state.settings.reviewsPerDay = value }
            if let value = args.maxInterval { state.settings.maxInterval = value }
        }
        context.undoGroup.add(UndoStep(label: "Lerneinstellungen", undo: { [weak library] in library?.changeState { $0 = before } }, redo: {}))
        return library.settings
    }
}

struct LearningMaterialAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var url: String?
        var text: String?
        var title: String?
        var source: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.material.add", summary: "Hinterlegt Material: einen Link (YouTube wird erkannt), eigenen Text oder eine Quelle aus Citation Studio (Citekey)",
        kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "url": .string("Adresse"), "text": .string("Text"), "title": .string("Titel"), "source": .string("Citekey einer Quelle")],
                       required: ["course"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let before = course
        var made: LearningMaterial?
        if let url = args.url {
            made = app.addCourseLink(url, title: args.title ?? "", to: course.id)
        } else if let text = args.text {
            let material = LearningMaterial(kind: .text, title: args.title ?? "", text: text)
            app.learning.courses.update(course.id) { $0.materials.append(material) }
            made = material
        } else if let key = args.source {
            app.citations.loadIfNeeded()
            guard let source = app.citations.source(citekey: key) else { throw RPCError.notFound("Quelle „\(key)“ gibt es nicht.") }
            made = app.addCourseSource(source.id, to: course.id)
        }
        guard let made else { throw RPCError.invalidParams("url, text oder source angeben.") }
        let library = app.learning.courses
        context.undoGroup.add(UndoStep(label: "Material", undo: { [weak library] in library?.restore(before) }, redo: {}))
        return OKOutput(id: made.id.uuidString)
    }
}

struct LearningLinkAddAction: LLMDAction {
    struct Args: Decodable, Sendable, ProjectRefArguments {
        var course: String
        var chat: String?
        var doc: String?
        var note: String?
        var world: String?
        var part: String?
        var element: String?
        var project: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.link.add", summary: "Verknüpft ein Dokument, eine Präsentation, ein Note, einen Chat, ein Projekt oder einen Teil einer Romanwelt mit einem Kurs",
        kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "project": projectProperty].merging(projectRefProperties) { $1 }, required: ["course"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try app.actionCourse(args.course)
        if let project = args.project {
            let id = try app.actionProject(project).id
            try context.changeCourse(course.id, label: "Mit Projekt verknüpfen") { if !$0.projects.contains(id) { $0.projects.append(id) } }
            return OKOutput(id: id.uuidString)
        }
        guard let ref = try app.actionProjectRef(args) else { throw RPCError.invalidParams("chat, doc, note, world oder project angeben.") }
        try context.changeCourse(course.id, label: "Verknüpfen") { if !$0.links.contains(ref) { $0.links.append(ref) } }
        return OKOutput(id: ref.targetID.uuidString)
    }
}

struct LearningAICardsAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var material: String?
        var count: Int?
    }
    struct Output: Encodable, Sendable {
        var added: Int
        var cards: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "learning.ai.cards", summary: "Lässt das lokale Modell Karteikarten aus Material des Kurses (oder dem ganzen Kurs) erstellen", kind: .write,
        security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .local),
        input: .object(["course": courseProperty, "material": .string("Material (ID oder Titel); ohne: alles"), "count": .integer("Wie viele (Vorgabe 12)", minimum: 1, maximum: 60)],
                       required: ["course"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let material = try args.material.map { reference in
            guard let found = course.materials.first(where: { $0.id.uuidString == reference || $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }) else {
                throw RPCError.notFound("Material „\(reference)“ gibt es nicht.")
            }
            return found.id
        }
        let before = course
        let cards = try await app.makeCards(courseID: course.id, material: material, count: args.count ?? 12)
        let library = app.learning.courses
        context.undoGroup.add(UndoStep(label: "Karten aus Material", undo: { [weak library] in library?.restore(before) }, redo: {}))
        return Output(added: cards.count, cards: cards.map(\.front))
    }
}

struct LearningAISheetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var material: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.ai.sheet", summary: "Lässt das lokale Modell einen Lernzettel (Writer-Dokument) aus Material des Kurses schreiben; er wird mit dem Kurs verknüpft",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .local),
        input: .object(["course": courseProperty, "material": .string("Material (ID oder Titel); ohne: alles")], required: ["course"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let material = args.material.flatMap { reference in course.materials.first { $0.id.uuidString == reference || $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }?.id }
        let document = try await app.makeStudySheet(courseID: course.id, material: material, open: false)
        let id = document.id
        context.undoGroup.add(UndoStep(label: "Lernzettel", undo: { [weak app] in app?.deleteDocument(id) }, redo: {}))
        return OKOutput(id: document.id.uuidString)
    }
}

struct LearningStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String?
        var review: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.studio.open", summary: "Öffnet Learning Studio: den Garten oder einen Kurs, auf Wunsch gleich zum Lernen", kind: .read, security: .plainRead,
        input: .object(["course": courseProperty, "review": .boolean("Gleich die fälligen Karten lernen")]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try args.course.map { try app.actionCourse($0).id }
        app.openLearningStudio(LearningStudioCommand(course: course, review: args.review == true))
        return OKOutput(id: course?.uuidString)
    }
}

struct LearningStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "learning.studio.close", summary: "Schließt Learning Studio", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeLearningStudio()
        return OKOutput()
    }
}
