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

    var body: some View {
        if let document = app.selectedDocument {
            VStack(spacing: 0) {
                WriterTopBar(document: document)
                    .opacity(showsToolbar ? 1 : 0)
                WriterToolbar(controller: controller, document: document, isShown: showsToolbar)
                    .padding(.bottom, 6)
                HStack(spacing: 0) {
                    ZStack {
                        WriterEditor(
                            app: app,
                            document: document,
                            palette: app.writerLightPaper ? .light : .dark,
                            controller: controller,
                            assistant: assistant,
                            isReadingAloud: app.speakingDocumentID != nil,
                            isDictating: app.dictationIntoDocument
                        )
                        .opacity(showsContent ? 1 : 0)
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 10) {
                                WriterAudioStatus(controller: controller)
                                WriterAssistantDock(assistant: assistant, state: controller.state)
                            }
                            .padding(.bottom, 16)
                            .opacity(showsContent ? 1 : 0)
                        }
                        if showsGlow {
                            UnfoldingFrame(progress: unfold, lightPaper: app.writerLightPaper)
                                .allowsHitTesting(false)
                        }
                    }
                    if assistant.isPanelShown {
                        WriterCheckPanel(assistant: assistant)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: assistant.isPanelShown)
            }
            .background(Theme.background)
            .onAppear(perform: playOpening)
            .onDisappear {
                app.writerFlush = nil
                app.writerDictation = nil
            }
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

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let start = CGRect(
                x: (size.width - min(size.width - 40, Theme.contentWidth + 16)) / 2,
                y: size.height - 120,
                width: min(size.width - 40, Theme.contentWidth + 16),
                height: 92
            )
            let column = min(WriterTextView.maxColumnWidth, max(260, size.width - 120))
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
private struct WriterAudioStatus: View {
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

    var body: some View {
        HStack(spacing: 8) {
            if !app.sidebarVisible {
                SidebarToggleButton()
                IconButton(systemName: "square.and.pencil", help: "Neuer Chat (⌘N)", frameSize: Theme.titleBarControlSize) { app.newChat() }
                    .padding(.trailing, 6)
            }
            Image(systemName: StudioApplication.writer.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Writer Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(document.displayTitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            // The assistant writes with this model.
            ModelPickerButton()
            ExportMenu(document: document)
            Text(wordCount)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            PaperSwitch()
            IconButton(systemName: "xmark", help: "Writer Studio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.3)) { app.closeDocument() }
            }
        }
        .padding(.leading, app.sidebarVisible ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, Theme.topBarBottomPadding)
        .background(WindowDragArea())
    }

    private var wordCount: String {
        let words = document.markdown.split { $0.isWhitespace || $0.isNewline }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        return words == 1 ? "1 Wort" : "\(words) Wörter"
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
        .help("Exportieren als PDF, LaTeX oder Markdown")
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
        HStack(spacing: 2) {
            group(0) { FontMenu(document: document) }
            divider(1)
            group(2) { BlockMenu(controller: controller, current: state.block) }
            divider(3)
            group(4) { markButton("bold", .bold, "Fett (⌘B)", state) }
            group(5) { markButton("italic", .italic, "Kursiv (⌘I)", state) }
            group(6) { markButton("underline", .underline, "Unterstrichen (⌘U)", state) }
            group(7) { markButton("strikethrough", .strikethrough, "Durchgestrichen (⇧⌘X)", state) }
            group(8) { markButton("chevron.left.forwardslash.chevron.right", .code, "Code im Text (⌘E)", state) }
            divider(9)
            group(10) {
                ToolbarButton(symbol: "list.bullet", help: "Aufzählung (⇧⌘8)", isActive: state.block == .bullet) { controller.setBlock(.bullet) }
            }
            group(11) {
                ToolbarButton(symbol: "list.number", help: "Nummerierte Liste (⇧⌘7)", isActive: state.block == .numbered) { controller.setBlock(.numbered) }
            }
            group(12) {
                ToolbarButton(symbol: "decrease.indent", help: "Weniger einrücken (⇧⇥)", isActive: false) { controller.changeListLevel(by: -1) }
                    .disabled(!state.block.isList)
            }
            group(13) {
                ToolbarButton(symbol: "increase.indent", help: "Weiter einrücken (⇥)", isActive: false) { controller.changeListLevel(by: 1) }
                    .disabled(!state.block.isList)
            }
            group(14) {
                ToolbarButton(symbol: "text.quote", help: "Zitat (⇧⌘9)", isActive: state.block == .quote) { controller.setBlock(.quote) }
            }
            divider(15)
            group(16) {
                ToolbarButton(symbol: "link", help: "Link (⌘K)", isActive: state.hasLink) { controller.editLink() }
            }
            group(17) {
                ToolbarButton(symbol: "minus", help: "Trennlinie / Abschnittsmarke", isActive: false) { controller.insertRule() }
            }
            divider(18)
            group(19) {
                ToolbarButton(
                    symbol: app.dictationIntoDocument ? "mic.fill" : "mic",
                    help: app.dictationIntoDocument ? "Diktat beenden (⌘D)" : "Ins Dokument diktieren (⌘D) – „neuer Absatz“ beginnt einen neuen Absatz",
                    isActive: app.dictationIntoDocument
                ) { controller.toggleDictation() }
                .disabled(!app.isDictationAvailable)
            }
            group(20) {
                ToolbarButton(
                    symbol: app.speakingDocumentID != nil ? "stop.fill" : "speaker.wave.2",
                    help: app.speakingDocumentID != nil ? "Vorlesen stoppen (esc)" : "Vorlesen (⌥⌘L): die Markierung, sonst ab dem Absatz mit dem Cursor",
                    isActive: app.speakingDocumentID != nil
                ) { controller.readAloud() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
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
        group(index) {
            Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 5)
        }
    }

    private func markButton(_ symbol: String, _ mark: WriterInline, _ help: String, _ state: WriterTextView.State) -> some View {
        ToolbarButton(symbol: symbol, help: help, isActive: state.marks.contains(mark)) { controller.toggle(mark) }
            .disabled(state.block == .code || state.block == .raw)
    }
}

private struct ToolbarButton: View {
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

private struct FontMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Schrift des Dokuments") {
                ForEach(WriterFont.allCases) { font in
                    Button { app.setDocumentFont(document.id, font) } label: {
                        if font == document.font { Label(font.label, systemImage: "checkmark") } else { Text(font.label) }
                    }
                }
            }
        } label: {
            MenuLabel(symbol: "textformat", title: shortName, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Schrift des ganzen Dokuments")
    }

    private var shortName: String {
        switch document.font {
        case .serif: "New York"
        case .sans: "SF Pro"
        case .rounded: "Rounded"
        case .mono: "Mono"
        }
    }
}

private struct BlockMenu: View {
    let controller: WriterEditorController
    let current: WriterBlock
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach([WriterBlock.paragraph, .heading1, .heading2, .heading3, .code], id: \.self) { block in
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
        .help("Absatzformat")
    }

    private func shortcut(_ block: WriterBlock) -> String {
        switch block {
        case .paragraph: "  ⌥⌘0"
        case .heading1: "  ⌥⌘1"
        case .heading2: "  ⌥⌘2"
        case .heading3: "  ⌥⌘3"
        case .code: "  ⌥⌘C"
        default: ""
        }
    }
}

private struct MenuLabel: View {
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
