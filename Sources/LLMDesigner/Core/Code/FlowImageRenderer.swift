import AppKit
import WebKit

/// A flow chart as pictures: PNG for the sheet (one for dark paper, one for white paper) and PDF for LaTeX, drawn from
/// the Mermaid SVG in a web view without a window.
@MainActor
final class FlowImageRenderer: NSObject, WKNavigationDelegate {
    struct Images {
        let light: Data
        let dark: Data
        let pdf: Data
        /// The chart's size in points.
        let size: CGSize
    }

    enum RenderError: LocalizedError {
        case failed

        var errorDescription: String? { "Das Flussdiagramm ließ sich nicht als Bild zeichnen." }
    }

    static let shared = FlowImageRenderer()

    private var loaded: CheckedContinuation<Void, Never>?
    private var lastRender: Task<Void, Never>?

    /// `opaque`: the pictures get a white card behind them, readable on any background (slides).
    func images(for graph: FlowGraph, opaque: Bool = false) async throws -> Images {
        let previous = lastRender
        let task = Task { @MainActor () throws -> Images in
            await previous?.value
            return try await self.make(graph, opaque: opaque)
        }
        lastRender = Task { _ = try? await task.value }
        return try await task.value
    }

    private func make(_ graph: FlowGraph, opaque: Bool) async throws -> Images {
        let light = try await MermaidRenderer.shared.render(graph.mermaid(palette: .light), palette: .light)
        let dark = try await MermaidRenderer.shared.render(graph.mermaid(palette: .dark), palette: .dark)
        let size = light.size
        guard let lightPNG = try await png(svg: light.svg, size: size, opaque: opaque),
              let darkPNG = try await png(svg: dark.svg, size: size, opaque: false),
              let pdf = try await pdf(svg: light.svg, size: size) else { throw RenderError.failed }
        return Images(light: lightPNG, dark: darkPNG, pdf: pdf, size: size)
    }

    private static let margin: CGFloat = 12

    private func page(svg: String, size: CGSize, opaque: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:\(opaque ? "#ffffff" : "transparent");overflow:hidden}
        #c{padding:\(Int(Self.margin))px;width:\(Int(ceil(size.width)))px}
        #c svg{display:block;width:\(Int(ceil(size.width)))px;height:\(Int(ceil(size.height)))px;max-width:none}
        </style></head><body><div id="c">\(svg)</div></body></html>
        """
    }

    private func load(svg: String, size: CGSize, opaque: Bool = false) async -> WKWebView {
        let pageSize = NSSize(width: ceil(size.width) + 2 * Self.margin, height: ceil(size.height) + 2 * Self.margin)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: pageSize))
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(page(svg: svg, size: size, opaque: opaque), baseURL: nil)
        }
        // A moment for the fonts and the layout.
        try? await Task.sleep(for: .milliseconds(80))
        return webView
    }

    private func png(svg: String, size: CGSize, opaque: Bool) async throws -> Data? {
        let webView = await load(svg: svg, size: size, opaque: opaque)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: webView.frame.size)
        configuration.snapshotWidth = NSNumber(value: Double(webView.frame.width * 2))
        configuration.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func pdf(svg: String, size: CGSize) async throws -> Data? {
        let webView = await load(svg: svg, size: size)
        let configuration = WKPDFConfiguration()
        configuration.rect = NSRect(origin: .zero, size: webView.frame.size)
        return try await webView.pdf(configuration: configuration)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading() }
    }

    private func finishLoading() {
        let continuation = loaded
        loaded = nil
        continuation?.resume()
    }
}
