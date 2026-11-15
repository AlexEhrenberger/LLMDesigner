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
    /// The lesson of the course it belongs to.
    var lesson: UUID?
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

    init(front: String = "", back: String = "", tags: [String] = [], material: UUID? = nil, lesson: UUID? = nil) {
        self.front = front
        self.back = back
        self.tags = tags
        self.material = material
        self.lesson = lesson
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
        case id, vorne, hinten, schlagwoerter, material, lektion, zustand, faellig, stabilitaet, schwierigkeit, faktor, intervall, schritt
        case wiederholungen, vergessen, zuletzt, zurueckgestellt, verlauf, erstellt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        front = c.soft(.vorne, "")
        back = c.soft(.hinten, "")
        tags = c.soft(.schlagwoerter, [String]())
        material = c.soft(.material, UUID?.none)
        lesson = c.soft(.lektion, UUID?.none)
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
        try c.encodeIfPresent(lesson, forKey: .lektion)
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
    /// The lesson it belongs to; nil: the whole course.
    var lesson: UUID?
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
    private enum CodingKeys: String, CodingKey { case id, art, titel, datei, url, zitat, text, zusammenfassung, lektion, hinzugefuegt }

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
        lesson = c.soft(.lektion, UUID?.none)
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
        try c.encodeIfPresent(lesson, forKey: .lektion)
        try c.encode(addedAt, forKey: .hinzugefuegt)
    }
}

/// One question of a quiz or a lesson test, with the person's answer and the model's verdict.
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

    /// An open question the model grades, or one with options the app grades by itself.
    enum Kind: String, Codable, Sendable {
        case open = "offen"
        case choice = "auswahl"
    }

    var id = UUID()
    var kind: Kind = .open
    var question: String
    /// Wissen, Verständnis or Anwendung (tests only).
    var level = ""
    /// The lesson's section it asks about (tests only).
    var section = ""
    /// The answers to choose from, already shuffled; `correctOption` points at the right one.
    var options: [String] = []
    var correctOption: Int?
    /// The option the person chose.
    var chosenOption: Int?
    /// What a good answer has to contain; the model grades against it.
    var expected = ""
    var answer = ""
    /// Answered (a test grades later, in the background).
    var answeredAt: Date?
    var verdict: Verdict?
    var feedback = ""
    /// What a full answer would have said.
    var solution = ""

    private enum CodingKeys: String, CodingKey {
        case id, art, frage, stufe, abschnitt, optionen, richtig, gewaehlt, erwartung, antwort, beantwortet, bewertung, rueckmeldung, loesung
    }

    init(question: String, kind: Kind = .open) {
        self.question = question
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        kind = c.soft(.art, Kind.open)
        question = c.soft(.frage, "")
        level = c.soft(.stufe, "")
        section = c.soft(.abschnitt, "")
        options = c.soft(.optionen, [String]())
        correctOption = c.soft(.richtig, Int?.none)
        chosenOption = c.soft(.gewaehlt, Int?.none)
        expected = c.soft(.erwartung, "")
        answer = c.soft(.antwort, "")
        answeredAt = c.soft(.beantwortet, Date?.none)
        verdict = c.soft(.bewertung, Verdict?.none)
        feedback = c.soft(.rueckmeldung, "")
        solution = c.soft(.loesung, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if kind != .open { try c.encode(kind, forKey: .art) }
        try c.encode(question, forKey: .frage)
        if !level.isEmpty { try c.encode(level, forKey: .stufe) }
        if !section.isEmpty { try c.encode(section, forKey: .abschnitt) }
        if !options.isEmpty { try c.encode(options, forKey: .optionen) }
        try c.encodeIfPresent(correctOption, forKey: .richtig)
        try c.encodeIfPresent(chosenOption, forKey: .gewaehlt)
        if !expected.isEmpty { try c.encode(expected, forKey: .erwartung) }
        try c.encode(answer, forKey: .antwort)
        try c.encodeIfPresent(answeredAt, forKey: .beantwortet)
        try c.encodeIfPresent(verdict, forKey: .bewertung)
        try c.encode(feedback, forKey: .rueckmeldung)
        try c.encode(solution, forKey: .loesung)
    }

    var isAnswered: Bool { answeredAt != nil || verdict != nil }

    /// The chosen option's text, or the written answer.
    var answerText: String {
        if let chosenOption, options.indices.contains(chosenOption) { return options[chosenOption] }
        return answer
    }

    var correctText: String? {
        guard let correctOption, options.indices.contains(correctOption) else { return nil }
        return options[correctOption]
    }
}

