import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Markdown of a Writer Studio selection, so formatting survives copy and paste between documents.
    static let writerMarkdown = NSPasteboard.PasteboardType("app.llmdesigner.writer-markdown")
}

/// The editor of Writer Studio: a sheet in the middle of the window, text with Markdown meaning underneath.
/// Formatting commands change only the meaning attributes; `WriterStyler` derives the look after every edit.
final class WriterTextView: NSTextView {
    var family: WriterFont = .serif
    var palette: WriterPalette = .dark {
        didSet { applyPalette() }
    }
    /// Called whenever text, formatting or selection changed, for the toolbar.
    var onStateChange: (() -> Void)?
    /// Context menu commands that need the app: read aloud (from the caret or the selection) and dictate.
    var onReadAloud: (() -> Void)?
    var onDictate: (() -> Void)?
    /// Whether the document is being read aloud or dictated into, for the context menu's titles.
    var isReadingAloud = false
    var isDictating = false
    /// Esc while the document is read aloud stops the voice.
    var onStopReading: (() -> Void)?

    // MARK: Assistant state (see WriterTextView+Assistant.swift)

    /// Places in the text that move along with edits: the AI cursor, the passage being written,
    /// a rewrite proposal's passage, the findings of a check.
    var trackedRanges: [String: NSRange] = [:]
    /// Ranges the assistant sets itself while it writes; edits don't move them.
    var untrackedKeys: Set<String> = []
    /// How the passage being written sits in the document.
    var aiPlacement: AIPlacement?
    var isAIWriting = false
    /// Commands from the context menu and ⌘J for the assistant.
    var onAssistant: ((WriterAssistantCommand) -> Void)?
    let aiCursorIndicator = AICursorIndicator()
    /// Messages for the user, e.g. a picture that can't be read.
    var onNotice: ((String) -> Void)?
    /// The bar on a selected picture (see WriterTextView+Images.swift).
    var imageControlsHost: NSView?
    /// Set while a table-safe or structural edit runs, so `shouldChangeText` lets it through.
    var isEditingStructure = false

    // MARK: Outline state (see WriterTextView+Outline.swift)

    var outlineCache: OutlineCache?
    var outlineRefreshPending = false
    var lastOutlineSignature = ""
    /// The headings changed (for the side panel).
    var onOutlineChange: (() -> Void)?
    /// A bookmark was just made; the side panel shows it.
    var onBookmarkAdded: ((String) -> Void)?
    /// Opens the formula editor (see WriterTextView+Math.swift).
    var onFormula: ((WriterFormulaRequest) -> Void)?
    /// Pictures made with Draw Things (see WriterTextView+Generation.swift): opens the sheet, starts and cancels
    /// a picture, and gives the choices of the last picture and the document's title.
    var onImageGeneration: ((WriterImageGenerationRequest) -> Void)?
    /// Presenter Studio: pictures inserted, pasted or dropped (at this point of the canvas) become free pictures on
    /// the slide instead of paragraphs; the same for a new picture from Draw Things and a picture taken out of the text.
    var onSlideImages: (([AttachmentStore.Source], CGPoint?) -> Void)?
    var onSlideGeneratedImage: ((GeneratedImageInfo, String, Bool) -> Void)?
    var onDetachSlideImage: ((WriterImageReference, CGRect) -> Void)?
    /// Where pictures are being dropped, while they are.
    var slideDropPoint: CGPoint?
    /// The text gets the keyboard (a free picture is then no longer selected).
    var onFocus: (() -> Void)?
    var onGenerateImage: ((String, GeneratedImageInfo) -> Void)?
    var onCancelImageGeneration: ((String) -> Void)?
    var onImageDefaults: (() -> GeneratedImageInfo)?
    var onDocumentTitle: (() -> String)?
    /// Citation Studio's sources and quotes (see WriterTextView+Citations.swift), the style made from them for
    /// this document, and opening a source there.
    var citations: CitationLibrary?
    var citationStyleCache: CitationStyle?
    var lastCitedKeys: [String] = []
    var onShowSource: ((UUID) -> Void)?
    /// The model's table of contents of the document; a dynamic table of contents block shows it.
    var dynamicOutline: DocumentOutline? {
        didSet { if oldValue != dynamicOutline { relayoutTablesOfContents() } }
    }
    /// A dynamic table of contents was put into the text; the model should make one if there is none yet.
    var onDynamicTOCNeeded: (() -> Void)?

