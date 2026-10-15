import SwiftUI

/// Connects the toolbar with the text view: the formatting at the caret, and the commands.
@MainActor
@Observable
final class WriterEditorController {
    var state = WriterTextView.State()
    /// The formula editor is open for this.
    var formulaRequest: WriterFormulaRequest?
    /// The Draw Things sheet is open for this.
    var imageRequest: WriterImageGenerationRequest?
    /// The heading the reader is in (for the side panel).
    var currentHeading: Int?
    /// A bookmark that was just made; the side panel shows it highlighted for a moment.
    var recentBookmarkID: String?
    /// Presenter Studio: the slide's text is longer than the slide.
    var slideOverflows = false
    @ObservationIgnored weak var textView: WriterTextView?
    @ObservationIgnored weak var app: AppModel?

    func toggle(_ mark: WriterInline) { perform { $0.toggle(mark) } }
    func setBlock(_ block: WriterBlock, toggle: Bool = true) { perform { $0.setBlock(block, toggle: toggle) } }
    func changeListLevel(by step: Int) { perform { $0.changeListLevel(by: step) } }
    func insertRule() { perform { $0.insertRule() } }
    func editLink() { perform { $0.editLink() } }
    func insertTable(rows: Int, columns: Int) { perform { $0.insertTable(rows: rows, columns: columns) } }
    func tableAction(_ action: WriterTableAction) { perform { $0.performTableAction(action) } }
    func insertTableOfContents(dynamic: Bool = false) { perform { $0.insertTableOfContents(dynamic: dynamic) } }
    func setTableOfContents(dynamic: Bool) { perform { $0.setTableOfContents(dynamic: dynamic) } }
    func editFormula() { perform { $0.editFormulaAtCaret() } }
    func generateImage() { perform { $0.generateImageAtCaret() } }

    // MARK: Citations

    func showCitationPicker() { perform { $0.showCitationPicker() } }
    func insertBibliography() { perform { $0.insertBibliography() } }
    func insertQuote(_ quote: CitationQuote, source: CitationSource, as insertion: CitationInsertion) {
        perform { $0.insertQuote(quote, source: source, as: insertion) }
    }
    func insertCitation(_ source: CitationSource) {
        perform { $0.insertCitation([CitationItem(key: source.citekey)]) }
    }
    func toggleBookmark() {
        perform { textView in
            if let bookmark = textView.bookmarkAtCaret, textView.selectedRange().length == 0 {
                textView.removeBookmark(bookmark.id)
            } else {
                textView.addBookmark()
            }
        }
    }

    // MARK: Formula editor

    func applyFormula(latex: String, display: Bool, plot: WriterImageReference?, isExisting: Bool) {
        formulaRequest = nil
        perform { $0.applyFormula(latex: latex, display: display, plot: plot, isExisting: isExisting) }
    }

    func cancelFormula() {
        formulaRequest = nil
        textView?.trackedRanges[WriterTextView.formulaKey] = nil
        focus()
    }

    // MARK: Draw Things

    func applyGeneratedImage(info: GeneratedImageInfo, caption: String, generate: Bool, isExisting: Bool) {
        imageRequest = nil
        perform { $0.applyGeneratedImage(info: info, caption: caption, generate: generate, isExisting: isExisting) }
    }

    func cancelImageGeneration() {
        imageRequest = nil
        textView?.trackedRanges[WriterTextView.generationKey] = nil
        focus()
    }

    // MARK: Side panel

    func jumpToHeading(_ index: Int) { textView?.jumpToHeading(index) }
    func jump(to anchor: DocumentAnchor, blockCount: Int) { textView?.jump(to: anchor, blockCount: blockCount) }
    func jumpToBookmark(_ id: String) { textView?.jumpToBookmark(id) }
    func renameBookmark(_ id: String, to title: String) { textView?.renameBookmark(id, to: title) }
    func removeBookmark(_ id: String) { textView?.removeBookmark(id) }

