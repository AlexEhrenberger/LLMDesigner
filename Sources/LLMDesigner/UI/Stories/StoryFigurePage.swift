import SwiftUI

/// A figure in six tabs: life, character, psyche, stance, its place in the story, and its scene book.
struct StoryFigurePage: View {
    enum Tab: Hashable {
        case life, character, psyche, stance, story, scenes
    }

    let figureID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private var tab: Binding<Tab> {
        Binding(get: { model.figureTab }, set: { model.figureTab = $0 })
    }

    private func field<T>(_ keyPath: WritableKeyPath<StoryFigure, T>) -> Binding<T> {
        library.binding(world.id, StoryFigure.self, figureID, keyPath)
    }

    var body: some View {
        if let figure = world.element(StoryFigure.self, figureID) {
            StoryPageScroll {
                HStack(alignment: .top, spacing: 16) {
                    StoryAvatar(kind: .figure, image: figure.images.first, worldID: world.id, library: library, size: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        StoryElementHeader(ref: figure.ref, name: field(\.name), world: world, model: model, library: library) {
                            StoryHeaderMenu(title: figure.role.label, symbol: "theatermask.and.paintbrush", help: "Rolle in der Geschichte") {
                                ForEach(FigureRole.allCases) { role in
                                    Button(role.label) { library.updateElement(world.id, StoryFigure.self, figureID) { $0.role = role } }
                                }
                            }
                            if !figure.personality.code.isEmpty {
                                Text(figure.personality.code)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                                    .help("Psychologisches Profil (Myers-Briggs)")
                            }
                        }
                        TextField("Beiname oder Titel – „die Unverbrannte“", text: field(\.epithet))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                StoryTabBar(tabs: [(Tab.life, "Lebenslauf", "person.text.rectangle"), (.character, "Charakter", "person.fill.questionmark"),
                                   (.psyche, "Psyche", "brain.head.profile"), (.stance, "Haltung", "arrow.left.arrow.right"),
                                   (.story, "Geschichte", "text.book.closed"), (.scenes, "Szenenbuch", "quote.bubble")],
                            selection: tab)
                    .padding(.vertical, 4)
                switch tab.wrappedValue {
                case .life: life(figure)
                case .character: character
                case .psyche: StoryPsycheEditor(figureID: figureID, world: world, library: library)
                case .stance: stance(figure)
                case .story: story(figure)
                case .scenes: StorySceneBook(figureID: figureID, world: world, model: model, library: library)
                }
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private func life(_ figure: StoryFigure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StoryLabel(title: "Bilder", hint: "Das erste Bild ist das Porträt der Figur. Rechtsklick macht ein anderes zum Hauptbild.")
            StoryImageGallery(worldID: world.id, images: figure.images, library: library) { images in
                library.updateElement(world.id, StoryFigure.self, figureID) { $0.images = images }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            StoryTextArea(title: "Geburt", placeholder: "Wann und unter welchen Umständen", text: field(\.birth), lines: 1...4)
            StoryTextArea(title: "Herkunft", placeholder: "Haus, Volk, Land, Stand", text: field(\.origin), lines: 1...4)
        }
        StoryTextArea(title: "Biografische Stationen", hint: "Ein freier Block statt eines Lebenslaufs mit festen Feldern – die Stationen so, wie sie in dieser Welt zählen.",
                      placeholder: "Kindheit in …, mit zwölf an den Hof von …, verliert …", text: field(\.biography), lines: 6...30)
    }

    @ViewBuilder
    private var character: some View {
        StoryTextArea(title: "Äußere Merkmale", placeholder: "Gestalt, Gesicht, Kleidung, Narben, Haltung", text: field(\.appearance), lines: 2...12)
        StoryTextArea(title: "Verhaltensmerkmale", placeholder: "Gewohnheiten, Gesten, wie sie mit anderen umgeht", text: field(\.behavior), lines: 2...12)
        StoryTextArea(title: "Geheimnisse", hint: "Was die Figur verbirgt – vor anderen oder vor sich selbst.", text: field(\.secrets), lines: 2...12)
        HStack(alignment: .top, spacing: 14) {
            StoryTextArea(title: "Wants", hint: "Was die Figur bewusst will – ihr äußeres Ziel.", placeholder: "Den Thron zurückgewinnen",
                          text: field(\.wants), lines: 3...12)
            StoryTextArea(title: "Needs", hint: "Was sie wirklich braucht, oft ohne es zu wissen – ihr inneres Bedürfnis.",
                          placeholder: "Lernen, anderen zu vertrauen", text: field(\.needs), lines: 3...12)
        }
        StoryTextArea(title: "Kernkonflikt", hint: "Wo Wants und Needs, Pflicht und Wunsch oder zwei Loyalitäten gegeneinander stehen.",
                      text: field(\.coreConflict), lines: 2...12)
        StoryTextArea(title: "Ängste", text: field(\.fears), lines: 2...10)
        StoryTextArea(title: "Charakterentwicklung", hint: "Von wo nach wo: wer die Figur am Anfang ist, was sie verändert, wer sie am Ende ist.",
                      placeholder: "Anfang → Wendepunkte → Ende", text: field(\.development), lines: 3...16)
    }

    @ViewBuilder
    private func stance(_ figure: StoryFigure) -> some View {
        StoryTextArea(title: "Politisches Profil", hint: "Wem sie dient, woran sie glaubt, was sie von Macht, Recht und Ordnung hält.",
                      placeholder: "Loyal zum Haus …, misstraut dem Glauben …", text: field(\.politics), lines: 3...14)
        StoryRelationEditor(figure: figure, world: world, model: model, library: library)
        let incoming = world.incomingRelations(to: figure.ref)
        if !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                StoryLabel(title: "Wie andere zu ihr stehen", symbol: "arrow.left", color: StoryElementKind.figure.color)
                ForEach(incoming, id: \.relation.id) { item in
                    HStack(spacing: 8) {
                        StoryElementChip(kind: .figure, name: item.figure.displayName, onOpen: { model.show(item.figure.ref) })
                        StoryAttitudeBadge(attitude: item.relation.attitude)
                        Text([item.relation.label, item.relation.note].filter { !$0.isEmpty }.joined(separator: " – "))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func story(_ figure: StoryFigure) -> some View {
        StoryTextArea(title: "Stimme der Person in der Geschichte", hint: "Wie sie spricht und denkt: Wortwahl, Satzlänge, Sprachmelodie, typische Wendungen, was sie nie sagen würde.",
                      text: field(\.voice), lines: 3...14)
        StoryTextArea(title: "Wahrnehmung der Person in der Geschichte", hint: "Wie andere Figuren und die Leser:innen sie sehen – und wo dieses Bild täuscht.",
                      text: field(\.perception), lines: 3...14)
        StoryUsageList(ref: figure.ref, world: world, model: model)
        StoryPinList(ref: figure.ref, world: world, model: model)
    }
}

// MARK: - Psyche

/// The four Myers-Briggs preferences as sliders, the reaction to stress and the persona as a whole.
private struct StoryPsycheEditor: View {
    let figureID: UUID
    let world: StoryWorld
    let library: StoryLibrary

    var body: some View {
        let profile = world.element(StoryFigure.self, figureID)?.personality ?? PersonalityProfile()
        StoryCard(tint: Theme.accent) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StoryLabel(title: "Psychologisches Profil (Myers-Briggs)", symbol: "brain.head.profile", color: Theme.accent)
                Spacer()
                if !profile.code.isEmpty {
                    Text(profile.code)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    if let temperament = profile.temperament {
                        Text(temperament)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            ForEach(PersonalityProfile.Axis.allCases) { axis in
                axisRow(axis, profile: profile)
                if axis != .lifestyle { Divider().opacity(0.4) }
            }
        }
        StoryCard(tint: Theme.warning) {
            StoryLabel(title: "Zunehmend Stress – wie neurotisch ist die Figur?", hint: "Bleibt sie unter Druck gelassen und stabil (A, „assertive“), oder gerät sie ins Wanken, grübelt, reagiert heftig (T, „turbulent“)?",
                       symbol: "waveform.path.ecg", color: Theme.warning)
            slider(value: profile.neuroticism, range: 0...1, poles: ("Gelassen", "Neurotisch")) { value in
                update { $0.neuroticism = value }
            }
            TextField("Wie verändert sie sich, wenn der Druck wächst?", text: Binding(
                get: { profile.stressNote }, set: { text in update { $0.stressNote = text } }
            ), axis: .vertical)
            .lineLimit(1...8)
            .storyField()
        }
        StoryTextArea(title: "Persona im Ganzen", hint: "Das Bild, das sich aus allem ergibt: wie diese Psyche in der Geschichte wirkt.",
                      text: library.binding(world.id, StoryFigure.self, figureID, \.persona), lines: 3...16)
    }

    private func axisRow(_ axis: PersonalityProfile.Axis, profile: PersonalityProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(axis.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .help(axis.hint)
                Spacer()
                Text(Self.tendency(profile.values[axis], poles: axis.poles))
                    .font(.system(size: 11.5))
                    .foregroundStyle(profile.values[axis] == nil ? Theme.textTertiary : Theme.textSecondary)
            }
            slider(value: profile.values[axis], range: -1...1, poles: axis.poles) { value in
                update { $0.values[axis] = value }
            }
            TextField("Wie zeigt sich das?", text: Binding(
                get: { profile.notes[axis] ?? "" },
                set: { text in update { $0.notes[axis] = text.isEmpty ? nil : text } }
            ), axis: .vertical)
            .lineLimit(1...6)
            .storyField()
        }
    }

    private func slider(value: Double?, range: ClosedRange<Double>, poles: (String, String), set: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(poles.0)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 92, alignment: .trailing)
            Slider(value: Binding(get: { value ?? (range.lowerBound + range.upperBound) / 2 }, set: { set($0) }), in: range)
                .opacity(value == nil ? 0.45 : 1)
            Text(poles.1)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 92, alignment: .leading)
            Button {
                set(nil)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(value == nil ? 0 : 1)
            .disabled(value == nil)
            .help("Wieder offen lassen")
        }
    }

    static func tendency(_ value: Double?, poles: (String, String)) -> String {
        guard let value else { return "noch offen" }
        let strength = abs(value)
        if strength < 0.15 { return "ausgeglichen" }
        let pole = value < 0 ? poles.0 : poles.1
        if strength < 0.45 { return "leicht \(pole)" }
        if strength < 0.8 { return "deutlich \(pole)" }
        return "stark \(pole)"
    }

    private func update(_ change: (inout PersonalityProfile) -> Void) {
        library.updateElement(world.id, StoryFigure.self, figureID) { change(&$0.personality) }
    }
}

// MARK: - Relations

/// "Wie steht die Person zu …": figures, events and places with an attitude, a word and a note.
private struct StoryRelationEditor: View {
    let figure: StoryFigure
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StoryLabel(title: "Wie steht die Person zu …", hint: "Zu anderen Figuren, zu Events und zu Orten. Die Haltung gilt nur in diese Richtung – wie die anderen zu ihr stehen, steht bei ihnen.",
                           symbol: "arrow.right", color: StoryElementKind.figure.color)
                Spacer()
                StoryElementPickerButton(kinds: [.figure, .event, .place], world: world, library: library,
                                         excluded: Set(figure.relations.map(\.target) + [figure.ref]), label: "Person, Event oder Ort") { ref in
                    library.updateElement(world.id, StoryFigure.self, figure.id) { $0.relations.append(StoryRelation(target: ref)) }
                }
            }
            if figure.relations.isEmpty {
                Text("Noch keine Haltungen. Füge eine Person, ein Event oder einen Ort hinzu.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(figure.relations) { relation in
                if let name = world.name(of: relation.target) {
                    row(relation, name: name)
                }
            }
        }
    }

    private func row(_ relation: StoryRelation, name: String) -> some View {
        StoryCard(tint: relation.target.kind.color) {
            HStack(spacing: 10) {
                StoryElementChip(kind: relation.target.kind, name: name, onOpen: { model.show(relation.target) })
                TextField("Beziehung – Bruder, Rivalin, Lehnsherr …", text: binding(relation.id, \.label))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    library.updateElement(world.id, StoryFigure.self, figure.id) { $0.relations.removeAll { $0.id == relation.id } }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Haltung entfernen")
            }
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(StoryRelation.attitudes, id: \.value) { attitude in
                    Button {
                        library.updateElement(world.id, StoryFigure.self, figure.id) { figure in
                            if let index = figure.relations.firstIndex(where: { $0.id == relation.id }) { figure.relations[index].attitude = attitude.value }
                        }
                    } label: {
                        Text(attitude.label)
                            .font(.system(size: 11.5, weight: relation.attitude == attitude.value ? .semibold : .regular))
                            .foregroundStyle(relation.attitude == attitude.value ? Theme.textPrimary : Theme.textTertiary)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(relation.attitude == attitude.value ? StoryAttitudeBadge.color(attitude.value).opacity(0.3) : Color.white.opacity(0.03)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Warum – was ist zwischen ihnen geschehen?", text: binding(relation.id, \.note), axis: .vertical)
                .lineLimit(1...8)
                .storyField()
        }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<StoryRelation, String>) -> Binding<String> {
        Binding(
            get: { world.element(StoryFigure.self, figure.id)?.relations.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { text in
                library.updateElement(world.id, StoryFigure.self, figure.id) { figure in
                    if let index = figure.relations.firstIndex(where: { $0.id == id }) { figure.relations[index][keyPath: keyPath] = text }
                }
            }
        )
    }
}

struct StoryAttitudeBadge: View {
    let attitude: Int

    static func color(_ attitude: Int) -> Color {
        switch attitude {
        case ..<(-1): Theme.danger
        case -1: Color(hex: 0xF2884C)
        case 0: Theme.textTertiary
        case 1: Color(hex: 0x8BD67A)
        default: Theme.success
        }
    }

    var body: some View {
        Text(StoryRelation.attitudeLabel(attitude))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.color(attitude))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Self.color(attitude).opacity(0.14)))
    }
}

// MARK: - Scene book

/// Quotes, example scenes and incidents of a figure, each perhaps tied to a part of the story.
private struct StorySceneBook: View {
    let figureID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    @State private var filter: SceneNote.Kind?
    @State private var focusID: UUID?

    var body: some View {
        let scenes = world.element(StoryFigure.self, figureID)?.scenes ?? []
        let shown = scenes.filter { filter == nil || $0.kind == filter }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    filterChip(nil, count: scenes.count)
                    ForEach(SceneNote.Kind.allCases) { kind in
                        filterChip(kind, count: scenes.filter { $0.kind == kind }.count)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(SceneNote.Kind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { add(kind) }
                    }
                } label: {
                    Label("Eintrag", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            if shown.isEmpty {
                Text("Das Szenenbuch sammelt, was die Figur ausmacht: Zitate in ihrer Stimme, Beispielszenen, die zeigen, wie sie handelt, und Vorkommnisse aus ihrem Leben.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
            }
            ForEach(shown) { note in
                StorySceneCard(note: note, figureID: figureID, world: world, model: model, library: library, focused: focusID == note.id)
            }
        }
    }

    private func filterChip(_ kind: SceneNote.Kind?, count: Int) -> some View {
        Button {
            filter = kind
        } label: {
            HStack(spacing: 5) {
                if let kind { Image(systemName: kind.symbol).font(.system(size: 10)) }
                Text(kind?.plural ?? "Alle")
                Text("\(count)").foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 12, weight: filter == kind ? .semibold : .regular))
            .foregroundStyle(filter == kind ? Theme.textPrimary : Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(filter == kind ? Theme.selection : Color.white.opacity(0.03)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func add(_ kind: SceneNote.Kind) {
        let note = SceneNote(kind: kind)
        library.updateElement(world.id, StoryFigure.self, figureID) { $0.scenes.insert(note, at: 0) }
        if filter != nil { filter = kind }
        focusID = note.id
    }
}

private struct StorySceneCard: View {
    let note: SceneNote
    let figureID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary
    let focused: Bool
    @FocusState private var textFocused: Bool

    var body: some View {
        StoryCard {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SceneNote.Kind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { update { $0.kind = kind } }
                    }
                } label: {
                    Label(note.kind.label, systemImage: note.kind.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                if let partID = note.partID {
                    StoryPartChip(world: world, partID: partID, model: model) { update { $0.partID = nil } }
                } else {
                    StoryPartMenu(world: world, onPick: { id in update { $0.partID = id } }) {
                        Label("Stelle in der Geschichte", systemImage: "link")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                Button {
                    library.updateElement(world.id, StoryFigure.self, figureID) { $0.scenes.removeAll { $0.id == note.id } }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Eintrag löschen")
            }
            TextField(placeholder, text: Binding(
                get: { world.element(StoryFigure.self, figureID)?.scenes.first { $0.id == note.id }?.text ?? "" },
                set: { text in update { $0.text = text } }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(note.kind == .quote ? .system(size: 14, design: .serif).italic() : .system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2...40)
            .focused($textFocused)
        }
        .onAppear {
            if focused { DispatchQueue.main.async { textFocused = true } }
        }
    }

    private var placeholder: String {
        switch note.kind {
        case .quote: "„Was sie sagt – in ihren eigenen Worten.“"
        case .scene: "Eine kurze Szene, die zeigt, wie sie handelt …"
        case .incident: "Was ihr widerfahren ist oder was sie getan hat …"
        }
    }

    private func update(_ change: (inout SceneNote) -> Void) {
        library.updateElement(world.id, StoryFigure.self, figureID) { figure in
            if let index = figure.scenes.firstIndex(where: { $0.id == note.id }) { change(&figure.scenes[index]) }
        }
    }
}
