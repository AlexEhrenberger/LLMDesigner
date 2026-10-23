import Foundation

/// The requests for a document's content analysis and how the answers become a `ContentAnalysis`. Each part is
/// one request with its own JSON schema; the model delivers content only, the diagrams are made from it here.
enum ContentAnalysisBuilder {
    /// Shorter texts have too little to analyse.
    static let minimumWords = 40

    /// The document as the model reads it: numbered paragraphs, and the search key of each number for anchors.
    struct Source: Sendable {
        let text: String
        let keys: [Int: String]
        /// Paragraphs had to be cut short to fit the model's context.
        let isShortened: Bool
    }

    struct Paragraph {
        let index: Int
        let text: String
        let isHeading: Bool
        let key: String
    }

    /// Characters of document text that fit next to the instructions and the answer.
    static func budget(contextLength: Int) -> Int {
        max(4_000, (contextLength - 3_400) * 3)
    }

    static func source(_ paragraphs: [Paragraph], budget: Int) -> Source {
        let collapsed = paragraphs.map { paragraph in
            (paragraph, paragraph.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let total = collapsed.reduce(0) { $0 + $1.1.count + 8 }
        let perParagraph = total > budget ? max(60, budget / max(collapsed.count, 1)) : Int.max
        var lines: [String] = []
        var length = 0
        var isShortened = total > budget
        for (paragraph, text) in collapsed {
            let cut = text.count > perParagraph ? String(text.prefix(perParagraph)) + " …" : text
            let line = "[\(paragraph.index)] " + (paragraph.isHeading ? "Überschrift: " : "") + cut
            guard length + line.count <= budget || lines.isEmpty else {
                isShortened = true
                break
            }
            lines.append(line)
            length += line.count + 1
        }
        return Source(
            text: lines.joined(separator: "\n"),
            keys: Dictionary(paragraphs.map { ($0.index, $0.key) }, uniquingKeysWith: { first, _ in first }),
            isShortened: isShortened
        )
    }

    // MARK: Requests

    /// The same for every part, and the document comes before the task: LM Studio can reuse the processed
    /// document for the next part instead of reading it again.
    private static let system = """
    Du analysierst Texte genau und sachlich. Du bekommst ein Dokument, dessen Absätze in eckigen Klammern nummeriert sind, z. B. [3], und danach eine Aufgabe.
    - Halte dich an das, was im Text steht. Erfinde nichts dazu.
    - „stelle“ ist immer die Nummer des Absatzes, in dem etwas steht.
    - Schreibe keine Absatznummern in die Texte.
    - Formuliere knapp und auf Deutsch.
    """

    static func messages(for module: ContentAnalysisModule, source: Source) -> [ChatPayloadMessage] {
        [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: "DOKUMENT\n\n" + source.text + "\n\nAUFGABE\n\n" + task(module)),
        ]
    }

    static func schemaName(_ module: ContentAnalysisModule) -> String {
        "inhaltsanalyse_" + module.rawValue
    }

    static func maxTokens(_ module: ContentAnalysisModule) -> Int {
        switch module {
        case .overview: 1_000
        case .argumentation: 2_400
        case .narrative: 2_400
        case .structure: 2_200
        case .code: 0
        }
    }

    private static func task(_ module: ContentAnalysisModule) -> String {
        switch module {
        case .overview:
            """
            Verschaffe dir einen Überblick über das Dokument.
            - „textsorte“: die vorherrschende Art des Textes.
            - „thema“: das Thema in höchstens 6 Wörtern.
            - „zusammenfassung“: 2 bis 3 Sätze.
            - „kernaussagen“: die 2 bis 5 wichtigsten Aussagen, je ein kurzer Satz.
            - „schluesselbegriffe“: 3 bis 8 zentrale Begriffe.
            - „enthaelt“: was im Text vorkommt. „argumentation“: Thesen, die mit Gründen gestützt werden. „erzaehlung“: Figuren und eine Handlung. „gliederung“: Beschreibungen, Aufzählungen oder Bestandteile. „ablauf“: Schritte oder ein Vorgang in fester Reihenfolge.
            """
        case .argumentation:
            """
            Analysiere die Argumentation des Dokuments.
            - „hauptthese“: die zentrale Behauptung, die der Text begründen will.
            - „argumente“: jedes Argument einzeln, mit kurzem „titel“ (höchstens 4 Wörter). „praemissen“ sind die Aussagen, auf die es sich stützt – auch allgemeine Regeln oder Werturteile („sollte“, „muss“). „konklusion“ ist, was daraus folgt.
            - Fehlt eine Voraussetzung, ohne die die Konklusion nicht folgt, ergänze sie als Prämisse mit „implizit“: true.
            - „stuetzt“: "Hauptthese", wenn die Konklusion die Hauptthese stützt; "vorheriges Argument", wenn sie das Argument direkt davor stützt.
            - „schlussart“: deduktiv (folgt zwingend aus einer allgemeinen Regel), induktiv (verallgemeinert aus Fällen oder Daten), kausal (Ursache und Wirkung), Analogie (Vergleich), Beispiel (einzelnes Beispiel), Autorität (beruft sich auf Studien oder Fachleute), praktisch (Ziel und Mittel: daher sollte man handeln).
            - „einwaende“: Gegenargumente, die der Text selbst nennt, mit seiner „erwiderung“ (leer, wenn keine). „gegen“: 0 für die Hauptthese, sonst die Nummer des Arguments (das erste ist 1).
            - „staerken“ und „schwaechen“: deine kurze Einschätzung der Argumentation (je 0 bis 3 Punkte).
            """
        case .narrative:
            """
            Analysiere den erzählenden Text.
            - „figuren“: alle Figuren mit Namen (oder Bezeichnung), ihrer „rolle“ und einer Beschreibung in höchstens 12 Wörtern. „stelle“: wo sie zuerst vorkommt.
            - „beziehungen“: wie zwei Figuren zueinander stehen. „von“ und „zu“ sind je genau ein Name aus „figuren“, „art“ hat 1 bis 3 Wörter, z. B. „Bruder von“, „streitet mit“, „hilft“.
            - „schauplaetze“: die Orte der Handlung mit kurzer Beschreibung.
            - „handlung“: die wichtigsten Ereignisse in der Reihenfolge des Textes (3 bis 10), je ein Satz mit höchstens 12 Wörtern, mit den beteiligten Figuren und dem Ort (ein Name aus „schauplaetze“).
            - „erzaehlperspektive“, „zeit“ (wann die Handlung spielt) und „konflikt“ (der zentrale Konflikt): je ein kurzer Satz. „motive“: wiederkehrende Motive oder Themen in Stichworten.
            """
        case .code:
            ""
        case .structure:
            """
            Zeige, wie das Dokument seinen Gegenstand gliedert.
            - „gegenstand“: worum es geht, in höchstens 4 Wörtern.
            - „aspekte“: die Teile, Bereiche oder Gesichtspunkte, die der Text beschreibt (2 bis 7), je mit kurzem „titel“ und den „punkte“n dazu (Stichworte, höchstens 6 Wörter). „details“: Aufzählungen oder Einzelheiten zu einem Punkt (Stichworte, oft leer).
            - „ablauf“: Schritte, die in fester Reihenfolge geschehen, je ein kurzer Satz (leer, wenn der Text keinen Ablauf beschreibt).
            - „zusammenhaenge“: wie Begriffe aus dem Text zusammenhängen, z. B. „versorgt“, „gehört zu“, „bewirkt“ (0 bis 8).
            """
        }
    }

    // MARK: Schemas

    /// A JSON schema whose properties keep their order: the model writes them in this order (names before
    /// relations, places before the events at them), which a Swift dictionary would shuffle.
    indirect enum Schema {
        case string, integer, boolean
        case choice([String])
        case array(Schema, max: Int)
        /// All properties are required.
        case object([(String, Schema)])

        var json: String {
            switch self {
            case .string: return #"{"type":"string"}"#
            case .integer: return #"{"type":"integer"}"#
            case .boolean: return #"{"type":"boolean"}"#
            case .choice(let values):
                return #"{"type":"string","enum":["# + values.map(Self.quoted).joined(separator: ",") + "]}"
            case .array(let items, let max):
                return #"{"type":"array","items":"# + items.json + #","maxItems":\#(max)}"#
            case .object(let properties):
                let fields = properties.map { Self.quoted($0.0) + ":" + $0.1.json }.joined(separator: ",")
                let required = properties.map { Self.quoted($0.0) }.joined(separator: ",")
                return #"{"type":"object","additionalProperties":false,"properties":{"# + fields + #"},"required":["# + required + "]}"
            }
        }

        private static func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }

    static func schema(_ module: ContentAnalysisModule) -> Schema {
        switch module {
        case .overview:
            .object([
                ("textsorte", .choice(TextKind.allCases.map(\.rawValue))),
                ("thema", .string),
                ("zusammenfassung", .string),
                ("kernaussagen", .array(.string, max: 5)),
                ("schluesselbegriffe", .array(.string, max: 8)),
                ("enthaelt", .object([("argumentation", .boolean), ("erzaehlung", .boolean), ("gliederung", .boolean), ("ablauf", .boolean)])),
            ])
        case .argumentation:
            .object([
                ("hauptthese", .object([("text", .string), ("stelle", .integer)])),
                ("argumente", .array(.object([
                    ("titel", .string),
                    ("praemissen", .array(.object([("text", .string), ("stelle", .integer), ("implizit", .boolean)]), max: 5)),
                    ("konklusion", .string),
                    ("stelle", .integer),
                    ("schlussart", .choice(["deduktiv", "induktiv", "kausal", "Analogie", "Beispiel", "Autorität", "praktisch"])),
                    ("stuetzt", .choice(["Hauptthese", "vorheriges Argument"])),
                ]), max: 7)),
                ("einwaende", .array(.object([("text", .string), ("gegen", .integer), ("erwiderung", .string), ("stelle", .integer)]), max: 5)),
                ("staerken", .array(.string, max: 3)),
                ("schwaechen", .array(.string, max: 3)),
            ])
        case .narrative:
            .object([
                ("figuren", .array(.object([
                    ("name", .string),
                    ("rolle", .choice(NarrativeAnalysis.Role.allCases.map(\.rawValue))),
                    ("beschreibung", .string),
                    ("stelle", .integer),
                ]), max: 14)),
                ("beziehungen", .array(.object([("von", .string), ("zu", .string), ("art", .string)]), max: 16)),
                ("schauplaetze", .array(.object([("name", .string), ("beschreibung", .string)]), max: 8)),
                ("handlung", .array(.object([("ereignis", .string), ("figuren", .array(.string, max: 5)), ("ort", .string), ("stelle", .integer)]), max: 10)),
                ("erzaehlperspektive", .string),
                ("zeit", .string),
                ("konflikt", .string),
                ("motive", .array(.string, max: 6)),
            ])
        case .code:
            .object([])
        case .structure:
            .object([
                ("gegenstand", .string),
                ("aspekte", .array(.object([
                    ("titel", .string),
                    ("stelle", .integer),
                    ("punkte", .array(.object([("text", .string), ("details", .array(.string, max: 8))]), max: 6)),
                ]), max: 7)),
                ("ablauf", .array(.object([("schritt", .string), ("stelle", .integer)]), max: 12)),
                ("zusammenhaenge", .array(.object([("von", .string), ("zu", .string), ("art", .string)]), max: 8)),
            ])
        }
    }

    // MARK: Answers

    private struct Located: Decodable {
        let text: String
        let stelle: Int
    }

    private struct OverviewAnswer: Decodable {
        struct Contains: Decodable {
            let argumentation: Bool
            let erzaehlung: Bool
            let gliederung: Bool
            let ablauf: Bool
        }
        let textsorte: TextKind
        let thema: String
        let zusammenfassung: String
        let kernaussagen: [String]
        let schluesselbegriffe: [String]
        let enthaelt: Contains
    }

    private struct ArgumentationAnswer: Decodable {
        struct Premise: Decodable {
            let text: String
            let stelle: Int
            let implizit: Bool
        }
        struct Argument: Decodable {
            let titel: String
            let praemissen: [Premise]
            let konklusion: String
            let stelle: Int
            let schlussart: String
            let stuetzt: String
        }
        struct Objection: Decodable {
            let text: String
            let gegen: Int
            let erwiderung: String
            let stelle: Int
        }
        let hauptthese: Located
        let argumente: [Argument]
        let einwaende: [Objection]
        let staerken: [String]
        let schwaechen: [String]
    }

    private struct NarrativeAnswer: Decodable {
        struct Character: Decodable {
            let name: String
            let rolle: NarrativeAnalysis.Role
            let beschreibung: String
            let stelle: Int
        }
        struct Relation: Decodable {
            let von: String
            let zu: String
            let art: String
        }
        struct Place: Decodable {
            let name: String
            let beschreibung: String
        }
        struct Event: Decodable {
            let ereignis: String
            let figuren: [String]
            let ort: String
            let stelle: Int
        }
        let figuren: [Character]
        let beziehungen: [Relation]
        let schauplaetze: [Place]
        let handlung: [Event]
        let erzaehlperspektive: String
        let zeit: String
        let konflikt: String
        let motive: [String]
    }

    private struct StructureAnswer: Decodable {
        struct Point: Decodable {
            let text: String
            let details: [String]
        }
        struct Aspect: Decodable {
            let titel: String
            let stelle: Int
            let punkte: [Point]
        }
        struct Step: Decodable {
            let schritt: String
            let stelle: Int
        }
        struct Relation: Decodable {
            let von: String
            let zu: String
            let art: String
        }
        let gegenstand: String
        let aspekte: [Aspect]
        let ablauf: [Step]
        let zusammenhaenge: [Relation]
    }

    /// Reads the model's answer for one part into the analysis; places are resolved against the source.
    static func apply(_ answer: String, module: ContentAnalysisModule, source: Source, to analysis: inout ContentAnalysis) throws {
        let data = Data(jsonObject(in: answer).utf8)
        let decoder = JSONDecoder()
        func anchor(_ number: Int) -> DocumentAnchor? {
            // A number between paragraphs (a picture, a rule) means the paragraph before it.
            guard let index = source.keys.keys.filter({ $0 <= number }).max() ?? source.keys.keys.min(),
                  let key = source.keys[index] else { return nil }
            return DocumentAnchor(block: index, key: key)
        }

        switch module {
        case .overview:
            let answer = try decoder.decode(OverviewAnswer.self, from: data)
            var suggested: [ContentAnalysisModule] = []
            if answer.enthaelt.argumentation { suggested.append(.argumentation) }
            if answer.enthaelt.erzaehlung { suggested.append(.narrative) }
            if answer.enthaelt.gliederung || answer.enthaelt.ablauf { suggested.append(.structure) }
            analysis.overview = AnalysisOverview(
                kind: answer.textsorte,
                topic: clean(answer.thema),
                summary: clean(answer.zusammenfassung),
                keyStatements: answer.kernaussagen.map(clean).filter { !$0.isEmpty },
                keywords: unique(answer.schluesselbegriffe.map(clean)),
                suggested: suggested
            )

        case .argumentation:
            let answer = try decoder.decode(ArgumentationAnswer.self, from: data)
            let arguments = answer.argumente.enumerated().compactMap { index, argument -> ArgumentAnalysis.Argument? in
                let conclusion = clean(argument.konklusion)
                guard !conclusion.isEmpty else { return nil }
                return ArgumentAnalysis.Argument(
                    title: clean(argument.titel),
                    premises: argument.praemissen.compactMap { premise in
                        let text = clean(premise.text)
                        return text.isEmpty ? nil : .init(text: text, isImplicit: premise.implizit, anchor: premise.implizit ? nil : anchor(premise.stelle))
                    },
                    conclusion: conclusion,
                    inference: argument.schlussart,
                    supportsPrevious: index > 0 && argument.stuetzt == "vorheriges Argument",
                    anchor: anchor(argument.stelle)
                )
            }
            guard !arguments.isEmpty || !answer.hauptthese.text.isEmpty else { throw noResult }
            analysis.argumentation = ArgumentAnalysis(
                thesis: clean(answer.hauptthese.text),
                thesisAnchor: anchor(answer.hauptthese.stelle),
                arguments: arguments,
                objections: answer.einwaende.compactMap { objection in
                    let text = clean(objection.text)
                    guard !text.isEmpty else { return nil }
                    let target = objection.gegen >= 1 && objection.gegen <= arguments.count ? objection.gegen - 1 : nil
                    return .init(text: text, target: target, rebuttal: clean(objection.erwiderung), anchor: anchor(objection.stelle))
                },
                strengths: answer.staerken.map(clean).filter { !$0.isEmpty },
                weaknesses: answer.schwaechen.map(clean).filter { !$0.isEmpty }
            )

        case .narrative:
            let answer = try decoder.decode(NarrativeAnswer.self, from: data)
            var characters: [NarrativeAnalysis.Character] = []
            for character in answer.figuren {
                let name = clean(character.name)
                guard !name.isEmpty, !characters.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
                characters.append(.init(name: name, role: character.rolle, description: clean(character.beschreibung), anchor: anchor(character.stelle)))
            }
            guard !characters.isEmpty || !answer.handlung.isEmpty else { throw noResult }
            analysis.narrative = NarrativeAnalysis(
                perspective: clean(answer.erzaehlperspektive),
                time: clean(answer.zeit),
                conflict: clean(answer.konflikt),
                characters: characters,
                relations: answer.beziehungen.map { AnalysisRelation(from: clean($0.von), to: clean($0.zu), kind: clean($0.art)) }
                    .filter { !$0.from.isEmpty && !$0.to.isEmpty },
                places: answer.schauplaetze.map { .init(name: clean($0.name), description: clean($0.beschreibung)) }.filter { !$0.name.isEmpty },
                events: answer.handlung.compactMap { event in
                    let text = clean(event.ereignis)
                    return text.isEmpty ? nil : .init(text: text, characters: event.figuren.map(clean).filter { !$0.isEmpty }, place: clean(event.ort), anchor: anchor(event.stelle))
                },
                motifs: unique(answer.motive.map(clean))
            )

        case .code:
            break
        case .structure:
            let answer = try decoder.decode(StructureAnswer.self, from: data)
            let aspects = answer.aspekte.compactMap { aspect -> StructureAnalysis.Aspect? in
                let title = clean(aspect.titel)
                guard !title.isEmpty else { return nil }
                return .init(
                    title: title,
                    points: aspect.punkte.compactMap { point in
                        let text = clean(point.text)
                        return text.isEmpty ? nil : .init(text: text, details: point.details.map(clean).filter { !$0.isEmpty })
                    },
                    anchor: anchor(aspect.stelle)
                )
            }
            guard !aspects.isEmpty || !answer.ablauf.isEmpty else { throw noResult }
            analysis.structure = StructureAnalysis(
                subject: clean(answer.gegenstand),
                aspects: aspects,
                steps: answer.ablauf.compactMap { step in
                    let text = clean(step.schritt)
                    return text.isEmpty ? nil : .init(text: text, anchor: anchor(step.stelle))
                },
                relations: answer.zusammenhaenge.map { AnalysisRelation(from: clean($0.von), to: clean($0.zu), kind: clean($0.art)) }
                    .filter { !$0.from.isEmpty && !$0.to.isEmpty }
            )
        }
    }

    /// The parts that fit the text after the overview: the one for its kind, and arguments a describing text makes.
    static func modules(after overview: AnalysisOverview) -> [ContentAnalysisModule] {
        var modules = [overview.kind.primaryModule]
        if overview.kind.primaryModule == .structure, overview.suggested.contains(.argumentation) {
            modules.append(.argumentation)
        }
        return modules
    }

    private static var noResult: Error {
        LMStudioError.server("Das Modell hat dazu nichts Verwertbares geliefert.")
    }

    static func jsonObject(in answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return trimmed }
        return String(trimmed[start...end])
    }

    /// One line without Markdown stars and without the paragraph numbers the model sometimes copies ("[3]").
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: #"\s*[\[(](Absatz\s*)?\d+(\s*[-–,/]\s*\d+)*[\])]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
