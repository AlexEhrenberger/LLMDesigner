import Foundation

/// What a slide is for. It decides the layout (a title in the middle, a chapter opening, content from the top)
/// and which of the presentation's backgrounds the slide gets.
enum SlideRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case title = "titel"
    case chapter = "kapitel"
    case content = "folie"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Titelfolie"
        case .chapter: "Kapitelfolie"
        case .content: "Folie"
        }
    }

    /// For "Alle Titelfolien" and the like.
    var plural: String {
        switch self {
        case .title: "Titelfolien"
        case .chapter: "Kapitelfolien"
        case .content: "Inhaltsfolien"
        }
    }

    var symbol: String {
        switch self {
        case .title: "star.square"
        case .chapter: "bookmark.square"
        case .content: "rectangle.on.rectangle"
        }
    }

    /// The text an empty slide shows where its first line goes.
    var placeholder: String {
        switch self {
        case .title: "Titel der Präsentation"
        case .chapter: "Kapitel"
        case .content: "Folientitel"
        }
    }

    /// The first line of an empty slide is a heading of this kind.
    var firstBlock: WriterBlock {
        switch self {
        case .title, .chapter: .chapter
        case .content: .heading1
        }
    }
}

/// Light text on a dark background, or dark text on a light one.
enum SlideTone: String, Codable, Sendable {
    case light, dark
}

/// A slide's background: one of the designs (CSS), a colour, a gradient or a picture (made with Draw Things or
/// chosen from disk). Stored leniently: only the fields of its kind are written.
struct SlideBackground: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case design, color, gradient, image
    }

    var kind: Kind
    /// `design`: the design's id (its file name without `.css`).
    var design: String?
    /// `color`: one colour; `gradient`: two or more, as `#RRGGBB`.
    var colors: [String]?
    /// `gradient`: the direction in degrees as in CSS (0 = upwards, 90 = to the right).
    var angle: Double?
    /// `gradient`: from the middle outwards instead of along a line.
    var radial: Bool?
    /// `image`: the picture's place, as in the documents (`Bilder/gen-….png`).
    var image: String?
    /// `image`: how much the picture is darkened (or lightened, for dark text) so the text stays readable, 0…0.8.
    var dim: Double?
    /// The text's colour when it shouldn't follow from the background.
    var tone: SlideTone?

    static func design(_ id: String) -> SlideBackground { SlideBackground(kind: .design, design: id) }
    static func color(_ hex: String) -> SlideBackground { SlideBackground(kind: .color, colors: [hex]) }

    static func gradient(_ colors: [String], angle: Double = 135, radial: Bool = false) -> SlideBackground {
        SlideBackground(kind: .gradient, colors: colors, angle: angle, radial: radial ? true : nil)
    }

    static func image(_ source: String, dim: Double = 0.25) -> SlideBackground {
        SlideBackground(kind: .image, image: source, dim: dim)
    }

    static let standard = SlideBackground.design(SlideDesign.defaultID)

    /// The colours of a colour or gradient background, as numbers.
    var hexColors: [UInt32] {
        (colors ?? []).compactMap { SlideBackground.hex($0) }
    }

    static func hex(_ string: String) -> UInt32? {
        let digits = string.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    static func string(_ hex: UInt32) -> String {
        String(format: "#%06X", hex & 0xFFFFFF)
    }

    /// Relative luminance after WCAG, 0 (black) to 1 (white).
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// The text colour for a background of this luminance: whichever contrasts more.
    static func tone(forLuminance luminance: Double) -> SlideTone {
        // Contrast with white is (1.05) / (L + 0.05), with near-black (L + 0.05) / 0.05; equal at about 0.18.
        luminance > 0.2 ? .dark : .light
    }
}

/// The background a presentation gives each kind of slide; a slide can have its own instead.
struct RoleBackgrounds: Codable, Hashable, Sendable {
    var titel: SlideBackground?
    var kapitel: SlideBackground?
    var folie: SlideBackground?

    subscript(role: SlideRole) -> SlideBackground {
        get {
            switch role {
            case .title: titel ?? folie ?? .standard
            case .chapter: kapitel ?? folie ?? .standard
            case .content: folie ?? .standard
            }
        }
        set {
            switch role {
            case .title: titel = newValue
            case .chapter: kapitel = newValue
            case .content: folie = newValue
            }
        }
    }

