import SwiftUI

/// Connects the toolbar with the text view: the formatting at the caret, and the commands.
@MainActor
@Observable
final class WriterEditorController {
    var state = WriterTextView.State()
    @ObservationIgnored weak var textView: WriterTextView?
    @ObservationIgnored weak var app: AppModel?

    func toggle(_ mark: WriterInline) { perform { $0.toggle(mark) } }
    func setBlock(_ block: WriterBlock, toggle: Bool = true) { perform { $0.setBlock(block, toggle: toggle) } }
    func changeListLevel(by step: Int) { perform { $0.changeListLevel(by: step) } }
    func insertRule() { perform { $0.insertRule() } }
    func editLink() { perform { $0.editLink() } }

    /// Reads the selection, or from the caret on; a second call stops.
    func readAloud() {
        guard let app, let textView else { return }
        if app.speakingDocumentID != nil { return app.stopReadingDocument() }
        let script = textView.speechScript()
        guard !script.text.isEmpty else { return app.showNotice("Hier gibt es nichts vorzulesen.") }
        app.readDocumentAloud(
            script.text,
            progress: { [weak textView] range in textView?.highlightSpoken(script.documentRange(for: range)) },
            ended: { [weak textView] in textView?.highlightSpoken(nil) }
        )
    }

    func toggleDictation() {
        guard let app else { return }
        focus()
        app.toggleDictation()
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    private func perform(_ action: (WriterTextView) -> Void) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        action(textView)
        state = textView.state
    }
}

/// The text view in its scroll view. Loads a document when its ID changes and reports the text as Markdown
/// shortly after every edit.
struct WriterEditor: NSViewRepresentable {
    let app: AppModel
    let document: WriterDocument
    let palette: WriterPalette
    let controller: WriterEditorController
    let assistant: WriterAssistant
    let isReadingAloud: Bool
    let isDictating: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.windowBackground
        scrollView.contentView.postsFrameChangedNotifications = true

        let textView = WriterTextView.make()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.controller = controller
        coordinator.onChange = { [weak app] id, markdown in app?.updateDocument(id, markdown: markdown) }
        controller.textView = textView
        controller.app = app
        textView.onStateChange = { [weak controller, weak textView] in
            guard let controller, let textView else { return }
            controller.state = textView.state
        }
        textView.onReadAloud = { [weak controller] in controller?.readAloud() }
        textView.onDictate = { [weak controller] in controller?.toggleDictation() }
        textView.onStopReading = { [weak app] in app?.stopReadingDocument() }
        assistant.app = app
        assistant.textView = textView
        textView.onAssistant = { [weak assistant] command in assistant?.handle(command) }
        // Pending edits are handed over before the app switches away or quits; dictation goes to this view.
        app.writerFlush = { [weak coordinator] in coordinator?.flush() }
        app.writerDictation = { [weak coordinator] event, id in coordinator?.dictation(event, for: id) }
        coordinator.observeResize(of: scrollView)
        coordinator.load(document, palette: palette)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.textView?.isReadingAloud = isReadingAloud
        coordinator.textView?.isDictating = isDictating
        if coordinator.documentID != document.id {
            assistant.reset()
            coordinator.flush()
            coordinator.load(document, palette: palette)
            return
        }
        guard let textView = coordinator.textView else { return }
        if textView.palette != palette || textView.family != document.font {
            textView.family = document.font
            textView.palette = palette
            scrollView.backgroundColor = palette.windowBackground
            textView.restyleAll()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: WriterTextView?
        weak var controller: WriterEditorController?
        var onChange: ((WriterDocument.ID, String) -> Void)?
        private(set) var documentID: WriterDocument.ID?
        private var isDirty = false
        private var pending: Task<Void, Never>?
        private var resizeObserver: NSObjectProtocol?

        func load(_ document: WriterDocument, palette: WriterPalette) {
            guard let textView else { return }
            documentID = document.id
            isDirty = false
            textView.load(markdown: document.markdown, family: document.font, palette: palette)
            controller?.state = textView.state
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            isDirty = true
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        func dictation(_ event: WriterDictationEvent, for id: WriterDocument.ID) {
            // Words for a document that is no longer open are dropped.
            guard id == documentID, let textView else { return }
            switch event {
            case .volatile(let text): textView.showDictationPreview(text)
            case .final(let text): textView.insertDictatedText(text)
            case .ended: textView.endDictation()
            }
        }

        /// Reports the current text right away if it changed since the last report.
        func flush() {
            pending?.cancel()
            pending = nil
            guard isDirty, let documentID, let textView else { return }
            isDirty = false
            onChange?(documentID, textView.markdown)
        }

        /// The sheet reaches down to the bottom of the window, even for a short text.
        func observeResize(of scrollView: NSScrollView) {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let textView = self?.textView else { return }
                    textView.setFrameSize(textView.frame.size)
                    textView.needsDisplay = true
                }
            }
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }
    }
}
