import SwiftUI
import WebKit

/// How a slide's text looks over its background: light or dark text, the design's accent, centred on a title slide.
@MainActor
enum SlideLook {
    static func tone(of background: SlideBackground, role: SlideRole) -> SlideTone {
        if let tone = background.tone { return tone }
        switch background.kind {
        case .design:
            return design(of: background)?.tone(for: role) ?? .light
        case .color, .gradient:
            let colors = background.hexColors
            guard !colors.isEmpty else { return .light }
            let luminance = colors.map(SlideBackground.luminance).reduce(0, +) / Double(colors.count)
            return SlideBackground.tone(forLuminance: luminance)
        case .image:
            return .light
        }
    }

    /// The design of a design background; a design that is gone falls back to the default one.
    static func design(of background: SlideBackground) -> SlideDesign? {
        let library = SlideDesignLibrary.shared
        return library.design(background.design) ?? library.design(SlideDesign.defaultID) ?? library.all.first
    }

    static func palette(_ background: SlideBackground, role: SlideRole) -> WriterPalette {
        let accent = background.kind == .design ? design(of: background)?.accent : nil
        return .slide(tone: tone(of: background, role: role), accent: accent, alignment: role == .title ? .center : .natural)
    }

    static func palette(of slide: PresentationSlide, in deck: PresentationDeck) -> WriterPalette {
        palette(deck.background(of: slide), role: slide.role)
    }

    /// A text field's text: the slide's colours, but set from the left also on a title slide.
    static func fieldPalette(_ background: SlideBackground, role: SlideRole) -> WriterPalette {
        let accent = background.kind == .design ? design(of: background)?.accent : nil
        return .slide(tone: tone(of: background, role: role), accent: accent, alignment: .natural)
    }

    static func fieldLook(of slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont) -> SlideTextLook {
        SlideTextLook(family: family, palette: fieldPalette(deck.background(of: slide), role: slide.role))
    }
}

/// How the text fields of a slide are set: handed down to the layers that draw them.
struct SlideTextLook: Equatable {
    var family: WriterFont
    var palette: WriterPalette
}

private struct SlideTextLookKey: EnvironmentKey {
    static let defaultValue: SlideTextLook? = nil
}

extension EnvironmentValues {
    var slideTextLook: SlideTextLook? {
        get { self[SlideTextLookKey.self] }
        set { self[SlideTextLookKey.self] = newValue }
    }
}

// MARK: Background

/// A slide's background at any size: a design (as a picture, or live with its animations), a colour, a gradient or
/// a picture with its darkening.
struct SlideBackgroundView: View {
    let background: SlideBackground
    let role: SlideRole
    /// In the presentation: designs move.
    var live = false

    var body: some View {
        switch background.kind {
        case .color:
            Color(hex: background.hexColors.first ?? 0x202024)
        case .gradient:
            gradient
        case .design:
            if let design = SlideLook.design(of: background) {
                DesignBackground(design: design, role: role, live: live)
            } else {
                Color(hex: 0x101014)
            }
        case .image:
            ImageBackground(background: background, role: role)
        }
    }

    @ViewBuilder
    private var gradient: some View {
        let colors = background.hexColors.map { Color(hex: $0) }
        let stops = colors.isEmpty ? [Color(hex: 0x202024), Color(hex: 0x101014)] : colors.count == 1 ? colors + colors : colors
        if background.radial == true {
            GeometryReader { geometry in
                RadialGradient(colors: stops, center: .center, startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.62)
            }
        } else {
            let angle = (background.angle ?? 135) * .pi / 180
            let dx = sin(angle) / 2
            let dy = -cos(angle) / 2
            LinearGradient(colors: stops, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
        }
    }
}

/// A design as its still picture; in the presentation the live page fades in over it once it is drawn.
private struct DesignBackground: View {
    let design: SlideDesign
    let role: SlideRole
    let live: Bool
    @State private var isLoaded = false

