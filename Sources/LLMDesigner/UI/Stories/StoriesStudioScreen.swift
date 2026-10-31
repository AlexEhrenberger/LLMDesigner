import SwiftUI

/// What Stories Studio shows.
@MainActor
@Observable
final class StoriesStudioModel {
    enum Page: Hashable {
        case overview
        case part(UUID)
        case elements(StoryElementKind)
    }

    enum PartTab: Hashable {
        case content, timeline, gallery
    }

    var worldID: UUID?
    var page: Page = .overview
    var partTab: PartTab = .content
    /// The element each kind's list has selected.
    var selected: [StoryElementKind: UUID] = [:]
    var searchText: [StoryElementKind: String] = [:]
    /// The tags the list of facts is filtered by: a fact must have all of them.
    var factTagFilter: [String] = []
    /// Parts open in the navigator.
    var expanded: Set<UUID> = []
    /// A new part or element whose name field should take the keyboard.
    var focusNameOf: UUID?
    /// A timeline entry to select when its timeline shows.
    var selectedEntryID: UUID?
    /// The tab figure pages open with: the last one chosen.
    var figureTab: StoryFigurePage.Tab = .life

    func world(in library: StoryLibrary) -> StoryWorld? {
        worldID.flatMap { library.world($0) }
    }

    func open(_ worldID: UUID) {
        guard worldID != self.worldID else { return }
        self.worldID = worldID
        page = .overview
        partTab = .content
        selected = [:]
        searchText = [:]
        factTagFilter = []
        expanded = []
        selectedEntryID = nil
    }

    func show(_ ref: StoryRef) {
        page = .elements(ref.kind)
        selected[ref.kind] = ref.id
    }

    func showPart(_ id: UUID, in world: StoryWorld, tab: PartTab = .content) {
        for part in world.path(to: id).dropLast() { expanded.insert(part.id) }
        page = .part(id)
        partTab = tab
    }

    func isSelected(_ ref: StoryRef) -> Bool {
        page == .elements(ref.kind) && selected[ref.kind] == ref.id
    }
}

/// Stories Studio: novel worlds with their books, acts, chapters and sections; the figures, places, events,
/// reasons and purposes they link; and a timeline for the world and each book, act and chapter.
struct StoriesStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = StoriesStudioModel()

    private static let lastWorldKey = "storiesLastWorld"

    var body: some View {
        let library = app.stories
        VStack(spacing: 0) {
            StoriesTopBar(model: model, library: library)
            if let world = model.world(in: library) {
                HStack(spacing: 0) {
                    StoryNavigator(world: world, model: model, library: library)
                        .frame(width: 236)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    StoryPageHost(world: world, model: model, library: library)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyState(library)
            }
        }
        .background(Theme.background)
        .onAppear {
            library.loadIfNeeded()
            let last = app.settings.string(forKey: Self.lastWorldKey).flatMap(UUID.init(uuidString:))
            if let id = last.flatMap({ library.world($0)?.id }) ?? library.worlds.first?.id { model.open(id) }
        }
        .onChange(of: model.worldID) { _, id in app.settings.set(id?.uuidString, forKey: Self.lastWorldKey) }
    }

    private func emptyState(_ library: StoryLibrary) -> some View {
        VStack(spacing: 14) {
            Image(systemName: StudioApplication.stories.symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Noch keine Romanwelt")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Eine Romanwelt hält deine Bücher – Hauptromane, Nebenromane, fiktionale Historienbücher – mit ihren Akten,\nKapiteln und Abschnitten, und die Figuren, Orte, Events, Reasons und Purposes, die sie verbinden.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                let world = library.addWorld()
                model.open(world.id)
                model.focusNameOf = world.id
            } label: {
                Label("Romanwelt anlegen", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The page on the right. It is the only part that reads which page is open, so opening another page doesn't make
/// the rest of the studio (navigator, top bar) build itself again.
private struct StoryPageHost: View {
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        switch model.page {
        case .overview:
            StoryWorldPage(world: world, model: model, library: library)
        case .part(let id):
            if world.part(id) != nil {
                StoryPartPage(partID: id, world: world, model: model, library: library)
                    .id(id)
            } else {
                StoryWorldPage(world: world, model: model, library: library)
            }
        case .elements(let kind):
            StoryElementBrowser(kind: kind, world: world, model: model, library: library)
                .id(kind)
        }
    }
}

// MARK: - Top bar

private struct StoriesTopBar: View {
    @Environment(AppModel.self) private var app
    let model: StoriesStudioModel
    let library: StoryLibrary
    @State private var confirmsDelete = false
    @State private var width: CGFloat = 1200

    var body: some View {
        let world = model.world(in: library)
        HStack(spacing: 10) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                    .padding(.trailing, 4)
            }
            Image(systemName: StudioApplication.stories.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Stories Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if !library.worlds.isEmpty {
                worldMenu(world)
            }
            if let world, width >= 980 {
                Text(counts(world))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 16)
            IconButton(systemName: "xmark", help: "Stories Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { app.closeStoriesStudio() }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.bottom, Theme.topBarBottomPadding + 4)
        .background(WindowDragArea())
        .confirmationDialog("„\(world?.displayTitle ?? "")“ löschen?", isPresented: $confirmsDelete) {
            Button("Romanwelt löschen", role: .destructive) {
                guard let id = world?.id else { return }
                library.deleteWorld(id)
                model.worldID = nil
                if let next = library.worlds.first { model.open(next.id) }
            }
        } message: {
            Text("Die Romanwelt kommt mit allen Büchern, Elementen und Bildern in den Papierkorb.")
        }
    }

    private func worldMenu(_ world: StoryWorld?) -> some View {
        Menu {
            Section("Romanwelten") {
                ForEach(library.worlds) { other in
                    Button {
                        model.open(other.id)
                    } label: {
                        if other.id == world?.id {
                            Label(other.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(other.displayTitle)
                        }
                    }
                }
            }
            Divider()
            Button("Neue Romanwelt", systemImage: "plus") {
                let new = library.addWorld()
                model.open(new.id)
                model.focusNameOf = new.id
            }
            if world != nil {
                Button("Romanwelt löschen …", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe.europe.africa")
                    .font(.system(size: 11))
                Text(world?.displayTitle ?? "Romanwelt wählen")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Romanwelt wechseln oder neu anlegen")
    }

    private func counts(_ world: StoryWorld) -> String {
        var parts = ["\(world.books.count) \(world.books.count == 1 ? "Buch" : "Bücher")", "\(world.chapterCount) Kapitel"]
        parts.append("\(world.figures.count) \(world.figures.count == 1 ? "Figur" : "Figuren")")
        parts.append("\(world.events.count) Events")
        return parts.joined(separator: " · ")
    }
}
