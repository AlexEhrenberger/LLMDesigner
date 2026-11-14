import Foundation
import LLMDProtocol
import LibraryMerge

extension ActionRegistry {
    func registerGitActions() {
        register(GitStatusAction.self)
        register(GitEnableAction.self)
        register(GitFlushAction.self)
        register(GitCommitAction.self)
        register(GitLogAction.self)
        register(GitShowAction.self)
        register(GitRestoreAction.self)
        register(GitFetchAction.self)
        register(GitPullAction.self)
        register(GitPushAction.self)
        register(GitMergeAction.self)
        register(GitConflictsAction.self)
        register(GitConflictResolveAction.self)
        register(GitMergeFinishAction.self)
        register(GitMergeAbortAction.self)
        register(GitBranchListAction.self)
        register(GitBranchCreateAction.self)
        register(GitBranchSwitchAction.self)
        register(GitBranchDeleteAction.self)
        register(GitTagAction.self)
        register(GitRevertAction.self)
        register(GitStashAction.self)
        register(GitStashApplyAction.self)
    }
}

/// Titles and commit messages may come from foreign documents or other people's commits.
private let gitRead = ActionSecurity.foreignRead
private let itemProperty: JSONSchema = .string("Ding der Bibliothek: ID (Dokument, Note, Romanwelt …) oder Titel")

// MARK: - Output

struct GitItemOutput: Encodable, Sendable {
    var kind: String
    var id: String
    var title: String
    var summary: String?
    var paths: [String]?

    init(_ group: GitChangeGroup) {
        kind = group.item.kind.rawValue
        id = group.item.key
        title = group.item.title
        summary = group.summary
        paths = group.paths
    }

    init(_ item: LibraryItem) {
        kind = item.kind.rawValue
        id = item.key
        title = item.title
    }
}

struct GitCommitOutput: Encodable, Sendable {
    var id: String
    var short: String
    var subject: String
    var author: String
    var date: String
    var parents: [String]
    var refs: [String]?
    var job: String?

    init(_ commit: GitCommit) {
        id = commit.id
        short = commit.shortID
        subject = commit.subject
        author = commit.author
        date = commit.date.formatted(.iso8601)
        parents = commit.parents
        refs = commit.refs.isEmpty ? nil : commit.refs
        job = commit.trailer("Auftrag")
    }
}

// MARK: - Finding

@MainActor
extension AppModel {
    /// The git of the open library, or an error that says how to turn it on.
    func actionGit() throws -> LibraryGit {
        guard git.isEnabled else { throw RPCError.invalidParams(GitError.notARepository.localizedDescription + " In LLM Designer: Power-Zugriff → Git → „Git einschalten“, oder llmd git enable.") }
        return git
    }

    /// An item by record id, by the title of a document, or by the title of a changed item.
    func actionGitItem(_ reference: String) throws -> LibraryItem {
        let git = try actionGit()
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text) {
            if let item = git.item(forRecord: id) { return item }
            if let changed = git.changes.first(where: { $0.item.recordID == id }) { return changed.item }
            throw RPCError.notFound("Zu \(text) gibt es nichts in der Bibliothek.")
        }
        let changed = git.changes.filter { $0.item.title.localizedCaseInsensitiveCompare(text) == .orderedSame }
        if changed.count == 1 { return changed[0].item }
        if let document = try? actionDocumentOrDeck(text), let item = git.item(forRecord: document.id) { return item }
        if changed.count > 1 { throw RPCError.ambiguous("Mehreres heißt „\(text)“. Bitte die ID verwenden.", candidates: changed.map(\.item.key)) }
        throw RPCError.notFound("„\(text)“ gibt es in der Bibliothek nicht.")
    }
}

private func gitCall<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as GitError {
        throw RPCError.invalidParams(error.localizedDescription)
    }
}

// MARK: - Actions

