import SwiftUI
import UniformTypeIdentifiers

/// Main area while the sidebar shows the personas: the editor of the selected persona.
struct PersonaLibraryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if !app.sidebarVisible {
                    SidebarToggleButton()
                    IconButton(systemName: "plus", help: "Neue Persona (⌥⇧⌘N)", frameSize: Theme.titleBarControlSize) { app.createPersona() }
                        .padding(.trailing, 6)
                }
                Text("Personas")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            .padding(.leading, app.sidebarVisible ? 14 : Theme.trafficLightInset)
            .padding(.trailing, 14)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            if let persona = app.selectedPersona {
                PersonaEditor(persona: persona)
                    .id(persona.id)
            } else {
                PersonaLibraryIntro()
            }
        }
        .background(Theme.background)
    }
}

private struct PersonaEditor: View {
    @Environment(AppModel.self) private var app
    let persona: Persona
    @State private var pendingDelete = false
    @State private var voices = QwenTTSClient.fallbackVoices
    @FocusState private var nameFocused: Bool

    var body: some View {
        let chats = app.chatCount(withPersona: persona.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 22) {
                    AvatarPicker(persona: persona)
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("", text: text(\.name), prompt: Text("Name der Persona").foregroundStyle(Theme.textTertiary))
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($nameFocused)
                        HStack(spacing: 8) {
                            ActionPill(title: "Chat starten", symbol: "square.and.pencil", isProminent: true) {
                                app.startChat(withPersona: persona.id)
                            }
                            .help("Neuen Chat mit \(persona.displayName) beginnen")
                            if chats > 0 {
                                Tag(text: chats == 1 ? "1 Chat" : "\(chats) Chats")
                            }
                        }
                    }
                }
                .padding(.bottom, 28)

                EditorSection(
                    title: "Biografie",
                    caption: "Wer \(subject) ist: Herkunft, Lebensgeschichte, Beruf, Menschen im Leben, was \(subject) geprägt hat."
                ) {
                    PersonaTextArea(
                        text: text(\.biography),
                        placeholder: "Zum Beispiel:\n„Mira ist 34, Meeresbiologin aus Kiel. Sie ist an der Ostsee aufgewachsen, hat zwei Jahre auf einem Forschungsschiff gelebt und …“",
                        height: 180
                    )
                }

                EditorSection(
                    title: "Verhalten",
                    caption: "Wie \(subject) ist und reagiert: Temperament, Sprechweise, Humor, Eigenheiten, was \(subject) mag und was nicht."
                ) {
                    PersonaTextArea(
                        text: text(\.behavior),
                        placeholder: "Zum Beispiel:\n„Neugierig und direkt, mit trockenem Humor. Stellt gern Gegenfragen, wird bei Ungerechtigkeit deutlich, …“",
                        height: 140
                    )
                }

                EditorSection(
                    title: "Stimme",
                    caption: "Mit dieser Qwen-TTS-Stimme spricht \(persona.displayName) im Gesprächsmodus und beim Vorlesen. Die Sprechweise geht als Anweisung an Qwen TTS."
                ) {
                    VoiceSettings(persona: persona, voices: voices)
                }

                EditorSection(
                    title: "Dateien",
                    caption: "Darin kann \(persona.displayName) beim Antworten suchen und nachlesen, z. B. Tagebücher, Briefe, Notizen oder Fachtexte. Sie kommen nicht in den System-Prompt, sondern werden bei Bedarf durchsucht."
                ) {
                    PersonaFilesList(persona: persona)
                }

                ThalamusEntriesSection(persona: persona)

                HStack(spacing: 8) {
                    PromptSize(persona: persona)
                    Spacer(minLength: 12)
                    IconButton(systemName: "trash", help: "Persona löschen", size: 13.5) { pendingDelete = true }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .task {
            guard app.newPersonaID == persona.id else { return }
            app.newPersonaID = nil
            try? await Task.sleep(for: .milliseconds(80))
            nameFocused = true
        }
        .task {
            if let loaded = try? await QwenTTSClient().voices(), !loaded.isEmpty { voices = loaded }
        }
        .alert("Persona löschen?", isPresented: $pendingDelete) {
            Button("Löschen", role: .destructive) { app.deletePersona(persona.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(PersonaDeleteText.message(for: persona, chats: chats))
        }
    }

    /// The name in the hints, or "die Persona" while it has none.
    private var subject: String {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "die Persona" : name
    }

    private func text(_ field: WritableKeyPath<Persona, String>) -> Binding<String> {
        let id = persona.id
        return Binding(
            get: { app.persona(id)?[keyPath: field] ?? "" },
            set: { value in app.updatePersona(id) { $0[keyPath: field] = value } }
        )
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            content
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 26)
    }
}

/// The profile picture: click or drop a picture to set it, right-click to remove it.
private struct AvatarPicker: View {
    @Environment(AppModel.self) private var app
    let persona: Persona
    @State private var hovering = false
    @State private var isDropTarget = false

