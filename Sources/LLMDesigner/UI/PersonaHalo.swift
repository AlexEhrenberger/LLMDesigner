import SwiftUI

/// Conversation mode with a persona: its round picture takes the place of the wave. While the persona speaks, rings of
/// light run out of the picture with the loudness of the voice and a glow swells around it; while the answer is on its
/// way, a light circles the picture; while listening, a calm ring breathes. Everything is drawn in the picture's colour.
struct PersonaHalo: View {
    let session: ConversationSession
    let persona: Persona
    @State private var motion = HaloMotion()

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let diameter = max(72, min(132, side * 0.55))
            TimelineView(.animation) { timeline in
                let state = motion.advance(to: timeline.date, target: target(at: timeline.date))
                ZStack {
                    Canvas { context, size in
                        Self.draw(in: &context, size: size, radius: diameter / 2, state: state, tint: persona.tintColor)
                    }
                    PersonaAvatar(persona: persona, size: diameter)
                        .saturation(state.dimmed ? 0.2 : 1)
                        .opacity(state.dimmed ? 0.55 : 1)
                        .scaleEffect(1 + 0.05 * state.amplitude)
                        .shadow(color: persona.tintColor.opacity(0.35 * state.brightness), radius: 14)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .accessibilityLabel("Profilbild von \(persona.displayName)")
    }

    private func target(at date: Date) -> HaloMotion.Target {
        switch session.phase {
        case .speaking:
            return .init(amplitude: Double(session.voice.levels.level(at: date)), brightness: 1, emits: true)
        case .waiting:
            return .init(amplitude: 0.05, brightness: 0.85, spinning: true)
        case .listening:
            return .init(amplitude: 0, brightness: 0.75, breathing: true)
        case .starting:
            return .init(amplitude: 0, brightness: 0.45, breathing: true)
        case .paused, .failed:
            return .init(amplitude: 0, brightness: 0.3, dimmed: true)
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, radius: CGFloat, state: HaloMotion.State, tint: Color) {
        guard size.width > 0, size.height > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = max(radius + 10, min(size.width, size.height) / 2 - 2)
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        // Glow that swells with the voice.
        let glow = radius + (outer - radius) * (0.3 + 0.7 * state.amplitude)
        context.fill(circle(glow), with: .radialGradient(
            Gradient(stops: [
                .init(color: tint.opacity(0.45 * state.brightness * (0.3 + 0.7 * state.amplitude)), location: radius / glow * 0.92),
                .init(color: tint.opacity(0), location: 1),
            ]),
            center: center, startRadius: 0, endRadius: glow
        ))

        context.blendMode = .plusLighter

        // Rings of light running outwards, each as bright as the voice was when it left the picture.
        if !state.ripples.isEmpty {
            func rings(_ layer: inout GraphicsContext, width: CGFloat, strength: Double) {
                for ripple in state.ripples {
                    let eased = 1 - pow(1 - ripple.progress, 2.2)
                    let r = radius + 3 + (outer - radius - 3) * eased
                    let opacity = ripple.strength * pow(1 - ripple.progress, 1.4) * state.brightness * strength
                    layer.stroke(circle(r), with: .color(tint.opacity(opacity)), lineWidth: width * (1.2 - ripple.progress))
                }
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                rings(&layer, width: 6, strength: 0.55)
            }
            rings(&context, width: 2.2, strength: 0.9)
        }

        // Rim around the picture.
        context.stroke(circle(radius + 3), with: .color(tint.opacity(0.16 + 0.5 * state.amplitude)), lineWidth: 1.5)

        // Breathing ring while listening.
        if state.breath > 0.01 {
            let phase = (sin(state.time * 1.7) + 1) / 2
            context.stroke(
                circle(radius + 8 + 3 * phase),
                with: .color(tint.opacity(state.breath * (0.16 + 0.24 * phase) * state.brightness)),
                lineWidth: 1.3
            )
        }

        // A comet of light circling the picture while the answer is on its way.
        if state.spin > 0.01 {
            let r = radius + 9
            let segments = 40
            let length = Double.pi * 0.75
            for index in 0..<segments {
                // Flat ends, so the segments join into one stroke that fades towards its tail.
                let from = state.rotation + length * Double(index) / Double(segments)
                let to = state.rotation + length * Double(index + 1) / Double(segments)
                var path = Path()
                path.move(to: CGPoint(x: center.x + r * cos(from), y: center.y + r * sin(from)))
                path.addLine(to: CGPoint(x: center.x + r * cos(to), y: center.y + r * sin(to)))
                let opacity = pow(Double(index + 1) / Double(segments), 1.6) * state.spin
                context.stroke(path, with: .color(tint.opacity(0.9 * opacity)), style: StrokeStyle(lineWidth: 2.4, lineCap: index == segments - 1 ? .round : .butt))
            }
            let head = state.rotation + length
            let point = CGPoint(x: center.x + r * cos(head), y: center.y + r * sin(head))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(tint.opacity(0.8 * state.spin)))
            }
        }
    }
}

/// Smooths the halo from frame to frame and keeps the rings that are running outwards.
private final class HaloMotion {
    struct Target {
        var amplitude: Double
        var brightness: Double
        var emits = false
        var spinning = false
        var breathing = false
        var dimmed = false
    }

    struct Ripple {
        /// 0 when it leaves the picture, 1 when it has faded at the edge.
        var progress: Double
        let strength: Double
    }

    struct State {
        var amplitude = 0.0
        var brightness = 0.45
        var spin = 0.0
        var breath = 0.0
        var rotation = -Double.pi / 2
        var time = 0.0
        var dimmed = false
        var ripples: [Ripple] = []
    }

    private static let rippleLife = 1.9
    private static let rippleInterval = 0.28

    private var state = State()
    private var lastFrame: Date?
    private var sinceRipple = 0.0

    func advance(to date: Date, target: Target) -> State {
        let elapsed = min(0.1, max(0, lastFrame.map { date.timeIntervalSince($0) } ?? 0))
        lastFrame = date
        func approach(_ value: inout Double, _ goal: Double, _ time: Double) {
            value += (goal - value) * (1 - exp(-elapsed / time))
        }
        approach(&state.amplitude, target.amplitude, target.amplitude > state.amplitude ? 0.05 : 0.2)
        approach(&state.brightness, target.brightness, 0.3)
        approach(&state.spin, target.spinning ? 1 : 0, 0.25)
        approach(&state.breath, target.breathing ? 1 : 0, 0.4)
        state.rotation += elapsed * 3.4
        state.time += elapsed
        state.dimmed = target.dimmed

        state.ripples = state.ripples
            .map { Ripple(progress: $0.progress + elapsed / Self.rippleLife, strength: $0.strength) }
            .filter { $0.progress < 1 }
        sinceRipple += elapsed
        if target.emits, sinceRipple >= Self.rippleInterval, state.amplitude > 0.08 {
            state.ripples.append(Ripple(progress: 0, strength: min(1, 0.2 + state.amplitude)))
            sinceRipple = 0
        }
        return state
    }
}
