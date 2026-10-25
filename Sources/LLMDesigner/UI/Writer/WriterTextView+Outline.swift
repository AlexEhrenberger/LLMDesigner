import AppKit

/// The structure of the document in the editor: chapters and headings (numbered once the document has a table of
/// contents), the table of contents block, jumps from the side panel, and bookmarks.
extension WriterTextView {
    /// The headings as the editor has them, with where they are.
    struct OutlineCache {
        var headings: [(heading: WriterHeading, range: NSRange)] = []
        /// Heading numbers by the location of their paragraph (formal documents only).
        var numbers: [Int: String] = [:]
        var isFormal = false
        /// Changes when a heading, its level or the numbering changes.
        var signature = ""
    }

    var outline: OutlineCache {
        if let outlineCache { return outlineCache }
        let cache = computeOutline()
        outlineCache = cache
        return cache
    }

    private func computeOutline() -> OutlineCache {
        guard let storage = textStorage, storage.length > 0 else { return OutlineCache() }
        var cache = OutlineCache()
        var levels: [Int] = []
        var found: [(title: String, range: NSRange)] = []
        for paragraph in WriterMarkdown.paragraphs(of: storage) where paragraph.cell == nil {
            // Only a table of contents from the headings numbers them; the dynamic one lists the model's topics.
            if paragraph.block == .toc, paragraph.range.length > 0,
               (storage.attribute(.attachment, at: paragraph.range.location, effectiveRange: nil) as? WriterTOCAttachment)?.isDynamic == false {
                cache.isFormal = true
            }
            guard let level = paragraph.block.headingLevel, paragraph.contentRange.length > 0 else { continue }
            let title = WriterBookmark.strip(WriterMarkdown.inlineMarkdown(storage.attributedSubstring(from: paragraph.contentRange)))
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            levels.append(level)
            found.append((title, paragraph.contentRange))
        }
        let numbers = cache.isFormal ? WriterHeadings.numbers(for: levels) : Array(repeating: nil, count: levels.count)
        for index in found.indices {
            let heading = WriterHeading(index: index, level: levels[index], title: found[index].title, number: numbers[index])
            cache.headings.append((heading, found[index].range))
            if let number = numbers[index] { cache.numbers[found[index].range.location] = number }
        }
        cache.signature = "\(cache.isFormal)|" + cache.headings.map { "\($0.heading.level):\($0.heading.title)" }.joined(separator: "\u{1F}")
        return cache
    }

