import SwiftUI

/// Under the composer: memory (Thalamus) and context length as one capsule with two menus. The memory belongs to a
/// persona and only shows with one. Once the chat has started, the memory stays as a grey label and the context
/// turns into a meter; hovering it shows what fills it.
struct ChatSetupBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let hasPersona = app.activePersona != nil
        HStack(spacing: 0) {
            if hasPersona {
                MemoryControl()
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 14)
            }
            ContextControl()
                .padding(.leading, hasPersona ? 0 : 2)
        }
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

private struct MemoryControl: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let level = app.activeMemory
        if app.isChatSetupLocked {
            label(level, locked: true)
                .help("Gedächtnis (Thalamus): beim Start des Chats festgelegt")
        } else {
            Button { app.chooseMemory(level == .on ? .off : .on) } label: {
                label(level, locked: false)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(level == .on
                  ? "Gedächtnis ausschalten"
                  : "Gedächtnis einschalten: Die Persona ordnet deine Nachrichten ein, verdichtet sie zu Erinnerungen und erinnert sich daran")
        }
    }

    private func label(_ level: MemoryLevel, locked: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .medium))
            Text("Gedächtnis: \(level.label)")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(foreground(level, locked: locked))
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private func foreground(_ level: MemoryLevel, locked: Bool) -> Color {
        if locked { return Theme.textTertiary }
        if level == .on { return Theme.accent }
        return hovering ? Theme.textPrimary : Theme.textSecondary
    }
}

private struct ContextControl: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        if let chat = app.selectedChat {
            if let reload = app.contextReload, reload.modelID == (chat.modelId ?? app.preferredModelId) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Lädt das Modell mit \(LMModel.formatTokens(reload.length)) …")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 11)
            } else {
                ContextMeter(usage: app.contextUsage(for: chat), choice: chat.contextLength)
            }
        } else {
            menu
        }
    }

    private var menu: some View {
        let current = app.newChatContextLength
        let loaded = app.currentModel?.loadedContextLength
        return Menu {
            Section("Kontext") {
                ForEach(ContextChoice.lengths, id: \.self) { length in
                    Button { app.chooseContextLength(length) } label: {
                        let title = "\(ContextChoice.label(for: length)) (\(LMModel.formatTokens(length)))"
                        if length == current {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                    .disabled(!app.modelAllows(contextLength: length))
                }
            }
            if let loaded, loaded != current, app.currentModel?.state != nil {
                Section {
                    Text("Geladen mit \(LMModel.formatTokens(loaded)): wird beim Senden neu geladen")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11, weight: .medium))
                Text("Kontext: \(LMModel.formatTokens(current))")
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Wie lang das Gespräch werden kann. Längerer Kontext braucht mehr Speicher, und lange Gespräche werden langsamer.")
    }
}

/// Under the composer on the right: opens one of the applications. Writer Studio starts a new document;
/// Presenter Studio and Notes follow later.
struct ApplicationMenu: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Applikationen") {
                ForEach(StudioApplication.allCases) { application in
                    Button { app.openApplication(application) } label: {
                        Label(application.isAvailable ? application.title : "\(application.title) – bald", systemImage: application.symbol)
                    }
                    .disabled(!application.isAvailable)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                Text("Applikationen")
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 11)
            .padding(.trailing, 11)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .overlay(Capsule().strokeBorder(Theme.border))
        .help("Applikation öffnen, in der dir die KI hilft")
    }
}

/// A small bar with how much of the context is taken; hovering it shows what takes it.
private struct ContextMeter: View {
    let usage: ContextUsage
    /// The chat's choice; nil for chats from before the setting.
    let choice: Int?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            ContextBar(usage: usage, height: 5)
                .frame(width: 84)
            Text("\(ContextNumbers.short(usage.used)) / \(LMModel.formatTokens(usage.capacity))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(ContextNumbers.color(for: usage.fraction, normal: Theme.textSecondary))
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .bottomLeading) {
            if hovering {
                ContextCard(usage: usage, choice: choice)
                    .fixedSize()
                    .offset(x: -8, y: -34)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ContextCard: View {
    let usage: ContextUsage
    let choice: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Kontext")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(choice.map { "\(ContextChoice.label(for: $0)) (\(LMModel.formatTokens($0)))" } ?? "\(LMModel.formatTokens(usage.capacity)) geladen")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 12)
                Text("\(Int(usage.fraction * 100)) %")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ContextNumbers.color(for: usage.fraction, normal: Theme.textSecondary))
            }
            ContextBar(usage: usage, height: 8)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(usage.parts) { part in
                    row(color: ContextNumbers.color(of: part.kind), label: part.label, tokens: part.tokens)
                }
                row(color: nil, label: "Frei", tokens: usage.free)
            }

            Divider().overlay(Theme.border)
            Text(footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private func row(color: Color?, label: String, tokens: Int) -> some View {
        HStack(spacing: 8) {
            Group {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(Theme.textTertiary, lineWidth: 1)
                }
            }
            .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(color == nil ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("≈ \(tokens.formatted())")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var footnote: String {
        var lines = [usage.isCalibrated
            ? "Geschätzt und mit der Zählung von LM Studio zur letzten Antwort abgeglichen."
            : "Geschätzt, etwa 3,5 Zeichen pro Token."]
        if let loaded = usage.loadedLength {
            lines.append("Das Modell ist gerade mit \(LMModel.formatTokens(loaded)) geladen; vor der nächsten Antwort lädt die App es mit \(LMModel.formatTokens(usage.capacity)) neu.")
        }
        if usage.fraction >= 0.9 {
            lines.append("Der Kontext ist fast voll. Für längere Gespräche einen neuen Chat mit mehr Kontext beginnen.")
        }
        return lines.joined(separator: " ")
    }
}

/// The parts side by side, each as wide as its share of the context.
private struct ContextBar: View {
    let usage: ContextUsage
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(usage.parts) { part in
                    Rectangle()
                        .fill(ContextNumbers.color(of: part.kind))
                        .frame(width: max(1.5, geometry.size.width * CGFloat(part.tokens) / CGFloat(max(usage.capacity, 1))))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

private enum ContextNumbers {
    /// 3,1K – one decimal under 10K.
    static func short(_ tokens: Int) -> String {
        guard tokens >= 1_024 else { return "\(tokens)" }
        let value = Double(tokens) / 1_024
        return value < 10 ? value.formatted(.number.precision(.fractionLength(1))) + "K" : "\(Int(value.rounded()))K"
    }

    static func color(for fraction: Double, normal: Color) -> Color {
        if fraction >= 0.95 { return Theme.danger }
        if fraction >= 0.8 { return Theme.warning }
        return normal
    }

    static func color(of kind: ContextUsage.Kind) -> Color {
        switch kind {
        case .system: Theme.accent
        case .memory: Color(hex: 0xD9D0FF)
        case .tools: Color(hex: 0x6FD3FF)
        case .questions: Color(hex: 0x3FD68F)
        case .answers: Color(hex: 0xFF8FD6)
        case .images: Color(hex: 0xF2B14C)
        }
    }
}
