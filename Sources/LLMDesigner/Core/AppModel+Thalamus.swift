import SwiftUI

/// The consolidation that is running, for the composer and the persona editor.
struct ThalamusConsolidationState: Equatable {
    let personaID: Persona.ID
    var done: Int
    var total: Int
}

/// The strong memory (Thalamus): sorts each message before the persona answers, keeps it as an impression, folds the
/// impressions of a quiet chat into memories and hands the persona what it remembers. See Thalamus.swift.
extension AppModel {
    /// A chat counts as quiet after this long without a new message; then its impressions are consolidated.
    static let thalamusQuietDelay: Duration = .seconds(30 * 60)

    // MARK: Lookup

    /// Impressions that are not consolidated yet, newest first.
    func thalamusImpressions(of personaID: Persona.ID) -> [ThalamusEntry] {
        (thalamus[personaID]?.entries ?? []).sorted { $0.date > $1.date }
    }

    /// Memories, the most important first; less important ones move back over time.
    func thalamusMemories(of personaID: Persona.ID) -> [ThalamusMemory] {
        let now = Date()
        return (thalamus[personaID]?.memories ?? []).sorted { $0.importance(now: now) > $1.importance(now: now) }
    }

    func thalamusProfile(of personaID: Persona.ID) -> [ThalamusFact] {
        (thalamus[personaID]?.profile ?? []).sorted { $0.since < $1.since }
    }

    /// What of the persona's latest chats is in a chat's context (see `ThalamusRecall.recent`).
    func recentThalamus(of personaID: Persona.ID, excluding chatID: Chat.ID?, contextLength: Int) -> (memories: [ThalamusMemory], impressions: [ThalamusEntry]) {
        ThalamusRecall.recent(
            in: thalamus[personaID] ?? ThalamusLibrary(), excludingChat: chatID,
            budget: ThalamusRecall.budget(ThalamusRecall.recentShare, contextLength: contextLength)
        )
    }

    /// What the persona remembers in a chat's system prompt, if the chat has the memory on.
    func memoryBlock(for chat: Chat) -> String? {
        guard chat.memory == .on, let personaID = chat.personaID else { return nil }
        return thalamusBlock(of: personaID, excluding: chat.id, contextLength: contextLength(of: chat))
    }

    /// The chat's context length, or what its model is loaded with for chats from before the setting.
    func contextLength(of chat: Chat) -> Int {
        let loaded = models.first { $0.id == (chat.modelId ?? preferredModelId) }?.loadedContextLength
        return chat.contextLength ?? loaded ?? 8_192
    }

