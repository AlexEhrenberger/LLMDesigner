import AppKit

/// Where boxes and sections in columns put their lines. TextKit lays out text in one column; two things change that:
/// - `WriterTextContainer` narrows each line: to a box's inside, to the first column of a section, and beside a box
///   the text flows around.
/// - The layout manager's delegate (`adjust`) moves finished lines: the second column of a section up and to the
///   right, the text after a floating box up beside it, and the text after a section below its longer column.
/// What a pass learns (the heights of a section's lines, where a floating box is) is kept here for the next lines and
/// the next pass; a section whose columns came out unequal is laid out once more.
final class WriterFlowLayout {
    struct Float {
        weak var box: WriterBox?
        var frame: CGRect
        /// The first character after the box; the line that starts there goes up beside it.
        var end: Int
        var awaitsFirstLine: Bool
        var isRight: Bool
    }

    struct Line {
        var height: CGFloat
        /// Where it ended up (after moving).
        var maxY: CGFloat
        var usedTop: CGFloat
        var isInSecondColumn: Bool
    }

    var floats: [ObjectIdentifier: Float] = [:]
    /// By section: where the second column starts (characters from the section's start, so text changing above it
    /// doesn't move it), the lines by their first character, and the bottom.
    var splits: [ObjectIdentifier: Int] = [:]
    var lines: [ObjectIdentifier: [Int: Line]] = [:]
    var bottoms: [ObjectIdentifier: CGFloat] = [:]
    /// Sections to lay out once more (their first character), because their split moved.
    var relayoutPending: [ObjectIdentifier: Int] = [:]

    func reset() {
        floats = [:]
        splits = [:]
        lines = [:]
        bottoms = [:]
    }
}

/// The text container of Writer Studio: lines in boxes, columns and beside floating boxes are narrower (see
/// `WriterFlowLayout`).
final class WriterTextContainer: NSTextContainer {
    weak var writerView: WriterTextView?

    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let view = writerView, view.slideLayout == nil, let storage = layoutManager?.textStorage,
              characterIndex < storage.length, !rect.isEmpty else { return rect }
        let section = storage.attribute(.writerColumns, at: characterIndex, effectiveRange: nil) as? WriterColumnSection
        let box = storage.attribute(.writerBox, at: characterIndex, effectiveRange: nil) as? WriterBox
        if section == nil, box == nil {
            return view.flow.cutting(rect, at: characterIndex, storage: storage)
        }
        let base = section.map { view.columnGeometry($0, width: size.width).columnWidth } ?? size.width
        if let box {
            let place = box.style.horizontal(in: base)
            let left = place.x + WriterBoxStyle.paddingLeft
            let right = place.x + place.width - WriterBoxStyle.paddingRight
            rect.origin.x = max(rect.minX, left)
            rect.size.width = max(20, right - rect.minX)
        } else {
            rect.size.width = max(20, min(rect.maxX, base) - rect.minX)
        }
        // A box or a section that comes while text flows around a box goes below it.
        if section == nil, box?.style.floats != true {
            for float in view.flow.floats.values where float.end <= characterIndex && float.box != nil && float.box !== box {
                if rect.minY < float.frame.maxY, rect.maxY > float.frame.minY { rect.origin.y = float.frame.maxY + WriterBoxStyle.marginTop }
            }
        }
        return rect
    }
}

extension WriterFlowLayout {
    /// A line of plain text beside floating boxes: shortened on the box's side. The first line after a box is measured
    /// where it will go, at the box's top.
    func cutting(_ rect: NSRect, at index: Int, storage: NSTextStorage) -> NSRect {
        guard !floats.isEmpty else { return rect }
        var result = rect
        for float in floats.values where float.end <= index {
            guard let box = float.box, float.end > 0, float.end <= storage.length,
                  storage.attribute(.writerBox, at: float.end - 1, effectiveRange: nil) as? WriterBox === box else { continue }
            var probe = result
            // The first line after the box goes up beside it (every time it is laid out): measured there.
            if index == float.end { probe.origin.y = float.frame.minY }
            guard probe.minY < float.frame.maxY, probe.maxY > float.frame.minY else { continue }
            if float.isRight {
                result.size.width = max(40, min(result.maxX, float.frame.minX - WriterBoxStyle.gap) - result.minX)
            } else {
                let left = float.frame.maxX + WriterBoxStyle.gap
                result.size.width = max(40, result.maxX - left)
                result.origin.x = max(result.minX, left)
            }
        }
        return result
    }
}

