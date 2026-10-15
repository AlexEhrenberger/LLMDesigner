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
        writerTab = .document
        selectedDocumentID = document.id
    }

    func selectDocument(_ id: WriterDocument.ID) {
        guard selectedDocumentID != id else { return showChats() }
        closeDocument()
        showChats()
        writerTab = .document
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

    // MARK: Table of contents

    func setDocumentTOCMode(_ id: WriterDocument.ID, _ mode: WriterTOCMode) {
        guard document(id)?.effectiveTOCMode != mode || document(id)?.tocMode == nil else { return }
        modifyDocument(id) { $0.tocMode = mode }
    }

    /// Asks the model for the document's topics (the dynamic table of contents). Returns the running task.
    @discardableResult
    func refreshDocumentOutline(_ id: WriterDocument.ID) -> Task<Void, Never>? {
        writerFlush?()
        if let running = documentOutlineTasks[id] { return running }
        guard let client, let model = currentModelId, let snapshot = document(id) else {
            documentOutlineErrors[id] = "Kein Modell gewählt. Wähle eines unten links in der Seitenleiste („LM Studio verbunden“)."
            return nil
        }
        let markdown = snapshot.markdown
        guard !DocumentOutlineBuilder.blocks(of: markdown).isEmpty else { return nil }
        documentOutlineGeneratingIDs.insert(id)
        documentOutlineErrors[id] = nil
        let request = DocumentOutlineBuilder.requestMessages(for: markdown)
        let task = Task { [weak self] in
            do {
                let answer = try await client.complete(
                    model: model, messages: request, temperature: 0.1, maxTokens: 1_500,
                    jsonSchema: (DocumentOutlineBuilder.schemaName, DocumentOutlineBuilder.schema)
                )
                let outline = try DocumentOutlineBuilder.parse(answer, markdown: markdown, model: model)
                // Written into the stored document without touching its text or date.
                if let self, let index = self.documents.firstIndex(where: { $0.id == id }) {
                    self.documents[index].outline = outline
                    self.saveDocument(id)
                }
            } catch {
                if !Task.isCancelled { self?.documentOutlineErrors[id] = error.localizedDescription }
            }
            self?.documentOutlineGeneratingIDs.remove(id)
            self?.documentOutlineTasks[id] = nil
        }
        documentOutlineTasks[id] = task
        return task
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
        documentOutlineTasks[id]?.cancel()
        deleteAnalysis(id)
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
        let paper = pdfPaperSize
        let engine = LaTeXEngine.locate()
        if format == .pdf, engine == nil {
            exportError = PDFExportError.noEngine.localizedDescription
            return
        }
        exportingIDs.insert(document.id)
        Task {
            // A dynamic table of contents in the text is brought up to date first, like the chat export does.
            if WriterTOCAttachment.kind(in: document.markdown) == true, client != nil,
               document.outline == nil || DocumentOutlineBuilder.isOutdated(document) {
                await refreshDocumentOutline(document.id)?.value
            }
            let current = self.document(document.id) ?? document
            let markdown = current.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            // The pictures that are on this Mac, by their Markdown source; LaTeX prints a plot's PDF version.
            var figures: [String: URL] = [:]
            var printFigures: [String: URL] = [:]
            for reference in markdown.components(separatedBy: "\n").compactMap(WriterImageReference.parse) {
                if let url = WriterImageStore.url(for: reference.source) { figures[reference.source] = url }
                if let url = WriterImageStore.printURL(for: reference) { printFigures[reference.source] = url }
            }
            var part = LaTeXWriter.Part(text: markdown)
            part.figures = printFigures
            if let contents = latexContents(of: current.outline, in: markdown) {
                part.contents = contents.outline
                part.blockAnchors = contents.anchors
            }

            do {
                switch format {
                case .markdown, .latex:
                    exportingIDs.remove(document.id)
                    guard let url = await askForDestination(fileName: current.displayTitle, type: format.type) else { return }
                    // The pictures go into a folder next to the file, e.g. "Aufsatz-Bilder".
                    let used = format == .markdown ? figures : printFigures
                    let folder = used.isEmpty ? nil : figureFolderName(for: url)
                    if let folder {
                        try copyFigures(Array(used.values), to: url.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true))
                    }
                    let text: String
                    if format == .markdown {
                        let exported = WriterMarkdownExport.expandTableOfContents(in: markdown, outline: current.outline)
                        text = folder.map { folder in
                            WriterImageStore.rewriteSources(in: exported) { figures[$0].map { folder + "/" + $0.lastPathComponent } }
                        } ?? exported
                    } else {
                        text = LaTeXWriter.document(parts: [part], paper: paper, math: .native, figureFolder: folder)
                    }
                    try text.write(to: url, atomically: true, encoding: .utf8)
                case .pdf:
                    guard let engine else { return }
                    let pdf = try await engine.makePDF(parts: [part], paper: paper)
                    exportingIDs.remove(document.id)
                    guard let url = await askForDestination(fileName: current.displayTitle, type: .pdf) else { return }
                    try pdf.write(to: url, options: .atomic)
                    if pdfOpenAfterExport { NSWorkspace.shared.open(url) }
                }
            } catch {
                exportingIDs.remove(document.id)
                exportError = error.localizedDescription
            }
        }
    }

    /// The model's table of contents for LaTeX: its entries, and labels in front of the blocks they point to.
    private func latexContents(of outline: DocumentOutline?, in markdown: String) -> (outline: LaTeXWriter.Outline, anchors: [Int: String])? {
        guard WriterTOCAttachment.kind(in: markdown) == true, let outline else { return nil }
        var anchors: [Int: String] = [:]
        func label(_ anchor: DocumentAnchor) -> String? {
            guard let index = DocumentOutlineBuilder.blockIndex(of: anchor, in: markdown) else { return nil }
            if let existing = anchors[index] { return existing }
            let label = "inhalt-\(anchors.count + 1)"
            anchors[index] = label
            return label
        }
        var entries: [LaTeXWriter.OutlineEntry] = []
        for section in outline.sections {
            entries.append(.init(title: section.title, level: 0, label: label(section.anchor)))
            for item in section.items { entries.append(.init(title: item.title, level: 1, label: label(item.anchor))) }
        }
        return (LaTeXWriter.Outline(summary: outline.summary, entries: entries), anchors)
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

/// Markdown for other programs: the table of contents marker becomes a list of the headings with links.
enum WriterMarkdownExport {
    static func expandTableOfContents(in markdown: String, outline: DocumentOutline? = nil) -> String {
        if WriterTOCAttachment.kind(in: markdown) == true {
            // The model's topics as a numbered list with their points.
            var lines: [String] = []
            for (index, section) in (outline?.sections ?? []).enumerated() {
                lines.append("\(index + 1). \(section.title)")
                lines += section.items.map { "   - \($0.title)" }
            }
            let block = "**Inhaltsverzeichnis**\n\n" + (lines.isEmpty ? "*(noch nicht erstellt)*" : lines.joined(separator: "\n"))
            return markdown.components(separatedBy: "\n").map { WriterTOCAttachment.kind(of: $0) == true ? block : $0 }.joined(separator: "\n")
        }
        guard WriterHeadings.isFormal(markdown) else { return markdown }
        let headings = WriterHeadings.headings(in: markdown)
        let top = headings.map(\.level).min() ?? 0
        var used: [String: Int] = [:]
        let list = headings.map { heading -> String in
            let plain = WriterHeadings.plainTitle(heading.title)
            var anchor = slug(plain)
            if let count = used[anchor] { used[anchor] = count + 1; anchor += "-\(count)" } else { used[anchor] = 1 }
            let indent = String(repeating: "  ", count: heading.level - top)
            return indent + "- [" + [heading.number, plain].compactMap { $0 }.joined(separator: " ") + "](#\(anchor))"
        }.joined(separator: "\n")
        let block = "**Inhaltsverzeichnis**\n\n" + (list.isEmpty ? "*(keine Überschriften)*" : list)
        return markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) == WriterTOCAttachment.marker ? block : $0 }
            .joined(separator: "\n")
    }

    /// The anchor GitHub and others give a heading: lower case, spaces as hyphens, without punctuation.
    private static func slug(_ text: String) -> String {
        String(text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return character == " " ? "-" : nil
        })
    }
}
