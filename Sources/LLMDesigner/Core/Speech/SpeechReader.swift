import AVFoundation
import NaturalLanguage

/// Reads text aloud with the macOS voices (AVSpeechSynthesizer) or with Qwen TTS (adapted from Auda).
/// With Qwen, the next sentence group is generated while the current one plays, so reading starts quickly.
@MainActor
final class SpeechReader: NSObject {
    enum State: Equatable {
        case preparing, speaking, stopped
    }

    var onState: ((State) -> Void)?
    /// Non-fatal problems, e.g. Qwen not reachable (the reader then falls back to the macOS voice).
    var onNotice: ((String) -> Void)?
    /// What is being spoken right now, as a UTF-16 range of the text passed to `speak`: the word with the
    /// macOS voice, the sentence group with Qwen.
    var onProgress: ((NSRange) -> Void)?

    private(set) var state: State = .stopped
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var qwenTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackFinished: CheckedContinuation<Void, Error>?
    /// UTF-16 length of the whitespace `speak` trimmed off the front, to report ranges in the caller's text.
    private var progressOffset = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `rate` is the macOS speech rate (0.3…0.7, 0.5 normal); Qwen playback uses the same slider as tempo.
    func speak(_ text: String, voice: VoiceChoice, rate: Double) {
        stop()
        progressOffset = text.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let model = voice.engine.qwenModel {
            speakWithQwen(text, model: model, voice: voice.qwenVoice, instructions: voice.instructions, rate: rate)
        } else {
            speakWithSystem(text, rate: rate)
        }
    }

    func stop() {
        qwenTask?.cancel()
        qwenTask = nil
        player?.stop()
        player = nil
        playbackFinished?.resume(throwing: CancellationError())
        playbackFinished = nil
        if utterance != nil {
            utterance = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        setState(.stopped)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onState?(newState)
    }

    // MARK: macOS voice

    private func speakWithSystem(_ text: String, rate: Double) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(forLanguage: SpeakableText.language(of: text))
        utterance.rate = Float(rate)
        utterance.prefersAssistiveTechnologySettings = false
        self.utterance = utterance
        synthesizer.speak(utterance)
        setState(.speaking)
    }

    static func bestVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language)
                && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            var score = voice.quality.rawValue * 10
            if let region, voice.language.hasSuffix(region) { score += 5 }
            if voice.identifier.contains("eloquence") { score -= 8 }
            return score
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    // MARK: Qwen TTS

    private func speakWithQwen(_ text: String, model: String, voice: String, instructions: String?, rate: Double) {
        let pieces = Self.chunks(of: text)
        guard !pieces.isEmpty else { return }
        let chunks = pieces.map(\.text)
        let language = ["de", "en", "fr", "es", "it", "pt", "ru", "ja", "ko", "zh"].contains(SpeakableText.language(of: text))
            ? SpeakableText.language(of: text) : "auto"
        let client = QwenTTSClient()
        setState(.preparing)

        qwenTask = Task { [weak self] in
            var next: Task<Data, Error>? = Task {
                try await client.speech(text: chunks[0], model: model, voice: voice, language: language, instructions: instructions)
            }
            do {
                for index in chunks.indices {
                    guard let pending = next else { break }
                    let clip = try await pending.value
                    // Generate the following sentence group while this one plays.
                    next = index + 1 < chunks.count
                        ? Task { try await client.speech(text: chunks[index + 1], model: model, voice: voice, language: language, instructions: instructions) }
                        : nil
                    try Task.checkCancellation()
                    self?.setState(.speaking)
                    self?.reportProgress(pieces[index].range)
                    try await self?.play(clip, rate: rate)
                    try await Task.sleep(for: .milliseconds(index + 1 < chunks.count ? 150 : 0))
                }
                self?.player = nil
                self?.qwenTask = nil
                self?.setState(.stopped)
            } catch is CancellationError {
                next?.cancel()
            } catch {
                next?.cancel()
                guard let self, self.state != .stopped else { return }
                self.qwenTask = nil
                self.onNotice?("\(error.localizedDescription) Es liest stattdessen die macOS-Stimme.")
                self.speakWithSystem(text, rate: rate)
            }
        }
    }

    private func play(_ data: Data, rate: Double) async throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.enableRate = true
        // Same tempo slider as the macOS voices: 0.3…0.7 → 0.6×…1.4×.
        player.rate = Float(min(2, max(0.5, 1 + (rate - 0.5) * 2)))
        self.player = player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playbackFinished = continuation
            player.play()
        }
    }

    private func reportProgress(_ range: NSRange) {
        onProgress?(NSRange(location: range.location + progressOffset, length: range.length))
    }

    /// Sentence groups of up to ~220 characters, with where they are in `text`. Short paragraphs (headings,
    /// list items) share a group, so Qwen doesn't pause for a new request after every line.
    private static func chunks(of text: String) -> [(text: String, range: NSRange)] {
        var result: [(text: String, range: NSRange)] = []
        var group = ""
        var groupRange: Range<String.Index>?
        func close() {
            if let groupRange, group.contains(where: { $0.isLetter || $0.isNumber }) {
                result.append((group, NSRange(groupRange, in: text)))
            }
            group = ""
            groupRange = nil
        }

        var paragraphStart = text.startIndex
        while paragraphStart < text.endIndex {
            let paragraphEnd = text[paragraphStart...].firstIndex(of: "\n") ?? text.endIndex
            let paragraph = paragraphStart..<paragraphEnd
            if text[paragraph].contains(where: { $0.isLetter || $0.isNumber }) {
                // A long paragraph starts its own group.
                if group.count >= 100 { close() }
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = text
                tokenizer.enumerateTokens(in: paragraph) { range, _ in
                    let sentence = text[range].trimmingCharacters(in: .whitespaces)
                    if !group.isEmpty && group.count + sentence.count > 220 { close() }
                    group += group.isEmpty ? sentence : " " + sentence
                    groupRange = groupRange.map { $0.lowerBound..<range.upperBound } ?? range
                    return true
                }
            }
            paragraphStart = paragraphEnd < text.endIndex ? text.index(after: paragraphEnd) : text.endIndex
        }
        close()
        return result
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.reportProgress(characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.utterance = nil
            self.setState(.stopped)
        }
    }
}

extension SpeechReader: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === self.player else { return }
            self.playbackFinished?.resume()
            self.playbackFinished = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, player === self.player else { return }
            self.playbackFinished?.resume(throwing: error ?? CancellationError())
            self.playbackFinished = nil
        }
    }
}
