import Testing
import AppKit
import WebKit
@testable import LLMDesigner

/// Draws the generated flow charts with mermaid.js (needs the window server; skipped where the render fails to start).
@Suite("Flussdiagramme zeichnen")
@MainActor
struct FlowRenderingTests {
    static let python = """
    import math

    def klassifiziere(werte, grenze=10):
        \"\"\"Sortiert Zahlen.\"\"\"
        ergebnis = []
        summe = 0
        for x in werte:
            if x < 0:
                continue
            elif x > grenze:
                ergebnis.append("gross")
                break
            summe += x
        try:
            wurzel = math.sqrt(summe)
        except ValueError as fehler:
            print("Fehler", fehler)
            raise
        finally:
            print("fertig")
        while summe > 100:
            summe -= 10
        return ergebnis, wurzel
    """

    static let sql = """
    WITH aktive AS (SELECT id, name FROM kunden WHERE aktiv = 1)
    SELECT a.name, COUNT(*) AS n, SUM(b.betrag) AS summe
    FROM aktive a
    LEFT JOIN bestellungen b ON b.kunde_id = a.id
    JOIN (SELECT kunde_id, MAX(datum) AS zuletzt FROM bestellungen GROUP BY kunde_id) t ON t.kunde_id = a.id
    WHERE b.datum >= '2024-01-01' AND b.status <> 'storniert'
    GROUP BY a.name
    HAVING SUM(b.betrag) > 100
    ORDER BY summe DESC
    LIMIT 10;
    """

    private func snapshot(svg: String, size: CGSize, to url: URL) async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: ceil(size.width) + 40, height: ceil(size.height) + 40))
        webView.loadHTMLString("<html><body style=\"margin:20px;background:#fff\">\(svg)</body></html>", baseURL: nil)
        try await Task.sleep(for: .seconds(1.2))
        let image = try await webView.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: url)
        }
    }

    @Test func rendersPythonAndSQL() async throws {
        guard FileManager.default.fileExists(atPath: "Resources/Mermaid/mermaid.min.js") else { return }
        setenv("LLMD_MERMAID_JS", FileManager.default.currentDirectoryPath + "/Resources/Mermaid/mermaid.min.js", 1)
        _ = NSApplication.shared
        var graphs = PythonFlow.graphs(for: Self.python) + SQLFlow.graphs(for: Self.sql)
        graphs += PythonFlow.graphs(for: "total = 0\nfor n in range(5):\n    total += n\nprint(total)")
        for (index, graph) in graphs.enumerated() {
            let code = graph.mermaid(palette: .light)
            let result: MermaidRenderer.Result
            do {
                result = try await MermaidRenderer.shared.render(code, palette: .light)
            } catch {
                Issue.record("Diagramm \(graph.title) ließ sich nicht zeichnen: \(error)\n\(code)")
                continue
            }
            #expect(result.size.width > 50)
            if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
                try await snapshot(svg: result.svg, size: result.size, to: URL(fileURLWithPath: directory).appendingPathComponent("flow-\(index).png"))
            }
        }
    }
}
