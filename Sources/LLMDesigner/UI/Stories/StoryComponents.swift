import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Building blocks Stories Studio's pages share: colours of the five kinds, text areas, chips of linked elements,
// the picker that links or creates an element, the part menu and the picture gallery.

extension StoryElementKind {
    var color: Color {
        switch self {
        case .event: Theme.warning
        case .figure: Theme.accent
        case .place: Color(hex: 0x4FD1A5)
        case .reason: Color(hex: 0x6CB4FF)
        case .purpose: Color(hex: 0xFF8FB8)
        case .species: Color(hex: 0xC5E063)
        case .fact: Color(hex: 0xE3C08D)
        }
    }

    /// Kinds whose elements have pictures (the first is shown in lists).
    var hasPictures: Bool { self == .figure || self == .place || self == .species || self == .fact }
}

// MARK: - Bindings

// Text goes through drafts (see StoryLibrary), so typing doesn't redraw the whole studio on every key; other
// values (menus, switches) change the world at once.

extension StoryLibrary {
    func binding<T>(_ worldID: UUID, _ keyPath: WritableKeyPath<StoryWorld, T>) -> Binding<T> {
        if T.self == String.self {
            return draftBinding(worldID, field: keyPath, fallback: StoryWorld()[keyPath: keyPath],
                                get: { $0[keyPath: keyPath] }, set: { $0[keyPath: keyPath] = $1 })
        }
        return Binding(
            get: { self.world(worldID)?[keyPath: keyPath] ?? StoryWorld()[keyPath: keyPath] },
            set: { value in self.update(worldID) { $0[keyPath: keyPath] = value } }
        )
    }

    func binding<E: StoryElement, T>(_ worldID: UUID, _ type: E.Type, _ id: UUID, _ keyPath: WritableKeyPath<E, T>) -> Binding<T> {
        if T.self == String.self {
            return draftBinding(worldID, field: [AnyHashable(id), AnyHashable(keyPath)], fallback: E()[keyPath: keyPath],
                                get: { $0.element(type, id)?[keyPath: keyPath] },
                                set: { world, value in world.updateElement(type, id) { $0[keyPath: keyPath] = value } })
        }
        return Binding(
            get: { self.world(worldID)?.element(type, id)?[keyPath: keyPath] ?? E()[keyPath: keyPath] },
            set: { value in self.update(worldID) { $0.updateElement(type, id) { $0[keyPath: keyPath] = value } } }
        )
    }

    func partBinding<T>(_ worldID: UUID, _ partID: UUID, _ keyPath: WritableKeyPath<StoryPart, T>) -> Binding<T> {
        if T.self == String.self {
            return draftBinding(worldID, field: [AnyHashable(partID), AnyHashable(keyPath)], fallback: StoryPart(level: .chapter)[keyPath: keyPath],
                                get: { $0.part(partID)?[keyPath: keyPath] },
                                set: { world, value in world.updatePart(partID) { $0[keyPath: keyPath] = value } })
        }
        return Binding(
            get: { self.world(worldID)?.part(partID)?[keyPath: keyPath] ?? StoryPart(level: .chapter)[keyPath: keyPath] },
            set: { value in self.update(worldID) { $0.updatePart(partID) { $0[keyPath: keyPath] = value } } }
        )
    }

    /// Text of something nested in an element (a relation's note, a scene, a consequence), found by `id`.
    func elementText<E: StoryElement>(_ worldID: UUID, _ type: E.Type, _ elementID: UUID, field: AnyHashable,
                                      get: @escaping (E) -> String?, set: @escaping (inout E, String) -> Void) -> Binding<String> {
        draftBinding(worldID, field: [AnyHashable(elementID), field], fallback: "",
                     get: { $0.element(type, elementID).flatMap(get) },
                     set: { world, text in world.updateElement(type, elementID) { set(&$0, text) } })
    }

    func updateElement<E: StoryElement>(_ worldID: UUID, _ type: E.Type, _ id: UUID, _ change: (inout E) -> Void) {
        update(worldID) { $0.updateElement(type, id, change) }
    }