    /// Profile and latest chats for the system prompt of a chat with the memory on.
    func thalamusBlock(of personaID: Persona.ID, excluding chatID: Chat.ID?, contextLength: Int) -> String? {
        let library = thalamus[personaID] ?? ThalamusLibrary()
        let facts = ThalamusRecall.profile(in: library, budget: ThalamusRecall.budget(ThalamusRecall.profileShare, contextLength: contextLength))
        let recent = recentThalamus(of: personaID, excluding: chatID, contextLength: contextLength)
        let parts = [ThalamusRecall.profileBlock(facts), ThalamusRecall.recentBlock(memories: recent.memories, impressions: recent.impressions)]
        let text = parts.compactMap { $0 }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    // MARK: Before an answer

    /// The message to sort before the answer, if the chat runs with a persona and the strong memory.
    func thalamusJob(for chat: Chat, model: String) -> ThalamusJob? {
        guard chat.memory == .on, let personaID = chat.personaID, persona(personaID) != nil,
              let index = chat.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let question = chat.messages[index]
        guard !question.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let previous = chat.messages[..<index].last { $0.role == .assistant && !$0.content.isEmpty && $0.error == nil }?.content
        return ThalamusJob(
            personaID: personaID, chatID: chat.id, question: question, previousAnswer: previous, model: model,
            contextLength: contextLength(of: chat)
        )
    }

    /// Sorts the message with a neutral prompt into an impression (or reuses it when the answer is regenerated) and
    /// returns the memories it brings back, for the system prompt. The answer shows each step in its `thalamus` trace.
    func runThalamus(_ job: ThalamusJob, answerID: ChatMessage.ID) async -> String? {
        guard let client else { return nil }
        var library = thalamus[job.personaID] ?? ThalamusLibrary()
        let inContext = Set(recentThalamus(of: job.personaID, excluding: job.chatID, contextLength: job.contextLength).memories.map(\.id))

        // Already consolidated (or deleted): no new impression, but the words of the message may still remind.
        if library.forgottenMessageIDs.contains(job.question.id) {
            let probe = ThalamusEntry(
                date: job.question.createdAt, chatID: job.chatID, messageID: job.question.id, category: "", summary: "",
                keywords: [], userEmotions: [], aiEmotions: [], text: job.question.content
            )
            let memories = ThalamusRecall.matches(for: probe, in: library.memories ?? [], excluding: inContext)
            guard !memories.isEmpty else { return nil }
            updateMessage(job.chatID, answerID) { $0.thalamus = ThalamusTrace(status: .done, memories: memories) }
            return ThalamusRecall.block(memories)
        }

        let entry: ThalamusEntry
        var stored = true
        if let existing = library.entries.first(where: { $0.messageID == job.question.id }) {
            entry = existing
        } else {
            updateMessage(job.chatID, answerID) { $0.thalamus = ThalamusTrace(status: .running) }
            do {
                let answer = try await client.complete(
                    model: job.model,
                    messages: ThalamusClassifier.requestMessages(for: job, knownCategories: library.categories),
                    temperature: 0.2, maxTokens: 1_000,
                    jsonSchema: (ThalamusClassifier.schemaName, ThalamusClassifier.schema)
                )
                try Task.checkCancellation()
                (entry, stored) = try ThalamusClassifier.parse(answer, job: job, knownCategories: library.categories)
            } catch {
                let message = Task.isCancelled || error is CancellationError ? "Abgebrochen" : error.localizedDescription
                updateMessage(job.chatID, answerID) { $0.thalamus = ThalamusTrace(status: .failed, error: message) }
                return nil
            }
            // The database may have changed while the model was sorting.
            library = thalamus[job.personaID] ?? library
            if stored, persona(job.personaID) != nil {
                library.entries.append(entry)
                library.noteActivity(job.chatID, at: entry.date)
                thalamus[job.personaID] = library
                PersonaStore.saveThalamus(library, of: job.personaID)
            }
        }

        let memories = stored ? ThalamusRecall.matches(for: entry, in: library.memories ?? [], excluding: inContext) : []
        updateMessage(job.chatID, answerID) {
            $0.thalamus = ThalamusTrace(status: .done, entry: entry, stored: stored, memories: memories.isEmpty ? nil : memories)
        }
        return ThalamusRecall.block(memories)
    }

    // MARK: Consolidation

    /// Whether a chat has impressions waiting for consolidation.
    func hasPendingImpressions(_ chatID: Chat.ID, of personaID: Persona.ID) -> Bool {
        thalamus[personaID]?.entries.contains { $0.chatID == chatID } ?? false
    }

    /// After an answer: the chat counts as quiet once nothing new comes for a while.
    func scheduleThalamusQuiet(_ chatID: Chat.ID) {
        thalamusQuietTasks[chatID]?.cancel()
        guard let chat = chat(chatID), chat.memory == .on, chat.personaID != nil else { return }
        thalamusQuietTasks[chatID] = Task { [weak self] in
            try? await Task.sleep(for: Self.thalamusQuietDelay)
            guard !Task.isCancelled, let self else { return }
            self.thalamusQuietTasks[chatID] = nil
            guard !self.isGenerating(chatID) else { return }
            self.consolidateThalamus(chatID)
        }
    }

    /// Consolidates a chat's impressions (when the user leaves it or it went quiet).
    func consolidateThalamus(_ chatID: Chat.ID) {
        guard let personaID = chat(chatID)?.personaID ?? thalamusOwner(of: chatID),
              hasPendingImpressions(chatID, of: personaID) else { return }
        enqueueConsolidation([(personaID, chatID)])
    }

    /// The "Jetzt verdichten" button: all waiting impressions of the persona, the oldest chat first.
    func consolidateAllThalamus(of personaID: Persona.ID) {
        let entries = thalamus[personaID]?.entries ?? []
        var latest: [Chat.ID: Date] = [:]
        for entry in entries { latest[entry.chatID] = max(latest[entry.chatID] ?? .distantPast, entry.date) }
        enqueueConsolidation(latest.sorted { $0.value < $1.value }.map { (personaID, $0.key) })
    }

    /// At launch: impressions of chats that went quiet while the app was closed.
    func catchUpThalamus() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        for (personaID, library) in thalamus {
            var latest: [Chat.ID: Date] = [:]
            for entry in library.entries { latest[entry.chatID] = max(latest[entry.chatID] ?? .distantPast, entry.date) }
            enqueueConsolidation(latest.filter { $0.value < cutoff }.sorted { $0.value < $1.value }.map { (personaID, $0.key) })
        }
    }

