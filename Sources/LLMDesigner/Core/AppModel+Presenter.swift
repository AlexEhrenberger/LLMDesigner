import SwiftUI

/// A slide that was just deleted; it can be brought back for a moment.
struct DeletedSlide: Equatable {
    let documentID: WriterDocument.ID
    let slide: PresentationSlide
    let index: Int
}

/// A speaker card the model is to write.
struct NotesJob: Equatable {
    let documentID: WriterDocument.ID
    let slideID: PresentationSlide.ID
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
        flushEdits()
        endSlideFieldEditing()
        selectedSlideID = id
    }

    /// Back from a text field (or the text area's frame) to the slide's own text.
    func endSlideFieldEditing() {
        if editingSlideFieldID != nil { flushEdits() }
        editingSlideFieldID = nil
        editingSlideTextArea = false
    }

    /// Puts a text field on the slide and opens it for writing.
    func addSlideField(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ field: SlideImage, undoManager: UndoManager?, actionName: String) {
        guard let slide = document(id)?.deck?.slide(slideID) else { return }
        flushEdits()
        setSlideImages(id, slideID, slide.images + [field], undoManager: undoManager, actionName: actionName)
        selectedSlideImageID = field.id
        editingSlideTextArea = false
        editingSlideFieldID = field.id
    }

    /// A free text box on the open slide, opened for writing; several in a row step apart.
    func addTextBoxToOpenSlide(box: WriterBoxKind? = nil) {
        guard let document = selectedPresentation, let slideID = currentSlideID(in: document),
              let slide = document.deck?.slide(slideID) else { return }
        let offset = slide.images.filter(\.isText).count % 5
        let size = box == nil ? CGSize(width: 300, height: 90) : CGSize(width: 280, height: 110)
        let field = SlideImage(text: box.map { "**\($0.label)**\n\n" } ?? "", box: box,
                               frame: SlideImage.defaultTextFrame(width: size.width, height: size.height, offset: offset))
        addSlideField(document.id, slideID, field, undoManager: NSApp.keyWindow?.undoManager, actionName: box == nil ? "Textbox" : "Kasten")
    }

    /// A text field whose text needs more room gets taller (down to the slide's bottom); it never shrinks by itself.
    func growSlideField(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ fieldID: SlideImage.ID, toHeight height: CGFloat) {
        guard let field = document(id)?.deck?.slide(slideID)?.images.first(where: { $0.id == fieldID }) else { return }
        let frame = field.frame
        let target = min(height, SlideImage.canvas.height - frame.minY)
        guard target > frame.height + 0.5 else { return }
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID), let field = deck.slides[index].images.firstIndex(where: { $0.id == fieldID }) else { return false }
            var grown = deck.slides[index].images[field].frame
            grown.size.height = target
            deck.slides[index].images[field].frame = grown
            return true
        }
    }

    /// Moves the slide's own text: nil puts it back inside the standard margins.
    func setSlideTextArea(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ area: SlideArea?, undoManager: UndoManager?) {
        guard let slide = document(id)?.deck?.slide(slideID), slide.textArea != area else { return }
        let old = slide.textArea
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            deck.slides[index].textArea = area
            return true
        }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { app in
            app.setSlideTextArea(id, slideID, old, undoManager: undoManager)
        }
        undoManager.setActionName("Textbereich")
    }

    // MARK: Changing the slides

    /// The presentation's slides as they were at some point, as one step that ⌘Z takes back.
    func restoreDeck(_ id: WriterDocument.ID, _ deck: PresentationDeck, undoManager: UndoManager?, actionName: String) {
        guard let old = document(id)?.deck, old != deck else { return }
        flushEdits()
        modifyDeck(id) { current in
            current = deck
            return true
        }
        if selectedDocumentID == id, let selectedSlideID, deck.index(of: selectedSlideID) == nil { self.selectedSlideID = deck.slides.first?.id }
        undoManager?.registerUndo(withTarget: self) { app in
            app.restoreDeck(id, old, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

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
        ActionHub.shared?.noteDocumentChange(id)
        return true
    }

    /// The editor reports a slide's text as Markdown, or that of one of its text fields (`slideID` is then the field's).
    func updateSlide(_ id: WriterDocument.ID, _ slideID: UUID, markdown: String) {
        modifyDeck(id, saveAfter: .milliseconds(700)) { deck in
            if let index = deck.index(of: slideID) {
                guard deck.slides[index].markdown != markdown else { return false }
                deck.slides[index].markdown = markdown
                return true
            }
            for index in deck.slides.indices {
                guard let field = deck.slides[index].images.firstIndex(where: { $0.id == slideID }) else { continue }
                guard deck.slides[index].images[field].text != markdown else { return false }
                deck.slides[index].images[field].text = markdown
                return true
            }
            return false
        }
    }

    /// A new, empty slide after `slideID` (or at the end); it is opened right away. A `blank` slide shows no hint
    /// where its title goes: a page for pictures and free text fields.
    @discardableResult
    func addSlide(to id: WriterDocument.ID, after slideID: PresentationSlide.ID?, role: SlideRole = .content, markdown: String = "", blank: Bool = false,
                  undoManager: UndoManager? = nil, actionName: String = "Neue Folie") -> PresentationSlide.ID? {
        flushEdits()
        var slide = PresentationSlide(role: role, markdown: markdown)
        slide.hidesPlaceholder = blank
        let index = slideID.flatMap { document(id)?.deck?.index(of: $0) }.map { $0 + 1 } ?? document(id)?.deck?.slides.count ?? 0
        guard insertSlide(slide, at: index, in: id, undoManager: undoManager, actionName: actionName) else { return nil }
        return slide.id
    }

    // MARK: Taking back (⌘Z)
    //
    // The slides' operations register their exact opposite, not the whole presentation from before: the model may be
    // filling slides or writing cards meanwhile, and ⌘Z must not take that away too.

    /// Puts a slide at a place and opens it; ⌘Z takes it out again.
    @discardableResult
    func insertSlide(_ slide: PresentationSlide, at index: Int, in id: WriterDocument.ID, undoManager: UndoManager?, actionName: String) -> Bool {
        flushEdits()
        let inserted = modifyDeck(id) { deck in
            guard deck.index(of: slide.id) == nil else { return false }
            deck.slides.insert(slide, at: min(max(0, index), deck.slides.count))
            return true
        }
        guard inserted else { return false }
        if deletedSlide?.slide.id == slide.id { deletedSlide = nil }
        if selectedDocumentID == id { selectedSlideID = slide.id }
        undoManager?.registerUndo(withTarget: self) { app in
            app.removeSlide(slide.id, from: id, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        return true
    }

    /// Takes a slide out (the last one stays); ⌘Z puts it back where it was. Returns it and its place.
    @discardableResult
    func removeSlide(_ slideID: PresentationSlide.ID, from id: WriterDocument.ID, undoManager: UndoManager?, actionName: String) -> DeletedSlide? {
        flushEdits()
        var removed: DeletedSlide?
        var next: PresentationSlide.ID?
        modifyDeck(id) { deck in
            guard deck.slides.count > 1, let index = deck.index(of: slideID) else { return false }
            removed = DeletedSlide(documentID: id, slide: deck.slides[index], index: index)
            deck.slides.remove(at: index)
            next = deck.slides[min(index, deck.slides.count - 1)].id
            return true
        }
        guard let removed else { return nil }
        if selectedDocumentID == id, selectedSlideID == slideID || selectedSlideID == nil { selectedSlideID = next }
        undoManager?.registerUndo(withTarget: self) { app in
            app.insertSlide(removed.slide, at: removed.index, in: id, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        return removed
    }

    /// Puts a slide at an index of the list as it is afterwards; ⌘Z puts it back.
    private func placeSlide(_ slideID: PresentationSlide.ID, at target: Int, in id: WriterDocument.ID, undoManager: UndoManager?) {
        flushEdits()
        var from: Int?
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID), target != index, deck.slides.indices.contains(target) else { return false }
            from = index
            let slide = deck.slides.remove(at: index)
            deck.slides.insert(slide, at: target)
            return true
        }
        guard let from else { return }
        undoManager?.registerUndo(withTarget: self) { app in
            app.placeSlide(slideID, at: from, in: id, undoManager: undoManager)
        }
        undoManager?.setActionName("Folie verschieben")
    }

    /// Backgrounds as they were or should be: the presentation's per kind of slide and those of single slides; ⌘Z
    /// brings back what was there.
    private func setBackgrounds(_ id: WriterDocument.ID, roles: RoleBackgrounds?, slides: [PresentationSlide.ID: SlideBackground?],
                                undoManager: UndoManager?, actionName: String) {
        guard let deck = document(id)?.deck else { return }
        let oldRoles = deck.backgrounds
        let oldSlides = Dictionary(uniqueKeysWithValues: slides.keys.compactMap { slideID in deck.slide(slideID).map { (slideID, $0.background) } })
        let changed = modifyDeck(id) { deck in
            var changed = false
            if let roles, deck.backgrounds != roles {
                deck.backgrounds = roles
                changed = true
            }
            for (slideID, background) in slides {
                guard let index = deck.index(of: slideID), deck.slides[index].background != background else { continue }
                deck.slides[index].background = background
                changed = true
            }
            return changed
        }
        guard changed else { return }
        undoManager?.registerUndo(withTarget: self) { app in
            app.setBackgrounds(id, roles: roles == nil ? nil : oldRoles, slides: oldSlides, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Shows or hides the hint of an empty slide ("Folientitel"); undoable.
    func setSlidePlaceholderHidden(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ hidden: Bool, undoManager: UndoManager?) {
        guard let current = document(id)?.deck?.slide(slideID), current.hidesPlaceholder != hidden else { return }
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            deck.slides[index].hidesPlaceholder = hidden
            return true
        }
        undoManager?.registerUndo(withTarget: self) { app in
            app.setSlidePlaceholderHidden(id, slideID, !hidden, undoManager: undoManager)
        }
        undoManager?.setActionName(hidden ? "Platzhalter entfernen" : "Platzhalter zeigen")
    }

    func duplicateSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, undoManager: UndoManager? = nil) {
        flushEdits()
        guard let deck = document(id)?.deck, let index = deck.index(of: slideID) else { return }
        var copy = deck.slides[index]
        copy.id = UUID()
        insertSlide(copy, at: index + 1, in: id, undoManager: undoManager, actionName: "Folie duplizieren")
    }

    /// Removes a slide; for a few seconds it can be brought back, and ⌘Z brings it back too. The last slide stays.
    func deleteSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, undoManager: UndoManager? = nil) {
        guard let removed = removeSlide(slideID, from: id, undoManager: undoManager, actionName: "Folie löschen") else { return }
        deletedSlide = removed
        deletedSlideTask?.cancel()
        deletedSlideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.deletedSlide = nil
        }
    }

    func restoreDeletedSlide(undoManager: UndoManager? = nil) {
        guard let deleted = deletedSlide else { return }
        deletedSlide = nil
        insertSlide(deleted.slide, at: deleted.index, in: deleted.documentID, undoManager: undoManager, actionName: "Folie wiederherstellen")
    }

    /// Moves a slide so that it stands at `destination` (an index of the list before the move, as in `onMove`).
    func moveSlide(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, to destination: Int, undoManager: UndoManager? = nil) {
        guard let index = document(id)?.deck?.index(of: slideID) else { return }
        placeSlide(slideID, at: destination > index ? destination - 1 : destination, in: id, undoManager: undoManager)
    }

    func setSlideRole(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ role: SlideRole, undoManager: UndoManager? = nil) {
        flushEdits()
        guard let old = document(id)?.deck?.slide(slideID)?.role, old != role else { return }
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            deck.slides[index].role = role
            return true
        }
        undoManager?.registerUndo(withTarget: self) { app in
            app.setSlideRole(id, slideID, old, undoManager: undoManager)
        }
        undoManager?.setActionName("Art der Folie")
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
    func setSlideBackground(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ background: SlideBackground?, undoManager: UndoManager? = nil) {
        setBackgrounds(id, roles: nil, slides: [slideID: background], undoManager: undoManager, actionName: "Hintergrund der Folie")
    }

    /// The presentation's background for every slide of a kind; slides of that kind with their own lose it.
    func setRoleBackground(_ id: WriterDocument.ID, _ role: SlideRole, _ background: SlideBackground, undoManager: UndoManager? = nil) {
        guard let deck = document(id)?.deck else { return }
        var roles = deck.backgrounds
        roles[role] = background
        let own = deck.slides.filter { $0.role == role && $0.background != nil }.map { ($0.id, SlideBackground?.none) }
        setBackgrounds(id, roles: roles, slides: Dictionary(uniqueKeysWithValues: own), undoManager: undoManager, actionName: "Hintergrund")
    }

    /// The same background for the whole presentation. A design keeps its own look per kind of slide.
    func setPresentationBackground(_ id: WriterDocument.ID, _ background: SlideBackground, undoManager: UndoManager? = nil) {
        guard let deck = document(id)?.deck else { return }
        let own = deck.slides.filter { $0.background != nil }.map { ($0.id, SlideBackground?.none) }
        setBackgrounds(id, roles: .all(background), slides: Dictionary(uniqueKeysWithValues: own), undoManager: undoManager, actionName: "Hintergrund der Präsentation")
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
            throw LLMError.server("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste.")
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
            // Qwen-Image paints any writing the prompt hints at, which would clash with the slide's own text.
            let prompt = PresenterPrompts.textFreeBackgroundPrompt(try ImagePromptBuilder.parse(answer).prompt)
            var info = defaults
            info.description = request.description
            info.prompt = prompt
            info.negativePrompt = PresenterPrompts.backgroundNegativePrompt
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

    /// Lets the model write the speaker notes of these slides. They wait in one queue that a single worker writes
    /// one after the other, so stopping it stops all of them. `first` puts them before the cards that wait (the
    /// presentation needs this one now).
    func writeSpeakerNotes(_ id: WriterDocument.ID, slides slideIDs: [PresentationSlide.ID], first: Bool = false) {
        flushEdits()
        let waiting = slideIDs.filter { !notesWriting.contains($0) }
        for slideID in waiting { notesErrors[slideID] = nil }
        notesWriting.formUnion(waiting)
        if first {
            let queued = Set(notesQueue.map(\.slideID)).intersection(slideIDs)
            notesQueue.removeAll { queued.contains($0.slideID) }
            let front = slideIDs.filter { queued.contains($0) || waiting.contains($0) }
            notesQueue.insert(contentsOf: front.map { NotesJob(documentID: id, slideID: $0) }, at: 0)
        } else {
            notesQueue += waiting.map { NotesJob(documentID: id, slideID: $0) }
        }
        startNotesWorker()
    }

    private func startNotesWorker() {
        guard notesTask == nil, !notesQueue.isEmpty else { return }
        notesWorker += 1
        let number = notesWorker
        notesTask = Task { [weak self] in
            while true {
                guard let self, self.notesWorker == number, !Task.isCancelled, !self.notesQueue.isEmpty else { break }
                let job = self.notesQueue.removeFirst()
                self.notesRunning = job
                do {
                    _ = try await self.generateNotes(job.documentID, job.slideID)
                } catch {
                    if !Task.isCancelled, self.notesWorker == number { self.notesErrors[job.slideID] = error.localizedDescription }
                }
                // A worker that was stopped meanwhile leaves the state to the one after it.
                guard self.notesWorker == number else { return }
                self.notesRunning = nil
                self.notesWriting.remove(job.slideID)
            }
            guard let self, self.notesWorker == number else { return }
            self.notesTask = nil
        }
    }

    /// Stops the model writing cards: the one it writes and all that wait.
    func cancelSpeakerNotes() {
        notesWorker += 1
        notesTask?.cancel()
        notesTask = nil
        notesQueue = []
        notesRunning = nil
        notesWriting = []
    }

    /// Takes these slides' cards out (their slides are gone); the other cards are still written.
    func cancelSpeakerNotes(for slides: Set<PresentationSlide.ID>) {
        notesQueue.removeAll { slides.contains($0.slideID) }
        notesWriting.subtract(slides)
        guard let running = notesRunning, slides.contains(running.slideID) else { return }
        notesWorker += 1
        notesTask?.cancel()
        notesTask = nil
        notesRunning = nil
        startNotesWorker()
    }

    /// Writes one slide's speaker notes and keeps them with the slide. A card that someone changed while the model
    /// wrote (by hand, or an agent) is theirs: it stays, and is what this returns.
    func generateNotes(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID) async throws -> String {
        guard let client, let model = currentModelId else {
            throw LLMError.server("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste.")
        }
        guard let document = document(id), let deck = document.deck, let index = deck.index(of: slideID) else {
            throw CancellationError()
        }
        let before = deck.slides[index].notes
        let answer = try await client.complete(
            model: model,
            messages: PresenterPrompts.notesMessages(deck: deck, title: document.displayTitle, slideIndex: index, source: deckSources[slideID]),
            temperature: 0.7,
            maxTokens: 1500
        )
        // Stopped while the answer came: nothing is written.
        try Task.checkCancellation()
        var notes = PresenterPrompts.cleanNotes(answer)
        if index > 0 { notes = PresenterPrompts.removingCopies(of: deck.slides[index - 1].notes, from: notes) }
        guard !notes.isEmpty else { throw LLMError.server("Das Modell hat keinen Text geliefert.") }
        guard let current = self.document(id)?.deck?.slide(slideID) else { throw CancellationError() }
        guard current.notes == before else { return current.notes }
        replaceNotes(id, slideID, notes, undoManager: MainWindow.window?.undoManager)
        return notes
    }

    /// A card from elsewhere than typing (the model, "Vorherige Karte"): a card that was there is kept for
    /// "Vorherige Karte", and ⌘Z takes it back.
    func replaceNotes(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ notes: String, undoManager: UndoManager?) {
        guard let old = document(id)?.deck?.slide(slideID)?.notes, old != notes else { return }
        setSlideNotes(id, slideID, notes)
        replacedNotes[slideID] = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : old
        undoManager?.registerUndo(withTarget: self) { app in
            app.replaceNotes(id, slideID, old, undoManager: undoManager)
        }
        undoManager?.setActionName("Moderatorenkarte")
    }

    /// Puts back the card the model replaced; a second time brings the model's card back.
    func restoreReplacedNotes(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, undoManager: UndoManager?) {
        guard let previous = replacedNotes[slideID] else { return }
        replaceNotes(id, slideID, previous, undoManager: undoManager)
    }

    /// Every card of the presentation that the model replaced, put back.
    func restoreAllReplacedNotes(_ id: WriterDocument.ID, undoManager: UndoManager?) {
        guard let deck = document(id)?.deck else { return }
        undoManager?.beginUndoGrouping()
        for slide in deck.slides where replacedNotes[slide.id] != nil && !notesWriting.contains(slide.id) {
            restoreReplacedNotes(id, slide.id, undoManager: undoManager)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Vorherige Moderatorenkarten")
    }

    // MARK: Agenda

    /// A slide that lists the chapters (or, without chapters, the slides' titles), after `slideID`.
    func insertAgendaSlide(_ id: WriterDocument.ID, after slideID: PresentationSlide.ID?, undoManager: UndoManager? = nil) {
        flushEdits()
        guard let deck = document(id)?.deck else { return }
        let chapters = deck.slides.filter { $0.role == .chapter }.map(\.title).filter { !$0.isEmpty }
        let items = chapters.isEmpty
            ? deck.slides.filter { $0.role == .content }.map(\.title).filter { !$0.isEmpty }
            : chapters
        let list = items.isEmpty ? "- " : items.map { "- " + $0 }.joined(separator: "\n")
        addSlide(to: id, after: slideID, role: .content, markdown: "# Agenda\n\n" + list, undoManager: undoManager, actionName: "Agenda-Folie")
    }
}

/// Whether a picture is light or dark, so the text on it gets the colour that can be read.
enum SlideImageTone {
    static func tone(of source: String) -> SlideTone {
        guard let url = WriterImageStore.url(for: source), let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .light }
        let side = 16
        guard let pixels = PixelSample.rgba(of: cgImage, side: side) else { return .light }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let hex = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
            total += SlideBackground.luminance(hex)
        }
        return SlideBackground.tone(forLuminance: total / Double(side * side))
    }
}

/// A picture drawn small, to look at its colours.
enum PixelSample {
    /// `side` × `side` pixels, four bytes each (RGBA, premultiplied). The context draws into the array's own memory,
    /// which is only certain to be there inside `withUnsafeMutableBytes` (`&pixels` would hand it over for the
    /// context's creation only).
    static func rgba(of image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}

// MARK: Free pictures

extension AppModel {
    /// The slide's free pictures, replaced as one step that ⌘Z takes back.
    func setSlideImages(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ images: [SlideImage], undoManager: UndoManager?, actionName: String) {
        guard let old = document(id)?.deck?.slide(slideID)?.images, old != images else { return }
        modifyDeck(id) { deck in
            guard let index = deck.index(of: slideID) else { return false }
            deck.slides[index].images = images
            return true
        }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { app in
            app.setSlideImages(id, slideID, old, undoManager: undoManager, actionName: actionName)
            if app.selectedDocumentID == id { app.selectedSlideID = slideID }
        }
        undoManager.setActionName(actionName)
    }

    /// Copies pictures into the library and puts them on the slide: around `center` (a point on the canvas), else
    /// at the right below the title. Returns the new pictures' ids.
    @discardableResult
    func addSlideImages(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, sources: [AttachmentStore.Source], at center: CGPoint?, undoManager: UndoManager?) -> [SlideImage.ID] {
        guard let slide = document(id)?.deck?.slide(slideID) else { return [] }
        var images = slide.images
        var added: [SlideImage.ID] = []
        for source in sources {
            do {
                let stored = try WriterImageStore.importImage(source)
                let size = WriterImageStore.url(for: stored).flatMap(WriterImageStore.naturalSize(of:))
                let aspect = size.map { Double($0.width / max(1, $0.height)) } ?? 1.5
                let image = SlideImage(source: stored, frame: SlideImage.defaultFrame(aspect: aspect, center: center, offset: added.count))
                images.append(image)
                added.append(image.id)
            } catch {
                showNotice(error.localizedDescription)
            }
        }
        setSlideImages(id, slideID, images, undoManager: undoManager, actionName: added.count == 1 ? "Bild einfügen" : "Bilder einfügen")
        return added
    }

    /// A picture Draw Things makes for the slide: its placeholder goes on the slide right away.
    @discardableResult
    func addGeneratedSlideImage(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, info: GeneratedImageInfo, caption: String, generate: Bool, undoManager: UndoManager?) -> SlideImage.ID? {
        guard let slide = document(id)?.deck?.slide(slideID) else { return nil }
        let source = WriterImageStore.newGeneratedSource()
        WriterImageStore.saveGenerationInfo(info, for: source)
        let image = SlideImage(source: source, caption: caption, frame: SlideImage.defaultFrame(aspect: info.format.aspect), generated: true)
        setSlideImages(id, slideID, slide.images + [image], undoManager: undoManager, actionName: generate ? "Bild generieren" : "Bildplatzhalter")
        if generate { imageGeneration.generate(source: source, info: info) }
        return image.id
    }

    /// The sheet's result for a free picture made with Draw Things: a new file (the old one stays for ⌘Z) or only
    /// the kept recipe.
    func updateGeneratedSlideImage(_ id: WriterDocument.ID, _ slideID: PresentationSlide.ID, _ imageID: SlideImage.ID, info: GeneratedImageInfo, caption: String, generate: Bool, undoManager: UndoManager?) {
        guard let slide = document(id)?.deck?.slide(slideID), let index = slide.images.firstIndex(where: { $0.id == imageID }) else { return }
        var images = slide.images
        let old = images[index]
        images[index].caption = caption
        if generate {
            imageGeneration.cancel(old.source)
            var next = info
            let hasPicture = WriterImageStore.url(for: old.source) != nil
            next.previous = hasPicture ? old.source : WriterImageStore.generationInfo(for: old.source)?.previous
            let source = WriterImageStore.newGeneratedSource()
            WriterImageStore.saveGenerationInfo(next, for: source)
            images[index].source = source
            images[index].generated = true
            setSlideImages(id, slideID, images, undoManager: undoManager, actionName: "Bild neu generieren")
            imageGeneration.generate(source: source, info: next)
        } else {
            WriterImageStore.saveGenerationInfo(info, for: old.source)
            setSlideImages(id, slideID, images, undoManager: undoManager, actionName: "Bildbeschreibung")
        }
    }
}
