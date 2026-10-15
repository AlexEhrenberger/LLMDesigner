import SwiftUI
import UniformTypeIdentifiers

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
        let pictures = document(id).map { WriterImageStore.sources(in: $0.markdown) } ?? []
        documents.removeAll { $0.id == id }
        documentStore.delete(id)
        // Its pictures go too, unless another document shows them (copied and pasted).
        WriterImageStore.removeUnused(pictures, stillUsedIn: documents.map(\.markdown))
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

/// The formats a Writer Studio document can be saved as.
enum WriterExportFormat: CaseIterable, Identifiable {
    case pdf, latex, markdown

    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: "Als PDF …"
        case .latex: "Als LaTeX (.tex) …"
        case .markdown: "Als Markdown (.md) …"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .latex: "function"
        case .markdown: "number"
        }
    }

    var type: UTType {
        switch self {
        case .pdf: .pdf
        case .latex: UTType(filenameExtension: "tex") ?? .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

extension AppModel {
    /// Saves the open document as PDF (typeset with LaTeX), as LaTeX source or as Markdown.
    func exportDocument(as format: WriterExportFormat) {
        writerFlush?()
        guard let document = selectedDocument, !exportingIDs.contains(document.id) else { return }
        let markdown = document.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        // The pictures that are on this Mac, by their Markdown source.
        var figures: [String: URL] = [:]
        for source in WriterImageStore.sources(in: markdown) {
            if let url = WriterImageStore.url(for: source) { figures[source] = url }
        }
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = figures
        let paper = pdfPaperSize

        switch format {
        case .markdown, .latex:
            Task {
                guard let url = await askForDestination(fileName: document.displayTitle, type: format.type) else { return }
                do {
                    // The pictures go into a folder next to the file, e.g. "Aufsatz-Bilder".
                    let folder = figures.isEmpty ? nil : figureFolderName(for: url)
                    if let folder {
                        try copyFigures(Array(figures.values), to: url.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true))
                    }
                    let text: String
                    if format == .markdown {
                        text = folder.map { folder in
                            WriterImageStore.rewriteSources(in: markdown) { figures[$0].map { folder + "/" + $0.lastPathComponent } }
                        } ?? markdown
                    } else {
                        text = LaTeXWriter.document(parts: [part], paper: paper, math: .native, figureFolder: folder)
                    }
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    exportError = error.localizedDescription
                }
            }
        case .pdf:
            guard let engine = LaTeXEngine.locate() else {
                exportError = PDFExportError.noEngine.localizedDescription
                return
            }
            exportingIDs.insert(document.id)
            Task {
                do {
                    let pdf = try await engine.makePDF(parts: [part], paper: paper)
                    exportingIDs.remove(document.id)
                    guard let url = await askForDestination(fileName: document.displayTitle, type: .pdf) else { return }
                    try pdf.write(to: url, options: .atomic)
                    if pdfOpenAfterExport { NSWorkspace.shared.open(url) }
                } catch {
                    exportingIDs.remove(document.id)
                    exportError = error.localizedDescription
                }
            }
        }
    }

    /// A chat or document dragged onto a folder (nil: out of its folder).
    func moveSidebarItem(_ id: UUID, to folderID: Folder.ID?) {
        if document(id) != nil {
            moveDocument(id, to: folderID)
        } else {
            moveChat(id, to: folderID)
        }
    }
}

/// "Mein Aufsatz.tex" → "Mein-Aufsatz-Bilder": no spaces or LaTeX specials, so `\\includegraphics` takes it.
private func figureFolderName(for file: URL) -> String {
    let stem = file.deletingPathExtension().lastPathComponent
    let cleaned = String(stem.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        .split(separator: "-").joined(separator: "-")
    return (cleaned.isEmpty ? "Dokument" : cleaned) + "-Bilder"
}

private func copyFigures(_ files: [URL], to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in Set(files) {
        let destination = folder.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
    }
}
