import CoreServices
import Foundation

/// What changed in the library from outside the app since the last report.
struct ExternalChanges: Sendable, Equatable {
    /// Library files (relative paths) another program wrote or removed.
    var paths: Set<String> = []
    /// HEAD, a branch or a merge state changed: a checkout, merge, reset or pull.
    var headChanged = false
    /// Only the index or refs changed (`git add`, `git fetch`): the status is stale, the data isn't.
    var repositoryChanged = false

    var isEmpty: Bool { paths.isEmpty && !headChanged && !repositoryChanged }

    /// Sorts one event path (relative to the library) into the report. The app's own writes never get here: the
    /// stream marks them (`kFSEventStreamCreateFlagMarkSelf`).
    mutating func add(_ relative: String) {
        if relative == ".git" || relative.hasPrefix(".git/") {
            let inner = String(relative.dropFirst(min(relative.count, 5)))
            // A commit only moves a branch; a checkout, merge or revert in progress moves HEAD or leaves a *_HEAD.
            if ["HEAD", "MERGE_HEAD", "ORIG_HEAD", "REVERT_HEAD", "CHERRY_PICK_HEAD"].contains(inner) {
                headChanged = true
            } else if inner == "index" || inner.hasPrefix("refs/") || inner == "packed-refs" || inner == "FETCH_HEAD" {
                repositoryChanged = true
            }
            return
        }
        guard !Self.isIgnored(relative) else { return }
        paths.insert(relative)
    }

    /// Files whose change says nothing about the library's content, or that never reach the repository anyway.
    static func isIgnored(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent
        if name == ".DS_Store" || name.hasPrefix(".dat.nosync") || name.hasSuffix(".tmp") || name.hasPrefix("._") { return true }
        let ignored = ["Einstellungen.plist", "SidebarStacks.json", "llmd.token", "llmd.sock"]
        if ignored.contains(relative) { return true }
        return relative.contains("/Schnipsel/") || relative.hasPrefix("Chats/") || relative == "ChatFolders.json"
            || relative.hasPrefix("Attachments/") || relative.hasPrefix("Personas/") || relative.isEmpty
    }
}

/// Watches a library folder with FSEvents, file by file, and reports what other programs changed there, a little
/// after the last event so that a checkout of 200 files arrives as one report.
final class LibraryWatcher: @unchecked Sendable {
    private let root: URL
    private let rootPath: String
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "LLMDesigner.LibraryWatcher")
    private var pending = ExternalChanges()
    private var flush: DispatchWorkItem?
    private let delay: TimeInterval
    private let report: @Sendable (ExternalChanges) -> Void

    init(root: URL, delay: TimeInterval = 0.8, report: @escaping @Sendable (ExternalChanges) -> Void) {
        self.root = root
        // FSEvents reports resolved paths (/private/var for /var); compare against the same spelling.
        rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        self.delay = delay
        self.report = report
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagMarkSelf | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var entries: [String] = []
            for index in 0..<count where index < list.count {
                let flag = eventFlags[index]
                if flag & UInt32(kFSEventStreamEventFlagOwnEvent) != 0 { continue }
                entries.append(list[index])
            }
            watcher.received(entries)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [rootPath] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { flush?.cancel() }
    }

    deinit { stop() }

    private func received(_ absolute: [String]) {
        for path in absolute {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardized.hasPrefix(rootPath) else { continue }
            let relative = String(standardized.dropFirst(rootPath.count).drop { $0 == "/" })
            pending.add(relative)
        }
        guard !pending.isEmpty else { return }
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changes = self.pending
            self.pending = ExternalChanges()
            self.report(changes)
        }
        flush = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
