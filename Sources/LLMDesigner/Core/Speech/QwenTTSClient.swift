import Foundation

enum SpeechEngine: String, CaseIterable, Identifiable {
    case system, qwenSmall, qwenLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "macOS-Stimme"
        case .qwenSmall: "Qwen TTS – klein (0.6B, schnell)"
        case .qwenLarge: "Qwen TTS – groß (1.7B, natürlicher)"
        }
    }

    var qwenModel: String? {
        switch self {
        case .system: nil
        case .qwenSmall: "qwen3-tts-small"
        case .qwenLarge: "qwen3-tts-large"
        }
    }
}

/// Client for the local Qwen TTS service (from the Auda project, OpenAI-compatible `/v1/audio/speech`).
struct QwenTTSClient: Sendable {
    static let defaultServer = "http://127.0.0.1:8790"

    struct Voice: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let gender: String
        let native: String
    }

    enum Failure: LocalizedError {
        case unreachable(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let url): "Der Qwen-TTS-Dienst ist nicht erreichbar (\(url))."
            case .server(let message): "Qwen TTS: \(message)"
            }
        }
    }

    /// Voices of the CustomVoice models, used until the service has answered.
    static let fallbackVoices: [Voice] = [
        Voice(id: "serena", name: "Serena", gender: "female", native: "zh"),
        Voice(id: "vivian", name: "Vivian", gender: "female", native: "zh"),
        Voice(id: "ono_anna", name: "Ono Anna", gender: "female", native: "ja"),
        Voice(id: "sohee", name: "Sohee", gender: "female", native: "ko"),
        Voice(id: "ryan", name: "Ryan", gender: "male", native: "en"),
        Voice(id: "aiden", name: "Aiden", gender: "male", native: "en"),
        Voice(id: "uncle_fu", name: "Uncle Fu", gender: "male", native: "zh"),
        Voice(id: "eric", name: "Eric", gender: "male", native: "zh"),
        Voice(id: "dylan", name: "Dylan", gender: "male", native: "zh"),
    ]

    var baseURL = URL(string: defaultServer)!

    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"), timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func voices() async throws -> [Voice] {
        struct Reply: Decodable { let voices: [Voice] }
        let request = URLRequest(url: baseURL.appending(path: "v1/audio/voices"), timeoutInterval: 3)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(Reply.self, from: data).voices
        } catch {
            throw Failure.unreachable(baseURL.absoluteString)
        }
    }

    /// WAV audio (24 kHz mono). The service caches results, so repeats are instant. `instructions` describe how
    /// the voice should sound, e.g. "ruhig und warm".
    func speech(text: String, model: String, voice: String, language: String, instructions: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "v1/audio/speech"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["model": model, "input": text, "voice": voice, "language": language, "response_format": "wav"]
        if let instructions { body["instructions"] = instructions }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable(baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure.server(message ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}
