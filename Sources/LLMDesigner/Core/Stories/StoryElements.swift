import Foundation

/// What the five kinds of elements share, so lists, pickers and links work the same for all of them.
protocol StoryElement: Identifiable, Hashable, Codable, Sendable where ID == UUID {
    static var kind: StoryElementKind { get }
    /// Where the world keeps elements of this kind.
    static var collection: WritableKeyPath<StoryWorld, [Self]> { get }
    var id: UUID { get }
    /// The name of a figure, place or event; the title of a reason or purpose.
    var name: String { get set }
    /// One line under the name in lists.
    var subtitle: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get set }
    init()
}

extension StoryElement {
    var ref: StoryRef { StoryRef(kind: Self.kind, id: id) }

    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "\(Self.kind.singular) ohne Namen" : name
    }
}

// MARK: - Figure

enum FigureRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, protagonist, antagonist, deuteragonist, mentor, supporting, minor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Ohne Rolle"
        case .protagonist: "Protagonist:in"
        case .antagonist: "Antagonist:in"
        case .deuteragonist: "Zweite Hauptfigur"
        case .mentor: "Mentor:in"
        case .supporting: "Nebenfigur"
        case .minor: "Randfigur"
        }
    }
}

/// The four Myers-Briggs preferences and how the figure reacts to growing stress. Each axis runs from -1 (the
/// first pole) to 1 (the second); nil means it is still open.
struct PersonalityProfile: Hashable, Codable, Sendable {
    enum Axis: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
        case energy, perception, decisions, lifestyle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .energy: "Energiequelle"
            case .perception: "Wahrnehmung"
            case .decisions: "Entscheidungen"
            case .lifestyle: "Lebensstil"
            }
        }

        var poles: (String, String) {
            switch self {
            case .energy: ("Extraversion", "Introversion")
            case .perception: ("Sensorik", "Intuition")
            case .decisions: ("Denken", "Fühlen")
            case .lifestyle: ("Beurteilend", "Wahrnehmend")
            }
        }

        var letters: (Character, Character) {
            switch self {
            case .energy: ("E", "I")
            case .perception: ("S", "N")
            case .decisions: ("T", "F")
            case .lifestyle: ("J", "P")
            }
        }

        var hint: String {
            switch self {
            case .energy: "Woraus schöpft die Figur Kraft – aus Menschen und Tun oder aus Rückzug und Innenleben?"
            case .perception: "Achtet sie auf Fakten und das Konkrete oder auf Muster, Ahnungen und Möglichkeiten?"
            case .decisions: "Entscheidet sie nach Logik und Prinzip oder nach Werten und Beziehungen?"
            case .lifestyle: "Plant und schließt sie ab, oder hält sie sich alles offen und improvisiert?"
            }
        }
    }

    var values: [Axis: Double] = [:]
    var notes: [Axis: String] = [:]
    /// 0: gelassen, bleibt unter Druck stabil (Assertive) … 1: neurotisch, gerät ins Wanken (Turbulent).
    var neuroticism: Double?
    var stressNote = ""

    /// "INTJ-T", with "x" for open axes; empty while nothing is set.
    var code: String {
        guard !values.isEmpty || neuroticism != nil else { return "" }
        let letters = Axis.allCases.map { axis -> String in
            guard let value = values[axis] else { return "x" }
            return String(value <= 0 ? axis.letters.0 : axis.letters.1)
        }.joined()
        guard let neuroticism else { return letters }
        return letters + (neuroticism < 0.5 ? "-A" : "-T")
    }

    /// Keirsey's temperament, which needs perception and the axis that goes with it.
    var temperament: String? {
        guard let perception = values[.perception] else { return nil }
        if perception > 0 {
            guard let decisions = values[.decisions] else { return nil }
            return decisions <= 0 ? "Rationalist (NT)" : "Idealist (NF)"
        }
        guard let lifestyle = values[.lifestyle] else { return nil }
        return lifestyle <= 0 ? "Bewahrer (SJ)" : "Handwerker (SP)"
    }

    var isEmpty: Bool { values.isEmpty && notes.values.allSatisfy(\.isEmpty) && neuroticism == nil && stressNote.isEmpty }
}

