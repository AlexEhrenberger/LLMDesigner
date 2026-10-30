import Foundation
import AppKit
import ImageIO

/// Stories Studio's files in the library: `Geschichten/<id>.json` holds one novel world with its books, elements
/// and timelines (written as one piece, so links never point into another file); `Geschichten/Bilder/<id>/` the
/// pictures of its figures and places.
struct StoryStore: Sendable {
    static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store of the open library.
    static func library() -> StoryStore {
        StoryStore(directory: AppLibrary.current.folder("Geschichten"))
    }

    var imagesDirectory: URL { directory.appendingPathComponent("Bilder", isDirectory: true) }

    struct Record: Codable {
        var format = StoryStore.formatVersion
        var world: StoryWorld
    }

    func loadAll() -> [StoryWorld] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try Self.decoder.decode(Record.self, from: Data(contentsOf: file)).world
            } catch {
                print("LLMDesigner: Romanwelt \(file.lastPathComponent) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    func save(_ world: StoryWorld) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(Record(world: world)).write(to: recordURL(for: world.id), options: .atomic)
    }

    /// The world's file and its pictures go to the Trash, so a deleted world can still be brought back.
    func delete(_ id: UUID) {
        for url in [recordURL(for: id), imageFolder(for: id)] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func imageFolder(for worldID: UUID) -> URL {
        imagesDirectory.appendingPathComponent(worldID.uuidString, isDirectory: true)
    }

    func imageURL(_ image: StoryImage, in worldID: UUID) -> URL {
        imageFolder(for: worldID).appendingPathComponent(image.fileName)
    }

    /// Copies a picture into the world's folder under a new name, so two pictures called "portrait.png" can't clash.
    func importImage(_ url: URL, into worldID: UUID) throws -> StoryImage {
        let folder = imageFolder(for: worldID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "bild-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        return StoryImage(fileName: name)
    }

    func removeImage(_ image: StoryImage, in worldID: UUID) {
        let url = imageURL(image, in: worldID)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// All novel worlds of the open library, kept in memory and written back a moment after each change.
@MainActor
@Observable
final class StoryLibrary {
    /// Most recently changed first, as loaded; new worlds go to the top.
    private(set) var worlds: [StoryWorld] = []

    @ObservationIgnored let store: StoryStore
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()

    init(store: StoryStore) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        worlds = store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    func world(_ id: UUID) -> StoryWorld? {
        worlds.first { $0.id == id }
    }

    // MARK: Worlds

    @discardableResult
    func addWorld(title: String = "") -> StoryWorld {
        loadIfNeeded()
        let world = StoryWorld(title: title)
        worlds.insert(world, at: 0)
        scheduleSave(world.id)
        return world
    }

    func deleteWorld(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        worlds.removeAll { $0.id == id }
        store.delete(id)
    }

    /// The one way to change a world; it is saved half a second after the last change.
    func update(_ id: UUID, _ change: (inout StoryWorld) -> Void) {
        guard let index = worlds.firstIndex(where: { $0.id == id }) else { return }
        var world = worlds[index]
        change(&world)
        guard world != worlds[index] else { return }
        world.updatedAt = Date()
        worlds[index] = world
        scheduleSave(id)
    }

    // MARK: Pictures

    func importImages(_ urls: [URL], into worldID: UUID) -> [StoryImage] {
        urls.compactMap { url in
            guard NSImage(contentsOf: url) != nil else { return nil }
            return try? store.importImage(url, into: worldID)
        }
    }

    func removeImage(_ image: StoryImage, in worldID: UUID) {
        thumbnails.removeObject(forKey: store.imageURL(image, in: worldID).path as NSString)
        store.removeImage(image, in: worldID)
    }

    func imageURL(_ image: StoryImage, in worldID: UUID) -> URL {
        store.imageURL(image, in: worldID)
    }

    /// A picture read once and kept small, for lists and galleries.
    func thumbnail(_ image: StoryImage, in worldID: UUID) -> NSImage? {
        let url = store.imageURL(image, in: worldID)
        if let cached = thumbnails.object(forKey: url.path as NSString) { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let small = NSImage(cgImage: cgImage, size: .zero)
        thumbnails.setObject(small, forKey: url.path as NSString)
        return small
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

    private func save(_ id: UUID) {
        saveTasks[id] = nil
        guard let world = world(id) else { return }
        do {
            try store.save(world)
        } catch {
            print("LLMDesigner: Romanwelt konnte nicht gespeichert werden: \(error)")
        }
    }

    /// Writes what is still waiting (leaving the studio, switching libraries, quitting).
    func saveAll() {
        for id in Array(saveTasks.keys) {
            saveTasks[id]?.cancel()
            save(id)
        }
    }
}
