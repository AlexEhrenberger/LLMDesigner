import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerAgentActions() {
        register(AgentsStatusAction.self)
        register(AgentsCatalogAction.self)
        register(AgentsTaskListAction.self)
        register(AgentsTaskReadAction.self)
        register(AgentsTaskCreateAction.self)
        register(AgentsTaskUpdateAction.self)
        register(AgentsTaskDeleteAction.self)
        register(AgentsStepAddAction.self)
        register(AgentsStepRemoveAction.self)
        register(AgentsStepMoveAction.self)
        register(AgentsScheduleSetAction.self)
        register(AgentsRunStartAction.self)
        register(AgentsRunListAction.self)
        register(AgentsRunReadAction.self)
        register(AgentsRunPauseAction.self)
        register(AgentsRunResumeAction.self)
        register(AgentsRunCancelAction.self)
        register(AgentsRunUndoAction.self)
        register(AgentsApprovalsListAction.self)
        register(AgentsHaltAction.self)
        register(AgentsPlanAction.self)
    }
}

// MARK: - Shared

extension ActionContext {
    /// A run of AgentSteps doesn't make, change or start agents: that would be a loop no one asked for.
    func refuseAgents(_ what: String = "Agenten-Aufgaben") throws {
        guard channel != .agent else { throw RPCError.denied("\(what) ändert kein Agent selbst; das tut die Person.") }
    }

    /// Whoever isn't the person at the app or in their terminal writes a task as foreign.
    var writesForeignTasks: Bool { channel != .ui && channel != .cli }
}

