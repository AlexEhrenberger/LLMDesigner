import Foundation
import LLMDProtocol

/// One reversible change: how to take it back and how to do it again.
struct UndoStep {
    let label: String
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
    /// The document the step changed, if it is about one.
    var document: UUID? = nil
    /// How it found and left the document. A step restores what it found; if the person (or anyone) changed the
    /// document since, that would take their change along. Steps without it are taken back as they are.
    var states: UndoStates? = nil
}

/// A document before and after a step, and as it is now; nil for one that isn't there.
struct UndoStates {
    let found: AnyHashable?
    let left: AnyHashable?
    let now: @MainActor () -> AnyHashable?
}

/// All changes of one action or batch. Taken back as a unit.
@MainActor
final class UndoGroup {
    let id = UUID()
    /// The run it belongs to; "undo this answer" takes back all groups of a run and turn.
    var runID: String?
    /// The answer of a chat it happened in; "undo this answer" takes back all groups of a turn.
    var turnID: UUID?
    var label: String
    private(set) var steps: [UndoStep] = []
    /// The documents this group changed, for "undo in this document".
    var documents: Set<UUID> = []

    init(label: String) {
        self.label = label
    }

    func add(_ step: UndoStep) {
        steps.append(step)
    }

    /// Documents changed by someone else since or between the steps: taking the group back would take that along.
    var changedSinceDone: Set<UUID> { breaks(forward: false) }

    /// The same for doing it again after it was taken back.
    var changedSinceUndone: Set<UUID> { breaks(forward: true) }

    /// Walks each document's chain of steps from its state now: every step has to have left what the next found.
    private func breaks(forward: Bool) -> Set<UUID> {
        var expected: [UUID: AnyHashable?] = [:]
        var broken = Set<UUID>()
        for step in forward ? steps : steps.reversed() {
            guard let document = step.document, let states = step.states, !broken.contains(document) else { continue }
            let now = expected[document] ?? states.now()
            if now != (forward ? states.found : states.left) { broken.insert(document) }
            expected[document] = forward ? states.left : states.found
        }
        return broken
    }

    /// Takes the steps back, newest first. On a document someone else changed meanwhile it stops there, so their
    /// change stays. Returns those documents.
    @discardableResult
    func undo() -> Set<UUID> { apply(forward: false) }

    @discardableResult
    func redo() -> Set<UUID> { apply(forward: true) }

    private func apply(forward: Bool) -> Set<UUID> {
        var kept = Set<UUID>()
        for step in forward ? steps : steps.reversed() {
            if let document = step.document, let states = step.states {
                guard !kept.contains(document), states.now() == (forward ? states.found : states.left) else {
                    kept.insert(document)
                    continue
                }
            }
            if forward { step.redo() } else { step.undo() }
        }
        return kept
    }

    var isEmpty: Bool { steps.isEmpty }
}

/// What the registry can take back. Independent of the editor's own undo, because actions also run on documents that
/// aren't open.
@MainActor
final class ActionUndoStack {
    static let capacity = 200
    private(set) var done: [UndoGroup] = []
    private(set) var undone: [UndoGroup] = []

    func push(_ group: UndoGroup) {
        guard !group.isEmpty else { return }
        done.append(group)
        undone = []
        if done.count > Self.capacity { done.removeFirst(done.count - Self.capacity) }
    }

    private static func conflict(_ group: UndoGroup, _ what: String) -> RPCError {
        RPCError(code: RPCError.versionConflictCode,
                 message: "„\(group.label)“ lässt sich nicht \(what): Das Dokument wurde danach geändert, und das ginge mit verloren.")
    }

    /// Takes back the newest group that `matches` (any). Returns its label; a group whose documents changed since stays
    /// and is a conflict.
    func undo(where matches: (UndoGroup) -> Bool = { _ in true }) throws -> String? {
        guard let index = done.lastIndex(where: matches) else { return nil }
        let group = done[index]
        guard group.changedSinceDone.isEmpty else { throw Self.conflict(group, "zurücknehmen") }
        done.remove(at: index)
        group.undo()
        undone.append(group)
        return group.label
    }

    func redo(where matches: (UndoGroup) -> Bool = { _ in true }) throws -> String? {
        guard let index = undone.lastIndex(where: matches) else { return nil }
        let group = undone[index]
        guard group.changedSinceUndone.isEmpty else { throw Self.conflict(group, "wiederherstellen") }
        undone.remove(at: index)
        group.redo()
        done.append(group)
        return group.label
    }

    /// Takes back all groups of an answer, newest first, up to one that can't go back. Returns how many.
    func undoAll(turn: UUID) -> Int {
        var count = 0
        while let label = try? undo(where: { $0.turnID == turn }), label != nil { count += 1 }
        return count
    }

    func removeAll() {
        done = []
        undone = []
    }
}
