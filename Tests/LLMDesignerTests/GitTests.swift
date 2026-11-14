import Foundation
import Testing
import LLMDProtocol
@testable import LLMDesigner

/// Git isolated from the person's own configuration: no global or system config, a fixed identity.
enum GitTestSupport {
    static let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.invalid",
    ]

    static func folder(_ name: String = "Git") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesignerGit-\(UUID().uuidString)").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func repository(at url: URL) throws -> GitRepository {
        let tool = try #require(GitTool.find())
        return GitRepository(root: url, tool: tool, environment: environment)
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func document(id: UUID = UUID(), title: String, body: String = "Text", presentation: Bool = false) -> String {
        "---\nid: \(id.uuidString)\ntitle: \(title)\n\(presentation ? "kind: presentation\n" : "")---\n\n# \(title)\n\n\(body)\n"
    }
}

@Suite("Git: Formate und Regeln")
struct GitFormatTests {
    @Test func statusIsReadFromPorcelainV2() {
        let raw = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 abc abc Documents/A B.md",
            "1 A. N... 000000 100644 100644 000 abc Notizen/x.json",
            "1 .D N... 100644 100644 000000 abc abc Daten/y.json",
            "2 R. N... 100644 100644 100644 abc abc R100 neu.md", "alt.md",
            "u UU N... 100644 100644 100644 100644 a b c Geschichten/w.json",
            "? Projekte/p.json",
            "",
        ].joined(separator: "\0")
        let status = GitStatus.parse(Data(raw.utf8))
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.entries.map(\.path) == ["Documents/A B.md", "Notizen/x.json", "Daten/y.json", "neu.md", "Geschichten/w.json", "Projekte/p.json"])
        #expect(status.entries.map(\.change) == [.modified, .added, .deleted, .renamed, .conflicted, .untracked])
        #expect(status.entries[3].originalPath == "alt.md")
        #expect(status.entries[1].isStaged && !status.entries[0].isStaged)
        #expect(status.hasConflicts)
    }

    @Test func commitsAndTrailersAreRead() {
        let raw = "abc123\u{1f}p1 p2\u{1f}Agent\u{1f}a@b.c\u{1f}1700000000\u{1f}Kurs angelegt\u{1f}- Kurs „X“: neu\n\nAuftrag: 42\nSchritt: 3/7\u{1f}HEAD -> main, tag: Abgabe\u{1e}\n"
        let commits = GitCommit.parse(Data(raw.utf8))
        #expect(commits.count == 1)
        #expect(commits[0].isMerge)
        #expect(commits[0].trailer("Auftrag") == "42")
        #expect(commits[0].trailer("schritt") == "3/7")
        #expect(commits[0].refs == ["HEAD -> main", "tag: Abgabe"])
    }

    @Test func configurationThatStartsProgramsIsFound() {
        let entries = [
            GitConfigCheck.Entry(key: "core.fsmonitor", value: "/tmp/x"),
            GitConfigCheck.Entry(key: "filter.evil.smudge", value: "sh"),
            GitConfigCheck.Entry(key: "alias.st", value: "!rm -rf"),
            GitConfigCheck.Entry(key: "alias.co", value: "checkout"),
            GitConfigCheck.Entry(key: "user.name", value: "Test"),
            GitConfigCheck.Entry(key: "merge.llmd.driver", value: "evil"),
            GitConfigCheck.Entry(key: "includeif.gitdir:/x.path", value: "/tmp/c"),
        ]
        let unsafe = GitConfigCheck.unsafeKeys(in: entries, allowedDrivers: ["merge.llmd.driver": "llmd ok"])
        #expect(unsafe == ["core.fsmonitor", "filter.evil.smudge", "alias.st", "merge.llmd.driver", "includeif.gitdir:/x.path"])
        #expect(GitConfigCheck.unsafeKeys(in: [GitConfigCheck.Entry(key: "merge.llmd.driver", value: "llmd ok")], allowedDrivers: ["merge.llmd.driver": "llmd ok"]).isEmpty)
    }

    @Test func pathsBecomeItemsWithTitles() throws {
        let doc = UUID(), deck = UUID(), note = UUID(), world = UUID()
        let files: [String: String] = [
            "Documents/\(doc.uuidString).md": GitTestSupport.document(id: doc, title: "Hausarbeit"),
            "Documents/\(deck.uuidString).md": GitTestSupport.document(id: deck, title: "Referat", presentation: true),
            "Notizen/\(note.uuidString).json": #"{"format":1,"note":{"titel":"Bachelorarbeit"}}"#,
            "Geschichten/\(world.uuidString).json": #"{"format":1,"world":{"title":"Nordwind"}}"#,
        ]
        let resolver = LibraryItemResolver { files[$0].map { Data($0.utf8) } }
        #expect(resolver.item(for: "Documents/\(doc.uuidString).md").title == "Hausarbeit")
        #expect(resolver.item(for: "Documents/\(deck.uuidString).md").kind == .presentation)
        #expect(resolver.item(for: "Notizen/\(note.uuidString).json").title == "Bachelorarbeit")
        let picture = resolver.item(for: "Geschichten/Bilder/\(world.uuidString)/bild-1.jpg")
        #expect(picture.kind == .world && picture.title == "Nordwind" && picture.key == world.uuidString)
        let groups = resolver.group(["Geschichten/\(world.uuidString).json", "Geschichten/Bilder/\(world.uuidString)/bild-1.jpg",
                                     "Documents/\(doc.uuidString).md"])
        #expect(groups.count == 2)
        #expect(groups[0].item.kind == .document)
        #expect(groups[1].paths.count == 2)
        #expect(resolver.item(for: "Documents/Bilder/plot.png").title == "plot.png (Dokument)")
    }

    @Test func externalChangesAreSorted() {
        var changes = ExternalChanges()
        changes.add(".git/index")
        #expect(changes.repositoryChanged && !changes.headChanged && changes.paths.isEmpty)
        changes.add(".git/HEAD")
        changes.add(".git/objects/ab/cdef")
        changes.add("Einstellungen.plist")
        changes.add("Chats/x.json")
        changes.add("Documents/x.md")
        changes.add("Documents/.DS_Store")
        #expect(changes.headChanged)
        #expect(changes.paths == ["Documents/x.md"])
    }

    @Test func onlyRealRemoteAddressesAreTaken() {
        #expect(LibraryGit.isValidRemoteURL("https://github.com/a/b.git"))
        #expect(LibraryGit.isValidRemoteURL("git@github.com:a/b.git"))
        #expect(LibraryGit.isValidRemoteURL("ssh://git@gitlab.com/a/b.git"))
        #expect(!LibraryGit.isValidRemoteURL("ext::sh -c evil"))
        #expect(!LibraryGit.isValidRemoteURL("--upload-pack=evil"))
        #expect(!LibraryGit.isValidRemoteURL("/tmp/repo"))
        #expect(!LibraryGit.isValidRemoteURL("file:///tmp/repo"))
    }

    @Test func commitMessageNamesTheItems() {
        let item = LibraryItem(kind: .document, key: "x", title: "Hausarbeit", mainPath: "Documents/x.md")
        let group = GitChangeGroup(item: item, entries: [GitStatus.Entry(path: "Documents/x.md", change: .modified, isStaged: false)])
        let text = LibraryGit.commitMessage("Kapitel 3", groups: [group], trailers: [("Auftrag", "1")])
        #expect(text == "Kapitel 3\n\n- Dokument „Hausarbeit“: geändert\n\nAuftrag: 1\n")
    }
}

