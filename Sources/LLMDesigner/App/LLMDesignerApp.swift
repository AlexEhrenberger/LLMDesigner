import SwiftUI

@main
struct LLMDesignerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The open library and its model; everything below follows when another library is opened.
    @State private var session = LibrarySession()

    var body: some Scene {
        Window("LLM Designer", id: "main") {
            // The minimum size comes from RootView: conversation mode makes the window narrow.
            RootView()
                .environment(session.app)
                .environment(session)
                // A new library gets fresh views, so no view state of the old one stays.
                .id(ObjectIdentifier(session.app))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 820)
        .commands {
            AppCommands(app: session.app)
            LibraryCommands(session: session)
        }

        // A chat of its own in a narrow window, beside the main window (see `MiniChat`).
        Window("Mini-Chat", id: MiniChatWindow.id) {
            MiniChatView()
                .environment(session.app)
                .environment(session)
                .id(ObjectIdentifier(session.app))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Theme.powerWidth, height: 640)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(session.app)
                .environment(session)
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

    /// A library double-clicked in the Finder (or dropped on the app icon) opens in place of the current one.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == AppLibrary.fileExtension || AppLibrary.isLibrary($0) }) else { return }
        Task { @MainActor in await LibrarySession.shared?.open(url) }
    }

    /// Coming back to the app: if the open library was moved or renamed in the Finder, it is followed.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in LibrarySession.shared?.checkLibraryLocation() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The narrow conversation window must not become the size the app opens with next time.
        MainWindow.restoreBeforeQuit()
    }
}

