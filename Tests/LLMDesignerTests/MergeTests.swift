import Foundation
import LibraryMerge
import LLMDProtocol
import Testing
@testable import LLMDesigner

private func document(title: String = "Hausarbeit", updated: String = "2026-11-01T10:00:00Z", _ paragraphs: [String]) -> String {
    "---\nid: 3BC48041-12EC-4B73-87B7-BAA02A0AC3A3\ntitle: \(title)\ncustomTitle: false\ncreated: 2026-11-01T09:00:00Z\nupdated: \(updated)\nfont: serif\n---\n\n"
        + paragraphs.joined(separator: "\n\n") + "\n"
}

private func deck(_ slides: [(id: String, meta: String, text: String)]) -> String {
    "---\nid: 1\ntitle: Referat\nkind: presentation\nbackgrounds: {}\n---\n\n"
        + slides.map { "<!-- folie {\"id\":\"\($0.id)\",\"rolle\":\"folie\"\($0.meta)} -->\n\n\($0.text)" }.joined(separator: "\n\n") + "\n"
}

@Suite("Zusammenführen nach Bausteinen")
struct LibraryMergeTests {
    @Test func differentParagraphsMergeCleanly() {
        let base = document(["Einleitung.", "Methode.", "Ergebnis."])
        let ours = document(updated: "2026-11-02T10:00:00Z", ["Einleitung, gekürzt.", "Methode.", "Ergebnis."])
        let theirs = document(updated: "2026-11-03T10:00:00Z", ["Einleitung.", "Methode.", "Ergebnis mit R² = 0,64."])
        let result = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs)
        #expect(result.isClean)
        #expect(result.text == document(updated: "2026-11-03T10:00:00Z", ["Einleitung, gekürzt.", "Methode.", "Ergebnis mit R² = 0,64."]))
    }

    @Test func oneParagraphChangedOnBothSidesMergesByWords() {
        let base = document(["Die Regression ist ein altes Verfahren der Statistik."])
        let ours = document(["Die lineare Regression ist ein altes Verfahren der Statistik."])
        let theirs = document(["Die Regression ist ein altes Verfahren der beschreibenden Statistik."])
        let result = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs)
        #expect(result.isClean)
        #expect(result.text?.contains("Die lineare Regression ist ein altes Verfahren der beschreibenden Statistik.") == true)
    }

    @Test func overlappingChangesAreConflictsThatKeepOursUntilChosen() throws {
        let base = document(["Erster.", "R² = 0,61", "Letzter."])
        let ours = document(["Erster.", "R² = 0,64", "Letzter."])
        let theirs = document(["Erster.", "R² = 0,59", "Letzter."])
        let result = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs)
        let conflict = try #require(result.conflicts.first)
        #expect(result.conflicts.count == 1)
        #expect(conflict.ours == "R² = 0,64" && conflict.theirs == "R² = 0,59" && conflict.base == "R² = 0,61")
        #expect(result.text == ours)
        #expect(!(result.text ?? "").contains("<<<<<<<"))
        let theirsChosen = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs, choices: [0: .theirs])
        #expect(theirsChosen.text == theirs)
        let both = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs, choices: [0: .both])
        #expect(both.text == document(["Erster.", "R² = 0,64", "R² = 0,59", "Letzter."]))
        let custom = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs, choices: [0: .custom("R² = 0,62")])
        #expect(custom.text == document(["Erster.", "R² = 0,62", "Letzter."]))
    }

    @Test func headerMergesByFieldAndTheLaterSaveWins() throws {
        let base = document(title: "Alt", ["Text."])
        let ours = document(title: "Neu A", updated: "2026-11-05T10:00:00Z", ["Text."])
        let theirs = document(title: "Neu B", updated: "2026-11-04T10:00:00Z", ["Text."])
        let result = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: ours, theirs: theirs)
        #expect(result.conflicts.map(\.label) == ["Kopf: Titel"])
        #expect(result.text?.contains("updated: 2026-11-05T10:00:00Z") == true)
        #expect(result.text?.contains("title: Neu A") == true)
    }

    @Test func slidesMergeByID() {
        let base = deck([("a", "", "# Start"), ("b", "", "# Mitte\n\n- eins"), ("c", "", "# Ende")])
        // Here: slide a changed, slide c deleted.
        let ours = deck([("a", "", "# Start neu"), ("b", "", "# Mitte\n\n- eins")])
        // There: slide b changed, a slide d after b.
        let theirs = deck([("a", "", "# Start"), ("b", "", "# Mitte\n\n- eins\n- zwei"), ("d", "", "# Neu"), ("c", "", "# Ende")])
        let result = LibraryMerge.merge(path: "Documents/y.md", base: base, ours: ours, theirs: theirs)
        #expect(result.isClean)
        let slides = MergeText.slides(of: MergeText.split(result.text ?? "").body)
        #expect(slides.map(\.id) == ["a", "b", "d"])
        #expect(slides[0].text == "# Start neu")
        #expect(slides[1].text.contains("- zwei"))
    }

    @Test func aSlideDeletedHereAndChangedThereIsAQuestion() {
        let base = deck([("a", "", "# Start"), ("b", "", "# Mitte")])
        let ours = deck([("a", "", "# Start")])
        let theirs = deck([("a", "", "# Start"), ("b", "", "# Mitte, überarbeitet")])
        let result = LibraryMerge.merge(path: "Documents/y.md", base: base, ours: ours, theirs: theirs)
        #expect(result.conflicts.count == 1)
        #expect(MergeText.slides(of: MergeText.split(result.text ?? "").body).map(\.id) == ["a"])
        let restored = LibraryMerge.merge(path: "Documents/y.md", base: base, ours: ours, theirs: theirs, choices: [0: .theirs])
        #expect(MergeText.slides(of: MergeText.split(restored.text ?? "").body).map(\.id) == ["a", "b"])
    }

    @Test func slideElementsMergeByID() throws {
        let picture = #"{"id":"p","quelle":"Bilder/a.png","x":0.1,"y":0.1,"b":0.3,"h":0.3}"#
        let moved = #"{"id":"p","quelle":"Bilder/a.png","x":0.5,"y":0.1,"b":0.3,"h":0.3}"#
        let box = #"{"id":"k","inhalt":"Merksatz","kasten":"merksatz","x":0.1,"y":0.6,"b":0.4,"h":0.2}"#
        let base = deck([("a", ",\"bilder\":[\(picture)]", "# Folie")])
        let ours = deck([("a", ",\"bilder\":[\(moved)]", "# Folie")])
        let theirs = deck([("a", ",\"bilder\":[\(picture),\(box)]", "# Folie\n\n- Punkt")])
        let result = LibraryMerge.merge(path: "Documents/y.md", base: base, ours: ours, theirs: theirs)
        #expect(result.isClean)
        let slide = try #require(MergeText.slides(of: MergeText.split(result.text ?? "").body).first)
        let elements = try #require(slide.meta["bilder"] as? [[String: Any]])
        #expect(elements.map { $0["id"] as? String } == ["p", "k"])
        #expect(elements[0]["x"] as? Double == 0.5)
        #expect(slide.text.contains("- Punkt"))
    }

    @Test func recordsMergeByEntries() throws {
        let base = #"{"format":1,"note":{"titel":"Plan","geaendert":"2026-11-01","tags":["a","b"],"todos":[{"id":"1","text":"Lesen","erledigt":false},{"id":"2","text":"Schreiben","erledigt":false}]}}"#
        let ours = #"{"format":1,"note":{"titel":"Plan","geaendert":"2026-11-03","tags":["a","b","c"],"todos":[{"id":"1","text":"Lesen","erledigt":true},{"id":"2","text":"Schreiben","erledigt":false}]}}"#
        let theirs = #"{"format":1,"note":{"titel":"Plan","geaendert":"2026-11-02","tags":["b"],"todos":[{"id":"1","text":"Lesen","erledigt":false},{"id":"2","text":"Kapitel schreiben","erledigt":false},{"id":"3","text":"Abgeben","erledigt":false}]}}"#
        let result = LibraryMerge.merge(path: "Notizen/n.json", base: base, ours: ours, theirs: theirs)
        #expect(result.isClean)
        let object = try #require(try JSONSerialization.jsonObject(with: Data((result.text ?? "").utf8)) as? [String: Any])
        let note = try #require(object["note"] as? [String: Any])
        #expect(note["geaendert"] as? String == "2026-11-03")
        #expect(note["tags"] as? [String] == ["b", "c"])
        let todos = try #require(note["todos"] as? [[String: Any]])
        #expect(todos.map { $0["id"] as? String } == ["1", "2", "3"])
        #expect(todos[0]["erledigt"] as? Bool == true)
        #expect(todos[1]["text"] as? String == "Kapitel schreiben")
    }

    @Test func recordFieldChangedOnBothSidesIsNamed() throws {
        let base = #"{"format":1,"projekt":{"titel":"A","aufgaben":[{"id":"1","titel":"Kapitel 3","prioritaet":"mittel"}]}}"#
        let ours = #"{"format":1,"projekt":{"titel":"A","aufgaben":[{"id":"1","titel":"Kapitel 3","prioritaet":"hoch"}]}}"#
        let theirs = #"{"format":1,"projekt":{"titel":"A","aufgaben":[{"id":"1","titel":"Kapitel 3","prioritaet":"niedrig"}]}}"#
        let result = LibraryMerge.merge(path: "Projekte/p.json", base: base, ours: ours, theirs: theirs)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.label == "projekt · aufgaben „Kapitel 3“ · prioritaet")
        #expect(conflict.ours == "hoch" && conflict.theirs == "niedrig")
        let chosen = LibraryMerge.merge(path: "Projekte/p.json", base: base, ours: ours, theirs: theirs, choices: [0: .theirs])
        #expect(chosen.text?.contains("\"niedrig\"") == true)
    }

    @Test func aFileDeletedOnOneSideIsOneChoice() {
        let base = document(["Text."])
        let result = LibraryMerge.merge(path: "Documents/x.md", base: base, ours: nil, theirs: document(["Text, geändert."]))
        #expect(result.conflicts.count == 1)
        #expect(result.text == nil)
        #expect(LibraryMerge.merge(path: "Documents/x.md", base: base, ours: nil, theirs: document(["Neu."]), choices: [0: .theirs]).text == document(["Neu."]))
    }
}

