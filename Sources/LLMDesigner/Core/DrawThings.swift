import Foundation

/// The picture's proportions. Sizes are multiples of 64, as Draw Things wants them, close to Qwen-Image's own
/// training sizes (1328², 1664×928, 1472×1140, …) in the high resolution and around one megapixel in the standard one.
enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case square = "1:1"
    case landscape43 = "4:3"
    case landscape32 = "3:2"
    case wide = "16:9"
    case portrait34 = "3:4"
    case portrait23 = "2:3"
    case tall = "9:16"

    var label: String { rawValue }

    var orientation: String {
        switch self {
        case .square: "quadratisch"
        case .landscape43, .landscape32, .wide: "Querformat"
        case .portrait34, .portrait23, .tall: "Hochformat"
        }
    }

    /// Width / height.
    var aspect: Double {
        let size = size(.standard)
        return Double(size.width) / Double(size.height)
    }

    func size(_ resolution: ImageResolution) -> (width: Int, height: Int) {
        let landscape: (Int, Int)
        switch (self, resolution) {
        case (.square, .standard), (.square, .preview): landscape = (1024, 1024)
        case (.square, .high): landscape = (1344, 1344)
        case (.landscape43, .standard), (.portrait34, .standard), (.landscape43, .preview), (.portrait34, .preview): landscape = (1152, 896)
        case (.landscape43, .high), (.portrait34, .high): landscape = (1472, 1088)
        case (.landscape32, .standard), (.portrait23, .standard), (.landscape32, .preview), (.portrait23, .preview): landscape = (1216, 832)
        case (.landscape32, .high), (.portrait23, .high): landscape = (1536, 1024)
        case (.wide, .standard), (.tall, .standard), (.wide, .preview), (.tall, .preview): landscape = (1344, 768)
        case (.wide, .high), (.tall, .high): landscape = (1664, 960)
        }
        var size = [.portrait34, .portrait23, .tall].contains(self) ? (landscape.1, landscape.0) : landscape
        if resolution == .preview {
            size = ((size.0 * 2 / 3) / 64 * 64, (size.1 * 2 / 3) / 64 * 64)
        }
        return size
    }
}

enum ImageResolution: String, CaseIterable, Codable, Sendable {
    /// Quick, for trying a prompt.
    case preview
    /// About one megapixel.
    case standard
    /// Qwen-Image's own size, about 1.7 megapixels.
    case high

    var label: String {
        switch self {
        case .preview: "Entwurf (klein, schnell)"
        case .standard: "Standard (ca. 1 MP)"
        case .high: "Hoch (Qwen-Originalgröße, ca. 1,7 MP)"
        }
    }
}

/// What Draw Things is told about the model. The presets pin model, LoRA, steps and guidance, so the picture
/// doesn't depend on whatever is set in the app; `.app` sends only prompt, size and seed.
enum DrawThingsProfile: String, CaseIterable, Codable, Sendable {
    case qwenLightning
    case qwenFull
    case app

    var label: String {
        switch self {
        case .qwenLightning: "Qwen Image 1.0 · Lightning (4 Schritte)"
        case .qwenFull: "Qwen Image 1.0 · volle Qualität (langsam)"
        case .app: "Wie in Draw Things eingestellt"
        }
    }

    static let qwenModel = "qwen_image_1.0_q6p.ckpt"
    static let qwenLightningLoRA = "qwen_image_1.0_lightning_4_step_v2.0_lora_f16.ckpt"

    func parameters() -> [String: Any] {
        let common: [String: Any] = [
            "batch_count": 1, "batch_size": 1, "strength": 1.0, "hires_fix": false,
            "upscaler": NSNull(), "refiner_model": NSNull(),
        ]
        switch self {
        case .qwenLightning:
            return common.merging([
                "model": Self.qwenModel,
                "loras": [["file": Self.qwenLightningLoRA, "weight": 1.0, "mode": "all"]],
                "steps": 4, "guidance_scale": 1.0, "sampler": "UniPC Trailing",
            ]) { $1 }
        case .qwenFull:
            return common.merging([
                "model": Self.qwenModel, "loras": [] as [Any],
                "steps": 30, "guidance_scale": 4.0, "sampler": "UniPC Trailing",
            ]) { $1 }
        case .app:
            return ["batch_count": 1, "batch_size": 1]
        }
    }
}

enum DrawThingsError: LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case noImage

    var errorDescription: String? {
        switch self {
        case .unreachable(let address):
            "Draw Things antwortet nicht unter \(address). In Draw Things unter Einstellungen → „API-Server“ den HTTP-Server einschalten (Port 7860)."
        case .http(let status, let message):
            "Draw Things meldet einen Fehler (\(status))" + (message.isEmpty ? "." : ": \(message)")
        case .noImage:
            "Draw Things hat kein Bild geliefert."
        }
    }
}

/// Draw Things' local HTTP API (Automatic1111-compatible): `GET /` returns the app's current settings,
/// `POST /sdapi/v1/txt2img` makes a picture and returns it as base64 PNG.
struct DrawThingsClient: Sendable {
    static let defaultAddress = "http://127.0.0.1:7860"

    let baseURL: URL

    init?(address: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Self.defaultAddress }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        baseURL = url
    }

    struct Status: Sendable {
        /// The model selected in the app, e.g. "qwen_image_1.0_q6p.ckpt".
        var model: String?
        var steps: Int?
    }

    func status() async throws -> Status {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DrawThingsError.unreachable(baseURL.absoluteString)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return Status(model: json?["model"] as? String, steps: json?["steps"] as? Int)
        } catch let error as DrawThingsError {
            throw error
        } catch {
            throw DrawThingsError.unreachable(baseURL.absoluteString)
        }
    }

    /// Makes one picture; generation takes from half a minute to several minutes.
    func generate(prompt: String, negativePrompt: String, width: Int, height: Int, seed: UInt32, profile: DrawThingsProfile) async throws -> Data {
        var body = profile.parameters()
        body["prompt"] = prompt
        body["negative_prompt"] = negativePrompt
        body["width"] = width
        body["height"] = height
        body["seed"] = Int(seed)
        var request = URLRequest(url: baseURL.appendingPathComponent("sdapi/v1/txt2img"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .networkConnectionLost {
            throw DrawThingsError.unreachable(baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw DrawThingsError.noImage }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw DrawThingsError.http(http.statusCode, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        struct Reply: Decodable { let images: [String]? }
        guard var encoded = try JSONDecoder().decode(Reply.self, from: data).images?.first else { throw DrawThingsError.noImage }
        if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") { encoded = String(encoded[encoded.index(after: comma)...]) }
        guard let image = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !image.isEmpty else { throw DrawThingsError.noImage }
        return image
    }
}