    func bookmarkAdded(_ id: String) {
        guard let app else { return }
        app.documentPanelTab = .bookmarks
        if !app.outlinePanelVisible { withAnimation(.smooth(duration: 0.28)) { app.outlinePanelVisible = true } }
        recentBookmarkID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if self.recentBookmarkID == id { self.recentBookmarkID = nil }
        }
    }

    func updateCurrentHeading() {
        let heading = textView?.headingAtTop()
        if heading != currentHeading { currentHeading = heading }
    }

    /// Asks for pictures and puts them below the current paragraph.
    func chooseImages() {
        guard let window = textView?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Einfügen"
        panel.message = "Bilder für das Dokument auswählen"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let sources = panel.urls.map { AttachmentStore.Source.file($0) }
            self?.perform { $0.insertImages(sources) }
        }
    }

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

/// Presenter Studio: the editor shows one slide of a presentation instead of a document's text.
struct WriterSlideContent: Equatable {
    let id: PresentationSlide.ID
    let markdown: String
    let layout: WriterTextView.SlideLayout
}

/// The text view in its scroll view. Loads a document (or a slide) when its ID changes and reports the text as
/// Markdown shortly after every edit.
struct WriterEditor: NSViewRepresentable {
    let app: AppModel
    let document: WriterDocument
    let palette: WriterPalette
    let controller: WriterEditorController
    let assistant: WriterAssistant
    let isReadingAloud: Bool
    let isDictating: Bool
    var slide: WriterSlideContent?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView: NSScrollView = slide == nil ? NSScrollView() : SlideScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = slide == nil
        scrollView.backgroundColor = palette.windowBackground
        scrollView.contentView.drawsBackground = slide == nil
        scrollView.contentView.postsFrameChangedNotifications = true

        let textView = WriterTextView.make()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.slideLayout = slide?.layout
        scrollView.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.controller = controller
        coordinator.onChange = { [weak app, weak coordinator] id, markdown in
            if let slideID = coordinator?.slideID {
                app?.updateSlide(id, slideID, markdown: markdown)
            } else {
                app?.updateDocument(id, markdown: markdown)
            }
        }
        controller.textView = textView
        controller.app = app
        textView.onStateChange = { [weak controller, weak textView] in
            guard let controller, let textView else { return }
            controller.state = textView.state
        }
        textView.onReadAloud = { [weak controller] in controller?.readAloud() }
        textView.onSlideOverflow = { [weak controller] overflows in controller?.slideOverflows = overflows }
        textView.onDictate = { [weak controller] in controller?.toggleDictation() }
        textView.onStopReading = { [weak app] in app?.stopReadingDocument() }
        textView.onNotice = { [weak app] in app?.showNotice($0) }
        textView.onFormula = { [weak controller] request in controller?.formulaRequest = request }
        textView.citations = app.citations
        textView.onShowSource = { [weak app] id in app?.openCitationStudio(showing: id) }
        textView.onImageGeneration = { [weak controller] request in controller?.imageRequest = request }
        textView.onGenerateImage = { [weak app] source, info in app?.imageGeneration.generate(source: source, info: info) }
        textView.onCancelImageGeneration = { [weak app] source in app?.imageGeneration.cancel(source) }
        textView.onImageDefaults = { [weak app] in app?.imageGeneration.defaults ?? GeneratedImageInfo() }
        textView.onDocumentTitle = { [weak app, weak coordinator] in
            coordinator?.documentID.flatMap { app?.document($0)?.title } ?? ""
        }
        coordinator.observeImageGeneration()
        // A dynamic table of contents put into the text: the model makes the topics if there are none yet.
        textView.onDynamicTOCNeeded = { [weak app, weak coordinator] in
            guard let app, let id = coordinator?.documentID, let document = app.document(id) else { return }
            app.writerFlush?()
            if document.outline == nil || DocumentOutlineBuilder.isOutdated(document) { app.refreshDocumentOutline(id) }
        }
        textView.onBookmarkAdded = { [weak controller] id in controller?.bookmarkAdded(id) }
        textView.onOutlineChange = { [weak controller] in
            DispatchQueue.main.async { controller?.updateCurrentHeading() }
        }
        assistant.app = app
        assistant.textView = textView
        textView.onAssistant = { [weak assistant] command in assistant?.handle(command) }
        // Pending edits are handed over before the app switches away or quits; dictation goes to this view.
        app.writerFlush = { [weak coordinator] in coordinator?.flush() }
        app.writerDictation = { [weak coordinator] event, id in coordinator?.dictation(event, for: id) }
        coordinator.observeResize(of: scrollView)
        coordinator.observeScrolling(of: scrollView)
        coordinator.load(document, slide: slide, palette: palette)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.textView?.isReadingAloud = isReadingAloud
        coordinator.textView?.isDictating = isDictating
        if coordinator.documentID != document.id || coordinator.slideID != slide?.id {
            assistant.reset()
            coordinator.flush()
            coordinator.textView?.slideLayout = slide?.layout
            coordinator.load(document, slide: slide, palette: palette)
            return
        }
        guard let textView = coordinator.textView else { return }
        textView.dynamicOutline = document.outline
        if let slide, textView.slideLayout != slide.layout {
            textView.slideLayout = slide.layout
            if textView.palette == palette { textView.restyleAll() }
        }
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
        /// The slide shown, in Presenter Studio.
        private(set) var slideID: PresentationSlide.ID?
        private var isDirty = false
        private var pending: Task<Void, Never>?
        private var resizeObserver: NSObjectProtocol?
        private var scrollObserver: NSObjectProtocol?
        private var scrollUpdatePending = false
        private var generationObserver: NSObjectProtocol?
        private var generationTimer: Timer?

