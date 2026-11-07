import SwiftUI

/// "Dazugehörige Dokumente" of a world or a part: Writer documents and presentations marked as belonging to it.
/// A click opens one; the document itself stays in its folder.
struct StoryLinkedDocumentsCard: View {
    @Environment(AppModel.self) private var app
    let ids: [UUID]
    /// What the card belongs to, for the hint ("zu diesem Kapitel").
    let ownerLabel: String
    let onChange: ([UUID]) -> Void
    @State private var picking = false

    var body: some View {
        let linked = ids.compactMap { app.document($0) }
        StoryCard {
            HStack {
                StoryLabel(title: "Dazugehörige Dokumente", hint: "Dokumente und Präsentationen, die \(ownerLabel) gehören – Recherche, Entwürfe, ein Vortrag. Sie bleiben in ihren Ordnern.",
                           symbol: "link", color: Theme.accent)
                Spacer()
                Button {
                    picking = true
                } label: {
                    Label("Verknüpfen", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    StoryDocumentPicker(excluded: Set(ids)) { id in
                        onChange(ids + [id])
                    }
                    .environment(app)
                }
            }
            if linked.isEmpty {
                Text("Noch nichts verknüpft.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(linked) { document in
                    StoryDocumentChip(document: document) {
                        app.selectDocument(document.id)
                    } onRemove: {
                        onChange(ids.filter { $0 != document.id })
                    }
                }
            }
        }
    }
}

private struct StoryDocumentChip: View {
    let document: WriterDocument
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onOpen) {
                Label(document.displayTitle, systemImage: document.isPresentation ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(document.isPresentation ? "Präsentation öffnen" : "Dokument öffnen")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Verknüpfung lösen; das Dokument bleibt")
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(Theme.ink.opacity(hovering ? 0.08 : 0.05)))
        .onHover { hovering = $0 }
    }
}

/// Searches the documents and presentations of the library, newest first.
private struct StoryDocumentPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<UUID>
    let onPick: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        let documents = app.documents
            .filter { !excluded.contains($0.id) && !$0.isEmpty && $0.matches(query.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(60)
        VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $query, prompt: "Dokumente und Präsentationen")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(documents)) { document in
                        Button {
                            onPick(document.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: document.isPresentation ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18)
                                Text(document.displayTitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(document.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
            .overlay {
                if documents.isEmpty {
                    Text(query.isEmpty ? "Keine Dokumente" : "Keine Treffer")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
