import Foundation

extension GitError {
    static let nothingToCommit = GitError.failed("commit", "Es gibt nichts zu committen.")
    static let emptyMessage = GitError.failed("commit", "Bitte eine Nachricht schreiben.")
    static let noRemote = GitError.failed("push", "Diese Bibliothek ist noch mit keinem Remote verbunden (GitHub, GitLab …).")
    static let diverged = GitError.failed("pull", "Der Remote und diese Bibliothek haben beide neue Commits. Sie müssen zusammengeführt werden.")
}

/// The everyday git calls of the app. They take items, not paths, and say what they did in German.
@MainActor
extension LibraryGit {
    // MARK: Commit

    /// The body below the subject: one line per item, so `git log` in the Terminal names titles, not UUIDs.
    nonisolated static func commitMessage(_ message: String, groups: [GitChangeGroup], trailers: [(String, String)] = []) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !groups.isEmpty {
            text += "\n\n" + groups.map { "- \($0.item.kind.label) „\($0.item.title)“: \($0.summary)" }.joined(separator: "\n")
        }
        if !trailers.isEmpty {
            text += "\n\n" + trailers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }
        return text + "\n"
    }

    /// Commits the given items, or everything when `groups` is nil. Files above the size limit go to `.gitignore`
    /// instead (they are named in `skipped`).
    @discardableResult
    func commit(_ groups: [GitChangeGroup]? = nil, message: String, trailers: [(String, String)] = [], author: String? = nil) async throws -> (commit: GitCommit, skipped: [String]) {
        let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { throw GitError.emptyMessage }
        return try await perform("Commit") { repository in
            await refresh()
            let chosen = groups.map { wanted in changes.filter { group in wanted.contains { $0.id == group.id } } } ?? changes
            guard !chosen.isEmpty else { throw GitError.nothingToCommit }
            var paths = chosen.flatMap(\.paths)
            let large = paths.filter { path in
                let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? Int) ?? 0
                return size > GitSetup.largeFileLimit
            }
            if !large.isEmpty {
                try GitSetup.ignore(large, in: root)
                paths.removeAll { large.contains($0) }
                if !paths.contains(".gitignore") { paths.append(".gitignore") }
            }
            let text = Self.commitMessage(subject, groups: chosen, trailers: trailers)
            try await repository.run(["add", "-A", "--"] + paths)
            var arguments = ["commit", "-q", "-F", "-"]
            if let author { arguments += ["--author", author] }
            // With paths, git commits exactly these, whatever else was staged in the Terminal.
            if groups != nil { arguments += ["--"] + paths }
            try await repository.run(arguments, input: Data(text.utf8))
            let head = try await log(limit: 1).first
            guard let head else { throw GitError.nothingToCommit }
            return (head, large)
        }
    }

    // MARK: History

    /// Commits, newest first; of one item when `paths` is given (following renames for a single file).
    func log(paths: [String] = [], limit: Int = 50, all: Bool = false, skip: Int = 0, revision: String? = nil) async throws -> [GitCommit] {
        let repository = try await checkedRepository()
        let head = try await repository.run(["rev-parse", "--verify", "-q", "HEAD"], allowFailure: true)
        guard head.succeeded || all else { return [] }
        var arguments = ["log", "--format=\(GitCommit.format)", "-n", "\(limit)", "--skip", "\(skip)"]
        if all { arguments += ["--all", "--topo-order"] }
        if let revision {
            guard !revision.hasPrefix("-") else { return [] }
            arguments.append(revision)
        }
        if paths.count == 1 { arguments.append("--follow") }
        if !paths.isEmpty { arguments += ["--"] + paths }
        let result = try await repository.run(arguments, allowFailure: true)
        return result.succeeded ? GitCommit.parse(result.output) : []
    }

    /// The history of one item, by its files as they are now (and as git still knows them).
    func history(of item: LibraryItem, limit: Int = 50) async throws -> [GitCommit] {
        try await log(paths: [item.mainPath ?? item.key], limit: limit)
    }

    /// A file's content at a commit, or nil where it didn't exist.
    func content(of path: String, at revision: String) async throws -> Data? {
        let repository = try await checkedRepository()
        let result = try await repository.run(["show", "\(revision):\(path)"], allowFailure: true)
        return result.succeeded ? result.output : nil
    }

    /// The files a commit changed (against its first parent).
    func changedPaths(in commit: String) async throws -> [String] {
        let repository = try await checkedRepository()
        let result = try await repository.run(["show", "--name-only", "--format=", "-z", "--first-parent", "-m", commit])
        return Array(Set(result.text.split(separator: "\0").map(String.init).filter { !$0.isEmpty })).sorted()
    }

    /// The items a commit changed, named as they were at that commit.
    func changedItems(in commit: GitCommit) async throws -> [GitChangeGroup] {
        let paths = try await changedPaths(in: commit.id)
        var contents: [String: Data] = [:]
        for path in paths {
            let main = LibraryItemResolver.place(of: path).mainPath ?? path
            if contents[main] == nil {
                contents[main] = try await content(of: main, at: commit.id)
                if contents[main] == nil, let parent = commit.parents.first { contents[main] = try await content(of: main, at: parent) }
            }
        }
        let resolver = LibraryItemResolver { contents[$0] }
        return resolver.group(paths).map { group in
            GitChangeGroup(item: group.item, entries: group.paths.map { GitStatus.Entry(path: $0, change: .modified, isStaged: true) })
        }
    }

    // MARK: Restore

    /// Puts an item back to how it was at a commit. What is there now is committed first ("Stand vor
    /// Wiederherstellen"), so nothing is lost; the restored version stays as a change to look at and commit.
    func restore(_ item: LibraryItem, to commit: String) async throws {
        try await perform("Wiederherstellen", changesFiles: true) { repository in
            await refresh()
            if let current = changes.first(where: { $0.item.id == item.id }) {
                let text = Self.commitMessage("Stand vor Wiederherstellen: \(item.title)", groups: [current])
                try await repository.run(["add", "-A", "--"] + current.paths)
                try await repository.run(["commit", "-q", "-F", "-", "--"] + current.paths, input: Data(text.utf8))
            }
            let place = LibraryItemResolver.place(of: item.mainPath ?? item.key)
            let scope = Self.scope(of: item, place: place)
            let listed = try await repository.run(["ls-tree", "-r", "--name-only", "-z", commit, "--"] + scope)
            let then = listed.text.split(separator: "\0").map(String.init)
            guard !then.isEmpty else { throw GitError.failed("restore", "„\(item.title)“ gab es in diesem Stand noch nicht.") }
            let nowResult = try await repository.run(["ls-files", "-z", "--"] + scope)
            let now = nowResult.text.split(separator: "\0").map(String.init)
            try await repository.run(["restore", "--source=\(commit)", "--worktree", "--"] + then)
            // Files the item got later go away, as they weren't there then.
            for path in now where !then.contains(path) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            }
        }
    }

    /// The paths that belong to an item: its file, or its folder when it has one.
    nonisolated static func scope(of item: LibraryItem, place: (kind: LibraryItemKind, key: String, mainPath: String?)) -> [String] {
        guard let main = item.mainPath else { return [item.key] }
        let folder = (main as NSString).deletingLastPathComponent
        switch item.kind {
        case .podcast, .template, .research, .course: return [folder]
        case .world: return [main, "Geschichten/Bilder/\(item.key)", "Geschichten/Videos/\(item.key)"]
        case .source: return [main, "Zitate/Anhänge/\(item.key)"]
        case .project: return [main, "Projekte/Audio/\(item.key)"]
        default: return [main]
        }
    }

    // MARK: Remote

    struct Remote: Equatable, Sendable {
        var name: String
        var url: String
    }

    func remotes() async throws -> [Remote] {
        let repository = try await checkedRepository()
        let result = try await repository.run(["remote", "-v"])
        var seen = Set<String>()
        return result.text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, seen.insert(parts[0]).inserted else { return nil }
            return Remote(name: parts[0], url: parts[1])
        }
    }

    /// Only addresses git can push to without running anything: https, ssh and scp-like `git@host:path`.
    nonisolated static func isValidRemoteURL(_ url: String) -> Bool {
        let text = url.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" "), !text.hasPrefix("-"), !text.contains("::") else { return false }
        if text.hasPrefix("https://") || text.hasPrefix("ssh://") { return URL(string: text)?.host != nil }
        return text.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/~-]+$"#, options: .regularExpression) != nil
    }

    /// Connects the library with a remote as `origin`. Only the interface calls this: no agent may change where a
    /// push goes.
    func setRemote(_ url: String) async throws {
        let url = url.trimmingCharacters(in: .whitespaces)
        guard Self.isValidRemoteURL(url) else {
            throw GitError.failed("remote", "„\(url)“ ist keine Adresse, die Git kennt (https://… oder git@host:pfad).")
        }
        try await perform("Remote") { repository in
            let existing = try await remotes()
            if existing.contains(where: { $0.name == "origin" }) {
                try await repository.run(["remote", "set-url", "origin", url])
            } else {
                try await repository.run(["remote", "add", "origin", url])
            }
        }
    }

    func push() async throws {
        try await perform("Push") { repository in
            guard try await !remotes().isEmpty else { throw GitError.noRemote }
            if status?.upstream == nil {
                try await repository.run(["push", "-u", "origin", "HEAD"], timeout: 300)
            } else {
                try await repository.run(["push"], timeout: 300)
            }
        }
    }

    func fetch() async throws {
        try await perform("Fetch") { repository in
            guard try await !remotes().isEmpty else { throw GitError.noRemote }
            try await repository.run(["fetch", "--prune", "origin"], timeout: 300)
        }
    }

    /// Takes over new commits from the remote when that works without a merge; otherwise says so (`diverged`).
    func pull() async throws {
        try await perform("Pull", changesFiles: true) { repository in
            guard try await !remotes().isEmpty else { throw GitError.noRemote }
            try await repository.run(["fetch", "--prune", "origin"], timeout: 300)
            await refresh()
            guard status?.upstream != nil else { return }
            if (status?.behind ?? 0) == 0 { return }
            if (status?.ahead ?? 0) > 0 { throw GitError.diverged }
            try await repository.run(["merge", "--ff-only", "-q", "@{upstream}"])
        }
    }
}

