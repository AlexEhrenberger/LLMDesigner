import Foundation

// Projects: a page laid out freely from blocks on a grid (text, progress, charts, to-do lists, milestones, links …)
// and a board of tasks in columns of the person's own. A project only holds references: the chats, documents,
// presentations, notes and novel worlds it links to stay where they are and as they are. Keys in the file are German,
// like the other new formats; everything is read leniently, so fields can be added later without a migration.

// MARK: - References

/// Something in the library a project, a task or a to-do points to.
enum ProjectRef: Hashable, Sendable {
    case chat(UUID)
    /// A Writer document or a presentation (both are documents in the library).
    case document(UUID)
    case note(UUID)
    /// A novel world as a whole, one of its parts, or one of its elements (a figure, a place …).
    case story(world: UUID, part: UUID?, element: StoryRef?)

    /// The id of the thing itself, for comparisons with deleted things and for the actions' output.
    var targetID: UUID {
        switch self {
        case .chat(let id), .document(let id), .note(let id): id
        case .story(let world, let part, let element): element?.id ?? part ?? world
        }
    }

    var worldID: UUID? {
        if case .story(let world, _, _) = self { return world }
        return nil
    }

    var art: String {
        switch self {
        case .chat: "chat"
        case .document: "dokument"
        case .note: "note"
        case .story: "romanwelt"
        }
    }
}

extension ProjectRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case art, id, teil, element
    }

    private enum ElementKeys: String, CodingKey {
        case art, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        switch try c.decode(String.self, forKey: .art) {
        case "chat": self = .chat(id)
        case "dokument", "praesentation": self = .document(id)
        case "note": self = .note(id)
        case "romanwelt":
            var element: StoryRef?
            if let nested = try? c.nestedContainer(keyedBy: ElementKeys.self, forKey: .element),
               let kind = StoryElementKind(rawValue: nested.lenient(.art, "")), let elementID = nested.lenient(.id, UUID?.none) {
                element = StoryRef(kind: kind, id: elementID)
            }
            self = .story(world: id, part: c.lenient(.teil, UUID?.none), element: element)
        case let other: throw DecodingError.dataCorruptedError(forKey: .art, in: c, debugDescription: "Unbekannte Verknüpfung „\(other)“")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(art, forKey: .art)
        switch self {
        case .chat(let id), .document(let id), .note(let id):
            try c.encode(id, forKey: .id)
        case .story(let world, let part, let element):
            try c.encode(world, forKey: .id)
            try c.encodeIfPresent(part, forKey: .teil)
            if let element {
                var nested = c.nestedContainer(keyedBy: ElementKeys.self, forKey: .element)
                try nested.encode(element.kind.rawValue, forKey: .art)
                try nested.encode(element.id, forKey: .id)
            }
        }
    }
}

// MARK: - Project

enum ProjectStatus: String, CaseIterable, Identifiable, Sendable {
    case planned = "geplant"
    case running = "laeuft"
    case paused = "pausiert"
    case done = "fertig"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .planned: "Geplant"
        case .running: "Läuft"
        case .paused: "Pausiert"
        case .done: "Fertig"
        }
    }

    var symbol: String {
        switch self {
        case .planned: "circle.dashed"
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// How the page looks as a whole: its typeface, accent and background. Blocks can set their own text style on top.
struct ProjectDesign: Hashable, Sendable {
    var font: WriterFont = .sans
    /// Nil: the project's colour.
    var accent: FolderColor?
    var background: ProjectBackground = .plain
}

enum ProjectBackground: String, CaseIterable, Identifiable, Sendable {
    case plain = "standard"
    case paper = "papier"
    case gradient = "verlauf"
    case dots = "punkte"
    case blueprint = "blaupause"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Schlicht"
        case .paper: "Papier"
        case .gradient: "Farbverlauf"
        case .dots: "Punktraster"
        case .blueprint: "Blaupause"
        }
    }
}

