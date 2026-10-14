import AppKit
import SwiftUI

/// Lets content run under the transparent title bar and paints the window background black.
/// No NSToolbar on purpose: with one, AppKit swallows clicks on SwiftUI controls in the
/// title bar area that appear after launch (e.g. the top bar buttons once the sidebar is hidden).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Closing the window during a conversation must not leave the narrow size as the saved frame.
            if closeObserver == nil {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { MainWindow.restoreBeforeQuit() }
                }
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(Theme.background)
            MainWindow.window = window
        }
    }
}

/// The main window, so conversation mode can make it narrow and give it back its size afterwards.
@MainActor
enum MainWindow {
    static weak var window: NSWindow?
    static let conversationMinSize = CGSize(width: 300, height: 420)
    private static var frameBeforeConversation: NSRect?
    private static let conversationSizeKey = "conversationWindowSize"

    /// Narrow window, top centre where it was; a size the user gave it last time is kept.
    static func shrinkForConversation() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        frameBeforeConversation = window.frame
        let saved = UserDefaults.standard.string(forKey: conversationSizeKey).map(NSSizeFromString)
        let size = saved.flatMap { $0.width >= conversationMinSize.width && $0.height >= conversationMinSize.height ? $0 : nil }
            ?? NSSize(width: 360, height: 560)
        var frame = NSRect(x: window.frame.midX - size.width / 2, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        // SwiftUI lowers the minimum size for the new content first.
        DispatchQueue.main.async {
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// Quitting or closing the window during a conversation: the window gets its old frame back without animation,
    /// so that frame is saved.
    static func restoreBeforeQuit() {
        guard let window, let previous = frameBeforeConversation, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: conversationSizeKey)
        window.setFrame(previous, display: false)
        frameBeforeConversation = nil
    }

    /// Back to the frame from before; `done` runs once the window has it (it is called right away if there is nothing to do).
    static func restoreAfterConversation(then done: @escaping () -> Void) {
        defer { frameBeforeConversation = nil }
        guard let window, let previous = frameBeforeConversation, !window.styleMask.contains(.fullScreen) else {
            done()
            return
        }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: conversationSizeKey)
        // Animates synchronously; the chat's minimum size only applies afterwards.
        window.setFrame(previous, display: true, animate: true)
        done()
    }
}