extension AppModel {
    func actionAgentTask(_ reference: String) throws -> AgentTask {
        agents.loadIfNeeded()
        if let id = UUID(uuidString: reference) {
            guard let task = agents.task(id) else { throw RPCError.notFound("Die Aufgabe \(reference) gibt es nicht.") }
            return task
        }
        let found = agents.tasks.records.filter { $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Eine Aufgabe „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Aufgaben heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    /// A run by id or its short id; without one the run working now, otherwise the latest.
    func actionAgentRun(_ reference: String?) throws -> AgentRun {
        agents.loadIfNeeded()
        guard let reference, !reference.isEmpty else {
            guard let run = agents.activeRun ?? agents.history.first else { throw RPCError.notFound("Es gibt noch keinen Lauf.") }
            return run
        }
        if let id = UUID(uuidString: reference), let run = agents.run(id) { return run }
        let short = reference.lowercased()
        let found = agents.runs.records.filter { $0.shortID == short }
        if found.count == 1 { return found[0] }
        if let task = try? actionAgentTask(reference), let run = agents.lastRun(of: task.id) { return run }
        throw RPCError.notFound("Einen Lauf „\(reference)“ gibt es nicht.")
    }
}

enum AgentDates {
    /// ISO 8601 with or without seconds and zone; without a zone the Mac's.
    static func parse(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

struct AgentStepInput: Decodable, Sendable {
    var kind: AgentStepDefinition.Kind
    var title: String
    var action: String?
    var arguments: JSONValue?
    var instruction: String?
    var tools: [String]?
    var rounds: Int?
    var thinking: Bool?
    var onError: AgentStepDefinition.OnError?

    @MainActor
    func definition(registry: ActionRegistry) throws -> AgentStepDefinition {
        if kind == .action {
            guard let action, let descriptor = registry.descriptor(action) else {
                throw RPCError.invalidParams("Die Action „\(action ?? "")“ gibt es nicht. `llmd actions` listet alle.")
            }
            guard descriptor.module != "agents" else { throw RPCError.invalidParams("Ein Schritt kann keine Agenten-Actions aufrufen.") }
        }
        if let tools {
            let known = Set(AgentToolbox.groups.map(\.id))
            if let unknown = tools.first(where: { !known.contains($0) && registry.descriptor($0) == nil }) {
                throw RPCError.invalidParams("Das Werkzeug „\(unknown)“ gibt es nicht. Gruppen: \(known.sorted().joined(separator: ", ")).")
            }
        }
        var step = AgentStepDefinition(kind: kind, title: title, action: action, arguments: arguments, instruction: instruction, tools: tools)
        step.maxRounds = rounds
        step.thinking = thinking
        step.onError = onError ?? .stop
        return step
    }

    static let schema: JSONSchema = .object([
        "kind": .choice(AgentStepDefinition.Kind.allCases.map(\.rawValue), "action (eine Action mit festen Parametern) oder agent (KI-Schritt)"),
        "title": .string("Name des Schritts"),
        "action": .string("bei action: die Action-ID, z. B. writer.doc.create"),
        "arguments": .freeObject("bei action: ihre Parameter; Platzhalter {{schritt1.id}}, {{vorher.title}}, {{ziel}}, {{heute}}"),
        "instruction": .string("bei agent: was das Modell tun soll und was danach vorliegt"),
        "tools": .array(of: .string(), "bei agent: Werkzeuggruppen (agents.catalog) oder einzelne Action-IDs"),
        "rounds": .integer("bei agent: höchstens so viele Runden (Standard 12)", minimum: 2, maximum: 40),
        "thinking": .boolean("bei agent: gründlich nachdenken (langsamer)"),
        "onError": .choice(AgentStepDefinition.OnError.allCases.map(\.rawValue), "abbrechen (Standard) oder weiter"),
    ], required: ["kind", "title"])
}

struct AgentScheduleInput: Decodable, Sendable {
    var kind: AgentSchedule.Kind
    var time: String?
    var weekdays: [Int]?
    var everyMinutes: Int?
    var date: String?
    var catchUp: Bool?
    var on: Bool?

    func schedule(keeping old: AgentSchedule = AgentSchedule()) throws -> AgentSchedule {
        var schedule = old
        schedule.kind = kind
        if let time { schedule.time = time }
        if let weekdays { schedule.weekdays = weekdays }
        if let everyMinutes { schedule.intervalMinutes = everyMinutes }
        if let date {
            guard let parsed = AgentDates.parse(date) else { throw RPCError.invalidParams("„\(date)“ ist kein Zeitpunkt (z. B. 2026-11-16T07:30).") }
            schedule.date = parsed
        }
        if let catchUp { schedule.catchUp = catchUp }
        if let on { schedule.isOn = on }
        schedule.since = Date()
        if let problem = schedule.problem { throw RPCError.invalidParams(problem) }
        return schedule
    }

    static let schema: JSONSchema = .object([
        "kind": .choice(AgentSchedule.Kind.allCases.map(\.rawValue), "manuell, einmalig, taeglich, woechentlich oder intervall"),
        "time": .string("Uhrzeit HH:MM (taeglich, woechentlich)"),
        "weekdays": .array(of: .integer(minimum: 1, maximum: 7), "1 = Montag … 7 = Sonntag (woechentlich)"),
        "everyMinutes": .integer("Abstand in Minuten (intervall)", minimum: AgentSchedule.minimumInterval),
        "date": .string("Zeitpunkt für einmalig, z. B. 2026-11-16T07:30"),
        "catchUp": .boolean("Verpasste Zeiten nachholen (Standard ja)"),
        "on": .boolean("Zeitplan an oder aus"),
    ], required: ["kind"])
}

struct AgentTaskSummary: Encodable, Sendable {
    var id: String
    var title: String
    var steps: Int
    var schedule: String
    var nextRun: Date?
    var lastRun: String?
    var lastRunState: String?
    var origin: String
    var sleepAfter: Bool

    @MainActor
    init(_ task: AgentTask, center: AgentCenter) {
        id = task.id.uuidString
        title = task.title
        steps = task.steps.count
        schedule = task.schedule.isOn ? task.schedule.summary : "\(task.schedule.summary) (aus)"
        nextRun = center.nextRun(of: task)
        let last = center.lastRun(of: task.id)
        lastRun = last?.id.uuidString
        lastRunState = last?.state.rawValue
        origin = task.origin.rawValue
        sleepAfter = task.options.sleepAfter
    }
}

struct AgentRunSummary: Encodable, Sendable {
    var id: String
    var shortID: String
    var task: String
    var title: String
    var state: String
    var trigger: String
    var step: Int?
    var steps: Int
    var done: Int
    var branch: String?
    var startedAt: Date?
    var endedAt: Date?
    var question: String?
    var error: String?

    init(_ run: AgentRun) {
        id = run.id.uuidString
        shortID = run.shortID
        task = run.taskID.uuidString
        title = run.title
        state = run.state.rawValue
        trigger = run.trigger.rawValue
        step = run.state.isActive ? run.currentStepIndex.map { $0 + 1 } : nil
        steps = run.steps.count
        done = run.doneCount
        branch = run.branch
        startedAt = run.startedAt
        endedAt = run.endedAt
        question = run.question.map { "\($0.summary): \($0.reason)" }
        error = run.error
    }
}

/// A change of a task that the undo arrow of a chat answer or `llmd` can take back.
@MainActor
private func recordTaskChange(_ context: ActionContext, before: AgentTask?, id: UUID) {
    let app = context.app
    let after = app.agents.task(id)
    context.undoGroup.add(UndoStep(label: "Agenten-Aufgabe", undo: { [weak app] in
        guard let app else { return }
        if let before { app.agents.tasks.restore(before) } else { app.agents.tasks.remove(id) }
    }, redo: { [weak app] in
        guard let app, let after else { return }
        app.agents.tasks.restore(after)
    }))
}

private let taskProperty: [String: JSONSchema] = ["task": .string("Aufgabe (ID oder Titel)")]
private let runProperty: [String: JSONSchema] = ["id": .string("Lauf (ID, Kurz-ID oder Titel der Aufgabe); Standard: der laufende oder letzte")]

struct AgentTaskRefArgs: Decodable, Sendable {
    var task: String
}

struct AgentRunRefArgs: Decodable, Sendable {
    /// Not `run`: `--run` is the terminal's own option for the run of a script.
    var id: String?
}

// MARK: - Overview

struct AgentsStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var active: AgentRunSummary?
        var queued: [AgentRunSummary]
        var questions: Int
        var halted: Bool
        var keepsAwake: Bool
        var next: String?
        var nextAt: Date?
        var sleepAt: Date?
        var tasks: Int
    }
    static let descriptor = ActionDescriptor(
        id: "agents.status", summary: "Zeigt, was die Agenten gerade tun und was als Nächstes kommt", kind: .read, security: .plainRead,
        input: .object(), output: .freeObject(), example: "llmd agents status", groups: ["agents.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let center = context.app.agents
        center.loadIfNeeded()
        let next = center.nextScheduled()
        return Output(active: center.activeRun.map(AgentRunSummary.init), queued: center.queued.map(AgentRunSummary.init), questions: center.openQuestions.count,
                      halted: center.isHalted, keepsAwake: center.awake.isHolding, next: next?.task.title, nextAt: next?.date, sleepAt: center.sleepAt,
                      tasks: center.tasks.records.count)
    }
}

struct AgentsCatalogAction: LLMDAction {
    struct Group: Encodable, Sendable {
        var id: String
        var label: String
        var actions: [String]
    }
    struct Output: Encodable, Sendable {
        var groups: [Group]
        var placeholders: [String]
        var scheduleKinds: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "agents.catalog", summary: "Listet die Werkzeuggruppen für KI-Schritte und die Platzhalter für Action-Schritte", kind: .read, security: .plainRead,
        input: .object(), output: .freeObject(), groups: ["agents.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let groups = AgentToolbox.groups.map { group in
            Group(id: group.id, label: group.label, actions: group.id == AgentToolbox.webGroup ? AgentToolbox.webTools : (ChatToolGroups.members[group.id] ?? []))
        }
        return Output(groups: groups,
                      placeholders: ["{{schritt1.id}}", "{{schritt1.title}}", "{{schritt1.satz}}", "{{vorher.id}}", "{{ziel}}", "{{heute}}", "{{jetzt}}", "{{datum}}"],
                      scheduleKinds: AgentSchedule.Kind.allCases.map(\.rawValue))
    }
}

// MARK: - Tasks

struct AgentsTaskListAction: LLMDAction {
    struct Output: Encodable, Sendable { var tasks: [AgentTaskSummary] }
    static let descriptor = ActionDescriptor(
        id: "agents.task.list", summary: "Listet die Agenten-Aufgaben mit Zeitplan und letztem Lauf", kind: .read, security: .plainRead,
        input: .object(), output: .freeObject(), example: "llmd agents task list", groups: ["agents.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let center = context.app.agents
        center.loadIfNeeded()
        return Output(tasks: center.tasks.records.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { AgentTaskSummary($0, center: center) })
    }
}

struct AgentsTaskReadAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var summary: AgentTaskSummary
        var task: AgentTask
    }
    static let descriptor = ActionDescriptor(
        id: "agents.task.read", summary: "Liest eine Agenten-Aufgabe mit allen Schritten", kind: .read, security: .plainRead,
        input: .object(taskProperty, required: ["task"]), output: .freeObject(), groups: ["agents.core"]
    )
    static func run(_ args: AgentTaskRefArgs, context: ActionContext) async throws -> Output {
        let task = try context.app.actionAgentTask(args.task)
        return Output(summary: AgentTaskSummary(task, center: context.app.agents), task: task)
    }
}

struct AgentsTaskCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var title: String
        var goal: String?
        var steps: [AgentStepInput]?
        var schedule: AgentScheduleInput?
        var sleepAfter: Bool?
        var approval: ChatToolApproval?
        var branch: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "agents.task.create", summary: "Legt eine Agenten-Aufgabe an", kind: .write, security: .localWrite,
        input: .object([
            "title": .string("Titel"),
            "goal": .string("Wozu die Aufgabe dient; jeder KI-Schritt liest es"),
            "steps": .array(of: AgentStepInput.schema, "Die Schritte in ihrer Reihenfolge"),
            "schedule": AgentScheduleInput.schema,
            "sleepAfter": .boolean("Danach den Mac in den Ruhezustand versetzen"),
            "approval": .choice(ChatToolApproval.allCases.map(\.rawValue), "ask, allowWrites (Standard) oder allowAll; nur die Person"),
            "branch": .boolean("Jeder Lauf auf einem eigenen Git-Branch (Standard ja)"),
        ], required: ["title"]),
        output: .freeObject(),
        example: #"llmd agents task create --title Morgenbericht --goal "Ein Überblick über meine offenen ToDos" --steps '[{"kind":"agent","title":"ToDos sammeln","instruction":"…","tools":["notes.core"]}]'"#,
        groups: ["agents.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        if args.approval != nil, args.approval != .ask { try context.requireThePerson("Die Freigabe einer Agenten-Aufgabe") }
        return ActionPreflight(target: args.title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> AgentTaskSummary {
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RPCError.invalidParams("Der Titel fehlt.") }
        var task = AgentTask(title: title, goal: args.goal ?? "", steps: try (args.steps ?? []).map { try $0.definition(registry: context.registry) })
        if let schedule = args.schedule { task.schedule = try schedule.schedule() }
        if let sleepAfter = args.sleepAfter { task.options.sleepAfter = sleepAfter }
        if let branch = args.branch { task.options.usesBranch = branch }
        if context.writesForeignTasks {
            // What a chat or a client wrote may come from what it read; its runs start as foreign and ask before changes.
            task.origin = .foreign
            task.options.approval = .ask
        } else if let approval = args.approval {
            task.options.approval = approval
        }
        context.app.agents.loadIfNeeded()
        let created = context.app.createAgentTask(task)
        recordTaskChange(context, before: nil, id: created.id)
        return AgentTaskSummary(created, center: context.app.agents)
    }
}

struct AgentsTaskUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var task: String
        var title: String?
        var goal: String?
        var steps: [AgentStepInput]?
        var sleepAfter: Bool?
        var approval: ChatToolApproval?
        var branch: Bool?
        var model: String?
    }
    static let descriptor = ActionDescriptor(
        id: "agents.task.update", summary: "Ändert Titel, Ziel, Schritte oder Optionen einer Agenten-Aufgabe", kind: .write, security: .localWrite,
        input: .object(taskProperty.merging([
            "title": .string("Neuer Titel"),
            "goal": .string("Neues Ziel"),
            "steps": .array(of: AgentStepInput.schema, "Alle Schritte neu"),
            "sleepAfter": .boolean("Danach Ruhezustand"),
            "approval": .choice(ChatToolApproval.allCases.map(\.rawValue), "nur die Person"),
            "branch": .boolean("Eigener Git-Branch je Lauf"),
            "model": .string("Modell-ID; leer: das Modell der Chats"),
        ]) { _, new in new }, required: ["task"]),
        output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        if args.approval != nil, args.approval != .ask { try context.requireThePerson("Die Freigabe einer Agenten-Aufgabe") }
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> AgentTaskSummary {
        let task = try context.app.actionAgentTask(args.task)
        let steps = try args.steps.map { try $0.map { try $0.definition(registry: context.registry) } }
        let before = task
        context.app.agents.tasks.update(task.id) { task in
            if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { task.title = title }
            if let goal = args.goal { task.goal = goal }
            if let steps { task.steps = steps }
            if let sleepAfter = args.sleepAfter { task.options.sleepAfter = sleepAfter }
            if let branch = args.branch { task.options.usesBranch = branch }
            if let model = args.model { task.options.model = model.isEmpty ? nil : model }
            if let approval = args.approval { task.options.approval = approval }
            if context.writesForeignTasks, args.goal != nil || args.steps != nil {
                task.origin = .foreign
                task.options.approval = .ask
            }
        }
        recordTaskChange(context, before: before, id: task.id)
        return AgentTaskSummary(context.app.agents.task(task.id) ?? task, center: context.app.agents)
    }
}

struct AgentsTaskDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.task.delete", summary: "Legt eine Agenten-Aufgabe in den Papierkorb", kind: .destructive, security: .destructive,
        input: .object(taskProperty, required: ["task"]), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentTaskRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title)
    }
    static func run(_ args: AgentTaskRefArgs, context: ActionContext) async throws -> OKOutput {
        let task = try context.app.actionAgentTask(args.task)
        do {
            try context.app.deleteAgentTask(task.id)
        } catch {
            throw RPCError.invalidTarget(error.localizedDescription)
        }
        return OKOutput(id: task.id.uuidString, message: "„\(task.title)“ liegt im Papierkorb.")
    }
}

