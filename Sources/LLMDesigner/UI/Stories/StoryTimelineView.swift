import SwiftUI

/// The timeline of a world, book, act or chapter, laid out like a Gantt chart: one row per pinned figure, place
/// or event; points in time as diamonds, spans as bars. Marks are dragged to move, a bar's ends to resize it; a
/// double-click into a row pins that element there once more.
struct StoryTimelineView: View {
    let owner: TimelineOwner
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    /// nil: the zoom that fits the whole range into the window.
    @State private var pointsPerUnit: Double?
    @State private var magnifyBase: Double?
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragState?
    /// While dragging, the range stays as it was, so the axis doesn't move under the pointer.
    @State private var frozenRange: ClosedRange<Double>?
    @State private var showsCalendar = false

    private struct DragState {
        enum Mode { case move, start, end }
        var entryID: UUID
        var mode: Mode
        var start: Double
        var end: Double?
        var original: (start: Double, end: Double?)
    }

    private let labelWidth: CGFloat = 200
    private let rowHeight: CGFloat = 34
    private let groupHeight: CGFloat = 26
    private let axisHeight: CGFloat = 30

    private var timeline: StoryTimeline { world.timeline(of: owner) ?? StoryTimeline() }
    private var scale: TimelineScale { world.scale(of: owner) }

    private var range: ClosedRange<Double> {
        frozenRange ?? TimelineAxis.visibleRange(of: timeline.extent)
    }

    private var chartWidth: CGFloat { max(viewportWidth - labelWidth - 2, 200) }

    /// Room on the right for the names beside the last marks.
    private let labelRoom: CGFloat = 150

    private var fittedPointsPerUnit: Double {
        Double(max(chartWidth - labelRoom, 120)) / max(range.upperBound - range.lowerBound, 0.000_1)
    }

    private var zoom: Double { pointsPerUnit ?? fittedPointsPerUnit }

    private var step: Double { TimelineAxis.step(pointsPerUnit: zoom) }

