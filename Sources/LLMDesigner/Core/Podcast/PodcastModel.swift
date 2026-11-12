import Foundation

// PodcastStudio: a podcast is a conversation about a question, between a moderator and discussants who each have a
// name, a description, a voice and a position. The model researches the question on the web and in Wikipedia, writes
// the script line by line, and Qwen TTS speaks every line; the lines are joined into one audio file. Keys in the file
// are German, like the other new formats.

/// Who someone is in the conversation.
enum PodcastRole: String, CaseIterable, Identifiable, Sendable {
    case moderator, discussant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moderator: "Moderation"
        case .discussant: "Diskutant:in"
        }
    }

    var stored: String {
        switch self {
        case .moderator: "moderator"
        case .discussant: "diskutant"
        }
    }

    init?(stored: String) {
        switch stored.lowercased() {
        case "moderator", "moderation", "moderatorin": self = .moderator
        case "diskutant", "diskutantin", "diskutant:in", "gast", "discussant": self = .discussant
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .moderator: "mic.fill"
        case .discussant: "person.wave.2.fill"
        }
    }
}

/// One person of the podcast.
struct PodcastParticipant: Identifiable, Hashable, Sendable {
    var id = UUID()
    var role: PodcastRole = .discussant
    /// Used in the conversation, so the others can address them.
    var name = ""
    /// Who the person is: "Biologin an der Uni Wien", "Taxifahrer aus Köln".
    var description = ""
    /// A Qwen TTS voice id (`serena`, `aiden` …).
    var voice = "serena"
    /// The stand they take in the conversation.
    var position = ""

    init(role: PodcastRole = .discussant, name: String = "", description: String = "", voice: String = "serena", position: String = "") {
        self.role = role
        self.name = name
        self.description = description
        self.voice = voice
        self.position = position
    }

    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? role.label : name
    }
}

extension PodcastParticipant: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, rolle, name, beschreibung, stimme, position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        role = PodcastRole(stored: c.lenient(.rolle, "diskutant")) ?? .discussant
        name = c.lenient(.name, "")
        description = c.lenient(.beschreibung, "")
        voice = c.lenient(.stimme, "serena")
        position = c.lenient(.position, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role.stored, forKey: .rolle)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .beschreibung)
        try c.encode(voice, forKey: .stimme)
        try c.encode(position, forKey: .position)
    }
}

/// Material the podcast draws on: a chat, a Writer document or presentation, a novel world or one of its parts.
enum PodcastReference: Hashable, Sendable {
    case chat(UUID)
    case document(UUID)
    case story(world: UUID, part: UUID?)
}

extension PodcastReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case art, id, welt, teil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .art) {
        case "chat": self = .chat(try c.decode(UUID.self, forKey: .id))
        case "dokument": self = .document(try c.decode(UUID.self, forKey: .id))
        case "romanwelt": self = .story(world: try c.decode(UUID.self, forKey: .welt), part: c.lenient(.teil, UUID?.none))
        case let other: throw DecodingError.dataCorruptedError(forKey: .art, in: c, debugDescription: "Unbekannte Referenz „\(other)“")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chat(let id):
            try c.encode("chat", forKey: .art)
            try c.encode(id, forKey: .id)
        case .document(let id):
            try c.encode("dokument", forKey: .art)
            try c.encode(id, forKey: .id)
        case .story(let world, let part):
            try c.encode("romanwelt", forKey: .art)
            try c.encode(world, forKey: .welt)
            try c.encodeIfPresent(part, forKey: .teil)
        }
    }
}

/// How the conversation sounds, from a factual exchange to a heated quarrel. The steps go into the prompts of the
/// plan, the script and the cast.
enum PodcastTone: String, CaseIterable, Identifiable, Sendable {
    case factual = "sachlich"
    case lively = "lebhaft"
    case controversial = "kontrovers"
    case polemic = "polemisch"
    case heated = "hitzig"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .factual: "Sachlich"
        case .lively: "Lebhaft"
        case .controversial: "Kontrovers"
        case .polemic: "Polemisch"
        case .heated: "Hitzig"
        }
    }

    var level: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func at(_ level: Int) -> PodcastTone {
        allCases[min(max(0, level), allCases.count - 1)]
    }

    /// For the slider's hint.
    var hint: String {
        switch self {
        case .factual: "Ruhiger Austausch, Argumente und Fakten stehen im Vordergrund."
        case .lively: "Engagiert und pointiert, mit Humor und Nachfragen."
        case .controversial: "Klare Gegenpositionen, man widerspricht sich deutlich."
        case .polemic: "Zugespitzt, ironisch, mit Seitenhieben und Unterstellungen."
        case .heated: "Wie die Fernsehdebatten der 70er und 80er: man fällt sich ins Wort, wird persönlich und beleidigt sich."
        }
    }
}

