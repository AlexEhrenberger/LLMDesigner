import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Chat: Verwaltung, Einstellungen, Skills, Personas, Gedächtnis, Geräte", .serialized)
struct ChatMoreActionTests {
    let h = ActionHarness()

    private func chat(_ extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["title": .string("Chat \(UUID().uuidString)")]
        args.merge(extra) { $1 }
        return try #require(try await h.call("chat.create", .object(args))["id"]?.stringValue)
    }

    private func value(_ id: String) -> Chat { h.app.chat(UUID(uuidString: id)!)! }

    /// A chat with a question and an answer, without a model.
    private func talked() async throws -> String {
        let id = try await chat()
        h.app.updateChat(UUID(uuidString: id)!) { chat in
            chat.messages = [
                ChatMessage(role: .user, content: "Wie heißt der Fluss?"),
                ChatMessage(role: .assistant, content: "Der **Rhein**.", model: "fake"),
            ]
            chat.messages[1].followUps = ["Wie lang ist er?"]
        }
        return id
    }

    private func withServer(_ script: [FakeLLMServer.Turn] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer(script: script)
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    private func pictureFile() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    // MARK: Managing

    @Test func openRenameMove() async throws {
        let id = try await talked()
        try await h.call("chat.open", ["chat": .string(id)])
        #expect(h.app.selectedChatID?.uuidString == id)
        try await h.call("chat.rename", ["chat": .string(id), "title": "Der Rhein"])
        #expect(value(id).title == "Der Rhein")
        try await h.call("writer.edit.undo")
        #expect(value(id).title != "Der Rhein")
        #expect(await h.errorCode("chat.rename", ["chat": .string(id), "title": " "]) == RPCError.invalidParamsCode)

        try await h.call("chat.rename", ["chat": .string(id), "title": "Anders"])
        h.app.updateChat(UUID(uuidString: id)!) { $0.outline = ChatOutline(title: "Vom Fluss", summary: "", sections: [], lastMessageID: nil, generatedAt: Date(), model: nil) }
        let title = try await h.call("chat.autoTitle", ["chat": .string(id)])
        #expect(title["title"] == "Vom Fluss")
        #expect(value(id).hasCustomTitle == false)

        let folderName = "Ordner \(UUID().uuidString)"
        try await h.call("folder.create", ["section": "chats", "name": .string(folderName)])
        try await h.call("chat.move", ["chat": .string(id), "folder": .string(folderName)])
        #expect(value(id).folderID != nil)
        try await h.call("chat.move", ["chat": .string(id)])
        #expect(value(id).folderID == nil)
        #expect(await h.errorCode("chat.move", ["chat": .string(id), "folder": "Gibt es nicht"]) == RPCError.notFoundCode)
    }

    @Test func branches() async throws {
        let id = try await talked()
        let first = value(id).messages[0].id.uuidString
        let branch = try #require(try await h.call("chat.branch", ["chat": .string(id), "message": .string(first)])["id"]?.stringValue)
        #expect(value(branch).messages.count == 1)
        let source = try await h.call("chat.branch.source", ["chat": .string(branch)])
        #expect(source["chat"] == .string(id))
        #expect(source["message"] == .string(first))
        #expect((try await h.call("chat.branch.source", ["chat": .string(id)]))["chat"] == nil)
    }

    // MARK: Reading

    @Test func readingMessages() async throws {
        let id = try await talked()
        let last = try await h.call("chat.message.read", ["chat": .string(id)])
        #expect(last["message"]?["text"] == "Der **Rhein**.")
        #expect(last["followUps"] == ["Wie lang ist er?"])
        let relative = try await h.call("chat.message.read", ["chat": .string(id), "message": "-2"])
        #expect(relative["message"]?["role"] == "user")
        #expect(await h.errorCode("chat.message.read", ["chat": .string(id), "message": "-9"]) == RPCError.notFoundCode)

        #expect((try await h.call("chat.message.copy", ["chat": .string(id), "format": "plain"]))["text"] == "Der Rhein.")
        #expect((try await h.call("chat.message.copy", ["chat": .string(id), "message": "last"]))["text"] == "Der **Rhein**.")
        #expect((try await h.call("chat.followUps.get", ["chat": .string(id)]))["followUps"] == ["Wie lang ist er?"])
        #expect((try await h.call("chat.outline.get", ["chat": .string(id)]))["sections"] == [])
        #expect((try await h.call("chat.sources.get", ["chat": .string(id)]))["sources"] == [])
    }

    @Test func sourcesAreListedOnce() async throws {
        let id = try await talked()
        h.app.updateChat(UUID(uuidString: id)!) { chat in
            var step = ToolStep(kind: .search, argument: "Rhein")
            step.sources = [WebSource(title: "Fluss", url: "https://example.org/a")]
            chat.messages[1].toolSteps = [step, step]
        }
        let sources = try await h.call("chat.sources.get", ["chat": .string(id)], run: "quellen")
        #expect(sources["sources"]?.arrayValue?.count == 1)
        #expect(h.registry.runState(id: "quellen", channel: .cli).hasReadUntrusted)
    }

    @Test func stateAndUsage() async throws {
        let id = try await talked()
        let state = try await h.call("chat.state.get", ["chat": .string(id)])
        #expect(state["locked"] == true)
        #expect(state["generating"] == false)
        #expect((state["usedTokens"]?.intValue ?? 0) > 0)
        let usage = try await h.call("chat.context.usage", ["chat": .string(id)])
        #expect((usage["used"]?.intValue ?? 0) > 0)
        #expect(usage["parts"]?.arrayValue?.isEmpty == false)
    }

    // MARK: Messages

    /// The prefix cache is measured per answer: what the server reports for the first request lands in the stats.
    @Test func cachedPromptTokens() async throws {
        try await withServer([.text("Neu.")]) { server in
            server.usage = ["prompt_tokens": 900, "completion_tokens": 2, "prompt_tokens_details": ["cached_tokens": 850]]
            let id = try await talked()
            h.app.updateChat(UUID(uuidString: id)!) {
                $0.modelId = "fake"
                $0.contextLength = 16384
            }
            try await h.call("chat.regenerate", ["chat": .string(id)])
            _ = try await h.call("chat.wait", ["chat": .string(id)])
            let stats = try #require(value(id).messages.last?.stats)
            #expect(stats.promptTokens == 900)
            #expect(stats.cachedPromptTokens == 850)
            #expect(stats.cacheSummary(singleRequest: true) == "Prompt 900 Tokens, davon 850 aus dem Cache")
            #expect(stats.cacheSummary(singleRequest: false) == "850 Prompt-Tokens aus dem Cache")
        }
        #expect(GenerationStats(promptTokens: 900).cacheSummary(singleRequest: true) == nil)
    }

    /// What belongs to one turn goes with the newest question, so the system prompt stays the same for the cache.
    @Test func turnNotesGoWithTheQuestion() async throws {
        try await withServer([.text("Kurz gesagt: ja.")]) { server in
            let id = try await talked()
            let chatID = UUID(uuidString: id)!
            h.app.updateChat(chatID) {
                $0.modelId = "fake"
                $0.contextLength = 16384
                $0.messages.append(ChatMessage(role: .user, content: "Fließt er in die Nordsee?"))
            }
            h.app.generate(in: chatID, spoken: true)
            _ = try await h.call("chat.wait", ["chat": .string(id)])
            let messages = try #require(server.requests.last?["messages"]?.arrayValue)
            let system = messages.first { $0["role"] == "system" }?["content"]?.stringValue ?? ""
            #expect(!system.contains("gesprochenes Gespräch"))
            let newest = try #require(messages.last?["content"]?.stringValue)
            #expect(newest.hasPrefix(ChatPayloadBuilder.noteStart) && newest.contains("gesprochenes Gespräch"))
            #expect(newest.hasSuffix("Fließt er in die Nordsee?"))
            #expect(messages.first { $0["role"] == "user" }?["content"] == "Wie heißt der Fluss?")
            // Nothing of it is stored.
            #expect(value(id).messages.first { $0.content.contains(ChatPayloadBuilder.noteStart) } == nil)
        }
    }

    @Test func regenerateEditFollowUp() async throws {
        try await withServer([.text("Neu."), .text("Anders."), .text("Lang.")]) { _ in
            let id = try await talked()
            h.app.updateChat(UUID(uuidString: id)!) {
                $0.modelId = "fake"
                $0.contextLength = 16384
            }
            try await h.call("chat.regenerate", ["chat": .string(id)])
            let first = try await h.call("chat.wait", ["chat": .string(id)])
            #expect(first["text"] == "Neu.")

            let question = value(id).messages[0].id.uuidString
            let made = try await h.call("chat.edit", ["chat": .string(id), "message": .string(question), "text": "Wie heißt der See?"])
            let branch = try #require(made["id"]?.stringValue)
            #expect((try await h.call("chat.wait", ["chat": .string(branch)]))["text"] == "Anders.")
            #expect(value(branch).messages[0].content == "Wie heißt der See?")
            #expect(value(id).messages[0].content == "Wie heißt der Fluss?")
            #expect(await h.errorCode("chat.edit", ["chat": .string(id), "message": "last", "text": "x"]) == RPCError.invalidTargetCode)

            try await h.call("chat.followUps.send", ["chat": .string(id), "text": "Und weiter?"])
            #expect((try await h.call("chat.wait", ["chat": .string(id)]))["text"] == "Lang.")
            #expect(await h.errorCode("chat.followUps.send", ["chat": .string(id)]) == RPCError.invalidParamsCode)
            #expect(await h.errorCode("chat.followUps.send", ["chat": .string(id), "index": 9]) == RPCError.notFoundCode)
        }
    }

    @Test func aChatCanNotTurnItselfUp() async throws {
        let id = try await talked()
        #expect(await h.errorCode("chat.regenerate", ["chat": .string(id)], channel: .chat, run: id) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.webSearch.set", ["chat": .string(id), "value": true], channel: .chat, run: id) == RPCError.deniedCode)
        #expect(value(id).webSearch == nil)
        let empty = try await chat()
        #expect(await h.errorCode("chat.memory.set", ["chat": .string(empty), "value": false], channel: .chat, run: empty) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.memory.set", ["chat": .string(empty), "value": false], channel: .mcp) == RPCError.deniedCode)
    }

    @Test func drafts() async throws {
        let id = try await chat()
        try await h.call("chat.draft.set", ["chat": .string(id), "text": "Noch nicht senden"])
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["text"] == "Noch nicht senden")
        #expect(value(id).messages.isEmpty)
        try await h.call("writer.edit.undo")
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["text"] == "")
    }

    // MARK: Settings

    @Test func switchesAndFixedSettings() async throws {
        let id = try await chat()
        try await h.call("chat.thinking.set", ["chat": .string(id), "value": true])
        try await h.call("chat.webSearch.set", ["chat": .string(id), "value": true])
        try await h.call("chat.wikipedia.set", ["chat": .string(id), "value": true])
        #expect(value(id).thinking == true)
        #expect(value(id).webSearch == true)
        #expect(value(id).wikipediaSearch == true)
        try await h.call("chat.webSearch.set", ["chat": .string(id), "value": false])
        #expect(value(id).webSearch == nil)

        try await h.call("chat.contextLength.set", ["chat": .string(id), "contextLength": 16384])
        #expect(value(id).contextLength == 16384)
        #expect(await h.errorCode("chat.contextLength.set", ["chat": .string(id), "contextLength": 9000]) == RPCError.invalidParamsCode)

        let persona = try #require(try await h.call("persona.create", ["name": .string("Lotta \(UUID().uuidString)")])["id"]?.stringValue)
        #expect(await h.errorCode("chat.memory.set", ["chat": .string(id), "value": true]) == RPCError.invalidTargetCode)
        try await h.call("chat.persona.set", ["chat": .string(id), "persona": .string(persona)])
        #expect(value(id).personaID?.uuidString == persona)
        try await h.call("chat.memory.set", ["chat": .string(id), "value": true])
        #expect(value(id).memory == .on)
        #expect(await h.errorCode("chat.skills.set", ["chat": .string(id), "add": []]) == RPCError.invalidTargetCode)
        try await h.call("chat.persona.set", ["chat": .string(id)])
        #expect(value(id).personaID == nil)
        #expect(value(id).memory == nil)

        let skill = try #require(try await h.call("skill.create", ["name": .string("Kurz \(UUID().uuidString)"), "instructions": "Antworte kurz."])["id"]?.stringValue)
        try await h.call("chat.skills.set", ["chat": .string(id), "add": .array([.string(skill)])])
        #expect(value(id).skillIDs?.count == 1)
        try await h.call("chat.skills.set", ["chat": .string(id), "remove": .array([.string(skill)])])
        #expect(value(id).skillIDs == nil)

        // After the first message these are fixed, and the action says so.
        let started = try await talked()
        #expect(await h.errorCode("chat.contextLength.set", ["chat": .string(started), "contextLength": 8192]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("chat.persona.set", ["chat": .string(started), "persona": .string(persona)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("chat.skills.set", ["chat": .string(started)]) == RPCError.invalidTargetCode)
    }

    @Test func modelOfAChat() async throws {
        try await withServer { _ in
            let id = try await chat()
            try await h.call("chat.model.set", ["chat": .string(id), "model": "fake"])
            #expect(value(id).modelId == "fake")
            #expect(await h.errorCode("chat.model.set", ["chat": .string(id), "model": "fehlt"]) == RPCError.notFoundCode)
            let refreshed = try await h.call("models.refresh")
            #expect(refreshed["models"] == 1)
            #expect(await h.errorCode("models.load", ["model": "fehlt", "contextLength": 8192]) == RPCError.notFoundCode)
            // The fake server knows no instances to compare; a real answer or the plain message both do.
            let code = await h.errorCode("models.load", ["model": "fake", "contextLength": 16384])
            #expect(code == nil || code == RPCError.unavailableCode)
        }
    }

    // MARK: Bookmarks

    @Test func bookmarks() async throws {
        let id = try await talked()
        let made = try await h.call("chat.bookmark.add", ["chat": .string(id), "selectedText": "Rhein"])
        let bookmark = try #require(made["id"]?.stringValue)
        var list = try await h.call("chat.bookmark.list", ["chat": .string(id)])
        #expect(list["bookmarks"]?.arrayValue?.first?["excerpt"] == "Rhein")
        try await h.call("chat.bookmark.rename", ["chat": .string(id), "bookmark": .string(bookmark), "title": "Der Fluss"])
        list = try await h.call("chat.bookmark.list", ["chat": .string(id)])
        #expect(list["bookmarks"]?.arrayValue?.first?["title"] == "Der Fluss")

        try await h.call("chat.jump", ["chat": .string(id), "bookmark": .string(bookmark)])
        #expect(h.app.selectedChatID?.uuidString == id)
        #expect(h.app.highlightedTarget != nil)
        try await h.call("chat.jump", ["chat": .string(id), "message": "-2"])
        #expect(await h.errorCode("chat.jump", ["chat": .string(id), "bookmark": "fehlt"]) == RPCError.notFoundCode)

        try await h.call("chat.bookmark.delete", ["chat": .string(id), "bookmark": .string(bookmark)])
        #expect((try await h.call("chat.bookmark.list", ["chat": .string(id)]))["bookmarks"] == [])
        #expect(await h.errorCode("chat.bookmark.delete", ["chat": .string(id), "bookmark": .string(bookmark)]) == RPCError.notFoundCode)
    }

    // MARK: Export

    @Test func exports() async throws {
        let id = try await talked()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("chat.md")
        try await h.call("chat.export.markdown", ["chat": .string(id), "path": .string(target.path)])
        #expect(try String(contentsOf: target, encoding: .utf8).contains("Rhein"))
        #expect(await h.errorCode("chat.export.markdown", ["chat": .string(id), "path": .string(target.path)]) == RPCError.invalidTargetCode)

        let pdf = folder.appendingPathComponent("chat.pdf"), answer = folder.appendingPathComponent("antwort.pdf")
        if LaTeXEngine.locate() != nil {
            try await h.call("chat.export.pdf", ["chat": .string(id), "path": .string(pdf.path)])
            #expect(FileManager.default.fileExists(atPath: pdf.path))
            try await h.call("chat.export.answer", ["chat": .string(id), "path": .string(answer.path)])
            #expect(FileManager.default.fileExists(atPath: answer.path))
        } else {
            #expect(await h.errorCode("chat.export.pdf", ["chat": .string(id), "path": .string(pdf.path)]) == RPCError.unavailableCode)
            #expect(await h.errorCode("chat.export.answer", ["chat": .string(id), "path": .string(answer.path)]) == RPCError.unavailableCode)
        }
    }

    @Test func aChatBecomesADocument() async throws {
        let id = try await talked()
        let made = try await h.call("chat.toDocument", ["chat": .string(id), "title": "Vom Rhein"])
        let doc = try #require(made["id"]?.stringValue)
        #expect(h.text(doc).contains("Wie heißt der Fluss?"))
        #expect(h.text(doc).contains("Rhein"))
        let part = try await h.call("chat.toDocument", ["chat": .string(id), "messages": ["last"]])
        let only = try #require(part["id"]?.stringValue)
        #expect(!h.text(only).contains("Wie heißt"))

        // What a chat found on the web stays foreign in the document.
        h.app.updateChat(UUID(uuidString: id)!) { $0.webSearch = true }
        let foreign = try await h.call("chat.toDocument", ["chat": .string(id)])
        let foreignID = try #require(foreign["id"]?.stringValue)
        #expect(h.app.document(UUID(uuidString: foreignID)!)?.provenance == .foreign)
    }

    // MARK: Folders

    @Test func folders() async throws {
        let name = "Mappe \(UUID().uuidString)"
        let made = try await h.call("folder.create", ["section": "chats", "name": .string(name), "color": "blue"])
        let id = try #require(made["id"]?.stringValue)
        var folder = try #require(h.app.chatFolders.first { $0.id.uuidString == id })
        #expect(folder.name == name)
        #expect(folder.color == .blue)
        #expect(h.app.renamingID == nil)
        try await h.call("folder.rename", ["folder": .string(id), "name": .string(name + "2")])
        try await h.call("folder.color", ["folder": .string(id), "color": "none"])
        try await h.call("folder.collapse", ["folder": .string(id), "collapsed": true])
        folder = try #require(h.app.chatFolders.first { $0.id.uuidString == id })
        #expect(folder.name == name + "2")
        #expect(folder.color == nil)
        #expect(folder.isCollapsed == true)
        try await h.call("folder.collapse", ["folder": .string(id), "collapsed": true])
        #expect(h.app.chatFolders.first { $0.id.uuidString == id }?.isCollapsed == true)

        let inside = try await chat()
        try await h.call("chat.move", ["chat": .string(inside), "folder": .string(id)])
        try await h.call("folder.delete", ["folder": .string(id)])
        #expect(!h.app.chatFolders.contains { $0.id.uuidString == id })
        #expect(value(inside).folderID == nil)

        let skills = try await h.call("folder.create", ["section": "skills", "name": .string("Fach \(UUID().uuidString)")])
        #expect(h.app.skillFolders.contains { $0.id.uuidString == skills["id"]?.stringValue })
    }

    // MARK: Skills

    @Test func skillsThereAndBack() async throws {
        let name = "Lektor \(UUID().uuidString)"
        let id = try #require(try await h.call("skill.create", ["name": .string(name), "instructions": "Prüfe genau."])["id"]?.stringValue)
        try await h.call("skill.update", ["skill": .string(id), "summary": "Liest Korrektur", "instructions": "Prüfe sehr genau."])
        #expect(h.app.skill(UUID(uuidString: id)!)?.instructions == "Prüfe sehr genau.")
        let copy = try await h.call("skill.duplicate", ["skill": .string(id)])
        let copyID = UUID(uuidString: try #require(copy["id"]?.stringValue))!
        #expect(h.app.skill(copyID)?.instructions == "Prüfe sehr genau.")

        let folderName = "Skills \(UUID().uuidString)"
        try await h.call("folder.create", ["section": "skills", "name": .string(folderName)])
        try await h.call("skill.move", ["skill": .string(id), "folder": .string(folderName)])
        #expect(h.app.skill(UUID(uuidString: id)!)?.folderID != nil)
        #expect(await h.errorCode("skill.move", ["skill": .string(id), "folder": "Fehlt"]) == RPCError.notFoundCode)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkillExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("lektor.md")
        try await h.call("skill.export", ["skill": .string(id), "path": .string(file.path)])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: \(name)\nsummary: Liest Korrektur\n---\n"))

        let imported = try await h.call("skill.import", ["file": .string(file.path)], run: "skill-lauf")
        let importedID = UUID(uuidString: try #require(imported["id"]?.stringValue))!
        let made = try #require(h.app.skill(importedID))
        #expect(made.name == name)
        #expect(made.instructions == "Prüfe sehr genau.")
        // Nobody here wrote it.
        #expect(made.provenance == .foreign)
        #expect(h.registry.runState(id: "skill-lauf", channel: .cli).hasReadUntrusted)
        #expect(await h.errorCode("skill.import", ["file": "/gibt/es/nicht.md"]) == RPCError.notFoundCode)

        try await h.call("skill.delete", ["skill": .string(made.id.uuidString)])
        #expect(h.app.skill(made.id) == nil)
    }

    @Test func aSkillWithoutAHeadIsNamedAfterItsFile() {
        let skill = SkillFile.skill(from: "Antworte kurz.", fallbackName: "kurz")
        #expect(skill.name == "kurz")
        #expect(skill.instructions == "Antworte kurz.")
    }

    // MARK: Personas

    @Test func personas() async throws {
        let picture = try pictureFile()
        defer { try? FileManager.default.removeItem(at: picture) }
        let name = "Lotta \(UUID().uuidString)"
        let id = try #require(try await h.call("persona.create", ["name": .string(name), "biography": "Lebt am Meer", "behavior": "Knapp"])["id"]?.stringValue)
        var read = try await h.call("persona.read", ["persona": .string(id)])
        #expect(read["biography"] == "Lebt am Meer")
        #expect(read["files"] == [])
        try await h.call("persona.update", ["persona": .string(id), "biography": "Lebt am See", "voice": "anna"])
        read = try await h.call("persona.read", ["persona": .string(id)])
        #expect(read["biography"] == "Lebt am See")
        #expect(read["voice"] == "anna")
        try await h.call("writer.edit.undo")
        #expect((try await h.call("persona.read", ["persona": .string(id)]))["biography"] == "Lebt am Meer")

        try await h.call("persona.avatar.set", ["persona": .string(id), "file": .string(picture.path)])
        #expect(h.app.persona(UUID(uuidString: id)!)?.avatarFileName != nil)
        try await h.call("persona.avatar.remove", ["persona": .string(id)])
        #expect(h.app.persona(UUID(uuidString: id)!)?.avatarFileName == nil)
        #expect(await h.errorCode("persona.avatar.set", ["persona": .string(id), "file": "/gibt/es/nicht.png"]) == RPCError.notFoundCode)

        let note = FileManager.default.temporaryDirectory.appendingPathComponent("Notiz-\(UUID().uuidString).txt")
        try "Ein neutraler Text.".write(to: note, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: note) }
        let added = try await h.call("persona.files.add", ["persona": .string(id), "files": .array([.string(note.path)])])
        let fileName = try #require(added["added"]?.arrayValue?.first?.stringValue)
        #expect((try await h.call("persona.read", ["persona": .string(id)]))["files"]?.arrayValue?.count == 1)
        // The private files stay inside: an MCP client neither adds nor removes any.
        #expect(await h.errorCode("persona.files.add", ["persona": .string(id), "files": .array([.string(note.path)])], channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("persona.files.remove", ["persona": .string(id), "files": .array([.string(fileName)])], channel: .mcp) == RPCError.deniedCode)
        try await h.call("persona.files.remove", ["persona": .string(id), "files": .array([.string(fileName)])])
        #expect((try await h.call("persona.read", ["persona": .string(id)]))["files"] == [])
        #expect(await h.errorCode("persona.files.remove", ["persona": .string(id), "files": ["fehlt.txt"]]) == RPCError.notFoundCode)

        let started = try await h.call("persona.startChat", ["persona": .string(id), "title": "Mit Lotta"])
        let startedID = try #require(started["id"]?.stringValue)
        #expect(value(startedID).personaID?.uuidString == id)

        try await h.call("persona.delete", ["persona": .string(id)])
        #expect(h.app.persona(UUID(uuidString: id)!) == nil)
        #expect(await h.errorCode("persona.voice.preview", ["persona": .string(id)]) == RPCError.notFoundCode)
    }

    // MARK: Memory

    @Test func memory() async throws {
        let persona = try #require(try await h.call("persona.create", ["name": .string("Merk \(UUID().uuidString)")])["id"]?.stringValue)
        let uuid = UUID(uuidString: persona)!
        var library = ThalamusLibrary()
        library.memories = [ThalamusMemory(title: "Reise", category: "Ort", summary: "War am Meer", keywords: [], feelings: [], firstDate: Date(), lastDate: Date(), mentions: 1, chatIDs: [])]
        library.profile = [ThalamusFact(text: "Mag Tee", since: Date(), updatedAt: Date())]
        h.app.thalamus[uuid] = library

        let list = try await h.call("memory.list", ["persona": .string(persona)])
        let items = try #require(list["items"]?.arrayValue)
        #expect(items.count == 2)
        let memory = try #require(items.first { $0["kind"] == "memory" }?["id"]?.stringValue)
        try await h.call("memory.delete", ["persona": .string(persona), "item": .string(memory)])
        #expect(h.app.thalamus[uuid]?.memories?.isEmpty == true)
        #expect(await h.errorCode("memory.delete", ["persona": .string(persona), "item": .string(memory)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("memory.delete", ["persona": .string(persona), "item": "keine id"]) == RPCError.invalidParamsCode)

        try await h.call("memory.deleteAll", ["persona": .string(persona)])
        #expect(h.app.thalamus[uuid]?.profile?.isEmpty == true)

        #expect(await h.errorCode("memory.consolidate") == RPCError.invalidParamsCode)
        try await h.call("memory.consolidate", ["persona": .string(persona)])
        try await h.call("memory.consolidate", ["all": true])
        try await h.call("memory.consolidate.cancel")
        // Memory stays out of reach for MCP clients.
        #expect(await h.errorCode("memory.deleteAll", ["persona": .string(persona)], channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("memory.consolidate", ["persona": .string(persona)], channel: .mcp) == RPCError.deniedCode)
    }

    // MARK: Pictures in the composer

    @Test func pictures() async throws {
        let picture = try pictureFile()
        defer { try? FileManager.default.removeItem(at: picture) }
        let id = try await chat()
        let added = try await h.call("chat.image.attach", ["chat": .string(id), "files": .array([.string(picture.path)])])
        let image = try #require(added["images"]?.arrayValue?.first?.stringValue)
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["images"]?.arrayValue?.count == 1)
        try await h.call("chat.image.removeDraft", ["chat": .string(id), "image": .string(image)])
        #expect((try await h.call("chat.draft.get", ["chat": .string(id)]))["images"] == [])
        #expect(await h.errorCode("chat.image.removeDraft", ["chat": .string(id), "image": .string(image)]) == RPCError.notFoundCode)

        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("chat.image.attach", ["chat": .string(id), "files": .array([.string(picture.path)])], channel: .mcp) == RPCError.deniedCode)
    }

    @Test func generatedPictureNeedsDrawThings() async throws {
        let id = try await chat()
        #expect(await h.errorCode("chat.image.generate", ["chat": .string(id), "prompt": " "]) == RPCError.invalidParamsCode)
        let center = h.app.imageGeneration
        let address = center.address
        center.address = "http://127.0.0.1:9"
        defer { center.address = address }
        #expect(await h.errorCode("chat.image.generate", ["chat": .string(id), "prompt": "a lighthouse"]) == RPCError.unavailableCode)
        #expect((try await h.call("chat.image.cancel"))["cancelled"] == 0)
    }

    // MARK: Microphone, screen, speech, mini chat, view (nothing records, speaks or takes a picture during tests)

    @Test func devicesAlwaysAsk() async throws {
        let id = try await talked()
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("chat.conversation.start", ["chat": .string(id)]) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.dictation.start", ["chat": .string(id)]) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.screen.glance") == RPCError.deniedCode)
        try await h.call("chat.dictation.stop")
        try await h.call("chat.speak.stop")
        try await h.call("chat.conversation.stop")
    }

    @Test func theScreenNeedsTheMiniChat() async throws {
        h.app.miniChat.isOpen = false
        #expect(await h.errorCode("chat.screen.glance") == RPCError.invalidTargetCode)
    }

    @Test func speakingWithoutText() async throws {
        let id = try await chat()
        h.app.updateChat(UUID(uuidString: id)!) { $0.messages = [ChatMessage(role: .assistant, content: "")] }
        #expect(await h.errorCode("chat.speak", ["chat": .string(id)]) == RPCError.invalidTargetCode)
    }

    @Test func miniChatAndViews() async throws {
        let id = try await talked()
        let before = h.app.miniChatOpenRequest
        try await h.call("minichat.open", ["chat": .string(id)])
        #expect(h.app.miniChat.chatID?.uuidString == id)
        #expect(h.app.miniChatOpenRequest != before)
        try await h.call("minichat.pin", ["on": false])
        #expect(!h.app.miniChat.floats)
        try await h.call("minichat.pin", ["on": true])
        #expect(h.app.miniChat.floats)
        try await h.call("minichat.toMainWindow")
        #expect(h.app.selectedChatID?.uuidString == id)
        try await h.call("minichat.open")
        #expect(h.app.miniChat.chatID == nil)
        #expect(await h.errorCode("minichat.toMainWindow") == RPCError.invalidTargetCode)
        try await h.call("chat.open", ["chat": .string(id), "window": "mini"])
        #expect(h.app.miniChat.chatID?.uuidString == id)

        try await h.call("view.sidebar", ["show": false])
        #expect(!(h.app.sidebarCollapsed ? h.app.sidebarOverlay : h.app.sidebarVisible))
        try await h.call("view.sidebar", ["show": true])
        #expect(h.app.sidebarCollapsed ? h.app.sidebarOverlay : h.app.sidebarVisible)
        try await h.call("view.panel", ["panel": "bookmarks"])
        #expect(h.app.sidePanelTab == .bookmarks)
        #expect(h.app.isPanelShown)
        try await h.call("view.panel", ["show": false])
        #expect(!h.app.isPanelShown)
    }

    // MARK: Connection and library

    @Test func connection() async throws {
        let state = try await h.call("connection.get")
        #expect(state["provider"] == .string(h.app.provider.rawValue))
        #expect(state["apiKey"] == nil)

        h.registry.approval.presenter = { _ in false }
        let endpoint = h.app.endpoint
        #expect(await h.errorCode("connection.set", ["endpoint": "http://example.org"]) == RPCError.deniedCode)
        #expect(h.app.endpoint == endpoint)
        h.registry.approval.presenter = { _ in true }
        let key = "sk-testwert"
        let oldKey = h.app.apiKey
        defer {
            h.app.endpoint = endpoint
            h.app.apiKey = oldKey
        }
        let changed = try await h.call("connection.set", ["endpoint": "http://127.0.0.1:9", "apiKey": .string(key)])
        #expect(changed["endpoint"] == "http://127.0.0.1:9")
        #expect(changed["hasKey"] == true)
        #expect(!changed.jsonLine().contains(key))
    }

    @Test func libraries() async throws {
        let list = try await h.call("library.list")
        #expect(list["current"] == .string(AppLibrary.current.url.path))
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("library.open", ["path": .string(AppLibrary.current.url.path)]) == RPCError.deniedCode)
        #expect(await h.errorCode("library.create", ["name": "Neu"]) == RPCError.deniedCode)
        h.registry.approval.presenter = { _ in true }
        #expect(await h.errorCode("library.open", ["path": "/gibt/es/nicht"]) == RPCError.notFoundCode)
        // In a test there is no session around the model that could change libraries.
        #expect(await h.errorCode("library.open", ["path": .string(AppLibrary.current.url.path)]) == RPCError.unavailableCode)
        #expect(await h.errorCode("library.create", ["name": "Neu"]) == RPCError.unavailableCode)
    }
}
}
