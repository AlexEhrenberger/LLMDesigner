import Foundation

// Rechercherista: a research assignment for the local model. It starts at Wikipedia to see what the words can mean,
// asks back when they can mean more than one thing, plans sub-questions as a tree, researches each in the chosen
// sources (Wikipedia, the web, arXiv, OpenAlex), looks for gaps, and writes a report from what it found. One folder
// per research: `Recherchen/<id>/recherche.json`. Keys in the file are German.

/// Where a research looks.
enum ResearchSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case wikipedia, web, arxiv, openalex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wikipedia: "Wikipedia"
        case .web: "Websuche"
        case .arxiv: "arXiv"
        case .openalex: "OpenAlex"
        }
    }

    var symbol: String {
        switch self {
        case .wikipedia: "book.closed"
        case .web: "globe"
        case .arxiv: "doc.text.magnifyingglass"
        case .openalex: "graduationcap"
        }
    }

    var summary: String {
        switch self {
        case .wikipedia: "Begriffe klären, Überblick"
        case .web: "Aktuelles, Seiten, Erklärungen"
        case .arxiv: "Preprints aus Informatik, Physik, Mathematik, Kognitionswissenschaft"
        case .openalex: "Fachartikel aller Disziplinen mit Abstracts und Zitationen"
        }
    }

    var isScholarly: Bool { self == .arxiv || self == .openalex }
}

/// How thorough: how many sub-questions, follow-ups and sources.
enum ResearchDepth: String, Codable, CaseIterable, Identifiable, Sendable {
    case ueberblick, gruendlich, sehrGruendlich

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ueberblick: "Überblick"
        case .gruendlich: "Gründlich"
        case .sehrGruendlich: "Sehr gründlich"
        }
    }

    var subQuestions: Int {
        switch self {
        case .ueberblick: 3
        case .gruendlich: 5
        case .sehrGruendlich: 7
        }
    }

    /// Follow-up questions after the first pass.
    var followUps: Int {
        switch self {
        case .ueberblick: 0
        case .gruendlich: 2
        case .sehrGruendlich: 4
        }
    }

    /// Hits taken per source and query.
    var hits: Int {
        switch self {
        case .ueberblick: 2
        case .gruendlich: 3
        case .sehrGruendlich: 4
        }
    }
}

enum ResearchPhase: String, Codable, Sendable {
    case entwurf, orientierung, rueckfrage, planen, recherchieren, luecken, bericht, fertig, gestoppt, fehler

    var label: String {
        switch self {
        case .entwurf: "Entwurf"
        case .orientierung: "Orientierung bei Wikipedia"
        case .rueckfrage: "Rückfrage an dich"
        case .planen: "Plan der Teilfragen"
        case .recherchieren: "Recherche"
        case .luecken: "Lücken schließen"
        case .bericht: "Bericht wird geschrieben"
        case .fertig: "Fertig"
        case .gestoppt: "Angehalten"
        case .fehler: "Fehler"
        }
    }

    var isRunning: Bool { [.orientierung, .planen, .recherchieren, .luecken, .bericht].contains(self) }
}

/// What a source the research found looks like.
struct ResearchSource: Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Its number in the report: [1], [2] …
    var number = 0
    var kind: ResearchSourceKind = .web
    var title = ""
    var url = ""
    var authors: [String] = []
    var year: Int?
    var doi: String?
    /// What it says on the question (an abstract, the read part of a page).
    var excerpt = ""
    var citations: Int?
    /// The person kept it (true), threw it out (false), or hasn't decided (nil: kept).
    var accepted: Bool?

    var isUsed: Bool { accepted != false }

    var byline: String {
        var parts: [String] = []
        if !authors.isEmpty { parts.append(authors.count > 2 ? "\(authors[0]) u. a." : authors.joined(separator: ", ")) }
        if let year { parts.append(String(year)) }
        return parts.joined(separator: ", ")
    }

    var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }
}

