import AppKit

/// How a picture is (or will be) made with Draw Things. It is stored next to the picture
/// (`Bilder/gen-….png` → `Bilder/gen-….json`), so the picture can be made again or changed later.
struct GeneratedImageInfo: Codable, Equatable, Sendable {
    /// What the user wants to see, in their words.
    var description: String = ""
    /// The English prompt for Qwen-Image.
    var prompt: String = ""
    var style: ImageStyle = .automatic
    var format: ImageFormat = .landscape32
    var resolution: ImageResolution = .standard
    var profile: DrawThingsProfile = .qwenLightning
    /// Adds "Ultra HD, 4K, cinematic composition." as the Qwen model card recommends.
    var qualitySuffix = true
    /// What the picture must not show, e.g. writing on a slide background; nil sends Draw Things none.
    var negativePrompt: String?
    /// The seed of the finished picture.
    var seed: UInt32?
    /// The picture this one replaces; it shows (dimmed) while the new one is made.
    var previous: String?
    /// The model Draw Things had selected when `profile` is `.app`, else the preset's.
    var model: String?
    var created: Date?
    /// Seconds the picture took.
    var duration: Double?
}

extension WriterImageStore {
    /// "Bilder/gen-1.png" → "Bilder/gen-1.json".
    static func infoVariant(of source: String) -> String {
        (source as NSString).deletingPathExtension + ".json"
    }

    /// A new, unused place for a generated picture.
    static func newGeneratedSource() -> String {
        _ = directory
        return folderName + "/gen-" + UUID().uuidString.prefix(13).lowercased() + ".png"
    }

    static func generationInfo(for source: String) -> GeneratedImageInfo? {
        if let cached = infos[source] { return cached }
        guard let url = targetURL(for: infoVariant(of: source)), let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder.iso.decode(GeneratedImageInfo.self, from: data) else { return nil }
        infos[source] = info
        return info
    }

    static func saveGenerationInfo(_ info: GeneratedImageInfo, for source: String) {
        infos[source] = info
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info), let url = targetURL(for: infoVariant(of: source)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated(unsafe) private static var infos: [String: GeneratedImageInfo] = [:]
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Makes pictures with Draw Things, one after the other, in the background: the document shows a placeholder
/// with the progress meanwhile, and the picture appears in its place when it is done.
@MainActor
@Observable
final class ImageGenerationCenter {
    enum Phase: Equatable, Sendable {
        case queued
        case running(started: Date)
        case failed(String)
    }

    /// Sent with the picture's source as `object` whenever its phase changes or it is done.
    static let didChange = Notification.Name("ImageGenerationCenter.didChange")

    /// The phases by source, readable while drawing.
    nonisolated(unsafe) private(set) static var phases: [String: Phase] = [:]

    private(set) var phases: [String: Phase] = [:] {
        didSet { Self.phases = phases }
    }

    private struct Job {
        var source: String
        var url: URL
        var info: GeneratedImageInfo
    }

    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    private var current: Job?
    @ObservationIgnored private let settings: LibrarySettings

    init(settings: LibrarySettings) {
        self.settings = settings
        Self.phases = [:]
    }

    // MARK: Settings (in the library)

    private enum Keys {
        static let address = "drawThingsAddress"
        static let defaults = "drawThingsDefaults"
    }

    var address: String {
        get { settings.string(forKey: Keys.address) ?? DrawThingsClient.defaultAddress }
        set { settings.set(newValue == DrawThingsClient.defaultAddress ? nil : newValue, forKey: Keys.address) }
    }

    /// The choices of the last picture (format, style, profile, …), for the next one.
    var defaults: GeneratedImageInfo {
        get {
            guard let data = settings.object(forKey: Keys.defaults) as? Data,
                  let info = try? JSONDecoder().decode(GeneratedImageInfo.self, from: data) else { return GeneratedImageInfo() }
            return GeneratedImageInfo(style: info.style, format: info.format, resolution: info.resolution, profile: info.profile, qualitySuffix: info.qualitySuffix)
        }
        set {
            let kept = GeneratedImageInfo(style: newValue.style, format: newValue.format, resolution: newValue.resolution, profile: newValue.profile, qualitySuffix: newValue.qualitySuffix)
            settings.set(try? JSONEncoder().encode(kept), forKey: Keys.defaults)
        }
    }

    var client: DrawThingsClient? { DrawThingsClient(address: address) }

    // MARK: Jobs

    func phase(for source: String) -> Phase? { phases[source] }

    /// Makes the picture at `source` (a file that doesn't exist yet) from `info`.
    func generate(source: String, info: GeneratedImageInfo) {
        // A source outside the picture folder gets no picture: Draw Things would write it anywhere.
        guard let url = WriterImageStore.targetURL(for: source) else { return }
        cancel(source)
        var info = info
        if info.seed == nil { info.seed = UInt32.random(in: 1...UInt32.max) }
        WriterImageStore.saveGenerationInfo(info, for: source)
        queue.append(Job(source: source, url: url, info: info))
        phases[source] = .queued
        notify(source)
        startWorker()
    }

    /// Drops a waiting job; a running one finishes in Draw Things, but its picture is thrown away.
    func cancel(_ source: String) {
        queue.removeAll { $0.source == source }
        if current?.source == source { current = nil }
        if phases.removeValue(forKey: source) != nil { notify(source) }
    }

    func cancelAll() {
        let sources = Array(phases.keys)
        queue.removeAll()
        current = nil
        worker?.cancel()
        worker = nil
        phases = [:]
        sources.forEach(notify)
    }

    /// Where in the queue a waiting picture is (1 = next).
    func position(of source: String) -> Int? {
        queue.firstIndex { $0.source == source }.map { $0 + 1 }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                await self.run(job)
            }
            self?.worker = nil
        }
    }

    private func run(_ job: Job) async {
        guard let client else {
            phases[job.source] = .failed("Die Adresse von Draw Things ist ungültig.")
            notify(job.source)
            return
        }
        current = job
        let started = Date()
        phases[job.source] = .running(started: started)
        notify(job.source)
        let info = job.info
        let size = info.format.size(info.resolution)
        do {
            let status = try? await client.status()
            let data = try await client.generate(
                prompt: ImagePromptBuilder.finalPrompt(info.prompt, qualitySuffix: info.qualitySuffix),
                negativePrompt: info.negativePrompt ?? (info.profile == .qwenFull ? " " : ""),
                width: size.width, height: size.height, seed: info.seed ?? 1, profile: info.profile
            )
            // Cancelled meanwhile: the picture is not wanted any more.
            guard current?.source == job.source else { return }
            try data.write(to: job.url, options: .atomic)
            var finished = info
            finished.created = Date()
            finished.duration = Date().timeIntervalSince(started)
            finished.model = info.profile == .app ? status?.model : DrawThingsProfile.qwenModel
            WriterImageStore.saveGenerationInfo(finished, for: job.source)
            phases[job.source] = nil
        } catch {
            guard current?.source == job.source else { return }
            phases[job.source] = .failed(error.localizedDescription)
        }
        current = nil
        notify(job.source)
    }

    private func notify(_ source: String) {
        NotificationCenter.default.post(name: Self.didChange, object: source)
    }
}