/// GitHub's own command line tool, when it is installed and signed in: it can make a new private repository.
enum GitHubCLI {
    static var executable: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func isSignedIn() async -> Bool {
        guard let executable else { return false }
        return (try? await run(executable, ["auth", "status"]))?.status == 0
    }

    /// `gh repo create <name> --private --source <library> --remote origin --push`.
    static func createPrivateRepository(named name: String, for root: URL) async throws {
        guard let executable else { throw GitError.failed("gh", "Die GitHub-App für das Terminal (gh) ist nicht installiert.") }
        let clean = name.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
        guard !clean.isEmpty, !clean.hasPrefix("-") else { throw GitError.failed("gh", "Dieser Name geht als Repository nicht.") }
        let result = try await run(executable, ["repo", "create", clean, "--private", "--source", root.path, "--remote", "origin", "--push"])
        guard result.status == 0 else { throw GitError.failed("gh repo create", result.errorText) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["GH_PROMPT_DISABLED"] = "1"
                env["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = env
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: GitResult(status: process.terminationStatus, output: data, errorText: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }
}

@MainActor
extension LibraryGit {
    /// The helper that ships inside the app, for hooks and merge drivers.
    nonisolated static var llmdPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llmd").path
    }

    static let hookMarker = "# LLM Designer: pre-commit"

    /// A hook for commits made in the Terminal: the app first writes what waits for a pause in typing. If that made a
    /// staged file newer, the commit stops and says so, rather than committing an older version than the one on disk.
    /// The app's own calls never run hooks.
    func installFlushHook() async throws {
        _ = try await checkedRepository()
        let hooks = root.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        if let existing = try? String(contentsOf: hook, encoding: .utf8), !existing.contains(Self.hookMarker) {
            throw GitError.failed("hook", "Es gibt schon einen eigenen pre-commit-Hook. LLM Designer überschreibt ihn nicht.")
        }
        let path = Self.llmdPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        \(Self.hookMarker)
        # Schreibt vor einem Commit im Terminal, was in LLM Designer noch auf eine Tipp-Pause wartet.
        LLMD='\(path)'
        [ -x "$LLMD" ] || exit 0
        "$LLMD" git flush >/dev/null 2>&1 || exit 0
        list=$(mktemp)
        git diff --cached --name-only > "$list"
        newer=$(git diff --name-only | grep -Fx -f "$list")
        rm -f "$list"
        if [ -n "$newer" ]; then
          echo "LLM Designer hat gerade noch gespeichert:"
          echo "$newer"
          echo "Bitte mit git add übernehmen und noch einmal committen."
          exit 1
        fi
        exit 0

        """
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }
}
