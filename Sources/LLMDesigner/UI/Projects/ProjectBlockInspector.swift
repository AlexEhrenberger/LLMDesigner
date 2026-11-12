import SwiftUI

/// Everything about one block: its heading, its text style, and what it shows.
struct ProjectBlockInspector: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let blockID: UUID

    var body: some View {
        if let project = app.projects.project(projectID), let block = project.block(blockID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: block.kind.symbol)
                            .foregroundStyle(project.accent.color)
                        Text(block.kind.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    if block.kind != .text {
                        section("Überschrift") {
                            TextField(block.headline.isEmpty ? "Ohne Überschrift" : block.headline, text: app.projects.draftBinding(projectID, field: "titel.\(blockID)", get: { $0.block(blockID)?.title }, set: { project, title in
                                project.updateBlock(blockID) { $0.title = title }
                            }))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    content(block, project: project)
                    if [.text, .sticky, .metric].contains(block.kind) {
                        textStyle(block, project: project)
                    }
                    if ![.text, .sticky].contains(block.kind) {
                        section(block.kind == .metric || block.kind == .countdown ? "Farbe" : "Rahmenfarbe") {
                            ProjectColorRow(selection: block.tint) { color in change("Farbe ändern") { $0.tint = color } }
                        }
                    }
                    Text("Größe: \(block.frame.width) von 12 Spalten, \(block.frame.height) Zeilen")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
            }
            .frame(width: 400)
            .frame(maxHeight: 560)
        }
    }

    private func change(_ label: String, _ edit: @escaping (inout ProjectBlock) -> Void) {
        app.projects.change(projectID, label, undo: undoManager) { $0.updateBlock(blockID, edit) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    // MARK: Text style

    private func textStyle(_ block: ProjectBlock, project: Project) -> some View {
        let style = block.style
        return section("Schrift") {
            HStack(spacing: 8) {
                Menu {
                    Toggle("Wie die Seite (\(project.design.font.label))", isOn: Binding(get: { style.font == nil }, set: { _ in change("Schrift ändern") { $0.style.font = nil } }))
                    ForEach(WriterFont.Group.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(WriterFont.allCases.filter { $0.group == group }) { font in
                                Toggle(font.label, isOn: Binding(get: { style.font == font }, set: { _ in change("Schrift ändern") { $0.style.font = font } }))
                            }
                        }
                    }
                } label: {
                    Text(style.font?.label ?? (block.kind == .sticky ? "Handschrift" : "Wie die Seite"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 170)
                Stepper(value: Binding(get: { style.size ?? defaultSize(block) }, set: { size in change("Schriftgröße ändern") { $0.style.size = size } }), in: 8...96, step: 1) {
                    Text("\(Int(style.size ?? defaultSize(block))) pt")
                        .font(.system(size: 12).monospacedDigit())
                }
            }
            HStack(spacing: 4) {
                toggle("bold", "Fett", isOn: style.bold) { change("Fett") { $0.style.bold.toggle() } }
                toggle("italic", "Kursiv", isOn: style.italic) { change("Kursiv") { $0.style.italic.toggle() } }
                Divider().frame(height: 18).padding(.horizontal, 4)
                ForEach(ProjectTextAlignment.allCases) { alignment in
                    toggle(alignment.symbol, alignment.title, isOn: style.alignment == alignment) { change("Ausrichtung ändern") { $0.style.alignment = alignment } }
                }
                Spacer()
                if !style.isPlain {
                    Button("Zurücksetzen") { change("Format zurücksetzen") { $0.style = ProjectTextStyle() } }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            ProjectColorRow(selection: style.color) { color in change("Schriftfarbe ändern") { $0.style.color = color } }
        }
    }

    private func defaultSize(_ block: ProjectBlock) -> Double {
        switch block.kind {
        case .sticky: 15
        case .metric: 40
        default: 14
        }
    }

    private func toggle(_ symbol: String, _ help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Theme.accent.opacity(0.14) : Theme.ink.opacity(0.04)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ block: ProjectBlock, project: Project) -> some View {
        switch block.kind {
        case .progress:
            section("Was zählt") {
                Picker("", selection: Binding(get: { block.measure }, set: { measure in change("Zählweise ändern") { $0.measure = measure } })) {
                    ForEach(ProjectMeasure.progressCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if block.measure == .todos { listPicker(block, project: project, allowsAll: true) }
            }
            section("Anzeige") {
                ProjectProgressStylePicker(selection: block.progressStyle, project: project) { style in change("Anzeige ändern") { $0.progressStyle = style } }
            }
        case .metric:
            section("Kennzahl") {
                Picker("", selection: Binding(get: { block.measure }, set: { measure in change("Kennzahl ändern") { $0.measure = measure } })) {
                    ForEach(ProjectMeasure.metricCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if block.measure == .todos { listPicker(block, project: project, allowsAll: true) }
                if block.measure == .manual {
                    HStack {
                        TextField("Zahl", value: Binding(get: { block.value ?? 0 }, set: { value in change("Zahl ändern") { $0.value = value } }), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        TextField("Beschriftung", text: app.projects.draftBinding(projectID, field: "text.\(blockID)", get: { $0.block(blockID)?.text }, set: { project, text in project.updateBlock(blockID) { $0.text = text } }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        case .countdown:
            section("Zählt bis") {
                Toggle("Zum nächsten offenen Meilenstein", isOn: Binding(get: { block.date == nil }, set: { next in
                    change("Countdown ändern") { $0.date = next ? nil : ProjectDay.normalized(Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()) }
                }))
                if let date = block.date {
                    DatePicker("Datum", selection: Binding(get: { date }, set: { value in change("Datum ändern") { $0.date = ProjectDay.normalized(value) } }), displayedComponents: .date)
                    Text("Die Überschrift ist der Name des Termins.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        case .todos:
            section("Liste") {
                listPicker(block, project: project, allowsAll: false)
                Button("Neue Liste für diesen Baustein") {
                    app.projects.change(projectID, "ToDo-Liste anlegen", undo: undoManager) { project in
                        let list = ProjectTodoList(title: "ToDos \(project.todoLists.count + 1)")
                        project.todoLists.append(list)
                        project.updateBlock(blockID) { $0.listID = list.id }
                    }
                }
                .font(.system(size: 11.5))
            }
        case .sticky:
            section("Papier") {
                ProjectColorRow(selection: block.tint, allowsNone: false) { color in change("Farbe ändern") { $0.tint = color } }
            }
        case .chart:
            chartContent(block, project: project)
        default:
            EmptyView()
        }
    }

    private func listPicker(_ block: ProjectBlock, project: Project, allowsAll: Bool) -> some View {
        Picker("Liste", selection: Binding(get: { block.listID }, set: { id in change("Liste wählen") { $0.listID = id } })) {
            if allowsAll { Text("Alle Listen").tag(UUID?.none) }
            ForEach(project.todoLists) { Text($0.displayTitle).tag(Optional($0.id)) }
        }
    }

    // MARK: Charts

    @ViewBuilder
    private func chartContent(_ block: ProjectBlock, project: Project) -> some View {
        let chart = block.chart ?? ProjectChart()
        section("Diagramm") {
            Picker("Art", selection: Binding(get: { chart.kind }, set: { kind in
                change("Diagramm ändern") { block in
                    var new = ProjectChart(kind: kind, source: kind.sources.contains(chart.source) ? chart.source : nil)
                    new.entries = chart.entries
                    block.chart = new
                }
            })) {
                ForEach(ProjectChartKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            if chart.kind.sources.count > 1 {
                Picker("Daten", selection: Binding(get: { chart.source }, set: { source in change("Daten ändern") { $0.chart?.source = source } })) {
                    ForEach(chart.kind.sources) { Text($0.title).tag($0) }
                }
            }
        }
        if chart.source == .manual {
            section(chart.kind == .flow ? "Schritte" : (chart.kind == .gantt ? "Zeilen" : "Werte")) {
                ForEach(chart.entries) { entry in
                    entryRow(entry, kind: chart.kind)
                }
                Button {
                    change("Wert hinzufügen") { block in
                        let count = block.chart?.entries.count ?? 0
                        var entry = ProjectChartEntry(title: chart.kind == .flow ? "Schritt \(count + 1)" : "Wert \(count + 1)")
                        if chart.kind == .gantt {
                            entry.start = ProjectDay.normalized(Calendar.current.date(byAdding: .day, value: count * 7, to: Date()) ?? Date())
                            entry.end = Calendar.current.date(byAdding: .day, value: 6, to: entry.start ?? Date())
                        }
                        block.chart?.entries.append(entry)
                    }
                } label: {
                    Label(chart.kind == .flow ? "Schritt" : (chart.kind == .gantt ? "Zeile" : "Wert"), systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private func entryRow(_ entry: ProjectChartEntry, kind: ProjectChartKind) -> some View {
        let entryID = entry.id
        func edit(_ label: String, _ change: @escaping (inout ProjectChartEntry) -> Void) {
            self.change(label) { block in
                guard let index = block.chart?.entries.firstIndex(where: { $0.id == entryID }) else { return }
                change(&block.chart!.entries[index])
            }
        }
        return HStack(spacing: 6) {
            Menu {
                ForEach(FolderColor.allCases, id: \.self) { color in
                    Button { edit("Farbe ändern") { $0.color = color } } label: { Label { Text(color.name) } icon: { Image(nsImage: color.swatch) } }
                }
                Button("Automatisch") { edit("Farbe ändern") { $0.color = nil } }
            } label: {
                Circle().fill(entry.color?.color ?? Theme.textTertiary).frame(width: 12, height: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            TextField("Titel", text: app.projects.draftBinding(projectID, field: "wert.\(entryID)", get: { project in
                project.block(blockID)?.chart?.entries.first { $0.id == entryID }?.title
            }, set: { project, title in
                project.updateBlock(blockID) { block in
                    if let index = block.chart?.entries.firstIndex(where: { $0.id == entryID }) { block.chart!.entries[index].title = title }
                }
            }))
            .textFieldStyle(.roundedBorder)
            switch kind {
            case .gantt:
                ProjectDayButton(date: entry.start, placeholder: "Start", warnsWhenPast: false) { date in edit("Start ändern") { $0.start = date } }
                ProjectDayButton(date: entry.end, placeholder: "Ende", warnsWhenPast: false) { date in edit("Ende ändern") { $0.end = date } }
            case .flow:
                Picker("", selection: Binding(get: { entry.shape }, set: { shape in edit("Form ändern") { $0.shape = shape } })) {
                    ForEach(ProjectFlowShape.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Toggle("", isOn: Binding(get: { entry.isDone }, set: { done in edit("Schritt ändern") { $0.isDone = done } }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Erledigt")
            default:
                TextField("Wert", value: Binding(get: { entry.value }, set: { value in edit("Wert ändern") { $0.value = value } }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            IconButton(systemName: "minus.circle", help: "Entfernen", size: 11, frameSize: 20) {
                change("Wert entfernen") { $0.chart?.entries.removeAll { $0.id == entryID } }
            }
        }
    }
}
