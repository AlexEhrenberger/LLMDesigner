import Foundation
import LLMDProtocol
import Testing
@testable import LLMDesigner

private func commit(_ id: String, _ parents: [String]) -> GitCommit {
    GitCommit(id: id, parents: parents, author: "Test", authorEmail: "t@example.invalid", date: Date(), subject: id, body: "", refs: [])
}

@Suite("Git Studio: Baum")
struct GitGraphTests {
    @Test func aLineStaysOnOneLane() {
        let rows = GitGraph.rows(for: [commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows[0].incoming.isEmpty && rows[0].outgoing == [0])
        #expect(rows[1].incoming == [0] && rows[1].outgoing == [0])
        #expect(rows[2].outgoing.isEmpty)
        #expect(rows.allSatisfy { $0.width == 1 })
    }

    @Test func aBranchAndItsMergeTakeTwoLanes() {
        // m merges f into b; both started at a.
        let rows = GitGraph.rows(for: [commit("m", ["b", "f"]), commit("f", ["a"]), commit("b", ["a"]), commit("a", [])])
        #expect(rows[0].lane == 0 && rows[0].outgoing == [0, 1])
        #expect(rows[1].lane == 1 && rows[1].incoming == [1] && rows[1].passing == [0])
        #expect(rows[2].lane == 0 && rows[2].outgoing == [1])
        #expect(rows[3].incoming.count == 1)
        #expect(rows.map(\.width).max() == 2)
    }

    @Test func parentsOutsideThePageEndTheLine() {
        let rows = GitGraph.rows(for: [commit("c", ["b"]), commit("b", ["older"])])
        #expect(rows[1].outgoing.isEmpty)
    }
}

@Suite("Git Studio: Branches", .serialized)
@MainActor
struct GitBranchTests {
    private func library() async throws -> (LibraryGit, String) {
        let root = GitTestSupport.folder("S.llmdlibrary")
        let path = "Documents/\(UUID().uuidString).md"
        try GitTestSupport.write(GitTestSupport.document(title: "Studio", body: "Fassung main"), to: path, in: root)
        let git = LibraryGit(root: root)
        git.environment = GitTestSupport.environment
        git.driverPath = nil
        try await git.enable()
        return (git, path)
    }

    private func write(_ body: String, _ path: String, in git: LibraryGit) throws {
        try GitTestSupport.write(GitTestSupport.document(title: "Studio", body: body), to: path, in: git.root)
    }

    private func text(_ path: String, in git: LibraryGit) throws -> String {
        try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func branchSwitchMergeAndDelete() async throws {
        let (git, path) = try await library()
        try await git.createBranch("experiment")
        #expect(git.branch == "experiment")
        try write("Fassung experiment", path, in: git)
        try await git.commit(message: "Kürzere Fassung")
        await #expect(throws: GitError.self) { try await git.deleteBranch("experiment") }
        try await git.switchBranch("main")
        #expect(git.branch == "main")
        #expect(try text(path, in: git).contains("Fassung main"))
        var refs = try await git.refs()
        #expect(refs.first { $0.name == "experiment" }?.isMerged == false)
        await #expect(throws: GitError.self) { try await git.deleteBranch("experiment") }
        #expect(try await git.merge("experiment") == .fastForward)
        #expect(try text(path, in: git).contains("Fassung experiment"))
        refs = try await git.refs()
        #expect(refs.first { $0.name == "experiment" }?.isMerged == true)
        try await git.deleteBranch("experiment")
        #expect(try await git.refs().contains { $0.name == "experiment" } == false)
    }

    @Test func uncommittedChangesBlockASwitch() async throws {
        let (git, path) = try await library()
        try await git.createBranch("b", switchTo: false)
        try write("ungesichert", path, in: git)
        await #expect(throws: GitError.self) { try await git.switchBranch("b") }
        #expect(git.branch == "main")
    }

    @Test func tagRevertAndStash() async throws {
        let (git, path) = try await library()
        try await git.tag("Abgabe Hausarbeit")
        #expect(try await git.refs().contains { $0.kind == .tag && $0.name == "Abgabe-Hausarbeit" })
        try write("Fehler", path, in: git)
        try await git.commit(message: "Versehentlich")
        try await git.revert("HEAD")
        #expect(try text(path, in: git).contains("Fassung main"))
        #expect(try await git.log(limit: 1).first?.subject.hasPrefix("Revert") == true)
        try write("halb fertig", path, in: git)
        try await git.stash("halbe Einleitung")
        #expect(try text(path, in: git).contains("Fassung main"))
        #expect(try await git.stashes().first?.message.contains("halbe Einleitung") == true)
        try await git.applyStash("stash@{0}")
        #expect(try text(path, in: git).contains("halb fertig"))
        #expect(try await git.stashes().isEmpty)
    }

    @Test func branchNamesAreChecked() async throws {
        let (git, _) = try await library()
        #expect(await git.validBranchName("neue Einleitung") == "neue-Einleitung")
        #expect(await git.validBranchName("..") == nil)
        #expect(await git.validBranchName("-x") == nil)
        await #expect(throws: GitError.self) { try await git.createBranch("a..b") }
        await #expect(throws: GitError.self) { try await git.switchBranch("gibt-es-nicht") }
    }
}

extension ActionSuites {
    @Suite("Git-Branch-Actions")
    @MainActor
    struct GitBranchActionTests {
        let harness = ActionHarness()

