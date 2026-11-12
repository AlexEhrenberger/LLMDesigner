import SwiftUI
import AppKit

/// A text field for Stories Studio's long forms, on AppKit's text view; it grows with its text.
///
/// SwiftUI's `TextField(axis: .vertical)` reports a possibly new size on every keystroke, and in a page with dozens
/// of fields each report made SwiftUI lay out the whole window again, measuring every other field too. This one
/// tells SwiftUI only when its height changes (a line more or less); typing within a line costs no layout at all.
/// Return starts a new line (with `singleLine`, it ends the input), Tab moves on to the next field.
struct StoryTextEditor: View {
    var placeholder = ""
    @Binding var text: String
    /// The height in lines it starts with; it grows with the text beyond that.
    var minLines = 1
    var font: NSFont = .systemFont(ofSize: 13)
    var color: NSColor = NSColor(Theme.textPrimary)
    /// A name or a title: no line breaks (long text still wraps), Return ends the input.
    var singleLine = false
    /// Takes the keyboard when it appears (a new element's name, a new scene).
    var focusOnAppear = false
    /// How the lines sit (project pages set text centred or to the right).
    var alignment: NSTextAlignment = .natural
    @State private var height: CGFloat?

    var body: some View {
        StoryTextViewHost(placeholder: placeholder, text: $text, minLines: minLines, font: font, color: color,
                          singleLine: singleLine, focusOnAppear: focusOnAppear, alignment: alignment) { newHeight in
            if height != newHeight { height = newHeight }
        }
        .frame(height: height ?? StoryTextViewHost.lineHeight(font) * CGFloat(max(minLines, 1)))
    }
}

private struct StoryTextViewHost: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let minLines: Int
    let font: NSFont
    let color: NSColor
    let singleLine: Bool
    let focusOnAppear: Bool
    let alignment: NSTextAlignment
    let onHeight: (CGFloat) -> Void

    /// Colours made from SwiftUI are new objects on every update, so the style is compared by what it looks like.
    static func styleKey(font: NSFont, color: NSColor, alignment: NSTextAlignment, in view: NSView) -> String {
        var rgb = ""
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) { rgb = String(format: "%.3f,%.3f,%.3f,%.3f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent) }
        }
        return "\(font.fontName)|\(font.pointSize)|\(alignment.rawValue)|\(rgb)"
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> StoryTextView {
        let textView = StoryTextView(frame: .zero)
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
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        textView.alignment = alignment
        textView.dataDisplay.view = textView
        textView.dataDisplay.set(text)
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        textView.dataDisplay.onSwap = { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        textView.focusOnAppear = focusOnAppear
        context.coordinator.textView = textView
        return textView
    }

    func updateNSView(_ textView: StoryTextView, context: Context) {
        context.coordinator.parent = self
        // Only text changed from outside (another field, the power access) is put in; while typing the two agree.
        if textView.dataDisplay.text != text {
            textView.dataDisplay.set(text)
            textView.needsDisplay = true
            context.coordinator.reportHeight()
        }
        // A style chosen while the field is shown (font, colour, alignment) goes onto all of its text.
        let style = Self.styleKey(font: font, color: color, alignment: alignment, in: textView)
        if context.coordinator.styleKey == nil { context.coordinator.styleKey = style }
        if context.coordinator.styleKey != style {
            context.coordinator.styleKey = style
            textView.font = font
            textView.textColor = color
            textView.insertionPointColor = color
            textView.typingAttributes = [.font: font, .foregroundColor: color]
            textView.alignment = alignment
            context.coordinator.reportHeight()
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StoryTextViewHost
        weak var textView: StoryTextView?
        var styleKey: String?
        private var reported: CGFloat?

        init(_ parent: StoryTextViewHost) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if parent.singleLine, [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                                   #selector(NSResponder.insertLineBreak(_:))].contains(selector) {
                textView.window?.makeFirstResponder(nil)
                return true
            }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        /// A single line takes pasted text with its line breaks as spaces.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard parent.singleLine, let text, text.contains(where: \.isNewline) else { return true }
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            textView.insertText(flat, replacementRange: range)
            return false
        }

        /// Lays the text out at the view's width and tells SwiftUI the height if it changed.
        func reportHeight() {
            guard let textView, let container = textView.textContainer, let layoutManager = textView.layoutManager,
                  textView.bounds.width > 0 else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = StoryTextViewHost.lineHeight(parent.font)
            let used = ceil(layoutManager.usedRect(for: container).height)
            let height = max(used, lineHeight * CGFloat(max(parent.minLines, 1)))
            guard height != reported else { return }
            reported = height
            let onHeight = parent.onHeight
            // Not during SwiftUI's own update of the view.
            DispatchQueue.main.async { onHeight(height) }
        }
    }
}

/// The text view: draws its placeholder while empty and reports when its width changes (the window was resized).
final class StoryTextView: NSTextView {
    var placeholder = ""
    var onWidthChange: (() -> Void)?
    var focusOnAppear = false
    private var lastWidth: CGFloat = 0
    /// Values of `{{…}}` fields while the field isn't being edited.
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
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder comes and goes with the first character.
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
