import SwiftUI

/// The applications the power access reaches from the right-hand panel.
enum PowerModule: String, CaseIterable, Identifiable {
    case chats, writer, presenter, citation, stories, notes, projects, podcasts, data, research, learning, skills, personas, git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .writer: "Writer"
        case .presenter: "Presenter"
        case .citation: "Citation"
        case .stories: "Stories"
        case .notes: "Notes"
        case .projects: "Projekte"
        case .podcasts: "Podcasts"
        case .data: "Data"
        case .research: "Recherche"
        case .learning: "Lernen"
        case .skills: "Skills"
        case .personas: "Personas"
        case .git: "Git"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .writer: StudioApplication.writer.symbol
        case .presenter: StudioApplication.presenter.symbol
        case .citation: StudioApplication.citation.symbol
        case .stories: StudioApplication.stories.symbol
        case .notes: StudioApplication.notes.symbol
        case .projects: Project.sidebarSymbol
        case .podcasts: StudioApplication.podcast.symbol
        case .data: StudioApplication.data.symbol
        case .research: StudioApplication.research.symbol
        case .learning: StudioApplication.learning.symbol
        case .skills: Skill.defaultSymbol
        case .personas: Persona.symbol
        case .git: "arrow.triangle.branch"
        }
    }
}

/// The power access: in the right-hand panel a small version of every application, next to the one in the main
/// area. Text goes back and forth by dragging; quotes and story elements can be made there.
@MainActor
@Observable
final class PowerAccess {
    var isOn = false
    var module: PowerModule = .writer
    /// The search over the list or in the open item.
    var query = ""
    var documentID: WriterDocument.ID?
    var presentationID: WriterDocument.ID?
    var chatID: Chat.ID?
    var sourceID: UUID?
    var worldID: UUID?
    var noteID: UUID?
    var projectID: UUID?
    var dataBlockID: UUID?
    var researchID: UUID?
    var courseID: UUID?
    var podcastID: UUID?
    var skillID: Skill.ID?
    var personaID: Persona.ID?
    var storyKind: StoryElementKind = .figure
    /// The last change made here, which "Rückgängig" takes back.
    var lastChange: Change?

    struct Change: Identifiable {
        let id = UUID()
        let label: String
        let undo: @MainActor () -> Void
    }

    /// The open item of the current module, if any.
    var hasOpenItem: Bool {
        switch module {
        case .chats: chatID != nil
        case .writer: documentID != nil
        case .presenter: presentationID != nil
        case .citation: sourceID != nil
        case .stories: worldID != nil
        case .notes: noteID != nil
        case .projects: projectID != nil
        case .podcasts: podcastID != nil
        case .data: dataBlockID != nil
        case .research: researchID != nil
        case .learning: courseID != nil
        case .skills: skillID != nil
        case .personas: personaID != nil
        case .git: false
        }
    }

    func closeItem() {
        switch module {
        case .chats: chatID = nil
        case .writer: documentID = nil
        case .presenter: presentationID = nil
        case .citation: sourceID = nil
        case .stories: worldID = nil
        case .notes: noteID = nil
        case .projects: projectID = nil
        case .podcasts: podcastID = nil
        case .data: dataBlockID = nil
        case .research: researchID = nil
        case .learning: courseID = nil
        case .skills: skillID = nil
        case .personas: personaID = nil
        case .git: break
        }
        query = ""
    }
}

extension AppModel {
    /// The panel on the right is wider while it holds the power access.
    var rightPanelWidth: CGFloat {
        if power.isOn { return Theme.powerWidth }
        if selectedDocumentID != nil, documentPanelTab == .notes { return Theme.notesPanelWidth }
        return Theme.outlineWidth
    }

    /// Switches the power access on (showing the panel) or off (back to the contents).
    func togglePower() {
        withAnimation(.smooth(duration: 0.28)) {
            power.isOn.toggle()
        }
        if power.isOn {
            if !isPanelShown { toggleOutlinePanel() }
            citations.loadIfNeeded()
            stories.loadIfNeeded()
            notes.loadIfNeeded()
            podcasts.loadIfNeeded()
        }
    }

    // MARK: Documents

    /// Changes a document's text from the power access. An open editor hands over its typing first and then shows the
    /// new text; the change can be taken back from the panel.
    func powerChangeDocument(_ id: WriterDocument.ID, label: String, _ change: (String) -> String) {
        guard let document = document(id), !document.isPresentation else { return }
        if selectedDocumentID == id { writerFlush?() }
        let old = self.document(id)?.markdown ?? document.markdown
        let new = change(old)
        guard new != old else { return }
        updateDocument(id, markdown: new)
        saveDocument(id)
        power.lastChange = PowerAccess.Change(label: label) { [weak self] in
            guard let self else { return }
            if self.selectedDocumentID == id { self.writerFlush?() }
            self.updateDocument(id, markdown: old)
            self.saveDocument(id)
        }
    }