@Suite("Git: Repository")
struct GitRepositoryTests {
    @Test func enablingLeavesOutSecretsChatsAndPersonas() async throws {
        let root = GitTestSupport.folder("A.llmdlibrary")
        let doc = UUID()
        try GitTestSupport.write(GitTestSupport.document(id: doc, title: "Hausarbeit"), to: "Documents/\(doc.uuidString).md", in: root)
        try GitTestSupport.write("<plist><dict><key>apiKey</key><string>geheim</string></dict></plist>", to: "Einstellungen.plist", in: root)
        try GitTestSupport.write("{}", to: "Chats/\(UUID().uuidString).json", in: root)
        try GitTestSupport.write("{}", to: "Personas/\(UUID().uuidString)/persona.json", in: root)
        try GitTestSupport.write("{}", to: "Attachments/a.txt", in: root)
        try GitTestSupport.write("{}", to: "SidebarStacks.json", in: root)
        try GitTestSupport.write("x", to: "Podcasts/\(UUID().uuidString)/Schnipsel/1.wav", in: root)
        let repository = try GitTestSupport.repository(at: root)
        try await GitSetup.enable(repository)
        let files = try await repository.run(["ls-files"]).text.split(separator: "\n").map(String.init)
        #expect(files.sorted() == [".gitattributes", ".gitignore", "Documents/\(doc.uuidString).md"])
        let subject = try await repository.run(["log", "-1", "--format=%s"]).text
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "Ausgangsstand")
        let all = try await repository.run(["log", "-p", "--all"]).text
        #expect(!all.contains("geheim"))
    }

    @Test func largeFilesStayOut() async throws {
        let root = GitTestSupport.folder("B.llmdlibrary")
        try GitTestSupport.write("klein", to: "Documents/a.md", in: root)
        let big = root.appendingPathComponent("Geschichten/Videos/x/video.mp4")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(GitSetup.largeFileLimit + 1))
        try handle.close()
        let repository = try GitTestSupport.repository(at: root)
        let skipped = try await GitSetup.enable(repository)
        #expect(skipped == ["Geschichten/Videos/x/video.mp4"])
        let files = try await repository.run(["ls-files"]).text
        #expect(!files.contains("video.mp4"))
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore.contains("/Geschichten/Videos/x/video.mp4"))
    }

    @Test func unsafeConfigurationStopsEveryCall() async throws {
        let root = GitTestSupport.folder("C.llmdlibrary")
        let repository = try GitTestSupport.repository(at: root)
        try await repository.run(["init", "-q", "-b", "main"])
        try await repository.run(["config", "--local", "core.fsmonitor", "/tmp/does-not-exist"])
        await #expect(throws: GitError.unsafeConfiguration(["core.fsmonitor"])) {
            try await repository.checkConfiguration()
        }
        await #expect(throws: GitError.self) {
            try await GitSetup.enable(repository)
        }
    }

    @Test func hooksNeverRun() async throws {
        let root = GitTestSupport.folder("D.llmdlibrary")
        let repository = try GitTestSupport.repository(at: root)
        try await repository.run(["init", "-q", "-b", "main"])
        let marker = root.appendingPathComponent("hook-ran")
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try GitTestSupport.write("a", to: "Documents/a.md", in: root)
        try await GitSetup.enable(repository)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func watcherReportsOtherProgramsOnly() async throws {
        let root = GitTestSupport.folder("E.llmdlibrary")
        let reports = Reports()
        let watcher = LibraryWatcher(root: root, delay: 0.2) { changes in Task { await reports.add(changes) } }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))
        // The app's own write: marked by FSEvents, never reported.
        try "eigen".write(to: root.appendingPathComponent("eigen.md"), atomically: true, encoding: .utf8)
        // Another program's write, as git in the Terminal would make it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "mkdir -p Documents && echo fremd > Documents/fremd.md"]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        var paths: Set<String> = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            paths = await reports.paths
            if paths.contains("Documents/fremd.md") { break }
        }
        #expect(paths.contains("Documents/fremd.md"))
        #expect(!paths.contains("eigen.md"))
    }

    actor Reports {
        var paths: Set<String> = []
        func add(_ changes: ExternalChanges) { paths.formUnion(changes.paths) }
    }
}

