import SwiftUI

/// The left column: the world's overview, its books as a tree down to the sections, and the five kinds of elements.
struct StoryNavigator: View {
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    @State private var deleting: StoryPart?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(title: "Weltübersicht", symbol: "globe.europe.africa", color: Theme.accent, selected: model.page == .overview) {
                    model.page = .overview
                }
                header("Werk") {
                    Menu {
                        ForEach(BookKind.allCases) { kind in
                            Button(kind.label, systemImage: kind.symbol) { addBook(kind) }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Neues Buch")
                }
                if world.books.isEmpty {
                    Text("Noch keine Bücher. Lege mit + einen Hauptroman, Nebenroman oder ein Historienbuch an.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                ForEach(world.books) { book in
                    StoryPartTreeRow(part: book, depth: 0, world: world, model: model, library: library) { deleting = $0 }
                }
                header("Elemente") { EmptyView() }
                ForEach(StoryElementKind.listOrder) { kind in
                    row(title: kind.title, symbol: kind.symbol, color: kind.color, selected: model.page == .elements(kind),
                        trailing: "\(world.count(of: kind))", hint: kind.question) {
                        model.page = .elements(kind)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(Theme.sidebar.opacity(0.5))
        .confirmationDialog("„\(deleting.map { world.displayTitle(of: $0) } ?? "")“ löschen?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                guard let part = deleting else { return }
                if case .part(let id) = model.page, world.path(to: id).contains(where: { $0.id == part.id }) {
                    model.page = world.parentID(of: part.id).map { .part($0) } ?? .overview
                }
                library.update(world.id) { $0.removePart(part.id) }
                deleting = nil
            }
        } message: {
            if let part = deleting {
                let below = countBelow(part)
                Text(below == 0 ? "Die verknüpften Elemente bleiben erhalten." : "Mit allem darin (\(below) Teile). Die verknüpften Elemente bleiben erhalten.")
            }
        }
    }

    private func countBelow(_ part: StoryPart) -> Int {
        part.children.reduce(part.children.count) { $0 + countBelow($1) }
    }

    private func addBook(_ kind: BookKind) {
        var added: StoryPart?
        library.update(world.id) { world in
            added = world.addPart(.book, under: nil)
            if let id = added?.id { world.updatePart(id) { $0.bookKind = kind } }
        }
        guard let added else { return }
        model.showPart(added.id, in: world)
        model.focusNameOf = added.id
    }

    private func header<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func row(title: String, symbol: String, color: Color, selected: Bool, trailing: String? = nil, hint: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(StoryRowButtonStyle(selected: selected))
    }
}

/// A book, act, chapter or section in the navigator, with its children when open.
struct StoryPartTreeRow: View {
    let part: StoryPart
    let depth: Int
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    let onDelete: (StoryPart) -> Void

    private var isExpanded: Bool { model.expanded.contains(part.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                model.page = .part(part.id)
            } label: {
                HStack(spacing: 6) {
                    disclosure
                    Image(systemName: part.level == .book ? part.bookKind.symbol : part.level.symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(part.level == .book ? Theme.accent : Theme.textSecondary)
                        .frame(width: 15)
                    if part.level != .book, !part.title.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(world.shortNumber(of: part.id))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(world.displayTitle(of: part))
                        .font(.system(size: part.level == .book ? 13 : 12.5, weight: part.level == .book ? .medium : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if part.status != .idea {
                        Image(systemName: part.status.symbol)
                            .font(.system(size: 9.5))
                            .foregroundStyle(part.status == .done ? Theme.success : Theme.textTertiary)
                            .help(part.status.label)
                    }
                }
                .padding(.leading, 4 + CGFloat(depth) * 14)
                .padding(.trailing, 8)
                .frame(height: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(StoryRowButtonStyle(selected: model.page == .part(part.id)))
            .contextMenu { menu }
            if isExpanded {
                ForEach(part.children) { child in
                    StoryPartTreeRow(part: child, depth: depth + 1, world: world, model: model, library: library, onDelete: onDelete)
                }
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if part.level.child != nil {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded { model.expanded.remove(part.id) } else { model.expanded.insert(part.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(part.children.isEmpty ? Theme.textTertiary.opacity(0.4) : Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 14, height: 20)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let child = part.level.child {
            Button("\(child.label) hinzufügen", systemImage: "plus") { addChild(child) }
        }
        Button("Nach oben", systemImage: "arrow.up") { library.update(world.id) { $0.movePart(part.id, by: -1) } }
            .disabled(!world.canMovePart(part.id, by: -1))
        Button("Nach unten", systemImage: "arrow.down") { library.update(world.id) { $0.movePart(part.id, by: 1) } }
            .disabled(!world.canMovePart(part.id, by: 1))
        if part.level.hasTimeline {
            Button("Timeline zeigen", systemImage: "calendar.day.timeline.left") { model.showPart(part.id, in: world, tab: .timeline) }
        }
        Divider()
        Button("\(part.level.label) löschen …", systemImage: "trash", role: .destructive) { onDelete(part) }
    }

    private func addChild(_ level: StoryPartLevel) {
        var added: StoryPart?
        library.update(world.id) { added = $0.addPart(level, under: part.id) }
        guard let added else { return }
        model.expanded.insert(part.id)
        model.showPart(added.id, in: world)
        model.focusNameOf = added.id
    }
}
