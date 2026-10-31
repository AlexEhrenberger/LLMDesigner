import SwiftUI

// MARK: - Species

/// A species: what the beings look like and can do, how and where they live, their culture, and who belongs to it.
struct StorySpeciesPage: View {
    let speciesID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StorySpecies, T>) -> Binding<T> {
        library.binding(world.id, StorySpecies.self, speciesID, keyPath)
    }

    private func update(_ change: (inout StorySpecies) -> Void) {
        library.updateElement(world.id, StorySpecies.self, speciesID, change)
    }

    var body: some View {
        if let species = world.element(StorySpecies.self, speciesID) {
            StoryPageScroll {
                StoryElementHeader(ref: species.ref, name: field(\.name), world: world, model: model, library: library,
                                   placeholder: "Name der Spezies – „Drachen“, „Elben“, „Weiße Wanderer“") {
                    StoryHeaderMenu(title: species.speciesKind.label, symbol: species.speciesKind.symbol, help: "Art der Wesen") {
                        ForEach(SpeciesKind.allCases) { kind in
                            Button(kind.label, systemImage: kind.symbol) { update { $0.speciesKind = kind } }
                        }
                    }
                }
                StoryImageGallery(worldID: world.id, images: species.images, library: library) { images in
                    update { $0.images = images }
                }
                StoryTextArea(title: "Gestalt & Erscheinung", placeholder: "Körperbau, Größe, Haut, Fell oder Schuppen, wie sie sich bewegen und klingen",
                              text: field(\.appearance), lines: 3...14)
                HStack(alignment: .top, spacing: 14) {
                    StoryTextArea(title: "Fähigkeiten", hint: "Was diese Wesen können – auch das, was andere fürchten oder begehren.",
                                  text: field(\.abilities), lines: 3...12)
                    StoryTextArea(title: "Schwächen", hint: "Woran sie leiden, was sie verwundbar macht – oft der Schlüssel für die Handlung.",
                                  text: field(\.weaknesses), lines: 3...12)
                }
                StoryTextArea(title: "Lebensweise & Lebenszyklus", placeholder: "Wie lange sie leben, wie sie geboren werden und aufwachsen, was sie fressen",
                              text: field(\.lifeCycle), lines: 2...12)
                VStack(alignment: .leading, spacing: 8) {
                    StoryTextArea(title: "Lebensraum", placeholder: "Wo sie leben und warum dort", text: field(\.habitat), lines: 2...10)
                    StoryLinkList(kind: .place, ids: species.habitatPlaceIDs, world: world, library: library, model: model, addLabel: "Ort verknüpfen") { ids in
                        update { $0.habitatPlaceIDs = ids }
                    }
                }
                StoryTextArea(title: "Kultur & Gesellschaft", hint: "Sprache, Bräuche, Herrschaft, Glaube – soweit diese Wesen so etwas haben.",
                              text: field(\.culture), lines: 2...14)
                StoryTextArea(title: "Verhältnis zu anderen Wesen", placeholder: "Wer sie fürchtet, jagt, verehrt oder mit ihnen handelt",
                              text: field(\.relations), lines: 2...12)
                StoryTextArea(title: "Herkunft & Geschichte", text: field(\.history), lines: 2...14)
                StoryTextArea(title: "Bedeutung für die Geschichte", hint: "Wofür die Spezies steht und was sie der Handlung gibt – Bedrohung, Spiegel, Versprechen.",
                              text: field(\.significance), lines: 2...12)
                StoryTextArea(title: "Geheimnisse", text: field(\.secrets), lines: 2...10)
                members
                StoryRelatedFacts(ref: species.ref, world: world, model: model)
                StoryUsageList(ref: species.ref, world: world, model: model)
                StoryTextArea(title: "Notizen", text: field(\.notes), lines: 2...16)
            }
        }
    }

    /// The figures of this species; adding one here sets its species.
    private var members: some View {
        let members = world.figures(ofSpecies: speciesID)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 6) {
            StoryLabel(title: "Figuren dieser Spezies", hint: "Eine Figur gehört zu höchstens einer Spezies. Wer hier hinzugefügt wird, verlässt eine andere.",
                       symbol: StoryElementKind.figure.symbol, color: StoryElementKind.figure.color)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(members) { figure in
                    StoryElementChip(kind: .figure, name: figure.displayName, onOpen: { model.show(figure.ref) }) {
                        library.updateElement(world.id, StoryFigure.self, figure.id) { $0.speciesID = nil }
                    }
                }
                StoryElementPickerButton(kinds: [.figure], world: world, library: library, excluded: Set(members.map(\.ref)), label: "Figur") { ref in
                    library.updateElement(world.id, StoryFigure.self, ref.id) { $0.speciesID = speciesID }
                }
            }
        }
    }
}

