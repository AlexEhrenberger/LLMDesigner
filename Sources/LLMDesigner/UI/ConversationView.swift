import AppKit
import SwiftUI

/// Conversation mode: a narrow window with the wave in the middle, or the picture of the persona the chat runs with.
/// Both move with the voice of the answer, not with the microphone. Click on them or space: send now, interrupt, or
/// switch the microphone back on; esc ends.
struct ConversationView: View {
    @Environment(AppModel.self) private var app
    let session: ConversationSession
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(session: session)
                .padding(.top, Theme.titleBarHeight + 8)
            Spacer(minLength: 12)
            Group {
                if let persona = app.activePersona {
                    PersonaHalo(session: session, persona: persona)
                        .frame(minHeight: 150, maxHeight: 250)
                } else {
                    VoiceWave(session: session)
                        .frame(height: 190)
                }
            }
                .contentShape(Rectangle())
                .onTapGesture { session.primaryAction() }
                .help(waveHelp)
            ConversationStatus(session: session)
                .frame(height: 124, alignment: .top)
                .padding(.top, 8)
            Spacer(minLength: 12)
            ConversationControls(session: session)
                .padding(.bottom, 26)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .background {
            RadialGradient(colors: [Theme.accent.opacity(0.09), .clear], center: .center, startRadius: 0, endRadius: 280)
                .background(Theme.background)
        }
        .opacity(session.isEnding ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: session.isEnding)
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Space and esc work wherever the focus is; there is no text field in this view.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [app, session] event in
            guard event.window === MainWindow.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad]).isEmpty
            else { return event }
            switch event.keyCode {
            case 49:
                if !event.isARepeat { session.primaryAction() }
                return nil
            case 53:
                app.endConversation()
                return nil
            default:
                return event
            }
        }
    }

    private var waveHelp: String {
        switch session.phase {
        case .listening: "Klicken (oder Leertaste): sofort senden, ohne die Pause abzuwarten"
        case .waiting, .speaking: "Klicken (oder Leertaste): unterbrechen und selbst sprechen"
        case .paused: "Klicken (oder Leertaste): Mikrofon wieder einschalten"
        case .failed: "Klicken (oder Leertaste): erneut zuhören"
        case .starting: ""
        }
    }
}

private struct ConversationHeader: View {
    @Environment(AppModel.self) private var app
    let session: ConversationSession

    var body: some View {
        VStack(spacing: 3) {
            Text(session.chatID.flatMap(app.chatTitle) ?? app.activePersona.map { "Gespräch mit \($0.displayName)" } ?? "Neues Gespräch")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(details)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .allowsHitTesting(false)
    }

    private var details: String {
        var parts: [String] = []
        if session.chatID != nil, let persona = app.activePersona { parts.append(persona.displayName) }
        if let model = app.currentModel?.displayName ?? app.currentModelId { parts.append(model) }
        let skills = app.activeSkills
        if skills.count == 1 {
            parts.append(skills[0].name)
        } else if skills.count > 1 {
            parts.append("\(skills.count) Skills")
        }
        return parts.joined(separator: " · ")
    }
}

/// What is happening, and what the recogniser has understood so far.
private struct ConversationStatus: View {
    @Environment(AppModel.self) private var app
    let session: ConversationSession

    var body: some View {
        VStack(spacing: 9) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(labelColor)
            if let transcript {
                Text(transcript)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary.opacity(session.phase == .listening ? 0.92 : 0.5))
                    .lineLimit(4)
                    .truncationMode(.head)
            } else if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(hintColor)
                    .lineLimit(4)
            }
            if let notice = session.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(3)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: label)
    }

    private var label: String {
        switch session.phase {
        case .starting(let progress):
            if let progress { return "Sprachmodell wird geladen … \(Int(progress * 100)) %" }
            return "Mikrofon wird vorbereitet …"
        case .listening: return "Ich höre zu"
        case .paused: return "Mikrofon aus"
        case .waiting: return session.isThinking ? "Denkt nach …" : "Einen Moment …"
        case .speaking: return "Spricht"
        case .failed: return "Das hat nicht geklappt"
        }
    }

    private var labelColor: Color {
        switch session.phase {
        case .failed: Theme.danger
        case .speaking: Theme.accent
        default: Theme.textSecondary
        }
    }

    /// The user's words while listening, and dimmed while the answer is on its way.
    private var transcript: String? {
        guard session.phase == .listening || session.phase == .waiting else { return nil }
        let text = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var hint: String? {
        switch session.phase {
        case .listening: "Sprich einfach los. Nach einer kurzen Pause antwortet das Modell."
        case .speaking: "Zum Unterbrechen auf \(app.activePersona == nil ? "die Welle" : "das Bild") klicken oder die Leertaste drücken."
        case .paused: "Klicke auf das Mikrofon, um weiterzusprechen."
        case .failed(let message): message
        case .starting, .waiting: nil
        }
    }

    private var hintColor: Color {
        if case .failed = session.phase { return Theme.textSecondary }
        return Theme.textTertiary
    }
}

