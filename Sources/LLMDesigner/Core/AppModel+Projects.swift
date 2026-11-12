import SwiftUI

/// The two tabs of a project: its page and its board of tasks.
enum ProjectTab: String, CaseIterable, Identifiable {
    case page, board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: "Projektseite"
        case .board: "Aufgaben"
        }
    }

    var symbol: String {
        switch self {
        case .page: "square.grid.3x2"
        case .board: "rectangle.split.3x1"
        }
    }
}

/// What an action or another studio wants the open project to show.
struct ProjectCommand: Equatable {
    var tab: ProjectTab?
    /// A task whose card opens on the board.
    var task: UUID?
    /// A block the page scrolls to.
    var block: UUID?
}

/// Projects take the main area like the studios. They are listed in the sidebar above the folders; the chats,
/// documents, notes and novel worlds they point to stay where they are and only get a reference.
extension AppModel {
    var openProject: Project? { openProjectID.flatMap { projects.project($0) } }

    func openProject(_ id: UUID, tab: ProjectTab? = nil, task: UUID? = nil) {
        projects.loadIfNeeded()
        guard projects.project(id) != nil else { return }
        if openProjectID != id {
            closeDocument()
            showChats()
            // Notes and novel worlds are shown with their titles and progress.
            notes.loadIfNeeded()
            stories.loadIfNeeded()
            openProjectID = id
        }
        if let tab { projectTab = tab }
        if tab != nil || task != nil { projectCommand = ProjectCommand(tab: tab, task: task) }
    }

    func closeProject() {
        projects.saveAll()
        openProjectID = nil
        projectCommand = nil
    }

    /// A new project with a page to start from, opened at once.
    @discardableResult
    func newProject(title: String = "", linking ref: ProjectRef? = nil, open: Bool = true) -> Project {
        projects.loadIfNeeded()
        var project = Project.starter(title: title)
        project.color = FolderColor.allCases[projects.projects.count % FolderColor.allCases.count]
        if let ref { project.links.append(ref) }
        let made = projects.add(project)
        if open {
            projectTab = .page
            openProject(made.id)
        }
        return made
    }

    // MARK: Linking from the studios

    /// Links a thing to the project as a whole.
    func link(_ ref: ProjectRef, toProject projectID: UUID, undo: UndoManager? = nil) {
        projects.change(projectID, "Mit Projekt verknüpfen", undo: undo) { project in
            if !project.links.contains(ref) { project.links.append(ref) }
        }
    }

    /// Links a thing to one task of the project.
    func link(_ ref: ProjectRef, toTask taskID: UUID, in projectID: UUID, undo: UndoManager? = nil) {
        projects.change(projectID, "Mit Aufgabe verknüpfen", undo: undo) { project in
            project.updateTask(taskID) { if !$0.links.contains(ref) { $0.links.append(ref) } }
        }
    }

    /// Takes the thing out of the project wherever it is linked (the project, its tasks, its to-dos).
    func unlink(_ ref: ProjectRef, fromProject projectID: UUID, undo: UndoManager? = nil) {
        projects.change(projectID, "Verknüpfung lösen", undo: undo) { $0.removeLinkEverywhere(ref) }
    }

    func unlink(_ ref: ProjectRef, fromTask taskID: UUID, in projectID: UUID, undo: UndoManager? = nil) {
        projects.change(projectID, "Verknüpfung lösen", undo: undo) { project in
            project.updateTask(taskID) { $0.links.removeAll { $0 == ref } }
        }
    }

    /// A new task in the project's first column that is not done, linked to the thing.
    @discardableResult
    func newTask(titled title: String, linking ref: ProjectRef? = nil, in projectID: UUID, undo: UndoManager? = nil) -> UUID? {
        guard let project = projects.project(projectID) else { return nil }
        let column = project.columns.first { !$0.isDone }?.id ?? project.columns[0].id
        var task = ProjectTask(title: title, column: column)
        if let ref { task.links = [ref] }
        let made = task
        projects.change(projectID, "Aufgabe anlegen", undo: undo) { $0.tasks.append(made) }
        return made.id
    }

