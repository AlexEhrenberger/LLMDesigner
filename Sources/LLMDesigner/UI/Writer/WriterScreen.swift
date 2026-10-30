import SwiftUI

/// Writer Studio: the chat gives way to a sheet with a word processor's toolbar. Opening it unfolds a
/// glowing frame from where the composer was to the size of the sheet; the toolbar drops in button by button.
struct WriterScreen: View {
    @Environment(AppModel.self) private var app
    @State private var controller = WriterEditorController()
    @State private var assistant = WriterAssistant()
    @State private var unfold: CGFloat = 0
    @State private var showsToolbar = false
    @State private var showsContent = false
    @State private var showsGlow = true
    @State private var analysisScrollTarget: ContentAnalysisModule?

    var body: some View {
        if let document = app.selectedDocument {
            HStack(spacing: 0) {
                main(document)
                // The document's contents and bookmarks; the check results take its place while they are open.
                if app.isPanelDocked, !assistant.isPanelShown, showsToolbar, app.writerTab == .document {
                    DocumentPanel(document: document, controller: controller, assistant: assistant)
                        .frame(width: Theme.outlineWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            // In a narrow window the panel lies over the sheet.
            .overlay {
                FloatingPanel(isShown: app.panelCollapsed && app.panelOverlay && !assistant.isPanelShown && app.writerTab == .document,
                              edge: .trailing, width: Theme.outlineWidth) {
                    DocumentPanel(document: document, controller: controller, assistant: assistant)
                }
            }
            .background(Theme.background)
            .background {
                // ⌃F opens the find bar as well as ⌘F (the menu).
                Button("") { app.findInDocument(.show) }
                    .keyboardShortcut("f", modifiers: .control)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            .onAppear {
                controller.find.isPresentation = false
                app.documentFind = controller.find
                playOpening()
            }
            .onDisappear {
                app.writerFlush = nil
                app.writerDictation = nil
                if app.documentFind === controller.find { app.documentFind = nil }
            }
            // The dynamic table of contents follows the text while it is shown (in the panel or in the document):
            // a moment after the user stopped writing, if enough changed.
            .task(id: followsDynamicOutline(document) ? document.markdown : "") {
                guard followsDynamicOutline(document) else { return }
                try? await Task.sleep(for: .seconds(document.outline == nil ? 1.5 : 6))
                guard !Task.isCancelled, !assistant.isBusy, app.documentOutlineErrors[document.id] == nil,
                      let current = app.document(document.id), DocumentOutlineBuilder.needsRefresh(current) else { return }
                app.refreshDocumentOutline(document.id)
            }
            .sheet(item: Binding(get: { controller.formulaRequest }, set: { if $0 == nil, controller.formulaRequest != nil { controller.cancelFormula() } })) { request in
                FormulaEditorSheet(request: request) { latex, display, plot, python in
                    controller.applyFormula(latex: latex, display: display, plot: plot, isExisting: request.isExisting, python: python)
                } onCancel: {
                    controller.cancelFormula()
                }
            }
            .sheet(item: Binding(get: { app.writerPageSheet }, set: { app.writerPageSheet = $0 })) { sheet in
                switch sheet {
                case .pageSetup: PageSetupSheet(document: document, paper: app.pdfPaperSize).environment(app)
                case .runningHeads: RunningHeadsSheet(document: document).environment(app)
                }
            }
            .sheet(item: Binding(get: { controller.figureRequest }, set: { if $0 == nil, controller.figureRequest != nil { controller.cancelFigure() } })) { request in
                switch request.kind {
                case .chart:
                    ChartEditorSheet(request: request) { images, recipe, caption, table in
                        controller.applyFigure(.chart, images: images, recipe: recipe, caption: caption, width: request.reference?.width ?? 80,
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
                    controller.applyGeneratedImage(info: info, caption: caption, generate: generate, isExisting: request.isExisting)
                } onCancel: {
                    controller.cancelImageGeneration()
                }
                .environment(app)
            }
        }
    }

    private func followsDynamicOutline(_ document: WriterDocument) -> Bool {
        let panelShowsIt = app.isPanelShown && app.documentPanelTab == .contents && document.effectiveTOCMode == .dynamic
        return panelShowsIt || WriterTOCAttachment.kind(in: document.markdown) == true
    }

    private func main(_ document: WriterDocument) -> some View {
            let showsAnalysis = app.writerTab == .analysis
            return VStack(spacing: 0) {
                WriterTopBar(document: document, pageCount: controller.pageCount)
                    .opacity(showsToolbar ? 1 : 0)
                Group {
                    if showsAnalysis {
                        ContentAnalysisToolbar(document: document, scrollTarget: $analysisScrollTarget)
                    } else {
                        WriterToolbar(controller: controller, document: document, isShown: showsToolbar)
                    }
                }
                .transition(.opacity)
                .padding(.bottom, 6)
                HStack(spacing: 0) {
                    ZStack {
                        WriterEditor(
                            app: app,
                            document: document,
                            palette: (app.writerLightPaper ? WriterPalette.light : .dark).with(format: document.pageFormat, setup: document.pageSetup),
                            controller: controller,
                            assistant: assistant,
                            isReadingAloud: app.speakingDocumentID != nil,
                            isDictating: app.dictationIntoDocument
                        )
                        .opacity(showsContent && !showsAnalysis ? 1 : 0)
                        .allowsHitTesting(!showsAnalysis)
                        // The editor stays while the analysis is shown, with its caret, selection and undo.
                        if showsAnalysis {
                            ContentAnalysisView(
                                document: document,
                                colors: .make(lightPaper: app.writerLightPaper),
                                scrollTarget: $analysisScrollTarget
                            ) { anchor in
                                jump(to: anchor, in: document)
                            }
                            .transition(.opacity)
                        }
                        VStack(spacing: 10) {
                            HandoutActivityCard(document: document)
                            WriterAudioStatus(controller: controller)
                            if !showsAnalysis {
                                WriterAssistantDock(assistant: assistant, state: controller.state)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 16)
                        .opacity(showsContent ? 1 : 0)
                        if controller.find.isShown, !showsAnalysis {
                            DocumentFindBar(find: controller.find)
                                .padding(.top, 10)
                                .padding(.trailing, 18)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if showsGlow {
                            UnfoldingFrame(progress: unfold, lightPaper: app.writerLightPaper,
                                           columnWidth: WriterStyler.columnWidth(document.pageFormat, family: document.textFont, setup: document.pageSetup)
                                               ?? WriterTextView.maxColumnWidth)
                                .allowsHitTesting(false)
                        }
                    }
                    if assistant.isPanelShown, !showsAnalysis {
                        WriterCheckPanel(assistant: assistant)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: assistant.isPanelShown)
                .animation(.easeInOut(duration: 0.2), value: showsAnalysis)
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: controller.find.isShown)
            }
            .onChange(of: showsAnalysis) { _, isShown in
                // The hidden editor must not keep the keyboard.
                if isShown { NSApp.keyWindow?.makeFirstResponder(nil) } else { controller.focus() }
            }
    }

    /// From the analysis to the passage it is about: back to the document, then scroll there.
    private func jump(to anchor: DocumentAnchor, in document: WriterDocument) {
        app.showWriterTab(.document)
        let blockCount = MarkdownParser.parse(WriterBookmark.strip(document.markdown)).count
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            controller.jump(to: anchor, blockCount: blockCount)
        }
    }

    private func playOpening() {
        unfold = 0
        withAnimation(.spring(response: 0.62, dampingFraction: 0.84)) { unfold = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            showsToolbar = true
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(.easeOut(duration: 0.45)) { showsContent = true }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.5)) { showsGlow = false }
            controller.focus()
        }
    }
}

/// The opening effect: a frame of light that grows from the composer's place to the sheet.
private struct UnfoldingFrame: View {
    let progress: CGFloat
    let lightPaper: Bool
    /// The sheet's text column (narrower for a paperback or a Normseite).
    let columnWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let start = CGRect(
                x: (size.width - min(size.width - 40, Theme.contentWidth + 16)) / 2,
                y: size.height - 120,
                width: min(size.width - 40, Theme.contentWidth + 16),
                height: 92
            )
            let column = min(columnWidth, max(260, size.width - 120))
            let padding = max(20, min(76, (size.width - column) / 2 - 18))
            let end = CGRect(x: (size.width - column) / 2 - padding, y: 28, width: column + 2 * padding, height: size.height + 20)
            let rect = interpolate(start, end, progress)
            let radius = 22 - 12 * progress

            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill((lightPaper ? Color.white : Color(hex: 0x141417)).opacity(Double(progress)))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [Theme.accent, Color(hex: 0x6FD3FF), Color(hex: 0xFF8FD6), Theme.accent],
                            center: .center,
                            angle: .degrees(Double(progress) * 220)
                        ),
                        lineWidth: 1.6
                    )
                    .shadow(color: Theme.accent.opacity(0.75), radius: 18)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 42)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}

// MARK: Audio

/// A pill at the bottom of the sheet while the document is dictated into or read aloud, and for notices
/// such as Qwen TTS not being reachable.
struct WriterAudioStatus: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController

    var body: some View {
        Group {
            if app.dictationIntoDocument {
                pill {
                    MicrophoneLevel(level: app.dictationLevel, isListening: app.dictationStatus == .listening)
                    Text(dictationText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("„Neuer Absatz“ beginnt einen neuen Absatz")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                    stopButton("Diktat beenden (⌘D)") { controller.toggleDictation() }
                }
            } else if app.speakingDocumentID != nil {
                pill {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: app.speechState == .speaking)
                    Text(app.speechState == .preparing ? "Stimme wird vorbereitet …" : "Liest vor …")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    stopButton("Vorlesen stoppen (esc)") { app.stopReadingDocument() }
                }
            } else if let notice = app.notice {
                pill {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.dictationIntoDocument)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.speakingDocumentID)
        .animation(.easeOut(duration: 0.2), value: app.notice)
    }

    private var dictationText: String {
        switch app.dictationStatus {
        case .preparing(let progress):
            if let progress, progress > 0, progress < 1 { return "Sprachmodell wird geladen … \(Int(progress * 100)) %" }
            return "Mikrofon wird vorbereitet …"
        case .finishing: return "Letzte Worte …"
        default: return "Ich höre zu"
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(Capsule().fill(Theme.elevated))
            .overlay(Capsule().strokeBorder(Theme.strongBorder))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func stopButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Five bars that follow the microphone level.
private struct MicrophoneLevel: View {
    let level: Float
    let isListening: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let weight: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]
                Capsule()
                    .fill(isListening ? Theme.danger : Theme.textTertiary)
                    .frame(width: 3, height: 5 + 13 * CGFloat(min(1, max(0, level))) * weight[index])
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: Top bar

private struct WriterTopBar: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    /// The pages of a paperback or a Normseite, as the editor counts them.
    let pageCount: WriterTextView.PageCount?
    /// In a narrow window the app's name and the word count give way, so the controls keep their room.
    @State private var width: CGFloat = 1200

    var body: some View {
        HStack(spacing: 8) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                IconButton(systemName: "square.and.pencil", help: "Neuer Chat (⌘N)", frameSize: Theme.titleBarControlSize) { app.newChat() }
                    .padding(.trailing, 6)
            }
            Image(systemName: StudioApplication.writer.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            if width >= 960 {
                Text("Writer Studio")
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
            PageFormatMenu(document: document, showsTitle: width >= 900)
            ExportMenu(document: document)
            if width >= 820 {
                Text(counts)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(countsHelp)
            }
            PaperSwitch()
            if !app.isPanelDocked, app.writerTab == .document {
                IconButton(systemName: "sidebar.right", help: "Inhaltsverzeichnis und Lesezeichen einblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            IconButton(systemName: "xmark", help: "Writer Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
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

    /// The words, and the pages of a paperback or a Normseite.
    private var counts: String {
        guard let pages = pageCount?.pages, document.pageFormat.showsPages else { return wordCount }
        let label = document.pageFormat == .manuscript
            ? (pages == 1 ? "1 Normseite" : "\(pages) Normseiten")
            : (pages == 1 ? "1 Seite" : "\(pages) Seiten")
        return label + " · " + wordCount
    }

    /// Publishers also count a Normseite as 1800 characters, spaces included.
    private var countsHelp: String {
        guard document.pageFormat == .manuscript, let characters = pageCount?.characters else { return "" }
        let pages = Double(characters) / Double(WriterPageFormat.manuscriptCharactersPerPage)
        return "Nach Zeilen gezählt: 30 Zeilen à 60 Anschläge je Seite. Nach Anschlägen: \(characters.formatted()) Zeichen mit Leerzeichen, "
            + "das sind \(pages.formatted(.number.precision(.fractionLength(1)))) Normseiten zu 1800 Anschlägen."
    }

    private var wordCount: String {
        // Pictures, formulas, bookmarks and the table of contents don't count; table cells do.
        let text = WriterBookmark.strip(document.markdown).components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return WriterImageReference.parse(line) == nil && !WriterTOCAttachment.isMarker(line)
                    && MarkdownParser.divOpening(trimmed) == nil && !MarkdownParser.isDivClosing(trimmed)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\$\$[\s\S]*?\$\$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\\)\$[^$\n]+\$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {.chapter}", with: "")
        let words = text.split { $0.isWhitespace || $0.isNewline }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        return words == 1 ? "1 Wort" : "\(words) Wörter"
    }
}

/// DIN A4, paperback, Normseite or a format of the user's own: how the document is set on the screen and in print.
/// The menu also opens the page setup and the head and foot lines.
private struct PageFormatMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let showsTitle: Bool
    @State private var hovering = false

    var body: some View {
        let current = document.pageFormat
        Menu {
            Section("Seitenformat") {
                ForEach(WriterPageFormat.builtIn) { format in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { app.setPageFormat(document.id, format) }
                    } label: {
                        Label {
                            Text(title(of: format) + "  ·  " + format.detail)
                        } icon: {
                            Image(systemName: format == current ? "checkmark" : format.symbol)
                        }
                    }
                }
                if let own = document.pageSetup, !app.writerPageTemplates.contains(where: { $0.id == own.id }) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { app.setPageSetup(document.id, own) }
                    } label: {
                        Label(own.name + "  ·  " + own.summary, systemImage: current == .custom ? "checkmark" : WriterPageFormat.custom.symbol)
                    }
                }
            }
            if !app.writerPageTemplates.isEmpty {
                Section("Eigene Formate") {
                    ForEach(app.writerPageTemplates) { template in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { app.setPageSetup(document.id, template) }
                        } label: {
                            Label(template.name + "  ·  " + template.summary,
                                  systemImage: current == .custom && document.pageSetup?.id == template.id ? "checkmark" : "doc.badge.gearshape")
                        }
                    }
                }
            }
            Section {
                Button("Seite einrichten …", systemImage: "slider.horizontal.3") { app.writerPageSheet = .pageSetup }
                Button("Kopf- und Fußzeile …", systemImage: "rectangle.topthird.inset.filled") { app.writerPageSheet = .runningHeads }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.symbol)
                    .font(.system(size: 12, weight: .medium))
                if showsTitle {
                    Text(title(of: current))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: Theme.titleBarControlSize)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Seitenformat: \(title(of: current)) (\(detail(of: current))). Hier auch Seite einrichten und Kopf- und Fußzeile.")
    }

    /// The standard sheet is named by its paper, the user's own format by its name.
    private func title(of format: WriterPageFormat) -> String {
        switch format {
        case .standard: app.pdfPaperSize.label
        case .custom: document.pageSetup?.name ?? format.label
        default: format.label
        }
    }

    private func detail(of format: WriterPageFormat) -> String {
        format == .custom ? (document.customSetup?.summary ?? format.detail) : format.detail
    }
}

/// PDF, LaTeX source or Markdown.
private struct ExportMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var hovering = false

    var body: some View {
        let isExporting = app.exportingIDs.contains(document.id)
        Menu {
            Section("Dokument exportieren") {
                ForEach(WriterExportFormat.allCases) { format in
                    Button(format.title, systemImage: format.symbol) { app.exportDocument(as: format) }
                }
            }
            Section("Drucken") {
                Button("Drucken … (⌘P)", systemImage: "printer") { app.printWriterDocument(document.id) }
            }
            Section("Präsentieren") {
                Button("Präsentation aus diesem Dokument …", systemImage: StudioApplication.presenter.symbol) { app.showDeckFromDocument(document) }
            }
        } label: {
            HStack(spacing: 5) {
                if isExporting {
                    ProgressView().controlSize(.mini)
                    Text("Erstelle PDF …")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: Theme.titleBarControlSize)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(isExporting || document.isEmpty)
        .help("Exportieren als PDF, LaTeX oder Markdown, drucken (⌘P) oder daraus eine Präsentation machen")
    }
}

/// Dark sheet or white paper.
private struct PaperSwitch: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 6) {
            Image(systemName: "moon.fill")
                .font(.system(size: 10))
                .foregroundStyle(app.writerLightPaper ? Theme.textTertiary : Theme.accent)
            Toggle("", isOn: $app.writerLightPaper.animation(.easeInOut(duration: 0.25)))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11))
                .foregroundStyle(app.writerLightPaper ? Theme.warning : Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .help(app.writerLightPaper ? "Dunkles Blatt" : "Helles Blatt")
    }
}

// MARK: Toolbar

private struct WriterToolbar: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    let isShown: Bool

