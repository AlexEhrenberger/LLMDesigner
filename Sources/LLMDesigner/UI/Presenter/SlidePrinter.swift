import AppKit
import PDFKit

/// Draws slides away from the screen, for the PDF and for the slide pictures of a handout. Each slide is the same
/// canvas as in the editor (720 × 405 points) with Writer Studio's text view on it, so line breaks, the centring
/// and the text around free pictures come out exactly as they look; the text stays text in the PDF.
@MainActor
enum SlidePrinter {
    static var canvas: CGSize { WriterTextView.SlideLayout.canvas }

    /// The whole presentation as a PDF, one page per slide. `progress` hears how many slides are done.
    static func pdf(deck: PresentationDeck, title: String, family: WriterFont, citations: CitationLibrary?,
                    progress: ((Int, Int) -> Void)? = nil) async -> Data? {
        let result = PDFDocument()
        PrintImages.reset()
        defer { PrintImages.reset() }
        for (index, slide) in deck.slides.enumerated() {
            if Task.isCancelled { return nil }
            progress?(index, deck.slides.count)
            let view = await view(for: slide, in: deck, family: family, citations: citations)
            let data = view.dataWithPDF(inside: view.bounds)
            guard let page = PDFDocument(data: data)?.page(at: 0) else { continue }
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { return nil }
        result.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "LLM Designer – Presenter Studio"]
        return result.dataRepresentation()
    }

