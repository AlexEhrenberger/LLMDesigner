import SwiftUI

/// The search that ⌘⇧K and "/cite" open at the caret: sources with their quotes. ↑↓ choose, ↩ inserts (a
/// quote word for word, a source as a reference), ⌥↩ a quote as a paraphrase, ⇧↩ only the reference.
struct CitationPicker: View {
    enum Choice {
        case source(UUID)
        case quote(UUID, CitationInsertion)
    }

    private enum Row: Identifiable, Equatable {
        case source(CitationSource)
        case quote(CitationQuote)

        var id: UUID {
            switch self {
            case .source(let source): source.id
            case .quote(let quote): quote.id
            }
        }
    }

    let library: CitationLibrary
    let onChoose: (Choice?) -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var rows: [Row] {
        let result = library.search(query)
        let quoteIDs = Set(result.quoteIDs)
        var rows: [Row] = []
        for id in result.sourceIDs.prefix(12) {
            guard let source = library.source(id) else { continue }
            rows.append(.source(source))
            let quotes = library.quotes(of: id).filter { query.isEmpty || quoteIDs.contains($0.id) }
            rows += quotes.prefix(query.isEmpty ? 3 : 6).map(Row.quote)
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble").foregroundStyle(Theme.accent)
                TextField("Quelle oder Zitat suchen – #tag @autor 2021", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onChange(of: query) { _, _ in selection = 0 }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(0, rows.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard rows.indices.contains(selection) else { return .ignored }
                        choose(rows[selection], modifiers: press.modifiers)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onChoose(nil)
                        return .handled
                    }
            }
            .padding(12)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isSelected: index == selection)
                                .id(row.id)
                                .onTapGesture { choose(row, modifiers: []) }
                                .onHover { if $0 { selection = index } }
                        }
                        if rows.isEmpty {
                            Text("Nichts gefunden")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(16)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, index in
                    if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
                }
            }
            .frame(height: 300)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("↩ einfügen (Zitat wörtlich, Quelle als Angabe) · ⌥↩ als Paraphrase · ⇧↩ nur Angabe · esc schließen")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 520)
        .background(Theme.surface)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isSelected: Bool) -> some View {
        Group {
            switch row {
            case .source(let source):
                HStack(spacing: 8) {
                    Image(systemName: source.type.symbol)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    Text(source.shortReference)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(source.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("@" + source.citekey)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            case .quote(let quote):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: quote.exactText.isEmpty ? "lightbulb" : "text.quote")
                        .font(.system(size: 10.5))
                        .foregroundStyle(quote.exactText.isEmpty ? Theme.warning : Theme.accent)
                        .frame(width: 16)
                        .padding(.leading, 14)
                        .padding(.top, 1)
                    Text(quote.exactText.isEmpty ? quote.paraphrase : "„\(quote.exactText)“")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if !quote.locator.isEmpty {
                        Text(quote.locator)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : .clear))
        .contentShape(Rectangle())
    }

    private func choose(_ row: Row, modifiers: EventModifiers) {
        switch row {
        case .source(let source):
            onChoose(.source(source.id))
        case .quote(let quote):
            let insertion: CitationInsertion
            if modifiers.contains(.shift) {
                insertion = .reference
            } else if modifiers.contains(.option) || quote.exactText.isEmpty {
                insertion = .paraphrase
            } else {
                insertion = .verbatim
            }
            onChoose(.quote(quote.id, insertion))
        }
    }
}
