import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerCitationStudioActions() {
        register(CitationStudioOpenAction.self)
        register(CitationStudioCloseAction.self)
        register(CitationViewShelfAction.self)
        register(CitationViewFilterTagsAction.self)
        register(CitationViewSelectAction.self)
    }
}

struct CitationStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.studio.open", summary: "Öffnet das Citation Studio, wenn gewünscht bei einer Quelle", kind: .read, security: .plainRead,
        input: .object(["source": .string("Quelle: Zitierschlüssel oder ID")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let source = try args.source.map { try context.app.actionSource($0) }
        context.app.openCitationStudio(showing: source?.id)
        return OKOutput(id: source?.id.uuidString)
    }
}

struct CitationStudioCloseAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.studio.close", summary: "Schließt das Citation Studio", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.closeCitationStudio()
        return OKOutput()
    }
}

/// The studio must be open for a view to change; an action opens it rather than failing.
@MainActor
private func showInStudio(_ command: CitationStudioCommand, app: AppModel) {
    app.citationStudioCommand = command
    if !app.citationStudioOpen { app.openCitationStudio() }
}

struct CitationViewShelfAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var shelf: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.view.shelf", summary: "Zeigt im Citation Studio die Quellen oder die Wissensbausteine", kind: .read, security: .plainRead,
        input: .object(["shelf": .choice(CitationStudioModel.Mode.allCases.map(\.rawValue), "Das Regal")], required: ["shelf"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let mode = CitationStudioModel.Mode(rawValue: args.shelf) else { throw RPCError.invalidParams("Dieses Regal gibt es nicht.") }
        showInStudio(.shelf(mode), app: context.app)
        return OKOutput()
    }
}

struct CitationViewFilterTagsAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var tags: [String]
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.view.filterTags", summary: "Filtert die Liste im Citation Studio nach Schlagworten; leer zeigt alles", kind: .read, security: .plainRead,
        input: .object(["tags": .array(of: .string(), "Schlagworte")], required: ["tags"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        showInStudio(.filterTags(args.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }), app: context.app)
        return OKOutput()
    }
}

struct CitationViewSelectAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String?
        var quote: String?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.view.select", summary: "Zeigt im Citation Studio eine Quelle; bei einem Baustein dessen Quelle", kind: .read, security: .plainRead,
        input: .object(["source": .string("Quelle: Zitierschlüssel oder ID"), "quote": .string("Baustein (ID)")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let id: UUID
        if let reference = args.source {
            id = try context.app.actionSource(reference).id
        } else if let reference = args.quote {
            id = try context.app.actionQuote(reference).sourceID
        } else {
            throw RPCError.invalidParams("Bitte source oder quote angeben.")
        }
        showInStudio(.select(source: id), app: context.app)
        return OKOutput(id: id.uuidString)
    }
}
