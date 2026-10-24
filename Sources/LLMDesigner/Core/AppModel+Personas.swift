import SwiftUI
import UniformTypeIdentifiers

/// The voice an answer is read with: the persona's own Qwen voice, or the one from the settings.
struct VoiceChoice: Equatable, Sendable {
    var engine: SpeechEngine
    var qwenVoice: String
    /// How Qwen TTS should speak, e.g. "ruhig und warm".
    var instructions: String?
}

/// Personas: characters with picture, life story and manner the user chats with. A chat has either a persona or skills.
extension AppModel {
    func showPersonas() {
        guard sidebarMode != .personas else { return }
        discardEmptySkill()
        sidebarMode = .personas
    }

    // MARK: Lookup

    var selectedPersona: Persona? {
        selectedPersonaID.flatMap(persona)
    }

    func persona(_ id: Persona.ID) -> Persona? {
        personas.first { $0.id == id }
    }

    func persona(of chat: Chat) -> Persona? {
        chat.personaID.flatMap(persona)
    }

    /// The persona of the selected chat, or of the new chat being written.
    var activePersona: Persona? {
        if let chat = selectedChat { return persona(of: chat) }
        return newChatPersonaID.flatMap(persona)
    }

    /// A persona is chosen when a chat starts; in a running chat, choosing one starts a new chat.
    var canChoosePersonaHere: Bool { selectedChat == nil }

