import AppKit

/// A paperback or a Normseite shows where its pages end: a dashed line across the sheet, the number of the page that
/// begins there in the right margin. The pages are counted from the laid-out lines: a page holds the format's
/// number of lines at the screen's line distance (`WriterStyler.lineHeight`), room before a page's first line and
/// after its last one doesn't count, and a chapter begins a new page, as in print.
extension WriterTextView: NSLayoutManagerDelegate {
    struct PageBreak: Equatable {
        /// Where the line between the pages goes, in the text container.
        var y: CGFloat
        /// The page that begins there.
        var page: Int
    }

    /// The pages, and the characters with spaces (without line ends and objects), which publishers also count a
    /// Normseite by.
    struct PageCount: Equatable {
        var pages: Int
        var characters: Int
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        schedulePageUpdate()
    }

    /// Counts the pages again once the layout settled (several layout passes come together).
    func schedulePageUpdate() {
        guard !pageUpdatePending else { return }
        pageUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pageUpdatePending = false
            updatePages()
        }
    }

    func updatePages() {
        let breaks = computePageBreaks()
        if breaks != pageBreaks {
            pageBreaks = breaks
            needsDisplay = true
        }
        let count = palette.format.isBook && slideLayout == nil ? PageCount(pages: breaks.count + 1, characters: characterCount) : nil
        if count != reportedPageCount {
            reportedPageCount = count
            onPageCount?(count)
        }
    }

    private var characterCount: Int {
        guard let storage = textStorage else { return 0 }
        return (storage.string as NSString).length - storage.string.utf16.reduce(0) { count, unit in
            count + (unit == 0x0A || unit == 0x2029 || unit == 0xFFFC ? 1 : 0)
        }
    }

    private func computePageBreaks() -> [PageBreak] {
        let format = palette.format
        guard format.isBook, slideLayout == nil, let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return [] }
        let capacity = CGFloat(format.linesPerPage) * WriterStyler.lineHeight(format, family: family)
        let string = storage.string as NSString
        var breaks: [PageBreak] = []
        // The top of the page's first line and the bottom of its lowest line so far.
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var pageHasLines = false
        layoutManager.ensureLayout(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.length > 0 else { return }
            let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
            let startsParagraph = characters.location == 0 || Self.isParagraphEnd(string.character(at: characters.location - 1))
            let endsParagraph = NSMaxRange(characters) >= string.length || Self.isParagraphEnd(string.character(at: NSMaxRange(characters) - 1))
            let lineTop = rect.minY + (startsParagraph ? style?.paragraphSpacingBefore ?? 0 : 0)
            let lineBottom = rect.maxY - (endsParagraph ? style?.paragraphSpacing ?? 0 : 0)
            let isChapter = startsParagraph && WriterStyler.block(in: storage, at: characters.location) == .chapter
            // A page never stays empty; a picture taller than a page has one of its own. The room above a chapter
            // stays at the top of its page, as in print; other room there goes.
            if pageHasLines, lineTop > top + 0.5, isChapter || lineBottom > top + capacity + 0.5 {
                breaks.append(PageBreak(y: bottom + min(12, (lineTop - bottom) / 2), page: breaks.count + 2))
                top = isChapter ? rect.minY : lineTop
                bottom = lineBottom
            } else {
                bottom = max(bottom, lineBottom)
            }
            pageHasLines = true
        }
        return breaks
    }

    private static func isParagraphEnd(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x2029
    }

    /// The page lines and numbers over the sheet's background (the text is drawn above them).
    func drawPageBreaks(in rect: NSRect, page: NSRect, origin: NSPoint) {
        guard palette.format.isBook else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.tertiaryText,
        ]
        func label(_ text: String, below y: CGFloat) {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: page.maxX - 12 - size.width, y: y + 4), withAttributes: attributes)
        }
        if rect.minY < page.minY + 40 { label("Seite 1", below: page.minY + 6) }
        for mark in pageBreaks {
            let y = (origin.y + mark.y).rounded() + 0.5
            guard y > rect.minY - 24, y < rect.maxY + 24 else { continue }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: page.minX + 1, y: y))
            line.line(to: NSPoint(x: page.maxX - 1, y: y))
            line.lineWidth = 1
            line.setLineDash([4, 4], count: 2, phase: 0)
            palette.rule.setStroke()
            line.stroke()
            label("Seite \(mark.page)", below: y)
        }
    }
}
