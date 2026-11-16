import Foundation
import LLMDProtocol

// AgentSteps: tasks the person defines once (`AgentSteps/Aufgaben/<id>.json`, in Git) and the runs they make
// (`AgentSteps/Protokolle/<id>.json`, outside Git, because a run rewrites its log at every step and taking a run
// back must not delete its own record). The keys are German like the other formats of the library.

/// An agentic task: a goal in the person's words, the steps that reach it, when it runs and what it may do.
struct AgentTask: StoredRecord {
    var id = UUID()
    var title: String
    /// What the whole task is for. Every model step reads it, so a step knows why it does what it does.
    var goal: String
    var steps: [AgentStepDefinition]
    var schedule = AgentSchedule()
    var options = AgentTaskOptions()
    /// Who wrote the definition. A task written by a chat or an MCP client starts its runs as foreign: what such a
    /// caller put into the steps may be an attacker's text.
    var origin: AgentTaskOrigin = .own
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String, goal: String = "", steps: [AgentStepDefinition] = []) {
        self.title = title
        self.goal = goal
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id, title = "titel", goal = "ziel", steps = "schritte", schedule = "zeitplan", options = "optionen"
        case origin = "herkunft", createdAt = "angelegt", updatedAt = "geaendert"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = c.soft(.title, "Aufgabe")
        goal = c.soft(.goal, "")
        steps = c.soft(.steps, [])
        schedule = c.soft(.schedule, AgentSchedule())
        options = c.soft(.options, AgentTaskOptions())
        origin = c.soft(.origin, .own)
        createdAt = c.soft(.createdAt, Date())
        updatedAt = c.soft(.updatedAt, Date())
    }

    static let symbol = "cpu"
}

enum AgentTaskOrigin: String, Codable, Sendable {
    case own = "eigen"
    case foreign = "fremd"
}

/// One building block of a task.
struct AgentStepDefinition: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// One action from the catalog with fixed parameters. No model: it does exactly that.
        case action
        /// A model works on one instruction with a small set of tools until it says it is done.
        case agent

        var label: String {
            switch self {
            case .action: "Action"
            case .agent: "KI-Schritt"
            }
        }
    }

    enum OnError: String, Codable, Sendable, CaseIterable {
        case stop = "abbrechen"
        case go = "weiter"
    }

    var id = UUID()
    var kind: Kind
    var title: String
    /// `.action`: the action and its parameters; strings may hold placeholders like `{{schritt1.id}}`.
    var action: String?
    var arguments: JSONValue?
    /// `.agent`: what the model is to do, and which tools it gets (group ids like `writer.core` or single actions).
    var instruction: String?
    var tools: [String]?
    var maxRounds: Int?
    var thinking: Bool?
    var onError: OnError = .stop

    static let defaultRounds = 12

    init(kind: Kind, title: String, action: String? = nil, arguments: JSONValue? = nil, instruction: String? = nil, tools: [String]? = nil) {
        self.kind = kind
        self.title = title
        self.action = action
        self.arguments = arguments
        self.instruction = instruction
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind = "art", title = "titel", action, arguments = "parameter", instruction = "auftrag", tools = "werkzeuge"
        case maxRounds = "runden", thinking = "nachdenken", onError = "beiFehler"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        kind = c.soft(.kind, .agent)
        title = c.soft(.title, "Schritt")
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        arguments = try? c.decodeIfPresent(JSONValue.self, forKey: .arguments)
        instruction = try? c.decodeIfPresent(String.self, forKey: .instruction)
        tools = try? c.decodeIfPresent([String].self, forKey: .tools)
        maxRounds = try? c.decodeIfPresent(Int.self, forKey: .maxRounds)
        thinking = try? c.decodeIfPresent(Bool.self, forKey: .thinking)
        onError = c.soft(.onError, .stop)
    }

    var rounds: Int { min(40, max(2, maxRounds ?? Self.defaultRounds)) }

    /// What is wrong with the step before it can run, or nil.
    var problem: String? {
        switch kind {
        case .action:
            return (action ?? "").isEmpty ? "Schritt „\(title)“: Es ist keine Action gewählt." : nil
        case .agent:
            if (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Schritt „\(title)“: Der Auftrag fehlt." }
            if (tools ?? []).isEmpty { return "Schritt „\(title)“: Es ist kein Werkzeug gewählt." }
            return nil
        }
    }
}

