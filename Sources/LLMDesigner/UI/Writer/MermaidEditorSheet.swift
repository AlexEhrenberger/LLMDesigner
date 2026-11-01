import SwiftUI

/// The state of the Mermaid editor: the code, its preview, and the model writing or changing it.
@MainActor
@Observable
final class MermaidEditorModel {
    var code: String
    var caption: String
    var description = ""
    /// The text around the place (or the selection) goes to the model with the description.
    var usesContext: Bool
    let context: String
    let isExisting: Bool
    var previewDark = true
    private(set) var svg: String?
    private(set) var renderError: String?
    private(set) var isWriting = false
    private(set) var isCommitting = false
    var message: String?
    private var renderTask: Task<Void, Never>?

    init(request: WriterFigureRequest) {
        code = request.mermaid
        caption = request.reference?.caption ?? ""
        context = request.context
        isExisting = request.isExisting
        usesContext = !request.context.isEmpty && !request.isExisting
    }

    var style: WriterMermaid.Style {
        get { WriterMermaid.style(of: code) }
        set { code = WriterMermaid.applying(newValue, to: code) }
    }

    var type: WriterMermaid.DiagramType? { WriterMermaid.type(of: code) }

    /// Draws the preview a moment after the last change.
    func scheduleRender() {
        renderTask?.cancel()
        let code = code, dark = previewDark
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let result = try await MermaidRenderer.shared.render(code, palette: dark && WriterMermaid.style(of: code).theme == nil ? .dark : .light)
                guard !Task.isCancelled else { return }
                self?.svg = result.svg
                self?.renderError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.renderError = error.localizedDescription
            }
        }
    }

    /// The loaded model writes the diagram from the description (or changes the one there is); Mermaid checks it, and
    /// code it can't read goes back to the model once to be repaired.
    func write(_ app: AppModel) async {
        guard let client = app.client, let model = app.currentModelId else {
            message = "Kein Sprachmodell gewählt. Wähle eines unten links in der Seitenleiste."
            return
        }
        let request = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty || usesContext else {
            message = "Beschreibe, was das Diagramm zeigen soll."
            return
        }
        isWriting = true
        message = nil
        defer { isWriting = false }
        let style = self.style
        let body = WriterMermaid.splitFrontMatter(code).body.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepsCurrent = isExisting || body != WriterMermaid.template(type ?? .flowchart).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let messages = WriterMermaid.messages(
                description: request.isEmpty ? "Fasse den Text als passendes Diagramm zusammen." : request,
                type: nil, context: usesContext ? context : "", current: keepsCurrent && !request.isEmpty ? code : nil
            )
            var answer = WriterMermaid.code(inAnswer: try await client.complete(model: model, messages: messages, temperature: 0.3, maxTokens: 2_000))
            // Code Mermaid can't read goes back to the model, twice at most.
            for _ in 0..<2 {
                do {
                    _ = try await MermaidRenderer.shared.render(answer, palette: .light)
                    break
                } catch {
                    let repaired = try await client.complete(
                        model: model, messages: WriterMermaid.repairMessages(code: answer, error: error.localizedDescription), temperature: 0.2, maxTokens: 2_000
                    )
                    answer = WriterMermaid.code(inAnswer: repaired)
                }
            }
            guard !answer.isEmpty else {
                message = "Das Modell hat kein Diagramm geschrieben."
                return
            }
            code = WriterMermaid.applying(style, to: answer)
            scheduleRender()
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    /// The pictures for the document; nil (with a message) when Mermaid can't draw the code.
    func images() async -> (WriterFigureImages, CGSize)? {
        isCommitting = true
        defer { isCommitting = false }
        do {
            let result = try await FlowImageRenderer.shared.images(mermaid: code)
            return (WriterFigureImages(light: result.light, dark: result.dark, pdf: result.pdf), result.size)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }
}

/// Makes or edits a Mermaid diagram: the code with a live preview, templates for every kind of diagram, the look, and
/// the loaded model writing the code from a description (or from the selected text).
struct MermaidEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var model: MermaidEditorModel
    let onCommit: (_ images: WriterFigureImages, _ code: String, _ caption: String, _ width: Int?) -> Void
    let onCancel: () -> Void

    init(request: WriterFigureRequest, onCommit: @escaping (WriterFigureImages, String, String, Int?) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: MermaidEditorModel(request: request))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FigureSheetHeader(symbol: "point.3.connected.trianglepath.dotted", title: model.isExisting ? "Mermaid-Diagramm bearbeiten" : "Neues Mermaid-Diagramm") {
                Menu {
                    ForEach(WriterMermaid.DiagramType.allCases) { type in
                        Button(type.label, systemImage: type.symbol) {
                            model.code = WriterMermaid.applying(model.style, to: WriterMermaid.template(type))
                        }
                    }
                } label: {
                    Label(model.type?.label ?? "Vorlage", systemImage: model.type?.symbol ?? "square.grid.2x2")
                        .font(.system(size: 12))
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Mit einer Vorlage beginnen – ersetzt den Code")
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    assistant
                    VStack(alignment: .leading, spacing: 6) {
                        FigureSectionTitle("Code", detail: "Mermaid 11")
                        TextEditor(text: $model.code)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.shade.opacity(0.25)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(model.renderError == nil ? Theme.border : Theme.danger.opacity(0.6)))
                        if let error = model.renderError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.warning)
                                .lineLimit(3)
                        }
                    }
                }
                .frame(width: 400)
                VStack(alignment: .leading, spacing: 12) {
                    preview
                    styleControls
                    FigureField(placeholder: "Bildunterschrift (im PDF „Abbildung n: …“)", text: $model.caption)
                }
                .frame(width: 480)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
            FigureSheetFooter(
                hint: "Mermaid zeichnet aus Text: flowchart, sequenceDiagram, mindmap, timeline, gantt, pie …",
                commitTitle: model.isExisting ? "Übernehmen" : "Einfügen",
                isWorking: model.isCommitting,
                canCommit: model.renderError == nil && !model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isWriting,
                onCancel: onCancel,
                onCommit: commit
            )
        }
        .padding(20)
        .frame(width: 940, height: 660)
        .background(Theme.surface)
        .onAppear {
            // In the light design the sheet is always white.
            if colorScheme == .light { model.previewDark = false }
            model.scheduleRender()
        }
        .onChange(of: model.code) { _, _ in model.scheduleRender() }
        .onChange(of: model.previewDark) { _, _ in model.scheduleRender() }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            FigureSectionTitle("Mit KI", detail: app.currentModelId.map { "– \($0)" })
            HStack(spacing: 6) {
                FigureField(placeholder: model.isExisting ? "Was soll sich ändern? z. B. „füge einen Schritt Prüfen ein“" : "Beschreibe das Diagramm, z. B. „Ablauf einer Bestellung“", text: $model.description)
                    .onSubmit { Task { await model.write(app) } }
                Button {
                    Task { await model.write(app) }
                } label: {
                    HStack(spacing: 5) {
                        if model.isWriting { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(model.isExisting ? "Ändern" : "Erstellen")
                    }
                }
                .disabled(model.isWriting)
            }
            if !model.context.isEmpty {
                Toggle("Den Text an der Stelle (oder die Markierung) einbeziehen", isOn: $model.usesContext)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)))
    }

    private var preview: some View {
        let ownTheme = model.style.theme != nil
        let dark = model.previewDark
        return ZStack(alignment: .topTrailing) {
            Group {
                if let svg = model.svg {
                    SVGPreview(svg: svg, background: ownTheme ? "#ffffff" : "transparent")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 330)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dark ? Color(nsColor: WriterPalette.dark.page) : .white))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
            Picker("", selection: $model.previewDark) {
                Text("Dunkel").tag(true)
                Text("Papier").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
        }
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FigureSectionTitle("Aussehen")
            HStack(spacing: 6) {
                FigureChip(title: "App-Farben", isSelected: model.style.theme == nil) { model.style.theme = nil }
                    .help("Hell auf weißem Papier und im Druck, dunkel auf dem dunklen Blatt")
                ForEach(WriterMermaid.Style.Theme.allCases) { theme in
                    FigureChip(title: theme.label, isSelected: model.style.theme == theme) { model.style.theme = theme }
                }
            }
            HStack(spacing: 6) {
                Toggle("Wie von Hand gezeichnet", isOn: Binding(get: { model.style.handDrawn }, set: { model.style.handDrawn = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                if model.type == .flowchart {
                    Picker("Linien", selection: Binding(get: { model.style.curve ?? .basis }, set: { model.style.curve = $0 == .basis ? nil : $0 })) {
                        ForEach(WriterMermaid.Style.Curve.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Picker("Richtung", selection: Binding(get: { WriterMermaid.direction(of: model.code) ?? "TD" },
                                                         set: { model.code = WriterMermaid.setting(direction: $0, in: model.code) })) {
                        Text("↓ von oben").tag("TD")
                        Text("→ von links").tag("LR")
                        Text("↑ von unten").tag("BT")
                        Text("← von rechts").tag("RL")
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
        }
    }

    private func commit() {
        Task {
            guard let (images, size) = await model.images() else { return }
            // As wide as drawn, at most the column.
            let width = min(100, max(30, Int((size.width / WriterImageStore.referenceColumnWidth * 100).rounded())))
            onCommit(images, model.code, model.caption.trimmingCharacters(in: .whitespacesAndNewlines), width)
        }
    }
}
