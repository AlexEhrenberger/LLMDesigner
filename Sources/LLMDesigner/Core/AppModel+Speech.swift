import SwiftUI

/// Dictation into the composer and reading answers aloud.
extension AppModel {
    var isDictationAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var isDictating: Bool {
        switch dictationStatus {
        case .preparing, .listening: true
        default: false
        }
    }

    // MARK: Dictation

    /// Starts or stops dictation. With a document open in Writer Studio, the words go into the document,
    /// or into the assistant bar when it has the focus or `intoInstruction` is set. `intoMiniChat`: into the mini
    /// chat's composer.
    func toggleDictation(intoInstruction: Bool = false, intoMiniChat: Bool = false) {
        guard #available(macOS 26.0, *) else { return }
        let engine = dictation()
        Task {
            if engine.isRunning {
                await engine.stop()
            } else if dictationStatus == .idle {
                let writerOpen = sidebarMode == .chats && selectedDocumentID != nil && !intoMiniChat
                miniChat.receivesDictation = intoMiniChat
                dictationIntoInstruction = writerOpen && (intoInstruction || isWriterInstructionFocused)
                dictationDocumentID = writerOpen && !dictationIntoInstruction ? selectedDocumentID : nil
                // The microphone would hear the voice reading the document.
                if dictationIntoDocument, speakingDocumentID != nil { stopReadingDocument() }
                await engine.start(mode: dictationMode)
            }
        }
    }

    func stopDictation() async {
        guard #available(macOS 26.0, *), let engine = dictationEngine as? DictationEngine, engine.isRunning else { return }
        await engine.stop()
    }

    @available(macOS 26.0, *)
    private func dictation() -> DictationEngine {
        if let engine = dictationEngine as? DictationEngine { return engine }
        let engine = DictationEngine()
        engine.onStatus = { [weak self] status in
            guard let self else { return }
            self.dictationStatus = status
            if status == .idle {
                self.dictationPreview = ""
                self.dictationLevel = 0
                if let id = self.dictationDocumentID { self.writerDictation?(.ended, id) }
                self.dictationDocumentID = nil
                self.dictationIntoInstruction = false
                self.miniChat.receivesDictation = false
            }
        }
        engine.onVolatile = { [weak self] text in
            guard let self else { return }
            if let id = self.dictationDocumentID {
                self.writerDictation?(.volatile(text), id)
            } else {
                self.dictationPreview = text
            }
        }
        engine.onFinal = { [weak self] text in
            guard let self else { return }
            let text = Self.withoutPhantomWords(text)
            guard !text.isEmpty else { return }
            if let id = self.dictationDocumentID {
                self.writerDictation?(.final(text), id)
            } else if self.dictationIntoInstruction {
                let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { return }
                let current = self.writerInstruction
                self.writerInstruction = current.isEmpty || current.last?.isWhitespace == true ? current + piece : current + " " + piece
            } else {
                self.appendDictatedText(text)
            }
        }
        engine.onLevel = { [weak self] level in self?.dictationLevel = level }
        engine.onError = { [weak self] message in self?.dictationError = message }
        dictationEngine = engine
        return engine
    }

    /// The recogniser sometimes hears an English "you" in the noise before the first words
    /// ("you Schreib einen Satz …"); it is dropped when German follows, or when it is all there is.
    nonisolated static func withoutPhantomWords(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if ["you", "you.", "you?"].contains(lowered) { return "" }
        guard lowered.hasPrefix("you ") else { return trimmed }
        let rest = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        guard let first = rest.first, first.isUppercase || "äöüß".contains(first) else { return trimmed }
        // "you Die Maschine …": the next word starts a German sentence, not an English one.
        let english: Set<String> = ["are", "can", "know", "have", "will", "should", "need", "want", "see", "and", "to"]
        let next = rest.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return english.contains(next) ? trimmed : rest
    }

    /// Recognised text goes to the end of the draft, so typing during dictation is kept.
    private func appendDictatedText(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        var current = miniChat.receivesDictation ? miniChat.draft : draft
        if let last = current.last, !last.isWhitespace { current += " " }
        if miniChat.receivesDictation { miniChat.draft = current + piece } else { draft = current + piece }
    }

    // MARK: Reading aloud

    func setUpSpeechReader() {
        speechReader.onState = { [weak self] state in
            guard let self else { return }
            self.speechState = state
            if state == .stopped {
                self.speakingMessageID = nil
                if self.speakingDocumentID != nil {
                    self.speakingDocumentID = nil
                    self.speechReader.onProgress = nil
                    let ended = self.writerSpeechEnded
                    self.writerSpeechEnded = nil
                    ended?()
                }
            }
        }
        speechReader.onNotice = { [weak self] message in self?.showNotice(message) }
    }

    func toggleSpeaking(_ messageID: ChatMessage.ID) {
        if speakingMessageID == messageID {
            speechReader.stop()
            return
        }
        guard let message = message(messageID) else { return }
        let text = SpeakableText.from(markdown: message.content)
        guard !text.isEmpty else { return }
        speechReader.speak(text, voice: voice(for: chat(holding: messageID)), rate: speechRate)
        speakingMessageID = messageID
        speechState = speechReader.state
    }

    // MARK: Reading a document aloud

    /// Reads text of the open document. `progress` gets the UTF-16 range of `text` being spoken.
    func readDocumentAloud(_ text: String, progress: @escaping (NSRange) -> Void, ended: @escaping () -> Void) {
        guard let id = selectedDocumentID else { return }
        // Ends whatever is being read, including its highlight, before the new reading takes over.
        speechReader.stop()
        if dictationIntoDocument { Task { await stopDictation() } }
        speakingDocumentID = id
        writerSpeechEnded = ended
        speechReader.onProgress = progress
        speechReader.speak(text, voice: voice(of: nil), rate: speechRate)
        speechState = speechReader.state
        if speechReader.state == .stopped {
            // Nothing to read (only code or empty paragraphs).
            speakingDocumentID = nil
            speechReader.onProgress = nil
            writerSpeechEnded = nil
            ended()
        }
    }

    /// Reads a text such as an assistant answer aloud; `id` names it, so a second call stops it.
    func toggleReading(_ markdown: String, id: UUID) {
        if speakingMessageID == id { return speechReader.stop() }
        let text = SpeakableText.from(markdown: markdown)
        guard !text.isEmpty else { return }
        if dictationIntoInstruction || dictationIntoDocument { Task { await stopDictation() } }
        speechReader.stop()
        speechReader.speak(text, voice: voice(of: nil), rate: speechRate)
        speakingMessageID = id
        speechState = speechReader.state
    }

    func stopReadingDocument() {
        guard speakingDocumentID != nil else { return }
        speechReader.stop()
    }

    func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