struct GitStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var enabled: Bool
        var branch: String?
        var upstream: String?
        var ahead: Int
        var behind: Int
        var conflicts: Bool
        var changes: [GitItemOutput]
        var problem: String?
    }
    static let descriptor = ActionDescriptor(
        id: "git.status", summary: "Zeigt Branch, Abstand zum Remote und die geänderten Dinge der Bibliothek mit Titeln",
        kind: .read, security: gitRead, output: .freeObject(), example: "llmd git status", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = context.app.git
        guard git.isEnabled else {
            return Output(enabled: false, ahead: 0, behind: 0, conflicts: false, changes: [], problem: git.problem)
        }
        context.app.saveEverythingForGit()
        await git.refresh()
        let status = git.status
        return Output(enabled: true, branch: status?.branch, upstream: status?.upstream, ahead: status?.ahead ?? 0, behind: status?.behind ?? 0,
                      conflicts: status?.hasConflicts ?? false, changes: git.changes.map(GitItemOutput.init), problem: git.problem)
    }
}

struct GitEnableAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var enabled: Bool
        var skippedLargeFiles: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "git.enable", summary: "Schaltet Git für die offene Bibliothek ein: Repository, .gitignore und erster Commit „Ausgangsstand“",
        kind: .write, security: .localWrite, output: .freeObject(), example: "llmd git enable", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let large = try await gitCall { try await context.app.git.enable() }
        return Output(enabled: true, skippedLargeFiles: large)
    }
}

struct GitFlushAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var saved: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "git.flush", summary: "Schreibt alles, was noch auf eine Tipp-Pause wartet, damit ein Commit im Terminal den neuesten Stand enthält",
        kind: .write, security: .localWrite, output: .freeObject(), example: "llmd git flush", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.saveEverythingForGit()
        return Output(saved: true)
    }
}

struct GitCommitAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var message: String
        var items: [String]?
    }
    struct Output: Encodable, Sendable {
        var commit: GitCommitOutput
        var items: [GitItemOutput]
        var skippedLargeFiles: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "git.commit", summary: "Committet alle Änderungen oder nur die genannten Dinge mit einer Nachricht",
        kind: .write, security: .localWrite,
        input: .object(["message": .string("Commit-Nachricht (erste Zeile: Betreff)"), "items": .array(of: itemProperty, "Nur diese Dinge; ohne: alles")], required: ["message"]),
        output: .freeObject(), example: "llmd git commit --message \"Kapitel 3 überarbeitet\"", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        context.app.saveEverythingForGit()
        await git.refresh()
        var groups: [GitChangeGroup]?
        if let items = args.items, !items.isEmpty {
            let wanted = try items.map { try context.app.actionGitItem($0) }
            groups = git.changes.filter { group in wanted.contains { $0.id == group.item.id } }
            if groups!.isEmpty { throw RPCError.invalidParams("An diesen Dingen hat sich nichts geändert.") }
        }
        let committed = groups ?? git.changes
        let result = try await gitCall { try await git.commit(groups, message: args.message) }
        return Output(commit: GitCommitOutput(result.commit), items: committed.map(GitItemOutput.init),
                      skippedLargeFiles: result.skipped.isEmpty ? nil : result.skipped)
    }
}

struct GitLogAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var item: String?
        var limit: Int?
        var all: Bool?
    }
    struct Output: Encodable, Sendable {
        var commits: [GitCommitOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "git.log", summary: "Listet Commits, neueste zuerst; auf Wunsch nur die eines Dings oder aller Branches",
        kind: .read, security: gitRead,
        input: .object(["item": itemProperty, "limit": .integer("Höchstens so viele (Vorgabe 30)"), "all": .boolean("Alle Branches")]),
        output: .freeObject(), example: "llmd git log --item Hausarbeit --limit 10", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let limit = min(max(args.limit ?? 30, 1), 500)
        let commits = try await gitCall {
            if let item = args.item {
                return try await git.history(of: try context.app.actionGitItem(item), limit: limit)
            }
            return try await git.log(limit: limit, all: args.all ?? false)
        }
        return Output(commits: commits.map(GitCommitOutput.init))
    }
}

