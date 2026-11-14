import Foundation

/// Turning Git on for a library: the repository, `.gitignore`, `.gitattributes` and a first commit.
enum GitSetup {
    /// What never goes into the repository. Paths start with `/`, so only the library's own folders match.
    static let ignoreFileContent = """
    # Angelegt von LLM Designer. Du darfst diese Datei ändern.

    # Laufzeit und Geheimes: nie in Git (Einstellungen enthalten API-Schlüssel)
    /Einstellungen.plist
    /llmd.token
    /llmd.sock

    # Chats, ihre Anhänge und Personas bleiben lokal, ohne Verlauf
    /Chats/
    /ChatFolders.json
    /Attachments/
    /Personas/

    # Zustand ohne Inhalt
    /SidebarStacks.json
    .DS_Store

    # lässt sich neu erzeugen
    /Podcasts/*/Schnipsel/
    /Auftr*ge/*/vorher/

    """

    static let largeFilesHeader = "# Größer als 50 MB, deshalb nicht im Verlauf (von LLM Designer eingetragen)"

    static let attributesContent = """
    # Angelegt von LLM Designer.
    Documents/*.md  diff=llmd merge=llmd
    *.json          diff=llmd merge=llmd
    *.m4a binary
    *.mp4 binary
    *.mov binary
    *.wav binary
    *.jpg binary
    *.jpeg binary
    *.png binary
    *.pdf binary

    """

    /// The app's own entries in `.git/config` for the merge driver in `llmd`. Only exactly these values count as safe
    /// for these keys (see `GitConfigCheck`); the app writes them itself before it looks at the configuration.
    static func driverConfiguration(llmd path: String) -> [String: String] {
        ["merge.llmd.name": "LLM Designer (nach Bausteinen)",
         "merge.llmd.driver": "\"\(path)\" git merge-file %O %A %B %P"]
    }

    static let largeFileLimit = 50 * 1024 * 1024

    /// Folders Git and iCloud would both write into, which breaks repositories.
    static func locationProblem(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") {
            return "Die Bibliothek liegt in iCloud Drive. iCloud und Git schreiben dort beide und beschädigen sich gegenseitig das Repository. Lege die Bibliothek außerhalb von iCloud Drive ab, bevor du Git einschaltest."
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return "Die Bibliothek wird mit iCloud abgeglichen. Lege sie außerhalb von iCloud Drive ab, bevor du Git einschaltest."
        }
        return nil
    }

    /// Paths of files above the limit that the ignore rules don't already leave out.
    static func largeFiles(in root: URL) -> [String] {
        let fileManager = FileManager.default
        let skipped = ["/.git/", "/Chats/", "/Attachments/", "/Personas/", "/Schnipsel/", "/vorher/"]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var found: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(rootPath.count))
            if skipped.contains(where: { relative.contains($0) || (relative + "/").hasPrefix($0) }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
                  let size = values.fileSize, size > largeFileLimit else { continue }
            found.append(String(relative.drop { $0 == "/" }))
        }
        return found.sorted()
    }

    /// Adds files to the ignore list, under their own heading.
    static func ignore(_ paths: [String], in root: URL) throws {
        guard !paths.isEmpty else { return }
        let url = root.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ignoreFileContent
        let existing = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let new = paths.map { "/" + $0 }.filter { !existing.contains($0) }
        guard !new.isEmpty else { return }
        if !text.contains(largeFilesHeader) { text += (text.hasSuffix("\n") ? "" : "\n") + "\n" + largeFilesHeader + "\n" }
        text += new.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes the library a repository with a first commit. Large files stay out and are named in the result.
    @discardableResult
    static func enable(_ repository: GitRepository, identity: (name: String, email: String)? = nil, drivers: [String: String] = [:]) async throws -> [String] {
        if let problem = locationProblem(repository.root) { throw GitError.unsuitableLocation(problem) }
        let fileManager = FileManager.default
        if !repository.exists {
            try await repository.run(["init", "-b", "main"])
        }
        for (key, value) in drivers.sorted(by: { $0.key < $1.key }) {
            try await repository.run(["config", "--local", key, value])
        }
        try await repository.checkConfiguration(allowedDrivers: drivers)
        if let identity {
            try await repository.run(["config", "--local", "user.name", identity.name])
            try await repository.run(["config", "--local", "user.email", identity.email])
        }
        guard try await hasIdentity(repository) else { throw GitError.noIdentity }
        let ignoreURL = repository.root.appendingPathComponent(".gitignore")
        if !fileManager.fileExists(atPath: ignoreURL.path) {
            try ignoreFileContent.write(to: ignoreURL, atomically: true, encoding: .utf8)
        }
        let attributesURL = repository.root.appendingPathComponent(".gitattributes")
        if !fileManager.fileExists(atPath: attributesURL.path) {
            try attributesContent.write(to: attributesURL, atomically: true, encoding: .utf8)
        }
        let large = largeFiles(in: repository.root)
        try ignore(large, in: repository.root)
        try await repository.run(["add", "-A"])
        let head = try await repository.run(["rev-parse", "--verify", "-q", "HEAD"], allowFailure: true)
        if !head.succeeded {
            try await repository.run(["commit", "--allow-empty", "-q", "-F", "-"], input: Data("Ausgangsstand\n".utf8))
        }
        return large
    }

    static func hasIdentity(_ repository: GitRepository) async throws -> Bool {
        // Name and e-mail may also come from the environment (tests, or a person who sets them per shell).
        if repository.environment["GIT_AUTHOR_NAME"] != nil, repository.environment["GIT_AUTHOR_EMAIL"] != nil { return true }
        let name = try await repository.run(["config", "user.name"], allowFailure: true)
        let email = try await repository.run(["config", "user.email"], allowFailure: true)
        return !name.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
