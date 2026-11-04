import Foundation
import LLMDProtocol

/// Where the language models run.
enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    /// LM Studio: many models, loaded on request and with a chosen context length.
    case lmStudio
    /// Kapitsa: runs Qwen 3.5 on Apple silicon especially fast, but only the one model it was started with
    /// (`kapitsa serve --model …`) and with the context it was started with.
    case kapitsa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .kapitsa: "Kapitsa"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .lmStudio: "http://127.0.0.1:1234"
        case .kapitsa: "http://127.0.0.1:8000"
        }
    }

    /// LM Studio loads a model on request and reloads it with another context length; Kapitsa can't.
    var loadsModels: Bool { self == .lmStudio }

    /// Kapitsa switches Qwen's thinking per request (`enable_thinking`); LM Studio ignores the switch.
    var switchesThinking: Bool { self == .kapitsa }
}

struct LMModel: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    var type: String?
    var publisher: String?
    var arch: String?
    var compatibilityType: String?
    var quantization: String?
    var state: String?
    var maxContextLength: Int?
    var loadedContextLength: Int?
    var capabilities: [String]?
    /// Set for Kapitsa (see `workingContextLength`).
    var contextBudget: Int?

    /// Kapitsa holds 120K or more per conversation, but on a 16 GB Mac it reads a long prompt at only about 150 tokens
    /// per second; what the app fills in by itself stays within this, as with LM Studio.
    static let kapitsaContextBudget = 32_768

    /// Servers without LM Studio's REST API don't report a state; treat their models as ready.
    var isLoaded: Bool { state == nil || state == "loaded" }
    var isChatCapable: Bool { type != "embeddings" }
    var isVision: Bool { type == "vlm" }
    var supportsTools: Bool { capabilities?.contains("tool_use") ?? false }
    /// Whether to offer tools such as the web search: LM Studio reports support per model,
    /// other servers don't say, so the app tries.
    var acceptsTools: Bool { supportsTools || state == nil }
    /// Gemma 4 only thinks when the system prompt starts with its `<|think|>` token. LM Studio doesn't pass
    /// `enable_thinking` through to the chat template, so the app sets the token itself.
    var thinksOnThinkToken: Bool {
        arch == "gemma4" || id.lowercased().contains("gemma-4") || id.lowercased().contains("gemma4")
    }
    var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }
    /// What the app fills in by itself (search results, memories, document excerpts, prompt warnings): the loaded
    /// context, or the smaller budget where reading the whole of it would take minutes.
    var workingContextLength: Int? {
        guard let loadedContextLength else { return contextBudget }
        return min(loadedContextLength, contextBudget ?? loadedContextLength)
    }

    static func formatTokens(_ count: Int) -> String {
        count >= 1024 ? "\(count / 1024)K" : "\(count)"
    }
}

struct ChatPayloadMessage: Encodable, Sendable {
    let role: String
    let content: String
    /// Pictures as `data:` URLs (role "user"). With pictures, `content` is sent as a list of parts.
    var images: [String]? = nil
    /// Functions the assistant called in this turn (role "assistant").
    var toolCalls: [ToolCall]? = nil
    /// The call this message answers (role "tool").
    var toolCallID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    /// One entry of a multi-part `content`, in the OpenAI format.
    private struct Part: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type: String
        var text: String? = nil
        var image_url: ImageURL? = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let images, !images.isEmpty {
            var parts = images.map { Part(type: "image_url", image_url: .init(url: $0)) }
            if !content.isEmpty { parts.append(Part(type: "text", text: content)) }
            try container.encode(parts, forKey: .content)
        } else {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

/// A function call the model asked for, in the OpenAI format. `arguments` is a JSON string.
struct ToolCall: Codable, Hashable, Sendable {
    struct Function: Codable, Hashable, Sendable {
        var name: String
        var arguments: String
    }
    var id: String
    var type = "function"
    var function: Function
}

/// A function the model may call, described in the OpenAI `tools` format.
struct ToolDefinition: Encodable, Sendable {
    struct Parameter: Encodable, Sendable {
        let type: String
        let description: String
    }
    struct Parameters: Encodable, Sendable {
        let type = "object"
        let properties: [String: Parameter]
        let required: [String]
    }
    /// The fixed kind above, or a whole JSON schema, as the actions have.
    enum Schema: Encodable, Sendable {
        case simple(Parameters)
        case json(JSONValue)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .simple(let parameters): try container.encode(parameters)
            case .json(let schema): try container.encode(schema)
            }
        }
    }
    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: Schema
    }
    let type = "function"
    let function: Function

    /// Without `required`, every parameter is required.
    init(name: String, description: String, parameters: [String: Parameter], required: [String]? = nil) {
        function = Function(
            name: name,
            description: description,
            parameters: .simple(Parameters(properties: parameters, required: required ?? parameters.keys.sorted()))
        )
    }

    init(name: String, description: String, schema: JSONValue) {
        function = Function(name: name, description: description, parameters: .json(schema))
    }
}

