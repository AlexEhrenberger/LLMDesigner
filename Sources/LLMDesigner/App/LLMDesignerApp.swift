import SwiftUI

@main
struct LLMDesignerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("LLM Designer", id: "main") {
            // The minimum size comes from RootView: conversation mode makes the window narrow.
            RootView()
                .environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 820)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // LLM Designer is always dark, regardless of the system appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The narrow conversation window must not become the size the app opens with next time.
        MainWindow.restoreBeforeQuit()
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neuer Chat") { app.newChat() }
                .keyboardShortcut("n")
            Button("Neues Dokument") { app.newDocument() }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Button("Neuer Skill") { app.createSkill() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Neue Persona") { app.createPersona() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Neuer Ordner") { app.createFolder(for: app.sidebarMode) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.sidebarMode == .personas)
        }
        CommandGroup(before: .toolbar) {
            Button(app.sidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden") { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Chats") { app.showChats() }
                .keyboardShortcut("1")
            Button("Skills") { app.showSkills() }
                .keyboardShortcut("2")
            Button("Personas") { app.showPersonas() }
                .keyboardShortcut("3")
            Divider()
        }
        CommandMenu("Chat") {
            Button("Generierung stoppen") { app.stop() }
                .keyboardShortcut(".")
                .disabled(!app.isGenerating)
            Button("Antwort neu generieren") { app.regenerate() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.isGenerating || app.selectedChat == nil)
            Button(app.isDictating ? "Diktat beenden" : "Diktieren") { app.toggleDictation() }
                .keyboardShortcut("d")
                .disabled(!app.isDictationAvailable || app.conversation != nil)
            Button(app.conversation == nil ? "Gesprächsmodus" : "Gesprächsmodus beenden") { app.toggleConversation() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.conversation == nil && !app.canStartConversation)
            Button("Bilder anhängen …") { app.chooseImages() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(app.isThinkingOn ? "Denkmodus ausschalten" : "Denkmodus einschalten") { app.toggleThinking() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Persona wählen …") {
                app.showChats()
                app.isPersonaPickerShown = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Skills wählen …") {
                app.showChats()
                app.isSkillPickerShown = true
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(app.activePersona != nil)
            Divider()
            Button("Chat exportieren …") { app.exportChat(withOutline: false) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.selectedChat == nil || app.isGenerating)
            Button("Chat mit Inhaltsverzeichnis exportieren …") { app.exportChat(withOutline: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                .disabled(app.selectedChat == nil || app.isGenerating)
            Button(app.outlinePanelVisible ? "Inhaltsverzeichnis ausblenden" : "Inhaltsverzeichnis einblenden") { app.toggleOutlinePanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Modelle aktualisieren") { Task { await app.refreshModels() } }
                .keyboardShortcut("r")
        }
    }
}