private struct ConversationControls: View {
    @Environment(AppModel.self) private var app
    let session: ConversationSession

    var body: some View {
        HStack(spacing: 22) {
            RoundControl(
                systemName: session.isMuted ? "mic.slash.fill" : "mic.fill",
                foreground: session.isMuted ? Theme.danger : Theme.textPrimary,
                fill: session.isMuted ? Theme.danger.opacity(0.16) : Theme.elevated,
                help: session.isMuted ? "Mikrofon einschalten" : "Mikrofon ausschalten"
            ) { session.toggleMute() }
            RoundControl(
                systemName: "xmark",
                foreground: .white,
                fill: Theme.danger.opacity(0.85),
                help: "Gespräch beenden (esc)"
            ) { app.endConversation() }
        }
    }
}

private struct RoundControl: View {
    let systemName: String
    let foreground: Color
    let fill: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 54, height: 54)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(Color.white.opacity(hovering ? 0.07 : 0)))
                .overlay(Circle().strokeBorder(Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Layered sine waves, tapered at both ends: a calm, almost flat line while listening, a slow shimmer while the answer
/// is on its way, and swinging with the loudness of the voice while it speaks.
struct VoiceWave: View {
    let session: ConversationSession
    @State private var motion = WaveMotion()

    private struct Layer {
        let frequency: Double
        let speed: Double
        let offset: Double
        let weight: Double
        let color: Color
    }

    private static let layers = [
        Layer(frequency: 1.5, speed: 1.0, offset: 0, weight: 1, color: Color(hex: 0xA996FF)),
        Layer(frequency: 2.2, speed: -1.35, offset: 1.9, weight: 0.78, color: Color(hex: 0x6FD3FF)),
        Layer(frequency: 2.9, speed: 1.7, offset: 3.3, weight: 0.6, color: Color(hex: 0xFF8FD6)),
        Layer(frequency: 1.15, speed: -0.8, offset: 4.6, weight: 0.88, color: Color(hex: 0xD9D0FF)),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let state = motion.advance(to: timeline.date, target: target(at: timeline.date))
                Self.draw(in: &context, size: size, state: state)
            }
        }
        .accessibilityLabel("Sprachwelle")
    }

    private func target(at date: Date) -> WaveMotion.Target {
        let time = date.timeIntervalSinceReferenceDate
        switch session.phase {
        case .speaking:
            return .init(amplitude: 0.06 + Double(session.voice.levels.level(at: date)) * 0.94, brightness: 1)
        case .waiting:
            return .init(amplitude: 0.1 + 0.05 * sin(time * 2.4), brightness: 0.8)
        case .listening:
            return .init(amplitude: 0.035, brightness: 0.6)
        case .starting:
            return .init(amplitude: 0.02, brightness: 0.35)
        case .paused, .failed:
            return .init(amplitude: 0.012, brightness: 0.25)
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, state: WaveMotion.State) {
        guard size.width > 0, size.height > 0 else { return }
        let middle = size.height / 2
        let height = size.height * 0.46 * state.amplitude
        let steps = max(2, Int(size.width / 2))
        let paths = layers.map { layer in
            var path = Path()
            for step in 0...steps {
                let position = Double(step) / Double(steps)
                // Tapered towards the ends, so the wave seems to come out of the line.
                let envelope = pow(sin(.pi * position), 2.2)
                let wave = sin(2 * .pi * layer.frequency * position + state.phase * layer.speed + layer.offset)
                let point = CGPoint(x: position * size.width, y: middle + height * layer.weight * envelope * wave)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
        func shading(_ color: Color, _ opacity: Double) -> GraphicsContext.Shading {
            .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(opacity), color.opacity(opacity), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: middle),
                endPoint: CGPoint(x: size.width, y: middle)
            )
        }

        context.blendMode = .plusLighter
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 9))
            for (path, layer) in zip(paths, layers) {
                glow.stroke(path, with: shading(layer.color, 0.55 * state.brightness), lineWidth: 5)
            }
        }
        for (path, layer) in zip(paths, layers) {
            context.stroke(path, with: shading(layer.color, 0.9 * state.brightness), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }
}

/// Smooths the wave from frame to frame: it rises quickly with the voice and settles more slowly.
private final class WaveMotion {
    struct Target {
        var amplitude: Double
        var brightness: Double
    }

    struct State {
        var amplitude = 0.02
        var brightness = 0.35
        var phase = 0.0
    }

    private var state = State()
    private var lastFrame: Date?

    func advance(to date: Date, target: Target) -> State {
        let elapsed = min(0.1, max(0, lastFrame.map { date.timeIntervalSince($0) } ?? 0))
        lastFrame = date
        let rising = target.amplitude > state.amplitude
        state.amplitude += (target.amplitude - state.amplitude) * (1 - exp(-elapsed / (rising ? 0.05 : 0.16)))
        state.brightness += (target.brightness - state.brightness) * (1 - exp(-elapsed / 0.3))
        // The waves travel faster the louder the voice is.
        state.phase += elapsed * (1.1 + state.amplitude * 5)
        return state
    }
}
