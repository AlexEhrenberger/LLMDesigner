import SwiftUI

/// Conversation mode: speaking instead of typing, answers read aloud, in a narrow window with a wave.
extension AppModel {
    /// Needs the macOS 26 speech recognition, like dictation.
    var isConversationAvailable: Bool { isDictationAvailable }

    var canStartConversation: Bool {
        isConversationAvailable && conversation == nil && currentModelId != nil && !isGenerating
    }

    func toggleConversation() {
        if conversation == nil {
            startConversation()
        } else {
            endConversation()
        }
    }

    /// Starts a conversation in the open chat, or in a new chat with the skills and switches chosen in the composer.
    func startConversation() {
        guard canStartConversation else { return }
        showChats()
        cancelEditing()
        isSkillPickerShown = false
        isPersonaPickerShown = false
        speechReader.stop()
        // Dictated text stays in the composer.
        Task { await stopDictation() }
        let session = ConversationSession(app: self, chatID: selectedChatID)
        conversation = session
        MainWindow.shrinkForConversation()
        session.start()
    }

    func endConversation() {
        guard let session = conversation, !session.isEnding else { return }
        session.end()
        // The window grows back first; the chat appears once it has its size again.
        MainWindow.restoreAfterConversation { [weak self] in
            guard let self else { return }
            self.conversation = nil
            if let chatID = session.chatID, self.isPanelShown { self.refreshOutlineIfNeeded(chatID) }
        }
    }

    /// Sends a spoken turn. Returns the chat and the answer that is now being written.
    func sendSpoken(_ text: String) -> (chat: Chat.ID, answer: ChatMessage.ID)? {
        guard currentModelId != nil, !isGenerating,
              let chatID = send(text: text, spoken: true),
              let answerID = streamingMessageIDs[chatID] else { return nil }
        return (chatID, answerID)
    }
}
