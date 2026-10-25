import SwiftUI

/// The model making a whole presentation, shown above the assistant bar of Presenter Studio.
struct DeckGeneration: Equatable {
    enum Phase: Equatable {
        /// The outline: title, chapters and slide titles.
        case outlining
        /// The slides' content, one after the other.
        case filling(done: Int, total: Int)
        case finished
        case stopped
        case failed(String)
    }

    let documentID: WriterDocument.ID
    var phase: Phase
    /// The slides before, for "Rückgängig".
    let before: PresentationDeck
    /// The slides that were made.
    var created: [PresentationSlide.ID] = []
    /// The presentation was empty and is now the new one (rather than new slides at its end).
    var replacedEmpty = false

    var isRunning: Bool {
        switch phase {
        case .outlining, .filling: true
        default: false
        }
    }
}

/// Presenter Studio's assistant bar also takes instructions about the whole presentation (see `PresenterIntent`).
extension AppModel {
    func runPresenterIntent(_ intent: PresenterIntent, instruction: String, in id: WriterDocument.ID) {
        switch intent.kind {
        case .createDeck:
            generatePresentation(id, instruction: instruction, withNotes: intent.withNotes, presents: intent.presents)
        case .speakerNotes:
            writeAllSpeakerNotes(id, anew: intent.rewritesNotes)
            if intent.presents { presentWithAI(id) }
        case .present:
            presentWithAI(id)
        }
    }

