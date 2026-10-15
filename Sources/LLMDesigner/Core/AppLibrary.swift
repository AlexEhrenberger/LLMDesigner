import AppKit
import UniformTypeIdentifiers

/// A library: one folder package (`Name.llmdlibrary`) with everything LLM Designer keeps – chats, documents with
/// their pictures, personas with their memory, skills, folders, attachments and the settings. Nothing goes to
/// Application Support or the system preferences, so a library can be copied, moved to another Mac or opened from
/// an external drive, and libraries never see each other's data. The app itself only remembers which libraries
/// were open lately (`LibraryRegistry`).
final class AppLibrary {
    static let fileExtension = "llmdlibrary"
    static let contentType = UTType(exportedAs: "app.llmdesigner.library", conformingTo: .package)
    static let infoFileName = "Bibliothek.json"
    /// The format of the folder layout, for later changes.
    static let formatVersion = 1

    /// The open library. Set before the app's model is made; the stores take their folders from it.
    nonisolated(unsafe) static var current: AppLibrary!

    let url: URL
    let settings: LibrarySettings
    /// From `Bibliothek.json`; tells a moved or renamed library apart from others.
    let id: String?

    init(url: URL) {
        self.url = Self.normalized(url)
        settings = LibrarySettings(url: url.appendingPathComponent("Einstellungen.plist"))
        id = Self.id(at: url)
    }

    static func id(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(infoFileName)),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info["id"] as? String
    }

    /// The name is the file name, so renaming in the Finder renames the library.
    var name: String { Self.name(of: url) }

    static func name(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// One spelling per place: a bookmark resolves to a directory URL with a trailing slash, a path doesn't.
    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    func isAt(_ other: URL) -> Bool { url.path == Self.normalized(other).path }

    /// A folder inside the library, created when it is missing.
    func folder(_ name: String) -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var exists: Bool { Self.isLibrary(url) }

    static func isLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(infoFileName).path)
    }

    /// Makes a new, empty library at `url` (a path ending in `.llmdlibrary`).
    static func create(at url: URL) throws -> AppLibrary {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { throw LibraryError.exists(name(of: url)) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "app": "LLM Designer",
            "format": formatVersion,
            "id": UUID().uuidString,
            "created": Date().formatted(.iso8601),
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.appendingPathComponent(infoFileName), options: .atomic)
        let library = AppLibrary(url: url)
        for folder in ["Chats", "Documents", "Personas", "Attachments"] { _ = library.folder(folder) }
        return library
    }

    /// Where new libraries go unless the user picks another place.
    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("LLM Designer", isDirectory: true)
    }

    /// A free place for a library with this name in `folder`: "Name", "Name 2", …
    static func freeURL(named name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(fileExtension)
            number += 1
        }
        return candidate
    }
}

enum LibraryError: LocalizedError {
    case exists(String)
    case notALibrary(String)
    case missing(String)
    case migrationIncomplete(Int, Int)

    var errorDescription: String? {
        switch self {
        case .exists(let name): "Am gewählten Ort gibt es schon „\(name)“."
        case .notALibrary(let name): "„\(name)“ ist keine LLM-Designer-Bibliothek."
        case .missing(let name): "Die Bibliothek „\(name)“ ist nicht da (verschoben, gelöscht oder auf einem Laufwerk, das nicht angeschlossen ist)."
        case .migrationIncomplete(let copied, let expected): "Beim Übernehmen der bisherigen Daten kamen nur \(copied) von \(expected) Dateien an. Die alten Daten bleiben, wo sie sind."
        }
    }
}

/// The settings of a library, as a property list in it (`Einstellungen.plist`). Same interface as `UserDefaults`
/// for the few calls the app makes.
final class LibrarySettings {
    let url: URL
    private var values: [String: Any]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = plist
        } else {
            values = [:]
        }
    }

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
        save()
    }

    /// Takes several values at once (when old settings move into a library).
    func merge(_ other: [String: Any]) {
        values.merge(other) { $1 }
        save()
    }

    private func save() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            print("LLMDesigner: Einstellungen konnten nicht gespeichert werden: \(error)")
        }
    }
}

/// The libraries this Mac opened lately, newest first. Only pointers (path and bookmark, so a library moved on the
/// same disk is found again); this is the one thing kept outside the libraries.
enum LibraryRegistry {
    struct Entry: Identifiable, Equatable {
        let url: URL
        let isAvailable: Bool
        var id: String { url.path }
        var name: String { AppLibrary.name(of: url) }
    }

    private static let recentKey = "recentLibraries"
    private static let limit = 12