/// How a figure stands towards another figure, an event or a place.
struct StoryRelation: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var target: StoryRef
    /// -2 feindlich … 2 loyal.
    var attitude = 0
    /// "Bruder", "Rivalin", "Lehnsherr", "Schuld an …".
    var label = ""
    var note = ""

    static let attitudes: [(value: Int, label: String)] = [(-2, "Feindlich"), (-1, "Ablehnend"), (0, "Neutral"), (1, "Zugetan"), (2, "Loyal")]

    static func attitudeLabel(_ value: Int) -> String {
        attitudes.first { $0.value == value }?.label ?? "Neutral"
    }
}

/// An entry of the figure's scene book.
struct SceneNote: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case quote, scene, incident

        var id: String { rawValue }

        var label: String {
            switch self {
            case .quote: "Zitat"
            case .scene: "Beispielszene"
            case .incident: "Vorkommnis"
            }
        }

        var plural: String {
            switch self {
            case .quote: "Zitate"
            case .scene: "Beispielszenen"
            case .incident: "Vorkommnisse"
            }
        }

        var symbol: String {
            switch self {
            case .quote: "quote.opening"
            case .scene: "film"
            case .incident: "exclamationmark.bubble"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var text = ""
    /// Where in the story it belongs (a book, act, chapter or section).
    var partID: UUID?
    var createdAt = Date()

    init(kind: Kind, text: String = "") {
        self.kind = kind
        self.text = text
    }
}

struct StoryFigure: StoryElement {
    static let kind = StoryElementKind.figure
    static let collection: WritableKeyPath<StoryWorld, [StoryFigure]> = \.figures

    var id = UUID()
    var name = ""
    /// Title or byname: "die Mutter der Drachen".
    var epithet = ""
    var role: FigureRole = .none
    var images: [StoryImage] = []
    var birth = ""
    var origin = ""
    /// Biographical stations as one block; a fantasy life doesn't fit a CV.
    var biography = ""
    var appearance = ""
    var behavior = ""
    var secrets = ""
    var wants = ""
    var needs = ""
    var coreConflict = ""
    var fears = ""
    var development = ""
    var personality = PersonalityProfile()
    var persona = ""
    var politics = ""
    var relations: [StoryRelation] = []
    var voice = ""
    var perception = ""
    var scenes: [SceneNote] = []
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    var subtitle: String {
        if !epithet.isEmpty { return epithet }
        return role == .none ? "" : role.label
    }
}

// MARK: - Place

enum PlaceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case world, realm, region, city, castle, building, landscape, water, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .world: "Kontinent / Welt"
        case .realm: "Reich / Land"
        case .region: "Region"
        case .city: "Stadt / Siedlung"
        case .castle: "Burg / Festung"
        case .building: "Gebäude / Raum"
        case .landscape: "Landschaft"
        case .water: "Gewässer"
        case .other: "Sonstiger Ort"
        }
    }

    var symbol: String {
        switch self {
        case .world: "globe.europe.africa"
        case .realm: "flag"
        case .region: "map"
        case .city: "building.2"
        case .castle: "building.columns"
        case .building: "house"
        case .landscape: "mountain.2"
        case .water: "water.waves"
        case .other: "mappin"
        }
    }
}

struct StoryPlace: StoryElement {
    static let kind = StoryElementKind.place
    static let collection: WritableKeyPath<StoryWorld, [StoryPlace]> = \.places

    var id = UUID()
    var name = ""
    var placeKind: PlaceKind = .other
    /// The place this one lies in: Winterfell in the North, the North in Westeros.
    var parentID: UUID?
    var images: [StoryImage] = []
    /// What one sees, hears and smells there; the mood it gives a scene.
    var atmosphere = ""
    var geography = ""
    var history = ""
    /// Who rules, who lives there, what they live on.
    var society = ""
    var residentIDs: [UUID] = []
    /// What the place stands for in the story.
    var significance = ""
    var secrets = ""
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    var subtitle: String { placeKind == .other ? "" : placeKind.label }
}

// MARK: - Event

