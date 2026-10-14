import SwiftUI

/// Folders in the sidebar and the skill library: system-prompt building blocks a chat can combine.
extension AppModel {
    // MARK: Sidebar mode

    func showChats() {
        guard sidebarMode != .chats else { return }
        discardEmptySkill()
        discardEmptyPersona()
        sidebarMode = .chats
    }

    func showSkills() {
        guard sidebarMode != .skills else { return }
        discardEmptyPersona()
        sidebarMode = .skills
    }

    // MARK: Folders (chats and skills alike)

    /// Creates a folder in the chat or skill list and lets the user name it right away.
    @discardableResult
    func createFolder(for kind: SidebarMode) -> Folder.ID {
        var folder = Folder(name: "Neuer Ordner")
        // A search would hide the new folder before it has a name.
        searchText = ""
        skillSearchText = ""
        switch kind {
        case .chats, .personas:
            folder.name = Self.uniqueName(folder.name, among: chatFolders.map(\.name))
            chatFolders.append(folder)
            library.saveChatFolders(chatFolders)
        case .skills:
            folder.name = Self.uniqueName(folder.name, among: skillFolders.map(\.name))
            skillFolders.append(folder)
            saveSkillLibrary()
        }
        renamingID = folder.id
        return folder.id
    }

    func renameFolder(_ id: Folder.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateFolder(id) { $0.name = trimmed }
    }

    func toggleFolderCollapsed(_ id: Folder.ID) {
        updateFolder(id) { $0.isCollapsed = $0.isCollapsed == true ? nil : true }
    }

    /// Deletes a folder. Its chats or skills go back to the plain list, or are deleted with it.
    func deleteFolder(_ id: Folder.ID, includingContents: Bool) {
        if chatFolders.contains(where: { $0.id == id }) {
            for chat in chats where chat.folderID == id {
                if includingContents { deleteChat(chat.id) } else { modifyChat(chat.id) { $0.folderID = nil } }
            }
            for document in documents where document.folderID == id {
                if includingContents { deleteDocument(document.id) } else { moveDocument(document.id, to: nil) }
            }
            chatFolders.removeAll { $0.id == id }
            library.saveChatFolders(chatFolders)
            if newChatFolderID == id { newChatFolderID = nil }
        } else {
            for skill in skills where skill.folderID == id {
                if includingContents { deleteSkill(skill.id) } else { updateSkill(skill.id, touch: false) { $0.folderID = nil } }
            }
            skillFolders.removeAll { $0.id == id }
            saveSkillLibrary()
        }
    }

    func folderName(_ id: Folder.ID?) -> String? {
        guard let id else { return nil }
        return (chatFolders.first { $0.id == id } ?? skillFolders.first { $0.id == id })?.name
    }

    private func updateFolder(_ id: Folder.ID, _ change: (inout Folder) -> Void) {
        if let index = chatFolders.firstIndex(where: { $0.id == id }) {
            change(&chatFolders[index])
            library.saveChatFolders(chatFolders)
        } else if let index = skillFolders.firstIndex(where: { $0.id == id }) {
            change(&skillFolders[index])
            saveSkillLibrary()
        }
    }

