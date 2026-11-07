import Foundation

/// Stacks in the chat list: what lies outside the folders, gathered by kind, relevance or topic (see SidebarStacks.swift).
extension AppModel {
    private enum StackKeys {
        static let arrangement = "sidebarArrangement"
        static let mode = "sidebarStackMode"
    }

    /// The person has been away this long before the model sorts the stacks.
    static let stackIdleSeconds: Double = 180
    /// After a sorting the model waits at least this long before the next.
    static let stackTidyPause: TimeInterval = 15 * 60

    func loadSidebarStacks() {
        sidebarArrangement = settings.string(forKey: StackKeys.arrangement).flatMap(SidebarArrangement.init(rawValue:)) ?? .date
        stackMode = settings.string(forKey: StackKeys.mode).flatMap(StackMode.init(rawValue:)) ?? .types
        sidebarStacks = library.loadSidebarStacks()
        startStackIdleWatch()
    }

    func setSidebarArrangement(_ arrangement: SidebarArrangement, mode: StackMode? = nil) {
        sidebarArrangement = arrangement
        if let mode { stackMode = mode }
        settings.set(arrangement.rawValue, forKey: StackKeys.arrangement)
        settings.set(stackMode.rawValue, forKey: StackKeys.mode)
        stackTidyError = nil
    }

    /// Chats and documents outside any folder that match the search, newest first.
    var unfiledEntries: [SidebarEntry] {
        let folderIDs = Set(chatFolders.map(\.id))
        return sidebarEntries.filter { !($0.folderID.map(folderIDs.contains) ?? false) }
    }

    /// The stacks of the chat list in the chosen mode.
    var sidebarStackList: [SidebarStack] {
        let entries = unfiledEntries
        switch stackMode {
        case .types: return SidebarStacking.byType(entries)
        case .relevance: return SidebarStacking.byRelevance(entries, activity: sidebarStacks.activity)
        case .topics: return SidebarStacking.byTopic(entries, topics: sidebarStacks.topics)
        }
    }

    func isStackExpanded(_ id: String) -> Bool { sidebarStacks.expanded.contains(id) }

    func toggleStack(_ id: String) {
        if let index = sidebarStacks.expanded.firstIndex(of: id) { sidebarStacks.expanded.remove(at: index) } else { sidebarStacks.expanded.append(id) }
        library.saveSidebarStacks(sidebarStacks)
    }

    /// A chat or document was opened: one more day for "Nach Relevanz".
    func noteSidebarActivity(_ id: UUID) {
        guard SidebarStacking.note(id, on: Date(), in: &sidebarStacks) else { return }
        library.saveSidebarStacks(sidebarStacks)
    }

    /// Turns a topic stack into a real folder with everything in it.
    func makeFolder(fromStack id: String) {
        guard let stack = sidebarStackList.first(where: { $0.id == id }) else { return }
        var folder = Folder(name: Self.uniqueName(stack.title, among: chatFolders.filter { $0.parentID == nil }.map(\.name)))
        folder.isCollapsed = nil
        chatFolders.append(folder)
        library.saveChatFolders(chatFolders)
        for entry in stack.entries { moveSidebarItem(entry.id, to: folder.id) }
        if let uuid = UUID(uuidString: id) {
            sidebarStacks.topics.removeAll { $0.id == uuid }
            library.saveSidebarStacks(sidebarStacks)
        }
    }

    func renameTopicStack(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let uuid = UUID(uuidString: id), let index = sidebarStacks.topics.firstIndex(where: { $0.id == uuid }) else { return }
        sidebarStacks.topics[index].name = trimmed
        library.saveSidebarStacks(sidebarStacks)
    }

    // MARK: Sorting by topic

    /// What has no topic yet among the chats and documents outside folders (search left aside).
    var entriesWithoutTopic: [SidebarEntry] {
        let folderIDs = Set(chatFolders.map(\.id))
        let placed = Set(sidebarStacks.topics.flatMap(\.itemIDs))
        let all = chats.map(SidebarEntry.chat) + documents.map(SidebarEntry.document)
        return all.filter { !($0.folderID.map(folderIDs.contains) ?? false) && !placed.contains($0.id) && !isEmptyEntry($0) }
    }