extension WriterTextView {
    /// The width of a section's columns and the room between them, in the container.
    func columnGeometry(_ section: WriterColumnSection, width: CGFloat) -> (columnWidth: CGFloat, gap: CGFloat) {
        let gap = max(10, WriterParagraphFormat.screenPoints(cm: section.style.gap, scale: palette.screenScale(family)))
        let count = CGFloat(section.style.count)
        return (((width - gap * (count - 1)) / count).rounded(.down), gap)
    }

    /// The range of the paragraphs that carry this attribute value around `location`.
    func containerRange(_ key: NSAttributedString.Key, at location: Int) -> NSRange? {
        guard let storage = textStorage, location < storage.length, storage.attribute(key, at: location, effectiveRange: nil) != nil else { return nil }
        var range = NSRange()
        storage.attribute(key, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        return range
    }

    // MARK: Moving lines (NSLayoutManagerDelegate)

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard slideLayout == nil, let storage = textStorage, storage.length > 0 else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let location = characters.location
        guard location < storage.length else { return false }
        let section = storage.attribute(.writerColumns, at: location, effectiveRange: nil) as? WriterColumnSection
        let box = storage.attribute(.writerBox, at: location, effectiveRange: nil) as? WriterBox
        var changed = false

        // After a section: below its longer column.
        if location > 0, let before = storage.attribute(.writerColumns, at: location - 1, effectiveRange: nil) as? WriterColumnSection,
           section !== before, let bottom = flow.bottoms[ObjectIdentifier(before)] {
            let down = bottom + 10 - lineFragmentRect.pointee.minY
            if down > 0 {
                lineFragmentRect.pointee.origin.y += down
                lineFragmentUsedRect.pointee.origin.y += down
                changed = true
            }
        }

        // After a floating box: up beside it.
        if section == nil, box == nil, location > 0, let before = storage.attribute(.writerBox, at: location - 1, effectiveRange: nil) as? WriterBox,
           before.style.floats, storage.attribute(.writerColumns, at: location - 1, effectiveRange: nil) == nil,
           let float = flow.floats[ObjectIdentifier(before)], float.box === before, float.end == location {
            let up = float.frame.minY - lineFragmentRect.pointee.minY
            if up < 0 {
                lineFragmentRect.pointee.origin.y += up
                lineFragmentUsedRect.pointee.origin.y += up
                changed = true
            }
        }

        // A floating box: where it is, for the lines that flow around it.
        if let box, box.style.floats, section == nil, let range = containerRange(.writerBox, at: location) {
            let key = ObjectIdentifier(box)
            let place = box.style.horizontal(in: textContainer.size.width)
            var float = flow.floats[key] ?? WriterFlowLayout.Float(box: box, frame: .zero, end: NSMaxRange(range), awaitsFirstLine: false,
                                                                    isRight: box.style.position == .right)
            float.box = box
            float.isRight = box.style.position == .right
            if location == range.location {
                float.frame = CGRect(x: place.x, y: lineFragmentRect.pointee.minY + WriterBoxStyle.marginTop, width: place.width, height: 0)
            }
            float.frame.origin.x = place.x
            float.frame.size.width = place.width
            float.frame.size.height = max(0, lineFragmentRect.pointee.maxY - float.frame.minY)
            if NSMaxRange(characters) >= NSMaxRange(range) {
                float.frame.size.height = max(0, lineFragmentRect.pointee.maxY - WriterBoxStyle.marginBottom - float.frame.minY)
                float.end = NSMaxRange(range)
                float.awaitsFirstLine = true
            }
            flow.floats[key] = float
        }

        // A line of a section in columns.
        if let section, let range = containerRange(.writerColumns, at: location) {
            changed = placeColumnLine(section, range: range, characters: characters, rect: lineFragmentRect, used: lineFragmentUsedRect,
                                      width: textContainer.size.width) || changed
        }
        return changed
    }

