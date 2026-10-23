import AppKit

/// Flow charts of code in the content analysis can go into the document: a picture right below the code block, which
/// LaTeX prints as a vector graphic. In a presentation they get a slide of their own after the slide with the code.
extension AppModel {
    static func flowchartKey(_ id: WriterDocument.ID, _ graph: FlowGraph, _ snippet: CodeSnippet) -> String {
        "\(id.uuidString)|\(snippet.id)|\(graph.title)"
    }

    func adoptFlowchart(_ graph: FlowGraph, of snippet: CodeSnippet, in id: WriterDocument.ID) {
        let key = Self.flowchartKey(id, graph, snippet)
        guard !adoptingFlowcharts.contains(key), let document = document(id) else { return }
        writerFlush?()
        adoptingFlowcharts.insert(key)
        let isPresentation = document.isPresentation
        Task {
            defer { adoptingFlowcharts.remove(key) }
            do {
                let images = try await FlowImageRenderer.shared.images(for: graph, opaque: isPresentation)
                if isPresentation {
                    try addFlowchartSlide(graph, images: images, snippet: snippet, to: id)
                } else {
                    try insertFlowchartPicture(graph, images: images, snippet: snippet, into: id)
                }
                adoptedFlowcharts.insert(key)
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    // MARK: Document

    private func insertFlowchartPicture(_ graph: FlowGraph, images: FlowImageRenderer.Images, snippet: CodeSnippet, into id: WriterDocument.ID) throws {
        guard let document = self.document(id) else { return }
        let source = try WriterImageStore.storeDiagram(light: images.light, dark: images.dark, pdf: images.pdf)
        // Wide charts take the column, narrow ones about the share they need.
        let width = max(35, min(90, Int(images.size.width / WriterImageStore.referenceColumnWidth * 100 * 0.85)))
        let reference = WriterImageReference(source: source, caption: "Ablauf: " + graph.title, width: width, isDiagram: true)
        guard let result = FlowchartInsertion.insert(reference, below: snippet.code, in: document.markdown) else {
            showNotice("Der Code-Block steht nicht mehr im Dokument. Das Flussdiagramm wurde nicht eingefügt.")
            WriterImageStore.removeUnused([source], stillUsedIn: [])
            return
        }
        updateDocument(id, markdown: result.markdown)
        // A chart that was replaced leaves its files behind otherwise.
        if let replaced = result.replacedSource {
            WriterImageStore.removeUnused([replaced], stillUsedIn: documents.map(\.pictureSources))
        }
        if selectedDocumentID == id { showNotice("Das Flussdiagramm steht unter dem Code im Dokument.") }
    }

    // MARK: Presentation

    private func addFlowchartSlide(_ graph: FlowGraph, images: FlowImageRenderer.Images, snippet: CodeSnippet, to id: WriterDocument.ID) throws {
        guard let deck = document(id)?.deck else { return }
        let source = try WriterImageStore.storeDiagram(light: images.light, dark: images.light, pdf: images.pdf)
        // After the slide whose text holds the code (and after the chart slides already made for it).
        let host = deck.slideIndex(forBlock: snippet.block)?.slide
        var after = host.map { deck.slides[$0].id }
        if let host {
            var next = host + 1
            while next < deck.slides.count, deck.slides[next].markdown.hasPrefix("# Ablauf") { after = deck.slides[next].id; next += 1 }
        }
        let title = "# Ablauf: " + graph.title.replacingOccurrences(of: "def ", with: "")
        guard let slideID = addSlide(to: id, after: after, role: .content, markdown: title) else { return }
        // The chart below the title, as large as the slide allows.
        let canvas = SlideImage.canvas
        let available = CGSize(width: canvas.width - 80, height: canvas.height - 100)
        let aspect = max(0.2, images.size.width / max(1, images.size.height))
        var height = min(available.height, available.width / aspect)
        var width = height * aspect
        if width > available.width { width = available.width; height = width / aspect }
        let frame = CGRect(x: (canvas.width - width) / 2, y: 84 + (available.height - height) / 2, width: width, height: height)
        setSlideImages(id, slideID, [SlideImage(source: source, caption: "Ablauf: " + graph.title, frame: frame, placement: .front)], undoManager: nil, actionName: "Flussdiagramm")
    }
}

/// Puts a picture line below a code block in a document's Markdown.
enum FlowchartInsertion {
    struct Result {
        let markdown: String
        /// The source of the picture that was replaced (a chart with the same caption below the block).
        let replacedSource: String?
    }

    /// The picture goes below the fenced block that holds `code`, after the charts that are already there; a chart with
    /// the same caption is replaced. nil when the block is not in the text.
    static func insert(_ reference: WriterImageReference, below code: String, in markdown: String) -> Result? {
        var lines = markdown.components(separatedBy: "\n")
        guard let end = blockEnd(of: code, in: lines) else { return nil }
        // The pictures right below the block (blank lines between them don't end the run).
        var position = end + 1
        var lastPicture: Int?
        var replace: Int?
        var replacedSource: String?
        var scan = position
        while scan < lines.count {
            let line = lines[scan].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { scan += 1; continue }
            guard let existing = WriterImageReference.parse(line), existing.isDiagram else { break }
            lastPicture = scan
            if existing.caption == reference.caption { replace = scan; replacedSource = existing.source }
            scan += 1
        }
        if let replace {
            lines[replace] = reference.markdown
        } else {
            position = (lastPicture ?? end) + 1
            lines.insert(contentsOf: ["", reference.markdown], at: position)
            // A blank line after the picture keeps the next paragraph apart.
            if position + 2 < lines.count, !lines[position + 2].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: position + 2)
            }
        }
        return Result(markdown: lines.joined(separator: "\n"), replacedSource: replacedSource)
    }

    /// The index of the closing fence of the block with this code.
    private static func blockEnd(of code: String, in lines: [String]) -> Int? {
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                var scan = index + 1
                while scan < lines.count, !lines[scan].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[scan])
                    scan += 1
                }
                if body.joined(separator: "\n") == code { return min(scan, lines.count - 1) }
                index = scan + 1
            } else {
                index += 1
            }
        }
        return nil
    }
}
