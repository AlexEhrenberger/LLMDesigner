import AppKit

/// Colour and font of a passage (see `WriterSpanStyle`): the selection, or the text typed from the caret on.
extension WriterTextView {
    /// Colours the selection. nil takes the colour away (the text's own colour again).
    func setTextColor(_ hex: String?) {
        applyPassageAttribute(.writerColor, value: hex)
    }

    /// Sets the selection in another font. nil takes it away (the document's font again).
    func setTextFont(_ font: WriterFont?) {
        applyPassageAttribute(.writerFont, value: font?.rawValue)
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

    private func applyPassageAttribute(_ key: NSAttributedString.Key, value: String?) {
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
        // Text only: code, lines, pictures and formulas on their own have no colour and font of their own.
        var parts: [NSRange] = []
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: range) {
            guard paragraph.block != .code, paragraph.block != .raw, paragraph.block != .rule, !paragraph.block.isEmbed else { continue }
            let part = NSIntersectionRange(range, paragraph.contentRange)
            if part.length > 0 { parts.append(part) }
        }
        guard let first = parts.first, let last = parts.last else { return }
        let hull = NSUnionRange(first, last)
        guard shouldChangeText(in: hull, replacementString: nil) else { return }
        storage.beginEditing()
        for part in parts {
            if let value { storage.addAttribute(key, value: value, range: part) } else { storage.removeAttribute(key, range: part) }
        }
        storage.endEditing()
        didChangeText()
        onStateChange?()
    }
}