extension ActionSuites {
    @Suite("Git-Actions")
    @MainActor
    struct GitActionTests {
        let harness = ActionHarness()

        private func prepare() async throws -> LibraryGit {
            let git = harness.app.git
            git.environment = GitTestSupport.environment
            if !git.isEnabled {
                let result = try await harness.call("git.enable")
                #expect(result["enabled"]?.boolValue == true)
            }
            return git
        }

        @Test func statusCommitLogShowAndRestore() async throws {
            let git = try await prepare()
            let id = try await harness.document("Erste Fassung")
            let title = try #require(harness.app.document(UUID(uuidString: id)!)?.displayTitle)

            let status = try await harness.call("git.status")
            let changes = status["changes"]?.arrayValue ?? []
            #expect(changes.contains { $0["title"]?.stringValue == title && $0["kind"]?.stringValue == "document" })

            let committed = try await harness.call("git.commit", ["message": "Erste Fassung", "items": [.string(id)]])
            let first = try #require(committed["commit"]?["id"]?.stringValue)
            #expect(committed["items"]?.arrayValue?.count == 1)
            #expect(!git.changes.contains { $0.item.key == id })

            harness.app.modifyDocument(UUID(uuidString: id)!) { $0.markdown = "Zweite Fassung" }
            harness.app.saveEverythingForGit()
            try await harness.call("git.commit", ["message": "Zweite Fassung", "items": [.string(id)]])

            let log = try await harness.call("git.log", ["item": .string(id)])
            let subjects = log["commits"]?.arrayValue?.compactMap { $0["subject"]?.stringValue } ?? []
            #expect(subjects.prefix(2) == ["Zweite Fassung", "Erste Fassung"])

            let shown = try await harness.call("git.show", ["commit": .string(first)])
            #expect(shown["items"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == true)

            try await harness.call("git.restore", ["item": .string(id), "commit": .string(first)])
            let file = git.root.appendingPathComponent("Documents/\(id).md")
            let restored = try String(contentsOf: file, encoding: .utf8)
            #expect(restored.contains("Erste Fassung"))
            #expect(!restored.contains("Zweite Fassung"))
        }

