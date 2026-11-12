import Foundation

// The blocks of a project page. Each sits on a grid of 12 columns and rows of a fixed height (`x`, `y`, `b`, `h` in
// the file); the page lays them out from that and stacks them when the window gets narrow.

enum ProjectBlockKind: String, CaseIterable, Identifiable, Sendable {
    case text
    case progress = "fortschritt"
    case todos
    case milestones = "meilensteine"
    case chart = "diagramm"
    case links = "verknuepfungen"
    case metric = "kennzahl"
    case countdown
    case sticky = "haftnotiz"
    case impediments = "hindernisse"
    case board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .progress: "Fortschritt"
        case .todos: "ToDo-Liste"
        case .milestones: "Meilensteine"
        case .chart: "Diagramm"
        case .links: "Verknüpfungen"
        case .metric: "Kennzahl"
        case .countdown: "Countdown"
        case .sticky: "Haftnotiz"
        case .impediments: "Hindernisse"
        case .board: "Aufgaben-Überblick"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .progress: "gauge.with.dots.needle.67percent"
        case .todos: "checklist"
        case .milestones: "flag.pattern.checkered"
        case .chart: "chart.pie"
        case .links: "link"
        case .metric: "number.square"
        case .countdown: "hourglass"
        case .sticky: "note"
        case .impediments: "exclamationmark.triangle"
        case .board: "rectangle.split.3x1"
        }
    }

    var tagline: String {
        switch self {
        case .text: "Überschrift oder Absatz, frei gestaltet"
        case .progress: "Wie weit das Projekt ist, als Bild"
        case .todos: "Eine ToDo-Liste des Projekts"
        case .milestones: "Termine auf einer Zeitleiste"
        case .chart: "Gantt, Kreis, Balken, Verlauf, Ablauf"
        case .links: "Chats, Dokumente, Notes, Romanwelten"
        case .metric: "Eine Zahl, groß"
        case .countdown: "Tage bis zum nächsten Termin"
        case .sticky: "Ein Zettel für zwischendurch"
        case .impediments: "Was die Aufgaben aufhält"
        case .board: "Die Spalten des Boards in klein"
        }
    }

    /// The size a new block starts with (columns, rows).
    var defaultSize: (width: Int, height: Int) {
        switch self {
        case .text: (12, 2)
        case .progress: (4, 4)
        case .todos: (6, 6)
        case .milestones: (12, 3)
        case .chart: (6, 6)
        case .links: (6, 4)
        case .metric: (3, 3)
        case .countdown: (3, 3)
        case .sticky: (3, 4)
        case .impediments: (6, 4)
        case .board: (12, 3)
        }
    }
}

