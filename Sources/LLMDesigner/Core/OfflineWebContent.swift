import WebKit

/// The app's web views show its own pages: diagrams and slide designs, sometimes from a design file or a document of
/// someone else. Such a page must not fetch anything: an image address could carry data out, or tell a server that the
/// document was opened. So network addresses are blocked for every page.
@MainActor
enum OfflineWebContent {
    static let rulesJSON = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
    ]
    """

    private static var list: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var isCompiling = false

    /// Calls back with the compiled rules, compiling them once. The store is a temporary folder: the rules are made
    /// from this text in a moment, and nothing of the app belongs in `~/Library/WebKit`.
    static func whenReady(_ body: @escaping (WKContentRuleList?) -> Void) {
        if let list { return body(list) }
        waiting.append(body)
        guard !isCompiling else { return }
        isCompiling = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesigner-WebRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return finish(nil) }
        store.compileContentRuleList(forIdentifier: "offline", encodedContentRuleList: rulesJSON) { compiled, error in
            if let error { print("LLMDesigner: Web-Regeln: \(error.localizedDescription)") }
            MainActor.assumeIsolated { finish(compiled) }
        }
    }

    private static func finish(_ compiled: WKContentRuleList?) {
        list = compiled
        isCompiling = false
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(compiled) }
    }
}

extension WKWebView {
    /// Loads a page with network addresses blocked. Without the rules nothing is shown: a missing diagram is better
    /// than a page that can reach out.
    func loadOfflineHTML(_ html: String) {
        OfflineWebContent.whenReady { [weak self] list in
            guard let self, let list else { return }
            self.configuration.userContentController.remove(list)
            self.configuration.userContentController.add(list)
            self.loadHTMLString(html, baseURL: nil)
        }
    }
}

extension SlideDesign {
    /// A design file without external addresses: `url(https://…)` and `@import`. The web view blocks them anyway; this
    /// keeps a page from waiting for something that never comes.
    static func removingExternalResources(_ css: String) -> String {
        var result = css.replacingOccurrences(of: #"(?i)@import\s+[^;]*(https?:|//)[^;]*;"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)url\(\s*['"]?\s*(https?:|wss?:|ftp:|//)[^)]*\)"#, with: "none", options: .regularExpression)
        return result
    }
}
