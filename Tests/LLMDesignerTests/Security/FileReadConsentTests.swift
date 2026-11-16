import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
/// A path from a model or a program reaches any file on this Mac: chat, MCP and the app's own agents ask before such a
/// file comes into the library; the person at the app or in the terminal names their own files. And reading a foreign
/// presentation marks the run, whichever action reads it.
@MainActor
@Suite("Sicherheit: Dateien von der Platte, fremde Präsentationen", .serialized)
struct FileReadConsentTests {
    let h = ActionHarness()

    /// An agent run whose task may change things without asking (the default "Änderungen erlauben").
    private func agentRun() -> String {
        let id = "agent-\(UUID().uuidString)"
        h.registry.runState(id: id, channel: .agent).approval = .allowWrites
        h.registry.approval.agentPresenter = { _ in false }
        return id
    }

    private func pictureFile() throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func presentation(foreign: Bool = false) -> WriterDocument.ID {
        var document = WriterDocument.newPresentation()
        document.title = "Vortrag \(UUID().uuidString)"
        document.hasCustomTitle = true
        if foreign { document.provenance = .foreign }
        h.app.documents.insert(document, at: 0)
        return document.id
    }

    @Test func whoAsksBeforeAFileComesIn() {
        let asks = Dictionary(uniqueKeysWithValues: ActionChannel.allCases.map { ($0, $0.asksBeforeReadingFiles) })
        #expect(asks == [.ui: false, .cli: false, .chat: true, .mcp: true, .agent: true])
    }

    @Test func anAgentAsksBeforeAFileFromTheDiskComesIn() async throws {
        let run = agentRun()
        let file = try pictureFile().path
        let deck = presentation().uuidString
        let doc = try await h.document("Ein Absatz.")
        #expect(await h.errorCode("presenter.background.image", ["deck": .string(deck), "file": .string(file)], channel: .agent, run: run) == RPCError.deniedCode)
        #expect(await h.errorCode("writer.image.insert", ["doc": .string(doc), "file": .string(file)], channel: .agent, run: run) == RPCError.deniedCode)
        #expect(await h.errorCode("chat.document.attach", ["chat": "irgendeiner", "files": .array([.string(file)])], channel: .agent, run: run) == RPCError.deniedCode)
        #expect(await h.errorCode("stories.gallery.add", ["world": "irgendeine", "file": .string(file)], channel: .agent, run: run) == RPCError.deniedCode)
        // Nothing came in.
        #expect(h.app.document(UUID(uuidString: deck)!)?.deck?.backgrounds.folie?.kind != .image)
    }

    @Test func theTerminalNamesItsOwnFiles() async throws {
        let deck = presentation().uuidString
        try await h.call("presenter.background.image", ["deck": .string(deck), "file": .string(try pictureFile().path)], channel: .cli)
        #expect(h.app.document(UUID(uuidString: deck)!)?.deck?.backgrounds.folie?.kind == .image)
    }

    @Test func makingSlidesFromAForeignPresentationMarksTheRun() async throws {
        let deck = presentation(foreign: true).uuidString
        let run = "lauf-\(UUID().uuidString)"
        // A creation that failed for want of a model stays on the card; other tests don't want to meet it.
        defer { h.app.deckGeneration = nil }
        // Without a model it fails, but what the run read counts from before.
        _ = await h.errorCode("presenter.ai.createDeck", ["deck": .string(deck), "instruction": "Wasser"], channel: .cli, run: run)
        #expect(h.registry.runState(id: run, channel: .cli).hasReadUntrusted)
    }

    @Test func theStateOfAnOpenForeignPresentationMarksTheRun() async throws {
        let deck = presentation(foreign: true)
        h.app.selectedDocumentID = deck
        defer { h.app.closeDocument() }
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("presenter.state.get", channel: .cli, run: run)
        #expect(h.registry.runState(id: run, channel: .cli).hasReadUntrusted)
    }

    @Test func readingACardAloudAsks() async throws {
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("presenter.play.readNotes", channel: .cli) == RPCError.deniedCode)
    }
}
}
