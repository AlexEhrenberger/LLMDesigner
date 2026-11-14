import Foundation

/// Something the new studios keep one file of: Data Studio's blocks and templates, Rechercherista's researches,
/// Learning Studio's courses.
protocol StoredRecord: Codable, Identifiable, Hashable, Sendable where ID == UUID {
    var updatedAt: Date { get set }
}

/// One JSON file per record, `{"format": 1, "<root>": {…}}`, either as `<folder>/<id>.json` or, when a record has
/// files of its own (a logo, PDFs), as `<folder>/<id>/<file>.json`. Same coders as Notes and Projects.
struct RecordStore<Record: StoredRecord>: Sendable {
    enum Layout: Sendable {
        /// `<id>.json`
        case file
        /// `<id>/<name>.json`, next to the record's own files.
        case folder(String)
    }

    let directory: URL
    let root: String
    let layout: Layout
    let format: Int

    init(directory: URL, root: String, layout: Layout = .file, format: Int = 1) {
        self.directory = directory
        self.root = root
        self.layout = layout
        self.format = format
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Envelope: Codable {
        static var rootInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "llmd.root")! }
        var format: Int
        var record: Record

        init(format: Int, record: Record) {
            self.format = format
            self.record = record
        }

        init(from decoder: Decoder) throws {
            let root = decoder.userInfo[Self.rootInfo] as? String ?? "record"
            let c = try decoder.container(keyedBy: Key.self)
            format = (try? c.decode(Int.self, forKey: Key("format"))) ?? 1
            record = try c.decode(Record.self, forKey: Key(root))
        }

        func encode(to encoder: Encoder) throws {
            let root = encoder.userInfo[Self.rootInfo] as? String ?? "record"
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(format, forKey: Key("format"))
            try c.encode(record, forKey: Key(root))
        }
    }

    func loadAll() -> [Record] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let files: [URL]
        switch layout {
        case .file:
            files = entries.filter { $0.pathExtension == "json" }
        case .folder(let name):
            files = entries.map { $0.appendingPathComponent("\(name).json") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return files.compactMap { file in
            do {
                return try decode(Data(contentsOf: file))
            } catch {
                print("LLMDesigner: \(file.path) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    func decode(_ data: Data) throws -> Record {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[Envelope.rootInfo] = root
        return try decoder.decode(Envelope.self, from: data).record
    }

    func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[Envelope.rootInfo] = root
        return try encoder.encode(Envelope(format: format, record: record))
    }

    func save(_ record: Record) throws {
        let url = recordURL(for: record.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(record).write(to: url, options: .atomic)
    }

    /// A deleted record goes to the Trash with its own files, so it can still be brought back.
    func delete(_ id: UUID) {
        let url: URL
        switch layout {
        case .file: url = recordURL(for: id)
        case .folder: url = folder(of: id)
        }
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    func recordURL(for id: UUID) -> URL {
        switch layout {
        case .file: directory.appendingPathComponent("\(id.uuidString).json")
        case .folder(let name): folder(of: id).appendingPathComponent("\(name).json")
        }
    }

    /// The record's own folder (only with `.folder`).
    func folder(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

/// The records of one kind in the open library: in memory, written back half a second after a change. Simpler than
/// the Notes library: the studios that use it have short texts, so a keystroke may change the record directly.
@MainActor
@Observable
final class RecordLibrary<Record: StoredRecord> {
    private(set) var records: [Record] = []
    /// Counts every change, for views that only need to know that something changed (the Writer's data fields).
    private(set) var revision = 0

    @ObservationIgnored let store: RecordStore<Record>
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    /// Records with a change that isn't on disk yet; Git asks before files of these change from outside.
    var pendingSaveIDs: Set<UUID> { Set(saveTasks.keys) }

    /// Drops a pending save: the version on disk wins (a reload after a change from outside).
    func discardPendingSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
    }
    @ObservationIgnored private let writer: DispatchQueue
    /// Called after every change (the studio's resolver takes it over).
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: RecordStore<Record>) {
        self.store = store
        writer = DispatchQueue(label: "LLMDesigner.RecordLibrary.\(store.root)", qos: .utility)
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        records = store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
        revision += 1
        onChange?()
    }

    func record(_ id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    @discardableResult
    func add(_ record: Record, at index: Int = 0) -> Record {
        loadIfNeeded()
        records.insert(record, at: min(index, records.count))
        changed(record.id)
        return record
    }

    /// Puts a record back (undo of a delete) or replaces it.
    func restore(_ record: Record) {
        loadIfNeeded()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        changed(record.id)
    }

    /// The one way to change a record. `touch` false keeps its date (progress of a running job).
    func update(_ id: UUID, touch: Bool = true, _ change: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        guard record != records[index] else { return }
        if touch { record.updatedAt = Date() }
        records[index] = record
        changed(id)
    }

    /// A change the person can take back with ⌘Z.
    func change(_ id: UUID, _ label: String, undo undoManager: UndoManager?, _ change: (inout Record) -> Void) {
        guard let before = record(id) else { return }
        update(id, change)
        guard let after = record(id), after != before else { return }
        registerUndo(undoManager, label: label, restoring: before, over: after)
    }

    private func registerUndo(_ undoManager: UndoManager?, label: String, restoring old: Record, over new: Record) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated {
                library.restore(old)
                library.registerUndo(undoManager, label: label, restoring: new, over: old)
            }
        }
        undoManager.setActionName(label)
    }

    func remove(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        records.removeAll { $0.id == id }
        store.delete(id)
        revision += 1
        onChange?()
    }

    func delete(_ id: UUID, label: String, undo undoManager: UndoManager?) {
        guard let record = record(id) else { return }
        remove(id)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.restore(record) }
        }
        undoManager.setActionName(label)
    }

    func move(_ id: UUID, to index: Int) {
        guard let from = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: from)
        records.insert(record, at: max(0, min(index, records.count)))
        revision += 1
    }

    private func changed(_ id: UUID) {
        revision += 1
        onChange?()
        scheduleSave(id)
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
        guard let record = record(id) else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(record)
            } catch {
                print("LLMDesigner: \(store.root) konnte nicht gespeichert werden: \(error)")
            }
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    func saveNow(_ id: UUID) {
        saveTasks[id]?.cancel()
        save(id, wait: true)
    }

    func saveAll() {
        for id in Array(saveTasks.keys) {
            saveTasks[id]?.cancel()
            save(id, wait: true)
        }
        writer.sync {}
    }
}

extension KeyedDecodingContainer {
    /// A value that may be missing or malformed in a file written by hand or by an older version.
    func soft<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
