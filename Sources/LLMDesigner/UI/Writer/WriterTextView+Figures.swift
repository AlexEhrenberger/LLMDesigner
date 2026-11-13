import AppKit

/// What a figure's editor (chart, drawing, Mermaid) opens with.
struct WriterFigureRequest: Identifiable {
    let id = UUID()
    let kind: WriterFigureKind
    /// The figure in the text that is edited; nil for a new one.
    var reference: WriterImageReference?
    var chart = WriterChart.sample
    var drawing = WriterDrawing()
    var mermaid = WriterMermaid.template(.flowchart)
    /// The document's font, for charts set in it.
    var family: WriterFont = .serif
    /// The text around the place, for the model writing a Mermaid diagram.
    var context = ""

    var isExisting: Bool { reference != nil }
}

/// Figures made in Writer Studio: charts (also from a table, which they then follow), drawings and Mermaid
/// diagrams. Each is a picture in the text with its recipe next to it; a double click opens its editor again, and a
/// change writes new pictures under a new name, so undo brings the old figure back.
extension WriterTextView {
    static let figureKey = "figure"
    /// The table a new chart is made from, while its editor is open.
    static let figureTableKey = "figureTable"

    /// A new figure at the caret (below the current paragraph).
    func newFigure(_ kind: WriterFigureKind) {
        if let image = selectedImage, image.reference.figure == kind { return editFigure(at: image.location) }
        trackedRanges[Self.figureKey] = NSRange(location: selectedRange().location, length: 0)
        trackedRanges[Self.figureTableKey] = nil
        var request = WriterFigureRequest(kind: kind, family: family)
        request.context = surroundingText(at: selectedRange().location)
        if kind == .mermaid, let selection = selectedMarkdown(), selection.count > 20 { request.context = selection }
        onFigure?(request)
    }

    /// A chart of the table with the caret, below it; it follows the table's numbers.
    func makeChartFromTable() {
        guard let cell = tableCellAtCaret, let model = tableModel(at: selectedRange().location) else { return }
        var chart = WriterChart()
        chart.table = model.table.style.id ?? WriterTableStyle.newID()
        chart.takeData(from: cellTexts(of: model), formulas: model.table.style.formulas)
        if chart.series.isEmpty {
            onNotice?("In der Tabelle stehen keine Zahlen für ein Diagramm – die erste Zeile benennt die Reihen, die erste Spalte die Kategorien.")
            return
        }
        chart.kind = chart.categories.count > 8 && chart.series.count == 1 ? .line : .column
        chart.title = ""
        _ = cell
        trackedRanges[Self.figureKey] = NSRange(location: model.range.location, length: 0)
        trackedRanges[Self.figureTableKey] = NSRange(location: model.range.location, length: 0)
        var request = WriterFigureRequest(kind: .chart, family: family)
        request.chart = chart
        onFigure?(request)
    }

    /// Opens the editor of the figure at `location`.
    func editFigure(at location: Int) {
        guard let attachment = image(at: location), let kind = attachment.reference.figure else { return }
        let reference = attachment.reference
        trackedRanges[Self.figureKey] = NSRange(location: location, length: 1)
        trackedRanges[Self.figureTableKey] = nil
        var request = WriterFigureRequest(kind: kind, reference: reference, family: family)
        let recipe = WriterImageStore.recipe(for: reference)
        switch kind {
        case .chart:
            guard var chart = WriterChart.decode(recipe) else {
                onNotice?("Die Daten dieses Diagramms fehlen.")
                return
            }
            // A chart of a table shows the table's numbers as they are now.
            if let id = chart.table, let model = tableModel(id: id) {
                chart.takeData(from: cellTexts(of: model), formulas: model.table.style.formulas)
            }
            request.chart = chart
        case .drawing:
            guard let drawing = WriterDrawing.decode(recipe) else {
                onNotice?("Die Daten dieser Zeichnung fehlen.")
                return
            }
            request.drawing = drawing
        case .mermaid:
            guard let code = recipe.flatMap({ String(data: $0, encoding: .utf8) }) else {
                onNotice?("Der Mermaid-Code dieses Diagramms fehlt.")
                return
            }
            request.mermaid = code
            request.context = surroundingText(at: location)
        }
        onFigure?(request)
    }

