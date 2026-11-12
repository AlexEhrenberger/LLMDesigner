import AppKit
import Foundation

/// The key combination that shows the search bar from anywhere. Modifiers as AppKit flags, so the core needs no
/// Carbon; `GlobalHotKey` translates them.
struct QuickBarShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt
    /// How the key is written in the settings, e.g. "Leertaste" or "K".
    var key: String

    /// ⌥ Leertaste, as in many AI apps.
    static let standard = QuickBarShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue, key: "Leertaste")

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var label: String {
        let flags = modifierFlags
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols + " " + key
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃; with only ⇧ (or nothing) it would swallow ordinary typing in every app.
    var isUsable: Bool { !modifierFlags.intersection([.command, .option, .control]).isEmpty }

    /// The name of a pressed key for the settings.
    static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49: "Leertaste"
        case 36: "↩"
        case 48: "⇥"
        case 51: "⌫"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: (characters ?? "").uppercased().isEmpty ? "Taste \(keyCode)" : (characters ?? "").uppercased()
        }
    }
}

/// The search bar: a glowing field in front of all apps (default ⌥ Leertaste) to chat or to give the app a job,
/// e.g. "Erstelle eine Präsentation über …". Its chats may use every tool of the app; the rules of the registry still
/// hold (private data and runs that read foreign material ask).
@MainActor
@Observable
final class QuickBar {
    private static let shortcutKey = "quickBarShortcut"
    private static let enabledKey = "quickBarEnabled"
    /// After this long without use the bar starts with a new chat; before, it goes on with the last one.
    static let freshAfter: TimeInterval = 10 * 60

    var isShown = false
    /// The chat in the bar; nil until the first message.
    var chatID: Chat.ID?
    var draft = ""
    /// Changes when the field should take the focus (each time the bar opens).
    var focusToken = UUID()
    var lastUsed: Date?
    /// The running dictation writes into the bar's field.
    var receivesDictation = false

    var isEnabled: Bool {
        didSet {
            settings.set(isEnabled, forKey: Self.enabledKey)
            onShortcutChange?()
        }
    }

    var shortcut: QuickBarShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut), let text = String(data: data, encoding: .utf8) {
                settings.set(text, forKey: Self.shortcutKey)
            }
            onShortcutChange?()
        }
    }

    /// The active shortcut, nil while the bar is switched off.
    var activeShortcut: QuickBarShortcut? { isEnabled ? shortcut : nil }

    /// Set by the app (not in tests): registers the shortcut again when it changes.
    @ObservationIgnored var onShortcutChange: (() -> Void)?
    @ObservationIgnored private let settings = AppLibrary.current.settings

    init() {
        isEnabled = settings.object(forKey: Self.enabledKey) as? Bool ?? true
        shortcut = settings.string(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(QuickBarShortcut.self, from: Data($0.utf8)) } ?? .standard
    }
}

extension AppModel {
    /// The context a chat with all tools needs: their descriptions alone fill most of 8K.
    static let quickBarContextLength = 32_768

    var currentQuickBarChat: Chat? { quickBar.chatID.flatMap { chat($0) } }

    var quickBarModelId: String? { currentQuickBarChat.flatMap(modelId(for:)) ?? preferredModelId }
    var quickBarModel: LMModel? {
        guard let id = quickBarModelId else { return nil }
        return models.first { $0.id == id }
    }

    var isQuickBarGenerating: Bool { quickBar.chatID.map(isGenerating) ?? false }

    var canSendQuickBar: Bool {
        !quickBar.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quickBarModelId != nil && !isQuickBarGenerating
    }

    var isDictatingIntoQuickBar: Bool { isDictating && quickBar.receivesDictation }

    /// Called each time the bar opens: after a pause it starts over, as a new search would.
    func prepareQuickBar(now: Date = Date()) {
        if let last = quickBar.lastUsed, now.timeIntervalSince(last) > QuickBar.freshAfter, !isQuickBarGenerating {
            newQuickBarChat()
        }
        if let id = quickBar.chatID, chat(id) == nil { quickBar.chatID = nil }
        quickBar.focusToken = UUID()
    }

    /// The broom: an empty bar with a new chat. The old chat stays in the sidebar.
    func newQuickBarChat() {
        guard !isQuickBarGenerating else { return }
        if isDictatingIntoQuickBar { Task { await stopDictation() } }
        quickBar.chatID = nil
        quickBar.draft = ""
        quickBar.focusToken = UUID()
    }