/// A project: its page, its board and everything both draw on.
struct Project: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var subtitle = ""
    var symbol = Project.defaultSymbol
    var color: FolderColor = .purple
    var status: ProjectStatus = .running
    var design = ProjectDesign()
    var blocks: [ProjectBlock] = []
    /// What belongs to the project as a whole (tasks and to-dos have links of their own).
    var links: [ProjectRef] = []
    var todoLists: [ProjectTodoList] = []
    var milestones: [ProjectMilestone] = []
    var columns: [ProjectColumn] = []
    /// In board order: the tasks of a column are the ones with its id, in this order.
    var tasks: [ProjectTask] = []
    /// One entry per day on which something changed: the numbers behind the course chart, never text.
    var history: [ProjectHistoryDay] = []
    var createdAt = Date()
    var updatedAt = Date()

    static let defaultSymbol = "square.grid.3x2"
    /// The kind's own symbol: the category in the sidebar and the New menu.
    static let sidebarSymbol = "rectangle.3.group"

    /// The symbols a project can choose from in its head.
    static let symbols = [
        "square.grid.3x2", "folder", "graduationcap", "book.closed", "doc.richtext", "sparkles", "lightbulb", "flag",
        "target", "chart.line.uptrend.xyaxis", "hammer", "paintbrush", "globe.europe.africa", "airplane", "house",
        "heart", "leaf", "music.note", "camera", "briefcase", "building.columns", "atom", "theatermasks", "puzzlepiece",
    ]

    init(title: String = "") {
        self.title = title
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Unbenanntes Projekt" : title
    }

    var accent: FolderColor { design.accent ?? color }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedStandardContains(query) || subtitle.localizedStandardContains(query)
            || tasks.contains { $0.title.localizedStandardContains(query) || $0.details.localizedStandardContains(query) }
            || blocks.contains { $0.text.localizedStandardContains(query) }
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, untertitel, symbol, farbe, status, gestaltung, bausteine, verknuepft, todoListen, meilensteine,
             spalten, aufgaben, verlauf, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        subtitle = c.lenient(.untertitel, "")
        symbol = c.lenient(.symbol, Project.defaultSymbol)
        color = FolderColor(rawValue: c.lenient(.farbe, "")) ?? .purple
        status = ProjectStatus(rawValue: c.lenient(.status, "")) ?? .running
        design = c.lenient(.gestaltung, ProjectDesign())
        blocks = c.lenient(.bausteine, [Lenient<ProjectBlock>]()).compactMap(\.value)
        links = c.lenient(.verknuepft, [Lenient<ProjectRef>]()).compactMap(\.value)
        todoLists = c.lenient(.todoListen, [Lenient<ProjectTodoList>]()).compactMap(\.value)
        milestones = c.lenient(.meilensteine, [Lenient<ProjectMilestone>]()).compactMap(\.value)
        columns = c.lenient(.spalten, [Lenient<ProjectColumn>]()).compactMap(\.value)
        tasks = c.lenient(.aufgaben, [Lenient<ProjectTask>]()).compactMap(\.value)
        history = c.lenient(.verlauf, [Lenient<ProjectHistoryDay>]()).compactMap(\.value)
        createdAt = c.lenient(.erstellt, Date())
        updatedAt = c.lenient(.geaendert, createdAt)
        // A board needs a column for its tasks; one left without its column goes to the first.
        if columns.isEmpty { columns = ProjectColumn.defaults }
        let known = Set(columns.map(\.id))
        for index in tasks.indices where !known.contains(tasks[index].column) { tasks[index].column = columns[0].id }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        if !subtitle.isEmpty { try c.encode(subtitle, forKey: .untertitel) }
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color.rawValue, forKey: .farbe)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(design, forKey: .gestaltung)
        try c.encode(blocks, forKey: .bausteine)
        try c.encode(links, forKey: .verknuepft)
        try c.encode(todoLists, forKey: .todoListen)
        try c.encode(milestones, forKey: .meilensteine)
        try c.encode(columns, forKey: .spalten)
        try c.encode(tasks, forKey: .aufgaben)
        if !history.isEmpty { try c.encode(history, forKey: .verlauf) }
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

extension ProjectDesign: Codable {
    private enum CodingKeys: String, CodingKey {
        case schrift, akzent, hintergrund
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = WriterFont(rawValue: c.lenient(.schrift, "")) ?? .sans
        accent = FolderColor(rawValue: c.lenient(.akzent, ""))
        background = ProjectBackground(rawValue: c.lenient(.hintergrund, "")) ?? .plain
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(font.rawValue, forKey: .schrift)
        try c.encodeIfPresent(accent?.rawValue, forKey: .akzent)
        try c.encode(background.rawValue, forKey: .hintergrund)
    }
}

// MARK: - Days

