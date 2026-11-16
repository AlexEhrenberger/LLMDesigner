import SwiftUI

/// AgentSteps' dashboard: on the left what runs, waits and is planned; on the right a task's building blocks, a run's
/// timeline or the chat for a new task; along the bottom the terminal with the agents' log.
struct AgentStepsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 1200
    @State private var terminalHeight: CGFloat = 220
    @State private var dragStart: CGFloat?

    private var center: AgentCenter { app.agents }

    var body: some View {
        VStack(spacing: 0) {
            StudioTopBar(symbol: AgentTask.symbol, title: "AgentSteps", detail: detail, close: { app.agentStepsOpen = false }) {
                if width < 760 { compactList }
            } trailing: {
                haltButton
                newTaskMenu
            }
            AgentBanners()
            HStack(spacing: 0) {
                if width >= 760 {
                    AgentListColumn()
                        .frame(width: 270)
                        .glassColumn()
                }
                VStack(spacing: 0) {
                    Group {
                        switch center.selection {
                        case .task(let id)?: AgentTaskEditor(taskID: id).id(id)
                        case .run(let id)?: AgentRunView(runID: id).id(id)
                        case .newTask?: AgentChatView()
                        case nil: AgentOverview()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    resizeHandle
                    AgentTerminalView(run: nil)
                        .frame(height: terminalHeight)
                }
            }
        }
        .background(Theme.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { center.loadIfNeeded() }
    }

    private var detail: String? {
        var parts = ["\(center.tasks.records.count) Aufgaben"]
        if center.activeRunID != nil { parts.append("1 läuft") }
        if !center.queued.isEmpty { parts.append("\(center.queued.count) warten") }
        if !center.openQuestions.isEmpty { parts.append("\(center.openQuestions.count) Fragen") }
        return parts.joined(separator: " · ")
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                let start = dragStart ?? terminalHeight
                dragStart = start
                terminalHeight = min(560, max(90, start - value.translation.height))
            }.onEnded { _ in dragStart = nil })
    }

    private var haltButton: some View {
        Button {
            center.isHalted.toggle()
        } label: {
            Label(center.isHalted ? "Agenten weiterlaufen lassen" : "Alle anhalten", systemImage: center.isHalted ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(center.isHalted ? Theme.warning : nil)
        .help(center.isHalted ? "Läufe gehen weiter, Zeitpläne starten wieder." : "Der laufende Agent hält am nächsten Schritt an, und nichts Neues startet.")
    }

    private var newTaskMenu: some View {
        Menu {
            Button {
                center.selection = .newTask
            } label: { Label("Im Chat beschreiben …", systemImage: "bubble.left.and.text.bubble.right") }
            Button {
                let task = app.createAgentTask(AgentTask(title: "Neue Aufgabe"))
                center.selection = .task(task.id)
            } label: { Label("Aus Bausteinen bauen", systemImage: "square.stack.3d.up") }
        } label: {
            Label("Neue Aufgabe", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    /// In a narrow window the list becomes a menu.
    private var compactList: some View {
        Menu {
            Button("Übersicht") { center.selection = nil }
            Button("Neue Aufgabe im Chat") { center.selection = .newTask }
            Section("Aufgaben") {
                ForEach(center.tasks.records) { task in Button(task.title) { center.selection = .task(task.id) } }
            }
            Section("Läufe") {
                ForEach(center.history.prefix(10)) { run in Button("\(run.title) – \(run.state.label)") { center.selection = .run(run.id) } }
            }
        } label: {
            Label("Liste", systemImage: "sidebar.left").font(.system(size: 12))
        }
        .fixedSize()
    }
}

/// Bars above everything: all agents halted, the Mac about to sleep, a run's branch still open, Git off.
private struct AgentBanners: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?

    var body: some View {
        let center = app.agents
        VStack(spacing: 6) {
            if center.isHalted {
                banner("pause.circle.fill", Theme.warning, "Alle Agenten sind angehalten. Zeitpläne stellen Läufe in die Warteschlange, gestartet wird nichts.") {
                    Button("Weiterlaufen lassen") { center.isHalted = false }
                }
            }
            if let sleepAt = center.sleepAt {
                banner("moon.zzz.fill", Theme.accent, "Der Mac geht \(sleepAt.formatted(date: .omitted, time: .standard)) in den Ruhezustand, wenn niemand ihn benutzt.") {
                    Button("Wach bleiben") { center.cancelSleep() }
                }
            }
            if center.activeRunID == nil, let run = center.unfinishedBranchRun(currentBranch: app.git.branch) {
                banner("arrow.triangle.branch", Theme.warning, "Die Bibliothek steht noch auf \(run.branch ?? "") von „\(run.title)“ (\(run.state.label)). Was du jetzt änderst, landet dort.") {
                    if run.state.canResume { Button("Fortsetzen") { app.resumeAgentRun(run.id) } }
                    Button("Übernehmen und beenden") { finish(run.id) }
                }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
        }
        .padding(.bottom, center.isHalted || center.sleepAt != nil || message != nil ? 8 : 0)
    }

    private func banner<Actions: View>(_ symbol: String, _ color: Color, _ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35)))
        .padding(.horizontal, 14)
    }

    private func finish(_ id: UUID) {
        Task {
            do { try await app.finishAgentBranch(id); message = nil } catch { message = error.localizedDescription }
        }
    }
}

/// The left column: running and waiting runs, questions, tasks with their time, the latest runs.
private struct AgentListColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let center = app.agents
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                StudioListRow(symbol: "rectangle.3.group", title: "Übersicht", subtitle: app.agentStatusLine, isSelected: center.selection == nil) {
                    center.selection = nil
                }
                StudioListRow(symbol: "bubble.left.and.text.bubble.right", title: "Neue Aufgabe im Chat", isSelected: center.selection == .newTask) {
                    center.selection = .newTask
                }
                let active = center.runs.records.filter { $0.state.isActive && $0.state != .asking }.sorted { $0.queuedAt < $1.queuedAt }
                if !active.isEmpty {
                    StudioSectionHeader(title: "Jetzt", symbol: "bolt.fill", count: active.count)
                    ForEach(active) { run in runRow(run) }
                }
                let questions = center.openQuestions
                if !questions.isEmpty {
                    StudioSectionHeader(title: "Wartet auf dich", symbol: "hand.raised.fill", count: questions.count)
                    ForEach(questions) { run in runRow(run) }
                }
                StudioSectionHeader(title: "Aufgaben", symbol: "square.stack.3d.up", count: center.tasks.records.count)
                if center.tasks.records.isEmpty {
                    Text("Noch keine. Beschreibe eine im Chat oder baue sie aus Bausteinen.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 10)
                }
                ForEach(center.tasks.records.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { task in
                    let next = center.nextRun(of: task)
                    StudioListRow(symbol: task.schedule.isTimed ? "calendar.badge.clock" : AgentTask.symbol,
                                  color: center.isActive(task.id) ? Theme.success : Theme.accent,
                                  title: task.title,
                                  subtitle: next.map { "\(task.schedule.summary) · \($0.formatted(.relative(presentation: .named)))" } ?? task.schedule.summary,
                                  trailing: "\(task.steps.count)",
                                  isSelected: center.selection == .task(task.id)) {
                        center.selection = .task(task.id)
                    }
                    .contextMenu {
                        Button("Jetzt starten") { _ = try? app.enqueueAgentRun(task.id, trigger: .person) }
                            .disabled(center.isActive(task.id))
                    }
                }
                let past = center.history.filter(\.state.isOver).prefix(15)
                if !past.isEmpty {
                    StudioSectionHeader(title: "Letzte Läufe", symbol: "clock.arrow.circlepath")
                    ForEach(Array(past)) { run in runRow(run) }
                }
            }
            .padding(8)
        }
    }

    private func runRow(_ run: AgentRun) -> some View {
        let step = run.state.isActive ? run.currentStepIndex.map { "Schritt \($0 + 1)/\(run.steps.count)" } : nil
        return StudioListRow(symbol: AgentStyle.symbol(run.state), color: AgentStyle.color(run.state), title: run.title,
                             subtitle: [run.state.label, step].compactMap { $0 }.joined(separator: " · "),
                             trailing: (run.startedAt ?? run.queuedAt).formatted(date: .omitted, time: .shortened),
                             isSelected: app.agents.selection == .run(run.id)) {
            app.agents.selection = .run(run.id)
        }
    }
}

