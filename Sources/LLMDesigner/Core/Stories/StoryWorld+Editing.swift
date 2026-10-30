import Foundation

/// Whose timeline: the world's own or that of a book, act or chapter.
enum TimelineOwner: Hashable, Sendable {
    case world
    case part(UUID)
}

/// Where an element is used, for the "Vorkommen" of its page.
struct StoryUsage: Hashable, Identifiable {
    enum Role: Hashable {
        case focus(StoryElementKind)
        case pointOfView
        case timeline
        case setup
        case payoff
        case scene
    }

    /// nil: the world itself (its timeline).
    var partID: UUID?
    var role: Role

    var id: String { "\(partID?.uuidString ?? "welt")-\(role)" }

    var label: String {
        switch role {
        case .focus(let kind): kind.question
        case .pointOfView: "Perspektive"
        case .timeline: "Timeline"
        case .setup: "Vorbereitet"
        case .payoff: "Eingelöst"
        case .scene: "Szenenbuch"
        }
    }
}

/// A part with its place in the tree, for lists of all parts.
struct StoryPartEntry: Identifiable, Hashable {
    var part: StoryPart
    var depth: Int
    var path: String

    var id: UUID { part.id }
}

// MARK: - Parts

extension StoryWorld {
    func part(_ id: UUID) -> StoryPart? {
        Self.find(id, in: books)
    }

    private static func find(_ id: UUID, in parts: [StoryPart]) -> StoryPart? {
        for part in parts {
            if part.id == id { return part }
            if let found = find(id, in: part.children) { return found }
        }
        return nil
    }

    /// Changes one part wherever it is in the tree; false if there is none with this id.
    @discardableResult
    mutating func updatePart(_ id: UUID, _ change: (inout StoryPart) -> Void) -> Bool {
        Self.update(id, in: &books, change)
    }

    private static func update(_ id: UUID, in parts: inout [StoryPart], _ change: (inout StoryPart) -> Void) -> Bool {
        for index in parts.indices {
            if parts[index].id == id {
                change(&parts[index])
                parts[index].updatedAt = Date()
                return true
            }
            if update(id, in: &parts[index].children, change) { return true }
        }
        return false
    }

    /// The parts from the book down to this one.
    func path(to id: UUID) -> [StoryPart] {
        func walk(_ parts: [StoryPart], _ trail: [StoryPart]) -> [StoryPart]? {
            for part in parts {
                if part.id == id { return trail + [part] }
                if let found = walk(part.children, trail + [part]) { return found }
            }
            return nil
        }
        return walk(books, []) ?? []
    }

    func parentID(of id: UUID) -> UUID? {
        let path = path(to: id)
        return path.count > 1 ? path[path.count - 2].id : nil
    }

    /// Every part in reading order, with its depth and its path ("Buch 1 › Akt II › Kapitel 3").
    var allParts: [StoryPartEntry] {
        var entries: [StoryPartEntry] = []
        func walk(_ parts: [StoryPart], depth: Int, trail: [String]) {
            for part in parts {
                let name = displayTitle(of: part)
                let path = (trail + [name]).joined(separator: " › ")
                entries.append(StoryPartEntry(part: part, depth: depth, path: path))
                walk(part.children, depth: depth + 1, trail: trail + [name])
            }
        }
        walk(books, depth: 0, trail: [])
        return entries
    }

    /// Adds a part as the last child of `parentID` (a book at the top when nil). A level that doesn't fit below
    /// the parent is refused.
    @discardableResult
    mutating func addPart(_ level: StoryPartLevel, under parentID: UUID?, title: String = "") -> StoryPart? {
        var part = StoryPart(level: level, title: title)
        guard let parentID else {
            guard level == .book else { return nil }
            books.append(part)
            return part
        }
        guard let parent = self.part(parentID), parent.level.child == level else { return nil }
        if level.hasTimeline, parent.timeline.scale != nil { part.timeline.scale = parent.timeline.scale }
        updatePart(parentID) { $0.children.append(part) }
        return part
    }

    /// Removes a part with everything below it; links to them go too.
    mutating func removePart(_ id: UUID) {
        guard let part = part(id) else { return }
        var removed: Set<UUID> = []
        func collect(_ part: StoryPart) {
            removed.insert(part.id)
            part.children.forEach(collect)
        }
        collect(part)
        func strip(_ parts: inout [StoryPart]) {
            parts.removeAll { $0.id == id }
            for index in parts.indices { strip(&parts[index].children) }
        }
        strip(&books)
        for index in purposes.indices {
            purposes[index].setupPartIDs.removeAll(where: removed.contains)
            purposes[index].payoffPartIDs.removeAll(where: removed.contains)
        }
        for index in figures.indices {
            for scene in figures[index].scenes.indices where figures[index].scenes[scene].partID.map(removed.contains) == true {
                figures[index].scenes[scene].partID = nil
            }
        }
    }

