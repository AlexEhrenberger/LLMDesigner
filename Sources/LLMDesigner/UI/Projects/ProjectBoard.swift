import SwiftUI

/// The tasks of a project as a Kanban board: columns of the person's own, cards to drag between them, and the open
/// card in a panel beside the board.
struct ProjectBoard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    @Binding var selectedTask: UUID?
    @State private var query = ""
    @State private var onlyBlocked = false
    @State private var width: CGFloat = 1200

    private var panelFloats: Bool { width < 980 }

    var body: some View {
        if let project = app.projects.project(projectID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar(project)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(project.columns) { column in
                                ProjectBoardColumn(projectID: projectID, column: column, project: project, query: query, onlyBlocked: onlyBlocked, selectedTask: $selectedTask)
                            }
                            addColumnButton
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !panelFloats, let id = selectedTask, project.task(id) != nil {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    ProjectTaskPanel(projectID: projectID, taskID: id) { selectedTask = nil }
                        .frame(width: 400)
                        .transition(.move(edge: .trailing))
                }
            }
            .overlay(alignment: .trailing) {
                if panelFloats, let id = selectedTask, project.task(id) != nil {
                    ProjectTaskPanel(projectID: projectID, taskID: id) { selectedTask = nil }
                        .frame(width: min(400, width - 40))
                        .background(Theme.sidebar)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                        .shadow(color: Theme.shade.opacity(0.3), radius: 20)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.smooth(duration: 0.25), value: selectedTask)
            .background(LinearGradient(colors: [project.accent.color.opacity(0.06), Theme.background], startPoint: .top, endPoint: .bottom))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .tint(project.accent.color)
        }
    }

    private func toolbar(_ project: Project) -> some View {
        let open = project.tasks.filter { !project.isFinished($0) }
        let blocked = open.filter(\.isBlocked).count
        let acceptable = open.filter(\.isAcceptable).count
        return HStack(spacing: 10) {
            SearchField(text: $query, prompt: "Aufgaben durchsuchen")
                .frame(maxWidth: 260)
            Button {
                onlyBlocked.toggle()
            } label: {
                Label(blocked == 1 ? "1 mit Hindernis" : "\(blocked) mit Hindernis", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(onlyBlocked ? Color.white : (blocked > 0 ? Theme.warning : Theme.textTertiary))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(onlyBlocked ? Theme.warning : Theme.warning.opacity(blocked > 0 ? 0.12 : 0.04)))
            }
            .buttonStyle(.plain)
            .help(onlyBlocked ? "Alle Aufgaben zeigen" : "Nur Aufgaben zeigen, die ein Hindernis haben")
            if acceptable > 0 && width > 820 {
                Label(acceptable == 1 ? "1 abnahmebereit" : "\(acceptable) abnahmebereit", systemImage: "checkmark.seal")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.success)
                    .help("Alle Akzeptanzkriterien erfüllt, aber noch nicht in einer erledigten Spalte")
            }
            Spacer()
            Text("\(project.tasks.count - open.count) von \(project.tasks.count) erledigt")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var addColumnButton: some View {
        Button {
            app.projects.change(projectID, "Spalte anlegen", undo: undoManager) { project in
                // A new column goes before the done columns, where work usually is added.
                let index = project.columns.firstIndex(where: \.isDone) ?? project.columns.count
                project.columns.insert(ProjectColumn(title: "Neue Spalte", color: Project.chartColors[project.columns.count % Project.chartColors.count]), at: index)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                Text("Spalte")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 120, height: 90)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Neue Spalte")
    }
}

// MARK: - Column

private struct ProjectBoardColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let column: ProjectColumn
    let project: Project
    let query: String
    let onlyBlocked: Bool
    @Binding var selectedTask: UUID?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var targeted = false
    @State private var adding = false
    @FocusState private var addFocused: Bool

    var body: some View {
        let all = project.tasks(in: column.id)
        let tasks = all.filter { $0.matches(query) && (!onlyBlocked || $0.isBlocked) }
        let color = column.color?.color ?? Theme.accent
        let over = column.limit.map { all.count > $0 } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9)
                if renaming {
                    TextField("Spalte", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .onSubmit { commitRename() }
                        .onExitCommand { renaming = false }
                } else {
                    Text(column.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { startRename() }
                }
                if column.isDone {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.success)
                        .help("Aufgaben in dieser Spalte gelten als erledigt")
                }
                Spacer(minLength: 0)
                Text(column.limit.map { "\(all.count)/\($0)" } ?? "\(all.count)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(over ? Theme.danger : Theme.textTertiary)
                    .help(over ? "Mehr Aufgaben als das Limit von \(column.limit ?? 0)" : "Aufgaben in dieser Spalte")
                columnMenu
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        ProjectTaskCard(projectID: projectID, task: task, project: project, isSelected: selectedTask == task.id) {
                            selectedTask = selectedTask == task.id ? nil : task.id
                        }
                    }
                    if adding {
                        TextField("Titel der Aufgabe", text: $newTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
                            .focused($addFocused)
                            .onSubmit { addTask(keepOpen: true) }
                            .onExitCommand { adding = false; newTitle = "" }
                            .onChange(of: addFocused) { _, focused in if !focused { addTask(keepOpen: false) } }
                    }
                    Button {
                        newTitle = ""
                        adding = true
                        addFocused = true
                    } label: {
                        Label("Aufgabe", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StoryRowButtonStyle())
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(targeted ? color.opacity(0.14) : Theme.ink.opacity(0.035)))
        .overlay(alignment: .top) {
            // The column's colour along its top edge.
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                .fill(color.opacity(0.7))
                .frame(height: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(targeted ? color.opacity(0.7) : Theme.border))
        .dropDestination(for: String.self) { items, _ in
            guard let id = ProjectDrag.taskID(in: items) else { return false }
            move(id, before: nil)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var columnMenu: some View {
        Menu {
            Button("Umbenennen", systemImage: "pencil") { startRename() }
            Menu("Farbe", systemImage: "paintpalette") {
                ForEach(FolderColor.allCases, id: \.self) { color in
                    Button { change("Spaltenfarbe ändern") { $0.color = color } } label: { Label { Text(color.name) } icon: { Image(nsImage: color.swatch) } }
                }
            }
            Toggle(isOn: Binding(get: { column.isDone }, set: { done in change(done ? "Als erledigt zählen" : "Nicht als erledigt zählen") { $0.isDone = done } })) {
                Label("Aufgaben hier gelten als erledigt", systemImage: "checkmark.seal")
            }
            Menu("Limit (WIP)", systemImage: "gauge.with.dots.needle.bottom.50percent") {
                Button("Kein Limit") { change("Limit ändern") { $0.limit = nil } }
                ForEach([1, 2, 3, 4, 5, 6, 8, 10], id: \.self) { limit in
                    Button("\(limit)") { change("Limit ändern") { $0.limit = limit } }
                }
            }
            Divider()
            Button("Nach links", systemImage: "arrow.left") { moveColumn(by: -1) }
                .disabled(project.columns.first?.id == column.id)
            Button("Nach rechts", systemImage: "arrow.right") { moveColumn(by: 1) }
                .disabled(project.columns.last?.id == column.id)
            Divider()
            Button("Spalte löschen", systemImage: "trash", role: .destructive) {
                app.projects.change(projectID, "Spalte löschen", undo: undoManager) { $0.removeColumn(column.id) }
            }
            .disabled(project.columns.count <= 1)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Spalte: umbenennen, Farbe, erledigt, Limit, verschieben, löschen")
    }

    private func change(_ label: String, _ edit: @escaping (inout ProjectColumn) -> Void) {
        app.projects.change(projectID, label, undo: undoManager) { project in
            if let index = project.columns.firstIndex(where: { $0.id == column.id }) { edit(&project.columns[index]) }
        }
    }

    private func moveColumn(by offset: Int) {
        app.projects.change(projectID, "Spalte verschieben", undo: undoManager) { project in
            guard let index = project.columns.firstIndex(where: { $0.id == column.id }) else { return }
            let target = index + offset
            guard project.columns.indices.contains(target) else { return }
            project.columns.swapAt(index, target)
        }
    }

    private func startRename() {
        newTitle = column.title
        renaming = true
    }

    private func commitRename() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        renaming = false
        newTitle = ""
        guard !title.isEmpty, title != column.title else { return }
        change("Spalte umbenennen") { $0.title = title }
    }

    private func addTask(keepOpen: Bool) {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        newTitle = ""
        if !keepOpen { adding = false }
        guard !title.isEmpty else { return }
        let task = ProjectTask(title: title, column: column.id)
        app.projects.change(projectID, "Aufgabe anlegen", undo: undoManager) { $0.tasks.append(task) }
    }

    private func move(_ id: UUID, before: UUID?) {
        guard let task = project.task(id) else { return }
        guard task.column != column.id || before != nil else { return }
        app.projects.change(projectID, "Aufgabe verschieben", undo: undoManager) { $0.moveTask(id, to: column.id, before: before) }
    }
}

// MARK: - Card

private struct ProjectTaskCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let task: ProjectTask
    let project: Project
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let done = project.isFinished(task)
        VStack(alignment: .leading, spacing: 7) {
            if !task.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(task.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ProjectTaskCard.tagColor(tag).color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(ProjectTaskCard.tagColor(tag).wash))
                    }
                }
            }
            Text(task.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(done ? Theme.textSecondary : Theme.textPrimary)
                .strikethrough(done, color: Theme.textTertiary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: task.priority.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(task.priority.color.color)
                    .help("Priorität: \(task.priority.title)")
                if let due = task.due {
                    Label(ProjectDay.label(due, short: true), systemImage: "calendar")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(!done && ProjectDay.days(until: due) < 0 ? Theme.danger : (!done && ProjectDay.days(until: due) <= 2 ? Theme.warning : Theme.textTertiary))
                        .help("Fällig \(ProjectDay.label(due)) – \(ProjectDay.countdown(due))")
                }
                if !task.criteria.isEmpty {
                    Label("\(task.criteriaMet)/\(task.criteria.count)", systemImage: task.isAcceptable ? "checkmark.seal.fill" : "checkmark.seal")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(task.isAcceptable ? Theme.success : Theme.textTertiary)
                        .help(task.isAcceptable ? "Alle Akzeptanzkriterien erfüllt: abnahmebereit" : "Akzeptanzkriterien erfüllt")
                }
                if task.isBlocked {
                    Label("\(task.openImpediments.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .help(task.openImpediments.map(\.text).joined(separator: "\n"))
                }
                if !task.links.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(task.links.prefix(3), id: \.self) { link in
                            Image(systemName: app.projectRefSymbol(link))
                                .font(.system(size: 9.5))
                        }
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .help(task.links.compactMap { app.projectRefTitle($0) }.joined(separator: "\n"))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated))
        .overlay(alignment: .leading) {
            if task.isBlocked && !done {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(Theme.warning)
                    .frame(width: 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.accent : (hovering ? Theme.strongBorder : Theme.border), lineWidth: isSelected ? 1.6 : 1))
        .overlay(alignment: .top) {
            if targeted {
                Capsule().fill(Theme.accent).frame(height: 3).offset(y: -6)
            }
        }
        .shadow(color: Theme.shade.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .draggable(ProjectDrag.payload(task.id)) {
            Text(task.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .padding(10)
                .frame(width: 240, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.elevated))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = ProjectDrag.taskID(in: items), id != task.id else { return false }
            app.projects.change(projectID, "Aufgabe verschieben", undo: undoManager) { $0.moveTask(id, to: task.column, before: task.id) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Menu("In Spalte", systemImage: "arrow.right.square") {
                ForEach(project.columns) { column in
                    Button(column.displayTitle) {
                        app.projects.change(projectID, "Aufgabe verschieben", undo: undoManager) { $0.moveTask(task.id, to: column.id) }
                    }
                    .disabled(column.id == task.column)
                }
            }
            Menu("Priorität", systemImage: "flag") {
                ForEach(ProjectPriority.allCases.reversed()) { priority in
                    Button(priority.title, systemImage: priority.symbol) {
                        app.projects.change(projectID, "Priorität ändern", undo: undoManager) { $0.updateTask(task.id) { $0.priority = priority } }
                    }
                }
            }
            Divider()
            Button("Aufgabe löschen", systemImage: "trash", role: .destructive) {
                app.projects.change(projectID, "Aufgabe löschen", undo: undoManager) { $0.tasks.removeAll { $0.id == task.id } }
            }
        }
    }

    /// Each tag keeps its colour wherever it shows.
    static func tagColor(_ tag: String) -> FolderColor {
        let sum = tag.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Project.chartColors[sum % Project.chartColors.count]
    }
}

// MARK: - Panel

/// One task in full: title, column, priority, dates, tags, description, acceptance criteria, impediments and links.
struct ProjectTaskPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let taskID: UUID
    let onClose: () -> Void
    @State private var newCriterion = ""
    @State private var newImpediment = ""
    @State private var tagText = ""

    var body: some View {
        if let project = app.projects.project(projectID), let task = project.task(taskID) {
            let library = app.projects
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    let column = project.column(task.column)
                    Circle().fill(column?.color?.color ?? Theme.accent).frame(width: 8, height: 8)
                    Text(column?.displayTitle ?? "")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    IconButton(systemName: "xmark", help: "Schließen", size: 11, frameSize: 24, action: onClose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        StoryTextEditor(placeholder: "Titel der Aufgabe",
                                        text: library.draftBinding(projectID, field: "aufgabe.\(taskID)", get: { $0.task(taskID)?.title }, set: { project, title in project.updateTask(taskID) { $0.title = title } }),
                                        font: .systemFont(ofSize: 18, weight: .semibold), singleLine: true)
                        facts(task, project: project)
                        acceptanceHint(task, project: project)
                        section("Beschreibung", symbol: "text.alignleft") {
                            StoryTextEditor(placeholder: "Worum es geht, was zu tun ist …",
                                            text: library.draftBinding(projectID, field: "beschreibung.\(taskID)", get: { $0.task(taskID)?.details }, set: { project, text in project.updateTask(taskID) { $0.details = text } }),
                                            minLines: 3)
                                .storyField()
                        }
                        criteria(task)
                        impediments(task)
                        links(task)
                        HStack {
                            Text("Angelegt \(task.createdAt.formatted(date: .abbreviated, time: .shortened)) · geändert \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button(role: .destructive) {
                                onClose()
                                library.change(projectID, "Aufgabe löschen", undo: undoManager) { $0.tasks.removeAll { $0.id == taskID } }
                            } label: {
                                Label("Löschen", systemImage: "trash")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.sidebar)
            .onAppear { tagText = task.tags.joined(separator: ", ") }
            .onChange(of: taskID) { _, _ in tagText = project.task(taskID)?.tags.joined(separator: ", ") ?? "" }
        }
    }

    private func change(_ label: String, _ edit: @escaping (inout ProjectTask) -> Void) {
        app.projects.change(projectID, label, undo: undoManager) { $0.updateTask(taskID, edit) }
    }

    private func section<Content: View>(_ title: String, symbol: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            content()
        }
    }

    private func facts(_ task: ProjectTask, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(project.columns) { column in
                        Button(column.displayTitle) {
                            app.projects.change(projectID, "Aufgabe verschieben", undo: undoManager) { $0.moveTask(taskID, to: column.id) }
                        }
                    }
                } label: {
                    Label(project.column(task.column)?.displayTitle ?? "Spalte", systemImage: "rectangle.split.3x1")
                }
                .fixedSize()
                Menu {
                    ForEach(ProjectPriority.allCases.reversed()) { priority in
                        Button(priority.title, systemImage: priority.symbol) { change("Priorität ändern") { $0.priority = priority } }
                    }
                } label: {
                    Label(task.priority.title, systemImage: task.priority.symbol)
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                ProjectDayButton(date: task.start, placeholder: "Start", symbol: "play", warnsWhenPast: false) { date in change("Start ändern") { $0.start = date } }
                ProjectDayButton(date: task.due, placeholder: "Fällig", warnsWhenPast: !project.isFinished(task)) { date in change("Fälligkeit ändern") { $0.due = date } }
                Spacer()
            }
            TextField("Etiketten, durch Komma getrennt", text: $tagText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(commitTags)
                .onChange(of: tagText) { _, text in if text.hasSuffix(",") { commitTags() } }
        }
    }

    private func commitTags() {
        let tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var unique: [String] = []
        for tag in tags where !unique.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) { unique.append(tag) }
        change("Etiketten ändern") { $0.tags = unique }
    }

    /// All criteria met but not yet in a done column: one click accepts it.
    @ViewBuilder
    private func acceptanceHint(_ task: ProjectTask, project: Project) -> some View {
        if task.isAcceptable, !project.isFinished(task), let done = project.columns.first(where: \.isDone) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                Text("Alle Akzeptanzkriterien sind erfüllt.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Abnehmen") {
                    app.projects.change(projectID, "Aufgabe abnehmen", undo: undoManager) { $0.moveTask(taskID, to: done.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.success)
                .controlSize(.small)
                .help("Nach „\(done.displayTitle)“ verschieben")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.success.opacity(0.1)))
        }
    }

    // MARK: Criteria

    private func criteria(_ task: ProjectTask) -> some View {
        section("Akzeptanzkriterien", symbol: "checkmark.seal", trailing: task.criteria.isEmpty ? nil : "\(task.criteriaMet) von \(task.criteria.count) erfüllt") {
            Text("Woran erkennst du, dass die Aufgabe abgenommen werden kann?")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            if !task.criteria.isEmpty {
                ProgressView(value: Double(task.criteriaMet), total: Double(task.criteria.count))
                    .tint(task.isAcceptable ? Theme.success : Theme.accent)
            }
            ForEach(task.criteria) { criterion in
                let criterionID = criterion.id
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        change(criterion.isMet ? "Kriterium offen" : "Kriterium erfüllt") { task in
                            if let index = task.criteria.firstIndex(where: { $0.id == criterionID }) { task.criteria[index].isMet.toggle() }
                        }
                    } label: {
                        Image(systemName: criterion.isMet ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(criterion.isMet ? Theme.success : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    StoryTextEditor(placeholder: "Kriterium",
                                    text: app.projects.draftBinding(projectID, field: "kriterium.\(criterionID)", get: { $0.task(taskID)?.criteria.first { $0.id == criterionID }?.text }, set: { project, text in
                                        project.updateTask(taskID) { task in if let index = task.criteria.firstIndex(where: { $0.id == criterionID }) { task.criteria[index].text = text } }
                                    }),
                                    font: .systemFont(ofSize: 12.5))
                    IconButton(systemName: "minus.circle", help: "Kriterium entfernen", size: 11, frameSize: 20) {
                        change("Kriterium entfernen") { $0.criteria.removeAll { $0.id == criterionID } }
                    }
                }
            }
            addField("Neues Kriterium, z. B. „Quellen geprüft“", text: $newCriterion) { text in
                change("Kriterium hinzufügen") { $0.criteria.append(ProjectCriterion(text: text)) }
            }
        }
    }

    // MARK: Impediments

    private func impediments(_ task: ProjectTask) -> some View {
        section("Hindernisse", symbol: "exclamationmark.triangle", trailing: task.impediments.isEmpty ? nil : "\(task.openImpediments.count) offen") {
            Text("Gibt es Hürden, und wie lassen sie sich beheben?")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            ForEach(task.impediments) { impediment in
                let impedimentID = impediment.id
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            change(impediment.isResolved ? "Hindernis offen" : "Hindernis behoben") { task in
                                if let index = task.impediments.firstIndex(where: { $0.id == impedimentID }) { task.impediments[index].isResolved.toggle() }
                            }
                        } label: {
                            Image(systemName: impediment.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(impediment.isResolved ? Theme.success : Theme.warning)
                        }
                        .buttonStyle(.plain)
                        .help(impediment.isResolved ? "Behoben – wieder öffnen" : "Als behoben markieren")
                        StoryTextEditor(placeholder: "Was hält auf?",
                                        text: app.projects.draftBinding(projectID, field: "hindernis.\(impedimentID)", get: { $0.task(taskID)?.impediments.first { $0.id == impedimentID }?.text }, set: { project, text in
                                            project.updateTask(taskID) { task in if let index = task.impediments.firstIndex(where: { $0.id == impedimentID }) { task.impediments[index].text = text } }
                                        }),
                                        font: .systemFont(ofSize: 12.5, weight: .medium), color: NSColor(impediment.isResolved ? Theme.textTertiary : Theme.textPrimary))
                        IconButton(systemName: "minus.circle", help: "Hindernis entfernen", size: 11, frameSize: 20) {
                            change("Hindernis entfernen") { $0.impediments.removeAll { $0.id == impedimentID } }
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        StoryTextEditor(placeholder: "Wie lässt es sich beheben?",
                                        text: app.projects.draftBinding(projectID, field: "loesung.\(impedimentID)", get: { $0.task(taskID)?.impediments.first { $0.id == impedimentID }?.solution }, set: { project, text in
                                            project.updateTask(taskID) { task in if let index = task.impediments.firstIndex(where: { $0.id == impedimentID }) { task.impediments[index].solution = text } }
                                        }),
                                        font: .systemFont(ofSize: 12), color: NSColor(Theme.textSecondary))
                    }
                    .padding(.leading, 22)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((impediment.isResolved ? Theme.success : Theme.warning).opacity(0.07)))
            }
            addField("Neues Hindernis, z. B. „Daten fehlen noch“", text: $newImpediment) { text in
                change("Hindernis hinzufügen") { $0.impediments.append(ProjectImpediment(text: text)) }
            }
        }
    }

    // MARK: Links

    private func links(_ task: ProjectTask) -> some View {
        section("Verknüpft", symbol: "link") {
            ForEach(task.links, id: \.self) { ref in
                ProjectRefTile(ref: ref, compact: true) {
                    app.unlink(ref, fromTask: taskID, in: projectID, undo: undoManager)
                }
            }
            ProjectLinkAddButton(title: "Chat, Dokument, Präsentation, Note oder Romanwelt verknüpfen", excluded: Set(task.links)) { ref in
                app.link(ref, toTask: taskID, in: projectID, undo: undoManager)
            }
        }
    }

    private func addField(_ prompt: String, text: Binding<String>, add: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit {
                    let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                    text.wrappedValue = ""
                    if !value.isEmpty { add(value) }
                }
        }
        .padding(.horizontal, 4)
    }
}