/// Where a block sits on the grid: column and row of its top left corner, its width in columns and height in rows.
struct ProjectGridFrame: Hashable, Sendable {
    static let columns = 12

    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.width = min(max(width, 1), Self.columns)
        self.height = max(height, 1)
        self.x = min(max(x, 0), Self.columns - self.width)
        self.y = max(y, 0)
    }

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func overlaps(_ other: ProjectGridFrame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

enum ProjectTextAlignment: String, CaseIterable, Identifiable, Sendable {
    case leading = "links"
    case center = "mitte"
    case trailing = "rechts"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: "Links"
        case .center: "Mitte"
        case .trailing: "Rechts"
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

/// How a block's text looks; nil fields follow the page.
struct ProjectTextStyle: Hashable, Sendable {
    var font: WriterFont?
    var size: Double?
    /// Nil: the normal text colour.
    var color: FolderColor?
    var bold = false
    var italic = false
    var alignment: ProjectTextAlignment = .leading

    var isPlain: Bool { self == ProjectTextStyle() }
}

/// What a progress display, a metric or a pie counts.
enum ProjectMeasure: String, CaseIterable, Identifiable, Sendable {
    /// Tasks in the done columns of all tasks.
    case tasks = "aufgaben"
    /// Acceptance criteria met of all criteria.
    case criteria = "akzeptanz"
    case todos
    case milestones = "meilensteine"
    /// Tasks, to-dos and milestones together.
    case all = "alles"
    // For metrics only:
    case openTasks = "offeneAufgaben"
    case blocked = "hindernisse"
    case links = "verknuepfungen"
    case daysLeft = "restTage"
    case manual = "manuell"

    var id: String { rawValue }

    static let progressCases: [ProjectMeasure] = [.tasks, .criteria, .todos, .milestones, .all]
    static let metricCases: [ProjectMeasure] = [.openTasks, .tasks, .blocked, .todos, .milestones, .links, .daysLeft, .manual]

    var title: String {
        switch self {
        case .tasks: "Erledigte Aufgaben"
        case .criteria: "Erfüllte Akzeptanzkriterien"
        case .todos: "Erledigte ToDos"
        case .milestones: "Erreichte Meilensteine"
        case .all: "Alles zusammen"
        case .openTasks: "Offene Aufgaben"
        case .blocked: "Aufgaben mit Hindernis"
        case .links: "Verknüpfungen"
        case .daysLeft: "Tage bis zum nächsten Meilenstein"
        case .manual: "Eigene Zahl"
        }
    }
}

enum ProjectChartKind: String, CaseIterable, Identifiable, Sendable {
    case gantt
    case pie = "kreis"
    case bars = "balken"
    case course = "verlauf"
    case flow = "ablauf"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gantt: "Gantt"
        case .pie: "Kreis"
        case .bars: "Balken"
        case .course: "Verlauf"
        case .flow: "Ablauf"
        }
    }

    var symbol: String {
        switch self {
        case .gantt: "chart.bar.doc.horizontal"
        case .pie: "chart.pie"
        case .bars: "chart.bar"
        case .course: "chart.line.uptrend.xyaxis"
        case .flow: "flowchart"
        }
    }

    /// Where its data can come from; the first is the default.
    var sources: [ProjectChartSource] {
        switch self {
        case .gantt: [.tasks, .milestones, .manual]
        case .pie, .bars: [.columns, .priorities, .tags, .todos, .manual]
        case .course: [.history]
        case .flow: [.columns, .manual]
        }
    }
}

enum ProjectChartSource: String, CaseIterable, Identifiable, Sendable {
    case tasks = "aufgaben"
    case milestones = "meilensteine"
    case columns = "spalten"
    case priorities = "prioritaet"
    case tags = "etiketten"
    case todos
    case history = "verlauf"
    case manual = "manuell"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Aufgaben mit Terminen"
        case .milestones: "Meilensteine"
        case .columns: "Aufgaben je Spalte"
        case .priorities: "Aufgaben je Priorität"
        case .tags: "Aufgaben je Etikett"
        case .todos: "ToDos offen und erledigt"
        case .history: "Verlauf des Projekts"
        case .manual: "Eigene Werte"
        }
    }
}

enum ProjectFlowShape: String, CaseIterable, Identifiable, Sendable {
    case step = "schritt"
    case decision = "entscheidung"
    case terminal = "start"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .step: "Schritt"
        case .decision: "Entscheidung"
        case .terminal: "Start/Ende"
        }
    }
}

/// One value of a chart drawn from the person's own numbers: a slice, a bar, a bar of the Gantt chart or a step.
struct ProjectChartEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var value: Double = 1
    var color: FolderColor?
    var start: Date?
    var end: Date?
    var isDone = false
    var shape: ProjectFlowShape = .step

    init(title: String = "", value: Double = 1, color: FolderColor? = nil, start: Date? = nil, end: Date? = nil) {
        self.title = title
        self.value = value
        self.color = color
        self.start = start
        self.end = end
    }
}

struct ProjectChart: Hashable, Sendable {
    var kind: ProjectChartKind = .pie
    var source: ProjectChartSource = .columns
    var entries: [ProjectChartEntry] = []