struct GitShowAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var commit: String
    }
    struct Output: Encodable, Sendable {
        var commit: GitCommitOutput
        var body: String
        var items: [GitItemOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "git.show", summary: "Zeigt einen Commit: Nachricht und die geänderten Dinge mit Titeln",
        kind: .read, security: gitRead,
        input: .object(["commit": .string("Commit (Hash, Kurzform, Branch oder Tag)")], required: ["commit"]),
        output: .freeObject(), example: "llmd git show --commit HEAD", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        guard !args.commit.hasPrefix("-") else { throw RPCError.invalidParams("Ungültiger Commit „\(args.commit)“.") }
        return try await gitCall {
            let repository = try await git.checkedRepository()
            let resolved = try await repository.run(["rev-parse", "--verify", "-q", "\(args.commit)^{commit}"], allowFailure: true)
            guard resolved.succeeded else { throw GitError.failed("show", "Den Commit „\(args.commit)“ gibt es nicht.") }
            let id = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await repository.run(["log", "-1", "--format=\(GitCommit.format)", id])
            guard let commit = GitCommit.parse(result.output).first else { throw GitError.failed("show", "Den Commit gibt es nicht.") }
            let items = try await git.changedItems(in: commit)
            return Output(commit: GitCommitOutput(commit), body: commit.body, items: items.map { GitItemOutput($0.item) })
        }
    }
}

struct GitRestoreAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var item: String
        var commit: String
    }
    struct Output: Encodable, Sendable {
        var restored: GitItemOutput
        var from: String
    }
    static let descriptor = ActionDescriptor(
        id: "git.restore", summary: "Stellt ein Ding so her, wie es in einem Commit war; der jetzige Stand wird vorher committet",
        kind: .destructive, security: .destructive,
        input: .object(["item": itemProperty, "commit": .string("Commit, aus dem es kommt")], required: ["item", "commit"]),
        output: .freeObject(), example: "llmd git restore --item Hausarbeit --commit HEAD~2", groups: ["git"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = (try? context.app.actionGitItem(args.item).title) ?? args.item
        preflight.detail = "Stand aus \(args.commit)"
        return preflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        guard !args.commit.hasPrefix("-") else { throw RPCError.invalidParams("Ungültiger Commit „\(args.commit)“.") }
        let item = try context.app.actionGitItem(args.item)
        try await gitCall { try await git.restore(item, to: args.commit) }
        return Output(restored: GitItemOutput(item), from: args.commit)
    }
}

struct GitFetchAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var ahead: Int
        var behind: Int
    }
    static let descriptor = ActionDescriptor(
        id: "git.fetch", summary: "Holt neue Commits vom Remote, ohne die Bibliothek zu ändern",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .local),
        output: .freeObject(), example: "llmd git fetch", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.fetch() }
        return Output(ahead: git.status?.ahead ?? 0, behind: git.status?.behind ?? 0)
    }
}

struct GitPullAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var branch: String?
        var behind: Int
    }
    static let descriptor = ActionDescriptor(
        id: "git.pull", summary: "Übernimmt neue Commits vom Remote, wenn das ohne Zusammenführen geht",
        kind: .destructive, security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .destructive),
        output: .freeObject(), example: "llmd git pull", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.pull() }
        return Output(branch: git.status?.branch, behind: git.status?.behind ?? 0)
    }
}

struct GitPushAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var branch: String?
        var remote: String?
    }
    static let descriptor = ActionDescriptor(
        id: "git.push", summary: "Schickt die Commits der Bibliothek zum verbundenen Remote (GitHub, GitLab …)",
        kind: .destructive, security: .outbound, output: .freeObject(), example: "llmd git push", groups: ["git"]
    )

    static func preflight(_ args: NoArgs, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = context.app.git.status?.upstream ?? "origin"
        preflight.detail = "Alle Commits von \(context.app.git.branch ?? "HEAD")"
        return preflight
    }

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.push() }
        return Output(branch: git.branch, remote: git.status?.upstream)
    }
}

// MARK: - Merging

