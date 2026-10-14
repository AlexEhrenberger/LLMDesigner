import AVFoundation

/// Speaks an answer while it is still being written (conversation mode). Pieces of text are queued as they arrive,
/// synthesised one after the other with Qwen TTS or a macOS voice, and played through one audio engine, so the next
/// piece is generated while the current one plays. Their loudness goes into `levels`, which drives the wave.
@MainActor
final class ConversationVoice {
    /// The first sound of the answer is about to play.
    var onStart: (() -> Void)?
    /// Everything queued has been played after `finish()`.
    var onFinish: (() -> Void)?
    /// Non-fatal problems, e.g. Qwen not reachable (the voice then falls back to macOS).
    var onNotice: ((String) -> Void)?

    let levels = VoiceLevelTimeline()

    private static let qwenLanguages: Set<String> = ["de", "en", "fr", "es", "it", "pt", "ru", "ja", "ko", "zh"]
    /// Loudness is measured in steps of 20 ms.
    private static let levelWindow = 0.02

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tempo = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let systemVoice = SystemVoiceRenderer()
    private var outputObserver: NSObjectProtocol?

    private var choice = VoiceChoice(engine: .system, qwenVoice: "")
    private var usesSystemVoice = false

    private var queue: [(text: String, language: String)] = []
    private var worker: Task<Void, Never>?
    private var playing: Set<Int> = []
    private var nextClip = 0
    /// Counts answers, so callbacks of an interrupted answer are ignored.
    private var answer = 0
    private var isActive = false
    private var isFinished = false
    private var hasStarted = false

    init() {
        engine.attach(player)
        engine.attach(tempo)
        engine.connect(player, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        outputObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    /// Starts a new answer; anything still playing is cut off. `rate` is the tempo setting shared with reading aloud.
    func begin(voice: VoiceChoice, rate: Double) {
        stop()
        choice = voice
        usesSystemVoice = voice.engine.qwenModel == nil
        // Same tempo slider as reading aloud: 0.3…0.7 → 0.6×…1.4×.
        tempo.rate = Float(min(2, max(0.5, 1 + (rate - 0.5) * 2)))
        isActive = true
    }

    /// Queues a piece of plain text (see `SpokenAnswerSegmenter`); `language` is a two-letter code.
    func enqueue(_ text: String, language: String) {
        guard isActive, !isFinished else { return }
        queue.append((text, language))
        startWorker()
    }

    /// No more text for this answer; `onFinish` follows once everything has been played.
    func finish() {
        guard isActive else { return }
        isFinished = true
        finishIfDone()
    }

    func stop() {
        answer += 1
        worker?.cancel()
        worker = nil
        queue = []
        playing = []
        if engine.isRunning { player.stop() }
        levels.reset()
        isActive = false
        isFinished = false
        hasStarted = false
    }

    /// Releases the audio output when the conversation ends.
    func shutDown() {
        stop()
        engine.stop()
        if let outputObserver { NotificationCenter.default.removeObserver(outputObserver) }
        outputObserver = nil
    }

    // MARK: Queue

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        let token = answer
        worker = Task { [weak self] in
            while let self, token == self.answer, !self.queue.isEmpty {
                let piece = self.queue.removeFirst()
                guard let clip = await self.render(piece.text, language: piece.language), token == self.answer else { continue }
                self.play(clip, token: token)
            }
            guard let self, token == self.answer else { return }
            self.worker = nil
            self.finishIfDone()
        }
    }

    /// The text as audio in the engine's format, or nil if it could not be synthesised.
    private func render(_ text: String, language: String) async -> AVAudioPCMBuffer? {
        if !usesSystemVoice, let model = choice.engine.qwenModel {
            do {
                let wav = try await QwenTTSClient().speech(
                    text: text, model: model, voice: choice.qwenVoice,
                    language: Self.qwenLanguages.contains(language) ? language : "auto",
                    instructions: choice.instructions
                )
                if let clip = try AudioClip.decode(wav: wav, to: format) { return clip }
            } catch {
                if error is CancellationError || Task.isCancelled { return nil }
                usesSystemVoice = true
                onNotice?("\(error.localizedDescription) Es spricht stattdessen die macOS-Stimme.")
            }
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechReader.bestVoice(forLanguage: language)
        utterance.prefersAssistiveTechnologySettings = false
        guard let pieces = try? await systemVoice.render(utterance), !Task.isCancelled else { return nil }
        return AudioClip.convert(pieces, to: format)
    }

    private func play(_ clip: AVAudioPCMBuffer, token: Int) {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                onNotice?("Die Tonausgabe konnte nicht gestartet werden: \(error.localizedDescription)")
                return
            }
        }
        let id = nextClip
        nextClip += 1
        playing.insert(id)
        player.scheduleBuffer(clip, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.clipPlayed(id, token: token) }
        }
        levels.append(AudioClip.envelope(of: clip, window: Self.levelWindow), step: Self.levelWindow / Double(tempo.rate))
        if !player.isPlaying { player.play() }
        if !hasStarted {
            hasStarted = true
            onStart?()
        }
    }

    private func clipPlayed(_ id: Int, token: Int) {
        guard token == answer, playing.remove(id) != nil else { return }
        finishIfDone()
    }

    private func finishIfDone() {
        guard isActive, isFinished, queue.isEmpty, worker == nil, playing.isEmpty else { return }
        isActive = false
        isFinished = false
        hasStarted = false
        levels.reset()
        onFinish?()
    }

    /// The output device changed (e.g. headphones): the engine stopped and lost what was scheduled.
    /// The answer goes on with the next piece.
    private func outputChanged() {
        if engine.isRunning { player.stop() }
        playing = []
        levels.reset()
        if isActive, !queue.isEmpty || worker != nil {
            try? engine.start()
        }
        finishIfDone()
    }
}