    static func all(_ background: SlideBackground) -> RoleBackgrounds {
        RoleBackgrounds(titel: background, kapitel: background, folie: background)
    }
}

/// A picture placed freely on a slide, outside the text: it can be moved and resized with the mouse. Its frame is
/// stored in fractions of the slide, so it keeps its place at every size (editor, slide list, presentation, PDF).
struct SlideImage: Identifiable, Hashable, Codable, Sendable {
    /// How the picture and the slide's text share the slide.
    enum Placement: String, Codable, CaseIterable, Sendable {
        /// The text flows around the picture.
        case wrap = "umfliessen"
        /// Over the text, which runs on underneath.
        case front = "vorne"
        /// Under the text, like a part of the background.
        case behind = "hinten"

        var label: String {
            switch self {
            case .wrap: "Text umfließt das Bild"
            case .front: "Vor dem Text"
            case .behind: "Hinter dem Text"
            }
        }

        var symbol: String {
            switch self {
            case .wrap: "text.wrap"
            case .front: "square.2.layers.3d.top.filled"
            case .behind: "square.2.layers.3d.bottom.filled"
            }
        }
    }

    var id = UUID()
    /// The picture's place, as in the documents (`Bilder/….png`).
    var source: String
    var caption = ""
    /// The frame, top left origin, in fractions of the slide's width and height.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var placement: Placement = .wrap
    /// Made with Draw Things; until its file exists, a placeholder shows its progress.
    var generated = false

    /// The smallest side, in fractions of the slide's width.
    static let minimumWidth = 0.04

    init(source: String, caption: String = "", frame: CGRect, placement: Placement = .wrap, generated: Bool = false) {
        self.source = source
        self.caption = caption
        x = 0
        y = 0
        width = 0
        height = 0
        self.placement = placement
        self.generated = generated
        self.frame = frame
    }

    /// The frame on the slide canvas (720 × 405 points, see `WriterTextView.SlideLayout`).
    var frame: CGRect {
        get {
            let canvas = SlideImage.canvas
            return CGRect(x: x * canvas.width, y: y * canvas.height, width: width * canvas.width, height: height * canvas.height)
        }
        set {
            let canvas = SlideImage.canvas
            x = Double(newValue.minX / canvas.width)
            y = Double(newValue.minY / canvas.height)
            width = Double(newValue.width / canvas.width)
            height = Double(newValue.height / canvas.height)
        }
    }

    static let canvas = CGSize(width: 720, height: 405)

    /// Where a new picture of this aspect (width / height) goes: centred on `center` (a point on the canvas), else
    /// at the right of the slide, below the title. `offset` moves several pictures apart.
    static func defaultFrame(aspect: Double, center: CGPoint? = nil, offset: Int = 0) -> CGRect {
        let aspect = max(0.2, min(5, aspect.isFinite && aspect > 0 ? aspect : 1.5))
        var width = canvas.width * 0.4
        var height = width / aspect
        let maxHeight = canvas.height * 0.62
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        let shift = CGFloat(offset) * 18
        let middle = center.map { CGPoint(x: $0.x + shift, y: $0.y + shift) }
            ?? CGPoint(x: canvas.width - 40 - width / 2 - shift, y: max(84 + height / 2, canvas.height * 0.56) + shift)
        var frame = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
        frame.origin.x = min(max(0, frame.minX), canvas.width - width)
        frame.origin.y = min(max(0, frame.minY), canvas.height - height)
        return frame
    }

