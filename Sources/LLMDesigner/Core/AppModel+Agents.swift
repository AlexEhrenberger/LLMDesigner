import AppKit
import Foundation
import LLMDProtocol

/// AgentSteps: the runner, the schedule, Git per run and what the person does with runs. One run works at a time.
///
/// Built for a small local model (Qwen 3.5 9B): the app, not the model, goes through the plan. Each model step starts
/// with a fresh context (the goal, one line per finished step, its own instruction), a handful of tools and one tool
/// to say it is done. Git keeps the state in between: every step is a commit on the run's branch, so the next step
/// only needs a sentence, not the whole history, and a run can go on after a restart from its last finished step.
extension AppModel {
    static let agentAuthor = "AgentSteps <agentsteps@llm-designer.invalid>"
    private static let haltedKey = "agentStepsHalted"

    // MARK: Lifecycle

    func startAgents() {
        agents.loadIfNeeded()
        agents.recoverAfterLaunch()
        agents.isHalted = settings.bool(forKey: Self.haltedKey)
        agents.onHaltChange = { [weak self] halted in
            guard let self else { return }
            self.settings.set(halted, forKey: Self.haltedKey)
            if !halted { self.pumpAgentQueue() }
        }
        agents.scheduler = Task { [weak self] in
            // The model server and Git need a moment after the start.
            try? await Task.sleep(for: .seconds(6))
            while !Task.isCancelled {
                self?.tickAgentSchedules()
                self?.pumpAgentQueue()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        agents.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickAgentSchedules()
                self?.pumpAgentQueue()
            }
        }
    }

    /// Before the library closes: a working run stops and stands on "unterbrochen".
    func stopAgents() async {
        agents.isClosing = true
        agents.scheduler?.cancel()
        agents.cancelSleep()
        if let observer = agents.wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let runner = agents.runner {
            if let id = agents.activeRunID { agents.answer(id, allow: false) }
            runner.cancel()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await runner.value }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        agents.recoverAfterLaunch()
        agents.awake.release()
        agents.saveAll()
    }

    /// A chat answering (in any window) or the planning chat thinking: the person has the model, the run waits.
    var personUsesModel: Bool {
        agents.personUsesModelOverride ?? (!streamingMessageIDs.isEmpty || agents.chat.isWorking)
    }

    // MARK: Schedule and queue

    func tickAgentSchedules(now: Date = Date()) {
        for task in agents.tasks.records where task.schedule.isTimed && task.schedule.isOn && !agents.isActive(task.id) {
            guard task.schedule.isDue(now: now, lastStart: agents.lastScheduledStart(of: task.id)) else { continue }
            do {
                try enqueueAgentRun(task.id, trigger: .schedule, at: now)
            } catch {
                // A task that can't run now is skipped for this time; the next time tries again.
                var skipped = AgentRun(task: task, trigger: .schedule)
                skipped.state = .failed
                skipped.error = error.localizedDescription
                skipped.endedAt = now
                skipped.append(.error, "Zeitplan: nicht gestartet – \(error.localizedDescription)")
                agents.runs.add(skipped)
            }
        }
    }

    /// Puts a run of the task into the queue; it starts as soon as nothing else runs.
    /// `at` is the moment the schedule met; the next due time is measured against it.
    @discardableResult
    func enqueueAgentRun(_ taskID: UUID, trigger: AgentRun.Trigger, at time: Date = Date()) throws -> AgentRun {
        guard let task = agents.task(taskID) else { throw AgentError.notFound("Die Aufgabe gibt es nicht.") }
        guard !task.steps.isEmpty else { throw AgentError.invalid("„\(task.title)“ hat noch keine Schritte.") }
        if let problem = task.steps.compactMap(\.problem).first { throw AgentError.invalid(problem) }
        guard !agents.isActive(taskID) else { throw AgentError.busy("„\(task.title)“ läuft schon oder wartet in der Schlange.") }
        var run = AgentRun(task: task, trigger: trigger)
        run.queuedAt = time
        let reason = switch trigger {
        case .person: "von dir gestartet"
        case .schedule: "Zeitplan: \(task.schedule.summary)"
        case .chat: "aus einem Chat"
        case .terminal: "aus dem Terminal"
        }
        run.append(.info, "In der Warteschlange (\(reason))")
        agents.runs.add(run)
        agents.runs.saveNow(run.id)
        pumpAgentQueue()
        return run
    }

    func pumpAgentQueue() {
        guard agents.activeRunID == nil, !agents.isHalted, !agents.isClosing, let next = agents.queued.first else { return }
        agents.cancelSleep()
        agents.activeRunID = next.id
        agents.runner = Task { [weak self] in
            await self?.executeAgentRun(next.id)
            guard let self else { return }
            self.agents.activeRunID = nil
            self.agents.runner = nil
            self.afterAgentRun(next.id)
            self.pumpAgentQueue()
        }
    }

    private func afterAgentRun(_ id: UUID) {
        guard let run = agents.run(id) else { return }
        agents.live[id] = nil
        agents.webEvidence[id] = nil
        if agents.queued.isEmpty { agents.awake.release() }
        switch run.state {
        case .finished:
            agents.notify("Fertig: \(run.title)", run.steps.last(where: { $0.summary != nil })?.summary ?? "\(run.doneCount) Schritte erledigt.")
            if run.options.sleepAfter, agents.queued.isEmpty, !agents.isClosing { agents.scheduleSleep(after: id) }
        case .failed:
            agents.notify("Fehler: \(run.title)", run.error ?? "Der Lauf ist nicht fertig geworden.")
        default:
            break
        }
    }

    // MARK: A run

    private enum StepResult {
        case done(String, [String: JSONValue]?)
        case failed(String)
    }

