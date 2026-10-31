import SwiftUI

/// A page with "Inhalt | Timeline | Galerie" in its head (as far as the page has them).
private struct StoryPageHead<Leading: View>: View {
    let model: StoriesStudioModel
    let tabs: [StoriesStudioModel.PartTab]
    @ViewBuilder let leading: () -> Leading
    @State private var width: CGFloat = .infinity
    @State private var leadingWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            leading()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
            Spacer(minLength: 12)
            if tabs.count > 1 {
                StoryTabBar(tabs: tabs.map { tab in
                    switch tab {
                    case .content: (tab, "Inhalt", "text.alignleft")
                    case .timeline: (tab, "Timeline", "calendar.day.timeline.left")
                    case .gallery: (tab, "Galerie", "photo.on.rectangle.angled")
                    }
                }, selection: Binding(get: { tabs.contains(model.partTab) ? model.partTab : .content }, set: { model.partTab = $0 }),
                   room: width - 48 - leadingWidth - 32)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - World

/// The world itself: what it is about, how it works, its calendar, its books; and its timeline.
struct StoryWorldPage: View {
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        VStack(spacing: 0) {
            StoryPageHead(model: model, tabs: [.content, .timeline, .gallery]) {
                Label("Romanwelt", systemImage: "globe.europe.africa")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            switch model.partTab {
            case .content: content
            case .timeline:
                StoryTimelineView(owner: .world, world: world, model: model, library: library)
                    .id(TimelineOwner.world)
            case .gallery:
                StoryGalleryView(title: "Galerie der Romanwelt", worldID: world.id, images: world.gallery, library: library) { image in
                    library.draftBinding(world.id, field: ["gallery", image.fileName], fallback: "",
                                         get: { $0.gallery.first { $0.fileName == image.fileName }?.caption },
                                         set: { world, text in
                                             if let index = world.gallery.firstIndex(where: { $0.fileName == image.fileName }) { world.gallery[index].caption = text }
                                         })
                } onChange: { images in
                    library.update(world.id) { $0.gallery = images }
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StoryTextEditor(placeholder: "Name der Romanwelt", text: library.binding(world.id, \.title),
                                font: .systemFont(ofSize: 24, weight: .semibold), singleLine: true, focusOnAppear: model.focusNameOf == world.id)
                StoryTextEditor(placeholder: "Genre – z. B. High Fantasy, Familiensaga, Space Opera", text: library.binding(world.id, \.genre),
                                font: .systemFont(ofSize: 14), color: NSColor(Theme.textSecondary), singleLine: true)
                StoryTextArea(title: "Prämisse", hint: "Worum es im Kern geht, in ein, zwei Sätzen: wer will was, was steht dagegen, was steht auf dem Spiel.",
                              placeholder: "In einer Welt, in der …", text: library.binding(world.id, \.logline), lines: 2...5)
                StoryTextArea(title: "Beschreibung der Welt", placeholder: "Wie sieht die Welt aus, wer lebt dort, was prägt sie?",
                              text: library.binding(world.id, \.overview), lines: 3...16)
                StoryTextArea(title: "Regeln der Welt", hint: "Was in dieser Welt möglich ist und was nicht: Magie, Glaube, Macht, Technik – und ihr Preis.",
                              placeholder: "Magie kostet …, niemand kann …", text: library.binding(world.id, \.rules), lines: 3...16)
                StoryTextArea(title: "Themen & Motive", placeholder: "Macht und ihre Kosten, Familie, Ehre gegen Überleben …",
                              text: library.binding(world.id, \.themes), lines: 2...8)
                calendar
                books
                stats
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if model.focusNameOf == world.id { model.focusNameOf = nil }
        }
    }

    private var calendar: some View {
        StoryCard {
            StoryLabel(title: "Kalender der Welt", hint: "Wie die Timelines zählen. Bücher, Akte und Kapitel übernehmen ihn, solange sie keinen eigenen haben.",
                       symbol: "calendar", color: Theme.accent)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Einheit").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    StoryTextEditor(placeholder: "Jahr", text: library.binding(world.id, \.calendar.unit), singleLine: true).storyField()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zusatz hinter der Zahl").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    StoryTextEditor(placeholder: "n. A. E.", text: library.binding(world.id, \.calendar.suffix), singleLine: true).storyField()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("So sieht es aus").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text(world.calendar.describe(start: 283, end: 298))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(height: 30)
                }
            }
        }
    }

    private var books: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StorySectionTitle(title: "Bücher", symbol: "books.vertical")
                Spacer()
                Menu {
                    ForEach(BookKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) {
                            var added: StoryPart?
                            library.update(world.id) { world in
                                added = world.addPart(.book, under: nil)
                                if let id = added?.id { world.updatePart(id) { $0.bookKind = kind } }
                            }
                            if let added {
                                model.showPart(added.id, in: world)
                                model.focusNameOf = added.id
                            }
                        }
                    }
                } label: {
                    Label("Neues Buch", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            StoryChildList(parts: world.books, world: world, model: model)
        }
    }