/// What the dashboard shows without a selection: the run working now, the questions, what comes next.
struct AgentOverview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let center = app.agents
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    tile("Läuft", center.activeRun.map { _ in "1" } ?? "–", "play.circle", Theme.accent)
                    tile("Wartet", "\(center.queued.count)", "hourglass", Theme.textSecondary)
                    tile("Fragen", "\(center.openQuestions.count)", "hand.raised", center.openQuestions.isEmpty ? Theme.textSecondary : Theme.warning)
                    tile("Aufgaben", "\(center.tasks.records.count)", AgentTask.symbol, Theme.textSecondary)
                }
                if let run = center.activeRun {
                    StudioCard(title: "Jetzt: \(run.title)", symbol: "bolt.fill") {
                        AgentRunStatus(runID: run.id)
                    }
                }
                ForEach(center.openQuestions) { run in
                    if let question = run.question {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            AgentQuestionCard(runID: run.id, question: question)
                        }
                    }
                }
                StudioCard(title: "Als Nächstes", symbol: "calendar") {
                    let planned = center.tasks.records.compactMap { task in center.nextRun(of: task).map { (task, $0) } }.sorted { $0.1 < $1.1 }
                    if planned.isEmpty {
                        Text("Keine Aufgabe hat einen Zeitplan.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(planned.prefix(8), id: \.0.id) { task, date in
                                StudioListRow(symbol: "calendar.badge.clock", title: task.title, subtitle: task.schedule.summary,
                                              trailing: date.formatted(date: .abbreviated, time: .shortened), isSelected: false) {
                                    center.selection = .task(task.id)
                                }
                            }
                        }
                    }
                }
                StudioCard(title: "So arbeiten Agenten hier", symbol: "info.circle") {
                    VStack(alignment: .leading, spacing: 5) {
                        bullet("Ein Lauf nach dem anderen. Chattest du, wartet der Agent, bis die Antwort fertig ist.")
                        bullet("Jeder Lauf bekommt einen eigenen Git-Branch, jeder Schritt einen Commit. Am Ende kommt alles in deinen Branch zurück; „Zurücknehmen“ macht den Lauf rückgängig.")
                        bullet("Will ein Agent etwas, das eine Freigabe braucht, wartet nur dieser Lauf; die Frage steht hier und im Power-Zugriff.")
                        bullet("Solange ein Agent arbeitet, bleibt der Mac wach. Auf Wunsch geht er danach schlafen.")
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The working run in a few lines: its step, the bar of steps, what the model writes, and the buttons.
struct AgentRunStatus: View {
    @Environment(AppModel.self) private var app
    let runID: UUID
    var compact = false

    var body: some View {
        if let run = app.agents.run(runID) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: AgentStyle.symbol(run.state)).foregroundStyle(AgentStyle.color(run.state))
                    if let index = run.currentStepIndex {
                        Text("Schritt \(index + 1)/\(run.steps.count): \(run.steps[index].title)")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    } else {
                        Text(run.state.label).font(.system(size: 12.5, weight: .medium))
                    }
                    Spacer(minLength: 0)
                    if app.agents.yielding.contains(runID) {
                        Tag(text: "wartet auf deinen Chat", color: Theme.warning)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(run.steps) { step in
                        Capsule().fill(AgentStyle.color(step.state).opacity(step.state == .pending ? 0.3 : 1)).frame(height: 4)
                    }
                }
                if let live = app.agents.live[runID] {
                    Text(live).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(compact ? 1 : 2)
                }
                HStack(spacing: 6) {
                    if run.state == .running {
                        Button { app.pauseAgentRun(runID) } label: { Label("Anhalten", systemImage: "pause.fill") }
                    } else if run.state == .paused {
                        Button { app.resumeAgentRun(runID) } label: { Label("Fortsetzen", systemImage: "play.fill") }
                    }
                    if run.state.isActive {
                        Button(role: .destructive) { app.cancelAgentRun(runID) } label: { Label("Abbrechen", systemImage: "stop.fill") }
                    }
                    Spacer(minLength: 0)
                    if !compact || !app.agentStepsOpen {
                        Button("Lauf zeigen") { app.openAgentSteps(.run(runID)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .controlSize(.small)
                .font(.system(size: 11.5))
            }
        }
    }
}
