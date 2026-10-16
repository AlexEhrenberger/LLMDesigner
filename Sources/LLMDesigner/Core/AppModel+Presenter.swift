import SwiftUI

/// A slide that was just deleted; it can be brought back for a moment.
struct DeletedSlide: Equatable {
    let documentID: WriterDocument.ID
    let slide: PresentationSlide
    let index: Int
}

/// What the background sheet asks Draw Things for.
struct SlideBackgroundRequest {
    var description: String
    var style: ImageStyle
    /// The text colour the picture is made for: light text needs a dark picture.
    var tone: SlideTone
    /// The kinds of slides that get the picture as the presentation's background …
    var roles: [SlideRole]
    /// … or only this slide.
    var slideID: PresentationSlide.ID?
    var resolution: ImageResolution
}

/// Presenter Studio: presentations are documents of their own kind (`WriterDocument.deck`). They open in the main
/// area like Writer Studio's documents; one slide at a time is edited with Writer Studio's editor.
extension AppModel {
    var selectedPresentation: WriterDocument? {
        guard let document = selectedDocument, document.isPresentation else { return nil }
        return document
    }

    /// The slide shown in the editor: the one chosen, else the first.
    func currentSlideID(in document: WriterDocument) -> PresentationSlide.ID? {
        guard let deck = document.deck else { return nil }
        if let selectedSlideID, deck.index(of: selectedSlideID) != nil { return selectedSlideID }
        return deck.slides.first?.id
    }

    // MARK: Opening

    /// Creates a presentation with its title slide and opens it. Left empty, it disappears again.
    func newPresentation(inFolder folderID: Folder.ID? = nil) {
        closeDocument()
        searchText = ""
        var document = WriterDocument.newPresentation()
        document.folderID = folderID ?? newChatFolderID
        documents.insert(document, at: 0)
        if let folderID = document.folderID { expandFolder(folderID) }
        showChats()
        writerTab = .document
        selectedSlideID = document.deck?.slides.first?.id
        selectedDocumentID = document.id
    }

    func selectSlide(_ id: PresentationSlide.ID) {
        guard selectedSlideID != id else { return }
        writerFlush?()
        selectedSlideID = id
    }

    // MARK: Changing the slides