// MARK: - Fact

/// A fact: a title, a note, tags to find it again, pictures, a source, and what it is about.
struct StoryFactPage: View {
    let factID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StoryFact, T>) -> Binding<T> {
        library.binding(world.id, StoryFact.self, factID, keyPath)
    }

    private func update(_ change: (inout StoryFact) -> Void) {
        library.updateElement(world.id, StoryFact.self, factID, change)
    }

    var body: some View {
        if let fact = world.element(StoryFact.self, factID) {
            StoryPageScroll {
                StoryElementHeader(ref: fact.ref, name: field(\.name), world: world, model: model, library: library,
                                   placeholder: "Titel – „Die Schlacht am Trident“, „Erbrecht im Norden“") {
                    Text(fact.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Angelegt")
                }
                StoryTagEditor(tags: fact.tags, known: world.factTags, color: StoryElementKind.fact.color) { tags in
                    update { $0.tags = tags }
                } onSearch: { tag in
                    model.factTagFilter = [tag]
                }
                StoryTextArea(title: "Notiz", placeholder: "Was über die Welt feststeht – Daten, Namen, Zusammenhänge …",
                              text: field(\.text), lines: 4...30)
                VStack(alignment: .leading, spacing: 6) {
                    StoryLabel(title: "Bilder", hint: "Karten, Wappen, Skizzen, Quellen – Bilder werden in die Bibliothek kopiert.")
                    StoryImageGallery(worldID: world.id, images: fact.images, library: library) { images in
                        update { $0.images = images }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    StoryLabel(title: "Quelle", hint: "Woher der Fakt stammt: eine Chronik der Welt, ein echtes Buch, ein Link.")
                    StoryTextEditor(placeholder: "Chronik von …, S. 12", text: field(\.source))
                        .storyField()
                }
                VStack(alignment: .leading, spacing: 6) {
                    StoryLabel(title: "Gehört zu", symbol: "link", color: StoryElementKind.fact.color)
                    StoryLinkList(kinds: [.figure, .species, .place, .event], refs: fact.links, world: world, library: library, model: model,
                                  addLabel: "Figur, Spezies, Ort oder Event") { refs in
                        update { $0.links = refs }
                    }
                }
            }
        }
    }
}

/// The tags of a fact as chips (the cross removes one), and a dropdown to tick known tags or make new ones.
struct StoryTagEditor: View {
    let tags: [String]
    /// Every tag the world's facts use, most used first.
    let known: [(tag: String, count: Int)]
    var color: Color = Theme.accent
    let onChange: ([String]) -> Void
    var onSearch: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StoryLabel(title: "Schlagworte", hint: "Im Menü ankreuzen oder neu anlegen. In der Liste der Fakten filtert das Menü „Schlagworte“ nach ihnen.",
                       symbol: "number", color: color)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    chip(tag)
                }
                StoryTagMenuButton(title: tags.isEmpty ? "Schlagworte wählen" : "Schlagworte", tags: known, selected: tags,
                                   allowsNew: true, color: color) { tag in
                    if let index = tags.firstIndex(where: { StoryFact.sameTag($0, tag) }) {
                        var result = tags
                        result.remove(at: index)
                        onChange(result)
                    } else {
                        onChange(tags + [tag])
                    }
                }
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#" + tag)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .onTapGesture { onSearch?(tag) }
                .help(onSearch == nil ? tag : "Die Liste der Fakten nach #\(tag) filtern")
            Button {
                onChange(tags.filter { $0 != tag })
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Schlagwort entfernen")
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }
}