    /// Writing frees the model: a running consolidation stops; quiet chats are taken up again later.
    func cancelThalamusConsolidation() {
        guard thalamusWorker != nil else { return }
        thalamusWorker?.cancel()
        thalamusWorker = nil
        thalamusQueue = []
        thalamusConsolidation = nil
    }

    private func thalamusOwner(of chatID: Chat.ID) -> Persona.ID? {
        thalamus.first { $0.value.entries.contains { $0.chatID == chatID } }?.key
    }

    private func enqueueConsolidation(_ items: [(Persona.ID, Chat.ID)]) {
        for item in items where !thalamusQueue.contains(where: { $0.0 == item.0 && $0.1 == item.1 }) {
            thalamusQueue.append(item)
            if thalamusConsolidation?.personaID == item.0 { thalamusConsolidation?.total += 1 }
        }
        guard thalamusWorker == nil, !thalamusQueue.isEmpty else { return }
        thalamusWorker = Task { [weak self] in
            await self?.runConsolidationQueue()
        }
    }

    /// Works through the queue one chat at a time, so only one consolidation talks to the model.
    private func runConsolidationQueue() async {
        while !Task.isCancelled, !thalamusQueue.isEmpty {
            let (personaID, chatID) = thalamusQueue.removeFirst()
            if thalamusConsolidation?.personaID != personaID {
                thalamusConsolidation = ThalamusConsolidationState(
                    personaID: personaID, done: 0, total: 1 + thalamusQueue.filter { $0.0 == personaID }.count
                )
            }
            await consolidate(chatID, of: personaID)
            guard !Task.isCancelled else { return }
            thalamusConsolidation?.done += 1
        }
        // A cancelled worker leaves the state to whatever started after it.
        guard !Task.isCancelled else { return }
        thalamusConsolidation = nil
        thalamusWorker = nil
    }

