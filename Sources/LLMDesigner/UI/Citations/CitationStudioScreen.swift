import SwiftUI
import AppKit

/// What Citation Studio shows and what it is doing.
@MainActor
@Observable
final class CitationStudioModel {
    enum Mode: String, CaseIterable {
        case sources, quotes

        var label: String {
            switch self {
            case .sources: "Quellen"
            case .quotes: "Wissensbausteine"
            }
        }
    }

    enum Sort: String, CaseIterable {
        case newest, author, year, title

        var label: String {
            switch self {
            case .newest: "Zuletzt angelegt"
            case .author: "Autor:in"
            case .year: "Jahr"
            case .title: "Titel"
            }
        }
    }

    /// A looked-up source that may already be in the library; it waits for the user's decision.
    struct PendingImport {
        var source: CitationSource
        var duplicates: [CitationDuplicate]
    }

    var mode: Mode = .sources
    var sort: Sort = .newest
    var searchText = ""
    private(set) var selectedSourceID: UUID?
    var importText = ""
    private(set) var isImporting = false
    var importMessage: String?
    var pendingImport: PendingImport?
    /// A new source whose title field should take the keyboard.
    var focusTitleOf: UUID?
    /// The quick-add sheet for a quote from any source (⇧⌘N).
    var showsQuickAdd = false

    func select(_ id: UUID?, in library: CitationLibrary) {
        guard id != selectedSourceID else { return }
        // A new source left without any entry goes away again.
        if let previous = selectedSourceID, let source = library.source(previous), source.isBlank, library.quotes(of: previous).isEmpty {
            library.deleteSource(previous)
        }
        selectedSourceID = id
    }

    func newSource(_ type: SourceType, in library: CitationLibrary) {
        var source = CitationSource()
        source.type = type
        if type == .web { source.accessed = Date() }
        let added = library.addSource(source)
        mode = .sources
        searchText = ""
        select(added.id, in: library)
        focusTitleOf = added.id
    }

    /// DOI, ISBN, arXiv ID or address → a filled source; a likely duplicate waits for the user.
    func runImport(in library: CitationLibrary) async {
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isImporting else { return }
        guard let identifier = CitationIdentifier.detect(text) else {
            importMessage = CitationLookupError.unrecognized.localizedDescription
            return
        }
        isImporting = true
        importMessage = nil
        defer { isImporting = false }
        do {
            let source = try await CitationLookup.lookup(identifier)
            importText = ""
            let duplicates = library.duplicates(of: source)
            if duplicates.isEmpty {
                accept(source, in: library)
            } else {
                pendingImport = PendingImport(source: source, duplicates: duplicates)
            }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    func accept(_ source: CitationSource, in library: CitationLibrary) {
        let added = library.addSource(source)
        pendingImport = nil
        mode = .sources
        searchText = ""
        select(added.id, in: library)
    }

    /// The sources that fit the search, in the chosen order.
    func visibleSources(_ library: CitationLibrary) -> [CitationSource] {
        let ids = library.search(searchText).sourceIDs
        var sources = ids.compactMap { library.source($0) }
        switch sort {
        case .newest: break
        case .author: sources.sort { ($0.creators.first?.sortName ?? $0.title).localizedStandardCompare($1.creators.first?.sortName ?? $1.title) == .orderedAscending }
        case .year: sources.sort { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) }
        case .title: sources.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return sources
    }

    /// `#tag` on or off in the search.
    func toggleTag(_ tag: String) {
        let token = "#" + tag.replacingOccurrences(of: " ", with: "")
        var words = searchText.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            words.remove(at: index)
        } else {
            words.append(token)
        }
        searchText = words.joined(separator: " ")
    }

    func isTagActive(_ tag: String) -> Bool {
        searchText.split(separator: " ").contains { $0.caseInsensitiveCompare("#" + tag.replacingOccurrences(of: " ", with: "")) == .orderedSame }
    }
}

/// Citation Studio: sources on the left, the selected source with its quotes on the right; or all quotes
/// (Wissensbausteine) at once. The field at the top imports a source from a DOI, ISBN, arXiv ID or address.
struct CitationStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = CitationStudioModel()

