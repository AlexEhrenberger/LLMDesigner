import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterAnalysisActions() {
        register(WriterAnalysisRunAction.self)
        register(WriterAnalysisGetAction.self)
        register(WriterAnalysisCancelAction.self)
        register(WriterAnalysisDeleteAction.self)
        register(WriterDocAutoTitleAction.self)
    }
}

struct WriterAnalysisArgs: Decodable, Sendable {
    var doc: String
    var modules: [String]?
    var wait: Bool?

    static let docProperty: [String: JSONSchema] = ["doc": .string("Dokument oder Präsentation (ID oder Titel)")]
}

/// What's known about a document's analysis.
struct WriterAnalysisState: Encodable, Sendable {
    var doc: String
    var running: Bool
    var current: String?
    var pending: [String]
    var errors: [String: String]
    var outdated: Bool
    var modules: [String]

    @MainActor
    init(_ document: WriterDocument, app: AppModel) {
        doc = document.id.uuidString
        running = app.isAnalyzing(document.id)
        current = app.analysisProgress[document.id]?.current?.rawValue
        pending = app.analysisProgress[document.id]?.pending.map(\.rawValue) ?? []
        errors = Dictionary(uniqueKeysWithValues: (app.analysisErrors[document.id] ?? [:]).map { ($0.key.rawValue, $0.value) })
        outdated = app.isAnalysisOutdated(document)
        modules = app.analysis(of: document.id)?.modules.map(\.rawValue) ?? []
    }
}

struct WriterAnalysisRunAction: LLMDAction {
    typealias Args = WriterAnalysisArgs
    typealias Output = WriterAnalysisState
    static let descriptor = ActionDescriptor(
        id: "writer.analysis.run", summary: "Das geladene Modell macht die Inhaltsanalyse; ohne modules der Überblick und was er nahelegt", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging([
            "modules": .array(of: .choice(ContentAnalysisModule.allCases.filter(\.isModelWork).map(\.rawValue)), "Einzelne Teile"),
            "wait": .boolean("Auf das Ergebnis warten; Standard: true"),
        ]) { _, new in new }, required: ["doc"]),
        output: .freeObject(), example: "llmd writer analysis run --doc Bericht"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocumentOrDeck(args.doc)
        // The model reads the text, and what it makes of it stays visible to whoever reads the analysis.
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocumentOrDeck(args.doc)
        let id = document.id
        guard !app.isAnalyzing(id) else { throw RPCError.invalidTarget("Die Analyse dieses Dokuments läuft schon. writer.analysis.get zeigt den Stand.") }
        let modules = (args.modules ?? []).compactMap(ContentAnalysisModule.init(rawValue:))
        app.analyzeDocument(id, adding: modules.first)
        if !app.isAnalyzing(id), let problem = app.analysisErrors[id]?[.overview] {
            throw RPCError.unavailable(problem)
        }
        // Further parts one after the other: the app makes one at a time.
        let work = Task { @MainActor in
            await app.analysisTasks[id]?.value
            for module in modules.dropFirst() where !Task.isCancelled {
                guard app.document(id) != nil else { return }
                app.analyzeDocument(id, adding: module)
                await app.analysisTasks[id]?.value
            }
        }
        if args.wait != false { await work.value }
        return WriterAnalysisState(app.document(id) ?? document, app: app)
    }
}

struct WriterAnalysisGetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    struct Output: Encodable, Sendable {
        var state: WriterAnalysisState
        var analysis: ContentAnalysis?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.analysis.get", summary: "Liest die Inhaltsanalyse eines Dokuments", kind: .read, security: .plainRead,
        input: .object(WriterAnalysisArgs.docProperty, required: ["doc"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocumentOrDeck(args.doc)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocumentOrDeck(args.doc)
        context.app.loadAnalysisIfNeeded(document.id)
        return Output(state: WriterAnalysisState(document, app: context.app), analysis: context.app.analysis(of: document.id))
    }
}

struct WriterAnalysisCancelAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.analysis.cancel", summary: "Bricht die laufende Inhaltsanalyse ab; Fertiges bleibt", kind: .write, security: .localWrite,
        input: .object(WriterAnalysisArgs.docProperty, required: ["doc"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let document = try context.app.actionDocumentOrDeck(args.doc)
        context.app.cancelAnalysis(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

struct WriterAnalysisDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.analysis.delete", summary: "Löscht die Inhaltsanalyse eines Dokuments; der Text bleibt", kind: .write, security: .localWrite,
        input: .object(WriterAnalysisArgs.docProperty, required: ["doc"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let document = try app.actionDocumentOrDeck(args.doc)
        app.loadAnalysisIfNeeded(document.id)
        let id = document.id
        let old = app.analysis(of: id)
        app.deleteAnalysis(id)
        if let old {
            context.undoGroup.add(UndoStep(label: context.undoGroup.label, undo: {
                app.documentAnalyses[id] = old
                app.analysisStore.save(old, for: id)
            }, redo: { app.deleteAnalysis(id) }))
        }
        return OKOutput(id: id.uuidString)
    }
}

struct WriterDocAutoTitleAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.doc.autoTitle", summary: "Der Titel folgt wieder dem Text", kind: .write, security: .localWrite,
        input: .object(WriterAnalysisArgs.docProperty, required: ["doc"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocumentOrDeck(args.doc)
        context.app.useAutomaticDocumentTitle(document.id)
        context.noteChange(of: document.id, before: document)
        return Output(id: document.id.uuidString, title: context.app.document(document.id)?.displayTitle ?? "")
    }
}