    /// The editor's result: new pictures for the figure in the text, or a new figure at the place the editor was
    /// opened for. `width`: a new figure's width in percent of the column (nil: its own size).
    func applyFigure(_ kind: WriterFigureKind, images: WriterFigureImages, recipe: Data, caption: String?, width: Int?,
                     linkedTable: String? = nil, isExisting: Bool) {
        let tracked = trackedRanges[Self.figureKey]
        let tableRange = trackedRanges[Self.figureTableKey]
        trackedRanges[Self.figureKey] = nil
        trackedRanges[Self.figureTableKey] = nil
        let source: String
        do {
            source = try WriterImageStore.storeFigure(kind, images: images, recipe: recipe)
        } catch {
            onNotice?("Die Bilder ließen sich nicht speichern: \(error.localizedDescription)")
            return
        }
        window?.makeFirstResponder(self)
        if isExisting, let tracked, let attachment = image(at: tracked.location), attachment.reference.figure == kind {
            updateImage(at: tracked.location) {
                $0.source = source
                if let caption { $0.caption = caption }
            }
            undoManager?.setActionName(kind.label)
            selectImage(at: tracked.location)
            return
        }
        undoManager?.beginUndoGrouping()
        // The table the chart is made from gets its name, so the chart finds it again.
        if let linkedTable, let tableRange, let model = tableModel(at: tableRange.location), model.table.style.id != linkedTable {
            var style = model.table.style
            style.id = linkedTable
            replaceTable(model, with: model.table.with(style: style))
        }
        if let tracked, let length = textStorage?.length {
            setSelectedRange(NSRange(location: min(tracked.location, length), length: 0))
        }
        let reference = WriterImageReference(source: source, caption: caption ?? "", width: width, figure: kind)
        let text = NSMutableAttributedString(attachment: WriterImageAttachment(reference: reference))
        text.append(NSAttributedString(string: "\n"))
        text.addAttributes([.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: text.length))
        if let start = insertBlock(text) {
            setSelectedRange(NSRange(location: start + text.length, length: 0))
            setBlockOfEmptyCaretParagraph(.paragraph)
            scrollRangeToVisible(NSRange(location: start, length: text.length))
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(kind.label)
    }

    func cancelFigure() {
        trackedRanges[Self.figureKey] = nil
        trackedRanges[Self.figureTableKey] = nil
    }

    // MARK: Mermaid code becomes a diagram

    /// The Mermaid code of a code block: one fenced as ```mermaid, or one without language that starts like a diagram.
    func mermaidCode(in run: NSRange) -> String? {
        guard let storage = textStorage, NSMaxRange(run) <= storage.length else { return nil }
        let fence = WriterStyler.language(of: run, in: storage).fence?.lowercased()
        let code = (storage.string as NSString).substring(with: run).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        if fence == "mermaid" { return code }
        return fence == nil && WriterMermaid.type(of: code) != nil ? code : nil
    }

    /// The code blocks with Mermaid code in a range (e.g. what the model just wrote).
    func mermaidRuns(in range: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var runs: [NSRange] = []
        var location = range.location
        while location < min(NSMaxRange(range), storage.length) {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            if WriterStyler.block(in: storage, at: paragraph.location) == .code {
                let run = WriterStyler.codeRun(around: paragraph, in: storage)
                if mermaidCode(in: run) != nil { runs.append(run) }
                location = NSMaxRange(run)
            } else {
                location = NSMaxRange(paragraph)
            }
        }
        return runs
    }

    /// Draws a Mermaid code block and puts the diagram in its place (one undoable step); code Mermaid can't read stays.
    func convertMermaidBlock(_ run: NSRange) {
        guard let code = mermaidCode(in: run) else { return }
        let key = "mermaid-" + UUID().uuidString
        trackedRanges[key] = run
        Task { @MainActor [weak self] in
            do {
                let result = try await FlowImageRenderer.shared.images(mermaid: code)
                guard let self, let tracked = self.trackedRanges[key], let storage = self.textStorage, NSMaxRange(tracked) <= storage.length else { return }
                self.trackedRanges[key] = nil
                let images = WriterFigureImages(light: result.light, dark: result.dark, pdf: result.pdf)
                let source = try WriterImageStore.storeFigure(.mermaid, images: images, recipe: Data(code.utf8))
                let width = min(100, max(30, Int((result.size.width / WriterImageStore.referenceColumnWidth * 100).rounded())))
                let reference = WriterImageReference(source: source, caption: "", width: width, figure: .mermaid)
                let text = NSMutableAttributedString(attachment: WriterImageAttachment(reference: reference))
                text.append(NSAttributedString(string: "\n"))
                text.addAttributes([.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: text.length))
                // The code block's paragraphs, with the newline of the last one.
                var target = tracked
                if NSMaxRange(target) < storage.length, (storage.string as NSString).character(at: NSMaxRange(target) - 1) != 0x0A { target.length += 1 }
                self.performStructureEdit(in: target, with: text)
                self.undoManager?.setActionName("Mermaid-Diagramm")
            } catch {
                self?.trackedRanges[key] = nil
                self?.onNotice?("Der Mermaid-Code ließ sich nicht zeichnen: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Charts that follow their table

    /// The table with this name.
    func tableModel(id: String) -> TableModel? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.writerTable, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? WriterTable)?.style.id == id {
                found = range.location
                stop.pointee = true
            }
        }
        return found.flatMap { tableModel(at: $0) }
    }

    /// A table with a name changed: the charts made from it are drawn anew a moment later.
    func tableChanged(_ id: String) {
        pendingChartTables.insert(id)
        chartRefreshGeneration += 1
        let generation = chartRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.chartRefreshGeneration == generation else { return }
            self.refreshLinkedCharts()
        }
    }

    /// Draws the charts of changed tables anew, in place (their files are rewritten; the text doesn't change).
    func refreshLinkedCharts() {
        guard let storage = textStorage, !pendingChartTables.isEmpty else { return }
        let tables = pendingChartTables
        pendingChartTables = []
        var redraw: [Int] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? WriterImageAttachment, attachment.reference.figure == .chart,
                  var chart = WriterChart.decode(WriterImageStore.recipe(for: attachment.reference)),
                  let id = chart.table, tables.contains(id), let model = tableModel(id: id) else { return }
            let before = chart
            chart.takeData(from: cellTexts(of: model), formulas: model.table.style.formulas)
            guard chart != before, let images = WriterFigureRenderer.images(of: chart, family: family) else { return }
            let source = attachment.reference.source
            try? WriterImageStore.write(images, to: source)
            if let url = WriterImageStore.targetURL(for: WriterImageStore.recipeVariant(of: source, kind: .chart)) { try? chart.json.write(to: url, options: .atomic) }
            redraw.append(range.location)
        }
        for location in redraw {
            layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            if let frame = attachmentFrame(at: location) { setNeedsDisplay(frame.insetBy(dx: -8, dy: -8)) }
        }
        if !redraw.isEmpty { needsDisplay = true }
    }
}
