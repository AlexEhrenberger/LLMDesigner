import AppKit

/// What the formula editor opens with, and where its result goes.
struct WriterFormulaRequest: Identifiable {
    let id = UUID()
    var latex: String
    var display: Bool
    /// Editing a formula that is in the text (its place is tracked while the editor is open).
    var isExisting: Bool
    /// The plot below the formula, if it has one.
    var plot: WriterImageReference?
}

/// Formulas in the editor: display formulas are paragraphs of their own (block `.math`), inline formulas sit in
/// the text. Both are `WriterMathAttachment`s; a click selects one, a double click opens the formula editor. A
/// display formula can have a plot right below it: a picture paragraph whose reference carries the plot settings.
extension WriterTextView {
    static let formulaKey = "formula"

    func formula(at location: Int) -> WriterMathAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? WriterMathAttachment
    }

    var selectedFormula: (attachment: WriterMathAttachment, location: Int)? {
        let range = selectedRange()
        guard range.length == 1, let formula = formula(at: range.location) else { return nil }
        return (formula, range.location)
    }

    func isDisplayFormula(at location: Int) -> Bool {
        guard let storage = textStorage, formula(at: location) != nil else { return false }
        return WriterStyler.block(in: storage, at: location) == .math
    }

    func selectFormula(at location: Int) {
        guard formula(at: location) != nil else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: location, length: 1))
    }

    // MARK: Opening the editor

    /// ⌥⌘E and the toolbar: edits the selected formula, else starts a new one (on its own line when the caret
    /// is in an empty paragraph, inside the text otherwise).
    func editFormulaAtCaret() {
        if let selected = selectedFormula { return editFormula(at: selected.location) }
        if let image = selectedImage, image.reference.plot != nil { return editPlot(at: image.location) }
        let paragraph = currentParagraph
        let isEmptyLine = paragraph == nil || paragraph?.contentRange.length == 0
        newFormula(display: isEmptyLine || paragraph?.block.isEmbed == true || paragraph?.block == .rule)
    }

    func newFormula(display: Bool) {
        trackedRanges[Self.formulaKey] = nil
        onFormula?(WriterFormulaRequest(latex: "", display: display, isExisting: false, plot: nil))
    }

    func editFormula(at location: Int) {
        guard let formula = formula(at: location) else { return }
        trackedRanges[Self.formulaKey] = NSRange(location: location, length: 1)
        let display = isDisplayFormula(at: location)
        onFormula?(WriterFormulaRequest(latex: formula.latex, display: display, isExisting: true,
                                        plot: display ? plotBelow(formulaAt: location)?.reference : nil))
    }

    /// A plot is edited together with its formula, the display formula right above it.
    func editPlot(at location: Int) {
        guard let storage = textStorage, location > 0 else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        guard paragraph.location > 0 else { onNotice?("Über diesem Plot steht keine Formel mehr."); return }
        let above = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
        guard isDisplayFormula(at: above.location) else { onNotice?("Über diesem Plot steht keine Formel mehr."); return }
        editFormula(at: above.location)
    }

    /// The plot paragraph right below the display formula at `location`.
    func plotBelow(formulaAt location: Int) -> (reference: WriterImageReference, location: Int)? {
        guard let storage = textStorage else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let next = NSMaxRange(paragraph)
        guard next < storage.length, let image = image(at: next), image.reference.plot != nil else { return nil }
        return (image.reference, next)
    }

    // MARK: Applying the editor's result

    /// Puts the edited formula (and its plot) into the text as one undoable step.
    func applyFormula(latex: String, display: Bool, plot: WriterImageReference?, isExisting: Bool) {
        guard let storage = textStorage else { return }
        let latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracked = isExisting ? trackedRanges[Self.formulaKey] : nil
        trackedRanges[Self.formulaKey] = nil
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Formel")
            onStateChange?()
        }

        if let tracked, tracked.location < storage.length, formula(at: tracked.location) != nil {
            let location = tracked.location
            let wasDisplay = isDisplayFormula(at: location)
            if latex.isEmpty {
                // An emptied formula goes away (with its plot).
                if wasDisplay {
                    if let plot = plotBelow(formulaAt: location) { deleteEmbed(at: plot.location) }
                    deleteEmbed(at: location)
                } else {
                    performStructureEdit(in: NSRange(location: location, length: 1), with: NSAttributedString())
                }
                return
            }
            switch (wasDisplay, display) {
            case (true, true):
                replaceFormula(at: location, latex: latex)
                updatePlot(below: location, with: plot)
                selectFormula(at: location)
            case (false, false):
                replaceFormula(at: location, latex: latex)
                setSelectedRange(NSRange(location: location + 1, length: 0))
            case (true, false):
                // The display formula becomes a paragraph that holds it inline.
                if let existing = plotBelow(formulaAt: location) { deleteEmbed(at: existing.location) }
                replaceFormula(at: location, latex: latex)
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
                performStructureEdit(in: paragraph, with: {
                    let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
                    text.addAttributes([.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: text.length))
                    return text
                }())
                setSelectedRange(NSRange(location: location + 1, length: 0))
            case (false, true):
                // The inline formula leaves the text and comes back as a display formula below the paragraph.
                performStructureEdit(in: NSRange(location: location, length: 1), with: NSAttributedString())
                setSelectedRange(NSRange(location: location, length: 0))
                insertDisplayFormula(latex, plot: plot)
            }
            return
        }

        guard !latex.isEmpty else { return }
        if display {
            insertDisplayFormula(latex, plot: plot)
        } else {
            var attributes = typingAttributes.filter { [.writerBold, .writerItalic, .underlineStyle, .strikethroughStyle, .link, .writerBlock, .writerListLevel, .writerBookmark, .writerColor, .writerFont].contains($0.key) || WriterMarkdown.tableKeys.contains($0.key) }
            attributes.removeValue(forKey: .writerCode)
            let text = NSMutableAttributedString(attachment: WriterMathAttachment(latex: latex))
            text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
            let range = selectedRange()
            breakUndoCoalescing()
            if shouldChangeText(in: range, replacementString: text.string) {
                storage.replaceCharacters(in: range, with: text)
                didChangeText()
            }
            setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        }
    }

    private func insertDisplayFormula(_ latex: String, plot: WriterImageReference?) {
        let block = NSMutableAttributedString()
        let formulaAttributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.math.rawValue, .writerListLevel: 0]
        block.append(NSAttributedString(attachment: WriterMathAttachment(latex: latex)))
        block.append(NSAttributedString(string: "\n"))
        block.addAttributes(formulaAttributes, range: NSRange(location: 0, length: block.length))
        if let plot {
            let start = block.length
            block.append(NSAttributedString(attachment: WriterImageAttachment(reference: plot)))
            block.append(NSAttributedString(string: "\n"))
            block.addAttributes([.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0], range: NSRange(location: start, length: block.length - start))
        }
        guard let start = insertBlock(block) else { return }
        setSelectedRange(NSRange(location: min(start + block.length, textStorage?.length ?? 0), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
        scrollRangeToVisible(NSRange(location: start, length: block.length))
    }

    /// A new attachment in place of the old one, keeping the character's other attributes.
    private func replaceFormula(at location: Int, latex: String) {
        guard let storage = textStorage, formula(at: location)?.latex != latex else { return }
        let range = NSRange(location: location, length: 1)
        let text = NSMutableAttributedString(attachment: WriterMathAttachment(latex: latex))
        var attributes = storage.attributes(at: location, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        performStructureEdit(in: range, with: text)
    }

    /// Replaces, adds or removes the plot below a display formula.
    private func updatePlot(below location: Int, with plot: WriterImageReference?) {
        guard let storage = textStorage else { return }
        let existing = plotBelow(formulaAt: location)
        switch (existing, plot) {
        case (let existing?, let plot?):
            guard existing.reference != plot else { return }
            let range = NSRange(location: existing.location, length: 1)
            let text = NSMutableAttributedString(attachment: WriterImageAttachment(reference: plot))
            var attributes = storage.attributes(at: existing.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            text.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            performStructureEdit(in: range, with: text)
        case (let existing?, nil):
            deleteEmbed(at: existing.location)
        case (nil, let plot?):
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            let block = NSMutableAttributedString(attachment: WriterImageAttachment(reference: plot))
            block.append(NSAttributedString(string: "\n"))
            block.addAttributes([.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: block.length))
            var insertion = NSMutableAttributedString(attributedString: block)
            // The formula is the last paragraph without a newline: the plot needs one before it.
            if NSMaxRange(paragraph) == storage.length, (storage.string as NSString).character(at: storage.length - 1) != 0x0A {
                insertion = NSMutableAttributedString(string: "\n", attributes: [.writerBlock: WriterBlock.math.rawValue, .writerListLevel: 0])
                insertion.append(block)
            }
            performStructureEdit(in: NSRange(location: NSMaxRange(paragraph), length: 0), with: insertion)
        case (nil, nil):
            break
        }
    }

    // MARK: Menu

    func formulaMenuItems(at location: Int) -> [NSMenuItem] {
        guard let formula = formula(at: location) else { return [] }
        let edit = ClosureMenuItem(title: "Formel bearbeiten …") { [weak self] in self?.editFormula(at: location) }
        edit.image = NSImage(systemSymbolName: "function", accessibilityDescription: nil)
        let copy = ClosureMenuItem(title: "LaTeX kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formula.latex, forType: .string)
        }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        var items: [NSMenuItem] = [edit]
        if isDisplayFormula(at: location) {
            let hasPlot = plotBelow(formulaAt: location) != nil
            let plot = ClosureMenuItem(title: hasPlot ? "Plot bearbeiten …" : "Plot hinzufügen …") { [weak self] in self?.editFormula(at: location) }
            plot.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil)
            items.append(plot)
        }
        let delete = ClosureMenuItem(title: "Formel entfernen") { [weak self] in
            guard let self else { return }
            if self.isDisplayFormula(at: location) {
                self.deleteEmbed(at: location)
            } else {
                self.performStructureEdit(in: NSRange(location: location, length: 1), with: NSAttributedString())
            }
        }
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return items + [copy, delete, .separator()]
    }

    /// The formula under a point (for the context menu).
    func formulaLocation(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        guard formula(at: location) != nil, let frame = attachmentFrame(at: location), frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return location
    }
}

/// Draws a formula with SwiftMath: centred and larger on its own line, on the text's baseline inside text. A
/// formula SwiftMath can't read shows its LaTeX in a dashed box.
final class WriterMathCell: NSTextAttachmentCell {
    private struct Layout {
        var image: NSImage?
        var source: NSAttributedString?
        var size: NSSize
        var baseline: CGFloat
        var display: Bool
    }

    private var lastLayout: Layout?

    private var latex: String { (attachment as? WriterMathAttachment)?.latex ?? "" }

    private func layout(available: CGFloat, view: WriterTextView?, characterIndex: Int, storage: NSTextStorage?) -> Layout {
        let palette = view?.palette ?? .dark
        let family = view?.family ?? .serif
        let display = storage.map { characterIndex < $0.length && WriterStyler.block(in: $0, at: characterIndex) == .math } ?? false
        var fontSize = WriterStyler.bodySize(family) * (display ? 1.3 : 1.08)
        if !display, let storage, characterIndex < storage.length, let font = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont {
            fontSize = font.pointSize * 1.08
        }
        if let rendered = MathRenderer.render(latex, fontSize: fontSize, display: display, color: palette.text) {
            var size = rendered.image.size
            var image = rendered.image
            // Wider than the column: scaled down to fit.
            if size.width > available, available > 40 {
                let scale = available / size.width
                size = NSSize(width: available, height: size.height * scale)
                image = NSImage(size: size, flipped: false) { rect in
                    rendered.image.draw(in: rect)
                    return true
                }
            }
            let padding: CGFloat = display ? 6 : 1
            return Layout(image: image, source: nil, size: NSSize(width: ceil(size.width) + 2 * padding, height: ceil(size.height) + (display ? 12 : 0)),
                          baseline: display ? 0 : rendered.baselineOffset, display: display)
        }
        let source = NSAttributedString(string: latex.isEmpty ? "Formel" : latex, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, fontSize * 0.7), weight: .regular),
            .foregroundColor: palette.secondaryText,
        ])
        let bounds = source.boundingRect(with: NSSize(width: max(60, available - 24), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return Layout(image: nil, source: source, size: NSSize(width: min(available, ceil(bounds.width) + 24), height: ceil(bounds.height) + 14),
                      baseline: display ? 0 : -4, display: display)
    }

    override func cellSize() -> NSSize { lastLayout?.size ?? NSSize(width: 40, height: 20) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: lastLayout?.baseline ?? 0) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let view = textContainer.textView as? WriterTextView
        let layout = self.layout(available: max(60, lineFrag.width - 4), view: view, characterIndex: charIndex, storage: textContainer.layoutManager?.textStorage)
        lastLayout = layout
        return NSRect(x: 0, y: layout.baseline, width: layout.size.width, height: layout.size.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: charIndex)
    }

    private func draw(_ frame: NSRect, view: WriterTextView?, characterIndex: Int?) {
        guard let layout = lastLayout else { return }
        let palette = view?.palette ?? .dark
        let isSelected = characterIndex.map { index in view?.selectedRange() == NSRange(location: index, length: 1) } ?? false
        if isSelected {
            palette.accent.withAlphaComponent(0.12).setFill()
            let shape = NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -2), xRadius: 6, yRadius: 6)
            shape.fill()
            palette.accent.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        if let image = layout.image {
            let rect = NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else if let source = layout.source {
            let box = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            palette.codeBlock.setFill()
            box.fill()
            palette.warningStroke.setStroke()
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            box.stroke()
            source.draw(with: frame.insetBy(dx: 12, dy: 7), options: [.usesLineFragmentOrigin])
        }
    }

    // A click selects the formula, a double click opens the editor.
    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        view.selectFormula(at: charIndex)
        if theEvent.clickCount >= 2 { view.editFormula(at: charIndex) }
        return true
    }
}

private extension WriterPalette {
    var warningStroke: NSColor { NSColor(hex: 0xF2B14C).withAlphaComponent(0.7) }
}
