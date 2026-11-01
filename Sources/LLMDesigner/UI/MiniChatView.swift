import AppKit
import SwiftUI

/// The mini chat's window (see `MiniChat`).
@MainActor
enum MiniChatWindow {
    static let id = "mini-chat"
    static let minSize = CGSize(width: 320, height: 420)
    static weak var window: NSWindow?
}

private struct MiniChatIDKey: EnvironmentKey {
    static let defaultValue: Chat.ID? = nil
}

extension EnvironmentValues {
    /// Set in the mini chat's message list: the messages' buttons act on that chat instead of the main window's.
    var miniChatID: Chat.ID? {
        get { self[MiniChatIDKey.self] }
        set { self[MiniChatIDKey.self] = newValue }
    }
}

/// Opens a chat in the mini chat (nil: a new chat there) and brings its window to the front.
@MainActor
struct OpenInMiniChat {
    let app: AppModel
    let openWindow: OpenWindowAction

    func callAsFunction(_ chatID: Chat.ID?) {
        app.showInMiniChat(chatID)
        openWindow(id: MiniChatWindow.id)
    }
}

struct MiniChatView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mini = app.miniChat
        VStack(spacing: 0) {
            MiniChatTopBar()
            if let chat = app.currentMiniChat, !chat.messages.isEmpty {
                MessageList(
                    chat: chat,
                    streamingID: app.streamingMessageIDs[chat.id],
                    exportingIDs: app.exportingIDs,
                    scrollRequest: nil,
                    highlight: nil,
                    isCompact: true
                )
                .id(chat.id)
                .environment(\.miniChatID, chat.id)
            } else {
                MiniChatWelcome()
            }
            MiniChatComposer()
        }
        .frame(minWidth: MiniChatWindow.minSize.width, minHeight: MiniChatWindow.minSize.height)
        .background(Theme.background)
        .ignoresSafeArea()
        .background(MiniChatWindowConfigurator(floats: mini.floats) { mini.isKey = $0 })
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { mini.isOpen = true }
        .onDisappear {
            mini.isOpen = false
            mini.isKey = false
        }
    }
}

// MARK: Top bar

private struct MiniChatTopBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let mini = app.miniChat
        HStack(spacing: 2) {
            // Only text: the window is dragged by its title, as in any title bar.
            Text(app.currentMiniChat?.title ?? "Neuer Chat")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 7)
                .allowsHitTesting(false)
            Spacer(minLength: 4)
            FloatToggle(isOn: mini.floats) { mini.floats.toggle() }
            IconButton(systemName: "macwindow", help: "Im Hauptfenster öffnen", size: 13, frameSize: Theme.titleBarControlSize) {
                app.openMiniChatInMainWindow()
                openWindow(id: "main")
            }
            .disabled(app.currentMiniChat == nil)
            .opacity(app.currentMiniChat == nil ? 0.4 : 1)
            IconButton(systemName: "square.and.pencil", help: "Neuer Chat im Mini-Chat", size: 13, frameSize: Theme.titleBarControlSize) {
                app.showInMiniChat(nil)
            }
        }
        .padding(.leading, Theme.trafficLightInset - 6)
        .padding(.trailing, 8)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, 4)
        .background(WindowDragArea())
    }
}

/// The pin: the window stays in front of all others, also while working in the main window or another app.
private struct FloatToggle: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.accent.opacity(0.14) : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Nicht mehr im Vordergrund halten" : "Immer im Vordergrund – auch vor dem Hauptfenster und anderen Apps")
    }
}

// MARK: Empty chat

