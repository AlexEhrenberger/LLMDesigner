import AVFoundation

/// Joining the spoken pieces: the pieces of one line into its snippet (WAV), and all snippets into the podcast (M4A),
/// with a short pause between lines and a longer one where the speaker changes.
enum PodcastAudio {
    /// Seconds of silence between two lines of the same speaker, and where the speaker changes.
    static let pauseSameSpeaker = 0.25
    static let pauseNewSpeaker = 0.45
    /// Between the pieces of one long line: like a breath.
    static let pauseWithinLine = 0.12

    enum Failure: LocalizedError {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "Es gibt noch keine gesprochenen Zeilen."
            case .unreadable(let name): "Die Audiodatei „\(name)“ ließ sich nicht lesen."
            }
        }
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Writes the WAV pieces of one line (as Qwen TTS returns them) as one WAV file; returns its seconds.
    @discardableResult
    static func writeSnippet(_ pieces: [Data], to destination: URL) throws -> Double {
        guard !pieces.isEmpty else { throw Failure.noAudio }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("llmd-podcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let files = try pieces.enumerated().map { index, data in
            let url = temporary.appendingPathComponent("\(index).wav")
            try data.write(to: url)
            return url
        }
        return try join(files.map { ($0, pauseWithinLine) }, to: destination, fileType: .wav)
    }

    /// The podcast from its snippets in order. `speakers` says who speaks each, for the length of the pause before it.
    @discardableResult
    static func joinPodcast(_ snippets: [(url: URL, speaker: UUID)], to destination: URL) throws -> Double {
        var previous: UUID?
        let parts = snippets.map { snippet -> (URL, Double) in
            defer { previous = snippet.speaker }
            guard let previous else { return (snippet.url, 0) }
            return (snippet.url, previous == snippet.speaker ? pauseSameSpeaker : pauseNewSpeaker)
        }
        return try join(parts, to: destination, fileType: .m4a)
    }

    enum FileType {
        case wav, m4a
    }

    /// Joins audio files, each after its pause (the first pause is left out), into one file; returns its seconds.
    /// It is written next to the destination first and moved over it at the end, so a stopped run leaves the old file.
    static func join(_ parts: [(url: URL, pauseBefore: Double)], to destination: URL, fileType: FileType) throws -> Double {
        guard let first = parts.first else { throw Failure.noAudio }
        let firstFile = try readable(first.url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: firstFile.processingFormat.sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = switch fileType {
        case .wav:
            [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1,
             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1,
             AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let working = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).\(destination.pathExtension)")
        var frames: AVAudioFramePosition = 0
        do {
            // The file is finished when it is released, so it lives only in this block.
            let output = try AVAudioFile(forWriting: working, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            for (index, part) in parts.enumerated() {
                if index > 0, part.pauseBefore > 0 {
                    let count = AVAudioFrameCount(part.pauseBefore * format.sampleRate)
                    let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
                    silence.frameLength = count
                    if let channel = silence.floatChannelData?[0] { channel.initialize(repeating: 0, count: Int(count)) }
                    try output.write(from: silence)
                    frames += AVAudioFramePosition(count)
                }
                let input = index == 0 ? firstFile : try readable(part.url)
                frames += try copy(input, into: output, as: format)
            }
        } catch {
            try? FileManager.default.removeItem(at: working)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: working)
        } else {
            try FileManager.default.moveItem(at: working, to: destination)
        }
        return Double(frames) / format.sampleRate
    }

    private static func readable(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url.lastPathComponent)
        }
    }

    /// Copies a file into the output, converted to its format (Qwen's voices all answer in 24 kHz mono, but a voice
    /// from another service might not). Returns the frames written.
    private static func copy(_ input: AVAudioFile, into output: AVAudioFile, as format: AVAudioFormat) throws -> AVAudioFramePosition {
        let chunk: AVAudioFrameCount = 16_384
        let source = input.processingFormat
        let needsConversion = source.sampleRate != format.sampleRate || source.channelCount != format.channelCount || source.commonFormat != format.commonFormat
        var written: AVAudioFramePosition = 0
        if !needsConversion {
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk)!
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
            return written
        }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw Failure.unreadable("Format") }
        let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk)!
        let ratio = format.sampleRate / source.sampleRate
        let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64)!
        var finished = false
        while !finished {
            var conversionError: NSError?
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, state in
                do {
                    if input.framePosition >= input.length {
                        state.pointee = .endOfStream
                        return nil
                    }
                    try input.read(into: inBuffer, frameCount: chunk)
                    state.pointee = inBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return inBuffer
                } catch {
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
                written += AVAudioFramePosition(outBuffer.frameLength)
            }
            finished = status == .endOfStream || status == .error
        }
        return written
    }
}