// MARK: - Steps

struct AgentsStepAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var task: String
        var step: AgentStepInput
        var position: Int?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var position: Int
        var steps: Int
    }
    static let descriptor = ActionDescriptor(
        id: "agents.step.add", summary: "Fügt einer Agenten-Aufgabe einen Baustein hinzu", kind: .write, security: .localWrite,
        input: .object(taskProperty.merging([
            "step": AgentStepInput.schema,
            "position": .integer("Stelle ab 1; Standard: ans Ende", minimum: 1),
        ]) { _, new in new }, required: ["task", "step"]),
        output: .freeObject(),
        example: #"llmd agents step add --task Morgenbericht --step '{"kind":"action","title":"Dokument","action":"writer.doc.create","arguments":{"title":"Bericht {{heute}}"}}'"#,
        groups: ["agents.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let task = try context.app.actionAgentTask(args.task)
        let step = try args.step.definition(registry: context.registry)
        let index = min(max(0, (args.position ?? task.steps.count + 1) - 1), task.steps.count)
        let before = task
        context.app.agents.tasks.update(task.id) { task in
            task.steps.insert(step, at: index)
            if context.writesForeignTasks {
                task.origin = .foreign
                task.options.approval = .ask
            }
        }
        recordTaskChange(context, before: before, id: task.id)
        return Output(id: step.id.uuidString, position: index + 1, steps: task.steps.count + 1)
    }
}

