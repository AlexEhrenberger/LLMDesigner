import Foundation
import Observation

/// The changes of one item in the working tree, as the Git lists show them.
struct GitChangeGroup: Identifiable, Hashable, Sendable {
    var item: LibraryItem
    var entries: [GitStatus.Entry]
    /// What changed, in the studio's words ("2 Absätze geändert, 1 neu"), once it is worked out.
    var detail: String?

    var id: String { item.id }
    var paths: [String] { entries.map(\.path) + entries.compactMap(\.originalPath) }

    /// "neu", "gelöscht", "2 Absätze geändert" or "geändert, 2 Dateien".
    var summary: String {
        if let detail, !detail.isEmpty { return detail }
        let changes = Set(entries.map(\.change))
        var text: String
        if changes == [.untracked] || changes == [.added] || changes == [.untracked, .added] {
            text = "neu"
        } else if changes == [.deleted] {
            text = "gelöscht"
        } else if changes.contains(.conflicted) {
            text = "Konflikt"
        } else {
            text = "geändert"
        }
        if entries.count > 1 { text += ", \(entries.count) Dateien" }
        return text
    }
}

/// A change from outside that meets unsaved work here, or that has to wait for running work.
struct ExternalChangeNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        /// These items changed on disk while the app holds changes to them that aren't written yet.
        case conflict([LibraryItem])
        /// Something runs (an answer, a podcast); reloading now would stop it.
        case deferred
    }

    let id = UUID()
    var kind: Kind
    var changes: ExternalChanges

    var message: String {
        switch kind {
        case .conflict(let items):
            let names = items.prefix(3).map { "„\($0.title)“" }.joined(separator: ", ")
            return "\(names) wurde außerhalb geändert (z. B. mit git im Terminal), und hier gibt es noch ungesicherte Änderungen daran."
        case .deferred:
            return "Die Bibliothek wurde außerhalb geändert (z. B. git checkout). Neu laden beendet die laufende Arbeit."
        }
    }
}

/// Git for the open library: the repository, its status with titles, the watcher for changes from outside, and the
/// calls the app makes. Everything git does runs off the main actor; the results land here.
@MainActor
@Observable
final class LibraryGit {
    let root: URL
    private(set) var tool: GitTool?
    private(set) var status: GitStatus?
    private(set) var changes: [GitChangeGroup] = []
    private(set) var isEnabled = false
    private(set) var isBusy = false
    /// Why git can't run here (unsafe configuration, missing tool); shown in the Git views.
    private(set) var problem: String?
    var notice: ExternalChangeNotice?

