import AppKit
import SwiftUI

/// A hint above the mini chat's composer.
enum MiniChatNotice: Equatable {
    /// macOS doesn't let the app record the screen (yet).
    case screenPermission
    case text(String)
}

/// The mini chat: a narrow window of its own (about as wide as the power access) with one chat, to talk to the model
/// while working on in the main window. It has its own composer, and it can show the model the screen.
@MainActor
@Observable
final class MiniChat {
    private static let floatsKey = "miniChatFloats"

    /// The window is open.
    var isOpen = false
    /// The window is the key window: the Chat menu's stop, regenerate, thinking, pictures and dictation act on its chat.
    var isKey = false
    /// The chat in the window; nil while a new one is being started there. The main window may show the same chat.
    var chatID: Chat.ID?
    /// The message being written, apart from the main window's composer.
    var draft = ""
    var images: [ImageAttachment] = []
    /// Pictures that are still being read or taken.
    var importing = 0
    /// Thinking of the chat that is being started in the window.
    var newChatThinking = false
    /// The running dictation writes into this composer.
    var receivesDictation = false
    /// A screenshot is being taken.
    var isGlancing = false
    var notice: MiniChatNotice?
    /// Changes when the composer should take the focus, e.g. once a screenshot is attached.
    var focusToken = UUID()
    /// The window stays above all others, also those of other apps, so it doesn't vanish behind the main window.
    var floats: Bool {
        didSet { settings.set(floats, forKey: Self.floatsKey) }
    }

    @ObservationIgnored private let settings = AppLibrary.current.settings

    init() {
        floats = settings.object(forKey: Self.floatsKey) as? Bool ?? true
    }
}

extension AppModel {
    var currentMiniChat: Chat? { miniChat.chatID.flatMap { chat($0) } }

    /// The model that answers in the mini chat: the chat's own, or the one chosen last.
    var miniChatModelId: String? { currentMiniChat.flatMap(modelId(for:)) ?? preferredModelId }
    var miniChatModel: LMModel? {
        guard let id = miniChatModelId else { return nil }
        return models.first { $0.id == id }
    }

    var isMiniChatGenerating: Bool { miniChat.chatID.map(isGenerating) ?? false }
    var isMiniChatThinkingOn: Bool { currentMiniChat.map { $0.thinking == true } ?? miniChat.newChatThinking }