    var body: some View {
        let library = app.citations
        VStack(spacing: 0) {
            CitationTopBar(model: model, library: library)
            if let pending = model.pendingImport {
                DuplicateBanner(pending: pending, model: model, library: library)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                CitationSourceList(model: model, library: library)
                    .frame(width: 320)
                Rectangle().fill(Theme.border).frame(width: 1)
                Group {
                    switch model.mode {
                    case .sources:
                        if let id = model.selectedSourceID, library.source(id) != nil {
                            CitationSourceDetail(sourceID: id, model: model, library: library)
                                .id(id)
                        } else {
                            emptyState(library)
                        }
                    case .quotes:
                        KnowledgeView(model: model, library: library)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.2), value: model.pendingImport != nil)
        .sheet(isPresented: $model.showsQuickAdd) {
            QuickQuoteSheet(library: library, preselected: model.selectedSourceID) { sourceID in
                model.showsQuickAdd = false
                if let sourceID {
                    model.mode = .sources
                    model.select(sourceID, in: library)
                }
            }
        }
        .onAppear {
            library.loadIfNeeded()
            if model.selectedSourceID == nil, let first = library.sources.first { model.select(first.id, in: library) }
        }
        .onDisappear {
            if let id = model.selectedSourceID, let source = library.source(id), source.isBlank, library.quotes(of: id).isEmpty {
                library.deleteSource(id)
            }
        }
    }

    private func emptyState(_ library: CitationLibrary) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(library.sources.isEmpty ? "Noch keine Quellen" : "Keine Quelle gewählt")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Füge oben eine DOI, ISBN, arXiv-ID oder Web-Adresse ein – die Angaben werden geholt.\nOder lege links unten eine Quelle von Hand an.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top bar

private struct CitationTopBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CitationStudioModel
    let library: CitationLibrary
    @FocusState private var importFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !app.sidebarVisible {
                SidebarToggleButton()
                    .padding(.trailing, 4)
            }
            Image(systemName: StudioApplication.citation.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Citation Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(library.sources.count) Quellen · \(library.quotes.count) Zitate")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 16)
            importField
                .frame(maxWidth: 460)
            Button {
                model.showsQuickAdd = true
            } label: {
                Label("Zitat", systemImage: "plus.bubble")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Zitat schnell erfassen – zu irgendeiner Quelle (⇧⌘N)")
            .disabled(library.sources.isEmpty)
            IconButton(systemName: "xmark", help: "Citation Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { app.closeCitationStudio() }
            }
        }
        .padding(.leading, app.sidebarVisible ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, Theme.topBarBottomPadding + 4)
        .background(WindowDragArea())
    }

    private var importField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                TextField("DOI, ISBN, arXiv-ID oder Web-Adresse einfügen …", text: $model.importText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($importFocused)
                    .onSubmit { Task { await model.runImport(in: library) } }
                    .onChange(of: model.importText) { _, _ in model.importMessage = nil }
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else if !model.importText.isEmpty {
                    Button("Holen") { Task { await model.runImport(in: library) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(importFocused ? Theme.accent.opacity(0.55) : Theme.border))
            .help("Die Kennung wird bei Crossref (DOI), der Deutschen Nationalbibliothek, Open Library oder Google Books (ISBN) bzw. arXiv nachgeschlagen; eine Web-Adresse wird gelesen.")
        }
        .overlay(alignment: .bottomLeading) {
            if let message = model.importMessage {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
                    .offset(y: 34)
                    .fixedSize(horizontal: false, vertical: true)
                    .zIndex(2)
            }
        }
    }
}

/// A looked-up source that looks like one in the library.
private struct DuplicateBanner: View {
    let pending: CitationStudioModel.PendingImport
    let model: CitationStudioModel
    let library: CitationLibrary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("„\(pending.source.title)“ gibt es vielleicht schon")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(pending.duplicates.compactMap { duplicate in
                    library.source(duplicate.sourceID).map { "\($0.citekey) (\(duplicate.reasons.map(\.label).joined(separator: ", ")))" }
                }.joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Spacer()
            if let first = pending.duplicates.first {
                Button("Zur vorhandenen") {
                    model.pendingImport = nil
                    model.mode = .sources
                    model.select(first.sourceID, in: library)
                }
            }
            Button("Trotzdem anlegen") { model.accept(pending.source, in: library) }
            Button("Verwerfen") { model.pendingImport = nil }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
    }
}

// MARK: - Source list

private struct CitationSourceList: View {
    @Bindable var model: CitationStudioModel
    let library: CitationLibrary
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sources = model.visibleSources(library)
        let quoteCounts = Dictionary(grouping: library.quotes, by: \.sourceID).mapValues(\.count)
        VStack(spacing: 10) {
            Picker("", selection: $model.mode) {
                ForEach(CitationStudioModel.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            searchField
            tagChips
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sources) { source in
                        SourceRow(source: source, quoteCount: quoteCounts[source.id] ?? 0,
                                  isSelected: model.mode == .sources && model.selectedSourceID == source.id) {
                            model.mode = .sources
                            model.select(source.id, in: library)
                        }
                    }
                    if sources.isEmpty, !library.sources.isEmpty {
                        Text("Nichts gefunden")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 8)
            }
            footer(count: sources.count)
        }
        .padding(.top, 2)
        .background(Theme.sidebar.opacity(0.5))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Suchen – #tag  @autor  2021  typ:buch", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? Theme.accent.opacity(0.5) : Theme.border))
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var tagChips: some View {
        let tags = library.allTags.prefix(14)
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(tags), id: \.tag) { item in
                        let active = model.isTagActive(item.tag)
                        Button {
                            model.toggleTag(item.tag)
                        } label: {
                            Text("#\(item.tag)")
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 21)
                                .background(Capsule().fill(active ? Theme.accent.opacity(0.18) : Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("\(item.count)× verwendet")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func footer(count: Int) -> some View {
        HStack {
            Menu {
                ForEach(SourceType.allCases) { type in
                    Button(type.label, systemImage: type.symbol) { model.newSource(type, in: library) }
                }
            } label: {
                Label("Neue Quelle", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .fixedSize()
            Spacer()
            Menu {
                Picker("Sortieren", selection: $model.sort) {
                    ForEach(CitationStudioModel.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(model.sort.label)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct SourceRow: View {
    let source: CitationSource
    let quoteCount: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: source.type.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title.isEmpty ? "Ohne Titel" : source.fullTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(source.title.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(source.shortReference)
                            .lineLimit(1)
                        if !source.container.isEmpty, !source.creators.isEmpty {
                            Text("· " + source.container).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                if quoteCount > 0 {
                    Text("\(quoteCount)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .help("\(quoteCount) Zitat\(quoteCount == 1 ? "" : "e")")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Knowledge (all quotes)

/// All quotes that fit the search, as cards; each names its source.
private struct KnowledgeView: View {
    let model: CitationStudioModel
    let library: CitationLibrary

    var body: some View {
        let ids = library.search(model.searchText).quoteIDs
        let quotes = ids.compactMap { library.quote($0) }.reversed()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(model.searchText.isEmpty ? "Alle Wissensbausteine" : "Wissensbausteine zu „\(model.searchText)“")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 4)
                if quotes.isEmpty {
                    Text(library.quotes.isEmpty ? "Noch keine Zitate. Wähle eine Quelle und füge ihr Zitate hinzu." : "Kein Zitat passt zur Suche.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(quotes)) { quote in
                    QuoteCard(quote: quote, library: library, showsSource: true) {
                        model.mode = .sources
                        model.select(quote.sourceID, in: library)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Quick add

/// A quote for any source: find the source by typing, then the words, the thought, page and tags.
private struct QuickQuoteSheet: View {
    let library: CitationLibrary
    let preselected: UUID?
    let onDone: (UUID?) -> Void
    @State private var query = ""
    @State private var sourceID: UUID?
    @State private var exactText = ""
    @State private var paraphrase = ""
    @State private var page = ""
    @State private var tags = ""
    @FocusState private var focus: Field?

    private enum Field { case search, exact }

    var body: some View {
        let matches = Array(library.search(query).sourceIDs.prefix(6).compactMap { library.source($0) })
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble").foregroundStyle(Theme.accent)
                Text("Zitat erfassen").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Quelle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                TextField("Quelle suchen – Titel, Autor:in, Jahr …", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onSubmit {
                        if let first = matches.first { sourceID = first.id; focus = .exact }
                    }
                VStack(spacing: 1) {
                    ForEach(matches) { source in
                        Button {
                            sourceID = source.id
                            focus = .exact
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: sourceID == source.id ? "checkmark.circle.fill" : source.type.symbol)
                                    .foregroundStyle(sourceID == source.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 16)
                                Text(source.shortReference).foregroundStyle(Theme.textSecondary)
                                Text(source.title.isEmpty ? "Ohne Titel" : source.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(sourceID == source.id ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField("Wörtliches Zitat", text: $exactText, axis: .vertical)
                .lineLimit(3...8)
                .font(.system(size: 13, design: .serif))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .exact)
            TextField("Eigener Gedanke oder Paraphrase", text: $paraphrase, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Seite", text: $page).textFieldStyle(.roundedBorder).frame(width: 90)
                TextField("Schlagwörter, mit Komma getrennt", text: $tags).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Hinzufügen") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sourceID == nil || (exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && paraphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
        .onAppear {
            sourceID = preselected
            focus = preselected == nil ? .search : .exact
        }
    }

    private func add() {
        guard let sourceID else { return }
        var quote = CitationQuote(sourceID: sourceID)
        quote.exactText = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.paraphrase = paraphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.page = page
        quote.tags = tags.split(separator: ",").map(String.init)
        library.addQuote(quote)
        onDone(sourceID)
    }
}
