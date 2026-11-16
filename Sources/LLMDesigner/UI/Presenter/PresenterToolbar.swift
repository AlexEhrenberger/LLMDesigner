import SwiftUI

// Presenter Studio's top bar and its toolbar above the slide (see PresenterScreen).

// MARK: Top bar

struct PresenterTopBar: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    /// In a narrow window the app's name and the slide count give way, so the controls keep their room.
    @State private var width: CGFloat = 1200

    var body: some View {
        HStack(spacing: 8) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                NewItemMenu()
                    .padding(.trailing, 6)
            }
            Image(systemName: StudioApplication.presenter.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            if width >= 1000 {
                Text("Presenter Studio")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
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
            if width >= 860 {
                Text(slideCount)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            PresentButton(document: document)
                .fixedSize()
            if app.writerTab == .document {
                ProjectMembershipButton(ref: .document(document.id), label: "diese Präsentation")
                PodcastFromButton(reference: .document(document.id), help: "Podcast über diese Präsentation erzeugen")
                DocumentNotesButton(document: document)
                PowerButton()
            }
            if !app.isPanelDocked, app.writerTab == .document {
                IconButton(systemName: "sidebar.right", help: "Inhalt, Lesezeichen und Quellen einblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            IconButton(systemName: "xmark", help: "Presenter Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.3)) { app.closeDocument() }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, Theme.topBarBottomPadding)
        .background(WindowDragArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var slideCount: String {
        let count = document.deck?.slides.count ?? 0
        return count == 1 ? "1 Folie" : "\(count) Folien"
    }
}

/// Starts the presentation in full screen from the open slide; the arrow next to it lets the model present.
struct PresentButton: View {
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
                .foregroundStyle(Theme.background.opacity(0.9))
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
                    .foregroundStyle(Theme.background.opacity(0.85))
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
        app.flushEdits()
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
struct PresenterToolbar: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide

    var body: some View {
        let state = controller.state
        let isText = !(state.block == .code || state.block == .raw || state.block.isEmbed)
        ToolbarFlow {
            HStack(spacing: 2) {
                NewSlideButton(document: document, slideID: slide.id)
            }
            divider
            HStack(spacing: 2) {
                RoleMenu(document: document, slide: slide)
                BackgroundButton(document: document, deck: deck, slide: slide)
            }
            divider
            HStack(spacing: 2) {
                FontMenu(controller: controller, document: document)
                FontSizeMenu(controller: controller, document: document).disabled(!isText)
            }
            HStack(spacing: 2) {
                BlockMenu(controller: controller, current: state.block)
                if state.block == .code { CodeLanguageMenu(controller: controller, state: state) }
            }
            divider
            HStack(spacing: 2) {
                markButton("bold", .bold, "Fett (⌘B)", state)
                markButton("italic", .italic, "Kursiv (⌘I)", state)
                markButton("underline", .underline, "Unterstrichen (⌘U)", state)
                markButton("strikethrough", .strikethrough, "Durchgestrichen (⇧⌘X)", state)
                markButton("textformat.superscript", .superscript, "Hochgestellt (⌃⌘+)", state)
                markButton("textformat.subscript", .subscript, "Tiefgestellt (⌃⌘−)", state)
                markButton("chevron.left.forwardslash.chevron.right", .code, "Code im Text (⌘E)", state)
                ColorMenu(controller: controller).disabled(!isText)
            }
            divider
            AlignmentButtons(controller: controller)
            divider
            HStack(spacing: 2) {
                ToolbarButton(symbol: "list.bullet", help: "Aufzählung (⇧⌘8)", isActive: state.block == .bullet) { controller.setBlock(.bullet) }
                    .disabled(state.block.isEmbed || state.block == .table)
                ToolbarButton(symbol: "list.number", help: "Nummerierte Liste (⇧⌘7)", isActive: state.block == .numbered) { controller.setBlock(.numbered) }
                    .disabled(state.block.isEmbed || state.block == .table)
                ToolbarButton(symbol: "text.quote", help: "Zitat (⇧⌘9)", isActive: state.block == .quote) { controller.setBlock(.quote) }
                    .disabled(state.block.isEmbed || state.block == .table)
            }
            divider
            HStack(spacing: 2) {
                ToolbarButton(
                    symbol: state.bookmarkID != nil ? "bookmark.fill" : "bookmark",
                    help: state.bookmarkID != nil ? "Lesezeichen entfernen (⌥⌘B)" : "Lesezeichen anlegen (⌥⌘B)",
                    isActive: state.bookmarkID != nil
                ) { controller.toggleBookmark() }
                ToolbarButton(symbol: "photo", help: "Bild einfügen …", isActive: state.image != nil) { controller.chooseImages() }
                ToolbarButton(symbol: "wand.and.stars", help: "Bild mit Draw Things generieren (⌥⌘G)", isActive: false) { controller.generateImage() }
            }
            HStack(spacing: 2) {
                ToolbarButton(symbol: "face.smiling", help: "Sonderzeichen und Symbole (⌃⌘Leertaste) – Pfeile, Griechisch, Mathesymbole, Emoji", isActive: false) {
                    controller.showCharacterPalette()
                }
            }
            HStack(spacing: 2) {
                TableButton(controller: controller, isInTable: state.table != nil)
                DiagramMenu(controller: controller, isInTable: state.table != nil, hasSelection: state.hasSelection)
                ToolbarButton(symbol: "pencil.and.scribble", help: "Zeichnung … – Stift, Marker, Pfeile, Formen und Text", isActive: false) {
                    controller.newFigure(.drawing)
                }
                ToolbarButton(symbol: "x.squareroot", help: "Formel (⌥⌘E)", isActive: state.isFormulaSelected) { controller.editFormula() }
                CitationMenu(controller: controller)
            }
            divider
            ToolbarButton(symbol: "character.textbox", help: "Textbox – frei auf der Folie, mit der Maus verschieben und in der Größe ändern (⌥⌘T)", isActive: false) {
                app.addTextBoxToOpenSlide()
            }
            FreeElementMenu(controller: controller, document: document, slide: slide, hasSelection: state.hasSelection)
            divider
            HStack(spacing: 2) {
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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        ToolbarDivider()
            .layoutValue(key: ToolbarFlow.IsDivider.self, value: true)
    }

    private func markButton(_ symbol: String, _ mark: WriterInline, _ help: String, _ state: WriterTextView.State) -> some View {
        ToolbarButton(symbol: symbol, help: help, isActive: state.marks.contains(mark)) { controller.toggle(mark) }
            .disabled(state.block == .code || state.block == .raw || state.block.isEmbed)
    }
}

/// Things placed freely on the slide: text fields, boxes, tables, code, figures in a field of their own; the selection
/// taken out of the slide's text into a field; the slide's own text area moved.
struct FreeElementMenu: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    let slide: PresentationSlide
    let hasSelection: Bool
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Frei auf der Folie") {
                Button("Textfeld", systemImage: "character.textbox") { add("", actionName: "Textfeld") }
                Menu("Kasten") {
                    ForEach(WriterBoxKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) {
                            add("**\(kind.label)**\n\n", box: kind, size: CGSize(width: 280, height: 110), actionName: "Kasten")
                        }
                    }
                }
                Button("Tabelle", systemImage: "tablecells") {
                    add(Self.table, size: CGSize(width: 360, height: 130), actionName: "Tabelle")
                }
                Button("Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                    add("```swift\n\n```", size: CGSize(width: 340, height: 130), actionName: "Code")
                }
                Button("Zeichnung …", systemImage: "pencil.and.scribble") { addFigure(.drawing) }
                Button("Diagramm …", systemImage: "chart.bar.xaxis") { addFigure(.chart) }
                Button("Mermaid-Diagramm …", systemImage: "point.3.connected.trianglepath.dotted") { addFigure(.mermaid) }
            }
            Divider()
            Button("Markierung als Textfeld herauslösen", systemImage: "rectangle.portrait.and.arrow.right") { detachSelection() }
                .disabled(!hasSelection)
            Divider()
            Button(app.editingSlideTextArea ? "Textbereich fertig" : "Textbereich der Folie verschieben …", systemImage: "character.textbox.badge.sparkles") {
                app.editingSlideFieldID = nil
                app.selectedSlideImageID = nil
                app.editingSlideTextArea.toggle()
            }
            Button("Textbereich zurücksetzen", systemImage: "arrow.uturn.backward") {
                app.setSlideTextArea(document.id, slide.id, nil, undoManager: undoManager)
            }
            .disabled(slide.textArea == nil)
        } label: {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering || app.editingSlideTextArea ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Frei platzieren – Textfeld, Kasten, Tabelle, Code oder Abbildung als eigenes Element, das sich auf der Folie verschieben lässt")
    }

    private static let table = "| Spalte 1 | Spalte 2 | Spalte 3 |\n|---|---|---|\n|  |  |  |\n|  |  |  |"

    private var undoManager: UndoManager? {
        controller.textView?.undoManager ?? NSApp.keyWindow?.undoManager
    }

    private var offset: Int {
        slide.images.filter(\.isText).count % 5
    }

    private func add(_ text: String, box: WriterBoxKind? = nil, size: CGSize = CGSize(width: 300, height: 90), actionName: String) {
        let field = SlideImage(text: text, box: box, frame: SlideImage.defaultTextFrame(width: size.width, height: size.height, offset: offset))
        app.addSlideField(document.id, slide.id, field, undoManager: undoManager, actionName: actionName)
    }

    /// A field of its own for the figure, whose editor opens once the field is in the editor.
    private func addFigure(_ kind: WriterFigureKind) {
        add("", size: CGSize(width: 380, height: 230), actionName: kind.label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.newFigure(kind) }
    }

    /// The selected passage leaves the slide's text and becomes a text field of its own.
    private func detachSelection() {
        guard let textView = controller.textView, let markdown = textView.selectedMarkdown() else { return }
        let range = textView.selectedRange()
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        if textView.shouldChangeText(in: range, replacementString: "") {
            textView.replaceCharacters(in: range, with: "")
            textView.didChangeText()
        }
        app.flushEdits()
        let lines = markdown.components(separatedBy: "\n").count
        let height = min(300, max(60, CGFloat(lines) * 26 + 20))
        let field = SlideImage(text: markdown, frame: SlideImage.defaultTextFrame(width: 320, height: height, offset: offset))
        app.addSlideField(document.id, slide.id, field, undoManager: undoManager, actionName: "Als Textfeld herauslösen")
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Als Textfeld herauslösen")
    }
}