    private func x(_ value: Double) -> CGFloat { CGFloat((value - range.lowerBound) * zoom) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.border).frame(height: 1)
            if timeline.entries.isEmpty {
                emptyState
            } else {
                chart
            }
            if let id = model.selectedEntryID, let entry = timeline.entries.first(where: { $0.id == id }) {
                Rectangle().fill(Theme.border).frame(height: 1)
                StoryTimelineInspector(entry: entry, owner: owner, world: world, model: model, library: library)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.day.timeline.left")
                .foregroundStyle(Theme.accent)
            Text("Timeline · \(world.title(of: owner))")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Button {
                showsCalendar = true
            } label: {
                Label(scale.unit.isEmpty ? "Kalender" : scale.unit + (scale.suffix.isEmpty ? "" : " · " + scale.suffix), systemImage: "calendar")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Wie diese Timeline zählt")
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                StoryCalendarEditor(owner: owner, world: world, library: library)
            }
            Spacer()
            StoryElementPickerButton(kinds: StoryElementKind.pinnable, world: world, library: library, label: "Anpinnen") { ref in
                pin(ref)
            }
            HStack(spacing: 2) {
                IconButton(systemName: "minus.magnifyingglass", help: "Verkleinern", size: 12, frameSize: 26) { setZoom(zoom / 1.5) }
                IconButton(systemName: "plus.magnifyingglass", help: "Vergrößern", size: 12, frameSize: 26) { setZoom(zoom * 1.5) }
                IconButton(systemName: "arrow.left.and.right.square", help: "Alles einpassen", size: 12, frameSize: 26) { pointsPerUnit = nil }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func setZoom(_ value: Double) {
        pointsPerUnit = min(max(value, fittedPointsPerUnit * 0.5), fittedPointsPerUnit * 400)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Noch nichts angepinnt")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Pinne Figuren, Orte und Events an diese Timeline. Events erscheinen als Zeitspanne wie in einem Gantt-Diagramm,\nFiguren und Orte als Zeitpunkte – beides lässt sich ziehen, dehnen und umwandeln.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            StoryElementPickerButton(kinds: StoryElementKind.pinnable, world: world, library: library, label: "Anpinnen") { ref in pin(ref) }
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chart

    private var groups: [(kind: StoryElementKind, refs: [StoryRef])] {
        let rows = timeline.rows.filter { world.exists($0) }
        return StoryElementKind.pinnable.compactMap { kind in
            let refs = rows.filter { $0.kind == kind }
            return refs.isEmpty ? nil : (kind, refs)
        }
    }

    private var chart: some View {
        let groups = groups
        let ticks = TimelineAxis.ticks(in: range, step: step)
        let width = max(CGFloat(chartWidth), CGFloat((range.upperBound - range.lowerBound) * zoom) + labelRoom)
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                labels(groups)
                    .frame(width: labelWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        axis(ticks)
                        ForEach(groups, id: \.kind) { group in
                            Color.clear.frame(height: groupHeight)
                            ForEach(group.refs, id: \.self) { ref in
                                row(ref)
                            }
                        }
                    }
                    .frame(width: width, alignment: .leading)
                    .background(alignment: .topLeading) { grid(ticks) }
                }
                .scrollIndicators(.visible)
            }
            .padding(.bottom, 16)
        }
        .gesture(MagnifyGesture()
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = zoom }
                setZoom((magnifyBase ?? zoom) * value.magnification)
            }
            .onEnded { _ in magnifyBase = nil })
    }

    private func labels(_ groups: [(kind: StoryElementKind, refs: [StoryRef])]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(scale.unit)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .frame(height: axisHeight, alignment: .center)
            ForEach(groups, id: \.kind) { group in
                HStack(spacing: 5) {
                    Image(systemName: group.kind.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(group.kind.title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(group.kind.color)
                .padding(.horizontal, 12)
                .frame(height: groupHeight, alignment: .bottom)
                ForEach(group.refs, id: \.self) { ref in
                    Button {
                        model.show(ref)
                    } label: {
                        HStack(spacing: 7) {
                            if ref.kind == .figure, let figure = world.element(StoryFigure.self, ref.id) {
                                StoryAvatar(kind: .figure, image: figure.images.first, worldID: world.id, library: library, size: 20)
                            } else {
                                Circle().fill(ref.kind.color).frame(width: 7, height: 7).padding(.horizontal, 6)
                            }
                            Text(world.name(of: ref) ?? "")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StoryRowButtonStyle())
                    .help("\(world.name(of: ref) ?? "") öffnen")
                    .contextMenu {
                        Button("Noch einmal anpinnen", systemImage: "pin") { pin(ref) }
                        Button("Von dieser Timeline lösen", systemImage: "pin.slash", role: .destructive) {
                            library.update(world.id) { $0.updateTimeline(owner) { $0.entries.removeAll { $0.ref == ref } } }
                        }
                    }
                }
            }
        }
    }

    private func axis(_ ticks: [Double]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                Text(scale.label(tick, step: step))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .offset(x: x(tick) + 4, y: 8)
            }
        }
        .frame(height: axisHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ ticks: [Double]) -> some View {
        Canvas { context, size in
            for tick in ticks {
                let position = x(tick)
                var path = Path()
                path.move(to: CGPoint(x: position, y: 4))
                path.addLine(to: CGPoint(x: position, y: size.height))
                context.stroke(path, with: .color(.white.opacity(abs(tick) < step / 1000 ? 0.16 : 0.06)), lineWidth: 1)
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: axisHeight))
            base.addLine(to: CGPoint(x: size.width, y: axisHeight))
            context.stroke(base, with: .color(.white.opacity(0.1)), lineWidth: 1)
        }
    }

    private func row(_ ref: StoryRef) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.015))
                .frame(height: rowHeight - 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    let value = TimelineAxis.snapped(range.lowerBound + Double(location.x) / zoom, to: TimelineAxis.snap(for: step))
                    addEntry(TimelineEntry(ref: ref, start: value, end: ref.kind == .event ? value + defaultSpan : nil))
                }
                .onTapGesture { model.selectedEntryID = nil }
            ForEach(timeline.entries(of: ref)) { entry in
                mark(entry)
            }
        }
        .frame(height: rowHeight)
        .help("Doppelklick pinnt \(world.name(of: ref) ?? "") hier noch einmal an")
    }

    // MARK: Marks

    private func shown(_ entry: TimelineEntry) -> (start: Double, end: Double?) {
        if let drag, drag.entryID == entry.id { return (drag.start, drag.end) }
        return (entry.start, entry.end)
    }

    @ViewBuilder
    private func mark(_ entry: TimelineEntry) -> some View {
        let values = shown(entry)
        let selected = model.selectedEntryID == entry.id
        let color = entry.ref.kind.color
        let name = world.name(of: entry.ref) ?? ""
        let tooltip = [name, scale.describe(start: values.start, end: values.end), entry.note].filter { !$0.isEmpty }.joined(separator: "\n")
        if let end = values.end {
            let width = max(x(end) - x(values.start), 10)
            let label = entry.note.isEmpty ? name : entry.note
            // A label that doesn't fit into its bar goes beside it.
            let fits = CGFloat(label.count) * 6.6 + 14 <= width
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(selected ? 0.5 : 0.28))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(selected ? 1 : 0.7), lineWidth: selected ? 1.5 : 1))
                .overlay(alignment: .leading) {
                    if fits {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(width: width, alignment: .leading)
                            .clipped()
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: 22)
                .overlay(alignment: .leading) {
                    if !fits {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: width + 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .leading) { handle(entry, mode: .start) }
                .overlay(alignment: .trailing) { handle(entry, mode: .end) }
                .contentShape(Rectangle())
                .gesture(dragGesture(entry, mode: .move))
                .onTapGesture { model.selectedEntryID = entry.id }
                .contextMenu { markMenu(entry) }
                .help(tooltip)
                .offset(x: x(values.start))
        } else {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(45))
                    .overlay(Rectangle().strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5).rotationEffect(.degrees(45)))
                    .frame(width: 16, height: 16)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(entry, mode: .move))
            .onTapGesture { model.selectedEntryID = entry.id }
            .contextMenu { markMenu(entry) }
            .help(tooltip)
            .offset(x: x(values.start) - 8)
        }
    }

    private func handle(_ entry: TimelineEntry, mode: DragState.Mode) -> some View {
        Color.clear
            .frame(width: 7, height: 22)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .highPriorityGesture(dragGesture(entry, mode: mode))
    }

    @ViewBuilder
    private func markMenu(_ entry: TimelineEntry) -> some View {
        Button("\(world.name(of: entry.ref) ?? "") öffnen", systemImage: "arrow.up.forward") { model.show(entry.ref) }
        if entry.isSpan {
            Button("In Zeitpunkt umwandeln", systemImage: "diamond") { update(entry.id) { $0.end = nil } }
        } else {
            Button("In Zeitspanne umwandeln", systemImage: "rectangle") { update(entry.id) { $0.end = $0.start + defaultSpan } }
        }
        Divider()
        Button("Entfernen", systemImage: "trash", role: .destructive) { remove(entry.id) }
    }

    private func dragGesture(_ entry: TimelineEntry, mode: DragState.Mode) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag?.entryID != entry.id {
                    frozenRange = range
                    drag = DragState(entryID: entry.id, mode: mode, start: entry.start, end: entry.end, original: (entry.start, entry.end))
                    model.selectedEntryID = entry.id
                }
                guard var state = drag else { return }
                let snap = TimelineAxis.snap(for: step)
                let delta = Double(value.translation.width) / zoom
                let original = state.original
                switch state.mode {
                case .move:
                    state.start = TimelineAxis.snapped(original.start + delta, to: snap)
                    state.end = original.end.map { $0 + (state.start - original.start) }
                case .start:
                    let limit = (original.end ?? original.start) - snap
                    state.start = min(TimelineAxis.snapped(original.start + delta, to: snap), limit)
                case .end:
                    let end = TimelineAxis.snapped((original.end ?? original.start) + delta, to: snap)
                    state.end = max(end, original.start + snap)
                }
                drag = state
            }
            .onEnded { _ in
                if let state = drag {
                    update(state.entryID) { entry in
                        entry.start = state.start
                        entry.end = state.end
                    }
                }
                drag = nil
                frozenRange = nil
            }
    }

    // MARK: Changes

    /// A tenth of what the timeline shows, rounded: the length of a new span.
    private var defaultSpan: Double {
        let extent = timeline.extent.map { $0.upperBound - $0.lowerBound } ?? 0
        return TimelineAxis.niceStep(atLeast: max(extent / 10, 1))
    }

    /// An element pinned after everything that is already on the timeline (an event as a span).
    private func pin(_ ref: StoryRef) {
        let start: Double
        if let extent = timeline.extent {
            start = TimelineAxis.snapped(extent.upperBound + defaultSpan / 2, to: TimelineAxis.snap(for: step))
        } else {
            start = 0
        }
        addEntry(TimelineEntry(ref: ref, start: start, end: ref.kind == .event ? start + defaultSpan : nil))
    }

    private func addEntry(_ entry: TimelineEntry) {
        library.update(world.id) { $0.updateTimeline(owner) { $0.entries.append(entry) } }
        model.selectedEntryID = entry.id
    }

    private func update(_ id: UUID, _ change: (inout TimelineEntry) -> Void) {
        library.update(world.id) { world in
            world.updateTimeline(owner) { timeline in
                if let index = timeline.entries.firstIndex(where: { $0.id == id }) { change(&timeline.entries[index]) }
            }
        }
    }

    private func remove(_ id: UUID) {
        if model.selectedEntryID == id { model.selectedEntryID = nil }
        library.update(world.id) { $0.updateTimeline(owner) { $0.entries.removeAll { $0.id == id } } }
    }
}

