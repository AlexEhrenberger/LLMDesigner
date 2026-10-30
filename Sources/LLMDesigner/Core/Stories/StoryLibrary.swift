import Foundation
import AppKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import SwiftUI

/// Stories Studio's files in the library: `Geschichten/<id>.json` holds one novel world with its books, elements
/// and timelines (written as one piece, so links never point into another file); `Geschichten/Bilder/<id>/` the
/// pictures of its elements and galleries; `Geschichten/Videos/<id>/` the video cards of its figures.
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
    var videosDirectory: URL { directory.appendingPathComponent("Videos", isDirectory: true) }

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

    /// The world's file, its pictures and videos go to the Trash, so a deleted world can still be brought back.
    func delete(_ id: UUID) {
        for url in [recordURL(for: id), imageFolder(for: id), videoFolder(for: id)] where FileManager.default.fileExists(atPath: url.path) {
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

    func videoFolder(for worldID: UUID) -> URL {
        videosDirectory.appendingPathComponent(worldID.uuidString, isDirectory: true)
    }

    func videoURL(_ video: StoryVideo, in worldID: UUID) -> URL {
        videoFolder(for: worldID).appendingPathComponent(video.fileName)
    }

    /// Copies a video into the world's folder under a new name.
    func importVideo(_ url: URL, into worldID: UUID) throws -> StoryVideo {
        let folder = videoFolder(for: worldID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let name = "video-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        return StoryVideo(fileName: name, caption: url.deletingPathExtension().lastPathComponent)
    }

    func removeVideo(_ video: StoryVideo, in worldID: UUID) {
        let url = videoURL(video, in: worldID)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
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

    fileprivate static let encoder: JSONEncoder = {
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
///
/// Typing goes into drafts first: every change of `worlds` makes the whole studio (navigator, page, every chip)
/// read the world again, which is too slow to do on each keystroke. A text field's binding keeps what was typed
/// as a draft, unseen by observation, and the drafts go into the world together once typing pauses.
@MainActor
@Observable
final class StoryLibrary {
    /// Most recently changed first, as loaded; new worlds go to the top.
    private(set) var worlds: [StoryWorld] = []

    @ObservationIgnored let store: StoryStore
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored private var posters: [String: NSImage] = [:]
    @ObservationIgnored private var drafts: [DraftKey: Draft] = [:]
    @ObservationIgnored private var draftOrder: [DraftKey] = []
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    /// Files are written one after another, off the main thread.
    @ObservationIgnored private let writer = DispatchQueue(label: "LLMDesigner.StoryLibrary.save", qos: .utility)

    /// How long typing has to pause before the drafts go into the world.
    static let draftDelay: Duration = .milliseconds(350)

    private struct DraftKey: Hashable {
        let worldID: UUID
        let field: AnyHashable
    }

    private struct Draft {
        let value: Any
        let apply: (inout StoryWorld) -> Void
    }

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
        discardDrafts(of: id)
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        worlds.removeAll { $0.id == id }
        store.delete(id)
    }

    /// The one way to change a world; it is saved half a second after the last change. Drafts of the world go in
    /// first, so a change never comes before text typed earlier.
    func update(_ id: UUID, _ change: (inout StoryWorld) -> Void) {
        guard let index = worlds.firstIndex(where: { $0.id == id }) else { return }
        var world = worlds[index]
        applyDrafts(of: id, to: &world)
        change(&world)
        guard world != worlds[index] else { return }
        world.updatedAt = Date()
        worlds[index] = world
        scheduleSave(id)
    }

    // MARK: Drafts

    /// A binding for a text field: what is typed stays a draft until typing pauses (see the type's comment).
    /// `field` names the field within the world (a key path, or the ids and key path of a nested value).
    func draftBinding<T>(_ worldID: UUID, field: AnyHashable, fallback: T, get: @escaping (StoryWorld) -> T?,
                         set: @escaping (inout StoryWorld, T) -> Void) -> Binding<T> {
        let key = DraftKey(worldID: worldID, field: field)
        return Binding(
            get: {
                if let draft = self.drafts[key]?.value as? T { return draft }
                return self.world(worldID).flatMap(get) ?? fallback
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
            try? await Task.sleep(for: StoryLibrary.draftDelay)
            guard !Task.isCancelled else { return }
            self?.commitDrafts()
        }
    }

    /// Puts every draft into its world now.
    func commitDrafts() {
        draftTask?.cancel()
        draftTask = nil
        for id in Set(draftOrder.map(\.worldID)) {
            update(id) { _ in }
        }
    }

    var hasDrafts: Bool { !drafts.isEmpty }

    private func applyDrafts(of worldID: UUID, to world: inout StoryWorld) {
        let keys = draftOrder.filter { $0.worldID == worldID }
        guard !keys.isEmpty else { return }
        for key in keys { drafts[key]?.apply(&world) }
        discardDrafts(of: worldID)
    }

    private func discardDrafts(of worldID: UUID) {
        for key in draftOrder where key.worldID == worldID { drafts[key] = nil }
        draftOrder.removeAll { $0.worldID == worldID }
    }

    // MARK: Removing with files

    /// Removes an element with every link to it; its pictures and videos go to the Trash.
    func removeElement(_ ref: StoryRef, in worldID: UUID) {
        guard let media = world(worldID)?.media(of: ref) else { return }
        update(worldID) { $0.removeElement(ref) }
        for image in media.images { removeImage(image, in: worldID) }
        for video in media.videos { removeVideo(video, in: worldID) }
    }

    /// Removes a part with everything below it; the pictures of their galleries go to the Trash.
    func removePart(_ partID: UUID, in worldID: UUID) {
        guard let images = world(worldID)?.galleryImages(within: partID) else { return }
        update(worldID) { $0.removePart(partID) }
        for image in images { removeImage(image, in: worldID) }
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

    // MARK: Videos

    static let videoTypes: [UTType] = [.movie]

    func importVideos(_ urls: [URL], into worldID: UUID) -> [StoryVideo] {
        urls.compactMap { url in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) || type.conforms(to: .video) else { return nil }
            return try? store.importVideo(url, into: worldID)
        }
    }

    func removeVideo(_ video: StoryVideo, in worldID: UUID) {
        posters[store.videoURL(video, in: worldID).path] = nil
        store.removeVideo(video, in: worldID)
    }

    func videoURL(_ video: StoryVideo, in worldID: UUID) -> URL {
        store.videoURL(video, in: worldID)
    }

    /// A still from the start of the video and its length, for the video cards; made once and kept.
    func poster(_ video: StoryVideo, in worldID: UUID) async -> (image: NSImage?, duration: Double?) {
        let url = store.videoURL(video, in: worldID)
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        if let cached = posters[url.path] { return (cached, duration) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: min(0.5, (duration ?? 0) / 2), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return (nil, duration) }
        let image = NSImage(cgImage: cgImage, size: .zero)
        posters[url.path] = image
        return (image, duration)
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

    /// Encodes and writes on the writer queue, so a large world doesn't hold up typing.
    private func save(_ id: UUID, wait: Bool = false) {
        saveTasks[id] = nil
        guard let world = world(id) else { return }
        let store = store
        let work: @Sendable () -> Void = {
            do {
                try store.save(world)
            } catch {
                print("LLMDesigner: Romanwelt konnte nicht gespeichert werden: \(error)")
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