    /// Words still being recognised never become typing attributes, so typed text isn't grey or lost. Outside a
    /// table, text never takes a cell's attributes (e.g. at the end of a document that ends with a table).
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attributes = newValue
            attributes.removeValue(forKey: .writerDictationPreview)
            // A formula is never a typing attribute; a bookmark only inside its passage.
            attributes.removeValue(forKey: .attachment)
            if let bookmark = attributes[.writerBookmark] as? WriterBookmark, textStorage == nil || !keepsBookmark(bookmark) {
                attributes.removeValue(forKey: .writerBookmark)
            }
            if attributes[.writerTable] != nil, textStorage != nil, tableCellAtCaret == nil {
                attributes = WriterStyler.typingAttributes(block: .paragraph, level: 0, semantic: attributes, family: family, palette: palette)
            }
            super.typingAttributes = attributes
        }
    }

    static let maxColumnWidth: CGFloat = 680
    private let pageTop: CGFloat = 28
    private let textTop: CGFloat = 92

    /// Presenter Studio: the view shows one slide on a canvas of fixed size (the scroll view magnifies it to fit)
    /// instead of a page; nothing but the text is drawn, the slide's background lies behind.
    struct SlideLayout: Equatable {
        /// The canvas in points: 16:9, small enough that the document fonts have slide proportions.
        static let canvas = CGSize(width: 720, height: 405)
        static let margin = CGSize(width: 46, height: 34)

        var centersVertically = false
        /// What an empty slide shows where its first line goes, and in which block.
        var placeholder = ""
        var firstBlock: WriterBlock = .heading1
        /// Free pictures the text flows around, on the canvas.
        var obstacles: [CGRect] = []
        /// The room kept between such a picture and the text.
        static let obstacleGap: CGFloat = 10

        init(role: SlideRole) {
            centersVertically = role != .content
            placeholder = role.placeholder
            firstBlock = role.firstBlock
        }

        init(slide: PresentationSlide, images: [SlideImage]? = nil) {
            self.init(role: slide.role)
            obstacles = (images ?? slide.images).filter { $0.placement == .wrap }.map(\.frame)
        }

        /// The same but for the pictures: changing only them needs no restyling.
        func sameText(as other: SlideLayout?) -> Bool {
            guard let other else { return false }
            return centersVertically == other.centersVertically && placeholder == other.placeholder && firstBlock == other.firstBlock
        }
    }

    var slideLayout: SlideLayout? {
        didSet {
            guard oldValue != slideLayout else { return }
            textContainerInset = slideLayout == nil ? NSSize(width: 0, height: 170) : NSSize(width: 0, height: SlideLayout.margin.height)
            updateSlideCentering()
        }
    }
    /// How far a centred slide's text sits below the top margin.
    private var slideCenterOffset: CGFloat = 0
    /// The slide's text is longer than the slide (reported to the screen as a hint).
    var onSlideOverflow: ((Bool) -> Void)?
    private var slideOverflows = false

    private let restyler = WriterRestyler()

    static func make() -> WriterTextView {
        let storage = NSTextStorage()
        let layoutManager = WriterLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: maxColumnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = WriterTextView(frame: .zero, textContainer: container)
        layoutManager.writerView = view
        view.restyler.view = view
        storage.delegate = view.restyler
        view.configure()
        return view
    }

    private func configure() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = true
        isAutomaticDashSubstitutionEnabled = true
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // Room below the text, so the end of the document can scroll above the assistant bar.
        textContainerInset = NSSize(width: 0, height: 170)
        drawsBackground = true
        applyPalette()
        // Pictures can be dropped in (see `acceptableDragTypes`).
        updateDragTypeRegistration()
    }

    private func applyPalette() {
        drawsBackground = !palette.isSlide
        backgroundColor = palette.windowBackground
        insertionPointColor = palette.accent
        selectedTextAttributes = [.backgroundColor: palette.selection]
        linkTextAttributes = [
            .foregroundColor: palette.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        enclosingScrollView?.backgroundColor = palette.windowBackground
        needsDisplay = true
    }

    // MARK: Page

    var columnWidth: CGFloat {
        if slideLayout != nil { return SlideLayout.canvas.width - 2 * SlideLayout.margin.width }
        return min(Self.maxColumnWidth, max(260, bounds.width - 120))
    }

    private var pagePadding: CGFloat {
        max(20, min(76, (bounds.width - columnWidth) / 2 - 18))
    }

    override var textContainerOrigin: NSPoint {
        if slideLayout != nil { return NSPoint(x: SlideLayout.margin.width, y: SlideLayout.margin.height + slideCenterOffset) }
        return NSPoint(x: floor((bounds.width - columnWidth) / 2), y: textTop)
    }

    /// A title or chapter slide keeps its text in the middle of the canvas; any slide reports when its text runs over.
    func updateSlideCentering() {
        guard let layout = slideLayout, let layoutManager, let container = textContainer else {
            if textContainer?.exclusionPaths.isEmpty == false { textContainer?.exclusionPaths = [] }
            if slideCenterOffset != 0 {
                slideCenterOffset = 0
                invalidateTextContainerOrigin()
            }
            return
        }
        let room = SlideLayout.canvas.height - 2 * SlideLayout.margin.height
        // The pictures' frames depend on where the text starts, and a centred text's start on its height with
        // them: a few rounds settle it.
        var offset = slideCenterOffset
        var used: CGFloat = 0
        for _ in 0..<3 {
            applySlideObstacles(layout.obstacles, offset: offset)
            layoutManager.ensureLayout(for: container)
            used = layoutManager.usedRect(for: container).height
            let next = layout.centersVertically ? max(0, floor((room - used) / 2)) : 0
            if abs(next - offset) <= 0.5 { break }
            offset = next
        }
        if abs(offset - slideCenterOffset) > 0.5 {
            slideCenterOffset = offset
            invalidateTextContainerOrigin()
            needsDisplay = true
            updateAICursorIndicator()
            updateImageControls()
        }
        let overflows = used > room + 1
        if overflows != slideOverflows {
            slideOverflows = overflows
            onSlideOverflow?(overflows)
        }
        setFrameSize(frame.size)
        // A slide that fits never stays scrolled.
        if !overflows, visibleRect.minY != 0 { scroll(.zero) }
    }

    /// The free pictures as exclusion paths of the text container (whose origin is the text's top left).
    private func applySlideObstacles(_ obstacles: [CGRect], offset: CGFloat) {
        guard let container = textContainer else { return }
        let origin = CGPoint(x: SlideLayout.margin.width, y: SlideLayout.margin.height + offset)
        let paths = obstacles.map { frame -> NSBezierPath in
            var rect = frame.insetBy(dx: -SlideLayout.obstacleGap, dy: -SlideLayout.obstacleGap)
            // The text passes the picture on one side only, the wider one: lines aren't torn in two.
            if frame.midX >= SlideLayout.canvas.width / 2 {
                rect = CGRect(x: rect.minX, y: rect.minY, width: SlideLayout.canvas.width + 100 - rect.minX, height: rect.height)
            } else {
                rect = CGRect(x: -100, y: rect.minY, width: rect.maxX + 100, height: rect.height)
            }
            return NSBezierPath(rect: rect.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        let old = container.exclusionPaths.map(\.bounds)
        if old != paths.map(\.bounds) { container.exclusionPaths = paths }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard slideLayout != nil else { return super.performDragOperation(sender) }
        slideDropPoint = convert(sender.draggingLocation, from: nil)
        defer { slideDropPoint = nil }
        return super.performDragOperation(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        guard slideLayout != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.updateSlideCentering() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var newSize = newSize
        if slideLayout != nil {
            // The canvas keeps its width; the scroll view magnifies it to the space there is. Its height is the
            // slide's (what AppKit computes ignores the centring), more only when the text runs over.
            newSize.width = SlideLayout.canvas.width
            let used = layoutManager.flatMap { manager in textContainer.map { manager.usedRect(for: $0).height } } ?? 0
            let visible = floor(enclosingScrollView?.contentView.bounds.height ?? SlideLayout.canvas.height)
            newSize.height = max(ceil(used) + 2 * SlideLayout.margin.height, min(visible, SlideLayout.canvas.height))
        } else if let visible = enclosingScrollView?.contentSize.height {
            // At least as tall as the visible area, so the sheet reaches the bottom of the window.
            newSize.height = max(newSize.height, visible)
        }
        super.setFrameSize(newSize)
        let width = columnWidth
        if let container = textContainer, abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateAICursorIndicator()
            self?.updateImageControls()
        }
    }

    override func drawBackground(in rect: NSRect) {
        if slideLayout != nil { return drawSlideBackground(in: rect) }
        palette.windowBackground.setFill()
        rect.fill()
        let origin = textContainerOrigin
        let page = NSRect(
            x: origin.x - pagePadding,
            y: pageTop,
            width: columnWidth + 2 * pagePadding,
            height: max(bounds.height, enclosingScrollView?.contentSize.height ?? 0) - pageTop + 40
        )
        let path = NSBezierPath(roundedRect: page, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(palette.isLight ? 0.45 : 0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        palette.page.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        palette.pageBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        // Heading numbers and bookmark marks sit in the page's margins, which only this layer draws.
        if let layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0, storage.editedMask.isEmpty {
            let inContainer = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: NSRect(x: 0, y: inContainer.minY - 40, width: container.size.width, height: inContainer.height + 80), in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            drawOutlineMarks(in: characters, origin: origin)
        }
    }

    /// A slide draws only its bookmark marks and, while it is empty, where its first line goes.
    private func drawSlideBackground(in rect: NSRect) {
        let origin = textContainerOrigin
        guard let storage = textStorage else { return }
        if storage.length == 0, let layout = slideLayout, !layout.placeholder.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = palette.alignment == .center ? .center : .natural
            let attributes: [NSAttributedString.Key: Any] = [
                .font: WriterStyler.blockFont(layout.firstBlock, family: family),
                .foregroundColor: palette.tertiaryText.withAlphaComponent(palette.isLight ? 0.38 : 0.42),
                .paragraphStyle: style,
            ]
            (layout.placeholder as NSString).draw(
                in: NSRect(x: origin.x, y: origin.y, width: columnWidth, height: 80), withAttributes: attributes
            )
        }
        if let layoutManager, let container = textContainer, storage.length > 0, storage.editedMask.isEmpty {
            let inContainer = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: NSRect(x: 0, y: inContainer.minY - 40, width: container.size.width, height: inContainer.height + 80), in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            drawOutlineMarks(in: characters, origin: origin)
        }
    }

    // MARK: Loading

    func load(markdown: String, family: WriterFont, palette: WriterPalette) {
        self.family = family
        self.palette = palette
        guard let storage = textStorage else { return }
        let text = WriterMarkdown.attributedString(from: markdown)
        trackedRanges = [:]
        untrackedKeys = []
        aiPlacement = nil
        isAIWriting = false
        restyler.isLoading = true
        storage.setAttributedString(text)
        WriterStyler.restyleAll(storage, family: family, palette: palette)
        restyler.isLoading = false
        outlineCache = nil
        lastOutlineSignature = outline.signature
        onOutlineChange?()
        undoManager?.removeAllActions()
        let end = (storage.string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        resetTypingAttributes()
        scroll(.zero)
        if let layout = slideLayout, storage.length == 0 {
            // An empty slide begins with its heading.
            typingAttributes = WriterStyler.typingAttributes(block: layout.firstBlock, level: 0, semantic: [:], family: family, palette: palette)
        }
        updateSlideCentering()
        updateAICursorIndicator()
        onStateChange?()
    }

    func restyleAll() {
        guard let storage = textStorage else { return }
        restyler.isLoading = true
        WriterStyler.restyleAll(storage, family: family, palette: palette)
        restyler.isLoading = false
        outlineCache = nil
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        resetTypingAttributes()
        if let layout = slideLayout, storage.length == 0 {
            typingAttributes = WriterStyler.typingAttributes(block: layout.firstBlock, level: 0, semantic: [:], family: family, palette: palette)
        }
        updateSlideCentering()
        needsDisplay = true
        updateAICursorIndicator()
    }

    var markdown: String {
        WriterMarkdown.markdown(from: textStorage ?? NSAttributedString())
    }

    // MARK: State for the toolbar

    struct State: Equatable {
        var marks: WriterInline = []
        var block: WriterBlock = .paragraph
        var hasLink = false
        var hasSelection = false
        /// The start of the selected text, for the assistant bar.
        var selectionExcerpt = ""
        var selectionLength = 0
        /// A few words before the AI cursor; empty at the start of the document.
        var aiCursorContext = ""
        var isAICursorAtEnd = true
        /// The picture selected on its own.
        var image: ImageState?
        /// The table with the caret.
        var table: TableState?
        /// A formula selected on its own.
        var isFormulaSelected = false
        /// The caret is in a bookmarked passage.
        var bookmarkID: String?

        struct ImageState: Equatable {
            var width: Int?
            var hasCaption: Bool
        }

        struct TableState: Equatable {
            var row: Int
            var column: Int
            var rows: Int
            var columns: Int
            var alignment: MarkdownBlock.Alignment
        }
    }

    var state: State {
        guard let storage = textStorage else { return State() }
        let range = selectedRange()
        var state = State()
        state.hasSelection = range.length > 0
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0 {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
            // A mark counts as on when the whole selection has it.
            var marks = WriterInline(attributes)
            storage.enumerateAttributes(in: range) { runAttributes, _, _ in marks.formIntersection(WriterInline(runAttributes)) }
            state.marks = marks
        } else {
            attributes = typingAttributes
            state.marks = WriterInline(attributes)
        }
        state.hasLink = attributes[.link] != nil
        if hasTextSelection {
            let text = (storage.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            state.selectionExcerpt = text.count > 46 ? String(text.prefix(46)) + "…" : text
            state.selectionLength = text.count
        }
        state.aiCursorContext = aiCursorContext
        state.isAICursorAtEnd = isAICursorAtEnd
        state.block = currentParagraph?.block
            ?? (typingAttributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
        if let embed = selectedEmbed, let storage = textStorage {
            state.block = WriterStyler.block(in: storage, at: embed.location)
        }
        if let image = selectedImage {
            state.block = .image
            state.image = State.ImageState(width: image.reference.width, hasCaption: !image.reference.caption.isEmpty)
        }
        state.isFormulaSelected = selectedFormula != nil
        state.bookmarkID = bookmarkAtCaret?.id
        state.table = tableState
        return state
    }

    var currentParagraph: WriterMarkdown.Paragraph? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = selectedRange().location
        // At the very end after a newline the caret sits in an empty paragraph that has no characters yet.
        if location == storage.length, (storage.string as NSString).character(at: location - 1) == 0x0A { return nil }
        return WriterMarkdown.paragraphs(of: storage, in: NSRange(location: min(location, storage.length - 1), length: 0)).first
    }

    /// Paragraphs the selection touches; empty when the caret sits in the empty last paragraph.
    private func selectedParagraphs() -> [WriterMarkdown.Paragraph] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let range = selectedRange()
        if range.length == 0 { return currentParagraph.map { [$0] } ?? [] }
        return WriterMarkdown.paragraphs(of: storage, in: range)
    }

    func resetTypingAttributes() {
        guard let storage = textStorage else { return }
        let location = selectedRange().location
        let semantic: [NSAttributedString.Key: Any]
        if storage.length == 0 {
            semantic = [:]
        } else if location > 0, (storage.string as NSString).character(at: location - 1) != 0x0A {
            semantic = storage.attributes(at: location - 1, effectiveRange: nil)
        } else if location < storage.length {
            semantic = storage.attributes(at: location, effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }
        } else {
            // The empty end of the document is never part of a table.
            semantic = typingAttributes.filter { $0.key == .writerBlock || $0.key == .writerListLevel }
        }
        var block = (semantic[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
        if block == .rule || block.isEmbed || (block == .table && tableCellAtCaret == nil) { block = .paragraph }
        let level = semantic[.writerListLevel] as? Int ?? 0
        typingAttributes = WriterStyler.typingAttributes(block: block, level: level, semantic: semantic, family: family, palette: palette)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = selectedAttachmentLocation
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Pictures, formulas and the table of contents show whether they are selected; redraw the one that was and the one that is.
        for location in [previous, selectedAttachmentLocation].compactMap({ $0 }) {
            if let frame = attachmentFrame(at: location) { setNeedsDisplay(frame.insetBy(dx: -6, dy: -6)) }
        }
        updateImageControls()
        if !stillSelecting { onStateChange?() }
    }

    // MARK: Inline marks

    func toggle(_ mark: WriterInline) {
        guard let storage = textStorage, let attribute = mark.attribute else { return }
        let range = selectedRange()
        if range.length == 0 {
            var attributes = typingAttributes
            if WriterInline(attributes).contains(mark) {
                attributes.removeValue(forKey: attribute.key)
            } else {
                attributes[attribute.key] = attribute.value
            }
            let block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            typingAttributes = WriterStyler.typingAttributes(block: block, level: attributes[.writerListLevel] as? Int ?? 0, semantic: attributes, family: family, palette: palette)
            onStateChange?()
            return
        }
        var allHave = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !WriterInline(attributes).contains(mark) { allHave = false; stop.pointee = true }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allHave {
            storage.removeAttribute(attribute.key, range: range)
        } else {
            storage.addAttribute(attribute.key, value: attribute.value, range: range)
        }
        storage.endEditing()
        didChangeText()
        onStateChange?()
    }

    // MARK: Blocks

    /// Sets the block of the selected paragraphs. Lists, quotes and code switch back to text when every
    /// selected paragraph already has them.
    func setBlock(_ block: WriterBlock, toggle: Bool = true) {
        guard let storage = textStorage else { return }
        let selected = selectedParagraphs()
        // Lines, pictures, formulas, the table of contents and table cells keep what they are.
        let paragraphs = selected.filter { $0.block != .rule && $0.block != .table && !$0.block.isEmbed }
        if paragraphs.isEmpty, selected.contains(where: { $0.block.isEmbed || $0.block == .table }) || selectedEmbed != nil { return }
        let current = paragraphs.isEmpty ? state.block : nil
        let all = paragraphs.isEmpty ? current == block : paragraphs.allSatisfy { $0.block == block }
        let target: WriterBlock = toggle && all && block != .paragraph ? .paragraph : block

        let range = paragraphs.reduce(into: NSRange?.none) { result, paragraph in
            result = result.map { NSUnionRange($0, paragraph.range) } ?? paragraph.range
        }
        if let range, range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            for paragraph in paragraphs where paragraph.range.length > 0 {
                storage.addAttributes([.writerBlock: target.rawValue, .writerListLevel: target.isList ? paragraph.level : 0], range: paragraph.range)
                if target == .code || target == .raw {
                    for key in [NSAttributedString.Key.writerBold, .writerItalic, .writerCode, .underlineStyle, .strikethroughStyle, .link] {
                        storage.removeAttribute(key, range: paragraph.range)
                    }
                }
            }
            storage.endEditing()
            didChangeText()
        }
        var attributes = typingAttributes
        attributes[.writerBlock] = target.rawValue
        typingAttributes = WriterStyler.typingAttributes(block: target, level: target.isList ? attributes[.writerListLevel] as? Int ?? 0 : 0, semantic: attributes, family: family, palette: palette)
        needsDisplay = true
        onStateChange?()
    }

    /// Moves list items one level in or out.
    func changeListLevel(by step: Int) {
        guard let storage = textStorage else { return }
        let paragraphs = selectedParagraphs().filter { $0.block.isList }
        let range = paragraphs.reduce(paragraphs.first?.range) { result, paragraph in result.map { NSUnionRange($0, paragraph.range) } }
        guard let range, range.length > 0 else {
            // The empty last item lives only in the typing attributes.
            guard state.block.isList else { return }
            let level = max(0, min(5, (typingAttributes[.writerListLevel] as? Int ?? 0) + step))
            typingAttributes = WriterStyler.typingAttributes(block: state.block, level: level, semantic: typingAttributes, family: family, palette: palette)
            needsDisplay = true
            onStateChange?()
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for paragraph in paragraphs where paragraph.range.length > 0 {
            storage.addAttribute(.writerListLevel, value: max(0, min(5, paragraph.level + step)), range: paragraph.range)
        }
        storage.endEditing()
        didChangeText()
        needsDisplay = true
        onStateChange?()
    }

    /// Puts a horizontal line below the current paragraph (or in place of an empty one) and the caret after it.
    func insertRule() {
        let ruleAttributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.rule.rawValue, .writerListLevel: 0]
        let rule = NSMutableAttributedString(attachment: WriterRuleAttachment())
        rule.addAttributes(ruleAttributes, range: NSRange(location: 0, length: rule.length))
        rule.append(NSAttributedString(string: "\n", attributes: ruleAttributes))
        guard let start = insertBlock(rule) else { return }
        setSelectedRange(NSRange(location: min(start + rule.length, textStorage?.length ?? 0), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
    }

    /// Puts whole paragraphs (a line, pictures, a table; ending with their newline) below the current
    /// paragraph, below the table with the caret, or in place of an empty paragraph. Returns where they start.
    @discardableResult
    func insertBlock(_ block: NSAttributedString) -> Int? {
        guard let storage = textStorage else { return nil }
        let string = storage.string as NSString
        var paragraph = currentParagraph
        var paragraphRange = paragraph?.range
        if let current = paragraph, current.cell != nil, let model = tableModel(at: current.range.location) {
            paragraphRange = model.range
        } else if selectedEmbed != nil {
            paragraph = WriterMarkdown.paragraphs(of: storage, in: NSRange(location: selectedRange().location, length: 0)).first
            paragraphRange = paragraph?.range
        }

        let target: NSRange
        let insertion = NSMutableAttributedString()
        let start: Int
        if let paragraph, let range = paragraphRange, paragraph.contentRange.length > 0 || paragraph.cell != nil {
            // Below the paragraph; at the end of the text a new empty paragraph follows.
            let end = NSMaxRange(range)
            target = NSRange(location: end, length: 0)
            if end == NSMaxRange(paragraph.contentRange), end > 0, string.character(at: end - 1) != 0x0A {
                insertion.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: max(0, end - 1), effectiveRange: nil)))
            }
            start = target.location + insertion.length
            insertion.append(block)
        } else if let paragraph {
            // An empty paragraph in the middle is taken by the block; writing goes on in a new empty paragraph.
            target = paragraph.range
            start = target.location
            insertion.append(block)
            insertion.append(NSAttributedString(string: "\n", attributes: [.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0]))
        } else {
            // The empty last paragraph.
            target = NSRange(location: string.length, length: 0)
            start = target.location
            insertion.append(block)
        }
        performStructureEdit(in: target, with: insertion)
        return start
    }

    /// Asks for an address and links the selection (or removes the link).
    func editLink() {
        guard let storage = textStorage else { return }
        var range = selectedRange()
        var current: String?
        if range.length == 0, range.location < storage.length {
            var effective = NSRange()
            if let link = storage.attribute(.link, at: range.location, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length)) {
                current = (link as? URL)?.absoluteString ?? link as? String
                range = effective
            }
        } else if range.length > 0 {
            let link = storage.attribute(.link, at: range.location, effectiveRange: nil)
            current = (link as? URL)?.absoluteString ?? link as? String
        }

        let alert = NSAlert()
        alert.messageText = current == nil ? "Link einfügen" : "Link bearbeiten"
        alert.informativeText = range.length == 0 ? "Die Adresse wird als Text eingefügt." : "Der markierte Text wird verlinkt."
        let field = NSTextField(string: current ?? "https://")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        if current != nil { alert.addButton(withTitle: "Link entfernen") }
        alert.window.initialFirstResponder = field
        let response = alert.runModal()

        if response == .alertThirdButtonReturn, range.length > 0 {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            storage.removeAttribute(.link, range: range)
            didChangeText()
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address != "https://" else { return }
        if range.length == 0 {
            var attributes = typingAttributes
            attributes[.link] = address
            insertText(NSAttributedString(string: address, attributes: attributes), replacementRange: range)
        } else if shouldChangeText(in: range, replacementString: nil) {
            storage.addAttribute(.link, value: address, range: range)
            didChangeText()
        }
        onStateChange?()
    }

    /// Links open with ⌘-click; a plain click puts the caret into the link text for editing.
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard NSEvent.modifierFlags.contains(.command) else { return }
        let address = (link as? URL)?.absoluteString ?? link as? String ?? ""
        if let url = URL(string: address), url.scheme != nil { NSWorkspace.shared.open(url) }
    }

    /// Gives the paragraph at the caret this block if it is empty (a fresh line after Return or a rule).
    /// A paragraph with text is left alone.
    func setBlockOfEmptyCaretParagraph(_ block: WriterBlock) {
        guard let storage = textStorage else { return }
        let location = selectedRange().location
        let string = storage.string as NSString
        if location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard string.substring(with: paragraph).trimmingCharacters(in: .newlines).isEmpty else {
                resetTypingAttributes()
                onStateChange?()
                return
            }
            if shouldChangeText(in: paragraph, replacementString: nil) {
                storage.beginEditing()
                storage.addAttributes([.writerBlock: block.rawValue, .writerListLevel: 0], range: paragraph)
                for key in [NSAttributedString.Key.writerBold, .writerItalic, .writerCode, .underlineStyle, .strikethroughStyle, .link] {
                    storage.removeAttribute(key, range: paragraph)
                }
                storage.endEditing()
                didChangeText()
            }
        }
        typingAttributes = WriterStyler.typingAttributes(block: block, level: 0, semantic: [:], family: family, palette: palette)
        needsDisplay = true
        onStateChange?()
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch flags {
        case [.command]:
            switch key {
            case "b": toggle(.bold); return true
            case "i": toggle(.italic); return true
            case "u": toggle(.underline); return true
            case "e": toggle(.code); return true
            case "k": editLink(); return true
            case "j": onAssistant?(.focusBar); return true
            default: break
            }
        case [.command, .option] where key == "l":
            onReadAloud?()
            return true
        case [.command, .option] where event.keyCode == 14:   // E
            editFormulaAtCaret()
            return true
        case [.command, .option] where event.keyCode == 5:    // G
            generateImageAtCaret()
            return true
        case [.command, .option] where event.keyCode == 11:   // B
            if let bookmark = bookmarkAtCaret, selectedRange().length == 0 { removeBookmark(bookmark.id) } else { addBookmark() }
            return true
        case [.command, .shift]:
            if key == "x" { toggle(.strikethrough); return true }
            switch event.keyCode {
            case 40: showCitationPicker(); return true      // K
            case 26: setBlock(.numbered); return true     // 7
            case 28: setBlock(.bullet); return true       // 8
            case 25: setBlock(.quote); return true        // 9
            default: break
            }
        case [.command, .option]:
            switch event.keyCode {
            case 29: setBlock(.paragraph, toggle: false); return true   // 0
            case 18: setBlock(.heading1, toggle: false); return true    // 1
            case 19: setBlock(.heading2, toggle: false); return true    // 2
            case 20: setBlock(.heading3, toggle: false); return true    // 3
            case 40: setBlock(.chapter, toggle: false); return true     // K
            case 8: setBlock(.code); return true                        // C
            default: break
            }
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        // In a table Return goes to the cell below (shift-return breaks the line inside the cell).
        if tableCellAtCaret != nil {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return insertText(String(WriterMarkdown.lineSeparator), replacementRange: selectedRange())
            }
            return moveToCellBelow()
        }
        // A selected picture, formula or table of contents stays; the new paragraph comes below it.
        if let embed = selectedEmbed { setSelectedRange(NSRange(location: embed.location + 1, length: 0)) }
        guard selectedRange().length == 0 else { return super.insertNewline(sender) }
        guard let paragraph = currentParagraph else {
            // Return in the empty last paragraph moves a list item out, or ends a list, quote or code block.
            if state.block.isList, typingAttributes[.writerListLevel] as? Int ?? 0 > 0 { return changeListLevel(by: -1) }
            if state.block != .paragraph { return setBlock(.paragraph, toggle: false) }
            return super.insertNewline(sender)
        }
        let location = selectedRange().location
        switch paragraph.block {
        case .bullet, .numbered, .quote, .code:
            // Return in an empty item ends the list (or quote, or code block).
            if paragraph.contentRange.length == 0 {
                if paragraph.block.isList, paragraph.level > 0 { return changeListLevel(by: -1) }
                return setBlock(.paragraph, toggle: false)
            }
            super.insertNewline(sender)
        case _ where paragraph.block.isEmbed && location == paragraph.contentRange.location:
            // Return in front of a picture pushes it down.
            insertEmptyParagraph(at: location)
            setSelectedRange(NSRange(location: location + 1, length: 0))
        case .chapter, .heading1, .heading2, .heading3, .rule, .image, .math, .toc:
            // After a heading, a line or a picture, writing goes on in a plain paragraph.
            let isObject = paragraph.block == .rule || paragraph.block.isEmbed
            if isObject || location >= NSMaxRange(paragraph.contentRange) {
                if isObject { setSelectedRange(NSRange(location: NSMaxRange(paragraph.contentRange), length: 0)) }
                undoManager?.beginUndoGrouping()
                super.insertNewline(sender)
                setBlockOfEmptyCaretParagraph(.paragraph)
                undoManager?.endUndoGrouping()
            } else {
                super.insertNewline(sender)
            }
        default:
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if tableCellAtCaret != nil { return moveToAdjacentCell(forward: true) }
        if state.block.isList { return changeListLevel(by: 1) }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if tableCellAtCaret != nil { return moveToAdjacentCell(forward: false) }
        if state.block.isList { return changeListLevel(by: -1) }
        super.insertBacktab(sender)
    }

    /// An empty text paragraph at `location` (the start of a paragraph), as its own undo step.
    private func insertEmptyParagraph(at location: Int) {
        let empty = NSAttributedString(string: "\n", attributes: [.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0])
        performStructureEdit(in: NSRange(location: location, length: 0), with: empty)
    }

    override func deleteForward(_ sender: Any?) {
        if selectedEmbed != nil { return deleteEmbed() }
        // At the end of a cell there is nothing to join.
        if selectedRange().length == 0, let paragraph = currentParagraph, paragraph.block == .table,
           selectedRange().location == NSMaxRange(paragraph.contentRange) { return }
        // At the end of a paragraph in front of a picture, delete selects the picture first.
        if let storage = textStorage, selectedRange().length == 0, let paragraph = currentParagraph,
           paragraph.block != .table, selectedRange().location == NSMaxRange(paragraph.contentRange),
           NSMaxRange(paragraph.range) < storage.length, embed(at: NSMaxRange(paragraph.range)) != nil {
            return selectEmbed(at: NSMaxRange(paragraph.range))
        }
        super.deleteForward(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedEmbed != nil { return deleteEmbed() }
        guard let storage = textStorage, selectedRange().length == 0 else { return super.deleteBackward(sender) }
        let location = selectedRange().location
        if let paragraph = currentParagraph, location == paragraph.contentRange.location {
            // In a table the cells stay apart: at the start of a cell backspace only moves to the previous one.
            if paragraph.block == .table {
                if location > 0 { setSelectedRange(NSRange(location: location - 1, length: 0)) }
                return
            }
            // In front of a picture: an empty paragraph above goes away; text above is never joined with it.
            if paragraph.block.isEmbed {
                guard location > 0 else { return }
                let above = (storage.string as NSString).paragraphRange(for: NSRange(location: location - 1, length: 0))
                if above.length == 1, tableCell(at: above.location) == nil {
                    performStructureEdit(in: above, with: NSAttributedString())
                    setSelectedRange(NSRange(location: above.location, length: 0))
                } else {
                    setSelectedRange(NSRange(location: location - 1, length: 0))
                }
                return
            }
            // At the start of a list item, quote, heading or code block, backspace first takes the formatting away.
            if paragraph.block.isList, paragraph.level > 0 { return changeListLevel(by: -1) }
            let previous = location > 0 ? WriterStyler.block(in: storage, at: location - 1) : nil
            if paragraph.block != .paragraph, paragraph.block != .rule, !(paragraph.block == previous && (paragraph.block == .code || paragraph.block == .quote)) {
                return setBlock(.paragraph, toggle: false)
            }
            // Right after a picture: an empty line goes away, otherwise backspace selects the picture first.
            if previous?.isEmbed == true, location >= 2, embed(at: location - 2) != nil {
                if paragraph.contentRange.length == 0, paragraph.range.length > 0 {
                    performStructureEdit(in: paragraph.range, with: NSAttributedString())
                    setSelectedRange(NSRange(location: location - 1, length: 0))
                    return
                }
                return selectEmbed(at: location - 2)
            }
            // A line above goes away as a whole instead of merging with this paragraph.
            if previous == .rule, location > 0 {
                let rule = (storage.string as NSString).paragraphRange(for: NSRange(location: location - 1, length: 0))
                if shouldChangeText(in: rule, replacementString: "") {
                    storage.replaceCharacters(in: rule, with: "")
                    didChangeText()
                }
                return
            }
        } else if currentParagraph == nil, location >= 2, location == storage.length, embed(at: location - 2) != nil,
                  WriterStyler.block(in: storage, at: location - 1).isEmbed {
            // In the empty end right after a picture.
            return selectEmbed(at: location - 2)
        } else if currentParagraph == nil, location > 0, location == storage.length, state.block != .paragraph {
            // Empty last paragraph with a block that only lives in the typing attributes.
            if state.block.isList, typingAttributes[.writerListLevel] as? Int ?? 0 > 0 { return changeListLevel(by: -1) }
            return setBlock(.paragraph, toggle: false)
        }
        super.deleteBackward(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        var replacementRange = replacementRange
        // Typing on the line of a horizontal rule or a picture starts a new paragraph below it (above a picture
        // when the caret is in front of it); the text then goes to the new caret, whatever range was asked for.
        // (The newline that `insertNewline` itself inserts passes through here and must not start another one.)
        if let paragraph = currentParagraph, paragraph.block == .rule || paragraph.block.isEmbed, selectedRange().length == 0,
           !text.isEmpty, !text.allSatisfy(\.isNewline) {
            defer { replacementRange = selectedRange() }
            if paragraph.block.isEmbed, selectedRange().location == paragraph.contentRange.location {
                insertEmptyParagraph(at: paragraph.range.location)
                setSelectedRange(NSRange(location: paragraph.range.location, length: 0))
            } else {
                setSelectedRange(NSRange(location: NSMaxRange(paragraph.contentRange), length: 0))
                super.insertNewline(nil)
            }
            setBlockOfEmptyCaretParagraph(.paragraph)
        }
        // A selected picture or formula is replaced only by Delete; typing goes below it.
        if let embed = selectedEmbed, !text.isEmpty, !text.allSatisfy(\.isNewline) {
            setSelectedRange(NSRange(location: embed.location + 1, length: 0))
            insertText(string, replacementRange: selectedRange())
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if text == " " { applyMarkdownShortcut() }
    }

    /// "# ", "## ", "- ", "1. " or "> " at the start of a paragraph turn it into a heading, list or quote.
    private func applyMarkdownShortcut() {
        guard let storage = textStorage, let paragraph = currentParagraph, paragraph.block == .paragraph else { return }
        let location = selectedRange().location
        let prefixRange = NSRange(location: paragraph.contentRange.location, length: location - paragraph.contentRange.location)
        guard prefixRange.length >= 2, prefixRange.length <= 5 else { return }
        let prefix = (storage.string as NSString).substring(with: prefixRange)
        if prefix == "$$ " {
            // "$$ " opens the formula editor for a display formula in place of the empty line.
            if shouldChangeText(in: prefixRange, replacementString: "") {
                storage.replaceCharacters(in: prefixRange, with: "")
                didChangeText()
            }
            return newFormula(display: true)
        }
        let block: WriterBlock
        switch prefix {
        case "# ": block = .heading1
        case "## ": block = .heading2
        case "### ": block = .heading3
        case "- ", "* ", "• ", "– ": block = .bullet
        case "> ": block = .quote
        default:
            guard prefix.hasSuffix(". "), prefix.dropLast(2).allSatisfy(\.isNumber), prefix.count > 2 else { return }
            block = .numbered
        }
        undoManager?.beginUndoGrouping()
        if shouldChangeText(in: prefixRange, replacementString: "") {
            storage.replaceCharacters(in: prefixRange, with: "")
            didChangeText()
        }
        setBlock(block, toggle: false)
        undoManager?.endUndoGrouping()
    }

    // MARK: Copy and paste

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.writerMarkdown, .string] }
    /// In this order of preference: own Markdown, picture files, text, picture data (e.g. a screenshot).
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.writerMarkdown, .fileURL, .string, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }

    override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        let allowed = allowedTypes ?? readablePasteboardTypes
        return readablePasteboardTypes.first { availableTypes.contains($0) && allowed.contains($0) }
            ?? super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let selection = storage.attributedSubstring(from: range)
        // Bookmarks stay in the document they were made in.
        let markdown = WriterBookmark.strip(selection.string.contains("\n") || selectedEmbed != nil
            ? WriterMarkdown.markdown(from: selection).trimmingCharacters(in: .newlines)
            : WriterMarkdown.inlineMarkdown(selection))
        let plain = NSMutableString(string: selection.string.replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: "\n"))
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length), options: .reverse) { value, attachmentRange, _ in
            guard value != nil else { return }
            let caption = (value as? WriterImageAttachment)?.reference.caption ?? ""
            let text: String
            switch value {
            case is WriterImageAttachment: text = caption.isEmpty ? "[Bild]" : "[Bild: \(caption)]"
            case let formula as WriterMathAttachment: text = "$" + formula.latex + "$"
            case is WriterTOCAttachment: text = "[Inhaltsverzeichnis]"
            case is WriterBibliographyAttachment: text = "[Literaturverzeichnis]"
            case let citation as WriterCitationAttachment: text = citationStyle.inText(citation.items)
            default: text = "———"
            }
            plain.replaceCharacters(in: attachmentRange, with: text)
        }
        var types: [NSPasteboard.PasteboardType] = [.writerMarkdown, .string]
        // A picture on its own also goes to other apps as a picture.
        let picture = selectedImage.flatMap { WriterImageStore.url(for: $0.reference.source) }.flatMap(NSImage.init(contentsOf:))
        if picture != nil { types.append(.tiff) }
        pboard.declareTypes(types, owner: nil)
        pboard.setString(markdown, forType: .writerMarkdown)
        pboard.setString(plain as String, forType: .string)
        if let data = picture?.tiffRepresentation { pboard.setData(data, forType: .tiff) }
        return true
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .writerMarkdown, let markdown = pboard.string(forType: .writerMarkdown) {
            insertMarkdown(markdown)
            return true
        }
        if type != .string, let sources = ImagePasteboard.sources(on: pboard, preferText: false) {
            insertImages(sources)
            return true
        }
        if let plain = pboard.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange())
            return true
        }
        return false
    }

    /// Inserts Markdown with its formatting. A single paragraph takes the block of the paragraph it lands in;
    /// pictures and tables go in as whole paragraphs; in a table cell everything stays on one line.
    func insertMarkdown(_ markdown: String) {
        let trimmed = markdown.trimmingCharacters(in: .newlines)
        let parsed = WriterMarkdown.attributedString(from: trimmed)
        let blocks = WriterMarkdown.paragraphs(of: parsed).map(\.block)
        let isInline = !parsed.string.contains("\n") && WriterStyler.block(in: parsed, at: 0) == .paragraph
        let insertion: NSAttributedString
        if let cell = tableCellAtCaret, !isInline {
            let flat = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
            let inline = NSMutableAttributedString(attributedString: WriterMarkdown.inline(flat))
            inline.addAttributes(cell.attributes, range: NSRange(location: 0, length: inline.length))
            insertion = inline
        } else if isInline {
            let inline = NSMutableAttributedString(attributedString: WriterMarkdown.inline(trimmed))
            let block = typingAttributes.filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            inline.addAttributes(block, range: NSRange(location: 0, length: inline.length))
            insertion = inline
        } else if blocks.contains(where: \.isEmbed) || blocks.contains(.table) {
            // Whole paragraphs below the current one, ending with a newline like every block.
            let text = NSMutableAttributedString(attributedString: parsed)
            if !text.string.hasSuffix("\n") {
                text.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            }
            if selectedRange().length > 0 { delete(nil) }
            guard let start = insertBlock(text) else { return }
            setSelectedRange(NSRange(location: min(start + text.length, textStorage?.length ?? 0), length: 0))
            resetTypingAttributes()
            return
        } else {
            insertion = parsed
        }
        insertText(insertion, replacementRange: selectedRange())
    }
}

