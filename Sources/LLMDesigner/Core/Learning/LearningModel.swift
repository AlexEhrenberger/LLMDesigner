import Foundation

// Learning Studio: disciplines (each one tree on the landing page) hold courses; a course holds flash cards with
// their schedule, material (PDFs, a practice exam, links, sources from Citation Studio) and links to the person's
// documents, presentations, notes and projects. Keys in the files are German, like Notes and Projects.

/// How a card answered counts for its schedule.
enum CardRating: Int, Codable, CaseIterable, Identifiable, Sendable {
    case again = 1, hard, good, easy

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .again: "Nochmal"
        case .hard: "Schwer"
        case .good: "Gut"
        case .easy: "Leicht"
        }
    }

    /// "nochmal", "schwer", "gut", "leicht" in actions; also 1 to 4.
    static func parse(_ text: String) -> CardRating? {
        if let number = Int(text) { return CardRating(rawValue: number) }
        return allCases.first { $0.label.lowercased() == text.lowercased() }
    }
}

/// Where a card is in its life: new, in its first steps, in review, or relearned after it was forgotten.
enum CardState: String, Codable, CaseIterable, Sendable {
    case new = "neu"
    case learning = "lernen"
    case review = "wiederholen"
    case relearning = "neulernen"

    var label: String {
        switch self {
        case .new: "Neu"
        case .learning: "Am Lernen"
        case .review: "Wiederholung"
        case .relearning: "Neu lernen"
        }
    }
}

/// One answer to a card, for the statistics and for FSRS.
struct CardReview: Codable, Hashable, Sendable {
    var date: Date
    var rating: CardRating
    /// The state before the answer.
    var state: CardState
    /// Days until it was due again (fractions while learning).
    var interval: Double

    private enum CodingKeys: String, CodingKey { case datum, bewertung, zustand, intervall }

    init(date: Date, rating: CardRating, state: CardState, interval: Double) {
        self.date = date
        self.rating = rating
        self.state = state
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.soft(.datum, Date())
        rating = c.soft(.bewertung, CardRating.good)
        state = c.soft(.zustand, CardState.review)
        interval = c.soft(.intervall, 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .datum)
        try c.encode(rating, forKey: .bewertung)
        try c.encode(state, forKey: .zustand)
        try c.encode((interval * 10_000).rounded() / 10_000, forKey: .intervall)
    }
}

/// A flash card with its schedule.
struct LearningCard: Identifiable, Hashable, Sendable {
    var id = UUID()
    var front = ""
    var back = ""
    var tags: [String] = []
    /// The material it was made from.
    var material: UUID?
    var state: CardState = .new
    var due = Date()
    /// FSRS: days until the chance to remember falls to 90 %.
    var stability = 0.0
    /// FSRS: 1 (easy) to 10 (hard).
    var difficulty = 0.0
    /// SM-2: the factor (2.5 to start).
    var ease = 2.5
    /// Days of the last interval.
    var interval = 0.0
    /// The learning step it is at.
    var step = 0
    var reps = 0
    var lapses = 0
    var lastReview: Date?
    /// Put aside: not asked until it is taken back.
    var suspended = false
    var history: [CardReview] = []
    var createdAt = Date()

    init(front: String = "", back: String = "", tags: [String] = [], material: UUID? = nil) {
        self.front = front
        self.back = back
        self.tags = tags
        self.material = material
    }

    var isMature: Bool { state == .review && interval >= 21 }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([front, back] + tags).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension LearningCard: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, vorne, hinten, schlagwoerter, material, zustand, faellig, stabilitaet, schwierigkeit, faktor, intervall, schritt
        case wiederholungen, vergessen, zuletzt, zurueckgestellt, verlauf, erstellt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        front = c.soft(.vorne, "")
        back = c.soft(.hinten, "")
        tags = c.soft(.schlagwoerter, [String]())
        material = c.soft(.material, UUID?.none)
        state = c.soft(.zustand, CardState.new)
        due = c.soft(.faellig, Date())
        stability = c.soft(.stabilitaet, 0.0)
        difficulty = c.soft(.schwierigkeit, 0.0)
        ease = c.soft(.faktor, 2.5)
        interval = c.soft(.intervall, 0.0)
        step = c.soft(.schritt, 0)
        reps = c.soft(.wiederholungen, 0)
        lapses = c.soft(.vergessen, 0)
        lastReview = c.soft(.zuletzt, Date?.none)
        suspended = c.soft(.zurueckgestellt, false)
        history = c.soft(.verlauf, [CardReview]())
        createdAt = c.soft(.erstellt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(front, forKey: .vorne)
        try c.encode(back, forKey: .hinten)
        if !tags.isEmpty { try c.encode(tags, forKey: .schlagwoerter) }
        try c.encodeIfPresent(material, forKey: .material)
        try c.encode(state, forKey: .zustand)
        try c.encode(due, forKey: .faellig)
        func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        try c.encode(rounded(stability), forKey: .stabilitaet)
        try c.encode(rounded(difficulty), forKey: .schwierigkeit)
        try c.encode(rounded(ease), forKey: .faktor)
        try c.encode(rounded(interval), forKey: .intervall)
        try c.encode(step, forKey: .schritt)
        try c.encode(reps, forKey: .wiederholungen)
        try c.encode(lapses, forKey: .vergessen)
        try c.encodeIfPresent(lastReview, forKey: .zuletzt)
        if suspended { try c.encode(true, forKey: .zurueckgestellt) }
        try c.encode(history, forKey: .verlauf)
        try c.encode(createdAt, forKey: .erstellt)
    }
}