enum EventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case turningPoint, conflict, political, personal, revelation, catastrophe, ritual, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .turningPoint: "Wendepunkt"
        case .conflict: "Konflikt / Schlacht"
        case .political: "Politisch"
        case .personal: "Persönlich"
        case .revelation: "Enthüllung"
        case .catastrophe: "Katastrophe / Natur"
        case .ritual: "Fest / Ritual"
        case .other: "Sonstiges"
        }
    }
}

/// Who knows that it happened, or how it really happened.
enum EventKnowledge: String, Codable, CaseIterable, Identifiable, Sendable {
    case open, rumour, secret

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "Allgemein bekannt"
        case .rumour: "Gerücht"
        case .secret: "Geheim"
        }
    }
}

/// One consequence of an event: where it reaches, how soon, whom it touches, and which event it leads to.
struct EventConsequence: Identifiable, Hashable, Codable, Sendable {
    enum Area: String, Codable, CaseIterable, Identifiable, Sendable {
        case power, society, personal, economy, war, faith, nature

        var id: String { rawValue }

        var label: String {
            switch self {
            case .power: "Macht & Politik"
            case .society: "Gesellschaft"
            case .personal: "Persönlich"
            case .economy: "Wirtschaft"
            case .war: "Krieg & Gewalt"
            case .faith: "Glaube & Magie"
            case .nature: "Natur & Welt"
            }
        }
    }

    enum Reach: String, Codable, CaseIterable, Identifiable, Sendable {
        case immediate, medium, long

        var id: String { rawValue }

        var label: String {
            switch self {
            case .immediate: "Sofort"
            case .medium: "Mittelfristig"
            case .long: "Langfristig"
            }
        }
    }

    var id = UUID()
    var area: Area = .power
    var reach: Reach = .immediate
    var text = ""
    /// Figures and places it touches.
    var affected: [StoryRef] = []
    /// The event this consequence turns into.
    var followEventID: UUID?
}

struct StoryEvent: StoryElement {
    static let kind = StoryElementKind.event
    static let collection: WritableKeyPath<StoryWorld, [StoryEvent]> = \.events

    var id = UUID()
    var name = ""
    var eventKind: EventKind = .other
    /// When, in words of the world ("im letzten Sommer vor dem langen Winter").
    var when = ""
    var placeIDs: [UUID] = []
    var figureIDs: [UUID] = []
    /// What happens, step by step.
    var course = ""
    var causes = ""
    /// Events that lead to this one (besides those whose consequences name it).
    var causeEventIDs: [UUID] = []
    var consequences: [EventConsequence] = []
    var knowledge: EventKnowledge = .open
    var knownByIDs: [UUID] = []
    var significance = ""
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    var subtitle: String { eventKind == .other ? when : eventKind.label }
}

// MARK: - Reason

/// A sentence of an argument, and whether it holds in the world: a figure may act on a false assumption.
struct ReasonStatement: Identifiable, Hashable, Codable, Sendable {
    enum Validity: String, Codable, CaseIterable, Identifiable, Sendable {
        case open, holds, mistaken

        var id: String { rawValue }

        var label: String {
            switch self {
            case .open: "Offen"
            case .holds: "Stimmt"
            case .mistaken: "Irrtum"
            }
        }

        var symbol: String {
            switch self {
            case .open: "questionmark.circle"
            case .holds: "checkmark.circle"
            case .mistaken: "xmark.octagon"
            }
        }
    }

    var id = UUID()
    var text = ""
    var validity: Validity = .open

    init(text: String = "") {
        self.text = text
    }
}

/// Why something happens, written as an argument: assumptions (often unspoken), premises, conclusion.
struct StoryReason: StoryElement {
    static let kind = StoryElementKind.reason
    static let collection: WritableKeyPath<StoryWorld, [StoryReason]> = \.reasons

    var id = UUID()
    var name = ""
    /// Whose reasoning it is; nil: the logic of the world or of the narrator.
    var holderID: UUID?
    var assumptions: [ReasonStatement] = []
    var premises: [ReasonStatement] = []
    var conclusion = ""
    /// Where the argument is weak: a counter-argument, a plot hole to close.
    var weakness = ""
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    var subtitle: String { conclusion.split(separator: "\n").first.map(String.init) ?? "" }

