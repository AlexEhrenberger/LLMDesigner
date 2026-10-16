import AppKit

extension NSTextView {
    /// Takes this view's edits off the undo stack. All text views of a window share its undo manager, and the
    /// typing actions point at the text storage without keeping it: once the view is gone, ⌘Z would message
    /// freed memory, and after the text was replaced from outside the old ranges no longer fit.
    func removeUndoActions() {
        guard let undoManager else { return }
        if let textStorage { undoManager.removeAllActions(withTarget: textStorage) }
        undoManager.removeAllActions(withTarget: self)
    }

    /// For `viewWillMove(toWindow:)`: the view leaves its window (while it can still reach the undo manager).
    func removeUndoActionsIfLeaving(for newWindow: NSWindow?) {
        if window != nil, newWindow !== window { removeUndoActions() }
    }
}