    /// Moves a part one place up (-1) or down (1) among its siblings.
    mutating func movePart(_ id: UUID, by offset: Int) {
        func move(_ parts: inout [StoryPart]) -> Bool {
            if let index = parts.firstIndex(where: { $0.id == id }) {
                let target = index + offset
                guard parts.indices.contains(target) else { return true }
                parts.swapAt(index, target)
                return true
            }
            for index in parts.indices where move(&parts[index].children) { return true }
            return false
        }
        _ = move(&books)
    }

    func canMovePart(_ id: UUID, by offset: Int) -> Bool {
        let siblings = parentID(of: id).flatMap { part($0)?.children } ?? books
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return false }
        return siblings.indices.contains(index + offset)
    }

    /// "Buch 2", "Akt II", "Kapitel 7" (counted through the whole book), "Abschnitt 7.2".
    func number(of id: UUID) -> String {
        let path = path(to: id)
        guard let part = path.last else { return "" }
        switch part.level {
        case .book:
            return "Buch \((books.firstIndex { $0.id == id } ?? 0) + 1)"
        case .act:
            let acts = path.first?.children ?? []
            return "Akt " + Self.roman((acts.firstIndex { $0.id == id } ?? 0) + 1)
        case .chapter:
            return "Kapitel \(chapterNumber(id, in: path.first))"
        case .section:
            let chapter = path.count >= 2 ? path[path.count - 2] : nil
            let index = (chapter?.children.firstIndex { $0.id == id } ?? 0) + 1
            return "Abschnitt \(chapter.map { chapterNumber($0.id, in: path.first) } ?? 0).\(index)"
        }
    }

    private func chapterNumber(_ id: UUID, in book: StoryPart?) -> Int {
        let chapters = (book?.children ?? []).flatMap(\.children)
        return (chapters.firstIndex { $0.id == id } ?? 0) + 1
    }

    /// "1", "II", "7", "7.2": the number without its word, for the navigator.
    func shortNumber(of id: UUID) -> String {
        number(of: id).split(separator: " ").last.map(String.init) ?? ""
    }

    /// The title, or the number while there is none.
    func displayTitle(of part: StoryPart) -> String {
        let title = part.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? number(of: part.id) : title
    }

    static func roman(_ number: Int) -> String {
        guard number > 0, number < 4000 else { return String(number) }
        let numerals: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                         (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = number
        var result = ""
        for (value, numeral) in numerals {
            while rest >= value {
                result += numeral
                rest -= value
            }
        }
        return result
    }

    var chapterCount: Int { allParts.filter { $0.part.level == .chapter }.count }
}

// MARK: - Timelines

extension StoryWorld {
    func timeline(of owner: TimelineOwner) -> StoryTimeline? {
        switch owner {
        case .world: timeline
        case .part(let id): part(id)?.timeline
        }
    }

    mutating func updateTimeline(_ owner: TimelineOwner, _ change: (inout StoryTimeline) -> Void) {
        switch owner {
        case .world: change(&timeline)
        case .part(let id): updatePart(id) { change(&$0.timeline) }
        }
    }

    /// The calendar a timeline counts in: its own, or the world's.
    func scale(of owner: TimelineOwner) -> TimelineScale {
        timeline(of: owner)?.scale ?? calendar
    }

    func title(of owner: TimelineOwner) -> String {
        switch owner {
        case .world: displayTitle
        case .part(let id): part(id).map(displayTitle(of:)) ?? ""
        }
    }

    /// Every timeline with something pinned on it.
    var timelineOwners: [TimelineOwner] {
        [.world] + allParts.filter { $0.part.level.hasTimeline }.map { .part($0.part.id) }
    }
}

// MARK: - Elements

extension StoryWorld {
    func element<E: StoryElement>(_ type: E.Type, _ id: UUID) -> E? {
        self[keyPath: E.collection].first { $0.id == id }
    }

    mutating func updateElement<E: StoryElement>(_ type: E.Type, _ id: UUID, _ change: (inout E) -> Void) {
        guard let index = self[keyPath: E.collection].firstIndex(where: { $0.id == id }) else { return }
        change(&self[keyPath: E.collection][index])
        self[keyPath: E.collection][index].updatedAt = Date()
    }

    @discardableResult
    mutating func addElement<E: StoryElement>(_ type: E.Type, name: String = "") -> E {
        var element = E()
        element.name = name
        self[keyPath: E.collection].append(element)
        return element
    }

