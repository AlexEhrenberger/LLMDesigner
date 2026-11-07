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

    /// Splits the bullet points of a slide that runs over: as many as fit stay, the rest go to slides of their own
    /// with the same title and "(Forts.)". A slide without points, or whose first point alone overflows, stays.
    static func split(_ slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont) -> [PresentationSlide] {
        let lines = slide.markdown.components(separatedBy: "\n")
        guard let heading = lines.first(where: { $0.hasPrefix("#") }) else { return [slide] }
        let points = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        guard points.count > 1, !report(slide, in: deck, family: family).fits else { return [slide] }
        var result: [PresentationSlide] = []
        var remaining = points[...]
        var current = slide
        var title = heading
        while !remaining.isEmpty {
            var take = remaining.count
            while take > 1 {
                current.markdown = ([title, ""] + remaining.prefix(take)).joined(separator: "\n")
                if report(current, in: deck, family: family).fits { break }
                take -= 1
            }
            current.markdown = ([title, ""] + remaining.prefix(take)).joined(separator: "\n")
            result.append(current)
            remaining = remaining.dropFirst(take)
            if !remaining.isEmpty {
                title = heading.hasSuffix("(Forts.)") ? heading : heading + " (Forts.)"
                current = PresentationSlide(role: .content, markdown: "")
            }
        }
        return result
    }
}
