import Foundation

/// The parts of a document's content analysis. The overview comes first and tells which of the others fit the text;
/// the user can add the others by hand.
enum ContentAnalysisModule: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview, argumentation, narrative, structure
    /// Flow charts of the document's Python and SQL code. Not made by the model: the code is read as it is.
    case code

    var id: String { rawValue }

    /// Made by the model (everything but the code's flow charts, which come from the code itself).
    var isModelWork: Bool { self != .code }

    var label: String {
        switch self {
        case .overview: "Überblick"
        case .argumentation: "Argumentation"
        case .narrative: "Figuren & Handlung"
        case .structure: "Gliederung"
        case .code: "Code-Ablauf"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "doc.text.magnifyingglass"
        case .argumentation: "point.3.connected.trianglepath.dotted"
        case .narrative: "person.2"
        case .structure: "list.bullet.indent"
        case .code: "flowchart"
        }
    }

    /// What the model is doing while this part is made.
    var progressText: String {
        switch self {
        case .overview: "Verschafft sich einen Überblick …"
        case .argumentation: "Zerlegt die Argumente in Prämissen und Konklusionen …"
        case .narrative: "Sucht Figuren, Beziehungen und Handlung …"
        case .structure: "Gliedert den Inhalt …"
        case .code: "Liest den Code …"
        }
    }

    var explanation: String {
        switch self {
        case .overview: "Textsorte, Thema, Zusammenfassung und Kernaussagen."
        case .argumentation: "Hauptthese, Argumente mit Prämissen und Konklusion, Einwände – als Argumentkarte."
        case .narrative: "Figuren, ihre Beziehungen und der Verlauf der Handlung – als Diagramme."
        case .structure: "Bereiche, Aufzählungen, Abläufe und Zusammenhänge – als Mindmap und Ablauf."
        case .code: "Was passiert im Code? Flussdiagramme der Python- und SQL-Blöcke, die sich ins Dokument übernehmen lassen."
        }
    }
}

/// What kind of text the model takes the document for. The raw values are the words the model chooses from.
enum TextKind: String, Codable, CaseIterable, Sendable {
    case argumentation = "Argumentation"
    case description = "Beschreibung"
    case narrative = "Erzählung"
    case instruction = "Anleitung"
    case report = "Bericht"
    case other = "Sonstiges"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = TextKind(rawValue: value) ?? .other
    }

    /// The part of the analysis that says most about this kind of text.
    var primaryModule: ContentAnalysisModule {
        switch self {
        case .argumentation: .argumentation
        case .narrative: .narrative
        case .description, .instruction, .report, .other: .structure
        }
    }

    var symbol: String {
        switch self {
        case .argumentation: "text.bubble"
        case .description: "doc.plaintext"
        case .narrative: "book"
        case .instruction: "list.number"
        case .report: "newspaper"
        case .other: "doc"
        }
    }
}

/// Two things in the text and how they are related ("Lena – Schwester von → Tom").
struct AnalysisRelation: Codable, Hashable, Sendable {
    var from: String
    var to: String
    var kind: String
}

struct AnalysisOverview: Codable, Hashable, Sendable {
    var kind: TextKind
    var topic: String
    var summary: String
    var keyStatements: [String]
    var keywords: [String]
    /// The parts the model found besides the one for the kind of text.
    var suggested: [ContentAnalysisModule]
}

/// The argumentation of a text: its main thesis, the arguments for it (premises and conclusion) and the objections.
struct ArgumentAnalysis: Codable, Hashable, Sendable {
    struct Premise: Codable, Hashable, Sendable {
        var text: String
        /// Not in the text: a premise the argument needs and the model added.
        var isImplicit: Bool
        var anchor: DocumentAnchor?
    }

    struct Argument: Codable, Hashable, Sendable {
        var title: String
        var premises: [Premise]
        var conclusion: String
        /// How the conclusion follows: deduktiv, induktiv, kausal …
        var inference: String
        /// Supports the argument before it instead of the main thesis.
        var supportsPrevious: Bool
        var anchor: DocumentAnchor?
    }

