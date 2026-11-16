import AppKit
import Foundation
import LLMDProtocol

/// Everything AgentSteps keeps for the open library: the tasks, their runs, the queue and the questions that wait
/// for the person. One run works at a time: there is one model and one checkout of the library, and a run's branch
/// is the library's branch while it works. The runner itself is in `AppModel+Agents.swift`.
@MainActor
@Observable
final class AgentCenter {
    let tasks: RecordLibrary<AgentTask>
    let runs: RecordLibrary<AgentRun>

    /// The run working now.
    var activeRunID: UUID?
    /// The person stopped all agent activity; runs wait, nothing new starts. Kept in the library's settings.
    var isHalted = false {
        didSet { onHaltChange?(isHalted) }
    }
    /// Runs waiting because the person uses the model (a chat answers).
    var yielding: Set<UUID> = []
    /// What the model of a run writes right now, short.
    var live: [UUID: String] = [:]
    /// The Mac goes to sleep at this moment unless someone stops it.
    var sleepAt: Date?
    /// The chat that drafts new tasks.
    let chat = AgentPlanningChat()
    /// The task or run the dashboard shows; set by the power access too.
    var selection: AgentSelection?

    @ObservationIgnored var runner: Task<Void, Never>?
    @ObservationIgnored var scheduler: Task<Void, Never>?
    @ObservationIgnored var sleepTask: Task<Void, Never>?
    @ObservationIgnored var wakeObserver: NSObjectProtocol?
    /// Set while the library closes: a cancelled run is then interrupted, not cancelled.
    @ObservationIgnored var isClosing = false
    @ObservationIgnored var onHaltChange: ((Bool) -> Void)?
    @ObservationIgnored private var answers: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Addresses a run may open: from the person's task text and from its own search results.
    @ObservationIgnored var webEvidence: [UUID: [NormalizedAddress]] = [:]
    @ObservationIgnored let awake = AgentAwake()

    // Stand-ins for tests.
    @ObservationIgnored var sleeper: @MainActor () -> Void = { MacSleep.sleepNow() }
    @ObservationIgnored var idleSeconds: @MainActor () -> Double = { MacSleep.idleSeconds() }
    @ObservationIgnored var notify: @MainActor (_ title: String, _ body: String) -> Void = { AgentNotifier.post(title: $0, body: $1) }
    @ObservationIgnored var sleepDelay: Duration = .seconds(60)
    @ObservationIgnored var questionTimeout: Duration = .seconds(24 * 60 * 60)
    /// Stands for "the person is chatting" in tests.
    @ObservationIgnored var personUsesModelOverride: Bool?

    /// How many finished runs stay with their log; older ones go (their commits stay in Git).
    static let keptRuns = 120

    init(root: URL) {
        tasks = RecordLibrary(store: RecordStore(directory: Self.folder(root, "Aufgaben"), root: "aufgabe"))
        runs = RecordLibrary(store: RecordStore(directory: Self.folder(root, "Protokolle"), root: "lauf"))
    }

    static let folderName = "AgentSteps"
    /// The runs' folder, which Git leaves out (see `GitSetup.ignoreFileContent`).
    static let runsPath = "AgentSteps/Protokolle"