/// Something to learn from.
struct LearningMaterial: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case pdf, probeklausur, link, youtube, quelle, text

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pdf: "PDF"
            case .probeklausur: "Probeklausur"
            case .link: "Link"
            case .youtube: "YouTube"
            case .quelle: "Quelle (Citation Studio)"
            case .text: "Text"
            }
        }

        var symbol: String {
            switch self {
            case .pdf: "doc.richtext"
            case .probeklausur: "checkmark.seal"
            case .link: "link"
            case .youtube: "play.rectangle.fill"
            case .quelle: "quote.bubble"
            case .text: "text.alignleft"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .text
    var title = ""
    /// The file in the course's `Material/` folder (PDFs, practice exams).
    var file: String?
    var url: String?
    /// A source of Citation Studio, by its citekey.
    var citekey: String?
    /// Own text, or what was pasted.
    var text = ""
    /// A short summary the model made once.
    var summary: String?
    var addedAt = Date()

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url ?? file ?? citekey ?? kind.label
    }

    /// A YouTube address of a link.
    static func isYouTube(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.contains("youtube.com/") || lower.contains("youtu.be/")
    }
}

extension LearningMaterial: Codable {
    private enum CodingKeys: String, CodingKey { case id, art, titel, datei, url, zitat, text, zusammenfassung, hinzugefuegt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        kind = c.soft(.art, Kind.text)
        title = c.soft(.titel, "")
        file = c.soft(.datei, String?.none)
        url = c.soft(.url, String?.none)
        citekey = c.soft(.zitat, String?.none)
        text = c.soft(.text, "")
        summary = c.soft(.zusammenfassung, String?.none)
        addedAt = c.soft(.hinzugefuegt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .art)
        try c.encode(title, forKey: .titel)
        try c.encodeIfPresent(file, forKey: .datei)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(citekey, forKey: .zitat)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        try c.encodeIfPresent(summary, forKey: .zusammenfassung)
        try c.encode(addedAt, forKey: .hinzugefuegt)
    }
}

/// One question of a quiz the model asked, with the person's answer and the model's verdict.
struct QuizItem: Identifiable, Hashable, Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case richtig, teilweise, falsch

        var label: String {
            switch self {
            case .richtig: "Richtig"
            case .teilweise: "Teilweise"
            case .falsch: "Falsch"
            }
        }

        var points: Double {
            switch self {
            case .richtig: 1
            case .teilweise: 0.5
            case .falsch: 0
            }
        }
    }

    var id = UUID()
    var question: String
    var answer = ""
    var verdict: Verdict?
    var feedback = ""
    /// What a full answer would have said.
    var solution = ""

    private enum CodingKeys: String, CodingKey { case id, frage, antwort, bewertung, rueckmeldung, loesung }

    init(question: String) {
        self.question = question
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        question = c.soft(.frage, "")
        answer = c.soft(.antwort, "")
        verdict = c.soft(.bewertung, Verdict?.none)
        feedback = c.soft(.rueckmeldung, "")
        solution = c.soft(.loesung, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(question, forKey: .frage)
        try c.encode(answer, forKey: .antwort)
        try c.encodeIfPresent(verdict, forKey: .bewertung)
        try c.encode(feedback, forKey: .rueckmeldung)
        try c.encode(solution, forKey: .loesung)
    }
}