        func load(_ document: WriterDocument, slide: WriterSlideContent?, palette: WriterPalette) {
            guard let textView else { return }
            documentID = document.id
            slideID = slide?.id
            isDirty = false
            textView.dynamicOutline = document.outline
            // Citations are drawn in the style of this document's sources.
            textView.citations?.loadIfNeeded()
            textView.citationStyleCache = nil
            textView.lastCitedKeys = []
            textView.load(markdown: slide?.markdown ?? document.markdown, family: document.font, palette: palette)
            controller?.state = textView.state
            updateGenerationTimer()
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            textView?.citationsChanged()
            textView?.checkCiteTrigger()
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

        /// While scrolling, the side panel follows the heading the reader is in.
        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.scrollUpdatePending else { return }
                    self.scrollUpdatePending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.scrollUpdatePending = false
                        self?.controller?.updateCurrentHeading()
                    }
                }
            }
        }

        /// A picture made with Draw Things changed its phase or is done: its place is drawn anew; while pictures
        /// are being made, their placeholders tick every second.
        func observeImageGeneration() {
            generationObserver = NotificationCenter.default.addObserver(
                forName: ImageGenerationCenter.didChange, object: nil, queue: .main
            ) { [weak self] notification in
                guard let source = notification.object as? String else { return }
                MainActor.assumeIsolated {
                    self?.textView?.refreshGeneratedImage(source)
                    self?.updateGenerationTimer()
                }
            }
        }

        private func updateGenerationTimer() {
            let running = !(textView?.generatingSources.isEmpty ?? true)
            if running, generationTimer == nil {
                generationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.textView?.redrawGeneratingImages() }
                }
            } else if !running {
                generationTimer?.invalidate()
                generationTimer = nil
            }
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let generationObserver { NotificationCenter.default.removeObserver(generationObserver) }
            generationTimer?.invalidate()
        }
    }
}

/// The scroll view of a slide: the canvas keeps its size in points and is magnified to the width there is, so the
/// slide looks the same in the editor, the slide list and the presentation. Pinching doesn't change it.
class SlideScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 40
        hasHorizontalScroller = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitCanvas()
    }

    func fitCanvas() {
        guard bounds.width > 1 else { return }
        let target = bounds.width / WriterTextView.SlideLayout.canvas.width
        if abs(magnification - target) > 0.0005 { magnification = target }
    }
}