/// A test's grade: A best, F failed. The app computes it from the graded answers; the model explains it.
enum LessonGrade: String, Codable, CaseIterable, Sendable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F"

    /// A from 90 %, B 80, C 70, D 60, E 50 (passed, as in German exams), below that F.
    init(score: Double) {
        switch score {
        case 0.9...: self = .a
        case 0.8..<0.9: self = .b
        case 0.7..<0.8: self = .c
        case 0.6..<0.7: self = .d
        case 0.5..<0.6: self = .e
        default: self = .f
        }
    }

    var label: String {
        switch self {
        case .a: "hervorragend"
        case .b: "sehr gut"
        case .c: "gut"
        case .d: "befriedigend"
        case .e: "ausreichend"
        case .f: "nicht bestanden"
        }
    }

    /// The lowest score that still gets this grade.
    var threshold: Double {
        switch self {
        case .a: 0.9
        case .b: 0.8
        case .c: 0.7
        case .d: 0.6
        case .e: 0.5
        case .f: 0
        }
    }

    var passed: Bool { self != .f }
}

/// A quiz (the model asks one question after another) or a lesson test (many questions over a whole lesson, graded in
/// the background, with a grade and the model's assessment at the end).
struct QuizSession: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case quiz = "abfrage"
        case test
    }

    var id = UUID()
    var kind: Kind = .quiz
    var date = Date()
    /// The material it asked about; nil: all of it and the cards.
    var material: UUID?
    /// The lesson a test is about.
    var lesson: UUID?
    /// How many questions a test asks.
    var planned = 0
    var items: [QuizItem] = []
    var grade: LessonGrade?
    /// The model's assessment of where the person stands.
    var assessment = ""
    var finishedAt: Date?

    private enum CodingKeys: String, CodingKey { case id, art, datum, material, lektion, geplant, fragen, note, einschaetzung, beendet }

    init(material: UUID? = nil) {
        self.material = material
    }

    init(lesson: UUID, planned: Int) {
        kind = .test
        self.lesson = lesson
        self.planned = planned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        kind = c.soft(.art, Kind.quiz)
        date = c.soft(.datum, Date())
        material = c.soft(.material, UUID?.none)
        lesson = c.soft(.lektion, UUID?.none)
        planned = c.soft(.geplant, 0)
        items = c.soft(.fragen, [QuizItem]())
        grade = c.soft(.note, LessonGrade?.none)
        assessment = c.soft(.einschaetzung, "")
        finishedAt = c.soft(.beendet, Date?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if kind != .quiz { try c.encode(kind, forKey: .art) }
        try c.encode(date, forKey: .datum)
        try c.encodeIfPresent(material, forKey: .material)
        try c.encodeIfPresent(lesson, forKey: .lektion)
        if planned > 0 { try c.encode(planned, forKey: .geplant) }
        try c.encode(items, forKey: .fragen)
        try c.encodeIfPresent(grade, forKey: .note)
        if !assessment.isEmpty { try c.encode(assessment, forKey: .einschaetzung) }
        try c.encodeIfPresent(finishedAt, forKey: .beendet)
    }

    /// 0…1 over the graded questions.
    var score: Double? {
        let graded = items.compactMap(\.verdict)
        guard !graded.isEmpty else { return nil }
        return graded.map(\.points).reduce(0, +) / Double(graded.count)
    }

    var isTest: Bool { kind == .test }
    var answeredCount: Int { items.filter(\.isAnswered).count }
}

