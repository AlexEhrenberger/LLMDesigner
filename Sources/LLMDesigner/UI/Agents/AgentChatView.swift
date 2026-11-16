import SwiftUI

/// The chat in which a task takes shape: the person describes it, the model answers with a draft, which can be
/// saved, started or refined in the building blocks. "Halt mal an" or "weiter" pause and resume the agents.
struct AgentChatView: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        let chat = app.agents.chat
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty { intro }
                        ForEach(chat.messages) { message in
                            bubble(message)
                        }
                        if chat.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Plant …").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        if let error = chat.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                        }
                        if let runID = chat.cancelOffer, let run = app.agents.run(runID), run.state.isActive {
                            HStack {
                                Text("„\(run.title)“ wirklich abbrechen? Was fertig ist, bleibt.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                Button("Lauf abbrechen", role: .destructive) {
                                    app.cancelAgentRun(runID)
                                    chat.cancelOffer = nil
                                }
                                .controlSize(.small)
                            }
                        }
                        if let draft = chat.draft {
                            AgentDraftCard(draft: draft, compact: compact)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(compact ? 10 : 16)
                    .frame(maxWidth: compact ? .infinity : 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: chat.draft) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            composer
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Neue Aufgabe im Gespräch", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Beschreibe, was ein Agent tun soll und wann. Zum Beispiel: „Fasse mir werktags um 7:30 meine offenen ToDos in einem Dokument zusammen und schick den Mac danach schlafen.“")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("„Halt an“, „weiter“ oder „brich ab“ wirken auf die laufenden Agenten. Während das Modell hier oder in einem Chat antwortet, warten die Agenten.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func bubble(_ message: AgentPlanningChat.Message) -> some View {
        let isPerson = message.role == .person
        return HStack {
            if isPerson { Spacer(minLength: 40) }
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isPerson ? Theme.userBubble : Theme.ink.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isPerson ? .clear : Theme.border))
                .fixedSize(horizontal: false, vertical: true)
            if !isPerson { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        @Bindable var chat = app.agents.chat
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(chat.draft == nil ? "Was soll ein Agent tun?" : "Ändern, ergänzen oder „halt an“ …", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .onSubmit { app.sendAgentChat() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
            if chat.isWorking {
                IconButton(systemName: "stop.circle.fill", help: "Anhalten", size: 18, frameSize: 30) {
                    chat.task?.cancel()
                    chat.isWorking = false
                }
            } else {
                IconButton(systemName: "arrow.up.circle.fill", help: "Senden (↩)", size: 18, frameSize: 30) { app.sendAgentChat() }
                    .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !chat.messages.isEmpty {
                IconButton(systemName: "arrow.counterclockwise", help: "Gespräch neu beginnen", size: 13, frameSize: 30) { chat.reset() }
            }
        }
        .padding(compact ? 8 : 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// The task the chat proposes: steps, tools and time, with saving, starting and the building blocks.
struct AgentDraftCard: View {
    @Environment(AppModel.self) private var app
    let draft: AgentDraft
    var compact = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(Theme.accent)
                Text("Entwurf: \(draft.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            if !draft.goal.isEmpty {
                Text(draft.goal).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        if !compact, let instruction = step.instruction, !instruction.isEmpty {
                            Text(instruction).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if step.kind == .action {
                            Text(step.action ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        } else if let tools = step.tools, !tools.isEmpty {
                            Text(tools.joined(separator: " · ")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("Noch kein Werkzeug gewählt").font(.system(size: 10.5)).foregroundStyle(Theme.warning)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 11))
                Text(draft.schedule.summary + (draft.sleepAfter ? " · danach Ruhezustand" : ""))
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.textSecondary)
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
            }
            // No ViewThatFits: it measured every layout pass and made typing lag in the Stories Studio.
            if compact {
                VStack(alignment: .leading, spacing: 6) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    }

    @ViewBuilder private var buttons: some View {
        Button {
            save(start: true)
        } label: {
            Label(draft.schedule.isTimed ? "Speichern und jetzt einmal starten" : "Speichern und starten", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        Button {
            save(start: false)
        } label: {
            Label(draft.schedule.isTimed ? "Speichern (\(draft.schedule.summary))" : "Speichern", systemImage: "tray.and.arrow.down")
        }
        .controlSize(.small)
        Button {
            save(start: false, open: true)
        } label: {
            Label("Im Baukasten bearbeiten", systemImage: "square.stack.3d.up")
        }
        .controlSize(.small)
    }

    private func save(start: Bool, open: Bool = false) {
        do {
            let task = try app.saveAgentDraft(start: start)
            if open || !app.agentStepsOpen { app.agents.selection = .task(task.id) }
            if open { app.openAgentSteps(.task(task.id)) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
