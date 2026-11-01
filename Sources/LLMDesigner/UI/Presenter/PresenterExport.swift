import SwiftUI

/// The top bar's share menu: the slides as a PDF, or the presentation as a handout in Writer Studio.
struct PresenterExportMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var hovering = false
    @State private var showsHandout = false

    var body: some View {
        let isExporting = app.exportingIDs.contains(document.id)
        Menu {
            Section("Präsentation exportieren") {
                Button("Folien als PDF …", systemImage: "doc.richtext") { app.exportPresentationPDF(document.id) }
                Button("Drucken … (⌘P)", systemImage: "printer") { app.printPresentation(document.id) }
            }
            Section("Writer Studio") {
                Button("Als Handout in Writer Studio …", systemImage: StudioApplication.writer.symbol) { showsHandout = true }
            }
        } label: {
            HStack(spacing: 5) {
                if isExporting {
                    ProgressView().controlSize(.mini)
                    Text("Erstelle PDF …")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: Theme.titleBarControlSize)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(isExporting || document.isEmpty)
        .help("Folien als PDF exportieren oder als Handout in Writer Studio weiterbearbeiten")
        .sheet(isPresented: $showsHandout) {
            HandoutSheet(document: document)
                .environment(app)
        }
    }
}

/// What goes into the handout, and whether the model writes the slides out.
private struct HandoutSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let document: WriterDocument
    @State private var options = HandoutOptions()
    @State private var isCreating = false

    var body: some View {
        let deck = document.deck ?? .new()
        let sections = HandoutBuilder.build(deck: deck, options: options).sections.count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: StudioApplication.writer.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handout in Writer Studio")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("„\(document.displayTitle)“ wird ein Dokument: Titelfolie als Titel, Kapitelfolien als Kapitel, jede Folie ein Abschnitt mit ihrer Überschrift.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Inhaltsverzeichnis nach dem Titel", isOn: $options.tableOfContents)
                    .help("Aus den Überschriften, nummeriert wie im Export. Eine Agenda-Folie macht ihm Platz.")
                Toggle("Folienbilder über den Abschnitten", isOn: $options.slidePictures)
                Toggle("Moderatorenkarten als Text übernehmen", isOn: $options.speakerNotes)
                    .disabled(options.expand)
                    .help(options.expand ? "Beim Ausformulieren dienen die Karten der KI als Material." : "")
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $options.expand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Die KI führt die Punkte aus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Aus den Stichpunkten jeder Folie wird zusammenhängender Text wie in einem Essay; die Moderatorenkarten dienen als Material.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                if options.expand {
                    Picker("Umfang je Folie", selection: $options.length) {
                        ForEach(HandoutLength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .padding(.leading, 20)
                    Text(app.currentModelId == nil
                         ? "Kein Modell geladen – wähle eines unten links in der Seitenleiste."
                         : "\(sections) \(sections == 1 ? "Folie wird" : "Folien werden") nacheinander ausformuliert. Das Dokument ist sofort offen; du kannst lesen, während die KI schreibt.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(app.currentModelId == nil ? Theme.warning : Theme.textTertiary)
                        .padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(options.expand ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(options.expand ? 0.35 : 0.12)))

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    isCreating = true
                    Task {
                        await app.createHandout(from: document.id, options: options)
                        dismiss()
                    }
                } label: {
                    if isCreating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Erstelle …")
                        }
                    } else {
                        Text("Handout erstellen")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || (options.expand && app.currentModelId == nil))
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.surface)
    }
}

/// Writer Studio: the model writing out a handout's slides, with "Stopp".
struct HandoutActivityCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        if let generation = app.handoutGeneration, generation.documentID == document.id {
            HStack(spacing: 10) {
                switch generation.phase {
                case .writing(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    text("Die KI führt die Folien aus – \(min(done + 1, total)) von \(total)", "Die Stichpunkte werden Abschnitt für Abschnitt durch Fließtext ersetzt.")
                    Spacer(minLength: 8)
                    SmallActionButton(title: "Stopp", symbol: "stop.fill") { app.stopHandoutGeneration() }
                case .finished(let skipped):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.success)
                    text("Handout ausformuliert", skipped == 0 ? "Alles lässt sich wie gewohnt bearbeiten." : "\(skipped) Abschnitt\(skipped == 1 ? "" : "e") blieb\(skipped == 1 ? "" : "en") als Stichpunkte – geändert oder ohne Antwort.")
                    Spacer(minLength: 8)
                    IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.handoutGeneration = nil }
                case .stopped:
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.warning)
                    text("Angehalten", "Was fertig ist, bleibt stehen; der Rest bleibt als Stichpunkte.")
                    Spacer(minLength: 8)
                    IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.handoutGeneration = nil }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.warning)
                    text("Das Ausformulieren ist abgebrochen", message)
                    Spacer(minLength: 8)
                    IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.handoutGeneration = nil }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(generation.isRunning ? 0.45 : 0.2)))
            .shadow(color: Theme.shade.opacity(0.35), radius: 14, y: 5)
            .frame(maxWidth: 680)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func text(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
    }
}
