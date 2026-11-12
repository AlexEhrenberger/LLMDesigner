import SwiftUI
import AppKit

/// What a to-do's line does with the keys an outliner has: Return starts the next to-do (splitting the text at the
/// caret), Tab and ⇧Tab move it in and out, Backspace on an empty line removes it, the arrows go to the line above or
/// below. Pasting several lines makes several to-dos.
struct NoteLineActions {
    var onReturn: ((_ before: String, _ after: String) -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onDeleteEmpty: (() -> Void)?
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onPasteLines: (([String]) -> Void)?
}

/// One line of text on AppKit's text view, for the title and the to-dos of a note. Like `StoryTextEditor`, it tells
/// SwiftUI only when its height changes, so typing doesn't lay out the note again. Long text wraps.
struct NoteLineEditor: View {
    var placeholder = ""
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13.5)
    var isDone = false
    /// The line should take the keyboard (a new to-do, or one moved by Tab).
    var wantsFocus = false
    var caretAtEnd = true
    var onFocused: () -> Void = {}
    var actions = NoteLineActions()
    @State private var height: CGFloat?

    var body: some View {
        NoteLineHost(placeholder: placeholder, text: $text, font: font, isDone: isDone, wantsFocus: wantsFocus, caretAtEnd: caretAtEnd,
                     onFocused: onFocused, actions: actions) { newHeight in
            if height != newHeight { height = newHeight }
        }
        .frame(height: height ?? NoteLineHost.lineHeight(font))
    }
}

private struct NoteLineHost: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let font: NSFont
    let isDone: Bool
    let wantsFocus: Bool
    let caretAtEnd: Bool
    let onFocused: () -> Void
    let actions: NoteLineActions
    let onHeight: (CGFloat) -> Void

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoteLineTextView {
        let textView = NoteLineTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.font = font
        textView.dataDisplay.view = textView
        textView.dataDisplay.set(text)
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        textView.dataDisplay.onSwap = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        // Reads the callback of the latest update, so a row that moved still clears its own request.
        textView.onFocus = { [weak coordinator = context.coordinator] in
            guard let done = coordinator?.parent.onFocused else { return }
            DispatchQueue.main.async { done() }
        }
        context.coordinator.textView = textView
        context.coordinator.applyLook()
        return textView
    }

    func updateNSView(_ textView: NoteLineTextView, context: Context) {
        let coordinator = context.coordinator
        let lookChanged = coordinator.parent.isDone != isDone
        coordinator.parent = self
        if textView.dataDisplay.text != text {
            textView.dataDisplay.set(text)
            coordinator.applyLook()
            textView.needsDisplay = true
            coordinator.reportHeight()
        } else if lookChanged {
            coordinator.applyLook()
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if wantsFocus {
            textView.pendingFocus = caretAtEnd ? .end : .start
            textView.takeFocusIfPending()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteLineHost
        weak var textView: NoteLineTextView?
        private var reported: CGFloat?

        init(_ parent: NoteLineHost) {
            self.parent = parent
        }

        /// Done to-dos are struck through and grey; the typing attributes follow, so new letters look the same.
        func applyLook() {
            guard let textView else { return }
            let color = parent.isDone ? NSColor(Theme.textTertiary) : NSColor(Theme.textPrimary)
            var attributes: [NSAttributedString.Key: Any] = [.font: parent.font, .foregroundColor: color]
            if parent.isDone {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = NSColor(Theme.textTertiary)
            }
            textView.typingAttributes = attributes
            textView.insertionPointColor = NSColor(Theme.textPrimary)
            if let storage = textView.textStorage, storage.length > 0 {
                storage.beginEditing()
                // Added, not set: the highlight of data field values stays.
                let all = NSRange(location: 0, length: storage.length)
                storage.removeAttribute(.strikethroughStyle, range: all)
                storage.removeAttribute(.strikethroughColor, range: all)
                storage.addAttributes(attributes, range: all)
                storage.endEditing()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let actions = parent.actions
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                guard let onReturn = actions.onReturn else {
                    textView.window?.makeFirstResponder(nil)
                    return true
                }
                let string = textView.string as NSString
                let caret = min(textView.selectedRange().location, string.length)
                let end = min(NSMaxRange(textView.selectedRange()), string.length)
                parent.text = textView.string
                onReturn(string.substring(to: caret), string.substring(from: end))
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let onTab = actions.onTab { parent.text = textView.string; onTab() } else { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if let onBacktab = actions.onBacktab { parent.text = textView.string; onBacktab() } else { textView.window?.selectPreviousKeyView(nil) }
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty, let onDeleteEmpty = actions.onDeleteEmpty else { return false }
                onDeleteEmpty()
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let onUp = actions.onUp, isOnFirstLine(textView) else { return false }
                onUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let onDown = actions.onDown, isOnLastLine(textView) else { return false }
                onDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        /// One line keeps one line: pasted lines become to-dos of their own where the list allows it, else spaces.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, text.contains(where: \.isNewline) else { return true }
            let parts = text.components(separatedBy: .newlines)
            let rest = parts.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let onPasteLines = parent.actions.onPasteLines, !rest.isEmpty {
                // The first piece continues this line as it was pasted; the others become to-dos below it.
                textView.insertText(parts[0], replacementRange: range)
                parent.text = textView.string
                onPasteLines(Array(rest))
                return false
            }
            let flat = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
            textView.insertText(flat, replacementRange: range)
            return false
        }

        private func caretLineRect(_ textView: NSTextView) -> (line: NSRect, used: NSRect)? {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let length = (textView.string as NSString).length
            guard length > 0 else { return (.zero, used) }
            let location = min(textView.selectedRange().location, length)
            let glyph = layoutManager.glyphIndexForCharacter(at: location == length ? max(0, length - 1) : location)
            return (layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), used)
        }

        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            guard let rects = caretLineRect(textView) else { return true }
            return rects.line.minY <= rects.used.minY + 0.5
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            guard let rects = caretLineRect(textView) else { return true }
            return rects.line.maxY >= rects.used.maxY - 0.5
        }

        func reportHeight() {
            guard let textView, let container = textView.textContainer, let layoutManager = textView.layoutManager,
                  textView.bounds.width > 0 else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = NoteLineHost.lineHeight(parent.font)
            let height = max(ceil(layoutManager.usedRect(for: container).height), lineHeight)
            guard height != reported else { return }
            reported = height
            let onHeight = parent.onHeight
            DispatchQueue.main.async { onHeight(height) }
        }
    }
}

final class NoteLineTextView: NSTextView {
    enum Caret { case start, end }

    var placeholder = ""
    var onWidthChange: (() -> Void)?
    var onFocus: (() -> Void)?
    /// Where the caret goes once the view can take the keyboard.
    var pendingFocus: Caret?
    private var lastWidth: CGFloat = 0
    /// Values of `{{…}}` fields while the line isn't being edited.
    let dataDisplay = DataValueDisplay()

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { dataDisplay.beginEditing() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dataDisplay.endEditing() }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width != lastWidth {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfPending()
    }

    /// A line made a moment ago is not in the window yet; it takes the keyboard as soon as it is.
    func takeFocusIfPending() {
        guard let caret = pendingFocus, let window else { return }
        pendingFocus = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            let length = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: caret == .end ? length : 0, length: 0))
            self.onFocus?()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if string.count <= 1 { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        let origin = textContainerOrigin
        (placeholder as NSString).draw(in: NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: bounds.height),
                                       withAttributes: attributes)
    }
}