struct AgentStepRefArgs: Decodable, Sendable {
    var task: String
    var step: String
    var to: Int?
}

@MainActor
private func stepIndex(_ reference: String, in task: AgentTask) throws -> Int {
    if let number = Int(reference), task.steps.indices.contains(number - 1) { return number - 1 }
    if let index = task.steps.firstIndex(where: { $0.id.uuidString == reference || $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame }) {
        return index
    }
    throw RPCError.notFound("Einen Schritt „\(reference)“ hat „\(task.title)“ nicht.")
}

private let stepProperty: [String: JSONSchema] = ["step": .string("Schritt: Nummer ab 1, ID oder Titel")]

struct AgentsStepRemoveAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.step.remove", summary: "Nimmt einen Baustein aus einer Agenten-Aufgabe", kind: .write, security: .localWrite,
        input: .object(taskProperty.merging(stepProperty) { _, new in new }, required: ["task", "step"]), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentStepRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title)
    }
    static func run(_ args: AgentStepRefArgs, context: ActionContext) async throws -> OKOutput {
        let task = try context.app.actionAgentTask(args.task)
        let index = try stepIndex(args.step, in: task)
        let before = task
        context.app.agents.tasks.update(task.id) { $0.steps.remove(at: index) }
        recordTaskChange(context, before: before, id: task.id)
        return OKOutput(id: task.steps[index].id.uuidString, message: "Schritt „\(task.steps[index].title)“ entfernt.")
    }
}

