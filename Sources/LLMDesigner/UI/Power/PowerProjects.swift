import SwiftUI

/// Projects in small: every project with its progress; one of them with its board's columns, its to-dos and what it
/// links to. Tasks and to-dos drag out as text; text dropped on a project becomes tasks (one per line).
struct PowerProjects: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.power.projectID, app.projects.project(id) != nil {
            PowerProjectView(projectID: id, query: app.power.query)
        } else {
            PowerProjectList(query: app.power.query)
        }
    }
}

private struct PowerProjectList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let projects = app.projects.projects.filter { $0.matches(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(projects) { project in
                    let open = project.tasks.filter { !project.isFinished($0) }.count
                    Button {
                        app.power.projectID = project.id
                    } label: {
                        HStack(spacing: 10) {
                            ProjectBadge(project: project, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text("\(project.status.title) · \(open == 1 ? "1 offene Aufgabe" : "\(open) offene Aufgaben")\(project.nextMilestone.map { " · \($0.displayTitle) \(ProjectDay.countdown($0.date))" } ?? "")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            NoteMiniRing(progress: project.overallProgress, size: 18)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(app.openProjectID == project.id ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StoryRowButtonStyle())
                }
                if projects.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Projekte." : "Kein Projekt passt zur Suche.")
                }
                HStack(spacing: 6) {
                    Button {
                        let project = app.newProject(open: false)
                        app.power.projectID = project.id
                    } label: {
                        Label("Neues Projekt", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 34)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    PowerDropZone(title: "Text hierher ziehen: neues Projekt", symbol: Project.sidebarSymbol) { dropped in
                        let lines = PowerProjects.lines(dropped.markdown)
                        guard let title = lines.first else { return }
                        let project = app.newProject(title: title, open: false)
                        for line in lines.dropFirst() { _ = app.newTask(titled: line, in: project.id) }
                        app.power.projectID = project.id
                        app.power.lastChange = PowerAccess.Change(label: "Projekt angelegt") { [weak app] in app?.projects.deleteProject(project.id) }
                    }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

private struct PowerProjectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let query: String

    var body: some View {
        if let project = app.projects.project(projectID) {
            VStack(spacing: 0) {
                PowerItemBar(title: project.displayTitle, symbol: Project.sidebarSymbol, openHelp: "Projektseite öffnen") {
                    app.power.closeItem()
                } onOpen: {
                    app.openProject(projectID)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summary(project)
                        PowerDropZone(title: "Text hierher ziehen: neue Aufgaben", symbol: "rectangle.stack.badge.plus") { dropped in
                            let lines = PowerProjects.lines(dropped.markdown)
                            guard !lines.isEmpty else { return }
                            let before = app.projects.project(projectID)
                            for line in lines { _ = app.newTask(titled: line, in: projectID, undo: undoManager) }
                            app.power.lastChange = PowerAccess.Change(label: lines.count == 1 ? "Aufgabe angelegt" : "\(lines.count) Aufgaben angelegt") { [weak app] in
                                if let before { app?.projects.update(projectID) { $0 = before } }
                            }
                        }
                        ForEach(project.columns) { column in
                            let tasks = project.tasks(in: column.id).filter { $0.matches(query) }
                            if !tasks.isEmpty {
                                header(column.displayTitle, color: column.color?.color, count: tasks.count)
                                ForEach(tasks) { task in taskRow(task, project: project) }
                            }
                        }
                        ForEach(project.todoLists) { list in
                            let todos = list.todos.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
                            if !todos.isEmpty {
                                header(list.displayTitle, color: nil, count: todos.count)
                                ForEach(todos) { todo in todoRow(todo) }
                            }
                        }
                        let links = project.allLinks
                        if !links.isEmpty {
                            header("Verknüpft", color: nil, count: links.count)
                            ForEach(links, id: \.self) { ref in
                                ProjectRefTile(ref: ref, compact: true)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func summary(_ project: Project) -> some View {
        let progress = project.overallProgress
        return HStack(spacing: 10) {
            NoteMiniRing(progress: progress, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(progress.percent) % · \(progress.label)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if let next = project.nextMilestone {
                    Text("Nächster Meilenstein: \(next.displayTitle), \(ProjectDay.countdown(next.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(project.color.wash))
    }

    private func header(_ title: String, color: Color?, count: Int) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 7, height: 7) }
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 6)
    }

    private func taskRow(_ task: ProjectTask, project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: project.isFinished(task) ? "checkmark.circle.fill" : (task.isBlocked ? "exclamationmark.triangle.fill" : "circle"))
                .font(.system(size: 12))
                .foregroundStyle(project.isFinished(task) ? Theme.success : (task.isBlocked ? Theme.warning : Theme.textTertiary))
            Button {
                app.openProject(projectID, tab: .board, task: task.id)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.displayTitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if !task.criteria.isEmpty {
                        Text("\(task.criteriaMet)/\(task.criteria.count) Kriterien erfüllt")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Im Board öffnen")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
                .powerDrag(markdown: PowerProjects.markdown(task), plain: PowerProjects.markdown(task))
                .help("Ziehen: die Aufgabe mit Kriterien und Hindernissen als Text")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.025)))
    }

    private func todoRow(_ todo: ProjectTodo) -> some View {
        HStack(spacing: 8) {
            Button {
                app.projects.change(projectID, todo.isDone ? "ToDo wieder öffnen" : "ToDo abhaken", undo: undoManager) { $0.updateTodo(todo.id) { $0.isDone.toggle() } }
            } label: {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(todo.isDone ? Theme.success : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            Text(todo.text)
                .font(.system(size: 12.5))
                .foregroundStyle(todo.isDone ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(todo.isDone)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let due = todo.due {
                Text(ProjectDay.label(due, short: true))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .powerDrag(markdown: "- [\(todo.isDone ? "x" : " ")] \(todo.text)", plain: todo.text)
    }
}

extension PowerProjects {
    /// The lines of dropped text, without list marks and empty lines.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            for mark in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(mark) { line = String(line.dropFirst(mark.count)) }
            while line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return line.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    }

    /// A task as Markdown: title, description, criteria as a task list, impediments.
    static func markdown(_ task: ProjectTask) -> String {
        var parts = ["**\(task.displayTitle)**"]
        if !task.details.isEmpty { parts.append(task.details) }
        if !task.criteria.isEmpty {
            parts.append("Akzeptanzkriterien:\n" + task.criteria.map { "- [\($0.isMet ? "x" : " ")] \($0.text)" }.joined(separator: "\n"))
        }
        if !task.impediments.isEmpty {
            parts.append("Hindernisse:\n" + task.impediments.map { "- \($0.text)\($0.solution.isEmpty ? "" : " – Lösung: \($0.solution)")\($0.isResolved ? " (behoben)" : "")" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