    @ObservationIgnored weak var app: AppModel?
    /// Extra environment for every call (tests isolate git from the person's own configuration).
    @ObservationIgnored var environment: [String: String] = [:]
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var configurationChecked = false
    /// While the app runs git itself it handles the result; the watcher's report of the same files is dropped.
    @ObservationIgnored private var ownOperations = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The `llmd` that serves as git's merge driver; nil where there is none (a test, a build outside the app).
    @ObservationIgnored var driverPath: String? = {
        let path = LibraryGit.llmdPath
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()
    /// A merge is under way (`.git/MERGE_HEAD`).
    private(set) var isMerging = false
    @ObservationIgnored private var hasRefreshed = false

    init(root: URL, preferredTool: String? = nil) {
        self.root = root
        tool = GitTool.find(preferred: preferredTool)
        isEnabled = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    var repository: GitRepository? {
        tool.map { GitRepository(root: root, tool: $0, environment: environment) }
    }

    /// The app runs git itself right now (or did a moment ago); changes from outside are not looked at then.
    var isRunningOwnOperation: Bool { ownOperations > 0 }

    var branch: String? { status?.branch }
    var changeCount: Int { changes.count }

    /// Starts watching and reads the status, if the library has a repository.
    func start() {
        guard isEnabled, watcher == nil else { return }
        let watcher = LibraryWatcher(root: root) { [weak self] changes in
            Task { @MainActor in self?.received(changes) }
        }
        watcher.start()
        self.watcher = watcher
        scheduleRefresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
    }

    // MARK: Status

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        guard isEnabled, let repository = try? await checkedRepository() else { return }
        do {
            let result = try await repository.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
            let status = GitStatus.parse(result.output)
            let deleted = status.entries.filter { $0.change == .deleted }.map(\.path)
            var old: [String: Data] = [:]
            for path in deleted { old[path] = try? await repository.run(["show", "HEAD:\(path)"]).output }
            let root = self.root
            let resolver = LibraryItemResolver { path in
                old[path] ?? (try? Data(contentsOf: root.appendingPathComponent(path)))
            }
            let groups = resolver.group(status.entries.map(\.path)).map { group in
                GitChangeGroup(item: group.item, entries: status.entries.filter { group.paths.contains($0.path) })
            }
            self.status = status
            isMerging = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path)
            if status.hasConflicts, await repairConflictMarkers(status) {
                // A file the app had read with `<<<<<<<` in it is valid again; read the library anew.
                app?.requestLibraryReload()
            }
            changes = await Self.describe(groups, repository: repository, root: root)
            // After the reload that follows a merge with conflicts, the new model opens the conflict view once.
            if !hasRefreshed {
                hasRefreshed = true
                if Self.openConflictsAfterReload, status.hasConflicts, let app {
                    Self.openConflictsAfterReload = false
                    app.mergeViewOpen = true
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Works out what changed in each item against the last commit, in the words of its studio. Only for the first
    /// items: a checkout of hundreds of files would otherwise hold up the list.
    static func describe(_ groups: [GitChangeGroup], repository: GitRepository, root: URL) async -> [GitChangeGroup] {
        var result = groups
        for index in result.indices.prefix(40) {
            let group = result[index]
            guard let main = group.item.mainPath, main.hasSuffix(".md") || main.hasSuffix(".json"),
                  group.entries.contains(where: { $0.path == main && ($0.change == .modified || $0.change == .renamed) }) else { continue }
            let before = try? await repository.run(["show", "HEAD:\(main)"]).output
            let now = try? Data(contentsOf: root.appendingPathComponent(main))
            let comparison = await Task.detached(priority: .utility) { Comparer.compare(path: main, left: before, right: now) }.value
            var text = comparison.summary
            if text == "unverändert" { continue }
            if group.entries.count > 1 { text += " · \(group.entries.count) Dateien" }
            result[index].detail = text
        }
        return result
    }

    /// The repository after one look at its own configuration: a library from elsewhere could make git start
    /// programs. Until that is fixed, no call runs.
    func checkedRepository() async throws -> GitRepository {
        guard let repository else {
            problem = GitError.notInstalled.localizedDescription
            throw GitError.notInstalled
        }
        guard repository.exists else { throw GitError.notARepository }
        if !configurationChecked {
            do {
                // The driver entries are the app's own: written first (over whatever stood there), then allowed.
                let drivers = driverPath.map { GitSetup.driverConfiguration(llmd: $0) } ?? [:]
                for (key, value) in drivers.sorted(by: { $0.key < $1.key }) {
                    try await repository.run(["config", "--local", key, value])
                }
                try await repository.checkConfiguration(allowedDrivers: drivers)
                configurationChecked = true
                problem = nil
            } catch {
                problem = error.localizedDescription
                throw error
            }
        }
        return repository
    }

    // MARK: Turning on

    /// Makes the library a repository. Returns the files left out for their size.
    @discardableResult
    func enable(identity: (name: String, email: String)? = nil) async throws -> [String] {
        guard let repository else { throw GitError.notInstalled }
        app?.saveEverythingForGit()
        ownOperations += 1
        defer { ownOperations -= 1 }
        let large = try await GitSetup.enable(repository, identity: identity, drivers: driverPath.map { GitSetup.driverConfiguration(llmd: $0) } ?? [:])
        isEnabled = true
        configurationChecked = false
        start()
        await refresh()
        return large
    }

    func hasIdentity() async -> Bool {
        guard let repository else { return false }
        return (try? await GitSetup.hasIdentity(repository)) ?? false
    }

    // MARK: Running git

    /// Runs git for the app: everything pending is written first, background writes wait, and the watcher's report
    /// of the same change is dropped. When the call changed the working tree (`changesFiles`), the library reloads
    /// afterwards so the app shows what git wrote.
    func perform<T>(_ reason: String, changesFiles: Bool = false, _ body: (GitRepository) async throws -> T) async throws -> T {
        guard !isBusy else { throw GitError.busy("Git arbeitet noch an etwas anderem.") }
        if changesFiles, let work = app?.runningWorkDescription { throw GitError.busy("\(work) läuft. Warte, bis es fertig ist, oder brich es ab.") }
        let repository = try await checkedRepository()
        app?.saveEverythingForGit()
        isBusy = true
        ownOperations += 1
        defer {
            isBusy = false
            // Events of this call arrive a little later; they stay ignored for that long.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.ownOperations -= 1
            }
        }
        let folders = Self.folders(in: root)
        defer { Self.restore(folders, in: root) }
        let value = try await body(repository)
        Self.restore(folders, in: root)
        await refresh()
        if changesFiles { app?.requestLibraryReload() }
        return value
    }

    /// Git removes a folder when its last file goes (a stash, a switch to a branch without documents), but the
    /// app's stores keep writing into the folders they were given. Folders that were there before stay.
    nonisolated static func folders(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        let top = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in top where url.lastPathComponent != ".git" && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            result.append(url)
            let inner = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            result += inner.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return result
    }

    nonisolated static func restore(_ folders: [URL], in root: URL) {
        for folder in folders where !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Changes from outside

    func received(_ changes: ExternalChanges) {
        guard !changes.isEmpty else { return }
        scheduleRefresh()
        guard ownOperations == 0, changes.headChanged || !changes.paths.isEmpty, let app else { return }
        let root = self.root
        let resolver = LibraryItemResolver { try? Data(contentsOf: root.appendingPathComponent($0)) }
        let items = Set(changes.paths.map(resolver.item(for:)))
        let pending = app.pendingSaveIDs()
        let touched = items.filter { $0.recordID.map(pending.contains) ?? false }
        if !touched.isEmpty {
            notice = ExternalChangeNotice(kind: .conflict(touched.sorted { $0.title < $1.title }), changes: changes)
        } else if app.runningWorkDescription != nil {
            notice = ExternalChangeNotice(kind: .deferred, changes: changes)
        } else {
            app.requestLibraryReload()
        }
    }

    /// The version on disk wins: pending changes to the touched items are dropped, then the library reloads.
    func takeVersionFromDisk() {
        guard let notice, let app else { return }
        if case .conflict(let items) = notice.kind {
            let ids = Set(items.compactMap(\.recordID))
            app.discardPendingSaves(ids)
            app.discardOnClose.formUnion(ids)
        }
        self.notice = nil
        app.requestLibraryReload()
    }

    /// The version here wins: it is written now, over what came from outside.
    func keepVersionHere() {
        notice = nil
        app?.saveEverythingForGit()
        scheduleRefresh()
    }
}

// MARK: - The model's side

extension AppModel {
    /// Writes everything that waits for a pause, so git sees what the person sees.
    func saveEverythingForGit() {
        writerFlush?()
        savePendingDocuments()
        citations.saveAll()
        stories.saveAll()
        notes.saveAll()
        projects.saveAll()
        dataStudio.saveAll()
        research.saveAll()
        learning.saveAll()
        podcasts.saveAll()
    }

    /// Ids of records whose latest change isn't on disk yet.
    func pendingSaveIDs() -> Set<UUID> {
        var ids = Set(documentSaveTasks.keys)
        ids.formUnion(citations.pendingSaveIDs)
        ids.formUnion(stories.pendingSaveIDs)
        ids.formUnion(notes.pendingSaveIDs)
        ids.formUnion(projects.pendingSaveIDs)
        ids.formUnion(podcasts.pendingSaveIDs)
        ids.formUnion(dataStudio.blocks.pendingSaveIDs)
        ids.formUnion(dataStudio.templates.pendingSaveIDs)
        ids.formUnion(research.records.pendingSaveIDs)
        ids.formUnion(learning.courses.pendingSaveIDs)
        return ids
    }

    func discardPendingSaves(_ ids: Set<UUID>) {
        for id in ids {
            documentSaveTasks[id]?.cancel()
            documentSaveTasks[id] = nil
            citations.discardPendingSave(id)
            stories.discardPendingSave(id)
            notes.discardPendingSave(id)
            projects.discardPendingSave(id)
            podcasts.discardPendingSave(id)
            dataStudio.blocks.discardPendingSave(id)
            dataStudio.templates.discardPendingSave(id)
            research.records.discardPendingSave(id)
            learning.courses.discardPendingSave(id)
        }
    }

    /// Asks the session to read the library anew (after a checkout, a merge, a restore).
    func requestLibraryReload() {
        onLibraryReload?()
    }
}

extension LibraryGit {
    /// Where each kind keeps the file that names a record.
    static func mainPaths(for id: UUID) -> [String] {
        let id = id.uuidString
        return ["Documents/\(id).md", "Zitate/Quellen/\(id).json", "Geschichten/\(id).json", "Notizen/\(id).json",
                "Projekte/\(id).json", "Podcasts/\(id)/podcast.json", "Daten/\(id).json", "Vorlagen/\(id)/vorlage.json",
                "Recherchen/\(id)/recherche.json", "Lernen/\(id)/kurs.json"]
    }

    /// The item of a record (document, note, world …) by its id, as it is on disk now.
    func item(forRecord id: UUID) -> LibraryItem? {
        let root = self.root
        guard let path = Self.mainPaths(for: id).first(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return nil }
        return LibraryItemResolver { try? Data(contentsOf: root.appendingPathComponent($0)) }.item(for: path)
    }
}

extension AppModel {
    /// Git Studio in the main area: the commit tree, branches and what each commit changed.
    func openGitStudio() {
        closeDocument()
        showChats()
        gitStudioOpen = true
    }
}