struct AgentsStepMoveAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.step.move", summary: "Verschiebt einen Baustein an eine andere Stelle", kind: .write, security: .localWrite,
        input: .object(taskProperty.merging(stepProperty) { _, new in new }.merging(["to": .integer("Neue Stelle ab 1", minimum: 1)]) { _, new in new }, required: ["task", "step", "to"]),
        output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentStepRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title)
    }
    static func run(_ args: AgentStepRefArgs, context: ActionContext) async throws -> OKOutput {
        let task = try context.app.actionAgentTask(args.task)
        let index = try stepIndex(args.step, in: task)
        let target = min(max(0, (args.to ?? 1) - 1), task.steps.count - 1)
        let before = task
        context.app.agents.tasks.update(task.id) { task in
            let step = task.steps.remove(at: index)
            task.steps.insert(step, at: target)
        }
        recordTaskChange(context, before: before, id: task.id)
        return OKOutput(id: task.steps[index].id.uuidString, message: "Jetzt Schritt \(target + 1).")
    }
}

struct AgentsScheduleSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var task: String
        var schedule: AgentScheduleInput
    }
    static let descriptor = ActionDescriptor(
        id: "agents.schedule.set", summary: "Stellt ein, wann eine Agenten-Aufgabe von selbst läuft", kind: .write, security: .localWrite,
        input: .object(taskProperty.merging(["schedule": AgentScheduleInput.schema]) { _, new in new }, required: ["task", "schedule"]),
        output: .freeObject(),
        example: #"llmd agents schedule set --task Morgenbericht --schedule '{"kind":"woechentlich","time":"07:30","weekdays":[1,2,3,4,5]}'"#,
        groups: ["agents.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents()
        return ActionPreflight(target: try context.app.actionAgentTask(args.task).title, detail: args.schedule.kind.rawValue)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> AgentTaskSummary {
        let task = try context.app.actionAgentTask(args.task)
        let schedule = try args.schedule.schedule(keeping: task.schedule)
        let before = task
        context.app.agents.tasks.update(task.id) { $0.schedule = schedule }
        recordTaskChange(context, before: before, id: task.id)
        return AgentTaskSummary(context.app.agents.task(task.id) ?? task, center: context.app.agents)
    }
}

// MARK: - Runs

struct AgentsRunStartAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.run.start", summary: "Startet eine Agenten-Aufgabe jetzt (sie wartet, falls schon ein Lauf arbeitet)", kind: .write, security: .localWrite,
        input: .object(taskProperty, required: ["task"]), output: .freeObject(), example: "llmd agents run start --task Morgenbericht", groups: ["agents.core"]
    )
    static func preflight(_ args: AgentTaskRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Läufe starten")
        let task = try context.app.actionAgentTask(args.task)
        var check = ActionPreflight(target: task.title, detail: task.steps.map(\.title).joined(separator: " → "))
        // A run works alone for a while, with the task's tools: whoever isn't the person needs the person's yes.
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Lauf arbeitet danach selbstständig mit den Werkzeugen der Aufgabe."
        }
        return check
    }
    static func run(_ args: AgentTaskRefArgs, context: ActionContext) async throws -> AgentRunSummary {
        let task = try context.app.actionAgentTask(args.task)
        let trigger: AgentRun.Trigger = switch context.channel {
        case .ui: .person
        case .cli: .terminal
        default: .chat
        }
        do {
            return AgentRunSummary(try context.app.enqueueAgentRun(task.id, trigger: trigger))
        } catch {
            throw RPCError.invalidTarget(error.localizedDescription)
        }
    }
}

