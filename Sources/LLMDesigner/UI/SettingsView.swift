import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibrarySession.self) private var session
    @State private var engine: LaTeXEngine?
    @State private var qwenVoices = QwenTTSClient.fallbackVoices
    @State private var qwenReachable: Bool?

    var body: some View {
        @Bindable var app = app

        Form {
            Section {
                LabeledContent("Bibliothek") {
                    HStack(spacing: 8) {
                        Text(session.library.name)
                            .foregroundStyle(Theme.textPrimary)
                        Button("Im Finder zeigen") { session.revealInFinder() }
                    }
                }
                LabeledContent("Ort") {
                    Text(session.library.url.deletingLastPathComponent().path)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Bibliothek")
            } footer: {
                Text("Alle Einstellungen hier gelten für die geöffnete Bibliothek und liegen in ihr – zusammen mit Chats, Dokumenten, Personas und Skills. Gewechselt wird unten links in der Seitenleiste.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section {
                Picker("Design", selection: $app.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Darstellung")
            } footer: {
                Text("„Wie das System“ folgt dem Erscheinungsbild in den Systemeinstellungen und wechselt mit ihm, auch beim automatischen Wechsel am Abend. Im dunklen Design kann Writer Studio weiter zwischen hellem und dunklem Blatt wechseln, im hellen ist das Blatt immer hell.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section {
                Toggle("Suchleiste mit Tastenkürzel öffnen", isOn: Binding(get: { app.quickBar.isEnabled }, set: { app.quickBar.isEnabled = $0 }))
                LabeledContent("Tastenkürzel") {
                    QuickBarShortcutRecorder(bar: app.quickBar)
                }
                .disabled(!app.quickBar.isEnabled)
            } header: {
                Text("Suchleiste")
            } footer: {
                Text("Die Suchleiste erscheint vor jeder App, wie Spotlight. Darin chattest du oder gibst einen Auftrag, z. B. „Erstelle eine Präsentation über …“. Ihre Chats dürfen alle Werkzeuge der App ohne Rückfrage benutzen, auch Web und Wikipedia; private Daten und Änderungen nach fremden Inhalten fragen trotzdem. Mitgeschickt werden nur die Werkzeuge, die der Auftrag nennt (Dokument, Präsentation, Quelle, Roman …), damit ein lokales Modell schnell antwortet. Die Chats stehen danach in der Seitenleiste.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section {
                Picker("Quelle", selection: $app.provider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Endpoint", text: $app.endpoint, prompt: Text(app.provider.defaultEndpoint))
                SecureField("API-Token (optional)", text: $app.apiKey)
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        StatusDot(color: app.connection.color, size: 6)
                        Text(statusText)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                        Button("Prüfen") { Task { await app.refreshModels() } }
                    }
                }
            } header: {
                Text("Sprachmodelle")
            } footer: {
                Text(providerFooter)
                    .foregroundStyle(Theme.textTertiary)
            }

            DrawThingsSettings(center: app.imageGeneration)

            ActionSettings()

            Section {
                Picker("Papierformat", selection: $app.pdfPaperSize) {
                    ForEach(PaperSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                Toggle("Antwort-PDF mit Sprecherzeile beginnen", isOn: $app.pdfSpeakerLineEnabled)
                TextField("Sprecherzeile", text: $app.pdfSpeakerTemplate, prompt: Text(AppModel.defaultSpeakerTemplate))
                Toggle("PDF nach dem Export öffnen", isOn: $app.pdfOpenAfterExport)
                LabeledContent("LaTeX-Engine") {
                    HStack(spacing: 8) {
                        StatusDot(color: engine == nil ? Theme.danger : Theme.success, size: 6)
                        Text(engine.map { "\($0.kind.rawValue) · \($0.executable.path)" } ?? "nicht gefunden: brew install tectonic")
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("PDF-Export")
            } footer: {
                Text("Antworten werden mit LaTeX gesetzt. „{Modell}“ in der Sprecherzeile wird durch den Kurznamen des Modells ersetzt, aktuell: „\(LaTeXWriter.speakerLine(template: app.pdfSpeakerTemplate, model: app.currentModelId))“. Beim Export des ganzen Chats steht die Zeile immer vor jeder Antwort.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section {
                if app.isDictationAvailable {
                    Picker("Diktat", selection: $app.dictationMode) {
                        ForEach(DictationMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
                Picker("Vorlesen mit", selection: $app.speechEngine) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                if app.speechEngine != .system {
                    Picker("Qwen-Stimme", selection: $app.qwenVoice) {
                        ForEach(qwenVoices) { voice in
                            Text("\(voice.name) (\(voice.gender == "female" ? "weiblich" : "männlich"))").tag(voice.id)
                        }
                    }
                    LabeledContent("Qwen-TTS-Dienst") {
                        HStack(spacing: 8) {
                            StatusDot(color: qwenReachable == true ? Theme.success : (qwenReachable == false ? Theme.danger : Theme.textTertiary), size: 6)
                            Text(qwenReachable == true ? "erreichbar · 127.0.0.1:8790" : (qwenReachable == false ? "nicht erreichbar – es liest die macOS-Stimme" : "prüfe …"))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                LabeledContent("Tempo") {
                    HStack {
                        Slider(value: $app.speechRate, in: 0.3...0.7, step: 0.02)
                        Text("\(Int((1 + (app.speechRate - 0.5) * 2) * 100)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if app.isConversationAvailable {
                    LabeledContent("Gesprächsmodus: Pause bis zur Antwort") {
                        HStack {
                            Slider(value: $app.conversationPause, in: 0.6...3, step: 0.1)
                            Text("\(app.conversationPause.formatted(.number.precision(.fractionLength(1)))) s")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Sprache")
            } footer: {
                Text("Das Diktat (⌘D oder Mikrofon im Eingabefeld) läuft vollständig auf diesem Mac und nutzt die Systemsprache. Qwen TTS ist der lokale Sprachdienst aus Auda. Im Gesprächsmodus (⇧⌘D) gilt ein Satz als beendet, wenn du so lange still bist wie eingestellt; Stimme und Tempo sind dieselben wie beim Vorlesen.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section {
                Toggle("Seiten ohne lesbaren Text über Jina Reader laden", isOn: $app.webReaderFallback)
            } header: {
                Text("Websuche")
            } footer: {
                Text("Eingeschaltet wird die Suche pro Chat im Eingabefeld: der Globus für die Websuche bei DuckDuckGo (ohne Konto, Region \(DuckDuckGoSearch.defaultRegion)), das W für Wikipedia (offizielle Schnittstelle, Ausgabe „\(WikipediaClient.defaultLanguage)“, bei Bedarf auch andere Sprachen). Seiten, die nur mit JavaScript Inhalt zeigen oder die App abweisen, kann Jina Reader (r.jina.ai) im Browser öffnen; dabei sieht Jina die Adresse der Seite.")
                    .foregroundStyle(Theme.textTertiary)
            }

            Section("Generierung") {
                Toggle("Folgefragen unter Antworten vorschlagen", isOn: $app.suggestFollowUps)
                Toggle("Eigene Temperatur verwenden", isOn: $app.useCustomTemperature)
                LabeledContent("Temperatur") {
                    HStack {
                        Slider(value: $app.temperature, in: 0...2, step: 0.05)
                        Text(app.temperature.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!app.useCustomTemperature)

                VStack(alignment: .leading, spacing: 6) {
                    Text("System-Prompt")
                    TextEditor(text: $app.systemPrompt)
                        .font(.system(size: 13))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    Text("Wird jedem Chat vorangestellt. Leer lassen, um die Vorgabe des Modells zu nutzen.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .frame(width: 580, height: 760)
        .onAppear { engine = LaTeXEngine.locate() }
        .task {
            let client = QwenTTSClient()
            qwenReachable = await client.isReachable()
            if let voices = try? await client.voices(), !voices.isEmpty { qwenVoices = voices }
        }
    }

    private var statusText: String {
        switch app.connection {
        case .connecting: "Verbinde…"
        case .connected:
            if app.provider == .kapitsa {
                app.loadedModels.first.map { "Verbunden · \($0.displayName), \(LMModel.formatTokens($0.loadedContextLength ?? 0)) Kontext" }
                    ?? "Verbunden · kein aktives Modell"
            } else {
                "Verbunden · \(app.chatModels.count) Modelle, \(app.loadedModels.count) geladen"
            }
        case .failed(let message): message
        }
    }

    private var providerFooter: String {
        switch app.provider {
        case .lmStudio:
            "Adresse des lokalen LM-Studio-Servers. Ein Token ist nur nötig, wenn in LM Studio die Authentifizierung aktiviert ist."
        case .kapitsa:
            "Kapitsa führt Qwen 3.5 auf Apple Silicon besonders schnell aus, im Terminal gestartet mit „kapitsa serve --model 9b“. Es stellt genau das Modell bereit, mit dem es gestartet wurde, mit dessen Kontextlänge; der Denkmodus lässt sich pro Chat ein- und ausschalten. Ein Token ist nur nötig, wenn Kapitsa mit --api-key läuft. Adresse, Token und gewähltes Modell merkt sich jede Quelle für sich."
        }
    }
}


/// Where Draw Things listens; pictures in Writer Studio are made there.
private struct DrawThingsSettings: View {
    let center: ImageGenerationCenter
    @State private var address = ""
    @State private var status: String?
    @State private var reachable: Bool?

    var body: some View {
        Section {
            TextField("Adresse", text: $address, prompt: Text(DrawThingsClient.defaultAddress))
                .onSubmit(save)
                .onChange(of: address) { _, _ in save() }
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    StatusDot(color: reachable == nil ? Theme.textTertiary : (reachable == true ? Theme.success : Theme.danger), size: 6)
                    Text(status ?? "nicht geprüft")
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Button("Prüfen") { Task { await check() } }
                }
            }
        } header: {
            Text("Draw Things")
        } footer: {
            Text("Writer Studio generiert Bilder mit Draw Things. In Draw Things unter Einstellungen den „API-Server“ (HTTP, Port 7860) einschalten. Die Voreinstellung „Qwen Image 1.0 · Lightning“ braucht die Modelldatei \(DrawThingsProfile.qwenModel) und die Lightning-LoRA; ist dieses Modell auch in Draw Things gewählt, entfällt das Umladen und das Bild kommt schneller.")
                .foregroundStyle(Theme.textTertiary)
        }
        .onAppear {
            address = center.address
            Task { await check() }
        }
    }

    private func save() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        center.address = trimmed.isEmpty ? DrawThingsClient.defaultAddress : trimmed
    }

    private func check() async {
        guard let client = center.client else {
            reachable = false
            status = "Ungültige Adresse"
            return
        }
        do {
            let reply = try await client.status()
            reachable = true
            status = "Verbunden" + (reply.model.map { " · gewählt: \($0)" } ?? "")
        } catch {
            reachable = false
            status = "Nicht erreichbar – API-Server in Draw Things einschalten"
        }
    }
}

/// Records a new shortcut for the search bar: click, then press the combination; esc cancels.
private struct QuickBarShortcutRecorder: View {
    let bar: QuickBar
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Button(isRecording ? "Kürzel drücken …" : bar.shortcut.label) {
                isRecording ? stop() : start()
            }
            .frame(minWidth: 130)
            if bar.shortcut != .standard {
                Button("Standard") { bar.shortcut = .standard }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        notice = nil
        isRecording = true
        // The current shortcut would open the bar instead of being recorded.
        GlobalHotKey.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let shortcut = QuickBarShortcut(keyCode: event.keyCode, modifiers: flags.rawValue,
                                            key: QuickBarShortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            guard shortcut.isUsable else {
                notice = "Mit ⌘, ⌥ oder ⌃"
                return nil
            }
            stop()
            bar.shortcut = shortcut
            if !GlobalHotKey.shared.register(bar.activeShortcut) {
                notice = "Belegt von einer anderen App"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        GlobalHotKey.shared.resume()
    }
}