/// A repository with the app's merge driver, as the app sets it up.
@MainActor
private enum MergeRig {
    static var llmd: String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".build/debug/llmd").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func library(driver: Bool) async throws -> (LibraryGit, URL, String) {
        let root = GitTestSupport.folder("M.llmdlibrary")
        let id = UUID().uuidString
        try GitTestSupport.write(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,61"]), to: "Documents/\(id).md", in: root)
        let git = LibraryGit(root: root)
        git.environment = GitTestSupport.environment
        git.driverPath = driver ? try #require(llmd, "llmd ist nicht gebaut") : nil
        try await git.enable()
        let repository = try #require(git.repository)
        try await repository.run(["branch", "experiment"])
        return (git, root, "Documents/\(id).md")
    }

    static func commit(_ text: String, to path: String, on branch: String, in git: LibraryGit) async throws {
        let repository = try #require(git.repository)
        try await repository.run(["switch", "-q", branch])
        try text.write(to: git.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await repository.run(["commit", "-q", "-am", "Änderung auf \(branch)"])
    }
}

@Suite("Zusammenführen im Repository", .serialized)
@MainActor
struct GitMergeTests {
    @Test func driverMergesParagraphsThatGitWouldFightOver() async throws {
        let (git, _, path) = try await MergeRig.library(driver: true)
        // The same line on both sides: git alone would stop with a conflict, the driver merges the words.
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,61 (n = 140)"]), to: path, on: "experiment", in: git)
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Endergebnis: R² = 0,61"]), to: path, on: "main", in: git)
        let outcome = try await git.merge("experiment")
        #expect(outcome == .merged)
        let text = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains("Endergebnis: R² = 0,61 (n = 140)"))
        let config = try await git.repository!.run(["config", "--local", "merge.llmd.driver"]).text
        #expect(config.contains("git merge-file %O %A %B %P"))
    }

    @Test func conflictKeepsAValidFileUntilResolved() async throws {
        let (git, _, path) = try await MergeRig.library(driver: true)
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,59"]), to: path, on: "experiment", in: git)
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,64"]), to: path, on: "main", in: git)
        let outcome = try await git.merge("experiment")
        #expect(outcome == .conflicts(1))
        #expect(git.isMerging)
        let onDisk = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(!onDisk.contains("<<<<<<<"))
        #expect(onDisk.contains("R² = 0,64"))
        let files = try await git.conflictFiles()
        let file = try #require(files.first)
        #expect(file.merge?.conflicts.count == 1)
        await #expect(throws: GitError.self) { try await git.finishMerge() }
        try await git.resolve(file, choices: [0: .theirs])
        #expect(try await git.conflictFiles().isEmpty)
        try await git.finishMerge()
        #expect(!git.isMerging)
        let head = try #require(try await git.log(limit: 1).first)
        #expect(head.isMerge)
        let merged = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(merged.contains("R² = 0,59"))
    }

    @Test func conflictMarksFromATextMergeAreRepaired() async throws {
        let (git, _, path) = try await MergeRig.library(driver: false)
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,59"]), to: path, on: "experiment", in: git)
        try await MergeRig.commit(document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,64"]), to: path, on: "main", in: git)
        // As in the Terminal, on a clone without the driver: git writes <<<<<<< into the file.
        _ = try await git.repository!.run(["merge", "-q", "experiment"], allowFailure: true)
        let marked = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(LibraryGit.hasConflictMarkers(marked))
        await git.refresh()
        let repaired = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(!LibraryGit.hasConflictMarkers(repaired))
        #expect(repaired.contains("R² = 0,64"))
        try await git.abortMerge()
        #expect(!git.isMerging)
        let back = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
        #expect(back == document(["Einleitung.", "Methode.", "Ergebnis: R² = 0,64"]))
    }

    @Test func uncommittedChangesBlockAMerge() async throws {
        let (git, _, path) = try await MergeRig.library(driver: false)
        try "geändert".write(to: git.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.uncommittedChanges) { try await git.merge("experiment") }
    }

    @Test func unsafeDriverValueIsReplacedByTheAppsOwn() async throws {
        let (git, _, _) = try await MergeRig.library(driver: true)
        let repository = try #require(git.repository)
        try await repository.run(["config", "--local", "merge.llmd.driver", "touch /tmp/llmd-evil"])
        // A fresh model on the same library: it writes its own value first, then checks.
        let again = LibraryGit(root: git.root)
        again.environment = GitTestSupport.environment
        again.driverPath = git.driverPath
        _ = try await again.checkedRepository()
        let value = try await repository.run(["config", "--local", "merge.llmd.driver"]).text
        #expect(!value.contains("/tmp/llmd-evil"))
        // Without a driver of its own, the app refuses a foreign one.
        let strict = LibraryGit(root: git.root)
        strict.environment = GitTestSupport.environment
        strict.driverPath = nil
        try await repository.run(["config", "--local", "merge.llmd.driver", "touch /tmp/llmd-evil"])
        await #expect(throws: GitError.self) { _ = try await strict.checkedRepository() }
    }
}

extension ActionSuites {
    @Suite("Git-Merge-Actions")
    @MainActor
    struct GitMergeActionTests {
        let harness = ActionHarness()

        @Test func mergeConflictsResolveAndFinishThroughTheRegistry() async throws {
            let git = harness.app.git
            git.environment = GitTestSupport.environment
            if !git.isEnabled { try await harness.call("git.enable") }
            let repository = try #require(git.repository)
            harness.app.saveEverythingForGit()
            await git.refresh()
            if !git.changes.isEmpty { try await harness.call("git.commit", ["message": "Vorher"]) }
            let note = UUID().uuidString
            let path = "Notizen/\(note).json"
            func write(_ todo: String) throws {
                try GitTestSupport.write(#"{"format":1,"note":{"titel":"Merge-Test","todos":[{"id":"1","text":"\#(todo)","erledigt":false}]}}"#, to: path, in: git.root)
            }
            try write("Lesen")
            try await repository.run(["add", "--", path])
            try await repository.run(["commit", "-q", "-m", "Note"])
            let main = try #require(git.branch)
            let branch = "merge-test-\(note.prefix(6))"
            try await repository.run(["switch", "-q", "-c", branch])
            try write("Lesen, Kapitel 1")
            try await repository.run(["commit", "-q", "-am", "dort"])
            try await repository.run(["switch", "-q", main])
            try write("Lesen, Kapitel 2")
            try await repository.run(["commit", "-q", "-am", "hier"])

            let merged = try await harness.call("git.merge", ["branch": .string(branch)])
            #expect(merged["outcome"]?.stringValue == "conflicts")
            let conflicts = try await harness.call("git.conflicts")
            let files = conflicts["files"]?.arrayValue ?? []
            #expect(files.contains { $0["path"]?.stringValue == path })
            let resolved = try await harness.call("git.conflict.resolve", ["path": .string(path), "choice": "theirs"])
            #expect(resolved["remaining"]?.intValue == 0)
            let finished = try await harness.call("git.merge.finish")
            #expect(finished["commit"]?["parents"]?.arrayValue?.count == 2)
            let text = try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
            #expect(text.contains("Lesen, Kapitel 1"))
            try await repository.run(["branch", "-q", "-D", branch])
        }
    }
}