enum StreamEvent: Sendable {
    case content(String)
    case reasoning(String)
    case usage(prompt: Int?, completion: Int?)
    /// The model that actually answered; LM Studio may silently fall back to a loaded one.
    case model(String)
    /// Functions the model wants to call; sent once, after the last chunk.
    case toolCalls([ToolCall])
}

enum LLMError: LocalizedError {
    case invalidEndpoint(String)
    case http(LLMProvider, Int, String?)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Ungültiger Endpoint: \(value)"
        case .http(let provider, let status, let message):
            return message.map { "\(provider.label) (\(status)): \($0)" } ?? "\(provider.label) antwortet mit Status \(status)."
        case .server(let message):
            return message
        }
    }
}

/// Talks to the local model server: LM Studio's REST API for model state, Kapitsa's model list, and the
/// OpenAI-compatible endpoint both offer for streaming chat completions.
struct LLMClient: Sendable {
    let provider: LLMProvider
    let baseURL: URL
    let apiKey: String?

    init(provider: LLMProvider, endpoint: String, apiKey: String?) throws {
        self.provider = provider
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        guard let url = URL(string: value), url.host != nil else {
            throw LLMError.invalidEndpoint(endpoint)
        }
        baseURL = url
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
    }

    var hostDescription: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    func fetchModels() async throws -> [LMModel] {
        if provider == .kapitsa { return try await fetchKapitsaModels() }
        do {
            return try await fetchModelList(path: "api/v0/models")
        } catch LLMError.http(_, let status, _) where status == 404 {
            // Plain OpenAI-compatible servers only offer /v1/models.
            return try await fetchModelList(path: "v1/models")
        }
    }

    /// Kapitsa's switch for Qwen's thinking; nil for LM Studio, which ignores it.
    private struct TemplateOptions: Encodable {
        let enable_thinking: Bool
    }

    private func templateOptions(thinking: Bool) -> TemplateOptions? {
        provider.switchesThinking ? TemplateOptions(enable_thinking: thinking) : nil
    }

    /// `thinking` switches the model's thinking where the server allows it (Kapitsa); Qwen thinks there unless told not to.
    func streamChat(
        model: String,
        messages: [ChatPayloadMessage],
        temperature: Double?,
        tools: [ToolDefinition]? = nil,
        thinking: Bool = false
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        struct StreamOptions: Encodable { let include_usage = true }
        struct Body: Encodable {
            let model: String
            let messages: [ChatPayloadMessage]
            let temperature: Double?
            let tools: [ToolDefinition]?
            let chat_template_kwargs: TemplateOptions?
            let stream = true
            let stream_options = StreamOptions()
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(Body(
                        model: model, messages: messages, temperature: temperature, tools: tools,
                        chat_template_kwargs: templateOptions(thinking: thinking)
                    ))
                    // Long idle timeout: LM Studio may load the model just-in-time before the first token.
                    let request = makeRequest("v1/chat/completions", method: "POST", body: body, timeout: 600)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 64_000 { break }
                        }
                        throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
                    }

                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    var reportedModel = false
                    // Tool calls arrive in pieces: the name first, then the arguments in fragments.
                    var pendingCalls: [Int: (id: String?, name: String, arguments: String)] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(StreamChunk.self, from: data) else { continue }

