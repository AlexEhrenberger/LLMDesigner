import AppKit
import SwiftUI

struct ComposerView: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    let placeholder: String
    let isGenerating: Bool
    let canSend: Bool
    let focusToken: AnyHashable?
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var textHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !app.draftImages.isEmpty || app.importingDraftImages > 0 {
                AttachmentStrip(images: app.draftImages, importing: app.importingDraftImages, onRemove: app.removeDraftImage)
            }
            ComposerTextView(
                text: $text,
                height: $textHeight,
                focusToken: focusToken,
                onSubmit: { if canSend { onSend() } },
                onImages: { app.attachImages($0) }
            )
            .frame(height: min(max(textHeight, 20), 260))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Typing cancels the consolidation, so this only shows while the field is empty.
                if let persona = app.activePersona, app.thalamusConsolidation?.personaID == persona.id {
                    MemoryIdleIndicator(text: "\(persona.displayName) verdichtet Erinnerungen …", name: persona.displayName)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: app.thalamusConsolidation?.personaID)

            HStack(spacing: 8) {
                AttachImageButton()
                PersonaButton()
                SkillsButton()
                ThinkingButton()
                WebSearchButton()
                WikipediaButton()
                if app.isDictationAvailable {
                    DictationButton()
                }
                if app.dictationStatus != .idle {
                    DictationPreview()
                }
                Spacer(minLength: 0)
                if app.isConversationAvailable {
                    ConversationButton()
                }
                SendButton(isGenerating: isGenerating, canSend: canSend || app.isDictating, onSend: onSend, onStop: onStop)
            }
        }
        .padding(.top, 15)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.strongBorder))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }
}

/// While the persona consolidates its memories: a brain that pulses and a shimmer running over the text.
private struct MemoryIdleIndicator: View {
    let text: String
    let name: String
    @State private var sweep = false

    var body: some View {
        label
            .foregroundStyle(Theme.textTertiary)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.5)
                }
                .mask(label)
            }
            .padding(.top, 1)
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { sweep = true }
            }
            .help("\(name) arbeitet an ihrem Gedächtnis. Wenn du weiterschreibst, wird das unterbrochen und später nachgeholt.")
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12, weight: .medium))
                .symbolEffect(.pulse, options: .repeating)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
    }
}

/// Opens a file dialog for pictures. Pictures can also be pasted (⌘V) or dragged into the window.
private struct AttachImageButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.chooseImages() } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? Theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Bilder anhängen (⇧⌘A) – oder einfügen (⌘V) bzw. ins Fenster ziehen")
    }
}

/// Switches the thinking mode on or off for this chat.
private struct ThinkingButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ComposerToggle(
            title: "Denken",
            isOn: app.isThinkingOn,
            isAvailable: true,
            helpOn: "Denkmodus ausschalten (⇧⌘T)",
            helpOff: "Denkmodus einschalten (⇧⌘T): Das Modell denkt nach, bevor es antwortet",
            action: app.toggleThinking
        ) {
            Image(systemName: "brain").font(.system(size: 14, weight: .medium))
        }
    }
}

/// Switches the web search on or off for this chat.
private struct WebSearchButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ComposerToggle(
            title: "Websuche",
            isOn: app.isWebSearchOn,
            isAvailable: app.canUseLookupTools,
            helpOn: "Websuche ausschalten",
            helpOff: "Websuche einschalten: Das Modell darf im Internet suchen und Seiten lesen",
            action: app.toggleWebSearch
        ) {
            Image(systemName: "globe").font(.system(size: 14, weight: .medium))
        }
    }
}

/// Switches the Wikipedia search on or off for this chat.
private struct WikipediaButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ComposerToggle(
            title: "Wikipedia",
            isOn: app.isWikipediaOn,
            isAvailable: app.canUseLookupTools,
            helpOn: "Wikipedia-Suche ausschalten",
            helpOff: "Wikipedia-Suche einschalten: Das Modell schlägt Sachfragen in Wikipedia nach",
            action: app.toggleWikipedia
        ) {
            Text("W").font(.system(size: 15, weight: .semibold, design: .serif))
        }
    }
}

/// Composer switch such as thinking or a lookup source. Off: just the icon, like the microphone; on: a tinted pill with the name.
private struct ComposerToggle<Icon: View>: View {
    let title: String
    let isOn: Bool
    let isAvailable: Bool
    let helpOn: String
    let helpOff: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false