    /// Puts a section's line in its column: lines from the split on go to the second column, the first of them to the
    /// section's top. At the section's last line the split is checked against the heights and, if the columns came
    /// out unequal, the section is laid out once more.
    private func placeColumnLine(_ section: WriterColumnSection, range: NSRange, characters: NSRange, rect: UnsafeMutablePointer<NSRect>,
                                 used: UnsafeMutablePointer<NSRect>, width: CGFloat) -> Bool {
        let key = ObjectIdentifier(section)
        let geometry = columnGeometry(section, width: width)
        let location = characters.location
        // A pass that starts at the section's first line lays all of it out anew; one that starts inside keeps the lines
        // above the change.
        var lines = location == range.location ? [:] : (flow.lines[key] ?? [:]).filter { $0.key < location && $0.key >= range.location }
        let height = rect.pointee.height
        var split = flow.splits[key].map { $0 == Int.max ? Int.max : range.location + $0 } ?? Int.max
        if let forced = forcedSplit(in: range) { split = forced }
        var changed = false
        let inSecond = location >= split || split < NSMaxRange(characters)
        if inSecond {
            // The first line of the second column goes up to where the section's text begins.
            let isFirst = !lines.values.contains(where: \.isInSecondColumn)
            if isFirst, let top = lines.min(by: { $0.key < $1.key })?.value.usedTop {
                let up = top - used.pointee.minY
                rect.pointee.origin.y += up
                used.pointee.origin.y += up
            }
            let right = geometry.columnWidth + geometry.gap
            rect.pointee.origin.x += right
            used.pointee.origin.x += right
            changed = true
        }
        lines[location] = WriterFlowLayout.Line(height: height, maxY: rect.pointee.maxY, usedTop: used.pointee.minY, isInSecondColumn: inSecond)
        flow.lines[key] = lines

        guard NSMaxRange(characters) >= NSMaxRange(range) else { return changed }
        // The last line: the section ends below its longer column.
        flow.bottoms[key] = lines.values.map(\.maxY).max() ?? rect.pointee.maxY
        // Balance: the second column starts where half of the heights is reached.
        if forcedSplit(in: range) == nil {
            let ordered = lines.sorted { $0.key < $1.key }
            let total = ordered.reduce(0) { $0 + $1.value.height }
            var sum: CGFloat = 0
            var ideal = Int.max
            for (start, line) in ordered {
                if sum >= total / 2 - 0.5, sum > 0 {
                    ideal = start
                    break
                }
                sum += line.height
            }
            let current = flow.splits[key].map { $0 == Int.max ? Int.max : range.location + $0 } ?? Int.max
            if ideal != current, flow.relayoutPending[key] == nil {
                flow.splits[key] = ideal == Int.max ? Int.max : ideal - range.location
                flow.relayoutPending[key] = range.location
                DispatchQueue.main.async { [weak self] in self?.relayoutPendingSections() }
            }
        }
        return changed
    }

