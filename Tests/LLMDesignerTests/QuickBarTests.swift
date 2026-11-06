import AppKit
import LLMDProtocol
import Testing
@testable import LLMDesigner

extension ActionSuites {
/// The search bar: its chats may use everything, the registry's rules still hold, and its shortcut is kept.
@MainActor
@Suite("Suchleiste", .serialized)
struct QuickBarTests {
    let registry = ActionRegistry.standard()
    let app = TestApp.model()

    @Test func itsChatsMayUseEveryTool() {
        let chat = app.makeQuickBarChat(for: "Erstelle ein Dokument über Bienen", modelId: "fake")
        #expect(chat.actionGroups == ["writer.core"])
        #expect(chat.actionApproval == .allowAll)
        #expect(chat.webSearch == true)
        #expect(chat.wikipediaSearch == true)
        if app.provider.loadsModels {
            #expect((chat.contextLength ?? 0) >= AppModel.quickBarContextLength)
        }
    }

    @Test func onlyTheToolsARequestNeedsGoAlong() {
        #expect(QuickBarTools.groups(for: "Wie geht es dir?").isEmpty)
        #expect(QuickBarTools.groups(for: "Erstelle eine Präsentation über Bienen") == ["presenter.core"])
        #expect(QuickBarTools.groups(for: "Suche Zitate zu Bienen und füge sie ins Dokument ein") == ["writer.core", "citation.core"])
        #expect(QuickBarTools.groups(for: "Wer ist die Figur Erulin in meinem Roman?") == ["stories.core"])
        #expect(QuickBarTools.groups(for: "Lege eine Mindmap an") == ["writer.core"])
        for group in ChatToolGroups.labels.map(\.id) {
            #expect(QuickBarTools.groups(for: "\(group)").allSatisfy(ChatToolGroups.isKnown))
        }
    }

    @Test func aLaterQuestionAddsTools() {
        let chat = app.makeQuickBarChat(for: "Hallo \(UUID().uuidString)", modelId: "fake")
        #expect(chat.actionGroups == nil)
        app.addChatFromAction(chat)
        defer { app.deleteChat(chat.id) }
        app.widenQuickBarTools(chat.id, for: "Mach daraus eine Präsentation")
        app.widenQuickBarTools(chat.id, for: "Und noch ein Dokument dazu")
        app.widenQuickBarTools(chat.id, for: "Danke")
        #expect(app.chat(chat.id)?.actionGroups == ["presenter.core", "writer.core"])
    }

    @Test func creatingNeedsNoQuestionButPrivateDataStillAsks() async throws {
        var asked: [ApprovalRequest] = []
        registry.approval.presenter = { asked.append($0); return false }
        let chat = app.makeQuickBarChat(for: "Test \(UUID().uuidString)", modelId: "fake")
        app.addChatFromAction(chat)
        app.actionRegistryOverride = registry
        defer { app.actionRegistryOverride = nil }
        app.prepareActionRun(for: chat)

        let title = "Aus der Suchleiste \(UUID().uuidString)"
        let created = try await registry.run("writer.doc.create", args: ["title": .string(title), "markdown": "# Bienen\n"],
                                             app: app, channel: .chat, run: chat.id.uuidString)
        #expect(asked.isEmpty)
        let id = created["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        #expect(id.flatMap(app.document) != nil)

        let persona = Persona(name: "Suchleiste \(UUID().uuidString)", biography: "", behavior: "")
        app.personas.append(persona)
        await #expect(throws: RPCError.self) {
            try await registry.run("memory.list", args: ["persona": .string(persona.name)], app: app, channel: .chat, run: chat.id.uuidString)
        }
        #expect(asked.map(\.action) == ["memory.list"])
        app.personas.removeAll { $0.id == persona.id }
        if let id { app.deleteDocument(id) }
        app.deleteChat(chat.id)
    }

    @Test func afterAPauseItStartsANewChat() {
        let chat = app.makeQuickBarChat(for: "Pause \(UUID().uuidString)", modelId: "fake")
        app.addChatFromAction(chat)
        defer { app.deleteChat(chat.id) }
        app.quickBar.chatID = chat.id
        let used = Date()
        app.quickBar.lastUsed = used

        app.prepareQuickBar(now: used.addingTimeInterval(60))
        #expect(app.quickBar.chatID == chat.id)
        app.prepareQuickBar(now: used.addingTimeInterval(QuickBar.freshAfter + 1))
        #expect(app.quickBar.chatID == nil)
    }

    @Test func theShortcutIsKeptInTheLibrary() {
        let old = app.quickBar.shortcut
        defer { app.quickBar.shortcut = old }
        let shortcut = QuickBarShortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "K")
        app.quickBar.shortcut = shortcut
        #expect(QuickBar().shortcut == shortcut)
        #expect(shortcut.label == "⇧⌘ K")
        #expect(QuickBarShortcut.standard.label == "⌥ Leertaste")
    }

    @Test func aShortcutNeedsCommandOptionOrControl() {
        #expect(QuickBarShortcut.standard.isUsable)
        #expect(!QuickBarShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags.shift.rawValue, key: "Leertaste").isUsable)
        #expect(!QuickBarShortcut(keyCode: 0, modifiers: 0, key: "A").isUsable)
    }
}
}