    /// A new element, ready to be linked.
    func addElement(_ kind: StoryElementKind, name: String = "", in worldID: UUID) -> StoryRef {
        var ref = StoryRef(kind: kind, id: UUID())
        update(worldID) { ref = $0.addElement(kind, name: name) }
        return ref
    }
}

// MARK: - Fields

extension View {
    func storyField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A small heading above a field or a group.
struct StoryLabel: View {
    let title: String
    var hint: String?
    var symbol: String?
    var color: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if let hint {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .help(hint)
            }
        }
    }
}

/// A titled text area that grows with its text (from `lines.lowerBound` lines; the upper bound is no longer a
/// limit, the page scrolls instead).
struct StoryTextArea: View {
    let title: String
    var hint: String?
    var placeholder = ""
    @Binding var text: String
    var lines: ClosedRange<Int> = 2...14

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            StoryLabel(title: title, hint: hint)
            StoryTextEditor(placeholder: placeholder, text: $text, minLines: lines.lowerBound)
                .storyField()
        }
    }
}

/// A heading that divides a page into parts.
struct StorySectionTitle: View {
    let title: String
    var symbol: String?
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.top, 6)
    }
}

/// A card around a group of fields.
struct StoryCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((tint ?? .white).opacity(tint == nil ? 0.07 : 0.22)))
    }
}

/// Tabs of a page as a row of capsules. Where the room is short, only the chosen tab keeps its title, then none.
///
/// The page measures the room (it only changes with the window) and the variant is worked out from the titles'
/// widths. `ViewThatFits` did this by building and measuring all three variants in every layout pass, which made
/// each keystroke and click in the studio noticeably slower. The bar keeps its own size: stretched to the room
/// (to measure it from inside), or inside a scroll view, its tabs stopped taking clicks.
struct StoryTabBar<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String, symbol: String)]
    @Binding var selection: Tab
    /// The width the bar may take.
    let room: CGFloat

    var body: some View {
        bar(showsTitle: titleRule(selection: selection, room: room))
            .fixedSize()
    }

    /// The widest variant that fits: every title, the chosen one's, or none.
    private func titleRule(selection: Tab, room: CGFloat) -> (Tab) -> Bool {
        if width({ _ in true }) <= room { return { _ in true } }
        if width({ $0 == selection }) <= room { return { $0 == selection } }
        return { _ in false }
    }

    /// The bar's width for a variant: 10 pt padding each side of a tab, 16 pt for a symbol, 5 pt between symbol and
    /// title, 4 pt between tabs and 3 pt around the bar.
    private func width(_ showsTitle: (Tab) -> Bool) -> CGFloat {
        let tabsWidth = tabs.reduce(CGFloat(0)) { sum, item in
            sum + 20 + 16 + (showsTitle(item.tab) ? 5 + Self.titleWidth(item.title) : 0)
        }
        return tabsWidth + CGFloat(max(tabs.count - 1, 0)) * 4 + 6 + 4
    }

    private static func titleWidth(_ title: String) -> CGFloat { StoryTabTitleWidths.width(of: title) }

    private func bar(showsTitle: @escaping (Tab) -> Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { item in
                Button {
                    selection = item.tab
                } label: {
                    Group {
                        if showsTitle(item.tab) {
                            Label(item.title, systemImage: item.symbol)
                        } else {
                            Label(item.title, systemImage: item.symbol)
                                .labelStyle(.iconOnly)
                        }
                    }
                    .font(.system(size: 12, weight: selection == item.tab ? .semibold : .regular))
                    .foregroundStyle(selection == item.tab ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(selection == item.tab ? Theme.selection : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.03)))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// The widths of tab titles, measured once each.
@MainActor
private enum StoryTabTitleWidths {
    static var known: [String: CGFloat] = [:]

    static func width(of title: String) -> CGFloat {
        if let width = known[title] { return width }
        let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
        known[title] = width
        return width
    }
}

/// A delete button that asks first.
struct StoryDeleteButton: View {
    let title: String
    var message = ""
    let action: () -> Void
    @State private var asks = false

    var body: some View {
        IconButton(systemName: "trash", help: "Löschen", size: 12.5, frameSize: 26) { asks = true }
            .confirmationDialog(title, isPresented: $asks) {
                Button("Löschen", role: .destructive, action: action)
            } message: {
                Text(message)
            }
    }
}

// MARK: - Linked elements

/// A linked element: a click opens it, the cross removes the link.
struct StoryElementChip: View {
    let kind: StoryElementKind
    let name: String
    var detail: String?
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(kind.color)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Verknüpfung lösen")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 9 : 7)
        .frame(height: 24)
        .background(Capsule().fill(kind.color.opacity(hovering ? 0.2 : 0.12)))
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.3)))
        .contentShape(Capsule())
        .onTapGesture { onOpen?() }
        .onHover { hovering = $0 }
        .help(onOpen == nil ? name : "\(name) öffnen")
    }
}

