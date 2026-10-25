import SwiftUI
import AppKit

/// The state of the Draw Things sheet.
@MainActor
@Observable
final class ImageGeneratorModel {
    var info: GeneratedImageInfo
    var caption: String
    let isExisting: Bool
    let source: String?
    let documentTitle: String
    let context: String
    var usesContext: Bool
    private(set) var isWritingPrompt = false
    var message: String?
    private(set) var status: Status = .checking
    /// The caption came from the model and may be replaced by the next one.
    private var captionFromModel = false
    private var promptTask: Task<Void, Never>?

    enum Status: Equatable {
        case checking
        case ready(model: String?)
        case unreachable(String)
    }

    init(request: WriterImageGenerationRequest) {
        info = request.info
        caption = request.caption
        isExisting = request.isExisting
        source = request.source
        documentTitle = request.documentTitle
        context = request.context
        usesContext = !request.context.isEmpty
    }

    var hasPrompt: Bool { !info.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasDescription: Bool { !info.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canGenerate: Bool { (hasPrompt || hasDescription || usesContext) && !isWritingPrompt }

    func checkDrawThings(_ center: ImageGenerationCenter) async {
        guard let client = center.client else {
            status = .unreachable("Die Adresse von Draw Things ist ungültig.")
            return
        }
        do {
            let reply = try await client.status()
            status = .ready(model: reply.model)
        } catch {
            status = .unreachable(error.localizedDescription)
        }
    }

    /// The loaded model turns the description into a prompt for Qwen-Image (and suggests a caption).
    func writePrompt(_ app: AppModel) async {
        guard let client = app.client, let model = app.currentModelId else {
            message = "Kein Sprachmodell gewählt. Wähle eines unten links in der Seitenleiste."
            return
        }
        isWritingPrompt = true
        message = nil
        defer { isWritingPrompt = false }
        let request = ImagePromptBuilder.Request(
            description: info.description, style: info.style, format: info.format,
            documentTitle: documentTitle, context: usesContext ? context : ""
        )
        do {
            let answer = try await client.complete(
                model: model, messages: ImagePromptBuilder.messages(for: request), temperature: 0.7, maxTokens: 900
            )
            let result = try ImagePromptBuilder.parse(answer)
            info.prompt = result.prompt
            if !result.caption.isEmpty, caption.isEmpty || captionFromModel {
                caption = result.caption
                captionFromModel = true
            }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    func captionEdited() { captionFromModel = false }
}

/// Describe a picture in your own words, let the model write the prompt for Qwen-Image, choose format and
/// quality; the picture is then made in the background where the placeholder is.
struct ImageGeneratorSheet: View {
    @Environment(AppModel.self) private var app
    @State private var model: ImageGeneratorModel
    @FocusState private var focus: Field?
    let onCommit: (_ info: GeneratedImageInfo, _ caption: String, _ generate: Bool) -> Void
    let onCancel: () -> Void

    private enum Field { case description, prompt, caption }

    init(request: WriterImageGenerationRequest, onCommit: @escaping (GeneratedImageInfo, String, Bool) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: ImageGeneratorModel(request: request))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    descriptionSection
                    promptSection
                    captionField
                }
                .frame(width: 440)
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    formatSection
                    qualitySection
                }
                .frame(width: 250)
            }
            if let message = model.message {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(message).foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 12))
            }
            footer
        }
        .padding(20)
        .frame(width: 750)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
        .task {
            // Checked again every few seconds while Draw Things isn't there, so starting it is noticed.
            while !Task.isCancelled {
                await model.checkDrawThings(app.imageGeneration)
                if case .ready = model.status { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppear { focus = model.isExisting && model.hasPrompt ? nil : .description }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(model.isExisting ? "Bild mit Draw Things" : "Neues Bild mit Draw Things")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let (color, text, help): (Color, String, String) = switch model.status {
        case .checking: (Theme.textTertiary, "Draw Things …", "Verbindung wird geprüft")
        case .ready(let name): (Theme.success, "Draw Things bereit", name.map { "In Draw Things gewählt: \($0)" } ?? "Verbunden")
        case .unreachable(let message): (Theme.danger, "Draw Things nicht erreichbar", message)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .help(help)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Was soll das Bild zeigen?", detail: "in deinen Worten")
            editor(text: Binding(get: { model.info.description }, set: { model.info.description = $0 }),
                   placeholder: "z. B. Eine Forscherin schaut im Labor durch ein Mikroskop, warmes Abendlicht",
                   field: .description, height: 70)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), alignment: .leading, spacing: 5) {
                ForEach(ImageStyle.allCases, id: \.self) { style in
                    Chip(title: style.label, isSelected: model.info.style == style) { model.info.style = style }
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.writePrompt(app) }
                } label: {
                    HStack(spacing: 6) {
                        if model.isWritingPrompt {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(model.hasPrompt ? "Prompt neu schreiben lassen" : "Prompt mit KI schreiben")
                    }
                }
                .controlSize(.regular)
                .disabled(model.isWritingPrompt || (!model.hasDescription && !model.usesContext))
                .help("Das geladene Modell macht aus der Beschreibung einen englischen Prompt, wie Qwen Image ihn am besten versteht")
                if !model.context.isEmpty {
                    Toggle("Text um die Stelle mitlesen", isOn: Binding(get: { model.usesContext }, set: { model.usesContext = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .help("Die Absätze vor und nach dem Bild helfen dem Modell, ein passendes Motiv zu finden")
                }
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Prompt für Qwen Image", detail: "Englisch · Text im Bild in \"Anführungszeichen\"")
            editor(text: Binding(get: { model.info.prompt }, set: { model.info.prompt = $0 }),
                   placeholder: "Wird von der KI geschrieben – oder selbst eingeben.",
                   field: .prompt, height: 120)
                .opacity(model.isWritingPrompt ? 0.5 : 1)
        }
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Bildunterschrift", detail: "optional")
            TextField("z. B. Im Labor", text: Binding(get: { model.caption }, set: { model.caption = $0; model.captionEdited() }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .focused($focus, equals: .caption)
        }
    }

    private var preview: some View {
        let aspect = model.info.format.aspect
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x141417))
            if let source = model.source, let image = WriterImageStore.displayImage(for: source) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                    let size = model.info.format.size(model.info.resolution)
                    Text("\(size.width) × \(size.height)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 170)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .animation(.easeInOut(duration: 0.2), value: model.info.format)
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Format", detail: nil)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                ForEach(ImageFormat.allCases, id: \.self) { format in
                    Chip(title: format.label, isSelected: model.info.format == format) { model.info.format = format }
                }
            }
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Qualität", detail: nil)
            Picker("", selection: Binding(get: { model.info.resolution }, set: { model.info.resolution = $0 })) {
                ForEach(ImageResolution.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            Picker("", selection: Binding(get: { model.info.profile }, set: { model.info.profile = $0 })) {
                ForEach(DrawThingsProfile.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .help("Die Voreinstellungen legen Modell, LoRA, Schritte und Guidance fest – unabhängig davon, was in Draw Things gerade eingestellt ist.")
            Toggle("Qualitätszusatz anhängen", isOn: Binding(get: { model.info.qualitySuffix }, set: { model.info.qualitySuffix = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Hängt „\(ImagePromptBuilder.qualitySuffix)“ an, wie es die Qwen-Image-Modellkarte empfiehlt")
        }
    }

    private var footer: some View {
        HStack {
            Text("Das Bild entsteht im Hintergrund – du kannst weiterschreiben.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Abbrechen", action: onCancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Button(model.isExisting ? "Speichern" : "Als Platzhalter einfügen") { commit(generate: false) }
                .controlSize(.large)
                .disabled(model.isWritingPrompt)
                .help("Merkt sich Beschreibung und Prompt; generiert wird später")
            Button {
                commit(generate: true)
            } label: {
                HStack(spacing: 6) {
                    if model.isWritingPrompt { ProgressView().controlSize(.small) }
                    Image(systemName: "wand.and.stars")
                    Text("Generieren")
                }
                .frame(minWidth: 110)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canGenerate)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func editor(text: Binding<String>, placeholder: String, field: Field, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .focused($focus, equals: field)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focus == field ? Theme.accent.opacity(0.6) : Theme.border))
    }

    /// Without a prompt, the model writes one first.
    private func commit(generate: Bool) {
        guard !model.isWritingPrompt else { return }
        Task {
            if generate, !model.hasPrompt {
                await model.writePrompt(app)
                guard model.hasPrompt else { return }
            }
            app.imageGeneration.defaults = model.info
            onCommit(model.info, model.caption, generate)
        }
    }
}

private struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? Theme.accent.opacity(0.18) : Color.white.opacity(hovering ? 0.08 : 0.04)))
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
