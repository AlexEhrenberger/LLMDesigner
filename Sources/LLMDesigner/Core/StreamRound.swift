import Foundation

/// One streamed request to the model, read off the main thread.
///
/// Reading the stream on the main actor made the answer fall minutes behind the model: once drawing the answer took
/// longer than the flush interval, every single token arrived after a redraw and immediately caused the next one, so
/// the view managed one token per redraw. Here the tokens pile up off the main thread, and the view gets the latest
/// text at most every `interval`, counted from the moment it took the previous one.
struct StreamRound: Sendable {
    /// The answer text as it came, thinking markers included (`ThinkingSplitter` takes them apart).
    var raw = ""
    /// Thoughts the server sent in a field of their own.
    var reasoning = ""
    var events = 0
    /// When the first text or thought arrived.
    var start: Date?
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedPromptTokens: Int?
    var sawUsage = false
    /// The model that actually answered.
    var model: String?
    var toolCalls: [ToolCall] = []

    struct Outcome: Sendable {
        var round: StreamRound
        /// What ended the stream early; the text up to there is still in `round`.
        var error: (any Error)?
    }

    static let defaultInterval: Duration = .milliseconds(50)

    /// Reads `stream` to its end. `onSnapshot` runs on the main actor with the text so far; a slow redraw makes the
    /// snapshots rarer, never the reading slower.
    static func read(
        _ stream: AsyncThrowingStream<StreamEvent, Error>,
        interval: Duration = defaultInterval,
        onSnapshot: @escaping @MainActor (StreamRound) -> Void
    ) async -> Outcome {
        let clock = ContinuousClock()
        var round = StreamRound()
        var lastSnapshot = clock.now - interval
        var pending = false
        do {
            for try await event in stream {
                switch event {
                case .content(let text):
                    if round.start == nil { round.start = Date() }
                    round.raw += text
                    round.events += 1
                case .reasoning(let text):
                    if round.start == nil { round.start = Date() }
                    round.reasoning += text
                    round.events += 1
                case .usage(let prompt, let completion, let cached):
                    round.promptTokens = prompt
                    round.completionTokens = completion
                    if !round.sawUsage {
                        round.sawUsage = true
                        round.cachedPromptTokens = cached
                    }
                case .model(let answering):
                    round.model = answering
                case .toolCalls(let calls):
                    round.toolCalls = calls
                }
                pending = true
                if clock.now - lastSnapshot >= interval {
                    let snapshot = round
                    await MainActor.run { onSnapshot(snapshot) }
                    // The pause starts when the view has the text, not when it was sent: otherwise the first token after
                    // a slow redraw would ask for the next redraw straight away.
                    lastSnapshot = clock.now
                    pending = false
                }
            }
        } catch {
            return Outcome(round: round, error: error)
        }
        if pending {
            let snapshot = round
            await MainActor.run { onSnapshot(snapshot) }
        }
        return Outcome(round: round, error: nil)
    }
}
