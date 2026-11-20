import AppKit

/// Whether a slide's text fits on the slide, measured the way the editor and the PDF lay it out (Writer Studio's
/// text view on the 720 × 405 canvas). Agents write slides blind; this tells them right in the result when the text
/// runs over, so they can shorten it before anyone sees it.
struct SlideFitReport: Encodable, Sendable, Equatable {
    var fits: Bool
    /// How much longer than the room the text is, in percent of the room.
    var overflowPercent: Int?
    /// Text fields that run past the bottom of the slide.
    var overflowingFields: [String]?
    /// What to do about it, for the model reading the result.
    var hint: String?
}

@MainActor
enum SlideFit {
    /// The height the slide's text needs and the height it has.
    static func measure(text markdown: String, layout: WriterTextView.SlideLayout, family: WriterFont, palette: WriterPalette) -> (needed: CGFloat, room: CGFloat) {
        let view = WriterTextView.make()
        view.isEditable = false
        view.isSelectable = false
        view.isContinuousSpellCheckingEnabled = false
        view.slideLayout = layout
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.frame = NSRect(origin: .zero, size: layout.size)
        var needed: CGFloat = 0
        view.onSlideTextHeight = { needed = $0 }
        view.load(markdown: markdown, family: family, palette: palette)
        view.setFrameSize(layout.size)
        if let layoutManager = view.layoutManager, let container = view.textContainer { layoutManager.ensureLayout(for: container) }
        view.updateSlideCentering()
        return (needed, layout.size.height)
    }

    static func report(_ slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont) -> SlideFitReport {
        let background = deck.background(of: slide)
        let palette = SlideLook.palette(background, role: slide.role)
        let main = measure(text: slide.markdown, layout: WriterTextView.SlideLayout(slide: slide), family: family, palette: palette)
        let over = main.needed - main.room
        // A text field grows downwards with its text; it runs over when it would leave the slide.
        let fieldPalette = SlideLook.fieldPalette(background, role: slide.role)
        let canvas = WriterTextView.SlideLayout.canvas
        let fields = slide.images.filter(\.isText).filter { field in
            let layout = WriterTextView.SlideLayout(field: field)
            let needed = measure(text: field.text ?? "", layout: layout, family: family, palette: fieldPalette).needed
            return field.frame.minY + max(needed, field.frame.height) > canvas.height + 1
        }.map(\.id.uuidString)
        guard over > 1 || !fields.isEmpty else { return SlideFitReport(fits: true) }
        var report = SlideFitReport(fits: false)
        var advice: [String] = []
        if over > 1 {
            let percent = Int((over / max(1, main.room) * 100).rounded(.up))
            report.overflowPercent = percent
            advice.append("Der Folientext ist etwa \(percent) % zu lang und läuft über den unteren Rand. Kürze ihn (höchstens 5–6 Punkte zu je einer Zeile), verteile ihn auf zwei Folien oder schiebe Einzelheiten in die Moderatorenkarte.")
        }
        if !fields.isEmpty {
            report.overflowingFields = fields
            advice.append("Ein Textfeld ragt über den unteren Folienrand: Text kürzen oder das Feld mit presenter.field.move höher setzen.")
        }
        report.hint = advice.joined(separator: " ")
        return report
    }

    /// The report for a slide of a presentation in the library.
    static func report(slideID: PresentationSlide.ID, in document: WriterDocument?) -> SlideFitReport? {
        guard let document, let deck = document.deck, let slide = deck.slide(slideID) else { return nil }
        return report(slide, in: deck, family: document.font)
    }

    /// Whether the slide's own text fits (its text fields don't count: splitting can't help them).
    static func textFits(_ slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont) -> Bool {
        let palette = SlideLook.palette(deck.background(of: slide), role: slide.role)
        let size = measure(text: slide.markdown, layout: WriterTextView.SlideLayout(slide: slide), family: family, palette: palette)
        return size.needed - size.room <= 1
    }