    /// Lays out the sections again whose columns came out unequal (right after the pass that found it).
    func relayoutPendingSections() {
        let pending = flow.relayoutPending
        flow.relayoutPending = [:]
        guard let storage = textStorage, let layoutManager else { return }
        for start in pending.values {
            guard let current = containerRange(.writerColumns, at: min(start, max(0, storage.length - 1))) else { continue }
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: current.location, length: storage.length - current.location), actualCharacterRange: nil)
        }
        needsDisplay = true
    }

    /// Lays everything out, with sections balanced (for tests and the page count).
    func settleLayout() {
        guard let layoutManager, let textContainer else { return }
        for _ in 0..<4 {
            layoutManager.ensureLayout(for: textContainer)
            guard !flow.relayoutPending.isEmpty else { break }
            relayoutPendingSections()
        }
    }

    /// Where a column break in the section sends the text to the second column.
    private func forcedSplit(in range: NSRange) -> Int? {
        guard let storage = textStorage else { return nil }
        var split: Int?
        storage.enumerateAttribute(.attachment, in: range) { value, run, stop in
            if value is WriterColumnBreakAttachment {
                split = NSMaxRange((storage.string as NSString).paragraphRange(for: run))
                stop.pointee = true
            }
        }
        return split
    }

    // MARK: Clicks

    /// Where a click puts the caret: in the line whose box holds the point (see `lineFragment(at:)`), by the glyphs'
    /// middles.
    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard slideLayout == nil, let line = lineFragment(at: inContainer), let layoutManager, let container = textContainer,
              let storage = textStorage else { return super.characterIndexForInsertion(at: point) }
        let characters = layoutManager.characterRange(forGlyphRange: line.glyphs, actualGlyphRange: nil)
        let string = storage.string as NSString
        var end = NSMaxRange(characters)
        // Not behind the line's own newline.
        while end > characters.location, [0x0A, 0x2028].contains(string.character(at: end - 1)) { end -= 1 }
        var glyph = line.glyphs.location
        while glyph < NSMaxRange(line.glyphs) {
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if inContainer.x < rect.midX { return min(layoutManager.characterIndexForGlyph(at: glyph), end) }
            glyph += 1
        }
        return end
    }

    /// Whether lines may stand side by side: a section in columns or a box with text flowing around it was laid out.
    var hasFlowLayout: Bool {
        !flow.lines.isEmpty || flow.floats.values.contains { $0.box != nil }
    }

    /// The line whose box holds a point (in the container), when lines stand side by side; TextKit's own search goes by
    /// height alone and finds the wrong one of two lines at the same height.
    func lineFragment(at point: NSPoint) -> (rect: NSRect, glyphs: NSRange)? {
        guard hasFlowLayout, let layoutManager, let container = textContainer else { return nil }
        let wide = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: NSRect(x: 0, y: point.y - 1500, width: container.size.width, height: 3000),
                                            in: container)
        var hit: (NSRect, NSRange)?
        layoutManager.enumerateLineFragments(forGlyphRange: wide) { rect, _, _, glyphs, stop in
            if rect.contains(point) {
                hit = (rect, glyphs)
                stop.pointee = true
            }
        }
        return hit
    }

    // MARK: Drawing boxes and sections

    /// The boxes' backgrounds, frames and titles, and the marks of sections in columns; drawn before the text.
    func drawBoxes(in characters: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0, slideLayout == nil else { return }
        // Boxes that begin above the drawn part still draw their part.
        var start = characters.location
        if start > 0, let range = containerRange(.writerBox, at: start) { start = range.location }
        let scan = NSRange(location: start, length: min(storage.length, NSMaxRange(characters)) - start)
        guard scan.length > 0 else { return }
        storage.enumerateAttribute(.writerBox, in: scan) { value, run, _ in
            guard let box = value as? WriterBox, let range = containerRange(.writerBox, at: run.location), range.location == run.location || run.location == scan.location else { return }
            drawBox(box, range: range, layoutManager: layoutManager, origin: origin)
        }
        var sectionStart = characters.location
        if sectionStart > 0, let range = containerRange(.writerColumns, at: sectionStart) { sectionStart = range.location }
        let sectionScan = NSRange(location: sectionStart, length: min(storage.length, NSMaxRange(characters)) - sectionStart)
        storage.enumerateAttribute(.writerColumns, in: sectionScan) { value, run, _ in
            guard let section = value as? WriterColumnSection, let range = containerRange(.writerColumns, at: run.location),
                  range.location == run.location || run.location == sectionScan.location else { return }
            drawSection(section, range: range, layoutManager: layoutManager, origin: origin)
        }
    }

    private func drawBox(_ box: WriterBox, range: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        // One frame per column the box's lines stand in.
        var frames: [CGRect] = []
        var lastX: CGFloat?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            if let lastX, abs(lastX - fragment.minX) < 1, var current = frames.last {
                current = current.union(fragment)
                frames[frames.count - 1] = current
            } else {
                frames.append(fragment)
            }
            lastX = fragment.minX
        }
        guard !frames.isEmpty else { return }
        let style = box.style
        let color = WriterColors.display(style.printColor, onDark: !palette.isLight) ?? palette.accent
        for (index, fragment) in frames.enumerated() {
            var frame = CGRect(x: fragment.minX - WriterBoxStyle.paddingLeft, y: fragment.minY,
                               width: fragment.width + WriterBoxStyle.paddingLeft + WriterBoxStyle.paddingRight, height: fragment.height)
            if index == 0 { frame.origin.y += WriterBoxStyle.marginTop; frame.size.height -= WriterBoxStyle.marginTop }
            if index == frames.count - 1 { frame.size.height -= WriterBoxStyle.marginBottom }
            frame = frame.offsetBy(dx: origin.x, dy: origin.y)
            let shape = NSBezierPath(roundedRect: frame, xRadius: style.frame == .bar ? 3 : 8, yRadius: style.frame == .bar ? 3 : 8)
            switch style.frame {
            case .bar:
                color.withAlphaComponent(palette.isLight ? 0.07 : 0.1).setFill()
                shape.fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: frame.minX, y: frame.minY, width: 4, height: frame.height), xRadius: 2, yRadius: 2).fill()
            case .outline:
                color.withAlphaComponent(palette.isLight ? 0.04 : 0.06).setFill()
                shape.fill()
                color.withAlphaComponent(0.8).setStroke()
                shape.lineWidth = 1.2
                shape.stroke()
            case .filled:
                color.withAlphaComponent(palette.isLight ? 0.15 : 0.2).setFill()
                shape.fill()
            }
            if index == 0, style.hasTitle {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: WriterStyler.font(family, size: max(11, WriterStyler.bodySize(family) * 0.72), weight: .bold),
                    .foregroundColor: color,
                    .kern: 0.8,
                ]
                (style.effectiveTitle.uppercased() as NSString).draw(
                    at: NSPoint(x: frame.minX + WriterBoxStyle.paddingLeft, y: frame.minY + WriterBoxStyle.paddingTop - 3), withAttributes: attributes
                )
            }
        }
    }

    private func drawSection(_ section: WriterColumnSection, range: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) {
        guard let container = textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var bounds = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in bounds = bounds.union(fragment) }
        guard !bounds.isNull else { return }
        let geometry = columnGeometry(section, width: container.size.width)
        let frame = bounds.offsetBy(dx: origin.x, dy: origin.y)
        // In the left margin: a bracket over the section and how many columns it has.
        palette.tertiaryText.withAlphaComponent(0.35).setStroke()
        let bracket = NSBezierPath()
        let x = origin.x - 12
        bracket.move(to: NSPoint(x: x + 4, y: frame.minY + 2))
        bracket.line(to: NSPoint(x: x, y: frame.minY + 2))
        bracket.line(to: NSPoint(x: x, y: frame.maxY - 2))
        bracket.line(to: NSPoint(x: x + 4, y: frame.maxY - 2))
        bracket.lineWidth = 1
        bracket.stroke()
        let label = "\(section.style.count) Spalten" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: palette.tertiaryText]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: x - 6 - size.width, y: frame.minY), withAttributes: attributes)
        // The line between the columns, if the section has one.
        if section.style.rule {
            palette.rule.setFill()
            let between = origin.x + geometry.columnWidth + geometry.gap / 2
            NSRect(x: between - 0.5, y: frame.minY + 4, width: 1, height: frame.height - 8).fill()
        }
    }
}
