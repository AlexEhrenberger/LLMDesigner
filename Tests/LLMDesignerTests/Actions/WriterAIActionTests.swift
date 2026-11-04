import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Writer-KI und Analyse", .serialized)
struct WriterAIActionTests {
    let h = ActionHarness()

    private func withServer(_ script: [FakeLLMServer.Turn] = [], completions: [String] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer(script: script)
        server.completions = completions
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    @Test func writeGoesToTheAddress() async throws {
        try await withServer([.text("Hier ist der Absatz:\nDer neue Absatz.")]) { _ in
            let id = try await h.document("# Eins\n\nA\n\n# Zwei\n\nB")
            let result = try await h.call("writer.ai.write", ["doc": .string(id), "heading": "Eins", "instruction": "Schreib weiter"])
            #expect(result["text"] == "Der neue Absatz.")
            #expect(result["applied"] == true)
            #expect(h.trimmed(id) == "# Eins\n\nDer neue Absatz.\n\nA\n\n# Zwei\n\nB")
            // One step back.
            try await h.call("writer.edit.undo")
            #expect(h.trimmed(id) == "# Eins\n\nA\n\n# Zwei\n\nB")
        }
    }

    @Test func theModelSeesWhereItWrites() async throws {
        try await withServer([.text("Text")]) { server in
            let id = try await h.document("Erster\n\nZweiter")
            try await h.call("writer.ai.write", ["doc": .string(id), "match": "Erster", "instruction": "Weiter"])
            let prompt = server.requests.last?["messages"]?.jsonLine() ?? ""
            #expect(prompt.contains("Erster"))
            #expect(prompt.contains(WriterPrompts.cursorMarker))
            #expect(prompt.contains("Weiter"))
        }
    }

    @Test func rewriteReplacesOrProposes() async throws {
        try await withServer([.text("kurz"), .text("knapp")]) { server in
            let id = try await h.document("Das ist ein sehr langer Satz.\n\nDanach.")
            let proposal = try await h.call("writer.ai.rewrite", ["doc": .string(id), "match": "sehr langer", "preset": "shorter", "apply": false])
            #expect(proposal["applied"] == false)
            #expect(proposal["text"] == "kurz")
            #expect(h.trimmed(id).hasPrefix("Das ist ein sehr langer Satz."))
            let prompt = server.requests.last?["messages"]?.jsonLine() ?? ""
            #expect(prompt.contains(WriterPrompts.selectionStart))
            #expect(prompt.contains("kürzer"))

            try await h.call("writer.ai.rewrite", ["doc": .string(id), "match": "sehr langer", "instruction": "Kürzer"])
            #expect(h.trimmed(id) == "Das ist ein knapp Satz.\n\nDanach.")
            #expect(await h.errorCode("writer.ai.rewrite", ["doc": .string(id), "match": "Danach"]) == RPCError.invalidParamsCode)
            #expect(await h.errorCode("writer.ai.rewrite", ["doc": .string(id), "preset": "shorter"]) == RPCError.invalidParamsCode)
        }
    }

    @Test func aPassageThatChangedMeanwhileIsNotHit() async throws {
        try await withServer([.text("Neu")]) { _ in
            let id = try await h.document("Alt und gut.")
            let uuid = UUID(uuidString: id)!
            // The person changes the text while the model writes.
            let task = Task { @MainActor in
                await Task.yield()
                h.app.updateDocument(uuid, markdown: "Ganz anders.")
            }
            let code = await h.errorCode("writer.ai.rewrite", ["doc": .string(id), "match": "Alt", "preset": "shorter"])
            await task.value
            #expect(code == RPCError.notFoundCode || h.trimmed(id) == "Ganz anders.")
            #expect(!h.trimmed(id).contains("Neu"))
        }
    }

    @Test func expandReplacesThePoints() async throws {
        try await withServer([.text("Ein ganzer Satz.")]) { server in
            let id = try await h.document("- Punkt\n- Noch einer")
            let blocks = try #require(try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue)
            try await h.call("writer.ai.expand", ["doc": .string(id), "block": .string(try #require(blocks[0]["id"]?.stringValue))])
            #expect(h.trimmed(id) == "Ein ganzer Satz.")
            #expect((server.requests.last?["messages"]?.jsonLine() ?? "").contains("Stichpunkten"))
        }
    }

    @Test func answerChangesNothingAndMarksTheRun() async throws {
        try await withServer([.text("<think>hm</think>Vierzehn."), .text("Ja.")]) { _ in
            let id = try await h.document("Es sind 14 Birnen.")
            let before = h.text(id)
            let answer = try await h.call("writer.ai.answer", ["doc": .string(id), "question": "Wie viele?"])
            #expect(answer["answer"] == "Vierzehn.")
            #expect(h.text(id) == before)

            var document = try #require(h.app.document(UUID(uuidString: id)!))
            document.provenance = .foreign
            h.app.restoreDocument(document)
            try await h.call("writer.ai.answer", ["doc": .string(id), "question": "Und?"], run: "ki-frage")
            #expect(h.registry.runState(id: "ki-frage", channel: .cli).hasReadUntrusted)
        }
    }

    @Test func checkKeepsOnlyWhatTheTextHolds() async throws {
        let reply = #"{"probleme":[{"art":"Rechtschreibung","original":"Fehlre","korrektur":"Fehler","erklaerung":"Buchstaben vertauscht"},{"art":"x","original":"gibt es nicht","korrektur":"y","erklaerung":"z"},{"art":"x","original":"Ein","korrektur":"Ein","erklaerung":"nichts"}]}"#
        try await withServer(completions: [reply]) { _ in
            let id = try await h.document("Ein Fehlre im Text.")
            let before = h.text(id)
            let result = try await h.call("writer.ai.check", ["doc": .string(id), "kind": "language"])
            let findings = try #require(result["findings"]?.arrayValue)
            #expect(findings.count == 1)
            #expect(findings.first?["correction"] == "Fehler")
            #expect(h.text(id) == before)
            let empty = try await h.document("```\ncode\n```")
            #expect(await h.errorCode("writer.ai.check", ["doc": .string(empty)]) == RPCError.invalidTargetCode)
        }
    }

    @Test func commentsLandOnTheirPassage() async throws {
        let reply = #"{"kommentare":[{"zitat":"schwacher Satz","kommentar":"Geht das stärker?"},{"zitat":"steht nirgends","kommentar":"Fällt weg"}]}"#
        try await withServer(completions: [reply]) { _ in
            let id = try await h.document("Ein schwacher Satz steht hier.")
            let result = try await h.call("writer.ai.comment", ["doc": .string(id)])
            #expect(result["added"] == 1)
            #expect(h.text(id).contains("data-comment"))
            #expect(WriterComment.strip(h.trimmed(id)) == "Ein schwacher Satz steht hier.")
        }
    }

    @Test func statusAndCancel() async throws {
        let server = try FakeLLMServer(script: [.text("Text")])
        server.delay = 1
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        let id = try await h.document("Inhalt")
        let running = Task { @MainActor in await h.errorCode("writer.ai.write", ["doc": .string(id), "instruction": "Schreib"]) }
        while h.app.writerAIJobs.jobs.isEmpty { await Task.yield() }
        let status = try await h.call("writer.ai.status")
        #expect(status["running"]?.arrayValue?.first?["kind"] == "write")
        #expect(status["running"]?.arrayValue?.first?["doc"] == .string(id))
        let cancelled = try await h.call("writer.ai.cancel", ["doc": .string(id)])
        #expect(cancelled["cancelled"] == 1)
        #expect(await running.value == RPCError.unavailableCode)
        #expect(h.trimmed(id) == "Inhalt")
        let after = try await h.call("writer.ai.status")
        #expect(after["running"] == [])
        #expect(after["finished"]?.arrayValue?.last?["error"] == "Abgebrochen.")
    }

    @Test func withoutAModelItSaysSo() async throws {
        let id = try await h.document("Text")
        let old = h.app.endpoint
        h.app.endpoint = "keine adresse"
        defer { h.app.endpoint = old }
        #expect(await h.errorCode("writer.ai.answer", ["doc": .string(id), "question": "?"]) == RPCError.unavailableCode)
    }

    // MARK: Analysis

    private var longText: String {
        String(repeating: "Das Wasser fließt den Berg hinab und sammelt sich im Tal. ", count: 40)
    }

    @Test func analysisRunGetDelete() async throws {
        try await withServer { _ in
            let id = try await h.document(longText)
            let state = try await h.call("writer.analysis.run", ["doc": .string(id), "modules": ["structure"]])
            #expect(state["running"] == false)
            #expect(state["doc"] == .string(id))
            let got = try await h.call("writer.analysis.get", ["doc": .string(id)])
            #expect(got["state"]?["running"] == false)
            #expect(got["state"]?["outdated"] == false || got["analysis"] == nil)

            try await h.call("writer.analysis.delete", ["doc": .string(id)])
            let gone = try await h.call("writer.analysis.get", ["doc": .string(id)])
            #expect(gone["analysis"] == nil)
            try await h.call("writer.analysis.cancel", ["doc": .string(id)])
        }
    }

    @Test func aTextTooShortIsNotAnalyzed() async throws {
        try await withServer { _ in
            let id = try await h.document("Kurz.")
            #expect(await h.errorCode("writer.analysis.run", ["doc": .string(id)]) == RPCError.unavailableCode)
        }
    }

    @Test func analysisOfASavedResultIsReadAndUndone() async throws {
        let id = try await h.document(longText)
        let uuid = UUID(uuidString: id)!
        var analysis = ContentAnalysis(sourceChecksum: DocumentOutlineBuilder.contentChecksum(h.text(id)), generatedAt: Date(), model: "fake")
        analysis.isShortened = true
        h.app.documentAnalyses[uuid] = analysis
        h.app.analysisStore.save(analysis, for: uuid)
        let got = try await h.call("writer.analysis.get", ["doc": .string(id)])
        #expect(got["analysis"]?["isShortened"] == true)
        #expect(got["state"]?["outdated"] == false)

        try await h.call("writer.analysis.delete", ["doc": .string(id)])
        #expect(h.app.analysis(of: uuid) == nil)
        try await h.call("writer.edit.undo")
        #expect(h.app.analysis(of: uuid)?.isShortened == true)
    }

    @Test func autoTitleFollowsTheText() async throws {
        let id = try await h.document("# Wasser\n\nText")
        #expect(h.app.document(UUID(uuidString: id)!)?.hasCustomTitle == true)
        let result = try await h.call("writer.doc.autoTitle", ["doc": .string(id)])
        #expect(result["title"] == "Wasser")
        #expect(h.app.document(UUID(uuidString: id)!)?.hasCustomTitle == false)
    }
}
}
