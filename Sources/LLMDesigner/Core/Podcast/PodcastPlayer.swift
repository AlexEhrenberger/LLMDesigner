import AVFoundation
import Foundation

/// Plays a finished podcast in the app. The position is read a few times a second for the time and the slider; the
/// script only hears of it when the spoken line changes (`currentLine`). Before, the whole script was drawn again at
/// every tick, which with a long script took the main thread most of the time.
@MainActor
@Observable
final class PodcastPlayer: NSObject {
    private(set) var podcastID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// The line being spoken, changed only when another one begins.
    private(set) var currentLine: UUID?
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var ticker: Timer?
    /// When each line begins, in order.
    @ObservationIgnored private var lineStarts: [(id: UUID, start: Double)] = []

    /// Loads the podcast's audio (without playing) unless it is loaded already; `lines` are when each line begins.
    func load(_ id: UUID, url: URL, lines: [UUID: Double] = [:]) {
        let starts = lines.map { (id: $0.key, start: $0.value) }.sorted { $0.start < $1.start }
        guard podcastID != id || player == nil || self.url != url else {
            lineStarts = starts
            return updateLine()
        }
        stop()
        podcastID = id
        self.url = url
        lineStarts = starts
        prepare()
    }

    /// The file was made anew while it was loaded: the same position in the new file.
    func reload() {
        let position = currentTime
        let wasPlaying = isPlaying
        pause()
        prepare()
        seek(to: position)
        if wasPlaying { play() }
    }

    private func prepare() {
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            self.player = nil
            duration = 0
            return
        }
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.rate = rate
        player.play()
        isPlaying = true
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Also while the person scrolls or drags the slider (event tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
        tick()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        currentTime = player.currentTime
        updateLine()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        pause()
        player?.stop()
        player = nil
        podcastID = nil
        url = nil
        currentTime = 0
        duration = 0
        currentLine = nil
        lineStarts = []
    }

    private func tick() {
        guard let player else { return }
        let now = player.currentTime
        // Observers redraw on every set, even an equal value.
        if abs(now - currentTime) >= 0.05 { currentTime = now }
        updateLine()
    }

    private func updateLine() {
        let now = currentTime + 0.05
        let line = lineStarts.last { $0.start <= now }?.id
        if line != currentLine { currentLine = line }
    }
}

extension PodcastPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === self.player else { return }
            self.isPlaying = false
            self.ticker?.invalidate()
            self.ticker = nil
            self.currentTime = self.duration
        }
    }
}
