import AppKit

/// What the context menu and the keyboard ask the assistant for.
enum WriterAssistantCommand {
    case rewrite(WriterPrompts.Rewrite)
    case expand
    case check(WriterPrompts.Check)
    case askAboutSelection
    case placeCursorHere
    case continueHere
    case focusBar
    /// The model comments on the selection or the whole document.
    case comment
}

/// Where the assistant's text goes relative to the paragraph at the AI cursor.
enum AIPlacement {
    /// Into an empty paragraph (or the empty end of the document).
    case fill(Int)
    /// After a paragraph with text: a new paragraph follows it.
    case after(Int)
    /// Before a paragraph with text.
    case before(Int)
    /// Into the middle of a paragraph, as running text.
    case inline(Int)

    var location: Int {
        switch self {
        case .fill(let location), .after(let location), .before(let location), .inline(let location): location
        }
    }
}

/// The assistant's side of the editor: its own cursor, text streaming in, proposals and findings.
extension WriterTextView {
    static let aiCursorKey = "aiCursor"
    static let aiWritingKey = "aiWriting"
    static let proposalKey = "proposal"

    // MARK: Tracked ranges

    /// Moves the tracked places along with an edit: `edited` is the changed range after the edit.
    func shiftTrackedRanges(edited: NSRange, delta: Int) {
        guard !trackedRanges.isEmpty else { return }
        let start = edited.location
        let oldEnd = start + edited.length - delta
        for (key, range) in trackedRanges where !untrackedKeys.contains(key) {
            var updated = range
            if oldEnd <= range.location {
                // Entirely before (an insertion right at a place pushes it along).
                updated.location += delta
            } else if start >= NSMaxRange(range) {
                continue
            } else {
                // The edit overlaps the place: keep what is left of it.
                let newStart = min(range.location, start)
                let newEnd = max(newStart, NSMaxRange(range) + delta)
                updated = NSRange(location: newStart, length: max(0, newEnd - newStart))
            }
            let length = textStorage?.length ?? 0
            updated.location = max(0, min(updated.location, length))
            updated.length = max(0, min(updated.length, length - updated.location))
            trackedRanges[key] = updated
        }
        // After the text system has laid out the edit.
        DispatchQueue.main.async { [weak self] in self?.updateAICursorIndicator() }
    }

    // MARK: AI cursor