    /// Consolidates a chat's impressions, one category at a time: small models otherwise fold different topics of the
    /// same chat (an exam and a move) into one memory.
    private func consolidate(_ chatID: Chat.ID, of personaID: Persona.ID) async {
        guard let client, let library = thalamus[personaID] else { return }
        let impressions = library.entries.filter { $0.chatID == chatID }.sorted { $0.date < $1.date }
        guard !impressions.isEmpty else { return }
        // The model that is loaded anyway; loading another one just for this would take long.
        let chatModel = chat(chatID)?.modelId
        guard let model = loadedModels.first(where: { $0.id == chatModel })?.id ?? loadedModels.first?.id ?? preferredModelId else { return }

        // Questions to the persona itself carry nothing to remember; they are dropped without asking the model.
        let personaName = persona(personaID)?.displayName ?? ""
        let aboutConversation = impressions.filter { ThalamusConsolidator.isAboutConversation($0, personaName: personaName) }
        if !aboutConversation.isEmpty {
            let dropped = Set(aboutConversation.map(\.id))
            changeThalamus(of: personaID) { library in
                for entry in aboutConversation { library.noteActivity(entry.chatID, at: entry.date) }
                library.entries.removeAll { dropped.contains($0.id) }
                library.forgottenMessageIDs += aboutConversation.map(\.messageID)
            }
        }
        let content = impressions.filter { !ThalamusConsolidator.isAboutConversation($0, personaName: personaName) }
        let groups = Dictionary(grouping: content) { $0.category.lowercased() }.values.sorted { $0[0].date < $1[0].date }
        var outcome = ThalamusConsolidator.Outcome()
        var failure: String?
        for group in groups {
            guard let persona = persona(personaID), let current = thalamus[personaID] else { return }
            let job = ThalamusConsolidationJob(
                personaName: persona.displayName,
                chatID: chatID,
                impressions: group,
                memories: ThalamusConsolidator.candidates(for: group, chatID: chatID, in: current.memories ?? []),
                profile: (current.profile ?? []).sorted { $0.since < $1.since },
                categories: current.categories + ThalamusClassifier.suggestedCategories
            )
            do {
                let answer = try await client.complete(
                    model: model, messages: ThalamusConsolidator.requestMessages(for: job), temperature: 0.2, maxTokens: 3_000,
                    jsonSchema: (ThalamusConsolidator.schemaName, ThalamusConsolidator.schema)
                )
                try Task.checkCancellation()
                // New impressions may have come in meanwhile; only the consolidated ones are removed.
                guard var latest = thalamus[personaID], self.persona(personaID) != nil else { return }
                // Another run may have consolidated them in the meantime.
                guard group.allSatisfy({ impression in latest.entries.contains { $0.id == impression.id } }) else { continue }
                let result = try ThalamusConsolidator.apply(answer, job: job, to: &latest)
                thalamus[personaID] = latest
                PersonaStore.saveThalamus(latest, of: personaID)
                outcome.updated += result.updated
                outcome.created += result.created
                outcome.facts += result.facts
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
        if outcome.updated + outcome.created + outcome.facts > 0 {
            var parts: [String] = []
            if outcome.updated > 0 { parts.append(outcome.updated == 1 ? "1 Erinnerung ergänzt" : "\(outcome.updated) Erinnerungen ergänzt") }
            if outcome.created > 0 { parts.append(outcome.created == 1 ? "1 neue" : "\(outcome.created) neue") }
            if outcome.facts > 0 { parts.append(outcome.facts == 1 ? "1 Fakt fürs Profil" : "\(outcome.facts) Fakten fürs Profil") }
            thalamusNotes[personaID] = "Verdichtet: " + parts.joined(separator: ", ") + "."
        } else if let failure {
            thalamusNotes[personaID] = "Verdichten hat nicht geklappt: \(failure) Die Eindrücke bleiben und werden später erneut verdichtet."
        }
    }

    // MARK: Forgetting

    /// Deletes an impression before it is consolidated. Its message is not sorted again.
    func deleteThalamusImpression(_ id: ThalamusEntry.ID, of personaID: Persona.ID) {
        changeThalamus(of: personaID) { library in
            guard let entry = library.entries.first(where: { $0.id == id }) else { return }
            library.entries.removeAll { $0.id == id }
            library.forgottenMessageIDs.append(entry.messageID)
        }
    }

    func deleteThalamusMemory(_ id: ThalamusMemory.ID, of personaID: Persona.ID) {
        changeThalamus(of: personaID) { $0.memories?.removeAll { $0.id == id } }
    }

    func deleteThalamusFact(_ id: ThalamusFact.ID, of personaID: Persona.ID) {
        changeThalamus(of: personaID) { $0.profile?.removeAll { $0.id == id } }
    }

    /// Deletes memories, profile and waiting impressions of the persona.
    func deleteAllThalamus(of personaID: Persona.ID) {
        if thalamusConsolidation?.personaID == personaID { cancelThalamusConsolidation() }
        changeThalamus(of: personaID) { library in
            library.forgottenMessageIDs += library.entries.map(\.messageID)
            library.entries = []
            library.memories = []
            library.profile = []
        }
        thalamusNotes[personaID] = nil
    }

    private func changeThalamus(of personaID: Persona.ID, _ change: (inout ThalamusLibrary) -> Void) {
        guard var library = thalamus[personaID] else { return }
        change(&library)
        library.version = ThalamusLibrary.currentVersion
        thalamus[personaID] = library
        PersonaStore.saveThalamus(library, of: personaID)
    }
}