    var body: some View {
        let state = controller.state
        let isText = !(state.block == .code || state.block == .raw || state.block.isEmbed)
        ToolbarFlow {
            HStack(spacing: 2) {
                group(0) { FontMenu(controller: controller, document: document) }
                group(1) { FontSizeMenu(controller: controller, document: document).disabled(!isText) }
            }
            divider(1)
            HStack(spacing: 2) {
                group(2) { BlockMenu(controller: controller, current: state.block) }
                if state.block == .code {
                    group(2) { CodeLanguageMenu(controller: controller, state: state) }
                }
            }
            divider(3)
            HStack(spacing: 2) {
                group(4) { markButton("bold", .bold, "Fett (⌘B)", state) }
                group(5) { markButton("italic", .italic, "Kursiv (⌘I)", state) }
                group(6) { markButton("underline", .underline, "Unterstrichen (⌘U)", state) }
                group(7) { markButton("strikethrough", .strikethrough, "Durchgestrichen (⇧⌘X)", state) }
                group(7) { markButton("textformat.superscript", .superscript, "Hochgestellt (⌃⌘+)", state) }
                group(7) { markButton("textformat.subscript", .subscript, "Tiefgestellt (⌃⌘−)", state) }
                group(8) { markButton("chevron.left.forwardslash.chevron.right", .code, "Code im Text (⌘E)", state) }
                group(9) { ColorMenu(controller: controller).disabled(!isText) }
            }
            divider(9)
            HStack(spacing: 2) {
                group(10) { AlignmentButtons(controller: controller) }
                group(10) { ParagraphFormatButton(controller: controller, state: state) }
                group(10) { ColumnsButton(controller: controller) }
                group(10) { BoxButton(controller: controller) }
            }
            divider(11)
            HStack(spacing: 2) {
                group(12) {
                    ToolbarButton(symbol: "list.bullet", help: "Aufzählung (⇧⌘8)", isActive: state.block == .bullet) { controller.setBlock(.bullet) }
                        .disabled(isStructure(state))
                }
                group(13) {
                    ToolbarButton(symbol: "list.number", help: "Nummerierte Liste (⇧⌘7)", isActive: state.block == .numbered) { controller.setBlock(.numbered) }
                        .disabled(isStructure(state))
                }
                group(14) {
                    ToolbarButton(symbol: "decrease.indent", help: state.block.isList ? "Weniger einrücken (⇧⇥)" : "Einzug verkleinern (⌘[)", isActive: false) {
                        controller.changeIndent(by: -1)
                    }
                    .disabled(!state.block.isList && (state.paragraphFormat?.indent ?? 0) <= 0)
                }
                group(15) {
                    ToolbarButton(symbol: "increase.indent", help: state.block.isList ? "Weiter einrücken (⇥)" : "Einzug vergrößern (⌘]) – um 1,25 cm", isActive: false) {
                        controller.changeIndent(by: 1)
                    }
                    .disabled(!state.block.isList && !state.takesIndent)
                }
                group(16) {
                    ToolbarButton(symbol: "text.quote", help: "Zitat (⇧⌘9)", isActive: state.block == .quote) { controller.setBlock(.quote) }
                        .disabled(isStructure(state))
                }
            }
            divider(17)
            HStack(spacing: 0) {
                group(18) {
                    ToolbarButton(symbol: "link", help: "Link (⌘K)", isActive: state.hasLink) { controller.editLink() }
                }
                group(19) {
                    ToolbarButton(
                        symbol: state.bookmarkID != nil ? "bookmark.fill" : "bookmark",
                        help: state.bookmarkID != nil ? "Lesezeichen entfernen (⌥⌘B)" : "Lesezeichen anlegen (⌥⌘B) – für die Markierung oder den Absatz",
                        isActive: state.bookmarkID != nil
                    ) { controller.toggleBookmark() }
                }
                group(19) {
                    ToolbarButton(
                        symbol: controller.activeCommentID != nil ? "text.bubble.fill" : "text.bubble",
                        help: "Kommentar (⌥⌘M) – zur Markierung, von dir oder der KI; steht am Rand und kommt nicht in den Druck",
                        isActive: controller.activeCommentID != nil
                    ) { controller.addComment() }
                }
                group(20) {
                    ToolbarButton(symbol: "minus", help: "Trennlinie / Abschnittsmarke", isActive: false) { controller.insertRule() }
                }
                group(20) {
                    ToolbarButton(symbol: "arrow.down.doc", help: "Seitenumbruch (⌘↩) – der Text geht auf einer neuen Seite weiter", isActive: false) {
                        controller.insertPageBreak()
                    }
                    .disabled(state.table != nil)
                }
                group(20) {
                    ToolbarButton(symbol: "character.textbox", help: "Sonderzeichen und Symbole (⌃⌘Leertaste) – Pfeile, Griechisch, Mathesymbole, Emoji", isActive: false) {
                        controller.showCharacterPalette()
                    }
                }
            }
            HStack(spacing: 0) {
                group(21) {
                    ToolbarButton(symbol: "photo", help: "Bild einfügen … – Bilder lassen sich auch hineinziehen oder einfügen", isActive: state.image != nil) {
                        controller.chooseImages()
                    }
                }
                group(21) {
                    ToolbarButton(symbol: "wand.and.stars", help: "Bild mit Draw Things generieren (⌥⌘G) – beschreiben, die KI schreibt den Prompt für Qwen Image", isActive: false) {
                        controller.generateImage()
                    }
                }
                group(21) { DiagramMenu(controller: controller, isInTable: state.table != nil, hasSelection: state.hasSelection) }
                group(21) {
                    ToolbarButton(symbol: "pencil.and.scribble", help: "Zeichnung … – Stift, Marker, Pfeile, Formen und Text", isActive: false) {
                        controller.newFigure(.drawing)
                    }
                }
                group(22) { TableButton(controller: controller, isInTable: state.table != nil) }
                group(23) {
                    ToolbarButton(symbol: "x.squareroot", help: "Formel (⌥⌘E) – visueller Formeleditor, auf eigener Zeile auch mit Plot", isActive: state.isFormulaSelected) {
                        controller.editFormula()
                    }
                }
                group(24) { TableOfContentsMenu(controller: controller, isActive: state.block == .toc) }
                group(24) { CitationMenu(controller: controller) }
            }
            divider(25)
            HStack(spacing: 2) {
                group(26) {
                    ToolbarButton(
                        symbol: app.dictationIntoDocument ? "mic.fill" : "mic",
                        help: app.dictationIntoDocument ? "Diktat beenden (⌘D)" : "Ins Dokument diktieren (⌘D) – „neuer Absatz“ beginnt einen neuen Absatz",
                        isActive: app.dictationIntoDocument
                    ) { controller.toggleDictation() }
                    .disabled(!app.isDictationAvailable)
                }
                group(27) {
                    ToolbarButton(
                        symbol: app.speakingDocumentID != nil ? "stop.fill" : "speaker.wave.2",
                        help: app.speakingDocumentID != nil ? "Vorlesen stoppen (esc)" : "Vorlesen (⌥⌘L): die Markierung, sonst ab dem Absatz mit dem Cursor",
                        isActive: app.speakingDocumentID != nil
                    ) { controller.readAloud() }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    /// Each control drops in a moment after the one before it.
    private func group<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : -12)
            .animation(.spring(response: 0.42, dampingFraction: 0.72).delay(Double(index) * 0.028), value: isShown)
    }

    private func divider(_ index: Int) -> some View {
        group(index) { ToolbarDivider() }
            .layoutValue(key: ToolbarFlow.IsDivider.self, value: true)
    }

    private func markButton(_ symbol: String, _ mark: WriterInline, _ help: String, _ state: WriterTextView.State) -> some View {
        ToolbarButton(symbol: symbol, help: help, isActive: state.marks.contains(mark)) { controller.toggle(mark) }
            .disabled(state.block == .code || state.block == .raw || state.block.isEmbed)
    }

    /// Pictures and table cells have no list or quote formatting.
    private func isStructure(_ state: WriterTextView.State) -> Bool {
        state.block.isEmbed || state.block == .table
    }
}

/// Toolbar controls in one row, or in more rows when the window is too narrow for one: nothing is cut off. A divider
/// that would start or end a row is left out; every row is centred.
struct ToolbarFlow: Layout {
    var spacing: CGFloat = 2
    var rowSpacing: CGFloat = 4

    /// Marks a divider between groups of controls (see `ToolbarDivider`).
    struct IsDivider: LayoutValueKey {
        static let defaultValue = false
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat?) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        func trimmed(_ row: Row) -> Row {
            var row = row
            while let last = row.items.last, subviews[last.index][IsDivider.self] {
                row.items.removeLast()
            }
            row.width = row.items.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.items.count - 1))
            row.height = row.items.map(\.size.height).max() ?? 0
            return row
        }
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let isDivider = subviews[index][IsDivider.self]
            if row.items.isEmpty, isDivider { continue }
            let width = row.items.map(\.size.width).reduce(0, +) + spacing * CGFloat(row.items.count) + size.width
            if !row.items.isEmpty, width > limit {
                rows.append(trimmed(row))
                row = Row()
                if isDivider { continue }
            }
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(trimmed(row)) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width)
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(subviews, width: bounds.width)
        var placed = Set<Int>()
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2)
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                placed.insert(item.index)
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
        // Dividers left out take no room (`ToolbarDivider` shrinks to nothing).
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }
}