    struct Objection: Codable, Hashable, Sendable {
        var text: String
        /// The argument the objection is raised against; nil: the main thesis.
        var target: Int?
        var rebuttal: String
        var anchor: DocumentAnchor?
    }

    var thesis: String
    var thesisAnchor: DocumentAnchor?
    var arguments: [Argument]
    var objections: [Objection]
    var strengths: [String]
    var weaknesses: [String]

    /// The argument an argument supports; nil: the main thesis.
    func supportedArgument(of index: Int) -> Int? {
        index > 0 && arguments[index].supportsPrevious ? index - 1 : nil
    }
}

/// Characters, how they relate and what happens in a narrative text.
struct NarrativeAnalysis: Codable, Hashable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case protagonist = "Hauptfigur"
        case antagonist = "Gegenspieler"
        case supporting = "Nebenfigur"
        case mentioned = "erwähnt"

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: value) ?? .supporting
        }

        var label: String { self == .mentioned ? "Erwähnt" : rawValue }
    }

    struct Character: Codable, Hashable, Sendable {
        var name: String
        var role: Role
        var description: String
        var anchor: DocumentAnchor?
    }

    struct Place: Codable, Hashable, Sendable {
        var name: String
        var description: String
    }

    struct Event: Codable, Hashable, Sendable {
        var text: String
        var characters: [String]
        var place: String
        var anchor: DocumentAnchor?
    }

    var perspective: String
    var time: String
    var conflict: String
    var characters: [Character]
    var relations: [AnalysisRelation]
    var places: [Place]
    var events: [Event]
    var motifs: [String]
}

/// How a describing text divides its subject: areas with their points, steps in order, and how things relate.
struct StructureAnalysis: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        var text: String
        var details: [String]
    }

    struct Aspect: Codable, Hashable, Sendable {
        var title: String
        var points: [Point]
        var anchor: DocumentAnchor?
    }

    struct Step: Codable, Hashable, Sendable {
        var text: String
        var anchor: DocumentAnchor?
    }

    var subject: String
    var aspects: [Aspect]
    var steps: [Step]
    var relations: [AnalysisRelation]
}

/// The model's analysis of what a document says. Stored next to the document, not in it.
struct ContentAnalysis: Codable, Hashable, Sendable {
    var overview: AnalysisOverview?
    var argumentation: ArgumentAnalysis?
    var narrative: NarrativeAnalysis?
    var structure: StructureAnalysis?
    /// The text it was made from (`DocumentOutlineBuilder.contentChecksum`), to tell whether it changed since.
    var sourceChecksum: UInt64
    var generatedAt: Date
    var model: String?
    /// The document was longer than the model's context; its paragraphs were cut short for the analysis.
    var isShortened = false

    var modules: [ContentAnalysisModule] {
        ContentAnalysisModule.allCases.filter(contains)
    }

    func contains(_ module: ContentAnalysisModule) -> Bool {
        switch module {
        case .overview: overview != nil
        case .argumentation: argumentation != nil
        case .narrative: narrative != nil
        case .structure: structure != nil
        case .code: false
        }
    }
}

/// Each analysis is a JSON file in the library's `Documents/Inhaltsanalysen` folder, named like its document.
struct ContentAnalysisStore {
    let directory: URL

    init() {
        directory = AppLibrary.current.folder("Documents").appendingPathComponent("Inhaltsanalysen", isDirectory: true)
    }

    func load(_ id: UUID) -> ContentAnalysis? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        do {
            return try Self.decoder.decode(ContentAnalysis.self, from: data)
        } catch {
            print("LLMDesigner: Inhaltsanalyse \(id) konnte nicht gelesen werden: \(error)")
            return nil
        }
    }

    func save(_ analysis: ContentAnalysis, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(analysis).write(to: url(for: id), options: .atomic)
        } catch {
            print("LLMDesigner: Inhaltsanalyse \(id) konnte nicht gespeichert werden: \(error)")
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
