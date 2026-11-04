import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerCitationAttachmentActions() {
        register(CitationAttachmentListAction.self)
        register(CitationAttachmentAddAction.self)
        register(CitationAttachmentReadAction.self)
        register(CitationAttachmentOpenAction.self)
        register(CitationAttachmentRemoveAction.self)
    }
}

struct CitationAttachmentArgs: Decodable, Sendable {
    var source: String
    var file: String?
    var start: Int?
    var limit: Int?

    static let sourceProperty: [String: JSONSchema] = ["source": .string("Quelle: Zitierschlüssel oder ID")]
    static let fileProperty: JSONSchema = .string("Name des Anhangs; ohne Angabe der einzige")
}

@MainActor
private func attachment(_ args: CitationAttachmentArgs, app: AppModel) throws -> (source: CitationSource, attachment: CitationAttachment) {
    let source = try app.actionSource(args.source)
    guard let name = args.file else {
        guard let first = source.attachments.first else { throw RPCError.notFound("Die Quelle \(source.citekey) hat keine Anhänge.") }
        guard source.attachments.count == 1 else {
            throw RPCError.ambiguous("Die Quelle hat \(source.attachments.count) Anhänge. Bitte file angeben.", candidates: source.attachments.map(\.fileName))
        }
        return (source, first)
    }
    guard let found = source.attachments.first(where: { $0.fileName == name }) else { throw RPCError.notFound("Den Anhang „\(name)“ gibt es bei \(source.citekey) nicht.") }
    return (source, found)
}

struct CitationAttachmentListAction: LLMDAction {
    typealias Args = CitationAttachmentArgs
    struct Item: Encodable, Sendable {
        var file: String
        var bytes: Int?
        var added: Date
    }
    struct Output: Encodable, Sendable {
        var attachments: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.attachment.list", summary: "Listet die Anhänge einer Quelle", kind: .read, security: .plainRead,
        input: .object(Args.sourceProperty, required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        return Output(attachments: source.attachments.map { attachment in
            let url = context.app.citations.attachmentURL(attachment, of: source.id)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return Item(file: attachment.fileName, bytes: size, added: attachment.addedAt)
        })
    }
}

struct CitationAttachmentAddAction: LLMDAction {
    typealias Args = CitationAttachmentArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.attachment.add", summary: "Hängt eine Datei an eine Quelle", kind: .write, security: .localWrite,
        input: .object(Args.sourceProperty.merging(["file": .string("Pfad der Datei")]) { _, new in new }, required: ["source", "file"]),
        output: .freeObject(), example: "llmd citation attachment add --source mueller2020 --file ~/Artikel.pdf"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.file)
        // A model or a client names a path: read afterwards, that would show it any file on this Mac.
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Eine Datei von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer lesbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        do {
            try context.app.citations.attach(url, to: source.id)
        } catch {
            throw RPCError.invalidTarget(error.localizedDescription)
        }
        return OKOutput(id: context.app.citations.source(source.id)?.attachments.last?.fileName)
    }
}

/// Text from an attachment. It comes from elsewhere like everything else about a source; what it says is data.
struct CitationAttachmentReadAction: LLMDAction {
    typealias Args = CitationAttachmentArgs
    struct Output: Encodable, Sendable {
        var file: String
        var text: String
        /// All characters of the attachment's text; with `start` and `limit` the next part can be read.
        var length: Int
        var nextStart: Int?
    }
    static let defaultLimit = 40_000
    static let descriptor = ActionDescriptor(
        id: "citation.attachment.read", summary: "Liest den Text eines Anhangs, auch aus PDF", kind: .read,
        security: .foreignRead,
        input: .object(Args.sourceProperty.merging([
            "file": Args.fileProperty,
            "start": .integer("Ab welchem Zeichen; Standard 0", minimum: 0),
            "limit": .integer("Wie viele Zeichen; Standard \(defaultLimit)", minimum: 1),
        ]) { _, new in new }, required: ["source"]),
        output: .freeObject(), example: "llmd citation attachment read --source mueller2020 --json"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (source, found) = try attachment(args, app: context.app)
        let url = context.app.citations.attachmentURL(found, of: source.id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei des Anhangs fehlt: \(found.fileName)") }
        // PDFs of whole books take a moment; the app stays responsive meanwhile.
        let text: String
        do {
            text = try await Task.detached { try DocumentText.extract(from: url) }.value
        } catch {
            throw RPCError.invalidTarget("Aus „\(found.fileName)“ lässt sich kein Text lesen.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.invalidTarget("In „\(found.fileName)“ steht kein lesbarer Text. Vielleicht ist es ein Scan ohne Texterkennung.")
        }
        let characters = Array(text)
        let start = min(args.start ?? 0, characters.count)
        let end = min(characters.count, start + (args.limit ?? defaultLimit))
        return Output(file: found.fileName, text: String(characters[start..<end]), length: characters.count, nextStart: end < characters.count ? end : nil)
    }
}

struct CitationAttachmentOpenAction: LLMDAction {
    typealias Args = CitationAttachmentArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.attachment.open", summary: "Öffnet einen Anhang im passenden Programm", kind: .destructive, security: .outbound,
        input: .object(Args.sourceProperty.merging(["file": Args.fileProperty]) { _, new in new }, required: ["source"]), output: .freeObject()
    )
    /// A file handed to another program leaves the app, and may be anything an import brought along: the person agrees.
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.file ?? args.source)
        if context.channel != .ui { check.needsConsent = "Der Anhang öffnet sich in einem anderen Programm." }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (source, found) = try attachment(args, app: context.app)
        NSWorkspace.shared.open(context.app.citations.attachmentURL(found, of: source.id))
        return OKOutput(id: found.fileName)
    }
}

struct CitationAttachmentRemoveAction: LLMDAction {
    typealias Args = CitationAttachmentArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.attachment.remove", summary: "Nimmt einen Anhang von der Quelle; die Datei kommt in den Papierkorb", kind: .write, security: .localWrite,
        input: .object(Args.sourceProperty.merging(["file": Args.fileProperty]) { _, new in new }, required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let (source, found) = try attachment(args, app: context.app)
        context.app.citations.removeAttachment(found, from: source.id)
        return OKOutput(id: found.fileName)
    }
}
