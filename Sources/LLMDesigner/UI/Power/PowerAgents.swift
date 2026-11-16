import SwiftUI

/// AgentSteps in the power access: what the agents do now (status, question, log as a terminal) and the chat for a
/// new task, beside whatever is open in the main area.
struct PowerAgents: View {
    @Environment(AppModel.self) private var app
    @State private var showsChat = false

    var body: some View {
        let center = app.agents
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if center.isHalted {
                    HStack {
                        Label("Alle Agenten angehalten", systemImage: "pause.circle.fill").foregroundStyle(Theme.warning)
                        Spacer()
                        Button("Weiter") { center.isHalted = false }.controlSize(.small)
                    }
                    .font(.system(size: 12))
                }
                if let sleepAt = center.sleepAt {
                    HStack {
                        Label("Ruhezustand um \(sleepAt.formatted(date: .omitted, time: .standard))", systemImage: "moon.zzz.fill").foregroundStyle(Theme.accent)
                        Spacer()
                        Button("Wach bleiben") { center.cancelSleep() }.controlSize(.small)
                    }
                    .font(.system(size: 12))
                }
                ForEach(center.openQuestions) { run in
                    if let question = run.question {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                            AgentQuestionCard(runID: run.id, question: question, compact: true)
                        }
                    }
                }
                if let run = center.activeRun {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        AgentRunStatus(runID: run.id, compact: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                } else {
                    nextLine
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if showsChat {
                AgentChatView(compact: true)
                    .frame(maxHeight: .infinity)
                AgentTerminalView(run: nil, compact: true)
                    .frame(height: 150)
            } else {
                AgentTerminalView(run: nil, compact: true)
                    .frame(maxHeight: .infinity)
            }
            footer
        }
    }

    private var nextLine: some View {
        let center = app.agents
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").foregroundStyle(Theme.textTertiary)
            if let next = center.nextScheduled() {
                Text("Kein Agent arbeitet. Als Nächstes: „\(next.task.title)“ \(next.date.formatted(.relative(presentation: .named)))")
            } else if !center.queued.isEmpty {
                Text("\(center.queued.count) Lauf wartet.")
            } else {
                Text("Kein Agent arbeitet gerade.")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(2)
    }

    private var footer: some View {
        let center = app.agents
        return HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsChat.toggle() }
            } label: {
                Label(showsChat ? "Nur Protokoll" : "Neue Aufgabe im Chat", systemImage: showsChat ? "terminal" : "bubble.left.and.text.bubble.right")
            }
            Spacer(minLength: 0)
            IconButton(systemName: center.isHalted ? "play.fill" : "pause.fill", help: center.isHalted ? "Agenten weiterlaufen lassen" : "Alle Agenten anhalten", size: 11, frameSize: 26) {
                center.isHalted.toggle()
            }
            Button("Dashboard") { app.openAgentSteps() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
