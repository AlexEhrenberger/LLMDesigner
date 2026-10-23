import AppKit

/// The colours of the places the find bar found, in the text and on the speaker card.
enum FindColors {
    static let current = NSColor(hex: 0xFFD60A)
    static let currentText = NSColor(hex: 0x17171B)

    static func other(onLight: Bool) -> NSColor {
        current.withAlphaComponent(onLight ? 0.4 : 0.27)
    }
}

/// The find bar's places in the text (see `DocumentFind`): all of them lightly marked, the current one in full
/// yellow with dark letters. They are drawn by the layout manager, so the other highlights (read aloud, the AI's
/// passage, a jump from the contents) are not touched.
extension WriterTextView {
    func setFindMatches(_ ranges: [NSRange], current: NSRange?) {
        guard ranges != findMatches || current != currentFindMatch else { return }
        findMatches = ranges
        currentFindMatch = current
        // The dark letters of the current place; edits may have moved the old ones, so they go everywhere.
        if let layoutManager, let storage = textStorage {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            if let current, NSMaxRange(current) <= storage.length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: FindColors.currentText, forCharacterRange: current)
            }
        }
        needsDisplay = true
    }

    /// Scrolls a found place into view, unless it is already well visible; the caret and the keyboard stay.
    func revealFindMatch(_ range: NSRange) {
        guard let layoutManager, let container = textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length,
              let scrollView = enclosingScrollView else { return }
        if slideLayout != nil { return scrollRangeToVisible(range) }
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let clip = scrollView.contentView
        let visible = clip.bounds
        // The find bar floats over the top of the sheet, the assistant bar over its bottom.
        let comfortable = NSRect(x: visible.minX, y: visible.minY + 64, width: visible.width, height: max(40, visible.height - 64 - 150))
        guard !comfortable.contains(rect) else { return }
        let maxY = max(0, frame.height - visible.height)
        let target = NSPoint(x: visible.origin.x, y: min(maxY, max(0, rect.midY - visible.height * 0.38)))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// The bar closes, or ⌘G goes on from the text: the place found becomes the selection, with the keyboard.
    func selectFindMatch(_ range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        revealFindMatch(range)
    }

    /// Called by the layout manager after the text's own backgrounds, for the glyphs being drawn.
    func drawFindMatches(in characters: NSRange, layoutManager: NSLayoutManager, container: NSTextContainer, origin: NSPoint) {
        guard !findMatches.isEmpty, let storage = textStorage else { return }
        let length = storage.length
        // The matches are in order: skip those before the part being drawn.
        var low = 0
        var high = findMatches.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(findMatches[middle]) < characters.location { low = middle + 1 } else { high = middle }
        }
        let other = FindColors.other(onLight: palette.isLight)
        for range in findMatches[low...] {
            guard range.location <= NSMaxRange(characters) else { break }
            // Edited a moment ago: the bar finds the places anew in a moment.
            guard NSMaxRange(range) <= length else { break }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let color = range == currentFindMatch ? FindColors.current : other
            color.setFill()
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let marked = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0)
                NSBezierPath(roundedRect: marked, xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}
