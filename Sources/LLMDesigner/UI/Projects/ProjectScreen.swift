import SwiftUI

/// A project in the main area: its page of blocks, or its board of tasks.
struct ProjectScreen: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID
    @State private var selectedTask: UUID?
    @State private var scrollTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ProjectTopBar(projectID: projectID)
            Group {
                switch app.projectTab {
                case .page: ProjectPage(projectID: projectID, scrollTarget: $scrollTarget)
                case .board: ProjectBoard(projectID: projectID, selectedTask: $selectedTask)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .onAppear { take(app.projectCommand) }
        .onChange(of: app.projectCommand) { _, command in take(command) }
        .onDisappear {
            app.projects.saveAll()
            app.projectPageEditing = false
        }
    }

    private func take(_ command: ProjectCommand?) {
        guard let command else { return }
        if let tab = command.tab { app.projectTab = tab }
        if let task = command.task {
            app.projectTab = .board
            selectedTask = task
        }
        if let block = command.block {
            app.projectTab = .page
            scrollTarget = block
        }
        app.projectCommand = nil
    }
}

// MARK: - Top bar

private struct ProjectTopBar: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID
    @State private var width: CGFloat = 1200

    var body: some View {
        let project = app.projects.project(projectID)
        HStack(spacing: 10) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                NewItemMenu()
                    .padding(.trailing, 4)
            }
            if let project {
                ProjectBadge(project: project, size: 20)
                Text(project.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: width < 900 ? 140 : 320, alignment: .leading)
                    .fixedSize(horizontal: width >= 900, vertical: false)
            }
            ProjectTabSwitch(compact: width < 760)
                .padding(.leading, 6)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if app.projectTab == .page {
                if app.projectPageEditing {
                    ProjectAddBlockMenu(projectID: projectID)
                    ProjectDesignMenu(projectID: projectID)
                }
                Button {
                    withAnimation(.snappy(duration: 0.2)) { app.projectPageEditing.toggle() }
                } label: {
                    Label(app.projectPageEditing ? "Fertig" : "Gestalten", systemImage: app.projectPageEditing ? "checkmark" : "paintbrush.pointed")
                        .font(.system(size: 12, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(app.projectPageEditing ? Color.white : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(app.projectPageEditing ? Theme.accent : Theme.ink.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(app.projectPageEditing ? "Gestalten beenden" : "Seite gestalten: Bausteine hinzufügen, verschieben, in der Größe ändern und formatieren")
            }
            IconButton(systemName: "xmark", help: "Projekt schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { app.closeProject() }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.bottom, Theme.topBarBottomPadding)
        .background(WindowDragArea())
    }
}

/// Projektseite | Aufgaben, with the number of open tasks on the second.
private struct ProjectTabSwitch: View {
    @Environment(AppModel.self) private var app
    let compact: Bool

    var body: some View {
        let open = app.openProject.map { project in project.tasks.filter { !project.isFinished($0) }.count } ?? 0
        HStack(spacing: 2) {
            ForEach(ProjectTab.allCases) { tab in
                let selected = app.projectTab == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { app.projectTab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .medium))
                        if !compact || selected {
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        if tab == .board, open > 0 {
                            Text("\(open)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.selection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .page ? "Die Projektseite mit ihren Bausteinen" : "Die Aufgaben als Kanban-Board")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }
}

/// "+ Baustein": every kind with what it shows.
private struct ProjectAddBlockMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID

    var body: some View {
        Menu {
            ForEach(ProjectBlockKind.allCases.filter { $0 != .chart }) { kind in
                Button {
                    app.projects.change(projectID, "Baustein hinzufügen", undo: undoManager) { $0.addBlock(kind) }
                } label: {
                    Label("\(kind.title) – \(kind.tagline)", systemImage: kind.symbol)
                }
            }
            Divider()
            Section("Diagramme") {
                ForEach(ProjectChartKind.allCases) { chart in
                    Button {
                        app.projects.change(projectID, "Diagramm hinzufügen", undo: undoManager) { $0.addChart(chart) }
                    } label: {
                        Label(chart.title, systemImage: chart.symbol)
                    }
                }
            }
        } label: {
            Label("Baustein", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Baustein hinzufügen")
    }
}

/// The page as a whole: typeface, accent and background.
private struct ProjectDesignMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID

    var body: some View {
        let design = app.projects.project(projectID)?.design ?? ProjectDesign()
        Menu {
            Menu("Schrift der Seite") {
                ForEach(WriterFont.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(WriterFont.allCases.filter { $0.group == group }) { font in
                            Toggle(font.label, isOn: Binding(get: { design.font == font }, set: { _ in change { $0.design.font = font } }))
                        }
                    }
                }
            }
            Menu("Hintergrund") {
                ForEach(ProjectBackground.allCases) { background in
                    Toggle(background.title, isOn: Binding(get: { design.background == background }, set: { _ in change { $0.design.background = background } }))
                }
            }
            Menu("Akzentfarbe") {
                Toggle("Farbe des Projekts", isOn: Binding(get: { design.accent == nil }, set: { _ in change { $0.design.accent = nil } }))
                ForEach(FolderColor.allCases, id: \.self) { color in
                    Toggle(isOn: Binding(get: { design.accent == color }, set: { _ in change { $0.design.accent = color } })) {
                        Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }
                    }
                }
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Gestaltung der Seite: Schrift, Hintergrund, Akzentfarbe")
    }

    private func change(_ edit: (inout Project) -> Void) {
        app.projects.change(projectID, "Gestaltung ändern", undo: undoManager, edit)
    }
}

// MARK: - Page

/// The page: its head, then the blocks on the grid.
private struct ProjectPage: View {
    @Environment(AppModel.self) private var app
    let projectID: UUID
    @Binding var scrollTarget: UUID?
    @State private var width: CGFloat = 0

    var body: some View {
        if let project = app.projects.project(projectID) {
            let accent = project.accent.color
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ProjectPageHead(projectID: projectID)
                        if width > 0 {
                            ProjectGrid(projectID: projectID, width: max(min(width, 1400) - 2 * padding, 280))
                        }
                        if project.blocks.isEmpty {
                            emptyHint
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    scrollTarget = nil
                }
            }
            .background(ProjectPageBackground(design: project.design, accent: accent).ignoresSafeArea())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .tint(accent)
        }
    }

    private var padding: CGFloat { width < 700 ? 16 : 32 }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Die Seite ist leer. Unter „Gestalten“ fügst du Bausteine hinzu: Text, Fortschritt, Diagramme, ToDos, Meilensteine …")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !app.projectPageEditing {
                Button("Gestalten") { app.projectPageEditing = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// The head of the page: symbol, title and subtitle in the page's typeface, status and the next milestone.
private struct ProjectPageHead: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    @State private var choosingSymbol = false

    var body: some View {
        if let project = app.projects.project(projectID) {
            let library = app.projects
            HStack(alignment: .top, spacing: 16) {
                Button {
                    choosingSymbol = true
                } label: {
                    ProjectBadge(project: project, size: 54)
                        .shadow(color: project.color.color.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .help("Symbol und Farbe des Projekts")
                .popover(isPresented: $choosingSymbol, arrowEdge: .bottom) {
                    ProjectSymbolPicker(project: project) { symbol, color in
                        library.change(projectID, "Symbol ändern", undo: undoManager) { $0.symbol = symbol; $0.color = color }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    StoryTextEditor(placeholder: "Projekttitel",
                                    text: library.draftBinding(projectID, field: "titel", get: { $0.title }, set: { $0.title = $1 }),
                                    font: WriterStyler.font(project.design.font, size: 30, weight: .bold), singleLine: true,
                                    focusOnAppear: project.title.isEmpty && project.tasks.isEmpty)
                    StoryTextEditor(placeholder: "Untertitel oder Ziel in einem Satz",
                                    text: library.draftBinding(projectID, field: "untertitel", get: { $0.subtitle }, set: { $0.subtitle = $1 }),
                                    font: WriterStyler.font(project.design.font, size: 15), color: NSColor(Theme.textSecondary))
                    HStack(spacing: 10) {
                        ProjectStatusMenu(project: project)
                        if let next = project.nextMilestone {
                            Label("\(next.displayTitle) · \(ProjectDay.label(next.date)) · \(ProjectDay.countdown(next.date))", systemImage: "flag.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(ProjectDay.days(until: next.date) < 0 ? Theme.danger : Theme.textSecondary)
                                .lineLimit(1)
                        }
                        let progress = project.overallProgress
                        if progress.total > 0 {
                            HStack(spacing: 5) {
                                NoteMiniRing(progress: progress, size: 14)
                                Text("\(progress.percent) %")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .help("Aufgaben, ToDos und Meilensteine zusammen: \(progress.label)")
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct ProjectStatusMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let project: Project

    var body: some View {
        Menu {
            ForEach(ProjectStatus.allCases) { status in
                Button(status.title, systemImage: status.symbol) {
                    app.projects.change(project.id, "Status ändern", undo: undoManager) { $0.status = status }
                }
            }
        } label: {
            Label(project.status.title, systemImage: project.status.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor.opacity(0.13)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Status des Projekts")
    }

    private var statusColor: Color {
        switch project.status {
        case .planned: Theme.textSecondary
        case .running: Theme.accent
        case .paused: Theme.warning
        case .done: Theme.success
        }
    }
}

/// The symbols and colours a project can wear.
private struct ProjectSymbolPicker: View {
    let project: Project
    let onPick: (String, FolderColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Symbol")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(Project.symbols, id: \.self) { symbol in
                    Button {
                        onPick(symbol, project.color)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(project.symbol == symbol ? Color.white : Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(project.symbol == symbol ? project.color.color : Theme.ink.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Farbe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            ProjectColorRow(selection: project.color, allowsNone: false) { color in
                onPick(project.symbol, color ?? project.color)
            }
        }
        .padding(14)
    }
}