    private static var stored: [[String: Any]] {
        get { UserDefaults.standard.array(forKey: recentKey) as? [[String: Any]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentKey) }
    }

    static var entries: [Entry] {
        var seen = Set<String>()
        return stored.compactMap { item -> Entry? in
            guard let resolved = resolve(item) else { return nil }
            let url = AppLibrary.normalized(resolved)
            guard seen.insert(url.path).inserted else { return nil }
            return Entry(url: url, isAvailable: AppLibrary.isLibrary(url))
        }
    }

    /// Puts a library at the top of the list.
    static func remember(_ url: URL) {
        let url = AppLibrary.normalized(url)
        var item: [String: Any] = ["path": url.path]
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            item["bookmark"] = bookmark
        }
        let others = stored.filter { resolve($0).map(AppLibrary.normalized)?.path != url.path }
        stored = Array(([item] + others).prefix(limit))
    }

    static func forget(_ url: URL) {
        let path = AppLibrary.normalized(url).path
        stored = stored.filter { resolve($0).map(AppLibrary.normalized)?.path != path }
    }

    /// Where a library is now: the bookmark follows moves on the same disk; otherwise the stored path.
    private static func resolve(_ item: [String: Any]) -> URL? {
        if let bookmark = item["bookmark"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               AppLibrary.isLibrary(url) {
                return url
            }
        }
        return (item["path"] as? String).map { URL(fileURLWithPath: $0) }
    }
}

/// Before libraries existed, LLM Designer kept its data in `~/Library/Application Support/LLMDesigner` and its
/// settings in the system preferences. On the first start this moves both into a library and the old folder to
/// the Trash, so nothing stays behind.
enum LegacyMigration {
    static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMDesigner", isDirectory: true)
    }

    /// The settings that used to be in the system preferences.
    static let settingKeys = [
        "endpoint", "apiKey", "systemPrompt", "temperature", "useCustomTemperature", "preferredModel", "sidebarVisible",
        "pdfPaperSize", "pdfSpeakerLineEnabled", "pdfSpeakerTemplate", "pdfOpenAfterExport", "outlinePanelVisible",
        "suggestFollowUps", "dictationMode", "speechEngine", "qwenVoice", "speechRate", "webReaderFallback",
        "thinkingDefault", "conversationPause", "memoryDefault", "contextDefault", "writerLightPaper",
        "writerReadsAnswers", "conversationWindowSize",
    ]

    static var hasLegacyData: Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: legacyFolder.path)) ?? []
        return items.contains { $0 != ".DS_Store" }
    }

    static var hasLegacySettings: Bool {
        settingKeys.contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    /// Copies the old data and settings into `library`, checks that every file arrived, then removes the old ones.
    static func run(into library: AppLibrary) throws {
        let fileManager = FileManager.default
        if hasLegacyData {
            let items = try fileManager.contentsOfDirectory(atPath: legacyFolder.path).filter { $0 != ".DS_Store" }
            for item in items {
                let target = library.url.appendingPathComponent(item)
                // An empty folder the new library made already is replaced by the old one.
                if fileManager.fileExists(atPath: target.path) {
                    let contents = (try? fileManager.contentsOfDirectory(atPath: target.path)) ?? []
                    guard contents.isEmpty else { continue }
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: legacyFolder.appendingPathComponent(item), to: target)
            }
            let expected = fileCount(in: legacyFolder)
            let copied = items.reduce(0) { $0 + fileCount(in: library.url.appendingPathComponent($1)) }
            guard copied >= expected else { throw LibraryError.migrationIncomplete(copied, expected) }
        }
        var settings: [String: Any] = [:]
        for key in settingKeys {
            if let value = UserDefaults.standard.object(forKey: key) { settings[key] = value }
        }
        if !settings.isEmpty { library.settings.merge(settings) }

        // Everything arrived: nothing stays outside the library. The old folder goes to the Trash, not away.
        for key in settingKeys { UserDefaults.standard.removeObject(forKey: key) }
        if hasLegacyData || fileManager.fileExists(atPath: legacyFolder.path) {
            try? fileManager.trashItem(at: legacyFolder, resultingItemURL: nil)
        }
        removeOldCaches()
    }

    /// HTTP caches of earlier versions; the app keeps none on disk any more.
    static func removeOldCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["LLMDesigner", "app.llmdesigner.LLMDesigner"] {
            let folder = caches.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private static func fileCount(in url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return url.lastPathComponent == ".DS_Store" ? 0 : 1 }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent != ".DS_Store", (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }
}
