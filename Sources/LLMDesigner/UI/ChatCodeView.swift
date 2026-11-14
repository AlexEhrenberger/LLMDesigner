import AppKit
import SwiftUI

/// How a code block's text changed since it was last shown.
enum CodeTextChange: Equatable {
    case none
    /// The model wrote on: only this is new.
    case append(String)
    case replace(String)

    static func between(_ shown: String, _ code: String) -> CodeTextChange {
        if shown == code { return .none }
        // While streaming, the new text starts with the old one; comparing bytes is enough and cheap.
        if !shown.isEmpty, code.utf8.count > shown.utf8.count, code.utf8.starts(with: shown.utf8) {
            return .append(String(decoding: code.utf8.dropFirst(shown.utf8.count), as: UTF8.self))
        }
        return .replace(code)
    }
}

/// The code of a chat answer in a text view that only appends what is new.
///
/// One SwiftUI `Text` with many lines costs time that grows with the square of its lines (1000 lines: over 600 ms per
/// update), and a growing code block is laid out again with every piece the model writes. TextKit lays out only the
/// appended part.
struct ChatCodeView: NSViewRepresentable {
    let code: String

    static let inset = NSSize(width: 14, height: 14)

    final class Coordinator {
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChatCodeScrollView {
        let scrollView = ChatCodeScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder

        // TextKit 1: appending keeps the layout of everything before.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = false
        textView.typingAttributes = Self.attributes
        scrollView.documentView = textView
        show(code, in: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: ChatCodeScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        show(code, in: textView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: ChatCodeScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let width = proposal.width ?? ceil(used.width) + Self.inset.width * 2
        return CGSize(width: width, height: ceil(used.height) + Self.inset.height * 2)
    }

    private func show(_ code: String, in textView: NSTextView, coordinator: Coordinator) {
        guard let storage = textView.textStorage else { return }
        switch CodeTextChange.between(coordinator.shown, code) {
        case .none:
            return
        case .append(let tail):
            storage.append(NSAttributedString(string: tail, attributes: Self.attributes))
        case .replace(let text):
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        }
        coordinator.shown = code
        textView.sizeToFit()
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            // Resolves per design when drawn, so a change of design needs no update.
            .foregroundColor: NSColor(Theme.textPrimary),
            .paragraphStyle: paragraph,
        ]
    }
}

/// Scrolls code sideways only; up and down belong to the chat around it.
final class ChatCodeScrollView: NSScrollView {
    private var forwardsGesture = false
    private var decided = false

    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let hasDelta = event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        if event.phase == .began {
            decided = false
        }
        if event.phase == [] && event.momentumPhase == [] {
            // A mouse wheel: each tick decides for itself.
            forwardsGesture = !horizontal
        } else if !decided && hasDelta && event.momentumPhase == [] {
            // A trackpad gesture keeps the direction of its first movement, momentum included.
            decided = true
            forwardsGesture = !horizontal
        }
        if forwardsGesture {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