/// Material the person hands over: web pages and PDFs. With `onlyThese` the research reads just them and searches
/// nothing else, and the script keeps to what they say.
struct PodcastOwnSources: Hashable, Sendable {
    enum Entry: Hashable, Sendable {
        case url(String)
        /// A PDF copied into the podcast's folder: its title and the path below that folder (`Quellen/…`).
        case pdf(title: String, file: String)

        var label: String {
            switch self {
            case .url(let address): address
            case .pdf(let title, let file): title.isEmpty ? (file as NSString).lastPathComponent : title
            }
        }
    }

    var onlyThese = false
    var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty && !onlyThese }
}

extension PodcastOwnSources.Entry: Codable {
    private enum CodingKeys: String, CodingKey { case art, url, titel, datei }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .art) {
        case "url": self = .url(try c.decode(String.self, forKey: .url))
        case "pdf": self = .pdf(title: c.lenient(.titel, ""), file: try c.decode(String.self, forKey: .datei))
        case let other: throw DecodingError.dataCorruptedError(forKey: .art, in: c, debugDescription: "Unbekannte Quelle „\(other)“")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let address):
            try c.encode("url", forKey: .art)
            try c.encode(address, forKey: .url)
        case .pdf(let title, let file):
            try c.encode("pdf", forKey: .art)
            try c.encode(title, forKey: .titel)
            try c.encode(file, forKey: .datei)
        }
    }
}

extension PodcastOwnSources: Codable {
    private enum CodingKeys: String, CodingKey { case nurDiese, eintraege }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onlyThese = c.lenient(.nurDiese, false)
        entries = c.lenient(.eintraege, [Lenient<Entry>]()).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(onlyThese, forKey: .nurDiese)
        try c.encode(entries, forKey: .eintraege)
    }
}

/// A source the research used.
struct PodcastSource: Hashable, Sendable {
    var title: String
    var url: String
}

extension PodcastSource: Codable {
    private enum CodingKeys: String, CodingKey { case titel, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.titel, "")
        url = c.lenient(.url, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .titel)
        try c.encode(url, forKey: .url)
    }
}

/// What the model found out before writing: a fact sheet and where it comes from.
struct PodcastResearch: Hashable, Sendable {
    var notes = ""
    var sources: [PodcastSource] = []

    var isEmpty: Bool { notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension PodcastResearch: Codable {
    private enum CodingKeys: String, CodingKey { case notizen, quellen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = c.lenient(.notizen, "")
        sources = c.lenient(.quellen, [Lenient<PodcastSource>]()).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notes, forKey: .notizen)
        try c.encode(sources, forKey: .quellen)
    }
}

/// A part of the conversation as planned: its title and what is said in it.
struct PodcastSection: Hashable, Sendable {
    var title: String
    var points: [String] = []
}

extension PodcastSection: Codable {
    private enum CodingKeys: String, CodingKey { case titel, punkte }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.titel, "")
        points = c.lenient(.punkte, [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .titel)
        try c.encode(points, forKey: .punkte)
    }
}

/// One spoken contribution of the script. Its audio is `Schnipsel/<id>.wav` in the podcast's folder; changing the
/// text removes that file, so only that line is spoken anew.
struct PodcastLine: Identifiable, Hashable, Sendable {
    var id = UUID()
    /// The participant who speaks it.
    var speaker: UUID
    var text: String
    /// Seconds of its snippet, once spoken.
    var duration: Double?

    init(speaker: UUID, text: String, duration: Double? = nil) {
        self.speaker = speaker
        self.text = text
        self.duration = duration
    }

    var wordCount: Int { PodcastLength.words(in: text) }
}

extension PodcastLine: Codable {
    private enum CodingKeys: String, CodingKey { case id, sprecher, text, dauer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        speaker = try c.decode(UUID.self, forKey: .sprecher)
        text = c.lenient(.text, "")
        duration = c.lenient(.dauer, Double?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(speaker, forKey: .sprecher)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(duration.map { ($0 * 100).rounded() / 100 }, forKey: .dauer)
    }
}

/// Where the making of a podcast stands. It is kept in the file, so the sidebar knows after a restart what is done.
enum PodcastPhase: String, CaseIterable, Sendable {
    /// Being set up: question, length, participants.
    case draft = "entwurf"
    /// Started, waiting for another podcast to finish.
    case queued = "wartet"
    case researching = "recherche"
    case scripting = "skript"
    case speaking = "audio"
    case finished = "fertig"
    case stopped = "gestoppt"
    case failed = "fehler"