    /// A new element of any kind; its link for the part or element that asked for it.
    mutating func addElement(_ kind: StoryElementKind, name: String = "") -> StoryRef {
        switch kind {
        case .event: addElement(StoryEvent.self, name: name).ref
        case .figure: addElement(StoryFigure.self, name: name).ref
        case .place: addElement(StoryPlace.self, name: name).ref
        case .reason: addElement(StoryReason.self, name: name).ref
        case .purpose: addElement(StoryPurpose.self, name: name).ref
        case .species: addElement(StorySpecies.self, name: name).ref
        case .fact: addElement(StoryFact.self, name: name).ref
        }
    }

    func count(of kind: StoryElementKind) -> Int {
        switch kind {
        case .event: events.count
        case .figure: figures.count
        case .place: places.count
        case .reason: reasons.count
        case .purpose: purposes.count
        case .species: species.count
        case .fact: facts.count
        }
    }

    /// Name and subtitle of every element of a kind, for lists and pickers that don't care about the type.
    func summaries(of kind: StoryElementKind) -> [(id: UUID, name: String, subtitle: String)] {
        func list<E: StoryElement>(_ elements: [E]) -> [(id: UUID, name: String, subtitle: String)] {
            elements.map { ($0.id, $0.displayName, $0.subtitle) }
        }
        switch kind {
        case .event: return list(events)
        case .figure: return list(figures)
        case .place: return list(places)
        case .reason: return list(reasons)
        case .purpose: return list(purposes)
        case .species: return list(species)
        case .fact: return list(facts)
        }
    }

    func name(of ref: StoryRef) -> String? {
        switch ref.kind {
        case .event: element(StoryEvent.self, ref.id)?.displayName
        case .figure: element(StoryFigure.self, ref.id)?.displayName
        case .place: element(StoryPlace.self, ref.id)?.displayName
        case .reason: element(StoryReason.self, ref.id)?.displayName
        case .purpose: element(StoryPurpose.self, ref.id)?.displayName
        case .species: element(StorySpecies.self, ref.id)?.displayName
        case .fact: element(StoryFact.self, ref.id)?.displayName
        }
    }

    func exists(_ ref: StoryRef) -> Bool { name(of: ref) != nil }

    /// Removes an element and every link to it: from the parts, the timelines and the other elements.
    mutating func removeElement(_ ref: StoryRef) {
        switch ref.kind {
        case .event: events.removeAll { $0.id == ref.id }
        case .figure: figures.removeAll { $0.id == ref.id }
        case .place: places.removeAll { $0.id == ref.id }
        case .reason: reasons.removeAll { $0.id == ref.id }
        case .purpose: purposes.removeAll { $0.id == ref.id }
        case .species: species.removeAll { $0.id == ref.id }
        case .fact: facts.removeAll { $0.id == ref.id }
        }
        let id = ref.id
        func forget(in parts: inout [StoryPart]) {
            for index in parts.indices {
                parts[index].focus.unlink(id, as: ref.kind)
                if ref.kind == .figure, parts[index].povFigureID == id { parts[index].povFigureID = nil }
                parts[index].timeline.entries.removeAll { $0.ref == ref }
                forget(in: &parts[index].children)
            }
        }
        forget(in: &books)
        timeline.entries.removeAll { $0.ref == ref }
        for index in figures.indices {
            figures[index].relations.removeAll { $0.target == ref }
        }
        for index in facts.indices {
            facts[index].links.removeAll { $0 == ref }
        }
        for index in events.indices {
            for consequence in events[index].consequences.indices {
                events[index].consequences[consequence].affected.removeAll { $0 == ref }
                if ref.kind == .event, events[index].consequences[consequence].followEventID == id {
                    events[index].consequences[consequence].followEventID = nil
                }
            }
        }
        switch ref.kind {
        case .figure:
            for index in places.indices { places[index].residentIDs.removeAll { $0 == id } }
            for index in events.indices {
                events[index].figureIDs.removeAll { $0 == id }
                events[index].knownByIDs.removeAll { $0 == id }
            }
            for index in reasons.indices where reasons[index].holderID == id { reasons[index].holderID = nil }
        case .place:
            for index in places.indices where places[index].parentID == id { places[index].parentID = nil }
            for index in events.indices { events[index].placeIDs.removeAll { $0 == id } }
            for index in species.indices { species[index].habitatPlaceIDs.removeAll { $0 == id } }
        case .event:
            for index in events.indices { events[index].causeEventIDs.removeAll { $0 == id } }
        case .species:
            for index in figures.indices where figures[index].speciesID == id { figures[index].speciesID = nil }
        case .reason, .purpose, .fact:
            break
        }
    }