/// "Ein Knopf legt eine Folie an": a new slide after the open one; the arrow next to it offers the other kinds.
struct NewSlideButton: View {
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
                Button("Leere Folie", systemImage: "rectangle") { app.addSlide(to: document.id, after: slideID, blank: true, undoManager: MainWindow.window?.undoManager) }
                Button("Neue Kapitelfolie", systemImage: SlideRole.chapter.symbol) { add(.chapter) }
                Button("Neue Titelfolie", systemImage: SlideRole.title.symbol) { add(.title) }
                Divider()
                Button("Agenda-Folie aus den Kapiteln", systemImage: "list.bullet.rectangle") {
                    app.insertAgendaSlide(document.id, after: slideID, undoManager: MainWindow.window?.undoManager)
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
        app.addSlide(to: document.id, after: slideID, role: role, undoManager: MainWindow.window?.undoManager)
    }
}

/// Title, chapter or content slide.
struct RoleMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let slide: PresentationSlide
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Art der Folie") {
                ForEach(SlideRole.allCases) { role in
                    Button { app.setSlideRole(document.id, slide.id, role, undoManager: MainWindow.window?.undoManager) } label: {
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
struct BackgroundButton: View {
    @Environment(AppModel.self) private var app
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
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ink.opacity(0.25)))
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
        .onAppear { showsPopover = app.presenterBackgroundPickerOpen }
        .onChange(of: app.presenterBackgroundPickerOpen) { _, open in showsPopover = open }
        .onChange(of: showsPopover) { _, open in app.presenterBackgroundPickerOpen = open }
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