/// What the automatic creation of a lesson makes, step by step. A lesson remembers the steps that are done, so a
/// stopped creation goes on where it was.
enum LessonBuildStep: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The model reads the lesson's pages piece by piece and writes study notes (`Lesenotizen/`).
    case reading = "lesen"
    /// The detailed summary as a Writer document, and the abstract.
    case summary = "zusammenfassung"
    case cards = "karten"
    /// The content analysis of the summary (topics and how they connect).
    case analysis = "analyse"
    /// A presentation made from the summary, with a speaker card on every slide.
    case presentation = "praesentation"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reading: "Lesen"
        case .summary: "Zusammenfassung"
        case .cards: "Karteikarten"
        case .analysis: "Inhaltsanalyse"
        case .presentation: "Präsentation"
        }
    }
}

/// A part of a lesson (a chapter like "1.1 Definitionen") with its pages in the PDF.
struct LessonSection: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    /// Pages of the lesson's PDF, counted from 1, both included.
    var firstPage: Int?
    var lastPage: Int?
}

extension LessonSection: Codable {
    private enum CodingKeys: String, CodingKey { case id, titel, von, bis }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        title = c.soft(.titel, "")
        firstPage = c.soft(.von, Int?.none)
        lastPage = c.soft(.bis, Int?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encodeIfPresent(firstPage, forKey: .von)
        try c.encodeIfPresent(lastPage, forKey: .bis)
    }
}

/// A lesson of a course: its abstract, its parts and pages, the documents made from it, and the cards that belong to it
/// (cards point at their lesson).
struct LearningLesson: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    /// A short summary shown when the lesson is opened.
    var abstract = ""
    /// What the person should be able to do afterwards (from the script's "Lernziele").
    var goals: [String] = []
    var sections: [LessonSection] = []
    /// The PDF (a material of the course) and the lesson's pages in it.
    var material: UUID?
    var firstPage: Int?
    var lastPage: Int?
    /// The detailed summary (a Writer document) and the presentation made from it.
    var summaryDocument: UUID?
    var presentation: UUID?
    /// Further documents, presentations, notes and chats that belong to the lesson.
    var links: [ProjectRef] = []
    var built: Set<LessonBuildStep> = []
    var createdAt = Date()

    init(title: String = "", abstract: String = "") {
        self.title = title
        self.abstract = abstract
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Neue Lektion" : trimmed
    }

    var pageLabel: String? {
        guard let firstPage else { return nil }
        guard let lastPage, lastPage != firstPage else { return "S. \(firstPage)" }
        return "S. \(firstPage)–\(lastPage)"
    }
}

extension LearningLesson: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, abstract, lernziele, abschnitte, material, von, bis, zusammenfassung, praesentation, verknuepft, erstellt, angelegt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        title = c.soft(.titel, "")
        abstract = c.soft(.abstract, "")
        goals = c.soft(.lernziele, [String]())
        sections = c.soft(.abschnitte, [LessonSection]())
        material = c.soft(.material, UUID?.none)
        firstPage = c.soft(.von, Int?.none)
        lastPage = c.soft(.bis, Int?.none)
        summaryDocument = c.soft(.zusammenfassung, UUID?.none)
        presentation = c.soft(.praesentation, UUID?.none)
        links = c.soft(.verknuepft, [ProjectRef]())
        // Unknown steps (from a newer version) are dropped one by one, not the whole list.
        built = Set(c.soft(.erstellt, [String]()).compactMap(LessonBuildStep.init(rawValue:)))
        createdAt = c.soft(.angelegt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(abstract, forKey: .abstract)
        if !goals.isEmpty { try c.encode(goals, forKey: .lernziele) }
        try c.encode(sections, forKey: .abschnitte)
        try c.encodeIfPresent(material, forKey: .material)
        try c.encodeIfPresent(firstPage, forKey: .von)
        try c.encodeIfPresent(lastPage, forKey: .bis)
        try c.encodeIfPresent(summaryDocument, forKey: .zusammenfassung)
        try c.encodeIfPresent(presentation, forKey: .praesentation)
        if !links.isEmpty { try c.encode(links, forKey: .verknuepft) }
        // In the order of the steps, so the file doesn't change with Set's order.
        try c.encode(LessonBuildStep.allCases.filter(built.contains).map(\.rawValue), forKey: .erstellt)
        try c.encode(createdAt, forKey: .angelegt)
    }
}