    private static func folder(_ root: URL, _ name: String) -> URL {
        let url = root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func loadIfNeeded() {
        tasks.loadIfNeeded()
        runs.loadIfNeeded()
    }

    func saveAll() {
        tasks.saveAll()
        runs.saveAll()
    }

    // MARK: Looking up

    func task(_ id: UUID) -> AgentTask? { tasks.record(id) }
    func run(_ id: UUID) -> AgentRun? { runs.record(id) }

    var activeRun: AgentRun? { activeRunID.flatMap(run) }

    var queued: [AgentRun] {
        runs.records.filter { $0.state == .queued }.sorted { $0.queuedAt < $1.queuedAt }
    }

    var openQuestions: [AgentRun] {
        runs.records.filter { $0.state == .asking && $0.question != nil }
    }

    /// Runs newest first.
    var history: [AgentRun] {
        runs.records.sorted { ($0.startedAt ?? $0.queuedAt) > ($1.startedAt ?? $1.queuedAt) }
    }

    func runs(of taskID: UUID) -> [AgentRun] {
        history.filter { $0.taskID == taskID }
    }

    func lastRun(of taskID: UUID) -> AgentRun? { runs(of: taskID).first }

    func isActive(_ taskID: UUID) -> Bool {
        runs.records.contains { $0.taskID == taskID && $0.state.isActive }
    }

    /// When the schedule last started this task; what the next due time is measured against.
    func lastScheduledStart(of taskID: UUID) -> Date? {
        runs.records.filter { $0.taskID == taskID && $0.trigger == .schedule }.map(\.queuedAt).max()
    }

    func nextRun(of task: AgentTask, now: Date = Date()) -> Date? {
        task.schedule.nextSlot(after: now)
    }

    /// The task due next, for the status line.
    func nextScheduled(now: Date = Date()) -> (task: AgentTask, date: Date)? {
        tasks.records.compactMap { task in nextRun(of: task, now: now).map { (task, $0) } }.min { $0.1 < $1.1 }
    }

    /// The library still stands on a run's branch: a run that a quit interrupted, which the person should finish.
    func unfinishedBranchRun(currentBranch: String?) -> AgentRun? {
        guard let currentBranch, currentBranch.hasPrefix("agent/") else { return nil }
        return history.first { $0.branch == currentBranch && $0.mergeCommit == nil }
    }

    // MARK: Log

    func log(_ runID: UUID, _ kind: AgentLogLine.Kind, _ text: String) {
        runs.update(runID, touch: false) { $0.append(kind, text) }
    }

    struct TerminalLine: Identifiable, Hashable {
        var id: String
        var runID: UUID
        var runTitle: String
        var line: AgentLogLine
    }

    /// The lines of the recent runs, merged by time; with `run` only that run's.
    func terminalLines(run: UUID? = nil, limit: Int = 400) -> [TerminalLine] {
        let chosen = run.flatMap { id in runs.record(id).map { [$0] } } ?? Array(history.prefix(25))
        let lines = chosen.flatMap { run in
            run.log.suffix(limit).enumerated().map { index, line in
                TerminalLine(id: "\(run.id.uuidString)-\(run.log.count - min(limit, run.log.count) + index)", runID: run.id, runTitle: run.title, line: line)
            }
        }
        return Array(lines.sorted { $0.line.time == $1.line.time ? $0.id < $1.id : $0.line.time < $1.line.time }.suffix(limit))
    }

    // MARK: After a launch

    /// A run that was working when the app or the library closed can't go on by itself: the model's state is gone.
    /// It stands on "unterbrochen" with everything that was done, and the person may continue it. Old runs go.
    func recoverAfterLaunch() {
        for run in runs.records where [.running, .paused, .asking].contains(run.state) {
            runs.update(run.id, touch: false) { run in
                run.state = .interrupted
                run.question = nil
                for index in run.steps.indices where run.steps[index].state == .running { run.steps[index].state = .pending }
                run.append(.pause, "Unterbrochen: Die App oder die Bibliothek wurde geschlossen, während der Lauf arbeitete.")
            }
        }
        let over = history.filter(\.state.isOver)
        for run in over.dropFirst(Self.keptRuns) { runs.remove(run.id) }
    }

    // MARK: Questions

    /// A call of a run needs the person. The run waits, and with it nothing else of the run; the app stays usable.
    /// Only the interface can answer (`answer`); after `questionTimeout` it counts as a no and the run pauses.
    func ask(_ request: ApprovalRequest) async -> Bool {
        guard let id = request.run.flatMap(UUID.init(uuidString:)), run(id) != nil else { return false }
        answers[id]?.resume(returning: false)
        answers[id] = nil
        runs.update(id, touch: false) { run in
            run.state = .asking
            run.question = AgentQuestion(request)
            run.append(.question, "Wartet auf dich: \(request.summary)\(request.target.map { " – \($0)" } ?? ""). Grund: \(request.reason)")
        }
        runs.saveNow(id)
        notify("AgentSteps wartet auf dich", "\(run(id)?.title ?? "Ein Lauf"): \(request.summary)")
        let timeout = questionTimeout
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.answer(id, allow: false, timedOut: true)
        }
        let allowed = await withCheckedContinuation { continuation in
            answers[id] = continuation
        }
        watchdog.cancel()
        return allowed
    }

    /// The person's answer, from the dashboard, the power access or a chat card. No action calls this.
    func answer(_ id: UUID, allow: Bool, timedOut: Bool = false) {
        guard let continuation = answers.removeValue(forKey: id) else { return }
        runs.update(id, touch: false) { run in
            run.question = nil
            if timedOut {
                run.state = .paused
                run.pauseReason = "Eine Frage blieb 24 Stunden offen und gilt als abgelehnt."
                run.append(.pause, "Frage abgelaufen: abgelehnt, der Lauf ist angehalten.")
            } else {
                run.state = .running
                run.append(.question, allow ? "Von dir erlaubt." : "Von dir abgelehnt.")
            }
        }
        continuation.resume(returning: allow)
    }

    func hasPendingQuestion(_ id: UUID) -> Bool { answers[id] != nil }

    // MARK: Sleep after a run

    /// The Mac sleeps after `sleepDelay`, unless someone works at it meanwhile, the person stops it or another run
    /// comes. The countdown shows in the dashboard and the power access.
    func scheduleSleep(after runID: UUID) {
        sleepTask?.cancel()
        let delay = sleepDelay
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        // Someone who touched the Mac during the countdown is at it; a few seconds of slack for the click that started it.
        let quiet = max(0.5, seconds - 5)
        sleepAt = Date().addingTimeInterval(seconds)
        log(runID, .info, "Der Mac geht in \(Int(seconds.rounded())) Sekunden in den Ruhezustand, wenn niemand ihn benutzt.")
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.sleepAt = nil
            let idle = self.idleSeconds()
            if self.activeRunID != nil || !self.queued.isEmpty {
                self.log(runID, .info, "Ruhezustand ausgelassen: Ein weiterer Lauf wartet.")
            } else if idle < quiet {
                self.log(runID, .info, "Ruhezustand ausgelassen: Jemand arbeitet am Mac.")
            } else {
                self.log(runID, .done, "Der Mac geht jetzt in den Ruhezustand.")
                self.runs.saveAll()
                self.sleeper()
            }
        }
    }

    func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
    }
}

/// What the dashboard shows on the right.
enum AgentSelection: Hashable {
    case task(UUID)
    case run(UUID)
    case newTask
}

enum AgentError: LocalizedError {
    case notFound(String)
    case invalid(String)
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let text), .invalid(let text), .busy(let text): text
        }
    }
}
