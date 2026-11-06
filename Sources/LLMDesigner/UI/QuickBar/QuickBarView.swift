import AppKit
import SwiftUI

private struct QuickBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set in the search bar's message list: follow-up questions and branches stay in the bar.
    var isQuickBar: Bool {
        get { self[QuickBarKey.self] }
        set { self[QuickBarKey.self] = newValue }
    }
}

/// The search bar's content: the field, the chat below it once there is one. Colour only moves softly inside the
/// field (`QuickBarAurora`), a little livelier while the model works; the rest stays still, so streaming text scrolls
/// without the whole bar being repainted each frame.
struct QuickBarView: View {
    static let width: CGFloat = 720
    static let cornerRadius: CGFloat = 20
    private static let chatHeight: CGFloat = 420

    let onSize: (CGSize) -> Void
    let onClose: () -> Void
    let onOpenMain: () -> Void

    @Environment(AppModel.self) private var app
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let bar = app.quickBar
        let busy = app.isQuickBarGenerating
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            // The free space around the field and the footer move the bar.
            inputRow(busy: busy)
                .background(QuickBarAurora(isBusy: busy))
                .background(QuickBarDragArea())
            if let chat = app.currentQuickBarChat, !chat.messages.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
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
                .environment(\.isQuickBar, true)
                .frame(height: Self.chatHeight)
            } else {
                QuickBarSuggestions { text in
                    bar.draft = text
                    isFieldFocused = true
                }
            }
            footer(busy: busy)
        }
        .frame(width: Self.width)
        .background(Theme.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.ink.opacity(0.12), lineWidth: 1))
        .scaleEffect(bar.isShown ? 1 : 0.97, anchor: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: bar.isShown)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .tint(Theme.accent)
        .onChange(of: bar.isShown) { _, shown in if shown { isFieldFocused = true } }
        .onChange(of: bar.focusToken) { _, _ in isFieldFocused = true }
    }

    private func inputRow(busy: Bool) -> some View {
        @Bindable var bar = app.quickBar
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: busy)
                    .frame(width: 26, height: 26)
                TextField("", text: $bar.draft, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...6)
                    .focused($isFieldFocused)
                    .onSubmit { app.sendQuickBar() }
                if app.isDictationAvailable {
                    DictationButton(intoQuickBar: true)
                }
                if busy {
                    QuickBarRoundButton(systemName: "stop.fill", help: "Stoppen (⌘.)") { app.stopQuickBar() }
                        .keyboardShortcut(".")
                } else if app.canSendQuickBar || app.isDictatingIntoQuickBar {
                    QuickBarRoundButton(systemName: "arrow.up", help: "Senden (↩)") { app.sendQuickBar() }
                }
            }
            if app.quickBar.receivesDictation, app.dictationStatus != .idle {
                DictationPreview()
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var placeholder: String {
        app.currentQuickBarChat == nil ? "Frag etwas oder gib einen Auftrag …" : "Weiter fragen …"
    }

    private func footer(busy: Bool) -> some View {
        HStack(spacing: 10) {
            Label("Darf alles in der App", systemImage: "bolt.fill")
                .foregroundStyle(Theme.textSecondary)
                .help("Die Suchleiste darf Dokumente, Präsentationen, Quellen und Romanwelten anlegen und ändern, ohne zu fragen. Private Daten und Änderungen nach fremden Inhalten (z. B. aus dem Web) fragen weiterhin.")
            if let model = app.quickBarModel {
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(model.displayName).foregroundStyle(Theme.textTertiary).lineLimit(1)
            } else {
                Text("· Kein Modell bereit").foregroundStyle(Theme.textTertiary)
            }
            if busy {
                Text("arbeitet …").foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 8)
            QuickBarBroomButton { app.newQuickBarChat() }
                .keyboardShortcut("n")
                .disabled(busy || (app.currentQuickBarChat == nil && app.quickBar.draft.isEmpty))
            QuickBarFooterButton(title: "Im Hauptfenster", shortcut: "⌘O") { onOpenMain() }
                .keyboardShortcut("o")
                .disabled(app.currentQuickBarChat == nil)
            QuickBarFooterButton(title: "Schließen", shortcut: "esc") { onClose() }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(QuickBarDragArea())
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: Colour in the field

/// Soft colour drifting behind the field, like light under frosted glass, a little brighter and quicker while the
/// model works. Core Animation moves it in the render server: the app computes nothing per frame, and nothing at all
/// while the bar is hidden. With "Bewegung reduzieren" it stands still.
private struct QuickBarAurora: NSViewRepresentable {
    let isBusy: Bool

    func makeNSView(context: Context) -> AuroraView { AuroraView() }

    func updateNSView(_ view: AuroraView, context: Context) {
        view.setBusy(isBusy)
    }
}

final class AuroraView: NSView {
    private let container = CALayer()
    private let blobs = (0..<3).map { _ in CAGradientLayer() }
    private let runner = CAGradientLayer()
    private var isBusy = false
    private var laidOutWidth: CGFloat = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Size and drift time of each patch of light: different times, so the pattern never repeats visibly.
    private static let blobSpecs: [(width: CGFloat, duration: CFTimeInterval, start: CGFloat, end: CGFloat)] = [
        (380, 13, 0.12, 0.62), (320, 17, 0.85, 0.35), (260, 11, 0.45, 0.95),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(container)
        for blob in blobs {
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            container.addSublayer(blob)
        }
        runner.startPoint = CGPoint(x: 0, y: 0.5)
        runner.endPoint = CGPoint(x: 1, y: 0.5)
        runner.opacity = 0
        layer?.addSublayer(runner)
        // The light fades out towards the bottom, so the row has no edge where it ends.
        let fade = CAGradientLayer()
        fade.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        container.mask = fade
        applyColors()
        applyStrength(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        container.mask?.frame = bounds
        for (blob, spec) in zip(blobs, Self.blobSpecs) {
            blob.bounds = CGRect(x: 0, y: 0, width: spec.width, height: max(bounds.height * 2.2, 140))
            blob.position = CGPoint(x: bounds.width * spec.start, y: bounds.height * 0.7)
        }
        runner.bounds = CGRect(x: 0, y: 0, width: 220, height: 1.5)
        runner.position = CGPoint(x: bounds.midX, y: 0.75)
        CATransaction.commit()
        if abs(bounds.width - laidOutWidth) > 1 {
            laidOutWidth = bounds.width
            startDrift()
        }
    }

    func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        applyStrength(animated: true)
        // Quicker while working, without a jump: the layer's own clock changes speed from where it is.
        for layer in blobs + [runner] { setSpeed(busy ? 2.6 : 1, of: layer) }
    }

    private func startDrift() {
        guard !reduceMotion, laidOutWidth > 0 else { return }
        for (blob, spec) in zip(blobs, Self.blobSpecs) {
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = laidOutWidth * spec.start
            drift.toValue = laidOutWidth * spec.end
            drift.duration = spec.duration
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(drift, forKey: "drift")
        }
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = -110
        run.toValue = laidOutWidth + 110
        run.duration = 4.5
        run.repeatCount = .infinity
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        runner.add(run, forKey: "run")
    }

    private func setSpeed(_ speed: Float, of layer: CALayer) {
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.timeOffset = local
        layer.beginTime = now
        layer.speed = speed
    }

    private func applyStrength(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.8 : 0)
        CATransaction.setDisableActions(!animated)
        container.opacity = isBusy ? 1 : 0.55
        runner.opacity = isBusy ? 0.8 : 0
        CATransaction.commit()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let light = !effectiveAppearance.name.rawValue.lowercased().contains("dark")
            let alpha: CGFloat = light ? 0.16 : 0.24
            let tints: [NSColor] = [
                NSColor(Theme.accent),
                NSColor(red: 0.36, green: 0.56, blue: 0.95, alpha: 1),
                NSColor(red: 0.30, green: 0.70, blue: 0.75, alpha: 1),
            ]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (blob, tint) in zip(blobs, tints) {
                blob.colors = [tint.withAlphaComponent(alpha).cgColor, tint.withAlphaComponent(0).cgColor]
            }
            let accent = NSColor(Theme.accent)
            runner.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.7).cgColor, accent.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
    }
}

// MARK: Pieces

/// Drags the panel. Not `WindowDragArea`: its double click zooms, which a panel can't.
private struct QuickBarDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// Starts for a job: a click writes the beginning into the field.
private struct QuickBarSuggestions: View {
    let onPick: (String) -> Void

    private static let items: [(symbol: String, title: String, text: String)] = [
        ("doc.richtext", "Dokument erstellen", "Erstelle ein Dokument über "),
        ("play.rectangle", "Präsentation erstellen", "Erstelle eine Präsentation mit fünf Folien über "),
        ("quote.bubble", "Quelle suchen", "Suche in meinen Quellen nach "),
        ("books.vertical", "Romanwelt", "Was weißt du über meine Romanwelt "),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.items, id: \.title) { item in
                QuickBarChip(symbol: item.symbol, title: item.title) { onPick(item.text) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

private struct QuickBarChip: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(Capsule().fill(hovering ? Theme.hover : Theme.ink.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Theme.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct QuickBarRoundButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Sweeps the bar clean: empty field, new chat. SF Symbols has no broom, so it is drawn.
private struct QuickBarBroomButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            BroomShape()
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 15)
                .rotationEffect(.degrees(28))
                .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help("Suchleiste leeren und neu beginnen (⌘N) – der Chat bleibt in der Seitenleiste")
    }
}

/// An upright broom in a 13×15 box: handle, binding, bristles.
private struct BroomShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        // Handle
        path.move(to: p(0.5, 0))
        path.addLine(to: p(0.5, 0.5))
        // Binding
        path.addRoundedRect(in: CGRect(origin: p(0.3, 0.5), size: CGSize(width: 0.4 * w, height: 0.1 * h)), cornerSize: CGSize(width: 1, height: 1))
        // Bristles, fanning out
        path.move(to: p(0.3, 0.6))
        path.addLine(to: p(0.08, 1))
        path.addLine(to: p(0.92, 1))
        path.addLine(to: p(0.7, 0.6))
        path.move(to: p(0.43, 0.68))
        path.addLine(to: p(0.36, 0.95))
        path.move(to: p(0.57, 0.68))
        path.addLine(to: p(0.64, 0.95))
        return path
    }
}

private struct QuickBarFooterButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.ink.opacity(0.06)))
            }
            .foregroundStyle(hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}
