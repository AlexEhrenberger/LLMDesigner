import AppKit

/// The model writing out a handout's slides, shown in Writer Studio above the assistant bar.
struct HandoutGeneration: Equatable {
    enum Phase: Equatable {
        case writing(done: Int, total: Int)
        case finished(skipped: Int)
        case stopped
        case failed(String)
    }

    let documentID: WriterDocument.ID
    var phase: Phase

    var isRunning: Bool {
        if case .writing = phase { return true }
        return false
    }
}

/// Presenter Studio's way out: the slides as a PDF, and the presentation as a document in Writer Studio.
extension AppModel {
    // MARK: PDF

    /// Saves the slides as a PDF, one page per slide, laid out as they are shown.
    func exportPresentationPDF(_ id: WriterDocument.ID) {
        writerFlush?()
        guard let document = document(id), let deck = document.deck, !exportingIDs.contains(id) else { return }
        exportingIDs.insert(id)
        Task {
            citations.loadIfNeeded()
            let data = await SlidePrinter.pdf(deck: deck, title: document.displayTitle, family: document.font, citations: citations)
            exportingIDs.remove(id)
            guard let data else {
                exportError = "Die Folien ließen sich nicht als PDF zeichnen."
                return
            }
            guard let url = await askForDestination(fileName: document.displayTitle, type: .pdf) else { return }
            do {
                try data.write(to: url, options: .atomic)
                if pdfOpenAfterExport { NSWorkspace.shared.open(url) }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: Handout

    /// Makes a Writer Studio document from the presentation and opens it. With `expand`, the model then writes the
    /// slides' points out one after the other; the document can be read (and edited) meanwhile.
    func createHandout(from id: WriterDocument.ID, options: HandoutOptions) async {
        writerFlush?()
        guard let presentation = document(id), let deck = presentation.deck else { return }
        var pictures: [PresentationSlide.ID: String] = [:]
        if options.slidePictures {
            citations.loadIfNeeded()
            for slide in deck.slides {
                guard let data = await SlidePrinter.png(slide: slide, in: deck, family: presentation.font, citations: citations),
                      let source = try? WriterImageStore.importImage(.data(data)) else { continue }
                pictures[slide.id] = source
            }
        }
        let built = HandoutBuilder.build(deck: deck, options: options, slidePictures: pictures)

        var handout = WriterDocument()
        handout.folderID = presentation.folderID
        handout.font = documents.first { !$0.isPresentation }?.font ?? .serif
        handout.markdown = built.markdown
        handout.title = presentation.displayTitle + " – Handout"
        handout.hasCustomTitle = true
        handout.tocMode = .headings
        documents.insert(handout, at: 0)
        saveDocument(handout.id)
        selectDocument(handout.id)

        guard options.expand, !built.sections.isEmpty else { return }
        expandHandout(handout.id, sections: built.sections, presentationTitle: presentation.displayTitle, length: options.length)
    }

    /// The model writes each section's points out as continuous text and puts it in their place.
    func expandHandout(_ id: WriterDocument.ID, sections: [HandoutSection], presentationTitle: String, length: HandoutLength) {
        handoutTask?.cancel()
        guard let client, let model = currentModelId else {
            handoutGeneration = HandoutGeneration(documentID: id, phase: .failed("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste."))
            return
        }
        handoutGeneration = HandoutGeneration(documentID: id, phase: .writing(done: 0, total: sections.count))
        handoutTask = Task { [weak self] in
            var skipped = 0
            for (index, section) in sections.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.handoutGeneration?.phase = .writing(done: index, total: sections.count)
                do {
                    let answer = try await client.complete(
                        model: model,
                        messages: HandoutPrompts.messages(
                            for: section, presentationTitle: presentationTitle,
                            previous: index > 0 ? sections[index - 1].title : nil,
                            next: index + 1 < sections.count ? sections[index + 1].title : nil,
                            length: length
                        ),
                        temperature: 0.6,
                        maxTokens: length.maxTokens
                    )
                    guard !Task.isCancelled else { break }
                    let text = HandoutPrompts.clean(answer, title: section.title)
                    guard !text.isEmpty else { skipped += 1; continue }
                    // What the user typed meanwhile is handed over first, so it isn't lost.
                    self.writerFlush?()
                    guard let document = self.document(id),
                          let markdown = HandoutBuilder.replacing(section, with: text, in: document.markdown) else { skipped += 1; continue }
                    self.updateDocument(id, markdown: markdown)
                } catch {
                    if Task.isCancelled { break }
                    self.handoutGeneration?.phase = .failed(error.localizedDescription)
                    return
                }
            }
            guard let self else { return }
            self.handoutGeneration?.phase = Task.isCancelled ? .stopped : .finished(skipped: skipped)
        }
    }

    func stopHandoutGeneration() {
        handoutTask?.cancel()
        handoutTask = nil
        if handoutGeneration?.isRunning == true { handoutGeneration?.phase = .stopped }
    }
}
