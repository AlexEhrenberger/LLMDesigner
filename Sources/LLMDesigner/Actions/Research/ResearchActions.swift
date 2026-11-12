import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerResearchActions() {
        register(ResearchListAction.self)
        register(ResearchReadAction.self)
        register(ResearchStartAction.self)
        register(ResearchAnswerAction.self)
        register(ResearchStopAction.self)
        register(ResearchSourceSetAction.self)
        register(ResearchReportAction.self)
        register(ResearchToDocumentAction.self)
        register(ResearchToPodcastAction.self)
        register(ResearchDeleteAction.self)
        register(ResearchStudioOpenAction.self)
        register(ResearchStudioCloseAction.self)
    }
}

/// A research holds web pages and abstracts: reading it is reading something foreign.
let researchRead = ActionSecurity.foreignRead
let researchProperty: JSONSchema = .string("Recherche (ID oder Titel)")

extension AppModel {
    func actionResearch(_ reference: String) throws -> Research {
        research.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let found = research.research(id) else { throw RPCError.notFound("Recherche \(reference) gibt es nicht.") }
            return found
        }
        let all = research.records.records
        let found = all.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let partial = all.filter { $0.displayTitle.localizedCaseInsensitiveContains(reference) || $0.question.localizedCaseInsensitiveContains(reference) }
        if found.isEmpty, partial.count == 1 { return partial[0] }
        if found.isEmpty, partial.isEmpty { throw RPCError.notFound("Recherche „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Recherchen passen zu „\(reference)“. Bitte die ID verwenden.", candidates: (found.isEmpty ? partial : found).map(\.id.uuidString))
    }
}

struct ResearchSummaryOutput: Encodable, Sendable {
    var id: String
    var title: String
    var question: String
    var phase: String
    var progress: Int?
    var focus: String?
    var questions: Int
    var sources: Int
    var hasReport: Bool
}

extension AppModel {
    func actionResearchSummary(_ item: Research) -> ResearchSummaryOutput {
        ResearchSummaryOutput(id: item.id.uuidString, title: item.displayTitle, question: item.question, phase: item.phase.rawValue,
                              progress: research.progress[item.id].map { Int(($0.fraction * 100).rounded()) }, focus: item.focus,
                              questions: item.nodes.filter { $0.parent != nil }.count, sources: item.sources.count, hasReport: !item.report.isEmpty)
    }
}

struct ResearchListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
    }
    struct Output: Encodable, Sendable {
        var researches: [ResearchSummaryOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "research.list", summary: "Listet die Recherchen mit Phase, Fortschritt, Zahl der Teilfragen und Quellen", kind: .read, security: .plainRead,
        input: .object(["query": .string("Suche in Titel, Frage und Bericht")]), output: .freeObject(), groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.research.loadIfNeeded()
        return Output(researches: app.research.records.records.filter { $0.matches(args.query ?? "") }.map { app.actionResearchSummary($0) })
    }
}

struct ResearchReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
        var include: String?
    }
    struct Node: Encodable, Sendable {
        var id: String
        var parent: String?
        var question: String
        var status: String
        var summary: String?
        var sources: [Int]
    }
    struct Source: Encodable, Sendable {
        var number: Int
        var kind: String
        var title: String
        var url: String
        var byline: String?
        var accepted: Bool?
    }
    struct Output: Encodable, Sendable {
        var research: ResearchSummaryOutput
        var clarification: ResearchClarification?
        var tree: [Node]?
        var sources: [Source]?
        var report: String?
    }
    static let descriptor = ActionDescriptor(
        id: "research.read", summary: "Liest eine Recherche: Rückfrage, Fragenbaum mit Zusammenfassungen, Quellen und Bericht", kind: .read, security: researchRead,
        input: .object(["research": researchProperty, "include": .choice(["alles", "baum", "quellen", "bericht", "kurz"], "Was mitkommt (Vorgabe alles)")], required: ["research"]),
        output: .freeObject(), groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let item = try app.actionResearch(args.research)
        let include = args.include ?? "alles"
        guard ["alles", "baum", "quellen", "bericht", "kurz"].contains(include) else { throw RPCError.invalidParams("include: alles, baum, quellen, bericht oder kurz.") }
        var output = Output(research: app.actionResearchSummary(item), clarification: item.clarification?.question.isEmpty == false ? item.clarification : nil)
        if include == "alles" || include == "baum" {
            output.tree = item.nodes.map { node in
                Node(id: node.id.uuidString, parent: node.parent?.uuidString, question: node.question, status: node.status.rawValue,
                     summary: node.summary.isEmpty ? nil : node.summary, sources: node.sources.compactMap { item.source($0)?.number })
            }
        }
        if include == "alles" || include == "quellen" {
            output.sources = item.sources.sorted { $0.number < $1.number }.map {
                Source(number: $0.number, kind: $0.kind.rawValue, title: $0.title, url: $0.url, byline: $0.byline.isEmpty ? nil : $0.byline, accepted: $0.accepted)
            }
        }
        if include == "alles" || include == "bericht" { output.report = item.report.isEmpty ? nil : item.report }
        return output
    }
}