    /// After an edit: the cached outline is stale. Once the edit is done, the table of contents and the numbers
    /// are redrawn if the headings changed.
    func outlineMayHaveChanged() {
        outlineCache = nil
        guard !outlineRefreshPending else { return }
        outlineRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outlineRefreshPending = false
            let signature = self.outline.signature
            guard signature != self.lastOutlineSignature else { return }
            self.lastOutlineSignature = signature
            self.relayoutTablesOfContents()
            self.needsDisplay = true
            self.onOutlineChange?()
        }
    }

    /// The table of contents block grows and shrinks with its entries.
    func relayoutTablesOfContents() {
        guard let storage = textStorage, let layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is WriterTOCAttachment else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    // MARK: Table of contents

    /// The table of contents in the text and where it is.
    var tableOfContents: (attachment: WriterTOCAttachment, location: Int)? {
        guard let location = firstLocation(of: WriterTOCAttachment.self),
              let attachment = textStorage?.attribute(.attachment, at: location, effectiveRange: nil) as? WriterTOCAttachment else { return nil }
        return (attachment, location)
    }

    /// Puts the table of contents below the current paragraph (or at the start when the caret is in the first
    /// empty line). From the headings, chapters and headings are numbered from then on; the dynamic one lists the
    /// model's topics. A document has one table of contents: if there is one already, it is switched over.
    func insertTableOfContents(dynamic: Bool = false) {
        guard let storage = textStorage else { return }
        if let existing = tableOfContents {
            if existing.attachment.isDynamic != dynamic {
                setTableOfContents(dynamic: dynamic)
            } else {
                onNotice?("Das Dokument hat schon ein Inhaltsverzeichnis.")
            }
            selectEmbed(at: existing.location)
            scrollRangeToVisible(NSRange(location: existing.location, length: 1))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.toc.rawValue, .writerListLevel: 0]
        let block = NSMutableAttributedString(attachment: WriterTOCAttachment(dynamic: dynamic))
        block.append(NSAttributedString(string: "\n"))
        block.addAttributes(attributes, range: NSRange(location: 0, length: block.length))
        guard let start = insertBlock(block) else { return }
        setSelectedRange(NSRange(location: min(start + block.length, storage.length), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
        scrollRangeToVisible(NSRange(location: start, length: 1))
        if dynamic { onDynamicTOCNeeded?() }
    }

    /// Switches the table of contents between the headings and the model's topics (one undoable step).
    func setTableOfContents(dynamic: Bool) {
        guard let storage = textStorage, let existing = tableOfContents, existing.attachment.isDynamic != dynamic else { return }
        let range = NSRange(location: existing.location, length: 1)
        let text = NSMutableAttributedString(attachment: WriterTOCAttachment(dynamic: dynamic))
        var attributes = storage.attributes(at: existing.location, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        text.addAttributes(attributes, range: NSRange(location: 0, length: 1))
        performStructureEdit(in: range, with: text)
        undoManager?.setActionName("Inhaltsverzeichnis umstellen")
        if dynamic { onDynamicTOCNeeded?() }
        onStateChange?()
    }

    func removeTableOfContents() {
        guard let existing = tableOfContents else { return }
        deleteEmbed(at: existing.location)
    }

    /// The table of contents under a point (for the context menu).
    func tableOfContentsLocation(at point: NSPoint) -> Int? {
        guard let existing = tableOfContents, let frame = attachmentFrame(at: existing.location), frame.contains(point) else { return nil }
        return existing.location
    }

    func tableOfContentsMenuItems(at location: Int) -> [NSMenuItem] {
        guard let existing = tableOfContents, existing.location == location else { return [] }
        let headings = ClosureMenuItem(title: "Aus Kapiteln und Überschriften (nummeriert)") { [weak self] in self?.setTableOfContents(dynamic: false) }
        headings.state = existing.attachment.isDynamic ? .off : .on
        let dynamic = ClosureMenuItem(title: "Dynamisch – vom Modell gegliedert") { [weak self] in self?.setTableOfContents(dynamic: true) }
        dynamic.state = existing.attachment.isDynamic ? .on : .off
        let remove = ClosureMenuItem(title: "Inhaltsverzeichnis entfernen") { [weak self] in self?.removeTableOfContents() }
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return [headings, dynamic, remove, .separator()]
    }

    /// The number of Markdown blocks, for finding a dynamic entry's place.
    var markdownBlockCount: Int {
        MarkdownParser.parse(WriterBookmark.strip(markdown)).count
    }

    func firstLocation<T: NSTextAttachment>(of type: T.Type) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value is T { found = range.location; stop.pointee = true }
        }
        return found
    }

    // MARK: Jumps

    func jumpToHeading(_ index: Int) {
        let headings = outline.headings
        guard headings.indices.contains(index) else { return }
        reveal(headings[index].range)
    }

    /// A place of the dynamic table of contents: the paragraph that begins like the anchored one, the nearest
    /// one to its old place when several do.
    func jump(to anchor: DocumentAnchor, blockCount: Int) {
        guard let storage = textStorage, storage.length > 0 else { return }
        var candidates: [NSRange] = []
        for paragraph in WriterMarkdown.paragraphs(of: storage) where paragraph.contentRange.length > 0 {
            let key = DocumentOutlineBuilder.searchKey(storage.attributedSubstring(from: paragraph.contentRange).string)
            if DocumentOutlineBuilder.matches(key, anchor: anchor.key) { candidates.append(paragraph.contentRange) }
        }
        let expected = Double(anchor.block) / Double(max(blockCount, 1)) * Double(storage.length)
        guard let best = candidates.min(by: { abs(Double($0.location) - expected) < abs(Double($1.location) - expected) }) else {
            onNotice?("Die Stelle gibt es so nicht mehr – das Inhaltsverzeichnis wird gleich aktualisiert.")
            return
        }
        reveal(best)
    }

    func jumpToBookmark(_ id: String) {
        guard let range = bookmarkRanges(id).first else { return }
        reveal(range, select: true)
    }

    /// Scrolls the passage to the upper part of the window, puts the caret there and lights it up briefly.
    func reveal(_ range: NSRange, select: Bool = false) {
        guard let layoutManager, let container = textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(select ? range : NSRange(location: range.location, length: 0))
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        if let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            let maxY = max(0, frame.height - clip.bounds.height)
            let target = NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(0, rect.minY - 110)))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        }
        flash(range)
    }

    private func flash(_ range: NSRange) {
        guard let layoutManager else { return }
        let color = palette.accent.withAlphaComponent(palette.isLight ? 0.2 : 0.28)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let layoutManager = self.layoutManager, let storage = self.textStorage, NSMaxRange(range) <= storage.length else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    /// The heading the reader is in: the last one above the upper part of the visible area.
    func headingAtTop() -> Int? {
        guard let layoutManager, let container = textContainer, let scrollView = enclosingScrollView else { return nil }
        let line = scrollView.documentVisibleRect.minY + 140
        var current: Int?
        for (heading, range) in outline.headings {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let y = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).minY + textContainerOrigin.y
            guard y <= line else { break }
            current = heading.index
        }
        return current
    }

    // MARK: Bookmarks

    /// The bookmark at the caret (or at the start of the selection).
    var bookmarkAtCaret: WriterBookmark? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = min(selectedRange().location, storage.length - 1)
        return storage.attribute(.writerBookmark, at: location, effectiveRange: nil) as? WriterBookmark
            ?? (location > 0 ? storage.attribute(.writerBookmark, at: location - 1, effectiveRange: nil) as? WriterBookmark : nil)
    }

    func bookmarkRanges(_ id: String) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.writerBookmark, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? WriterBookmark)?.id == id else { return }
            if let last = ranges.last, NSMaxRange(last) == range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Bookmarks the selection (within its first paragraph), or the paragraph with the caret.
    func addBookmark() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let selection = selectedRange()
        let paragraph = WriterMarkdown.paragraphs(of: storage, in: NSRange(location: min(selection.location, storage.length - 1), length: 0)).first
        guard let paragraph else { onNotice?("Setze den Cursor in einen Absatz, um ein Lesezeichen anzulegen."); return }
        guard ![.code, .raw, .rule].contains(paragraph.block), !paragraph.block.isEmbed else {
            onNotice?("Lesezeichen gehen auf Text, Überschriften, Listen und Tabellen.")
            return
        }
        var range = selection.length > 0 ? NSIntersectionRange(selection, paragraph.contentRange) : paragraph.contentRange
        // Without the spaces around it.
        let string = storage.string as NSString
        while range.length > 0, string.substring(with: NSRange(location: range.location, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty {
            range = NSRange(location: range.location + 1, length: range.length - 1)
        }
        while range.length > 0, string.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty {
            range.length -= 1
        }
        guard range.length > 0 else { onNotice?("Hier gibt es keinen Text für ein Lesezeichen."); return }
        let text = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: " ")
        let bookmark = WriterBookmark(title: BookmarkLocator.title(from: text))
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.removeAttribute(.writerBookmark, range: range)
        storage.addAttribute(.writerBookmark, value: bookmark, range: range)
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName("Lesezeichen anlegen")
        needsDisplay = true
        onBookmarkAdded?(bookmark.id)
        onStateChange?()
    }

    func removeBookmark(_ id: String) {
        changeBookmark(id) { _ in nil }
        undoManager?.setActionName("Lesezeichen entfernen")
    }

    func renameBookmark(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        changeBookmark(id) { WriterBookmark(id: $0.id, title: trimmed) }
        undoManager?.setActionName("Lesezeichen umbenennen")
    }

    private func changeBookmark(_ id: String, _ change: (WriterBookmark) -> WriterBookmark?) {
        guard let storage = textStorage else { return }
        let ranges = bookmarkRanges(id)
        guard let first = ranges.first, let current = storage.attribute(.writerBookmark, at: first.location, effectiveRange: nil) as? WriterBookmark,
              shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        let replacement = change(current)
        storage.beginEditing()
        for range in ranges {
            if let replacement {
                storage.addAttribute(.writerBookmark, value: replacement, range: range)
            } else {
                storage.removeAttribute(.writerBookmark, range: range)
            }
        }
        storage.endEditing()
        didChangeText()
        needsDisplay = true
        onStateChange?()
    }

    /// Text typed inside a bookmark belongs to it; at its edges it doesn't.
    func keepsBookmark(_ bookmark: WriterBookmark) -> Bool {
        guard let storage = textStorage else { return false }
        let location = selectedRange().location
        guard location > 0, location < storage.length else { return false }
        return (storage.attribute(.writerBookmark, at: location - 1, effectiveRange: nil) as? WriterBookmark)?.id == bookmark.id
            && (storage.attribute(.writerBookmark, at: location, effectiveRange: nil) as? WriterBookmark)?.id == bookmark.id
    }

    // MARK: Margin marks

    /// Heading numbers left of the column and bookmark marks right of it.
    func drawOutlineMarks(in characters: NSRange, origin: NSPoint) {
        guard let layoutManager, let storage = textStorage, let container = textContainer, storage.length > 0 else { return }
        let cache = outline
        if !cache.numbers.isEmpty {
            for paragraph in WriterMarkdown.paragraphs(of: storage, in: characters) {
                guard let number = cache.numbers[paragraph.contentRange.location], paragraph.contentRange.length > 0 else { continue }
                let glyph = layoutManager.glyphIndexForCharacter(at: paragraph.contentRange.location)
                guard glyph < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = layoutManager.location(forGlyphAt: glyph).y
                let font = WriterStyler.blockFont(paragraph.block, family: family, format: palette.format)
                let attributes: [NSAttributedString.Key: Any] = [.font: WriterStyler.font(family, size: font.pointSize, weight: .regular), .foregroundColor: palette.tertiaryText]
                let size = (number as NSString).size(withAttributes: attributes)
                let point = NSPoint(x: origin.x - 14 - size.width, y: origin.y + fragment.minY + baseline - font.ascender)
                (number as NSString).draw(at: point, withAttributes: attributes)
            }
        }

        var drawn = Set<String>()
        storage.enumerateAttribute(.writerBookmark, in: characters) { value, range, _ in
            guard let bookmark = value as? WriterBookmark, drawn.insert(bookmark.id).inserted else { return }
            // Only where the bookmark begins.
            if range.location > 0, (storage.attribute(.writerBookmark, at: range.location - 1, effectiveRange: nil) as? WriterBookmark)?.id == bookmark.id { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { return }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [palette.accent]))
            guard let image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Lesezeichen")?.withSymbolConfiguration(configuration) else { return }
            let x = origin.x + container.size.width + 12
            let rect = NSRect(x: x, y: origin.y + fragment.minY + max(0, (min(fragment.height, 30) - image.size.height) / 2), width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Draws the table of contents: the chapters and headings with their numbers, indented by level, or the model's
/// topics with their points. A click on an entry jumps there; a click elsewhere selects the block.
final class WriterTOCCell: NSTextAttachmentCell {
    private enum Target {
        case heading(Int)
        case anchor(DocumentAnchor)
    }

    private struct Entry {
        let target: Target
        let rect: NSRect
        let number: NSAttributedString?
        let numberWidth: CGFloat
        let title: NSAttributedString
    }

    private struct Layout {
        var size: NSSize
        var heading: NSAttributedString
        var entries: [Entry]
        var placeholder: NSAttributedString?
    }

    private static let padding: CGFloat = 20
    private var lastLayout: Layout?

    private var isDynamic: Bool { (attachment as? WriterTOCAttachment)?.isDynamic ?? false }

    /// The entries to draw: (target, level from 0, number, title).
    private func items(_ view: WriterTextView?) -> [(target: Target, level: Int, number: String?, title: String)] {
        if isDynamic {
            guard let outline = view?.dynamicOutline else { return [] }
            return outline.sections.enumerated().flatMap { index, section in
                [(Target.anchor(section.anchor), 0, "\(index + 1)", section.title)]
                    + section.items.map { (Target.anchor($0.anchor), 1, nil as String?, $0.title) }
            }
        }
        let headings = view?.outline.headings.map(\.heading) ?? []
        let top = headings.map(\.level).min() ?? 0
        return headings.map { (Target.heading($0.index), $0.level - top, $0.number, WriterHeadings.plainTitle($0.title)) }
    }

    private func layout(width: CGFloat, view: WriterTextView?) -> Layout {
        let family = view?.family ?? .serif
        let palette = view?.palette ?? .dark
        let body = WriterStyler.bodySize(family)
        let heading = NSMutableAttributedString(string: "Inhaltsverzeichnis", attributes: [
            .font: WriterStyler.font(family, size: body + 3, weight: .semibold),
            .foregroundColor: palette.text,
        ])
        if isDynamic {
            heading.append(NSAttributedString(string: "   dynamisch · vom Modell gegliedert", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: palette.tertiaryText,
            ]))
        }
        var y = Self.padding + ceil(heading.size().height) + 12
        var entries: [Entry] = []
        let truncating: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        for item in items(view) {
            let isTop = item.level == 0
            let font = WriterStyler.font(family, size: body - (isTop ? 0 : 1), weight: isTop ? .semibold : .regular)
            if isTop, !entries.isEmpty { y += 6 }
            let indent = Self.padding + CGFloat(item.level) * 22
            let number = item.number.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: palette.secondaryText]) }
            let numberWidth = number.map { ceil($0.size().width) + 10 } ?? 0
            let title = NSAttributedString(string: item.title, attributes: [
                .font: font, .foregroundColor: isTop ? palette.text : palette.secondaryText, .paragraphStyle: truncating,
            ])
            let height = ceil(font.ascender - font.descender + font.leading) + 7
            entries.append(Entry(target: item.target, rect: NSRect(x: indent, y: y, width: max(40, width - indent - Self.padding), height: height),
                                 number: number, numberWidth: numberWidth, title: title))
            y += height
        }
        var placeholder: NSAttributedString?
        if entries.isEmpty {
            let text = isDynamic
                ? "Das Modell gliedert das Dokument in Themen, sobald es etwa \(DocumentOutlineBuilder.minimumWords) Wörter hat (oder über „Jetzt erstellen“ in der Seitenleiste). Die Themen erscheinen hier und wachsen mit dem Text."
                : "Noch keine Überschriften. Kapitel und Überschriften (Absatzformat ¶) erscheinen hier von selbst und werden nummeriert."
            placeholder = NSAttributedString(string: text, attributes: [
                .font: WriterStyler.font(family, size: body - 2, italic: true),
                .foregroundColor: palette.tertiaryText,
            ])
            let bounds = placeholder!.boundingRect(with: NSSize(width: width - 2 * Self.padding, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += ceil(bounds.height)
        }
        return Layout(size: NSSize(width: width, height: y + Self.padding - 4), heading: heading, entries: entries, placeholder: placeholder)
    }

    override func cellSize() -> NSSize { lastLayout?.size ?? NSSize(width: 320, height: 90) }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let layout = layout(width: max(220, lineFrag.width - 2), view: textContainer.textView as? WriterTextView)
        lastLayout = layout
        return NSRect(origin: .zero, size: layout.size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: charIndex)
    }

    private func draw(_ frame: NSRect, view: WriterTextView?, characterIndex: Int?) {
        let layout = lastLayout.flatMap { $0.size == frame.size ? $0 : nil } ?? self.layout(width: frame.width, view: view)
        let palette = view?.palette ?? .dark
        let box = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        palette.codeBlock.setFill()
        box.fill()
        if let characterIndex, let view, view.selectedRange() == NSRange(location: characterIndex, length: 1) {
            palette.accent.setStroke()
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 1.25, dy: 1.25), xRadius: 9, yRadius: 9)
            outline.lineWidth = 2.5
            outline.stroke()
        }
        layout.heading.draw(at: NSPoint(x: frame.minX + Self.padding, y: frame.minY + Self.padding))
        for entry in layout.entries {
            let rect = entry.rect.offsetBy(dx: frame.minX, dy: frame.minY)
            entry.number?.draw(at: NSPoint(x: rect.minX, y: rect.minY + 3))
            entry.title.draw(with: NSRect(x: rect.minX + entry.numberWidth, y: rect.minY + 3, width: rect.width - entry.numberWidth, height: rect.height),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let placeholder = layout.placeholder {
            let y = frame.minY + Self.padding + ceil(layout.heading.size().height) + 12
            placeholder.draw(with: NSRect(x: frame.minX + Self.padding, y: y, width: frame.width - 2 * Self.padding, height: frame.maxY - y),
                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        let point = view.convert(theEvent.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - cellFrame.minX, y: point.y - cellFrame.minY)
        switch lastLayout?.entries.first(where: { $0.rect.insetBy(dx: -6, dy: 0).contains(local) })?.target {
        case .heading(let index): view.jumpToHeading(index)
        case .anchor(let anchor): view.jump(to: anchor, blockCount: view.markdownBlockCount)
        case nil: view.selectEmbed(at: charIndex)
        }
        return true
    }
}
