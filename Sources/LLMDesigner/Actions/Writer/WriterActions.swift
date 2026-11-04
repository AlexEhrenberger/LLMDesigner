import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerWriterActions() {
        register(WriterDocListAction.self)
        register(WriterDocReadAction.self)
    }
    func registerPresenterActions() {}
    func registerCitationActions() {}
    func registerStoriesActions() {}
    func registerChatActions() {}
}

/// The fingerprint of a text: every read returns it, and a write can demand `ifVersion`, so an agent doesn't overwrite
/// what the person changed in between.
enum ActionVersion {
    static func of(_ text: String) -> String {
        // FNV-1a: no secret involved, it only has to tell two texts apart and stay the same across runs.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension AppModel {
    /// A Writer document by id or by its title. A title that fits several documents is an error, not a guess.
    func actionDocument(_ reference: String, presentation: Bool = false) throws -> WriterDocument {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = presentation ? "Präsentation" : "Dokument"
        let candidates = documents.filter { $0.isPresentation == presentation }
        if let id = UUID(uuidString: reference) {
            guard let document = candidates.first(where: { $0.id == id }) else { throw RPCError.notFound("\(kind) \(reference) gibt es nicht.") }
            return document
        }
        let matching = candidates.filter { $0.displayTitle == reference }
        let found = matching.isEmpty ? candidates.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame } : matching
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("\(kind) „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Dokumente heißen „\(reference)“. Bitte die ID verwenden.", candidates: found.map(\.id.uuidString))
    }
}

struct WriterDocListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var folder: String?
        var query: String?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var updated: Date
        var folder: String?
        var words: Int
    }
    struct Output: Encodable, Sendable {
        var documents: [Item]
    }

    static let descriptor = ActionDescriptor(
        id: "writer.doc.list", summary: "Listet die Dokumente", kind: .read, security: .plainRead,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "query": .string("Suchtext in Titel und Inhalt")]),
        output: .freeObject(), example: "llmd writer doc list --query Bericht", groups: ["core", "writer.core"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let folderID = try args.folder.map { try app.actionChatFolder($0).id }
        let items = app.documents
            .filter { !$0.isPresentation && (args.query.map($0.matches) ?? true) && (folderID == nil || $0.folderID == folderID) }
            .map { document in
                Item(id: document.id.uuidString, title: document.displayTitle, updated: document.updatedAt,
                     folder: document.folderID.flatMap { id in app.chatFolders.first { $0.id == id }?.name },
                     words: document.markdown.split(whereSeparator: \.isWhitespace).count)
            }
        return Output(documents: items)
    }
}

struct WriterDocReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var format: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var text: String
        var version: String
    }

    static let descriptor = ActionDescriptor(
        id: "writer.doc.read", summary: "Liest ein Dokument", kind: .read, security: .plainRead,
        input: .object(["doc": .string("Dokument (ID oder Titel)"), "format": .choice(["markdown", "plain"], "Standard: markdown")], required: ["doc"]),
        output: .freeObject(), example: "llmd writer doc read Bericht --format plain", groups: ["core", "writer.core"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.doc)
        let text = args.format == "plain" ? PowerText.plain(document.markdown) : document.markdown
        return Output(id: document.id.uuidString, title: document.displayTitle, text: text, version: ActionVersion.of(document.markdown))
    }
}

extension AppModel {
    /// A folder of the chat and document list by id or name.
    func actionChatFolder(_ reference: String) throws -> Folder {
        if let id = UUID(uuidString: reference), let folder = chatFolders.first(where: { $0.id == id }) { return folder }
        let found = chatFolders.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Ordner „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Ordner heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }
}
