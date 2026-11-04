import Testing
import AppKit
import WebKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Einstellungen, Ereignisse, Installation", .serialized)
struct ActionSettingsTests {
    let h = ActionHarness()

    @Test func levelsArePerChannelAndKind() {
        let settings = h.app.settings
        let approval = h.registry.approval
        #expect(approval.level(channel: .cli, kind: .destructive, settings: settings) == .ask)
        approval.setLevel(.allow, channel: .cli, kind: .destructive, settings: settings)
        defer { approval.setLevel(.ask, channel: .cli, kind: .destructive, settings: settings) }
        #expect(approval.level(channel: .cli, kind: .destructive, settings: settings) == .allow)
        #expect(approval.level(channel: .mcp, kind: .destructive, settings: settings) == .ask)
    }

    @Test func aDeniedLevelStopsTheAction() async throws {
        let settings = h.app.settings
        h.registry.approval.setLevel(.deny, channel: .cli, kind: .write, settings: settings)
        defer { h.registry.approval.setLevel(.allow, channel: .cli, kind: .write, settings: settings) }
        #expect(await h.errorCode("writer.doc.create", ["title": "Gesperrt"]) == RPCError.deniedCode)
    }

    @Test func actionsSendEvents() async throws {
        var events: [ActionEvent] = []
        h.registry.eventSink = { events.append($0) }
        let id = try await h.document("Text.")
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Mehr."])
        #expect(events.contains { $0.kind == ActionEvent.documentChanged && $0.target == id && $0.channel == "cli" })
        #expect(events.contains { $0.kind == ActionEvent.actionExecuted && $0.action == "writer.text.insert" })
        let decoded = try JSONValue.encoding(events[0]).decoded(as: ActionEvent.self)
        #expect(decoded.kind == events[0].kind)
    }

    @Test func theOpenDocumentGetsAFlash() async throws {
        let id = try await h.document("Offen.")
        try await h.call("writer.doc.open", ["doc": .string(id)])
        h.app.actionFlash = nil
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Mehr."])
        #expect(h.app.actionFlash?.document.uuidString == id)
        #expect(h.app.actionFlash?.channel == .cli)
        try await h.call("writer.doc.close")
    }

    @Test func aClosedDocumentGetsNoFlash() async throws {
        h.app.actionFlash = nil
        let id = try await h.document("Zu.")
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Mehr."])
        #expect(h.app.actionFlash == nil)
    }

    @Test func theLinkIsMadeAndRenewedButNeverOverwritesAFile() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Link-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: base) }
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let helper = base.appendingPathComponent("llmd")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(throws: CLIInstaller.Failure.self) { try CLIInstaller.install(helper: helper, into: bin) }
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let link = try CLIInstaller.install(helper: helper, into: bin)
        #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == helper.path)
        try CLIInstaller.install(helper: helper, into: bin)

        try manager.removeItem(at: link)
        try Data("fremd".utf8).write(to: link)
        #expect(throws: CLIInstaller.Failure.self) { try CLIInstaller.install(helper: helper, into: bin) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "fremd")
    }
}

@MainActor
@Suite("Web-Ansichten laden nichts aus dem Netz", .serialized)
struct OfflineWebContentTests {
    @Test func cssLosesItsExternalAddresses() {
        let css = """
        @import url("https://evil.example/a.css");
        body { background: url(https://evil.example/x.png); color: red; }
        div { background-image: url( 'http://evil.example/y.png' ); }
        p { background: url(//evil.example/z.png); }
        span { background: url(data:image/png;base64,AAAA); }
        """
        let cleaned = SlideDesign.removingExternalResources(css)
        #expect(!cleaned.contains("evil.example"))
        #expect(cleaned.contains("color: red"))
        #expect(cleaned.contains("data:image/png"))
    }

    @Test func aParsedDesignIsClean() {
        let design = SlideDesign.parse(id: "x", css: "body{background:url(https://evil.example/x.png)}", isBuiltIn: false)
        #expect(!design.css.contains("evil.example"))
    }

    /// A tiny server on an ephemeral port, only here in the test, that counts who knocks.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let port: UInt16
        private let descriptor: Int32

        init() throws {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            descriptor = listener
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) } }
            listen(listener, 8)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }
            port = UInt16(bigEndian: address.sin_port)
            Thread.detachNewThread { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { return }
                    self?.lock.withLock { self?.count += 1 }
                    close(client)
                }
            }
        }

        var hits: Int { lock.withLock { count } }

        func stop() {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    private func wait(_ condition: () -> Bool, seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func aPageCannotFetchAnImage() async throws {
        _ = NSApplication.shared
        let counter = try Counter()
        defer { counter.stop() }
        let page = "<!doctype html><html><body><img src=\"http://127.0.0.1:\(counter.port)/bild.png\"></body></html>"

        let delegate = Loaded()
        let blocked = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        blocked.navigationDelegate = delegate
        blocked.loadOfflineHTML(page)
        await wait({ delegate.done }, seconds: 10)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(delegate.done)
        #expect(counter.hits == 0)

        // The same page without the rules does knock: the test sees what it claims to see.
        let openDelegate = Loaded()
        let open = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        open.navigationDelegate = openDelegate
        open.loadHTMLString(page, baseURL: nil)
        await wait({ counter.hits > 0 }, seconds: 10)
        #expect(counter.hits > 0)
    }
}
}