    func powerInsert(_ markdown: String, into id: WriterDocument.ID, at index: Int) {
        powerChangeDocument(id, label: "Eingefügt") { PowerText.inserting(markdown, at: index, into: $0) }
    }

    /// A new document with this text, opened in the power access.
    @discardableResult
    func powerNewDocument(title: String = "", markdown: String = "") -> WriterDocument.ID {
        var document = WriterDocument()
        document.font = documents.first?.font ?? .serif
        document.markdown = markdown
        if !title.isEmpty {
            document.title = title
            document.hasCustomTitle = true
        } else {
            document.title = WriterDocument.makeTitle(from: markdown)
        }
        documents.insert(document, at: 0)
        saveDocument(document.id)
        power.documentID = document.id
        return document.id
    }

    // MARK: Presentations

    /// Changes a presentation's slides from the power access (undoable from the panel).
    func powerChangeDeck(_ id: WriterDocument.ID, label: String, _ change: (inout PresentationDeck) -> Bool) {
        if selectedDocumentID == id { writerFlush?() }
        guard let old = document(id)?.deck else { return }
        guard modifyDeck(id, change) else { return }
        power.lastChange = PowerAccess.Change(label: label) { [weak self] in
            guard let self else { return }
            if self.selectedDocumentID == id { self.writerFlush?() }
            self.modifyDeck(id) { deck in
                deck = old
                return true
            }
            if let selected = self.selectedSlideID, old.slide(selected) == nil { self.selectedSlideID = old.slides.first?.id }
        }
    }

    /// Text dropped onto a slide goes below its text.
    func powerAppend(_ markdown: String, toSlide slideID: PresentationSlide.ID, in id: WriterDocument.ID) {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        powerChangeDeck(id, label: "Auf die Folie") { deck in
            guard let index = deck.index(of: slideID) else { return false }
            let current = deck.slides[index].markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            deck.slides[index].markdown = current.isEmpty ? text : current + "\n\n" + text
            return true
        }
    }

    /// Text dropped on "Neue Folie": its first line becomes the slide's title, the rest its points.
    func powerNewSlide(_ markdown: String, in id: WriterDocument.ID, after slideID: PresentationSlide.ID?) {
        let slide = PresentationSlide(role: .content, markdown: Self.slideMarkdown(from: markdown))
        powerChangeDeck(id, label: "Neue Folie") { deck in
            let index = slideID.flatMap { deck.index(of: $0) }.map { $0 + 1 } ?? deck.slides.count
            deck.slides.insert(slide, at: index)
            return true
        }
    }

