import Foundation

/// One reversible change: how to take it back and how to do it again.
struct UndoStep {
    let label: String
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
}

/// All changes of one action or batch. Taken back as a unit.
@MainActor
final class UndoGroup {
    let id = UUID()
    /// The run it belongs to; "undo this answer" takes back all groups of a run and turn.
    var runID: String?
    var label: String
    private(set) var steps: [UndoStep] = []
    /// Documents already snapshotted in this group.
    var snapshotted: Set<UUID> = []

    init(label: String) {
        self.label = label
    }

    func add(_ step: UndoStep) {
        steps.append(step)
    }

    func undo() {
        for step in steps.reversed() { step.undo() }
    }

    func redo() {
        for step in steps { step.redo() }
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

    /// Takes back the newest group that touches `target` (any, if nil). Returns its label.
    func undo(where matches: (UndoGroup) -> Bool = { _ in true }) -> String? {
        guard let index = done.lastIndex(where: matches) else { return nil }
        let group = done.remove(at: index)
        group.undo()
        undone.append(group)
        return group.label
    }

    func redo(where matches: (UndoGroup) -> Bool = { _ in true }) -> String? {
        guard let index = undone.lastIndex(where: matches) else { return nil }
        let group = undone.remove(at: index)
        group.redo()
        done.append(group)
        return group.label
    }

    /// Takes back all groups of a run, newest first. Returns how many.
    func undoAll(run: String) -> Int {
        var count = 0
        while undo(where: { $0.runID == run }) != nil { count += 1 }
        return count
    }

    func removeAll() {
        done = []
        undone = []
    }
}