    /// A selection with text in it; a selected line end or blank (e.g. from a right-click) doesn't count.
    var hasTextSelection: Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        return (storage.string as NSString).substring(with: range).contains { $0.isLetter || $0.isNumber }
    }

    /// Where the assistant writes next; the end of the document until it is placed.
    var aiCursorLocation: Int {
        let length = textStorage?.length ?? 0
        return min(trackedRanges[Self.aiCursorKey]?.location ?? length, length)
    }

    func placeAICursor(at location: Int) {
        trackedRanges[Self.aiCursorKey] = NSRange(location: outsideTables(max(0, min(location, textStorage?.length ?? 0))), length: 0)
        updateAICursorIndicator()
        onStateChange?()
    }

    /// A few words before the AI cursor, to say where it is.
    var aiCursorContext: String {
        guard let storage = textStorage, storage.length > 0 else { return "" }
        let location = aiCursorLocation
        let start = max(0, location - 40)
        var text = (storage.string as NSString).substring(with: NSRange(location: start, length: location - start))
        text = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        let words = text.split(separator: " ").suffix(4).joined(separator: " ")
        return start > 0 || words.count < text.count ? "…" + words : words
    }

    var isAICursorAtEnd: Bool { aiCursorLocation >= (textStorage?.length ?? 0) }

    /// The assistant writes paragraphs, which don't fit into a table cell: a place in a table moves below it.
    func outsideTables(_ location: Int) -> Int {
        guard tableCell(at: location) != nil, let model = tableModel(at: location) else { return location }
        return NSMaxRange(model.range)
    }

    /// Moves the AI cursor's marker (its own small view on top of the text) to where the cursor is.
    func updateAICursorIndicator() {
        let indicator = aiCursorIndicator
        if indicator.superview !== self { addSubview(indicator) }
        // A slide shown in the presentation or the slide list has no assistant.
        guard isEditable else {
            indicator.isHidden = true
            return
        }
        let rect = caretRect(at: aiCursorLocation)
        guard !rect.isEmpty, textStorage != nil else {
            indicator.isHidden = true
            return
        }
        indicator.isHidden = false
        indicator.palette = palette
        indicator.isWriting = isAIWriting
        // The flag sits in the sheet's margin, a line leads from it to the cursor.
        let flagWidth: CGFloat = 20
        let left = textContainerOrigin.x - flagWidth - 14
        indicator.frame = NSRect(x: left, y: rect.minY - 2, width: rect.maxX - left + 4, height: rect.height + 4)
        indicator.caretX = rect.minX - left
        indicator.flagWidth = flagWidth
        indicator.needsDisplay = true
    }

    /// The caret's rectangle in view coordinates at a character position.
    func caretRect(at location: Int) -> NSRect {
        guard let layoutManager, let container = textContainer, let storage = textStorage else { return .zero }
        layoutManager.ensureLayout(for: container)
        let origin = textContainerOrigin
        let string = storage.string as NSString
        var rect: NSRect
        if storage.length == 0 || (location >= storage.length && string.character(at: storage.length - 1) == 0x0A) {
            rect = layoutManager.extraLineFragmentRect
            let font = WriterStyler.blockFont(.paragraph, family: family)
            rect.size.height = min(rect.height, font.ascender - font.descender + 6)
        } else if location >= storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            rect = NSRect(x: glyphRect.maxX, y: glyphRect.minY, width: 2, height: glyphRect.height)
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            rect = NSRect(x: glyphRect.minX, y: glyphRect.minY, width: 2, height: glyphRect.height)
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Document for the prompt

    /// The document as Markdown with the AI cursor or the selection marked, cut around that spot when it
    /// is longer than `limit` characters.
    func assistantDocument(cursor: Int?, selection: NSRange?, limit: Int) -> String {
        guard let storage = textStorage else { return "" }
        let copy = NSMutableAttributedString(attributedString: storage)
        func marker(_ text: String, at location: Int) {
            // The marker takes the paragraph it stands in (the next one when it sits right after a newline).
            var source = location > 0 ? location - 1 : 0
            if location > 0, location < copy.length, (copy.string as NSString).character(at: location - 1) == 0x0A { source = location }
            let startsEmptyEnd = location == copy.length && location > 0 && (copy.string as NSString).character(at: location - 1) == 0x0A
            let block = copy.length > 0 && !startsEmptyEnd
                ? copy.attributes(at: min(source, copy.length - 1), effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }
                : [:]
            copy.insert(NSAttributedString(string: text, attributes: block), at: location)
        }
        if let selection, selection.length > 0 {
            marker(WriterPrompts.selectionEnd, at: NSMaxRange(selection))
            marker(WriterPrompts.selectionStart, at: selection.location)
        } else if let cursor {
            marker(WriterPrompts.cursorMarker, at: min(cursor, copy.length))
        }
        // Bookmarks are the user's; the model doesn't need them (and would copy them).
        var markdown = WriterMarkdown.removingDivFences(WriterBookmark.strip(WriterMarkdown.markdown(from: copy))).trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty { markdown = WriterPrompts.cursorMarker }
        guard markdown.count > limit else { return markdown }

        let anchor = markdown.range(of: WriterPrompts.cursorMarker) ?? markdown.range(of: WriterPrompts.selectionStart)
        let center = anchor.map { markdown.distance(from: markdown.startIndex, to: $0.lowerBound) } ?? markdown.count
        let before = Int(Double(limit) * 0.7)
        let start = max(0, min(center - before, markdown.count - limit))
        let lower = markdown.index(markdown.startIndex, offsetBy: start)
        let upper = markdown.index(lower, offsetBy: min(limit, markdown.count - start))
        return (start > 0 ? "[…]\n" : "") + markdown[lower..<upper] + (upper < markdown.endIndex ? "\n[…]" : "")
    }

    /// The selected text as Markdown, without grey dictation.
    func selectedMarkdown() -> String? {
        guard let storage = textStorage, hasTextSelection else { return nil }
        let range = selectedRange()
        let selection = storage.attributedSubstring(from: range)
        let markdown = selection.string.contains("\n") ? WriterMarkdown.markdown(from: selection) : WriterMarkdown.inlineMarkdown(selection)
        let trimmed = WriterMarkdown.removingDivFences(WriterBookmark.strip(markdown)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Writing at the AI cursor

    /// Decides how the text will sit at the AI cursor and starts an empty passage there.
    func beginAIWriting() {
        guard let storage = textStorage else { return }
        removeDictationPreview()
        let string = storage.string as NSString
        let location = outsideTables(aiCursorLocation)
        let placement: AIPlacement
        if storage.length == 0 || (location >= storage.length && string.character(at: storage.length - 1) == 0x0A) {
            placement = .fill(storage.length)
        } else {
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, storage.length - 1), length: 0))
            var contentEnd = NSMaxRange(paragraph)
            if contentEnd > paragraph.location, string.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            if contentEnd == paragraph.location {
                placement = .fill(paragraph.location)
            } else if location >= contentEnd {
                placement = .after(contentEnd)
            } else if location <= paragraph.location {
                placement = .before(paragraph.location)
            } else {
                placement = .inline(location)
            }
        }
        aiPlacement = placement
        isAIWriting = true
        trackedRanges[Self.aiWritingKey] = NSRange(location: placement.location, length: 0)
        trackedRanges[Self.aiCursorKey] = NSRange(location: placement.location, length: 0)
        untrackedKeys = [Self.aiWritingKey, Self.aiCursorKey]
        updateAICursorIndicator()
    }

    /// Shows the text written so far. Not undoable on its own: the finished text becomes one undo step.
    func updateAIWriting(_ markdown: String) {
        guard let storage = textStorage, let placement = aiPlacement, var writing = trackedRanges[Self.aiWritingKey] else { return }
        let (rendered, contentLength) = renderAI(markdown, placement: placement)
        writing.length = min(writing.length, storage.length - writing.location)
        storage.beginEditing()
        storage.replaceCharacters(in: writing, with: rendered)
        storage.endEditing()
        let range = NSRange(location: writing.location, length: rendered.length)
        trackedRanges[Self.aiWritingKey] = range
        trackedRanges[Self.aiCursorKey] = NSRange(location: writing.location + contentLength, length: 0)
        if let layoutManager {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            layoutManager.addTemporaryAttribute(.backgroundColor, value: palette.accent.withAlphaComponent(palette.isLight ? 0.1 : 0.13), forCharacterRange: range)
        }
        scrollRangeToVisible(NSRange(location: writing.location + contentLength, length: 0))
        updateAICursorIndicator()
    }

    /// Puts the finished text in as one undoable change; the AI cursor stays at its end.
    func finishAIWriting(_ markdown: String) {
        guard let storage = textStorage, let placement = aiPlacement, var writing = trackedRanges[Self.aiWritingKey] else {
            isAIWriting = false
            return
        }
        writing.length = min(writing.length, storage.length - writing.location)
        storage.beginEditing()
        storage.replaceCharacters(in: writing, with: "")
        storage.endEditing()
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))

        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var cursor = writing.location
        if !text.isEmpty {
            let (rendered, contentLength) = renderAI(text, placement: placement)
            let target = NSRange(location: writing.location, length: 0)
            breakUndoCoalescing()
            if shouldChangeText(in: target, replacementString: rendered.string) {
                storage.replaceCharacters(in: target, with: rendered)
                didChangeText()
            }
            breakUndoCoalescing()
            cursor = writing.location + contentLength
            // Diagrams the model wrote as Mermaid code become pictures.
            for run in mermaidRuns(in: NSRange(location: writing.location, length: rendered.length)).reversed() { convertMermaidBlock(run) }
        }
        untrackedKeys = []
        trackedRanges[Self.aiWritingKey] = nil
        trackedRanges[Self.aiCursorKey] = NSRange(location: cursor, length: 0)
        aiPlacement = nil
        isAIWriting = false
        updateAICursorIndicator()
        onStateChange?()
    }

    /// The text as it goes into the document, and how much of it comes before the AI cursor.
    private func renderAI(_ markdown: String, placement: AIPlacement) -> (NSAttributedString, Int) {
        guard let storage = textStorage else { return (NSAttributedString(), 0) }
        let string = storage.string as NSString
        switch placement {
        case .inline(let location):
            let flat = markdown.replacingOccurrences(of: "\n\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            let inline = NSMutableAttributedString(attributedString: WriterMarkdown.inline(flat))
            let block = storage.attributes(at: max(0, location - 1), effectiveRange: nil)
                .filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            inline.addAttributes(block, range: NSRange(location: 0, length: inline.length))
            let previous = location > 0 ? Character(Unicode.Scalar(string.character(at: location - 1)) ?? " ") : " "
            if !previous.isWhitespace, !flat.isEmpty {
                inline.insert(NSAttributedString(string: " ", attributes: block), at: 0)
            }
            if location < string.length, let next = Unicode.Scalar(string.character(at: location)).map(Character.init),
               !next.isWhitespace, !".,;:!?".contains(next), !flat.isEmpty {
                inline.append(NSAttributedString(string: " ", attributes: block))
                return (inline, inline.length - 1)
            }
            return (inline, inline.length)
        case .fill:
            let text = WriterMarkdown.attributedString(from: markdown)
            return (text, text.length)
        case .after(let location):
            let result = NSMutableAttributedString(string: "\n", attributes: storage.attributes(at: max(0, location - 1), effectiveRange: nil)
                .filter { WriterMarkdown.paragraphKeys.contains($0.key) })
            result.append(WriterMarkdown.attributedString(from: markdown))
            return (result, result.length)
        case .before:
            let text = NSMutableAttributedString(attributedString: WriterMarkdown.attributedString(from: markdown))
            guard text.length > 0 else { return (text, 0) }
            // A table at the end already ends with its newline.
            if text.string.hasSuffix("\n") { return (text, text.length) }
            let last = text.attributes(at: text.length - 1, effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            let length = text.length
            text.append(NSAttributedString(string: "\n", attributes: last))
            return (text, length)
        }
    }

    // MARK: Proposals and findings

    /// Marks a passage (a proposal's original, a finding) without touching the text.
    func markPassage(_ range: NSRange?) {
        guard let layoutManager, let storage = textStorage else { return }
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: storage.length))
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        if !isAIWriting {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        guard let range, NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: palette.accent.withAlphaComponent(palette.isLight ? 0.16 : 0.22), forCharacterRange: range)
        scrollRangeToVisible(range)
    }

    /// Replaces a passage with Markdown as one undoable change. Whole paragraphs get blocks; a part of a
    /// paragraph gets running text.
    func replacePassage(_ range: NSRange, withMarkdown markdown: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let string = storage.string as NSString
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsParagraph = range.location == 0 || string.character(at: range.location - 1) == 0x0A
        let end = NSMaxRange(range)
        let endsParagraph = end == string.length || string.character(at: end) == 0x0A || (end > 0 && string.character(at: end - 1) == 0x0A)
        let replacement: NSMutableAttributedString
        if startsParagraph && endsParagraph {
            replacement = NSMutableAttributedString(attributedString: WriterMarkdown.attributedString(from: text))
            if end > 0, string.character(at: end - 1) == 0x0A, replacement.length > 0, !replacement.string.hasSuffix("\n") {
                let last = replacement.attributes(at: replacement.length - 1, effectiveRange: nil)
                    .filter { WriterMarkdown.paragraphKeys.contains($0.key) }
                replacement.append(NSAttributedString(string: "\n", attributes: last))
            }
            // The model sees no alignment: rewritten paragraphs keep the passage's.
            if range.location < storage.length, let alignment = storage.attribute(.writerAlignment, at: range.location, effectiveRange: nil) as? String {
                for paragraph in WriterMarkdown.paragraphs(of: replacement) where paragraph.block.takesAlignment && paragraph.alignment == nil {
                    replacement.addAttribute(.writerAlignment, value: alignment, range: paragraph.range)
                }
            }
        } else {
            let flat = text.replacingOccurrences(of: "\n\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            replacement = NSMutableAttributedString(attributedString: WriterMarkdown.inline(flat))
            let block = storage.attributes(at: range.location, effectiveRange: nil)
                .filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            replacement.addAttributes(block, range: NSRange(location: 0, length: replacement.length))
        }
        markPassage(nil)
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: replacement.string) {
            storage.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
    }

    /// Puts Markdown as new paragraphs below the paragraph that contains `location`.
    func insertBelowParagraph(at location: Int, markdown: String) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let paragraph = string.length == 0 ? NSRange(location: 0, length: 0) : string.paragraphRange(for: NSRange(location: min(location, string.length - 1), length: 0))
        var contentEnd = NSMaxRange(paragraph)
        if contentEnd > paragraph.location, string.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        let insertion = NSMutableAttributedString(string: "\n", attributes: storage.length > 0
            ? storage.attributes(at: max(0, contentEnd - 1), effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) } : [:])
        insertion.append(WriterMarkdown.attributedString(from: markdown.trimmingCharacters(in: .whitespacesAndNewlines)))
        let target = NSRange(location: contentEnd, length: 0)
        markPassage(nil)
        breakUndoCoalescing()
        if shouldChangeText(in: target, replacementString: insertion.string) {
            storage.replaceCharacters(in: target, with: insertion)
            didChangeText()
        }
        breakUndoCoalescing()
    }

    /// Replaces a finding with its correction (plain text in the passage's formatting).
    func applyCorrection(_ range: NSRange, original: String, correction: String) -> Bool {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        var target = range
        if (storage.string as NSString).substring(with: range) != original {
            // The text moved or changed: look for the passage nearby.
            let window = NSRange(location: max(0, range.location - 200), length: min(storage.length - max(0, range.location - 200), range.length + 400))
            let found = (storage.string as NSString).range(of: original, options: [], range: window)
            guard found.location != NSNotFound else { return false }
            target = found
        }
        let attributes = storage.attributes(at: target.location, effectiveRange: nil)
            .filter { $0.key != .writerDictationPreview }
        markPassage(nil)
        breakUndoCoalescing()
        if shouldChangeText(in: target, replacementString: correction) {
            storage.replaceCharacters(in: target, with: NSAttributedString(string: correction, attributes: attributes))
            didChangeText()
        }
        breakUndoCoalescing()
        return true
    }

    /// Text and document ranges of the passage to check: the selection, or the whole document, in pieces
    /// of about `limit` characters along paragraph boundaries. Code and lines are left out.
    func checkPieces(limit: Int) -> [(text: String, range: NSRange)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let scope = hasTextSelection ? selectedRange() : NSRange(location: 0, length: storage.length)
        var pieces: [(text: String, range: NSRange)] = []
        var text = ""
        var range: NSRange?
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: scope) {
            guard ![.code, .raw, .rule].contains(paragraph.block), !paragraph.block.isEmbed else { continue }
            let part = NSIntersectionRange(paragraph.contentRange, scope)
            guard part.length > 0 else { continue }
            let piece = (storage.string as NSString).substring(with: part)
            guard piece.contains(where: { $0.isLetter }) else { continue }
            if !text.isEmpty, text.count + piece.count > limit, let current = range {
                pieces.append((text, current))
                text = ""
                range = nil
            }
            text += (text.isEmpty ? "" : "\n\n") + piece
            range = range.map { NSUnionRange($0, part) } ?? part
        }
        if let range, !text.isEmpty { pieces.append((text, range)) }
        return pieces
    }

    /// Where a finding's text is within a checked piece of the document.
    func locate(_ original: String, in scope: NSRange) -> NSRange? {
        guard let storage = textStorage, !original.isEmpty, NSMaxRange(scope) <= storage.length else { return nil }
        let string = storage.string as NSString
        var found = string.range(of: original, options: [], range: scope)
        if found.location == NSNotFound { found = string.range(of: original, options: [.caseInsensitive, .diacriticInsensitive], range: scope) }
        return found.location == NSNotFound ? nil : found
    }
}

