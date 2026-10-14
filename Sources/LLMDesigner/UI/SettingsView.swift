import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var engine: LaTeXEngine?
    @State private var qwenVoices = QwenTTSClient.fallbackVoices
    @State private var qwenReachable: Bool?

    var body: some View {
        @Bindable var app = app

        Form {
            Section {
                TextField("Endpoint", text: $app.endpoint, prompt: Text(AppModel.defaultEndpoint))
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
                Text("LM Studio")
            } footer: {
                Text("Adresse des lokalen LM-Studio-Servers. Ein Token ist nur nötig, wenn in LM Studio die Authentifizierung aktiviert ist.")
                    .foregroundStyle(Theme.textTertiary)
            }

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
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
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
        .preferredColorScheme(.dark)
    }

    private var statusText: String {
        switch app.connection {
        case .connecting: "Verbinde…"
        case .connected: "Verbunden · \(app.chatModels.count) Modelle, \(app.loadedModels.count) geladen"
        case .failed(let message): message
        }
    }
}
