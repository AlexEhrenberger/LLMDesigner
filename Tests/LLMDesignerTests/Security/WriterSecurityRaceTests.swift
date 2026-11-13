import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// T4 and T5: export, undo between runs and the person, and changes that arrive while the text moves on.
/// The person is played by `updateDocument`, the way the editor reports typing.
extension ActionSuites {
@MainActor
@Suite("Writer-Sicherheit und Gleichzeitigkeit (T4/T5)", .serialized)
struct WriterSecurityRaceTests {
    let h = ActionHarness()

    private final class Requests {
        var list: [ApprovalRequest] = []
    }

    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    private func withExportFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = temporary("Export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { ActionExportFolder.set(nil, settings: h.app.settings) }
        try await body(folder)
    }

    private func type(_ id: String, _ markdown: String) {
        h.app.updateDocument(UUID(uuidString: id)!, markdown: markdown)
    }

    // MARK: Export

    @Test func exportingOverALinkLeavesItsTargetAlone() async throws {
        try await withExportFolder { folder in
            let target = temporary("Ziel").appendingPathExtension("txt")
            try Data("Unberührt".utf8).write(to: target)
            let link = folder.appendingPathComponent("Bericht.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let id = try await h.document("Inhalt")
            try await h.call("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(link.path), "overwrite": true])
            #expect(try String(contentsOf: target, encoding: .utf8) == "Unberührt")
        }
    }

    @Test func picturesOfAnExportDoNotFollowALinkedFolder() async throws {
        try await withExportFolder { folder in
            let outside = temporary("Draussen")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Bericht-Bilder"), withDestinationURL: outside)
            let id = try await h.document("Mit Bild")
            try await h.call("writer.image.insert", ["doc": .string(id), "file": .string(try WriterFixture.picture().path)])
            let code = await h.errorCode("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(folder.appendingPathComponent("Bericht.md").path)])
            #expect(code == RPCError.invalidTargetCode)
            let written = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            #expect(written.isEmpty, "Export schrieb über die Verknüpfung nach draußen: \(written)")
        }
    }

    @Test func anExportOutsideTheFolderAsksAndANoLeavesNothing() async throws {
        try await withExportFolder { folder in
            let requests = Requests()
            h.registry.approval.presenter = { request in
                requests.list.append(request)
                return false
            }
            let id = try await h.document("Inhalt")
            for path in [temporary("Woanders").appendingPathExtension("md").path, folder.path + "/../Hinaus-\(UUID().uuidString).md"] {
                #expect(await h.errorCode("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(path)]) == RPCError.deniedCode, "\(path)")
                #expect(!FileManager.default.fileExists(atPath: path))
            }
            #expect(requests.list.count == 2)
            // Over MCP even the export folder asks.
            requests.list = []
            #expect(await h.errorCode("writer.export", ["doc": .string(id), "format": "markdown"], channel: .mcp) == RPCError.deniedCode)
            #expect(requests.list.count == 1)
        }
    }

    // MARK: Vouching for a text (S4)

    @Test func confirmingAForeignTextShowsAllOfIt() async throws {
        let tail = "ANWEISUNG AM ENDE"
        let markdown = String(repeating: "Ein harmloser Satz. ", count: 60) + "\n\n" + tail
        let made = try await h.call("writer.doc.create", ["title": .string("Fremd \(UUID().uuidString)"), "markdown": .string(markdown)], channel: .mcp)
        let id = try #require(made["id"]?.stringValue)
        let requests = Requests()
        h.registry.approval.presenter = { request in
            requests.list.append(request)
            return false
        }
        #expect(await h.errorCode("writer.doc.confirmReviewed", ["doc": .string(id)]) == RPCError.deniedCode)
        let request = try #require(requests.list.first)
        #expect(request.fullText?.contains(tail) == true)
        let alert = ActionApproval.makeAlert(for: request)
        let shown = ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string
        #expect(shown?.contains(tail) == true, "Der Dialog zeigt das Ende des Texts nicht")
        #expect(alert.buttons.first?.title == "Nicht erlauben")
        #expect(h.app.document(UUID(uuidString: id)!)?.provenance == .foreign)
    }

    @Test func otherQuestionsKeepTheirShortForm() async throws {
        let request = ApprovalRequest(action: "writer.export", summary: "Exportiert", channel: .mcp, target: "/tmp/x.md",
                                      detail: String(repeating: "x", count: 1_000), reason: "Grund")
        let alert = ActionApproval.makeAlert(for: request)
        #expect(alert.accessoryView == nil)
        #expect(alert.informativeText.contains(String(repeating: "x", count: ActionApproval.detailLimit) + " …"))
    }

    // MARK: Undo

    @Test func undoKeepsWhatThePersonTypedAfterwards() async throws {
        let id = try await h.document("Eins")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"])
        type(id, h.text(id) + "\nVom Menschen getippt.\n")
        #expect(await h.errorCode("writer.edit.undo", ["doc": .string(id)]) == RPCError.versionConflictCode)
        #expect(h.text(id).contains("Vom Menschen getippt."), "Undo hat getippten Text gelöscht: \(h.text(id).debugDescription)")
        #expect(h.text(id).contains("**Eins**"))
    }

    @Test func redoKeepsWhatThePersonTypedAfterTheUndo() async throws {
        let id = try await h.document("Eins")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"])
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        type(id, h.text(id) + "\nDanach getippt.\n")
        #expect(await h.errorCode("writer.edit.redo", ["doc": .string(id)]) == RPCError.versionConflictCode)
        #expect(h.trimmed(id) == "Eins\nDanach getippt.")
    }

    @Test func undoAndRedoStillWorkOnAnUntouchedDocument() async throws {
        let id = try await h.document("Eins")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"])
        try await h.call("writer.format.italic", ["doc": .string(id), "match": "Eins", "state": "on"])
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Eins")
        try await h.call("writer.edit.redo", ["doc": .string(id)])
        #expect(h.trimmed(id) == "**Eins**")
    }

    @Test func anMcpClientCannotUndoAnotherRunsWork() async throws {
        let id = try await h.document("Eins")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"], run: "terminal-lauf")
        #expect(await h.errorCode("writer.edit.undo", ["doc": .string(id)], channel: .mcp, run: "mcp-lauf") == RPCError.notFoundCode)
        #expect(h.trimmed(id) == "**Eins**", "MCP hat die Änderung des Terminals zurückgenommen")
    }

    @Test func anMcpClientUndoesItsOwnAndThePersonAny() async throws {
        let id = try await h.document("Eins Zwei")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"], channel: .mcp, run: "mcp-lauf")
        try await h.call("writer.edit.undo", ["doc": .string(id)], channel: .mcp, run: "mcp-lauf")
        #expect(h.trimmed(id) == "Eins Zwei")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Zwei", "state": "on"], channel: .mcp, run: "mcp-lauf")
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Eins Zwei")
    }

    /// A batch that fails takes its steps back, but not over what the person typed meanwhile.
    @Test func aFailedBatchKeepsWhatThePersonTyped() async throws {
        let id = try await h.document("Eins")
        h.registry.approval.presenter = { _ in true }
        let server = try FakeLLMServer(script: [.text("Neu.")])
        server.delay = 0.5
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        async let batch = h.registry.runBatch([
            ("writer.format.bold", ["doc": .string(id), "match": "Eins", "state": "on"]),
            ("writer.ai.write", ["doc": .string(id), "instruction": "Weiter"]),
            ("writer.format.bold", ["doc": .string(id), "match": "gibtsnicht", "state": "on"]),
        ], app: h.app, channel: .cli)
        try await Task.sleep(for: .milliseconds(200))
        type(id, h.text(id) + "\nGetippt.\n")
        _ = try? await batch
        #expect(h.text(id).contains("Getippt."), "→ \(h.text(id).debugDescription)")
    }

    // MARK: T5 – while the text moves on

    /// The text changes while the approval dialog is open: the call no longer fits and comes back as a conflict.
    @Test(arguments: ["range", "match"])
    func aChangeApprovedLateIsAConflictNotAnotherPlace(form: String) async throws {
        let id = try await h.document("Hier steht das Ziel im Satz.")
        let text = h.text(id)
        let offset = text.distance(from: text.startIndex, to: text.range(of: "Ziel")!.lowerBound)
        h.registry.approval.presenter = { _ in
            self.type(id, "Neu vorne. " + self.h.text(id))
            return true
        }
        var args: [String: JSONValue] = ["doc": .string(id), "state": "on"]
        args[form] = form == "range" ? .string("\(offset):4") : "Ziel"
        #expect(await h.errorCode("writer.format.bold", .object(args), channel: .chat) == RPCError.versionConflictCode)
        #expect(h.trimmed(id) == "Neu vorne. Hier steht das Ziel im Satz.")
    }

    @Test func anApprovalWithoutChangeStillGoesThrough() async throws {
        let id = try await h.document("Hier steht das Ziel.")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Ziel", "state": "on"], channel: .chat)
        #expect(h.trimmed(id) == "Hier steht das **Ziel**.")
    }

    private func withSlowModel(_ answer: String, _ body: () async throws -> Void) async throws {
        let server = try FakeLLMServer(script: [.text(answer)])
        server.delay = 0.6
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body()
    }

    /// The person types elsewhere while the model rewrites a passage: the rewrite lands on the passage.
    @Test(arguments: ["range", "match", "block"])
    func aRewriteWhileThePersonTypesElsewhereHitsThePassage(form: String) async throws {
        try await withSlowModel("Kurz.") {
            let id = try await h.document("Erster Satz.\n\nZweiter Satz.")
            let text = h.text(id)
            let offset = text.distance(from: text.startIndex, to: text.range(of: "Zweiter Satz.")!.lowerBound)
            var args: [String: JSONValue] = ["doc": .string(id), "preset": "shorter"]
            switch form {
            case "range": args["range"] = .string("\(offset):13")
            case "match": args["match"] = "Zweiter Satz."
            default: args["block"] = try #require(try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue?[1]["id"])
            }
            async let rewrite = h.call("writer.ai.rewrite", .object(args))
            try await Task.sleep(for: .milliseconds(200))
            type(id, "Ganz neu vorne.\n\n" + h.text(id))
            let result = try? await rewrite
            let now = h.trimmed(id)
            if form == "block" {
                // A block id names the place by its index: after a block before it, it is stale, and that is said.
                #expect(result == nil)
                #expect(now == "Ganz neu vorne.\n\nErster Satz.\n\nZweiter Satz.")
            } else {
                #expect(now == "Ganz neu vorne.\n\nErster Satz.\n\nKurz.", "→ \(now.debugDescription)")
            }
        }
    }

    /// K9: the editor reports typing after a short pause, and while it holds typing back it doesn't take a change
    /// from outside; at its pause it writes what it has. Played here by `writerFlush`, which writes what it holds.
    @Test func whatAnAgentWritesWhileThePersonTypesIsNotTypedOver() async throws {
        try await withSlowModel("Vom Modell.") {
            let id = try await h.document("Erster Absatz.")
            let uuid = try #require(UUID(uuidString: id))
            final class Editor {
                var pending: String?
            }
            let editor = Editor()
            let app = h.app
            let old = app.writerFlush
            app.writerFlush = {
                guard let text = editor.pending else { return }
                editor.pending = nil
                app.updateDocument(uuid, markdown: text)
            }
            defer { app.writerFlush = old }
            async let write = h.call("writer.ai.write", ["doc": .string(id), "instruction": "Weiter"])
            try await Task.sleep(for: .milliseconds(200))
            // Typed while the model writes, not reported yet.
            editor.pending = h.text(id).replacingOccurrences(of: "Erster Absatz.", with: "Erster Absatz, getippt.")
            _ = try await write
            // The editor's pause comes.
            app.writerFlush?()
            #expect(h.text(id).contains("getippt") && h.text(id).contains("Vom Modell."), "→ \(h.text(id).debugDescription)")
        }
    }

    /// The person changes the passage itself while the model rewrites it: theirs stays, the model's text comes back.
    @Test func aRewriteOfAPassageThePersonChangedIsAConflict() async throws {
        try await withSlowModel("Kurz.") {
            let id = try await h.document("Erster Satz.\n\nZweiter Satz.")
            async let rewrite = h.call("writer.ai.rewrite", ["doc": .string(id), "range": "14:13", "preset": "shorter"])
            try await Task.sleep(for: .milliseconds(200))
            type(id, "Erster Satz.\n\nZweiter Satz, vom Menschen erweitert.")
            do {
                _ = try await rewrite
                Issue.record("Die Umformulierung lief trotz geänderter Stelle")
            } catch let error as RPCError {
                #expect(error.code == RPCError.versionConflictCode)
                #expect(error.data?["text"]?.stringValue == "Kurz.")
            }
            #expect(h.trimmed(id) == "Erster Satz.\n\nZweiter Satz, vom Menschen erweitert.")
        }
    }

    // MARK: Moving an address along

    @Test func aRangeMovesWithTheTextBeforeIt() throws {
        let old = "Eins Zwei Drei"
        func moved(_ range: String, to new: String) throws -> String? {
            var address = WriterAddress()
            address.range = range
            return try WriterAddressing.rebase(address, from: old, to: new).range
        }
        #expect(try moved("5:4", to: "Null Eins Zwei Drei") == "10:4")
        #expect(try moved("0:4", to: "Eins Zwei Drei und mehr") == "0:4")
        #expect(try moved("10:4", to: "Eins Zwei, drei, Drei") == "17:4")
        #expect(throws: RPCError.self) { try moved("5:4", to: "Eins Zwo Drei") }
        var nth = WriterAddress()
        nth.match = "Zwei"
        nth.occurrence = 1
        #expect(throws: RPCError.self) { try WriterAddressing.rebase(nth, from: old, to: "Zwei " + old) }
        #expect(try WriterAddressing.rebase(nth, from: old, to: old) == nth)
    }

    @Test func aFailedBatchTakesEverythingBack() async throws {
        let a = try await h.document("A")
        let before = h.app.documents
        let title = "Stapel \(UUID().uuidString)"
        await #expect(throws: RPCError.self) {
            try await h.registry.runBatch([
                ("writer.doc.create", ["title": .string(title), "markdown": "x"]),
                ("writer.text.insert", ["doc": .string(a), "text": "mehr"]),
                ("writer.format.bold", ["doc": .string(a), "match": "gibtsnicht", "state": "on"]),
            ], app: h.app, channel: .cli)
        }
        #expect(h.app.documents == before)
        #expect(!h.app.documents.contains { $0.displayTitle == title })
    }

    // MARK: Plots

    static let hostileFormulas = [
        "\\operatorname{__import__}(x)", "f(x) = \\mathrm{eval}(x)", "f(x) = \\text{os.system('ls')}", "x^{__class__}",
        "f(x) = \\operatorname{exec}(x) + 1", "\\mathrm{open}(x)", "f(x) = x\\;\\#\\; import os", "y = \"; import os; \"",
    ]

    @Test(arguments: hostileFormulas)
    func plotCodeIsBuiltOnlyFromItsWhitelist(latex: String) {
        guard let program = try? PlotTranslator.program(for: latex) else { return }
        let code = (program.functions.map(\.code) + program.items.map(\.code)).joined(separator: "\n")
        for word in ["__", "import", "eval", "exec", "open(", "os.", "system", "\"", "'", ";"] {
            #expect(!code.contains(word), "„\(word)“ im Plot-Code von \(latex): \(code)")
        }
    }
}
}
