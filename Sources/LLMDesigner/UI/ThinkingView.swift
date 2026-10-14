import AppKit
import SwiftUI

/// The model's thinking. While the model thinks, a card of fixed height shows a live glimpse of the latest
/// thoughts, so the chat doesn't grow with them. Afterwards it folds into one line that opens the whole
/// thought process as a timeline in a popover.
struct ThinkingView: View {
    let text: String
    let isThinking: Bool
    let seconds: Double?
    /// When the answer started; the card counts the seconds from here.
    let startedAt: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isThinking {
                ThinkingCard(text: text, startedAt: startedAt)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            } else {
                ThinkingSummary(text: text, seconds: seconds)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: isThinking)
    }
}

/// Splits the thinking into steps (its paragraphs) and prepares it for display.
enum ThoughtSteps {
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The end of the thinking as plain text: no Markdown markers, no blank lines, starting at a word.
    static func tail(of text: String, characters: Int) -> String {
        var tail = Substring(text.suffix(characters))
        if text.count > characters, let space = tail.firstIndex(where: \.isWhitespace) {
            tail = tail[space...]
        }
        return plain(String(tail))
    }

    static func plain(_ text: String) -> String {
        var result = text
        for marker in ["**", "__", "`"] { result = result.replacingOccurrences(of: marker, with: "") }
        result = result.replacingOccurrences(of: #"(?m)^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "• ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A step with its inline Markdown (bold, italics, code) rendered.
    static func attributed(_ step: String) -> AttributedString {
        // Inline Markdown has no lists, so bullets become plain dots.
        let bulleted = step.replacingOccurrences(of: #"(?m)^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(bulleted)
    }
}

/// Colours of the thinking visuals, from violet over pink to light blue.
enum ThinkingPalette {
    static let violet = Color(hex: 0x8B76FF)
    static let lavender = Color(hex: 0xD6CCFF)
    static let pink = Color(hex: 0xFF8FD8)
    static let sky = Color(hex: 0x7FD4FF)

    static let ring: [Color] = [violet, lavender, pink, sky, violet]

    /// Colour along the thought process, 0 = first step, 1 = last.
    static func color(at fraction: Double) -> Color {
        let stops = [violet, pink, sky]
        let position = min(max(fraction, 0), 1) * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        return stops[index].mix(with: stops[index + 1], by: position - Double(index))
    }
}

// MARK: - While thinking

private struct ThinkingCard: View {
    let text: String
    let startedAt: Date

    var body: some View {
        let steps = ThoughtSteps.split(text)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ThinkingOrb(size: 20)
                ShimmeringText(text: "Denkt nach")
                    .font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.status(seconds: context.date.timeIntervalSince(startedAt), steps: steps.count))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 12)
                ThoughtTrail(lengths: steps.map(\.count), isLive: true)
                    .frame(width: 150, height: 5)
            }
            ThoughtGlimpse(text: text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RadialGradient(colors: [ThinkingPalette.violet.opacity(0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .overlay(GlowBorder(cornerRadius: 14))
    }

    private static func status(seconds: TimeInterval, steps: Int) -> String {
        let time = "\(max(Int(seconds), 0)) s"
        return steps > 1 ? "\(time) · Schritt \(steps)" : time
    }
}

/// The latest thoughts in a window of three lines. New text pushes older lines up, where they fade out.
private struct ThoughtGlimpse: View {
    let text: String

    var body: some View {
        let tail = ThoughtSteps.tail(of: text, characters: 600)
        // The newest words are brighter, like ink that is still wet.
        let split = tail.index(tail.endIndex, offsetBy: -min(tail.count, 42))
        (Text(tail[..<split]).foregroundColor(Theme.textSecondary) + Text(tail[split...]).foregroundColor(Theme.textPrimary))
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: 54, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.35), .init(color: .black, location: 0.75)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .padding(.leading, 30)
    }
}

/// A glowing orb: a rotating colour ring, sparks circling on it and a softly pulsing core.
struct ThinkingOrb: View {
    var size: CGFloat = 20

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [ThinkingPalette.violet.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: size * 0.95))
                    .frame(width: size * 1.9, height: size * 1.9)
                    .scaleEffect(1 + 0.12 * sin(time * 2.2))
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: ThinkingPalette.ring, center: .center, angle: .degrees(time * 150)),
                        lineWidth: size * 0.12
                    )
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: size * 0.15, height: size * 0.15)
                        .offset(x: size * (index == 1 ? 0.3 : 0.43))
                        .rotationEffect(.degrees(time * (120 + Double(index) * 70) + Double(index) * 120))
                }
                Circle()
                    .fill(RadialGradient(colors: [.white, ThinkingPalette.lavender, ThinkingPalette.violet], center: .center, startRadius: 0, endRadius: size * 0.18))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .scaleEffect(0.82 + 0.18 * sin(time * 3.1))
            }
            .frame(width: size, height: size)
        }
    }
}

/// The orb at rest, for the finished thought process.
struct ThinkingOrbStill: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(AngularGradient(colors: ThinkingPalette.ring, center: .center, angle: .degrees(-60)), lineWidth: size * 0.14)
            Circle()
                .fill(ThinkingPalette.lavender)
                .frame(width: size * 0.32, height: size * 0.32)
        }
        .frame(width: size, height: size)
    }
}