/// Chips for linked elements of a world, with the picker to add more.
struct StoryLinkList: View {
    let kinds: [StoryElementKind]
    let refs: [StoryRef]
    let world: StoryWorld
    let library: StoryLibrary
    let model: StoriesStudioModel
    var addLabel = "Verknüpfen"
    let onChange: ([StoryRef]) -> Void

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(refs, id: \.self) { ref in
                if let name = world.name(of: ref) {
                    StoryElementChip(kind: ref.kind, name: name, onOpen: { model.show(ref) }) {
                        onChange(refs.filter { $0 != ref })
                    }
                }
            }
            StoryElementPickerButton(kinds: kinds, world: world, library: library, excluded: Set(refs), label: addLabel) { ref in
                onChange(refs + [ref])
            }
        }
    }
}

extension StoryLinkList {
    /// Links of one kind given as ids.
    init(kind: StoryElementKind, ids: [UUID], world: StoryWorld, library: StoryLibrary, model: StoriesStudioModel,
         addLabel: String = "Verknüpfen", onChange: @escaping ([UUID]) -> Void) {
        self.init(kinds: [kind], refs: ids.map { StoryRef(kind: kind, id: $0) }, world: world, library: library, model: model,
                  addLabel: addLabel) { refs in onChange(refs.map(\.id)) }
    }
}

/// "+ Verknüpfen": a popover that finds an element by typing or makes a new one with the typed name.
struct StoryElementPickerButton: View {
    let kinds: [StoryElementKind]
    let world: StoryWorld
    let library: StoryLibrary
    var excluded: Set<StoryRef> = []
    var label = "Verknüpfen"
    var compact = false
    let onPick: (StoryRef) -> Void
    @State private var shows = false

    var body: some View {
        Button {
            shows = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                if !compact {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            StoryElementPicker(kinds: kinds, world: world, library: library, excluded: excluded) { ref in
                shows = false
                onPick(ref)
            }
        }
    }
}

private struct StoryElementPicker: View {
    let kinds: [StoryElementKind]
    let world: StoryWorld
    let library: StoryLibrary
    let excluded: Set<StoryRef>
    let onPick: (StoryRef) -> Void
    @State private var query = ""
    @State private var kind: StoryElementKind
    @FocusState private var focused: Bool

    init(kinds: [StoryElementKind], world: StoryWorld, library: StoryLibrary, excluded: Set<StoryRef>, onPick: @escaping (StoryRef) -> Void) {
        self.kinds = kinds
        self.world = world
        self.library = library
        self.excluded = excluded
        self.onPick = onPick
        _kind = State(initialValue: kinds.first ?? .figure)
    }

