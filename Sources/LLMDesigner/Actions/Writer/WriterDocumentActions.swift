import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerWriterDocumentActions() {
        register(WriterDocListAction.self)
        register(WriterDocCreateAction.self)
        register(WriterDocOpenAction.self)
        register(WriterDocCloseAction.self)
        register(WriterDocRenameAction.self)
        register(WriterDocMoveAction.self)
        register(WriterDocDuplicateAction.self)
        register(WriterDocSaveAction.self)
        register(WriterDocDeleteAction.self)
        register(WriterDocConfirmAction.self)
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
        var herkunft: String?
    }
    struct Output: Encodable, Sendable {
        var documents: [Item]
    }

    static let descriptor = ActionDescriptor(
        id: "writer.doc.list", summary: "Listet die Dokumente", kind: .read, security: .plainRead,
        input: .object(["folder": .string("Ordner (ID oder Name)"), "query": .string("Suchtext in Titel und Inhalt")]),
        output: .freeObject(), example: "llmd writer doc list --query Bericht", groups: ["core", "writer.core"]
    )

    private static func listed(_ args: Args, app: AppModel) throws -> [WriterDocument] {
        let folderID = try args.folder.map { try app.actionChatFolder($0).id }
        return app.documents.filter { !$0.isPresentation && (args.query.map($0.matches) ?? true) && (folderID == nil || $0.folderID == folderID) }
    }

    /// Titles are text too; a foreign document's title can carry instructions.
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try listed(args, app: context.app).contains(where: \.isForeign))
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        return Output(documents: try listed(args, app: app).map { document in
            Item(id: document.id.uuidString, title: document.displayTitle, updated: document.updatedAt,
                 folder: document.folderID.flatMap { id in app.chatFolders.first { $0.id == id }?.name },
                 words: document.markdown.split(whereSeparator: \.isWhitespace).count, herkunft: document.provenance?.rawValue)
        })
    }
}

struct WriterDocCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String?
        var folder: String?
        var markdown: String?
        var format: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var version: String
    }

    static let descriptor = ActionDescriptor(
        id: "writer.doc.create", summary: "Legt ein Dokument an", kind: .write, security: .localWrite,
        input: .object([
            "title": .string("Titel; ohne ihn folgt er der ersten Zeile"), "folder": .string("Ordner (ID oder Name)"),
            "markdown": .string("Anfangstext"), "format": .choice(WriterPageFormat.allCases.map(\.rawValue), "Seitenformat"),
        ]),
        output: .freeObject(), example: "llmd writer doc create --title Bericht --json", groups: ["core", "writer.core"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let folderID = try args.folder.map { try app.actionChatFolder($0).id }
        var document = app.createDocumentForAction(title: args.title, folderID: folderID, markdown: args.markdown ?? "", provenance: context.mergedProvenance(nil))
        if let format = args.format.flatMap(WriterPageFormat.init(rawValue:)) {
            document.pageFormat = format
            app.restoreDocument(document)
        }
        let created = document
        context.undoGroup.documents.insert(created.id)
        context.undoGroup.add(UndoStep(label: "Dokument anlegen", undo: { app.removeDocumentForActionUndo(created.id) }, redo: { app.reinsertDocumentForActionRedo(created) }))
        return Output(id: created.id.uuidString, title: created.displayTitle, version: ActionVersion.of(created.markdown))
    }
}

struct DocumentArgs: Decodable, Sendable {
    var doc: String
}

struct OKOutput: Encodable, Sendable {
    var ok = true
    var id: String?
    var message: String?
}

private let docProperty: [String: JSONSchema] = ["doc": .string("Dokument (ID oder Titel)")]

struct WriterDocOpenAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "writer.doc.open", summary: "Zeigt ein Dokument in Writer Studio", kind: .read, security: .plainRead,
        input: .object(docProperty, required: ["doc"]), output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: DocumentArgs, context: ActionContext) async throws -> OKOutput {
        let document = try context.app.actionDocument(args.doc)
        context.app.selectDocument(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

struct WriterDocCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "writer.doc.close", summary: "Schließt das geöffnete Dokument", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeDocument()
        return OKOutput()
    }
}

