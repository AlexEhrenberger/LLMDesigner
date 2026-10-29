import AppKit

/// Line spacing and indents of paragraphs (`WriterParagraphFormat`), and page breaks.
extension WriterTextView {
    /// The format of the paragraph with the caret and whether it takes indents; nil where it has none.
    var paragraphFormatAtCaret: (format: WriterParagraphFormat, takesIndent: Bool)? {
        guard tableCellAtCaret == nil, selectedEmbed == nil else { return nil }
        let block: WriterBlock
        let attributes: [NSAttributedString.Key: Any]
        if let paragraph = currentParagraph, let storage = textStorage, paragraph.range.length > 0 {
            block = paragraph.block
            attributes = storage.attributes(at: paragraph.range.location, effectiveRange: nil)
        } else {
            attributes = typingAttributes
            block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
        }
        guard block.takesAlignment || block.isList else { return nil }
        let takesIndent = block == .paragraph || block == .quote
        return (WriterParagraphFormat(attributes).applying(to: block), takesIndent)
    }

    /// Changes the format of the selected paragraphs (the one with the caret) in one undoable step: `change` gets
    /// each paragraph's format and returns the new one; what a block doesn't take is left out.
    func changeParagraphFormat(_ change: (WriterParagraphFormat) -> WriterParagraphFormat) {
        guard let storage = textStorage, tableCellAtCaret == nil else { return }
        let range = selectedRange()
        let paragraphs = range.length == 0 && currentParagraph == nil ? [] : WriterMarkdown.paragraphs(of: storage, in: range)
            .filter { ($0.block.takesAlignment || $0.block.isList) && $0.cell == nil }
        if paragraphs.isEmpty {
            // The empty last paragraph lives in the typing attributes.
            let block = (typingAttributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            guard block.takesAlignment || block.isList, currentParagraph == nil, range.length == 0 else { return }
            var attributes = typingAttributes
            let format = change(WriterParagraphFormat(attributes)).applying(to: block)
            for key in WriterParagraphFormat.keys { attributes.removeValue(forKey: key) }
            attributes.merge(format.attributes) { $1 }
            typingAttributes = WriterStyler.typingAttributes(block: block, level: attributes[.writerListLevel] as? Int ?? 0, semantic: attributes, family: family, palette: palette)
            needsDisplay = true
            onStateChange?()
            return
        }
        let hull = NSUnionRange(paragraphs[0].range, paragraphs[paragraphs.count - 1].range)
        guard shouldChangeText(in: hull, replacementString: nil) else { return }
        storage.beginEditing()
        for paragraph in paragraphs where paragraph.range.length > 0 {
            let current = WriterParagraphFormat(storage.attributes(at: paragraph.range.location, effectiveRange: nil))
            let format = change(current).applying(to: paragraph.block)
            // The alignment stays as `setAlignment` keeps it: the default one is stored as none.
            for key in WriterParagraphFormat.keys { storage.removeAttribute(key, range: paragraph.range) }
            storage.addAttributes(format.attributes, range: paragraph.range)
        }
        storage.endEditing()
        didChangeText()
        resetTypingAttributes()
        needsDisplay = true
        onStateChange?()
    }

    func setLineSpacing(_ value: Double?) {
        changeParagraphFormat { format in
            var format = format
            format.lineSpacing = value
            return WriterParagraphFormat(alignment: format.alignment, lineSpacing: format.lineSpacing, indent: format.indent,
                                         rightIndent: format.rightIndent, firstLine: format.firstLine)
        }
    }

    /// Sets the indents in centimetres; nil leaves one as it is. Zero takes it away.
    func setIndents(left: Double? = nil, right: Double? = nil, firstLine: Double? = nil) {
        changeParagraphFormat { format in
            WriterParagraphFormat(alignment: format.alignment, lineSpacing: format.lineSpacing, indent: left ?? format.indent,
                                  rightIndent: right ?? format.rightIndent, firstLine: firstLine ?? format.firstLine)
        }
    }

    /// ⌘] and ⌘[, and the indent buttons: a list item one level in or out; text and quotes one step (1,25 cm) further
    /// in from the left or back.
    func changeIndent(by step: Int) {
        if state.block.isList { return changeListLevel(by: step) }
        changeParagraphFormat { format in
            let indent = max(0, (format.indent ?? 0) + Double(step) * WriterParagraphFormat.indentStep)
            return WriterParagraphFormat(alignment: format.alignment, lineSpacing: format.lineSpacing, indent: indent,
                                         rightIndent: format.rightIndent, firstLine: format.firstLine)
        }
    }

    /// Takes the selected paragraphs' line spacing and indents away (their alignment stays).
    func clearParagraphFormat() {
        changeParagraphFormat { WriterParagraphFormat(alignment: $0.alignment) }
    }

    // MARK: Page break

    /// ⌘↩: the text after the caret goes on on a new page. In the middle of a paragraph it is split there; at its end
    /// the break comes below it.
    func insertPageBreak() {
        guard let storage = textStorage, tableCellAtCaret == nil else { return }
        let attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.rule.rawValue, .writerListLevel: 0]
        let mark = NSMutableAttributedString(attachment: WriterPageBreakAttachment())
        mark.addAttributes(attributes, range: NSRange(location: 0, length: mark.length))
        mark.append(NSAttributedString(string: "\n", attributes: attributes))
        let caret = selectedRange()
        if let paragraph = currentParagraph, paragraph.block != .rule, !paragraph.block.isEmbed, caret.length == 0,
           caret.location > paragraph.contentRange.location, caret.location < NSMaxRange(paragraph.contentRange) {
            // Splits the paragraph: its first part ends, the break follows, the rest begins the new page.
            let before = storage.attributes(at: caret.location - 1, effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            let insertion = NSMutableAttributedString(string: "\n", attributes: before)
            insertion.append(mark)
            performStructureEdit(in: caret, with: insertion)
            setSelectedRange(NSRange(location: min(caret.location + insertion.length, storage.length), length: 0))
            resetTypingAttributes()
            onStateChange?()
            return
        }
        guard let start = insertBlock(mark) else { return }
        setSelectedRange(NSRange(location: min(start + mark.length, storage.length), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
    }
}

/// Draws a page break: a dashed line across the column with its name in the middle.
final class WriterPageBreakCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { NSSize(width: 200, height: 22) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -6) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -6, width: max(40, lineFrag.width - 4), height: 22)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let palette = (controlView as? WriterTextView)?.palette
        let color = palette?.tertiaryText ?? NSColor.tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color]
        let label = "Seitenumbruch" as NSString
        let size = label.size(withAttributes: attributes)
        let gap: CGFloat = 10
        let left = NSBezierPath()
        left.move(to: NSPoint(x: cellFrame.minX, y: cellFrame.midY))
        left.line(to: NSPoint(x: cellFrame.midX - size.width / 2 - gap, y: cellFrame.midY))
        left.move(to: NSPoint(x: cellFrame.midX + size.width / 2 + gap, y: cellFrame.midY))
        left.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.midY))
        left.lineWidth = 1
        left.setLineDash([5, 4], count: 2, phase: 0)
        (palette?.rule ?? NSColor.separatorColor).setStroke()
        left.stroke()
        label.draw(at: NSPoint(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2), withAttributes: attributes)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