                        if let error = chunk.error { throw LLMError.server(error.message) }
                        if !reportedModel, let answering = chunk.model {
                            reportedModel = true
                            continuation.yield(.model(answering))
                        }
                        for choice in chunk.choices ?? [] {
                            if let reasoning = choice.delta?.reasoningContent ?? choice.delta?.reasoning, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = choice.delta?.content, !content.isEmpty {
                                continuation.yield(.content(content))
                            }
                            for call in choice.delta?.toolCalls ?? [] {
                                let index = call.index ?? 0
                                var pending = pendingCalls[index] ?? (nil, "", "")
                                if let id = call.id, !id.isEmpty { pending.id = id }
                                if pending.name.isEmpty { pending.name = call.function?.name ?? "" }
                                pending.arguments += call.function?.arguments ?? ""
                                pendingCalls[index] = pending
                            }
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens))
                        }
                    }
                    if !pendingCalls.isEmpty {
                        let calls = pendingCalls.sorted { $0.key < $1.key }.map { index, call in
                            ToolCall(id: call.id ?? "call_\(index)", function: .init(name: call.name, arguments: call.arguments))
                        }
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Single, non-streamed completion, without thinking where the server can switch it off. With `jsonSchema`,
    /// the server constrains the answer to that schema.
    func complete(
        model: String,
        messages: [ChatPayloadMessage],
        temperature: Double,
        maxTokens: Int,
        jsonSchema: (name: String, schema: [String: Any])? = nil,
        orderedSchema: (name: String, json: String)? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if provider.switchesThinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        // A schema given as JSON text keeps the order of its properties, which the model then writes in.
        let placeholder = "__ordered_schema__"
        if let schema = jsonSchema.map({ ($0.name, $0.schema as Any) }) ?? orderedSchema.map({ ($0.name, placeholder as Any) }) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.0, "strict": true, "schema": schema.1],
            ]
        }
        var requestBody = try JSONSerialization.data(withJSONObject: body)
        if jsonSchema == nil, let orderedSchema, let text = String(data: requestBody, encoding: .utf8) {
            requestBody = Data(text.replacingOccurrences(of: "\"\(placeholder)\"", with: orderedSchema.json).utf8)
        }
        let request = makeRequest("v1/chat/completions", method: "POST", body: requestBody, timeout: 300)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
        }

        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content,
              !content.isEmpty else {
            throw LLMError.server("\(provider.label) hat eine leere Antwort geliefert.")
        }
        return content
    }

    // MARK: - Loading with a context length

    /// A loaded copy of a model, as LM Studio's REST API reports it.
    struct LoadedInstance: Sendable {
        let id: String
        let contextLength: Int?
        let flashAttention: Bool?
    }

    /// The loaded instances of a model (usually one).
    func loadedInstances(of model: String) async throws -> [LoadedInstance] {
        struct Reply: Decodable {
            struct Model: Decodable {
                struct Instance: Decodable {
                    struct Config: Decodable {
                        let contextLength: Int?
                        let flashAttention: Bool?
                    }
                    let id: String
                    let config: Config?
                }
                let key: String
                let loadedInstances: [Instance]?
            }
            let models: [Model]
        }
        let (data, response) = try await URLSession.shared.data(for: makeRequest("api/v1/models", timeout: 5))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let instances = try decoder.decode(Reply.self, from: data).models.first { $0.key == model }?.loadedInstances ?? []
        return instances.map { LoadedInstance(id: $0.id, contextLength: $0.config?.contextLength, flashAttention: $0.config?.flashAttention) }
    }

    func unload(instanceID: String) async throws {
        try await post("api/v1/models/unload", ["instance_id": instanceID], timeout: 30)
    }

    /// Loads a model with this context length; LM Studio's other settings for the model stay as they are.
    func load(model: String, contextLength: Int, flashAttention: Bool?) async throws {
        var body: [String: Any] = ["model": model, "context_length": contextLength]
        if let flashAttention { body["flash_attention"] = flashAttention }
        try await post("api/v1/models/load", body, timeout: 300)
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws {
        let request = makeRequest(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body), timeout: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
        }
    }

    // MARK: - Kapitsa

    /// Kapitsa lists its whole catalog; only the active model answers (requests naming another one are ignored unless the
    /// server runs with `--allow-switch`, and then it may download gigabytes), so the others are left out.
    private func fetchKapitsaModels() async throws -> [LMModel] {
        struct Entry: Decodable {
            let id: String
            let displayName: String?
            let contextLength: Int?
            let active: Bool?
            let quant: String?
        }
        struct ListResponse: Decodable { let data: [Entry] }
        let (data, response) = try await URLSession.shared.data(for: makeRequest("v1/models", timeout: 5))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ListResponse.self, from: data).data.filter { $0.active == true }.map { entry in
            // "qwen3.5-9b:4bit" names the precision after the colon; the long description ("MLX affine 4-bit, group 64")
            // is the fallback.
            let variant = entry.displayName?.split(separator: ":").dropFirst().first.map(String.init)
            let lowercased = entry.id.lowercased()
            return LMModel(
                id: entry.id,
                // Kapitsa's Qwen 3.5 models read pictures (its log says "images on"); the text-only Nemotrons don't.
                type: lowercased.contains("qwen") || lowercased.contains("-vl") ? "vlm" : "llm",
                compatibilityType: "mlx",
                quantization: variant ?? entry.quant,
                state: "loaded",
                maxContextLength: entry.contextLength,
                loadedContextLength: entry.contextLength,
                capabilities: ["tool_use"],
                contextBudget: LMModel.kapitsaContextBudget
            )
        }
    }

    // MARK: - Private

    private func fetchModelList(path: String) async throws -> [LMModel] {
        struct ListResponse: Decodable { let data: [LMModel] }
        let (data, response) = try await URLSession.shared.data(for: makeRequest(path, timeout: 5))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(provider, http.statusCode, Self.errorMessage(from: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ListResponse.self, from: data).data
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func errorMessage(from data: Data) -> String? {
        struct Envelope: Decodable { let error: FlexibleError }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.error.message
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let reasoning: String?
            let toolCalls: [ToolCallDelta]?
        }
        struct ToolCallDelta: Decodable {
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
            let index: Int?
            let id: String?
            let function: Function?
        }
        let delta: Delta?
    }
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
    }
    let model: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: FlexibleError?
}

/// Servers report errors either as a plain string or as `{ "message": … }`.
private struct FlexibleError: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            message = text
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = (try? container.decode(String.self, forKey: .message)) ?? "Unbekannter Fehler"
        }
    }
}