    private static func uniqueName(_ name: String, among names: [String]) -> String {
        let taken = Set(names)
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Chat folders

    /// Folders with their chats and documents (newest first). While searching, folders without a hit are left out.
    var chatFolderSections: [FolderSection<SidebarEntry>] {
        let query = chatSearchQuery
        let all = (chats.map(SidebarEntry.chat) + documents.map(SidebarEntry.document)).sorted { $0.updatedAt > $1.updatedAt }
        let hits = sidebarEntries
        return Folder.sorted(chatFolders).compactMap { folder in
            if query.isEmpty || folder.name.localizedStandardContains(query) {
                return FolderSection(folder: folder, items: all.filter { $0.folderID == folder.id })
            }
            let inFolder = hits.filter { $0.folderID == folder.id }
            return inFolder.isEmpty ? nil : FolderSection(folder: folder, items: inFolder)
        }
    }

    /// Moves a chat into a folder (nil: out of its folder). The folder opens, so the chat stays in view.
    func moveChat(_ chatID: Chat.ID, to folderID: Folder.ID?) {
        guard let chat = chat(chatID), chat.folderID != folderID else { return }
        modifyChat(chatID) { $0.folderID = folderID }
        if let folderID { expandFolder(folderID) }
    }

    func moveChatToNewFolder(_ chatID: Chat.ID) {
        moveChat(chatID, to: createFolder(for: .chats))
    }

    /// Starts a chat that goes into this folder once it is sent.
    func newChat(inFolder folderID: Folder.ID) {
        newChat()
        newChatFolderID = folderID
    }

    func expandFolder(_ id: Folder.ID) {
        guard (chatFolders + skillFolders).first(where: { $0.id == id })?.isCollapsed == true else { return }
        updateFolder(id) { $0.isCollapsed = nil }
    }

    // MARK: Skill library

    var selectedSkill: Skill? {
        guard let selectedSkillID else { return nil }
        return skills.first { $0.id == selectedSkillID }
    }

    func skill(_ id: Skill.ID) -> Skill? {
        skills.first { $0.id == id }
    }

    /// Folders with their skills (by name) and the skills outside any folder that match `query`.
    func skillSections(matching query: String) -> (folders: [FolderSection<Skill>], unfiled: [Skill]) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderIDs = Set(skillFolders.map(\.id))
        let folders = Folder.sorted(skillFolders).compactMap { folder -> FolderSection<Skill>? in
            let inFolder = Skill.sorted(skills.filter { $0.folderID == folder.id })
            if query.isEmpty || folder.name.localizedStandardContains(query) {
                return FolderSection(folder: folder, items: inFolder)
            }
            let hits = inFolder.filter { $0.matches(query) }
            return hits.isEmpty ? nil : FolderSection(folder: folder, items: hits)
        }
        let unfiled = Skill.sorted(skills.filter { skill in
            !(skill.folderID.map(folderIDs.contains) ?? false) && skill.matches(query)
        })
        return (folders, unfiled)
    }

    /// Creates an empty skill and opens it in the editor.
    func createSkill(inFolder folderID: Folder.ID? = nil) {
        discardEmptySkill()
        skillSearchText = ""
        let skill = Skill(name: "", summary: "", instructions: "", folderID: folderID)
        skills.append(skill)
        saveSkillLibrary()
        newSkillID = skill.id
        selectedSkillID = skill.id
        if let folderID { expandFolder(folderID) }
        showSkills()
    }

    func selectSkill(_ id: Skill.ID) {
        guard selectedSkillID != id else { return showSkills() }
        discardEmptySkill()
        selectedSkillID = id
        showSkills()
    }

    /// Opens a skill in the library, e.g. from the picker in the composer.
    func editSkill(_ id: Skill.ID) {
        isSkillPickerShown = false
        selectSkill(id)
    }