    /// A chat of the search bar: it may do everything without asking, web and Wikipedia included. What the registry's
    /// rules require (private data, foreign material before changes) is still asked; that is not a setting.
    /// Only the tools the request needs go along (`QuickBarTools`): all of them take a local model over a minute to read.
    func makeQuickBarChat(for text: String, modelId: String) -> Chat {
        var chat = Chat(title: Self.title(for: text), modelId: modelId)
        chat.hasCustomTitle = false
        let groups = QuickBarTools.groups(for: text)
        chat.actionGroups = groups.isEmpty ? nil : groups
        chat.actionApproval = .allowAll
        chat.webSearch = true
        chat.wikipediaSearch = true
        if thinkingDefault { chat.thinking = true }
        chat.contextLength = provider.loadsModels ? max(newChatContextLength, Self.quickBarContextLength) : nil
        return chat
    }

    /// A later question can need more: the groups it names join the chat's and stay.
    func widenQuickBarTools(_ chatID: Chat.ID, for text: String) {
        guard let chat = chat(chatID) else { return }
        let current = chat.actionGroups ?? []
        let added = QuickBarTools.groups(for: text).filter { !current.contains($0) }
        guard !added.isEmpty else { return }
        updateChat(chatID) { $0.actionGroups = current + added }
    }

    func sendQuickBar() {
        // Sending while dictating: wait for the last words first, then send everything.
        if isDictatingIntoQuickBar {
            Task {
                await stopDictation()
                sendQuickBar()
            }
            return
        }
        let text = quickBar.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendQuickBar else { return }
        quickBar.draft = ""
        sendInQuickBar(text: text)
    }

    /// Sends in the bar's chat (also a suggested follow-up question), or starts its chat with it.
    func sendInQuickBar(text: String) {
        guard let modelId = quickBarModelId, !isQuickBarGenerating else { return }
        quickBar.lastUsed = Date()
        let chatID: Chat.ID
        if let current = currentQuickBarChat {
            chatID = current.id
            widenQuickBarTools(chatID, for: text)
        } else {
            let chat = makeQuickBarChat(for: text, modelId: modelId)
            insert(chat)
            quickBar.chatID = chat.id
            chatID = chat.id
        }
        ask(text, images: [], in: chatID, model: modelId)
    }

    func stopQuickBar() {
        guard let id = quickBar.chatID else { return }
        stopGeneration(in: id)
    }

    /// Shows the bar's chat in the main window. The caller brings the window to the front.
    func openQuickBarInMainWindow() {
        guard let id = currentQuickBarChat?.id else { return }
        selectChat(id)
    }
}

/// Which tool groups a request of the search bar needs, by its words. The bar may use every group; it only doesn't
/// send them all, because a 9B model on this Mac reads the descriptions of all of them for over a minute before it
/// answers, even to "Hallo".
enum QuickBarTools {
    private static let words: [(group: String, stems: [String])] = [
        ("writer.core", ["dokument", "text", "essay", "aufsatz", "artikel", "brief", "bericht", "notiz", "schreib", "writer", "absatz", "überschrift", "kapitel"]),
        ("presenter.core", ["präsentation", "folie", "vortrag", "slide", "deck", "presenter", "sprechernotiz"]),
        ("citation.core", ["quelle", "zitat", "literatur", "doi", "isbn", "arxiv", "studie", "beleg", "citation", "bibliograf", "zitier"]),
        ("stories.core", ["roman", "figur", "szene", "geschichte", "story", "stories", "kapitel", "akt ", "erzähl", "welt"]),
        ("projects.core", ["projekt", "kanban", "board", "meilenstein", "akzeptanz", "hindernis", "impediment", "spalte", "projektseite"]),
        ("notes.core", ["todo", "to-do", "to do", "aufgabe", "notes", "note ", "erledig", "abhak", "checkliste", "fortschritt", "hak "]),
        ("podcast.core", ["podcast", "hörspiel", "gesprächsrunde", "diskussionsrunde", "folge ", "vertonen", "einsprechen"]),
        ("chat.core", ["chat", "persona", "skill"]),
        ("chat.private", ["gedächtnis", "erinnerst", "erinnere dich", "persona-datei", "tagebuch"]),
    ]

    /// Asking for something to be made or changed without saying what: a document is the likeliest.
    private static let doing = ["erstell", "lege ", "leg ", "anlegen", "änder", "lösch", "füg", "export", "speicher", "mach mir"]

    static func groups(for text: String) -> [String] {
        let text = text.lowercased()
        var groups = words.filter { $0.stems.contains(where: text.contains) }.map(\.group)
        if groups.isEmpty, doing.contains(where: text.contains) { groups = ["writer.core"] }
        return groups
    }
}