struct GitConflictOutput: Encodable, Sendable {
    var id: Int
    var label: String
    var ours: String?
    var theirs: String?
}

struct GitConflictFileOutput: Encodable, Sendable {
    var path: String
    var item: GitItemOutput
    var whole: Bool
    var conflicts: [GitConflictOutput]

    init(_ file: GitConflictFile) {
        path = file.path
        item = GitItemOutput(file.item)
        whole = !file.isText
        conflicts = (file.merge?.conflicts ?? []).map {
            GitConflictOutput(id: $0.id, label: $0.label, ours: $0.ours.map { diffShort($0, 300) }, theirs: $0.theirs.map { diffShort($0, 300) })
        }
    }
}

struct GitMergeAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var branch: String
    }
    struct Output: Encodable, Sendable {
        var outcome: String
        var message: String
        var conflicts: [GitConflictFileOutput]?
    }
    static let descriptor = ActionDescriptor(
        id: "git.merge", summary: "Führt einen Branch in den aktuellen zusammen, nach Absätzen, Folien und Einträgen; Konflikte warten auf eine Entscheidung",
        kind: .destructive, security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .destructive),
        input: .object(["branch": .string("Branch, der hineinkommt (z. B. experiment oder origin/main)")], required: ["branch"]),
        output: .freeObject(), example: "llmd git merge --branch experiment", groups: ["git"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = "\(args.branch) → \(context.app.git.branch ?? "HEAD")"
        return preflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let outcome = try await gitCall { try await git.merge(args.branch) }
        var output = Output(outcome: "\(outcome)", message: outcome.message)
        if case .conflicts = outcome {
            output.outcome = "conflicts"
            output.conflicts = try await gitCall { try await git.conflictFiles() }.map(GitConflictFileOutput.init)
        }
        return output
    }
}

struct GitConflictsAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var merging: Bool
        var files: [GitConflictFileOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "git.conflicts", summary: "Zeigt die Konflikte eines laufenden Zusammenführens, je Datei mit den Stellen",
        kind: .read, security: gitRead, output: .freeObject(), example: "llmd git conflicts", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let files = try await gitCall { try await git.conflictFiles() }
        return Output(merging: git.isMerging, files: files.map(GitConflictFileOutput.init))
    }
}

struct GitConflictResolveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var path: String
        var choice: String?
        var choices: [String: String]?
    }
    struct Output: Encodable, Sendable {
        var resolved: String
        var remaining: Int
    }
    static let descriptor = ActionDescriptor(
        id: "git.conflict.resolve", summary: "Löst die Konflikte einer Datei: alle mit einer Seite (ours/theirs/both) oder einzeln nach Nummer",
        kind: .write, security: .localWrite,
        input: .object(["path": .string("Datei aus git.conflicts"), "choice": .choice(["ours", "theirs", "both"], "Für alle Stellen"),
                        "choices": .freeObject("Je Stelle: {\"0\": \"theirs\", \"2\": \"both\"}")], required: ["path"]),
        output: .freeObject(), example: "llmd git conflict resolve --path Documents/….md --choice theirs", groups: ["git"]
    )

    static func choice(_ text: String) throws -> MergeChoice {
        switch text {
        case "ours", "meine": return .ours
        case "theirs", "andere": return .theirs
        case "both", "beide": return .both
        default: throw RPCError.invalidParams("Wahl „\(text)“ gibt es nicht: ours, theirs oder both.")
        }
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let files = try await gitCall { try await git.conflictFiles() }
        guard let file = files.first(where: { $0.path == args.path }) else {
            throw RPCError.notFound("„\(args.path)“ hat keine Konflikte.")
        }
        var choices: [Int: MergeChoice] = [:]
        if let all = args.choice {
            let value = try choice(all)
            for conflict in file.merge?.conflicts ?? [] { choices[conflict.id] = value }
        }
        for (key, value) in args.choices ?? [:] {
            guard let id = Int(key) else { throw RPCError.invalidParams("„\(key)“ ist keine Nummer einer Stelle.") }
            choices[id] = try choice(value)
        }
        let whole: MergeChoice? = file.isText ? nil : try args.choice.map(choice) ?? .ours
        try await gitCall { try await git.resolve(file, choices: choices, whole: whole) }
        let remaining = try await gitCall { try await git.conflictFiles() }.count
        return Output(resolved: file.path, remaining: remaining)
    }
}