    /// Changes a skill; text edits are saved shortly after the user stops typing.
    func updateSkill(_ id: Skill.ID, touch: Bool = true, _ change: (inout Skill) -> Void) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        change(&skills[index])
        if touch { skills[index].updatedAt = Date() }
        saveSkillLibrary(after: .milliseconds(600))
    }

    func renameSkill(_ id: Skill.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSkill(id) { $0.name = trimmed }
    }

    func moveSkill(_ id: Skill.ID, to folderID: Folder.ID?) {
        guard let skill = skill(id), skill.folderID != folderID else { return }
        updateSkill(id, touch: false) { $0.folderID = folderID }
        if let folderID { expandFolder(folderID) }
    }

    func moveSkillToNewFolder(_ id: Skill.ID) {
        moveSkill(id, to: createFolder(for: .skills))
    }

    func duplicateSkill(_ id: Skill.ID) {
        guard let original = skill(id) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = Self.uniqueName("\(original.displayName) (Kopie)", among: skills.map(\.name))
        copy.createdAt = Date()
        copy.updatedAt = Date()
        skills.append(copy)
        saveSkillLibrary()
        selectedSkillID = copy.id
        showSkills()
    }

    /// Removes a skill from the library and from every chat that used it.
    func deleteSkill(_ id: Skill.ID) {
        skills.removeAll { $0.id == id }
        for chat in chats where chat.skillIDs?.contains(id) == true {
            modifyChat(chat.id) { chat in
                chat.skillIDs?.removeAll { $0 == id }
                if chat.skillIDs?.isEmpty == true { chat.skillIDs = nil }
            }
        }
        newChatSkillIDs.removeAll { $0 == id }
        if selectedSkillID == id { selectedSkillID = nil }
        if newSkillID == id { newSkillID = nil }
        saveSkillLibrary()
    }

    func chatCount(using skillID: Skill.ID) -> Int {
        chats.filter { $0.skillIDs?.contains(skillID) == true }.count
    }

    /// Starts a new chat with this skill switched on.
    func startChat(with skillID: Skill.ID) {
        newChat()
        newChatSkillIDs = [skillID]
    }

    func addExampleSkills() {
        let examples = SkillPrompt.examples()
        skillFolders += examples.folders
        skills += examples.skills
        saveSkillLibrary()
        selectedSkillID = examples.skills.first?.id
    }

    /// A skill the user created and left without writing anything is not worth keeping.
    func discardEmptySkill() {
        guard let skill = selectedSkill, skill.isEmpty, chatCount(using: skill.id) == 0 else { return }
        deleteSkill(skill.id)
    }

    /// Writes the skill library to disk, right away or once the user pauses typing.
    func saveSkillLibrary(after delay: Duration? = nil) {
        skillSaveTask?.cancel()
        skillSaveTask = nil
        guard let delay else {
            library.saveSkills(.init(skills: skills, folders: skillFolders))
            return
        }
        skillSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveSkillLibrary()
        }
    }

    /// Saves edits that are still waiting for the typing pause when the app quits.
    func saveSkillsOnQuit() {
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.skillSaveTask != nil { self.saveSkillLibrary() }
                self.savePendingPersonas()
                self.savePendingDocuments()
            }
        }
    }

    // MARK: Skills in a chat

    /// The chat's skills that still exist, in the order they go into the system prompt.
    func skills(of chat: Chat) -> [Skill] {
        (chat.skillIDs ?? []).compactMap(skill)
    }

    /// Skills of the selected chat, or of the new chat being written. None while a persona is chosen.
    var activeSkills: [Skill] {
        guard activePersona == nil else { return [] }
        if let chat = selectedChat { return skills(of: chat) }
        return newChatSkillIDs.compactMap(skill)
    }

    func isSkillActive(_ id: Skill.ID) -> Bool {
        activeSkills.contains { $0.id == id }
    }

    /// Switches a skill on or off for the selected chat (or the new one being written).
    func toggleSkill(_ id: Skill.ID) {
        guard activePersona == nil else { return }
        guard let chat = selectedChat else {
            if newChatSkillIDs.contains(id) { newChatSkillIDs.removeAll { $0 == id } } else { newChatSkillIDs.append(id) }
            return
        }
        modifyChat(chat.id) { chat in
            var ids = (chat.skillIDs ?? []).filter { skill($0) != nil }
            if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
            chat.skillIDs = ids.isEmpty ? nil : ids
        }
    }

    /// The system prompt the next message is sent with (without the hints for web search and thinking).
    var activeSystemPrompt: String {
        if let chat = selectedChat { return systemPrompt(for: chat) }
        if let persona = activePersona {
            let prompt = PersonaPrompt.compose(base: systemPrompt, persona: persona)
            let memories = newChatMemory == .on
                ? thalamusBlock(of: persona.id, excluding: nil, contextLength: newChatContextLength) : nil
            return [prompt, memories].compactMap { $0 }.joined(separator: "\n\n")
        }
        return SkillPrompt.compose(base: systemPrompt, skills: activeSkills)
    }

    /// A chat's system prompt: the persona it talks to with what it remembers, or else its skills.
    func systemPrompt(for chat: Chat) -> String {
        if let persona = persona(of: chat) {
            let prompt = PersonaPrompt.compose(base: systemPrompt, persona: persona)
            return [prompt, memoryBlock(for: chat)].compactMap { $0 }.joined(separator: "\n\n")
        }
        return SkillPrompt.compose(base: systemPrompt, skills: skills(of: chat))
    }
}