extension ResearchSource: Codable {
    private enum CodingKeys: String, CodingKey { case id, nummer, art, titel, url, autoren, jahr, doi, auszug, zitationen, angenommen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        number = c.soft(.nummer, 0)
        kind = c.soft(.art, ResearchSourceKind.web)
        title = c.soft(.titel, "")
        url = c.soft(.url, "")
        authors = c.soft(.autoren, [String]())
        year = c.soft(.jahr, Int?.none)
        doi = c.soft(.doi, String?.none)
        excerpt = c.soft(.auszug, "")
        citations = c.soft(.zitationen, Int?.none)
        accepted = c.soft(.angenommen, Bool?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(number, forKey: .nummer)
        try c.encode(kind, forKey: .art)
        try c.encode(title, forKey: .titel)
        try c.encode(url, forKey: .url)
        if !authors.isEmpty { try c.encode(authors, forKey: .autoren) }
        try c.encodeIfPresent(year, forKey: .jahr)
        try c.encodeIfPresent(doi, forKey: .doi)
        try c.encode(excerpt, forKey: .auszug)
        try c.encodeIfPresent(citations, forKey: .zitationen)
        try c.encodeIfPresent(accepted, forKey: .angenommen)
    }
}

/// A question in the tree: the assignment at the root, sub-questions below it, follow-ups below those.
struct ResearchNode: Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case offen, laeuft, fertig, uebersprungen
    }

    var id = UUID()
    var parent: UUID?
    var question = ""
    var status: Status = .offen
    /// What the sources say on it, with [n] for the sources.
    var summary = ""
    /// The searches that were made for it.
    var queries: [String] = []
    var sources: [UUID] = []
    /// Why it was asked (a gap the model saw).
    var reason = ""
}

extension ResearchNode: Codable {
    private enum CodingKeys: String, CodingKey { case id, eltern, frage, status, zusammenfassung, suchen, quellen, grund }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        parent = c.soft(.eltern, UUID?.none)
        question = c.soft(.frage, "")
        status = c.soft(.status, Status.offen)
        summary = c.soft(.zusammenfassung, "")
        queries = c.soft(.suchen, [String]())
        sources = c.soft(.quellen, [UUID]())
        reason = c.soft(.grund, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(parent, forKey: .eltern)
        try c.encode(question, forKey: .frage)
        try c.encode(status, forKey: .status)
        try c.encode(summary, forKey: .zusammenfassung)
        try c.encode(queries, forKey: .suchen)
        try c.encode(sources, forKey: .quellen)
        if !reason.isEmpty { try c.encode(reason, forKey: .grund) }
    }
}

/// The question the model asked back, and the person's answer.
struct ResearchClarification: Hashable, Codable, Sendable {
    var question: String
    var options: [String]
    var answer: String?

    private enum CodingKeys: String, CodingKey { case frage, optionen, antwort }

    init(question: String, options: [String], answer: String? = nil) {
        self.question = question
        self.options = options
        self.answer = answer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = c.soft(.frage, "")
        options = c.soft(.optionen, [String]())
        answer = c.soft(.antwort, String?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(question, forKey: .frage)
        try c.encode(options, forKey: .optionen)
        try c.encodeIfPresent(answer, forKey: .antwort)
    }
}

struct Research: StoredRecord {
    var id = UUID()
    var title = ""
    var question = ""
    var sourceKinds: [ResearchSourceKind] = [.wikipedia, .web, .arxiv, .openalex]
    var depth: ResearchDepth = .gruendlich
    /// The Wikipedia edition and the language of the report.
    var language = "de"
    var thinking = false
    var phase: ResearchPhase = .entwurf
    /// What Wikipedia said first (the lead of the best article and the other meanings).
    var orientation = ""
    var clarification: ResearchClarification?
    var nodes: [ResearchNode] = []
    var sources: [ResearchSource] = []
    var report = ""
    /// Each search and page, in order, for the log.
    var log: [String] = []
    var error: String?
    /// The chat it came from.
    var chat: UUID?
    /// Only Wikipedia: the chat it came from had read private files.
    var restricted = false
    var createdAt = Date()
    var updatedAt = Date()

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? "Neue Recherche" : String(question.prefix(70))
    }

    var root: ResearchNode? { nodes.first { $0.parent == nil } }

    func children(of id: UUID) -> [ResearchNode] { nodes.filter { $0.parent == id } }

    func source(_ id: UUID) -> ResearchSource? { sources.first { $0.id == id } }

    /// The focus the person chose, or nil.
    var focus: String? { clarification?.answer.flatMap { $0.isEmpty ? nil : $0 } }

