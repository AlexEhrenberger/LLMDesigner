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
        /// It follows a page break of the user's, which draws its own line.
        var isManual = false
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
        let count = palette.format.showsPages && slideLayout == nil ? PageCount(pages: breaks.count + 1, characters: characterCount) : nil
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
        guard format.showsPages, slideLayout == nil, let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return [] }
        // A book holds its number of lines, the user's own format its text block's height at screen size.
        let capacity = format == .custom
            ? (palette.pageSetup ?? WriterPageSetup()).textHeight * palette.screenScale(family)
            : CGFloat(format.linesPerPage) * WriterStyler.lineHeight(format, family: family)
        let string = storage.string as NSString
        var breaks: [PageBreak] = []
        // The top of the page's first line and the bottom of its lowest line so far.
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var pageHasLines = false
        // The line after a page break begins a page.
        var breaksBefore = false
        layoutManager.ensureLayout(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.length > 0 else { return }
            let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
            let startsParagraph = characters.location == 0 || Self.isParagraphEnd(string.character(at: characters.location - 1))
            let endsParagraph = NSMaxRange(characters) >= string.length || Self.isParagraphEnd(string.character(at: NSMaxRange(characters) - 1))
            let lineTop = rect.minY + (startsParagraph ? style?.paragraphSpacingBefore ?? 0 : 0)
            let lineBottom = rect.maxY - (endsParagraph ? style?.paragraphSpacing ?? 0 : 0)
            let isChapter = format.isBook && startsParagraph && WriterStyler.block(in: storage, at: characters.location) == .chapter
            let isPageBreak = storage.attribute(.attachment, at: characters.location, effectiveRange: nil) is WriterPageBreakAttachment
            // A page never stays empty; a picture taller than a page has one of its own. The room above a chapter
            // stays at the top of its page, as in print; other room there goes.
            if pageHasLines, lineTop > top + 0.5, breaksBefore || isChapter || lineBottom > top + capacity + 0.5 {
                breaks.append(PageBreak(y: bottom + min(12, (lineTop - bottom) / 2), page: breaks.count + 2, isManual: breaksBefore))
                top = isChapter ? rect.minY : lineTop
                bottom = lineBottom
            } else {
                bottom = max(bottom, lineBottom)
            }
            pageHasLines = true
            // The break's own line ends its page.
            breaksBefore = isPageBreak
        }
        return breaks
    }

    private static func isParagraphEnd(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x2029
    }

    /// The page lines and numbers over the sheet's background (the text is drawn above them).
    func drawPageBreaks(in rect: NSRect, page: NSRect, origin: NSPoint) {
        guard palette.format.showsPages else { return }
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
            // A page break of the user's is its own line; only the page's number goes with it.
            if mark.isManual {
                label("Seite \(mark.page)", below: y - 22)
                continue
            }
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

    // MARK: Head and foot

    /// Where the head line (above the text) and the foot line (below its end) are drawn; nil without them.
    func runningHeadFrames() -> (header: NSRect?, footer: NSRect?) {
        guard let heads = runningHeads, !heads.isEmpty, slideLayout == nil, let layoutManager, let container = textContainer else { return (nil, nil) }
        let origin = textContainerOrigin
        let header = heads.header.isEmpty ? nil : NSRect(x: origin.x, y: origin.y - 46, width: columnWidth, height: 18)
        let used = layoutManager.usedRect(for: container)
        let footer = heads.footer.isEmpty ? nil : NSRect(x: origin.x, y: origin.y + used.maxY + 26, width: columnWidth, height: 18)
        return (header, footer)
    }

    /// The head as the first page shows it (or the second, when the first goes without), the foot as the last page.
    func drawRunningHeads(in rect: NSRect, page: NSRect, origin: NSPoint) {
        guard let heads = runningHeads else { return }
        let frames = runningHeadFrames()
        let pages = palette.format.showsPages ? pageBreaks.count + 1 : nil
        let chapters = topLevelHeadings()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: palette.tertiaryText]
        func draw(_ line: WriterRunningHeads.Line, in frame: NSRect, page number: Int, chapter: String, note: String?, rule: CGFloat?) {
            guard frame.intersects(rect.insetBy(dx: 0, dy: -30)) else { return }
            for (text, alignment) in [(line.left, NSTextAlignment.left), (line.center, .center), (line.right, .right)] where !text.isEmpty {
                let style = NSMutableParagraphStyle()
                style.alignment = alignment
                style.lineBreakMode = .byTruncatingTail
                var shown = attributes
                shown[.paragraphStyle] = style
                let resolved = WriterRunningHeads.resolve(text, page: number, pages: pages, title: documentTitle, chapter: chapter)
                (resolved as NSString).draw(in: frame, withAttributes: shown)
            }
            if let note {
                let size = (note as NSString).size(withAttributes: attributes)
                (note as NSString).draw(at: NSPoint(x: frame.minX - size.width - 12, y: frame.minY), withAttributes: attributes)
            }
            if let rule {
                palette.rule.setFill()
                NSRect(x: frame.minX, y: rule, width: frame.width, height: 1).fill()
            }
        }
        if let frame = frames.header {
            draw(heads.header, in: frame, page: heads.skipsFirstPage ? 2 : 1, chapter: chapters.first ?? "",
                 note: heads.skipsFirstPage ? "ab S. 2" : nil, rule: heads.hasRules ? frame.maxY + 3 : nil)
        }
        if let frame = frames.footer {
            let last = pages ?? 1
            draw(heads.footer, in: frame, page: last, chapter: chapters.last ?? "", note: nil, rule: heads.hasRules ? frame.minY - 5 : nil)
        }
    }

    /// The texts of the chapters, or of the first-level headings when there are none ({Kapitel}).
    private func topLevelHeadings() -> [String] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let paragraphs = WriterMarkdown.paragraphs(of: storage)
        let level: WriterBlock = paragraphs.contains { $0.block == .chapter } ? .chapter : .heading1
        return paragraphs.filter { $0.block == level }.map {
            (storage.string as NSString).substring(with: $0.contentRange).trimmingCharacters(in: .whitespaces)
        }
    }
}
