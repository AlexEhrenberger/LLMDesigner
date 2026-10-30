import SwiftUI

// MARK: - Place

/// A place: where it lies, how it feels, its history and people, what it means for the story.
struct StoryPlacePage: View {
    let placeID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StoryPlace, T>) -> Binding<T> {
        library.binding(world.id, StoryPlace.self, placeID, keyPath)
    }

    var body: some View {
        if let place = world.element(StoryPlace.self, placeID) {
            StoryPageScroll {
                StoryElementHeader(ref: place.ref, name: field(\.name), world: world, model: model, library: library) {
                    StoryHeaderMenu(title: place.placeKind.label, symbol: place.placeKind.symbol, help: "Art des Ortes") {
                        ForEach(PlaceKind.allCases) { kind in
                            Button(kind.label, systemImage: kind.symbol) { library.updateElement(world.id, StoryPlace.self, placeID) { $0.placeKind = kind } }
                        }
                    }
                    parentMenu(place)
                }
                StoryImageGallery(worldID: world.id, images: place.images, library: library) { images in
                    library.updateElement(world.id, StoryPlace.self, placeID) { $0.images = images }
                }
                StoryTextArea(title: "Erscheinung & Atmosphäre", hint: "Was man dort sieht, hört, riecht und spürt – und welche Stimmung der Ort einer Szene gibt.",
                              placeholder: "Nebel über schwarzem Stein, das Krächzen der Raben …", text: field(\.atmosphere), lines: 3...14)
                StoryTextArea(title: "Geografie & Klima", text: field(\.geography), lines: 2...10)
                StoryTextArea(title: "Geschichte des Ortes", placeholder: "Wer hat ihn gegründet, was ist hier geschehen?", text: field(\.history), lines: 2...14)
                VStack(alignment: .leading, spacing: 8) {
                    StoryTextArea(title: "Herrschaft & Bewohner", placeholder: "Wer herrscht, wer lebt hier, wovon?", text: field(\.society), lines: 2...12)
                    StoryLinkList(kind: .figure, ids: place.residentIDs, world: world, library: library, model: model, addLabel: "Figur verknüpfen") { ids in
                        library.updateElement(world.id, StoryPlace.self, placeID) { $0.residentIDs = ids }
                    }
                }
                StoryTextArea(title: "Bedeutung für die Geschichte", hint: "Wofür der Ort steht: Zuflucht, Gefängnis, Versprechen, Spiegel einer Figur – seine Symbolik und seine Funktion.",
                              text: field(\.significance), lines: 2...12)
                StoryTextArea(title: "Geheimnisse", text: field(\.secrets), lines: 2...10)
                related(place)
                StoryUsageList(ref: place.ref, world: world, model: model)
                StoryPinList(ref: place.ref, world: world, model: model)
                StoryTextArea(title: "Notizen", text: field(\.notes), lines: 2...16)
            }
        }
    }

    private func parentMenu(_ place: StoryPlace) -> some View {
        StoryHeaderMenu(title: place.parentID.flatMap { world.element(StoryPlace.self, $0)?.displayName }.map { "liegt in \($0)" } ?? "liegt in …",
                        symbol: "arrow.turn.left.up", help: "Der Ort, in dem dieser liegt") {
            Button("Nirgends (oberste Ebene)") { library.updateElement(world.id, StoryPlace.self, placeID) { $0.parentID = nil } }
            Divider()
            ForEach(world.possibleParents(of: placeID).sorted { world.placePath($0.id).localizedStandardCompare(world.placePath($1.id)) == .orderedAscending }) { other in
                Button(world.placePath(other.id)) { library.updateElement(world.id, StoryPlace.self, placeID) { $0.parentID = other.id } }
            }
        }
    }

    @ViewBuilder
    private func related(_ place: StoryPlace) -> some View {
        let subplaces = world.subplaces(of: placeID)
        let events = world.events.filter { $0.placeIDs.contains(placeID) }
        if !subplaces.isEmpty || !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !subplaces.isEmpty {
                    StoryLabel(title: "Orte darin", symbol: StoryElementKind.place.symbol, color: StoryElementKind.place.color)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(subplaces) { sub in
                            StoryElementChip(kind: .place, name: sub.displayName, onOpen: { model.show(sub.ref) })
                        }
                    }
                }
                if !events.isEmpty {
                    StoryLabel(title: "Events an diesem Ort", symbol: StoryElementKind.event.symbol, color: StoryElementKind.event.color)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(events) { event in
                            StoryElementChip(kind: .event, name: event.displayName, onOpen: { model.show(event.ref) })
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Event

/// An event: what happens, where and with whom; what led to it and, above all, what follows from it.
struct StoryEventPage: View {
    let eventID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StoryEvent, T>) -> Binding<T> {
        library.binding(world.id, StoryEvent.self, eventID, keyPath)
    }

    private func update(_ change: (inout StoryEvent) -> Void) {
        library.updateElement(world.id, StoryEvent.self, eventID, change)
    }

    var body: some View {
        if let event = world.element(StoryEvent.self, eventID) {
            StoryPageScroll {
                StoryElementHeader(ref: event.ref, name: field(\.name), world: world, model: model, library: library, placeholder: "Was passiert – „Sturz des Königs“") {
                    StoryHeaderMenu(title: event.eventKind.label, symbol: "tag", help: "Art des Events") {
                        ForEach(EventKind.allCases) { kind in
                            Button(kind.label) { update { $0.eventKind = kind } }
                        }
                    }
                }
                TextField("Wann – in den Worten der Welt („im letzten Sommer vor dem langen Winter“)", text: field(\.when))
                    .storyField()
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        StoryLabel(title: "Wo", symbol: StoryElementKind.place.symbol, color: StoryElementKind.place.color)
                        StoryLinkList(kind: .place, ids: event.placeIDs, world: world, library: library, model: model, addLabel: "Ort") { ids in
                            update { $0.placeIDs = ids }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        StoryLabel(title: "Beteiligte", symbol: StoryElementKind.figure.symbol, color: StoryElementKind.figure.color)
                        StoryLinkList(kind: .figure, ids: event.figureIDs, world: world, library: library, model: model, addLabel: "Figur") { ids in
                            update { $0.figureIDs = ids }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                StoryTextArea(title: "Hergang", placeholder: "Was geschieht, Schritt für Schritt?", text: field(\.course), lines: 3...20)
                causality(event)
                consequences(event)
                knowledge(event)
                StoryTextArea(title: "Bedeutung für die Handlung", hint: "Was dieses Event für den Bogen der Geschichte leistet – was ohne es nicht ginge.",
                              text: field(\.significance), lines: 2...12)
                StoryPinList(ref: event.ref, world: world, model: model)
                StoryUsageList(ref: event.ref, world: world, model: model)
                StoryTextArea(title: "Notizen", text: field(\.notes), lines: 2...16)
            }
        }
    }

    /// Causes on the left, the event in the middle, what follows on the right.
    private func causality(_ event: StoryEvent) -> some View {
        let causes = world.causes(of: eventID)
        let followers = world.followers(of: eventID)
        let causeList = VStack(alignment: .trailing, spacing: 6) {
            ForEach(causes) { cause in
                StoryElementChip(kind: .event, name: cause.displayName, onOpen: { model.show(cause.ref) },
                                 onRemove: event.causeEventIDs.contains(cause.id) ? { update { $0.causeEventIDs.removeAll { $0 == cause.id } } } : nil)
            }
            StoryElementPickerButton(kinds: [.event], world: world, library: library,
                                     excluded: Set((event.causeEventIDs + [eventID]).map { StoryRef(kind: .event, id: $0) }), label: "Ursache") { ref in
                update { $0.causeEventIDs.append(ref.id) }
            }
        }
        let center = Text(event.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StoryElementKind.event.color.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StoryElementKind.event.color.opacity(0.5)))
        let followerList = VStack(alignment: .leading, spacing: 6) {
            ForEach(followers) { follower in
                StoryElementChip(kind: .event, name: follower.displayName, onOpen: { model.show(follower.ref) })
            }
            if followers.isEmpty {
                Text("Folge-Events entstehen aus den Auswirkungen unten.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let arrow = { (symbol: String) in Image(systemName: symbol).foregroundStyle(Theme.textTertiary) }
        return StoryCard(tint: StoryElementKind.event.color) {
            StoryLabel(title: "Ursachen & Folgen", hint: "Was zu diesem Event führt, und die Events, zu denen seine Auswirkungen werden. So entsteht eine Kette von Ursache und Wirkung.",
                       symbol: "arrow.triangle.branch", color: StoryElementKind.event.color)
            // Side by side where there is room, one below the other where there isn't.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    causeList.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
                    arrow("arrow.right")
                    center.fixedSize()
                    arrow("arrow.right")
                    followerList.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Ursachen").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                    causeList
                    arrow("arrow.down")
                    center
                    arrow("arrow.down")
                    followerList
                }
            }
            TextField("Auslöser und Ursachen in Worten", text: field(\.causes), axis: .vertical)
                .lineLimit(1...10)
                .storyField()
        }
    }

    private func consequences(_ event: StoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StorySectionTitle(title: "Auswirkungen", symbol: "waveform.path.ecg.rectangle", color: StoryElementKind.event.color)
                Spacer()
                Button {
                    update { $0.consequences.append(EventConsequence()) }
                } label: {
                    Label("Auswirkung", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if event.consequences.isEmpty {
                Text("Was ändert sich durch dieses Event – an der Macht, für die Menschen, für einzelne Figuren? Was folgt sofort, was erst in Jahren?")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(event.consequences) { consequence in
                StoryConsequenceCard(consequence: consequence, eventID: eventID, world: world, model: model, library: library)
            }
        }
    }

    private func knowledge(_ event: StoryEvent) -> some View {
        StoryCard {
            StoryLabel(title: "Wer weiß davon?", hint: "Ob das Event – oder wie es wirklich geschah – bekannt ist. Wer es weiß und wer nicht, trägt Spannung und dramatische Ironie.",
                       symbol: "eye.slash")
            Picker("", selection: field(\.knowledge)) {
                ForEach(EventKnowledge.allCases) { knowledge in Text(knowledge.label).tag(knowledge) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            if event.knowledge != .open {
                StoryLinkList(kind: .figure, ids: event.knownByIDs, world: world, library: library, model: model, addLabel: "Eingeweihte Figur") { ids in
                    update { $0.knownByIDs = ids }
                }
            }
        }
    }
}

/// One consequence: area, reach, text, whom it touches, and the event it becomes.
private struct StoryConsequenceCard: View {
    let consequence: EventConsequence
    let eventID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func update(_ change: (inout EventConsequence) -> Void) {
        library.updateElement(world.id, StoryEvent.self, eventID) { event in
            if let index = event.consequences.firstIndex(where: { $0.id == consequence.id }) { change(&event.consequences[index]) }
        }
    }

    var body: some View {
        StoryCard(tint: StoryElementKind.event.color) {
            HStack(spacing: 10) {
                StoryHeaderMenu(title: consequence.area.label, symbol: "square.grid.2x2", help: "Bereich") {
                    ForEach(EventConsequence.Area.allCases) { area in Button(area.label) { update { $0.area = area } } }
                }
                StoryHeaderMenu(title: consequence.reach.label, symbol: "clock", help: "Wann die Auswirkung greift") {
                    ForEach(EventConsequence.Reach.allCases) { reach in Button(reach.label) { update { $0.reach = reach } } }
                }
                Spacer()
                Button {
                    library.updateElement(world.id, StoryEvent.self, eventID) { $0.consequences.removeAll { $0.id == consequence.id } }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Auswirkung entfernen")
            }
            TextField("Was ändert sich?", text: Binding(
                get: { world.element(StoryEvent.self, eventID)?.consequences.first { $0.id == consequence.id }?.text ?? "" },
                set: { text in update { $0.text = text } }
            ), axis: .vertical)
            .lineLimit(1...12)
            .storyField()
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Betrifft").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    StoryLinkList(kinds: [.figure, .place], refs: consequence.affected, world: world, library: library, model: model,
                                  addLabel: "Figur oder Ort") { refs in update { $0.affected = refs } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Führt zu Event").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    if let followID = consequence.followEventID, let follow = world.element(StoryEvent.self, followID) {
                        StoryElementChip(kind: .event, name: follow.displayName, onOpen: { model.show(follow.ref) }) {
                            update { $0.followEventID = nil }
                        }
                    } else {
                        StoryElementPickerButton(kinds: [.event], world: world, library: library,
                                                 excluded: [StoryRef(kind: .event, id: eventID)], label: "Folge-Event") { ref in
                            update { $0.followEventID = ref.id }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Reason

/// Why something happens, as an argument: assumptions → premises → conclusion, and where it is weak.
struct StoryReasonPage: View {
    let reasonID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StoryReason, T>) -> Binding<T> {
        library.binding(world.id, StoryReason.self, reasonID, keyPath)
    }

    var body: some View {
        if let reason = world.element(StoryReason.self, reasonID) {
            StoryPageScroll {
                StoryElementHeader(ref: reason.ref, name: field(\.name), world: world, model: model, library: library,
                                   placeholder: "Worum es geht – „Warum der Lord den Gast verrät“") {
                    StoryHeaderMenu(title: reason.holderID.flatMap { world.element(StoryFigure.self, $0)?.displayName }.map { "Sicht von \($0)" } ?? "Logik der Welt",
                                    symbol: "eye", help: "Wessen Begründung das ist: die einer Figur – die sich irren kann – oder die Logik der Welt und der Erzählung") {
                        Button("Logik der Welt / der Erzählung") { library.updateElement(world.id, StoryReason.self, reasonID) { $0.holderID = nil } }
                        Divider()
                        ForEach(world.figures.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { figure in
                            Button(figure.displayName) { library.updateElement(world.id, StoryReason.self, reasonID) { $0.holderID = figure.id } }
                        }
                    }
                }
                Text("Eine Reason ist ein Argument: Annahmen – oft unausgesprochen – und Prämissen führen zur Konklusion. Markiere, was in der Welt stimmt und was ein Irrtum ist.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                StoryStatementColumn(title: "Annahmen", hint: "Was stillschweigend vorausgesetzt wird – Überzeugungen, Vorurteile, Weltbild.",
                                     symbol: "cloud", dashed: true, statements: reason.assumptions, add: "Annahme") { statements in
                    library.updateElement(world.id, StoryReason.self, reasonID) { $0.assumptions = statements }
                }
                arrow
                StoryStatementColumn(title: "Prämissen", hint: "Die ausdrücklichen Gründe, auf die sich die Schlussfolgerung stützt.",
                                     symbol: "square.stack.3d.up", dashed: false, statements: reason.premises, add: "Prämisse") { statements in
                    library.updateElement(world.id, StoryReason.self, reasonID) { $0.premises = statements }
                }
                arrow
                VStack(alignment: .leading, spacing: 6) {
                    StoryLabel(title: "Konklusion", symbol: "arrow.down.to.line", color: StoryElementKind.reason.color)
                    TextField("Also …", text: field(\.conclusion), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1...10)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StoryElementKind.reason.color.opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StoryElementKind.reason.color.opacity(0.55)))
                }
                if reason.mistakenCount > 0 {
                    Label(reason.holderID == nil
                          ? "\(reason.mistakenCount) Irrtum\(reason.mistakenCount == 1 ? "" : "er") im Argument – trägt die Logik der Welt das wirklich?"
                          : "Die Figur handelt auf \(reason.mistakenCount) Irrtum\(reason.mistakenCount == 1 ? "" : "er") hin – dramatische Ironie, wenn die Leser:innen es früher wissen.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
                StoryTextArea(title: "Schwachstelle & Gegenargument", hint: "Wo das Argument bricht oder angreifbar ist – ein Plot-Loch, das zu schließen ist, oder ein Widerspruch, den eine Figur nutzen kann.",
                              text: field(\.weakness), lines: 2...12)
                StoryUsageList(ref: reason.ref, world: world, model: model)
                StoryTextArea(title: "Notizen", text: field(\.notes), lines: 2...16)
            }
        }
    }

    private var arrow: some View {
        HStack {
            Spacer()
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StoryElementKind.reason.color.opacity(0.7))
            Spacer()
        }
    }
}

/// Assumptions or premises: one sentence each, with whether it holds in the world.
private struct StoryStatementColumn: View {
    let title: String
    let hint: String
    let symbol: String
    let dashed: Bool
    let statements: [ReasonStatement]
    let add: String
    let onChange: ([ReasonStatement]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StoryLabel(title: title, hint: hint, symbol: symbol, color: StoryElementKind.reason.color)
                Spacer()
                Button {
                    onChange(statements + [ReasonStatement()])
                } label: {
                    Label(add, systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if statements.isEmpty {
                Text("Noch keine.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(statements) { statement in
                HStack(alignment: .top, spacing: 8) {
                    TextField(add, text: Binding(
                        get: { statement.text },
                        set: { text in change(statement.id) { $0.text = text } }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...8)
                    Menu {
                        ForEach(ReasonStatement.Validity.allCases) { validity in
                            Button(validity.label, systemImage: validity.symbol) { change(statement.id) { $0.validity = validity } }
                        }
                    } label: {
                        Label(statement.validity.label, systemImage: statement.validity.symbol)
                            .font(.system(size: 11.5))
                            .foregroundStyle(color(statement.validity))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Stimmt das in der Welt der Geschichte?")
                    Button {
                        onChange(statements.filter { $0.id != statement.id })
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(StoryElementKind.reason.color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            }
        }
    }

    private func color(_ validity: ReasonStatement.Validity) -> Color {
        switch validity {
        case .open: Theme.textTertiary
        case .holds: Theme.success
        case .mistaken: Theme.danger
        }
    }

    private func change(_ id: UUID, _ change: (inout ReasonStatement) -> Void) {
        var statements = statements
        guard let index = statements.firstIndex(where: { $0.id == id }) else { return }
        change(&statements[index])
        onChange(statements)
    }
}

// MARK: - Purpose

/// The literary purpose: its function, what it should do to the readers, and where it is set up and paid off.
struct StoryPurposePage: View {
    let purposeID: UUID
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private func field<T>(_ keyPath: WritableKeyPath<StoryPurpose, T>) -> Binding<T> {
        library.binding(world.id, StoryPurpose.self, purposeID, keyPath)
    }

    var body: some View {
        if let purpose = world.element(StoryPurpose.self, purposeID) {
            StoryPageScroll {
                StoryElementHeader(ref: purpose.ref, name: field(\.name), world: world, model: model, library: library,
                                   placeholder: "Wozu – „Das Schwert über dem Kamin“") {
                    StoryHeaderMenu(title: purpose.function.label, symbol: "theatermasks", help: "Literarische Funktion") {
                        ForEach(LiteraryFunction.allCases) { function in
                            Button(function.label) { library.updateElement(world.id, StoryPurpose.self, purposeID) { $0.function = function } }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(StoryElementKind.purpose.color)
                    Text(purpose.function.explanation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StoryElementKind.purpose.color.opacity(0.08)))
                StoryTextArea(title: "Was soll damit erreicht werden?", text: field(\.intent), lines: 2...12)
                StoryTextArea(title: "Wirkung auf die Leser:innen", hint: "Was sie fühlen, ahnen oder glauben sollen – Spannung, Mitgefühl, Grauen, Erleichterung, ein falscher Verdacht.",
                              text: field(\.readerEffect), lines: 2...10)
                StoryTextArea(title: "Thema & Motiv", text: field(\.theme), lines: 1...8)
                setupAndPayoff(purpose)
                StoryUsageList(ref: purpose.ref, world: world, model: model)
                StoryTextArea(title: "Notizen", text: field(\.notes), lines: 2...16)
            }
        }
    }

    private func setupAndPayoff(_ purpose: StoryPurpose) -> some View {
        StoryCard(tint: StoryElementKind.purpose.color) {
            StoryLabel(title: "Vorbereitung und Einlösung", hint: "Wo das Versprechen gegeben wird (Setup) und wo es eingelöst wird (Payoff). Was vorbereitet, aber nie eingelöst wird, fällt hier auf.",
                       symbol: "arrow.right.circle", color: StoryElementKind.purpose.color)
            HStack(alignment: .top, spacing: 14) {
                partColumn("Vorbereitet in", ids: purpose.setupPartIDs, excluded: Set(purpose.setupPartIDs)) { ids in
                    library.updateElement(world.id, StoryPurpose.self, purposeID) { $0.setupPartIDs = ids }
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 22)
                partColumn("Eingelöst in", ids: purpose.payoffPartIDs, excluded: Set(purpose.payoffPartIDs)) { ids in
                    library.updateElement(world.id, StoryPurpose.self, purposeID) { $0.payoffPartIDs = ids }
                }
            }
            if purpose.isOpenPromise {
                Label("Vorbereitet, aber noch nirgends eingelöst.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func partColumn(_ title: String, ids: [UUID], excluded: Set<UUID>, onChange: @escaping ([UUID]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            ForEach(ids, id: \.self) { id in
                StoryPartChip(world: world, partID: id, model: model) { onChange(ids.filter { $0 != id }) }
            }
            StoryPartMenu(world: world, excluded: excluded, onPick: { id in if let id { onChange(ids + [id]) } }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                    Text("Teil wählen").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(Capsule().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