    /// The files an element keeps in the library: pictures, and a figure's videos.
    func media(of ref: StoryRef) -> (images: [StoryImage], videos: [StoryVideo]) {
        switch ref.kind {
        case .figure:
            let figure = element(StoryFigure.self, ref.id)
            return (figure?.images ?? [], figure?.videos ?? [])
        case .place: return (element(StoryPlace.self, ref.id)?.images ?? [], [])
        case .species: return (element(StorySpecies.self, ref.id)?.images ?? [], [])
        case .fact: return (element(StoryFact.self, ref.id)?.images ?? [], [])
        case .event, .reason, .purpose: return ([], [])
        }
    }

    /// The gallery pictures of a part and everything below it.
    func galleryImages(within partID: UUID) -> [StoryImage] {
        func collect(_ part: StoryPart) -> [StoryImage] { part.gallery + part.children.flatMap(collect) }
        return part(partID).map(collect) ?? []
    }

    /// The figures that belong to a species.
    func figures(ofSpecies speciesID: UUID) -> [StoryFigure] {
        figures.filter { $0.speciesID == speciesID }
    }

    /// Facts that are linked to an element.
    func facts(about ref: StoryRef) -> [StoryFact] {
        facts.filter { $0.links.contains(ref) }
    }

    /// Every tag the facts use, with how often, most used first.
    var factTags: [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for fact in facts {
            for tag in fact.tags {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.tag ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// The parts (and timelines) that use an element, in reading order.
    func usages(of ref: StoryRef) -> [StoryUsage] {
        var usages: [StoryUsage] = []
        if timeline.entries.contains(where: { $0.ref == ref }) { usages.append(StoryUsage(partID: nil, role: .timeline)) }
        for entry in allParts {
            let part = entry.part
            if part.focus.ids(ref.kind).contains(ref.id) { usages.append(StoryUsage(partID: part.id, role: .focus(ref.kind))) }
            if ref.kind == .figure, part.povFigureID == ref.id { usages.append(StoryUsage(partID: part.id, role: .pointOfView)) }
            if part.timeline.entries.contains(where: { $0.ref == ref }) { usages.append(StoryUsage(partID: part.id, role: .timeline)) }
        }
        if ref.kind == .purpose, let purpose = element(StoryPurpose.self, ref.id) {
            usages += purpose.setupPartIDs.map { StoryUsage(partID: $0, role: .setup) }
            usages += purpose.payoffPartIDs.map { StoryUsage(partID: $0, role: .payoff) }
        }
        return usages
    }

    /// Where an element sits on the timelines, for its page.
    func pins(of ref: StoryRef) -> [(owner: TimelineOwner, entry: TimelineEntry)] {
        timelineOwners.flatMap { owner in
            (timeline(of: owner)?.entries(of: ref) ?? []).map { (owner, $0) }
        }
    }

    /// Figures' relations that point at this element: how others stand towards it.
    func incomingRelations(to ref: StoryRef) -> [(figure: StoryFigure, relation: StoryRelation)] {
        figures.flatMap { figure in
            figure.relations.filter { $0.target == ref }.map { (figure, $0) }
        }
    }

    /// Events that lead to this one: named as its causes, or whose consequences turn into it.
    func causes(of eventID: UUID) -> [StoryEvent] {
        guard let event = element(StoryEvent.self, eventID) else { return [] }
        let named = event.causeEventIDs.compactMap { element(StoryEvent.self, $0) }
        let leading = events.filter { other in
            other.id != eventID && !event.causeEventIDs.contains(other.id) && other.consequences.contains { $0.followEventID == eventID }
        }
        return named + leading
    }

    /// Events this one leads to.
    func followers(of eventID: UUID) -> [StoryEvent] {
        guard let event = element(StoryEvent.self, eventID) else { return [] }
        var seen = Set<UUID>()
        let viaConsequences = event.consequences.compactMap(\.followEventID).filter { seen.insert($0).inserted }
        let naming = events.filter { $0.causeEventIDs.contains(eventID) && !seen.contains($0.id) }.map(\.id)
        return (viaConsequences + naming).compactMap { element(StoryEvent.self, $0) }
    }

    /// Places below this one.
    func subplaces(of placeID: UUID) -> [StoryPlace] {
        places.filter { $0.parentID == placeID }
    }

    /// "Westeros › Der Norden › Winterfell".
    func placePath(_ placeID: UUID) -> String {
        var names: [String] = []
        var current: UUID? = placeID
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted, let place = element(StoryPlace.self, id) {
            names.insert(place.displayName, at: 0)
            current = place.parentID
        }
        return names.joined(separator: " › ")
    }

    /// Places that may become the parent of `placeID`: not itself and not one that lies within it.
    func possibleParents(of placeID: UUID) -> [StoryPlace] {
        places.filter { candidate in
            var current: UUID? = candidate.id
            var seen = Set<UUID>()
            while let id = current, seen.insert(id).inserted {
                if id == placeID { return false }
                current = element(StoryPlace.self, id)?.parentID
            }
            return true
        }
    }
}