    init(kind: ProjectChartKind = .pie, source: ProjectChartSource? = nil) {
        self.kind = kind
        self.source = source ?? kind.sources[0]
    }
}

/// A block on the page.
struct ProjectBlock: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: ProjectBlockKind
    var frame: ProjectGridFrame
    /// The heading above the content; empty: none (text, sticky notes) or the kind's own (others).
    var title = ""
    var style = ProjectTextStyle()
    /// Text blocks and sticky notes.
    var text = ""
    var progressStyle: ProjectProgressStyle = .classic(.rings)
    var measure: ProjectMeasure = .tasks
    /// The to-do list it shows.
    var listID: UUID?
    var chart: ProjectChart?
    /// The day a countdown counts to; nil: the next milestone that is not done.
    var date: Date?
    /// The colour of a sticky note or a block's frame; the value of a manual metric.
    var tint: FolderColor?
    var value: Double?

    init(kind: ProjectBlockKind, frame: ProjectGridFrame) {
        self.kind = kind
        self.frame = frame
        if kind == .chart { chart = ProjectChart() }
        if kind == .metric { measure = .openTasks }
        if kind == .sticky { tint = .yellow }
    }

    var headline: String {
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        switch kind {
        case .text, .sticky: return ""
        case .chart: return chart.map { "\($0.kind.title): \($0.source.title)" } ?? kind.title
        case .metric, .progress: return measure.title
        default: return kind.title
        }
    }
}

extension ProjectBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, art, x, y, b, h, titel, stil, text, anzeige, quelle, liste, diagramm, datum, farbe, wert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = ProjectBlockKind(rawValue: try c.decode(String.self, forKey: .art)) else {
            throw DecodingError.dataCorruptedError(forKey: .art, in: c, debugDescription: "Unbekannter Baustein")
        }
        let size = kind.defaultSize
        self.init(kind: kind, frame: ProjectGridFrame(x: c.lenient(.x, 0), y: c.lenient(.y, 0), width: c.lenient(.b, size.width), height: c.lenient(.h, size.height)))
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        style = c.lenient(.stil, ProjectTextStyle())
        text = c.lenient(.text, "")
        progressStyle = ProjectProgressStyle(rawValue: c.lenient(.anzeige, "")) ?? .classic(.rings)
        measure = ProjectMeasure(rawValue: c.lenient(.quelle, "")) ?? measure
        listID = c.lenient(.liste, UUID?.none)
        chart = c.lenient(.diagramm, ProjectChart?.none) ?? chart
        date = c.lenientDay(.datum)
        if let tint = try? c.decodeIfPresent(String.self, forKey: .farbe) { self.tint = FolderColor(rawValue: tint) }
        value = c.lenient(.wert, Double?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .art)
        try c.encode(frame.x, forKey: .x)
        try c.encode(frame.y, forKey: .y)
        try c.encode(frame.width, forKey: .b)
        try c.encode(frame.height, forKey: .h)
        if !title.isEmpty { try c.encode(title, forKey: .titel) }
        if !style.isPlain { try c.encode(style, forKey: .stil) }
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if kind == .progress { try c.encode(progressStyle.rawValue, forKey: .anzeige) }
        if kind == .progress || kind == .metric { try c.encode(measure.rawValue, forKey: .quelle) }
        try c.encodeIfPresent(listID, forKey: .liste)
        if kind == .chart { try c.encodeIfPresent(chart, forKey: .diagramm) }
        try c.encodeDay(date, forKey: .datum)
        try c.encodeIfPresent(tint?.rawValue, forKey: .farbe)
        try c.encodeIfPresent(value, forKey: .wert)
    }
}

