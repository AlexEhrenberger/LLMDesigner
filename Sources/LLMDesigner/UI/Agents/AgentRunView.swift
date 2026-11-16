import SwiftUI

/// One run: its steps as a timeline in sentences, the question it waits on, what it made, its branch and the log.
struct AgentRunView: View {
    @Environment(AppModel.self) private var app
    let runID: UUID
    @State private var message: String?
    @State private var confirmUndo = false
    @State private var working = false

    var body: some View {
        if let run = app.agents.run(runID) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(run)
                        if let message {
                            Text(message).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                        }
                        if run.state == .asking, let question = run.question {
                            AgentQuestionCard(runID: runID, question: question)
                        }
                        if let reason = run.pauseReason, run.state == .paused {
                            Label(reason, systemImage: "pause.circle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                        }
                        if let error = run.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        StudioCard(title: "Schritte", symbol: "list.number") {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                                    stepRow(run, index: index, step: step)
                                }
                            }
                        }
                        if !run.results.isEmpty {
                            StudioCard(title: "Ergebnisse", symbol: "shippingbox") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(run.results, id: \.self) { result in
                                        Button {
                                            app.openAgentResult(result)
                                        } label: {
                                            Label("\(result.title ?? "Ohne Titel") – \(AgentStyle.label(ofResult: result.kind))", systemImage: "arrow.up.forward.square")
                                                .font(.system(size: 12.5))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                        }
                        gitCard(run)
                    }
                    .padding(18)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .confirmationDialog("Lauf „\(run.title)“ zurücknehmen?", isPresented: $confirmUndo) {
                Button("Zurücknehmen", role: .destructive) { undo() }
            } message: {
                Text("Ein neuer Commit macht die \(run.commits.count) Schritt-Commits des Laufs rückgängig. Deine eigenen Änderungen bleiben. Das lässt sich im Git Studio wieder umkehren.")
            }
        } else {
            StudioEmptyState(symbol: "questionmark.square.dashed", title: "Lauf nicht gefunden", text: "Er ist zu alt und wurde aufgeräumt.")
        }
    }