/// Loudness of the voice over time. Every clip adds its envelope from the moment it is expected to play,
/// so the wave can be drawn in step with the audio at any frame rate.
@MainActor
final class VoiceLevelTimeline {
    private struct Clip {
        let start: TimeInterval
        let step: TimeInterval
        let values: [Float]
        var end: TimeInterval { start + step * Double(values.count) }
    }

    private var clips: [Clip] = []

    /// `step` is the playback duration of one envelope value.
    func append(_ envelope: [Float], step: TimeInterval, now: Date = Date()) {
        let time = now.timeIntervalSinceReferenceDate
        clips.removeAll { $0.end < time - 1 }
        // A clip plays right after the previous one, or now if the player has run dry.
        let start = max(time, clips.last?.end ?? 0)
        clips.append(Clip(start: start, step: step, values: envelope))
    }

    /// 0…1
    func level(at date: Date) -> Float {
        let time = date.timeIntervalSinceReferenceDate
        guard let clip = clips.last(where: { $0.start <= time && time < $0.end }), !clip.values.isEmpty else { return 0 }
        return clip.values[min(Int((time - clip.start) / clip.step), clip.values.count - 1)]
    }

    func reset() {
        clips = []
    }
}

/// Helpers for synthesised audio.
enum AudioClip {
    /// Reads a WAV file from memory and converts it to `format`.
    static func decode(wav data: Data, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appending(path: "llmd-voice-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        try file.read(into: buffer)
        return convert([buffer], to: format)
    }

    /// Joins buffers of one format into a single buffer in `format`.
    static func convert(_ pieces: [AVAudioPCMBuffer], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = pieces.first?.format else { return nil }
        if pieces.count == 1, source == format { return pieces[0] }
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let frames = pieces.reduce(0) { $0 + Double($1.frameLength) }
        let capacity = AVAudioFrameCount((frames * format.sampleRate / source.sampleRate).rounded(.up)) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var next = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard next < pieces.count else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            next += 1
            return pieces[next - 1]
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// A buffer the caller may keep (the speech synthesizer reuses its own).
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let destination = to.mData else { continue }
            memcpy(destination, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Loudness (0…1) per window of `window` seconds, for a float buffer.
    static func envelope(of buffer: AVAudioPCMBuffer, window: TimeInterval) -> [Float] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        let size = max(1, Int(buffer.format.sampleRate * window))
        var values: [Float] = []
        values.reserveCapacity(count / size + 1)
        var start = 0
        while start < count {
            let end = min(start + size, count)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            let rms = (sum / Float(end - start)).squareRoot()
            let decibels = 20 * log10(max(rms, 0.000_01))
            values.append(min(1, max(0, (decibels + 50) / 38)))
            start = end
        }
        return values
    }
}

/// Renders text with a macOS voice into PCM buffers instead of playing it, so it runs through the same engine.
private final class SystemVoiceRenderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var pieces: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @MainActor
    func render(_ utterance: AVSpeechUtterance) async throws -> [AVAudioPCMBuffer] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pieces = []
                    self.continuation = continuation
                }
                // The synthesizer ends with an empty buffer (sometimes two); the first one completes the clip.
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        self.complete(nil)
                    } else if let copy = AudioClip.copy(pcm) {
                        self.lock.withLock { self.pieces.append(copy) }
                    }
                }
            }
        } onCancel: {
            complete(CancellationError())
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func complete(_ error: Error?) {
        let (continuation, pieces) = lock.withLock {
            defer {
                self.continuation = nil
                self.pieces = []
            }
            return (self.continuation, self.pieces)
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: pieces)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(CancellationError())
    }
}