    // MARK: References

    /// Whether the thing a reference points to is still there.
    func projectRefExists(_ ref: ProjectRef) -> Bool {
        projectRefTitle(ref) != nil
    }

    /// The name the person knows it by: a chat's or document's title, "Eisland › Buch 1 › Kapitel 3", "Eisland › Mara".
    /// Nil when it is gone.
    func projectRefTitle(_ ref: ProjectRef) -> String? {
        switch ref {
        case .chat(let id):
            return chat(id)?.title
        case .document(let id):
            return document(id)?.displayTitle
        case .note(let id):
            notes.loadIfNeeded()
            return notes.note(id)?.displayTitle
        case .story(let worldID, let partID, let element):
            stories.loadIfNeeded()
            guard let world = stories.world(worldID) else { return nil }
            if let element {
                guard let name = world.summaries(of: element.kind).first(where: { $0.id == element.id })?.name else { return nil }
                return "\(world.displayTitle) › \(name)"
            }
            guard let partID else { return world.displayTitle }
            guard world.part(partID) != nil else { return nil }
            return ([world.displayTitle] + world.path(to: partID).map { world.displayTitle(of: $0) }).joined(separator: " › ")
        }
    }

    func projectRefSymbol(_ ref: ProjectRef) -> String {
        switch ref {
        case .chat: return "bubble.left"
        case .document(let id): return document(id)?.isPresentation == true ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol
        case .note: return "checklist"
        case .story(let worldID, let partID, let element):
            if let element { return element.kind.symbol }
            guard let partID, let part = stories.world(worldID)?.part(partID) else { return StudioApplication.stories.symbol }
            return part.level.symbol
        }
    }

    /// "Chat", "Dokument", "Präsentation", "Note", "Romanwelt", "Kapitel", "Figur".
    func projectRefKind(_ ref: ProjectRef) -> String {
        switch ref {
        case .chat: return "Chat"
        case .document(let id): return document(id)?.isPresentation == true ? "Präsentation" : "Dokument"
        case .note: return "Note"
        case .story(let worldID, let partID, let element):
            if let element { return element.kind.singular }
            guard let partID, let part = stories.world(worldID)?.part(partID) else { return "Romanwelt" }
            return part.level.label
        }
    }

    /// A short line about its state: a note's progress, a document's words, a chat's messages.
    func projectRefDetail(_ ref: ProjectRef) -> String? {
        switch ref {
        case .chat(let id):
            guard let chat = chat(id) else { return nil }
            return "\(chat.messages.count) Nachrichten"
        case .document(let id):
            guard let document = document(id) else { return nil }
            if let deck = document.deck { return deck.slides.count == 1 ? "1 Folie" : "\(deck.slides.count) Folien" }
            return "geändert \(document.updatedAt.formatted(.relative(presentation: .named)))"
        case .note(let id):
            return notes.note(id)?.progress.label
        case .story:
            return nil
        }
    }

    /// The progress a reference has of its own (a note), for the rings in lists.
    func projectRefProgress(_ ref: ProjectRef) -> NoteProgress? {
        guard case .note(let id) = ref else { return nil }
        return notes.note(id)?.progress
    }

    func openProjectRef(_ ref: ProjectRef) {
        guard projectRefExists(ref) else { return }
        switch ref {
        case .chat(let id): selectChat(id)
        case .document(let id): selectDocument(id)
        case .note(let id): openNotesStudio(showing: id)
        case .story(let worldID, let partID, let element):
            storiesStudioCommand = StoriesStudioCommand(world: worldID, element: element, part: partID)
            openStoriesStudio()
        }
    }

    /// The thing that is open in the main area, as a reference (for "Zu Projekt hinzufügen" in the title bars).
    var openItemRef: ProjectRef? {
        if let id = selectedDocumentID { return .document(id) }
        return nil
    }
}