/// File menu: libraries.
struct LibraryCommands: Commands {
    let session: LibrarySession

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Neue Bibliothek …") { session.createLibrary() }
            Button("Bibliothek öffnen …") { session.chooseLibrary() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Zuletzt geöffnete Bibliotheken") {
                ForEach(session.recent) { entry in
                    Button(entry.name + (session.library.isAt(entry.url) ? " ✓" : "")) {
                        Task { await session.open(entry.url) }
                    }
                    .disabled(!entry.isAvailable || session.library.isAt(entry.url))
                }
            }
            Button("Bibliothek im Finder zeigen") { session.revealInFinder() }
        }
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
            Button("Neue Präsentation") { app.newPresentation() }
                .keyboardShortcut("p", modifiers: [.command, .control])
            Button("Präsentation aus Dokument …") { app.showDeckFromDocument() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Neuer Skill") { app.createSkill() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Neue Persona") { app.createPersona() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Neuer Ordner") { app.createFolder(for: app.sidebarMode) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.sidebarMode == .personas)
        }
        CommandGroup(after: .textEditing) {
            Menu("Suchen") {
                Button("Suchen …") { app.findInDocument(.show) }
                    .keyboardShortcut("f")
                Button("Weitersuchen") { app.findInDocument(.next) }
                    .keyboardShortcut("g")
                Button("Rückwärts suchen") { app.findInDocument(.previous) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(!app.canFindInDocument)
        }
        CommandGroup(replacing: .printItem) {
            Button("Drucken …") { app.printOpenDocument() }
                .keyboardShortcut("p")
                .disabled(app.selectedDocument == nil || app.exportingIDs.contains(app.selectedDocumentID ?? UUID()))
        }
        CommandGroup(before: .toolbar) {
            Button(app.isSidebarShown ? "Seitenleiste ausblenden" : "Seitenleiste einblenden") { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Chats") { app.showChats() }
                .keyboardShortcut("1")
            Button("Skills") { app.showSkills() }
                .keyboardShortcut("2")
            Button("Personas") { app.showPersonas() }
                .keyboardShortcut("3")
            Divider()
        }
        CommandMenu("Format") {
            Group {
                Button("Schrift größer") { app.formatText { $0.changeFontSize(by: 1) } }
                    .keyboardShortcut("+")
                Button("Schrift kleiner") { app.formatText { $0.changeFontSize(by: -1) } }
                    .keyboardShortcut("-")
                Button("Standardgröße") { app.formatText { $0.setFontSize(nil) } }
                Divider()
                Button("Durchgestrichen") { app.formatText { $0.toggle(.strikethrough) } }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Hochgestellt") { app.formatText { $0.toggle(.superscript) } }
                    .keyboardShortcut("+", modifiers: [.command, .control])
                Button("Tiefgestellt") { app.formatText { $0.toggle(.subscript) } }
                    .keyboardShortcut("-", modifiers: [.command, .control])
                Divider()
                ForEach(WriterAlignment.allCases, id: \.self) { alignment in
                    Button(alignment.label) { app.formatText { $0.setAlignment(alignment) } }
                }
                Menu("Zeilenabstand") {
                    ForEach(WriterParagraphFormat.lineSpacingSteps, id: \.value) { step in
                        Button(step.label) { app.formatText { $0.setLineSpacing(step.value) } }
                    }
                }
                Button("Einzug vergrößern") { app.formatText { $0.changeIndent(by: 1) } }
                    .keyboardShortcut("]")
                Button("Einzug verkleinern") { app.formatText { $0.changeIndent(by: -1) } }
                    .keyboardShortcut("[")
                Button("Absatzformat zurücksetzen") { app.formatText { $0.clearParagraphFormat() } }
                Divider()
                Button("Seitenumbruch") { app.formatText { $0.insertPageBreak() } }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .disabled(!app.canFormatText)
            Divider()
            Group {
                Picker("Seitenformat", selection: Binding(
                    get: { app.selectedDocument?.pageFormat ?? .standard },
                    set: { format in
                        guard let document = app.selectedDocument else { return }
                        if format == .custom { app.setPageSetup(document.id, document.pageSetup ?? WriterPageSetup()) } else { app.setPageFormat(document.id, format) }
                    }
                )) {
                    ForEach(WriterPageFormat.allCases) { format in
                        Text(format == .standard ? app.pdfPaperSize.label : format == .custom ? (app.selectedDocument?.pageSetup?.name ?? format.label) : format.label)
                            .tag(format)
                    }
                }
                Button("Seite einrichten …") { app.writerPageSheet = .pageSetup }
                Button("Kopf- und Fußzeile …") { app.writerPageSheet = .runningHeads }
            }
            .disabled(app.selectedDocument == nil || app.selectedDocument?.isPresentation == true)
        }
        CommandMenu("Einfügen") {
            Group {
                Button("Kommentar") { app.formatText { $0.addComment() } }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Menu("Kasten") {
                    ForEach(WriterBoxKind.allCases) { kind in
                        Button(kind.label) { app.formatText { $0.insertBox(kind) } }
                    }
                }
                Button("Zwei Spalten") { app.formatText { $0.setColumns(WriterColumnStyle()) } }
                Button("Spaltenumbruch") { app.formatText { $0.insertColumnBreak() } }
                Divider()
                Button("Diagramm aus Zahlen …") { app.formatText { $0.newFigure(.chart) } }
                Button("Diagramm aus der Tabelle …") { app.formatText { $0.chartFromTable() } }
                Button("Mermaid-Diagramm …") { app.formatText { $0.newFigure(.mermaid) } }
                Button("Zeichnung …") { app.formatText { $0.newFigure(.drawing) } }
            }
            .disabled(!app.canFormatText || app.selectedDocument?.isPresentation == true)
        }
        // Stop, regenerate, dictation, pictures and thinking act on the mini chat while its window is in front.
        CommandMenu("Chat") {
            Button("Generierung stoppen") { app.commandChatID.map(app.stopGeneration(in:)) }
                .keyboardShortcut(".")
                .disabled(!(app.commandChatID.map(app.isGenerating) ?? false))
            Button("Antwort neu generieren") { if let id = app.commandChatID { app.regenerate(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.commandChatID.map { app.isGenerating($0) || app.chat($0) == nil } ?? true)
            Button(app.isDictating ? "Diktat beenden" : "Diktieren") { app.toggleDictation(intoMiniChat: app.miniChat.isKey) }
                .keyboardShortcut("d")
                .disabled(!app.isDictationAvailable || app.conversation != nil)
            Button(app.conversation == nil ? "Gesprächsmodus" : "Gesprächsmodus beenden") { app.toggleConversation() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.conversation == nil && !app.canStartConversation)
            Button("Bilder anhängen …") { app.chooseImages(forMiniChat: app.miniChat.isKey) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button((app.miniChat.isKey ? app.isMiniChatThinkingOn : app.isThinkingOn) ? "Denkmodus ausschalten" : "Denkmodus einschalten") {
                if app.miniChat.isKey { app.toggleMiniChatThinking() } else { app.toggleThinking() }
            }
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
            Button(app.isPanelShown ? "Inhaltsverzeichnis ausblenden" : "Inhaltsverzeichnis einblenden") { app.toggleOutlinePanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(app.power.isOn ? "Power-Zugriff ausschalten" : "Power-Zugriff einschalten") { app.togglePower() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            MiniChatCommands(app: app)
            Divider()
            Button("Modelle aktualisieren") { Task { await app.refreshModels() } }
                .keyboardShortcut("r")
        }
    }
}

/// Chat menu: the mini chat. A view, so it can open the window.
private struct MiniChatCommands: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The chat the main window shows goes into the mini chat; otherwise the mini chat keeps its own.
        Button("Im Mini-Chat öffnen") {
            OpenInMiniChat(app: app, openWindow: openWindow)(app.mainWindowChatID ?? app.miniChat.chatID)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Bildschirm betrachten") { app.glanceAtScreen() }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!app.miniChat.isOpen || app.miniChat.isGlancing)
    }
}
