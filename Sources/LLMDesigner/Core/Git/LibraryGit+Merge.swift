import Foundation
import LibraryMerge

/// A file git couldn't merge by itself: the three versions from the index and, for text, the merge by blocks.
struct GitConflictFile: Identifiable, Sendable {
    var path: String
    var item: LibraryItem
    /// Stage 1 (common), 2 (this side), 3 (the other side); nil where that side doesn't have the file.
    var base: String?
    var ours: String?
    var theirs: String?
    /// For text files: the conflicts by paragraph, slide or entry. Nil for pictures and other binary files, which
    /// are one choice as a whole.
    var merge: MergeResult?

    var id: String { path }
    var isText: Bool { merge != nil }
}

enum GitMergeOutcome: Equatable, Sendable {
    case upToDate
    case fastForward
    case merged
    case conflicts(Int)

    var message: String {
        switch self {
        case .upToDate: "Es gab nichts zusammenzuführen."
        case .fastForward: "Übernommen (ohne eigenen Merge-Commit)."
        case .merged: "Zusammengeführt."
        case .conflicts(let count): "\(count) Datei(en) mit Konflikten: In der Konfliktansicht entscheiden, dann abschließen."
        }
    }
}

extension GitError {
    static let uncommittedChanges = GitError.busy("Es gibt Änderungen, die noch nicht committet sind. Committe sie zuerst, dann geht das Zusammenführen.")
}

@MainActor
extension LibraryGit {
    /// Set before the reload that follows a merge with conflicts: the next model opens the conflict view.
    nonisolated(unsafe) static var openConflictsAfterReload = false