/// A quiz: the model asks about the course's material one question after another.
struct QuizSession: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var date = Date()
    /// The material it asked about; nil: all of it and the cards.
    var material: UUID?
    var items: [QuizItem] = []

    private enum CodingKeys: String, CodingKey { case id, datum, material, fragen }

    init(material: UUID? = nil) {
        self.material = material
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        date = c.soft(.datum, Date())
        material = c.soft(.material, UUID?.none)
        items = c.soft(.fragen, [QuizItem]())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .datum)
        try c.encodeIfPresent(material, forKey: .material)
        try c.encode(items, forKey: .fragen)
    }

    /// 0…1 over the graded questions.
    var score: Double? {
        let graded = items.compactMap(\.verdict)
        guard !graded.isEmpty else { return nil }
        return graded.map(\.points).reduce(0, +) / Double(graded.count)
    }
}

/// A course: cards, material and what belongs to it.
struct LearningCourse: StoredRecord {
    var id = UUID()
    var discipline: UUID?
    var name = ""
    var summary = ""
    var symbol = "book"
    var color: FolderColor = .green
    /// A day to be ready by (an exam).
    var examDate: Date?
    var cards: [LearningCard] = []
    var materials: [LearningMaterial] = []
    /// Chats, documents, presentations, notes and parts of novel worlds that belong to the course.
    var links: [ProjectRef] = []
    var projects: [UUID] = []
    var quizzes: [QuizSession] = []
    var finished = false
    var createdAt = Date()
    var updatedAt = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Neuer Kurs" : trimmed
    }

    func card(_ id: UUID) -> LearningCard? { cards.first { $0.id == id } }

    func material(_ id: UUID) -> LearningMaterial? { materials.first { $0.id == id } }

    mutating func updateCard(_ id: UUID, _ change: (inout LearningCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query)
            || cards.contains { $0.matches(query) } || materials.contains { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }
}

extension LearningCourse: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, disziplin, name, beschreibung, symbol, farbe, pruefung, karten, material, verknuepft, projekte, abfragen, abgeschlossen, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        discipline = c.soft(.disziplin, UUID?.none)
        name = c.soft(.name, "")
        summary = c.soft(.beschreibung, "")
        symbol = c.soft(.symbol, "book")
        color = c.soft(.farbe, FolderColor.green)
        examDate = c.lenientDay(.pruefung)
        cards = c.soft(.karten, [LearningCard]())
        materials = c.soft(.material, [LearningMaterial]())
        links = c.soft(.verknuepft, [ProjectRef]())
        projects = c.soft(.projekte, [UUID]())
        quizzes = c.soft(.abfragen, [QuizSession]())
        finished = c.soft(.abgeschlossen, false)
        createdAt = c.soft(.erstellt, Date())
        updatedAt = c.soft(.geaendert, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(discipline, forKey: .disziplin)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .beschreibung)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .farbe)
        try c.encodeDay(examDate, forKey: .pruefung)
        try c.encode(cards, forKey: .karten)
        try c.encode(materials, forKey: .material)
        try c.encode(links, forKey: .verknuepft)
        try c.encode(projects, forKey: .projekte)
        try c.encode(quizzes, forKey: .abfragen)
        try c.encode(finished, forKey: .abgeschlossen)
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

/// A discipline: one tree on the landing page.
struct LearningDiscipline: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var color: FolderColor = .green
    var symbol = "leaf"
    /// The kind of tree it grows as.
    var tree: TreeKind = .eiche
    var createdAt = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Neue Disziplin" : trimmed
    }
}

/// How a discipline's tree looks: its shape and its blossoms.
enum TreeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case eiche, kirsche, ahorn, birke, kiefer, magnolie

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eiche: "Eiche"
        case .kirsche: "Kirschbaum"
        case .ahorn: "Ahorn"
        case .birke: "Birke"
        case .kiefer: "Kiefer"
        case .magnolie: "Magnolie"
        }
    }
}

extension LearningDiscipline: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, farbe, symbol, baum, erstellt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        color = c.soft(.farbe, FolderColor.green)
        symbol = c.soft(.symbol, "leaf")
        tree = c.soft(.baum, TreeKind.eiche)
        createdAt = c.soft(.erstellt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .farbe)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(tree, forKey: .baum)
        try c.encode(createdAt, forKey: .erstellt)
    }
}

/// The algorithm and its knobs.
struct LearningSettings: Hashable, Sendable {
    enum Algorithm: String, Codable, CaseIterable, Identifiable, Sendable {
        case fsrs, sm2

        var id: String { rawValue }
        var label: String { self == .fsrs ? "FSRS (empfohlen)" : "SM-2 (Anki klassisch)" }
    }

