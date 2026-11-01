import SwiftUI

/// The "Quellen" tab of Writer Studio's side panel: Citation Studio's sources and quotes, ready to go into the
/// text at the caret — a quote word for word, as a paraphrase, or just the reference.
struct DocumentSourcesPanel: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let controller: WriterEditorController
    let library: CitationLibrary
    @State private var query = ""
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let cited = CitationMarkup.keys(in: document.markdown)
        let citedSources = cited.compactMap { library.source(citekey: $0) }
        let missing = cited.filter { library.source(citekey: $0) == nil }
        let result = library.search(query)
        let matchingQuotes = Set(result.quoteIDs)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Quellen und Zitate durchsuchen", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if library.sources.isEmpty {
                        Text("Noch keine Quellen. Öffne Citation Studio und füge eine DOI, ISBN oder Web-Adresse ein.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if query.isEmpty, !citedSources.isEmpty || !missing.isEmpty {
                        sectionTitle("Im Dokument zitiert", count: cited.count)
                        ForEach(citedSources) { source in
                            Text("\(source.shortReference) · \(source.title)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        ForEach(missing, id: \.self) { key in
                            Label("@\(key) fehlt in Citation Studio", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.warning)
                        }
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 2)
                    }
                    if !library.sources.isEmpty {
                        sectionTitle(query.isEmpty ? "Alle Quellen" : "Treffer", count: result.sourceIDs.count)
                    }
                    ForEach(result.sourceIDs.compactMap { library.source($0) }) { source in
                        let quotes = library.quotes(of: source.id).filter { query.isEmpty || matchingQuotes.contains($0.id) }
                        sourceRow(source, quotes: quotes, isOpen: expanded.contains(source.id) || (!query.isEmpty && !quotes.isEmpty))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                Button {
                    controller.insertBibliography()
                } label: {
                    Label("Literaturverzeichnis einfügen", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .disabled(document.markdown.components(separatedBy: "\n").contains(where: WriterBibliographyAttachment.isMarker))
                .help("Listet alle zitierten Quellen nach APA – im Dokument und im Export")
                Button {
                    app.openCitationStudio()
                } label: {
                    Label("Citation Studio öffnen", systemImage: "quote.bubble")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .onAppear { library.loadIfNeeded() }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func sourceRow(_ source: CitationSource, quotes: [CitationQuote], isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    if expanded.contains(source.id) { expanded.remove(source.id) } else { expanded.insert(source.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(quotes.isEmpty ? Theme.textTertiary.opacity(0.4) : Theme.textTertiary)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(quotes.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.shortReference)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(source.title.isEmpty ? "Ohne Titel" : source.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
                Button {
                    controller.insertCitation(source)
                } label: {
                    Image(systemName: "at")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Quellenangabe \(source.parenthetical()) an der Cursorstelle einfügen")
            }
            if isOpen {
                ForEach(quotes) { quote in
                    quoteRow(quote, source: source)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.03)))
    }

    private func quoteRow(_ quote: CitationQuote, source: CitationSource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(quote.exactText.isEmpty ? quote.paraphrase : "„\(quote.exactText)“")
                .font(.system(size: 11.5, design: quote.exactText.isEmpty ? .default : .serif))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if !quote.locator.isEmpty {
                    Text(quote.locator)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if !quote.exactText.isEmpty {
                    insertButton("text.quote", help: "Wörtlich einfügen: „…“ \(source.parenthetical(locator: quote.locator))") {
                        controller.insertQuote(quote, source: source, as: .verbatim)
                    }
                }
                if !quote.paraphrase.isEmpty {
                    insertButton("lightbulb", help: "Den eigenen Gedanken mit Quellenangabe einfügen") {
                        controller.insertQuote(quote, source: source, as: .paraphrase)
                    }
                }
                insertButton("at", help: "Nur die Quellenangabe \(source.parenthetical(locator: quote.locator)) einfügen") {
                    controller.insertQuote(quote, source: source, as: .reference)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 4)
    }

    private func insertButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .frame(width: 22, height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .help(help)
    }
}
