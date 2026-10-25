import AppKit

/// Colour, font and size of a passage (see `WriterSpanStyle`): the selection, or the text typed from the caret on.
/// And the alignment of paragraphs.
extension WriterTextView {
    /// The sizes the size menu offers and ⌘+ / ⌘− step through.
    static let fontSizeSteps: [Double] = [6, 7, 8, 9, 10, 10.5, 11, 12, 13, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 40, 44, 48, 54, 60, 66, 72, 80, 88, 96]

    /// Colours the selection. nil takes the colour away (the text's own colour again).
    func setTextColor(_ hex: String?) {
        applyPassageAttribute(.writerColor, value: hex)
    }

    /// Sets the selection in another font. nil takes it away (the document's font again).
    func setTextFont(_ font: WriterFont?) {
        applyPassageAttribute(.writerFont, value: font?.rawValue)
    }

    /// Sets the selection in this size (points as printed); nil takes the size away (the block's own again).
    func setFontSize(_ size: Double?) {
        applyPassageAttribute(.writerFontSize, value: size.map { min(WriterSpanStyle.sizeRange.upperBound, max(WriterSpanStyle.sizeRange.lowerBound, $0)) })
    }

    /// ⌘+ and ⌘−: every stretch of the selection one size larger or smaller, from the size it has (so headings stay
    /// larger than text); without a selection the text typed from the caret on.
    func changeFontSize(by step: Int) {
        guard let storage = textStorage else { return }
        func next(from size: Double) -> Double {
            let steps = Self.fontSizeSteps
            if step > 0 { return steps.first { $0 > size + 0.01 } ?? min(WriterSpanStyle.sizeRange.upperBound, size + 8) }
            return steps.last { $0 < size - 0.01 } ?? max(WriterSpanStyle.sizeRange.lowerBound, size - 1)
        }
        let range = selectedRange()
        if range.length == 0 {
            let block = (typingAttributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            guard block != .code, block != .raw else { return }
            setFontSize(next(from: WriterStyler.printedSize(of: typingAttributes, block: block, family: family, palette: palette)))
            return
        }
        let parts = passageParts(in: range)
        guard let first = parts.first, let last = parts.last else { return }
        let hull = NSUnionRange(first.range, last.range)
        guard shouldChangeText(in: hull, replacementString: nil) else { return }
        storage.beginEditing()
        for part in parts {
            storage.enumerateAttributes(in: part.range) { attributes, run, _ in
                let size = WriterStyler.printedSize(of: attributes, block: part.block, family: family, palette: palette)
                storage.addAttribute(.writerFontSize, value: next(from: size), range: run)
            }
        }
        storage.endEditing()
        didChangeText()
        onStateChange?()
    }

    /// The size of the text at the caret (or the start of the selection) in points as printed, and whether it is the
    /// passage's own.
    var passageSize: (size: Double, isOwn: Bool) {
        guard let storage = textStorage else { return (Double(WriterFont.printSize), false) }
        let range = selectedRange()
        let attributes = range.length > 0 && range.location < storage.length ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        let block = currentParagraph?.block ?? (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
        let own = attributes[.writerFontSize] as? Double
        return (own ?? WriterStyler.printedSize(of: attributes, block: block, family: family, palette: palette), own != nil)
    }

    // MARK: Alignment

    /// Aligns the selected paragraphs (the one with the caret). In a table it aligns the caret's column instead; the
    /// default alignment is stored as none, so a title slide keeps centring what isn't set otherwise.
    func setAlignment(_ alignment: WriterAlignment) {
        guard let storage = textStorage else { return }
        if tableCellAtCaret != nil {
            switch alignment {
            case .left: performTableAction(.align(.leading))
            case .center: performTableAction(.align(.center))
            case .right: performTableAction(.align(.trailing))
            case .justify: break
            }
            return
        }
        let range = selectedRange()
        let paragraphs = range.length == 0 && currentParagraph == nil ? [] : WriterMarkdown.paragraphs(of: storage, in: range)
            .filter { $0.block.takesAlignment && $0.cell == nil }
        if paragraphs.isEmpty {
            // The empty last paragraph lives in the typing attributes.
            let block = (typingAttributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            guard block.takesAlignment, currentParagraph == nil, range.length == 0 else { return }
            var attributes = typingAttributes
            let isDefault = alignment == WriterStyler.defaultAlignment(block, palette: palette)
            if isDefault { attributes.removeValue(forKey: .writerAlignment) } else { attributes[.writerAlignment] = alignment.rawValue }
            typingAttributes = WriterStyler.typingAttributes(block: block, level: attributes[.writerListLevel] as? Int ?? 0, semantic: attributes, family: family, palette: palette)
            needsDisplay = true
            onStateChange?()
            return
        }
        let hull = NSUnionRange(paragraphs[0].range, paragraphs[paragraphs.count - 1].range)
        guard shouldChangeText(in: hull, replacementString: nil) else { return }
        storage.beginEditing()
        for paragraph in paragraphs where paragraph.range.length > 0 {
            if alignment == WriterStyler.defaultAlignment(paragraph.block, palette: palette) {
                storage.removeAttribute(.writerAlignment, range: paragraph.range)
            } else {
                storage.addAttribute(.writerAlignment, value: alignment.rawValue, range: paragraph.range)
            }
        }
        storage.endEditing()
        didChangeText()
        resetTypingAttributes()
        needsDisplay = true
        onStateChange?()
    }

    /// How the paragraph with the caret is set, as the toolbar shows it; nil where nothing can be aligned.
    var alignmentAtCaret: WriterAlignment? {
        if let cell = tableCellAtCaret {
            switch cell.table.alignment(of: cell.column) {
            case .leading: return .left
            case .center: return .center
            case .trailing: return .right
            }
        }
        if selectedEmbed != nil { return nil }
        let block: WriterBlock
        let attributes: [NSAttributedString.Key: Any]
        if let paragraph = currentParagraph, let storage = textStorage, paragraph.range.length > 0 {
            block = paragraph.block
            attributes = storage.attributes(at: paragraph.range.location, effectiveRange: nil)
        } else {
            attributes = typingAttributes
            block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
        }
        guard block.takesAlignment else { return nil }
        return (attributes[.writerAlignment] as? String).flatMap(WriterAlignment.init(rawValue:)) ?? WriterStyler.defaultAlignment(block, palette: palette)
    }

    /// Colour and font at the caret, or at the start of the selection.
    var passageStyle: WriterSpanStyle {
        guard let storage = textStorage else { return WriterSpanStyle() }
        let range = selectedRange()
        if range.length > 0, range.location < storage.length {
            return WriterSpanStyle(storage.attributes(at: range.location, effectiveRange: nil))
        }
        return WriterSpanStyle(typingAttributes)
    }

    private func applyPassageAttribute(_ key: NSAttributedString.Key, value: Any?) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        if range.length == 0 {
            var attributes = typingAttributes
            if let value { attributes[key] = value } else { attributes.removeValue(forKey: key) }
            let block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            typingAttributes = WriterStyler.typingAttributes(
                block: block, level: attributes[.writerListLevel] as? Int ?? 0, semantic: attributes, family: family, palette: palette
            )
            onStateChange?()
            return
        }
        let parts = passageParts(in: range)
        guard let first = parts.first, let last = parts.last else { return }
        let hull = NSUnionRange(first.range, last.range)
        guard shouldChangeText(in: hull, replacementString: nil) else { return }
        storage.beginEditing()
        for part in parts {
            if let value { storage.addAttribute(key, value: value, range: part.range) } else { storage.removeAttribute(key, range: part.range) }
        }
        storage.endEditing()
        didChangeText()
        onStateChange?()
    }

    /// The text of the selection by paragraph. Text only: code, lines, pictures and formulas on their own have no
    /// colour, font or size of their own.
    private func passageParts(in range: NSRange) -> [(range: NSRange, block: WriterBlock)] {
        guard let storage = textStorage else { return [] }
        var parts: [(range: NSRange, block: WriterBlock)] = []
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: range) {
            guard paragraph.block != .code, paragraph.block != .raw, paragraph.block != .rule, !paragraph.block.isEmbed else { continue }
            let part = NSIntersectionRange(range, paragraph.contentRange)
            if part.length > 0 { parts.append((part, paragraph.block)) }
        }
        return parts
    }
}
