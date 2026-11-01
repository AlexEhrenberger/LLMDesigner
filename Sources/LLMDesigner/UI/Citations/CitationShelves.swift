import SwiftUI

/// The left column of Citation Studio: groups with folders for the sources, or for the knowledge pieces, plus
/// what isn't filed yet. Sources and quotes can be dragged onto folders.
struct CitationSourceList: View {
    @Bindable var model: CitationStudioModel
    let library: CitationLibrary
    @FocusState private var searchFocused: Bool

    var body: some View {
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
                LazyVStack(alignment: .leading, spacing: 1) {
                    switch model.mode {
                    case .sources: SourceShelf(model: model, library: library)
                    case .quotes: QuoteShelf(model: model, library: library)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            footer
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05)))
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
                                .background(Capsule().fill(active ? Theme.accent.opacity(0.18) : Theme.ink.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("\(item.count)× verwendet")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        let shelf: CitationShelf = model.mode == .sources ? .sources : .quotes
        return HStack(spacing: 12) {
            if model.mode == .sources {
                Menu {
                    ForEach(SourceType.allCases) { type in
                        Button(type.label, systemImage: type.symbol) { model.newSource(type, in: library) }
                    }
                } label: {
                    Label("Quelle", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .help("Neue Quelle von Hand anlegen – im zuletzt geöffneten Ordner")
            }
            Menu {
                Button("Neue Gruppe", systemImage: "square.stack") {
                    let group = library.addGroup(shelf)
                    model.renamingID = group.id
                }
                let groups = library.groups(shelf)
                if !groups.isEmpty {
                    Section("Neuer Ordner in …") {
                        ForEach(groups) { group in
                            Button(group.name, systemImage: "folder.badge.plus") {
                                if let folder = library.addFolder(in: group.id) { model.renamingID = folder.id }
                            }
                        }
                    }
                }
            } label: {
                Label(model.mode == .sources ? "Ordner" : "Gruppe / Ordner", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .help("Gruppen enthalten Ordner, Ordner enthalten \(model.mode == .sources ? "Quellen" : "Wissensbausteine")")
            Spacer()
            if model.mode == .sources {
                Menu {
                    Picker("Sortieren", selection: $model.sort) {
                        ForEach(CitationStudioModel.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sortieren: \(model.sort.label)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Sources

/// Groups → folders → sources, then the unsorted ones. While searching, only what matches, all open.
private struct SourceShelf: View {
    let model: CitationStudioModel
    let library: CitationLibrary

    var body: some View {
        let visible = model.visibleSources(library)
        let searching = !model.searchText.isEmpty
        let quoteCounts = Dictionary(grouping: library.quotes, by: \.sourceID).mapValues(\.count)
        let byFolder = Dictionary(grouping: visible) { source in library.folder(source.folderID) != nil ? source.folderID : nil }
        ForEach(library.groups(.sources)) { group in
            let folders = library.folders(in: group.id)
            let count = folders.reduce(0) { $0 + (byFolder[$1.id]?.count ?? 0) }
            if !searching || count > 0 {
                CollectionRow(kind: .group(group), count: count, model: model, library: library)
                if !group.isCollapsed || searching {
                    ForEach(folders) { folder in
                        let sources = byFolder[folder.id] ?? []
                        if !searching || !sources.isEmpty {
                            CollectionRow(kind: .folder(folder), count: sources.count, model: model, library: library)
                                .padding(.leading, 14)
                            if !folder.isCollapsed || searching {
                                ForEach(sources) { source in
                                    row(source, quoteCounts: quoteCounts).padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
            }
        }
        let unsorted = byFolder[nil] ?? []
        if !unsorted.isEmpty || library.groups(.sources).isEmpty {
            if !library.groups(.sources).isEmpty {
                UnsortedHeader(count: unsorted.count, shelf: .sources, model: model, library: library)
            }
            ForEach(unsorted) { source in
                row(source, quoteCounts: quoteCounts).padding(.leading, library.groups(.sources).isEmpty ? 0 : 14)
            }
        }
        if visible.isEmpty, !library.sources.isEmpty {
            Text("Nichts gefunden")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 20)
                .frame(maxWidth: .infinity)
        }
    }

    private func row(_ source: CitationSource, quoteCounts: [UUID: Int]) -> some View {
        SourceRow(source: source, quoteCount: quoteCounts[source.id] ?? 0,
                  isSelected: model.mode == .sources && model.selectedSourceID == source.id) {
            model.mode = .sources
            model.select(source.id, in: library)
        }
        .draggable(CitationDrag.source(source.id))
        .contextMenu {
            CitationFolderMenu(shelf: .sources, current: source.folderID, library: library) { library.file(source: source.id, in: $0) }
        }
    }
}

struct SourceRow: View {
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
                        .background(Capsule().fill(Theme.ink.opacity(0.07)))
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

// MARK: - Knowledge pieces

/// "Alle", "Unsortiert", then groups → folders; choosing one filters the cards on the right.
private struct QuoteShelf: View {
    let model: CitationStudioModel
    let library: CitationLibrary

    var body: some View {
        let matching = library.search(model.searchText).quoteIDs.compactMap { library.quote($0) }
        let byFolder = Dictionary(grouping: matching) { quote in library.folder(quote.folderID) != nil ? quote.folderID : nil }
        FilterRow(title: "Alle Wissensbausteine", symbol: "square.grid.2x2", count: matching.count,
                  isSelected: model.quoteFilter == .all) { model.quoteFilter = .all }
        UnsortedHeader(count: byFolder[nil]?.count ?? 0, shelf: .quotes, model: model, library: library)
        ForEach(library.groups(.quotes)) { group in
            let folders = library.folders(in: group.id)
            CollectionRow(kind: .group(group), count: folders.reduce(0) { $0 + (byFolder[$1.id]?.count ?? 0) }, model: model, library: library)
                .padding(.top, 4)
            if !group.isCollapsed {
                ForEach(folders) { folder in
                    CollectionRow(kind: .folder(folder), count: byFolder[folder.id]?.count ?? 0, model: model, library: library)
                        .padding(.leading, 14)
                }
            }
        }
        if library.groups(.quotes).isEmpty {
            Text("Lege unten eine Gruppe und darin Ordner an, um Wissensbausteine nach Themen zu sortieren. Karten lassen sich auf Ordner ziehen.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 12)
        }
    }
}

private struct FilterRow: View {
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Unsortiert": what isn't in a folder; dropping something here takes it out of its folder.
private struct UnsortedHeader: View {
    let count: Int
    let shelf: CitationShelf
    let model: CitationStudioModel
    let library: CitationLibrary
    @State private var isTargeted = false

    var body: some View {
        FilterRow(title: "Unsortiert", symbol: "tray", count: count,
                  isSelected: shelf == .quotes && model.quoteFilter == .unsorted) {
            if shelf == .quotes { model.quoteFilter = .unsorted }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isTargeted ? Theme.accent : .clear, lineWidth: 1.5))
        .padding(.top, shelf == .sources ? 6 : 0)
        .dropDestination(for: CitationDrag.self) { items, _ in
            for item in items { item.file(in: nil, library: library) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - Group and folder rows

private struct CollectionRow: View {
    enum Kind {
        case group(CitationGroup)
        case folder(CitationFolder)
    }

    let kind: Kind
    let count: Int
    let model: CitationStudioModel
    let library: CitationLibrary
    @State private var hovering = false
    @State private var isTargeted = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var id: UUID {
        switch kind {
        case .group(let group): group.id
        case .folder(let folder): folder.id
        }
    }

    private var title: String {
        switch kind {
        case .group(let group): group.name
        case .folder(let folder): folder.name
        }
    }

    private var isCollapsed: Bool {
        switch kind {
        case .group(let group): group.isCollapsed
        case .folder(let folder): folder.isCollapsed
        }
    }

    private var shelf: CitationShelf {
        switch kind {
        case .group(let group): group.shelf
        case .folder(let folder): folder.shelf
        }
    }

    private var isSelected: Bool {
        guard case .folder(let folder) = kind else { return false }
        return folder.shelf == .quotes ? model.quoteFilter == .folder(folder.id) : model.activeSourceFolder == folder.id
    }

    var body: some View {
        HStack(spacing: 6) {
            // Folders of the knowledge shelf have nothing to unfold; they filter.
            if case .folder(let folder) = kind, folder.shelf == .quotes {
                Spacer().frame(width: 12)
            } else {
                Button(action: toggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            if model.renamingID == id {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onAppear {
                        name = title
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            } else {
                Text(title)
                    .font(.system(size: 12.5, weight: kind.isGroup ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isTargeted ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.renamingID = id }
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .modifier(FolderDrop(kind: kind, library: library, isTargeted: $isTargeted))
    }

    private var symbol: String {
        switch kind {
        case .group: isCollapsed ? "square.stack" : "square.stack.fill"
        case .folder: isSelected ? "folder.fill" : "folder"
        }
    }

    private func toggle() {
        switch kind {
        case .group(let group): library.setCollapsed(group: group.id, !group.isCollapsed)
        case .folder(let folder): library.setCollapsed(folder: folder.id, !folder.isCollapsed)
        }
    }

    private func select() {
        switch kind {
        case .group: toggle()
        case .folder(let folder):
            if folder.shelf == .quotes {
                model.quoteFilter = .folder(folder.id)
            } else {
                // A source folder opens, and new sources go into it.
                model.activeSourceFolder = folder.id
                if folder.isCollapsed { library.setCollapsed(folder: folder.id, false) }
            }
        }
    }

    private func commitName() {
        guard model.renamingID == id else { return }
        switch kind {
        case .group(let group): library.renameGroup(group.id, to: name)
        case .folder(let folder): library.renameFolder(folder.id, to: name)
        }
        model.renamingID = nil
    }

    @ViewBuilder
    private var menu: some View {
        switch kind {
        case .group(let group):
            Button("Neuer Ordner in dieser Gruppe", systemImage: "folder.badge.plus") {
                if let folder = library.addFolder(in: group.id) { model.renamingID = folder.id }
            }
            Button("Umbenennen", systemImage: "pencil") { model.renamingID = group.id }
            Divider()
            Button("Gruppe löschen", systemImage: "trash", role: .destructive) { library.deleteGroup(group.id) }
                .help("Die Ordner verschwinden; ihr Inhalt kommt nach „Unsortiert“")
        case .folder(let folder):
            Button("Umbenennen", systemImage: "pencil") { model.renamingID = folder.id }
            let others = library.groups(folder.shelf).filter { $0.id != folder.groupID }
            if !others.isEmpty {
                Menu("In Gruppe verschieben") {
                    ForEach(others) { group in
                        Button(group.name) { library.moveFolder(folder.id, to: group.id) }
                    }
                }
            }
            Divider()
            Button("Ordner löschen (Inhalt bleibt)", systemImage: "trash", role: .destructive) {
                if model.quoteFilter == .folder(folder.id) { model.quoteFilter = .all }
                if model.activeSourceFolder == folder.id { model.activeSourceFolder = nil }
                library.deleteFolder(folder.id)
            }
        }
    }
}

private extension CollectionRow.Kind {
    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// Sources and quotes dropped on a folder are filed there.
private struct FolderDrop: ViewModifier {
    let kind: CollectionRow.Kind
    let library: CitationLibrary
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if case .folder(let folder) = kind {
            content.dropDestination(for: CitationDrag.self) { items, _ in
                for item in items { item.file(in: folder.id, library: library) }
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Filing

/// What can be dragged onto a folder: a source or a quote.
enum CitationDrag: Codable, Transferable {
    case source(UUID)
    case quote(UUID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }

    @MainActor
    func file(in folderID: UUID?, library: CitationLibrary) {
        switch self {
        case .source(let id):
            if folderID == nil || library.folder(folderID)?.shelf == .sources { library.file(source: id, in: folderID) }
        case .quote(let id):
            if folderID == nil || library.folder(folderID)?.shelf == .quotes { library.file(quote: id, in: folderID) }
        }
    }
}

/// "Unsortiert" and every folder of a shelf, by group; the current one is checked.
struct CitationFolderMenu: View {
    let shelf: CitationShelf
    let current: UUID?
    let library: CitationLibrary
    let onChoose: (UUID?) -> Void

    var body: some View {
        Menu("In Ordner ablegen") {
            CitationFolderItems(shelf: shelf, current: current, library: library, onChoose: onChoose)
        }
    }
}

/// The entries of a folder menu.
struct CitationFolderItems: View {
    let shelf: CitationShelf
    let current: UUID?
    let library: CitationLibrary
    let onChoose: (UUID?) -> Void

    var body: some View {
        Group {
            Button {
                onChoose(nil)
            } label: {
                if current == nil { Label("Unsortiert", systemImage: "checkmark") } else { Text("Unsortiert") }
            }
            ForEach(library.groups(shelf)) { group in
                Section(group.name) {
                    ForEach(library.folders(in: group.id)) { folder in
                        Button {
                            onChoose(folder.id)
                        } label: {
                            if current == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                        }
                    }
                }
            }
            if library.groups(shelf).isEmpty {
                Text("Noch keine Ordner – links unten anlegen")
            }
        }
    }
}

// MARK: - The cards on the right

/// The knowledge pieces of the chosen folder (or all, or the unsorted ones) that fit the search, as cards.
struct KnowledgeView: View {
    let model: CitationStudioModel
    let library: CitationLibrary

    var body: some View {
        let ids = library.search(model.searchText).quoteIDs
        let quotes = Array(ids.compactMap { library.quote($0) }.filter { quote in
            switch model.quoteFilter {
            case .all: true
            case .unsorted: library.folder(quote.folderID) == nil
            case .folder(let id): quote.folderID == id
            }
        }.reversed())
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 4)
                if quotes.isEmpty {
                    Text(library.quotes.isEmpty ? "Noch keine Zitate. Wähle eine Quelle und füge ihr Zitate hinzu." : "Hier ist (noch) nichts – ziehe Karten aus „Alle“ auf einen Ordner links.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(quotes) { quote in
                    HStack(alignment: .top, spacing: 4) {
                        // The words stay selectable; the card is dragged by its grip.
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 18, height: 34)
                            .contentShape(Rectangle())
                            .draggable(CitationDrag.quote(quote.id))
                            .help("Auf einen Ordner links ziehen")
                        QuoteCard(quote: quote, library: library, showsSource: true) {
                            model.mode = .sources
                            model.select(quote.sourceID, in: library)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var title: String {
        let base: String
        switch model.quoteFilter {
        case .all: base = "Alle Wissensbausteine"
        case .unsorted: base = "Unsortierte Wissensbausteine"
        case .folder(let id): base = library.folderPath(id) ?? "Ordner"
        }
        return model.searchText.isEmpty ? base : "\(base) – „\(model.searchText)“"
    }
}