    /// Changes the presentation's slides; `change` says whether anything changed. Saved after a pause.
    @discardableResult
    func modifyDeck(_ id: WriterDocument.ID, saveAfter delay: Duration? = .milliseconds(500), _ change: (inout PresentationDeck) -> Bool) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }), var deck = documents[index].deck else { return false }
        guard change(&deck) else { return false }
        documents[index].deck = deck
        documents[index].updatedAt = Date()
        if !documents[index].hasCustomTitle {
            documents[index].title = WriterDocument.makeTitle(from: documents[index].markdown)
        }
        saveDocument(id, after: delay)
        return true
    }

    /// The editor reports a slide's text as Markdown.
    func updateSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, markdown: String) {
        modifyDeck(id, saveAfter: .milliseconds(700)) { deck in
            guard let index = deck.index(of: slideID), deck.slides[index].markdown != markdown else { return false }
            deck.slides[index].markdown = markdown
            return true
        }
    }

    /// A new, empty slide after `slideID` (or at the end); it is opened right away.
    @discardableResult
    func addSlide(to id: WriterDocument.ID, after slideID: PresentationSlide.ID?, role: SlideRole = .content, markdown: String = "") -> PresentationSlide.ID? {
        writerFlush?()
        let slide = PresentationSlide(role: role, markdown: markdown)
        let added = modifyDeck(id) { deck in
            let index = slideID.flatMap { deck.index(of: $0) }.map { $0 + 1 } ?? deck.slides.count
            deck.slides.insert(slide, at: index)
            return true
        }
        guard added else { return nil }
        selectedSlideID = slide.id
        return slide.id
    }

    func duplicateSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID) {
        writerFlush?()
        var copy: PresentationSlide?
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            var slide = deck.slides[index]
            slide.id = UUID()
            deck.slides.insert(slide, at: index + 1)
            copy = slide
            return true
        }
        if let copy { selectedSlideID = copy.id }
    }

    /// Removes a slide; for a few seconds it can be brought back. The last slide stays.
    func deleteSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID) {
        writerFlush?()
        var removed: DeletedSlide?
        var next: PresentationSlide.ID?
        modifyDeck(id) { deck in
            guard deck.slides.count > 1, let index = deck.index(of: slideID) else { return false }
            removed = DeletedSlide(documentID: id, slide: deck.slides[index], index: index)
            deck.slides.remove(at: index)
            next = deck.slides[min(index, deck.slides.count - 1)].id
            return true
        }
        guard let removed else { return }
        if selectedSlideID == slideID || selectedSlideID == nil { selectedSlideID = next }
        deletedSlide = removed
        deletedSlideTask?.cancel()
        deletedSlideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.deletedSlide = nil
        }
    }

    func restoreDeletedSlide() {
        guard let deleted = deletedSlide else { return }
        deletedSlide = nil
        writerFlush?()
        modifyDeck(deleted.documentID) { deck in
            guard deck.index(of: deleted.slide.id) == nil else { return false }
            deck.slides.insert(deleted.slide, at: min(deleted.index, deck.slides.count))
            return true
        }
        if selectedDocumentID == deleted.documentID { selectedSlideID = deleted.slide.id }
    }

    /// Moves a slide so that it stands at `destination` (an index of the list before the move, as in `onMove`).
    func moveSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, to destination: Int) {
        writerFlush?()
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            let target = destination > index ? destination - 1 : destination
            guard target != index, target >= 0, target < deck.slides.count else { return false }
            let slide = deck.slides.remove(at: index)
            deck.slides.insert(slide, at: target)
            return true
        }
    }

    func setSlideRole(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ role: SlideRole) {
        writerFlush?()
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID), deck.slides[index].role != role else { return false }
            deck.slides[index].role = role
            return true
        }
    }

    func setSlideNotes(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ notes: String) {
        modifyDeck(id, saveAfter: .milliseconds(800)) { deck in
            guard let index = deck.index(of: slideID), deck.slides[index].notes != notes else { return false }
            deck.slides[index].notes = notes
            return true
        }
    }

    // MARK: Backgrounds

    /// A background for one slide only; nil gives it the presentation's again.
    func setSlideBackground(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ background: SlideBackground?) {
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID), deck.slides[index].background != background else { return false }
            deck.slides[index].background = background
            return true
        }
    }

    /// The presentation's background for every slide of a kind; slides of that kind with their own lose it.
    func setRoleBackground(_ id: WriterDocument.ID, _ role: SlideRole, _ background: SlideBackground) {
        modifyDeck(id) { deck in
            deck.backgrounds[role] = background
            for index in deck.slides.indices where deck.slides[index].role == role { deck.slides[index].background = nil }
            return true
        }
    }

    /// The same background for the whole presentation. A design keeps its own look per kind of slide.
    func setPresentationBackground(_ id: WriterDocument.ID, _ background: SlideBackground) {
        modifyDeck(id) { deck in
            deck.backgrounds = .all(background)
            for index in deck.slides.indices { deck.slides[index].background = nil }
            return true
        }
    }

    /// Asks for a picture on this Mac and makes it a background.
    func chooseBackgroundImage(for id: WriterDocument.ID, apply: @escaping (SlideBackground) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Als Hintergrund"
        panel.message = "Bild für den Folienhintergrund auswählen"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let source = try WriterImageStore.importImage(.file(url))
                var background = SlideBackground.image(source)
                background.tone = SlideImageTone.tone(of: source)
                apply(background)
            } catch {
                self?.showNotice(error.localizedDescription)
            }
        }
        if let window = MainWindow.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Lets the model write a prompt per picture and puts the pictures into Draw Things' queue. The backgrounds
    /// are set right away; they show a placeholder until their picture is done.
    func generateSlideBackgrounds(_ id: WriterDocument.ID, _ request: SlideBackgroundRequest, progress: @escaping (String) -> Void) async throws {
        guard let client, let model = currentModelId else {
            throw LMStudioError.server("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste.")
        }
        guard let document = document(id), let deck = document.deck else { return }
        // One picture per kind of slide; a single slide gets one for its own kind.
        let targets: [SlideRole] = request.slideID.flatMap { deck.slide($0)?.role }.map { [$0] } ?? request.roles
        var defaults = imageGeneration.defaults
        defaults.format = .wide
        defaults.resolution = request.resolution
        defaults.style = request.style
        for (number, role) in targets.enumerated() {
            try Task.checkCancellation()
            progress(targets.count == 1 ? "Das Modell beschreibt das Bild …" : "Das Modell beschreibt Bild \(number + 1) von \(targets.count) (\(role.label)) …")
            let answer = try await client.complete(
                model: model,
                messages: PresenterPrompts.backgroundMessages(
                    description: request.description, presentationTitle: document.displayTitle, role: role, tone: request.tone, style: request.style
                ),
                temperature: 0.7,
                maxTokens: 1200
            )
            let prompt = try ImagePromptBuilder.parse(answer).prompt
            var info = defaults
            info.description = request.description
            info.prompt = prompt
            let source = WriterImageStore.newGeneratedSource()
            imageGeneration.generate(source: source, info: info)
            var background = SlideBackground.image(source, dim: role == .content ? 0.3 : 0.15)
            background.tone = request.tone
            if let slideID = request.slideID {
                setSlideBackground(id, slideID, background)
            } else {
                setRoleBackground(id, role, background)
            }
        }
        var kept = imageGeneration.defaults
        kept.style = request.style
        kept.resolution = request.resolution
        imageGeneration.defaults = kept
    }

    // MARK: Speaker notes

    /// Lets the model write the speaker notes of these slides, one after the other.
    func writeSpeakerNotes(_ id: WriterDocument.ID, slides slideIDs: [PresentationSlide.ID]) {
        writerFlush?()
        let waiting = slideIDs.filter { !notesWriting.contains($0) }
        guard !waiting.isEmpty else { return }
        notesWriting.formUnion(waiting)
        for slideID in waiting { notesErrors[slideID] = nil }
        let previous = notesTask
        notesTask = Task { [weak self] in
            await previous?.value
            for slideID in waiting {
                guard let self, !Task.isCancelled else { break }
                do {
                    _ = try await self.generateNotes(id, slideID)
                } catch {
                    if !Task.isCancelled { self.notesErrors[slideID] = error.localizedDescription }
                }
                self.notesWriting.remove(slideID)
            }
            if Task.isCancelled { self?.notesWriting.subtract(waiting) }
        }
    }

    func cancelSpeakerNotes() {
        notesTask?.cancel()
        notesTask = nil
        notesWriting = []
    }

    /// Writes one slide's speaker notes and keeps them with the slide.
    func generateNotes(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID) async throws -> String {
        guard let client, let model = currentModelId else {
            throw LMStudioError.server("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste.")
        }
        guard let document = document(id), let deck = document.deck, let index = deck.index(of: slideID) else {
            throw CancellationError()
        }
        let answer = try await client.complete(
            model: model,
            messages: PresenterPrompts.notesMessages(deck: deck, title: document.displayTitle, slideIndex: index),
            temperature: 0.7,
            maxTokens: 1500
        )
        var notes = PresenterPrompts.cleanNotes(answer)
        if index > 0 { notes = PresenterPrompts.removingCopies(of: deck.slides[index - 1].notes, from: notes) }
        guard !notes.isEmpty else { throw LMStudioError.server("Das Modell hat keinen Text geliefert.") }
        setSlideNotes(id, slideID, notes)
        return notes
    }

    // MARK: Agenda

    /// A slide that lists the chapters (or, without chapters, the slides' titles), after `slideID`.
    func insertAgendaSlide(_ id: WriterDocument.ID, after slideID: PresentationSlide.ID?) {
        writerFlush?()
        guard let deck = document(id)?.deck else { return }
        let chapters = deck.slides.filter { $0.role == .chapter }.map(\.title).filter { !$0.isEmpty }
        let items = chapters.isEmpty
            ? deck.slides.filter { $0.role == .content }.map(\.title).filter { !$0.isEmpty }
            : chapters
        let list = items.isEmpty ? "- " : items.map { "- " + $0 }.joined(separator: "\n")
        addSlide(to: id, after: slideID, role: .content, markdown: "# Agenda\n\n" + list)
    }
}

/// Whether a picture is light or dark, so the text on it gets the colour that can be read.
enum SlideImageTone {
    static func tone(of source: String) -> SlideTone {
        guard let url = WriterImageStore.url(for: source), let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .light }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .light }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let hex = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
            total += SlideBackground.luminance(hex)
        }
        return SlideBackground.tone(forLuminance: total / Double(side * side))
    }
}