struct ResearchStartAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var question: String?
        var research: String?
        var sources: [String]?
        var depth: String?
        var focus: String?
        var language: String?
        var thinking: Bool?
        var open: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var started: Bool
        var message: String?
    }
    static let descriptor = ActionDescriptor(
        id: "research.start",
        summary: "Startet eine gründliche Recherche (Deep Research) zu einer Frage oder setzt eine fort; sie läuft im Hintergrund. Aus dem Chat öffnet sie Rechercherista.",
        // Search words leave the Mac: acting outwards, which the rules treat like a destructive step (the person is asked).
        kind: .destructive, security: .outbound,
        input: .object([
            "question": .string("Der Forschungsauftrag"), "research": .string("Bestehende Recherche fortsetzen (ID oder Titel)"),
            "sources": .array(of: .choice(ResearchSourceKind.allCases.map(\.rawValue)), "Quellen (Vorgabe alle)"),
            "depth": .choice(ResearchDepth.allCases.map(\.rawValue), "Gründlichkeit (Vorgabe gruendlich)"),
            "focus": .string("Was gemeint ist, falls mehrdeutig"), "language": .choice(["de", "en"], "Sprache"), "thinking": .boolean("Denkmodus"),
            "open": .boolean("Rechercherista öffnen (im Chat Vorgabe ja)"),
        ]),
        output: .freeObject(), example: "llmd research start --question \"Predictive Coding\" --focus Kognitionswissenschaft --depth gruendlich", groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.research.loadIfNeeded()
        let id: UUID
        if let reference = args.research {
            id = try app.actionResearch(reference).id
        } else {
            guard let question = args.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                throw RPCError.invalidParams("question oder research angeben.")
            }
            let chatID = context.channel == .chat ? app.selectedChatID : nil
            id = app.newResearch(question: question, fromChat: chatID, open: false).id
            let library = app.research.records
            context.undoGroup.add(UndoStep(label: "Recherche anlegen", undo: { [weak app] in app?.stopResearch(id); library.remove(id) }, redo: {}))
        }
        let kinds = try args.sources?.map { text -> ResearchSourceKind in
            guard let kind = ResearchSourceKind(rawValue: text) else { throw RPCError.invalidParams("Quelle „\(text)“ gibt es nicht.") }
            return kind
        }
        let depth = try ProjectArgs.choice(args.depth, ResearchDepth.allCases, raw: \.rawValue, "Tiefe")
        app.research.records.update(id) { item in
            if let kinds, !kinds.isEmpty { item.sourceKinds = kinds }
            if let depth { item.depth = depth }
            if let language = args.language { item.language = language }
            if let thinking = args.thinking { item.thinking = thinking }
            if let focus = args.focus, !focus.isEmpty { item.clarification = ResearchClarification(question: "", options: [], answer: focus) }
        }
        let problem = app.startResearch(id)
        if args.open ?? (context.channel == .chat) { app.openResearchStudio(showing: id) }
        return Output(id: id.uuidString, started: problem == nil, message: problem ?? "Läuft im Hintergrund. Mit research.read sehen, wie weit sie ist.")
    }
}

struct ResearchAnswerAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
        var answer: String
    }
    static let descriptor = ActionDescriptor(
        id: "research.answer", summary: "Beantwortet die Rückfrage einer Recherche (was gemeint ist); sie läuft dann weiter", kind: .destructive,
        security: .outbound,
        input: .object(["research": researchProperty, "answer": .string("Antwort, z. B. eine der Optionen")], required: ["research", "answer"]),
        output: .freeObject(), groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let item = try app.actionResearch(args.research)
        guard item.phase == .rueckfrage else { throw RPCError.invalidTarget("Die Recherche wartet auf keine Antwort (Phase: \(item.phase.label)).") }
        app.answerResearch(item.id, args.answer)
        return OKOutput(id: item.id.uuidString)
    }
}