    /// One slide as a PNG, `scale` times the canvas.
    static func png(slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont, citations: CitationLibrary?, scale: CGFloat = 2) async -> Data? {
        let view = await view(for: slide, in: deck, family: family, citations: citations)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The slide as views that draw themselves: background with the pictures behind the text, the text, the
    /// pictures in front.
    static func view(for slide: PresentationSlide, in deck: PresentationDeck, family: WriterFont, citations: CitationLibrary?) async -> NSView {
        let background = deck.background(of: slide)
        var designImage: NSImage?
        if background.kind == .design, let design = SlideLook.design(of: background) {
            designImage = await SlideDesignRenderer.shared.render(design, role: slide.role, width: 1920)
        }
        let frame = NSRect(origin: .zero, size: canvas)
        let stage = SlidePrintLayer(frame: frame)
        stage.background = background
        stage.tone = SlideLook.tone(of: background, role: slide.role)
        stage.designImage = designImage.flatMap { PrintImages.compact($0, key: "design|\(background.design ?? "")|\(slide.role.rawValue)", size: canvas) }
        stage.images = slide.images.filter { $0.placement == .behind && !$0.isText }
        let fieldPalette = SlideLook.fieldPalette(background, role: slide.role)
        for field in slide.images where field.isText && field.placement == .behind {
            stage.addSubview(fieldView(field, family: family, palette: fieldPalette, citations: citations))
        }

        let text = WriterTextView.make()
        text.isEditable = false
        text.isSelectable = false
        text.isContinuousSpellCheckingEnabled = false
        text.slideLayout = WriterTextView.SlideLayout(slide: slide)
        text.citations = citations
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.frame = frame
        citations?.loadIfNeeded()
        text.load(markdown: slide.markdown, family: family, palette: SlideLook.palette(background, role: slide.role))
        text.setFrameSize(canvas)
        if let layoutManager = text.layoutManager, let container = text.textContainer { layoutManager.ensureLayout(for: container) }
        text.updateSlideCentering()
        stage.addSubview(text)

        let front = SlidePrintLayer(frame: frame)
        front.images = slide.images.filter { $0.placement != .behind && !$0.isText }
        stage.addSubview(front)
        for field in slide.images where field.isText && field.placement != .behind {
            stage.addSubview(fieldView(field, family: family, palette: fieldPalette, citations: citations))
        }
        return stage
    }

    /// A text field: its box drawn behind Writer Studio's text view, both at the field's frame.
    private static func fieldView(_ field: SlideImage, family: WriterFont, palette: WriterPalette, citations: CitationLibrary?) -> NSView {
        let frame = field.frame
        // The view's coordinates are flipped like the stage's (top left origin).
        let holder = SlideFieldPrintView(frame: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
        holder.field = field
        let layout = WriterTextView.SlideLayout(field: field)
        let text = WriterTextView.make()
        text.isEditable = false
        text.isSelectable = false
        text.isContinuousSpellCheckingEnabled = false
        text.slideLayout = layout
        text.citations = citations
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.frame = NSRect(origin: .zero, size: layout.size)
        text.load(markdown: field.text ?? "", family: family, palette: palette)
        text.setFrameSize(layout.size)
        if let layoutManager = text.layoutManager, let container = text.textContainer { layoutManager.ensureLayout(for: container) }
        text.updateSlideCentering()
        // Text that runs over the field is cut at its edge, as on the screen.
        text.setFrameSize(layout.size)
        holder.addSubview(text)
        return holder
    }
}

/// Pictures for the PDF: at most about 220 dpi where they are drawn, and as JPEG when they have no transparency,
/// so a presentation stays a few megabytes. Kept for one export, so a design used on many slides is made once.
@MainActor
private enum PrintImages {
    private static var cache: [String: NSImage] = [:]
    /// Pixels per point of the slide (a 720 pt slide printed 10 inches wide).
    static let density: CGFloat = 3

    static func reset() { cache = [:] }

    static func image(_ source: String, size: CGSize) -> NSImage? {
        let key = "\(source)|\(Int(size.width))x\(Int(size.height))"
        if let image = cache[key] { return image }
        guard let url = WriterImageStore.url(for: source), let image = NSImage(contentsOf: url) else { return nil }
        return compact(image, key: key, size: size)
    }

    static func compact(_ image: NSImage, key: String, size: CGSize) -> NSImage {
        if let cached = cache[key] { return cached }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // Filling the frame: the shorter side decides how many pixels are needed.
        let needed = max(size.width * density / width, size.height * density / height)
        let scale = min(1, needed)
        let target = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        let alpha = cgImage.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast || !hasTransparency(cgImage)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        let data = opaque
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            : rep.representation(using: .png, properties: [:])
        let result = data.flatMap(NSImage.init(data:)) ?? image
        result.size = image.size
        cache[key] = result
        return result
    }

    /// Whether any pixel of a small copy is see-through.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }
}

/// A layer of a printed slide: its background (if it has one) and pictures.
private final class SlidePrintLayer: NSView {
    var background: SlideBackground?
    var tone: SlideTone = .light
    var designImage: NSImage?
    var images: [SlideImage] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let background { draw(background) }
        for image in images { draw(image) }
    }

    private func draw(_ background: SlideBackground) {
        let colors = background.hexColors.map { NSColor(hex: $0) }
        switch background.kind {
        case .color:
            (colors.first ?? NSColor(hex: 0x202024)).setFill()
            bounds.fill()
        case .gradient:
            let stops = colors.isEmpty ? [NSColor(hex: 0x202024), NSColor(hex: 0x101014)] : colors.count == 1 ? colors + colors : colors
            guard let gradient = NSGradient(colors: stops) else { return }
            if background.radial == true {
                let center = NSPoint(x: bounds.midX, y: bounds.midY)
                gradient.draw(fromCenter: center, radius: 0, toCenter: center, radius: max(bounds.width, bounds.height) * 0.62,
                              options: [.drawsAfterEndingLocation])
            } else {
                // As in CSS and the slide view: 0° upwards, 90° to the right; the view is flipped (y downwards).
                let angle = (background.angle ?? 135) * .pi / 180
                let dx = sin(angle) / 2
                let dy = -cos(angle) / 2
                let start = NSPoint(x: bounds.width * (0.5 - dx), y: bounds.height * (0.5 - dy))
                let end = NSPoint(x: bounds.width * (0.5 + dx), y: bounds.height * (0.5 + dy))
                gradient.draw(from: start, to: end, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
            }
        case .design:
            if let designImage {
                designImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                NSColor(hex: 0x111116).setFill()
                bounds.fill()
            }
        case .image:
            if let source = background.image, let image = PrintImages.image(source, size: bounds.size) {
                drawFilling(image, in: bounds)
                (tone == .light ? NSColor.black : NSColor.white).withAlphaComponent(background.dim ?? 0).setFill()
                bounds.fill(using: .sourceOver)
            } else {
                NSColor(hex: tone == .light ? 0x1C1A2E : 0xF4F1EA).setFill()
                bounds.fill()
            }
        }
    }

    private func draw(_ image: SlideImage) {
        let frame = image.frame
        if let picture = PrintImages.image(image.source, size: frame.size) {
            drawFilling(picture, in: frame)
        } else {
            NSColor(hex: 0x2A2740).setFill()
            frame.fill()
        }
    }

    /// The picture covers the rectangle and is cut to it, like `.aspectRatio(contentMode: .fill)`.
    private func drawFilling(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A text field in the PDF: the box behind its text, cut at the field's edge.
private final class SlideFieldPrintView: NSView {
    var field: SlideImage?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let field, let kind = field.box else { return }
        let color = NSColor(hex: SlideBoxBackground.hex(field, kind: kind))
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        switch field.boxFrame {
        case .filled:
            color.withAlphaComponent(0.26).setFill()
            path.fill()
        case .outline:
            color.withAlphaComponent(0.1).setFill()
            path.fill()
            color.withAlphaComponent(0.9).setStroke()
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: 6.2, yRadius: 6.2)
            inner.lineWidth = 1.6
            inner.stroke()
        case .bar:
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.withAlphaComponent(0.14).setFill()
            bounds.fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