    var mistakenCount: Int { (assumptions + premises).filter { $0.validity == .mistaken }.count }
}

// MARK: - Purpose

/// The literary function a part or element serves.
enum LiteraryFunction: String, Codable, CaseIterable, Identifiable, Sendable {
    case exposition, tension, turningPoint, foreshadowing, characterization, worldbuilding, theme,
         redHerring, retardation, relief, contrast, climax, resolution, catharsis, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposition: "Exposition"
        case .tension: "Spannungsaufbau"
        case .turningPoint: "Wendepunkt"
        case .foreshadowing: "Vorausdeutung"
        case .characterization: "Charakterisierung"
        case .worldbuilding: "Weltenbau"
        case .theme: "Thema & Motiv"
        case .redHerring: "Falsche Fährte"
        case .retardation: "Retardierendes Moment"
        case .relief: "Komische Entlastung"
        case .contrast: "Spiegelung & Kontrast"
        case .climax: "Höhepunkt"
        case .resolution: "Auflösung"
        case .catharsis: "Katharsis"
        case .other: "Eigener Zweck"
        }
    }

    var explanation: String {
        switch self {
        case .exposition: "Führt in Welt, Figuren und Ausgangslage ein, damit die Leser:innen Halt finden."
        case .tension: "Erhöht den Druck: Ziele geraten in Gefahr, Fragen bleiben offen, die Zeit wird knapp."
        case .turningPoint: "Dreht die Richtung der Handlung; danach ist nichts mehr wie vorher."
        case .foreshadowing: "Deutet Späteres an – ein Versprechen, das später eingelöst werden muss."
        case .characterization: "Zeigt, wer eine Figur ist, durch das, was sie tut, sagt oder verschweigt."
        case .worldbuilding: "Macht Regeln, Geschichte und Kultur der Welt erfahrbar."
        case .theme: "Trägt das Thema oder ein wiederkehrendes Motiv der Geschichte."
        case .redHerring: "Lenkt bewusst auf eine falsche Spur, damit die Wahrheit später trifft."
        case .retardation: "Verzögert die Lösung kurz vor dem Ziel und hält so die Spannung."
        case .relief: "Gibt nach schwerer Spannung Luft – damit das Nächste wieder wirken kann."
        case .contrast: "Stellt Figuren, Orte oder Wege nebeneinander, die sich spiegeln oder widersprechen."
        case .climax: "Der Punkt höchster Spannung, an dem der Konflikt entschieden wird."
        case .resolution: "Löst Fragen auf und zeigt, was nach dem Konflikt bleibt."
        case .catharsis: "Erlöst angestaute Gefühle – Trauer, Furcht oder Mitleid finden ein Ende."
        case .other: "Ein Zweck, der in keine Schublade passt."
        }
    }
}

struct StoryPurpose: StoryElement {
    static let kind = StoryElementKind.purpose
    static let collection: WritableKeyPath<StoryWorld, [StoryPurpose]> = \.purposes

    var id = UUID()
    var name = ""
    var function: LiteraryFunction = .other
    /// What it should achieve in the story.
    var intent = ""
    /// What the readers should feel or think.
    var readerEffect = ""
    var theme = ""
    /// Parts where it is set up and where it pays off (Chekhov's gun).
    var setupPartIDs: [UUID] = []
    var payoffPartIDs: [UUID] = []
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    var subtitle: String { function == .other ? "" : function.label }

    /// Set up somewhere but never paid off.
    var isOpenPromise: Bool { !setupPartIDs.isEmpty && payoffPartIDs.isEmpty }
}

// MARK: - Coding (lenient, see StoryModel.swift)

extension PersonalityProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = c.lenient(.values, [:])
        notes = c.lenient(.notes, [:])
        neuroticism = c.lenient(.neuroticism, Double?.none)
        stressNote = c.lenient(.stressNote, "")
    }
}

extension StoryRelation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try c.decode(StoryRef.self, forKey: .target))
        id = c.lenient(.id, id)
        attitude = c.lenient(.attitude, 0)
        label = c.lenient(.label, "")
        note = c.lenient(.note, "")
    }
}