struct ResearchStopAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
    }
    static let descriptor = ActionDescriptor(
        id: "research.stop", summary: "Hält eine laufende Recherche an; research.start mit research setzt sie fort", kind: .write, security: .localWrite,
        input: .object(["research": researchProperty], required: ["research"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let item = try context.app.actionResearch(args.research)
        context.app.stopResearch(item.id)
        return OKOutput(id: item.id.uuidString)
    }
}

struct ResearchSourceSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
        var number: Int
        var accepted: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "research.source.set", summary: "Nimmt eine Quelle einer Recherche an (accepted true), verwirft sie (false) oder lässt sie offen", kind: .write, security: .localWrite,
        input: .object(["research": researchProperty, "number": .integer("Nummer der Quelle", minimum: 1), "accepted": .boolean("Annehmen oder verwerfen; weglassen: offen")],
                       required: ["research", "number"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let item = try app.actionResearch(args.research)
        guard let source = item.sources.first(where: { $0.number == args.number }) else { throw RPCError.notFound("Quelle [\(args.number)] gibt es nicht.") }
        let before = item
        app.research.records.update(item.id) { item in
            if let index = item.sources.firstIndex(where: { $0.id == source.id }) { item.sources[index].accepted = args.accepted }
        }
        let library = app.research.records
        context.undoGroup.add(UndoStep(label: "Quelle", undo: { [weak library] in library?.restore(before) }, redo: {}))
        return OKOutput(id: source.id.uuidString)
    }
}

struct ResearchReportAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
    }
    struct Output: Encodable, Sendable {
        var report: String
    }
    static let descriptor = ActionDescriptor(
        id: "research.report", summary: "Gibt den Bericht einer fertigen Recherche als Markdown mit Quellenverzeichnis", kind: .read, security: researchRead,
        input: .object(["research": researchProperty], required: ["research"]), output: .freeObject(), groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let item = try context.app.actionResearch(args.research)
        guard !item.report.isEmpty else { throw RPCError.invalidTarget("Die Recherche hat noch keinen Bericht (Phase: \(item.phase.label)).") }
        return Output(report: item.report)
    }
}

struct ResearchToDocumentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
        var open: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "research.toDocument", summary: "Macht aus dem Bericht ein Writer-Dokument (mit Quellen); für eine Präsentation danach presenter.fromDocument", kind: .write, security: .localWrite,
        input: .object(["research": researchProperty, "open": .boolean("Öffnen")], required: ["research"]), output: .freeObject(), groups: ["research.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let item = try app.actionResearch(args.research)
        guard let document = app.researchDocument(item.id, open: args.open == true) else { throw RPCError.invalidTarget("Die Recherche hat noch keinen Bericht.") }
        let id = document.id
        context.undoGroup.add(UndoStep(label: "Bericht als Dokument", undo: { [weak app] in app?.deleteDocument(id) }, redo: {}))
        return OKOutput(id: document.id.uuidString)
    }
}

struct ResearchToPodcastAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
    }
    static let descriptor = ActionDescriptor(
        id: "research.toPodcast", summary: "Legt einen Podcast über die Recherche an (ihr Bericht wird sein Material) und öffnet PodcastStudio", kind: .write, security: .localWrite,
        input: .object(["research": researchProperty], required: ["research"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let item = try app.actionResearch(args.research)
        guard let podcast = app.researchPodcast(item.id) else { throw RPCError.invalidTarget("Die Recherche hat noch keinen Bericht.") }
        return OKOutput(id: podcast.id.uuidString)
    }
}

struct ResearchDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String
    }
    static let descriptor = ActionDescriptor(
        id: "research.delete", summary: "Legt eine Recherche in den Papierkorb", kind: .destructive, security: .destructive,
        input: .object(["research": researchProperty], required: ["research"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionResearch(args.research).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let item = try app.actionResearch(args.research)
        app.stopResearch(item.id)
        let library = app.research.records
        library.remove(item.id)
        context.undoGroup.add(UndoStep(label: "Recherche löschen", undo: { [weak library] in library?.restore(item) }, redo: { [weak library] in library?.remove(item.id) }))
        return OKOutput(id: item.id.uuidString)
    }
}

struct ResearchStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var research: String?
    }
    static let descriptor = ActionDescriptor(
        id: "research.studio.open", summary: "Öffnet Rechercherista, auf Wunsch bei einer Recherche", kind: .read, security: .plainRead,
        input: .object(["research": researchProperty]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let id = try args.research.map { try app.actionResearch($0).id }
        app.openResearchStudio(showing: id)
        return OKOutput(id: id?.uuidString)
    }
}

struct ResearchStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "research.studio.close", summary: "Schließt Rechercherista", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeResearchStudio()
        return OKOutput()
    }
}