/// What the model wrote down while it read a lesson's pages, piece by piece; the summary, cards and test questions are
/// made from these short notes, not from the long PDF text (a small model reads a few pages reliably, not fifty).
struct LessonNotes: Hashable, Sendable {
    struct Section: Hashable, Sendable {
        var section: UUID?
        var title = ""
        /// How many pieces the section's text was cut into; the section is read when there is a note for each.
        var pieces = 0
        var notes: [String] = []

        var isComplete: Bool { pieces > 0 && notes.count >= pieces }
        var text: String { notes.joined(separator: "\n\n") }
    }

    var lesson: UUID
    var sections: [Section] = []

    func section(_ id: UUID?) -> Section? { sections.first { $0.section == id } }

    var characterCount: Int { sections.reduce(0) { $0 + $1.notes.reduce(0) { $0 + $1.count } } }
}

extension LessonNotes: Codable {
    private enum CodingKeys: String, CodingKey { case format, lektion, abschnitte }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lesson = try c.decode(UUID.self, forKey: .lektion)
        sections = c.soft(.abschnitte, [Section]())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .format)
        try c.encode(lesson, forKey: .lektion)
        try c.encode(sections, forKey: .abschnitte)
    }
}

extension LessonNotes.Section: Codable {
    private enum CodingKeys: String, CodingKey { case abschnitt, titel, stuecke, notizen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = c.soft(.abschnitt, UUID?.none)
        title = c.soft(.titel, "")
        pieces = c.soft(.stuecke, 0)
        notes = c.soft(.notizen, [String]())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(section, forKey: .abschnitt)
        try c.encode(title, forKey: .titel)
        try c.encode(pieces, forKey: .stuecke)
        try c.encode(notes, forKey: .notizen)
    }
}

/// What the automatic creation makes for every lesson.
struct CourseBuildOptions: Hashable, Sendable {
    var summary = true
    var cards = true
    var cardsPerSection = 5
    var analysis = true
    var presentation = true
    /// A speaker card for every slide, for the presentation spoken by the model.
    var speakerNotes = true

    /// The steps these options call for, in the order they are made.
    var steps: [LessonBuildStep] {
        var steps: [LessonBuildStep] = [.reading]
        // Cards, the analysis and the presentation are made from the summary or the notes; the summary comes first.
        if summary || analysis || presentation { steps.append(.summary) }
        if cards { steps.append(.cards) }
        if analysis { steps.append(.analysis) }
        if presentation { steps.append(.presentation) }
        return steps
    }
}