    /// A title line and points from text: a heading stays, a long paragraph stays a paragraph, short lines become points.
    static func slideMarkdown(from markdown: String) -> String {
        let chunks = PowerText.chunks(of: markdown)
        guard let first = chunks.first else { return "" }
        if case .heading = first.kind { return markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lines = PowerText.plain(markdown).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let title = lines.first else { return "" }
        if lines.count == 1, title.count > 90 { return title }
        let rest = lines.dropFirst().map { line -> String in
            let point = line.hasPrefix("• ") ? String(line.dropFirst(2)) : line
            return "- " + point
        }
        return (["# " + title] + (rest.isEmpty ? [] : [""] + rest)).joined(separator: "\n")
    }

    // MARK: Citations

    /// A quote made from dropped or typed text, on a source of Citation Studio.
    @discardableResult
    func powerAddQuote(_ text: String, to sourceID: UUID, page: String = "") -> CitationQuote? {
        let exact = PowerText.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "„“\"”"))
        guard !exact.isEmpty else { return nil }
        var quote = CitationQuote(sourceID: sourceID)
        quote.exactText = exact
        quote.page = page
        guard let added = citations.addQuote(quote) else { return nil }
        power.lastChange = PowerAccess.Change(label: "Zitat angelegt") { [weak self] in
            self?.citations.deleteQuote(added.id)
        }
        return added
    }

    /// A quote for a document: the words in quotation marks with its citation, as Markdown (the editor makes the
    /// citation a pill) and as plain text for other places.
    func powerQuoteText(_ quote: CitationQuote) -> (markdown: String, plain: String) {
        guard let source = citations.source(quote.sourceID) else { return (quote.exactText, quote.exactText) }
        let item = CitationItem(key: source.citekey, locator: quote.locator)
        let words = quote.exactText.isEmpty ? quote.paraphrase : "„" + quote.exactText + "“"
        let style = CitationStyle(sources: [source], cited: [source.citekey])
        let markdown = words + " " + CitationMarkup.markdown([item])
        return (markdown, words + " " + style.inText([item]))
    }

    // MARK: Stories

    /// A story element named after the first line of the text; the rest goes into its main field.
    @discardableResult
    func powerAddStoryElement(_ kind: StoryElementKind, text: String, in worldID: UUID) -> UUID? {
        let lines = PowerText.plain(text).components(separatedBy: "\n")
        let name = String((lines.first ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var added: UUID?
        stories.update(worldID) { world in
            let ref = world.addElement(kind, name: name)
            added = ref.id
            if !body.isEmpty { Self.setStoryText(body, of: ref, in: &world) }
        }
        if let added {
            power.lastChange = PowerAccess.Change(label: "\(kind.singular) angelegt") { [weak self] in
                self?.stories.update(worldID) { world in Self.removeStoryElement(StoryRef(kind: kind, id: added), from: &world) }
            }
        }
        return added
    }

    /// The field the power access shows and fills for each kind of element.
    static func storyText(of ref: StoryRef, in world: StoryWorld) -> String {
        switch ref.kind {
        case .figure: world.figures.first { $0.id == ref.id }?.biography ?? ""
        case .place: world.places.first { $0.id == ref.id }?.atmosphere ?? ""
        case .event: world.events.first { $0.id == ref.id }?.course ?? ""
        case .reason: world.reasons.first { $0.id == ref.id }?.conclusion ?? ""
        case .purpose: world.purposes.first { $0.id == ref.id }?.intent ?? ""
        case .species: world.species.first { $0.id == ref.id }?.appearance ?? ""
        case .fact: world.facts.first { $0.id == ref.id }?.text ?? ""
        }
    }

    static func storyTextLabel(_ kind: StoryElementKind) -> String {
        switch kind {
        case .figure: "Biografie"
        case .place: "Atmosphäre"
        case .event: "Verlauf"
        case .reason: "Schluss"
        case .purpose: "Absicht"
        case .species: "Gestalt"
        case .fact: "Notiz"
        }
    }

    static func setStoryText(_ text: String, of ref: StoryRef, in world: inout StoryWorld) {
        switch ref.kind {
        case .figure: if let i = world.figures.firstIndex(where: { $0.id == ref.id }) { world.figures[i].biography = text; world.figures[i].updatedAt = Date() }
        case .place: if let i = world.places.firstIndex(where: { $0.id == ref.id }) { world.places[i].atmosphere = text; world.places[i].updatedAt = Date() }
        case .event: if let i = world.events.firstIndex(where: { $0.id == ref.id }) { world.events[i].course = text; world.events[i].updatedAt = Date() }
        case .reason: if let i = world.reasons.firstIndex(where: { $0.id == ref.id }) { world.reasons[i].conclusion = text; world.reasons[i].updatedAt = Date() }
        case .purpose: if let i = world.purposes.firstIndex(where: { $0.id == ref.id }) { world.purposes[i].intent = text; world.purposes[i].updatedAt = Date() }
        case .species: if let i = world.species.firstIndex(where: { $0.id == ref.id }) { world.species[i].appearance = text; world.species[i].updatedAt = Date() }
        case .fact: if let i = world.facts.firstIndex(where: { $0.id == ref.id }) { world.facts[i].text = text; world.facts[i].updatedAt = Date() }
        }
    }

    static func removeStoryElement(_ ref: StoryRef, from world: inout StoryWorld) {
        switch ref.kind {
        case .figure: world.figures.removeAll { $0.id == ref.id }
        case .place: world.places.removeAll { $0.id == ref.id }
        case .event: world.events.removeAll { $0.id == ref.id }
        case .reason: world.reasons.removeAll { $0.id == ref.id }
        case .purpose: world.purposes.removeAll { $0.id == ref.id }
        case .species: world.species.removeAll { $0.id == ref.id }
        case .fact: world.facts.removeAll { $0.id == ref.id }
        }
    }

    /// The elements of one kind as name, line below and main text, in the world's order.
    static func storyItems(_ kind: StoryElementKind, in world: StoryWorld) -> [(ref: StoryRef, name: String, subtitle: String, text: String)] {
        func items<E: StoryElement>(_ elements: [E]) -> [(ref: StoryRef, name: String, subtitle: String, text: String)] {
            elements.map { ($0.ref, $0.displayName, $0.subtitle, storyText(of: $0.ref, in: world)) }
        }
        switch kind {
        case .figure: return items(world.figures)
        case .place: return items(world.places)
        case .event: return items(world.events)
        case .reason: return items(world.reasons)
        case .purpose: return items(world.purposes)
        case .species: return items(world.species)
        case .fact: return items(world.facts)
        }
    }
}
