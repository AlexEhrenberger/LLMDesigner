import AppKit
import SwiftUI

/// The terminal-like strip where the agents' log runs in: time, run, kind and a sentence, newest at the bottom, and
/// below it what the working model writes right now. Always dark, in both designs, like a terminal.
struct AgentTerminalView: View {
    @Environment(AppModel.self) private var app
    /// Only this run; nil shows the recent runs together.
    var run: UUID?
    var compact = false
    @State private var follows = true

    static let background = Color(nsColor: NSColor(hex: 0x0B0B0E))
    static let text = Color(nsColor: NSColor(hex: 0xD4D4DA))
    static let dim = Color(nsColor: NSColor(hex: 0x6F6F7A))

    static func color(_ kind: AgentLogLine.Kind) -> Color {
        let hex: UInt32 = switch kind {
        case .info: 0x8E8E99
        case .step: 0xA996FF
        case .tool: 0x5CC8E8
        case .model: 0xC9B8FF
        case .git: 0xF0A35E
        case .question: 0xF2C14C
        case .pause: 0xE8D36B
        case .error: 0xFF6B6B
        case .done: 0x3FD68F
        }
        return Color(nsColor: NSColor(hex: hex))
    }

    var body: some View {
        let center = app.agents
        let lines = center.terminalLines(run: run, limit: compact ? 200 : 400)
        let liveRun = run ?? center.activeRunID
        let live = liveRun.flatMap { center.live[$0] }
        VStack(spacing: 0) {
            header(count: lines.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if lines.isEmpty {
                            Text("$ Noch keine Agentenaktivität. Starte eine Aufgabe oder beschreibe eine neue im Chat.")
                                .foregroundStyle(Self.dim)
                                .padding(.vertical, 4)
                        }
                        ForEach(lines) { line in
                            row(line)
                        }
                        if let live, center.activeRunID != nil {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("▍")
                                    .foregroundStyle(Self.color(.model))
                                    .phaseAnimator([false, true]) { content, on in content.opacity(on ? 1 : 0.2) } animation: { _ in .easeInOut(duration: 0.6) }
                                Text(live)
                                    .foregroundStyle(Self.color(.model).opacity(0.85))
                                    .lineLimit(2)
                            }
                            .padding(.top, 2)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: compact ? 10.5 : 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lines.last?.id) { _, _ in
                    if follows { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onChange(of: live) { _, _ in
                    if follows { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(Self.background)
        .environment(\.colorScheme, .dark)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
            Text(run == nil ? "Agentenprotokoll" : "Protokoll dieses Laufs")
                .font(.system(size: 11.5, weight: .semibold))
            if app.agents.awake.isHolding {
                Label("Mac bleibt wach", systemImage: "cup.and.saucer.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Self.color(.pause))
                    .help("Solange ein Agent arbeitet, schläft der Mac nicht von selbst ein. Den Deckel zuzuklappen schickt ihn trotzdem schlafen.")
            }
            Spacer(minLength: 0)
            Toggle(isOn: $follows) {
                Text("Mitlaufen").font(.system(size: 10.5))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            CopyButton(help: "Protokoll kopieren", size: 10.5, frameSize: 22) {
                app.agents.terminalLines(run: run, limit: 600).map(Self.plain).joined(separator: "\n")
            }
        }
        .foregroundStyle(Self.dim)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color(nsColor: NSColor(hex: 0x131317)))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func row(_ line: AgentCenter.TerminalLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.line.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .foregroundStyle(Self.dim)
            if run == nil, !compact {
                Text(AgentWords.excerpt(line.runTitle, limit: 18))
                    .foregroundStyle(Self.dim.opacity(0.9))
                    .frame(width: 128, alignment: .leading)
                    .lineLimit(1)
            }
            Text(line.line.kind.tag.padding(toLength: 7, withPad: " ", startingAt: 0))
                .foregroundStyle(Self.color(line.line.kind))
            Text(line.line.text)
                .foregroundStyle(line.line.kind == .error ? Self.color(.error) : Self.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func plain(_ line: AgentCenter.TerminalLine) -> String {
        let time = line.line.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        return "\(time)  \(line.runTitle)  [\(line.line.kind.tag)]  \(line.line.text)"
    }
}