struct AgentsRunListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var task: String?
        var limit: Int?
    }
    struct Output: Encodable, Sendable { var runs: [AgentRunSummary] }
    static let descriptor = ActionDescriptor(
        id: "agents.run.list", summary: "Listet die Läufe, die neuesten zuerst", kind: .read, security: .plainRead,
        input: .object(["task": .string("Nur Läufe dieser Aufgabe"), "limit": .integer("Höchstens so viele (Standard 20)", minimum: 1, maximum: 200)]),
        output: .freeObject(), example: "llmd agents run list", groups: ["agents.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let center = context.app.agents
        center.loadIfNeeded()
        let runs = try args.task.map { center.runs(of: try context.app.actionAgentTask($0).id) } ?? center.history
        return Output(runs: runs.prefix(args.limit ?? 20).map(AgentRunSummary.init))
    }
}

struct AgentsRunReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var id: String?
        var lines: Int?
    }
    struct Step: Encodable, Sendable {
        var number: Int
        var title: String
        var kind: String
        var state: String
        var summary: String?
        var calls: Int
        var commit: String?
    }
    struct Line: Encodable, Sendable {
        var time: Date
        var kind: String
        var text: String
    }
    struct Output: Encodable, Sendable {
        var run: AgentRunSummary
        var steps: [Step]
        var results: [AgentResult]
        var log: [Line]
        var mergeCommit: String?
    }
    static let descriptor = ActionDescriptor(
        id: "agents.run.read", summary: "Zeigt einen Lauf: Schritte als Sätze, Ergebnisse und das Protokoll", kind: .read, security: .plainRead,
        input: .object(runProperty.merging(["lines": .integer("Zeilen des Protokolls (Standard 40)", minimum: 0, maximum: 600)]) { _, new in new }),
        output: .freeObject(), example: "llmd agents run read", groups: ["agents.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let run = try context.app.actionAgentRun(args.id)
        let steps = run.steps.enumerated().map { index, step in
            Step(number: index + 1, title: step.title, kind: run.plan.indices.contains(index) ? run.plan[index].kind.rawValue : "agent", state: step.state.rawValue,
                 summary: step.summary, calls: step.calls.count, commit: step.commit)
        }
        let log = run.log.suffix(args.lines ?? 40).map { Line(time: $0.time, kind: $0.kind.rawValue, text: $0.text) }
        return Output(run: AgentRunSummary(run), steps: steps, results: run.results, log: log, mergeCommit: run.mergeCommit)
    }
}

