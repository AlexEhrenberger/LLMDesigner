import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerStoriesLinkActions() {
        register(StoriesDocumentsLinkAction.self)
        register(StoriesDocumentsUnlinkAction.self)
        register(StoriesDocumentsListAction.self)
    }
}

/// Documents and presentations marked as belonging to a world or one of its parts ("Dazugehörige Dokumente").
struct StoriesDocumentsArgs: Decodable, Sendable {
    var world: String
    var part: String?
    var doc: String?
}

private let linkInput: [String: JSONSchema] = [
    "world": .string("Romanwelt (ID oder Titel)"),
    "part": .string("Buch, Akt, Kapitel oder Abschnitt (ID oder Pfad Buch/Akt/…); ohne Angabe die Welt selbst"),
]

@MainActor
private func changeLinks(_ args: StoriesDocumentsArgs, context: ActionContext, label: String, _ change: (inout [UUID]) -> Void) throws {
    let world = try context.app.actionWorld(args.world)
    let part = try args.part.map { try world.actionPart($0).id }
    try context.changeWorld(world.id, label: label) { world in
        if let part { world.updatePart(part) { change(&$0.linkedDocuments) } } else { change(&world.linkedDocuments) }
    }
}

struct StoriesDocumentsLinkAction: LLMDAction {
    typealias Args = StoriesDocumentsArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.documents.link", summary: "Markiert ein Dokument oder eine Präsentation als zugehörig zu einer Welt, einem Buch, Akt, Kapitel oder Abschnitt",
        kind: .write, security: .localWrite,
        input: .object(linkInput.merging(["doc": .string("Dokument oder Präsentation (ID oder Titel)")]) { _, new in new }, required: ["world", "doc"]),
        output: .freeObject(), example: "llmd stories documents link Eldoria --part 'Buch 1/Akt 1' --doc Recherche"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocumentOrDeck(args.doc ?? "")
        try changeLinks(args, context: context, label: "Dokument verknüpfen") { ids in
            if !ids.contains(document.id) { ids.append(document.id) }
        }
        return OKOutput(id: document.id.uuidString)
    }
}

struct StoriesDocumentsUnlinkAction: LLMDAction {
    typealias Args = StoriesDocumentsArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "stories.documents.unlink", summary: "Löst die Verknüpfung eines Dokuments; das Dokument bleibt",
        kind: .write, security: .localWrite,
        input: .object(linkInput.merging(["doc": .string("Dokument oder Präsentation (ID oder Titel)")]) { _, new in new }, required: ["world", "doc"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let reference = args.doc ?? ""
        // A deleted document can still be unlinked by its id.
        let id = try UUID(uuidString: reference) ?? context.app.actionDocumentOrDeck(reference).id
        try changeLinks(args, context: context, label: "Verknüpfung lösen") { $0.removeAll { $0 == id } }
        return OKOutput(id: id.uuidString)
    }
}

struct StoriesDocumentsListAction: LLMDAction {
    typealias Args = StoriesDocumentsArgs
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var kind: String
        /// Where it is linked: "Welt" or the part's path.
        var linkedAt: String
    }
    struct Output: Encodable, Sendable {
        var documents: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "stories.documents.list", summary: "Listet die verknüpften Dokumente einer Welt oder eines Teils, samt denen der Unterteile",
        kind: .read, security: .foreignRead, input: .object(linkInput, required: ["world"]), output: .freeObject(),
        example: "llmd stories documents list Eldoria --json"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let world = try app.actionWorld(args.world)
        var found: [(UUID, String)] = []
        func collect(_ part: StoryPart) {
            let path = (world.path(to: part.id).map { world.displayTitle(of: $0) }).joined(separator: "/")
            found += part.linkedDocuments.map { ($0, path) }
            part.children.forEach(collect)
        }
        if let reference = args.part {
            collect(try world.actionPart(reference))
        } else {
            found += world.linkedDocuments.map { ($0, "Welt") }
            world.books.forEach(collect)
        }
        return Output(documents: found.compactMap { id, place in
            guard let document = app.document(id) else { return nil }
            return Item(id: id.uuidString, title: document.displayTitle, kind: document.isPresentation ? "Präsentation" : "Dokument", linkedAt: place)
        })
    }
}
