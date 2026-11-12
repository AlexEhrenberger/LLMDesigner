import SwiftUI

// Where projects meet the studios: a document, a presentation, a note or a part of a novel world can be put into a
// project or onto one of its tasks from where it is open. The link is kept in the project; the thing stays as it is.

/// The project symbol in a title bar, with the number of projects the thing belongs to.
struct ProjectMembershipButton: View {
    @Environment(AppModel.self) private var app
    let ref: ProjectRef
    /// "dieses Dokument", "diese Präsentation", "dieses Note".
    let label: String
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let count = app.projects.projects(referring: ref).count
        Button {
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: Project.sidebarSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(count > 0 ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                    .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: -1, y: 2)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(open ? Theme.accent.opacity(0.14) : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(count == 0 ? "Projekte: \(label) einem Projekt oder einer Aufgabe zuordnen" : "Gehört zu \(count == 1 ? "einem Projekt" : "\(count) Projekten")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectMembershipPanel(ref: ref, label: label)
                .environment(app)
        }
    }
}

/// The projects a thing belongs to, and the others to put it into: as a whole, or onto a task.
struct ProjectMembershipPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let ref: ProjectRef
    let label: String

    var body: some View {
        let linked = app.projects.projects(referring: ref)
        let others = app.projects.projects.filter { !$0.refers(to: ref) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: Project.sidebarSymbol)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Projekte")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(app.projectRefTitle(ref).map { "\(app.projectRefKind(ref)) „\($0)“" } ?? label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !linked.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Gehört zu")
                    ForEach(linked) { project in
                        linkedRow(project)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                caption(linked.isEmpty ? "Zuordnen" : "Weiteren Projekten zuordnen")
                if others.isEmpty {
                    Text(app.projects.projects.isEmpty ? "Noch kein Projekt." : "Gehört schon zu allen Projekten.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(others) { project in
                            otherRow(project)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider()
            Button {
                let title = app.projectRefTitle(ref) ?? ""
                app.newProject(title: title, linking: ref)
            } label: {
                Label("Neues Projekt mit \(label)", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { app.projects.loadIfNeeded() }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.textTertiary)
    }

    private func linkedRow(_ project: Project) -> some View {
        let tasks = project.tasks(referring: ref)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProjectBadge(project: project, size: 20)
                Button {
                    app.openProject(project.id)
                } label: {
                    Text(project.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Projektseite öffnen")
                Spacer(minLength: 0)
                taskMenu(project)
                IconButton(systemName: "xmark", help: "Aus dem Projekt lösen (auch von seinen Aufgaben)", size: 10, frameSize: 20) {
                    app.unlink(ref, fromProject: project.id, undo: undoManager)
                }
            }
            ForEach(tasks) { task in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Button {
                        app.openProject(project.id, tab: .board, task: task.id)
                    } label: {
                        Text(task.displayTitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Aufgabe im Board öffnen")
                    if let column = project.column(task.column) {
                        Text(column.displayTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(column.color?.color ?? Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Von der Aufgabe lösen", size: 9, frameSize: 18) {
                        app.unlink(ref, fromTask: task.id, in: project.id, undo: undoManager)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(project.color.wash))
    }

    private func otherRow(_ project: Project) -> some View {
        HStack(spacing: 8) {
            ProjectBadge(project: project, size: 18)
            Text(project.displayTitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Hinzufügen") {
                app.link(ref, toProject: project.id, undo: undoManager)
            }
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            taskMenu(project)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// "Zu Aufgabe …": the project's tasks by column, and a new one for the thing.
    private func taskMenu(_ project: Project) -> some View {
        Menu {
            Button("Neue Aufgabe dafür", systemImage: "plus") {
                let title = app.projectRefTitle(ref).map { "\($0) bearbeiten" } ?? "Neue Aufgabe"
                if let task = app.newTask(titled: title, linking: ref, in: project.id, undo: undoManager) {
                    app.openProject(project.id, tab: .board, task: task)
                }
            }
            ForEach(project.columns) { column in
                let tasks = project.tasks(in: column.id)
                if !tasks.isEmpty {
                    Section(column.displayTitle) {
                        ForEach(tasks) { task in
                            let linked = task.links.contains(ref)
                            Button {
                                if linked { app.unlink(ref, fromTask: task.id, in: project.id, undo: undoManager) } else { app.link(ref, toTask: task.id, in: project.id, undo: undoManager) }
                            } label: {
                                if linked { Label(task.displayTitle, systemImage: "checkmark") } else { Text(task.displayTitle) }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 20)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Einer Aufgabe dieses Projekts zuordnen")
    }
}

/// The card on a novel world's or a part's page: the projects it belongs to, with the button to add it to one.
struct StoryProjectsCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let ref: ProjectRef
    let label: String
    @State private var open = false

    var body: some View {
        let projects = app.projects.projects(referring: ref)
        StoryCard(tint: projects.isEmpty ? nil : Theme.accent) {
            HStack(spacing: 10) {
                StoryLabel(title: "Projekte", hint: "Projekte, zu denen \(label) gehört – als Ganzes oder bei einer Aufgabe. Die Projektseite zeigt Stand, Termine und Aufgaben.",
                           symbol: Project.sidebarSymbol, color: Theme.accent)
                Spacer()
                Button {
                    open = true
                } label: {
                    Label("Zuordnen", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    ProjectMembershipPanel(ref: ref, label: label)
                        .environment(app)
                }
            }
            if projects.isEmpty {
                Text("Gehört zu keinem Projekt.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(projects) { project in
                HStack(spacing: 9) {
                    ProjectBadge(project: project, size: 20)
                    Button {
                        app.openProject(project.id)
                    } label: {
                        Text(project.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    let tasks = project.tasks(referring: ref)
                    if !tasks.isEmpty {
                        Text(tasks.count == 1 ? "Aufgabe „\(tasks[0].displayTitle)“" : "\(tasks.count) Aufgaben")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    NoteMiniRing(progress: project.overallProgress, size: 16)
                    IconButton(systemName: "xmark", help: "Aus dem Projekt lösen", size: 10, frameSize: 20) {
                        app.unlink(ref, fromProject: project.id, undo: undoManager)
                    }
                }
            }
        }
    }
}