/// Dates without a time of day ("2026-11-20") for due dates, milestones and the history, read in the local calendar.
enum ProjectDay {
    static func string(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ string: String) -> Date? {
        let pieces = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    /// The start of the day, so that two dates of the same day compare equal.
    static func normalized(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Whole days from today to `date`; negative when it is past.
    static func days(until date: Date, from now: Date = Date()) -> Int {
        Calendar.current.dateComponents([.day], from: normalized(now), to: normalized(date)).day ?? 0
    }

    /// "20.11.2026" or "20. Nov."
    static func label(_ date: Date, short: Bool = false) -> String {
        short ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(date: .numeric, time: .omitted)
    }

    /// "noch 9 Tage", "morgen", "heute", "seit 2 Tagen".
    static func countdown(_ date: Date, from now: Date = Date()) -> String {
        let days = days(until: date, from: now)
        switch days {
        case 0: return "heute"
        case 1: return "morgen"
        case -1: return "seit gestern"
        case ..<0: return "seit \(-days) Tagen"
        default: return "noch \(days) Tage"
        }
    }
}

extension KeyedDecodingContainer {
    /// A day as "2026-11-20"; a full date-time is accepted too.
    func lenientDay(_ key: Key) -> Date? {
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return ProjectDay.date(text)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeDay(_ date: Date?, forKey key: Key) throws {
        if let date { try encode(ProjectDay.string(date), forKey: key) }
    }
}

// MARK: - To-dos and milestones

/// A to-do list of the project. It has nothing to do with Notes: it belongs to the project and shows on its page.
struct ProjectTodoList: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var todos: [ProjectTodo] = []

    init(title: String = "", todos: [ProjectTodo] = []) {
        self.title = title
        self.todos = todos
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "ToDos" : title }
    var done: Int { todos.filter(\.isDone).count }
}

struct ProjectTodo: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
    var isDone = false
    var due: Date?
    var link: ProjectRef?

    init(text: String = "", isDone: Bool = false, due: Date? = nil, link: ProjectRef? = nil) {
        self.text = text
        self.isDone = isDone
        self.due = due
        self.link = link
    }
}

struct ProjectMilestone: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var date = ProjectDay.normalized(Date())
    var isDone = false
    var color: FolderColor?

    init(title: String = "", date: Date = Date(), isDone: Bool = false) {
        self.title = title
        self.date = ProjectDay.normalized(date)
        self.isDone = isDone
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Meilenstein" : title }
}

extension ProjectTodoList: Codable {
    private enum CodingKeys: String, CodingKey { case id, titel, todos }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        todos = c.lenient(.todos, [Lenient<ProjectTodo>]()).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(todos, forKey: .todos)
    }
}

extension ProjectTodo: Codable {
    private enum CodingKeys: String, CodingKey { case id, text, erledigt, faellig, verweis }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        text = c.lenient(.text, "")
        isDone = c.lenient(.erledigt, false)
        due = c.lenientDay(.faellig)
        link = c.lenient(.verweis, ProjectRef?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(isDone, forKey: .erledigt)
        try c.encodeDay(due, forKey: .faellig)
        try c.encodeIfPresent(link, forKey: .verweis)
    }
}

extension ProjectMilestone: Codable {
    private enum CodingKeys: String, CodingKey { case id, titel, datum, erledigt, farbe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        date = c.lenientDay(.datum) ?? ProjectDay.normalized(Date())
        isDone = c.lenient(.erledigt, false)
        color = FolderColor(rawValue: c.lenient(.farbe, ""))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encodeDay(date, forKey: .datum)
        try c.encode(isDone, forKey: .erledigt)
        try c.encodeIfPresent(color?.rawValue, forKey: .farbe)
    }
}

// MARK: - Board

/// A column of the board. Tasks in a column marked `isDone` count as finished for the progress.
struct ProjectColumn: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var color: FolderColor?
    var isDone = false
    /// How many tasks should be in it at most (work in progress); nil: no limit.
    var limit: Int?

    init(title: String, color: FolderColor? = nil, isDone: Bool = false, limit: Int? = nil) {
        self.title = title
        self.color = color
        self.isDone = isDone
        self.limit = limit
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Spalte" : title }

    /// A new project's board.
    static var defaults: [ProjectColumn] {
        [
            ProjectColumn(title: "Ideen", color: .yellow),
            ProjectColumn(title: "Offen", color: .blue),
            ProjectColumn(title: "In Arbeit", color: .orange, limit: 3),
            ProjectColumn(title: "Prüfen", color: .purple),
            ProjectColumn(title: "Erledigt", color: .green, isDone: true),
        ]
    }
}

enum ProjectPriority: String, CaseIterable, Identifiable, Sendable, Comparable {
    case low = "niedrig"
    case normal = "mittel"
    case high = "hoch"
    case urgent = "dringend"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Niedrig"
        case .normal: "Mittel"
        case .high: "Hoch"
        case .urgent: "Dringend"
        }
    }

    var symbol: String {
        switch self {
        case .low: "chevron.down"
        case .normal: "equal"
        case .high: "chevron.up"
        case .urgent: "exclamationmark.2"
        }
    }

    var color: FolderColor {
        switch self {
        case .low: .teal
        case .normal: .blue
        case .high: .orange
        case .urgent: .red
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// "Woran erkenne ich, dass die Aufgabe abgenommen werden kann?" – one condition.
struct ProjectCriterion: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
    var isMet = false

    init(text: String = "", isMet: Bool = false) {
        self.text = text
        self.isMet = isMet
    }
}

/// An obstacle in the way of a task, and how it can be removed.
struct ProjectImpediment: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
    var solution = ""
    var isResolved = false

    init(text: String = "", solution: String = "", isResolved: Bool = false) {
        self.text = text
        self.solution = solution
        self.isResolved = isResolved
    }
}

