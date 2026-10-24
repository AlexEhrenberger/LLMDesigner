// Draws slide designs the way the app does (WKWebView snapshot of the same page), optionally with sample text.
// swift render.swift <css folder> <out folder> [text|plain] [time in s] [name,name,…]
import AppKit
import WebKit

let args = CommandLine.arguments
let cssFolder = URL(fileURLWithPath: args[1])
let outFolder = URL(fileURLWithPath: args[2])
let withText = args.count > 3 && args[3] == "text"
let time = args.count > 4 ? Double(args[4]) ?? 0 : 0
let only: Set<String>? = args.count > 5 ? Set(args[5].split(separator: ",").map(String.init)) : nil
try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

func tones(_ css: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in css.components(separatedBy: "\n").prefix(12) {
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " *\t"))
        guard t.hasPrefix("@text") else { continue }
        let parts = t.split(separator: " ")
        guard parts.count >= 2 else { continue }
        let key = String(parts[0]), value = String(parts[1])
        if key == "@text" { for r in ["titel", "kapitel", "folie"] where result[r] == nil { result[r] = value } }
        else { result[String(key.dropFirst(6))] = value }
    }
    return result
}

func sample(_ role: String, dark: Bool) -> String {
    let color = dark ? "#16161a" : "#ffffff"
    let base = "position:absolute;font-family:-apple-system,Helvetica;color:\(color);"
    switch role {
    case "titel":
        return "<div style='\(base)inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center'><div style='font-size:5vw;font-weight:700'>Wie Gehirne Vorhersagen machen</div><div style='font-size:2.2vw;margin-top:1.4vw;opacity:.8'>Eine Einführung in Predictive Coding</div></div>"
    case "kapitel":
        return "<div style='\(base)left:6.4%;top:0;bottom:0;display:flex;flex-direction:column;justify-content:center'><div style='font-size:1.8vw;opacity:.7'>Kapitel 2</div><div style='font-size:4.4vw;font-weight:700'>Fehler als Signal</div></div>"
    default:
        let items = ["Das Gehirn sagt Sinnesdaten voraus", "Nur die Abweichung wird weitergeleitet", "Lernen heißt, die Vorhersage zu verbessern", "Aufmerksamkeit gewichtet die Fehler", "Beispiel: der blinde Fleck"].map { "<li style='margin:.5vw 0'>\($0)</li>" }.joined()
        return "<div style='\(base)left:6.4%;right:6.4%;top:8.4%'><div style='font-size:3vw;font-weight:700'>Vorhersagefehler</div><ul style='font-size:1.9vw;line-height:1.35;margin-top:1.6vw;padding-left:2.2vw'>\(items)</ul></div>"
    }
}

func page(css: String, role: String, dark: Bool) -> String {
    let still = time > 0
        ? "html.still *, html.still *::before, html.still *::after { animation-play-state: paused !important; animation-delay: -\(time)s !important; }"
        : "html.still *, html.still *::before, html.still *::after { animation-play-state: paused !important; transition: none !important; }"
    return """
    <!doctype html><html class="still"><head><meta charset="utf-8"><style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }
    body { position: relative; -webkit-font-smoothing: antialiased; }
    .e { position: absolute; inset: 0; pointer-events: none; }
    \(still)
    </style><style>\(css)</style></head>
    <body class="\(role)"><div class="e e1"></div><div class="e e2"></div><div class="e e3"></div><div class="e e4"></div><div class="e e5"></div><div class="e e6"></div>\(withText ? sample(role, dark: dark) : "")</body></html>
    """
}

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var loaded: CheckedContinuation<Void, Never>?

    override init() {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        super.init()
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    func draw(_ html: String) async -> NSImage? {
        await withCheckedContinuation { c in loaded = c; view.loadHTMLString(html, baseURL: nil) }
        try? await Task.sleep(for: .milliseconds(150))
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 960, height: 540)
        config.snapshotWidth = 960
        config.afterScreenUpdates = true
        return await withCheckedContinuation { c in view.takeSnapshot(with: config) { image, _ in c.resume(returning: image) } }
    }
}

func save(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let renderer = Renderer()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: cssFolder.path))?.filter { $0.hasSuffix(".css") }.sorted() ?? []
    for name in names {
        let id = String(name.dropLast(4))
        if let only, !only.contains(id) { continue }
        guard let css = try? String(contentsOf: cssFolder.appendingPathComponent(name), encoding: .utf8) else { continue }
        let tone = tones(css)
        for role in ["titel", "kapitel", "folie"] {
            let dark = tone[role] == "dunkel"
            if let image = await renderer.draw(page(css: css, role: role, dark: dark)) {
                save(image, to: outFolder.appendingPathComponent("\(id)-\(role).png"))
            }
        }
        print("drawn \(id)")
    }
    exit(0)
}
app.run()
