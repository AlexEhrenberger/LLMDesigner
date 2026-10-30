import AppKit

/// A drawing in a Writer Studio document: strokes, lines, arrows, shapes and text on a canvas of its own size. It is a
/// picture in the text (`.drawing`: light and dark PNG, a PDF for print) with this recipe next to it as JSON, so it
/// opens in the drawing editor again. Points are in the canvas's own coordinates, the top left being 0, 0.
struct WriterDrawing: Codable, Equatable, Sendable {
    enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The paper shows through.
        case none, paper, grid, dots
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Durchsichtig"
            case .paper: "Papier"
            case .grid: "Kariert"
            case .dots: "Punkte"
            }
        }
    }

    enum Kind: String, Codable, CaseIterable, Sendable {
        case pen, highlighter, line, arrow, doubleArrow, rectangle, roundedRectangle, ellipse, diamond, text

        /// Drawn by dragging from one corner (or end) to the other.
        var isTwoPoint: Bool { ![.pen, .highlighter, .text].contains(self) }
        /// Has an inside that can be filled.
        var canFill: Bool { [.rectangle, .roundedRectangle, .ellipse, .diamond].contains(self) }
    }

    struct Shape: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var kind: Kind
        /// A stroke's points; the two ends or corners of the other shapes; a text's top left.
        var points: [CGPoint]
        /// Six hex digits as printed.
        var stroke: String
        var fill: String?
        var width: CGFloat
        var dashed = false
        var text = ""
        var fontSize: CGFloat = 22

        /// The box the shape covers (without its line's width).
        var bounds: CGRect {
            if kind == .text {
                let size = WriterDrawing.textSize(text, fontSize: fontSize)
                return CGRect(origin: points.first ?? .zero, size: size)
            }
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
            return rect
        }

        /// Whether a point is on the shape (within `tolerance` of its line, or inside a filled shape or a text).
        func hit(_ point: CGPoint, tolerance: CGFloat) -> Bool {
            let reach = tolerance + width / 2
            switch kind {
            case .text:
                return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case .pen, .highlighter:
                guard points.count > 1 else { return points.first.map { hypot($0.x - point.x, $0.y - point.y) <= reach } ?? false }
                return zip(points, points.dropFirst()).contains { WriterDrawing.distance(point, $0, $1) <= reach }
            case .line, .arrow, .doubleArrow:
                guard points.count >= 2 else { return false }
                return WriterDrawing.distance(point, points[0], points[1]) <= reach
            case .rectangle, .roundedRectangle, .ellipse, .diamond:
                let rect = bounds
                if fill != nil, rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return true }
                let outer = rect.insetBy(dx: -reach, dy: -reach), inner = rect.insetBy(dx: reach, dy: reach)
                return outer.contains(point) && (inner.isNull || inner.isEmpty || !inner.contains(point))
            }
        }

        func moved(by offset: CGSize) -> Shape {
            var shape = self
            shape.points = points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
            return shape
        }

        /// The shape fitted into another box (scaled from its own).
        func fitted(into rect: CGRect) -> Shape {
            let old = bounds
            var shape = self
            if kind == .text {
                let scale = old.height > 0 ? rect.height / old.height : 1
                shape.fontSize = max(6, fontSize * scale)
                shape.points = [rect.origin]
                return shape
            }
            let sx = old.width > 0.5 ? rect.width / old.width : 1, sy = old.height > 0.5 ? rect.height / old.height : 1
            shape.points = points.map { CGPoint(x: rect.minX + ($0.x - old.minX) * sx, y: rect.minY + ($0.y - old.minY) * sy) }
            return shape
        }
    }

    var size = CGSize(width: 800, height: 500)
    var background: Background = .none
    var shapes: [Shape] = []

    /// The sizes the editor offers.
    static let formats: [(label: String, size: CGSize)] = [
        ("Breit 16 : 10", CGSize(width: 800, height: 500)),
        ("Quer 4 : 3", CGSize(width: 800, height: 600)),
        ("Quadrat", CGSize(width: 640, height: 640)),
        ("Hoch 3 : 4", CGSize(width: 600, height: 800)),
        ("Streifen", CGSize(width: 900, height: 300)),
    ]

    var isEmpty: Bool { shapes.isEmpty }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data?) -> WriterDrawing? {
        data.flatMap { try? JSONDecoder().decode(WriterDrawing.self, from: $0) }
    }

    static func distance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin],
            attributes: [.font: textFont(size: fontSize)]
        ).size
        return CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height))
    }

    // MARK: Colours

    /// Ink colours the editor offers, as printed.
    static let inks: [(name: String, hex: String)] = [
        ("Schwarz", "1C1C1F"), ("Grau", "6B6B76"), ("Rot", "C0392B"), ("Orange", "D35400"), ("Gold", "B7791F"),
        ("Grün", "1E8449"), ("Türkis", "148F8F"), ("Blau", "1F5FBF"), ("Violett", "7B3FC4"), ("Rosa", "C2185B"),
    ]

    /// Fill colours, light as printed.
    static let fills: [(name: String, hex: String)] = WriterColors.cellPalette.map { ($0.name, $0.printHex) }

    /// A colour as drawn: on the dark sheet black becomes light, the palette's inks brighten and light fills darken.
    static func color(_ hex: String, dark: Bool, isFill: Bool = false, alpha: CGFloat = 1) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0x1C1C1F
        guard dark else { return NSColor(hex: value).withAlphaComponent(alpha) }
        if isFill { return (WriterColors.cellFill(hex, onDark: true) ?? NSColor(hex: value)).withAlphaComponent(alpha) }
        let base = NSColor(hex: value)
        if let rgb = base.usingColorSpace(.sRGB), rgb.brightnessComponent < 0.25, rgb.saturationComponent < 0.25 {
            return NSColor(hex: 0xE8E8EC).withAlphaComponent(alpha)
        }
        return WriterChartPalette.display(hex, onDark: true).withAlphaComponent(alpha)
    }

    // MARK: Drawing

    /// Draws the drawing into a context whose origin is its top left (y downwards), as AppKit's flipped views have it.
    func draw(in context: CGContext, dark: Bool, selection: Set<UUID> = [], showsBackground: Bool = true) {
        if showsBackground { drawBackground(in: context, dark: dark) }
        for shape in shapes {
            WriterDrawing.draw(shape, in: context, dark: dark)
        }
    }

    func drawBackground(in context: CGContext, dark: Bool) {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case .none:
            break
        case .paper:
            context.setFillColor((dark ? NSColor(hex: 0x1D1D22) : .white).cgColor)
            context.fill(rect)
        case .grid, .dots:
            context.setFillColor((dark ? NSColor(hex: 0x1D1D22) : .white).cgColor)
            context.fill(rect)
            let ink = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor(hex: 0x1F5FBF).withAlphaComponent(0.16)).cgColor
            let step: CGFloat = 20
            if background == .grid {
                context.setStrokeColor(ink)
                context.setLineWidth(0.6)
                var x = step
                while x < size.width { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y = step
                while y < size.height { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                context.strokePath()
            } else {
                context.setFillColor((dark ? NSColor.white.withAlphaComponent(0.22) : NSColor(hex: 0x6B6B76).withAlphaComponent(0.35)).cgColor)
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width { context.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += step }
                    y += step
                }
            }
        }
    }

    static func path(for shape: Shape) -> CGPath {
        let path = CGMutablePath()
        let rect = shape.bounds
        switch shape.kind {
        case .pen, .highlighter:
            guard let first = shape.points.first else { return path }
            path.move(to: first)
            if shape.points.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
                return path
            }
            // Through the middles of the segments: a smooth line through the hand's points.
            for index in 1..<shape.points.count {
                let previous = shape.points[index - 1], point = shape.points[index]
                let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                path.addQuadCurve(to: middle, control: previous)
            }
            if let last = shape.points.last { path.addLine(to: last) }
        case .line, .arrow, .doubleArrow:
            guard shape.points.count >= 2 else { return path }
            path.move(to: shape.points[0])
            path.addLine(to: shape.points[1])
        case .rectangle:
            path.addRect(rect)
        case .roundedRectangle:
            let radius = min(14, min(rect.width, rect.height) / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: rect)
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .text:
            break
        }
        return path
    }

    static func draw(_ shape: Shape, in context: CGContext, dark: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        if shape.kind == .text {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textFont(size: shape.fontSize),
                .foregroundColor: color(shape.stroke, dark: dark),
            ]
            if let fill = shape.fill {
                context.setFillColor(color(fill, dark: dark, isFill: true).cgColor)
                context.fill(shape.bounds.insetBy(dx: -4, dy: -2))
            }
            (shape.text as NSString).draw(with: shape.bounds, options: [.usesLineFragmentOrigin], attributes: attributes)
            NSGraphicsContext.current = previous
            return
        }
        let path = path(for: shape)
        if let fill = shape.fill, shape.kind.canFill {
            context.addPath(path)
            context.setFillColor(color(fill, dark: dark, isFill: true).cgColor)
            context.fillPath()
        }
        let isHighlighter = shape.kind == .highlighter
        context.addPath(path)
        context.setStrokeColor(color(shape.stroke, dark: dark, alpha: isHighlighter ? 0.38 : 1).cgColor)
        context.setLineWidth(shape.width)
        context.setLineCap(isHighlighter ? .square : .round)
        context.setLineJoin(.round)
        if shape.dashed { context.setLineDash(phase: 0, lengths: [shape.width * 3, shape.width * 2.4]) }
        if isHighlighter { context.setBlendMode(dark ? .screen : .multiply) }
        context.strokePath()
        if shape.kind == .arrow || shape.kind == .doubleArrow, shape.points.count >= 2 {
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(color(shape.stroke, dark: dark).cgColor)
            arrowHead(at: shape.points[1], from: shape.points[0], width: shape.width, in: context)
            if shape.kind == .doubleArrow { arrowHead(at: shape.points[0], from: shape.points[1], width: shape.width, in: context) }
        }
    }

    private static func arrowHead(at tip: CGPoint, from tail: CGPoint, width: CGFloat, in context: CGContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(10, width * 4.2), spread: CGFloat = .pi / 7.5
        let left = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let right = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    // MARK: Pictures

    /// PNGs (two pixels per point) for white paper and the dark sheet, and a vector PDF.
    func images() -> WriterFigureImages? {
        guard let light = png(dark: false), let dark = png(dark: true), let pdf = pdf() else { return nil }
        return WriterFigureImages(light: light, dark: dark, pdf: pdf)
    }

    private func png(dark: Bool) -> Data? {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, dark: dark)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    private func pdf() -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(in: context, dark: false)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