/// The selected mark: exact numbers, point or span, a note.
private struct StoryTimelineInspector: View {
    let entry: TimelineEntry
    let owner: TimelineOwner
    let world: StoryWorld
    let model: StoriesStudioModel
    let library: StoryLibrary

    private static let numberFormat = FloatingPointFormatStyle<Double>.number.grouping(.never).locale(Locale(identifier: "de_DE"))

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                chip
                times
                spanToggle
                note.frame(minWidth: 160)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    chip
                    Spacer(minLength: 0)
                    buttons
                }
                HStack(spacing: 12) {
                    times
                    spanToggle
                }
                note
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(Theme.surface)
    }

    private var chip: some View {
        StoryElementChip(kind: entry.ref.kind, name: world.name(of: entry.ref) ?? "", onOpen: { model.show(entry.ref) })
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize()
    }

    private var times: some View {
        HStack(spacing: 6) {
            Text(entry.isSpan ? "Von" : "Zeitpunkt")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            TextField("", value: binding(\.start), format: Self.numberFormat)
                .frame(width: 80)
                .storyField()
            if let end = entry.end {
                Text("bis")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                TextField("", value: Binding(get: { end }, set: { value in update { $0.end = max(value, $0.start) } }), format: Self.numberFormat)
                    .frame(width: 80)
                    .storyField()
            }
            Text(world.scale(of: owner).suffix)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }

    private var spanToggle: some View {
        Toggle("Zeitspanne", isOn: Binding(
            get: { entry.isSpan },
            set: { span in update { $0.end = span ? $0.start + 1 : nil } }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11.5))
        .fixedSize()
    }

    private var note: some View {
        TextField("Notiz – was hier geschieht", text: binding(\.note))
            .storyField()
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button {
                model.selectedEntryID = nil
                library.update(world.id) { $0.updateTimeline(owner) { $0.entries.removeAll { $0.id == entry.id } } }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Von der Timeline entfernen")
            Button {
                model.selectedEntryID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Auswahl aufheben")
        }
        .fixedSize()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TimelineEntry, T>) -> Binding<T> {
        Binding(
            get: { world.timeline(of: owner)?.entries.first { $0.id == entry.id }?[keyPath: keyPath] ?? entry[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout TimelineEntry) -> Void) {
        library.update(world.id) { world in
            world.updateTimeline(owner) { timeline in
                if let index = timeline.entries.firstIndex(where: { $0.id == entry.id }) { change(&timeline.entries[index]) }
            }
        }
    }
}

/// The calendar of one timeline: the world's, or one of its own (a chapter that counts in hours).
private struct StoryCalendarEditor: View {
    let owner: TimelineOwner
    let world: StoryWorld
    let library: StoryLibrary

    var body: some View {
        let own = owner == .world || world.timeline(of: owner)?.scale != nil
        VStack(alignment: .leading, spacing: 10) {
            Text("Kalender dieser Timeline")
                .font(.system(size: 13, weight: .semibold))
            if owner != .world {
                Toggle("Eigener Kalender", isOn: Binding(
                    get: { world.timeline(of: owner)?.scale != nil },
                    set: { on in library.update(world.id) { w in
                        let calendar = w.calendar
                        w.updateTimeline(owner) { $0.scale = on ? calendar : nil }
                    } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                if !own {
                    Text("Zählt wie die Romanwelt: \(world.calendar.unit)\(world.calendar.suffix.isEmpty ? "" : " · " + world.calendar.suffix)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if own {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Einheit").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField("Jahr, Tag, Stunde", text: binding(\.unit)).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Zusatz").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField("n. A. E.", text: binding(\.suffix)).textFieldStyle(.roundedBorder)
                    }
                }
                Text("Beispiel: \(world.scale(of: owner).describe(start: 3, end: 5))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func binding(_ keyPath: WritableKeyPath<TimelineScale, String>) -> Binding<String> {
        Binding(
            get: { world.scale(of: owner)[keyPath: keyPath] },
            set: { value in
                library.update(world.id) { w in
                    if owner == .world {
                        w.calendar[keyPath: keyPath] = value
                    } else {
                        let current = w.scale(of: owner)
                        w.updateTimeline(owner) { timeline in
                            var scale = timeline.scale ?? current
                            scale[keyPath: keyPath] = value
                            timeline.scale = scale
                        }
                    }
                }
            }
        )
    }
}
