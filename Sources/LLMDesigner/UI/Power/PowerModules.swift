import AppKit
import SwiftUI

// MARK: - Writer

/// Writer Studio in small: the documents, then one of them as blocks to drag out, with text dropped in between.
struct PowerDocuments: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.power.documentID, let document = app.document(id), !document.isPresentation {
            PowerDocumentView(document: document)
        } else {
            list
        }
    }

    private var list: some View {
        let query = app.power.query
        let documents = app.documents.filter { !$0.isPresentation }
        let shown = query.isEmpty ? documents : documents.filter { PowerText.matches($0.displayTitle, query) || PowerText.matches($0.markdown, query) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                PowerDropZone(title: "Text hierher ziehen: neues Dokument", symbol: "doc.badge.plus") { dropped in
                    app.powerNewDocument(markdown: dropped.markdown)
                }
                .padding(.bottom, 6)
                ForEach(shown) { document in
                    PowerListRow(
                        title: document.displayTitle,
                        subtitle: document.updatedAt.formatted(date: .abbreviated, time: .shortened),
                        snippet: query.isEmpty ? nil : PowerText.snippet(of: PowerText.plain(document.markdown), around: query),
                        symbol: StudioApplication.writer.symbol,
                        isCurrent: document.id == app.selectedDocumentID
                    ) {
                        app.power.documentID = document.id
                    }
                }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Dokumente." : "Kein Dokument passt zur Suche.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

/// One document as blocks: search marks and scrolls to its places; blocks drag out; text dropped on a block goes
/// before it, at the end below the last one; a block dragged within the panel moves.
private struct PowerDocumentView: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var currentMatch = 0

    var body: some View {
        let query = app.power.query
        let chunks = PowerText.chunks(of: document.markdown)
        let matches = query.isEmpty ? [] : chunks.filter { PowerText.matches($0.plain, query) }.map(\.id)
        VStack(spacing: 0) {
            PowerItemBar(title: document.displayTitle, symbol: StudioApplication.writer.symbol, openHelp: "In Writer Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.selectDocument(document.id)
            }
            if !query.isEmpty { PowerMatchBar(count: matches.count, current: $currentMatch) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(chunks) { chunk in
                            PowerBlockRow(
                                chunk: chunk,
                                query: query,
                                isMatch: matches.contains(chunk.id),
                                origin: "\(document.id.uuidString)|\(chunk.id)",
                                onDrop: { drop($0, before: chunk.id) },
                                onEdit: { text in
                                    app.powerChangeDocument(document.id, label: "Block geändert") { PowerText.replacing(chunk.id, with: text, in: $0) }
                                },
                                onDelete: {
                                    app.powerChangeDocument(document.id, label: "Block gelöscht") { PowerText.replacing(chunk.id, with: "", in: $0) }
                                }
                            )
                            .id(chunk.id)
                        }
                        PowerDropZone(title: chunks.isEmpty ? "Text hierher ziehen" : "Text ans Ende ziehen", symbol: "text.append") { drop($0, before: chunks.count) }
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .onChange(of: currentMatch) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(matches[index], anchor: .center) }
                }
                .onChange(of: query) { _, _ in
                    currentMatch = 0
                    if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }

    private func drop(_ dropped: PowerDrag.Dropped, before index: Int) {
        let prefix = document.id.uuidString + "|"
        if let block = dropped.block, block.hasPrefix(prefix), let from = Int(block.dropFirst(prefix.count)) {
            guard from != index, from + 1 != index else { return }
            app.powerChangeDocument(document.id, label: "Block verschoben") { PowerText.moving(from, to: index, in: $0) }
        } else {
            app.powerInsert(dropped.markdown, into: document.id, at: index)
        }
    }
}

// MARK: - Presenter

/// Presenter Studio in small: the presentations, then one of them as slide cards. Each card shows the slide and its
/// text as blocks to drag out; text dropped on a card goes onto that slide, on "Neue Folie" it becomes a slide.
struct PowerPresentations: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.power.presentationID, let document = app.document(id), let deck = document.deck {
            PowerDeckView(document: document, deck: deck)
        } else {
            list
        }
    }

    private var list: some View {
        let query = app.power.query
        let decks = app.documents.filter(\.isPresentation)
        let shown = query.isEmpty ? decks : decks.filter { PowerText.matches($0.displayTitle, query) || PowerText.matches($0.markdown, query) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { document in
                    PowerListRow(
                        title: document.displayTitle,
                        subtitle: "\(document.deck?.slides.count ?? 0) Folien",
                        snippet: query.isEmpty ? nil : PowerText.snippet(of: PowerText.plain(document.markdown), around: query),
                        symbol: StudioApplication.presenter.symbol,
                        isCurrent: document.id == app.selectedDocumentID
                    ) {
                        app.power.presentationID = document.id
                    }
                }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Präsentationen." : "Keine Präsentation passt zur Suche.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

private struct PowerDeckView: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    @State private var currentMatch = 0

    var body: some View {
        let query = app.power.query
        let matches = query.isEmpty ? [] : deck.slides.filter { PowerText.matches(PowerText.plain($0.fullMarkdown), query) }.map(\.id)
        VStack(spacing: 0) {
            PowerItemBar(title: document.displayTitle, symbol: StudioApplication.presenter.symbol, openHelp: "In Presenter Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.selectDocument(document.id)
            }
            if !query.isEmpty { PowerMatchBar(count: matches.count, current: $currentMatch) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                            PowerSlideCard(document: document, deck: deck, slide: slide, number: index + 1, query: query, isMatch: matches.contains(slide.id))
                                .id(slide.id)
                        }
                        PowerDropZone(title: "Text hierher ziehen: neue Folie", symbol: "rectangle.badge.plus") { dropped in
                            app.powerNewSlide(dropped.markdown, in: document.id, after: deck.slides.last?.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
                .onChange(of: currentMatch) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(matches[index], anchor: .top) }
                }
                .onChange(of: query) { _, _ in
                    currentMatch = 0
                    if let first = matches.first { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
    }
}

/// A slide in the panel: its picture with the number, its text as blocks (also those of its text fields).
private struct PowerSlideCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide
    let number: Int
    let query: String
    let isMatch: Bool
    @State private var targeted = false
    @State private var expanded = false

    var body: some View {
        let chunks = PowerText.chunks(of: slide.fullMarkdown)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                SlideThumbnail(slide: slide, deck: deck, family: document.textFont)
                    .frame(width: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(targeted ? Theme.accent : Color.white.opacity(0.1), lineWidth: targeted ? 2 : 1))
                    .powerDrag(markdown: slide.fullMarkdown, plain: PowerText.plain(slide.fullMarkdown))
                    .help("Ziehen: der ganze Text der Folie")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folie \(number) · \(slide.role.label)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isMatch ? Theme.accent : Theme.textTertiary)
                    Text(powerHighlighted(slide.title.isEmpty ? "Ohne Titel" : slide.title, query))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        Button(expanded ? "Text ausblenden" : "Text zeigen") { expanded.toggle() }
                        Button("Öffnen") {
                            app.selectDocument(document.id)
                            app.selectSlide(slide.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            if expanded || isMatch {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chunks) { chunk in
                        PowerBlockRow(chunk: chunk, query: query)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(targeted ? Theme.accent.opacity(0.1) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isMatch ? Theme.accent.opacity(0.5) : Theme.border))
        .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
            PowerDrag.load(providers) { dropped in
                app.powerAppend(dropped.markdown, toSlide: slide.id, in: document.id)
                expanded = true
            }
        }
        .contextMenu {
            Button("Text kopieren", systemImage: "doc.on.doc") { powerCopy(markdown: slide.fullMarkdown, plain: PowerText.plain(slide.fullMarkdown)) }
            Button("An der Schreibmarke einfügen", systemImage: "text.insert") { _ = powerInsertAtCaret(slide.fullMarkdown, app: app) }
                .disabled(!app.canFormatText)
        }
    }
}

// MARK: - Chats

/// The chats in small: a chat's messages as blocks to drag into a document or onto a slide.
struct PowerChats: View {
    @Environment(AppModel.self) private var app
    @State private var currentMatch = 0

    var body: some View {
        if let id = app.power.chatID, let chat = app.chats.first(where: { $0.id == id }) {
            chatView(chat)
        } else {
            list
        }
    }

    private var list: some View {
        let query = app.power.query
        let shown = query.isEmpty ? app.chats : app.chats.filter { chat in
            PowerText.matches(chat.title, query) || chat.messages.contains { PowerText.matches($0.content, query) }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { chat in
                    PowerListRow(
                        title: chat.title.isEmpty ? "Neuer Chat" : chat.title,
                        subtitle: "\(chat.messages.count) Nachrichten",
                        snippet: query.isEmpty ? nil : chat.messages.lazy.compactMap { PowerText.snippet(of: $0.content, around: query) }.first,
                        symbol: "bubble.left",
                        isCurrent: chat.id == app.selectedChatID && app.selectedDocumentID == nil
                    ) {
                        app.power.chatID = chat.id
                    }
                }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Chats." : "Kein Chat passt zur Suche.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func chatView(_ chat: Chat) -> some View {
        let query = app.power.query
        let messages = chat.messages.filter { $0.role == .user || $0.role == .assistant }
        let matches = query.isEmpty ? [] : messages.filter { PowerText.matches($0.content, query) }.map(\.id)
        return VStack(spacing: 0) {
            PowerItemBar(title: chat.title.isEmpty ? "Neuer Chat" : chat.title, symbol: "bubble.left", openHelp: "Chat öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.closeDocument()
                app.selectChat(chat.id)
            }
            if !query.isEmpty { PowerMatchBar(count: matches.count, current: $currentMatch) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.role == .user ? "Du" : (message.model ?? "Antwort"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(message.role == .user ? Theme.accent : Theme.textTertiary)
                                    .padding(.leading, 20)
                                ForEach(PowerText.chunks(of: message.content)) { chunk in
                                    PowerBlockRow(chunk: chunk, query: query, isMatch: PowerText.matches(chunk.plain, query))
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .onChange(of: currentMatch) { _, index in
                    guard matches.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(matches[index], anchor: .top) }
                }
                .onChange(of: query) { _, _ in
                    currentMatch = 0
                    if let first = matches.first { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
    }
}

// MARK: - Citation

/// Citation Studio in small: the sources (and quotes the search finds), a source's quotes to drag into the text with
/// their citation, text dropped on the source becomes a quote; a field adds one by hand, another imports a source.
struct PowerCitations: View {
    @Environment(AppModel.self) private var app
    @State private var importText = ""
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        let library = app.citations
        if let id = app.power.sourceID, let source = library.source(id) {
            PowerSourceView(source: source)
        } else {
            list(library)
        }
    }

    private func list(_ library: CitationLibrary) -> some View {
        let query = app.power.query
        let sources = library.sources
        let shown = query.isEmpty ? sources : sources.filter { source in
            PowerText.matches(source.title, query) || PowerText.matches(source.shortAuthors, query) || PowerText.matches(source.citekey, query)
                || library.quotes(of: source.id).contains { PowerText.matches($0.exactText + " " + $0.paraphrase, query) }
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("", text: $importText, prompt: Text("DOI, ISBN, arXiv oder URL").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { runImport() }
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    IconButton(systemName: "square.and.arrow.down", help: "Quelle importieren", size: 12, frameSize: 24) { runImport() }
                        .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            if let importMessage {
                Text(importMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { source in
                        let quotes = library.quotes(of: source.id)
                        PowerListRow(
                            title: source.title.isEmpty ? "Ohne Titel" : source.title,
                            subtitle: [source.shortAuthors, source.yearText, "\(quotes.count) Zitate"].filter { !$0.isEmpty }.joined(separator: " · "),
                            snippet: query.isEmpty ? nil : quotes.lazy.compactMap { PowerText.snippet(of: $0.exactText + " " + $0.paraphrase, around: query) }.first,
                            symbol: "book.closed"
                        ) {
                            app.power.sourceID = source.id
                            app.power.query = query.isEmpty || PowerText.matches(source.title, query) ? "" : query
                        }
                    }
                    if shown.isEmpty {
                        PowerEmpty(text: query.isEmpty ? "Noch keine Quellen – oben eine DOI oder ISBN eingeben." : "Keine Quelle passt zur Suche.")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func runImport() {
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !importing else { return }
        guard let identifier = CitationIdentifier.detect(text) else {
            importMessage = CitationLookupError.unrecognized.localizedDescription
            return
        }
        importing = true
        importMessage = nil
        Task {
            defer { importing = false }
            do {
                let source = try await CitationLookup.lookup(identifier)
                let library = app.citations
                if let existing = library.duplicates(of: source).first.flatMap({ library.source($0.sourceID) }) {
                    importMessage = "Schon da: „\(existing.title)“"
                    app.power.sourceID = existing.id
                } else {
                    let added = library.addSource(source)
                    app.power.sourceID = added.id
                }
                importText = ""
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }
}

private struct PowerSourceView: View {
    @Environment(AppModel.self) private var app
    let source: CitationSource
    @State private var newQuote = ""
    @State private var page = ""
    @State private var targeted = false

    var body: some View {
        let query = app.power.query
        let quotes = app.citations.quotes(of: source.id)
        let shown = query.isEmpty ? quotes : quotes.filter { PowerText.matches($0.exactText + " " + $0.paraphrase, query) }
        let reference = CitationStyle(sources: [source], cited: [source.citekey]).reference(source).plain
        VStack(spacing: 0) {
            PowerItemBar(title: source.title.isEmpty ? "Ohne Titel" : source.title, symbol: "book.closed", openHelp: "In Citation Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openCitationStudio(showing: source.id)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reference)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    ForEach(shown) { quote in
                        PowerQuoteCard(quote: quote, query: query)
                    }
                    if shown.isEmpty {
                        PowerEmpty(text: query.isEmpty ? "Noch keine Zitate – Text hierher ziehen oder unten eingeben." : "Kein Zitat passt zur Suche.")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.accent.opacity(0.08) : .clear))
            .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
                PowerDrag.load(providers) { dropped in app.powerAddQuote(dropped.markdown, to: source.id) }
            }
            composer
        }
    }

    /// A quote typed in: its words and page; ⌘↩ keeps it.
    private var composer: some View {
        VStack(alignment: .trailing, spacing: 5) {
            TextEditor(text: $newQuote)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 54)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(alignment: .topLeading) {
                    if newQuote.isEmpty {
                        Text("Neues Zitat – oder Text auf die Quelle ziehen")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                TextField("", text: $page, prompt: Text("Seite").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 70)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05)))
                Spacer(minLength: 0)
                Button("Zitat anlegen") {
                    if app.powerAddQuote(newQuote, to: source.id, page: page) != nil {
                        newQuote = ""
                        page = ""
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(newQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.textTertiary : Theme.accent)
                .disabled(newQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// A quote: its words, the page, the paraphrase; dragged out with its citation.
private struct PowerQuoteCard: View {
    @Environment(AppModel.self) private var app
    let quote: CitationQuote
    let query: String
    @State private var hovering = false

    var body: some View {
        let text = app.powerQuoteText(quote)
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
                .powerDrag(markdown: text.markdown, plain: text.plain)
                .help("Ziehen: das Zitat mit Quellenangabe")
            VStack(alignment: .leading, spacing: 4) {
                if !quote.exactText.isEmpty {
                    Text(powerHighlighted("„\(quote.exactText)“", query))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                if !quote.paraphrase.isEmpty {
                    Text(powerHighlighted(quote.paraphrase, query))
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                if !quote.locator.isEmpty {
                    Text(quote.locator)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Mit Quellenangabe kopieren", systemImage: "doc.on.doc") { powerCopy(markdown: text.markdown, plain: text.plain) }
            Button("An der Schreibmarke einfügen", systemImage: "text.insert") { _ = powerInsertAtCaret(text.markdown, app: app) }
                .disabled(!app.canFormatText)
            Divider()
            Button("Zitat löschen", systemImage: "trash", role: .destructive) { app.citations.deleteQuote(quote.id) }
        }
    }
}

// MARK: - Stories

/// Stories Studio in small: the novel worlds, then one world's figures, places, events, reasons and purposes. An
/// element drags out as its name and text; text dropped on the list becomes a new element (first line: its name).
struct PowerStories: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.stories
        if let id = app.power.worldID, let world = library.world(id) {
            PowerWorldView(world: world)
        } else {
            let query = app.power.query
            let shown = query.isEmpty ? library.worlds : library.worlds.filter { world in
                PowerText.matches(world.displayTitle, query)
                    || StoryElementKind.listOrder.contains { kind in AppModel.storyItems(kind, in: world).contains { PowerText.matches($0.name + " " + $0.text, query) } }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { world in
                        PowerListRow(
                            title: world.displayTitle,
                            subtitle: "\(world.figures.count) Figuren · \(world.places.count) Orte · \(world.events.count) Events",
                            symbol: StudioApplication.stories.symbol
                        ) {
                            app.power.worldID = world.id
                        }
                    }
                    if shown.isEmpty {
                        PowerEmpty(text: query.isEmpty ? "Noch keine Romanwelten – in Stories Studio anlegen." : "Keine Romanwelt passt zur Suche.")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct PowerWorldView: View {
    @Environment(AppModel.self) private var app
    let world: StoryWorld
    @State private var newName = ""
    @State private var targeted = false
    @State private var expanded: UUID?

    var body: some View {
        @Bindable var power = app.power
        let query = power.query
        let kind = power.storyKind
        let items = AppModel.storyItems(kind, in: world)
        let shown = query.isEmpty ? items : items.filter { PowerText.matches($0.name + " " + $0.subtitle + " " + $0.text, query) }
        VStack(spacing: 0) {
            PowerItemBar(title: world.displayTitle, symbol: StudioApplication.stories.symbol, openHelp: "In Stories Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openStoriesStudio()
            }
            HStack(spacing: 2) {
                ForEach(StoryElementKind.listOrder) { option in
                    let count = AppModel.storyItems(option, in: world).count
                    let matching = !query.isEmpty && AppModel.storyItems(option, in: world).contains { PowerText.matches($0.name + " " + $0.text, query) }
                    Button { power.storyKind = option } label: {
                        VStack(spacing: 1) {
                            Image(systemName: option.symbol).font(.system(size: 11))
                            Text("\(option.title) \(count)").font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(option == kind ? Theme.textPrimary : (matching ? Theme.accent : Theme.textTertiary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(option == kind ? Color.white.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(shown, id: \.ref.id) { item in
                        PowerStoryCard(world: world, ref: item.ref, name: item.name, subtitle: item.subtitle, text: item.text, query: query,
                                       expanded: Binding(get: { expanded == item.ref.id || (!query.isEmpty && PowerText.matches(item.text, query)) },
                                                         set: { expanded = $0 ? item.ref.id : nil }))
                    }
                    if shown.isEmpty {
                        PowerEmpty(text: query.isEmpty ? "Noch keine \(kind.title) – Text hierher ziehen oder unten einen Namen eingeben." : "Nichts passt zur Suche.")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.accent.opacity(0.08) : .clear))
            .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
                PowerDrag.load(providers) { dropped in
                    if let id = app.powerAddStoryElement(kind, text: dropped.markdown, in: world.id) { expanded = id }
                }
            }
            HStack(spacing: 6) {
                TextField("", text: $newName, prompt: Text("Neu: \(kind.singular) – Name").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(add)
                IconButton(systemName: "plus", help: "\(kind.singular) anlegen", size: 12, frameSize: 24, action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            .padding(10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = app.powerAddStoryElement(app.power.storyKind, text: name, in: world.id) { expanded = id }
        newName = ""
    }
}

/// An element of a world: name and line below; opened, its main text to edit. Dragged out as name and text.
private struct PowerStoryCard: View {
    @Environment(AppModel.self) private var app
    let world: StoryWorld
    let ref: StoryRef
    let name: String
    let subtitle: String
    let text: String
    let query: String
    @Binding var expanded: Bool
    @State private var draft = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
                    .powerDrag(markdown: "**\(name)**" + (text.isEmpty ? "" : "\n\n" + text), plain: name + (text.isEmpty ? "" : "\n\n" + text))
                    .help("Ziehen: Name und \(AppModel.storyTextLabel(ref.kind))")
                Button {
                    expanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(powerHighlighted(name, query))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        if !expanded, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppModel.storyTextLabel(ref.kind))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    TextEditor(text: $draft)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70, maxHeight: 200)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05)))
                        .onAppear { draft = text }
                        .onChange(of: draft) { _, value in
                            guard value != text else { return }
                            app.stories.update(world.id) { world in AppModel.setStoryText(value, of: ref, in: &world) }
                        }
                }
                .padding(.leading, 20)
                .onDrop(of: PowerDrag.accepted, isTargeted: nil) { providers in
                    PowerDrag.load(providers) { dropped in
                        let addition = PowerText.plain(dropped.markdown)
                        draft = draft.isEmpty ? addition : draft + "\n\n" + addition
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Kopieren", systemImage: "doc.on.doc") { powerCopy(markdown: "**\(name)**\n\n\(text)", plain: name + "\n\n" + text) }
            Button("An der Schreibmarke einfügen", systemImage: "text.insert") { _ = powerInsertAtCaret("**\(name)**\n\n\(text)", app: app) }
                .disabled(!app.canFormatText)
        }
    }
}

// MARK: - Empty

struct PowerEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
    }
}
