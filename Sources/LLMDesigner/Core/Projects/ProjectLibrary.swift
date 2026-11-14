import Foundation
import SwiftUI

/// The projects in the library: `Projekte/<id>.json` holds one project as `{"format": 1, "projekt": {…}}`.
struct ProjectStore: Sendable {
    static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func library() -> ProjectStore {
        ProjectStore(directory: AppLibrary.current.folder("Projekte"))
    }

    struct Record: Codable {
        var format = ProjectStore.formatVersion
        var projekt: Project
    }

    func loadAll() -> [Project] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try NoteStore.decoder.decode(Record.self, from: Data(contentsOf: file)).projekt
            } catch {
                print("LLMDesigner: Projekt \(file.lastPathComponent) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    func save(_ project: Project) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NoteStore.encoder.encode(Record(projekt: project)).write(to: recordURL(for: project.id), options: .atomic)
    }

    /// A deleted project goes to the Trash; what it linked to stays untouched.
    func delete(_ id: UUID) {
        let url = recordURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}

/// All projects of the open library, in memory and written back a moment after each change.
///
/// As in Notes and Stories Studio, typed text goes into drafts first and into the project once typing pauses (or right
/// before any other change of it): every change of `projects` makes the sidebar, the page and the board read again.
@MainActor
@Observable
final class ProjectLibrary {
    /// Most recently changed first, as loaded; new projects go to the top. The order doesn't follow later changes, so
    /// the sidebar stays still while the person works on a project.
    private(set) var projects: [Project] = []

    @ObservationIgnored let store: ProjectStore
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    /// Records with a change that isn't on disk yet; Git asks before files of these change from outside.
    var pendingSaveIDs: Set<UUID> { Set(saveTasks.keys) }

    /// Drops a pending save: the version on disk wins (a reload after a change from outside).
    func discardPendingSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
    }
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var drafts: [DraftKey: Draft] = [:]
    @ObservationIgnored private var draftOrder: [DraftKey] = []
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private let writer = DispatchQueue(label: "LLMDesigner.ProjectLibrary.save", qos: .utility)

    private struct DraftKey: Hashable {
        let projectID: UUID
        let field: AnyHashable
    }

    private struct Draft {
        let value: String
        let apply: (inout Project) -> Void
    }

    init(store: ProjectStore) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        projects = store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// The projects that point to this thing anywhere.
    func projects(referring ref: ProjectRef) -> [Project] {
        projects.filter { $0.refers(to: ref) }
    }

    // MARK: Projects

    @discardableResult
    func add(_ project: Project) -> Project {
        loadIfNeeded()
        var project = project
        project.recordHistory()
        projects.insert(project, at: 0)
        scheduleSave(project.id)
        return project
    }

    func restore(_ project: Project) {
        loadIfNeeded()
        guard self.project(project.id) == nil else { return update(project.id) { $0 = project } }
        projects.insert(project, at: 0)
        scheduleSave(project.id)
    }

    func deleteProject(_ id: UUID) {
        discardDrafts(of: id)
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        projects.removeAll { $0.id == id }
        store.delete(id)
    }

    /// The one way to change a project; drafts go in first, the history follows, and it is saved half a second later.
    func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        applyDrafts(of: id, to: &project)
        change(&project)
        guard project != projects[index] else { return }
        project.recordHistory()
        project.updatedAt = Date()
        projects[index] = project
        scheduleSave(id)
    }

    /// A change the person can take back with ⌘Z.
    func change(_ id: UUID, _ label: String, undo undoManager: UndoManager?, _ change: (inout Project) -> Void) {
        commitDrafts(of: id)
        guard let before = project(id) else { return }
        update(id, change)
        guard let after = project(id), after != before else { return }
        registerUndo(undoManager, label: label, restoring: before, over: after)
    }

    private func registerUndo(_ undoManager: UndoManager?, label: String, restoring old: Project, over new: Project) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated {
                library.commitDrafts(of: old.id)
                if library.project(old.id) == nil { library.restore(old) } else { library.update(old.id) { $0 = old } }
                library.registerUndo(undoManager, label: label, restoring: new, over: old)
            }
        }
        undoManager.setActionName(label)
    }

    func delete(_ id: UUID, undo undoManager: UndoManager?) {
        commitDrafts(of: id)
        guard let project = project(id) else { return }
        deleteProject(id)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.restore(project) }
        }
        undoManager.setActionName("Projekt löschen")
    }

    // MARK: Drafts

    /// A binding for a text field of a project: what is typed stays a draft until typing pauses.
    func draftBinding(_ projectID: UUID, field: AnyHashable, get: @escaping (Project) -> String?, set: @escaping (inout Project, String) -> Void) -> Binding<String> {
        let key = DraftKey(projectID: projectID, field: field)
        return Binding(
            get: {
                if let draft = self.drafts[key]?.value { return draft }
                return self.project(projectID).flatMap(get) ?? ""
            },
            set: { value in
                if self.drafts[key] == nil { self.draftOrder.append(key) }
                self.drafts[key] = Draft(value: value) { set(&$0, value) }
                self.scheduleDraftCommit()
            }
        )
    }

    private func scheduleDraftCommit() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: NoteLibrary.draftDelay)
            guard !Task.isCancelled else { return }
            self?.commitDrafts()
        }
    }

    func commitDrafts() {
        draftTask?.cancel()
        draftTask = nil
        for id in Set(draftOrder.map(\.projectID)) { update(id) { _ in } }
    }

    func commitDrafts(of projectID: UUID) {
        guard draftOrder.contains(where: { $0.projectID == projectID }) else { return }
        update(projectID) { _ in }
    }

    private func applyDrafts(of projectID: UUID, to project: inout Project) {
        let keys = draftOrder.filter { $0.projectID == projectID }
        guard !keys.isEmpty else { return }
        for key in keys { drafts[key]?.apply(&project) }
        discardDrafts(of: projectID)
    }

    private func discardDrafts(of projectID: UUID) {
        for key in draftOrder where key.projectID == projectID { drafts[key] = nil }
        draftOrder.removeAll { $0.projectID == projectID }
    }

    // MARK: Saving

    private func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save(id)
        }
    }

    private func save(_ id: UUID, wait: Bool = false) {
        saveTasks[id] = nil
        guard let project = project(id) else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(project)
            } catch {
                print("LLMDesigner: Projekt konnte nicht gespeichert werden: \(error)")
            }
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    func saveAll() {
        commitDrafts()
        for id in Array(saveTasks.keys) {
            saveTasks[id]?.cancel()
            save(id, wait: true)
        }
        writer.sync {}
    }
}