    var body: some View {
        Button { app.chooseAvatar(for: persona.id) } label: {
            PersonaAvatar(persona: persona, size: 112)
                .overlay {
                    if hovering || isDropTarget {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .overlay {
                                VStack(spacing: 4) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 18))
                                    Text(persona.avatarFileName == nil ? "Bild wählen" : "Bild ändern")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundStyle(Color.white.opacity(0.9))
                            }
                            .transition(.opacity)
                    }
                }
                .overlay(Circle().strokeBorder(Theme.accent.opacity(isDropTarget ? 0.9 : 0), lineWidth: 2))
                .background(Circle().fill(persona.tintColor.opacity(persona.avatarFileName == nil ? 0 : 0.28)).blur(radius: 18))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Profilbild wählen – oder ein Bild hierher ziehen")
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            Task {
                if let source = await DroppedItems.imageSource(from: provider) { app.setAvatar(of: persona.id, from: source) }
            }
            return true
        }
        .contextMenu {
            Button("Bild wählen …", systemImage: "photo") { app.chooseAvatar(for: persona.id) }
            if persona.avatarFileName != nil {
                Button("Bild entfernen", systemImage: "trash", role: .destructive) { app.removeAvatar(of: persona.id) }
            }
        }
    }
}

/// A text field for the biography or the behaviour, with an example while it is empty.
private struct PersonaTextArea: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Voice, way of speaking and a sample to listen to.
private struct VoiceSettings: View {
    @Environment(AppModel.self) private var app
    let persona: Persona
    let voices: [QwenTTSClient.Voice]
    @State private var hovering = false

    var body: some View {
        let speech = app.speakingMessageID == persona.id ? app.speechState : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button("Wie in den Einstellungen") { app.updatePersona(persona.id, saveAfter: nil) { $0.voice = nil } }
                    Divider()
                    Section("Weiblich") {
                        ForEach(voices.filter { $0.gender == "female" }) { voice in voiceButton(voice) }
                    }
                    Section("Männlich") {
                        ForEach(voices.filter { $0.gender != "female" }) { voice in voiceButton(voice) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12, weight: .medium))
                        Text(voiceLabel)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(hovering ? Theme.hover : Color.white.opacity(0.04)))
                    .overlay(Capsule().strokeBorder(Theme.border))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hovering = $0 }

                ActionPill(
                    title: speech == nil ? "Probehören" : (speech == .preparing ? "Wird erzeugt …" : "Stopp"),
                    symbol: speech == nil ? "play.fill" : "stop.fill",
                    isProminent: false
                ) { app.previewVoice(of: persona.id) }
            }

            TextField("", text: style, prompt: Text("Sprechweise (optional), z. B. ruhig und warm, leicht heiser, schnell und fröhlich").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.strongBorder))
                .disabled(persona.voice == nil)
                .opacity(persona.voice == nil ? 0.5 : 1)
                .help(persona.voice == nil ? "Erst eine eigene Stimme wählen" : "Anweisung an Qwen TTS, wie die Stimme klingen soll")
        }
    }

    private func voiceButton(_ voice: QwenTTSClient.Voice) -> some View {
        Button {
            app.updatePersona(persona.id, saveAfter: nil) { $0.voice = voice.id }
        } label: {
            if persona.voice == voice.id {
                Label(voice.name, systemImage: "checkmark")
            } else {
                Text(voice.name)
            }
        }
    }

    private var voiceLabel: String {
        guard let id = persona.voice else {
            let fallback = app.speechEngine == .system ? "macOS-Stimme" : (voices.first { $0.id == app.qwenVoice }?.name ?? app.qwenVoice)
            return "Wie in den Einstellungen (\(fallback))"
        }
        return voices.first { $0.id == id }?.name ?? id
    }

    private var style: Binding<String> {
        let id = persona.id
        return Binding(
            get: { app.persona(id)?.voiceStyle ?? "" },
            set: { value in app.updatePersona(id) { $0.voiceStyle = value.isEmpty ? nil : value } }
        )
    }
}

