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

/// The search bar's content: the field, the chat below it once there is one, and a glow that lights up when the bar
/// opens and runs around it while the model works.
struct QuickBarView: View {
    /// Room around the bar for the glow; the panel is that much larger than the bar.
    static let glowMargin: CGFloat = 90
    static let width: CGFloat = 720
    static let cornerRadius: CGFloat = 24
    private static let chatHeight: CGFloat = 420

    let onSize: (CGSize) -> Void
    let onClose: () -> Void
    let onOpenMain: () -> Void

    @Environment(AppModel.self) private var app
    @FocusState private var isFieldFocused: Bool
    /// 1 right after opening, then dies away: the flash and the fast turn of the entrance.
    @State private var flare: Double = 0

    var body: some View {
        let bar = app.quickBar
        let busy = app.isQuickBarGenerating
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            inputRow(busy: busy)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                QuickBarSuggestions { text in
                    bar.draft = text
                    isFieldFocused = true
                }
                .transition(.opacity)
            }
            footer(busy: busy)
        }
        .frame(width: Self.width)
        .background(shape.fill(.ultraThinMaterial))
        .background(shape.fill(Theme.background.opacity(0.82)))
        .clipShape(shape)
        .overlay(QuickBarGlow(shape: shape, isBusy: busy, flare: flare, isHalo: false))
        .background(QuickBarGlow(shape: shape, isBusy: busy, flare: flare, isHalo: true))
        .scaleEffect(bar.isShown ? 1 : 0.92, anchor: .top)
        .opacity(bar.isShown ? 1 : 0)
        .offset(y: bar.isShown ? 0 : -14)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: bar.isShown)
        .animation(.smooth(duration: 0.3), value: app.currentQuickBarChat?.messages.isEmpty ?? true)
        .padding(Self.glowMargin)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .tint(Theme.accent)
        .onChange(of: bar.isShown) { _, shown in
            guard shown else { return }
            flare = 1
            withAnimation(.easeOut(duration: 1.4)) { flare = 0 }
            isFieldFocused = true
        }
        .onChange(of: bar.focusToken) { _, _ in isFieldFocused = true }
    }

    private func inputRow(busy: Bool) -> some View {
        @Bindable var bar = app.quickBar
        return HStack(alignment: .center, spacing: 14) {
            QuickBarSpark(isBusy: busy, flare: flare)
            TextField("", text: $bar.draft, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...6)
                .focused($isFieldFocused)
                .onSubmit { app.sendQuickBar() }
            if busy {
                QuickBarRoundButton(systemName: "stop.fill", help: "Stoppen (⌘.)") { app.stopQuickBar() }
                    .keyboardShortcut(".")
                    .transition(.scale.combined(with: .opacity))
            } else if app.canSendQuickBar {
                QuickBarRoundButton(systemName: "arrow.up", help: "Senden (↩)") { app.sendQuickBar() }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: busy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: app.canSendQuickBar)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var placeholder: String {
        app.currentQuickBarChat == nil ? "Frag etwas oder gib einen Auftrag …" : "Weiter fragen …"
    }

    private func footer(busy: Bool) -> some View {
        HStack(spacing: 10) {
            Label("Darf alles in der App", systemImage: "bolt.fill")
                .foregroundStyle(Theme.accent)
                .help("Die Suchleiste darf Dokumente, Präsentationen, Quellen und Romanwelten anlegen und ändern, ohne zu fragen. Private Daten und Änderungen nach fremden Inhalten (z. B. aus dem Web) fragen weiterhin.")
            if let model = app.quickBarModel {
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(model.displayName).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else {
                Text("· Kein Modell bereit").foregroundStyle(Theme.textTertiary)
            }
            if busy {
                Text("arbeitet …")
                    .foregroundStyle(Theme.accent)
                    .phaseAnimator([0.45, 1]) { content, phase in content.opacity(phase) } animation: { _ in .easeInOut(duration: 0.7) }
            }
            Spacer(minLength: 8)
            QuickBarFooterButton(title: "Neu", shortcut: "⌘N") { app.newQuickBarChat() }
                .keyboardShortcut("n")
                .disabled(busy || app.currentQuickBarChat == nil)
            QuickBarFooterButton(title: "Im Hauptfenster", shortcut: "⌘O") { onOpenMain() }
                .keyboardShortcut("o")
                .disabled(app.currentQuickBarChat == nil)
            QuickBarFooterButton(title: "Schließen", shortcut: "esc") { onClose() }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Theme.ink.opacity(0.035))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: Glow

/// The light around the bar: a band of colours running around the edge. It flashes up and spins fast when the bar
/// opens, turns slowly while it waits, and races and breathes while the model works.
private struct QuickBarGlow: View {
    let shape: RoundedRectangle
    let isBusy: Bool
    let flare: Double
    /// The soft light outside the bar (behind it); otherwise the sharp edge (on top).
    let isHalo: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var clock = GlowClock()

    static let colors: [Color] = [
        Theme.accent,
        Color(red: 0.36, green: 0.62, blue: 1.0),
        Color(red: 0.25, green: 0.88, blue: 0.95),
        Color(red: 1.0, green: 0.42, blue: 0.78),
        Color(red: 1.0, green: 0.66, blue: 0.30),
        Color(red: 0.78, green: 0.45, blue: 1.0),
        Theme.accent,
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // Degrees per second: the speed changes, the angle doesn't jump.
            let speed = (isBusy ? 220 : 34) + flare * 720
            let angle = reduceMotion ? 0 : clock.advance(to: time, degreesPerSecond: speed)
            let breath = isBusy ? 0.5 + 0.5 * sin(time * 3.6) : 0
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle))
            // A light background swallows soft light; there it needs more strength to be seen.
            let strength = colorScheme == .light ? 1.25 : 1
            if isHalo {
                ZStack {
                    shape.stroke(gradient, lineWidth: 24)
                        .blur(radius: 26)
                        .opacity(min(1, (0.34 + 0.3 * breath + 0.7 * flare + (isBusy ? 0.25 : 0)) * strength))
                    shape.stroke(gradient, lineWidth: 8)
                        .blur(radius: 12)
                        .opacity(min(1, (0.42 + 0.3 * breath + 0.6 * flare + (isBusy ? 0.2 : 0)) * strength))
                }
                .scaleEffect(1 + 0.025 * flare + 0.006 * breath)
            } else {
                ZStack {
                    shape.strokeBorder(gradient, lineWidth: isBusy ? 2 : 1.4)
                        .opacity(0.75 + 0.25 * max(flare, breath))
                    // A bright arc that sweeps the edge: the comet tail of the light.
                    shape.strokeBorder(
                        AngularGradient(colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)], center: .center,
                                        startAngle: .degrees(angle * 1.6), endAngle: .degrees(angle * 1.6 + 70)),
                        lineWidth: isBusy ? 2.2 : 1.4
                    )
                    .opacity(isBusy ? 0.9 : 0.35 + 0.65 * flare)
                    .blendMode(.plusLighter)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The glow's angle, carried from frame to frame, so the speed can change without a jump.
private final class GlowClock {
    private var angle: Double = 0
    private var last: TimeInterval?

    func advance(to time: TimeInterval, degreesPerSecond: Double) -> Double {
        if let last { angle += min(time - last, 0.1) * degreesPerSecond }
        last = time
        angle = angle.truncatingRemainder(dividingBy: 360)
        return angle
    }
}

/// The sparkle in front of the field: it jumps when the bar opens and shimmers while the model works.
private struct QuickBarSpark: View {
    let isBusy: Bool
    let flare: Double

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Theme.accent, Color(red: 1.0, green: 0.42, blue: 0.78), Color(red: 0.25, green: 0.88, blue: 0.95)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .symbolEffect(.variableColor.iterative.reversing, isActive: isBusy)
            .symbolEffect(.bounce, value: flare > 0.99)
            .shadow(color: Theme.accent.opacity(0.4 + 0.5 * flare), radius: 6 + 10 * flare)
            .frame(width: 28, height: 28)
    }
}

// MARK: Pieces

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
        .padding(.horizontal, 20)
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
                .background(Capsule().fill(hovering ? Theme.accent.opacity(0.16) : Theme.ink.opacity(0.05)))
                .overlay(Capsule().strokeBorder(hovering ? Theme.accent.opacity(0.5) : Theme.border))
                .scaleEffect(hovering ? 1.04 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { self.hovering = hovering } }
    }
}

private struct QuickBarRoundButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