    /// Splits the bullet points of a slide that runs over: as many as fit stay, the rest go to slides of their own
    /// with the same title and "(Forts.)". Only the points move: what stands before the list stays on the first slide,
    /// what follows it goes to the last, so nothing of the slide is lost. A slide without a heading or points, or
    /// whose first point alone overflows, stays as it is.
    static func split(_ slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont) -> [PresentationSlide] {
        guard let parts = SlidePoints(slide.markdown), parts.points.count > 1,
              let heading = parts.head.first(where: { $0.hasPrefix("#") }),
              !textFits(slide, in: deck, family: family) else { return [slide] }
        let title = continuationTitle(heading)
        var result: [PresentationSlide] = []
        var remaining = parts.points[...]
        var current = slide
        while !remaining.isEmpty {
            let head = result.isEmpty ? parts.head : [title]
            func text(_ count: Int) -> String {
                SlidePoints.compose(head: head, points: remaining.prefix(count).flatMap { $0 }, tail: count == remaining.count ? parts.tail : [])
            }
            var take = remaining.count
            while take > 0 {
                current.markdown = text(take)
                if textFits(current, in: deck, family: family) { break }
                take -= 1
            }
            if take == 0 {
                guard !result.isEmpty else { return [slide] }
                // A point that fills a slide by itself still gets one; it runs over there, but it is kept.
                take = 1
            }
            current.markdown = text(take)
            result.append(current)
            remaining = remaining.dropFirst(take)
            if !remaining.isEmpty {
                // The continuation looks like the slide it continues.
                current = PresentationSlide(role: .content, markdown: "")
                current.background = slide.background
                current.textArea = slide.textArea
            }
        }
        return result
    }

    /// The heading of a continuation: "(Forts.)" before its attributes, without the bookmarks and ids that belong
    /// to the first slide only.
    static func continuationTitle(_ heading: String) -> String {
        var line = heading.trimmingCharacters(in: .whitespaces)
        if line.contains("id=\"") { line = WriterBookmark.strip(line) }
        let hashes = String(line.prefix { $0 == "#" })
        let rest = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        let text = WriterMarkdown.headingAttributes(rest).text
        var attributes = String(rest.dropFirst(text.count)).trimmingCharacters(in: .whitespaces)
        if attributes.hasPrefix("{"), attributes.hasSuffix("}") {
            let kept = attributes.dropFirst().dropLast().split(separator: " ").filter { !$0.hasPrefix("#") }
            attributes = kept.isEmpty ? "" : "{" + kept.joined(separator: " ") + "}"
        }
        let title = text.hasSuffix("(Forts.)") ? text : text + " (Forts.)"
        return hashes + " " + title + (attributes.isEmpty ? "" : " " + attributes)
    }
}

/// A slide's text as splitting sees it: the lines before its first list, the list's top-level points (each with its
/// sub-points and indented lines), and the lines after the list.
struct SlidePoints: Equatable {
    var head: [String]
    var points: [[String]]
    var tail: [String]

    /// nil: the text has no list.
    init?(_ markdown: String) {
        let lines = markdown.components(separatedBy: "\n")
        var inFence = false
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence, Self.isPoint(line) { start = index; break }
        }
        guard let start else { return nil }
        var points: [[String]] = []
        var index = start
        var end = lines.count
        while index < lines.count {
            let line = lines[index]
            if Self.isPoint(line) {
                points.append([line])
                index += 1
            } else if Self.isIndented(line) {
                points[points.count - 1].append(line)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank lines belong to the list when it goes on after them (a loose list).
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count, Self.isPoint(lines[next]) || Self.isIndented(lines[next]) else { end = index; break }
                points[points.count - 1] += lines[index..<next]
                index = next
            } else {
                end = index
                break
            }
        }
        head = Array(lines[..<start])
        self.points = points
        tail = Array(lines[end...])
    }

    /// A top-level list item: "- ", "* ", "+ " or "1. ", "1) " at the start of the line.
    static func isPoint(_ line: String) -> Bool {
        line.range(of: #"^(?:[-*+]|\d{1,3}[.)])[ \t]"#, options: .regularExpression) != nil
    }

    private static func isIndented(_ line: String) -> Bool {
        (line.hasPrefix(" ") || line.hasPrefix("\t")) && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The parts as one text again, a blank line between the head, the list and the tail.
    static func compose(head: [String], points: [String], tail: [String]) -> String {
        func trimmed(_ lines: [String]) -> [String] {
            let isBlank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = lines.firstIndex(where: { !isBlank($0) }), let last = lines.lastIndex(where: { !isBlank($0) }) else { return [] }
            return Array(lines[first...last])
        }
        return [trimmed(head), trimmed(points), trimmed(tail)].filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }
}