/// The persona's files: open with a click, remove with ✕, add with the button or by dropping them here.
private struct PersonaFilesList: View {
    @Environment(AppModel.self) private var app
    let persona: Persona
    @State private var isDropTarget = false

    var body: some View {
        let files = persona.files ?? []
        let importing = app.importingPersonaFiles[persona.id] ?? 0
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
                PersonaFileRow(file: file, onOpen: { app.openFile(file, of: persona.id) }, onRemove: { app.removeFile(file.id, from: persona.id) })
                Divider().overlay(Theme.border)
            }
            HStack(spacing: 10) {
                Button { app.chooseFiles(for: persona.id) } label: {
                    Label("Dateien hinzufügen …", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if importing > 0 {
                    ProgressView().controlSize(.small)
                    Text(importing == 1 ? "Liest 1 Datei …" : "Liest \(importing) Dateien …")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                } else if files.isEmpty {
                    Text("oder hierher ziehen")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if !files.isEmpty, app.currentModel?.acceptsTools == false {
                    Label("Das gewählte Modell kann keine Werkzeuge nutzen", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .help("Nur Modelle mit Werkzeugen (z. B. Gemma 4, Qwen 3.5) können in den Dateien suchen.")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTarget ? Theme.accent.opacity(0.8) : Theme.strongBorder, style: StrokeStyle(lineWidth: isDropTarget ? 1.5 : 1, dash: isDropTarget ? [6, 4] : []))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await DroppedItems.fileURL(from: provider) { urls.append(url) }
                }
                app.addFiles(urls, to: persona.id)
            }
            return true
        }
    }
}

private struct PersonaFileRow: View {
    let file: PersonaFile
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent.opacity(0.85))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.hover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Datei entfernen")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help("Öffnen")
        .contextMenu {
            Button("Öffnen", systemImage: "arrow.up.forward.app", action: onOpen)
            Button("Entfernen", systemImage: "trash", role: .destructive, action: onRemove)
        }
    }

    private var icon: String {
        switch (file.name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "md", "markdown", "txt", "text": "doc.plaintext"
        case "html", "htm": "globe"
        case "csv", "tsv": "tablecells"
        case "json", "xml", "yaml", "yml", "swift", "py", "js", "ts": "chevron.left.forwardslash.chevron.right"
        default: "doc.text"
        }
    }

    private var details: String {
        let kind = (file.name as NSString).pathExtension.uppercased()
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
        let tokens = Int((Double(file.characterCount) / 3.5).rounded(.up))
        return [kind.isEmpty ? nil : kind, size, "≈ \(LMModel.formatTokens(tokens)) Tokens Text"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// How much of the context the persona takes, with a warning when it is more than a quarter.
private struct PromptSize: View {
    @Environment(AppModel.self) private var app
    let persona: Persona

    var body: some View {
        let tokens = SkillPrompt.estimatedTokens(PersonaPrompt.instructions(for: persona))
        let context = app.currentModel?.loadedContextLength
        let isLarge = context.map { tokens * 4 > $0 } ?? false
        HStack(spacing: 5) {
            if isLarge {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
            }
            Text("System-Prompt der Persona ≈ \(tokens) Tokens")
                .font(.system(size: 11.5).monospacedDigit())
        }
        .foregroundStyle(isLarge ? Theme.warning : Theme.textTertiary)
        .help(isLarge
              ? "Biografie und Verhalten belegen mehr als ein Viertel des geladenen Kontexts (\(LMModel.formatTokens(context ?? 0)))."
              : "Name, Biografie und Verhalten gehen bei jeder Nachricht als System-Prompt mit.")
    }
}

/// Shown when no persona is selected: what personas are and how to start.
private struct PersonaLibraryIntro: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: Persona.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            Text("Personas")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Charaktere mit Bild, Lebensgeschichte, eigener Art und eigener Stimme. Mit einer Persona chattest du wie mit einem Menschen; sie kann in ihren eigenen Dateien nachschauen. Einen Chat führst du entweder mit einer Persona oder mit Skills.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            ActionPill(title: "Neue Persona", symbol: "plus", isProminent: true) { app.createPersona() }
                .padding(.top, 6)
            if !app.personas.isEmpty {
                Text("Oder wähle links eine Persona zum Bearbeiten.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reads what was dropped: a file address, or picture data.
enum DroppedItems {
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    static func imageSource(from provider: NSItemProvider) async -> AttachmentStore.Source? {
        if let url = await fileURL(from: provider) { return .file(url) }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return data.map { .data($0) }
    }
}
