import SwiftUI

/// What a block shows, by its kind.
struct ProjectBlockContent: View {
    let projectID: UUID
    let block: ProjectBlock
    let project: Project

    var body: some View {
        switch block.kind {
        case .text: ProjectTextBlock(projectID: projectID, block: block, project: project, sticky: false)
        case .sticky: ProjectTextBlock(projectID: projectID, block: block, project: project, sticky: true)
        case .progress: ProjectProgressBlock(block: block, project: project)
        case .todos: ProjectTodosBlock(projectID: projectID, block: block, project: project)
        case .milestones: ProjectMilestonesBlock(projectID: projectID, project: project)
        case .chart: ProjectChartBlock(projectID: projectID, block: block, project: project)
        case .links: ProjectLinksBlock(projectID: projectID, project: project)
        case .metric: ProjectMetricBlock(block: block, project: project)
        case .countdown: ProjectCountdownBlock(block: block, project: project)
        case .impediments: ProjectImpedimentsBlock(projectID: projectID, project: project)
        case .board: ProjectBoardOverviewBlock(project: project)
        }
    }
}

// MARK: - Text and sticky notes

private struct ProjectTextBlock: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID
    let block: ProjectBlock
    let project: Project
    let sticky: Bool

    var body: some View {
        let style = block.style
        let font = sticky ? ProjectLook.stickyFont(style, page: project.design) : ProjectLook.font(style, page: project.design, size: 14)
        let blockID = block.id
        ScrollView {
            StoryTextEditor(placeholder: sticky ? "Notiz …" : "Text eingeben …",
                            text: app.projects.draftBinding(projectID, field: "text.\(blockID)", get: { $0.block(blockID)?.text }, set: { project, text in project.updateBlock(blockID) { $0.text = text } }),
                            font: font, color: NSColor(sticky ? (style.color?.color ?? Theme.textPrimary) : ProjectLook.color(style)),
                            alignment: ProjectLook.alignment(style))
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Progress

private struct ProjectProgressBlock: View {
    let block: ProjectBlock
    let project: Project

    var body: some View {
        let progress = project.progress(block.measure, list: block.listID)
        GeometryReader { geometry in
            VStack(spacing: 6) {
                ProjectProgressArt(style: block.progressStyle, progress: progress, project: project, accent: project.accent.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(progress.percent) %")
                        .font(Font(WriterStyler.font(project.design.font, size: min(26, max(15, geometry.size.height / 7)), weight: .bold)).monospacedDigit())
                        .foregroundStyle(progress.isComplete ? Theme.success : Theme.textPrimary)
                    Text(progress.total == 0 ? "Noch nichts zu zählen" : "\(progress.done) von \(progress.total)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - To-dos

private struct ProjectTodosBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let block: ProjectBlock
    let project: Project
    @State private var newText = ""
    @State private var showsDone = true

    var body: some View {
        if let listID = block.listID ?? project.todoLists.first?.id, let list = project.todoList(listID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    NoteMiniRing(progress: NoteProgress(done: list.done, total: list.todos.count), size: 15)
                    StoryTextEditor(placeholder: "Name der Liste",
                                    text: app.projects.draftBinding(projectID, field: "liste.\(listID)", get: { $0.todoList(listID)?.title }, set: { project, title in
                                        if let index = project.todoLists.firstIndex(where: { $0.id == listID }) { project.todoLists[index].title = title }
                                    }),
                                    font: .systemFont(ofSize: 13, weight: .semibold), singleLine: true)
                    Text("\(list.done)/\(list.todos.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    if list.done > 0 {
                        IconButton(systemName: showsDone ? "eye" : "eye.slash", help: showsDone ? "Erledigte ausblenden" : "Erledigte zeigen", size: 10.5, frameSize: 20) { showsDone.toggle() }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list.todos.filter { showsDone || !$0.isDone }) { todo in
                            ProjectTodoRow(projectID: projectID, todo: todo)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                            TextField("Neues ToDo", text: $newText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit { add(to: listID) }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                }
                .scrollIndicators(.automatic)
            }
        } else {
            Button("ToDo-Liste anlegen") {
                app.projects.change(projectID, "ToDo-Liste anlegen", undo: undoManager) { project in
                    let list = ProjectTodoList(title: "ToDos")
                    project.todoLists.append(list)
                    project.updateBlock(block.id) { $0.listID = list.id }
                }
            }
        }
    }

    private func add(to listID: UUID) {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        newText = ""
        app.projects.change(projectID, "ToDo hinzufügen", undo: undoManager) { project in
            if let index = project.todoLists.firstIndex(where: { $0.id == listID }) { project.todoLists[index].todos.append(ProjectTodo(text: text)) }
        }
    }
}

private struct ProjectTodoRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let todo: ProjectTodo
    @State private var hovering = false
    @State private var linking = false

    var body: some View {
        let todoID = todo.id
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    app.projects.change(projectID, todo.isDone ? "ToDo wieder öffnen" : "ToDo abhaken", undo: undoManager) { $0.updateTodo(todoID) { $0.isDone.toggle() } }
                }
            } label: {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.isDone ? Theme.success : Theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            StoryTextEditor(placeholder: "ToDo",
                            text: app.projects.draftBinding(projectID, field: "todo.\(todoID)", get: { $0.todo(todoID)?.text }, set: { project, text in project.updateTodo(todoID) { $0.text = text } }),
                            font: .systemFont(ofSize: 13), color: NSColor(todo.isDone ? Theme.textTertiary : Theme.textPrimary), singleLine: true)
                .strikethrough(todo.isDone)
            if let link = todo.link {
                Button {
                    app.openProjectRef(link)
                } label: {
                    Image(systemName: app.projectRefSymbol(link))
                        .font(.system(size: 10.5))
                        .foregroundStyle(app.projectRefExists(link) ? Theme.accent : Theme.danger)
                }
                .buttonStyle(.plain)
                .help(app.projectRefTitle(link).map { "Öffnen: \($0)" } ?? "Das Verknüpfte gibt es nicht mehr.")
            }
            if todo.due != nil || hovering {
                ProjectDayButton(date: todo.due, placeholder: "Fällig", warnsWhenPast: !todo.isDone) { date in
                    app.projects.change(projectID, "Fälligkeit ändern", undo: undoManager) { $0.updateTodo(todoID) { $0.due = date } }
                }
            }
            if hovering {
                Menu {
                    Button("Verknüpfen …", systemImage: "link") { linking = true }
                    if todo.link != nil {
                        Button("Verknüpfung lösen", systemImage: "xmark") {
                            app.projects.change(projectID, "Verknüpfung lösen", undo: undoManager) { $0.updateTodo(todoID) { $0.link = nil } }
                        }
                    }
                    Divider()
                    Button("ToDo löschen", systemImage: "trash", role: .destructive) {
                        app.projects.change(projectID, "ToDo löschen", undo: undoManager) { project in
                            for index in project.todoLists.indices { project.todoLists[index].todos.removeAll { $0.id == todoID } }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .popover(isPresented: $linking, arrowEdge: .bottom) {
                    ProjectRefPicker { ref in
                        app.projects.change(projectID, "ToDo verknüpfen", undo: undoManager) { $0.updateTodo(todoID) { $0.link = ref } }
                    }
                    .environment(app)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - Milestones

/// The milestones on a line through time, with today marked; a click on one opens it.
private struct ProjectMilestonesBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let project: Project
    @State private var editing: UUID?

    var body: some View {
        let milestones = project.sortedMilestones
        VStack(alignment: .leading, spacing: 6) {
            if milestones.isEmpty {
                Text("Noch keine Meilensteine. Lege Termine wie Abgabe, Referat oder Probedruck an.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                GeometryReader { geometry in
                    timeline(milestones, size: geometry.size)
                }
            }
            HStack {
                Spacer()
                Button {
                    let milestone = ProjectMilestone(title: "Neuer Meilenstein", date: Calendar.current.date(byAdding: .day, value: 7, to: milestones.last?.date ?? Date()) ?? Date())
                    app.projects.change(projectID, "Meilenstein anlegen", undo: undoManager) { $0.milestones.append(milestone) }
                    editing = milestone.id
                } label: {
                    Label("Meilenstein", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func timeline(_ milestones: [ProjectMilestone], size: CGSize) -> some View {
        let today = ProjectDay.normalized(Date())
        let first = min(milestones.first!.date, today)
        let last = max(milestones.last!.date, today)
        let span = max(last.timeIntervalSince(first), 86_400)
        let inset: CGFloat = 46
        let lineY = size.height * 0.5
        func x(_ date: Date) -> CGFloat { inset + CGFloat(date.timeIntervalSince(first) / span) * max(size.width - 2 * inset, 1) }
        let accent = project.accent.color
        return ZStack(alignment: .topLeading) {
            // The road: done part solid, the rest dashed.
            Path { path in
                path.move(to: CGPoint(x: inset - 18, y: lineY))
                path.addLine(to: CGPoint(x: size.width - inset + 18, y: lineY))
            }
            .stroke(Theme.ink.opacity(0.16), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
            Path { path in
                path.move(to: CGPoint(x: inset - 18, y: lineY))
                path.addLine(to: CGPoint(x: x(today), y: lineY))
            }
            .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // Today.
            VStack(spacing: 2) {
                Text("heute")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(accent)
                Circle().fill(accent).frame(width: 9, height: 9)
                    .shadow(color: accent.opacity(0.6), radius: 4)
            }
            .position(x: x(today), y: lineY - 7)
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                let above = index % 2 == 0
                let color = milestone.color?.color ?? (milestone.isDone ? Theme.success : accent)
                Button {
                    editing = milestone.id
                } label: {
                    VStack(spacing: 3) {
                        if above { label(milestone, color: color) }
                        Image(systemName: milestone.isDone ? "diamond.fill" : "diamond")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(color)
                            .background(Image(systemName: "diamond.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.surface))
                        if !above { label(milestone, color: color) }
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .position(x: x(milestone.date), y: above ? lineY - 19 : lineY + 19)
                .popover(isPresented: Binding(get: { editing == milestone.id }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
                    ProjectMilestoneEditor(projectID: projectID, milestoneID: milestone.id)
                        .environment(app)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func label(_ milestone: ProjectMilestone, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(milestone.displayTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(milestone.isDone ? Theme.textSecondary : Theme.textPrimary)
                .strikethrough(milestone.isDone, color: Theme.textTertiary)
                .lineLimit(1)
            Text(ProjectDay.label(milestone.date, short: true))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(ProjectDay.days(until: milestone.date) < 0 && !milestone.isDone ? Theme.danger : Theme.textTertiary)
        }
        .frame(maxWidth: 110)
    }
}

struct ProjectMilestoneEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let milestoneID: UUID

    var body: some View {
        if let milestone = app.projects.project(projectID)?.milestone(milestoneID) {
            VStack(alignment: .leading, spacing: 10) {
                StoryTextEditor(placeholder: "Meilenstein",
                                text: app.projects.draftBinding(projectID, field: "meilenstein.\(milestoneID)", get: { $0.milestone(milestoneID)?.title }, set: { project, title in project.updateMilestone(milestoneID) { $0.title = title } }),
                                font: .systemFont(ofSize: 14, weight: .semibold), singleLine: true, focusOnAppear: milestone.title == "Neuer Meilenstein")
                    .storyField()
                DatePicker("Datum", selection: Binding(get: { milestone.date }, set: { date in change("Datum ändern") { $0.date = date } }), displayedComponents: .date)
                Toggle("Erreicht", isOn: Binding(get: { milestone.isDone }, set: { done in change(done ? "Meilenstein erreicht" : "Meilenstein offen") { $0.isDone = done } }))
                ProjectColorRow(selection: milestone.color) { color in change("Farbe ändern") { $0.color = color } }
                HStack {
                    Text(ProjectDay.countdown(milestone.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Löschen", role: .destructive) {
                        app.projects.change(projectID, "Meilenstein löschen", undo: undoManager) { $0.milestones.removeAll { $0.id == milestoneID } }
                        dismiss()
                    }
                }
            }
            .padding(14)
            .frame(width: 290)
        }
    }

    private func change(_ label: String, _ edit: @escaping (inout ProjectMilestone) -> Void) {
        app.projects.change(projectID, label, undo: undoManager) { $0.updateMilestone(milestoneID, edit) }
    }
}

// MARK: - Links

private struct ProjectLinksBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let project: Project

    var body: some View {
        let uses = project.linkUses
        var seen: Set<ProjectRef> = []
        let shown = uses.filter { seen.insert($0.ref).inserted }
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(shown) { use in
                        ProjectRefTile(ref: use.ref, note: note(for: use), compact: true) {
                            app.unlink(use.ref, fromProject: projectID, undo: undoManager)
                        }
                    }
                }
                if shown.isEmpty {
                    Text("Noch nichts verknüpft. Ziehe Chats und Dokumente aus der Seitenleiste auf das Projekt, oder verknüpfe sie hier.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                ProjectLinkAddButton(excluded: Set(project.links)) { ref in
                    app.link(ref, toProject: projectID, undo: undoManager)
                }
            }
        }
    }

    private func note(for use: ProjectLinkUse) -> String? {
        switch use.place {
        case .project: nil
        case .task(let id): project.task(id).map { "Aufgabe „\($0.displayTitle)“" }
        case .todo(_, let id): project.todo(id).map { "ToDo „\($0.text)“" }
        }
    }
}

// MARK: - Numbers

private struct ProjectMetricBlock: View {
    let block: ProjectBlock
    let project: Project

    var body: some View {
        let metric = project.metric(block)
        GeometryReader { geometry in
            VStack(alignment: ProjectLook.horizontal(block.style), spacing: 2) {
                Spacer(minLength: 0)
                Text(metric.value)
                    .font(Font(ProjectLook.font(block.style, page: project.design, size: min(64, max(24, geometry.size.height * 0.42)), weight: .bold)).monospacedDigit())
                    .foregroundStyle(block.style.color?.color ?? block.tint?.color ?? project.accent.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                Text(metric.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: Alignment(horizontal: ProjectLook.horizontal(block.style), vertical: .center))
        }
        .animation(.snappy, value: metric.value)
    }
}

/// The days to a date as a big number in a ring that empties as the day comes closer.
private struct ProjectCountdownBlock: View {
    let block: ProjectBlock
    let project: Project

    var body: some View {
        if let target = project.countdownTarget(block) {
            let days = ProjectDay.days(until: target.date)
            let total = max(ProjectDay.days(until: target.date, from: project.createdAt), 1)
            let remaining = min(max(Double(days) / Double(total), 0), 1)
            let color = days < 0 ? Theme.danger : (days <= 3 ? Theme.warning : (block.tint?.color ?? project.accent.color))
            GeometryReader { geometry in
                let ring = min(geometry.size.height - 8, geometry.size.width * 0.42)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Theme.ink.opacity(0.08), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: remaining)
                            .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: -2) {
                            Text("\(abs(days))")
                                .font(Font(WriterStyler.font(project.design.font, size: max(16, ring * 0.36), weight: .bold)).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                                .minimumScaleFactor(0.5)
                            Text(abs(days) == 1 ? "Tag" : "Tage")
                                .font(.system(size: max(9, ring * 0.12), weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: max(ring, 30), height: max(ring, 30))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(days < 0 ? "vorbei seit" : (days == 0 ? "heute ist" : "bis"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(target.title)
                            .font(Font(WriterStyler.font(project.design.font, size: 15, weight: .semibold)))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(ProjectDay.label(target.date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            Text("Kein offener Meilenstein. Lege einen an oder wähle unter „Gestalten“ ein Datum.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Board on the page

/// The tasks that something is in the way of, with what can be done about it.
private struct ProjectImpedimentsBlock: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let project: Project

    var body: some View {
        let blocked = project.tasks.filter { $0.isBlocked && !project.isFinished($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if blocked.isEmpty {
                    Label("Nichts hält auf. Freie Fahrt!", systemImage: "checkmark.seal")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.success)
                }
                ForEach(blocked) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            app.openProject(projectID, tab: .board, task: task.id)
                        } label: {
                            Text(task.displayTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .help("Aufgabe im Board öffnen")
                        ForEach(task.openImpediments) { impediment in
                            HStack(alignment: .top, spacing: 7) {
                                Button {
                                    app.projects.change(projectID, "Hindernis behoben", undo: undoManager) { project in
                                        project.updateTask(task.id) { task in
                                            if let index = task.impediments.firstIndex(where: { $0.id == impediment.id }) { task.impediments[index].isResolved = true }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.warning)
                                }
                                .buttonStyle(.plain)
                                .help("Als behoben markieren")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(impediment.text.isEmpty ? "Hindernis" : impediment.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textPrimary)
                                    if !impediment.solution.isEmpty {
                                        Label(impediment.solution, systemImage: "wrench.and.screwdriver")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.08)))
                }
            }
        }
    }
}

/// The board's columns in small: how many tasks each holds, and the first of them.
private struct ProjectBoardOverviewBlock: View {
    @Environment(AppModel.self) private var app
    let project: Project

    var body: some View {
        let total = max(project.tasks.count, 1)
        VStack(alignment: .leading, spacing: 8) {
            // One bar for the whole board, a segment per column.
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(project.columns) { column in
                        let count = project.tasks(in: column.id).count
                        if count > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(column.color?.color ?? Theme.accent)
                                .frame(width: max(4, geometry.size.width * CGFloat(count) / CGFloat(total) - 2))
                        }
                    }
                    if project.tasks.isEmpty {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.ink.opacity(0.08))
                    }
                }
            }
            .frame(height: 8)
            HStack(alignment: .top, spacing: 10) {
                ForEach(project.columns) { column in
                    let tasks = project.tasks(in: column.id)
                    Button {
                        app.projectTab = .board
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Circle().fill(column.color?.color ?? Theme.accent).frame(width: 7, height: 7)
                                Text(column.displayTitle)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                Text("\(tasks.count)")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(column.limit.map { tasks.count > $0 } == true ? Theme.danger : Theme.textPrimary)
                            }
                            ForEach(tasks.prefix(3)) { task in
                                HStack(spacing: 4) {
                                    if task.isBlocked { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5)).foregroundStyle(Theme.warning) }
                                    Text(task.displayTitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            if tasks.count > 3 {
                                Text("+ \(tasks.count - 3) weitere")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Board öffnen")
                }
            }
        }
    }
}