    var body: some View {
        let active = isOn && isAvailable
        Button(action: action) {
            HStack(spacing: 5) {
                icon
                if active {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .foregroundStyle(foreground(active: active))
            .padding(.horizontal, active ? 11 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .background(Capsule().fill(active ? Theme.accent.opacity(hovering ? 0.24 : 0.16) : (hovering && isAvailable ? Theme.hover : .clear)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(active ? 0.35 : 0)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onHover { hovering = $0 }
        .help(isAvailable ? (active ? helpOn : helpOff) : "\(title): Das gewählte Modell kann keine Werkzeuge nutzen")
    }

    private func foreground(active: Bool) -> Color {
        if active { return Theme.accent }
        if !isAvailable { return Theme.textTertiary.opacity(0.6) }
        return hovering ? Theme.textPrimary : Theme.textSecondary
    }
}

private struct DictationButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.toggleDictation() } label: {
            ZStack {
                switch app.dictationStatus {
                case .listening:
                    // The halo follows the microphone level.
                    Circle()
                        .fill(Theme.danger.opacity(0.22))
                        .scaleEffect(1 + CGFloat(app.dictationLevel) * 0.45)
                    Circle().fill(Theme.danger)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                case .preparing, .finishing:
                    ProgressView().controlSize(.small)
                case .idle:
                    Circle().fill(hovering ? Theme.hover : .clear)
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.08), value: app.dictationLevel)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(app.dictationStatus == .listening ? "Diktat beenden (⌘D)" : "Diktieren (⌘D)")
    }
}

/// Grey line next to the microphone: what the recogniser hears right now, or what it is doing.
private struct DictationPreview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .italic()
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    private var text: String {
        switch app.dictationStatus {
        case .preparing(let progress):
            if let progress { return "Sprachmodell wird geladen … \(Int(progress * 100)) %" }
            return "Mikrofon wird vorbereitet …"
        case .listening:
            return app.dictationPreview.isEmpty ? "Ich höre zu …" : app.dictationPreview
        case .finishing:
            return "Letzte Wörter …"
        case .idle:
            return ""
        }
    }
}

/// Starts conversation mode: speaking instead of typing, the answers are read aloud. Sits next to the send button.
private struct ConversationButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let available = app.canStartConversation
        Button { app.startConversation() } label: {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(available ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering && available ? Theme.strongBorder : Theme.elevated))
                .overlay(Circle().strokeBorder(Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var helpText: String {
        if app.canStartConversation { return "Gesprächsmodus (⇧⌘D): sprechen statt tippen, die Antworten werden vorgelesen" }
        if app.isGenerating { return "Gesprächsmodus: Warte, bis die Antwort fertig ist" }
        return "Gesprächsmodus: Lade zuerst ein Modell in LM Studio"
    }
}

private struct SendButton: View {
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        let active = isGenerating || canSend
        Button(action: isGenerating ? onStop : onSend) {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: isGenerating ? 11 : 14, weight: .bold))
                .foregroundStyle(active ? Color.black : Theme.textTertiary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(active ? Theme.textPrimary : Theme.elevated))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .help(isGenerating ? "Stoppen (⌘.)" : "Senden (⏎)")
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// Multi-line input backed by NSTextView: Return sends, Shift/Option+Return inserts a line break,
/// and the view reports its content height so the composer can grow with the text.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusToken: AnyHashable?
    let onSubmit: () -> Void
    /// Pictures pasted or dropped onto the text.
    var onImages: (([AttachmentStore.Source]) -> Void)? = nil
    /// Escape, e.g. to leave the editor of a sent message.
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = SubmittingTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = NSColor(Theme.textPrimary)
        textView.insertionPointColor = NSColor(Theme.textPrimary)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.recalculateHeight() }
        if onImages != nil {
            textView.onImages = { [weak coordinator = context.coordinator] in coordinator?.parent.onImages?($0) }
        }
        if onCancel != nil {
            textView.onCancel = { [weak coordinator = context.coordinator] in coordinator?.parent.onCancel?() }
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.focusSoon()
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            coordinator.recalculateHeight()
        }
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            coordinator.focusSoon()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: SubmittingTextView?
        var lastFocusToken: AnyHashable?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }

        func focusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }
}

final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onWidthChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var onImages: (([AttachmentStore.Source]) -> Void)? {
        didSet { updateDragTypeRegistration() }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let wantsNewline = !event.modifierFlags.intersection([.shift, .option]).isEmpty
        if isReturn && !wantsNewline && !hasMarkedText() {
            onSubmit?()
            return
        }
        // Escape would otherwise open the word completion.
        if event.keyCode == 53, let onCancel, !hasMarkedText() {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Pictures

    /// A plain-text view greys out Paste when the clipboard holds only a picture.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onImages != nil, ImagePasteboard.containsImages(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if let onImages, let sources = ImagePasteboard.sources(on: .general, preferText: true) {
            onImages(sources)
            return
        }
        super.paste(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        onImages == nil ? super.acceptableDragTypes : super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsImages(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsImages(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsImages(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onImages, let sources = ImagePasteboard.sources(on: sender.draggingPasteboard, preferText: false) {
            onImages(sources)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func acceptsImages(_ info: NSDraggingInfo) -> Bool {
        onImages != nil && ImagePasteboard.containsImages(info.draggingPasteboard)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }
}
