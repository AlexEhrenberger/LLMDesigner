import Foundation
import LLMDProtocol

/// The one place through which actions run: it checks parameters, asks the safety rule, keeps run state, undo groups
/// and the log. Whoever calls it (socket, chat, tests) gets the same checks.
@MainActor
final class ActionRegistry {
    private struct Entry {
        let descriptor: ActionDescriptor
        let preflight: (JSONValue, ActionContext) throws -> ActionPreflight
        let run: (JSONValue, ActionContext) async throws -> JSONValue
    }

    private var entries: [String: Entry] = [:]
    private var runs: [String: RunState] = [:]
    let approval = ActionApproval()
    let log = ActionLog()
    let undoStack = ActionUndoStack()
    /// Delivered to `events.subscribe`.
    var eventSink: (@MainActor (ActionEvent) -> Void)?
    /// Actions running right now; a document change meanwhile is theirs and already reported.
    private(set) var activeActions = 0
    /// The model the undo stack belongs to; a new library starts clean.
    private weak var lastApp: AppModel?

    init() {}

    /// All actions of the app.
    static func standard() -> ActionRegistry {
        let registry = ActionRegistry()
        registry.registerAppActions()
        registry.registerWriterActions()
        registry.registerPresenterActions()
        registry.registerCitationActions()
        registry.registerStoriesActions()
        registry.registerNotesActions()
        registry.registerProjectsActions()
        registry.registerDataActions()
        registry.registerResearchActions()
        registry.registerLearningActions()
        registry.registerPodcastActions()
        registry.registerChatActions()
        return registry
    }

    // MARK: Registering

    /// A descriptor can't be made without security properties (they have no defaults); here it is also checked for
    /// contradictions. A mistake is a programming error and shows up in every test run.
    func register<A: LLMDAction>(_ action: A.Type) {
        let descriptor = A.descriptor
        if let problem = descriptor.inconsistency { fatalError(problem) }
        guard entries[descriptor.id] == nil else { fatalError("Action „\(descriptor.id)“ doppelt registriert.") }
        entries[descriptor.id] = Entry(
            descriptor: descriptor,
            preflight: { args, context in try A.preflight(try Self.decode(args, for: descriptor.id), context: context) },
            run: { args, context in
                let output = try await A.run(try Self.decode(args, for: descriptor.id), context: context)
                return try JSONValue.encoding(output)
            }
        )
    }

    private static func decode<T: Decodable>(_ args: JSONValue, for id: String) throws -> T {
        do {
            return try args.decoded(as: T.self)
        } catch {
            throw RPCError.invalidParams("Parameter von „\(id)“ passen nicht: \(error.localizedDescription)")
        }
    }