    /// Speaker notes for every slide: those still missing, or all of them anew (also when none is missing).
    func writeAllSpeakerNotes(_ id: WriterDocument.ID, anew: Bool) {
        writerFlush?()
        guard let deck = document(id)?.deck else { return }
        let missing = deck.slides.filter { $0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        writeSpeakerNotes(id, slides: anew || missing.isEmpty ? deck.slides.map(\.id) : missing)
    }

    /// The model presents from the first slide in full screen; it writes the notes it needs on the way.
    func presentWithAI(_ id: WriterDocument.ID) {
        writerFlush?()
        guard let first = document(id)?.deck?.slides.first?.id else { return }
        let player = presentationPlayer
        player.app = self
        player.prepare(id, at: first)
        player.go(to: 0)
        player.enterFullScreen()
        player.present()
    }

    // MARK: A whole presentation

    /// Makes a presentation from the instruction: the model outlines it first, the slides appear with their titles,
    /// then it fills them one by one. An empty presentation becomes the new one; otherwise the slides are added at
    /// its end. "Rückgängig" brings back the slides from before.
    func generatePresentation(_ id: WriterDocument.ID, instruction: String, withNotes: Bool, presents: Bool) {
        guard deckGeneration?.isRunning != true else { return }
        writerFlush?()
        guard let document = document(id), let before = document.deck else { return }
        guard let client, let model = currentModelId else {
            deckGeneration = DeckGeneration(documentID: id, phase: .failed("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste."), before: before)
            return
        }
        let isEmpty = before.slides.allSatisfy { $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        deckGeneration = DeckGeneration(documentID: id, phase: .outlining, before: before, replacedEmpty: isEmpty)
        let title = document.displayTitle

        deckGenerationTask = Task { [weak self] in
            do {
                let answer = try await client.complete(
                    model: model,
                    messages: PresenterPrompts.outlineMessages(instruction: instruction, existing: isEmpty ? [] : before.slides, presentationTitle: title),
                    temperature: 0.5,
                    maxTokens: 2500,
                    orderedSchema: ("gliederung", PresenterPrompts.outlineSchema.json)
                )
                let outline = try JSONDecoder().decode(PresenterPrompts.Outline.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
                guard outline.kapitel.contains(where: { !$0.folien.isEmpty }) else {
                    throw LLMError.server("Das Modell hat keine Gliederung geliefert.")
                }
                try Task.checkCancellation()
                guard let self else { return }

                // The skeleton: title, chapters and slides with their titles.
                var slides: [PresentationSlide] = []
                var plan: [(id: PresentationSlide.ID, chapter: String, slide: PresenterPrompts.Outline.Slide)] = []
                let titleSlide: PresentationSlide? = isEmpty ? PresentationSlide(
                    id: before.slides.first?.id ?? UUID(),
                    role: .title,
                    markdown: "# \(Self.slideLine(outline.titel)) {.chapter}" + (outline.untertitel.isEmpty ? "" : "\n\n" + Self.slideLine(outline.untertitel))
                ) : nil
                for chapter in outline.kapitel where !chapter.folien.isEmpty {
                    slides.append(PresentationSlide(role: .chapter, markdown: "# \(Self.slideLine(chapter.titel)) {.chapter}"))
                    for slide in chapter.folien {
                        let new = PresentationSlide(role: .content, markdown: "# " + Self.slideLine(slide.titel))
                        slides.append(new)
                        plan.append((new.id, chapter.titel, slide))
                    }
                }
                self.modifyDeck(id) { deck in
                    if let titleSlide { deck.slides = [titleSlide] + slides } else { deck.slides += slides }
                    return true
                }
                let created = (titleSlide.map { [$0.id] } ?? []) + slides.map(\.id)
                self.deckGeneration?.created = created
                if self.selectedDocumentID == id { self.selectedSlideID = created.first }

                // The content, slide by slide.
                for (number, item) in plan.enumerated() {
                    try Task.checkCancellation()
                    self.deckGeneration?.phase = .filling(done: number, total: plan.count)
                    let answer = try await client.complete(
                        model: model,
                        messages: PresenterPrompts.slideMessages(outline: outline, chapter: item.chapter, slide: item.slide),
                        temperature: 0.4,
                        maxTokens: 900,
                        orderedSchema: ("folie", PresenterPrompts.slideSchema.json)
                    )
                    try Task.checkCancellation()
                    let content = try? JSONDecoder().decode(PresenterPrompts.SlideContent.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
                    let points = (content?.punkte ?? []).map(Self.slidePoint).filter { !$0.isEmpty }
                    guard !points.isEmpty else { continue }
                    let markdown = "# " + Self.slideLine(item.slide.titel) + "\n\n" + points.map { "- " + $0 }.joined(separator: "\n")
                    self.modifyDeck(id) { deck in
                        guard let index = deck.index(of: item.id) else { return false }
                        deck.slides[index].markdown = markdown
                        return true
                    }
                }
                self.deckGeneration?.phase = .finished
                if withNotes { self.writeSpeakerNotes(id, slides: created) }
                if presents { self.presentWithAI(id) }
            } catch {
                guard let self else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    self.deckGeneration?.phase = .stopped
                } else {
                    self.deckGeneration?.phase = .failed(error.localizedDescription)
                }
            }
            self?.deckGenerationTask = nil
        }
    }

    func stopDeckGeneration() {
        deckGenerationTask?.cancel()
    }

    /// The slides from before the model made the presentation.
    func undoDeckGeneration() {
        guard let generation = deckGeneration, !generation.isRunning else { return }
        let created = Set(generation.created)
        notesTask?.cancel()
        notesWriting.subtract(created)
        modifyDeck(generation.documentID) { deck in
            deck = generation.before
            return true
        }
        if selectedDocumentID == generation.documentID { selectedSlideID = generation.before.slides.first?.id }
        deckGeneration = nil
    }

    // MARK: Cleaning the model's text

    /// A title in one line, without Markdown marks and numbering.
    static func slideLine(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        line = line.replacingOccurrences(of: #"^(#+|\d+[.)]|[-–•*])\s*"#, with: "", options: .regularExpression)
        // "Kapitel 2: …", "Folie 1.3 – …": the slides number themselves.
        line = line.replacingOccurrences(of: #"^(?i:Kapitel|Folie|Teil|Abschnitt|Chapter|Slide)\s+(\d+(\.\d+)*|[IVX]+)\b\s*[:.–-]?\s*"#, with: "", options: .regularExpression)
        while line.hasSuffix(":") || line.hasSuffix(".") { line.removeLast() }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// A point of a slide: one line without its own bullet; bold marks are kept.
    static func slidePoint(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        line = line.replacingOccurrences(of: #"^([-–•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
        if line.hasSuffix("."), !line.hasSuffix("..") { line.removeLast() }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
