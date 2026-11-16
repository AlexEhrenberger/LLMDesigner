import SwiftUI

// The cards below the slide: what the model does with the whole presentation, a deleted slide, the speaker card
// (see PresenterScreen).

/// What the model does with the whole presentation: making it from the bar's instruction (with "Rückgängig"
/// afterwards), or writing the speaker notes of many slides.
struct DeckActivityCard: View {
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
                SmallActionButton(title: "Rückgängig", symbol: "arrow.uturn.backward") { app.undoDeckGeneration(undoManager: MainWindow.window?.undoManager) }
                    .help("Die Folien der KI wieder entfernen; was du selbst hinzugefügt hast, bleibt. ⌘Z holt sie zurück.")
                IconButton(systemName: "xmark", help: "Ausblenden", size: 10.5, frameSize: 22) { app.deckGeneration = nil }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.warning)
                text("Die Präsentation ließ sich nicht erstellen", message)
                Spacer(minLength: 8)
                if !generation.created.isEmpty {
                    SmallActionButton(title: "Rückgängig", symbol: "arrow.uturn.backward") { app.undoDeckGeneration(undoManager: MainWindow.window?.undoManager) }
                        .help("Die Folien der KI wieder entfernen; was du selbst hinzugefügt hast, bleibt. ⌘Z holt sie zurück.")
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
struct DeletedSlideToast: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text("Folie gelöscht")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Button("Wiederherstellen") { app.restoreDeletedSlide(undoManager: MainWindow.window?.undoManager) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(Theme.strongBorder))
        .shadow(color: Theme.shade.opacity(0.4), radius: 14, y: 5)
    }
}

// MARK: Speaker notes

/// The "Moderatorenkarte" below the slide: what the presenter (or the AI) says to it.
struct SpeakerNotesCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide
    let find: DocumentFind

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
                if !isWriting, app.replacedNotes[slide.id] != nil {
                    SmallActionButton(title: "Vorherige Karte", symbol: "arrow.uturn.backward") {
                        app.restoreReplacedNotes(document.id, slide.id, undoManager: MainWindow.window?.undoManager)
                    }
                    .help("Die Karte von vorher zurückholen; ein zweiter Klick bringt die neue wieder")
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
                    if deck.slides.contains(where: { app.replacedNotes[$0.id] != nil }) {
                        Button("Vorherige Karten aller Folien zurückholen", systemImage: "arrow.uturn.backward") {
                            app.restoreAllReplacedNotes(document.id, undoManager: MainWindow.window?.undoManager)
                        }
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
                SpeakerNotesEditor(app: app, text: slide.notes, slideID: slide.id, isEditable: !isWriting, find: find) { notes in
                    app.setSlideNotes(document.id, slide.id, notes)
                }
                .opacity(isWriting ? 0.6 : 1)
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

/// The speaker card's text: a plain text view, so the find bar can mark its places.
struct SpeakerNotesEditor: NSViewRepresentable {
    let app: AppModel
    let text: String
    let slideID: PresentationSlide.ID
    let isEditable: Bool
    let find: DocumentFind
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor(Theme.textPrimary)
        textView.insertionPointColor = NSColor(Theme.textPrimary)
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(Theme.textPrimary)]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.onChange = onChange
        context.coordinator.register(in: app)
        show(text, of: slideID, in: textView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // Typing not yet handed over belongs to the slide it was typed on.
        if coordinator.slideID != slideID { coordinator.flush() }
        coordinator.onChange = onChange
        guard let textView = coordinator.textView else { return }
        textView.isEditable = isEditable
        // Another slide, or the card was written elsewhere (the model); never over typing not yet handed over, never
        // while letters are being composed.
        if coordinator.slideID != slideID || (!coordinator.hasPendingEdits && textView.string != text && !textView.hasMarkedText()) {
            show(text, of: slideID, in: textView, context: context)
        }
    }

    private func show(_ text: String, of slideID: PresentationSlide.ID, in textView: NSTextView, context: Context) {
        let isSameSlide = context.coordinator.slideID == slideID
        let selection = textView.selectedRange()
        context.coordinator.slideID = slideID
        if textView.string != text {
            // Typing steps of the old text would point at ranges that no longer fit.
            textView.removeUndoActions()
            textView.string = text
            textView.textColor = NSColor(Theme.textPrimary)
            let length = (text as NSString).length
            textView.setSelectedRange(isSameSlide ? NSRange(location: min(selection.location, length), length: 0) : NSRange(location: 0, length: 0))
        }
        find.attachNotes(textView, slideID: slideID)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
        coordinator.unregister()
        coordinator.textView?.removeUndoActions()
    }

    /// Hands what is typed over to the presentation after a pause, as the slide's editor does: every change of the
    /// presentation redraws the whole screen, slide list and panel included, which is too much for every letter.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let pause: Duration = .milliseconds(350)

        weak var textView: NSTextView?
        var slideID: PresentationSlide.ID?
        var onChange: ((String) -> Void)?
        private weak var app: AppModel?
        private var pending: Task<Void, Never>?
        /// Where the typing goes: the slide's it was typed on, kept from the first letter.
        private var pendingWrite: ((String) -> Void)?

        var hasPendingEdits: Bool { pendingWrite != nil }

        /// `app.flushEdits()` (called before anything else reads or changes the presentation) hands over this card too.
        func register(in app: AppModel) {
            self.app = app
            app.registerNotesFlush(self) { [weak self] in self?.flush() }
        }

        func unregister() {
            app?.unregisterNotesFlush(self)
        }

        func textDidChange(_ notification: Notification) {
            if pendingWrite == nil { pendingWrite = onChange }
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.pause)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            flush()
        }

        func flush() {
            pending?.cancel()
            pending = nil
            guard let write = pendingWrite, let textView else { return }
            pendingWrite = nil
            write(textView.string)
        }
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
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Theme.hover : Theme.ink.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
