import Foundation

// Stories Studio plans novels. A novel world (Romanwelt, e.g. a fantasy saga) holds books; a book has acts, an
// act chapters, a chapter sections. Each of these parts says what happens (events), with whom (figures), where
// (places), why (reasons) and to what end (literary purposes). The elements themselves are kept once per world
// and only linked from the parts, so a figure is written up in one place and appears wherever it is used.

/// The kinds of elements a world keeps: first the five a part answers its questions with, then species (the beings
/// that live in the world) and facts (tagged notes, e.g. on the world's history).
enum StoryElementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case event, figure, place, reason, purpose, species, fact

    var id: String { rawValue }

    /// The order of the navigator (the user's own order).
    static let listOrder: [StoryElementKind] = [.figure, .species, .place, .event, .reason, .purpose, .fact]

    /// The kinds a part answers its five questions with, in the order of the questions.
    static let questions: [StoryElementKind] = [.event, .figure, .place, .reason, .purpose]

    var title: String {
        switch self {
        case .event: "Events"
        case .figure: "Figuren"
        case .place: "Orte"
        case .reason: "Reasons"
        case .purpose: "Purposes"
        case .species: "Spezies"
        case .fact: "Fakten"
        }
    }

    var singular: String {
        switch self {
        case .event: "Event"
        case .figure: "Figur"
        case .place: "Ort"
        case .reason: "Reason"
        case .purpose: "Purpose"
        case .species: "Spezies"
        case .fact: "Fakt"
        }
    }

    /// The question a part answers with this kind.
    var question: String {
        switch self {
        case .event: "Was"
        case .figure: "Mit wem"
        case .place: "Wo"
        case .reason: "Warum"
        case .purpose: "Wozu"
        case .species: "Wesen"
        case .fact: "Wissen"
        }
    }

    var prompt: String {
        switch self {
        case .event: "Was passiert?"
        case .figure: "Wer ist dabei, wer handelt, wer leidet?"
        case .place: "Wo spielt es, und wie wirkt der Ort?"
        case .reason: "Warum geschieht es – welche Annahmen und Gründe tragen es?"
        case .purpose: "Wozu dient es der Geschichte – was soll es bei den Leser:innen bewirken?"
        case .species: "Welche Wesen kommen vor?"
        case .fact: "Was ist darüber bekannt?"
        }
    }

    var symbol: String {
        switch self {
        case .event: "bolt.fill"
        case .figure: "person.fill"
        case .place: "mappin.and.ellipse"
        case .reason: "point.3.connected.trianglepath.dotted"
        case .purpose: "scope"
        case .species: "pawprint.fill"
        case .fact: "note.text"
        }
    }

    /// Kinds that can be pinned to a timeline.
    static let pinnable: [StoryElementKind] = [.event, .figure, .place]
}

/// A link to one element of the world.
struct StoryRef: Hashable, Codable, Sendable {
    var kind: StoryElementKind
    var id: UUID
}

// MARK: - Parts

/// Book, act, chapter, section: each level holds the next.
enum StoryPartLevel: String, Codable, CaseIterable, Sendable {
    case book, act, chapter, section

    var label: String {
        switch self {
        case .book: "Buch"
        case .act: "Akt"
        case .chapter: "Kapitel"
        case .section: "Abschnitt"
        }
    }

    var plural: String {
        switch self {
        case .book: "Bücher"
        case .act: "Akte"
        case .chapter: "Kapitel"
        case .section: "Abschnitte"
        }
    }

    var symbol: String {
        switch self {
        case .book: "book.closed"
        case .act: "theatermasks"
        case .chapter: "doc.plaintext"
        case .section: "text.alignleft"
        }
    }

    var child: StoryPartLevel? {
        switch self {
        case .book: .act
        case .act: .chapter
        case .chapter: .section
        case .section: nil
        }
    }

    /// Sections are too small for a timeline of their own.
    var hasTimeline: Bool { self != .section }

    /// Chapters and sections are told from someone's point of view.
    var hasPointOfView: Bool { self == .chapter || self == .section }
}

/// What kind of book it is within the world.
enum BookKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case main, side, history, novella, anthology, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .main: "Hauptroman"
        case .side: "Nebenroman"
        case .history: "Fiktionales Historienbuch"
        case .novella: "Novelle"
        case .anthology: "Kurzgeschichten"
        case .other: "Sonstiges"
        }
    }

    var symbol: String {
        switch self {
        case .main: "book.closed.fill"
        case .side: "book.closed"
        case .history: "scroll"
        case .novella: "book.pages"
        case .anthology: "books.vertical"
        case .other: "book"
        }
    }
}

/// How far a part has come.
enum DraftStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case idea, outlined, draft, revised, done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idea: "Idee"
        case .outlined: "Skizziert"
        case .draft: "Entwurf"
        case .revised: "Überarbeitet"
        case .done: "Fertig"
        }
    }

    var symbol: String {
        switch self {
        case .idea: "lightbulb"
        case .outlined: "list.bullet.indent"
        case .draft: "pencil"
        case .revised: "pencil.and.outline"
        case .done: "checkmark.seal"
        }
    }
}

/// The five questions of a part: a few words for each and the elements that answer it.
struct StoryFocus: Hashable, Codable, Sendable {
    var texts: [StoryElementKind: String] = [:]
    var links: [StoryElementKind: [UUID]] = [:]

