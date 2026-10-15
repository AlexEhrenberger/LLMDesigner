import SwiftUI
import UniformTypeIdentifiers

/// Holds the open library and the app's model for it. Switching libraries closes the model (pending saves are
/// written, running work stops) and makes a new one for the other library, so no state crosses over.
@MainActor
@Observable
final class LibrarySession {
    /// For the app delegate (a library double-clicked in the Finder).
    nonisolated(unsafe) static weak var shared: LibrarySession?

    private(set) var app: AppModel
    private(set) var library: AppLibrary
    private(set) var recent: [LibraryRegistry.Entry] = []
    private(set) var isSwitching = false
    /// A message for the user (shown as an alert), e.g. a library that couldn't be opened.
    var message: String?

    init() {
        // HTTP answers are never cached on disk: nothing of a library ends up in ~/Library/Caches.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0, directory: nil)
        let (library, message) = Self.libraryAtLaunch()
        AppLibrary.current = library
        LibraryRegistry.remember(library.url)
        self.library = library
        self.message = message
        app = AppModel()
        recent = LibraryRegistry.entries
        Self.shared = self
    }

    /// The library that was open last; on the very first start the data of earlier versions moves into a new one.
    private static func libraryAtLaunch() -> (AppLibrary, String?) {
        let entries = LibraryRegistry.entries
        if let last = entries.first, last.isAvailable {
            let library = AppLibrary(url: last.url)
            // Settings an older version left behind join the library that is in use.
            if LegacyMigration.hasLegacyData || LegacyMigration.hasLegacySettings { try? LegacyMigration.run(into: library) }
            return (library, nil)
        }
        var message = entries.first.map { "Die Bibliothek „\($0.name)“ ist nicht verfügbar (verschoben oder auf einem Laufwerk, das nicht angeschlossen ist)." }
        if LegacyMigration.hasLegacyData || LegacyMigration.hasLegacySettings {
            do {
                let library = try AppLibrary.create(at: AppLibrary.freeURL(named: "Meine Bibliothek", in: AppLibrary.defaultFolder))
                try LegacyMigration.run(into: library)
                return (library, message)
            } catch {
                message = error.localizedDescription
            }
        }
        if let other = entries.dropFirst().first(where: \.isAvailable) {
            return (AppLibrary(url: other.url), message.map { $0 + " Geöffnet ist „\(other.name)“." })
        }
        let url = AppLibrary.freeURL(named: "Meine Bibliothek", in: AppLibrary.defaultFolder)
        let library = (try? AppLibrary.create(at: url)) ?? AppLibrary(url: url)
        return (library, message)
    }

    // MARK: Switching

    func open(_ url: URL) async {
        let url = AppLibrary.normalized(url)
        guard !library.isAt(url) else { return }
        guard AppLibrary.isLibrary(url) else {
            message = FileManager.default.fileExists(atPath: url.path)
                ? LibraryError.notALibrary(AppLibrary.name(of: url)).localizedDescription
                : LibraryError.missing(AppLibrary.name(of: url)).localizedDescription
            refreshRecent()
            return
        }
        await switchTo(AppLibrary(url: url))
    }

    private func switchTo(_ next: AppLibrary) async {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        await app.close()
        AppLibrary.current = next
        library = next
        LibraryRegistry.remember(next.url)
        app = AppModel()
        refreshRecent()
    }

    func refreshRecent() {
        recent = LibraryRegistry.entries
    }

    // MARK: Commands

    /// Asks for a name and a place, makes the library and opens it.
    func createLibrary() {
        let panel = NSSavePanel()
        panel.title = "Neue Bibliothek"
        panel.message = "Eine Bibliothek enthält Chats, Dokumente, Personas, Skills und Einstellungen – getrennt von allen anderen."
        panel.prompt = "Anlegen"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "Neue Bibliothek"
        panel.allowedContentTypes = [AppLibrary.contentType]
        panel.canCreateDirectories = true
        try? FileManager.default.createDirectory(at: AppLibrary.defaultFolder, withIntermediateDirectories: true)
        panel.directoryURL = AppLibrary.defaultFolder
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != AppLibrary.fileExtension { url.appendPathExtension(AppLibrary.fileExtension) }
        do {
            // The save panel already asked whether to replace an existing item; a library is never overwritten.
            let library = try AppLibrary.create(at: url)
            Task { await switchTo(library) }
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Bibliothek öffnen"
        panel.prompt = "Öffnen"
        panel.allowedContentTypes = [AppLibrary.contentType]
        // Without the type registered (a library copied from elsewhere), it is still a folder that can be chosen.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.url])
    }

    /// Renames the library on disk (it is closed while it moves) and opens it again.
    func renameLibrary() {
        let alert = NSAlert()
        alert.messageText = "Bibliothek umbenennen"
        alert.informativeText = "Der Name ist der Dateiname der Bibliothek."
        let field = NSTextField(string: library.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Umbenennen")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != library.name else { return }
        let target = library.url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(AppLibrary.fileExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            message = LibraryError.exists(name).localizedDescription
            return
        }
        let old = library.url
        Task {
            isSwitching = true
            await app.close()
            do {
                try FileManager.default.moveItem(at: old, to: target)
                LibraryRegistry.forget(old)
                let renamed = AppLibrary(url: target)
                AppLibrary.current = renamed
                library = renamed
                LibraryRegistry.remember(target)
            } catch {
                message = error.localizedDescription
                AppLibrary.current = library
            }
            app = AppModel()
            refreshRecent()
            isSwitching = false
        }
    }

    func forget(_ entry: LibraryRegistry.Entry) {
        LibraryRegistry.forget(entry.url)
        refreshRecent()
    }

    /// The open library was moved or renamed in the Finder while the app ran: it is opened from its new place.
    func checkLibraryLocation() {
        guard !isSwitching, !library.exists else { return }
        let moved = LibraryRegistry.entries.first { $0.isAvailable && !library.isAt($0.url) && library.id != nil && AppLibrary.id(at: $0.url) == library.id }
        guard let moved else {
            message = LibraryError.missing(library.name).localizedDescription
            return
        }
        Task {
            await app.close()
            let library = AppLibrary(url: moved.url)
            AppLibrary.current = library
            self.library = library
            LibraryRegistry.remember(moved.url)
            app = AppModel()
            refreshRecent()
        }
    }
}