    private enum CodingKeys: String, CodingKey {
        case id, source = "quelle", caption = "text", x, y, width = "b", height = "h", placement = "lage", generated = "generiert"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        source = try container.decode(String.self, forKey: .source)
        caption = (try? container.decodeIfPresent(String.self, forKey: .caption)) ?? ""
        x = (try? container.decodeIfPresent(Double.self, forKey: .x)) ?? 0.5
        y = (try? container.decodeIfPresent(Double.self, forKey: .y)) ?? 0.25
        width = max(Self.minimumWidth, (try? container.decodeIfPresent(Double.self, forKey: .width)) ?? 0.4)
        height = max(Self.minimumWidth, (try? container.decodeIfPresent(Double.self, forKey: .height)) ?? 0.4)
        placement = (try? container.decodeIfPresent(Placement.self, forKey: .placement)) ?? .wrap
        generated = (try? container.decodeIfPresent(Bool.self, forKey: .generated)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        if !caption.isEmpty { try container.encode(caption, forKey: .caption) }
        // Four digits are a tenth of a point on the canvas.
        func rounded(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
        try container.encode(rounded(x), forKey: .x)
        try container.encode(rounded(y), forKey: .y)
        try container.encode(rounded(width), forKey: .width)
        try container.encode(rounded(height), forKey: .height)
        if placement != .wrap { try container.encode(placement, forKey: .placement) }
        if generated { try container.encode(true, forKey: .generated) }
    }
}

/// One slide: its text (Writer Studio's Markdown), what the presenter says to it, its role and maybe a background
/// of its own.
struct PresentationSlide: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var role: SlideRole = .content
    var markdown = ""
    /// The "Moderatorenkarte": the spoken text for this slide.
    var notes = ""
    /// nil: the presentation's background for the slide's role.
    var background: SlideBackground?
    /// Pictures placed freely on the slide, the last one on top.
    var images: [SlideImage] = []

    /// The first line of the slide, for the slide list and the contents.
    var title: String {
        WriterDocument.makeTitle(from: markdown)
    }

    var isEmpty: Bool {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && images.isEmpty
    }
}

/// The slides of a presentation, with its backgrounds. A presentation is a document of its own kind
/// (`WriterDocument.deck`): it lives in the sidebar, in folders and on disk like the others.
struct PresentationDeck: Hashable, Sendable {
    var slides: [PresentationSlide]
    var backgrounds = RoleBackgrounds.all(.standard)

    /// A new presentation starts with its title slide.
    static func new() -> PresentationDeck {
        PresentationDeck(slides: [PresentationSlide(role: .title)])
    }

    func index(of id: PresentationSlide.ID) -> Int? {
        slides.firstIndex { $0.id == id }
    }

    func slide(_ id: PresentationSlide.ID) -> PresentationSlide? {
        slides.first { $0.id == id }
    }

    func background(of slide: PresentationSlide) -> SlideBackground {
        slide.background ?? backgrounds[slide.role]
    }

    /// The chapter a slide belongs to: the last chapter slide before it (or itself).
    func chapter(of id: PresentationSlide.ID) -> PresentationSlide? {
        guard let index = index(of: id) else { return nil }
        return slides[...index].last { $0.role == .chapter }
    }

    // MARK: Text for the document features

