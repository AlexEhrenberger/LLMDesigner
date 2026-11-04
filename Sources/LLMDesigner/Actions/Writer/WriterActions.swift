import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerWriterActions() {
        registerWriterDocumentActions()
        registerWriterReadActions()
        registerWriterTextActions()
        registerWriterFormatActions()
        registerWriterBlockActions()
        registerWriterMoreActions()
    }
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

extension AppModel {
    /// A folder of the chat and document list by id or name.
    func actionChatFolder(_ reference: String) throws -> Folder {
        if let id = UUID(uuidString: reference), let folder = chatFolders.first(where: { $0.id == id }) { return folder }
        let found = chatFolders.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Ordner „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Ordner heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    /// A new document without opening it: an agent's work doesn't take the screen away from the person.
    func createDocumentForAction(title: String?, folderID: Folder.ID?, markdown: String, provenance: DocumentProvenance?) -> WriterDocument {
        var document = WriterDocument()
        document.folderID = folderID
        document.font = documents.first { !$0.isPresentation }?.font ?? .serif
        document.provenance = provenance
        document.markdown = markdown
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            document.title = title
            document.hasCustomTitle = true
        } else {
            document.title = WriterDocument.makeTitle(from: markdown)
        }
        documents.insert(document, at: 0)
        saveDocument(document.id)
        return document
    }

    /// Removes a document again when its creation is taken back.
    func removeDocumentForActionUndo(_ id: WriterDocument.ID) {
        if selectedDocumentID == id { selectedDocumentID = nil }
        documents.removeAll { $0.id == id }
        documentStore.delete(id)
    }

    func reinsertDocumentForActionRedo(_ document: WriterDocument) {
        guard !documents.contains(where: { $0.id == document.id }) else { return }
        documents.insert(document, at: 0)
        saveDocument(document.id)
    }
}