    var allowedKinds: [ResearchSourceKind] { restricted ? [.wikipedia] : sourceKinds }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, question, report].contains { $0.localizedCaseInsensitiveContains(query) }
            || nodes.contains { $0.question.localizedCaseInsensitiveContains(query) }
    }

    /// The sources in the report's order, without those the person threw out.
    var usedSources: [ResearchSource] { sources.filter(\.isUsed).sorted { $0.number < $1.number } }

    /// The reference list in Markdown, numbered like the report.
    var bibliography: String {
        usedSources.map { source in
            var line = "\(source.number). "
            if !source.byline.isEmpty { line += source.byline + ": " }
            line += "*\(WriterMarkdown.escape(source.title, atLineStart: false))*"
            line += " (\(source.kind.label))"
            if !source.url.isEmpty { line += " – <\(source.url)>" }
            return line
        }.joined(separator: "\n")
    }
}

extension Research: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, frage, quellenarten, tiefe, sprache, denkmodus, phase, orientierung, rueckfrage, baum, quellen, bericht, protokoll, fehler, chat, nurWikipedia, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        title = c.soft(.titel, "")
        question = c.soft(.frage, "")
        sourceKinds = c.soft(.quellenarten, ResearchSourceKind.allCases)
        depth = c.soft(.tiefe, ResearchDepth.gruendlich)
        language = c.soft(.sprache, "de")
        thinking = c.soft(.denkmodus, false)
        phase = c.soft(.phase, ResearchPhase.entwurf)
        orientation = c.soft(.orientierung, "")
        clarification = c.soft(.rueckfrage, ResearchClarification?.none)
        nodes = c.soft(.baum, [ResearchNode]())
        sources = c.soft(.quellen, [ResearchSource]())
        report = c.soft(.bericht, "")
        log = c.soft(.protokoll, [String]())
        error = c.soft(.fehler, String?.none)
        chat = c.soft(.chat, UUID?.none)
        restricted = c.soft(.nurWikipedia, false)
        createdAt = c.soft(.erstellt, Date())
        updatedAt = c.soft(.geaendert, createdAt)
        // A research that was running when the app quit is stopped, not running.
        if phase.isRunning { phase = .gestoppt }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(question, forKey: .frage)
        try c.encode(sourceKinds, forKey: .quellenarten)
        try c.encode(depth, forKey: .tiefe)
        try c.encode(language, forKey: .sprache)
        try c.encode(thinking, forKey: .denkmodus)
        try c.encode(phase, forKey: .phase)
        try c.encode(orientation, forKey: .orientierung)
        try c.encodeIfPresent(clarification, forKey: .rueckfrage)
        try c.encode(nodes, forKey: .baum)
        try c.encode(sources, forKey: .quellen)
        try c.encode(report, forKey: .bericht)
        try c.encode(log, forKey: .protokoll)
        try c.encodeIfPresent(error, forKey: .fehler)
        try c.encodeIfPresent(chat, forKey: .chat)
        if restricted { try c.encode(true, forKey: .nurWikipedia) }
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

/// How far a running research is.
struct ResearchProgress: Equatable {
    var fraction = 0.0
    var detail = ""
}

/// Rechercherista's researches and the one that runs.
@MainActor
@Observable
final class ResearchLibrary {
    let records = RecordLibrary<Research>(store: RecordStore(directory: AppLibrary.current.folder("Recherchen"), root: "recherche", layout: .folder("recherche")))
    var progress: [UUID: ResearchProgress] = [:]
    var runningID: UUID?
    var queue: [UUID] = []
    @ObservationIgnored var task: Task<Void, Never>?

    func loadIfNeeded() { records.loadIfNeeded() }
    func research(_ id: UUID) -> Research? { records.record(id) }
    func saveAll() { records.saveAll() }
}

/// What an action or the chat wants Rechercherista to show.
struct ResearchStudioCommand: Equatable {
    var research: UUID?
    var tab: ResearchTab?
}

enum ResearchTab: String, CaseIterable, Identifiable {
    case tree, sources, report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tree: "Fragenbaum"
        case .sources: "Quellen"
        case .report: "Bericht"
        }
    }

    var symbol: String {
        switch self {
        case .tree: "point.3.filled.connected.trianglepath.dotted"
        case .sources: "books.vertical"
        case .report: "doc.text"
        }
    }
}
