import SwiftUI

struct ModelPickerButton: View {
    @Environment(AppModel.self) private var app
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 7) {
                StatusDot(color: statusColor)
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.titleBarControlSize)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || isOpen ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Modell wählen")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ModelPickerPanel { isOpen = false }
                .environment(app)
        }
        .onChange(of: isOpen) { _, open in
            if open { Task { await app.refreshModels() } }
        }
    }

    private var title: String {
        if let model = app.currentModel { return model.displayName }
        if let id = app.currentModelId { return id }
        return app.connection == .connected ? "Kein Modell geladen" : "Kein Modell"
    }

    private var statusColor: Color {
        guard app.connection == .connected else { return app.connection.color }
        guard let model = app.currentModel else { return Theme.textTertiary }
        return model.isLoaded ? Theme.success : Theme.warning
    }
}

private struct ModelPickerPanel: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    @State private var showAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("In LM Studio geladen")

            if app.loadedModels.isEmpty {
                Text(app.connection == .connected
                     ? "Aktuell ist kein Modell geladen. Lade eines in LM Studio oder wähle unten ein verfügbares Modell."
                     : "Keine Verbindung zu LM Studio.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(app.loadedModels) { model in
                    ModelRow(model: model, isSelected: model.id == app.currentModelId) {
                        app.selectModel(model.id)
                        close()
                    }
                }
            }

            if !app.availableModels.isEmpty {
                Divider().overlay(Theme.border).padding(.vertical, 6)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showAvailable.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Weitere Modelle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Tag(text: "\(app.availableModels.count)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(showAvailable ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAvailable {
                    Text("Nicht geladen. LM Studio lädt sie beim ersten Senden (Just-in-Time).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(app.availableModels) { model in
                                ModelRow(model: model, isSelected: model.id == app.currentModelId) {
                                    app.selectModel(model.id)
                                    close()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }

            Divider().overlay(Theme.border).padding(.vertical, 6)
            HStack(spacing: 8) {
                StatusDot(color: app.connection.color, size: 6)
                Text(app.hostDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Task { await app.refreshModels() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 380)
        .background(Theme.elevated)
        .onAppear {
            showAvailable = app.currentModel.map { !$0.isLoaded } ?? false
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }
}

private struct ModelRow: View {
    let model: LMModel
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: model.isVision ? "eye" : "cpu")
                    .font(.system(size: 13))
                    .foregroundStyle(model.isLoaded ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(model.isLoaded ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        if let quantization = model.quantization { Tag(text: quantization) }
                        if let format = model.compatibilityType { Tag(text: format.uppercased()) }
                        if model.isVision { Tag(text: "Vision", color: Theme.accent) }
                        if model.supportsTools { Tag(text: "Tools") }
                        if let context = contextLabel { Tag(text: context) }
                    }
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.id)
    }

    private var contextLabel: String? {
        if let loaded = model.loadedContextLength { return "\(LMModel.formatTokens(loaded)) ctx" }
        if let max = model.maxContextLength { return "max \(LMModel.formatTokens(max))" }
        return nil
    }
}
