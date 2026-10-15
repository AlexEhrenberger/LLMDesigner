import SwiftUI
import WebKit

/// A diagram of the content analysis: title, the drawing, and a footer to enlarge it or copy its Mermaid code.
/// A click on a node with a place in the text jumps there.
struct DiagramCard: View {
    let diagram: MermaidDiagram
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void
    @State private var isEnlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(diagram.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.text)
                Spacer(minLength: 8)
                CardIconButton(symbol: "doc.on.doc", help: "Mermaid-Code kopieren", colors: colors) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagram.code, forType: .string)
                }
                CardIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Vergrößern – mit Zoom (Trackpad) und Scrollen", colors: colors) {
                    isEnlarged = true
                }
            }
            MermaidDiagramView(diagram: diagram, palette: colors.mermaid, onNode: jump)
            if let caption = diagram.caption {
                Text(caption + (diagram.links.isEmpty ? "" : " Ein Klick auf ein Kästchen springt zur Stelle im Text."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colors.border))
        .sheet(isPresented: $isEnlarged) {
            EnlargedDiagram(diagram: diagram, colors: colors) { node in
                isEnlarged = false
                jump(node)
            }
        }
    }

    private func jump(_ node: String) {
        if let anchor = diagram.links[node] { onJump(anchor) }
    }
}

/// The diagram in a big window: zoom with the trackpad, scroll in all directions.
private struct EnlargedDiagram: View {
    let diagram: MermaidDiagram
    let colors: AnalysisColors
    let onNode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Most of the window: a sheet otherwise takes the small size of its content.
    private var size: CGSize {
        let window = NSApp.mainWindow?.frame.size ?? CGSize(width: 1300, height: 900)
        return CGSize(width: max(720, window.width * 0.86), height: max(480, window.height * 0.84))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(diagram.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.text)
                Spacer()
                Text("Zoomen mit zwei Fingern · ⌘0 zurück")
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.tertiaryText)
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            MermaidDiagramView(diagram: diagram, palette: colors.mermaid, isInteractive: true, onNode: onNode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .background(colors.page)
    }
}

private struct CardIconButton: View {
    let symbol: String
    let help: String
    let colors: AnalysisColors
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? colors.text : colors.tertiaryText)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? colors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Draws a diagram: the hidden renderer makes the SVG, a small web view shows it at the width of the page, never
/// larger than its natural size and never so small that the text gets unreadable (then it scrolls sideways).
struct MermaidDiagramView: View {
    let diagram: MermaidDiagram
    let palette: MermaidPalette
    var isInteractive = false
    let onNode: (String) -> Void
    @State private var result: MermaidRenderer.Result?
    @State private var error: String?
    @State private var width: CGFloat = 0

    /// The smallest scale in the page; wider diagrams scroll sideways instead.
    private let minimumScale: CGFloat = 0.58

    var body: some View {
        content
            .task(id: "\(palette.isLight)" + diagram.code) {
                error = nil
                if let cached = MermaidRenderer.shared.cached(diagram.code, palette: palette) {
                    result = cached
                    return
                }
                do {
                    result = try await MermaidRenderer.shared.render(diagram.code, palette: palette)
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            if isInteractive {
                DiagramWebView(svg: result.svg, size: result.size, links: Set(diagram.links.keys), isInteractive: true, onNode: onNode)
            } else {
                let size = displaySize(result.size)
                Group {
                    if size.width > width + 1 {
                        ScrollView(.horizontal) {
                            DiagramWebView(svg: result.svg, size: result.size, links: Set(diagram.links.keys), isInteractive: false, onNode: onNode)
                                .frame(width: size.width, height: size.height)
                        }
                        .scrollIndicators(.visible)
                    } else {
                        DiagramWebView(svg: result.svg, size: result.size, links: Set(diagram.links.keys), isInteractive: false, onNode: onNode)
                            .frame(width: size.width, height: size.height)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: width > 0 ? size.height + (size.width > width + 1 ? 14 : 0) : 120)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func displaySize(_ natural: CGSize) -> CGSize {
        guard width > 0, natural.width > 0 else { return CGSize(width: max(width, 1), height: 120) }
        let scale = min(1, max(width / natural.width, minimumScale))
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// The web view that shows one SVG. In the page it passes scrolling on to the page and only reacts to clicks;
/// enlarged it scrolls and zooms itself.
private struct DiagramWebView: NSViewRepresentable {
    let svg: String
    let size: CGSize
    let links: Set<String>
    let isInteractive: Bool
    let onNode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiagramWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "node")
        let webView = DiagramWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.forwardsScrolling = !isInteractive
        webView.allowsMagnification = isInteractive
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: DiagramWKWebView, context: Context) {
        context.coordinator.onNode = onNode
        let html = page()
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: DiagramWKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "node")
    }

    private func page() -> String {
        let linkList = links.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        // Enlarged: as wide as the window allows up to the natural size; zooming in goes further.
        let layout = isInteractive
            ? "html,body{margin:0;overflow:auto} body{padding:20px 24px} #c svg{display:block;margin:0 auto;width:100%;height:auto;max-width:\(Int(size.width))px}"
            : "html,body{margin:0;padding:0;overflow:hidden} #c svg{display:block;width:100%;height:auto;max-width:none}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{background:transparent;-webkit-user-select:none;cursor:default}
        \(layout)
        g.node.link{cursor:pointer}
        g.node.link:hover > rect, g.node.link:hover > path, g.node.link:hover > polygon, g.node.link:hover > circle{filter:brightness(1.35)}
        </style></head><body><div id="c">\(svg)</div><script>
        const links = new Set([\(linkList)]);
        document.querySelectorAll('g.node').forEach(node => {
          const match = node.id.match(/flowchart-(.+)-\\d+$/);
          if (!match || !links.has(match[1])) return;
          node.classList.add('link');
          const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
          title.textContent = 'Zur Stelle im Text springen';
          node.appendChild(title);
          node.addEventListener('click', () => window.webkit.messageHandlers.node.postMessage(match[1]));
        });
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onNode: ((String) -> Void)?
        var html = ""

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let node = message.body as? String else { return }
            onNode?(node)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the page itself loads; nothing in a diagram navigates anywhere.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

final class DiagramWKWebView: WKWebView {
    var forwardsScrolling = true

    /// A click on a node works even while the window is not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrolling {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘0: back to the fitted size.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "0", allowsMagnification {
            magnification = 1
            return
        }
        super.keyDown(with: event)
    }
}
