import SwiftUI
import UniformTypeIdentifiers

/// "Präsentation aus Dokument": choose a document (or a file), say what goes into the slides, and the model makes the
/// presentation: chapters and slides from the headings, points from the text, then speaker cards and, if wanted, the
/// automatic presentation.
struct DeckFromDocumentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var material: DeckMaterial?
    @State private var options = DeckSourceOptions()
    @State private var message: String?

    init(request: DeckSourceRequest) {
        _material = State(initialValue: request.material)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: StudioApplication.presenter.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Präsentation aus Dokument")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Aus den Überschriften werden Kapitel und Folien, das Modell fasst jeden Abschnitt in Stichpunkten zusammen.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sourceRow

            if let material {
                summary(for: material)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $options.notes) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Moderatorenkarten schreiben")
                        Text("Zu jeder Folie ein Sprechtext, gestützt auf den Text des Dokuments.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Toggle(isOn: $options.carriesObjects) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Formeln, Code, Tabellen und Bilder übernehmen")
                        Text("Die ersten davon eines Abschnitts kommen unverändert auf seine Folie.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Toggle(isOn: $options.presents) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Danach automatisch präsentieren")
                        Text("Vollbild: Die KI trägt Folie für Folie vor und schaltet selbst weiter.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))

            if app.currentModelId == nil {
                Label("Kein Modell geladen – wähle eines unten links in der Seitenleiste.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
            } else {
                Text("Das dauert je nach Länge ein paar Minuten. Die Präsentation ist sofort offen, die Folien füllen sich nacheinander; „Stopp“ hält an.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Präsentation erstellen") {
                    guard let material else { return }
                    app.createPresentation(from: material, options: options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(material == nil || app.currentModelId == nil || app.deckGeneration?.isRunning == true)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.surface)
    }

    // MARK: Source

    private var sourceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(material?.title ?? "Kein Dokument gewählt")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(material == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                if let material, material.sourceName != material.title {
                    Text(material.sourceName).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Menu {
                let candidates = app.documents.filter { !$0.isPresentation && !$0.isEmpty }
                if !candidates.isEmpty {
                    Section("Dokumente der Bibliothek") {
                        ForEach(candidates.prefix(30)) { document in
                            Button(document.displayTitle) { material = app.deckMaterial(from: document); message = nil }
                        }
                    }
                }
                Divider()
                Button("Datei wählen …", systemImage: "folder") { chooseFile() }
            } label: {
                Text(material == nil ? "Wählen …" : "Ändern …")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private func summary(for material: DeckMaterial) -> some View {
        let words = DocumentOutlineBuilder.wordCount(material.markdown)
        let plan = DocumentDeckPlanner.plan(for: material)
        return VStack(alignment: .leading, spacing: 4) {
            if let plan {
                Label(
                    "Gliederung aus den Überschriften: \(plan.chapterCount > 0 ? "\(plan.chapterCount) Kapitel, " : "")\(plan.slideCount) Folien",
                    systemImage: "list.bullet.indent"
                )
                .foregroundStyle(Theme.success)
            } else {
                Label("Keine brauchbaren Überschriften – das Modell gliedert den Text in Kapitel und Folien.", systemImage: "sparkles")
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("\(words) Wörter")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 12))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .pdf, .rtf, .html, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Ein Dokument für die Präsentation wählen: Markdown, Text, Word, RTF, PDF oder HTML"
        panel.prompt = "Wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            material = try app.deckMaterial(from: url)
            message = nil
        } catch {
            message = "Die Datei ließ sich nicht lesen: \(error.localizedDescription)"
        }
    }
}
