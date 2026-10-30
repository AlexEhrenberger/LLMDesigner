import AppKit

/// Comments on passages (`WriterComment` on the characters): the passage is tinted, a bubble in the right margin marks
/// where a comment begins, and the side panel lists the threads. Every change is a new comment object on the same
/// characters, so undo covers it.
extension WriterTextView {
    // MARK: Finding comments

    /// The comments in text order, with their passage.
    var comments: [WriterCommentEntry] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var found: [String: (comment: WriterComment, location: Int, text: String)] = [:]
        var order: [String] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.writerComment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let comment = value as? WriterComment else { return }
            let piece = string.substring(with: range)
            if let existing = found[comment.id] {
                found[comment.id] = (existing.comment, existing.location, existing.text + " " + piece)
            } else {
                found[comment.id] = (comment, range.location, piece)
                order.append(comment.id)
            }
        }
        return order.compactMap { id in
            guard let entry = found[id] else { return nil }
            let excerpt = entry.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ").trimmingCharacters(in: .whitespaces)
            return WriterCommentEntry(comment: entry.comment, excerpt: excerpt, location: entry.location)
        }
    }

    /// The comment on the passage with the caret (or the selection's start).
    var commentAtCaret: WriterComment? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = min(selectedRange().location, storage.length - 1)
        return storage.attribute(.writerComment, at: location, effectiveRange: nil) as? WriterComment
            ?? (location > 0 ? storage.attribute(.writerComment, at: location - 1, effectiveRange: nil) as? WriterComment : nil)
    }

    func commentRanges(_ id: String) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.writerComment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? WriterComment)?.id == id else { return }
            if let last = ranges.last, NSMaxRange(last) == range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Typing at the end of a commented passage doesn't extend it; inside it, it does.
    func keepsComment(_ comment: WriterComment) -> Bool {
        guard let storage = textStorage else { return false }
        let location = selectedRange().location
        guard location > 0, location < storage.length else { return false }
        return (storage.attribute(.writerComment, at: location - 1, effectiveRange: nil) as? WriterComment)?.id == comment.id
            && (storage.attribute(.writerComment, at: location, effectiveRange: nil) as? WriterComment)?.id == comment.id
    }

    // MARK: Changing comments

    /// A comment on the selection (without one: the word at the caret, or its paragraph). Returns its id.
    @discardableResult
    func addComment(text: String = "", author: String = WriterComment.userName, isAI: Bool = false, range wanted: NSRange? = nil) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var range = wanted ?? selectedRange()
        if range.length == 0 {
            let string = storage.string as NSString
            let word = selectionRange(forProposedRange: NSRange(location: min(range.location, string.length - 1), length: 0), granularity: .selectByWord)
            if word.length > 0, string.substring(with: word).contains(where: { $0.isLetter || $0.isNumber }) {
                range = word
            } else if let paragraph = currentParagraph, paragraph.contentRange.length > 0 {
                range = paragraph.contentRange
            } else {
                onNotice?("Markiere zuerst die Stelle, die du kommentieren willst.")
                return nil
            }
        }
        // Newlines and objects at the ends stay out of the passage.
        let string = storage.string as NSString
        while range.length > 0, [0x0A, 0x20].contains(string.character(at: range.location)) { range.location += 1; range.length -= 1 }
        while range.length > 0, [0x0A, 0x20].contains(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        guard range.length > 0 else { return nil }
        let entries = text.isEmpty ? [] : [WriterComment.Entry(author: author, isAI: isAI, date: Date(), text: text)]
        let comment = WriterComment(entries: entries)
        guard shouldChangeText(in: range, replacementString: nil) else { return nil }
        storage.addAttribute(.writerComment, value: comment, range: range)
        didChangeText()
        undoManager?.setActionName("Kommentar")
        needsDisplay = true
        onStateChange?()
        return comment.id
    }

    /// Puts a changed comment on all characters of the old one, as one undoable step.
    func updateComment(_ id: String, actionName: String, _ change: (WriterComment) -> WriterComment) {
        guard let storage = textStorage else { return }
        let ranges = commentRanges(id)
        guard let first = ranges.first, let old = storage.attribute(.writerComment, at: first.location, effectiveRange: nil) as? WriterComment else { return }
        let new = change(old)
        guard new != old else { return }
        let union = ranges.reduce(first) { NSUnionRange($0, $1) }
        guard shouldChangeText(in: union, replacementString: nil) else { return }
        storage.beginEditing()
        for range in ranges { storage.addAttribute(.writerComment, value: new, range: range) }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        needsDisplay = true
        onStateChange?()
    }

    func replyToComment(_ id: String, text: String, author: String = WriterComment.userName, isAI: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        updateComment(id, actionName: "Kommentar") { comment in
            comment.with(entries: comment.entries + [WriterComment.Entry(author: author, isAI: isAI, date: Date(), text: text)])
        }
    }

    /// Changes the text of one entry (the user's own).
    func editComment(_ id: String, entry index: Int, text: String) {
        updateComment(id, actionName: "Kommentar bearbeiten") { comment in
            guard index < comment.entries.count else { return comment }
            var entries = comment.entries
            entries[index].text = text
            return comment.with(entries: entries)
        }
    }

    func resolveComment(_ id: String, _ resolved: Bool) {
        updateComment(id, actionName: resolved ? "Kommentar erledigt" : "Kommentar wieder öffnen") { $0.with(isResolved: resolved) }
    }

    func deleteComment(_ id: String) {
        guard let storage = textStorage else { return }
        let ranges = commentRanges(id)
        guard let first = ranges.first else { return }
        let union = ranges.reduce(first) { NSUnionRange($0, $1) }
        guard shouldChangeText(in: union, replacementString: nil) else { return }
        storage.beginEditing()
        for range in ranges { storage.removeAttribute(.writerComment, range: range) }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName("Kommentar löschen")
        needsDisplay = true
        onStateChange?()
    }

    /// Selects the commented passage and shows it.
    func jumpToComment(_ id: String) {
        guard let range = commentRanges(id).first else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
    }

    /// The passage and the paragraph it stands in, for the model answering a comment.
    func commentContext(_ id: String) -> (passage: String, paragraph: String)? {
        guard let storage = textStorage, let range = commentRanges(id).first else { return nil }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: range)
        var around = paragraph
        // A paragraph before and after, for context.
        if around.location > 0 { around = NSUnionRange(around, string.paragraphRange(for: NSRange(location: around.location - 1, length: 0))) }
        if NSMaxRange(around) < string.length { around = NSUnionRange(around, string.paragraphRange(for: NSRange(location: NSMaxRange(around), length: 0))) }
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (clean(commentRanges(id).map { string.substring(with: $0) }.joined(separator: " ")), clean(string.substring(with: around)))
    }

    // MARK: The margin

    /// Where the margin bubble of each open comment is (where it begins), in view coordinates.
    private func commentMarks(in characters: NSRange, origin: NSPoint) -> [(comment: WriterComment, rect: NSRect)] {
        guard let layoutManager, let storage = textStorage, let container = textContainer, storage.length > 0 else { return [] }
        var marks: [(WriterComment, NSRect)] = []
        var seen = Set<String>()
        let range = NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.writerComment, in: range) { value, run, _ in
            guard let comment = value as? WriterComment, !comment.isResolved, seen.insert(comment.id).inserted else { return }
            if run.location > 0, (storage.attribute(.writerComment, at: run.location - 1, effectiveRange: nil) as? WriterComment)?.id == comment.id { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: run.location)
            guard glyph < layoutManager.numberOfGlyphs else { return }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = origin.y + fragment.minY + max(0, (min(fragment.height, 30) - 15) / 2)
            // Several comments on one line stand side by side.
            let before = marks.filter { abs($0.1.minY - y) < 1 }.count
            let x = origin.x + container.size.width + 30 + CGFloat(before) * 24
            marks.append((comment, NSRect(x: x, y: y, width: 16, height: 15)))
        }
        return marks
    }

    /// A bubble in the right margin where each open comment begins; the active one is filled.
    func drawCommentMarks(in characters: NSRange, origin: NSPoint) {
        let active = commentAtCaret?.id
        for (comment, rect) in commentMarks(in: characters, origin: origin) {
            let symbol = comment.id == active ? "text.bubble.fill" : "text.bubble"
            let color = comment.entries.last?.isAI == true ? palette.accent : WriterStyler.commentColor(palette)
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kommentar")?.withSymbolConfiguration(configuration) else { continue }
            let drawn = NSRect(x: rect.minX, y: rect.minY, width: image.size.width, height: image.size.height)
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if comment.entries.count > 1 {
                ("\(comment.entries.count)" as NSString).draw(at: NSPoint(x: drawn.maxX + 2, y: drawn.minY - 1),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: palette.tertiaryText])
            }
        }
    }

    /// The comment whose margin bubble is at this point.
    func commentMark(at point: NSPoint) -> String? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        guard point.x > origin.x + container.size.width + 20 else { return nil }
        let band = NSRect(x: 0, y: point.y - origin.y - 40, width: container.size.width, height: 80)
        let glyphs = layoutManager.glyphRange(forBoundingRect: band, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // A comment that begins further up still has its bubble here only where it begins.
        let start = max(0, characters.location - 2_000)
        let wide = NSRange(location: start, length: min(storage.length, NSMaxRange(characters)) - start)
        return commentMarks(in: wide, origin: origin).first { $0.rect.insetBy(dx: -6, dy: -5).contains(point) }?.comment.id
    }

    // MARK: Menu

    func commentMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let comment = commentAtCaret {
            let show = ClosureMenuItem(title: "Kommentar zeigen") { [weak self] in self?.onCommentSelected?(comment.id) }
            show.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            let done = ClosureMenuItem(title: comment.isResolved ? "Kommentar wieder öffnen" : "Kommentar erledigt") { [weak self] in
                self?.resolveComment(comment.id, !comment.isResolved)
            }
            done.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            let delete = ClosureMenuItem(title: "Kommentar löschen") { [weak self] in self?.deleteComment(comment.id) }
            delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            items += [show, done, delete]
        } else {
            let add = ClosureMenuItem(title: "Kommentar hinzufügen (⌥⌘M)") { [weak self] in self?.newComment() }
            add.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            items.append(add)
        }
        let ai = ClosureMenuItem(title: hasTextSelection ? "KI kommentiert die Markierung" : "KI kommentiert das Dokument") { [weak self] in
            self?.onAssistant?(.comment)
        }
        ai.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        items.append(ai)
        return items
    }

    /// ⌥⌘M and the toolbar: a comment on the selection, written in the side panel.
    func newComment() {
        if let comment = commentAtCaret, selectedRange().length == 0 {
            onCommentSelected?(comment.id)
            return
        }
        guard let id = addComment() else { return }
        onCommentSelected?(id)
    }
}