/// The thin line between groups of toolbar controls; offered no room, it disappears.
struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(maxWidth: 1, maxHeight: 18)
            .padding(.horizontal, 5)
            .frame(minWidth: 0, idealWidth: 11, maxWidth: 11, minHeight: 0, idealHeight: 18, maxHeight: 18)
            .clipped()
    }
}

/// Inserts the table of contents: from the chapters and headings (numbered), or the model's topics.
private struct TableOfContentsMenu: View {
    let controller: WriterEditorController
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Inhaltsverzeichnis einfügen") {
                Button("Aus Kapiteln und Überschriften (nummeriert)", systemImage: "list.number") {
                    controller.insertTableOfContents(dynamic: false)
                }
                Button("Dynamisch – vom Modell gegliedert", systemImage: "sparkles") {
                    controller.insertTableOfContents(dynamic: true)
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isActive ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Inhaltsverzeichnis einfügen – aus den Überschriften (nummeriert wie im Export) oder dynamisch vom Modell")
    }
}

/// Diagrams: a chart of numbers (typed in, or of the table with the caret, which it then follows) and Mermaid diagrams,
/// which the model can write from a description or the selected text.
struct DiagramMenu: View {
    let controller: WriterEditorController
    let isInTable: Bool
    let hasSelection: Bool
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Diagramm aus Zahlen") {
                if isInTable {
                    Button("Aus dieser Tabelle …", systemImage: "tablecells") { controller.chartFromTable() }
                }
                Button("Säulen, Linien, Kreis … ", systemImage: "chart.bar.xaxis") { controller.newFigure(.chart) }
            }
            Section("Mermaid") {
                Button(hasSelection ? "Aus der Markierung mit KI …" : "Mermaid-Diagramm …", systemImage: "point.3.connected.trianglepath.dotted") {
                    controller.newFigure(.mermaid)
                }
            }
        } label: {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Diagramm – aus Zahlen oder einer Tabelle (Säulen, Linien, Kreis …) oder als Mermaid-Diagramm, auch von der KI")
    }
}