    /// The slides one after the other, as one Markdown text. Search, the word count, citations, the content
    /// analysis and the automatic title work on it. A line between slides keeps their paragraphs and lists apart.
    var plainMarkdown: String {
        slides.map { $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n" + Self.separator + "\n\n")
    }

    static let separator = "---"

    /// The slide with this block of `plainMarkdown` (as `MarkdownParser` counts blocks), and the block's index within
    /// the slide.
    func slideIndex(forBlock block: Int) -> (slide: Int, block: Int)? {
        var start = 0
        for (index, slide) in slides.enumerated() {
            let text = slide.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = text.isEmpty ? 0 : MarkdownParser.parse(WriterBookmark.strip(text)).count
            if block < start + count { return (index, block - start) }
            // The separator line after the slide is a block of its own.
            start += count + 1
        }
        return nil
    }

    /// The slide that holds a passage, found by its text key (see `DocumentOutlineBuilder.searchKey`); the block
    /// number is the fallback when the text changed since.
    func slideIndex(for anchor: DocumentAnchor) -> (slide: Int, block: Int)? {
        if !anchor.key.isEmpty {
            for (index, slide) in slides.enumerated() {
                let blocks = DocumentOutlineBuilder.blocks(of: slide.markdown)
                if let found = blocks.first(where: { $0.key.hasPrefix(anchor.key) || anchor.key.hasPrefix($0.key) && !$0.key.isEmpty }) {
                    return (index, found.index)
                }
            }
        }
        return slideIndex(forBlock: anchor.block)
    }

    /// The slide that has this bookmark.
    func slideIndex(ofBookmark id: String) -> Int? {
        slides.firstIndex { $0.markdown.contains("id=\"\(id)\"") }
    }

    // MARK: Storing

    /// Each slide begins with a comment line that carries its role and background; the speaker notes follow its text
    /// in a comment of their own. Other Markdown programs show the slides' text and hide the rest.
    ///
    ///     <!-- folie {"id":"…","rolle":"titel","bilder":[{"quelle":"Bilder/….png","x":0.5,…}]} -->
    ///
    ///     # Titel {.chapter}
    ///
    ///     <!-- moderation
    ///     Was der Vortragende sagt.
    ///     -->
    var serialized: String {
        slides.map { slide in
            var meta: [String: Any] = ["id": slide.id.uuidString, "rolle": slide.role.rawValue]
            if let background = slide.background, let object = Self.jsonObject(background) { meta["hintergrund"] = object }
            if !slide.images.isEmpty, let object = Self.jsonObject(slide.images) { meta["bilder"] = object }
            var parts = ["<!-- folie \(Self.jsonLine(meta)) -->"]
            let text = slide.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                // "-->" would end the comment early.
                parts.append("<!-- moderation\n" + notes.replacingOccurrences(of: "-->", with: "-- >") + "\n-->")
            }
            return parts.joined(separator: "\n\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// Reads the slides back; text before the first slide marker (a Markdown file written elsewhere) becomes the
    /// first slide.
    static func parse(_ body: String) -> PresentationDeck {
        var slides: [PresentationSlide] = []
        var current: PresentationSlide?
        var text: [String] = []
        var notes: [String]?
        var inNotes = false

        func close() {
            let markdown = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if var slide = current {
                slide.markdown = markdown
                slide.notes = (notes ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                slides.append(slide)
            } else if !markdown.isEmpty {
                slides.append(PresentationSlide(role: .title, markdown: markdown))
            }
            text = []
            notes = nil
        }

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inNotes {
                if trimmed == "-->" { inNotes = false } else { notes?.append(line) }
                continue
            }
            if trimmed.hasPrefix("<!-- folie"), trimmed.hasSuffix("-->") {
                close()
                let json = trimmed.dropFirst("<!-- folie".count).dropLast(3).trimmingCharacters(in: .whitespaces)
                current = slide(from: json)
                continue
            }
            if trimmed.hasPrefix("<!-- moderation") {
                inNotes = true
                notes = notes ?? []
                // Notes on the same line as the marker.
                let rest = trimmed.dropFirst("<!-- moderation".count).trimmingCharacters(in: .whitespaces)
                if rest.hasSuffix("-->") {
                    inNotes = false
                    let inline = rest.dropLast(3).trimmingCharacters(in: .whitespaces)
                    if !inline.isEmpty { notes?.append(inline) }
                } else if !rest.isEmpty {
                    notes?.append(rest)
                }
                continue
            }
            text.append(line)
        }
        close()
        return PresentationDeck(slides: slides.isEmpty ? [PresentationSlide(role: .title)] : slides)
    }

    private static func slide(from json: String) -> PresentationSlide {
        var slide = PresentationSlide()
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return slide }
        if let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) { slide.id = id }
        if let role = (object["rolle"] as? String).flatMap(SlideRole.init(rawValue:)) { slide.role = role }
        if let background = object["hintergrund"], let data = try? JSONSerialization.data(withJSONObject: background) {
            slide.background = try? JSONDecoder().decode(SlideBackground.self, from: data)
        }
        if let images = object["bilder"], let data = try? JSONSerialization.data(withJSONObject: images) {
            slide.images = (try? JSONDecoder().decode([SlideImage].self, from: data)) ?? []
        }
        return slide
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// One line of JSON with sorted keys, so files only change where something changed.
    static func jsonLine(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The presentation's backgrounds for the front matter.
    var backgroundsLine: String {
        Self.jsonObject(backgrounds).map(Self.jsonLine) ?? "{}"
    }

    static func backgrounds(from line: String) -> RoleBackgrounds? {
        try? JSONDecoder().decode(RoleBackgrounds.self, from: Data(line.utf8))
    }
}