struct WriterDocRenameAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var title: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.doc.rename", summary: "Benennt ein Dokument um", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument (ID oder Titel)"), "title": .string("Neuer Titel")], required: ["doc", "title"]),
        output: .freeObject(), groups: ["writer.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let document = try context.app.actionDocument(args.doc)
        context.app.renameDocument(document.id, to: args.title)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: document.id.uuidString)
    }
}

struct WriterDocMoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var folder: String?
        var newFolder: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.doc.move", summary: "Verschiebt ein Dokument in einen Ordner", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument (ID oder Titel)"), "folder": .string("Ordner (ID oder Name); ohne ihn: aus dem Ordner heraus"), "newFolder": .string("Name eines neuen Ordners")], required: ["doc"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let document = try app.actionDocument(args.doc)
        let folderID: Folder.ID?
        if let name = args.newFolder {
            let id = app.createFolder(for: .chats)
            app.renameFolder(id, to: name)
            folderID = id
        } else {
            folderID = try args.folder.map { try app.actionChatFolder($0).id }
        }
        app.moveDocument(document.id, to: folderID, reveal: false)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: document.id.uuidString)
    }
}

struct WriterDocDuplicateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var title: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.doc.duplicate", summary: "Kopiert ein Dokument", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument (ID oder Titel)"), "title": .string("Titel der Kopie")], required: ["doc"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        // The copy carries the original's origin along; the run itself reads nothing back.
        ActionPreflight(target: try context.app.actionDocument(args.doc).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        var copy = try app.actionDocument(args.doc)
        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.title = args.title ?? copy.displayTitle + " (Kopie)"
        copy.hasCustomTitle = true
        copy.provenance = context.mergedProvenance(copy.provenance)
        app.reinsertDocumentForActionRedo(copy)
        let made = copy
        context.undoGroup.add(UndoStep(label: "Dokument kopieren", undo: { app.removeDocumentForActionUndo(made.id) }, redo: { app.reinsertDocumentForActionRedo(made) }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct WriterDocSaveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.doc.save", summary: "Schreibt ein Dokument sofort auf die Platte", kind: .write, security: .localWrite,
        input: .object(docProperty), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        if let reference = args.doc {
            app.saveDocument(try app.actionDocument(reference).id)
        } else {
            app.savePendingDocuments()
        }
        return OKOutput()
    }
}

struct WriterDocDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "writer.doc.delete", summary: "Löscht ein Dokument endgültig", kind: .destructive, security: .destructive,
        input: .object(docProperty, required: ["doc"]), output: .freeObject()
    )
    static func preflight(_ args: DocumentArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionDocument(args.doc).displayTitle)
    }
    static func run(_ args: DocumentArgs, context: ActionContext) async throws -> OKOutput {
        let document = try context.app.actionDocument(args.doc)
        context.app.deleteDocument(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}

/// Only the person can vouch for a text (safety concept, 4.1). So this always asks, one document at a time.
struct WriterDocConfirmAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "writer.doc.confirmReviewed", summary: "Bestätigt ein fremdes Dokument als geprüft", kind: .write, security: .localWrite,
        input: .object(docProperty, required: ["doc"]), output: .freeObject()
    )
    static func preflight(_ args: DocumentArgs, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        var check = ActionPreflight(target: document.displayTitle)
        check.needsConsent = "Danach gilt der Text als deiner: Anweisungen darin würden nicht mehr als fremd behandelt. Hast du ihn gelesen?"
        check.detail = String(document.markdown.prefix(ActionApproval.detailLimit))
        return check
    }
    static func run(_ args: DocumentArgs, context: ActionContext) async throws -> OKOutput {
        var document = try context.app.actionDocument(args.doc)
        guard context.channel == .ui || !context.run.hasReadUntrusted || context.channel == .cli else {
            throw RPCError.denied("Ein Lauf mit fremden Inhalten kann nichts als geprüft bestätigen, auch nicht nach Rückfrage.")
        }
        document.provenance = .own
        context.app.restoreDocument(document)
        return OKOutput(id: document.id.uuidString, message: "Als geprüft bestätigt.")
    }
}
