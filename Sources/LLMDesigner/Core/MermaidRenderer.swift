import WebKit

/// Renders Mermaid code to SVG with the bundled mermaid.js, in one hidden web view for all diagrams. Results are
/// kept by code and colours, so switching between document and analysis doesn't draw them again.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    struct Result: Hashable, Sendable {
        let svg: String
        /// The diagram's natural size (its viewBox).
        let size: CGSize
    }

    enum RenderError: LocalizedError {
        case missingLibrary
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingLibrary: "mermaid.js fehlt im App-Paket."
            case .failed(let message): "Das Diagramm ließ sich nicht zeichnen: \(message)"
            }
        }
    }

    /// Where the library is: next to the app's other resources (see scripts/build-app.sh).
    nonisolated static var libraryURL: URL? {
        if let path = ProcessInfo.processInfo.environment["LLMD_MERMAID_JS"] { return URL(fileURLWithPath: path) }
        return Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
    }

    private var webView: WKWebView?
    private var isLoaded = false
    private var waitingForLoad: [CheckedContinuation<Void, Error>] = []
    private var cache: [String: Result] = [:]
    private var counter = 0
    /// Renders run one after another: each sets the colours before it draws.
    private var lastRender: Task<Void, Never>?

    func cached(_ code: String, palette: MermaidPalette) -> Result? {
        cache[cacheKey(code, palette)]
    }

    func render(_ code: String, palette: MermaidPalette) async throws -> Result {
        let key = cacheKey(code, palette)
        if let result = cache[key] { return result }
        let previous = lastRender
        let task = Task { @MainActor () -> Result in
            await previous?.value
            if let result = cache[key] { return result }
            try await loadIfNeeded()
            let result = try await draw(code, palette: palette)
            cache[key] = result
            return result
        }
        lastRender = Task { _ = try? await task.value }
        return try await task.value
    }

    private func draw(_ code: String, palette: MermaidPalette) async throws -> Result {
        guard let webView else { throw RenderError.missingLibrary }
        counter += 1
        var config: [String: Any] = [
            "startOnLoad": false,
            "securityLevel": "strict",
            "theme": "base",
            "themeVariables": palette.themeVariables,
            "fontFamily": palette.themeVariables["fontFamily"] ?? "sans-serif",
            "flowchart": ["htmlLabels": true, "curve": "basis", "padding": 14, "nodeSpacing": 26, "rankSpacing": 42, "wrappingWidth": 230],
            "mindmap": ["padding": 14, "maxNodeWidth": 230],
        ]
        // A diagram with a theme of its own (Writer Studio's Mermaid editor) gets Mermaid's colours, not the app's.
        if WriterMermaid.style(of: code).theme != nil {
            config["theme"] = "default"
            config["themeVariables"] = nil
            config["fontFamily"] = "-apple-system, Helvetica Neue, sans-serif"
        }
        let script = """
        mermaid.initialize(config);
        try {
            const result = await mermaid.render(id, code);
            return result.svg;
        } catch (error) {
            document.getElementById(id)?.remove();
            document.getElementById('d' + id)?.remove();
            throw new Error(String(error && error.message ? error.message : error));
        }
        """
        do {
            let value = try await webView.callAsyncJavaScript(
                script, arguments: ["config": config, "code": code, "id": "diagramm\(counter)"], contentWorld: .page
            )
            guard let svg = value as? String, !svg.isEmpty else { throw RenderError.failed("leere Ausgabe") }
            return Result(svg: svg, size: Self.viewBoxSize(of: svg))
        } catch let error as RenderError {
            throw error
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw RenderError.failed(message.components(separatedBy: "\n").first ?? message)
        }
    }

    private func loadIfNeeded() async throws {
        if isLoaded { return }
        if webView == nil {
            guard let url = Self.libraryURL, let library = try? String(contentsOf: url, encoding: .utf8) else {
                throw RenderError.missingLibrary
            }
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(
                WKUserScript(source: library, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
            // Wide enough that labels are measured at their natural width.
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            webView.loadOfflineHTML("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>")
        }
        try await withCheckedThrowingContinuation { waitingForLoad.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(error) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page is gone; the next render loads it again.
        MainActor.assumeIsolated {
            isLoaded = false
            self.webView = nil
        }
    }

    private func finishLoading(_ error: Error?) {
        isLoaded = error == nil
        if error != nil { webView = nil }
        let waiting = waitingForLoad
        waitingForLoad = []
        for continuation in waiting {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    private func cacheKey(_ code: String, _ palette: MermaidPalette) -> String {
        (palette.isLight ? "L" : "D") + code
    }

    /// `viewBox="x y w h"` → (w, h).
    nonisolated static func viewBoxSize(of svg: String) -> CGSize {
        guard let range = svg.range(of: #"viewBox="[^"]+""#, options: .regularExpression) else { return CGSize(width: 600, height: 400) }
        let numbers = svg[range].dropFirst(9).dropLast().split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return CGSize(width: 600, height: 400) }
        return CGSize(width: numbers[2], height: numbers[3])
    }
}
