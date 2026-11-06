import AppKit
import SwiftUI

/// A borderless panel in front of all apps, like Spotlight: it takes the keyboard without making LLM Designer the
/// active app, so the app the person works in stays where it is.
final class QuickBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The window server draws the shadow from the rounded content; much cheaper than a shadow in SwiftUI.
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Opens and closes the search bar; the global shortcut, the menu bar and the Chat menu call it.
@MainActor
final class QuickBarController: NSObject, NSWindowDelegate {
    static let shared = QuickBarController()
    /// How long the panel fades in and out; the window fades as a whole, shadow included.
    static let fadeDuration = 0.16

    /// Lets the bar open the main window when it is closed; set by the main window's view.
    var openWindow: OpenWindowAction?

    private var panel: QuickBarPanel?
    private weak var model: AppModel?
    /// Where the person dragged the bar (top centre); it opens there again while the app runs.
    private var movedTo: CGPoint?
    /// The bar is resizing itself, not being dragged.
    private var isFitting = false

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
        let appearing = !panel.isVisible || panel.alphaValue < 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 1
            }
        }
        // One turn later, so the view sees the change and plays its entrance.
        DispatchQueue.main.async { app.quickBar.isShown = true }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        if let app, app.isDictatingIntoQuickBar { Task { await app.stopDictation() } }
        app?.quickBar.isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // Opened again while fading: it stays.
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

    /// The SwiftUI content reports its size; the panel follows and grows downwards, its top edge staying in place.
    func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        isFitting = true
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        isFitting = false
        panel.invalidateShadow()
    }

    // MARK: Window delegate

    /// Clicking elsewhere closes the bar, as Spotlight does. The answer or job goes on; opening the bar shows it again.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, !isFitting, panel.isVisible else { return }
        movedTo = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
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

    /// Where it was dragged to, if that is still on a screen; otherwise the upper third of the screen with the mouse,
    /// centred, as Spotlight sits.
    private func position(_ panel: QuickBarPanel) {
        let size = panel.frame.size
        var anchor: CGPoint
        if let movedTo, NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(movedTo) }) {
            anchor = movedTo
        } else {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            anchor = CGPoint(x: visible.midX, y: visible.maxY - visible.height * 0.16)
        }
        isFitting = true
        panel.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height), display: false)
        isFitting = false
    }
}