    var isRunning: Bool {
        switch self {
        case .queued, .researching, .scripting, .speaking: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .draft: "Entwurf"
        case .queued: "Wartet"
        case .researching: "Recherche"
        case .scripting: "Skript"
        case .speaking: "Sprachaufnahme"
        case .finished: "Fertig"
        case .stopped: "Angehalten"
        case .failed: "Fehler"
        }
    }
}

/// The speech model of the podcast. The small one is the default: the large one now and then made noise and
/// unpleasant artefacts in longer recordings (the user's experience, November 2026).
enum PodcastSpeechModel: String, CaseIterable, Identifiable, Sendable {
    case small = "klein"
    case large = "gross"

    var id: String { rawValue }

    var engine: SpeechEngine {
        switch self {
        case .small: .qwenSmall
        case .large: .qwenLarge
        }
    }

    var label: String {
        switch self {
        case .small: "Qwen TTS klein (0.6B)"
        case .large: "Qwen TTS groß (1.7B)"
        }
    }
}

/// The lengths to choose from and how much text each needs.
enum PodcastLength {
    static let choices = [5, 10, 15]
    static let standard = 10
    /// Spoken German in a relaxed conversation; Qwen TTS reads at about this pace (measured with the small model).
    static let wordsPerMinute = 140

    static func targetWords(minutes: Int) -> Int { minutes * wordsPerMinute }

    /// Parts of the conversation: opening and close included.
    static func sectionCount(minutes: Int) -> Int {
        switch minutes {
        case ..<7: 3
        case ..<12: 5
        default: 7
        }
    }

    static func words(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
    }

    /// "10:12", for durations.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A podcast of the library.
struct Podcast: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    /// The question or topic the conversation is about.
    var question = ""
    /// Minutes: 5, 10 or 15.
    var minutes = PodcastLength.standard
    var language = "de"
    var speechModel: PodcastSpeechModel = .small
    /// The model thinks before it answers, where it can (research, plan and script).
    var thinking = true
    var tone: PodcastTone = .factual
    var ownSources = PodcastOwnSources()
    /// The folder of the sidebar it lies in.
    var folderID: Folder.ID?
    var participants: [PodcastParticipant] = []
    var references: [PodcastReference] = []
    var research = PodcastResearch()
    var outline: [PodcastSection] = []
    var script: [PodcastLine] = []
    var phase: PodcastPhase = .draft
    var error: String?
    /// Seconds of the finished audio.
    var duration: Double?
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String = "", question: String = "") {
        self.title = title
        self.question = question
    }

    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { return Self.shortTitle(question) }
        return "Neuer Podcast"
    }

    /// A long question as a title: whole words up to about 60 characters, with "…" where it was cut.
    static func shortTitle(_ text: String, limit: Int = 60) -> String {
        guard text.count > limit else { return text }
        var title = ""
        for word in text.split(separator: " ") {
            guard title.count + word.count + 1 <= limit else { break }
            title += title.isEmpty ? String(word) : " " + word
        }
        if title.isEmpty { title = String(text.prefix(limit)) }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: ",;:–- ")) + " …"
    }

    var moderator: PodcastParticipant? { participants.first { $0.role == .moderator } }
    var discussants: [PodcastParticipant] { participants.filter { $0.role == .discussant } }

    func participant(_ id: UUID) -> PodcastParticipant? { participants.first { $0.id == id } }

    var scriptWords: Int { script.reduce(0) { $0 + $1.wordCount } }
    var targetWords: Int { PodcastLength.targetWords(minutes: minutes) }

    /// What is missing before it can start, as a sentence for the person; nil when it can.
    var startProblem: String? {
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && references.isEmpty && ownSources.entries.isEmpty {
            return "Gib eine Frage oder ein Thema ein."
        }
        if ownSources.onlyThese && ownSources.entries.isEmpty {
            return "„Nur aus diesen Quellen“ ist an, aber es gibt noch keine Quelle."
        }
        if moderator == nil { return "Es fehlt eine Moderation." }
        if discussants.isEmpty { return "Es fehlt mindestens ein:e Diskutant:in." }
        let names = participants.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("") { return "Jede:r Teilnehmer:in braucht einen Namen." }
        if Set(names).count != names.count { return "Zwei Teilnehmer:innen heißen gleich." }
        return nil
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return displayTitle.localizedStandardContains(query) || question.localizedStandardContains(query)
            || participants.contains { $0.name.localizedStandardContains(query) }
            || script.contains { $0.text.localizedStandardContains(query) }
    }

    /// When each line starts in the finished audio: the same pauses as `PodcastAudio.join`.
    var lineStarts: [UUID: Double] {
        var starts: [UUID: Double] = [:]
        var time = 0.0
        var previous: UUID?
        for line in script {
            if let previous { time += previous == line.speaker ? PodcastAudio.pauseSameSpeaker : PodcastAudio.pauseNewSpeaker }
            starts[line.id] = time
            time += line.duration ?? 0
            previous = line.speaker
        }
        return starts
    }

    /// The script as text, "Name: Satz" per line.
    var scriptText: String {
        script.map { "\(participant($0.speaker)?.displayName ?? "?"): \($0.text)" }.joined(separator: "\n\n")
    }
}