/// What a task may do and what happens around its runs.
struct AgentTaskOptions: Codable, Hashable, Sendable {
    /// How much a run may do without asking; destructive things and private data ask anyway (see `ActionPolicy`).
    var approval: ChatToolApproval = .allowWrites
    /// The run works on a branch of its own (`agent/…`), one commit per step, merged back at the end.
    var usesBranch = true
    /// After a finished run the Mac goes to sleep, unless someone is at it or another run waits.
    var sleepAfter = false
    /// The model; nil takes the one chosen for chats.
    var model: String?

    private enum CodingKeys: String, CodingKey {
        case approval = "freigabe", usesBranch = "branch", sleepAfter = "danachRuhezustand", model = "modell"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = c.soft(.approval, .allowWrites)
        usesBranch = c.soft(.usesBranch, true)
        sleepAfter = c.soft(.sleepAfter, false)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
    }
}

// MARK: - Runs

/// One run of a task: its plan as it was at the start, the steps as far as they got, the log and the Git places.
struct AgentRun: StoredRecord {
    enum State: String, Codable, Sendable, CaseIterable {
        case queued = "wartet"
        case running = "laeuft"
        case paused = "pausiert"
        case asking = "frage"
        case finished = "fertig"
        case failed = "fehler"
        case cancelled = "abgebrochen"
        case interrupted = "unterbrochen"
        case undone = "zurueckgenommen"

        var label: String {
            switch self {
            case .queued: "wartet"
            case .running: "läuft"
            case .paused: "pausiert"
            case .asking: "wartet auf dich"
            case .finished: "fertig"
            case .failed: "Fehler"
            case .cancelled: "abgebrochen"
            case .interrupted: "unterbrochen"
            case .undone: "zurückgenommen"
            }
        }

        /// Still to come or going on: the queue holds it, a restart interrupts it.
        var isActive: Bool { [.queued, .running, .paused, .asking].contains(self) }
        var isOver: Bool { !isActive }
        var canResume: Bool { self == .interrupted || self == .failed || self == .cancelled }
    }

    enum Trigger: String, Codable, Sendable {
        case person = "hand"
        case schedule = "zeitplan"
        case chat
        case terminal
    }

    var id = UUID()
    var taskID: UUID
    var title: String
    var goal: String
    var trigger: Trigger
    var state: State = .queued
    var plan: [AgentStepDefinition]
    var options: AgentTaskOptions
    var origin: AgentTaskOrigin = .own
    var steps: [AgentRunStep]
    var log: [AgentLogLine] = []
    var results: [AgentResult] = []
    var question: AgentQuestion?
    var pauseReason: String?
    var error: String?
    /// Git: the branch of the run, where it started, and the merge that brought it back.
    var branch: String?
    var baseBranch: String?
    var baseCommit: String?
    var mergeCommit: String?
    var hadUntrusted = false
    var hadSensitive = false
    var queuedAt = Date()
    var startedAt: Date?
    var endedAt: Date?
    var updatedAt = Date()

    static let logLimit = 600