struct AgentsRunPauseAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.run.pause", summary: "Hält einen Lauf an (er wartet, bis er fortgesetzt wird)", kind: .write, security: .localWrite,
        input: .object(runProperty), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentRunRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Läufe anhalten")
        return ActionPreflight(target: try context.app.actionAgentRun(args.id).title)
    }
    static func run(_ args: AgentRunRefArgs, context: ActionContext) async throws -> AgentRunSummary {
        let run = try context.app.actionAgentRun(args.id)
        guard run.state == .running || run.state == .queued else { throw RPCError.invalidTarget("Der Lauf ist \(run.state.label); anhalten geht nur, solange er läuft oder wartet.") }
        context.app.pauseAgentRun(run.id)
        return AgentRunSummary(context.app.agents.run(run.id) ?? run)
    }
}

struct AgentsRunResumeAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.run.resume", summary: "Setzt einen angehaltenen oder unterbrochenen Lauf ab dem ersten offenen Schritt fort", kind: .write, security: .localWrite,
        input: .object(runProperty), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentRunRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Läufe fortsetzen")
        let run = try context.app.actionAgentRun(args.id)
        var check = ActionPreflight(target: run.title)
        if context.channel == .chat || context.channel == .mcp { check.needsConsent = "Der Lauf arbeitet danach wieder selbstständig." }
        return check
    }
    static func run(_ args: AgentRunRefArgs, context: ActionContext) async throws -> AgentRunSummary {
        let run = try context.app.actionAgentRun(args.id)
        guard run.state == .paused || run.state.canResume else { throw RPCError.invalidTarget("Der Lauf ist \(run.state.label) und lässt sich nicht fortsetzen.") }
        context.app.resumeAgentRun(run.id)
        return AgentRunSummary(context.app.agents.run(run.id) ?? run)
    }
}

struct AgentsRunCancelAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.run.cancel", summary: "Bricht einen Lauf ab; was fertig ist, bleibt und kommt zurück in den Ausgangsbranch", kind: .write, security: .localWrite,
        input: .object(runProperty), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentRunRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Läufe abbrechen")
        return ActionPreflight(target: try context.app.actionAgentRun(args.id).title)
    }
    static func run(_ args: AgentRunRefArgs, context: ActionContext) async throws -> AgentRunSummary {
        let run = try context.app.actionAgentRun(args.id)
        guard run.state.isActive else { throw RPCError.invalidTarget("Der Lauf ist schon \(run.state.label).") }
        context.app.cancelAgentRun(run.id)
        return AgentRunSummary(context.app.agents.run(run.id) ?? run)
    }
}

