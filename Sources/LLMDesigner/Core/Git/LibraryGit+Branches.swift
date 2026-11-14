import Foundation

/// A branch or tag as the Git Studio lists it.
struct GitRef: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case local, remote, tag }

    var kind: Kind
    /// `main`, `origin/main`, `Abgabe`.
    var name: String
    var isCurrent: Bool
    var upstream: String?
    var ahead = 0
    var behind = 0
    var date: Date
    var subject: String
    /// Everything of it is already in the current branch.
    var isMerged = false

    var id: String { "\(kind.rawValue):\(name)" }
}

/// Work put aside with `git stash` ("Zurückgelegt").
struct GitStash: Identifiable, Hashable, Sendable {
    var ref: String
    var message: String
    var date: Date
    var id: String { ref }
}

@MainActor
extension LibraryGit {
    // MARK: Listing

    func refs() async throws -> [GitRef] {
        let repository = try await checkedRepository()
        let format = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)%1f%(contents:subject)%1e"
        let result = try await repository.run(["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes", "refs/tags"])
        let merged = try await repository.run(["for-each-ref", "--merged=HEAD", "--format=%(refname)", "refs/heads", "refs/remotes"], allowFailure: true)
        let mergedRefs = Set(merged.text.split(separator: "\n").map(String.init))
        return result.text.components(separatedBy: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 7 else { return nil }
            let full = fields[0]
            let kind: GitRef.Kind = full.hasPrefix("refs/heads/") ? .local : full.hasPrefix("refs/tags/") ? .tag : .remote
            // `origin/HEAD` only points at the remote's default branch.
            if kind == .remote, full.hasSuffix("/HEAD") { return nil }
            var ref = GitRef(kind: kind, name: fields[1], isCurrent: fields[2] == "*", upstream: fields[3].isEmpty ? nil : fields[3],
                             date: Date(timeIntervalSince1970: TimeInterval(fields[5]) ?? 0), subject: fields[6])
            for part in fields[4].split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.count == 2, let number = Int(words[1]) else { continue }
                if words[0] == "ahead" { ref.ahead = number }
                if words[0] == "behind" { ref.behind = number }
            }
            ref.isMerged = !ref.isCurrent && mergedRefs.contains(full)
            return ref
        }
    }

    func stashes() async throws -> [GitStash] {
        let repository = try await checkedRepository()
        let result = try await repository.run(["stash", "list", "--format=%gd%x1f%s%x1f%ct"], allowFailure: true)
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 3 else { return nil }
            return GitStash(ref: fields[0], message: fields[1], date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0))
        }
    }

    // MARK: Names

    /// Whether git takes this as a branch name; spaces become dashes first.
    func validBranchName(_ name: String) async -> String? {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix("-"), let repository else { return nil }
        let result = try? await repository.run(["check-ref-format", "--branch", clean], allowFailure: true)
        return result?.succeeded == true ? clean : nil
    }

    private func requireRevision(_ revision: String, in repository: GitRepository) async throws -> String {
        guard !revision.hasPrefix("-") else { throw GitError.failed("rev-parse", "„\(revision)“ ist kein Commit.") }
        let result = try await repository.run(["rev-parse", "--verify", "-q", "\(revision)^{commit}"], allowFailure: true)
        guard result.succeeded else { throw GitError.failed("rev-parse", "Den Commit „\(revision)“ gibt es nicht.") }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Branches

    /// A new branch at HEAD or at a commit; with `switchTo` the library changes over to it at once (it has the same
    /// files, so nothing reloads unless it starts at another commit).
    func createBranch(_ name: String, at revision: String? = nil, switchTo: Bool = true) async throws {
        guard let clean = await validBranchName(name) else { throw GitError.failed("branch", "„\(name)“ geht als Branch-Name nicht.") }
        let startsElsewhere = revision != nil
        try await perform("Branch", changesFiles: switchTo && startsElsewhere) { repository in
            var arguments = switchTo ? ["switch", "-q", "-c", clean] : ["branch", clean]
            if let revision { arguments.append(try await requireRevision(revision, in: repository)) }
            try await repository.run(arguments)
        }
    }

    /// Changes the library over to another branch. Uncommitted changes would mix into it, so they have to be
    /// committed or put aside first.
    func switchBranch(_ name: String) async throws {
        await refresh()
        guard !isMerging else { throw GitError.busy("Ein Zusammenführen läuft. Schließe es ab oder brich es ab.") }
        guard changes.isEmpty else { throw GitError.busy("Es gibt Änderungen, die noch nicht committet sind. Committe sie oder lege sie zurück, dann geht der Wechsel.") }
        guard !name.hasPrefix("-") else { throw GitError.failed("switch", "„\(name)“ ist kein Branch.") }
        let refs = try await refs()
        guard let ref = refs.first(where: { $0.name == name && $0.kind != .tag }) else { throw GitError.failed("switch", "Den Branch „\(name)“ gibt es nicht.") }
        try await perform("Wechseln", changesFiles: true) { repository in
            if ref.kind == .remote {
                let local = String(name.drop { $0 != "/" }.dropFirst())
                if refs.contains(where: { $0.kind == .local && $0.name == local }) {
                    try await repository.run(["switch", "-q", local])
                } else {
                    try await repository.run(["switch", "-q", "--track", name])
                }
            } else {
                try await repository.run(["switch", "-q", name])
            }
        }
    }

    func renameBranch(_ name: String, to newName: String) async throws {
        guard !name.hasPrefix("-"), let clean = await validBranchName(newName) else { throw GitError.failed("branch", "„\(newName)“ geht als Branch-Name nicht.") }
        try await perform("Umbenennen") { repository in
            try await repository.run(["branch", "-m", name, clean])
        }
    }

    /// Deletes a local branch. One that isn't merged yet only goes with `force`, which the interface asks for.
    func deleteBranch(_ name: String, force: Bool = false) async throws {
        guard !name.hasPrefix("-") else { throw GitError.failed("branch", "„\(name)“ ist kein Branch.") }
        guard name != branch else { throw GitError.busy("Der aktuelle Branch lässt sich nicht löschen. Wechsle vorher.") }
        try await perform("Löschen") { repository in
            let result = try await repository.run(["branch", force ? "-D" : "-d", name], allowFailure: true)
            guard result.succeeded else {
                throw GitError.failed("branch", force ? result.errorText : "„\(name)“ ist noch nicht zusammengeführt; seine Commits gingen verloren.")
            }
        }
    }

    // MARK: Tags, revert, stash

    func tag(_ name: String, at revision: String = "HEAD", message: String? = nil) async throws {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix("-") else { throw GitError.failed("tag", "„\(name)“ geht als Tag nicht.") }
        try await perform("Tag") { repository in
            let commit = try await requireRevision(revision, in: repository)
            let check = try await repository.run(["check-ref-format", "refs/tags/\(clean)"], allowFailure: true)
            guard check.succeeded else { throw GitError.failed("tag", "„\(name)“ geht als Tag nicht.") }
            try await repository.run(["tag", "-a", clean, "-m", message ?? clean, commit])
        }
    }

    /// Takes a commit back with a new commit that does the opposite. A merge commit is taken back against its first
    /// parent. If that collides with later changes, nothing happens and the app says so.
    func revert(_ revision: String) async throws {
        await refresh()
        guard changes.isEmpty else { throw GitError.uncommittedChanges }
        try await perform("Rückgängig", changesFiles: true) { repository in
            let commit = try await requireRevision(revision, in: repository)
            let parents = try await repository.run(["rev-list", "--parents", "-n", "1", commit]).text.split(separator: " ").count - 1
            var arguments = ["revert", "--no-edit"]
            if parents > 1 { arguments += ["-m", "1"] }
            let result = try await repository.run(arguments + [commit], allowFailure: true)
            if !result.succeeded {
                _ = try? await repository.run(["revert", "--abort"], allowFailure: true)
                throw GitError.failed("revert", "Der Commit lässt sich nicht von selbst zurücknehmen, weil spätere Änderungen dieselben Stellen betreffen. Stelle die Dinge einzeln wieder her.")
            }
        }
    }

    /// Puts the uncommitted changes aside, so a branch can be switched; they come back with `applyStash`.
    func stash(_ message: String) async throws {
        await refresh()
        guard !changes.isEmpty else { throw GitError.nothingToCommit }
        try await perform("Zurücklegen", changesFiles: true) { repository in
            try await repository.run(["stash", "push", "-u", "-q", "-m", message.isEmpty ? "Zurückgelegt" : message])
        }
    }

    func applyStash(_ ref: String) async throws {
        guard ref.hasPrefix("stash@{") else { throw GitError.failed("stash", "„\(ref)“ ist nichts Zurückgelegtes.") }
        await refresh()
        guard changes.isEmpty else { throw GitError.uncommittedChanges }
        try await perform("Hervorholen", changesFiles: true) { repository in
            let result = try await repository.run(["stash", "pop", "-q", ref], allowFailure: true)
            guard result.succeeded else {
                _ = try? await repository.run(["reset", "-q", "--merge"], allowFailure: true)
                throw GitError.failed("stash", "Das Zurückgelegte passt nicht mehr auf den jetzigen Stand; es bleibt zurückgelegt.")
            }
        }
    }

    func dropStash(_ ref: String) async throws {
        guard ref.hasPrefix("stash@{") else { throw GitError.failed("stash", "„\(ref)“ ist nichts Zurückgelegtes.") }
        try await perform("Verwerfen") { repository in
            try await repository.run(["stash", "drop", "-q", ref])
        }
    }
}