/// The AI cursor: a bar where the assistant writes and a "KI" flag in the margin of the sheet.
final class AICursorIndicator: NSView {
    var palette: WriterPalette = .dark
    var isWriting = false
    /// Where the bar is, from the left edge of this view.
    var caretX: CGFloat = 0
    var flagWidth: CGFloat = 20

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = palette.accent
        let caret = NSRect(x: caretX, y: 2, width: 2, height: bounds.height - 4)
        if isWriting {
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: caret.insetBy(dx: -3, dy: -1), xRadius: 3, yRadius: 3).fill()
        }
        color.setFill()
        NSBezierPath(roundedRect: caret, xRadius: 1, yRadius: 1).fill()

        let label = NSAttributedString(string: "KI", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: palette.isLight ? NSColor.white : NSColor(hex: 0x141417),
        ])
        let size = label.size()
        let flag = NSRect(x: 0, y: bounds.midY - (size.height + 3) / 2, width: flagWidth, height: size.height + 3)
        NSBezierPath(roundedRect: flag, xRadius: 3.5, yRadius: 3.5).fill()
        label.draw(at: NSPoint(x: flag.midX - size.width / 2, y: flag.minY + 1.5))
        if caretX - flag.maxX > 10 {
            color.withAlphaComponent(0.3).setFill()
            NSRect(x: flag.maxX + 3, y: bounds.midY - 0.5, width: caretX - flag.maxX - 6, height: 1).fill()
        }
    }
}