    private var stats: some View {
        let parts = world.allParts.map(\.part)
        let counts: [(String, Int)] = [
            ("Bücher", world.books.count),
            ("Akte", parts.filter { $0.level == .act }.count),
            ("Kapitel", parts.filter { $0.level == .chapter }.count),
            ("Abschnitte", parts.filter { $0.level == .section }.count),
        ] + StoryElementKind.listOrder.map { ($0.title, world.count(of: $0)) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), alignment: .leading, spacing: 10) {
            ForEach(counts, id: \.0) { title, count in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count)")
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Part

/// A book, act, chapter or section: its five questions, its notes, what lies within it; and its timeline.
struct StoryPartPage: View {
    let partID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        if let part = world.part(partID) {
            VStack(spacing: 0) {
                StoryPageHead(model: model, tabs: tabs(part)) {
                    breadcrumb(part)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                if model.partTab == .timeline, part.level.hasTimeline {
                    StoryTimelineView(owner: .part(partID), world: world, model: model, library: library)
                        .id(TimelineOwner.part(partID))
                } else if model.partTab == .gallery, part.level == .book {
                    StoryGalleryView(title: "Galerie zu „\(world.displayTitle(of: part))“", worldID: world.id, images: part.gallery, library: library) { image in
                        library.draftBinding(world.id, field: [AnyHashable(partID), AnyHashable("gallery"), AnyHashable(image.fileName)], fallback: "",
                                             get: { [partID] in $0.part(partID)?.gallery.first { $0.fileName == image.fileName }?.caption },
                                             set: { [partID] world, text in
                                                 world.updatePart(partID) { part in
                                                     if let index = part.gallery.firstIndex(where: { $0.fileName == image.fileName }) { part.gallery[index].caption = text }
                                                 }
                                             })
                    } onChange: { images in
                        library.update(world.id) { $0.updatePart(partID) { $0.gallery = images } }
                    }
                } else {
                    content(part)
                }
            }
        }
    }

    private func tabs(_ part: StoryPart) -> [StoriesStudioModel.PartTab] {
        switch part.level {
        case .book: [.content, .timeline, .gallery]
        case .act, .chapter: [.content, .timeline]
        case .section: []
        }
    }

    private func breadcrumb(_ part: StoryPart) -> some View {
        let path = world.path(to: partID)
        return HStack(spacing: 5) {
            Button(world.displayTitle) { model.page = .overview }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            ForEach(path) { step in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                Button(world.displayTitle(of: step)) { model.page = .part(step.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(step.id == partID ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
    }

    private func content(_ part: StoryPart) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(part)
                StoryTextEditor(placeholder: world.number(of: partID), text: library.partBinding(world.id, partID, \.title),
                                font: .systemFont(ofSize: 24, weight: .semibold), singleLine: true, focusOnAppear: model.focusNameOf == partID)
                if part.level == .book {
                    StoryTextEditor(placeholder: "Untertitel", text: library.partBinding(world.id, partID, \.subtitle),
                                    font: .systemFont(ofSize: 14), color: NSColor(Theme.textSecondary), singleLine: true)
                }
                if part.level.hasPointOfView {
                    pointOfView(part)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(StoryElementKind.questions) { kind in
                        StoryFocusCard(kind: kind, part: part, world: world, model: model, library: library)
                    }
                }
                StoryTextArea(title: "Notizen", placeholder: "Was sonst noch dazugehört – Ideen, offene Fragen, Recherche …",
                              text: library.partBinding(world.id, partID, \.notes), lines: 3...20)
                if let child = part.level.child {
                    children(part, level: child)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if model.focusNameOf == partID { model.focusNameOf = nil }
        }
    }

    private func header(_ part: StoryPart) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FlowLayout(spacing: 10, lineSpacing: 6) { headerControls(part) }
            Spacer(minLength: 0)
            StoryDeleteButton(title: "„\(world.displayTitle(of: part))“ löschen?",
                              message: part.children.isEmpty ? "Die verknüpften Elemente bleiben erhalten." : "Mit allem, was darin liegt. Die verknüpften Elemente bleiben erhalten.") {
                model.page = world.parentID(of: partID).map { .part($0) } ?? .overview
                library.removePart(partID, in: world.id)
            }
        }
    }

    @ViewBuilder
    private func headerControls(_ part: StoryPart) -> some View {
            Label(world.number(of: partID), systemImage: part.level.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Theme.accent.opacity(0.13)))
            if part.level == .book {
                Menu {
                    ForEach(BookKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { library.update(world.id) { $0.updatePart(partID) { $0.bookKind = kind } } }
                    }
                } label: {
                    Label(part.bookKind.label, systemImage: part.bookKind.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Art des Buches")
            }
            Menu {
                ForEach(DraftStatus.allCases) { status in
                    Button(status.label, systemImage: status.symbol) { library.update(world.id) { $0.updatePart(partID) { $0.status = status } } }
                }
            } label: {
                Label(part.status.label, systemImage: part.status.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(part.status == .done ? Theme.success : Theme.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Stand der Arbeit")
    }

    private func pointOfView(_ part: StoryPart) -> some View {
        HStack(spacing: 8) {
            StoryLabel(title: "Erzählperspektive", hint: "Durch wessen Augen die Leser:innen diesen Teil erleben.", symbol: "eye", color: StoryElementKind.figure.color)
            if let id = part.povFigureID, let figure = world.element(StoryFigure.self, id) {
                StoryElementChip(kind: .figure, name: figure.displayName, onOpen: { model.show(figure.ref) }) {
                    library.update(world.id) { $0.updatePart(partID) { $0.povFigureID = nil } }
                }
            } else {
                StoryElementPickerButton(kinds: [.figure], world: world, library: library, label: "Figur wählen") { ref in
                    library.update(world.id) { $0.updatePart(partID) { $0.povFigureID = ref.id } }
                }
            }
        }
    }

    private func children(_ part: StoryPart, level: StoryPartLevel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StorySectionTitle(title: "\(level.plural) in diesem \(part.level == .act ? "Akt" : part.level.label)", symbol: level.symbol)
                Spacer()
                Button {
                    var added: StoryPart?
                    library.update(world.id) { added = $0.addPart(level, under: partID) }
                    if let added {
                        model.expanded.insert(partID)
                        model.page = .part(added.id)
                        model.focusNameOf = added.id
                    }
                } label: {
                    Label("\(level.label) hinzufügen", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            StoryChildList(parts: part.children, world: world, model: model)
        }
    }
}

/// The parts within a part, with what happens in each.
private struct StoryChildList: View {
    let parts: [StoryPart]
    let world: StoryWorld
    let model: StoriesStudioModel

    var body: some View {
        if parts.isEmpty {
            Text("Noch leer.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        VStack(spacing: 4) {
            ForEach(parts) { part in
                Button {
                    model.showPart(part.id, in: world)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: part.level == .book ? part.bookKind.symbol : part.level.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(world.displayTitle(of: part))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if !part.title.isEmpty {
                                    Text(world.number(of: part.id))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                if part.level == .book {
                                    Text(part.bookKind.label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            let what = part.focus.text(.event)
                            if !what.isEmpty {
                                Text(what)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(part.status.label)
                            .font(.system(size: 11))
                            .foregroundStyle(part.status == .done ? Theme.success : Theme.textTertiary)
                        if let child = part.level.child, !part.children.isEmpty {
                            Text("\(part.children.count) \(part.children.count == 1 ? child.label : child.plural)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One of the five questions of a part: a few words and the linked elements.
private struct StoryFocusCard: View {
    let kind: StoryElementKind
    let part: StoryPart
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        StoryCard(tint: kind.color) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color)
                Text(kind.question.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(kind.color)
                Text(kind.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            StoryTextEditor(placeholder: kind.prompt, text: library.draftBinding(
                world.id, field: [AnyHashable(part.id), AnyHashable(kind)], fallback: "",
                get: { $0.part(part.id)?.focus.text(kind) },
                set: { world, text in world.updatePart(part.id) { $0.focus.setText(text, for: kind) } }
            ))
            StoryLinkList(kind: kind, ids: part.focus.ids(kind), world: world, library: library, model: model,
                          addLabel: "\(kind.singular) verknüpfen") { ids in
                library.update(world.id) { $0.updatePart(part.id) { $0.focus.links[kind] = ids.isEmpty ? nil : ids } }
            }
        }
    }
}
