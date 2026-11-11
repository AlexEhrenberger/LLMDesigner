import Foundation
import SwiftUI

/// The notes in the library: `Notizen/<id>.json` holds one note as `{"format": 1, "note": {…}}`.
struct NoteStore: Sendable {
    static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store of the open library.
    static func library() -> NoteStore {
        NoteStore(directory: AppLibrary.current.folder("Notizen"))
    }

    struct Record: Codable {
        var format = NoteStore.formatVersion
        var note: Note
    }

    func loadAll() -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try Self.decoder.decode(Record.self, from: Data(contentsOf: file)).note
            } catch {
                print("LLMDesigner: Note \(file.lastPathComponent) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    func save(_ note: Note) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(Record(note: note)).write(to: recordURL(for: note.id), options: .atomic)
    }

    /// A deleted note goes to the Trash, so it can still be brought back.
    func delete(_ id: UUID) {
        let url = recordURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// All notes of the open library, kept in memory and written back a moment after each change.
///
/// Typed text goes into drafts first, as in Stories Studio: every change of `notes` makes the lists, the open note and
/// the panels read again, which is too much on each keystroke. The text field keeps what was typed as a draft, and the
/// drafts go into their notes together once typing pauses, or right before any other change of the note.
@MainActor
@Observable
final class NoteLibrary {
    /// Most recently changed first, as loaded; new notes go to the top.
    private(set) var notes: [Note] = []

    @ObservationIgnored let store: NoteStore
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var drafts: [DraftKey: Draft] = [:]
    @ObservationIgnored private var draftOrder: [DraftKey] = []
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private let writer = DispatchQueue(label: "LLMDesigner.NoteLibrary.save", qos: .utility)

    static let draftDelay: Duration = .milliseconds(350)

    private struct DraftKey: Hashable {
        let noteID: UUID
        let field: AnyHashable
    }

    private struct Draft {
        let value: String
        let apply: (inout Note) -> Void
    }

    init(store: NoteStore) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        notes = store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    /// The notes that belong to a document, a novel world or one of its parts, oldest first (the order they were made).
    func notes(for owner: NoteOwner) -> [Note] {
        notes.filter { $0.belongs(to: owner) }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Notes

    @discardableResult
    func addNote(title: String = "", style: NoteProgressStyle = .bar, owners: [NoteOwner] = [], todos: [NoteTodo] = []) -> Note {
        loadIfNeeded()
        var note = Note(title: title, style: style, owners: owners)
        note.todos = todos
        notes.insert(note, at: 0)
        scheduleSave(note.id)
        return note
    }

    /// Puts a note back as it was (undo of a deletion), at the top.
    func restore(_ note: Note) {
        loadIfNeeded()
        guard self.note(note.id) == nil else { return update(note.id) { $0 = note } }
        notes.insert(note, at: 0)
        scheduleSave(note.id)
    }

    func deleteNote(_ id: UUID) {
        discardDrafts(of: id)
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        notes.removeAll { $0.id == id }
        store.delete(id)
    }

    /// The one way to change a note; it is saved half a second after the last change. Drafts of the note go in first,
    /// and a parent's done state is brought in line with its to-dos afterwards.
    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        applyDrafts(of: id, to: &note)
        change(&note)
        note.todos.normalize()
        guard note != notes[index] else { return }
        note.updatedAt = Date()
        notes[index] = note
        scheduleSave(id)
    }

    /// A change the person can take back with ⌘Z: the note as it was before is kept with the window's undo manager.
    func change(_ id: UUID, _ label: String, undo undoManager: UndoManager?, _ change: (inout Note) -> Void) {
        commitDrafts(of: id)
        guard let before = note(id) else { return }
        update(id, change)
        guard let after = note(id), after != before else { return }
        registerUndo(undoManager, label: label, restoring: before, over: after)
    }

    private func registerUndo(_ undoManager: UndoManager?, label: String, restoring old: Note, over new: Note) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated {
                library.commitDrafts(of: old.id)
                if library.note(old.id) == nil { library.restore(old) } else { library.update(old.id) { $0 = old } }
                library.registerUndo(undoManager, label: label, restoring: new, over: old)
            }
        }
        undoManager.setActionName(label)
    }

    /// Deleting with ⌘Z to bring it back.
    func delete(_ id: UUID, undo undoManager: UndoManager?) {
        commitDrafts(of: id)
        guard let note = note(id) else { return }
        deleteNote(id)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.restore(note) }
        }
        undoManager.setActionName("Note löschen")
    }

    // MARK: Drafts

    /// A binding for a text field of a note: what is typed stays a draft until typing pauses.
    /// `field` names the field within the note (a key path, or a to-do's id).
    func draftBinding(_ noteID: UUID, field: AnyHashable, get: @escaping (Note) -> String?, set: @escaping (inout Note, String) -> Void) -> Binding<String> {
        let key = DraftKey(noteID: noteID, field: field)
        return Binding(
            get: {
                if let draft = self.drafts[key]?.value { return draft }
                return self.note(noteID).flatMap(get) ?? ""
            },
            set: { value in
                if self.drafts[key] == nil { self.draftOrder.append(key) }
                self.drafts[key] = Draft(value: value) { set(&$0, value) }
                self.scheduleDraftCommit()
            }
        )
    }

    func titleBinding(_ noteID: UUID) -> Binding<String> {
        draftBinding(noteID, field: "titel", get: { $0.title }, set: { $0.title = $1 })
    }

    func textBinding(_ noteID: UUID) -> Binding<String> {
        draftBinding(noteID, field: "text", get: { $0.text }, set: { $0.text = $1 })
    }

    func todoBinding(_ noteID: UUID, _ todoID: UUID) -> Binding<String> {
        draftBinding(noteID, field: todoID, get: { $0.todo(todoID)?.text }, set: { note, text in note.updateTodo(todoID) { $0.text = text } })
    }

    private func scheduleDraftCommit() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: NoteLibrary.draftDelay)
            guard !Task.isCancelled else { return }
            self?.commitDrafts()
        }
    }

    /// Puts every draft into its note now.
    func commitDrafts() {
        draftTask?.cancel()
        draftTask = nil
        for id in Set(draftOrder.map(\.noteID)) { update(id) { _ in } }
    }

    func commitDrafts(of noteID: UUID) {
        guard draftOrder.contains(where: { $0.noteID == noteID }) else { return }
        update(noteID) { _ in }
    }

    private func applyDrafts(of noteID: UUID, to note: inout Note) {
        let keys = draftOrder.filter { $0.noteID == noteID }
        guard !keys.isEmpty else { return }
        for key in keys { drafts[key]?.apply(&note) }
        discardDrafts(of: noteID)
    }

    private func discardDrafts(of noteID: UUID) {
        for key in draftOrder where key.noteID == noteID { drafts[key] = nil }
        draftOrder.removeAll { $0.noteID == noteID }
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
        guard let note = note(id) else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(note)
            } catch {
                print("LLMDesigner: Note konnte nicht gespeichert werden: \(error)")
            }
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    /// Writes what is still waiting, drafts included (leaving the studio, switching libraries, quitting).
    func saveAll() {
        commitDrafts()
        for id in Array(saveTasks.keys) {
            saveTasks[id]?.cancel()
            save(id, wait: true)
        }
        writer.sync {}
    }
}
