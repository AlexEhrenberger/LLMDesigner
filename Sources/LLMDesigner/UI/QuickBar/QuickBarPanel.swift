import AppKit
import SwiftUI

/// A borderless panel in front of all apps, like Spotlight: it takes the keyboard without making LLM Designer the
/// active app, so the app the person works in stays where it is.
final class QuickBarPanel: NSPanel {
    /// The bar grows downwards: its top edge stays where it opened.
    var pinnedTop: CGFloat?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The glow is the shadow; a window shadow would draw a grey box around the transparent margin.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let pinnedTop { frame.origin.y = pinnedTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Opens and closes the search bar; the global shortcut, the menu bar and the Chat menu call it.
@MainActor
final class QuickBarController: NSObject, NSWindowDelegate {
    static let shared = QuickBarController()
    /// How long the bar takes to fade out before the panel goes.
    static let hideDelay = 0.2

    /// Lets the bar open the main window when it is closed; set by the main window's view.
    var openWindow: OpenWindowAction?

    private var panel: QuickBarPanel?
    private weak var model: AppModel?

    private var app: AppModel? { LibrarySession.shared?.app }

    /// Starts the global shortcut with the open library's setting.
    func start() {
        GlobalHotKey.shared.start { [weak self] in self?.toggle() }
        libraryChanged()
    }

    /// Another library has its own setting and its own chats: the bar starts over with them.
    func libraryChanged() {
        if let panel, panel.isVisible { panel.orderOut(nil) }
        panel = nil
        model?.quickBar.isShown = false
        guard let app else { return }
        model = app
        app.quickBar.onShortcutChange = { [weak app] in
            guard let app else { return }
            GlobalHotKey.shared.register(app.quickBar.activeShortcut)
        }
        GlobalHotKey.shared.register(app.quickBar.activeShortcut)
    }

    var isShown: Bool { panel?.isVisible == true && app?.quickBar.isShown == true }

    func toggle() {
        if isShown, panel?.isKeyWindow == true { hide() } else { show() }
    }

    func show() {
        guard let app else { return }
        if model !== app { libraryChanged() }
        let panel = self.panel ?? makePanel(for: app)
        app.prepareQuickBar()
        if !panel.isVisible {
            position(panel)
            app.quickBar.isShown = false
        }
        panel.makeKeyAndOrderFront(nil)
        // One turn later, so the view sees the change and plays its entrance.
        DispatchQueue.main.async { app.quickBar.isShown = true }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        app?.quickBar.isShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay) { [weak self, weak panel] in
            guard let panel, self?.app?.quickBar.isShown != true else { return }
            panel.orderOut(nil)
        }
    }

    /// Shows the bar's chat in the main window and leaves the bar.
    func openInMainWindow() {
        guard let app else { return }
        app.openQuickBarInMainWindow()
        hide()
        if let window = MainWindow.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
        NSApp.activate()
    }

    /// The SwiftUI content reports its size; the panel follows, its top edge staying in place.
    func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
    }

    // MARK: Window delegate

    /// Clicking elsewhere closes the bar, as Spotlight does; while it works it stays, glowing, so the person sees it.
    func windowDidResignKey(_ notification: Notification) {
        guard app?.isQuickBarGenerating != true else { return }
        hide()
    }

    // MARK: Private

    private func makePanel(for app: AppModel) -> QuickBarPanel {
        let panel = QuickBarPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        let root = QuickBarView(
            onSize: { [weak self] size in self?.fit(size) },
            onClose: { [weak self] in self?.hide() },
            onOpenMain: { [weak self] in self?.openInMainWindow() }
        )
        .environment(app)
        .environment(LibrarySession.shared!)
        let host = NSHostingView(rootView: AnyView(root))
        // The panel takes the size the content reports (`fit`); the view doesn't push it around itself.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Upper third of the screen with the mouse, centred, as Spotlight sits.
    private func position(_ panel: QuickBarPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let top = visible.maxY - visible.height * 0.16 + QuickBarView.glowMargin
        panel.pinnedTop = top
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: false)
    }
}