    private func header(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: AgentStyle.symbol(run.state))
                    .font(.system(size: 18))
                    .foregroundStyle(AgentStyle.color(run.state))
                Text(run.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Tag(text: run.state.label, color: AgentStyle.color(run.state))
                Spacer(minLength: 8)
                controls(run)
            }
            HStack(spacing: 12) {
                Text(started(run)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                Text("\(run.doneCount) von \(run.steps.count) Schritten").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Text("Lauf \(run.shortID)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                if run.hadUntrusted { Tag(text: "fremd gelesen", color: Theme.warning) }
                Button("Aufgabe") { app.agents.selection = .task(run.taskID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                    .disabled(app.agents.task(run.taskID) == nil)
            }
        }
    }

    private func started(_ run: AgentRun) -> String {
        let trigger = switch run.trigger {
        case .person: "von dir"
        case .schedule: "nach Zeitplan"
        case .chat: "aus einem Chat"
        case .terminal: "aus dem Terminal"
        }
        guard let start = run.startedAt else { return "wartet seit \(run.queuedAt.formatted(date: .omitted, time: .shortened)), \(trigger)" }
        let end = run.endedAt ?? Date()
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return "gestartet \(start.formatted(date: .abbreviated, time: .shortened)) \(trigger) · \(minutes) min"
    }

    @ViewBuilder private func controls(_ run: AgentRun) -> some View {
        HStack(spacing: 6) {
            if run.state == .running || run.state == .queued {
                Button { app.pauseAgentRun(runID) } label: { Label("Anhalten", systemImage: "pause.fill") }
            }
            if run.state == .paused || run.state.canResume {
                Button { app.resumeAgentRun(runID) } label: { Label("Fortsetzen", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            }
            if run.state.isActive {
                Button(role: .destructive) { app.cancelAgentRun(runID) } label: { Label("Abbrechen", systemImage: "stop.fill") }
            }
            if run.state.isOver, run.state != .undone, !run.commits.isEmpty, run.mergeCommit != nil {
                Button { confirmUndo = true } label: { Label("Zurücknehmen", systemImage: "arrow.uturn.backward") }
                    .disabled(working || app.agents.activeRunID != nil)
            }
        }
        .controlSize(.small)
    }

    private func stepRow(_ run: AgentRun, index: Int, step: AgentRunStep) -> some View {
        let definition = run.plan.indices.contains(index) ? run.plan[index] : nil
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: AgentStyle.symbol(step.state))
                    .font(.system(size: 14))
                    .foregroundStyle(AgentStyle.color(step.state))
                    .frame(height: 18)
                if index < run.steps.count - 1 {
                    Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(index + 1). \(step.title)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    if let definition {
                        Text(definition.kind == .agent ? "KI" : (definition.action ?? "Action"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if step.state == .running, let live = app.agents.live[runID] {
                        Text(live).font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                if let summary = step.summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(step.state == .failed ? Theme.danger : Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if !step.calls.isEmpty {
                        Text("\(step.calls.count) Aufruf\(step.calls.count == 1 ? "" : "e")\(step.calls.contains { !$0.ok } ? ", \(step.calls.filter { !$0.ok }.count) mit Fehler" : "")")
                    }
                    if step.rounds > 0, definition?.kind == .agent { Text("\(step.rounds) Runde\(step.rounds == 1 ? "" : "n")") }
                    if let commit = step.commit {
                        Label(String(commit.prefix(7)), systemImage: "arrow.triangle.branch").font(.system(size: 10.5, design: .monospaced))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func gitCard(_ run: AgentRun) -> some View {
        StudioCard(title: "Git", symbol: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 5) {
                if let branch = run.branch {
                    LabeledContent("Branch") { Text(branch).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    if let base = run.baseBranch { LabeledContent("Ausgehend von") { Text("\(base) · \(run.baseCommit?.prefix(7) ?? "")").font(.system(size: 12, design: .monospaced)) } }
                    LabeledContent("Commits der Schritte") { Text("\(run.commits.count)").monospacedDigit() }
                    if let merge = run.mergeCommit {
                        LabeledContent("Übernommen") { Text(merge == run.baseCommit ? "nichts zu übernehmen" : String(merge.prefix(7))).font(.system(size: 12, design: .monospaced)) }
                    } else if run.state.isOver, app.git.branch == branch {
                        HStack {
                            Text("Die Bibliothek steht noch auf diesem Branch.").font(.system(size: 12)).foregroundStyle(Theme.warning)
                            Button("Übernehmen und beenden") { finishBranch() }.controlSize(.small).disabled(working)
                        }
                    }
                    Button("Im Git Studio zeigen") { app.openGitStudio() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(run.options.usesBranch ? "Ohne Branch: Git war aus, als der Lauf begann." : "Ohne Branch (so eingestellt).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 12))
        }
    }

    private func undo() {
        working = true
        Task {
            defer { working = false }
            do {
                try await app.undoAgentRun(runID)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func finishBranch() {
        working = true
        Task {
            defer { working = false }
            do {
                try await app.finishAgentBranch(runID)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// A call that waits for the person: what, on what, and why. Only here (and in the power access) is it answered.
struct AgentQuestionCard: View {
    @Environment(AppModel.self) private var app
    let runID: UUID
    let question: AgentQuestion
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.warning)
                Text("Möchte: \(question.summary)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            if let target = question.target {
                Text("Ziel: \(target)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).lineLimit(compact ? 2 : 6)
            }
            Text("Action: \(question.action)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            if !compact, let detail = question.detail {
                Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.04)))
            }
            Text("Grund: \(question.reason)").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Einmal erlauben") { app.agents.answer(runID, allow: true) }
                    .buttonStyle(.borderedProminent)
                Button("Ablehnen") { app.agents.answer(runID, allow: false) }
                Button("Lauf abbrechen", role: .destructive) { app.cancelAgentRun(runID) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.4)))
    }
}