extension Podcast: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, frage, laenge, sprache, sprachmodell, denkmodus, ton, eigeneQuellen, ordner, teilnehmer, referenzen, recherche, gliederung, skript, phase, fehler, dauer, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = c.lenient(.titel, "")
        question = c.lenient(.frage, "")
        let minutes = c.lenient(.laenge, PodcastLength.standard)
        self.minutes = PodcastLength.choices.contains(minutes) ? minutes : PodcastLength.standard
        language = c.lenient(.sprache, "de")
        speechModel = PodcastSpeechModel(rawValue: c.lenient(.sprachmodell, "klein")) ?? .small
        thinking = c.lenient(.denkmodus, true)
        tone = PodcastTone(rawValue: c.lenient(.ton, "sachlich")) ?? .factual
        ownSources = c.lenient(.eigeneQuellen, PodcastOwnSources())
        folderID = c.lenient(.ordner, UUID?.none)
        participants = c.lenient(.teilnehmer, [Lenient<PodcastParticipant>]()).compactMap(\.value)
        references = c.lenient(.referenzen, [Lenient<PodcastReference>]()).compactMap(\.value)
        research = c.lenient(.recherche, PodcastResearch())
        outline = c.lenient(.gliederung, [Lenient<PodcastSection>]()).compactMap(\.value)
        script = c.lenient(.skript, [Lenient<PodcastLine>]()).compactMap(\.value)
        phase = PodcastPhase(rawValue: c.lenient(.phase, "entwurf")) ?? .draft
        error = c.lenient(.fehler, String?.none)
        duration = c.lenient(.dauer, Double?.none)
        createdAt = c.lenient(.erstellt, Date())
        updatedAt = c.lenient(.geaendert, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(question, forKey: .frage)
        try c.encode(minutes, forKey: .laenge)
        try c.encode(language, forKey: .sprache)
        try c.encode(speechModel.rawValue, forKey: .sprachmodell)
        try c.encode(thinking, forKey: .denkmodus)
        try c.encode(tone.rawValue, forKey: .ton)
        if !ownSources.isEmpty { try c.encode(ownSources, forKey: .eigeneQuellen) }
        try c.encodeIfPresent(folderID, forKey: .ordner)
        try c.encode(participants, forKey: .teilnehmer)
        if !references.isEmpty { try c.encode(references, forKey: .referenzen) }
        if !research.isEmpty || !research.sources.isEmpty { try c.encode(research, forKey: .recherche) }
        if !outline.isEmpty { try c.encode(outline, forKey: .gliederung) }
        if !script.isEmpty { try c.encode(script, forKey: .skript) }
        try c.encode(phase.rawValue, forKey: .phase)
        try c.encodeIfPresent(error, forKey: .fehler)
        try c.encodeIfPresent(duration.map { ($0 * 10).rounded() / 10 }, forKey: .dauer)
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

// MARK: - Voices

extension PodcastParticipant {
    /// The voices a new participant gets, one after the other: clear ones first. ryan swung most in pitch and was the
    /// only voice that still mumbled at temperature 0.6, so it comes last.
    static let femaleVoices = ["serena", "sohee", "ono_anna", "vivian"]
    static let maleVoices = ["aiden", "eric", "dylan", "uncle_fu", "ryan"]

    /// A voice none of `taken` has, of the wished gender if there is one.
    static func freeVoice(female: Bool?, taken: [String], available: [String]) -> String {
        let order: [String] = switch female {
        case true?: femaleVoices + maleVoices
        case false?: maleVoices + femaleVoices
        case nil: ["serena", "aiden", "sohee", "eric", "ono_anna", "dylan", "vivian", "uncle_fu", "ryan"]
        }
        let pool = order.filter { available.isEmpty || available.contains($0) } + available.filter { !order.contains($0) }
        return pool.first { !taken.contains($0) } ?? pool.first ?? "serena"
    }

    /// A start: a moderator and two discussants who see the question differently.
    static func defaultCast() -> [PodcastParticipant] {
        [
            PodcastParticipant(role: .moderator, name: "Lena", description: "Wissenschaftsjournalistin, führt durch das Gespräch", voice: "serena",
                               position: "neugierig und unparteiisch, fragt nach und fasst zusammen"),
            PodcastParticipant(role: .discussant, name: "Jonas", description: "Fachmann für das Thema", voice: "aiden",
                               position: "befürwortet die Idee und erklärt sie"),
            PodcastParticipant(role: .discussant, name: "Mira", description: "Kritische Stimme aus einem Nachbarfach", voice: "sohee",
                               position: "skeptisch, nennt Grenzen und Einwände"),
        ]
    }
}