    func personas(matching query: String) -> [Persona] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Persona.sorted(personas.filter { $0.matches(query) })
    }

    func chatCount(withPersona id: Persona.ID) -> Int {
        chats.filter { $0.personaID == id }.count
    }

    // MARK: Choosing

    /// Picks the persona for the new chat (nil: none). Skills chosen before are switched off. In a running chat
    /// this starts a new chat with the persona instead.
    func choosePersona(_ id: Persona.ID?) {
        isPersonaPickerShown = false
        guard canChoosePersonaHere else {
            if let id { startChat(withPersona: id) }
            return
        }
        newChatPersonaID = id
        if id != nil { newChatSkillIDs = [] }
    }

    /// Starts a new chat with this persona.
    func startChat(withPersona id: Persona.ID) {
        newChat()
        newChatPersonaID = id
    }

    // MARK: Library

    func createPersona() {
        discardEmptyPersona()
        personaSearchText = ""
        let persona = Persona(name: "", biography: "", behavior: "")
        personas.append(persona)
        PersonaStore.save(persona)
        newPersonaID = persona.id
        selectedPersonaID = persona.id
        showPersonas()
    }

    func selectPersona(_ id: Persona.ID) {
        guard selectedPersonaID != id else { return showPersonas() }
        discardEmptyPersona()
        selectedPersonaID = id
        showPersonas()
    }

    /// Opens a persona in the library, e.g. from the picker in the composer.
    func editPersona(_ id: Persona.ID) {
        isPersonaPickerShown = false
        selectPersona(id)
    }

    /// Changes a persona; text edits are saved shortly after the user stops typing.
    func updatePersona(_ id: Persona.ID, touch: Bool = true, saveAfter delay: Duration? = .milliseconds(600), _ change: (inout Persona) -> Void) {
        guard let index = personas.firstIndex(where: { $0.id == id }) else { return }
        change(&personas[index])
        if touch { personas[index].updatedAt = Date() }
        savePersona(id, after: delay)
    }

    func renamePersona(_ id: Persona.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePersona(id, saveAfter: nil) { $0.name = trimmed }
    }

    /// Deletes the persona with its folder. Its chats stay and continue without a persona.
    func deletePersona(_ id: Persona.ID) {
        personaSaveTasks[id]?.cancel()
        personaSaveTasks[id] = nil
        personas.removeAll { $0.id == id }
        thalamus[id] = nil
        for chat in chats where chat.personaID == id {
            modifyChat(chat.id) { $0.personaID = nil }
        }
        if newChatPersonaID == id { newChatPersonaID = nil }
        if selectedPersonaID == id { selectedPersonaID = nil }
        if newPersonaID == id { newPersonaID = nil }
        Task.detached(priority: .utility) { PersonaStore.delete(id) }
    }

    /// A persona the user created and left without filling in anything is not worth keeping.
    func discardEmptyPersona() {
        guard let persona = selectedPersona, persona.isEmpty, chatCount(withPersona: persona.id) == 0,
              importingPersonaFiles[persona.id, default: 0] == 0 else { return }
        deletePersona(persona.id)
    }

    func savePersona(_ id: Persona.ID, after delay: Duration? = nil) {
        personaSaveTasks[id]?.cancel()
        personaSaveTasks[id] = nil
        guard let delay else {
            if let persona = persona(id) { PersonaStore.save(persona) }
            return
        }
        personaSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.savePersona(id)
        }
    }

    /// Writes personas whose edits are still waiting for the typing pause (when the app quits).
    func savePendingPersonas() {
        for id in personaSaveTasks.keys { savePersona(id) }
    }

    // MARK: Profile picture

    func chooseAvatar(for id: Persona.ID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Als Profilbild"
        panel.message = "Profilbild für \(persona(id)?.displayName ?? "die Persona") auswählen"
        Task {
            guard await runPanel(panel), let url = panel.url else { return }
            setAvatar(of: id, from: .file(url))
        }
    }

    func setAvatar(of id: Persona.ID, from source: AttachmentStore.Source) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PersonaStore.importAvatar(source, for: id) }
            }.value
            switch result {
            case .success(let avatar):
                let old = persona(id)?.avatarFileName
                updatePersona(id, saveAfter: nil) { persona in
                    persona.avatarFileName = avatar.fileName
                    persona.tint = avatar.tint
                }
                if let old { PersonaStore.removeItem(named: old, of: id) }
            case .failure(let error):
                showNotice(error.localizedDescription)
            }
        }
    }

    func removeAvatar(of id: Persona.ID) {
        guard let old = persona(id)?.avatarFileName else { return }
        updatePersona(id, saveAfter: nil) { persona in
            persona.avatarFileName = nil
            persona.tint = nil
        }
        PersonaStore.removeItem(named: old, of: id)
    }

    // MARK: Files

    func chooseFiles(for id: Persona.ID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Hinzufügen"
        panel.message = "Dateien, in denen \(persona(id)?.displayName ?? "die Persona") nachschauen kann (PDF, Word, Text, Markdown …)"
        Task {
            guard await runPanel(panel) else { return }
            addFiles(panel.urls, to: id)
        }
    }

    func addFiles(_ urls: [URL], to id: Persona.ID) {
        guard !urls.isEmpty else { return }
        importingPersonaFiles[id, default: 0] += urls.count
        Task {
            for url in urls {
                let taken = Set((persona(id)?.files ?? []).map(\.name))
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try PersonaStore.importFile(url, for: id, takenNames: taken) }
                }.value
                importingPersonaFiles[id, default: 0] -= 1
                switch result {
                case .success(let file):
                    guard persona(id) != nil else {
                        PersonaStore.removeFile(file, of: id)
                        continue
                    }
                    updatePersona(id, saveAfter: nil) { $0.files = ($0.files ?? []) + [file] }
                case .failure(let error):
                    showNotice(error.localizedDescription)
                }
            }
            if importingPersonaFiles[id] == 0 { importingPersonaFiles[id] = nil }
        }
    }

    func removeFile(_ fileID: PersonaFile.ID, from id: Persona.ID) {
        guard let file = persona(id)?.files?.first(where: { $0.id == fileID }) else { return }
        updatePersona(id, saveAfter: nil) { persona in
            persona.files?.removeAll { $0.id == fileID }
            if persona.files?.isEmpty == true { persona.files = nil }
        }
        PersonaStore.removeFile(file, of: id)
    }

    func openFile(_ file: PersonaFile, of id: Persona.ID) {
        NSWorkspace.shared.open(PersonaStore.fileURL(file, of: id))
    }

    private func runPanel(_ panel: NSOpenPanel) async -> Bool {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await panel.beginSheetModal(for: window) == .OK
        }
        return panel.runModal() == .OK
    }

    // MARK: Voice

    /// The voice for answers in this chat (nil: the chat being started). A persona with its own voice always
    /// speaks with Qwen TTS, in the model size from the settings.
    func voice(for chat: Chat?) -> VoiceChoice {
        let persona = chat.map(persona(of:)) ?? newChatPersonaID.flatMap(persona)
        return voice(of: persona)
    }

    /// The speaking style goes to the large model only: the small one was not trained on instructions and gets
    /// unsteady with them (in a test, 5 of 16 German sentences went wrong instead of 1).
    func voice(of persona: Persona?) -> VoiceChoice {
        guard let persona, let voice = persona.voice else {
            return VoiceChoice(engine: speechEngine, qwenVoice: qwenVoice)
        }
        let engine: SpeechEngine = speechEngine.qwenModel == nil ? .qwenSmall : speechEngine
        let style = persona.voiceStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceChoice(
            engine: engine,
            qwenVoice: voice,
            instructions: engine == .qwenLarge && style?.isEmpty == false ? style : nil
        )
    }

    /// Plays a short greeting in the persona's voice; a second click stops it.
    func previewVoice(of id: Persona.ID) {
        // The sample counts as a message being read, so the button can show its state.
        if speakingMessageID == id {
            speechReader.stop()
            return
        }
        guard let persona = persona(id) else { return }
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = name.isEmpty ? "Hallo! Schön, dich kennenzulernen." : "Hallo, ich bin \(name). Schön, dich kennenzulernen."
        speechReader.speak(text, voice: voice(of: persona), rate: speechRate)
        speakingMessageID = id
        speechState = speechReader.state
    }
}
