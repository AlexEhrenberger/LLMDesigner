import Foundation

/// The `git` program on this Mac. LLM Designer calls the ordinary command line tool rather than a library, so the
/// Terminal, Fork or VS Code see exactly the repository the app sees, and no third-party code comes in.
struct GitTool: Sendable, Hashable {
    let executable: URL

    /// The first usable `git`: a path the person set, then Homebrew, then `/usr/local`, then Apple's. `/usr/bin/git`
    /// is only a shim that opens an installer dialog when the Command Line Tools are missing, so it only counts when
    /// they are there.
    static func find(preferred: String? = nil) -> GitTool? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        if fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") {
            candidates.append("/usr/bin/git")
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { GitTool(executable: URL(fileURLWithPath: $0)) }
    }
}

struct GitResult: Sendable {
    let status: Int32
    let output: Data
    let errorText: String

    var text: String { String(decoding: output, as: UTF8.self) }
    var succeeded: Bool { status == 0 }
}

enum GitError: LocalizedError, Equatable {
    case notInstalled
    case notARepository
    case failed(String, String)
    case timeout(String)
    /// The repository's own configuration would make git start programs (see `GitConfigCheck`).
    case unsafeConfiguration([String])
    case noIdentity
    case busy(String)
    case unsuitableLocation(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Git ist auf diesem Mac nicht installiert. Im Terminal: xcode-select --install (oder brew install git)."
        case .notARepository:
            "Für diese Bibliothek ist Git nicht eingeschaltet."
        case .failed(let command, let message):
            "git \(command) hat nicht geklappt: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timeout(let command):
            "git \(command) hat zu lange gebraucht und wurde abgebrochen."
        case .unsafeConfiguration(let keys):
            "Die Git-Einstellungen dieser Bibliothek würden Programme starten (\(keys.joined(separator: ", "))). LLM Designer ruft Git hier nicht auf. Entferne sie im Terminal mit git config --local --unset <Schlüssel>, wenn du sie nicht selbst gesetzt hast."
        case .noIdentity:
            "Git kennt noch keinen Namen und keine E-Mail für Commits."
        case .busy(let reason):
            "Gerade geht das nicht: \(reason)"
        case .unsuitableLocation(let reason):
            reason
        }
    }
}

/// A repository: here always one library. Every call goes through `run`, which adds the fixed safety options.
struct GitRepository: Sendable {
    let root: URL
    let tool: GitTool
    /// Extra environment, for tests (`GIT_CONFIG_GLOBAL=/dev/null` and the like).
    var environment: [String: String] = [:]

    var gitDirectory: URL { root.appendingPathComponent(".git", isDirectory: true) }
    var exists: Bool { FileManager.default.fileExists(atPath: gitDirectory.path) }

    /// Options that hold for every call. A library is portable and may come from elsewhere, and its `.git/config` or
    /// hooks could start programs; hooks and the file system monitor are always off, and no pager or editor opens.
    static let safetyOptions = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.quotePath=false",
        "-c", "core.pager=cat",
        "-c", "core.editor=:",
        "-c", "color.ui=never",
        "-c", "advice.detachedHead=false",
    ]

    /// Runs git in the library, off the main actor. A failing status throws unless `allowFailure` is set.
    @discardableResult
    func run(_ arguments: [String], input: Data? = nil, allowFailure: Bool = false, timeout: TimeInterval = 120) async throws -> GitResult {
        let process = Process()
        process.executableURL = tool.executable
        process.arguments = ["-C", root.path] + Self.safetyOptions + arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_ASKPASS", "SSH_ASKPASS"] { env.removeValue(forKey: key) }
        // Never wait for a password prompt that nobody sees; the keychain or SSH agent answers, or the call fails.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = ":"
        // `status` would otherwise refresh the index, which the watcher sees and which would ask for another status.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin

        let name = arguments.first ?? ""
        let result: GitResult = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitError.notInstalled)
                    return
                }
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                var timedOut = false
                let timer = DispatchWorkItem {
                    timedOut = true
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Both pipes are read at the same time, so a long error output can't block a long result.
                var errorData = Data()
                let errorReader = DispatchQueue(label: "LLMDesigner.git.stderr")
                let group = DispatchGroup()
                group.enter()
                errorReader.async {
                    errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                if timedOut {
                    continuation.resume(throwing: GitError.timeout(name))
                } else {
                    continuation.resume(returning: GitResult(status: process.terminationStatus, output: data,
                                                             errorText: String(decoding: errorData, as: UTF8.self)))
                }
            }
        }
        if !result.succeeded && !allowFailure {
            let message = result.errorText.isEmpty ? result.text : result.errorText
            throw GitError.failed(name, message)
        }
        return result
    }

    /// The repository's own configuration, checked before git does anything that reads it in depth.
    func checkConfiguration(allowedDrivers: [String: String] = [:]) async throws {
        let result = try await run(["config", "--local", "--list", "-z"], allowFailure: true)
        guard result.succeeded else { return }
        let unsafe = GitConfigCheck.unsafeKeys(in: GitConfigCheck.entries(result.output), allowedDrivers: allowedDrivers)
        if !unsafe.isEmpty { throw GitError.unsafeConfiguration(unsafe) }
    }
}

/// Which keys of a repository's own configuration would start a program. The app's own merge and diff drivers count
/// as safe only with exactly the command the app writes.
enum GitConfigCheck {
    struct Entry: Equatable {
        var key: String
        var value: String
    }

    static func entries(_ data: Data) -> [Entry] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").compactMap { item in
            let parts = item.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { return nil }
            return Entry(key: key.lowercased(), value: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    private static let exactKeys: Set<String> = [
        "core.sshcommand", "core.pager", "core.editor", "core.fsmonitor", "core.hookspath", "core.askpass",
        "core.gitproxy", "diff.external", "gpg.program", "gpg.ssh.program", "gpg.x509.program", "credential.helper",
        "sequence.editor", "uploadpack.packobjectshook", "include.path", "http.proxy", "remote.origin.uploadpack",
        "remote.origin.receivepack", "protocol.ext.allow", "core.alternaterefscommand", "filter.lfs.process",
    ]

    static func unsafeKeys(in entries: [Entry], allowedDrivers: [String: String] = [:]) -> [String] {
        var found: [String] = []
        for entry in entries {
            let key = entry.key
            if let allowed = allowedDrivers[key] {
                if entry.value != allowed { found.append(key) }
                continue
            }
            let isUnsafe = exactKeys.contains(key)
                || key.hasPrefix("includeif.")
                || key.hasPrefix("filter.")
                || (key.hasPrefix("diff.") && (key.hasSuffix(".command") || key.hasSuffix(".textconv")))
                || (key.hasPrefix("merge.") && key.hasSuffix(".driver"))
                || (key.hasPrefix("remote.") && (key.hasSuffix(".uploadpack") || key.hasSuffix(".receivepack") || key.hasSuffix(".proxy")))
                || (key.hasPrefix("alias.") && entry.value.hasPrefix("!"))
                || key.hasPrefix("credential.")
                || (key.hasPrefix("core.") && key.hasSuffix("command"))
            if isUnsafe { found.append(key) }
        }
        return found
    }
}
