import SwiftUI

/// Plays a presentation, in the "Abspielen" tab and in the full-screen window at the same time. With "KI
/// präsentiert" the model takes over: it reads each slide's speaker notes aloud (writing them first if there are
/// none) and goes on to the next slide when it is done.
@MainActor
@Observable
final class PresentationPlayer {
    enum Phase: Equatable {
        case idle
        /// The model writes the speaker notes of the slide.
        case writing
        case speaking
        /// A short pause before the next slide.
        case turning
        case finished
    }

    @ObservationIgnored weak var app: AppModel?
    private(set) var documentID: WriterDocument.ID?
    private(set) var index = 0
    private(set) var isPresenting = false
    private(set) var phase: Phase = .idle
    /// What is being read aloud (the notes as spoken text) and the part being spoken right now.
    private(set) var spokenText = ""
    private(set) var spokenRange: NSRange?
    /// The speaker notes show as subtitles on the slide.
    var showsSubtitles = false
    /// At the end the model starts again from the first slide.
    var repeats = false
    private(set) var isFullScreen = false
    var error: String?

    @ObservationIgnored private var run: Task<Void, Never>?
    /// Each reading gets a number; when it ends, only the current one counts.
    @ObservationIgnored private var reading = 0
    @ObservationIgnored private var readingEnded: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var window: PresentationWindowController?

    var deck: PresentationDeck? {
        documentID.flatMap { app?.document($0)?.deck }
    }

    var currentSlide: PresentationSlide? {
        guard let deck, deck.slides.indices.contains(index) else { return nil }
        return deck.slides[index]
    }

    /// The presentation shown and where it starts; called when the tab or the window opens.
    func prepare(_ documentID: WriterDocument.ID, at slideID: PresentationSlide.ID?) {
        if self.documentID != documentID {
            stop()
            self.documentID = documentID
            phase = .idle
        }
        if let slideID, let found = deck?.index(of: slideID), !isPresenting {
            index = found
        }
        clampIndex()
    }

    // MARK: Moving

    func go(to newIndex: Int) {
        guard let deck, deck.slides.indices.contains(newIndex), newIndex != index else { return }
        interruptReading()
        withAnimation(.easeInOut(duration: 0.45)) { index = newIndex }
        if phase == .finished { phase = .idle }
        if let slide = currentSlide { app?.selectedSlideID = slide.id }
        if isPresenting { startLoop() }
    }

    func next() {
        guard let deck else { return }
        if index + 1 < deck.slides.count { go(to: index + 1) }
    }

    func previous() {
        if index > 0 { go(to: index - 1) }
    }

    // MARK: The model presents

    func togglePresenting() {
        isPresenting ? pause() : present()
    }

    /// The model presents from the current slide on; at the end it starts from the first.
    func present() {
        guard let deck, !deck.slides.isEmpty else { return }
        error = nil
        if phase == .finished || index >= deck.slides.count { index = 0 }
        isPresenting = true
        startLoop()
    }

    func pause() {
        isPresenting = false
        run?.cancel()
        run = nil
        interruptReading()
        if phase != .finished { phase = .idle }
    }

    /// Ends presenting and reading (also when the presentation closes).
    func stop() {
        pause()
        spokenText = ""
        spokenRange = nil
    }

