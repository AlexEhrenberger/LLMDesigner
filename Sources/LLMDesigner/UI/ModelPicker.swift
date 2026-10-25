import SwiftUI

/// The source (LM Studio or Kapitsa) and the models it has loaded (and the others it offers) to choose from. Opens from
/// the connection row at the bottom of the sidebar.
struct ModelPickerPanel: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    @State private var showAvailable = false

    var body: some View {
        @Bindable var app = app

        VStack(alignment: .leading, spacing: 2) {
            Picker("Quelle", selection: $app.provider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)

            sectionLabel(app.provider == .kapitsa ? "In Kapitsa aktiv" : "In LM Studio geladen")

            if app.loadedModels.isEmpty {
                Text(emptyText)
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

            if app.provider == .kapitsa, !app.loadedModels.isEmpty {
                Text("Kapitsa stellt das Modell bereit, mit dem es gestartet wurde (kapitsa serve --model …).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
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

    private var emptyText: String {
        switch (app.provider, app.connection) {
        case (.kapitsa, .connected): "Kapitsa meldet kein aktives Modell."
        case (.kapitsa, _): "Keine Verbindung zu Kapitsa. Im Terminal starten mit „kapitsa serve --model 9b“."
        case (.lmStudio, .connected): "Aktuell ist kein Modell geladen. Lade eines in LM Studio oder wähle unten ein verfügbares Modell."
        case (.lmStudio, _): "Keine Verbindung zu LM Studio."
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