private struct MiniChatWelcome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 16)
            LogoMark(size: 40)
            Text("Mini-Chat")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Frag nebenbei – oder zeig dem Modell mit „Bildschirm betrachten“, woran du gerade arbeitest.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let model = app.miniChatModel {
                HStack(spacing: 6) {
                    StatusDot(color: model.isLoaded ? Theme.success : Theme.warning, size: 6)
                    Text(model.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 2)
            } else if case .failed = app.connection {
                Text("\(app.provider.label) ist nicht erreichbar.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Composer

private struct MiniChatComposer: View {
    @Environment(AppModel.self) private var app
    @State private var textHeight: CGFloat = 20
    @State private var width: CGFloat = Theme.powerWidth

    var body: some View {
        @Bindable var mini = app.miniChat

        VStack(spacing: 8) {
            if let notice = mini.notice {
                MiniChatNoticeView(notice: notice) { mini.notice = nil }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            VStack(alignment: .leading, spacing: 8) {
                if !mini.images.isEmpty || mini.importing > 0 {
                    AttachmentStrip(images: mini.images, importing: mini.importing, onRemove: app.removeMiniChatImage)
                }
                ComposerTextView(
                    text: $mini.draft,
                    height: $textHeight,
                    focusToken: mini.focusToken,
                    onSubmit: { if app.canSendMiniChat { app.sendMiniChat() } },
                    onImages: { app.attachMiniChatImages($0) }
                )
                .frame(height: min(max(textHeight, 20), 180))
                .overlay(alignment: .topLeading) {
                    if mini.draft.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }

                if mini.receivesDictation && app.dictationStatus != .idle {
                    DictationPreview()
                }
                HStack(spacing: 4) {
                    IconButton(systemName: "photo.badge.plus", help: "Bilder anhängen (⇧⌘A) – oder einfügen (⌘V)", size: 14) {
                        app.chooseImages(forMiniChat: true)
                    }
                    // The name goes when the row would run out of room (the thinking pill is wider when on).
                    ScreenGlanceButton(showsTitle: width >= (app.isMiniChatThinkingOn ? 430 : 370))
                    ComposerToggle(
                        title: "Denken",
                        isOn: app.isMiniChatThinkingOn,
                        isAvailable: true,
                        helpOn: "Denkmodus ausschalten (⇧⌘T)",
                        helpOff: "Denkmodus einschalten (⇧⌘T): Das Modell denkt nach, bevor es antwortet",
                        action: app.toggleMiniChatThinking
                    ) {
                        Image(systemName: "brain").font(.system(size: 14, weight: .medium))
                    }
                    if app.isDictationAvailable {
                        DictationButton(intoMiniChat: true)
                    }
                    Spacer(minLength: 0)
                    SendButton(
                        isGenerating: app.isMiniChatGenerating,
                        canSend: app.canSendMiniChat || (app.isDictating && mini.receivesDictation),
                        onSend: app.sendMiniChat,
                        onStop: app.stopMiniChat
                    )
                }
                .padding(.leading, -6)
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.strongBorder))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
                .offset(y: -20)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: mini.notice)
    }

    private var placeholder: String {
        if !app.miniChat.images.isEmpty { return "Frage zum Bild …" }
        return app.miniChatModel.map { "Nachricht an \($0.displayName)" } ?? "Nachricht schreiben"
    }
}

/// "Bildschirm betrachten": attaches a picture of the screen (without the mini chat) to the message. With several
/// screens, a right-click chooses which one.
private struct ScreenGlanceButton: View {
    @Environment(AppModel.self) private var app
    let showsTitle: Bool
    @State private var hovering = false

    var body: some View {
        let isGlancing = app.miniChat.isGlancing
        let screens = NSScreen.screens
        Button { app.glanceAtScreen() } label: {
            HStack(spacing: 6) {
                if isGlancing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .medium))
                }
                if showsTitle {
                    Text("Bildschirm betrachten")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, showsTitle ? 11 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .background(Capsule().fill(hovering ? Theme.hover : Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isGlancing)
        .onHover { hovering = $0 }
        .contextMenu {
            if screens.count > 1 {
                ForEach(Array(screens.enumerated()), id: \.offset) { _, screen in
                    Button(screen.localizedName) { app.glanceAtScreen(screen) }
                }
            }
        }
        .help("Bildschirm betrachten (⇧⌘B): Ein Bildschirmfoto – ohne dieses Fenster – kommt an die Nachricht, damit das Modell sieht, woran du arbeitest."
              + (screens.count > 1 ? " Rechtsklick: Bildschirm wählen." : ""))
    }
}

private struct MiniChatNoticeView: View {
    let notice: MiniChatNotice
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isPermission ? "eye.trianglebadge.exclamationmark" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 7) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isPermission {
                    Button("Systemeinstellungen öffnen") { ScreenGlance.openSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Schließen")
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.25)))
    }

    private var isPermission: Bool { notice == .screenPermission }

    private var text: String {
        switch notice {
        case .screenPermission:
            "Damit das Modell deinen Bildschirm sehen kann, braucht LLM Designer die Erlaubnis zur Bildschirmaufnahme "
                + "(Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme). Danach LLM Designer neu starten."
        case .text(let message):
            message
        }
    }
}

// MARK: Window

/// Like `WindowConfigurator` for the main window: content under the transparent title bar, a black background. It also
/// keeps the window floating if wanted and reports whether it is the key window (for the Chat menu).
private struct MiniChatWindowConfigurator: NSViewRepresentable {
    let floats: Bool
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.onKeyChange = onKeyChange
        view.floats = floats
    }

    final class ConfiguringView: NSView {
        var onKeyChange: ((Bool) -> Void)?
        var floats = true {
            didSet { applyLevel() }
        }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(Theme.background)
            // Can stand beside a main window in full screen.
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            MiniChatWindow.window = window
            applyLevel()
            for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKeyChange?(isKey) }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onKeyChange?(window.isKeyWindow)
            }
        }

        private func applyLevel() {
            window?.level = floats ? .floating : .normal
        }
    }
}