    /// Reads the current slide's speaker notes once, without going on.
    func readCurrentNotes() {
        guard let slide = currentSlide else { return }
        if phase == .speaking { return interruptReading() }
        let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return app?.showNotice("Diese Folie hat noch keine Moderatorenkarte.") ?? () }
        Task { _ = await speak(notes) }
    }

    private func startLoop() {
        run?.cancel()
        run = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while isPresenting, !Task.isCancelled {
            guard let app, let documentID, let deck, deck.slides.indices.contains(index) else { break }
            let slide = deck.slides[index]
            var notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if notes.isEmpty {
                phase = .writing
                notes = await notesWhenWritten(slide.id, in: documentID) ?? ""
                guard isPresenting, !Task.isCancelled else { return }
                if notes.isEmpty {
                    if let message = app.notesErrors[slide.id] {
                        error = message
                    } else {
                        do {
                            notes = try await app.generateNotes(documentID, slide.id)
                        } catch {
                            if !Task.isCancelled { self.error = "Die Moderatorenkarte ließ sich nicht schreiben: \(error.localizedDescription)" }
                        }
                    }
                    guard isPresenting, !Task.isCancelled else { return }
                    if notes.isEmpty {
                        isPresenting = false
                        phase = .idle
                        return
                    }
                }
            }
            prepareNotes(after: index, in: documentID)
            let started = Date()
            let finished = await speak(notes)
            guard finished, isPresenting, !Task.isCancelled else { return }
            // A voice that ends at once is not there (Qwen TTS not running, for example).
            if Date().timeIntervalSince(started) < 0.6, notes.count > 40 {
                error = app.notice ?? "Die Stimme hat nichts vorgelesen. Ist die Sprachausgabe erreichbar?"
                isPresenting = false
                phase = .idle
                return
            }
            phase = .turning
            try? await Task.sleep(for: .milliseconds(900))
            guard isPresenting, !Task.isCancelled, let count = self.deck?.slides.count else { return }
            if index + 1 < count {
                withAnimation(.easeInOut(duration: 0.6)) { index += 1 }
                if let slide = currentSlide { app.selectedSlideID = slide.id }
            } else if repeats {
                withAnimation(.easeInOut(duration: 0.6)) { index = 0 }
                if let slide = currentSlide { app.selectedSlideID = slide.id }
            } else {
                isPresenting = false
                phase = .finished
                return
            }
        }
    }

    /// The model writes the next slide's notes while this one is read, so there is no pause between them.
    private func prepareNotes(after index: Int, in documentID: WriterDocument.ID) {
        guard let app, let deck, index + 1 < deck.slides.count else { return }
        let next = deck.slides[index + 1]
        guard next.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !app.notesWriting.contains(next.id) else { return }
        app.writeSpeakerNotes(documentID, slides: [next.id])
    }

    /// Waits for notes the model is writing already; nil when it isn't writing them.
    private func notesWhenWritten(_ slideID: PresentationSlide.ID, in documentID: WriterDocument.ID) async -> String? {
        guard let app, app.notesWriting.contains(slideID) else { return nil }
        while app.notesWriting.contains(slideID), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return app.document(documentID)?.deck?.slide(slideID)?.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading aloud

    /// Reads the text and returns when it is done: true if it was read to the end.
    private func speak(_ notes: String) async -> Bool {
        guard let app else { return false }
        interruptReading()
        reading += 1
        let number = reading
        stoppedByUser = false
        let text = SpeakableText.from(markdown: notes)
        spokenText = text
        spokenRange = nil
        phase = .speaking
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            readingEnded = continuation
            app.readDocumentAloud(
                text,
                progress: { [weak self] range in
                    guard let self, self.reading == number else { return }
                    self.spokenRange = range
                },
                ended: { [weak self] in
                    guard let self, self.reading == number else { return }
                    let continuation = self.readingEnded
                    self.readingEnded = nil
                    continuation?.resume(returning: !self.stoppedByUser)
                }
            )
        }
        if reading == number {
            spokenRange = nil
            if phase == .speaking { phase = .idle }
        }
        return finished
    }

    private func interruptReading() {
        guard let continuation = readingEnded else { return }
        readingEnded = nil
        stoppedByUser = true
        reading += 1
        app?.stopReadingDocument()
        continuation.resume(returning: false)
        spokenRange = nil
        if phase == .speaking { phase = .idle }
    }

    private func clampIndex() {
        guard let deck else { return }
        index = min(max(0, index), max(0, deck.slides.count - 1))
    }

    // MARK: Full screen

    func enterFullScreen() {
        guard let app, documentID != nil else { return }
        if window == nil { window = PresentationWindowController(player: self, app: app) }
        window?.show()
        isFullScreen = true
    }

    func exitFullScreen() {
        window?.close()
        window = nil
        isFullScreen = false
    }
}