extension CourseBuildOptions: Codable {
    private enum CodingKeys: String, CodingKey { case zusammenfassung, karten, kartenJeAbschnitt, analyse, praesentation, moderatorenkarten }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.soft(.zusammenfassung, true)
        cards = c.soft(.karten, true)
        cardsPerSection = min(12, max(1, c.soft(.kartenJeAbschnitt, 5)))
        analysis = c.soft(.analyse, true)
        presentation = c.soft(.praesentation, true)
        speakerNotes = c.soft(.moderatorenkarten, true)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .zusammenfassung)
        try c.encode(cards, forKey: .karten)
        try c.encode(cardsPerSection, forKey: .kartenJeAbschnitt)
        try c.encode(analysis, forKey: .analyse)
        try c.encode(presentation, forKey: .praesentation)
        try c.encode(speakerNotes, forKey: .moderatorenkarten)
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
    /// Credit points (ECTS) and the form of the exam, shown after the name: "Statistik (5 CP, Klausur)".
    var creditPoints: Int?
    var examForm = ""
    /// The course's structure, in order.
    var lessons: [LearningLesson] = []
    var cards: [LearningCard] = []
    var materials: [LearningMaterial] = []
    /// Chats, documents, presentations, notes and parts of novel worlds that belong to the course.
    var links: [ProjectRef] = []
    var projects: [UUID] = []
    var quizzes: [QuizSession] = []
    /// The sidebar folder the automatic creation puts the course's documents in.
    var documentFolder: UUID?
    /// What the automatic creation was last asked to make.
    var buildOptions: CourseBuildOptions?
    var finished = false
    var createdAt = Date()
    var updatedAt = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Neuer Kurs" : trimmed
    }

    /// "Statistik (5 CP, Klausur)"; without points and exam form only the name.
    var titleWithFacts: String {
        var facts: [String] = []
        if let creditPoints, creditPoints > 0 { facts.append("\(creditPoints) CP") }
        let form = examForm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !form.isEmpty { facts.append(form) }
        return facts.isEmpty ? displayName : "\(displayName) (\(facts.joined(separator: ", ")))"
    }

    func card(_ id: UUID) -> LearningCard? { cards.first { $0.id == id } }

    func material(_ id: UUID) -> LearningMaterial? { materials.first { $0.id == id } }

    func lesson(_ id: UUID?) -> LearningLesson? {
        guard let id else { return nil }
        return lessons.first { $0.id == id }
    }

    /// "Lektion 2" for the second lesson.
    func lessonNumber(_ id: UUID) -> Int? { lessons.firstIndex { $0.id == id }.map { $0 + 1 } }

    func cards(of lessonID: UUID) -> [LearningCard] { cards.filter { $0.lesson == lessonID } }

    /// The lesson's tests, newest last.
    func tests(of lessonID: UUID) -> [QuizSession] { quizzes.filter { $0.isTest && $0.lesson == lessonID } }

    /// The newest finished test's grade.
    func latestGrade(of lessonID: UUID) -> QuizSession? {
        tests(of: lessonID).last { $0.grade != nil }
    }

    mutating func updateCard(_ id: UUID, _ change: (inout LearningCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    mutating func updateLesson(_ id: UUID, _ change: (inout LearningLesson) -> Void) {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { return }
        change(&lessons[index])
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query)
            || lessons.contains { $0.title.localizedCaseInsensitiveContains(query) }
            || cards.contains { $0.matches(query) } || materials.contains { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }
}

extension LearningCourse: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, disziplin, name, beschreibung, symbol, farbe, pruefung, cp, pruefungsform, lektionen, karten, material, verknuepft, projekte, abfragen
        case ordner, erstellung, abgeschlossen, erstellt, geaendert
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
        creditPoints = c.soft(.cp, Int?.none)
        examForm = c.soft(.pruefungsform, "")
        lessons = c.soft(.lektionen, [LearningLesson]())
        cards = c.soft(.karten, [LearningCard]())
        materials = c.soft(.material, [LearningMaterial]())
        links = c.soft(.verknuepft, [ProjectRef]())
        projects = c.soft(.projekte, [UUID]())
        quizzes = c.soft(.abfragen, [QuizSession]())
        documentFolder = c.soft(.ordner, UUID?.none)
        buildOptions = c.soft(.erstellung, CourseBuildOptions?.none)
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
        try c.encodeIfPresent(creditPoints, forKey: .cp)
        if !examForm.isEmpty { try c.encode(examForm, forKey: .pruefungsform) }
        try c.encode(lessons, forKey: .lektionen)
        try c.encode(cards, forKey: .karten)
        try c.encode(materials, forKey: .material)
        try c.encode(links, forKey: .verknuepft)
        try c.encode(projects, forKey: .projekte)
        try c.encode(quizzes, forKey: .abfragen)
        try c.encodeIfPresent(documentFolder, forKey: .ordner)
        try c.encodeIfPresent(buildOptions, forKey: .erstellung)
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
