import AppKit
import SwiftUI

/// Documents waiting to be sent, in the composer or in the editor of a sent question, and those still being read.
struct DocumentStrip: View {
    @Environment(AppModel.self) private var app
    let documents: [DocumentAttachment]
    var imports: [DocumentImport] = []
    /// Characters each document may bring in the chat it goes to; more and only the beginning comes along.
    var budget: Int?
    let onRemove: (DocumentAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(documents) { document in
                    DocumentChip(document: document, budget: budget, onRemove: { onRemove(document.id) })
                }
                ForEach(imports) { job in
                    DocumentChipFrame {
                        ProgressView().controlSize(.small).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(job.status).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .animation(.easeOut(duration: 0.15), value: documents)
    }
}

/// One document: kind, name, pages, size in tokens, and whether it fits.
struct DocumentChip: View {
    let document: DocumentAttachment
    var budget: Int?
    /// In the composer: the button to take it out again.
    var onRemove: (() -> Void)?
    /// At a sent question: opens the document's sheet.
    var onOpen: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let length = DocumentPrompt.fullText(of: document).count
        let tokens = Int(Double(length) / DocumentPrompt.charactersPerToken)
        let fits = budget.map { length <= $0 } ?? true
        DocumentChipFrame(isHovered: hovering && onOpen != nil) {
            Image(systemName: document.isPDF ? "doc.richtext" : "doc.text")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    // Tokens first: the summary may be cut off, the size matters more.
                    Text("≈ \(tokens.formatted()) Tokens · \(DocumentPrompt.summary(of: document))")
                    if !fits {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.8)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Dokument entfernen")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { hovering = $0 }
        .help(help(fits: fits))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func help(fits: Bool) -> String {
        var text = onOpen != nil ? "Text, Abbildungen und Original ansehen" : "Der Text geht mit der Nachricht an das Modell"
        if !fits {
            text += ". Das Dokument ist länger als der Platz im Kontext: Nur der Anfang kommt mit, den Rest liest das Modell bei Bedarf nach (wenn es Werkzeuge kann). Ein größerer Kontext hilft."
        }
        return text
    }
}

private struct DocumentChipFrame<Content: View>: View {
    var isHovered = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 9) { content }
            .padding(.horizontal, 11)
            .frame(height: 48)
            .frame(maxWidth: 340, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Theme.hover : Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
    }
}

/// The documents of a sent question, above its bubble.
struct MessageDocumentList: View {
    let documents: [DocumentAttachment]
    let chatID: Chat.ID?
    @State private var opened: DocumentAttachment?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(documents) { document in
                DocumentChip(document: document, onOpen: { opened = document })
            }
        }
        .sheet(item: $opened) { document in
            DocumentSheet(documentID: document.id, fallback: document, chatID: chatID)
        }
    }
}

/// What the model gets from a document: its text with figure placeholders, and the figures themselves.
struct DocumentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let documentID: DocumentAttachment.ID
    /// Shown when the chat is gone or the document can't be found in it.
    let fallback: DocumentAttachment
    let chatID: Chat.ID?
    @State private var tab = 0
    @State private var error: String?

    private var document: DocumentAttachment {
        guard let chatID, let chat = app.chat(chatID) else { return fallback }
        return chat.messages.lazy.compactMap { $0.documents?.first { $0.id == documentID } }.first ?? fallback
    }

    var body: some View {
        let document = document
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: document.isPDF ? "doc.richtext" : "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(DocumentPrompt.summary(of: document)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button("Original öffnen") { NSWorkspace.shared.open(DocumentStore.originalURL(of: document)) }
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Picker("", selection: $tab) {
                Text("Text fürs Modell").tag(0)
                Text("Abbildungen (\(document.figures?.count ?? 0))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.border).frame(height: 1)

            if tab == 0 {
                ScrollView {
                    Text(DocumentPrompt.fullText(of: document))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                FigureList(document: document, chatID: chatID, error: $error)
            }
        }
        .frame(width: 680, height: 620)
        .background(Theme.surface)
    }
}

private struct FigureList: View {
    @Environment(AppModel.self) private var app
    let document: DocumentAttachment
    let chatID: Chat.ID?
    @Binding var error: String?

    var body: some View {
        let figures = document.figures ?? []
        let describing = app.describingDocumentIDs.contains(document.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(figures.isEmpty
                     ? "In diesem Dokument wurden keine Abbildungen gefunden."
                     : "Das Modell bekommt zu jeder Abbildung einen Platzhalter mit Bildunterschrift. Eine Beschreibung schreibt ein Modell, das Bilder versteht, einmal; danach geht sie als Text mit.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !figures.isEmpty, let chatID {
                    if describing {
                        ProgressView().controlSize(.small)
                        Text("Wird beschrieben …").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    } else {
                        Button(figures.allSatisfy { $0.description != nil } ? "Neu beschreiben" : "Abbildungen beschreiben") {
                            let again = figures.allSatisfy { $0.description != nil }
                            Task {
                                do {
                                    try await app.describeFigures(of: document.id, in: chatID, again: again)
                                    error = nil
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .disabled(app.describingModel(for: app.chat(chatID)) == nil)
                        .help(app.describingModel(for: app.chat(chatID)).map { "Beschreibt mit \($0)" } ?? "Es ist kein Modell geladen, das Bilder versteht.")
                    }
                }
            }
            .padding(16)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.horizontal, 16).padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(figures) { figure in
                        FigureRow(figure: figure)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct FigureRow: View {
    @Environment(AppModel.self) private var app
    let figure: DocumentFigure
    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Theme.elevated
                }
            }
            .frame(width: 220, height: 160)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .onTapGesture { NSWorkspace.shared.open(DocumentStore.figureURL(figure)) }
            .help("In Vorschau öffnen")

            VStack(alignment: .leading, spacing: 6) {
                Text("Abbildung \(figure.number) · Seite \(figure.page)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let caption = figure.caption {
                    Text(caption).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                if let description = figure.description {
                    Text(description).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let by = figure.describedBy {
                        Text("Beschrieben von \(by), nicht geprüft").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("Noch nicht beschrieben").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Button("Mit der nächsten Frage als Bild mitschicken") {
                    app.attachImages([.file(DocumentStore.figureURL(figure))])
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .help("Für Fragen, bei denen das Modell die Abbildung selbst sehen soll")
            }
            Spacer(minLength: 0)
        }
        .task(id: figure.imageFileName) {
            let url = DocumentStore.figureURL(figure)
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}