    var descriptors: [ActionDescriptor] {
        entries.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    func descriptor(_ id: String) -> ActionDescriptor? {
        entries[id]?.descriptor
    }

    // MARK: Running

    /// The state of a run; without an id every call is a run of its own.
    func runState(id: String?, channel: ActionChannel) -> RunState {
        guard let id, !id.isEmpty else { return RunState(channel: channel) }
        // A run of another channel is another run: a CLI script can't take over the state of an MCP session.
        let key = "\(channel.rawValue):\(id)"
        if let state = runs[key] {
            state.lastUsed = Date()
            return state
        }
        // Stale runs go, so the table doesn't grow without end.
        let limit = Date().addingTimeInterval(-24 * 60 * 60)
        runs = runs.filter { $0.value.lastUsed > limit }
        let state = RunState(id: id, channel: channel)
        runs[key] = state
        return state
    }

    /// Runs an action. Errors arrive as `RPCError`.
    @discardableResult
    func run(_ id: String, args: JSONValue = .object([:]), app: AppModel, channel: ActionChannel, run runID: String? = nil) async throws -> JSONValue {
        let state = runState(id: runID, channel: channel)
        let group = UndoGroup(label: id)
        group.runID = state.id
        group.turnID = state.currentTurn
        do {
            let result = try await perform(id, args: args, app: app, state: state, group: group)
            undoStack.push(group)
            return result
        } catch {
            group.undo()
            throw error
        }
    }

    /// Runs several actions as one undo group; the first error takes everything back and ends it.
    func runBatch(_ steps: [(id: String, args: JSONValue)], app: AppModel, channel: ActionChannel, run runID: String? = nil) async throws -> [JSONValue] {
        let state = runState(id: runID, channel: channel)
        let group = UndoGroup(label: "Stapel (\(steps.count))")
        group.runID = state.id
        group.turnID = state.currentTurn
        var results: [JSONValue] = []
        do {
            for step in steps {
                results.append(try await perform(step.id, args: step.args, app: app, state: state, group: group))
            }
        } catch {
            group.undo()
            if let failure = error as? RPCError {
                var data = failure.data?.objectValue ?? [:]
                data["step"] = .int(results.count)
                throw RPCError(code: failure.code, message: "Schritt \(results.count + 1): \(failure.message)", data: .object(data))
            }
            throw error
        }
        undoStack.push(group)
        return results
    }

    private func perform(_ id: String, args: JSONValue, app: AppModel, state: RunState, group: UndoGroup) async throws -> JSONValue {
        if lastApp !== app {
            undoStack.removeAll()
            lastApp = app
        }
        guard let entry = entries[id] else { throw RPCError.methodNotFound(id) }
        activeActions += 1
        defer { activeActions -= 1 }
        let descriptor = entry.descriptor
        // JSON without parameters arrives as null from some clients.
        let args: JSONValue = args == .null ? .object([:]) : args
        let problems = descriptor.input.problems(with: args)
        guard problems.isEmpty else { throw RPCError.invalidParams(problems.joined(separator: " ")) }

        let context = ActionContext(app: app, channel: state.channel, run: state, undoGroup: group, registry: self)
        context.flushEditor()

        // Before anything looks at the target: a closed door doesn't say what is behind it.
        if state.channel == .mcp, descriptor.security.sensitive {
            let refusal = ActionPolicy.decide(ActionPolicy.Input(channel: .mcp, runHasUntrusted: true, runHasSensitive: state.hasReadSensitive, security: descriptor.security, kind: descriptor.kind), level: .deny)
            if case .deny(let reason) = refusal {
                log.append(ActionLogEntry(channel: state.channel, run: state.id, action: id, target: nil, hadUntrusted: true, hadSensitive: state.hasReadSensitive, decision: refusal.label, error: reason))
                throw RPCError.denied(reason)
            }
        }

        var logEntry = ActionLogEntry(channel: state.channel, run: state.id, action: id, target: nil,
                                      hadUntrusted: state.hasReadUntrusted, hadSensitive: state.hasReadSensitive, decision: "")
        do {
            let preflight = try entry.preflight(args, context)
            logEntry.target = preflight.target
            var security = descriptor.security
            security.readsUntrusted = security.readsUntrusted || preflight.readsUntrusted
            security.sensitive = security.sensitive || preflight.readsSensitive
            let levelKind: ActionKind = preflight.isInSafePlace ? .write : descriptor.kind
            let level = state.approval?.level(for: levelKind, isSensitive: security.sensitive)
                ?? approval.level(channel: state.channel, kind: levelKind, settings: app.settings)
            var decision = ActionPolicy.decide(
                ActionPolicy.Input(channel: state.channel, runHasUntrusted: state.hasReadUntrusted, runHasSensitive: state.hasReadSensitive,
                                   security: security, kind: descriptor.kind),
                level: level
            )
            if let reason = preflight.needsConsent, decision == .allow { decision = .ask(reason: reason) }
            logEntry.decision = decision.label

            switch decision {
            case .allow:
                break
            case .deny(let reason):
                throw RPCError.denied(reason)
            case .ask(let reason):
                let request = ApprovalRequest(action: id, summary: descriptor.summary, channel: state.channel, target: preflight.target,
                                              detail: ActionApproval.abridged(preflight.detail), reason: reason, fullText: preflight.review)
                guard await approval.presenter(request) else {
                    logEntry.decision = "abgelehnt"
                    throw RPCError.denied("Nicht freigegeben: \(reason)")
                }
                logEntry.decision = "freigegeben"
                // While the dialog was open the text may have changed (another agent, a model writing): a place named
                // by position would now be another place, and what was agreed to was the call on the old text.
                if let version = preflight.version {
                    context.flushEditor()
                    let now = try entry.preflight(args, context).version
                    if now != version {
                        throw RPCError(code: RPCError.versionConflictCode, message: "Der Text hat sich geändert, während die Freigabe offen war. Bitte neu lesen.",
                                       data: .object(["version": .string(now ?? "")]))
                    }
                }
            }

            // It counts from here on, also if the action then fails half way through.
            if security.readsUntrusted { state.markUntrusted() }
            if security.sensitive { state.markSensitive() }

            let result = try await entry.run(args, context)
            log.append(logEntry)
            eventSink?(ActionEvent(kind: ActionEvent.actionExecuted, action: id, channel: state.channel.rawValue, run: state.id, target: preflight.target))
            return result
        } catch let error as RPCError {
            logEntry.error = error.message
            log.append(logEntry)
            throw error
        } catch {
            logEntry.error = error.localizedDescription
            log.append(logEntry)
            throw RPCError.internal(error.localizedDescription)
        }
    }
}