struct GitMergeFinishAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var commit: GitCommitOutput?
    }
    static let descriptor = ActionDescriptor(
        id: "git.merge.finish", summary: "Schließt ein Zusammenführen ab, wenn keine Konflikte mehr offen sind (Merge-Commit)",
        kind: .write, security: .localWrite, output: .freeObject(), example: "llmd git merge finish", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.finishMerge() }
        let head = try await gitCall { try await git.log(limit: 1).first }
        return Output(commit: head.map(GitCommitOutput.init))
    }
}

struct GitMergeAbortAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var aborted: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "git.merge.abort", summary: "Bricht ein laufendes Zusammenführen ab; die Bibliothek ist wieder wie davor",
        kind: .destructive, security: .destructive, output: .freeObject(), example: "llmd git merge abort", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.abortMerge() }
        return Output(aborted: true)
    }
}

// MARK: - Branches, tags, stash

struct GitRefOutput: Encodable, Sendable {
    var kind: String
    var name: String
    var current: Bool?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var merged: Bool?
    var subject: String
    var date: String

    init(_ ref: GitRef) {
        kind = ref.kind.rawValue
        name = ref.name
        current = ref.isCurrent ? true : nil
        upstream = ref.upstream
        ahead = ref.ahead > 0 ? ref.ahead : nil
        behind = ref.behind > 0 ? ref.behind : nil
        merged = ref.isMerged ? true : nil
        subject = ref.subject
        date = ref.date.formatted(.iso8601)
    }
}

struct GitBranchListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var current: String?
        var refs: [GitRefOutput]
        var stashes: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "git.branch.list", summary: "Listet Branches (lokal und Remote), Tags und Zurückgelegtes; zeigt, was schon zusammengeführt ist",
        kind: .read, security: gitRead, output: .freeObject(), example: "llmd git branch list", groups: ["git"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let refs = try await gitCall { try await git.refs() }
        let stashes = try await gitCall { try await git.stashes() }
        return Output(current: git.branch, refs: refs.map(GitRefOutput.init), stashes: stashes.map { "\($0.ref): \($0.message)" })
    }
}

struct GitBranchCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var at: String?
        var switchTo: Bool?
    }
    struct Output: Encodable, Sendable {
        var branch: String
        var current: String?
    }
    static let descriptor = ActionDescriptor(
        id: "git.branch.create", summary: "Legt einen Branch an (am aktuellen Stand oder an einem Commit) und wechselt auf Wunsch dorthin",
        kind: .write, security: .localWrite,
        input: .object(["name": .string("Name des Branches"), "at": .string("Commit, an dem er beginnt (ohne: jetzt)"),
                        "switchTo": .boolean("Gleich dorthin wechseln (Vorgabe: ja)")], required: ["name"]),
        output: .freeObject(), example: "llmd git branch create --name experiment", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        // Starting at another commit replaces the files, which is a destructive step of its own.
        if args.at != nil, args.switchTo ?? true {
            throw RPCError.invalidParams("Einen Branch an einem anderen Commit anlegen und wechseln geht in zwei Schritten: git.branch.create mit switchTo=false, dann git.branch.switch.")
        }
        try await gitCall { try await git.createBranch(args.name, at: args.at, switchTo: args.switchTo ?? true) }
        return Output(branch: args.name.replacingOccurrences(of: " ", with: "-"), current: git.branch)
    }
}