extension SceneNote {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: c.lenient(.kind, .incident), text: c.lenient(.text, ""))
        id = c.lenient(.id, id)
        partID = c.lenient(.partID, UUID?.none)
        createdAt = c.lenient(.createdAt, createdAt)
    }
}

extension EventConsequence {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.lenient(.id, id)
        area = c.lenient(.area, area)
        reach = c.lenient(.reach, reach)
        text = c.lenient(.text, "")
        affected = c.lenient(.affected, [Lenient<StoryRef>]()).compactMap(\.value)
        followEventID = c.lenient(.followEventID, UUID?.none)
    }
}

extension ReasonStatement {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: c.lenient(.text, ""))
        id = c.lenient(.id, id)
        validity = c.lenient(.validity, .open)
    }
}

extension StoryFigure {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(.name, name)
        epithet = c.lenient(.epithet, epithet)
        role = c.lenient(.role, role)
        images = c.lenient(.images, images)
        birth = c.lenient(.birth, birth)
        origin = c.lenient(.origin, origin)
        biography = c.lenient(.biography, biography)
        appearance = c.lenient(.appearance, appearance)
        behavior = c.lenient(.behavior, behavior)
        secrets = c.lenient(.secrets, secrets)
        wants = c.lenient(.wants, wants)
        needs = c.lenient(.needs, needs)
        coreConflict = c.lenient(.coreConflict, coreConflict)
        fears = c.lenient(.fears, fears)
        development = c.lenient(.development, development)
        personality = c.lenient(.personality, personality)
        persona = c.lenient(.persona, persona)
        politics = c.lenient(.politics, politics)
        relations = c.lenient(.relations, [Lenient<StoryRelation>]()).compactMap(\.value)
        voice = c.lenient(.voice, voice)
        perception = c.lenient(.perception, perception)
        scenes = c.lenient(.scenes, scenes)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryPlace {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(.name, name)
        placeKind = c.lenient(.placeKind, placeKind)
        parentID = c.lenient(.parentID, parentID)
        images = c.lenient(.images, images)
        atmosphere = c.lenient(.atmosphere, atmosphere)
        geography = c.lenient(.geography, geography)
        history = c.lenient(.history, history)
        society = c.lenient(.society, society)
        residentIDs = c.lenient(.residentIDs, residentIDs)
        significance = c.lenient(.significance, significance)
        secrets = c.lenient(.secrets, secrets)
        notes = c.lenient(.notes, notes)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(.name, name)
        eventKind = c.lenient(.eventKind, eventKind)
        when = c.lenient(.when, when)
        placeIDs = c.lenient(.placeIDs, placeIDs)
        figureIDs = c.lenient(.figureIDs, figureIDs)
        course = c.lenient(.course, course)
        causes = c.lenient(.causes, causes)
        causeEventIDs = c.lenient(.causeEventIDs, causeEventIDs)
        consequences = c.lenient(.consequences, consequences)
        knowledge = c.lenient(.knowledge, knowledge)
        knownByIDs = c.lenient(.knownByIDs, knownByIDs)
        significance = c.lenient(.significance, significance)
        notes = c.lenient(.notes, notes)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryReason {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(.name, name)
        holderID = c.lenient(.holderID, holderID)
        assumptions = c.lenient(.assumptions, assumptions)
        premises = c.lenient(.premises, premises)
        conclusion = c.lenient(.conclusion, conclusion)
        weakness = c.lenient(.weakness, weakness)
        notes = c.lenient(.notes, notes)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}

extension StoryPurpose {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        name = c.lenient(.name, name)
        function = c.lenient(.function, function)
        intent = c.lenient(.intent, intent)
        readerEffect = c.lenient(.readerEffect, readerEffect)
        theme = c.lenient(.theme, theme)
        setupPartIDs = c.lenient(.setupPartIDs, setupPartIDs)
        payoffPartIDs = c.lenient(.payoffPartIDs, payoffPartIDs)
        notes = c.lenient(.notes, notes)
        createdAt = c.lenient(.createdAt, createdAt)
        updatedAt = c.lenient(.updatedAt, createdAt)
    }
}
