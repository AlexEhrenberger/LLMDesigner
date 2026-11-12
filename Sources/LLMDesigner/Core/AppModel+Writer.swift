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
        if citationStudioOpen { return .citation }
        if storiesStudioOpen { return .stories }
        if notesStudioOpen { return .notes }
        if openProjectID != nil { return .projects }
        guard let document = selectedDocument else { return nil }
        return document.isPresentation ? .presenter : .writer
    }

    /// ⌘F, ⌘G and ⇧⌘G work in an open document or presentation, also from its analysis or the play tab.
    var canFindInDocument: Bool {
        activeApplication == .writer || activeApplication == .presenter
    }

    /// The Format menu (size and alignment) works on the text of the open document or slide.
    var canFormatText: Bool {
        canFindInDocument && writerTab == .document
    }

    func formatText(_ command: (WriterEditorController) -> Void) {
        guard canFormatText, let controller = documentFind?.controller else { return }
        command(controller)
    }

    func findInDocument(_ command: DocumentFind.Command) {
        guard canFindInDocument else { return }
        // The code view searches its own text with the system's find bar.
        if writerTab == .code {
            let item = NSMenuItem()
            item.tag = Int((command == .show ? NSTextFinder.Action.showFindInterface : command == .next ? .nextMatch : .previousMatch).rawValue)
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            return
        }
        if writerTab != .document { showWriterTab(.document) }
        documentFind?.perform(command)
    }

    /// From the applications menu under the composer.
    func openApplication(_ application: StudioApplication) {
        switch application {
        case .writer: newDocument()
        case .citation: openCitationStudio()
        case .presenter: newPresentation()
        case .stories: openStoriesStudio()
        case .notes: openNotesStudio()
        case .projects: newProject()
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
        noteSidebarActivity(id)
    }

    /// Citation Studio takes the main area; choosing a chat or a document closes it again. `showing` selects a
    /// source there (from a citation in a document).
    func openCitationStudio(showing sourceID: UUID? = nil) {
        closeDocument()
        showChats()
        citations.loadIfNeeded()
        citationStudioRequest = sourceID
        citationStudioOpen = true
    }

    func closeCitationStudio() {
        citations.saveAll()
        citationStudioOpen = false
    }

    /// Leaves Writer Studio for the chat that was open before.
    func closeDocument() {
        if citationStudioOpen { closeCitationStudio() }
        if storiesStudioOpen { closeStoriesStudio() }
        if notesStudioOpen { closeNotesStudio() }
        if openProjectID != nil { closeProject() }
        guard let id = selectedDocumentID else { return }
        // Dictation and reading belong to the open document.
        if dictationIntoDocument { Task { await stopDictation() } }
        stopReadingDocument()
        writerFlush?()
        if document(id)?.isPresentation == true {
            presentationPlayer.stop()
            presentationPlayer.exitFullScreen()
            selectedSlideID = nil
            editingSlideFieldID = nil
            editingSlideTextArea = false
        }
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
        ActionHub.shared?.noteDocumentChange(id)
    }

    func setDocumentFont(_ id: WriterDocument.ID, _ font: WriterFont) {
        modifyDocument(id) { $0.font = font }
    }

    /// DIN A4 (the paper of the settings), paperback or Normseite: the editor, the export and the print follow.
    func setPageFormat(_ id: WriterDocument.ID, _ format: WriterPageFormat) {
        guard document(id)?.pageFormat != format else { return }
        modifyDocument(id) { $0.pageFormat = format }
    }

    /// The document is set in the user's own format: paper, margins, text size and line spacing.
    func setPageSetup(_ id: WriterDocument.ID, _ setup: WriterPageSetup) {
        let setup = setup.normalized()
        guard let current = document(id), current.pageFormat != .custom || current.pageSetup != setup else { return }
        modifyDocument(id) {
            $0.pageFormat = .custom
            $0.pageSetup = setup
        }
    }

    /// The lines at the top and the bottom of the printed pages; empty ones take them away.
    func setRunningHeads(_ id: WriterDocument.ID, _ heads: WriterRunningHeads?) {
        let heads = heads?.isEmpty == true ? nil : heads
        guard document(id)?.runningHeads != heads else { return }
        modifyDocument(id) { $0.runningHeads = heads }
    }

    // MARK: Page templates

    /// Saves a format of the user's own in the library, so other documents can use it; one of the same name is replaced.
    func savePageTemplate(_ setup: WriterPageSetup) {
        var setup = setup.normalized()
        if let index = writerPageTemplates.firstIndex(where: { $0.id == setup.id || $0.name == setup.name }) {
            setup.id = writerPageTemplates[index].id
            writerPageTemplates[index] = setup
        } else {
            writerPageTemplates.append(setup)
        }
    }

    func deletePageTemplate(_ id: WriterPageSetup.ID) {
        writerPageTemplates.removeAll { $0.id == id }
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
            documentOutlineErrors[id] = "Kein Modell gewählt. Wähle eines unten links in der Seitenleiste."
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

    func moveDocument(_ id: WriterDocument.ID, to folderID: Folder.ID?, reveal: Bool = true) {
        guard let document = document(id), document.folderID != folderID else { return }
        modifyDocument(id) { $0.folderID = folderID }
        if reveal, let folderID { expandFolder(folderID) }
    }

    func moveDocumentToNewFolder(_ id: WriterDocument.ID) {
        moveDocument(id, to: createFolder(for: .chats))
    }

    func deleteDocument(_ id: WriterDocument.ID) {
        documentOutlineTasks[id]?.cancel()
        deleteAnalysis(id)
        documentSaveTasks[id]?.cancel()
        documentSaveTasks[id] = nil
        let pictures = document(id)?.pictureSources ?? []
        documents.removeAll { $0.id == id }
        documentStore.delete(id)
        // Its pictures go too, unless another document shows them (copied and pasted, or taken into a handout).
        WriterImageStore.removeUnused(pictures, stillUsedIn: documents.map(\.pictureSources))
        if selectedDocumentID == id { selectedDocumentID = nil }
    }

    /// A document in a given state again (undo of an action, its origin). Saved at once, because it didn't come from typing.
    func restoreDocument(_ document: WriterDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index] = document
        saveDocument(document.id)
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

/// A document made ready for export and print, see `AppModel.prepareExport(of:)`.
struct WriterExportInput {
    let document: WriterDocument
    let markdown: String
    let figures: [String: URL]
    let printFigures: [String: URL]
    let bibliography: [StyledText]
    let part: LaTeXWriter.Part
}

/// The formats a Writer Studio document can be saved as.
enum WriterExportFormat: CaseIterable, Identifiable {
    case pdf, latex, markdown, plainMarkdown

    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: "Als PDF …"
        case .latex: "Als LaTeX (.tex) …"
        case .markdown: "Als Markdown (.md) …"
        case .plainMarkdown: "Als reines Markdown (ohne Farben, Schriften) …"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .latex: "function"
        case .markdown: "number"
        case .plainMarkdown: "number.square"
        }
    }

    var type: UTType {
        switch self {
        case .pdf: .pdf
        case .latex: UTType(filenameExtension: "tex") ?? .plainText
        case .markdown, .plainMarkdown: UTType(filenameExtension: "md") ?? .plainText
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
            let input = await prepareExport(of: document)
            let current = input.document
            let part = input.part

            do {
                switch format {
                case .markdown, .plainMarkdown, .latex:
                    exportingIDs.remove(document.id)
                    guard let url = await askForDestination(fileName: current.displayTitle, type: format.type) else { return }
                    // The pictures go into a folder next to the file, e.g. "Aufsatz-Bilder".
                    try writeTextExport(input, as: format, paper: paper, to: url)
                case .pdf:
                    guard let engine else { return }
                    let pdf = try await engine.makePDF(parts: [part], paper: paper, typeface: current.pageFormat.font(current.font), format: current.pageFormat,
                                                       design: current.pageDesign)
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

    /// Writes Markdown, plain Markdown or LaTeX source; the pictures go into a folder next to the file, e.g. "Aufsatz-Bilder".
    func writeTextExport(_ input: WriterExportInput, as format: WriterExportFormat, paper: PaperSize, to url: URL) throws {
        let current = input.document
        let used = format == .latex ? input.printFigures : input.figures
        let folder = used.isEmpty ? nil : figureFolderName(for: url)
        if let folder {
            try copyFigures(Array(used.values), to: url.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true))
        }
        let text: String
        if format != .latex {
            var exported = CitationExport.expandBibliography(in: WriterMarkdownExport.expandTableOfContents(in: input.markdown, outline: current.outline),
                                                             entries: input.bibliography)
            // Plain Markdown is for programs that only know Markdown: no colours, fonts, bookmarks or underline.
            if format == .plainMarkdown { exported = WriterMarkdownExport.plain(exported) }
            text = folder.map { folder in
                WriterImageStore.rewriteSources(in: exported) { input.figures[$0].map { folder + "/" + $0.lastPathComponent } }
            } ?? exported
        } else {
            text = LaTeXWriter.document(parts: [input.part], paper: paper, math: .native, figureFolder: folder,
                                        typeface: current.pageFormat.font(current.font), format: current.pageFormat, design: current.pageDesign)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Everything an export or a print needs of a document: its text, the pictures on this Mac, the reference list,
    /// and the text as a LaTeX part with citations set in APA and the table of contents made.
    func prepareExport(of document: WriterDocument) async -> WriterExportInput {
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
        // Citations are set in APA for LaTeX and PDF; the Markdown keeps Pandoc's `[@key]`.
        citations.loadIfNeeded()
        let style = CitationStyle(sources: citations.sources, cited: CitationMarkup.keys(in: markdown))
        let bibliography = style.bibliography(CitationMarkup.keys(in: markdown)).map(\.text)
        var part = LaTeXWriter.Part(text: CitationExport.resolve(markdown, style: style))
        part.figures = printFigures
        part.bibliography = bibliography
        if let contents = latexContents(of: current.outline, in: markdown) {
            part.contents = contents.outline
            part.blockAnchors = contents.anchors
        }
        return WriterExportInput(document: current, markdown: markdown, figures: figures, printFigures: printFigures,
                                 bibliography: bibliography, part: part)
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

    /// A chat or document dragged onto a folder (nil: out of its folder). The folder swallows it and stays as it is.
    func moveSidebarItem(_ id: UUID, to folderID: Folder.ID?) {
        if document(id) != nil {
            moveDocument(id, to: folderID, reveal: false)
        } else {
            moveChat(id, to: folderID, reveal: false)
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
    /// Markdown without what Markdown can't say: the spans of colours, fonts and bookmarks and the underline tags go;
    /// the text stays. (The Markdown the library stores keeps them, as HTML in the text, which most programs show.)
    static func plain(_ markdown: String) -> String {
        WriterBookmark.strip(WriterMarkdown.removingDivFences(markdown))
            .replacingOccurrences(of: "<u>", with: "")
            .replacingOccurrences(of: "</u>", with: "")
    }

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