struct ProjectTask: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var details = ""
    var column: UUID
    var priority: ProjectPriority = .normal
    var start: Date?
    var due: Date?
    var tags: [String] = []
    var criteria: [ProjectCriterion] = []
    var impediments: [ProjectImpediment] = []
    var links: [ProjectRef] = []
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String = "", column: UUID) {
        self.title = title
        self.column = column
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Neue Aufgabe" : title }
    var openImpediments: [ProjectImpediment] { impediments.filter { !$0.isResolved } }
    var isBlocked: Bool { !openImpediments.isEmpty }
    var criteriaMet: Int { criteria.filter(\.isMet).count }
    /// Every acceptance criterion is met: the task is ready to be accepted.
    var isAcceptable: Bool { !criteria.isEmpty && criteriaMet == criteria.count }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedStandardContains(query) || details.localizedStandardContains(query)
            || tags.contains { $0.localizedStandardContains(query) }
    }
}

extension ProjectColumn: Codable {
    private enum CodingKeys: String, CodingKey { case id, titel, farbe, fertig, limit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        color = FolderColor(rawValue: c.lenient(.farbe, ""))
        isDone = c.lenient(.fertig, false)
        limit = c.lenient(.limit, Int?.none).flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encodeIfPresent(color?.rawValue, forKey: .farbe)
        if isDone { try c.encode(true, forKey: .fertig) }
        try c.encodeIfPresent(limit, forKey: .limit)
    }
}

extension ProjectCriterion: Codable {
    private enum CodingKeys: String, CodingKey { case id, text, erfuellt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        text = c.lenient(.text, "")
        isMet = c.lenient(.erfuellt, false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(isMet, forKey: .erfuellt)
    }
}

extension ProjectImpediment: Codable {
    private enum CodingKeys: String, CodingKey { case id, text, loesung, behoben }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        text = c.lenient(.text, "")
        solution = c.lenient(.loesung, "")
        isResolved = c.lenient(.behoben, false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        if !solution.isEmpty { try c.encode(solution, forKey: .loesung) }
        try c.encode(isResolved, forKey: .behoben)
    }
}

extension ProjectTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, beschreibung, spalte, prioritaet, start, faellig, etiketten, akzeptanz, hindernisse, verweise, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        details = c.lenient(.beschreibung, "")
        // A missing column is repaired by the project (first column).
        column = c.lenient(.spalte, UUID())
        priority = ProjectPriority(rawValue: c.lenient(.prioritaet, "")) ?? .normal
        start = c.lenientDay(.start)
        due = c.lenientDay(.faellig)
        tags = c.lenient(.etiketten, [String]())
        criteria = c.lenient(.akzeptanz, [Lenient<ProjectCriterion>]()).compactMap(\.value)
        impediments = c.lenient(.hindernisse, [Lenient<ProjectImpediment>]()).compactMap(\.value)
        links = c.lenient(.verweise, [Lenient<ProjectRef>]()).compactMap(\.value)
        createdAt = c.lenient(.erstellt, Date())
        updatedAt = c.lenient(.geaendert, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        if !details.isEmpty { try c.encode(details, forKey: .beschreibung) }
        try c.encode(column, forKey: .spalte)
        try c.encode(priority.rawValue, forKey: .prioritaet)
        try c.encodeDay(start, forKey: .start)
        try c.encodeDay(due, forKey: .faellig)
        if !tags.isEmpty { try c.encode(tags, forKey: .etiketten) }
        try c.encode(criteria, forKey: .akzeptanz)
        try c.encode(impediments, forKey: .hindernisse)
        if !links.isEmpty { try c.encode(links, forKey: .verweise) }
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

// MARK: - History

/// The project's numbers on one day: tasks and to-dos that were open and done (for the course chart).
struct ProjectHistoryDay: Hashable, Sendable {
    var day: String
    var open: Int
    var done: Int
}

extension ProjectHistoryDay: Codable {
    private enum CodingKeys: String, CodingKey { case tag, offen, erledigt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .tag)
        open = c.lenient(.offen, 0)
        done = c.lenient(.erledigt, 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .tag)
        try c.encode(open, forKey: .offen)
        try c.encode(done, forKey: .erledigt)
    }
}