    private var matches: [(id: UUID, name: String, subtitle: String)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return world.summaries(of: kind)
            .filter { !excluded.contains(StoryRef(kind: kind, id: $0.id)) }
            .filter { item in words.allSatisfy { (item.name + " " + item.subtitle).lowercased().contains($0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let matches = matches
        let typed = query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 8) {
            if kinds.count > 1 {
                Picker("", selection: $kind) {
                    ForEach(kinds) { kind in Text(kind.singular).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            TextField("\(kind.singular) suchen oder neu anlegen …", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = matches.first {
                        onPick(StoryRef(kind: kind, id: first.id))
                    } else if !typed.isEmpty {
                        onPick(library.addElement(kind, name: typed, in: world.id))
                    }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches.prefix(60), id: \.id) { item in
                        Button {
                            onPick(StoryRef(kind: kind, id: item.id))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: kind.symbol)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(kind.color)
                                    .frame(width: 16)
                                Text(item.name)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StoryRowButtonStyle())
                    }
                    if matches.isEmpty, typed.isEmpty {
                        Text(world.count(of: kind) == 0 ? "Noch keine \(kind.title)." : "Alle \(kind.title) sind schon verknüpft.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(8)
                    }
                }
            }
            .frame(height: min(CGFloat(max(matches.count, 1)) * 27 + 4, 240))
            Divider()
            Button {
                onPick(library.addElement(kind, name: typed, in: world.id))
            } label: {
                Label(typed.isEmpty ? "Neue:n \(kind.singular) anlegen" : "„\(typed)“ als \(kind.singular) anlegen", systemImage: "plus.circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { focused = true }
    }
}

/// A list row that lights up under the pointer.
struct StoryRowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        StoryRow(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }

    private struct StoryRow<Label: View>: View {
        let selected: Bool
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false

        var body: some View {
            label()
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.selection : (hovering || pressed ? Theme.hover : .clear)))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Parts

/// A menu of all parts of the world, indented by level.
struct StoryPartMenu<Label: View>: View {
    let world: StoryWorld
    var excluded: Set<UUID> = []
    var allowsNone = false
    let onPick: (UUID?) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if allowsNone {
                Button("Keinem Teil zugeordnet") { onPick(nil) }
                Divider()
            }
            if world.books.isEmpty {
                Text("Noch keine Bücher")
            }
            ForEach(world.allParts.filter { !excluded.contains($0.id) }) { entry in
                Button {
                    onPick(entry.id)
                } label: {
                    Text(String(repeating: "    ", count: entry.depth) + world.displayTitle(of: entry.part))
                }
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A part shown as a chip that opens it.
struct StoryPartChip: View {
    let world: StoryWorld
    let partID: UUID
    let model: StoriesStudioModel
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let part = world.part(partID) {
            HStack(spacing: 5) {
                Image(systemName: part.level.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(world.displayTitle(of: part))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !part.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(world.number(of: partID))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.09 : 0.055)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
            .onTapGesture { model.showPart(partID, in: world) }
            .onHover { hovering = $0 }
            .help(world.path(to: partID).map { world.displayTitle(of: $0) }.joined(separator: " › "))
        }
    }
}

// MARK: - Where it is used

/// The parts and timelines that use an element; a click opens them.
struct StoryUsageList: View {
    let ref: StoryRef
    let world: StoryWorld
    let model: StoriesStudioModel

    var body: some View {
        let usages = world.usages(of: ref)
        VStack(alignment: .leading, spacing: 6) {
            StoryLabel(title: "Vorkommen in der Geschichte", symbol: "text.book.closed")
            if usages.isEmpty {
                Text("Noch mit keinem Buch, Akt, Kapitel oder Abschnitt verknüpft und auf keiner Timeline.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(usages) { usage in
                Button {
                    if let partID = usage.partID {
                        model.showPart(partID, in: world, tab: usage.role == .timeline ? .timeline : .content)
                    } else {
                        model.page = .overview
                        model.partTab = .timeline
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(usage.label)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(ref.kind.color)
                            .frame(width: 76, alignment: .leading)
                        Text(usage.partID.map { id in world.path(to: id).map { world.displayTitle(of: $0) }.joined(separator: " › ") }
                             ?? "Timeline der Romanwelt")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StoryRowButtonStyle())
            }
        }
    }
}

/// Where an element sits on the timelines (an event's span, a figure's points).
struct StoryPinList: View {
    let ref: StoryRef
    let world: StoryWorld
    let model: StoriesStudioModel

    var body: some View {
        let pins = world.pins(of: ref)
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                StoryLabel(title: "Auf den Timelines", symbol: "calendar.day.timeline.left")
                ForEach(pins, id: \.entry.id) { pin in
                    Button {
                        switch pin.owner {
                        case .world:
                            model.page = .overview
                            model.partTab = .timeline
                        case .part(let id):
                            model.showPart(id, in: world, tab: .timeline)
                        }
                        model.selectedEntryID = pin.entry.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: pin.entry.isSpan ? "rectangle.fill" : "diamond.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(ref.kind.color)
                            Text(world.title(of: pin.owner))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(world.scale(of: pin.owner).describe(start: pin.entry.start, end: pin.entry.end))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                            if !pin.entry.note.isEmpty {
                                Text(pin.entry.note)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StoryRowButtonStyle())
                }
            }
        }
    }
}

// MARK: - Pictures

/// The pictures of a figure or place: the first one is its portrait. New ones are copied into the library.
struct StoryImageGallery: View {
    let worldID: UUID
    let images: [StoryImage]
    let library: StoryLibrary
    let onChange: ([StoryImage]) -> Void
    @State private var targeted = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images, id: \.fileName) { image in
                    tile(image)
                }
                Button(action: choose) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20, weight: .light))
                        Text(images.isEmpty ? "Bilder hinzufügen" : "Weiteres Bild")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(targeted ? Theme.accent : Theme.textTertiary)
                    .frame(width: 120, height: 120)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Bilder auswählen oder hierher ziehen – sie werden in die Bibliothek kopiert.")
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
    }

    private func tile(_ image: StoryImage) -> some View {
        let isPortrait = image == images.first
        return ZStack(alignment: .bottomLeading) {
            StoryThumbnail(image: image, worldID: worldID, library: library, fill: true) {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 120, height: 120)
            .clipped()
            if isPortrait, images.count > 1 {
                Text("Hauptbild")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(6)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(library.imageURL(image, in: worldID)) }
        .help("Doppelklick öffnet das Bild")
        .contextMenu {
            if !isPortrait {
                Button("Als Hauptbild") { onChange([image] + images.filter { $0 != image }) }
            }
            Button("Öffnen") { NSWorkspace.shared.open(library.imageURL(image, in: worldID)) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([library.imageURL(image, in: worldID)]) }
            Divider()
            Button("Bild entfernen", role: .destructive) {
                onChange(images.filter { $0 != image })
                library.removeImage(image, in: worldID)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let added = library.importImages(urls, into: worldID)
        guard !added.isEmpty else { return }
        onChange(images + added)
    }
}

/// The portrait in lists: the first picture, or the kind's symbol.
struct StoryAvatar: View {
    let kind: StoryElementKind
    let image: StoryImage?
    let worldID: UUID
    let library: StoryLibrary
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image {
                StoryThumbnail(image: image, worldID: worldID, library: library, fill: true) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(kind.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(kind.color.opacity(0.14))
    }
}

/// A picture of the library, made small off the main thread; the placeholder shows until it is there.
struct StoryThumbnail<Placeholder: View>: View {
    let image: StoryImage
    let worldID: UUID
    let library: StoryLibrary
    /// Fill the frame (cut off what doesn't fit) rather than fit into it.
    var fill = false
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let shown = loaded ?? library.cachedThumbnail(image, in: worldID) {
                if fill {
                    Image(nsImage: shown).resizable().scaledToFill()
                } else {
                    Image(nsImage: shown).resizable().scaledToFit()
                }
            } else {
                placeholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: image.fileName) {
            loaded = await library.loadThumbnail(image, in: worldID)
        }
    }
}