    var algorithm: Algorithm = .fsrs
    /// FSRS: the chance to still know a card when it comes up again.
    var retention = 0.9
    var newPerDay = 20
    var reviewsPerDay = 200
    /// Days.
    var maxInterval = 365.0
    /// Minutes between the first answers of a new card.
    var learningSteps: [Double] = [1, 10]
    var relearningSteps: [Double] = [10]
    /// SM-2: the factor new cards start with and the extra for "Leicht".
    var startingEase = 2.5
    var easyBonus = 1.3
    /// SM-2: stretches (> 1) or shortens every interval.
    var intervalModifier = 1.0
}

extension LearningSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case algorithmus, behaltensrate, neueProTag, wiederholungenProTag, maxIntervall, lernschritte, neulernschritte, startfaktor, leichtBonus, intervallFaktor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = c.soft(.algorithmus, Algorithm.fsrs)
        retention = min(0.99, max(0.7, c.soft(.behaltensrate, 0.9)))
        newPerDay = max(0, c.soft(.neueProTag, 20))
        reviewsPerDay = max(1, c.soft(.wiederholungenProTag, 200))
        maxInterval = max(1, c.soft(.maxIntervall, 365.0))
        learningSteps = c.soft(.lernschritte, [1.0, 10.0])
        relearningSteps = c.soft(.neulernschritte, [10.0])
        startingEase = c.soft(.startfaktor, 2.5)
        easyBonus = c.soft(.leichtBonus, 1.3)
        intervalModifier = c.soft(.intervallFaktor, 1.0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(algorithm, forKey: .algorithmus)
        try c.encode(retention, forKey: .behaltensrate)
        try c.encode(newPerDay, forKey: .neueProTag)
        try c.encode(reviewsPerDay, forKey: .wiederholungenProTag)
        try c.encode(maxInterval, forKey: .maxIntervall)
        try c.encode(learningSteps, forKey: .lernschritte)
        try c.encode(relearningSteps, forKey: .neulernschritte)
        try c.encode(startingEase, forKey: .startfaktor)
        try c.encode(easyBonus, forKey: .leichtBonus)
        try c.encode(intervalModifier, forKey: .intervallFaktor)
    }
}

/// A break (a vacation): no cards come up while it lasts, and when it ends every card due after its start moves on
/// by its length, so nothing piles up.
struct LearningPause: Identifiable, Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        case all
        case discipline(UUID)
        case course(UUID)
    }

    var id = UUID()
    var start = Date()
    /// Planned or reached end; nil: until it is ended by hand.
    var end: Date?
    var scope: Scope = .all
    var reason = ""
    /// The due dates were moved on.
    var applied = false

    func isActive(at date: Date = Date()) -> Bool {
        !applied && start <= date && (end.map { date < $0 } ?? true)
    }

    func covers(_ course: LearningCourse) -> Bool {
        switch scope {
        case .all: true
        case .discipline(let id): course.discipline == id
        case .course(let id): course.id == id
        }
    }
}

extension LearningPause: Codable {
    private enum CodingKeys: String, CodingKey { case id, beginn, ende, bereich, disziplin, kurs, grund, angewandt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        start = c.soft(.beginn, Date())
        end = c.soft(.ende, Date?.none)
        switch c.soft(.bereich, "alles") {
        case "disziplin": scope = c.soft(.disziplin, UUID?.none).map(Scope.discipline) ?? .all
        case "kurs": scope = c.soft(.kurs, UUID?.none).map(Scope.course) ?? .all
        default: scope = .all
        }
        reason = c.soft(.grund, "")
        applied = c.soft(.angewandt, false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .beginn)
        try c.encodeIfPresent(end, forKey: .ende)
        switch scope {
        case .all: try c.encode("alles", forKey: .bereich)
        case .discipline(let id):
            try c.encode("disziplin", forKey: .bereich)
            try c.encode(id, forKey: .disziplin)
        case .course(let id):
            try c.encode("kurs", forKey: .bereich)
            try c.encode(id, forKey: .kurs)
        }
        try c.encode(reason, forKey: .grund)
        try c.encode(applied, forKey: .angewandt)
    }
}

/// `Lernen/lernen.json`: what is not one course.
struct LearningState: Codable, Hashable, Sendable {
    var disciplines: [LearningDiscipline] = []
    var settings = LearningSettings()
    var pauses: [LearningPause] = []

    private enum CodingKeys: String, CodingKey { case format, disziplinen, einstellungen, pausen }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disciplines = c.soft(.disziplinen, [LearningDiscipline]())
        settings = c.soft(.einstellungen, LearningSettings())
        pauses = c.soft(.pausen, [LearningPause]())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .format)
        try c.encode(disciplines, forKey: .disziplinen)
        try c.encode(settings, forKey: .einstellungen)
        try c.encode(pauses, forKey: .pausen)
    }
}