    func text(_ kind: StoryElementKind) -> String { texts[kind] ?? "" }

    func ids(_ kind: StoryElementKind) -> [UUID] { links[kind] ?? [] }

    mutating func setText(_ text: String, for kind: StoryElementKind) {
        texts[kind] = text.isEmpty ? nil : text
    }

    mutating func link(_ id: UUID, as kind: StoryElementKind) {
        guard !ids(kind).contains(id) else { return }
        links[kind, default: []].append(id)
    }

    mutating func unlink(_ id: UUID, as kind: StoryElementKind) {
        links[kind]?.removeAll { $0 == id }
        if links[kind]?.isEmpty == true { links[kind] = nil }
    }

    var isEmpty: Bool { texts.values.allSatisfy(\.isEmpty) && links.values.allSatisfy(\.isEmpty) }
}

/// A book, act, chapter or section.
struct StoryPart: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var level: StoryPartLevel
    var title = ""
    /// Books only.
    var subtitle = ""
    var bookKind: BookKind = .main
    var status: DraftStatus = .idea
    var focus = StoryFocus()
    /// Chapters and sections: whose eyes the reader sees through.
    var povFigureID: UUID?
    /// The Writer Studio document with this part's text. The world keeps the plan, the document the prose.
    var manuscriptID: UUID?
    var notes = ""
    var timeline = StoryTimeline()
    /// Books only: pictures with a short description.
    var gallery: [StoryImage] = []
    var children: [StoryPart] = []
    var createdAt = Date()
    var updatedAt = Date()

    init(level: StoryPartLevel, title: String = "") {
        self.level = level
        self.title = title
    }
}

// MARK: - World

/// A novel world: its books, its elements and the timeline of its history.
struct StoryWorld: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var title = ""
    var genre = ""
    /// The premise in a sentence or two.
    var logline = ""
    var overview = ""
    /// How the world works: magic, faith, power, technology.
    var rules = ""
    var themes = ""
    /// The calendar of the world's own timeline and of every timeline that has none of its own.
    var calendar = TimelineScale()
    var timeline = StoryTimeline()
    var books: [StoryPart] = []
    var figures: [StoryFigure] = []
    var places: [StoryPlace] = []
    var events: [StoryEvent] = []
    var reasons: [StoryReason] = []
    var purposes: [StoryPurpose] = []
    var species: [StorySpecies] = []
    var facts: [StoryFact] = []
    /// Pictures of the world with a short description each.
    var gallery: [StoryImage] = []
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String = "") {
        self.title = title
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Unbenannte Romanwelt" : title }
}

// MARK: - Images

/// A picture of a figure, place, species or fact, or one of a gallery, copied into the library
/// (`Geschichten/Bilder/<Welt>/`).
struct StoryImage: Hashable, Codable, Sendable {
    var fileName: String
    var caption = ""

    init(fileName: String, caption: String = "") {
        self.fileName = fileName
        self.caption = caption
    }
}

// MARK: - Coding

// The files are read leniently: a field that is missing (an older file, or one written by hand) or that holds
// a value this version doesn't know keeps its default, so fields can be added later without a migration.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// The five kinds are the keys of a part's questions in the file.
extension StoryElementKind: CodingKeyRepresentable {}

extension StoryFocus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        texts = c.lenient(.texts, [:])
        links = c.lenient(.links, [:])
    }
}

extension StoryPart {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(level: c.lenient(.level, .chapter))
        id = try c.decode(UUID.self, forKey: .id)
        title = c.lenient(.title, title)
        subtitle = c.lenient(.subtitle, subtitle)
        bookKind = c.lenient(.bookKind, bookKind)
        status = c.lenient(.status, status)
        focus = c.lenient(.focus, focus)
        povFigureID = c.lenient(.povFigureID, povFigureID)
        manuscriptID = c.lenient(.manuscriptID, manuscriptID)
        notes = c.lenient(.notes, notes)
        timeline = c.lenient(.timeline, timeline)
        gallery = c.lenient(.gallery, gallery)
        children = c.lenient(.children, children)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryWorld {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        title = c.lenient(.title, title)
        genre = c.lenient(.genre, genre)
        logline = c.lenient(.logline, logline)
        overview = c.lenient(.overview, overview)
        rules = c.lenient(.rules, rules)
        themes = c.lenient(.themes, themes)
        calendar = c.lenient(.calendar, calendar)
        timeline = c.lenient(.timeline, timeline)
        books = c.lenient(.books, books)
        figures = c.lenient(.figures, figures)
        places = c.lenient(.places, places)
        events = c.lenient(.events, events)
        reasons = c.lenient(.reasons, reasons)
        purposes = c.lenient(.purposes, purposes)
        species = c.lenient(.species, species)
        facts = c.lenient(.facts, facts)
        gallery = c.lenient(.gallery, gallery)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryImage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fileName: try c.decode(String.self, forKey: .fileName), caption: c.lenient(.caption, ""))
    }
}

/// A video of a figure (a character video card), copied into the library (`Geschichten/Videos/<Welt>/`).
struct StoryVideo: Hashable, Codable, Sendable {
    var fileName: String
    var caption = ""

    init(fileName: String, caption: String = "") {
        self.fileName = fileName
        self.caption = caption
    }
}

extension StoryVideo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fileName: try c.decode(String.self, forKey: .fileName), caption: c.lenient(.caption, ""))
    }
}