    var body: some View {
        ZStack {
            if let image = SlideDesignRenderer.shared.image(design, role: role, width: live ? 1920 : 960) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color(hex: 0x111116)
            }
            if live {
                LiveDesignView(html: design.html(role: role, live: true)) { isLoaded = true }
                    .opacity(isLoaded ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: isLoaded)
            }
        }
        .onChange(of: design.id + role.rawValue) { _, _ in isLoaded = false }
    }
}

/// The design's page in a web view, with its animations running.
private struct LiveDesignView: NSViewRepresentable {
    let html: String
    let onLoad: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = PassthroughWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.onLoad = onLoad
        context.coordinator.html = html
        view.loadOfflineHTML(html)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoad = onLoad
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadOfflineHTML(html)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoad: (() -> Void)?
        var html = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The first frame with its filters needs a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.onLoad?() }
        }
    }
}

/// Clicks go through to the slide (they turn it in the presentation).
private final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A picture as background, darkened (or lightened) for the text; while Draw Things makes it, its progress.
private struct ImageBackground: View {
    @Environment(AppModel.self) private var app
    let background: SlideBackground
    let role: SlideRole

    var body: some View {
        let source = background.image ?? ""
        let phase = app.imageGeneration.phase(for: source)
        let tone = SlideLook.tone(of: background, role: role)
        ZStack {
            if phase == nil, let image = SlideImageCache.image(source) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                (tone == .light ? Color.black : Color.white).opacity(background.dim ?? 0)
            } else {
                placeholder(phase: phase, tone: tone)
            }
        }
    }

    private func placeholder(phase: ImageGenerationCenter.Phase?, tone: SlideTone) -> some View {
        let dark = tone == .light
        return ZStack {
            LinearGradient(
                colors: dark ? [Color(hex: 0x1C1A2E), Color(hex: 0x0E0D18)] : [Color(hex: 0xF4F1EA), Color(hex: 0xE5E0D6)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            GeometryReader { geometry in
                let size = max(9, geometry.size.width / 70)
                VStack(spacing: size * 0.6) {
                    switch phase {
                    case .running(let started):
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = Int(context.date.timeIntervalSince(started))
                            Label("Draw Things malt den Hintergrund … \(seconds / 60):\(String(format: "%02d", seconds % 60))", systemImage: "wand.and.stars")
                        }
                    case .queued:
                        Label("Wartet auf Draw Things" + (app.imageGeneration.position(of: background.image ?? "").map { " (Platz \($0))" } ?? ""), systemImage: "hourglass")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .lineLimit(2)
                    case nil:
                        Label("Bild fehlt", systemImage: "photo")
                    }
                }
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                .padding(size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

/// Background pictures, read once.
@MainActor
enum SlideImageCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ source: String) -> NSImage? {
        if let image = images[source] { return image }
        guard let url = WriterImageStore.url(for: source), let image = NSImage(contentsOf: url) else { return nil }
        images[source] = image
        return image
    }
}

// MARK: Text

/// A slide's text as it looks in the presentation: Writer Studio's text view on the slide canvas, magnified to the
/// size there is, not editable.
struct SlideTextView: NSViewRepresentable {
    let markdown: String
    let family: WriterFont
    let palette: WriterPalette
    let layout: WriterTextView.SlideLayout
    let citations: CitationLibrary?

    func makeNSView(context: Context) -> SlideScrollView {
        let scrollView = PassthroughSlideScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        let textView = WriterTextView.make()
        textView.isEditable = false
        textView.isSelectable = false
        textView.slideLayout = layout
        textView.citations = citations
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView
        textView.load(markdown: markdown, family: family, palette: palette)
        context.coordinator.shown = Shown(markdown: markdown, family: family, palette: palette, layout: layout)
        // Text that runs over shows from its start (a field too small for it is cut at the bottom).
        DispatchQueue.main.async { textView.scroll(.zero) }
        return scrollView
    }

    func updateNSView(_ scrollView: SlideScrollView, context: Context) {
        let shown = Shown(markdown: markdown, family: family, palette: palette, layout: layout)
        guard context.coordinator.shown != shown, let textView = scrollView.documentView as? WriterTextView else { return }
        context.coordinator.shown = shown
        textView.slideLayout = layout
        textView.load(markdown: markdown, family: family, palette: palette)
        scrollView.fitCanvas()
        DispatchQueue.main.async { textView.scroll(.zero) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct Shown: Equatable {
        let markdown: String
        let family: WriterFont
        let palette: WriterPalette
        let layout: WriterTextView.SlideLayout
    }

    final class Coordinator {
        var shown: Shown?
    }
}

private final class PassthroughSlideScrollView: SlideScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// One whole slide as it is presented: background and text.
struct SlideStageView: View {
    @Environment(AppModel.self) private var app
    let slide: PresentationSlide
    let deck: PresentationDeck
    let family: WriterFont
    var live = false

    var body: some View {
        let background = deck.background(of: slide)
        ZStack {
            SlideBackgroundView(background: background, role: slide.role, live: live)
                // The same background on the next slide stays where it is, without fading.
                .id(backgroundKey(background))
            ZStack {
                SlideImagesLayer(images: slide.images, placements: [.behind])
                SlideTextView(
                    markdown: slide.markdown,
                    family: family,
                    palette: SlideLook.palette(background, role: slide.role),
                    layout: WriterTextView.SlideLayout(slide: slide),
                    citations: app.citations
                )
                SlideImagesLayer(images: slide.images, placements: [.wrap, .front])
            }
            .environment(\.slideTextLook, SlideLook.fieldLook(of: slide, in: deck, family: family))
            .id(slide.id)
            .transition(.opacity)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
    }

    private func backgroundKey(_ background: SlideBackground) -> String {
        "\(background.hashValue)|\(slide.role.rawValue)"
    }
}

// MARK: Thumbnails

/// A slide's text drawn as a picture (for the slide list and the background menu), kept until the slide changes.
@MainActor
enum SlideThumbnailRenderer {
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []
    /// A text view kept for drawing.
    private static var textView: WriterTextView?

    static func image(markdown: String, family: WriterFont, palette: WriterPalette, layout: WriterTextView.SlideLayout, citations: CitationLibrary?, scale: CGFloat = 0.6) -> NSImage? {
        let key = "\(layout.centersVertically)|\(layout.obstacles)|\(layout.textRect)|\(family.rawValue)|\(palette.isLight)|\(palette.accent.hashValue)|\(scale)|\(markdown)"
        if let image = cache[key] { return image }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let canvas = WriterTextView.SlideLayout.canvas
        let view = textView ?? WriterTextView.make()
        textView = view
        view.slideLayout = layout
        view.citations = citations
        view.frame = NSRect(origin: .zero, size: canvas)
        view.load(markdown: markdown, family: family, palette: palette)
        view.setFrameSize(canvas)
        if let layoutManager = view.layoutManager, let container = view.textContainer { layoutManager.ensureLayout(for: container) }
        view.updateSlideCentering()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale * 2), pixelsHigh: Int(canvas.height * scale * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas
        view.cacheDisplay(in: NSRect(origin: .zero, size: canvas), to: rep)
        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        cache[key] = image
        order.append(key)
        if order.count > 240 { cache[order.removeFirst()] = nil }
        return image
    }
}

/// A small picture of a slide.
struct SlideThumbnail: View {
    @Environment(AppModel.self) private var app
    let slide: PresentationSlide
    let deck: PresentationDeck
    let family: WriterFont

    var body: some View {
        let background = deck.background(of: slide)
        ZStack {
            SlideBackgroundView(background: background, role: slide.role)
            SlideImagesLayer(images: slide.images, placements: [.behind])
            if let image = SlideThumbnailRenderer.image(
                markdown: slide.markdown, family: family, palette: SlideLook.palette(background, role: slide.role),
                layout: WriterTextView.SlideLayout(slide: slide), citations: app.citations
            ) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            }
            SlideImagesLayer(images: slide.images, placements: [.wrap, .front])
        }
        .environment(\.slideTextLook, SlideLook.fieldLook(of: slide, in: deck, family: family))
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
    }
}

// MARK: Free pictures

/// A slide's free pictures and text fields of some placements, drawn at the size there is (the canvas scaled to it).
struct SlideImagesLayer: View {
    let images: [SlideImage]
    let placements: Set<SlideImage.Placement>
    /// A text field being edited is drawn by the editor.
    var hiding: SlideImage.ID?

    var body: some View {
        let shown = images.filter { placements.contains($0.placement) && $0.id != hiding }
        if !shown.isEmpty {
            GeometryReader { geometry in
                let scale = geometry.size.width / SlideImage.canvas.width
                ForEach(shown) { image in
                    let frame = image.frame
                    SlideImageView(image: image)
                        .frame(width: frame.width * scale, height: frame.height * scale)
                        .position(x: frame.midX * scale, y: frame.midY * scale)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// One free picture filling its frame (cut to it when the frame has another shape); while Draw Things makes it,
/// a placeholder with its progress.
struct SlideImageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.slideTextLook) private var look
    let image: SlideImage

    var body: some View {
        let phase = image.isText ? nil : app.imageGeneration.phase(for: image.source)
        if image.isText {
            if let look { SlideFieldView(field: image, look: look) }
        } else if phase == nil, let picture = SlideImageCache.image(image.source) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            GeometryReader { geometry in
                let size = max(7, min(geometry.size.width, geometry.size.height * 1.6) / 22)
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x2A2740), Color(hex: 0x15141F)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: size * 0.5) {
                        Image(systemName: phase == nil ? "photo" : "wand.and.stars")
                            .font(.system(size: size * 1.8, weight: .light))
                        Group {
                            switch phase {
                            case .running(let started):
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let seconds = Int(context.date.timeIntervalSince(started))
                                    Text("Draw Things malt … \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                                }
                            case .queued:
                                Text("Wartet auf Draw Things")
                            case .failed(let message):
                                Text(message).lineLimit(2)
                            case nil:
                                Text(image.generated ? "Noch nicht generiert" : "Bild fehlt")
                            }
                        }
                        .font(.system(size: size, weight: .medium))
                        .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(size)
                }
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }
}

// MARK: Text fields

/// A text field on the slide: its box (if it is one) and its text, at the size there is.
struct SlideFieldView: View {
    @Environment(AppModel.self) private var app
    let field: SlideImage
    let look: SlideTextLook
    var showsText = true

    var body: some View {
        ZStack {
            SlideBoxBackground(field: field)
            if showsText, let text = field.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SlideTextView(
                    markdown: text,
                    family: look.family,
                    palette: look.palette,
                    layout: WriterTextView.SlideLayout(field: field),
                    citations: app.citations
                )
            }
        }
    }
}

/// The tint and line of a box, scaled like the slide.
struct SlideBoxBackground: View {
    let field: SlideImage

    var body: some View {
        if let kind = field.box {
            GeometryReader { geometry in
                let scale = geometry.size.width / max(1, field.frame.width)
                let color = Color(hex: SlideBoxBackground.hex(field, kind: kind))
                let shape = RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                ZStack(alignment: .leading) {
                    switch field.boxFrame {
                    case .filled:
                        shape.fill(color.opacity(0.26))
                    case .outline:
                        shape.fill(color.opacity(0.1))
                        shape.strokeBorder(color.opacity(0.9), lineWidth: max(1, 1.6 * scale))
                    case .bar:
                        shape.fill(color.opacity(0.14))
                        Rectangle().fill(color).frame(width: max(2, 4 * scale))
                    }
                }
                .clipShape(shape)
            }
        }
    }

    static func hex(_ field: SlideImage, kind: WriterBoxKind) -> UInt32 {
        UInt32(kind.color, radix: 16) ?? 0x6B6B76
    }
}