    init(task: AgentTask, trigger: Trigger) {
        taskID = task.id
        title = task.title
        goal = task.goal
        self.trigger = trigger
        plan = task.steps
        options = task.options
        origin = task.origin
        steps = task.steps.map { AgentRunStep(definition: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID = "aufgabe", title = "titel", goal = "ziel", trigger = "anlass", state = "zustand", plan, options = "optionen"
        case origin = "herkunft", steps = "schritte", log = "protokoll", results = "ergebnisse", question = "frage", pauseReason = "pause"
        case error = "fehler", branch, baseBranch = "ausgangsbranch", baseCommit = "ausgangscommit", mergeCommit = "mergecommit"
        case hadUntrusted = "fremd", hadSensitive = "sensibel", queuedAt = "angelegt", startedAt = "gestartet", endedAt = "beendet"
        case updatedAt = "geaendert"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        title = c.soft(.title, "Lauf")
        goal = c.soft(.goal, "")
        trigger = c.soft(.trigger, .person)
        state = c.soft(.state, .interrupted)
        plan = c.soft(.plan, [])
        options = c.soft(.options, AgentTaskOptions())
        origin = c.soft(.origin, .own)
        steps = c.soft(.steps, [])
        log = c.soft(.log, [])
        results = c.soft(.results, [])
        question = try? c.decodeIfPresent(AgentQuestion.self, forKey: .question)
        pauseReason = try? c.decodeIfPresent(String.self, forKey: .pauseReason)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        branch = try? c.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try? c.decodeIfPresent(String.self, forKey: .baseBranch)
        baseCommit = try? c.decodeIfPresent(String.self, forKey: .baseCommit)
        mergeCommit = try? c.decodeIfPresent(String.self, forKey: .mergeCommit)
        hadUntrusted = c.soft(.hadUntrusted, false)
        hadSensitive = c.soft(.hadSensitive, false)
        queuedAt = c.soft(.queuedAt, Date())
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        updatedAt = c.soft(.updatedAt, Date())
    }

    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    var doneCount: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
    var currentStepIndex: Int? { steps.firstIndex { $0.state == .running } ?? steps.firstIndex { $0.state == .pending } }
    var commits: [String] { steps.compactMap(\.commit) }

    mutating func append(_ kind: AgentLogLine.Kind, _ text: String, at time: Date = Date()) {
        log.append(AgentLogLine(time: time, kind: kind, text: String(text.prefix(AgentLogLine.textLimit))))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}

struct AgentRunStep: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending = "offen"
        case running = "laeuft"
        case done = "fertig"
        case failed = "fehler"
        case skipped = "uebersprungen"
    }

    var id: UUID
    var title: String
    var state: State = .pending
    /// What came of it, as a sentence with titles and ids; the next steps read it.
    var summary: String?
    /// The small values of an action's result (ids, titles, counts) for placeholders in later steps.
    var output: [String: JSONValue]?
    var calls: [AgentCall] = []
    var rounds = 0
    var commit: String?
    var startedAt: Date?
    var endedAt: Date?

    init(definition: AgentStepDefinition) {
        id = definition.id
        title = definition.title
    }

    private enum CodingKeys: String, CodingKey {
        case id, title = "titel", state = "zustand", summary = "satz", output = "ausgabe", calls = "aufrufe", rounds = "runden", commit
        case startedAt = "gestartet", endedAt = "beendet"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        title = c.soft(.title, "Schritt")
        state = c.soft(.state, .pending)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        output = try? c.decodeIfPresent([String: JSONValue].self, forKey: .output)
        calls = c.soft(.calls, [])
        rounds = c.soft(.rounds, 0)
        commit = try? c.decodeIfPresent(String.self, forKey: .commit)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
    }
}

/// One action a step called: no parameters or results, only what it was about, like the activity log.
struct AgentCall: Codable, Hashable, Sendable {
    var action: String
    var target: String?
    var ok: Bool
    var error: String?

    private enum CodingKeys: String, CodingKey { case action, target = "ziel", ok, error = "fehler" }
}

/// A thing a run made or changed, to open from the dashboard.
struct AgentResult: Codable, Hashable, Sendable {
    var kind: String
    var id: String
    var title: String?

    private enum CodingKeys: String, CodingKey { case kind = "art", id, title = "titel" }
}

/// A call that waits for the person. Only the interface answers it.
struct AgentQuestion: Codable, Hashable, Sendable {
    var action: String
    var summary: String
    var target: String?
    var detail: String?
    var reason: String
    var since = Date()

    private enum CodingKeys: String, CodingKey { case action, summary = "beschreibung", target = "ziel", detail = "daten", reason = "grund", since = "seit" }

    init(_ request: ApprovalRequest) {
        action = request.action
        summary = request.summary
        target = request.target
        detail = request.detail
        reason = request.reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = c.soft(.action, "")
        summary = c.soft(.summary, "")
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        reason = c.soft(.reason, "")
        since = c.soft(.since, Date())
    }
}

/// A line of the terminal-like log: when, what kind, and a short sentence. Never parameters or texts.
struct AgentLogLine: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case info, step = "schritt", tool = "werkzeug", model = "modell", git, question = "frage", pause, error = "fehler", done = "fertig"

        var tag: String {
            switch self {
            case .info: "info"
            case .step: "schritt"
            case .tool: "tool"
            case .model: "modell"
            case .git: "git"
            case .question: "frage"
            case .pause: "pause"
            case .error: "fehler"
            case .done: "fertig"
            }
        }
    }

    var time: Date
    var kind: Kind
    var text: String

    static let textLimit = 400

    private enum CodingKeys: String, CodingKey { case time = "zeit", kind = "art", text }
}