extension ProjectTextStyle: Codable {
    private enum CodingKeys: String, CodingKey { case schrift, groesse, farbe, fett, kursiv, ausrichtung }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = WriterFont(rawValue: c.lenient(.schrift, ""))
        size = c.lenient(.groesse, Double?.none).map { min(max($0, 8), 96) }
        color = FolderColor(rawValue: c.lenient(.farbe, ""))
        bold = c.lenient(.fett, false)
        italic = c.lenient(.kursiv, false)
        alignment = ProjectTextAlignment(rawValue: c.lenient(.ausrichtung, "")) ?? .leading
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(font?.rawValue, forKey: .schrift)
        try c.encodeIfPresent(size, forKey: .groesse)
        try c.encodeIfPresent(color?.rawValue, forKey: .farbe)
        if bold { try c.encode(true, forKey: .fett) }
        if italic { try c.encode(true, forKey: .kursiv) }
        if alignment != .leading { try c.encode(alignment.rawValue, forKey: .ausrichtung) }
    }
}

extension ProjectChart: Codable {
    private enum CodingKeys: String, CodingKey { case art, quelle, werte }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = ProjectChartKind(rawValue: c.lenient(.art, "")) ?? .pie
        let source = ProjectChartSource(rawValue: c.lenient(.quelle, ""))
        self.source = source.flatMap { kind.sources.contains($0) ? $0 : nil } ?? kind.sources[0]
        entries = c.lenient(.werte, [Lenient<ProjectChartEntry>]()).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .art)
        try c.encode(source.rawValue, forKey: .quelle)
        if !entries.isEmpty { try c.encode(entries, forKey: .werte) }
    }
}

extension ProjectChartEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, titel, wert, farbe, start, ende, erledigt, form }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        value = c.lenient(.wert, 1)
        color = FolderColor(rawValue: c.lenient(.farbe, ""))
        start = c.lenientDay(.start)
        end = c.lenientDay(.ende)
        isDone = c.lenient(.erledigt, false)
        shape = ProjectFlowShape(rawValue: c.lenient(.form, "")) ?? .step
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(value, forKey: .wert)
        try c.encodeIfPresent(color?.rawValue, forKey: .farbe)
        try c.encodeDay(start, forKey: .start)
        try c.encodeDay(end, forKey: .ende)
        if isDone { try c.encode(true, forKey: .erledigt) }
        if shape != .step { try c.encode(shape.rawValue, forKey: .form) }
    }
}

// MARK: - Progress displays

/// The pictures of a project's progress: the twelve of Notes and four of the project's own, which draw on what a
/// project has (its milestones, its tasks).
enum ProjectProgressStyle: Hashable, Sendable, Identifiable {
    case classic(NoteProgressStyle)
    /// A path through the milestones; the marker walks on as the work gets done.
    case journey
    /// One star per task; done tasks light up and join the constellation.
    case constellation
    /// The sand runs down.
    case hourglass
    /// The windows of a city at night light up one after another.
    case skyline

    static let ownCases: [ProjectProgressStyle] = [.journey, .constellation, .hourglass, .skyline]
    static var allCases: [ProjectProgressStyle] { ownCases + NoteProgressStyle.allCases.map { .classic($0) } }

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "reise": self = .journey
        case "sternbild": self = .constellation
        case "sanduhr": self = .hourglass
        case "skyline": self = .skyline
        default:
            guard let style = NoteProgressStyle(rawValue: rawValue) else { return nil }
            self = .classic(style)
        }
    }

    var rawValue: String {
        switch self {
        case .classic(let style): style.rawValue
        case .journey: "reise"
        case .constellation: "sternbild"
        case .hourglass: "sanduhr"
        case .skyline: "skyline"
        }
    }

    var title: String {
        switch self {
        case .classic(let style): style.title
        case .journey: "Reise"
        case .constellation: "Sternbild"
        case .hourglass: "Sanduhr"
        case .skyline: "Skyline"
        }
    }

    var tagline: String {
        switch self {
        case .classic(let style): style.tagline
        case .journey: "Station für Station zum Ziel"
        case .constellation: "Jede Aufgabe ein Stern"
        case .hourglass: "Der Sand rinnt"
        case .skyline: "Die Stadt geht an"
        }
    }
}
