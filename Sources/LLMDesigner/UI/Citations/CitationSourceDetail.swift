import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The fields of a source the form offers.
enum SourceField: CaseIterable {
    case year, date, container, publisher, place, edition, volume, issue, pages, doi, isbn, arxiv, url, accessed, language

    func label(for type: SourceType) -> String {
        switch self {
        case .year: "Jahr"
        case .date: "Datum"
        case .container: type.containerLabel
        case .publisher: type == .report ? "Institution" : "Verlag"
        case .place: "Ort"
        case .edition: "Auflage"
        case .volume: type == .article ? "Jahrgang / Band" : "Band"
        case .issue: "Heft"
        case .pages: "Seiten"
        case .doi: "DOI"
        case .isbn: "ISBN"
        case .arxiv: "arXiv-ID"
        case .url: "Adresse (URL)"
        case .accessed: "Abgerufen am"
        case .language: "Sprache"
        }
    }

    /// What a source of this kind usually needs; the others are behind "Alle Felder".
    static func primary(for type: SourceType) -> [SourceField] {
        switch type {
        case .book: [.year, .publisher, .place, .edition, .isbn, .doi, .url]
        case .chapter: [.year, .container, .publisher, .place, .pages, .isbn, .doi]
        case .article: [.year, .container, .volume, .issue, .pages, .doi, .url]
        case .paper: [.year, .container, .doi, .arxiv, .url]
        case .thesis: [.year, .container, .place, .url]
        case .report: [.year, .publisher, .place, .doi, .url]
        case .web: [.date, .container, .url, .accessed]
        case .other: [.year, .container, .publisher, .place, .url]
        }
    }

    var keyPath: WritableKeyPath<CitationSource, String>? {
        switch self {
        case .date: \.date
        case .container: \.container
        case .publisher: \.publisher
        case .place: \.place
        case .edition: \.edition
        case .volume: \.volume
        case .issue: \.issue
        case .pages: \.pages
        case .doi: \.doi
        case .isbn: \.isbn
        case .arxiv: \.arxiv
        case .url: \.url
        case .language: \.language
        case .year, .accessed: nil
        }
    }
}