/// Citations from Citation Studio: the search at the caret (⌘⇧K), the reference list, the sources panel.
struct CitationMenu: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Quelle zitieren … (⌘⇧K)", systemImage: "quote.bubble") { controller.showCitationPicker() }
            Button("Literaturverzeichnis einfügen", systemImage: "books.vertical") { controller.insertBibliography() }
            Divider()
            Button("Quellen in der Seitenleiste", systemImage: "sidebar.right") {
                app.documentPanelTab = .sources
                if !app.isPanelShown { app.toggleOutlinePanel() }
            }
            Button("Citation Studio öffnen", systemImage: "arrow.up.forward.app") { app.openCitationStudio() }
        } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Zitieren – Quellen und Zitate aus Citation Studio (⌘⇧K), Literaturverzeichnis")
    }
}

/// Inserts a table (a grid to pick its size) or, with the caret in a table, changes it.
struct TableButton: View {
    let controller: WriterEditorController
    let isInTable: Bool
    @State private var showsPopover = false

    var body: some View {
        ToolbarButton(symbol: "tablecells", help: isInTable ? "Tabelle bearbeiten" : "Tabelle einfügen", isActive: isInTable || showsPopover) {
            showsPopover.toggle()
        }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            WriterTablePopover(controller: controller) { showsPopover = false }
        }
    }
}

