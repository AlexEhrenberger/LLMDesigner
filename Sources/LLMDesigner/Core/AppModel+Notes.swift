import SwiftUI

/// What an action or another studio wants the Notes studio to show.
struct NotesStudioCommand: Equatable {
    var note: UUID?
    /// A to-do whose text field should take the keyboard.
    var focusTodo: UUID?
}

/// The Notes studio takes the main area like Stories Studio; documents, presentations and novel worlds keep the notes
/// that belong to them in their own panels.
extension AppModel {
    static let notesDefaultStyleKey = "notesDefaultStyle"
    static let notesLastNoteKey = "notesLastNote"

    func openNotesStudio(showing noteID: UUID? = nil) {
        closeDocument()
        showChats()
        notes.loadIfNeeded()
        if let noteID { notesStudioCommand = NotesStudioCommand(note: noteID) }
        notesStudioOpen = true
    }

    func closeNotesStudio() {
        notes.saveAll()
        notesStudioOpen = false
    }

    /// The display new notes start with: the one chosen last.
    var defaultNoteStyle: NoteProgressStyle {
        get { settings.string(forKey: Self.notesDefaultStyleKey).flatMap(NoteProgressStyle.init(rawValue:)) ?? .bar }
        set { settings.set(newValue.rawValue, forKey: Self.notesDefaultStyleKey) }
    }

    /// A new note, belonging to `owner` if given; its title follows the owner ("Bachelorarbeit").
    @discardableResult
    func newNote(title: String? = nil, for owner: NoteOwner? = nil, todos: [NoteTodo] = []) -> Note {
        let title = title ?? owner.flatMap { noteOwnerTitle($0) } ?? ""
        return notes.addNote(title: title, style: defaultNoteStyle, owners: owner.map { [$0] } ?? [], todos: todos)
    }

    /// Links a note to a document, a novel world or a part; the owner itself stays as it is.
    func attachNote(_ noteID: UUID, to owner: NoteOwner, undo: UndoManager? = nil) {
        notes.change(noteID, "Note zuordnen", undo: undo) { note in
            if !note.owners.contains(owner) { note.owners.append(owner) }
        }
    }

    func detachNote(_ noteID: UUID, from owner: NoteOwner, undo: UndoManager? = nil) {
        notes.change(noteID, "Zuordnung lösen", undo: undo) { $0.owners.removeAll { $0 == owner } }
    }

    // MARK: Owners

    /// The owner's name as the person sees it: a document's title, "Eisland › Buch 1 › Kapitel 3". Nil if it is gone.
    func noteOwnerTitle(_ owner: NoteOwner) -> String? {
        switch owner {
        case .document(let id):
            return document(id)?.displayTitle
        case .story(let worldID, let partID):
            stories.loadIfNeeded()
            guard let world = stories.world(worldID) else { return nil }
            guard let partID else { return world.displayTitle }
            guard world.part(partID) != nil else { return nil }
            return ([world.displayTitle] + world.path(to: partID).map { world.displayTitle(of: $0) }).joined(separator: " › ")
        }
    }

    /// Short: the document's or the part's own name.
    func noteOwnerShortTitle(_ owner: NoteOwner) -> String? {
        switch owner {
        case .document(let id):
            return document(id)?.displayTitle
        case .story(let worldID, let partID):
            guard let world = stories.world(worldID) else { return nil }
            guard let partID else { return world.displayTitle }
            return world.part(partID).map { world.displayTitle(of: $0) }
        }
    }

    func noteOwnerSymbol(_ owner: NoteOwner) -> String {
        switch owner {
        case .document(let id):
            return document(id)?.isPresentation == true ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol
        case .story(let worldID, let partID):
            guard let partID, let part = stories.world(worldID)?.part(partID) else { return StudioApplication.stories.symbol }
            return part.level.symbol
        }
    }

    /// What kind of thing it is, for hints: "Dokument", "Präsentation", "Kapitel".
    func noteOwnerKind(_ owner: NoteOwner) -> String {
        switch owner {
        case .document(let id):
            return document(id)?.isPresentation == true ? "Präsentation" : "Dokument"
        case .story(let worldID, let partID):
            guard let partID, let part = stories.world(worldID)?.part(partID) else { return "Romanwelt" }
            return part.level.label
        }
    }

    /// Opens what a note belongs to: the document, or the world or part in Stories Studio.
    func openNoteOwner(_ owner: NoteOwner) {
        switch owner {
        case .document(let id):
            guard document(id) != nil else { return }
            selectDocument(id)
        case .story(let worldID, let partID):
            guard stories.world(worldID) != nil else { return }
            storiesStudioCommand = StoriesStudioCommand(world: worldID, element: nil, part: partID)
            openStoriesStudio()
        }
    }

    // MARK: To-dos linked to documents

    /// A presentation whose title slide carries the title, saved at once (a note links to it before it is opened).
    func createPresentation(titled title: String, provenance: DocumentProvenance? = nil) -> WriterDocument {
        var document = WriterDocument.newPresentation()
        document.title = title
        document.hasCustomTitle = true
        if var deck = document.deck, !deck.slides.isEmpty {
            deck.slides[0].markdown = "# \(AppModel.slideLine(title)) {.chapter}"
            document.deck = deck
        }
        document.provenance = provenance
        reinsertDocumentForActionRedo(document)
        return document
    }

    /// A new Writer document or presentation for a to-do, named after it and linked to it.
    @discardableResult
    func newDocument(forTodo todoID: UUID, in noteID: UUID, presentation: Bool, undo: UndoManager? = nil) -> WriterDocument? {
        guard let todo = notes.note(noteID)?.todo(todoID) else { return nil }
        let text = notes.todoBinding(noteID, todoID).wrappedValue.trimmingCharacters(in: .whitespaces)
        let title = text.isEmpty ? (todo.text.isEmpty ? (presentation ? "Neue Präsentation" : "Neues Dokument") : todo.text) : text
        let document = presentation
            ? createPresentation(titled: title)
            : createDocumentForAction(title: title, folderID: nil, markdown: "# " + WriterMarkdown.escape(title, atLineStart: false) + "\n", provenance: nil)
        linkDocument(document.id, toTodo: todoID, in: noteID, undo: undo)
        return document
    }

    func linkDocument(_ documentID: UUID, toTodo todoID: UUID, in noteID: UUID, undo: UndoManager? = nil) {
        notes.change(noteID, "Dokument verknüpfen", undo: undo) { note in
            note.updateTodo(todoID) { if !$0.documents.contains(documentID) { $0.documents.append(documentID) } }
        }
    }

    func unlinkDocument(_ documentID: UUID, fromTodo todoID: UUID, in noteID: UUID, undo: UndoManager? = nil) {
        notes.change(noteID, "Verknüpfung lösen", undo: undo) { note in
            note.updateTodo(todoID) { $0.documents.removeAll { $0 == documentID } }
        }
    }
}