    private func isEmptyEntry(_ entry: SidebarEntry) -> Bool {
        switch entry {
        case .chat(let chat): chat.messages.isEmpty
        case .document(let document): document.isEmpty
        }
    }

    /// Lets the model sort by topic. `everything`: from scratch; otherwise only what has no topic yet goes into the
    /// existing stacks or new ones.
    func tidySidebarStacks(everything: Bool) {
        guard !isTidyingStacks else { return }
        guard let client, let model = currentModelId else {
            stackTidyError = "Kein Modell gewählt."
            return
        }
        let folderIDs = Set(chatFolders.map(\.id))
        let unfiled = (chats.map(SidebarEntry.chat) + documents.map(SidebarEntry.document))
            .filter { !($0.folderID.map(folderIDs.contains) ?? false) && !isEmptyEntry($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let merging = !everything && !sidebarStacks.topics.isEmpty
        let pool = merging ? entriesWithoutTopic.sorted { $0.updatedAt > $1.updatedAt } : unfiled
        let items = pool.prefix(TopicStackPrompt.maxItems).map(stackItem)
        guard !items.isEmpty else {
            sidebarStacks.tidiedAt = Date()
            return
        }
        // Forget what went into folders or was deleted, so the file doesn't keep growing.
        let alive = Set(unfiled.map(\.id))
        let previous = sidebarStacks.topics.map { TopicStack(id: $0.id, name: $0.name, itemIDs: $0.itemIDs.filter(alive.contains)) }.filter { !$0.itemIDs.isEmpty }
        isTidyingStacks = true
        stackTidyError = nil
        Task { [weak self] in
            do {
                let answer = try await client.complete(
                    model: model, messages: TopicStackPrompt.messages(items: items, existing: previous.map(\.name)),
                    temperature: 0.2, maxTokens: 2500, orderedSchema: ("stapel", TopicStackPrompt.schema)
                )
                let decoded = try JSONDecoder().decode(TopicStackPrompt.Answer.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
                guard let self else { return }
                self.sidebarStacks.topics = TopicStackPrompt.stacks(from: decoded, items: items, previous: previous, merging: merging)
                self.sidebarStacks.tidiedAt = Date()
                self.library.saveSidebarStacks(self.sidebarStacks)
            } catch {
                self?.stackTidyError = "Aufräumen ging nicht: \(error.localizedDescription)"
                // Not again right away: a missing model would fail at every round.
                self?.sidebarStacks.tidiedAt = Date()
            }
            self?.isTidyingStacks = false
        }
    }

    private func stackItem(_ entry: SidebarEntry) -> TopicStackPrompt.Item {
        switch entry {
        case .chat(let chat):
            let first = chat.messages.first { $0.role == .user }?.content ?? ""
            return .init(id: chat.id, kind: "Chat", title: chat.title, snippet: Self.snippet(first))
        case .document(let document):
            let text = document.isPresentation ? (document.deck?.slides.map(\.markdown).joined(separator: " ") ?? "") : document.markdown
            return .init(id: document.id, kind: document.isPresentation ? "Präsentation" : "Dokument", title: document.displayTitle, snippet: Self.snippet(text))
        }
    }

    private static func snippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: #"[#*_`>\[\]{}|]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flat.prefix(90))
    }

    /// Every minute and a half: when the person is away, no model is busy and something has no topic yet, the
    /// model sorts it in.
    func startStackIdleWatch() {
        stackIdleTask?.cancel()
        stackIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard let self else { return }
                if self.shouldTidyStacksNow { self.tidySidebarStacks(everything: false) }
            }
        }
    }

    private var shouldTidyStacksNow: Bool {
        guard sidebarArrangement == .stacks, stackMode == .topics, !isTidyingStacks, currentModelId != nil,
              streamingMessageIDs.isEmpty, deckGeneration?.isRunning != true, !entriesWithoutTopic.isEmpty else { return false }
        if let tidied = sidebarStacks.tidiedAt, Date().timeIntervalSince(tidied) < Self.stackTidyPause { return false }
        return SidebarStacking.secondsSinceInput >= Self.stackIdleSeconds
    }
}