/// Text with a band of light moving across it.
private struct ShimmeringText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0) / 2.0
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.textSecondary, Theme.textPrimary, ThinkingPalette.lavender, Theme.textPrimary, Theme.textSecondary],
                        startPoint: UnitPoint(x: phase * 2.6 - 1.3, y: 0.5),
                        endPoint: UnitPoint(x: phase * 2.6 - 0.3, y: 0.5)
                    )
                )
        }
    }
}

/// A light that runs around the card's edge while the model thinks.
private struct GlowBorder: View {
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate * 80
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: ThinkingPalette.violet.opacity(0.75), location: 0.12),
                            .init(color: ThinkingPalette.pink.opacity(0.55), location: 0.22),
                            .init(color: .clear, location: 0.36),
                            .init(color: .clear, location: 1),
                        ],
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 1
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Thought trail

/// The thought process at a glance: one segment per step, its width growing with the step's length,
/// coloured from the first step to the last. While thinking, the newest segment pulses.
struct ThoughtTrail: View {
    let lengths: [Int]
    var isLive = false

    var body: some View {
        GeometryReader { geometry in
            let segments = Self.segments(lengths, maxCount: max(Int(geometry.size.width / 6), 1))
            let gap: CGFloat = 2
            let weights = segments.map { sqrt(Double(max($0, 1))) }
            let total = weights.reduce(0, +)
            let available = geometry.size.width - gap * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: gap) {
                ForEach(Array(weights.enumerated()), id: \.offset) { index, weight in
                    let isNewest = isLive && index == weights.count - 1
                    Capsule()
                        .fill(ThinkingPalette.color(at: weights.count > 1 ? Double(index) / Double(weights.count - 1) : 0))
                        .frame(width: max(3, available * CGFloat(weight / max(total, 1))))
                        .phaseAnimator(isNewest ? [0.35, 1.0] : [1.0]) { capsule, opacity in
                            capsule.opacity(opacity)
                        } animation: { _ in .easeInOut(duration: 0.6) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .animation(.easeOut(duration: 0.3), value: segments.count)
        }
        .overlay {
            if lengths.isEmpty {
                Capsule().fill(Theme.elevated)
            }
        }
    }

    /// Merges neighbouring steps when there are more than fit.
    private static func segments(_ lengths: [Int], maxCount: Int) -> [Int] {
        guard lengths.count > maxCount else { return lengths }
        let size = Int((Double(lengths.count) / Double(maxCount)).rounded(.up))
        return stride(from: 0, to: lengths.count, by: size).map { start in
            lengths[start..<min(start + size, lengths.count)].reduce(0, +)
        }
    }
}

// MARK: - After thinking

private struct ThinkingSummary: View {
    let text: String
    let seconds: Double?
    @State private var showsDetails = false
    @State private var hovering = false

    var body: some View {
        let steps = ThoughtSteps.split(text)
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 8) {
                ThinkingOrbStill(size: 14)
                Text(title(steps: steps.count))
                    .font(.system(size: 13, weight: .medium))
                ThoughtTrail(lengths: steps.map(\.count))
                    .frame(width: 70, height: 4)
                    .opacity(hovering || showsDetails ? 1 : 0.75)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showsDetails ? 90 : 0))
            }
            .foregroundStyle(hovering || showsDetails ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering || showsDetails ? Theme.hover : Color.white.opacity(0.03)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
            .animation(.snappy(duration: 0.2), value: showsDetails)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Gedankengang ansehen")
        // SwiftUI's own popover never appears inside the message list, so this one is AppKit's.
        .background(
            PopoverAnchor(isPresented: $showsDetails) {
                ThoughtProcessView(steps: steps, fullText: text, title: title(steps: steps.count))
            }
        )
    }

    private func title(steps: Int) -> String {
        var parts: [String] = []
        if let seconds {
            parts.append("Nachgedacht · \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s")
        } else {
            parts.append("Gedankengang")
        }
        if steps > 1 { parts.append("\(steps) Schritte") }
        return parts.joined(separator: " · ")
    }
}

/// Shows `content` in an `NSPopover` below the view it sits behind.
private struct PopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if isPresented, coordinator.popover == nil, view.window != nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingController(rootView: content())
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.delegate = coordinator
            coordinator.popover = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        } else if !isPresented, let popover = coordinator.popover {
            coordinator.popover = nil
            popover.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        var popover: NSPopover?

        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }
    }
}

/// The whole thought process as a timeline: one entry per step.
private struct ThoughtProcessView: View {
    let steps: [String]
    let fullText: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ThinkingOrbStill(size: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                CopyButton(text: fullText, help: "Gedankengang kopieren")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 10)

            ThoughtTrail(lengths: steps.map(\.count))
                .frame(height: 5)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)

            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        ThoughtStepRow(
                            text: step,
                            color: ThinkingPalette.color(at: steps.count > 1 ? Double(index) / Double(steps.count - 1) : 0),
                            isLast: index == steps.count - 1
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 560)
        .background(Theme.surface)
    }
}

private struct ThoughtStepRow: View {
    let text: String
    let color: Color
    let isLast: Bool

    var body: some View {
        Text(ThoughtSteps.attributed(text))
            .font(.system(size: 13))
            .lineSpacing(3)
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 24)
            .padding(.bottom, isLast ? 0 : 16)
            .overlay(alignment: .topLeading) {
                // Timeline: a dot per step, joined by a line to the next one.
                ZStack(alignment: .top) {
                    if !isLast {
                        Rectangle()
                            .fill(Theme.strongBorder)
                            .frame(width: 1.5)
                            .padding(.top, 12)
                    }
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.6), radius: 3)
                        .padding(.top, 5)
                }
                .frame(width: 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
    }
}
