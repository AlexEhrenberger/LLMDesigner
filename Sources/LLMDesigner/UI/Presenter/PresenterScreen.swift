import SwiftUI

/// Presenter Studio: like Writer Studio, but the text is set on slides. On the left the slides, in the middle the
/// open slide with Writer Studio's editor on its background, below it the assistant bar and the speaker notes, on the
/// right the contents, bookmarks and sources. The tab "Abspielen" plays the presentation, "Inhaltsanalyse" analyses it.
struct PresenterScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = WriterEditorController()
    @State private var assistant = WriterAssistant()
    @State private var analysisScrollTarget: ContentAnalysisModule?
    /// The free pictures while one is dragged (see `SlideImageEditor`).
    @State private var dragImages: [SlideImage]?
    /// The slide's text area while it is dragged.
    @State private var dragTextFrame: CGRect?
    /// The free picture the Draw Things sheet is open for.
    @State private var regeneratingImage: (slideID: PresentationSlide.ID, imageID: SlideImage.ID)?

    var body: some View {
        if let document = app.selectedPresentation, let deck = document.deck,
           let slideID = app.currentSlideID(in: document), let slide = deck.slide(slideID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PresenterTopBar(document: document)
                    switch app.writerTab {
                    // Presentations have no code view (their tabs don't offer it).
                    case .document, .code:
                        editor(document, deck: deck, slide: slide)
                    case .play:
                        PresentationPlayView(document: document)
                            .transition(.opacity)
                    case .analysis:
                        analysis(document, deck: deck)
                            .transition(.opacity)
                    }
                }
                // While the panel slides in or out the slide would be scaled again in every frame (editor
                // magnification, background, pictures, shadow), which stutters; it takes its new size at once instead.
                .transaction(value: app.power.isOn) { $0.animation = nil }
                .transaction(value: app.isPanelDocked) { $0.animation = nil }
                .transaction(value: app.rightPanelWidth) { $0.animation = nil }
                if app.isPanelDocked, app.writerTab == .document, !assistant.isPanelShown {
                    Group {
                        if app.power.isOn {
                            PowerPanel()
                        } else if app.documentPanelTab == .notes {
                            DocumentNotesPanel(document: document)
                        } else {
                            PresenterPanel(document: document, deck: deck, currentSlideID: slide.id, controller: controller)
                        }
                    }
                    .frame(width: app.rightPanelWidth)
                    .transition(.move(edge: .trailing))
                }
            }
            // In a narrow window the panel lies over the slide.
            .overlay {
                FloatingPanel(isShown: app.panelCollapsed && app.panelOverlay && app.writerTab == .document && !assistant.isPanelShown,
                              edge: .trailing, width: app.rightPanelWidth) {
                    if app.power.isOn {
                        PowerPanel()
                    } else if app.documentPanelTab == .notes {
                        DocumentNotesPanel(document: document)
                    } else {
                        PresenterPanel(document: document, deck: deck, currentSlideID: slide.id, controller: controller)
                    }
                }
            }
            .background(Theme.canvas)
            .onAppear {
                app.presentationPlayer.app = app
                controller.find.isPresentation = true
                app.documentFind = controller.find
                SlideDesignLibrary.shared.reloadIfNeeded()
                // "Erstelle eine Präsentation über …", "Schreib Moderatorenkarten" in the bar act on the whole presentation.
                assistant.isPresentation = true
                assistant.onPresentationIntent = { [weak app] intent, instruction in
                    guard let app, let presentation = app.selectedPresentation else { return }
                    var text = instruction
                    if intent.kind == .createDeck, text.isEmpty {
                        text = "Eine Präsentation zum Thema „\(presentation.displayTitle)“"
                    }
                    app.runPresenterIntent(intent, instruction: text, in: presentation.id)
                }
            }
            .onDisappear {
                app.writerFlush = nil
                app.writerDictation = nil
                if app.documentFind === controller.find { app.documentFind = nil }
            }
            .onChange(of: app.writerTab) { _, tab in
                if tab != .document { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            // The find bar follows slides and cards changed elsewhere (the model, moving slides, typing on the card).
            .onChange(of: deck) { _, _ in controller.find.deckChanged() }
            .sheet(item: Binding(get: { controller.formulaRequest }, set: { if $0 == nil, controller.formulaRequest != nil { controller.cancelFormula() } })) { request in
                FormulaEditorSheet(request: request) { latex, display, plot, python in
                    controller.applyFormula(latex: latex, display: display, plot: plot, isExisting: request.isExisting, python: python)
                } onCancel: {
                    controller.cancelFormula()
                }
            }
            .sheet(item: Binding(get: { controller.figureRequest }, set: { if $0 == nil, controller.figureRequest != nil { controller.cancelFigure() } })) { request in
                switch request.kind {
                case .chart:
                    ChartEditorSheet(request: request) { images, recipe, caption, table in
                        controller.applyFigure(.chart, images: images, recipe: recipe, caption: caption, width: request.reference?.width ?? 100,
                                               linkedTable: table, isExisting: request.isExisting)
                    } onCancel: {
                        controller.cancelFigure()
                    }
                case .mermaid:
                    MermaidEditorSheet(request: request) { images, code, caption, width in
                        controller.applyFigure(.mermaid, images: images, recipe: Data(code.utf8), caption: caption, width: width, isExisting: request.isExisting)
                    } onCancel: {
                        controller.cancelFigure()
                    }
                    .environment(app)
                case .drawing:
                    DrawingEditorSheet(request: request) { images, recipe, caption, width in
                        controller.applyFigure(.drawing, images: images, recipe: recipe, caption: caption, width: width, isExisting: request.isExisting)
                    } onCancel: {
                        controller.cancelFigure()
                    }
                }
            }
            .sheet(item: Binding(get: { controller.imageRequest }, set: { if $0 == nil, controller.imageRequest != nil { controller.cancelImageGeneration() } })) { request in
                ImageGeneratorSheet(request: request) { info, caption, generate in
                    if let target = regeneratingImage {
                        regeneratingImage = nil
                        controller.imageRequest = nil
                        app.updateGeneratedSlideImage(document.id, target.slideID, target.imageID, info: info, caption: caption, generate: generate,
                                                      undoManager: controller.textView?.undoManager)
                    } else {
                        controller.applyGeneratedImage(info: info, caption: caption, generate: generate, isExisting: request.isExisting)
                    }
                } onCancel: {
                    regeneratingImage = nil
                    controller.cancelImageGeneration()
                }
                .environment(app)
            }
        }
    }

    // MARK: Editing

    private func editor(_ document: WriterDocument, deck: PresentationDeck, slide: PresentationSlide) -> some View {
        VStack(spacing: 0) {
            PresenterToolbar(controller: controller, document: document, deck: deck, slide: slide)
                .padding(.bottom, 8)
            HStack(spacing: 0) {
                SlideStrip(document: document, deck: deck, currentSlideID: slide.id, find: controller.find)
                    .frame(width: 188)
                VStack(spacing: 10) {
                    if controller.find.isShown {
                        DocumentFindBar(find: controller.find)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let bar = controller.tableBar {
                        WriterTableBarHost(bar: bar)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                    }
                    canvas(document, deck: deck, slide: slide)
                    DeckActivityCard(document: document)
                    WriterAudioStatus(controller: controller)
                    WriterAssistantDock(assistant: assistant, state: controller.state)
                    if app.presenterNotesVisible {
                        SpeakerNotesCard(document: document, deck: deck, slide: slide, find: controller.find)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
                if assistant.isPanelShown {
                    WriterCheckPanel(assistant: assistant)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: assistant.isPanelShown)
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: app.presenterNotesVisible)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: controller.find.isShown)
        }
        .overlay(alignment: .bottomLeading) {
            if let deleted = app.deletedSlide, deleted.documentID == document.id {
                DeletedSlideToast()
                    .padding(.leading, 14)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.deletedSlide)
        .background {
            // New slide and turning slides from the keyboard, also while the text has the focus.
            Group {
                Button("") { app.addSlide(to: document.id, after: slide.id, undoManager: MainWindow.window?.undoManager) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("") { step(by: 1, in: deck, from: slide.id) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("") { step(by: -1, in: deck, from: slide.id) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                // ⌃F opens the find bar as well as ⌘F (the menu).
                Button("") { app.findInDocument(.show) }
                    .keyboardShortcut("f", modifiers: .control)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func step(by offset: Int, in deck: PresentationDeck, from slideID: PresentationSlide.ID) {
        guard let index = deck.index(of: slideID), deck.slides.indices.contains(index + offset) else { return }
        app.selectSlide(deck.slides[index + offset].id)
    }

    /// The slide with its background; the editor is magnified to the space there is.
    private func canvas(_ document: WriterDocument, deck: PresentationDeck, slide: PresentationSlide) -> some View {
        let background = deck.background(of: slide)
        let palette = SlideLook.palette(background, role: slide.role)
        let fieldLook = SlideLook.fieldLook(of: slide, in: deck, family: document.textFont)
        let images = dragImages ?? slide.images
        let textLayout = WriterTextView.SlideLayout(slide: slide, images: images, textFrame: dragTextFrame)
        // A text field open for writing: the editor moves into it, the slide's own text is drawn as it is.
        let field = app.editingSlideFieldID.flatMap { id in images.first { $0.id == id && $0.isText } }
        let editorFrame = field?.frame ?? CGRect(origin: .zero, size: SlideImage.canvas)
        let content = field.map { WriterSlideContent(id: $0.id, markdown: $0.text ?? "", layout: WriterTextView.SlideLayout(field: $0), slideID: slide.id) }
            ?? WriterSlideContent(id: slide.id, markdown: slide.markdown, layout: textLayout)
        return ZStack {
            SlideBackgroundView(background: background, role: slide.role)
            SlideMasterLayer(deck: deck, slide: slide, title: document.displayTitle)
            SlideImagesLayer(images: images, placements: [.behind], hiding: field?.id)
            if field != nil {
                SlideTextView(markdown: slide.markdown, family: document.textFont, palette: palette, layout: textLayout, citations: app.citations)
                // A click beside the field goes back to the slide's text.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        app.endSlideFieldEditing()
                        controller.focus()
                    }
            }
            GeometryReader { geometry in
                let scale = geometry.size.width / SlideImage.canvas.width
                ZStack(alignment: .topLeading) {
                    if let field {
                        SlideBoxBackground(field: field)
                            .frame(width: editorFrame.width * scale, height: editorFrame.height * scale)
                            .offset(x: editorFrame.minX * scale, y: editorFrame.minY * scale)
                            .allowsHitTesting(false)
                    }
                    WriterEditor(
                        app: app,
                        document: document,
                        palette: field == nil ? palette : fieldLook.palette,
                        controller: controller,
                        assistant: assistant,
                        isReadingAloud: app.speakingDocumentID != nil,
                        isDictating: app.dictationIntoDocument,
                        slide: content
                    )
                    .frame(width: max(1, editorFrame.width * scale), height: max(1, editorFrame.height * scale))
                    .offset(x: editorFrame.minX * scale, y: editorFrame.minY * scale)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            // The field being written in lies over the other things on the slide.
            .zIndex(field == nil ? 0 : 2)
            SlideImageEditor(document: document, slide: slide, controller: controller, dragImages: $dragImages, dragTextFrame: $dragTextFrame) { image in
                regenerate(image, on: slide, in: document)
            }
            .zIndex(1)
        }
        .environment(\.slideTextLook, fieldLook)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
        .shadow(color: Theme.shade.opacity(0.5), radius: 24, y: 10)
        .overlay(alignment: .bottomTrailing) {
            if controller.slideOverflows {
                Label("Der Text ist länger als die Folie", systemImage: "arrow.down.to.line.compact")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(10)
                    .help("Kürze den Text, verteile ihn auf zwei Folien oder lass ihn mit „Umformulieren → kürzer“ straffen.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// Opens the Draw Things sheet for a free picture.
    private func regenerate(_ image: SlideImage, on slide: PresentationSlide, in document: WriterDocument) {
        app.selectedSlideImageID = image.id
        regeneratingImage = (slide.id, image.id)
        var info = WriterImageStore.generationInfo(for: image.source) ?? app.imageGeneration.defaults
        info.seed = nil
        controller.imageRequest = WriterImageGenerationRequest(
            info: info, caption: image.caption, isExisting: true, source: image.source,
            documentTitle: document.displayTitle, context: PresenterPrompts.plainText(of: slide)
        )
    }

    // MARK: Analysis

    private func analysis(_ document: WriterDocument, deck: PresentationDeck) -> some View {
        VStack(spacing: 0) {
            ContentAnalysisToolbar(document: document, scrollTarget: $analysisScrollTarget)
                .padding(.bottom, 6)
            ContentAnalysisView(
                document: document,
                colors: .make(lightPaper: app.writerUsesLightPaper(colorScheme)),
                scrollTarget: $analysisScrollTarget
            ) { anchor in
                jump(to: anchor, in: deck)
            }
        }
    }

    /// From the analysis to the slide with the passage.
    private func jump(to anchor: DocumentAnchor, in deck: PresentationDeck) {
        guard let found = deck.slideIndex(for: anchor) else { return }
        let slide = deck.slides[found.slide]
        app.selectSlide(slide.id)
        app.showWriterTab(.document)
        let blockCount = MarkdownParser.parse(WriterBookmark.strip(slide.markdown)).count
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            controller.jump(to: DocumentAnchor(block: found.block, key: anchor.key), blockCount: blockCount)
        }
    }
}
