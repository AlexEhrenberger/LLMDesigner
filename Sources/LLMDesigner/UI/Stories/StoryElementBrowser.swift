import SwiftUI

/// One kind of element: the list on the left, the selected element's page on the right.
struct StoryElementBrowser: View {
    let kind: StoryElementKind
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        HStack(spacing: 0) {
            StoryElementList(kind: kind, world: world, model: model, library: library)
                .frame(width: 232)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if let id = model.selected[kind], world.exists(StoryRef(kind: kind, id: id)) {
                    detail(id)
                        .id(id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detail(_ id: UUID) -> some View {
        switch kind {
        case .figure: StoryFigurePage(figureID: id, world: world, model: model, library: library)
        case .place: StoryPlacePage(placeID: id, world: world, model: model, library: library)
        case .event: StoryEventPage(eventID: id, world: world, model: model, library: library)
        case .reason: StoryReasonPage(reasonID: id, world: world, model: model, library: library)
        case .purpose: StoryPurposePage(purposeID: id, world: world, model: model, library: library)
        case .species: StorySpeciesPage(speciesID: id, world: world, model: model, library: library)
        case .fact: StoryFactPage(factID: id, world: world, model: model, library: library)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(kind.color)
            Text(world.count(of: kind) == 0 ? "Noch keine \(kind.title)" : "Nichts ausgewählt")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(Self.explanation(kind))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    static func explanation(_ kind: StoryElementKind) -> String {
        switch kind {
        case .figure: "Figuren bekommen einen Lebenslauf, ein psychologisches Profil, ihre Haltung zu anderen Figuren, Events und Orten – und ein Szenenbuch."
        case .place: "Orte liegen ineinander (Kontinent › Reich › Stadt) und haben Atmosphäre, Geschichte, Bewohner und eine Bedeutung für die Geschichte."
        case .event: "Events sind das, was passiert – etwa der Sturz des Königs. Wichtig sind ihre Ursachen und Auswirkungen, und welche Events daraus folgen."
        case .reason: "Reasons erklären, warum etwas geschieht: Annahmen und Prämissen führen zu einer Konklusion – oft zu der einer Figur, die sich irrt."
        case .purpose: "Purposes halten fest, wozu etwas in der Geschichte dient – Vorausdeutung, Spannungsaufbau, falsche Fährte – und wo es vorbereitet und eingelöst wird."
        case .species: "Spezies beschreiben die Wesen, die in der Welt leben – Völker, Bestien, magische Geschöpfe: Gestalt, Fähigkeiten, Lebensraum, Kultur. Figuren können einer Spezies angehören."
        case .fact: "Fakten sind einfache Notizen zur Welt – historische Fakten, Gesetze, Daten, Details. Sie bekommen Schlagworte und Bilder, lassen sich durchsuchen und über das Menü „Schlagworte“ filtern – auch nach mehreren zugleich."
        }
    }
}

/// The elements of one kind, searchable; places nested by where they lie.
private struct StoryElementList: View {
    let kind: StoryElementKind
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    @State private var deleting: UUID?

    private var query: Binding<String> {
        Binding(get: { model.searchText[kind] ?? "" }, set: { model.searchText[kind] = $0 })
    }

    private struct Item: Identifiable {
        let id: UUID
        let name: String
        let subtitle: String
        let image: StoryImage?
        let depth: Int
    }

    private var items: [Item] {
        let words = query.wrappedValue.lowercased().split(separator: " ").map(String.init)
        func fits(_ text: String) -> Bool { words.allSatisfy { text.lowercased().contains($0) } }
        switch kind {
        case .species:
            return world.species
                .filter { fits($0.name + " " + $0.speciesKind.label) }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .map { Item(id: $0.id, name: $0.displayName, subtitle: $0.subtitle, image: $0.images.first, depth: 0) }
        case .fact:
            // Newest first: facts are collected as they come up.
            let query = query.wrappedValue
            let tags = model.factTagFilter
            return world.facts
                .filter { fact in fact.matches(query) && tags.allSatisfy(fact.hasTag) }
                .sorted { $0.createdAt > $1.createdAt }
                .map { Item(id: $0.id, name: $0.displayName, subtitle: $0.subtitle, image: $0.images.first, depth: 0) }
        case .figure:
            return world.figures
                .filter { fits($0.name + " " + $0.epithet + " " + $0.role.label + " " + ($0.speciesID.flatMap { world.element(StorySpecies.self, $0)?.name } ?? "")) }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .map { Item(id: $0.id, name: $0.displayName, subtitle: $0.subtitle, image: $0.images.first, depth: 0) }
        case .place:
            guard words.isEmpty else {
                return world.places.filter { fits($0.name + " " + $0.placeKind.label) }
                    .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                    .map { Item(id: $0.id, name: $0.displayName, subtitle: world.placePath($0.id), image: $0.images.first, depth: 0) }
            }
            // Places as a tree: each place under the one it lies in.
            var result: [Item] = []
            var seen = Set<UUID>()
            func walk(_ parent: UUID?, depth: Int) {
                let level = world.places.filter { place in
                    parent == nil ? (place.parentID == nil || world.element(StoryPlace.self, place.parentID!) == nil) : place.parentID == parent
                }
                for place in level.sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
                where seen.insert(place.id).inserted {
                    result.append(Item(id: place.id, name: place.displayName, subtitle: place.subtitle, image: place.images.first, depth: depth))
                    walk(place.id, depth: depth + 1)
                }
            }
            walk(nil, depth: 0)
            // Places caught in a loop of parents still show.
            for place in world.places where !seen.contains(place.id) {
                result.append(Item(id: place.id, name: place.displayName, subtitle: place.subtitle, image: place.images.first, depth: 0))
            }
            return result
        default:
            return world.summaries(of: kind)
                .filter { fits($0.name + " " + $0.subtitle) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Item(id: $0.id, name: $0.name, subtitle: $0.subtitle, image: nil, depth: 0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kind.color)
                Text(kind.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.question)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                IconButton(systemName: "plus", help: "Neue:n \(kind.singular) anlegen", size: 12.5, frameSize: 26) { add() }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("\(kind.title) durchsuchen", text: query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if kind == .fact {
                tagFilter
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .confirmationDialog("„\(deleting.flatMap { world.name(of: StoryRef(kind: kind, id: $0)) } ?? "")“ löschen?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Löschen", role: .destructive) {
                if let id = deleting { remove(id) }
                deleting = nil
            }
        } message: {
            Text("Alle Verknüpfungen in Büchern, Timelines und anderen Elementen werden gelöst.")
        }
    }

    /// The facts' tags as a dropdown with checkboxes; a fact must have every tag ticked.
    @ViewBuilder
    private var tagFilter: some View {
        let tags = world.factTags
        if !tags.isEmpty {
            HStack(spacing: 6) {
                StoryTagMenuButton(title: "Schlagworte", tags: tags, selected: model.factTagFilter, color: kind.color) { tag in
                    if let index = model.factTagFilter.firstIndex(where: { StoryFact.sameTag($0, tag) }) {
                        model.factTagFilter.remove(at: index)
                    } else {
                        model.factTagFilter.append(tag)
                    }
                } onClear: {
                    model.factTagFilter = []
                }
                if !model.factTagFilter.isEmpty {
                    Button {
                        model.factTagFilter = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter aufheben")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func row(_ item: Item) -> some View {
        Button {
            model.selected[kind] = item.id
        } label: {
            HStack(spacing: 9) {
                if kind.hasPictures, kind != .fact || item.image != nil {
                    StoryAvatar(kind: kind, image: item.image, worldID: world.id, library: library, size: 28)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(kind.color)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + CGFloat(item.depth) * 14)
            .padding(.trailing, 8)
            .frame(height: kind.hasPictures && kind != .fact ? 40 : 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(StoryRowButtonStyle(selected: model.selected[kind] == item.id))
        .contextMenu {
            Button("\(kind.singular) löschen …", systemImage: "trash", role: .destructive) { deleting = item.id }
        }
    }

    private func add() {
        let ref = library.addElement(kind, in: world.id)
        model.searchText[kind] = nil
        model.selected[kind] = ref.id
        model.focusNameOf = ref.id
    }

    private func remove(_ id: UUID) {
        if model.selected[kind] == id { model.selected[kind] = nil }
        library.removeElement(StoryRef(kind: kind, id: id), in: world.id)
    }
}

/// The head of an element's page: kind, name, and what goes beside it.
struct StoryElementHeader<Accessory: View>: View {
    let ref: StoryRef
    @Binding var name: String
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    var placeholder: String?
    @ViewBuilder let accessory: () -> Accessory
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                FlowLayout(spacing: 10, lineSpacing: 6) {
                    Label(ref.kind.singular, systemImage: ref.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ref.kind.color)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(ref.kind.color.opacity(0.13)))
                    accessory()
                }
                Spacer(minLength: 0)
                StoryDeleteButton(title: "„\(world.name(of: ref) ?? "")“ löschen?",
                                  message: "Alle Verknüpfungen in Büchern, Timelines und anderen Elementen werden gelöst.") {
                    model.selected[ref.kind] = nil
                    library.removeElement(ref, in: world.id)
                }
            }
            TextField(placeholder ?? "Name", text: $name, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .focused($focused)
        }
        .onAppear {
            if model.focusNameOf == ref.id {
                model.focusNameOf = nil
                DispatchQueue.main.async { focused = true }
            }
        }
    }
}

/// A scrolling page column of the usual width.
struct StoryPageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A menu button in a page's head (kind of place, kind of event …).
struct StoryHeaderMenu<Items: View>: View {
    let title: String
    var symbol: String?
    var help = ""
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