/// Keeps every edited paragraph consistent and styled right after the edit.
final class WriterRestyler: NSObject, NSTextStorageDelegate {
    weak var view: WriterTextView?
    var isLoading = false

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !isLoading, let view else { return }
        if editedMask.contains(.editedCharacters) { view.shiftTrackedRanges(edited: editedRange, delta: delta) }
        WriterStyler.restyle(textStorage, around: editedRange, family: view.family, palette: view.palette)
        view.outlineMayHaveChanged()
        DispatchQueue.main.async { [weak view] in view?.updateImageControls() }
    }
}

/// Draws what the text itself doesn't contain: list bullets and numbers, the bar of a quote and the
/// background of code blocks.
final class WriterLayoutManager: NSLayoutManager {
    weak var writerView: WriterTextView?

    /// A picture selected on its own shows a frame of its own (see `WriterImageCell`) instead of the grey
    /// selection band, which would also cover its caption.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        if charRange.length == 1, let view = writerView, view.selectedRange() == charRange, view.selectedAttachmentLocation == charRange.location { return }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, let view = writerView, storage.length > 0 else { return }
        let palette = view.palette
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let paragraphs = WriterMarkdown.paragraphs(of: storage, in: characters)
        var drawnBlocks = Set<Int>()

        for paragraph in paragraphs where paragraph.range.length > 0 {
            switch paragraph.block {
            case .code, .raw:
                let block = blockRange(around: paragraph, in: storage)
                guard drawnBlocks.insert(block.location).inserted else { continue }
                var rect = usedRect(for: block, in: container)
                guard !rect.isEmpty else { continue }
                rect.origin.x = 0
                rect.size.width = container.size.width
                rect = rect.insetBy(dx: 0, dy: -8).offsetBy(dx: origin.x, dy: origin.y)
                palette.codeBlock.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            case .quote:
                let rect = fragmentRect(for: paragraph.range, in: container)
                guard !rect.isEmpty else { continue }
                palette.quoteBar.setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + rect.minY + 2, width: 3, height: rect.height - 4), xRadius: 1.5, yRadius: 1.5).fill()
            case .bullet, .numbered:
                let glyph = glyphIndexForCharacter(at: paragraph.range.location)
                guard glyph < numberOfGlyphs else { continue }
                let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let position = location(forGlyphAt: glyph)
                let marker = marker(for: paragraph, in: storage)
                // Where the item's text begins: past a free picture on a slide the line starts further right.
                drawMarker(marker, block: paragraph.block, level: paragraph.level, fragment: fragment, baseline: position.y, origin: origin, view: view,
                           textStart: fragment.minX + position.x)
            default:
                break
            }
        }

        // An empty last paragraph that is a list item exists only in the typing attributes.
        let extra = extraLineFragmentRect
        if !extra.isEmpty, let block = (view.typingAttributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)), block.isList {
            let level = view.typingAttributes[.writerListLevel] as? Int ?? 0
            let font = WriterStyler.blockFont(.paragraph, family: view.family)
            let number = block == .numbered ? listNumber(before: storage.length, level: level, in: storage) : 0
            let marker = block == .numbered ? "\(number)." : bullet(for: level)
            let lineHeight = font.ascender - font.descender + font.leading
            let baseline = (extra.height - lineHeight) / 2 + font.ascender
            drawMarker(marker, block: block, level: level, fragment: extra, baseline: baseline, origin: origin, view: view)
        }
    }

    private func drawMarker(_ marker: String, block: WriterBlock, level: Int, fragment: NSRect, baseline: CGFloat, origin: NSPoint, view: WriterTextView,
                            textStart: CGFloat? = nil) {
        let font = WriterStyler.blockFont(.paragraph, family: view.family, bold: block == .numbered)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: view.palette.secondaryText]
        let size = (marker as NSString).size(withAttributes: attributes)
        let indent = WriterStyler.listIndent + CGFloat(level) * WriterStyler.listStep
        let start = max(indent, textStart ?? indent)
        let point = NSPoint(
            x: origin.x + start - size.width - 8,
            y: origin.y + fragment.minY + baseline - font.ascender
        )
        (marker as NSString).draw(at: point, withAttributes: attributes)
    }

    private func bullet(for level: Int) -> String {
        ["•", "◦", "▪︎"][level % 3]
    }

    private func marker(for paragraph: WriterMarkdown.Paragraph, in storage: NSTextStorage) -> String {
        guard paragraph.block == .numbered else { return bullet(for: paragraph.level) }
        return "\(listNumber(before: paragraph.range.location, level: paragraph.level, in: storage))."
    }

    /// The number of a numbered item: one more than the numbered items of the same level right above it.
    private func listNumber(before location: Int, level: Int, in storage: NSTextStorage) -> Int {
        let string = storage.string as NSString
        var number = 1
        var scan = location
        while scan > 0 {
            let previous = string.paragraphRange(for: NSRange(location: scan - 1, length: 0))
            let attributes = storage.attributes(at: previous.location, effectiveRange: nil)
            let block = (attributes[.writerBlock] as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
            let previousLevel = attributes[.writerListLevel] as? Int ?? 0
            guard block.isList, previousLevel >= level else { break }
            if previousLevel == level {
                guard block == .numbered else { break }
                number += 1
            }
            scan = previous.location
        }
        return number
    }

    /// All paragraphs of the code block (or raw Markdown) this paragraph belongs to.
    private func blockRange(around paragraph: WriterMarkdown.Paragraph, in storage: NSTextStorage) -> NSRange {
        let string = storage.string as NSString
        var range = paragraph.range
        while range.location > 0 {
            let previous = string.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            guard WriterStyler.block(in: storage, at: previous.location) == paragraph.block else { break }
            range = NSUnionRange(range, previous)
        }
        while NSMaxRange(range) < string.length {
            let next = string.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            guard WriterStyler.block(in: storage, at: next.location) == paragraph.block else { break }
            range = NSUnionRange(range, next)
        }
        return range
    }

    private func usedRect(for characters: NSRange, in container: NSTextContainer) -> NSRect {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            rect = rect.union(used)
        }
        return rect.isNull ? .zero : rect
    }

    private func fragmentRect(for characters: NSRange, in container: NSTextContainer) -> NSRect {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect.isNull ? .zero : rect
    }
}

/// Draws a horizontal rule across the column.
final class WriterRuleCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { NSSize(width: 200, height: 22) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -6) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -6, width: max(40, lineFrag.width - 4), height: 22)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let color = (controlView as? WriterTextView)?.palette.rule ?? NSColor.separatorColor
        color.setFill()
        NSRect(x: cellFrame.minX + cellFrame.width * 0.1, y: cellFrame.midY - 0.5, width: cellFrame.width * 0.8, height: 1).fill()
    }

    override func wantsToTrackMouse() -> Bool { false }
}
