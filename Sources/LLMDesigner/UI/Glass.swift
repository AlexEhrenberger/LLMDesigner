import AppKit
import SwiftUI

/// The blurred desktop behind the window. Screens lay `Theme.canvas` over it and side panels `Theme.panel`, so the
/// window reads as frosted glass; fields, documents and slides keep their opaque colours on top.
struct WindowGlass: NSViewRepresentable {
    /// Rounds the top trailing corner (`glassColumn()`); 0 keeps it square.
    var topTrailingRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughEffectView()
        view.blendingMode = .behindWindow
        // A clip shape from SwiftUI does not reliably reach the blur, so the effect view gets its own mask.
        if topTrailingRadius > 0 { view.maskImage = Self.mask(topTrailingRadius: topTrailingRadius) }
        // Stays glass when the window is in the background, as the design asks for, instead of turning flat grey.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// A stretchable mask, opaque except outside the rounded top trailing corner.
    private static func mask(topTrailingRadius r: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// Only a backdrop: clicks and drags go to the views above it.
    private final class PassThroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMaterial()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyMaterial()
        }

        /// The light under-window material is nearly white; the sidebar material lets the desktop show as clearly
        /// as the dark one does.
        private func applyMaterial() {
            material = Theme.isLight(effectiveAppearance) ? .sidebar : .underWindowBackground
        }
    }
}

extension View {
    /// A side panel of frosted glass. It brings its own blur because behind-window blur ignores what lies under it in
    /// the window: the panel looks the same docked beside a screen and floating over one in a narrow window.
    func glassPanel() -> some View {
        background {
            ZStack {
                WindowGlass()
                Theme.panel
            }
        }
    }

    /// A studio's list column below its top bar: glass like a side panel, closed at the top with a rounded corner
    /// towards the page and a fine edge along the top and the trailing side (which replaces a separate divider).
    func glassColumn() -> some View {
        let radius: CGFloat = 12
        return background {
            ZStack {
                WindowGlass(topTrailingRadius: radius)
                Theme.panel.clipShape(UnevenRoundedRectangle(topTrailingRadius: radius, style: .circular))
            }
        }
        .overlay {
            ColumnEdge(radius: radius)
                .stroke(Theme.border, lineWidth: 1)
                .padding(0.5)
                .allowsHitTesting(false)
        }
    }

    /// Fades the bottom edge of a scrolled list out, so text runs softly into the composer below it. A mask instead
    /// of a gradient in the background colour, because over glass that colour would cover the list as a solid band.
    func bottomFade(_ height: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
        }
    }
}

/// The top and trailing edge of a `glassColumn()`, round where they meet; the leading side borders the sidebar,
/// which has its own line.
private struct ColumnEdge: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