    private func executeAgentRun(_ id: UUID) async {
        guard let first = agents.run(id) else { return }
        let resuming = first.startedAt != nil
        agents.runs.update(id, touch: false) { run in
            run.state = .running
            run.startedAt = run.startedAt ?? Date()
            run.endedAt = nil
            run.error = nil
            run.pauseReason = nil
            run.append(.info, resuming ? "Lauf geht weiter: „\(run.title)“" : "Lauf gestartet: „\(run.title)“ – \(run.steps.count) Schritte")
        }
        agents.awake.hold("AgentSteps: \(first.title)")
        agents.log(id, .info, "Der Mac bleibt wach, solange der Agent arbeitet.")
        agents.webEvidence[id] = first.origin == .own ? Array(WebToolGuard.addresses(in: first.goal + "\n" + first.plan.compactMap(\.instruction).joined(separator: "\n"))) : []

        var failure: String?
        var cancelled = false
        do {
            guard let registry = actionRegistry else { throw AgentError.busy("Die Actions der App sind noch nicht bereit.") }
            // Only the interface answers an agent's questions: they go to the run's inbox, never to a dialog.
            registry.approval.agentPresenter = { [weak self] request in await self?.agents.ask(request) ?? false }
            let state = registry.runState(id: id.uuidString, channel: .agent)
            state.approval = first.options.approval
            if first.origin == .foreign || first.hadUntrusted { state.markUntrusted() }
            if first.hadSensitive { state.markSensitive() }

            try await agentPrepareGit(id)
            for index in first.plan.indices {
                guard let run = agents.run(id), run.steps.indices.contains(index) else { break }
                if run.steps[index].state == .done || run.steps[index].state == .skipped { continue }
                try await agentCheckpoint(id)
                try await agentCommitPersonChanges(id)
                let definition = run.plan[index]
                let result = try await runAgentStep(id, index: index, definition: definition, registry: registry, state: state)
                agents.runs.update(id, touch: false) { run in
                    run.hadUntrusted = run.hadUntrusted || state.hasReadUntrusted
                    run.hadSensitive = run.hadSensitive || state.hasReadSensitive
                }
                try await agentCommitStep(id, index: index)
                if case .failed(let reason) = result, definition.onError == .stop {
                    failure = "Schritt \(index + 1) „\(definition.title)“: \(reason)"
                    break
                }
            }
        } catch is CancellationError {
            cancelled = true
        } catch {
            if Task.isCancelled { cancelled = true } else { failure = error.localizedDescription }
        }

        // Whatever happened, the branch comes back. In a task of its own: this one may be cancelled.
        let closing = agents.isClosing
        if !closing {
            await Task { @MainActor in await self.agentFinishGit(id) }.value
        }
        agents.runs.update(id, touch: false) { run in
            run.question = nil
            run.endedAt = Date()
            for index in run.steps.indices where run.steps[index].state == .running { run.steps[index].state = .failed }
            if closing {
                run.state = .interrupted
                run.append(.pause, "Unterbrochen: Die Bibliothek wird geschlossen.")
            } else if cancelled {
                run.state = .cancelled
                run.append(.pause, "Abgebrochen.")
            } else if let failure {
                run.state = .failed
                run.error = failure
                run.append(.error, "Beendet mit Fehler: \(failure)")
            } else {
                run.state = .finished
                run.append(.done, "Fertig: \(run.doneCount) von \(run.steps.count) Schritten erledigt.")
            }
        }
        agents.yielding.remove(id)
        agents.runs.saveNow(id)
    }

