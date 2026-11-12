import Foundation

/// The podcasts in the library: `Podcasts/<id>/podcast.json` as `{"format": 1, "podcast": {…}}`, next to it the spoken
/// lines in `Schnipsel/<line id>.wav` and the finished `Podcast.m4a`.
struct PodcastStore: Sendable {
    static let formatVersion = 1
    static let recordName = "podcast.json"
    static let audioName = "Podcast.m4a"
    static let snippetFolder = "Schnipsel"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func library() -> PodcastStore {
        PodcastStore(directory: AppLibrary.current.folder("Podcasts"))
    }

    struct Record: Codable {
        var format = PodcastStore.formatVersion
        var podcast: Podcast
    }

    func folder(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func recordURL(of id: UUID) -> URL {
        folder(of: id).appendingPathComponent(Self.recordName)
    }

    func audioURL(of id: UUID) -> URL {
        folder(of: id).appendingPathComponent(Self.audioName)
    }

    func snippetURL(of podcastID: UUID, line lineID: UUID) -> URL {
        folder(of: podcastID).appendingPathComponent(Self.snippetFolder, isDirectory: true).appendingPathComponent("\(lineID.uuidString).wav")
    }

    func loadAll() -> [Podcast] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent(Self.recordName)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                return try Self.decoder.decode(Record.self, from: Data(contentsOf: file)).podcast
            } catch {
                print("LLMDesigner: Podcast \(folder.lastPathComponent) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    func save(_ podcast: Podcast) throws {
        try FileManager.default.createDirectory(at: folder(of: podcast.id), withIntermediateDirectories: true)
        try Self.encoder.encode(Record(podcast: podcast)).write(to: recordURL(of: podcast.id), options: .atomic)
    }

    /// The whole folder goes to the Trash, audio included; returns where it went, to bring it back.
    @discardableResult
    func delete(_ id: UUID) -> URL? {
        let url = folder(of: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var trashed: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Brings a folder back from the Trash.
    func restore(_ id: UUID, from trashed: URL) {
        let url = folder(of: id)
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: trashed.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: trashed, to: url)
    }

    static let sourceFolder = "Quellen"

    /// A copy of a PDF in the podcast's folder (`Quellen/<name>.pdf`, numbered if the name is taken); returns the
    /// path below the podcast's folder. The library stays whole when the original moves or goes.
    func importPDF(_ file: URL, into podcastID: UUID) throws -> String {
        let folder = folder(of: podcastID).appendingPathComponent(Self.sourceFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent
        var name = "\(stem).pdf"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem) \(number).pdf"
            number += 1
        }
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        return "\(Self.sourceFolder)/\(name)"
    }

    /// The file of a PDF source, below the podcast's folder; nil for a path that would lead out of it.
    func sourceURL(of podcastID: UUID, file: String) -> URL? {
        guard !file.contains(".."), !file.hasPrefix("/") else { return nil }
        return folder(of: podcastID).appendingPathComponent(file)
    }

    func removeSnippet(of podcastID: UUID, line lineID: UUID) {
        try? FileManager.default.removeItem(at: snippetURL(of: podcastID, line: lineID))
    }

    func hasSnippet(of podcastID: UUID, line lineID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: snippetURL(of: podcastID, line: lineID).path)
    }

    /// Snippets of lines that are no longer in the script.
    func removeSnippets(of podcastID: UUID, except kept: Set<UUID>) {
        let folder = folder(of: podcastID).appendingPathComponent(Self.snippetFolder, isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
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

/// All podcasts of the open library, in memory and written back a moment after each change.
@MainActor
@Observable
final class PodcastLibrary {
    /// Most recently changed first, as loaded; new podcasts go to the top.
    private(set) var podcasts: [Podcast] = []

    @ObservationIgnored let store: PodcastStore
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private let writer = DispatchQueue(label: "LLMDesigner.PodcastLibrary.save", qos: .utility)

    init(store: PodcastStore) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        podcasts = store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
        // Nothing runs right after loading: what was being made when the app quit is stopped and can go on.
        for podcast in podcasts where podcast.phase.isRunning {
            update(podcast.id, touch: false) { $0.phase = .stopped }
        }
    }

    func podcast(_ id: UUID) -> Podcast? {
        podcasts.first { $0.id == id }
    }

    @discardableResult
    func add(_ podcast: Podcast) -> Podcast {
        loadIfNeeded()
        podcasts.insert(podcast, at: 0)
        scheduleSave(podcast.id)
        return podcast
    }

    /// The one way to change a podcast. A line whose text changed, or that is gone, loses its snippet, so only it is
    /// spoken anew; `touch` false keeps its place in the sidebar (progress of a running podcast).
    func update(_ id: UUID, touch: Bool = true, _ change: (inout Podcast) -> Void) {
        guard let index = podcasts.firstIndex(where: { $0.id == id }) else { return }
        let before = podcasts[index]
        var podcast = before
        change(&podcast)
        guard podcast != before else { return }
        let oldLines = Dictionary(before.script.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(podcast.script.map(\.id))
        for (position, line) in podcast.script.enumerated() {
            guard let old = oldLines[line.id] else { continue }
            if old.text != line.text || old.speaker != line.speaker {
                store.removeSnippet(of: id, line: line.id)
                podcast.script[position].duration = nil
            }
        }
        for old in before.script where !newIDs.contains(old.id) { store.removeSnippet(of: id, line: old.id) }
        if touch { podcast.updatedAt = Date() }
        podcasts[index] = podcast
        scheduleSave(id)
    }

    /// The deleted podcast's folder lies in the Trash; returns where, for undo.
    @discardableResult
    func delete(_ id: UUID) -> (podcast: Podcast, trashed: URL?)? {
        guard let podcast = podcast(id) else { return nil }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        writer.sync {}
        podcasts.removeAll { $0.id == id }
        return (podcast, store.delete(id))
    }

    /// Puts a deleted podcast back, its folder from the Trash if it is still there.
    func restore(_ podcast: Podcast, from trashed: URL?) {
        loadIfNeeded()
        guard self.podcast(podcast.id) == nil else { return }
        if let trashed { store.restore(podcast.id, from: trashed) }
        var podcast = podcast
        if podcast.phase.isRunning { podcast.phase = .stopped }
        podcasts.insert(podcast, at: 0)
        scheduleSave(podcast.id)
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
        guard let podcast = podcast(id) else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(podcast)
            } catch {
                print("LLMDesigner: Podcast konnte nicht gespeichert werden: \(error)")
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
