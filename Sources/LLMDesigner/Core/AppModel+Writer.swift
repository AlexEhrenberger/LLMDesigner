import SwiftUI

/// What the dictation hands the open document.
enum WriterDictationEvent {
    /// Words that are still being recognised; shown grey and replaced by the next update.
    case volatile(String)
    /// Recognised text that goes into the document.
    case final(String)
    case ended
}

/// Writer Studio: documents in the sidebar next to the chats, opened instead of the chat.
extension AppModel {
    var selectedDocument: WriterDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    func document(_ id: WriterDocument.ID) -> WriterDocument? {
        documents.first { $0.id == id }
    }

    /// The application in the main area; nil while the chat is shown.
    var activeApplication: StudioApplication? {
        selectedDocumentID != nil ? .writer : nil
    }

    /// From the applications menu under the composer.
    func openApplication(_ application: StudioApplication) {
        switch application {
        case .writer: newDocument()
        case .presenter, .notes: break
        }
    }

    // MARK: Opening and closing

    /// Creates an empty document and opens it in Writer Studio. Left empty, it disappears again.
    func newDocument(inFolder folderID: Folder.ID? = nil) {
        closeDocument()
        searchText = ""
        var document = WriterDocument()
        document.folderID = folderID ?? newChatFolderID
        document.font = documents.first?.font ?? .serif
        documents.insert(document, at: 0)
        if let folderID = document.folderID { expandFolder(folderID) }
        showChats()
        selectedDocumentID = document.id
    }

    func selectDocument(_ id: WriterDocument.ID) {
        guard selectedDocumentID != id else { return showChats() }
        closeDocument()
        showChats()
        selectedDocumentID = id
    }

    /// Leaves Writer Studio for the chat that was open before.
    func closeDocument() {
        guard let id = selectedDocumentID else { return }
        // Dictation and reading belong to the open document.
        if dictationIntoDocument { Task { await stopDictation() } }
        stopReadingDocument()
        writerFlush?()
        selectedDocumentID = nil
        if let document = document(id), document.isEmpty, !document.hasCustomTitle {
            deleteDocument(id)
        } else {
            saveDocument(id)
        }
    }

    // MARK: Changes

    /// The editor reports the text as Markdown; it is written to disk once the user pauses.
    func updateDocument(_ id: WriterDocument.ID, markdown: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].markdown != markdown else { return }
        documents[index].markdown = markdown
        documents[index].updatedAt = Date()
        if !documents[index].hasCustomTitle {
            documents[index].title = WriterDocument.makeTitle(from: markdown)
        }
        saveDocument(id, after: .milliseconds(700))
    }

    func setDocumentFont(_ id: WriterDocument.ID, _ font: WriterFont) {
        modifyDocument(id) { $0.font = font }
    }

    func renameDocument(_ id: WriterDocument.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modifyDocument(id) {
            $0.title = trimmed
            $0.hasCustomTitle = true
        }
    }

    /// The title follows the first line of the text again.
    func useAutomaticDocumentTitle(_ id: WriterDocument.ID) {
        modifyDocument(id) {
            $0.hasCustomTitle = false
            $0.title = WriterDocument.makeTitle(from: $0.markdown)
        }
    }

    func moveDocument(_ id: WriterDocument.ID, to folderID: Folder.ID?) {
        guard let document = document(id), document.folderID != folderID else { return }
        modifyDocument(id) { $0.folderID = folderID }
        if let folderID { expandFolder(folderID) }
    }

    func moveDocumentToNewFolder(_ id: WriterDocument.ID) {
        moveDocument(id, to: createFolder(for: .chats))
    }

    func deleteDocument(_ id: WriterDocument.ID) {
        documentSaveTasks[id]?.cancel()
        documentSaveTasks[id] = nil
        documents.removeAll { $0.id == id }
        documentStore.delete(id)
        if selectedDocumentID == id { selectedDocumentID = nil }
    }

    private func modifyDocument(_ id: WriterDocument.ID, _ change: (inout WriterDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        change(&documents[index])
        saveDocument(id)
    }

    // MARK: Saving

    /// Writes the document to disk, right away or after a pause in typing.
    func saveDocument(_ id: WriterDocument.ID, after delay: Duration? = nil) {
        documentSaveTasks[id]?.cancel()
        documentSaveTasks[id] = nil
        guard let delay else {
            if let document = document(id) { documentStore.save(document) }
            return
        }
        documentSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.documentSaveTasks[id] = nil
            if let document = self.document(id) { self.documentStore.save(document) }
        }
    }

    func savePendingDocuments() {
        writerFlush?()
        for id in Array(documentSaveTasks.keys) { saveDocument(id) }
    }
}

extension AppModel {
    /// A chat or document dragged onto a folder (nil: out of its folder).
    func moveSidebarItem(_ id: UUID, to folderID: Folder.ID?) {
        if document(id) != nil {
            moveDocument(id, to: folderID)
        } else {
            moveChat(id, to: folderID)
        }
    }
}