/// One source: its data, its files and its quotes.
struct CitationSourceDetail: View {
    let sourceID: UUID
    let model: CitationStudioModel
    let library: CitationLibrary
    @State private var showsAllFields = false
    @State private var editingKey = false
    @State private var keyText = ""
    @State private var keyError: String?
    @State private var confirmsDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let source = library.source(sourceID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(source)
                    duplicateWarning(source)
                    titleFields(source)
                    PeopleField(title: "Autor:innen", people: source.authors) { people in library.updateSource(sourceID) { $0.authors = people } }
                    if [.chapter, .book, .report, .other].contains(source.type) || !source.editors.isEmpty {
                        PeopleField(title: "Herausgeber:innen", people: source.editors) { people in library.updateSource(sourceID) { $0.editors = people } }
                    }
                    fields(source)
                    TagField(tags: source.tags, placeholder: "Schlagwörter der Quelle, mit Komma getrennt") { tags in
                        library.updateSource(sourceID) { $0.tags = tags }
                    }
                    notes(source)
                    attachments(source)
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                    QuotesSection(source: source, library: library)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in try? library.attach(url, to: sourceID) }
                    }
                }
                return true
            }
            .onAppear {
                if model.focusTitleOf == sourceID {
                    model.focusTitleOf = nil
                    DispatchQueue.main.async { titleFocused = true }
                }
            }
            .confirmationDialog("„\(source.title.isEmpty ? "Ohne Titel" : source.title)“ löschen?", isPresented: $confirmsDelete) {
                Button("Quelle und \(library.quotes(of: sourceID).count) Zitate löschen", role: .destructive) {
                    model.select(nil, in: library)
                    library.deleteSource(sourceID)
                }
            } message: {
                Text("Angehängte Dateien kommen in den Papierkorb.")
            }
        }
    }

    // MARK: Parts

    private func header(_ source: CitationSource) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SourceType.allCases) { type in
                    Button(type.label, systemImage: type.symbol) { library.updateSource(sourceID) { $0.type = type } }
                }
            } label: {
                Label(source.type.label, systemImage: source.type.symbol)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            citekey(source)
            Spacer()
            Menu {
                CitationFolderItems(shelf: .sources, current: source.folderID, library: library) { library.file(source: sourceID, in: $0) }
            } label: {
                Label(library.folderPath(source.folderID) ?? "Unsortiert", systemImage: source.folderID == nil ? "tray" : "folder")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            .help("Ordner der Quelle")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[@\(source.citekey)]", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Verweis [@\(source.citekey)] kopieren")
            Button {
                confirmsDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Quelle löschen")
        }
    }

    @ViewBuilder
    private func citekey(_ source: CitationSource) -> some View {
        if editingKey {
            HStack(spacing: 6) {
                Text("@").foregroundStyle(Theme.textTertiary)
                TextField("schluessel2026", text: $keyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
                    .onSubmit { saveKey() }
                Button("OK", action: saveKey).controlSize(.small)
                Button("Abbrechen") { editingKey = false; keyError = nil }.controlSize(.small)
                if let suggestion = library.suggestedCitekey(for: sourceID), suggestion != source.citekey {
                    Button("Vorschlag: \(suggestion)") { keyText = suggestion }
                        .controlSize(.small)
                }
                if let keyError {
                    Text(keyError).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
                }
            }
        } else {
            Button {
                keyText = source.citekey
                editingKey = true
            } label: {
                Text("@" + source.citekey)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Zitierschlüssel – so wird die Quelle im Text zitiert ([@\(source.citekey)]). Klicken zum Ändern.")
        }
    }

    private func saveKey() {
        do {
            try library.setCitekey(keyText, for: sourceID)
            editingKey = false
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func duplicateWarning(_ source: CitationSource) -> some View {
        let duplicates = library.duplicates(of: source)
        if !duplicates.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("Sieht aus wie " + duplicates.compactMap { duplicate in
                    library.source(duplicate.sourceID).map { "@\($0.citekey) (\(duplicate.reasons.map(\.label).joined(separator: ", ")))" }
                }.joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let first = duplicates.first {
                    Button("Anzeigen") { model.select(first.sourceID, in: library) }.controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.08)))
        }
    }

    private func titleFields(_ source: CitationSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Titel", text: binding(\.title), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .focused($titleFocused)
            TextField("Untertitel", text: binding(\.subtitle), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1...3)
        }
    }

    private func fields(_ source: CitationSource) -> some View {
        let primary = SourceField.primary(for: source.type)
        let shown = showsAllFields ? SourceField.allCases : primary
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 8) {
                ForEach(shown, id: \.self) { field in
                    fieldRow(field, source: source)
                }
            }
            Button(showsAllFields ? "Weniger Felder" : "Alle Felder") { withAnimation(.easeInOut(duration: 0.15)) { showsAllFields.toggle() } }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: SourceField, source: CitationSource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(field.label(for: source.type))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                if field == .url, let url = URL(string: source.url), url.scheme?.hasPrefix("http") == true {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.accent)
                        .help("Im Browser öffnen")
                }
                if field == .doi, !source.doi.isEmpty, let url = URL(string: "https://doi.org/" + source.doi) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.accent)
                        .help("DOI öffnen")
                }
            }
            switch field {
            case .year:
                TextField("o. J.", text: Binding(
                    get: { library.source(sourceID)?.year.map(String.init) ?? "" },
                    set: { text in library.updateSource(sourceID) { $0.year = Int(text.filter(\.isNumber).prefix(4)) } }
                ))
                .styledField()
            case .accessed:
                HStack {
                    if let accessed = source.accessed {
                        DatePicker("", selection: Binding(get: { accessed }, set: { date in library.updateSource(sourceID) { $0.accessed = date } }),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                        Button { library.updateSource(sourceID) { $0.accessed = nil } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Button("Heute") { library.updateSource(sourceID) { $0.accessed = Date() } }
                            .controlSize(.small)
                    }
                }
            default:
                if let keyPath = field.keyPath {
                    TextField("", text: binding(keyPath))
                        .styledField()
                }
            }
        }
    }

    private func notes(_ source: CitationSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !source.abstract.isEmpty {
                DisclosureGroup {
                    Text(source.abstract)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("Zusammenfassung (Abstract)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Notizen zur Quelle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField("Was ist an dieser Quelle wichtig?", text: binding(\.notes), axis: .vertical)
                .lineLimit(2...8)
                .styledField()
        }
    }

    private func attachments(_ source: CitationSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Anhänge").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    chooseAttachments()
                } label: {
                    Label("Datei hinzufügen …", systemImage: "paperclip")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent)
            }
            if source.attachments.isEmpty {
                Text("PDFs und andere Dateien hierher ziehen – sie werden in die Bibliothek kopiert.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(source.attachments, id: \.fileName) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.fileName.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc")
                        .foregroundStyle(Theme.textSecondary)
                    Button(attachment.fileName) { NSWorkspace.shared.open(library.attachmentURL(attachment, of: sourceID)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .help("Öffnen")
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([library.attachmentURL(attachment, of: sourceID)]) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Im Finder zeigen")
                    Button { library.removeAttachment(attachment, from: sourceID) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Anhang entfernen (in den Papierkorb)")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Anhängen"
        panel.message = "Dateien zur Quelle (z. B. das PDF)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { try? library.attach(url, to: sourceID) }
    }

    private func binding(_ keyPath: WritableKeyPath<CitationSource, String>) -> Binding<String> {
        Binding(
            get: { library.source(sourceID)?[keyPath: keyPath] ?? "" },
            set: { value in library.updateSource(sourceID) { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - People and tags

/// One person per line: "Nachname, Vorname" (or "Vorname Nachname"); institutions in braces.
private struct PeopleField: View {
    let title: String
    let people: [PersonName]
    let onChange: ([PersonName]) -> Void
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField("Nachname, Vorname – eine Person pro Zeile, {Institution} in Klammern", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .styledField()
                .onChange(of: text) { _, newValue in
                    guard loaded else { return }
                    onChange(newValue.split(separator: "\n").map { PersonName.parse(String($0)) }.filter { !$0.isEmpty })
                }
        }
        .onAppear {
            text = people.map { $0.isInstitution ? "{\($0.family)}" : $0.sortName }.joined(separator: "\n")
            DispatchQueue.main.async { loaded = true }
        }
    }
}

/// Tags with commas between them.
struct TagField: View {
    let tags: [String]
    var placeholder = "Schlagwörter, mit Komma getrennt"
    let onChange: ([String]) -> Void
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onChange(of: text) { _, newValue in
                    guard loaded else { return }
                    onChange(newValue.split(separator: ",").map(String.init))
                }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
        .onAppear {
            text = tags.joined(separator: ", ")
            DispatchQueue.main.async { loaded = true }
        }
    }
}

private extension View {
    func styledField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Quotes

/// A new quote at the top, the source's quotes below.
private struct QuotesSection: View {
    let source: CitationSource
    let library: CitationLibrary

    var body: some View {
        let quotes = library.quotes(of: source.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Zitate & Gedanken")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(quotes.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            QuoteComposer(sourceID: source.id, library: library)
            ForEach(quotes.reversed()) { quote in
                QuoteCard(quote: quote, library: library, showsSource: false)
            }
        }
    }
}

/// Writes a new quote: the exact words, an own thought, the page and tags. ⌘↩ adds it.
private struct QuoteComposer: View {
    let sourceID: UUID
    let library: CitationLibrary
    @State private var exactText = ""
    @State private var paraphrase = ""
    @State private var page = ""
    @State private var tags = ""
    @FocusState private var focus: Bool

    private var canAdd: Bool {
        !exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paraphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Wörtliches Zitat – genau wie in der Quelle", text: $exactText, axis: .vertical)
                .lineLimit(2...8)
                .font(.system(size: 13, design: .serif))
                .focused($focus)
                .styledField()
            TextField("Eigener Gedanke oder Paraphrase", text: $paraphrase, axis: .vertical)
                .lineLimit(1...6)
                .styledField()
            HStack(spacing: 8) {
                TextField("Seite", text: $page)
                    .frame(width: 90)
                    .styledField()
                TextField("Schlagwörter, mit Komma getrennt", text: $tags)
                    .styledField()
                Button {
                    add()
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canAdd)
                .help("Zitat hinzufügen (⌘↩)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }

    private func add() {
        guard canAdd else { return }
        var quote = CitationQuote(sourceID: sourceID)
        quote.exactText = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.paraphrase = paraphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.page = page
        quote.tags = tags.split(separator: ",").map(String.init)
        library.addQuote(quote)
        exactText = ""
        paraphrase = ""
        page = ""
        // Tags often stay the same for the next quote from the same source.
        focus = true
    }
}

/// A quote as a card: the words, the thought, page, tags; editable in place.
struct QuoteCard: View {
    let quote: CitationQuote
    let library: CitationLibrary
    let showsSource: Bool
    var onOpenSource: () -> Void = {}
    @State private var hovering = false
    @State private var editing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSource, let source = library.source(quote.sourceID) {
                Button(action: onOpenSource) {
                    HStack(spacing: 5) {
                        Image(systemName: source.type.symbol)
                        Text(source.shortReference)
                        Text("· " + (source.title.isEmpty ? "Ohne Titel" : source.title)).lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Zur Quelle")
            }
            if editing {
                QuoteEditor(quote: quote, library: library) { editing = false }
            } else {
                if !quote.exactText.isEmpty {
                    Text("„\(quote.exactText)“")
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !quote.paraphrase.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                            .padding(.top, 2)
                        Text(quote.paraphrase)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                footer
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !quote.locator.isEmpty {
                Text(quote.locator)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            ForEach(quote.tags, id: \.self) { tag in
                Text("#" + tag)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }
            if !quote.linkedQuoteIDs.isEmpty {
                Label("\(quote.linkedQuoteIDs.count)", systemImage: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Verweist auf \(quote.linkedQuoteIDs.count) andere\(quote.linkedQuoteIDs.count == 1 ? "s" : "") Zitat\(quote.linkedQuoteIDs.count == 1 ? "" : "e")")
            }
            Spacer()
            if let path = library.folderPath(quote.folderID) {
                Label(path, systemImage: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Menu {
                    CitationFolderItems(shelf: .quotes, current: quote.folderID, library: library) { library.file(quote: quote.id, in: $0) }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Wissensbaustein in einen Ordner legen")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quote.formatted(with: library.source(quote.sourceID)), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Mit Quellenangabe kopieren: „…“ (Autor, Jahr, S. …)")
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .help("Bearbeiten")
                Button { library.deleteQuote(quote.id) } label: { Image(systemName: "trash") }
                    .help("Zitat löschen")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .opacity(hovering ? 1 : 0.35)
        }
    }
}

/// The fields of a quote in place.
private struct QuoteEditor: View {
    let quote: CitationQuote
    let library: CitationLibrary
    let onDone: () -> Void
    @State private var exactText = ""
    @State private var paraphrase = ""
    @State private var page = ""
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Wörtliches Zitat", text: $exactText, axis: .vertical)
                .lineLimit(2...10)
                .font(.system(size: 13, design: .serif))
                .styledField()
            TextField("Eigener Gedanke oder Paraphrase", text: $paraphrase, axis: .vertical)
                .lineLimit(1...8)
                .styledField()
            HStack(spacing: 8) {
                TextField("Seite", text: $page).frame(width: 90).styledField()
                TextField("Schlagwörter, mit Komma getrennt", text: $tags).styledField()
                Button("Fertig") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear {
            exactText = quote.exactText
            paraphrase = quote.paraphrase
            page = quote.page
            tags = quote.tags.joined(separator: ", ")
        }
    }

    private func save() {
        library.updateQuote(quote.id) {
            $0.exactText = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.paraphrase = paraphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.page = page
            $0.tags = tags.split(separator: ",").map(String.init)
        }
        onDone()
    }
}