private struct WriterTablePopover: View {
    let controller: WriterEditorController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let table = controller.state.table {
                Text("Tabelle · \(table.columns) × \(table.rows)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                VStack(spacing: 2) {
                    action("Zeile darüber einfügen", "arrow.up.to.line", .insertRowAbove)
                    action("Zeile darunter einfügen", "arrow.down.to.line", .insertRowBelow)
                    action("Spalte links einfügen", "arrow.left.to.line", .insertColumnLeft)
                    action("Spalte rechts einfügen", "arrow.right.to.line", .insertColumnRight)
                }
                HStack(spacing: 6) {
                    Text("Spalte")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    alignment("text.alignleft", .leading, table.alignment, help: "Linksbündig")
                    alignment("text.aligncenter", .center, table.alignment, help: "Zentriert")
                    alignment("text.alignright", .trailing, table.alignment, help: "Rechtsbündig")
                }
                .padding(.horizontal, 8)
                if table.hasOwnWidths {
                    action("Spalten gleich breit", "rectangle.split.3x1", .equalizeColumns)
                }
                Divider()
                VStack(spacing: 2) {
                    if table.selectedCells > 1 {
                        action("Markierte Zellen verbinden", "rectangle.compress.vertical", .mergeCells)
                    } else {
                        action("Mit Zelle rechts verbinden", "arrow.right.to.line.compact", .mergeRight).disabled(!table.canMergeRight)
                        action("Mit Zelle darunter verbinden", "arrow.down.to.line.compact", .mergeDown).disabled(!table.canMergeDown)
                    }
                    if table.isMerged {
                        action("Verbindung aufheben", "rectangle.split.2x1", .splitCell)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(table.selectedCells > 1 ? "Farbe der markierten Zellen" : "Zellfarbe")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 5) {
                        CellSwatch(color: nil, isCurrent: table.fill == nil) { controller.tableAction(.fill(nil)) }
                            .help("Keine Farbe")
                        ForEach(WriterColors.cellPalette) { entry in
                            CellSwatch(color: entry.printHex, isCurrent: table.fill == entry.printHex) { controller.tableAction(.fill(entry.printHex)) }
                                .help(entry.name)
                        }
                    }
                }
                .padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Linien im Druck")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Picker("", selection: Binding(get: { table.lineWidth }, set: { controller.tableAction(.lineWidth($0)) })) {
                            ForEach(WriterTableStyle.lineWidths, id: \.label) { option in Text(option.label).tag(option.value) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(table.lines == .none)
                    }
                    HStack(spacing: 3) {
                        ForEach(WriterTableLines.allCases) { lines in
                            ToolbarButton(symbol: lines.symbol, help: "\(lines.label) – \(lines.detail)", isActive: table.lines == lines) {
                                controller.tableAction(.lines(lines))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                Divider()
                VStack(spacing: 2) {
                    action("Zeile löschen", "minus.square", .deleteRow)
                    action("Spalte löschen", "minus.rectangle.portrait", .deleteColumn)
                    action("Tabelle löschen", "trash", .deleteTable, destructive: true)
                }
                Text("⇥ nächste Zelle · ↩ Zelle darunter · ⇧↩ neue Zeile in der Zelle · die Linie zwischen zwei Spalten ziehen ändert ihre Breite · über mehrere Zellen markieren, dann verbinden")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TableSizePicker { rows, columns in
                    controller.insertTable(rows: rows, columns: columns)
                    close()
                }
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private func action(_ title: String, _ symbol: String, _ action: WriterTableAction, destructive: Bool = false) -> some View {
        PopoverRow(title: title, symbol: symbol, destructive: destructive) {
            controller.tableAction(action)
            if action == .deleteTable { close() }
        }
    }

    private func alignment(_ symbol: String, _ value: MarkdownBlock.Alignment, _ current: MarkdownBlock.Alignment, help: String) -> some View {
        ToolbarButton(symbol: symbol, help: help, isActive: value == current) { controller.tableAction(.align(value)) }
    }
}

/// A cell colour to choose; nil is none.
private struct CellSwatch: View {
    let color: String?
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.flatMap { WriterColors.cellFill($0, onDark: false) }.map { Color(nsColor: $0) } ?? Color.clear)
                .overlay {
                    if color == nil {
                        Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isCurrent ? Theme.accent : Theme.border, lineWidth: isCurrent ? 2 : 1))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct PopoverRow: View {
    let title: String
    let symbol: String
    let destructive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Theme.danger : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

/// A grid like in word processors: move over it to choose columns and rows (the first row is the header).
private struct TableSizePicker: View {
    let onPick: (_ rows: Int, _ columns: Int) -> Void
    @State private var rows = 3
    @State private var columns = 3
    private let maxRows = 8
    private let maxColumns = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tabelle einfügen")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 3) {
                ForEach(0..<maxRows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<maxColumns, id: \.self) { column in
                            let isOn = row < rows && column < columns
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isOn ? Theme.accent.opacity(row == 0 ? 0.95 : 0.6) : Color.white.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(isOn ? 0 : 0.08)))
                                .frame(width: 24, height: 18)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    guard inside else { return }
                                    rows = row + 1
                                    columns = column + 1
                                }
                                .onTapGesture { onPick(row + 1, column + 1) }
                        }
                    }
                }
            }
            Text("\(columns) \(columns == 1 ? "Spalte" : "Spalten") × \(rows) \(rows == 1 ? "Zeile" : "Zeilen") (erste Zeile = Kopf)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

struct ToolbarButton: View {
    let symbol: String
    let help: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        if !isEnabled { return Theme.textTertiary.opacity(0.5) }
        if isActive { return Theme.accent }
        return hovering ? Theme.textPrimary : Theme.textSecondary
    }

    private var background: Color {
        if isActive { return Theme.accent.opacity(0.16) }
        return hovering && isEnabled ? Theme.hover : .clear
    }
}

struct BlockMenu: View {
    let controller: WriterEditorController
    let current: WriterBlock
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach([WriterBlock.paragraph, .chapter, .heading1, .heading2, .heading3, .code], id: \.self) { block in
                Button { controller.setBlock(block, toggle: false) } label: {
                    let title = "\(block.label)\(shortcut(block))"
                    if block == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            MenuLabel(symbol: "paragraphsign", title: current.isList || current == .quote || current == .rule ? "Text" : current.label, hovering: hovering)
                .frame(minWidth: 122, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(current.isEmbed || current == .table)
        .help("Absatzformat")
    }

    private func shortcut(_ block: WriterBlock) -> String {
        switch block {
        case .paragraph: "  ⌥⌘0"
        case .chapter: "  ⌥⌘K"
        case .heading1: "  ⌥⌘1"
        case .heading2: "  ⌥⌘2"
        case .heading3: "  ⌥⌘3"
        case .code: "  ⌥⌘C"
        default: ""
        }
    }
}

struct MenuLabel: View {
    let symbol: String
    let title: String
    let hovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
    }
}
