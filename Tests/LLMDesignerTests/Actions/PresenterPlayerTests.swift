import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// The presentation never gets stuck: reading always ends, a presentation that loses its slides stops, the full
/// screen gives back the menu bar, a design that doesn't draw doesn't hold up the others. Nothing here speaks aloud
/// or takes the screen.
extension ActionSuites {
@MainActor
@Suite("Presenter: Vortrag bleibt nicht hängen", .serialized)
struct PresenterPlayerTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    private func withServer(_ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer()
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.presentationPlayer.stop()
            h.app.cancelSpeakerNotes()
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    private func deck(_ title: String = "Vortrag \(UUID().uuidString)") -> WriterDocument.ID {
        var document = WriterDocument.newPresentation()
        document.title = title
        document.hasCustomTitle = true
        h.app.documents.insert(document, at: 0)
        h.app.updateSlide(document.id, document.deck!.slides[0].id, markdown: "# Titel")
        return document.id
    }

    @Test func readingWithoutAnOpenDocumentStillEnds() async throws {
        h.app.closeDocument()
        #expect(h.app.selectedDocumentID == nil)
        var ended: Bool?
        h.app.readDocumentAloud("Ein Satz zum Vorlesen.", progress: { _ in }, ended: { ended = $0 })
        // It ends at once, and not as read to the end.
        #expect(ended == false)
        #expect(h.app.speakingDocumentID == nil)
    }

    @Test func showingTheFullScreenTwiceStillGivesTheMenuBarBack() {
        var hiding = MenuBarHiding()
        let before: NSApplication.PresentationOptions = [.autoHideDock]
        let hidden = hiding.hide(current: before)
        #expect(hidden == [.hideDock, .hideMenuBar])
        // A second "Vorführen" while it is shown: the app's options are the hidden ones now.
        _ = hiding.hide(current: hidden)
        #expect(hiding.restore() == before)
        #expect(hiding.restore() == nil)
    }

    @Test func aDesignThatNeverLoadsHoldsUpNothing() async throws {
        let renderer = SlideDesignRenderer.shared
        let design = try #require(SlideDesignLibrary.shared.design(SlideDesign.defaultID))
        let load = SlideDesignRenderer.load
        let timeout = SlideDesignRenderer.loadTimeout
        defer {
            SlideDesignRenderer.load = load
            SlideDesignRenderer.loadTimeout = timeout
        }
        // A width no other test draws, so nothing comes from the cache.
        let width = CGFloat(Int.random(in: 300...399))

        // The page never loads (a hanging web process): the time-out ends the wait.
        SlideDesignRenderer.load = { _, _, _ in }
        SlideDesignRenderer.loadTimeout = .milliseconds(200)
        var started = Date()
        #expect(await renderer.render(design, role: .content, width: width) == nil)
        #expect(Date().timeIntervalSince(started) < 3)

        // The rules for blocking the network are missing: nothing loads, and that is known at once.
        SlideDesignRenderer.load = { _, _, blocked in blocked() }
        SlideDesignRenderer.loadTimeout = .seconds(30)
        started = Date()
        #expect(await renderer.render(design, role: .title, width: width) == nil)
        #expect(Date().timeIntervalSince(started) < 3)

        // The next design draws again, in a fresh web view.
        SlideDesignRenderer.load = load
        #expect(await renderer.render(design, role: .content, width: width) != nil)
    }

    @Test func deletingThePresentedDeckStopsThePlayer() async throws {
        try await withServer { server in
            server.respond = { request in
                let text = (request["messages"]?.arrayValue ?? []).compactMap { $0["content"]?.stringValue }.joined()
                guard text.contains("Moderatorenkarte zu einer Folie") else { return nil }
                // The card takes a while: the presentation waits for it.
                Thread.sleep(forTimeInterval: 0.5)
                return "Eine Karte."
            }
            let id = deck()
            let player = h.app.presentationPlayer
            player.app = h.app
            player.prepare(id, at: nil)
            player.present()
            try await Task.sleep(for: .milliseconds(150))
            #expect(player.isPresenting)
            #expect(player.phase == .writing)
            h.app.deleteDocument(id)
            #expect(!player.isPresenting)
            #expect(player.phase == .idle)
            #expect(player.deck == nil)
            await h.app.notesTask?.value
        }
    }
}
}
