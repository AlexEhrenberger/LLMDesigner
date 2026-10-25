import SwiftUI

/// A model that is being loaded again with another context length.
struct ContextReload: Equatable {
    let modelID: String
    let length: Int
}

/// How full a chat's context is, and with what.
struct ContextUsage {
    enum Kind: CaseIterable {
        case system, memory, tools, questions, answers, images
    }

    struct Part: Identifiable {
        let kind: Kind
        let label: String
        let tokens: Int
        var id: Kind { kind }
    }

    /// The chat's context length.
    let capacity: Int
    let parts: [Part]
    /// What the model is loaded with right now, if that differs from the chat's choice.
    let loadedLength: Int?
    /// The estimate was matched against the server's count for the last answer.
    let isCalibrated: Bool

    var used: Int { parts.map(\.tokens).reduce(0, +) }
    var free: Int { max(0, capacity - used) }
    var fraction: Double { capacity > 0 ? min(1, Double(used) / Double(capacity)) : 0 }
}

/// Memory and context length of a chat: chosen before the first message, fixed afterwards.
extension AppModel {
    /// Rough cost of a picture for a vision model; the server's count for the last answer corrects it.
    static let tokensPerImage = 260

    /// Once the chat has started, memory and context length can't change any more.
    var isChatSetupLocked: Bool { selectedChat != nil }

    var activeMemory: MemoryLevel {
        if let chat = selectedChat { return chat.memory ?? .off }
        return newChatMemory
    }

    /// The context length of the selected chat (nil for chats from before the setting), or of the new chat.
    var activeContextLength: Int? {
        if let chat = selectedChat { return chat.contextLength }
        return newChatContextLength
    }

    /// Kapitsa's context, set when it was started (`kapitsa serve --context …`); nil for LM Studio, where each chat
    /// chooses its own.
    var fixedContextLength: Int? {
        provider.loadsModels ? nil : currentModel?.loadedContextLength
    }

    /// What a new chat's memories may fill (see `contextLength(of:)`).
    var newChatBudget: Int {
        provider.loadsModels ? newChatContextLength : currentModel?.workingContextLength ?? 8_192
    }

    func chooseMemory(_ level: MemoryLevel) {
        guard !isChatSetupLocked else { return }
        newChatMemory = level
    }

    func chooseContextLength(_ length: Int) {
        guard !isChatSetupLocked else { return }
        newChatContextLength = length
    }

    /// Whether the selected model can be loaded with this context length.
    func modelAllows(contextLength length: Int) -> Bool {
        guard let maximum = currentModel?.maxContextLength else { return true }
        return length <= maximum
    }

    // MARK: Loading

    /// Loads the model with this context length unless an instance already has it. Takes a few seconds;
    /// meanwhile `contextReload` tells the UI.
    func loadModel(_ id: String, contextLength: Int) async throws {
        guard let client else { return }
        contextReload = ContextReload(modelID: id, length: contextLength)
        defer { contextReload = nil }
        let instances = try await client.loadedInstances(of: id)
        guard !instances.contains(where: { $0.contextLength == contextLength }) else { return }
        for instance in instances {
            try await client.unload(instanceID: instance.id)
        }
        try await client.load(model: id, contextLength: contextLength, flashAttention: instances.first?.flashAttention)
        await refreshModels()
    }

    // MARK: Usage

    /// What the next request of this chat will hold, estimated per part (about 3.5 characters per token) and,
    /// where possible, scaled to the prompt size the server reported for the last answer.
    func contextUsage(for chat: Chat) -> ContextUsage {
        let model = models.first { $0.id == modelId(for: chat) }
        let loaded = model?.loadedContextLength
        // Kapitsa holds its whole context for every chat, whatever the chat chose with LM Studio.
        let capacity = (provider.loadsModels ? chat.contextLength : nil) ?? loaded ?? 8_192
        let persona = persona(of: chat)
        func tokens(_ text: String) -> Int { SkillPrompt.estimatedTokens(text) }

        // The memories are part of the system prompt but shown on their own.
        let memory = memoryBlock(for: chat).map { tokens($0) + 1 } ?? 0
        let system = max(0, tokens(systemPrompt(for: chat)) - memory)
        var tools = 0
        if model?.acceptsTools ?? false {
            let sources = lookupSources(of: chat)
            let fileTools = persona.flatMap(PersonaFileTools.init(persona:))
            let definitions = WebTools.definitions(for: sources) + (fileTools?.definitions ?? [])
            // JSON splits into more tokens than prose.
            if !definitions.isEmpty, let json = try? JSONEncoder().encode(definitions) { tools += json.count / 3 }
            if !sources.isEmpty { tools += tokens(WebTools.systemHint(for: sources)) }
            if let fileTools { tools += tokens(fileTools.systemHint) }
        }

        // Each message also costs a few tokens of chat-template markup.
        func cost(of message: ChatMessage) -> (text: Int, images: Int) {
            (tokens(WebTools.historyContent(of: message)) + 4, (message.images?.count ?? 0) * Self.tokensPerImage)
        }
        let messages = chat.messages.filter { $0.error == nil && $0.hasContent }
        var questions = 0, answers = 0, images = 0, imageCount = 0
        for message in messages {
            let (text, pictures) = cost(of: message)
            if message.role == .user { questions += text } else { answers += text }
            images += pictures
            imageCount += message.images?.count ?? 0
        }

        // The server counted the prompt of the latest answer exactly; that prompt held everything before it.
        // Answers that looked things up don't count: their prompt also held the search results.
        var scale = 1.0
        var isCalibrated = false
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.stats?.promptTokens != nil && ($0.toolSteps ?? []).isEmpty }),
           let prompt = messages[index].stats?.promptTokens {
            let before = messages[..<index].map { cost(of: $0) }.reduce(0) { $0 + $1.text + $1.images }
            let estimate = system + memory + tools + before
            if estimate > 0 {
                scale = min(1.8, max(0.6, Double(prompt) / Double(estimate)))
                isCalibrated = true
            }
        }

        let name = persona?.displayName
        let candidates: [(ContextUsage.Kind, String, Int)] = [
            (.system, name.map { "Persona (\($0))" } ?? (skills(of: chat).isEmpty ? "System-Prompt" : "System-Prompt & Skills"), system),
            (.memory, "Erinnerungen", memory),
            (.tools, "Werkzeuge & Hinweise", tools),
            (.questions, "Deine Nachrichten", questions),
            (.answers, name.map { "Antworten von \($0)" } ?? "Antworten", answers),
            (.images, imageCount == 1 ? "1 Bild" : "\(imageCount) Bilder", images),
        ]
        let parts = candidates.compactMap { kind, label, value -> ContextUsage.Part? in
            value > 0 ? ContextUsage.Part(kind: kind, label: label, tokens: Int((Double(value) * scale).rounded())) : nil
        }
        return ContextUsage(
            capacity: capacity,
            parts: parts,
            // Kapitsa isn't reloaded: its context is the one it was started with.
            loadedLength: provider.loadsModels ? loaded.flatMap { $0 == capacity ? nil : $0 } : nil,
            isCalibrated: isCalibrated
        )
    }
}
