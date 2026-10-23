import SwiftUI

/// Presenter Studio: like Writer Studio, but the text is set on slides. On the left the slides, in the middle the
/// open slide with Writer Studio's editor on its background, below it the assistant bar and the speaker notes, on the
/// right the contents, bookmarks and sources. The tab "Abspielen" plays the presentation, "Inhaltsanalyse" analyses it.
struct PresenterScreen: View {
    @Environment(AppModel.self) private var app
    @State private var controller = WriterEditorController()
    @State private var assistant = WriterAssistant()
    @State private var analysisScrollTarget: ContentAnalysisModule?
    @State private var appeared = false
    /// The free pictures while one is dragged (see `SlideImageEditor`).
    @State private var dragImages: [SlideImage]?
    /// The free picture the Draw Things sheet is open for.
    @State private var regeneratingImage: (slideID: PresentationSlide.ID, imageID: SlideImage.ID)?

    var body: some View {
        if let document = app.selectedPresentation, let deck = document.deck,
           let slideID = app.currentSlideID(in: document), let slide = deck.slide(slideID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PresenterTopBar(document: document)
                    switch app.writerTab {
                    case .document:
                        editor(document, deck: deck, slide: slide)
                    case .play:
                        PresentationPlayView(document: document)
                            .transition(.opacity)
                    case .analysis:
                        analysis(document, deck: deck)
                            .transition(.opacity)
                    }
                }
                if app.outlinePanelVisible, app.writerTab == .document, !assistant.isPanelShown {
                    PresenterPanel(document: document, deck: deck, currentSlideID: slide.id, controller: controller)
                        .frame(width: Theme.outlineWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Theme.background)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.985)
            .onAppear {
                app.presentationPlayer.app = app
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
                withAnimation(.easeOut(duration: 0.35)) { appeared = true }
            }
            .onDisappear {
                app.writerFlush = nil
                app.writerDictation = nil
            }
            .onChange(of: app.writerTab) { _, tab in
                if tab != .document { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .sheet(item: Binding(get: { controller.formulaRequest }, set: { if $0 == nil, controller.formulaRequest != nil { controller.cancelFormula() } })) { request in
                FormulaEditorSheet(request: request) { latex, display, plot, python in
                    controller.applyFormula(latex: latex, display: display, plot: plot, isExisting: request.isExisting, python: python)
                } onCancel: {
                    controller.cancelFormula()
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
                SlideStrip(document: document, deck: deck, currentSlideID: slide.id)
                    .frame(width: 188)
                VStack(spacing: 10) {
                    canvas(document, deck: deck, slide: slide)
                    DeckActivityCard(document: document)
                    WriterAudioStatus(controller: controller)
                    WriterAssistantDock(assistant: assistant, state: controller.state)
                    if app.presenterNotesVisible {
                        SpeakerNotesCard(document: document, deck: deck, slide: slide)
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
                Button("") { app.addSlide(to: document.id, after: slide.id) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("") { step(by: 1, in: deck, from: slide.id) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("") { step(by: -1, in: deck, from: slide.id) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
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
        let images = dragImages ?? slide.images
        return ZStack {
            SlideBackgroundView(background: background, role: slide.role)
            SlideImagesLayer(images: images, placements: [.behind])
            WriterEditor(
                app: app,
                document: document,
                palette: palette,
                controller: controller,
                assistant: assistant,
                isReadingAloud: app.speakingDocumentID != nil,
                isDictating: app.dictationIntoDocument,
                slide: WriterSlideContent(id: slide.id, markdown: slide.markdown, layout: WriterTextView.SlideLayout(slide: slide, images: images))
            )
            SlideImageEditor(document: document, slide: slide, controller: controller, dragImages: $dragImages) { image in
                regenerate(image, on: slide, in: document)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
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
                colors: .make(lightPaper: app.writerLightPaper),
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

// MARK: Top bar

private struct PresenterTopBar: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        HStack(spacing: 8) {
            if !app.sidebarVisible {
                SidebarToggleButton()
                IconButton(systemName: "square.and.pencil", help: "Neuer Chat (⌘N)", frameSize: Theme.titleBarControlSize) { app.newChat() }
                    .padding(.trailing, 6)
            }
            Image(systemName: StudioApplication.presenter.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Presenter Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(document.displayTitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            WriterTabSwitch(document: document)
                .padding(.leading, 10)
                .layoutPriority(1)
            Spacer(minLength: 12)
            PresenterExportMenu(document: document)
            Text(slideCount)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            PresentButton(document: document)
            if !app.outlinePanelVisible, app.writerTab == .document {
                IconButton(systemName: "sidebar.right", help: "Inhalt, Lesezeichen und Quellen einblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            IconButton(systemName: "xmark", help: "Presenter Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.3)) { app.closeDocument() }
            }
        }
        .padding(.leading, app.sidebarVisible ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, Theme.topBarBottomPadding)
        .background(WindowDragArea())
    }

    private var slideCount: String {
        let count = document.deck?.slides.count ?? 0
        return count == 1 ? "1 Folie" : "\(count) Folien"
    }
}

/// Starts the presentation in full screen from the open slide; the arrow next to it lets the model present.
private struct PresentButton: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var hovering = false
    @State private var hoveringMenu = false

    var body: some View {
        HStack(spacing: 1) {
            Button { start(fromStart: false, presenting: false) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Vorführen")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.leading, 11)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous).fill(hovering ? Theme.accent.opacity(0.85) : Theme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help("Ab dieser Folie im Vollbild vorführen (⌥⌘P) – auf einem zweiten Bildschirm, wenn es einen gibt")
            Menu {
                Button("Ab dieser Folie vorführen", systemImage: "play.fill") { start(fromStart: false, presenting: false) }
                Button("Von Anfang an vorführen", systemImage: "backward.end.fill") { start(fromStart: true, presenting: false) }
                Divider()
                Button("KI präsentiert – ab dieser Folie", systemImage: "person.wave.2.fill") { start(fromStart: false, presenting: true) }
                Button("KI präsentiert – von Anfang an", systemImage: "person.wave.2") { start(fromStart: true, presenting: true) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 20, height: 24)
                    .background(UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous).fill(hoveringMenu ? Theme.accent.opacity(0.85) : Theme.accent))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hoveringMenu = $0 }
            .help("Von Anfang an vorführen oder die KI präsentieren lassen: Sie liest die Moderatorenkarten vor und schaltet weiter")
        }
        .background {
            Button("") { start(fromStart: false, presenting: false) }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func start(fromStart: Bool, presenting: Bool) {
        app.writerFlush?()
        let player = app.presentationPlayer
        player.app = app
        player.prepare(document.id, at: fromStart ? document.deck?.slides.first?.id : app.currentSlideID(in: document))
        if fromStart { player.go(to: 0) }
        player.enterFullScreen()
        if presenting { player.present() }
    }
}

// MARK: Toolbar

/// Writer Studio's formatting, plus what slides need: a new slide, the kind of slide, its background.
private struct PresenterToolbar: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide

    var body: some View {
        let state = controller.state
        HStack(spacing: 2) {
            NewSlideButton(document: document, slideID: slide.id)
            divider
            RoleMenu(document: document, slide: slide)
            BackgroundButton(document: document, deck: deck, slide: slide)
            divider
            FontMenu(controller: controller, document: document)
            BlockMenu(controller: controller, current: state.block)
            if state.block == .code { CodeLanguageMenu(controller: controller, state: state) }
            divider
            markButton("bold", .bold, "Fett (⌘B)", state)
            markButton("italic", .italic, "Kursiv (⌘I)", state)
            markButton("underline", .underline, "Unterstrichen (⌘U)", state)
            markButton("strikethrough", .strikethrough, "Durchgestrichen (⇧⌘X)", state)
            ColorMenu(controller: controller).disabled(state.block == .code || state.block == .raw || state.block.isEmbed)
            divider
            ToolbarButton(symbol: "list.bullet", help: "Aufzählung (⇧⌘8)", isActive: state.block == .bullet) { controller.setBlock(.bullet) }
                .disabled(state.block.isEmbed || state.block == .table)
            ToolbarButton(symbol: "list.number", help: "Nummerierte Liste (⇧⌘7)", isActive: state.block == .numbered) { controller.setBlock(.numbered) }
                .disabled(state.block.isEmbed || state.block == .table)
            ToolbarButton(symbol: "text.quote", help: "Zitat (⇧⌘9)", isActive: state.block == .quote) { controller.setBlock(.quote) }
                .disabled(state.block.isEmbed || state.block == .table)
            divider
            ToolbarButton(
                symbol: state.bookmarkID != nil ? "bookmark.fill" : "bookmark",
                help: state.bookmarkID != nil ? "Lesezeichen entfernen (⌥⌘B)" : "Lesezeichen anlegen (⌥⌘B)",
                isActive: state.bookmarkID != nil
            ) { controller.toggleBookmark() }
            ToolbarButton(symbol: "photo", help: "Bild einfügen …", isActive: state.image != nil) { controller.chooseImages() }
            ToolbarButton(symbol: "wand.and.stars", help: "Bild mit Draw Things generieren (⌥⌘G)", isActive: false) { controller.generateImage() }
            TableButton(controller: controller, isInTable: state.table != nil)
            ToolbarButton(symbol: "x.squareroot", help: "Formel (⌥⌘E)", isActive: state.isFormulaSelected) { controller.editFormula() }
            CitationMenu(controller: controller)
            divider
            ToolbarButton(
                symbol: app.dictationIntoDocument ? "mic.fill" : "mic",
                help: app.dictationIntoDocument ? "Diktat beenden (⌘D)" : "Auf die Folie diktieren (⌘D)",
                isActive: app.dictationIntoDocument
            ) { controller.toggleDictation() }
            .disabled(!app.isDictationAvailable)
            ToolbarButton(
                symbol: app.speakingDocumentID != nil ? "stop.fill" : "speaker.wave.2",
                help: app.speakingDocumentID != nil ? "Vorlesen stoppen (esc)" : "Folie vorlesen (⌥⌘L)",
                isActive: app.speakingDocumentID != nil
            ) { controller.readAloud() }
            ToolbarButton(
                symbol: app.presenterNotesVisible ? "text.bubble.fill" : "text.bubble",
                help: app.presenterNotesVisible ? "Moderatorenkarte ausblenden" : "Moderatorenkarte einblenden",
                isActive: app.presenterNotesVisible
            ) { app.presenterNotesVisible.toggle() }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 5)
    }

    private func markButton(_ symbol: String, _ mark: WriterInline, _ help: String, _ state: WriterTextView.State) -> some View {
        ToolbarButton(symbol: symbol, help: help, isActive: state.marks.contains(mark)) { controller.toggle(mark) }
            .disabled(state.block == .code || state.block == .raw || state.block.isEmbed)
    }
}

/// "Ein Knopf legt eine Folie an": a new slide after the open one; the arrow next to it offers the other kinds.
private struct NewSlideButton: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let slideID: PresentationSlide.ID
    @State private var hovering = false
    @State private var hoveringMenu = false

    var body: some View {
        HStack(spacing: 1) {
            Button { add(.content) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Folie")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.leading, 9)
                .padding(.trailing, 7)
                .frame(height: 28)
                .background(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7, style: .continuous).fill(Theme.accent.opacity(hovering ? 0.24 : 0.15)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help("Neue Folie nach dieser (⇧⌘↩)")
            Menu {
                Button("Neue Folie (⇧⌘↩)", systemImage: SlideRole.content.symbol) { add(.content) }
                Button("Neue Kapitelfolie", systemImage: SlideRole.chapter.symbol) { add(.chapter) }
                Button("Neue Titelfolie", systemImage: SlideRole.title.symbol) { add(.title) }
                Divider()
                Button("Agenda-Folie aus den Kapiteln", systemImage: "list.bullet.rectangle") {
                    app.insertAgendaSlide(document.id, after: slideID)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 28)
                    .background(UnevenRoundedRectangle(bottomTrailingRadius: 7, topTrailingRadius: 7, style: .continuous).fill(Theme.accent.opacity(hoveringMenu ? 0.24 : 0.15)))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hoveringMenu = $0 }
            .help("Kapitel-, Titel- oder Agenda-Folie anlegen")
        }
    }

    private func add(_ role: SlideRole) {
        app.addSlide(to: document.id, after: slideID, role: role)
    }
}

/// Title, chapter or content slide.
private struct RoleMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let slide: PresentationSlide
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Art der Folie") {
                ForEach(SlideRole.allCases) { role in
                    Button { app.setSlideRole(document.id, slide.id, role) } label: {
                        if role == slide.role { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                    }
                }
            }
        } label: {
            MenuLabel(symbol: slide.role.symbol, title: slide.role.label, hovering: hovering)
                .frame(minWidth: 118, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Art der Folie: Titel und Kapitel stehen in der Mitte, Inhalt beginnt oben. Jede Art hat ihren eigenen Hintergrund.")
    }
}

/// Opens the background menu.
private struct BackgroundButton: View {
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide
    @State private var showsPopover = false
    @State private var showsGenerator = false
    @State private var hovering = false

    var body: some View {
        Button { showsPopover.toggle() } label: {
            HStack(spacing: 6) {
                SlideBackgroundView(background: deck.background(of: slide), role: slide.role)
                    .frame(width: 26, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
                Text("Hintergrund")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(hovering || showsPopover ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(showsPopover ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Hintergrund: Designs, Farbe, Verlauf oder ein Bild von Draw Things – für diese Folie, eine Art von Folien oder alle")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            SlideBackgroundPicker(documentID: document.id, slideID: slide.id) {
                showsPopover = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showsGenerator = true
                }
            }
        }
        .sheet(isPresented: $showsGenerator) {
            SlideBackgroundGeneratorSheet(documentID: document.id, slideID: slide.id)
        }
    }
}

// MARK: Slide list

/// What is dragged when slides are put in another order.
struct SlideDrag: Codable, Transferable {
    let slideID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct SlideStrip: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let currentSlideID: PresentationSlide.ID
    @State private var dropTarget: Int?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                            SlideStripRow(
                                document: document, deck: deck, slide: slide, number: index + 1,
                                isSelected: slide.id == currentSlideID, showsDropMark: dropTarget == index
                            )
                            .id(slide.id)
                            .draggable(SlideDrag(slideID: slide.id)) {
                                SlideThumbnail(slide: slide, deck: deck, family: document.font)
                                    .frame(width: 140)
                                    .environment(app)
                            }
                            .dropDestination(for: SlideDrag.self) { items, _ in
                                guard let item = items.first else { return false }
                                app.moveSlide(document.id, item.slideID, to: index)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = index } else if dropTarget == index { dropTarget = nil }
                            }
                        }
                        // Dropped below the last slide: to the end.
                        Color.clear
                            .frame(height: 30)
                            .overlay(alignment: .top) {
                                if dropTarget == deck.slides.count {
                                    Capsule().fill(Theme.accent).frame(height: 3).padding(.horizontal, 12)
                                }
                            }
                            .dropDestination(for: SlideDrag.self) { items, _ in
                                guard let item = items.first else { return false }
                                app.moveSlide(document.id, item.slideID, to: deck.slides.count)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = deck.slides.count } else if dropTarget == deck.slides.count { dropTarget = nil }
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: currentSlideID) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            Button {
                app.addSlide(to: document.id, after: currentSlideID)
            } label: {
                Label("Neue Folie", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Neue Folie nach der geöffneten (⇧⌘↩)")
        }
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
}

private struct SlideStripRow: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide
    let number: Int
    let isSelected: Bool
    let showsDropMark: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                if slide.role != .content {
                    Image(systemName: slide.role.symbol)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                        .help(slide.role.label)
                }
                if !slide.notes.isEmpty || app.notesWriting.contains(slide.id) {
                    Image(systemName: app.notesWriting.contains(slide.id) ? "ellipsis.bubble" : "text.bubble")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .symbolEffect(.pulse, isActive: app.notesWriting.contains(slide.id))
                        .help(app.notesWriting.contains(slide.id) ? "Die KI schreibt die Moderatorenkarte …" : "Hat eine Moderatorenkarte")
                }
            }
            .frame(width: 18)
            .padding(.top, 2)
            SlideThumbnail(slide: slide, deck: deck, family: document.font)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(hovering ? 0.25 : 0.1), lineWidth: isSelected ? 2 : 1)
                        .padding(isSelected ? -2 : 0)
                )
        }
        .padding(.vertical, 4)
        .padding(.leading, slide.role == .content && deck.chapter(of: slide.id) != nil ? 4 : 0)
        .overlay(alignment: .top) {
            if showsDropMark {
                Capsule().fill(Theme.accent).frame(height: 3).offset(y: -3).padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectSlide(slide.id) }
        .onHover { hovering = $0 }
        .help(slide.title.isEmpty ? "Folie \(number)" : slide.title)
        .contextMenu {
            Button("Neue Folie danach", systemImage: "plus") { app.addSlide(to: document.id, after: slide.id) }
            Button("Duplizieren", systemImage: "plus.square.on.square") { app.duplicateSlide(document.id, slide.id) }
            Menu("Art der Folie") {
                ForEach(SlideRole.allCases) { role in
                    Button { app.setSlideRole(document.id, slide.id, role) } label: {
                        if role == slide.role { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                    }
                }
            }
            Button("Moderatorenkarte schreiben lassen", systemImage: "sparkles") { app.writeSpeakerNotes(document.id, slides: [slide.id]) }
            if slide.background != nil {
                Button("Hintergrund der Präsentation verwenden", systemImage: "arrow.uturn.backward") { app.setSlideBackground(document.id, slide.id, nil) }
            }
            Divider()
            Button("Folie löschen", systemImage: "trash", role: .destructive) { app.deleteSlide(document.id, slide.id) }
                .disabled(deck.slides.count <= 1)
        }
    }
}

/// What the model does with the whole presentation: making it from the bar's instruction (with "Rückgängig"
/// afterwards), or writing the speaker notes of many slides.
private struct DeckActivityCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        let generation = app.deckGeneration?.documentID == document.id ? app.deckGeneration : nil
        let slides = document.deck?.slides ?? []
        let writingNotes = slides.filter { app.notesWriting.contains($0.id) }.count
        if generation != nil || writingNotes > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if let generation { row(for: generation, slides: slides, writingNotes: writingNotes) }
                if writingNotes > 1 || (writingNotes > 0 && generation != nil) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Die KI schreibt Moderatorenkarten – noch \(writingNotes) von \(slides.count) Folien")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        SmallActionButton(title: "Abbrechen", symbol: "stop.fill") { app.cancelSpeakerNotes() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(generation?.isRunning == true ? 0.45 : 0.2)))
            .frame(maxWidth: 760)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func row(for generation: DeckGeneration, slides: [PresentationSlide], writingNotes: Int) -> some View {
        HStack(spacing: 10) {
            switch generation.phase {
            case .outlining:
                ProgressView().controlSize(.small)
                text("Die KI entwirft die Gliederung …", "Danach erscheinen die Folien und werden eine nach der anderen gefüllt.")
                Spacer(minLength: 8)
                SmallActionButton(title: "Stopp", symbol: "stop.fill") { app.stopDeckGeneration() }
            case .filling(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                text("Die KI füllt die Folien – \(min(done + 1, total)) von \(total)", "Du kannst schon durch die Folien gehen; Fertiges bleibt stehen.")
                Spacer(minLength: 8)
                SmallActionButton(title: "Stopp", symbol: "stop.fill") { app.stopDeckGeneration() }
            case .finished, .stopped:
                Image(systemName: generation.phase == .finished ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(generation.phase == .finished ? Theme.success : Theme.warning)
                text(
                    (generation.phase == .finished ? "Präsentation erstellt: " : "Angehalten: ") + count(generation.created.count),
                    generation.replacedEmpty ? "Alles lässt sich wie gewohnt bearbeiten." : "Die neuen Folien stehen am Ende."
                )
                Spacer(minLength: 8)
                let missingNotes = slides.filter { generation.created.contains($0.id) && $0.notes.isEmpty }.map(\.id)
                if !missingNotes.isEmpty, writingNotes == 0 {
                    SmallActionButton(title: "Moderatorenkarten schreiben", symbol: "text.bubble") {
                        app.writeSpeakerNotes(document.id, slides: missingNotes)
                    }
                }
                SmallActionButton(title: "Rückgängig", symbol: "arrow.uturn.backward") { app.undoDeckGeneration() }
                IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.deckGeneration = nil }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.warning)
                text("Die Präsentation ließ sich nicht erstellen", message)
                Spacer(minLength: 8)
                if !generation.created.isEmpty {
                    SmallActionButton(title: "Rückgängig", symbol: "arrow.uturn.backward") { app.undoDeckGeneration() }
                }
                IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.deckGeneration = nil }
            }
        }
    }

    private func text(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
    }

    private func count(_ number: Int) -> String {
        number == 1 ? "1 Folie" : "\(number) Folien"
    }
}

/// "Folie gelöscht – Wiederherstellen" for a few seconds.
private struct DeletedSlideToast: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text("Folie gelöscht")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Button("Wiederherstellen") { app.restoreDeletedSlide() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(Theme.strongBorder))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
    }
}

// MARK: Speaker notes

/// The "Moderatorenkarte" below the slide: what the presenter (or the AI) says to it.
private struct SpeakerNotesCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide

    var body: some View {
        let isWriting = app.notesWriting.contains(slide.id)
        let player = app.presentationPlayer
        let isReading = player.phase == .speaking && player.currentSlide?.id == slide.id && player.documentID == document.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Moderatorenkarte")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(wordCount)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                if isWriting {
                    ProgressView().controlSize(.mini)
                    Text("Die KI schreibt …")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                } else if let error = app.notesErrors[slide.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .help(error)
                }
                SmallActionButton(title: slide.notes.isEmpty ? "Schreiben lassen" : "Neu schreiben", symbol: "sparkles") {
                    app.writeSpeakerNotes(document.id, slides: [slide.id])
                }
                .disabled(isWriting)
                .help("Die KI schreibt, was zu dieser Folie gesagt wird – passend zu den Folien davor und danach")
                Menu {
                    Button("Fehlende Karten aller Folien schreiben lassen", systemImage: "sparkles") {
                        app.writeSpeakerNotes(document.id, slides: deck.slides.filter { $0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
                    }
                    Button("Alle Karten neu schreiben lassen", systemImage: "arrow.clockwise") {
                        app.writeSpeakerNotes(document.id, slides: deck.slides.map(\.id))
                    }
                    if !app.notesWriting.isEmpty {
                        Divider()
                        Button("Schreiben abbrechen", systemImage: "stop") { app.cancelSpeakerNotes() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Moderatorenkarten für alle Folien")
                IconButton(systemName: isReading ? "stop.fill" : "speaker.wave.2", help: isReading ? "Vorlesen stoppen" : "Moderatorenkarte vorlesen", size: 12.5, frameSize: 24) {
                    player.app = app
                    player.prepare(document.id, at: slide.id)
                    player.readCurrentNotes()
                }
                .disabled(slide.notes.isEmpty)
                IconButton(systemName: "chevron.down", help: "Moderatorenkarte ausblenden", size: 11, frameSize: 24) {
                    app.presenterNotesVisible = false
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { slide.notes }, set: { app.setSlideNotes(document.id, slide.id, $0) }))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .disabled(isWriting)
                if slide.notes.isEmpty, !isWriting {
                    Text("Was zu dieser Folie gesagt wird … Schreib es selbst oder lass es die KI schreiben. Beim Vorführen liest die KI diese Karte vor.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 92)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: 900)
    }

    private var wordCount: String {
        let words = slide.notes.split { $0.isWhitespace || $0.isNewline }.count
        guard words > 0 else { return "" }
        // About 130 spoken words a minute.
        let seconds = max(5, Int((Double(words) / 130 * 60).rounded()))
        return "\(words) Wörter · ca. \(seconds < 60 ? "\(seconds) s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60)) min")"
    }
}

/// A small labelled button for the cards.
struct SmallActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isEnabled ? (hovering ? Theme.textPrimary : Theme.textSecondary) : Theme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Theme.hover : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