    /// Files that go through the merge by blocks; everything else is one choice as a whole.
    nonisolated static func isMergeableText(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".md", ".json", ".txt", ".plist", ".css", ".gitignore", ".gitattributes"].contains { lower.hasSuffix($0) }
    }

    // MARK: Merging

    /// Merges a branch (or `origin/main`) into the current one. Conflicts are no error: they wait in the conflict
    /// view, while every file stays one the app can open.
    @discardableResult
    func merge(_ branch: String, message: String? = nil) async throws -> GitMergeOutcome {
        let name = branch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitError.failed("merge", "„\(branch)“ ist kein Branch.") }
        await refresh()
        guard !isMerging else { throw GitError.busy("Ein Zusammenführen läuft schon. Schließe es ab oder brich es ab.") }
        guard changes.isEmpty else { throw GitError.uncommittedChanges }
        return try await perform("Zusammenführen", changesFiles: true) { repository in
            let target = try await repository.run(["rev-parse", "--verify", "-q", "\(name)^{commit}"], allowFailure: true)
            guard target.succeeded else { throw GitError.failed("merge", "Den Branch „\(name)“ gibt es nicht.") }
            let before = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = status?.branch ?? "HEAD"
            let text = message ?? "„\(name)“ in „\(current)“ zusammengeführt"
            let result = try await repository.run(["merge", "--no-edit", "-q", "-m", text, name], allowFailure: true, timeout: 300)
            await refresh()
            if !result.succeeded {
                guard let status, status.hasConflicts else {
                    throw GitError.failed("merge", result.errorText.isEmpty ? result.text : result.errorText)
                }
                let count = Set(status.entries.filter { $0.change == .conflicted }.map(\.path)).count
                Self.openConflictsAfterReload = true
                return .conflicts(count)
            }
            let after = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if after == before { return .upToDate }
            let parents = try await repository.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " ").count - 1
            return parents > 1 ? .merged : .fastForward
        }
    }

    /// Fetches and merges what the remote has, for when a plain pull can't go ahead (both sides have new commits).
    @discardableResult
    func pullMerging() async throws -> GitMergeOutcome {
        try await fetch()
        guard let upstream = status?.upstream else { throw GitError.noRemote }
        return try await merge(upstream, message: "Stand von \(upstream) übernommen")
    }

    // MARK: Conflicts

    func conflictFiles() async throws -> [GitConflictFile] {
        let repository = try await checkedRepository()
        await refresh()
        let paths = Array(Set((status?.entries ?? []).filter { $0.change == .conflicted }.map(\.path))).sorted()
        var files: [GitConflictFile] = []
        for path in paths {
            func stage(_ number: Int) async -> Data? {
                let result = try? await repository.run(["show", ":\(number):\(path)"], allowFailure: true)
                return result?.succeeded == true ? result?.output : nil
            }
            let base = await stage(1), ours = await stage(2), theirs = await stage(3)
            let resolver = LibraryItemResolver { $0 == path ? (ours ?? theirs ?? base) : (try? Data(contentsOf: self.root.appendingPathComponent($0))) }
            var file = GitConflictFile(path: path, item: resolver.item(for: path))
            if Self.isMergeableText(path) {
                file.base = base.map { String(decoding: $0, as: UTF8.self) }
                file.ours = ours.map { String(decoding: $0, as: UTF8.self) }
                file.theirs = theirs.map { String(decoding: $0, as: UTF8.self) }
                file.merge = LibraryMerge.merge(path: path, base: file.base, ours: file.ours, theirs: file.theirs)
            }
            files.append(file)
        }
        return files
    }

    /// Settles one file. Text: the merge with these choices (unchosen conflicts keep this side's version). Other
    /// files: `.ours` or `.theirs` as a whole. A side without the file means the file goes.
    func resolve(_ file: GitConflictFile, choices: [Int: MergeChoice] = [:], whole: MergeChoice? = nil) async throws {
        try await perform("Konflikt lösen") { repository in
            let url = root.appendingPathComponent(file.path)
            if file.isText && whole == nil {
                let result = LibraryMerge.merge(path: file.path, base: file.base, ours: file.ours, theirs: file.theirs, choices: choices)
                if let text = result.text {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    try await repository.run(["add", "--", file.path])
                } else {
                    try await repository.run(["rm", "-q", "--cached", "--ignore-unmatch", "--", file.path])
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            let side = whole ?? .ours
            let present = try await repository.run(["show", ":\(side == .theirs ? 3 : 2):\(file.path)"], allowFailure: true)
            if present.succeeded {
                try await repository.run(["checkout", side == .theirs ? "--theirs" : "--ours", "--", file.path])
                try await repository.run(["add", "--", file.path])
            } else {
                try await repository.run(["rm", "-q", "--cached", "--ignore-unmatch", "--", file.path])
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The merge commit, once no file has conflicts left. The library reloads with the merged files.
    func finishMerge() async throws {
        await refresh()
        guard isMerging else { throw GitError.failed("merge", "Es läuft kein Zusammenführen.") }
        guard status?.hasConflicts != true else { throw GitError.busy("Es gibt noch Dateien mit Konflikten.") }
        try await perform("Abschließen", changesFiles: true) { repository in
            try await repository.run(["commit", "--no-edit", "-q"])
        }
    }

    /// Back to the state before the merge.
    func abortMerge() async throws {
        try await perform("Abbrechen", changesFiles: true) { repository in
            try await repository.run(["merge", "--abort"])
        }
    }

    /// A merge in the Terminal without the driver leaves `<<<<<<<` in files. Those files are rewritten with the merge
    /// by blocks (this side's version where it conflicts), so the app never shows conflict marks as text. Returns
    /// whether anything was rewritten.
    func repairConflictMarkers(_ status: GitStatus) async -> Bool {
        guard let repository = try? await checkedRepository() else { return false }
        var repaired = false
        for path in Set(status.entries.filter { $0.change == .conflicted }.map(\.path)) where Self.isMergeableText(path) {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8), Self.hasConflictMarkers(text) else { continue }
            func stage(_ number: Int) async -> String? {
                guard let result = try? await repository.run(["show", ":\(number):\(path)"], allowFailure: true), result.succeeded else { return nil }
                return String(decoding: result.output, as: UTF8.self)
            }
            let merged = LibraryMerge.merge(path: path, base: await stage(1), ours: await stage(2), theirs: await stage(3))
            guard let fixed = merged.text else { continue }
            try? fixed.write(to: url, atomically: true, encoding: .utf8)
            repaired = true
        }
        return repaired
    }

    nonisolated static func hasConflictMarkers(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasPrefix("<<<<<<< ") || $0 == "<<<<<<<" }
            && text.contains("\n=======") && text.contains("\n>>>>>>>")
    }
}
