import AppKit
import SwiftUI

/// What a master puts on one slide, ready to draw: its lines already filled in.
struct SlideMasterContent: Equatable {
    var header = ""
    var footer = ""
    var number: String?
    var logo: URL?
    var corner = SlideMaster.Corner.obenRechts
    var logoSize = 0.12
    var rule = true
    var textColor = NSColor.black

    static func == (lhs: SlideMasterContent, rhs: SlideMasterContent) -> Bool {
        lhs.header == rhs.header && lhs.footer == rhs.footer && lhs.number == rhs.number && lhs.logo == rhs.logo && lhs.corner == rhs.corner
            && lhs.logoSize == rhs.logoSize && lhs.rule == rhs.rule && lhs.textColor.isEqual(rhs.textColor)
    }

    /// The master's content on a slide of a deck; nil when the deck has no master or the slide shows none.
    @MainActor
    static func make(deck: PresentationDeck, slide: PresentationSlide, title: String) -> SlideMasterContent? {
        guard let (master, logo) = DataFields.studio?.master(of: deck) else { return nil }
        if slide.role == .title, !master.onTitle { return nil }
        let index = (deck.index(of: slide.id) ?? 0) + 1
        var resolver = DataFields.resolver
        resolver.extras = ["titel": title, "folie": String(index), "folien": String(deck.slides.count)]
        let background = deck.background(of: slide)
        var content = SlideMasterContent()
        content.header = resolver.resolve(master.header).replacingOccurrences(of: "\n", with: " ")
        content.footer = resolver.resolve(master.footer).replacingOccurrences(of: "\n", with: " ")
        content.number = master.pageNumbers ? "\(index) / \(deck.slides.count)" : nil
        content.logo = logo
        content.corner = master.logoCorner
        content.logoSize = master.logoSize
        content.rule = master.rule
        content.textColor = SlideLook.palette(background, role: slide.role).text
        return content
    }
}

/// Draws a master on the slide canvas (720 × 405 points), scaled to its own size. Lets every click through.
final class SlideMasterView: NSView {
    var content = SlideMasterContent() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let canvas = WriterTextView.SlideLayout.canvas
        guard bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let scale = bounds.width / canvas.width
        context.scaleBy(x: scale, y: scale)
        Self.draw(content, in: canvas)
        context.restoreGState()
    }

    /// In canvas points, top left origin.
    static func draw(_ content: SlideMasterContent, in canvas: CGSize) {
        let margin: CGFloat = 18
        let color = content.textColor.withAlphaComponent(0.62)
        let font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var logoRect: NSRect?
        if let url = content.logo, let image = MainActor.assumeIsolated({ SlideMasterImageCache.image(url) }), image.size.width > 0 {
            let width = canvas.width * CGFloat(max(0.04, min(0.4, content.logoSize)))
            let height = width * image.size.height / image.size.width
            let x = content.corner.isLeft ? margin : canvas.width - margin - width
            let y = content.corner.isTop ? margin - 4 : canvas.height - margin - height + 4
            let rect = NSRect(x: x, y: y, width: width, height: height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            logoRect = rect
        }
        let footerY = canvas.height - margin + 2 - font.pointSize
        let bottomLogo = logoRect != nil && !content.corner.isTop
        if content.rule, !content.footer.isEmpty || content.number != nil {
            let rule = NSBezierPath()
            let left = bottomLogo && content.corner.isLeft ? (logoRect?.maxX ?? margin) + 10 : margin
            let right = bottomLogo && !content.corner.isLeft ? (logoRect?.minX ?? canvas.width - margin) - 10 : canvas.width - margin
            rule.move(to: NSPoint(x: left, y: footerY - 5))
            rule.line(to: NSPoint(x: right, y: footerY - 5))
            rule.lineWidth = 0.5
            content.textColor.withAlphaComponent(0.25).setStroke()
            rule.stroke()
        }
        if !content.header.isEmpty {
            let text = NSAttributedString(string: content.header, attributes: attributes)
            let x = logoRect.map { content.corner.isTop && content.corner.isLeft ? $0.maxX + 10 : margin } ?? margin
            let limit = (logoRect.map { content.corner.isTop && !content.corner.isLeft ? $0.minX - 10 : canvas.width - margin } ?? canvas.width - margin) - x
            text.draw(with: NSRect(x: x, y: margin - 2, width: max(20, limit), height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if !content.footer.isEmpty {
            let text = NSAttributedString(string: content.footer, attributes: attributes)
            let x = bottomLogo && content.corner.isLeft ? (logoRect?.maxX ?? margin) + 10 : margin
            text.draw(with: NSRect(x: x, y: footerY, width: canvas.width * 0.62, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let number = content.number {
            let text = NSAttributedString(string: number, attributes: attributes)
            let width = text.size().width
            let right = bottomLogo && !content.corner.isLeft ? (logoRect?.minX ?? canvas.width - margin) - 10 : canvas.width - margin
            text.draw(at: NSPoint(x: right - width, y: footerY))
        }
    }
}

/// The master over a slide in SwiftUI: on the editing canvas, the stage and the thumbnails.
struct SlideMasterLayer: View {
    @Environment(AppModel.self) private var app
    let deck: PresentationDeck
    let slide: PresentationSlide
    var title = ""

    var body: some View {
        // Read so the layer follows changes of the template.
        let _ = app.dataStudio.templates.revision
        let _ = app.dataStudio.blocks.revision
        if let content = SlideMasterContent.make(deck: deck, slide: slide, title: title.isEmpty ? app.selectedDocument?.displayTitle ?? "" : title) {
            SlideMasterRepresentable(content: content)
                .allowsHitTesting(false)
        }
    }
}

private struct SlideMasterRepresentable: NSViewRepresentable {
    let content: SlideMasterContent

    func makeNSView(context: Context) -> SlideMasterView {
        let view = SlideMasterView()
        view.content = content
        return view
    }

    func updateNSView(_ view: SlideMasterView, context: Context) {
        if view.content != content { view.content = content }
    }
}