    var canSendMiniChat: Bool {
        let hasText = !miniChat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !miniChat.images.isEmpty) && miniChat.importing == 0 && miniChatModelId != nil && !isMiniChatGenerating
    }

    /// The chat the Chat menu acts on: the mini chat's while its window is in front, else the main window's.
    var commandChatID: Chat.ID? { miniChat.isKey ? miniChat.chatID : selectedChatID }

    /// The chat the main window shows, if it shows one (not a document, a studio or a new chat).
    var mainWindowChatID: Chat.ID? {
        sidebarMode == .chats && activeApplication == nil ? selectedChatID : nil
    }

    // MARK: Opening

    /// Shows `chatID` in the mini chat, nil a new chat there. The view that calls this opens the window (`openWindow`).
    func showInMiniChat(_ chatID: Chat.ID?) {
        if let chatID, chat(chatID) == nil { return }
        if chatID == nil || chatID != miniChat.chatID {
            miniChat.newChatThinking = thinkingDefault
        }
        miniChat.chatID = chatID
        miniChat.focusToken = UUID()
    }

    /// Opens the mini chat's chat in the main window. The view that calls this brings the main window to the front.
    func openMiniChatInMainWindow() {
        guard let id = currentMiniChat?.id else { return }
        selectChat(id)
    }

    // MARK: Sending

    func sendMiniChat() {
        // Sending while dictating: wait for the last words first, then send everything.
        if isDictating && miniChat.receivesDictation {
            Task {
                await stopDictation()
                sendMiniChat()
            }
            return
        }
        let text = miniChat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = miniChat.images
        guard canSendMiniChat else { return }
        miniChat.draft = ""
        miniChat.images = []
        sendInMiniChat(text: text, images: images)
    }

    /// Sends a message in the mini chat (also a suggested follow-up question), or starts a new chat there with it.
    func sendInMiniChat(text: String, images: [ImageAttachment] = []) {
        guard let modelId = miniChatModelId, !isMiniChatGenerating else { return }
        miniChat.notice = nil
        let chatID: Chat.ID
        if let current = currentMiniChat {
            chatID = current.id
        } else {
            var chat = Chat(title: Self.title(for: text), modelId: modelId)
            chat.hasCustomTitle = false
            if miniChat.newChatThinking { chat.thinking = true }
            // As in the main window: the chosen context length with LM Studio, Kapitsa's own otherwise.
            chat.contextLength = provider.loadsModels ? newChatContextLength : nil
            insert(chat)
            miniChat.chatID = chat.id
            chatID = chat.id
        }
        ask(text, images: images, in: chatID, model: modelId)
    }

    func stopMiniChat() {
        guard let id = miniChat.chatID else { return }
        stopGeneration(in: id)
    }

    /// Switches thinking for the mini chat's chat; new chats (here and in the main window) start with the last choice.
    func toggleMiniChatThinking() {
        thinkingDefault = !isMiniChatThinkingOn
        guard let id = currentMiniChat?.id else { return miniChat.newChatThinking.toggle() }
        modifyChat(id) { $0.thinking = $0.thinking == true ? nil : true }
    }

    // MARK: Pictures

    func attachMiniChatImages(_ sources: [AttachmentStore.Source]) {
        miniChat.importing += sources.count
        Task {
            for source in sources {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try AttachmentStore.importImage(source) }
                }.value
                miniChat.importing -= 1
                switch result {
                case .success(let attachment): miniChat.images.append(attachment)
                case .failure(let error): miniChat.notice = .text(error.localizedDescription)
                }
            }
        }
    }

    func removeMiniChatImage(_ id: ImageAttachment.ID) {
        miniChat.images.removeAll { $0.id == id }
    }

    /// "Bildschirm betrachten": a picture of the screen – without the mini chat's own window – goes to the mini chat's
    /// message, so the model sees what the user is working on. `screen`: by default the one the mini chat stands on.
    func glanceAtScreen(_ screen: NSScreen? = nil) {
        guard miniChat.isOpen, !miniChat.isGlancing else { return }
        guard ScreenGlance.isAllowed else {
            // The first time macOS asks by itself; after that the permission is only in System Settings.
            ScreenGlance.requestPermission()
            miniChat.notice = .screenPermission
            return
        }
        let window = MiniChatWindow.window
        guard let screen = screen ?? window?.screen ?? NSScreen.main, let displayID = screen.displayID else { return }
        let excluded = window.map { CGWindowID($0.windowNumber) }
        miniChat.isGlancing = true
        miniChat.importing += 1
        miniChat.notice = nil
        Task {
            defer {
                miniChat.isGlancing = false
                miniChat.importing -= 1
            }
            do {
                let data = try await ScreenGlance.capture(display: displayID, excluding: excluded)
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try AttachmentStore.importImage(.data(data))
                }.value
                miniChat.images.append(attachment)
                // LM Studio says which models see pictures; other servers don't, there it is simply tried.
                if let model = miniChatModel, model.type == "llm" {
                    miniChat.notice = .text("„\(model.displayName)“ kann laut \(provider.label) keine Bilder sehen. Wähle ein Modell mit Bildverständnis, z. B. Gemma 4.")
                }
                // The question about the picture is written in the mini chat, also after ⇧⌘B in the main window.
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                miniChat.focusToken = UUID()
            } catch {
                miniChat.notice = ScreenGlance.isAllowed ? .text(error.localizedDescription) : .screenPermission
            }
        }
    }
}
