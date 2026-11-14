import Foundation
import Testing
@testable import LLMDesigner

/// The answer must keep up with the model even when drawing it is slow (see `StreamRound`).
@Suite struct StreamRoundTests {
    /// A model writing `count` pieces of text, one every millisecond, then optionally calling a tool.
    private func stream(count: Int, calls: [ToolCall] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                continuation.yield(.model("test-model"))
                for _ in 0..<count {
                    if Task.isCancelled { break }
                    continuation.yield(.content("x"))
                    try? await Task.sleep(for: .milliseconds(1))
                }
                continuation.yield(.usage(prompt: 10, completion: count, cached: 4))
                if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    @Test func slowRedrawsDoNotHoldBackTheText() async throws {
        let count = 2_000
        var snapshots = 0
        var shown = 0
        let started = Date()
        let outcome = await StreamRound.read(stream(count: count)) { round in
            snapshots += 1
            shown = round.raw.count
            // A redraw of a long code block: before, every token waited for one of these.
            Thread.sleep(forTimeInterval: 0.15)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome.error == nil)
        #expect(outcome.round.raw.count == count)
        #expect(shown == count)
        #expect(outcome.round.model == "test-model")
        #expect(outcome.round.completionTokens == count)
        #expect(outcome.round.cachedPromptTokens == 4)
        // One token per redraw would take about 300 s and as many snapshots as tokens.
        #expect(snapshots < count / 10)
        #expect(elapsed < 30)
    }

    @MainActor
    @Test func toolCallsArrive() async {
        let call = ToolCall(id: "call_1", function: .init(name: "web_search", arguments: "{}"))
        let outcome = await StreamRound.read(stream(count: 20, calls: [call])) { _ in }
        #expect(outcome.round.toolCalls == [call])
        #expect(outcome.round.raw.count == 20)
    }

    @MainActor
    @Test func stoppingKeepsTheTextSoFar() async {
        let reading = Task { @MainActor in
            await StreamRound.read(stream(count: 100_000)) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(300))
        reading.cancel()
        let outcome = await reading.value
        #expect(outcome.round.raw.count > 0)
        #expect(outcome.round.raw.count < 100_000)
    }
}