struct GitBranchSwitchAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
    }
    struct Output: Encodable, Sendable {
        var current: String?
    }
    static let descriptor = ActionDescriptor(
        id: "git.branch.switch", summary: "Wechselt die Bibliothek auf einen anderen Branch; Änderungen müssen vorher committet oder zurückgelegt sein",
        kind: .destructive, security: .destructive,
        input: .object(["name": .string("Branch (auch origin/…)")], required: ["name"]),
        output: .freeObject(), example: "llmd git branch switch --name experiment", groups: ["git"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = "\(context.app.git.branch ?? "HEAD") → \(args.name)"
        return preflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.switchBranch(args.name) }
        return Output(current: git.branch)
    }
}

struct GitBranchDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var force: Bool?
    }
    struct Output: Encodable, Sendable {
        var deleted: String
    }
    static let descriptor = ActionDescriptor(
        id: "git.branch.delete", summary: "Löscht einen lokalen Branch; einer, der noch nicht zusammengeführt ist, nur mit force",
        kind: .destructive, security: .destructive,
        input: .object(["name": .string("Branch"), "force": .boolean("Auch wenn er noch nicht zusammengeführt ist")], required: ["name"]),
        output: .freeObject(), example: "llmd git branch delete --name experiment", groups: ["git"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = args.name
        if args.force == true { preflight.detail = "auch wenn er nicht zusammengeführt ist" }
        return preflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.deleteBranch(args.name, force: args.force ?? false) }
        return Output(deleted: args.name)
    }
}

struct GitTagAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var commit: String?
        var message: String?
    }
    struct Output: Encodable, Sendable {
        var tag: String
    }
    static let descriptor = ActionDescriptor(
        id: "git.tag", summary: "Setzt ein Tag (etwa „Abgabe-Hausarbeit“) an den aktuellen Stand oder einen Commit",
        kind: .write, security: .localWrite,
        input: .object(["name": .string("Name des Tags"), "commit": .string("Commit (ohne: HEAD)"), "message": .string("Beschreibung")], required: ["name"]),
        output: .freeObject(), example: "llmd git tag --name Abgabe-Hausarbeit", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.tag(args.name, at: args.commit ?? "HEAD", message: args.message) }
        return Output(tag: args.name.replacingOccurrences(of: " ", with: "-"))
    }
}

struct GitRevertAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var commit: String
    }
    struct Output: Encodable, Sendable {
        var commit: GitCommitOutput?
    }
    static let descriptor = ActionDescriptor(
        id: "git.revert", summary: "Nimmt einen Commit mit einem neuen Commit zurück; der Verlauf bleibt",
        kind: .destructive, security: .destructive,
        input: .object(["commit": .string("Commit, der zurückgenommen wird")], required: ["commit"]),
        output: .freeObject(), example: "llmd git revert --commit HEAD", groups: ["git"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var preflight = ActionPreflight()
        preflight.target = args.commit
        return preflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.revert(args.commit) }
        let head = try await gitCall { try await git.log(limit: 1).first }
        return Output(commit: head.map(GitCommitOutput.init))
    }
}

struct GitStashAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var message: String?
    }
    struct Output: Encodable, Sendable {
        var stashed: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "git.stash", summary: "Legt Änderungen, die noch nicht committet sind, zurück (git stash), etwa um den Branch zu wechseln",
        kind: .write, security: .localWrite,
        input: .object(["message": .string("Notiz dazu")]),
        output: .freeObject(), example: "llmd git stash --message \"halbe Einleitung\"", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        try await gitCall { try await git.stash(args.message ?? "") }
        return Output(stashed: true)
    }
}

struct GitStashApplyAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var stash: String?
    }
    struct Output: Encodable, Sendable {
        var applied: String
    }
    static let descriptor = ActionDescriptor(
        id: "git.stash.apply", summary: "Holt Zurückgelegtes wieder hervor (ohne Angabe das jüngste)",
        kind: .destructive, security: .destructive,
        input: .object(["stash": .string("z. B. stash@{0}")]),
        output: .freeObject(), example: "llmd git stash apply", groups: ["git"]
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let git = try context.app.actionGit()
        let ref = args.stash ?? "stash@{0}"
        try await gitCall { try await git.applyStash(ref) }
        return Output(applied: ref)
    }
}
