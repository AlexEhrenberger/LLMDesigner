import AVFoundation
import Foundation
import Speech

/// Dictation state as the UI sees it (independent of the macOS 26 types).
enum DictationStatus: Equatable {
    case idle
    case preparing(progress: Double?)
    case listening
    case finishing
}

enum DictationMode: String, CaseIterable, Identifiable {
    case accurate, fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accurate: "Genau – Text erscheint satzweise"
        case .fast: "Schnell – Wörter erscheinen sofort"
        }
    }
}

/// On-device dictation with the macOS 26 SpeechAnalyzer API (adapted from Auda). `SpeechTranscriber` is the
/// long-form model with the better recognition; `DictationTranscriber` reports words right away.
@available(macOS 26.0, *)
@MainActor
final class DictationEngine {
    enum Failure: LocalizedError {
        case microphoneDenied, noMicrophone, unsupportedLocale(String), noAudioFormat

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Kein Zugriff auf das Mikrofon. Erlaube LLM Designer den Zugriff unter Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon."
            case .noMicrophone:
                "Es wurde kein Mikrofon gefunden."
            case .unsupportedLocale(let name):
                "Die Spracherkennung unterstützt „\(name)“ nicht."
            case .noAudioFormat:
                "Die Spracherkennung konnte nicht gestartet werden."
            }
        }
    }

    var onStatus: ((DictationStatus) -> Void)?
    /// Text that is still being recognised and may change.
    var onVolatile: ((String) -> Void)?
    /// Text the model has settled on.
    var onFinal: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var status: DictationStatus = .idle
    private var session = 0
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var progressObservation: NSKeyValueObservation?

    var isRunning: Bool {
        switch status {
        case .preparing, .listening: true
        default: false
        }
    }

    func start(mode: DictationMode) async {
        if isRunning || status == .finishing { await stop() }
        session += 1
        let current = session
        report(.preparing(progress: nil))

        do {
            guard await requestMicrophoneAccess() else { throw Failure.microphoneDenied }
            guard current == session else { return }

            let (module, locale) = try await makeModule(mode: mode)
            try await installAssets(for: module, locale: locale)
            guard current == session else { return }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw Failure.noAudioFormat
            }
            // The microphone starts before the model is ready; the stream buffers the first words.
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = continuation
            try startAudio(into: continuation, format: format)
            report(.listening)

            let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
            self.analyzer = analyzer
            consumeResults(of: module)
            try await analyzer.prepareToAnalyze(in: format)
            guard current == session else { return await teardown() }
            try await analyzer.start(inputSequence: stream)
            guard current == session else { return await teardown() }
        } catch {
            guard current == session else { return }
            await teardown()
            onError?(error.localizedDescription)
            report(.idle)
        }
    }

    /// Stops listening and waits until the last words have been delivered.
    func stop() async {
        guard status != .idle else { return }
        session += 1
        report(.finishing)
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        await teardown()
        report(.idle)
    }

    // MARK: - Setup

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeModule(mode: DictationMode) async throws -> (any SpeechModule, Locale) {
        let wanted = Locale.current
        if mode == .fast, let module = await dictationTranscriber(for: wanted, fast: true) {
            return module
        }
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            return (module, locale)
        }
        if let module = await dictationTranscriber(for: wanted, fast: false) { return module }
        throw Failure.unsupportedLocale(Locale.current.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)
    }

    private func dictationTranscriber(for wanted: Locale, fast: Bool) async -> (any SpeechModule, Locale)? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) else { return nil }
        let module = fast
            ? DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
            )
            : DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        return (module, locale)
    }

    private func installAssets(for module: any SpeechModule, locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }) {
            if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
                await AssetInventory.release(reservedLocale: oldest)
            }
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        report(.preparing(progress: 0))
        progressObservation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, case .preparing = self.status else { return }
                self.report(.preparing(progress: fraction))
            }
        }
        defer {
            progressObservation?.invalidate()
            progressObservation = nil
        }
        try await request.downloadAndInstall()
    }

    private func consumeResults(of module: any SpeechModule) {
        if let transcriber = module as? SpeechTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.deliver(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    self?.resultsFailed(error)
                }
            }
        } else if let transcriber = module as? DictationTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.deliver(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    self?.resultsFailed(error)
                }
            }
        }
    }

    private func deliver(_ text: String, isFinal: Bool) {
        if isFinal {
            onVolatile?("")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onFinal?(text) }
        } else {
            onVolatile?(text)
        }
    }

    private func resultsFailed(_ error: Error) {
        guard isRunning else { return }
        onError?(error.localizedDescription)
        Task { await stop() }
    }

    // MARK: - Audio

    private func startAudio(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw Failure.noMicrophone }
        guard let pipe = AudioPipe(from: inputFormat, to: format, continuation: continuation, level: { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }) else { throw Failure.noAudioFormat }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            pipe.process(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopAudio() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    private func teardown() async {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func report(_ newStatus: DictationStatus) {
        status = newStatus
        onStatus?(newStatus)
    }
}

/// Converts microphone buffers to the analyzer format on the audio thread and reports the input level.
@available(macOS 26.0, *)
private final class AudioPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let level: @Sendable (Float) -> Void
    private var lastLevelReport: UInt64 = 0

    init?(from source: AVAudioFormat, to target: AVAudioFormat,
          continuation: AsyncStream<AnalyzerInput>.Continuation,
          level: @escaping @Sendable (Float) -> Void) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        converter.downmix = source.channelCount != target.channelCount
        self.converter = converter
        self.target = target
        self.continuation = continuation
        self.level = level
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        reportLevel(buffer)
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelReport > 70_000_000, let samples = buffer.floatChannelData?[0] else { return }
        lastLevelReport = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        level(min(1, max(0, (db + 55) / 45)))
    }
}