        @Test func pushAndPullThroughABareRemote() async throws {
            let git = try await prepare()
            let remote = GitTestSupport.folder("remote.git")
            let tool = try #require(GitTool.find())
            let bare = GitRepository(root: remote, tool: tool, environment: GitTestSupport.environment)
            try await bare.run(["init", "-q", "--bare", "-b", "main"])
            let repository = try #require(git.repository)
            try await repository.run(["remote", "remove", "origin"], allowFailure: true)
            try await repository.run(["remote", "add", "origin", remote.path])

            let id = try await harness.document("Für den Remote")
            try await harness.call("git.commit", ["message": "Für den Remote", "items": [.string(id)]])
            let pushed = try await harness.call("git.push")
            #expect(pushed["remote"]?.stringValue == "origin/main")

            // Someone else adds a commit on another Mac.
            let other = GitTestSupport.folder("other")
            let clone = GitRepository(root: other, tool: tool, environment: GitTestSupport.environment)
            try await clone.run(["clone", "-q", remote.path, other.path])
            let note = UUID()
            try GitTestSupport.write(#"{"format":1,"note":{"titel":"Vom anderen Mac"}}"#, to: "Notizen/\(note.uuidString).json", in: other)
            try await clone.run(["add", "-A"])
            try await clone.run(["commit", "-q", "-m", "Note vom anderen Mac"])
            try await clone.run(["push", "-q"])

            try await harness.call("git.pull")
            #expect(FileManager.default.fileExists(atPath: git.root.appendingPathComponent("Notizen/\(note.uuidString).json").path))
            #expect(git.status?.behind == 0)
        }

        @Test func changesFromOutsideReloadOrAsk() async throws {
            let git = try await prepare()
            let id = try await harness.document("Von außen")
            try await harness.call("git.flush")
            for _ in 0..<40 where git.isRunningOwnOperation { try await Task.sleep(for: .milliseconds(100)) }
            #expect(!git.isRunningOwnOperation)
            #expect(harness.app.runningWorkDescription == nil)
            var reloads = 0
            harness.app.onLibraryReload = { reloads += 1 }
            defer { harness.app.onLibraryReload = nil }
            var changes = ExternalChanges()
            changes.paths = ["Documents/\(id).md"]
            // Nothing pending here: the library reloads.
            git.received(changes)
            #expect(reloads == 1)
            #expect(git.notice == nil)
            // A change that waits for a pause in typing: the person decides.
            harness.app.saveDocument(UUID(uuidString: id)!, after: .seconds(60))
            git.received(changes)
            #expect(reloads == 1)
            guard case .conflict(let items) = git.notice?.kind else { Issue.record("Keine Rückfrage"); return }
            #expect(items.map(\.key) == [id])
            git.takeVersionFromDisk()
            #expect(reloads == 2)
            #expect(!harness.app.pendingSaveIDs().contains(UUID(uuidString: id)!))
            harness.app.discardOnClose = []
            // A pull moved HEAD: also a reload.
            var head = ExternalChanges()
            head.headChanged = true
            git.received(head)
            #expect(reloads == 3)
        }

        @Test func fetchWithoutRemoteSaysSo() async throws {
            let git = try await prepare()
            let repository = try #require(git.repository)
            try await repository.run(["remote", "remove", "origin"], allowFailure: true)
            let code = await harness.errorCode("git.fetch")
            #expect(code != nil)
        }

        @Test func flushHookStopsAnOlderCommit() async throws {
            let git = try await prepare()
            try await git.installFlushHook()
            let hook = try String(contentsOf: git.root.appendingPathComponent(".git/hooks/pre-commit"), encoding: .utf8)
            #expect(hook.contains(LibraryGit.hookMarker))
            #expect(hook.contains("git flush"))
            // Installing twice keeps the app's own hook; someone else's hook stays untouched.
            try await git.installFlushHook()
            try "#!/bin/sh\nexit 0\n".write(to: git.root.appendingPathComponent(".git/hooks/pre-commit"), atomically: true, encoding: .utf8)
            await #expect(throws: GitError.self) { try await git.installFlushHook() }
            try FileManager.default.removeItem(at: git.root.appendingPathComponent(".git/hooks/pre-commit"))
        }

        @Test func gitActionsNeedAnEnabledLibraryAndValidCommits() async throws {
            _ = try await prepare()
            let code = await harness.errorCode("git.show", ["commit": "--output=/tmp/x"])
            #expect(code != nil)
            let missing = await harness.errorCode("git.restore", ["item": .string(UUID().uuidString), "commit": "HEAD"])
            #expect(missing != nil)
            let empty = await harness.errorCode("git.commit", ["message": "  "])
            #expect(empty != nil)
        }
    }
}