    /// Waits while the run is paused, all agents are halted, or the person has the model (`beforeModel`).
    func agentCheckpoint(_ id: UUID, beforeModel: Bool = false) async throws {
        var announced = false
        while true {
            try Task.checkCancellation()
            guard let run = agents.run(id) else { throw CancellationError() }
            let paused = run.state == .paused || agents.isHalted
            let yielding = beforeModel && personUsesModel
            guard paused || yielding else { break }
            if yielding, !paused, !announced {
                announced = true
                agents.yielding.insert(id)
                agents.log(id, .pause, "Pausiert: Du arbeitest gerade mit dem Modell. Es geht weiter, sobald die Antwort fertig ist.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        if agents.yielding.remove(id) != nil { agents.log(id, .pause, "Weiter: Das Modell ist wieder frei.") }
    }

    private func runAgentStep(_ id: UUID, index: Int, definition: AgentStepDefinition, registry: ActionRegistry, state: RunState) async throws -> StepResult {
        let total = agents.run(id)?.steps.count ?? 0
        agents.runs.update(id, touch: false) { run in
            run.steps[index].state = .running
            run.steps[index].startedAt = Date()
            run.steps[index].calls = []
            run.steps[index].rounds = 0
            run.append(.step, "Schritt \(index + 1)/\(total): \(definition.title) (\(definition.kind.label))")
        }
        let result: StepResult
        switch definition.kind {
        case .action: result = try await runAgentActionStep(id, index: index, definition: definition, registry: registry)
        case .agent: result = try await runAgentModelStep(id, index: index, definition: definition, registry: registry, state: state)
        }
        agents.runs.update(id, touch: false) { run in
            run.steps[index].endedAt = Date()
            switch result {
            case .done(let summary, let output):
                run.steps[index].state = .done
                run.steps[index].summary = summary
                run.steps[index].output = output
                run.append(.done, "Schritt \(index + 1) erledigt: \(AgentWords.excerpt(summary, limit: 240))")
            case .failed(let reason):
                run.steps[index].state = .failed
                run.steps[index].summary = reason
                run.append(.error, "Schritt \(index + 1) nicht erledigt: \(reason)")
            }
        }
        return result
    }

    // MARK: Action steps

    private func runAgentActionStep(_ id: UUID, index: Int, definition: AgentStepDefinition, registry: ActionRegistry) async throws -> StepResult {
        guard let actionID = definition.action, let descriptor = registry.descriptor(actionID) else {
            return .failed("Die Action „\(definition.action ?? "")“ gibt es nicht.")
        }
        guard descriptor.module != "agents" else { return .failed("Ein Lauf startet keine Agenten.") }
        guard let run = agents.run(id) else { throw CancellationError() }
        let args = AgentPlaceholders.resolve(definition.arguments ?? .object([:]), steps: run.steps, current: index, goal: run.goal)
        try await agentCheckpoint(id)
        do {
            let result = try await registry.run(actionID, args: args, app: self, channel: .agent, run: id.uuidString)
            let summary = AgentWords.sentence(for: descriptor, result: result)
            agents.runs.update(id, touch: false) { run in
                run.steps[index].calls.append(AgentCall(action: actionID, target: Self.agentTarget(args), ok: true))
                if let made = AgentWords.result(of: descriptor, args: args, output: result), !run.results.contains(made) { run.results.append(made) }
                run.append(.tool, "\(actionID) → \(AgentWords.excerpt(summary))")
            }
            return .done(summary, AgentPlaceholders.smallValues(of: result))
        } catch {
            let message = (error as? RPCError)?.message ?? error.localizedDescription
            agents.runs.update(id, touch: false) { run in
                run.steps[index].calls.append(AgentCall(action: actionID, target: Self.agentTarget(args), ok: false, error: message))
                run.append(.error, "\(actionID) → \(message)")
            }
            try Task.checkCancellation()
            return .failed(message)
        }
    }

    // MARK: Model steps

    private func agentModel(for run: AgentRun) throws -> (client: LLMClient, model: LMModel) {
        if let wanted = run.options.model, let client {
            return (client, models.first { $0.id == wanted } ?? LMModel(id: wanted))
        }
        return try studioModel()
    }

    /// What a model step reads: why the run exists, what is done, and its own task. Nothing of the earlier rounds:
    /// that is what keeps a 9B model on track in step five.
    static func agentStepPrompt(run: AgentRun, index: Int, definition: AgentStepDefinition) -> String {
        var lines = ["Auftrag: \(run.goal.isEmpty ? run.title : run.goal)"]
        let done = run.steps.prefix(index).enumerated().filter { $0.element.state == .done }
        if !done.isEmpty {
            lines.append("")
            lines.append("Bisher erledigt:")
            for (number, step) in done { lines.append("\(number + 1). \(step.title): \(String((step.summary ?? "erledigt").prefix(1_800)))") }
        }
        if !run.results.isEmpty {
            lines.append("")
            lines.append("In diesem Lauf angelegt:")
            for result in run.results.suffix(12) { lines.append("- \(result.kind) „\(result.title ?? "ohne Titel")“, ID \(result.id)") }
        }
        lines.append("")
        lines.append("Dein Schritt (\(index + 1) von \(run.steps.count)): \(definition.title)")
        lines.append(definition.instruction ?? "")
        lines.append("")
        lines.append("Wenn du fertig bist, rufe \(AgentToolbox.finishName) auf.")
        return lines.joined(separator: "\n")
    }

    private func runAgentModelStep(_ id: UUID, index: Int, definition: AgentStepDefinition, registry: ActionRegistry, state: RunState) async throws -> StepResult {
        guard let run = agents.run(id) else { throw CancellationError() }
        let toolbox = AgentToolbox(registry: registry, selection: definition.tools ?? [])
        guard !toolbox.isEmpty else { return .failed("Für diesen Schritt ist kein Werkzeug gewählt.") }
        let (client, model) = try agentModel(for: run)
        let budget = max(12_000, (model.workingContextLength ?? 16_384) * 2)
        let resultLimit = min(AgentToolbox.resultLimit, budget / 5)
        let definitions = toolbox.definitions
        var system = toolbox.systemPrompt()
        if definition.thinking == true, !client.provider.switchesThinking, model.thinksOnThinkToken { system = "<|think|>" + system }
        var messages = [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: Self.agentStepPrompt(run: run, index: index, definition: definition)),
        ]
        var nudged = false
        var seen: [String: Int] = [:]
        var lastCreated: String?
        var lastContent = ""

        for round in 1...definition.rounds {
            try await agentCheckpoint(id, beforeModel: true)
            agents.runs.update(id, touch: false) { $0.steps[index].rounds = round }
            agents.live[id] = "Runde \(round): denkt nach …"
            Self.trimAgentHistory(&messages, budget: budget)
            let stream = client.streamChat(model: model.id, messages: messages, temperature: 0.2, tools: definitions, thinking: definition.thinking == true)
            let outcome = await StreamRound.read(stream, interval: .milliseconds(400)) { [weak self] snapshot in
                let parts = ThinkingSplitter.split(snapshot.raw)
                let text = parts.content.isEmpty ? (snapshot.reasoning.isEmpty ? parts.reasoning : snapshot.reasoning) : parts.content
                self?.agents.live[id] = "Runde \(round): " + AgentWords.excerpt(String(text.suffix(400)), limit: 160)
            }
            try Task.checkCancellation()
            if let error = outcome.error { throw error }
            var content = ThinkingSplitter.split(outcome.round.raw).content
            var calls = outcome.round.toolCalls
            if calls.isEmpty { calls = AgentCallParser.calls(in: content) }
            if let leaked = WebTools.leakedCallStart(in: content) { content = String(content[..<leaked]) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                agents.log(id, .model, AgentWords.excerpt(content, limit: 220))
                lastContent = content
            }

            guard !calls.isEmpty else {
                // A small model often answers in prose when it thinks it is done; once it is reminded of the tools.
                if !nudged, round < definition.rounds {
                    nudged = true
                    messages.append(ChatPayloadMessage(role: "assistant", content: content))
                    messages.append(ChatPayloadMessage(role: "user", content: "Rufe jetzt ein Werkzeug auf. Ist der Schritt schon erledigt, rufe \(AgentToolbox.finishName) mit dem Ergebnis auf."))
                    continue
                }
                return .done(content.isEmpty ? "Ohne Bericht beendet." : content, lastCreated.map { ["id": .string($0)] })
            }

            messages.append(ChatPayloadMessage(role: "assistant", content: content, toolCalls: calls))
            for (number, call) in calls.enumerated() {
                if call.function.name == AgentToolbox.finishName {
                    let args = (try? JSONValue.parse(call.function.arguments)) ?? .object([:])
                    let given = args["ergebnis"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = Self.agentHandOver(result: given, notes: lastContent)
                    var output: [String: JSONValue] = ["satz": .string(text)]
                    if let lastCreated { output["id"] = .string(lastCreated) }
                    return args["erfolg"]?.boolValue == false ? .failed(text) : .done(text, output)
                }
                guard number < AgentToolbox.maxCallsPerRound else {
                    messages.append(ChatPayloadMessage(role: "tool", content: "Übersprungen: Rufe höchstens \(AgentToolbox.maxCallsPerRound) Werkzeuge auf einmal auf.", toolCallID: call.id))
                    continue
                }
                let signature = call.function.name + call.function.arguments
                seen[signature, default: 0] += 1
                if seen[signature, default: 0] >= 3 {
                    return .failed("Der Agent hat denselben Aufruf dreimal wiederholt (\(call.function.name)).")
                }
                let (text, created) = try await agentExecute(call, toolbox: toolbox, id: id, index: index, registry: registry, state: state, limit: resultLimit)
                if let created { lastCreated = created }
                messages.append(ChatPayloadMessage(role: "tool", content: text, toolCallID: call.id))
            }
        }
        return .failed("Nach \(definition.rounds) Runden war der Schritt nicht fertig.")
    }

    /// What a model step hands to the next ones. A 9B model often writes the findings into its text and then gives
    /// `schritt_fertig` only a count ("2 offene ToDos"); the next step, which sees nothing else, then invented
    /// "ToDo 1, ToDo 2". So the step's last text goes along when it says clearly more than the result.
    static func agentHandOver(result: String, notes: String, limit: Int = 800) -> String {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return notes.isEmpty ? "Schritt beendet." : String(notes.suffix(limit)) }
        // A result that lists things already names them; the model's thinking aloud would only cost context.
        let listed = result.split(separator: "\n").filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return ["-", "•", "*"].contains { text.hasPrefix($0) } || text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        }
        guard listed.count < 2, notes.count > result.count + 40, !result.contains(notes.prefix(80)) else { return result }
        // The findings usually stand at the end, just before the model says it is done.
        return result + "\n" + String(notes.suffix(limit))
    }

    /// Old tool results give way first when the history grows past what the model can read; the instruction stays.
    static func trimAgentHistory(_ messages: inout [ChatPayloadMessage], budget: Int) {
        var total = messages.reduce(0) { $0 + $1.content.count }
        guard total > budget else { return }
        for index in messages.indices where index > 1 && messages[index].role == "tool" && total > budget {
            let before = messages[index].content.count
            guard before > 120 else { continue }
            messages[index].content = "[Älteres Ergebnis gekürzt.]"
            total -= before - messages[index].content.count
        }
    }

    /// Runs one call of the model through the registry (or the web tools). Returns the text for the model and the id
    /// of something it created.
    private func agentExecute(_ call: ToolCall, toolbox: AgentToolbox, id: UUID, index: Int, registry: ActionRegistry, state: RunState, limit: Int) async throws -> (String, String?) {
        let name = call.function.name
        if AgentToolbox.webTools.contains(name) {
            return (try await agentWebCall(call, toolbox: toolbox, id: id, index: index, state: state, limit: limit), nil)
        }
        guard let action = toolbox.action(forTool: name) else {
            let names = toolbox.definitions.map(\.function.name).joined(separator: ", ")
            agents.log(id, .error, "Unbekanntes Werkzeug „\(name)“")
            return ("Fehler: Das Werkzeug „\(name)“ gibt es nicht. Verfügbar sind: \(names).", nil)
        }
        let trimmed = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = try? JSONValue.parse(trimmed.isEmpty ? "{}" : trimmed), raw.objectValue != nil else {
            return ("Fehler: Die Parameter von \(name) sind kein gültiges JSON-Objekt. Erwartet: \(AgentToolbox.parameterHint(action)).", nil)
        }
        let (args, dropped) = AgentArguments.coerce(raw, schema: action.input)
        let note = dropped.isEmpty ? "" : " (Unbekannte Parameter ignoriert: \(dropped.joined(separator: ", ")).)"
        try await agentCheckpoint(id)
        do {
            let result = try await registry.run(action.id, args: args, app: self, channel: .agent, run: id.uuidString)
            let made = AgentWords.result(of: action, args: args, output: result)
            agents.runs.update(id, touch: false) { run in
                run.steps[index].calls.append(AgentCall(action: action.id, target: Self.agentTarget(args), ok: true))
                if let made, !run.results.contains(made) { run.results.append(made) }
                run.append(.tool, "\(action.id)\(Self.agentTarget(args).map { " „\($0)“" } ?? "") → ok")
            }
            var text = result.jsonLine()
            if text.count > limit { text = String(text.prefix(limit)) + " […gekürzt]" }
            if state.hasReadUntrusted { text = ForeignFrame.wrap(text) }
            return ("Ergebnis von \(name)\(note): \(text)", made?.id)
        } catch {
            try Task.checkCancellation()
            let rpc = error as? RPCError
            let message = rpc?.message ?? error.localizedDescription
            agents.runs.update(id, touch: false) { run in
                run.steps[index].calls.append(AgentCall(action: action.id, target: Self.agentTarget(args), ok: false, error: message))
                run.append(.error, "\(action.id) → \(message)")
            }
            var text = "Fehler bei \(name): \(message)"
            if rpc?.code == RPCError.invalidParamsCode { text += " Erwartet: \(AgentToolbox.parameterHint(action))." }
            if rpc?.code == RPCError.deniedCode { text += " Versuche es nicht auf anderem Weg; beende den Schritt, wenn es ohne nicht geht." }
            return (text, nil)
        }
    }

    /// Web search and pages, by the same rules as in a chat: addresses only from the person's task or this run's
    /// search results, and a run that has read private data asks first.
    private func agentWebCall(_ call: ToolCall, toolbox: AgentToolbox, id: UUID, index: Int, state: RunState, limit: Int) async throws -> String {
        guard let step = WebTools.step(for: call, allowed: toolbox.web) else {
            return "Fehler: Das Werkzeug „\(call.function.name)“ ist in diesem Schritt nicht frei."
        }
        if step.kind == .openPage, let refusal = WebToolGuard.refusal(forOpening: step.argument, trusted: agents.webEvidence[id] ?? []) {
            agents.log(id, .error, "\(call.function.name) „\(AgentWords.excerpt(step.argument, limit: 80))“ → abgelehnt")
            return refusal
        }
        try await agentCheckpoint(id)
        if state.hasReadSensitive, step.kind == .openPage || step.kind == .search {
            let request = ApprovalRequest(action: call.function.name, summary: step.kind == .search ? "Im Web suchen" : "Seite öffnen", channel: .agent,
                                          target: step.argument, detail: nil,
                                          reason: "Dieser Lauf hat private Daten gelesen. Über Suchbegriffe oder Adressen könnten sie die App verlassen.", run: id.uuidString)
            guard await agents.ask(request) else { return "Nicht freigegeben: Die Person hat das abgelehnt." }
        }
        let (done, text) = await WebTools.execute(step, limit: limit, readerFallback: webReaderFallback)
        try Task.checkCancellation()
        state.markUntrusted()
        if done.kind == .search || done.kind.isWikipedia {
            let found = (done.sources ?? []).compactMap { NormalizedAddress($0.url) }
            agents.webEvidence[id, default: []].append(contentsOf: found)
        }
        agents.runs.update(id, touch: false) { run in
            run.hadUntrusted = true
            run.steps[index].calls.append(AgentCall(action: call.function.name, target: AgentWords.excerpt(done.argument, limit: 80), ok: done.status == .done, error: done.error))
            run.append(done.status == .done ? .tool : .error, "\(call.function.name) „\(AgentWords.excerpt(done.argument, limit: 80))“ → \(done.status == .done ? "ok" : done.error ?? "Fehler")")
        }
        return ForeignFrame.wrap(text)
    }

    /// What a call is about, for the log: a title or id, never a text.
    static func agentTarget(_ args: JSONValue) -> String? {
        for key in ["doc", "deck", "title", "world", "source", "note", "project", "course", "podcast", "chat", "name", "block"] {
            if let value = args[key]?.stringValue, !value.isEmpty { return AgentWords.excerpt(value, limit: 60) }
        }
        return nil
    }

    // MARK: Git

    /// Retries while Git is busy with something of the person's (a refresh of the Git Studio, a commit).
    private func agentGit<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let error as GitError {
                guard case .busy = error, attempt < 6 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private static func agentTrailers(_ run: AgentRun, step: String?) -> [(String, String)] {
        var trailers = [("Auftrag", "\(run.title) (\(run.shortID))")]
        if let step { trailers.append(("Schritt", step)) }
        trailers.append(("Lauf", run.id.uuidString))
        return trailers
    }

    /// A branch name from the title: `agent/morgenbericht-1a2b3c4d`.
    static func agentBranchName(_ run: AgentRun) -> String {
        let folded = run.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss").lowercased()
        var slug = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber { slug.append(character) } else if slug.last != "-" { slug.append("-") }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "agent/\(slug.isEmpty ? "lauf" : slug)-\(run.shortID)"
    }

    /// Before the first step: what the person has open goes into a commit on the current branch, then the run gets
    /// its own branch at that commit. The files stay as they are; only the branch name changes.
    private func agentPrepareGit(_ id: UUID) async throws {
        guard let run = agents.run(id) else { return }
        guard run.options.usesBranch else {
            agents.log(id, .git, "Ohne eigenen Branch (so eingestellt).")
            return
        }
        guard git.isEnabled else {
            agents.log(id, .git, "Git ist für diese Bibliothek aus: Der Lauf arbeitet ohne Branch und ohne Zwischenstände. Schalte Git im Power-Zugriff ein, dann bekommt jeder Lauf einen eigenen Branch.")
            return
        }
        await git.refresh()
        if git.isMerging || git.status?.hasConflicts == true {
            throw AgentError.busy("Git führt gerade zusammen. Schließe das im Git Studio ab, dann kann der Lauf starten.")
        }
        if let branch = run.branch, run.mergeCommit == nil {
            guard git.branch == branch else {
                throw AgentError.busy("Die Bibliothek steht nicht mehr auf „\(branch)“. Wechsle im Git Studio dorthin oder starte die Aufgabe neu.")
            }
            agents.log(id, .git, "Weiter auf Branch \(branch).")
            return
        }
        try await ensureAgentIgnore()
        saveEverythingForGit()
        await git.refresh()
        if !git.changes.isEmpty {
            try await agentGit { _ = try await git.commit(nil, message: "Stand vor dem Lauf „\(run.title)“") }
            agents.log(id, .git, "Offene Änderungen committet: Stand vor dem Lauf.")
        }
        await git.refresh()
        guard let base = git.branch, let head = git.status?.head else {
            throw AgentError.busy("Git hat noch keinen Commit oder steht auf keinem Branch. Ein Lauf braucht beides.")
        }
        let name = Self.agentBranchName(run)
        try await agentGit { try await git.createBranch(name, switchTo: true) }
        await git.refresh()
        agents.runs.update(id, touch: false) { run in
            run.branch = name
            run.baseBranch = base
            run.baseCommit = head
            run.append(.git, "Branch \(name) angelegt, ausgehend von \(base) (\(head.prefix(7))).")
        }
        agents.runs.saveNow(id)
    }

    /// The runs' folder stays out of Git, also in libraries whose `.gitignore` is older than AgentSteps.
    private func ensureAgentIgnore() async throws {
        let url = git.root.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = "/\(AgentCenter.runsPath)/"
        if !text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\n# AgentSteps: Protokolle der Läufe ändern sich bei jedem Schritt\n\(line)\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try await agentGit {
            try await git.perform("Protokolle aus Git") { repository in
                _ = try await repository.run(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", AgentCenter.runsPath], allowFailure: true)
            }
        }
    }

    /// What changed before a step and not by the run (the person kept working) gets a commit of its own, so the
    /// step's commit, and taking the run back, is only the run's.
    private func agentCommitPersonChanges(_ id: UUID) async throws {
        guard let run = agents.run(id), let branch = run.branch, run.mergeCommit == nil, git.isEnabled else { return }
        saveEverythingForGit()
        await git.refresh()
        guard git.branch == branch else {
            throw AgentError.busy("Die Bibliothek ist nicht mehr auf „\(branch)“. Der Lauf hält an, damit nichts in einen anderen Branch gerät.")
        }
        guard !git.changes.isEmpty else { return }
        try await agentGit { _ = try await git.commit(nil, message: "Zwischenstand während „\(run.title)“") }
        agents.log(id, .git, "Deine Änderungen während des Laufs committet (gehören nicht zum Lauf).")
    }

    /// One commit per step, with `Auftrag:`, `Schritt:` and `Lauf:`; the Git Studio marks such commits as an agent's.
    private func agentCommitStep(_ id: UUID, index: Int, label: String? = nil) async throws {
        guard let run = agents.run(id), let branch = run.branch, run.mergeCommit == nil, git.isEnabled, run.steps.indices.contains(index) else { return }
        saveEverythingForGit()
        await git.refresh()
        guard git.branch == branch else { return }
        guard !git.changes.isEmpty else {
            agents.log(id, .git, "Schritt \(index + 1): nichts in der Bibliothek geändert, kein Commit.")
            return
        }
        let step = run.steps[index]
        var message = "\(run.title) – Schritt \(index + 1): \(step.title)\(label.map { " (\($0))" } ?? "")"
        if let summary = step.summary { message += "\n\n" + AgentWords.excerpt(summary, limit: 600) }
        let trailers = Self.agentTrailers(run, step: "\(index + 1)/\(run.steps.count)")
        let commit = try await agentGit { try await git.commit(nil, message: message, trailers: trailers, author: Self.agentAuthor).commit }
        agents.runs.update(id, touch: false) { run in
            run.steps[index].commit = commit.id
            run.append(.git, "[\(branch) \(commit.shortID)] Schritt \(index + 1): \(step.title)")
        }
        agents.runs.saveNow(id)
    }

    private enum MergeBack {
        case nothing, merged(String), moved
    }

    /// After the last step (or a stop): a half step is committed, then the branch goes back into where the run
    /// started. The base hasn't moved while the library stood on the run's branch, so the merge commit is made
    /// without touching a file: the library shows what it showed, and nothing reloads.
    func agentFinishGit(_ id: UUID) async {
        guard let run = agents.run(id), let branch = run.branch, run.mergeCommit == nil, git.isEnabled,
              let base = run.baseBranch, let baseCommit = run.baseCommit else { return }
        await git.refresh()
        guard git.branch == branch else {
            agents.log(id, .git, "Die Bibliothek steht nicht mehr auf \(branch). Führe den Branch im Git Studio zusammen.")
            return
        }
        do {
            if let open = run.steps.firstIndex(where: { $0.state == .running || ($0.state == .failed && $0.commit == nil) }) {
                try await agentCommitStep(id, index: open, label: "unvollständig")
            } else {
                try await agentCommitPersonChanges(id)
            }
            let title = run.title
            let message = LibraryGit.commitMessage("Lauf „\(title)“ übernommen", groups: [], trailers: Self.agentTrailers(run, step: nil))
            let outcome: MergeBack = try await agentGit {
                try await git.perform("Lauf übernehmen") { repository in
                    func value(_ arguments: [String]) async throws -> String {
                        try await repository.run(arguments).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let head = try await value(["rev-parse", "HEAD"])
                    let baseNow = try await repository.run(["rev-parse", "--verify", "-q", "refs/heads/\(base)"], allowFailure: true)
                        .text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard baseNow == baseCommit else { return .moved }
                    if head == baseCommit {
                        try await repository.run(["symbolic-ref", "HEAD", "refs/heads/\(base)"])
                        _ = try await repository.run(["branch", "-d", branch], allowFailure: true)
                        return .nothing
                    }
                    let tree = try await value(["rev-parse", "HEAD^{tree}"])
                    let merge = try await repository.run(["commit-tree", tree, "-p", baseCommit, "-p", head, "-F", "-"], input: Data(message.utf8))
                        .text.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await repository.run(["update-ref", "-m", "AgentSteps: \(title) übernommen", "refs/heads/\(base)", merge, baseCommit])
                    try await repository.run(["symbolic-ref", "HEAD", "refs/heads/\(base)"])
                    return .merged(merge)
                }
            }
            await git.refresh()
            switch outcome {
            case .nothing:
                agents.runs.update(id, touch: false) { run in
                    run.mergeCommit = baseCommit
                    run.append(.git, "Nichts geändert: zurück auf \(base), Branch \(branch) entfernt.")
                }
            case .merged(let merge):
                agents.runs.update(id, touch: false) { run in
                    run.mergeCommit = merge
                    run.append(.git, "Übernommen: \(branch) → \(base) (\(merge.prefix(7))). Die Bibliothek ist wieder auf \(base).")
                }
            case .moved:
                agents.log(id, .git, "\(base) hat inzwischen eigene Commits. Die Bibliothek bleibt auf \(branch); führe ihn im Git Studio mit \(base) zusammen.")
            }
        } catch {
            agents.log(id, .error, "Git: \(error.localizedDescription)")
        }
        agents.runs.saveNow(id)
    }

    // MARK: What the person does

    func pauseAgentRun(_ id: UUID) {
        guard let run = agents.run(id), run.state == .running || run.state == .queued else { return }
        agents.runs.update(id, touch: false) { run in
            run.state = .paused
            run.pauseReason = "Von dir angehalten."
            run.append(.pause, "Angehalten. Der Lauf wartet, bis du ihn fortsetzt.")
        }
    }

    func resumeAgentRun(_ id: UUID) {
        guard let run = agents.run(id) else { return }
        if run.state == .paused {
            agents.runs.update(id, touch: false) { run in
                run.state = run.startedAt == nil || self.agents.activeRunID != id ? .queued : .running
                run.pauseReason = nil
                run.append(.pause, "Fortgesetzt.")
            }
            pumpAgentQueue()
        } else if run.state.canResume {
            agents.runs.update(id, touch: false) { run in
                run.state = .queued
                run.error = nil
                run.endedAt = nil
                for index in run.steps.indices where run.steps[index].state == .failed || run.steps[index].state == .running {
                    run.steps[index].state = .pending
                }
                run.append(.info, "Wird fortgesetzt ab dem ersten offenen Schritt.")
            }
            pumpAgentQueue()
        }
    }

    func cancelAgentRun(_ id: UUID) {
        guard let run = agents.run(id), run.state.isActive else { return }
        if agents.activeRunID == id {
            agents.answer(id, allow: false)
            agents.runner?.cancel()
        } else {
            agents.runs.update(id, touch: false) { run in
                run.state = .cancelled
                run.endedAt = Date()
                run.append(.pause, "Abgebrochen, bevor er anfing.")
            }
        }
    }

    /// Takes a run's commits back with one commit that does the opposite, after it was merged. Fails as a whole when
    /// later changes touch the same places.
    func undoAgentRun(_ id: UUID) async throws {
        guard let run = agents.run(id) else { throw AgentError.notFound("Den Lauf gibt es nicht.") }
        guard run.state.isOver, agents.activeRunID != id else { throw AgentError.busy("Der Lauf arbeitet noch.") }
        guard run.state != .undone else { throw AgentError.invalid("Dieser Lauf ist schon zurückgenommen.") }
        guard git.isEnabled else { throw AgentError.invalid("Ohne Git lässt sich ein Lauf nicht zurücknehmen.") }
        let commits = run.commits
        guard !commits.isEmpty else { throw AgentError.invalid("Dieser Lauf hat nichts in der Bibliothek geändert.") }
        await git.refresh()
        if let branch = run.branch, git.branch == branch { throw AgentError.busy("Die Bibliothek steht noch auf \(branch). Übernimm den Lauf zuerst.") }
        saveEverythingForGit()
        await git.refresh()
        if !git.changes.isEmpty { _ = try await git.commit(nil, message: "Stand vor dem Zurücknehmen von „\(run.title)“") }
        let message = LibraryGit.commitMessage("Lauf „\(run.title)“ zurückgenommen", groups: [], trailers: [("Lauf", run.id.uuidString)])
        try await git.perform("Lauf zurücknehmen", changesFiles: true) { repository in
            let result = try await repository.run(["revert", "--no-commit"] + commits.reversed(), allowFailure: true)
            guard result.succeeded else {
                _ = try? await repository.run(["revert", "--abort"], allowFailure: true)
                throw AgentError.busy("Der Lauf lässt sich nicht von selbst zurücknehmen: Spätere Änderungen betreffen dieselben Stellen. Stelle die Dinge im Git Studio einzeln wieder her.")
            }
            try await repository.run(["commit", "-q", "--author", Self.agentAuthor, "-F", "-"], input: Data(message.utf8))
            // Saved now: the library reloads right after this, and the run must already say so.
            agents.runs.update(id, touch: false) { run in
                run.state = .undone
                run.append(.git, "Zurückgenommen: \(commits.count) Commit(s) rückgängig gemacht.")
            }
            agents.runs.saveNow(id)
        }
    }

    /// The library still stands on the branch of a run that a quit interrupted: take over what is there.
    func finishAgentBranch(_ id: UUID) async throws {
        guard agents.activeRunID == nil else { throw AgentError.busy("Ein Lauf arbeitet gerade.") }
        guard let run = agents.run(id), let branch = run.branch, let base = run.baseBranch else { throw AgentError.notFound("Der Lauf hat keinen Branch.") }
        await agentFinishGit(id)
        await git.refresh()
        // Written before anything reloads the library, so the next model reads the run as finished.
        agents.runs.update(id, touch: false) { run in
            if run.state == .interrupted { run.state = .cancelled }
            run.append(.git, "Branch übernommen und Lauf beendet.")
        }
        agents.runs.saveNow(id)
        if git.branch == branch {
            // The base moved on: an ordinary merge, which reloads the library.
            try await commitAll("Stand von „\(run.title)“")
            try await git.switchBranch(base)
            _ = try await git.merge(branch, message: "Lauf „\(run.title)“ übernommen")
        }
    }

    private func commitAll(_ message: String) async throws {
        saveEverythingForGit()
        await git.refresh()
        if !git.changes.isEmpty { _ = try await git.commit(nil, message: message) }
    }

    // MARK: Tasks

    @discardableResult
    func createAgentTask(_ task: AgentTask) -> AgentTask {
        agents.tasks.add(task)
        agents.tasks.saveNow(task.id)
        return task
    }

    /// The task goes to the Trash; its runs stay until they age out.
    func deleteAgentTask(_ id: UUID) throws {
        guard !agents.isActive(id) else { throw AgentError.busy("Die Aufgabe läuft gerade oder wartet. Brich den Lauf zuerst ab.") }
        agents.tasks.remove(id)
        if case .task(id) = agents.selection { agents.selection = nil }
    }

    /// AgentSteps in the main area.
    func openAgentSteps(_ selection: AgentSelection? = nil) {
        closeDocument()
        showChats()
        agents.loadIfNeeded()
        if let selection { agents.selection = selection }
        agentStepsOpen = true
    }

    /// Opens what a run made: a document or presentation, otherwise the studio of its kind.
    func openAgentResult(_ result: AgentResult) {
        guard let id = UUID(uuidString: result.id) else { return }
        switch result.kind {
        case "writer", "presenter":
            if document(id) != nil { selectDocument(id) }
        case "notes": openNotesStudio()
        case "projects": if projects.project(id) != nil { openProjectID = id }
        case "research": openResearchStudio(new: false)
        case "learning": openLearningStudio()
        case "finance": openFinanceStudio()
        case "citation": openCitationStudio(showing: id)
        default: break
        }
    }

    // MARK: The planning chat

    /// A line about what the agents do, for the planning chat's model.
    var agentStatusLine: String {
        var parts: [String] = []
        if let run = agents.activeRun {
            let step = run.currentStepIndex.map { "Schritt \($0 + 1) von \(run.steps.count): \(run.steps[$0].title)" } ?? ""
            parts.append("„\(run.title)“ \(run.state.label), \(step)")
        }
        if !agents.queued.isEmpty { parts.append("\(agents.queued.count) in der Warteschlange") }
        if agents.isHalted { parts.append("alle Agenten sind angehalten") }
        if let next = agents.nextScheduled() { parts.append("als Nächstes „\(next.task.title)“ \(next.date.formatted(date: .abbreviated, time: .shortened))") }
        return parts.isEmpty ? "Kein Agent arbeitet gerade." : parts.joined(separator: "; ")
    }

    /// The person's message to the planning chat: the model answers with a draft, or with pausing, resuming or
    /// stopping the agents. Stopping only offers a button; the person confirms it.
    func sendAgentChat(_ text: String? = nil) {
        let chat = agents.chat
        let message = (text ?? chat.input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !chat.isWorking else { return }
        chat.input = ""
        chat.error = nil
        chat.cancelOffer = nil
        chat.messages.append(.init(role: .person, text: message))
        chat.isWorking = true
        chat.task = Task { [weak self] in
            guard let self else { return }
            defer { chat.isWorking = false }
            do {
                let (client, model) = try self.studioModel()
                var messages = [ChatPayloadMessage(role: "system", content: AgentPlanner.systemPrompt(draft: chat.draft, status: self.agentStatusLine))]
                for entry in chat.messages.suffix(12) {
                    messages.append(ChatPayloadMessage(role: entry.role == .person ? "user" : "assistant", content: entry.text))
                }
                let raw = try await client.complete(model: model.id, messages: messages, temperature: 0.3, maxTokens: 2_500,
                                                    orderedSchema: ("agentenaufgabe", AgentPlanner.schemaJSON))
                try Task.checkCancellation()
                var reply = AgentPlanner.parse(raw, previous: chat.draft)
                if reply.intent == .draft {
                    reply.draft = AgentPlanner.applyWords(reply.draft, personTexts: chat.messages.filter { $0.role == .person }.map(\.text))
                }
                chat.draft = reply.draft
                chat.messages.append(.init(role: .assistant, text: reply.text))
                self.applyAgentChatIntent(reply.intent)
            } catch is CancellationError {
            } catch {
                chat.error = error.localizedDescription
            }
        }
    }

    private func applyAgentChatIntent(_ intent: AgentPlanner.Intent) {
        let chat = agents.chat
        switch intent {
        case .pause:
            if let id = agents.activeRunID {
                pauseAgentRun(id)
            } else {
                agents.isHalted = true
            }
            chat.messages.append(.init(role: .assistant, text: "⏸ Angehalten. Sag „weiter“, wenn es weitergehen soll."))
        case .resume:
            agents.isHalted = false
            if let paused = agents.runs.records.first(where: { $0.state == .paused }) { resumeAgentRun(paused.id) }
            chat.messages.append(.init(role: .assistant, text: "▶ Es geht weiter."))
        case .cancel:
            chat.cancelOffer = agents.activeRunID
        case .draft, .none:
            break
        }
    }

    /// Saves the chat's draft as a task; with `start` it runs right away.
    @discardableResult
    func saveAgentDraft(start: Bool) throws -> AgentTask {
        guard let draft = agents.chat.draft else { throw AgentError.invalid("Es gibt noch keinen Entwurf.") }
        let task = createAgentTask(draft.task())
        agents.chat.reset()
        agents.selection = .task(task.id)
        if start { try enqueueAgentRun(task.id, trigger: .person) }
        return task
    }
}
