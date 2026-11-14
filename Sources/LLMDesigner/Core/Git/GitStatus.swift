import Foundation

/// What `git status --porcelain=v2 --branch -z` says, read into plain values.
struct GitStatus: Sendable, Equatable {
    enum Change: String, Sendable, Equatable {
        case modified, added, deleted, renamed, untracked, conflicted

        var label: String {
            switch self {
            case .modified: "geändert"
            case .added: "neu"
            case .deleted: "gelöscht"
            case .renamed: "umbenannt"
            case .untracked: "neu"
            case .conflicted: "Konflikt"
            }
        }
    }

    struct Entry: Sendable, Equatable, Hashable {
        /// Relative to the library, with `/`.
        var path: String
        var change: Change
        /// Already marked for the next commit (`git add`).
        var isStaged: Bool
        var originalPath: String?
    }

    /// Nil when HEAD is detached.
    var branch: String?
    /// The commit HEAD points at; nil before the first commit.
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var entries: [Entry] = []

    var hasConflicts: Bool { entries.contains { $0.change == .conflicted } }
    var isClean: Bool { entries.isEmpty }

    static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus()
        let records = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.head = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.upstream = parts[2]
                case "branch.ab":
                    for value in parts[2].split(separator: " ") {
                        if value.hasPrefix("+") { status.ahead = Int(value.dropFirst()) ?? 0 }
                        if value.hasPrefix("-") { status.behind = Int(value.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1", "2":
                // "1 XY sub mH mI mW hH hI path"; "2 … Xscore path" followed by the original path as its own record.
                let fieldCount = kind == "1" ? 8 : 9
                let parts = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == fieldCount + 1 else { continue }
                let xy = Array(parts[1])
                var entry = Entry(path: parts[fieldCount], change: change(xy), isStaged: xy.first.map { $0 != "." } ?? false)
                if kind == "2" {
                    entry.change = .renamed
                    if index < records.count {
                        entry.originalPath = records[index]
                        index += 1
                    }
                }
                status.entries.append(entry)
            case "u":
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 11 else { continue }
                status.entries.append(Entry(path: parts[10], change: .conflicted, isStaged: false))
            case "?":
                status.entries.append(Entry(path: String(record.dropFirst(2)), change: .untracked, isStaged: false))
            default:
                continue
            }
        }
        return status
    }

    private static func change(_ xy: [Character]) -> Change {
        let staged = xy.first ?? "."
        let worktree = xy.count > 1 ? xy[1] : "."
        if staged == "D" || worktree == "D" { return .deleted }
        if staged == "A" { return .added }
        if staged == "R" || staged == "C" { return .renamed }
        return .modified
    }
}

/// One commit as the history lists show it.
struct GitCommit: Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var parents: [String]
    var author: String
    var authorEmail: String
    var date: Date
    var subject: String
    var body: String
    /// Branch and tag names that point at it (`HEAD -> main`, `origin/main`, `tag: Abgabe`).
    var refs: [String]

    var shortID: String { String(id.prefix(7)) }
    /// The branch and tag names without "HEAD -> " and "tag: ".
    var refNames: [String] {
        refs.map { ref in
            if ref.hasPrefix("HEAD -> ") { return String(ref.dropFirst(8)) }
            if ref.hasPrefix("tag: ") { return String(ref.dropFirst(5)) }
            return ref
        }
    }
    var isMerge: Bool { parents.count > 1 }

    /// The value of a trailer such as `Auftrag:` in the message.
    func trailer(_ name: String) -> String? {
        for line in body.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix(name.lowercased() + ":") {
                return text.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The `--format` that `parse` reads: fields split by 0x1F, commits by 0x1E.
    static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1f%D%x1e"

    static func parse(_ data: Data) -> [GitCommit] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1e}").compactMap { record in
            let trimmed = record.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = trimmed.components(separatedBy: "\u{1f}")
            guard fields.count >= 8 else { return nil }
            return GitCommit(
                id: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                authorEmail: fields[3],
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                subject: fields[5],
                body: fields[6].trimmingCharacters(in: .whitespacesAndNewlines),
                refs: fields[7].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )
        }
    }
}
