import SwiftUI

/// The tab "Abspielen": the slide as the audience sees it, the controls, the next slide and the speaker notes with
/// the part being read. With the full-screen window open on a second screen, this is the presenter's view.
struct PresentationPlayView: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        let player = app.presentationPlayer
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 14) {
                PresentationStage(player: player, family: document.font)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PresentationControls(player: player, isFullScreen: false)
            }
            VStack(alignment: .leading, spacing: 14) {
                nextSlide(player)
                NotesPrompter(player: player)
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .onAppear {
            player.app = app
            player.prepare(document.id, at: app.currentSlideID(in: document))
        }
        .background {
            PresentationKeys(player: player, exitsFullScreen: false)
        }
    }

    @ViewBuilder
    private func nextSlide(_ player: PresentationPlayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nächste Folie")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            if let deck = player.deck, player.index + 1 < deck.slides.count {
                SlideThumbnail(slide: deck.slides[player.index + 1], deck: deck, family: document.font)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .onTapGesture { player.next() }
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(Text("Ende der Präsentation").font(.system(size: 12)).foregroundStyle(Theme.textTertiary))
            }
        }
    }
}

/// The slide the player is on, with its live background; a click goes on. Subtitles show what is being said.
struct PresentationStage: View {
    @Environment(AppModel.self) private var app
    let player: PresentationPlayer
    let family: WriterFont