/// A dropdown of tags with checkboxes: each click ticks or unticks one and the list stays open, so several can be
/// chosen in a row. A search field narrows long lists; with `allowsNew` it also makes a new tag.
struct StoryTagMenuButton: View {
    let title: String
    let tags: [(tag: String, count: Int)]
    let selected: [String]
    var allowsNew = false
    var color: Color = Theme.accent
    let onToggle: (String) -> Void
    var onClear: (() -> Void)?
    @State private var shows = false

    var body: some View {
        Button {
            shows = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: allowsNew ? "plus" : "line.3.horizontal.decrease")
                    .font(.system(size: 9.5, weight: .bold))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(!allowsNew && !selected.isEmpty ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(!allowsNew && !selected.isEmpty ? color.opacity(0.25) : Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: allowsNew ? [3, 2] : [])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(allowsNew ? "Schlagworte ankreuzen oder neu anlegen" : "Nach Schlagworten filtern – mehrere zugleich möglich")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            StoryTagList(tags: tags, selected: selected, allowsNew: allowsNew, color: color, onToggle: onToggle, onClear: onClear)
        }
    }

    private var label: String {
        if allowsNew || selected.isEmpty { return title }
        if selected.count == 1 { return "#" + selected[0] }
        return "\(selected.count) Schlagworte"
    }
}

private struct StoryTagList: View {
    let tags: [(tag: String, count: Int)]
    let selected: [String]
    let allowsNew: Bool
    let color: Color
    let onToggle: (String) -> Void
    let onClear: (() -> Void)?
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let typed = StoryFact.normalizedTag(query)
        let shown = tags.filter { typed.isEmpty || $0.tag.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let isNew = !typed.isEmpty && !tags.contains { StoryFact.sameTag($0.tag, typed) }
        VStack(alignment: .leading, spacing: 8) {
            TextField(allowsNew ? "Suchen oder neues Schlagwort …" : "Schlagworte suchen", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if isNew, allowsNew {
                        onToggle(typed)
                        query = ""
                    } else if let first = shown.first {
                        onToggle(first.tag)
                        query = ""
                    }
                }
            if isNew, allowsNew {
                Button {
                    onToggle(typed)
                    query = ""
                } label: {
                    Label("„#\(typed)“ anlegen", systemImage: "plus.circle")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.tag) { item in
                        let on = selected.contains { StoryFact.sameTag($0, item.tag) }
                        Button {
                            onToggle(item.tag)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(on ? color : Theme.textTertiary)
                                Text("#" + item.tag)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(item.count)")
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StoryRowButtonStyle())
                    }
                    if shown.isEmpty, !isNew {
                        Text(tags.isEmpty ? "Noch keine Schlagworte." : "Kein Schlagwort passt.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(8)
                    }
                }
            }
            .frame(height: min(CGFloat(max(shown.count, 1)) * 27 + 4, 270))
            if let onClear, !selected.isEmpty {
                Divider()
                Button("Auswahl aufheben", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { focused = true }
    }
}

/// The facts linked to an element, for its page.
struct StoryRelatedFacts: View {
    let ref: StoryRef
    let world: StoryWorld
    let model: StoriesStudioModel

    var body: some View {
        let facts = world.facts(about: ref)
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                StoryLabel(title: "Fakten dazu", symbol: StoryElementKind.fact.symbol, color: StoryElementKind.fact.color)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(facts) { fact in
                        StoryElementChip(kind: .fact, name: fact.displayName, detail: fact.tags.first.map { "#" + $0 }, onOpen: { model.show(fact.ref) })
                    }
                }
            }
        }
    }
}