        private func clean() async throws -> LibraryGit {
            let git = harness.app.git
            git.environment = GitTestSupport.environment
            if !git.isEnabled { try await harness.call("git.enable") }
            harness.app.saveEverythingForGit()
            await git.refresh()
            if !git.changes.isEmpty { try await harness.call("git.commit", ["message": "Vorher"]) }
            return git
        }

        @Test func branchesTagsAndStashThroughTheRegistry() async throws {
            let git = try await clean()
            let main = try #require(git.branch)
            let name = "studio-\(UUID().uuidString.prefix(6))"
            try await harness.call("git.branch.create", ["name": .string(name), "switchTo": false])
            let list = try await harness.call("git.branch.list")
            #expect(list["refs"]?.arrayValue?.contains { $0["name"]?.stringValue == name } == true)
            #expect(list["current"]?.stringValue == main)
            _ = try await clean()
            let switched = try await harness.call("git.branch.switch", ["name": .string(name)])
            #expect(switched["current"]?.stringValue == name)
            _ = try await clean()
            try await harness.call("git.branch.switch", ["name": .string(main)])
            try await harness.call("git.branch.delete", ["name": .string(name)])
            let tag = "Tag-\(UUID().uuidString.prefix(6))"
            try await harness.call("git.tag", ["name": .string(tag)])
            #expect(try await git.refs().contains { $0.kind == .tag && $0.name == tag })
            let combined = await harness.errorCode("git.branch.create", ["name": "x-y", "at": "HEAD"])
            #expect(combined != nil)
        }

        @Test func revertAndStashThroughTheRegistry() async throws {
            let git = try await clean()
            let note = UUID().uuidString
            let path = "Notizen/\(note).json"
            try GitTestSupport.write(#"{"format":1,"note":{"titel":"Zurück"}}"#, to: path, in: git.root)
            await git.refresh()
            try await harness.call("git.commit", ["message": "Note zum Zurücknehmen"])
            let reverted = try await harness.call("git.revert", ["commit": "HEAD"])
            #expect(reverted["commit"]?["subject"]?.stringValue?.hasPrefix("Revert") == true)
            #expect(!FileManager.default.fileExists(atPath: git.root.appendingPathComponent(path).path))

            try GitTestSupport.write(#"{"format":1,"note":{"titel":"Beiseite"}}"#, to: path, in: git.root)
            try await harness.call("git.stash", ["message": "beiseite"])
            #expect(!FileManager.default.fileExists(atPath: git.root.appendingPathComponent(path).path))
            try await harness.call("git.stash.apply")
            #expect(FileManager.default.fileExists(atPath: git.root.appendingPathComponent(path).path))
            try? FileManager.default.removeItem(at: git.root.appendingPathComponent(path))
        }
    }
}