    var body: some View {
        if let deck = player.deck, let slide = player.currentSlide {
            SlideStageView(slide: slide, deck: deck, family: family, live: true)
                .overlay(alignment: .bottom) {
                    if player.showsSubtitles, let line = subtitle {
                        GeometryReader { geometry in
                            Text(line)
                                .font(.system(size: max(11, geometry.size.width / 46), weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, geometry.size.width / 60)
                                .padding(.vertical, geometry.size.width / 140)
                                .background(RoundedRectangle(cornerRadius: geometry.size.width / 160, style: .continuous).fill(Color.black.opacity(0.62)))
                                .frame(maxWidth: geometry.size.width * 0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, geometry.size.height * 0.05)
                        }
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if player.phase == .writing {
                        Label("Die KI bereitet die Folie vor …", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(12)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: player.phase)
                .contentShape(Rectangle())
                .onTapGesture { player.next() }
        } else {
            Color.black.aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    /// The sentence (or the piece) being spoken.
    private var subtitle: String? {
        guard player.phase == .speaking, let range = player.spokenRange else { return nil }
        let text = player.spokenText as NSString
        guard NSMaxRange(range) <= text.length, range.length > 0 else { return nil }
        let line = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

/// Back, forward, the model presenting, subtitles, full screen.
struct PresentationControls: View {
    @Environment(AppModel.self) private var app
    let player: PresentationPlayer
    let isFullScreen: Bool

    var body: some View {
        let count = player.deck?.slides.count ?? 0
        HStack(spacing: 10) {
            IconButton(systemName: "chevron.left", help: "Vorige Folie (←)", size: 14, frameSize: 30) { player.previous() }
                .disabled(player.index == 0)
            Text("\(min(player.index + 1, count)) / \(count)")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 48)
            IconButton(systemName: "chevron.right", help: "Nächste Folie (→ oder Leertaste)", size: 14, frameSize: 30) { player.next() }
                .disabled(player.index + 1 >= count)
            Rectangle().fill(Theme.border).frame(width: 1, height: 18)
            Button { player.togglePresenting() } label: {
                HStack(spacing: 6) {
                    Image(systemName: player.isPresenting ? "pause.fill" : "person.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(player.isPresenting ? "Pause" : (player.phase == .finished ? "KI präsentiert erneut" : "KI präsentiert"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(player.isPresenting ? Theme.textPrimary : Color.black.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(player.isPresenting ? Color.white.opacity(0.12) : Theme.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Die KI trägt vor: Sie liest die Moderatorenkarten vor (fehlende schreibt sie vorher) und schaltet danach weiter (P)")
            status
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { player.showsSubtitles }, set: { player.showsSubtitles = $0 })) {
                Label("Untertitel", systemImage: "captions.bubble")
                    .font(.system(size: 12))
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(player.showsSubtitles ? Theme.accent : Theme.textSecondary)
            .help("Was die KI sagt, unten auf der Folie zeigen (U)")
            if isFullScreen {
                IconButton(systemName: "xmark", help: "Vorführung beenden (esc)", size: 13, frameSize: 30) { player.exitFullScreen() }
            } else {
                Button { player.enterFullScreen() } label: {
                    Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.elevated))
                        .overlay(Capsule().strokeBorder(Theme.border))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(NSScreen.screens.count > 1 ? "Auf dem zweiten Bildschirm vorführen; hier bleibt die Ansicht für dich" : "Im Vollbild vorführen (⌥⌘P)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isFullScreen ? Color.black.opacity(0.72) : Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: 760)
    }

    @ViewBuilder
    private var status: some View {
        if let error = player.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.warning)
                .lineLimit(1)
                .help(error)
        } else {
            switch player.phase {
            case .writing:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("schreibt die Moderatorenkarte …")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            case .speaking:
                Label(app.speechState == .preparing ? "Stimme wird vorbereitet …" : "spricht …", systemImage: "waveform")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .symbolEffect(.variableColor.iterative, isActive: app.speechState == .speaking)
            case .finished:
                Text("Ende der Präsentation")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            case .idle, .turning:
                EmptyView()
            }
        }
    }
}

/// The speaker notes of the current slide; while they are read, the part being spoken is marked.
private struct NotesPrompter: View {
    @Environment(AppModel.self) private var app
    let player: PresentationPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Moderatorenkarte")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let slide = player.currentSlide, let id = player.documentID {
                    if app.notesWriting.contains(slide.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        SmallActionButton(title: slide.notes.isEmpty ? "Schreiben lassen" : "Neu", symbol: "sparkles") {
                            app.writeSpeakerNotes(id, slides: [slide.id])
                        }
                    }
                }
            }
            ScrollView {
                Text(attributed)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private var attributed: AttributedString {
        let speaking = player.phase == .speaking && !player.spokenText.isEmpty
        let text = speaking ? player.spokenText : (player.currentSlide?.notes ?? "")
        guard !text.isEmpty else {
            var empty = AttributedString("Noch keine Moderatorenkarte. Beim Vortrag schreibt die KI sie selbst.")
            empty.foregroundColor = Theme.textTertiary
            return empty
        }
        var result = AttributedString(text)
        result.foregroundColor = Theme.textSecondary
        if speaking, let range = player.spokenRange, let swiftRange = Range(range, in: text),
           let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
           let upper = AttributedString.Index(swiftRange.upperBound, within: result) {
            result[lower..<upper].foregroundColor = Theme.textPrimary
            result[lower..<upper].backgroundColor = Theme.accent.opacity(0.22)
        }
        return result
    }
}

/// Arrow keys, space, P and U turn the slides and start the model, while no text field has the keyboard; esc ends
/// the full screen (or pauses in the window).
struct PresentationKeys: NSViewRepresentable {
    let player: PresentationPlayer
    let exitsFullScreen: Bool

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.handler = handle
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) {
        view.handler = handle
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 124, 125, 49, 36, 121: player.next()          // → ↓ space return page down
        case 123, 126, 51, 116: player.previous()          // ← ↑ delete page up
        case 115: player.go(to: 0)                         // home
        case 119: player.go(to: max(0, (player.deck?.slides.count ?? 1) - 1))   // end
        case 53:                                           // esc
            if exitsFullScreen { player.exitFullScreen() } else if player.isPresenting { player.pause() } else { return false }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p": player.togglePresenting()
            case "u": player.showsSubtitles.toggle()
            default: return false
            }
        }
        return true
    }
}

/// Watches the keys of its own window while it is there.
final class KeyMonitorView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            // Typing in a text field (the sidebar's search, for example) stays typing.
            if let textView = window.firstResponder as? NSTextView, textView.isEditable { return event }
            return self.handler?(event) == true ? nil : event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Full screen

/// The presentation on a whole screen: on a second screen if there is one, else on the window's. The controls show
/// when the mouse moves.
@MainActor
final class PresentationWindowController: NSObject, NSWindowDelegate {
    private let window: PresentationWindow
    private weak var player: PresentationPlayer?
    private var previousOptions: NSApplication.PresentationOptions = []

    init(player: PresentationPlayer, app: AppModel) {
        self.player = player
        let screen = Self.targetScreen()
        window = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PresentationFullScreenView(player: player)
                .environment(app)
                .preferredColorScheme(.dark)
        )
    }

    /// A screen other than the main window's when there is one (the audience's), else the main window's.
    private static func targetScreen() -> NSScreen {
        let windowScreen = MainWindow.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        return NSScreen.screens.first { $0 != windowScreen } ?? windowScreen
    }

    func show() {
        let screen = Self.targetScreen()
        // On the screen with the menu bar, the menu bar and the Dock go away for the presentation.
        if screen == NSScreen.screens.first {
            previousOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        window.delegate = nil
        window.orderOut(nil)
        NSApp.presentationOptions = previousOptions
        MainWindow.window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking into the main window on the same screen ends nothing; the presentation simply stays behind.
    }
}

/// A borderless window that takes the keyboard.
final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PresentationFullScreenView: View {
    @Environment(AppModel.self) private var app
    let player: PresentationPlayer
    @State private var showsControls = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let family = player.documentID.flatMap { app.document($0)?.font } ?? .sans
        ZStack(alignment: .bottom) {
            Color.black
            PresentationStage(player: player, family: family)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PresentationControls(player: player, isFullScreen: true)
                .padding(.bottom, 24)
                .opacity(showsControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: showsControls)
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .background { PresentationKeys(player: player, exitsFullScreen: true) }
    }

    private func revealControls() {
        showsControls = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            showsControls = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
