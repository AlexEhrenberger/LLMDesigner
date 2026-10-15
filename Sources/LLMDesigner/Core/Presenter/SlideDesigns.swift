import AppKit
import WebKit

/// A slide background written in CSS. Each design is one `.css` file: the app's own lie in the app bundle
/// (`Resources/SlideDesigns`), more can be put into the library (`Präsentationen/Designs`). The file starts with a
/// comment that names the design and says which text colour fits:
///
///     /*
///      * @name Aurora
///      * @beschreibung Polarlicht über einem Nachthimmel
///      * @text hell                (hell: helle Schrift, dunkel: dunkle Schrift)
///      * @text-folie hell          (optional, je Folienart: titel, kapitel, folie)
///      * @akzent #7CF0D0
///      */
///
/// The stage it draws on (see `html(role:live:)`) is a 16:9 page whose `body` has the class `titel`, `kapitel` or
/// `folie` and holds six empty layers `.e1` … `.e6` (each with `::before` and `::after`). Sizes in `vw`, `vh` or
/// `vmin` scale with the slide. Animations run in the presentation and stand still in the editor.
struct SlideDesign: Identifiable, Hashable, Sendable {
    static let defaultID = "aurora"

    let id: String
    var name: String
    var summary: String
    var css: String
    var tones: [SlideRole: SlideTone]
    var accent: UInt32?
    var isBuiltIn: Bool

    func tone(for role: SlideRole) -> SlideTone {
        tones[role] ?? tones[.content] ?? .light
    }

    /// The page the design is drawn on; `live` lets its animations run.
    func html(role: SlideRole, live: Bool) -> String {
        """
        <!doctype html>
        <html class="\(live ? "live" : "still")">
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }
        body { position: relative; -webkit-font-smoothing: antialiased; }
        .e { position: absolute; inset: 0; pointer-events: none; }
        html.still *, html.still *::before, html.still *::after { animation-play-state: paused !important; transition: none !important; }
        </style>
        <style>
        \(css)
        </style>
        </head>
        <body class="\(role.rawValue)">
        <div class="e e1"></div><div class="e e2"></div><div class="e e3"></div><div class="e e4"></div><div class="e e5"></div><div class="e e6"></div>
        </body>
        </html>
        """
    }

    /// Reads the comment at the top of a design file.
    static func parse(id: String, css: String, isBuiltIn: Bool) -> SlideDesign {
        var design = SlideDesign(id: id, name: id.capitalized, summary: "", css: css, tones: [:], accent: nil, isBuiltIn: isBuiltIn)
        guard let start = css.range(of: "/*"), let end = css.range(of: "*/", range: start.upperBound..<css.endIndex) else { return design }
        for rawLine in css[start.upperBound..<end.lowerBound].components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " *\t"))
            guard line.hasPrefix("@"), let space = line.firstIndex(of: " ") else { continue }
            let key = line[line.index(after: line.startIndex)..<space].lowercased()
            let value = line[space...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": design.name = value
            case "beschreibung", "description": design.summary = value
            case "akzent", "accent": design.accent = SlideBackground.hex(value)
            case "text": design.tones[.content] = tone(value)
            case "text-titel": design.tones[.title] = tone(value)
            case "text-kapitel": design.tones[.chapter] = tone(value)
            case "text-folie": design.tones[.content] = tone(value)
            default: break
            }
        }
        // "@text" is the default for every kind of slide.
        if let base = design.tones[.content] {
            for role in SlideRole.allCases where design.tones[role] == nil { design.tones[role] = base }
        }
        return design
    }

    private static func tone(_ value: String) -> SlideTone {
        let word = value.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return ["dunkel", "dark", "schwarz"].contains(word) ? .dark : .light
    }
}

/// The designs there are: the app's own and the library's. The library's folder is read again when it changed.
@MainActor
@Observable
final class SlideDesignLibrary {
    static let shared = SlideDesignLibrary()

    private(set) var designs: [SlideDesign] = []
    @ObservationIgnored private var loadedFolder: URL?
    @ObservationIgnored private var loadedStamp: Date?

    /// Where the app's own designs are: next to its other resources (see scripts/build-app.sh).
    nonisolated static var builtInFolder: URL? {
        if let path = ProcessInfo.processInfo.environment["LLMD_SLIDE_DESIGNS"] { return URL(fileURLWithPath: path) }
        return Bundle.main.resourceURL?.appendingPathComponent("SlideDesigns", isDirectory: true)
    }