struct AgentsRunUndoAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "agents.run.undo", summary: "Nimmt alles zurück, was ein Lauf in der Bibliothek geändert hat (ein Git-Commit, der das Gegenteil tut)",
        kind: .destructive, security: .destructive, input: .object(runProperty), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: AgentRunRefArgs, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Läufe zurücknehmen")
        let run = try context.app.actionAgentRun(args.id)
        return ActionPreflight(target: run.title, detail: "\(run.commits.count) Commit(s) auf \(run.branch ?? "keinem Branch")")
    }
    static func run(_ args: AgentRunRefArgs, context: ActionContext) async throws -> AgentRunSummary {
        let run = try context.app.actionAgentRun(args.id)
        do {
            try await context.app.undoAgentRun(run.id)
        } catch {
            throw RPCError.invalidTarget(error.localizedDescription)
        }
        return AgentRunSummary(context.app.agents.run(run.id) ?? run)
    }
}

struct AgentsApprovalsListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var run: String
        var title: String
        var action: String
        var summary: String
        var target: String?
        var reason: String
        var since: Date
    }
    struct Output: Encodable, Sendable {
        var questions: [Item]
        var note: String
    }
    static let descriptor = ActionDescriptor(
        id: "agents.approvals.list", summary: "Listet die Fragen, auf die Läufe warten (beantworten kann sie nur die Person in der App)", kind: .read, security: .plainRead,
        input: .object(), output: .freeObject(), groups: ["agents.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.agents.loadIfNeeded()
        let items = context.app.agents.openQuestions.compactMap { run in
            run.question.map { Item(run: run.id.uuidString, title: run.title, action: $0.action, summary: $0.summary, target: $0.target, reason: $0.reason, since: $0.since) }
        }
        return Output(questions: items, note: "Antworten gibt es nur in der App: AgentSteps, Power-Zugriff oder Mitteilung.")
    }
}

struct AgentsHaltAction: LLMDAction {
    struct Args: Decodable, Sendable { var halted: Bool }
    static let descriptor = ActionDescriptor(
        id: "agents.halt", summary: "Hält alle Agenten an oder lässt sie weiterlaufen", kind: .write, security: .localWrite,
        input: .object(["halted": .boolean("true: alles anhalten; false: weiterlaufen lassen")], required: ["halted"]), output: .freeObject(), groups: ["agents.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try context.refuseAgents("Alle Agenten anhalten")
        var check = ActionPreflight(target: args.halted ? "anhalten" : "weiterlaufen")
        if !args.halted, context.channel == .chat || context.channel == .mcp { check.needsConsent = "Die Agenten arbeiten danach wieder selbstständig." }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        context.app.agents.isHalted = args.halted
        return OKOutput(message: args.halted ? "Alle Agenten sind angehalten." : "Die Agenten arbeiten weiter.")
    }
}

struct AgentsPlanAction: LLMDAction {
    struct Args: Decodable, Sendable { var description: String }
    struct Output: Encodable, Sendable {
        var answer: String
        var draft: AgentDraftOutput?
    }
    struct AgentDraftOutput: Encodable, Sendable {
        var title: String
        var goal: String
        var steps: [AgentStepDefinition]
        var schedule: String
        var sleepAfter: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "agents.plan", summary: "Lässt das Modell aus einer Beschreibung einen Entwurf für eine Aufgabe machen (legt nichts an)", kind: .read, security: .plainRead,
        input: .object(["description": .string("Was die Aufgabe tun soll, in eigenen Worten")], required: ["description"]),
        output: .freeObject(), example: #"llmd agents plan --description "Jeden Morgen um 7 meine offenen ToDos zusammenfassen""#, groups: ["agents.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let (client, model) = try app.studioModel()
        let messages = [
            ChatPayloadMessage(role: "system", content: AgentPlanner.systemPrompt(draft: nil, status: app.agentStatusLine)),
            ChatPayloadMessage(role: "user", content: args.description),
        ]
        let raw = try await client.complete(model: model.id, messages: messages, temperature: 0.3, maxTokens: 2_500, orderedSchema: ("agentenaufgabe", AgentPlanner.schemaJSON))
        let reply = AgentPlanner.parse(raw, previous: nil)
        let draft = AgentPlanner.applyWords(reply.draft, personTexts: [args.description])
        return Output(answer: reply.text, draft: draft.map {
            AgentDraftOutput(title: $0.title, goal: $0.goal, steps: $0.steps, schedule: $0.schedule.summary, sleepAfter: $0.sleepAfter)
        })
    }
}