    /// The library's own designs; the folder is only made when the user opens it.
    static var userFolder: URL {
        AppLibrary.current.url.appendingPathComponent("Präsentationen/Designs", isDirectory: true)
    }

    func design(_ id: String?) -> SlideDesign? {
        reloadIfNeeded()
        guard let id else { return nil }
        return designs.first { $0.id == id }
    }

    var all: [SlideDesign] {
        reloadIfNeeded()
        return designs
    }

    func reloadIfNeeded() {
        let folder = Self.userFolder
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
        guard designs.isEmpty || loadedFolder != folder || loadedStamp != stamp else { return }
        loadedFolder = folder
        loadedStamp = stamp
        var result = Self.load(from: Self.builtInFolder, isBuiltIn: true)
        let own = Self.load(from: folder, isBuiltIn: false)
        // A library's design with the same name replaces the app's.
        result.removeAll { design in own.contains { $0.id == design.id } }
        result += own
        if result != designs { designs = result }
    }

    /// Makes the library's folder (with the instructions and an example to start from) and shows it in the Finder.
    func revealUserFolder() {
        let folder = Self.userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let builtIn = Self.builtInFolder {
            for name in ["LIESMICH.md"] where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                try? FileManager.default.copyItem(at: builtIn.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            let example = folder.appendingPathComponent("eigenes-design.css")
            let hasCSS = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix(".css") }
            if !hasCSS { try? FileManager.default.copyItem(at: builtIn.appendingPathComponent("aurora.css"), to: example) }
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        loadedStamp = nil
    }

    private static func load(from folder: URL?, isBuiltIn: Bool) -> [SlideDesign] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let order = ["aurora", "prisma", "blaupause", "schiefer", "morgenrot", "papier", "bauhaus"]
        return names.filter { $0.hasSuffix(".css") }
            .compactMap { name -> SlideDesign? in
                guard let css = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
                return SlideDesign.parse(id: String(name.dropLast(4)), css: css, isBuiltIn: isBuiltIn)
            }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.id) ?? Int.max
                let ib = order.firstIndex(of: b.id) ?? Int.max
                return ia == ib ? a.name.localizedStandardCompare(b.name) == .orderedAscending : ia < ib
            }
    }
}

/// Draws the designs as pictures (for the editor, the slide list and the PDF), in one hidden web view. Pictures are
/// kept by design, role and width; views asking for one that isn't there yet are told when it is.
@MainActor
@Observable
final class SlideDesignRenderer: NSObject, WKNavigationDelegate {
    static let shared = SlideDesignRenderer()

    /// Points of the page the design is drawn on; the picture has twice as many pixels.
    static let pageSize = CGSize(width: 960, height: 540)

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var loaded: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var lastRender: Task<Void, Never>?

    private func key(_ design: SlideDesign, _ role: SlideRole, _ width: CGFloat) -> String {
        "\(design.id)|\(role.rawValue)|\(Int(width))|\(design.css.hashValue)"
    }

    /// The picture if it is there; otherwise it is made, and views reading this see it once it is done.
    func image(_ design: SlideDesign, role: SlideRole, width: CGFloat = 960) -> NSImage? {
        let key = key(design, role, width)
        if let image = images[key] { return image }
        if requested.insert(key).inserted {
            Task { @MainActor in _ = await self.render(design, role: role, width: width) }
        }
        return nil
    }

    func render(_ design: SlideDesign, role: SlideRole, width: CGFloat = 960) async -> NSImage? {
        let key = key(design, role, width)
        if let image = images[key] { return image }
        requested.insert(key)
        let previous = lastRender
        let task = Task { @MainActor () -> NSImage? in
            await previous?.value
            if let image = self.images[key] { return image }
            let image = await self.draw(design.html(role: role, live: false), width: width)
            if let image { self.images[key] = image }
            return image
        }
        lastRender = Task { _ = await task.value }
        return await task.value
    }

    private func draw(_ html: String, width: CGFloat) async -> NSImage? {
        let size = Self.pageSize
        let webView = self.webView ?? {
            let view = WKWebView(frame: NSRect(origin: .zero, size: size))
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            self.webView = view
            return view
        }()
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // A moment for the layers with filters to be drawn.
        try? await Task.sleep(for: .milliseconds(60))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: size)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        configuration.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
    }

    private func finishLoading() {
        let continuation = loaded
        loaded = nil
        continuation?.resume()
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

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            finishLoading()
            self.webView = nil
        }
    }
}
