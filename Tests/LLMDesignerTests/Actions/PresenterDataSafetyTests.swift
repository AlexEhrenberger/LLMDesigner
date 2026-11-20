import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// Nothing the person wrote is lost when the app or the model works on a presentation at the same time: splitting a
/// full slide, the model making slides, the model writing speaker cards.
extension ActionSuites {
@MainActor
@Suite("Presenter: nichts geht verloren", .serialized)
struct PresenterDataSafetyTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    private func deck(_ id: WriterDocument.ID) -> PresentationDeck { h.app.document(id)!.deck! }

    /// A presentation as a new one is: one empty title slide.
    private func emptyDeck() -> WriterDocument.ID {
        var document = WriterDocument.newPresentation()
        document.title = "Leer \(UUID().uuidString)"
        document.hasCustomTitle = true
        h.app.documents.insert(document, at: 0)
        return document.id
    }

    private func withServer(_ body: (FakeLLMServer) async throws -> Void) async throws {
        let server = try FakeLLMServer()
        server.fallback = "Karte der Folie."
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.cancelSpeakerNotes()
            h.app.deckGeneration = nil
            h.app.endpoint = old
            server.stop()
        }
        try await body(server)
    }

    nonisolated static func text(of request: JSONValue) -> String {
        (request["messages"]?.arrayValue ?? []).compactMap { $0["content"]?.stringValue }.joined(separator: "\n")
    }

    nonisolated static let outline = #"{"titel":"Wasser","untertitel":"Ein Überblick","kapitel":[{"titel":"Grundlagen","folien":[{"titel":"Erste Folie","inhalt":"Was Wasser ist"},{"titel":"Zweite Folie","inhalt":"Wie es fließt"}]}]}"#
    nonisolated static let points = #"{"punkte":["Eins","Zwei","Drei"]}"#

    /// The outline for the outline request, three points for each slide.
    nonisolated static let answers: @Sendable (JSONValue) -> String? = { request in
        text(of: request).contains("Du entwirfst die Gliederung") ? outline : points
    }

    // MARK: Splitting a full slide

    private static let longPoint = "mit einem Satz, der schon für sich allein recht lang ist und eine Zeile füllt"

    private static var mixedSlide: String {
        var lines = ["# Gemischt", "", "Ein Satz vorweg, der bleiben muss.", ""]
        for number in 1...14 {
            lines.append("- Punkt \(number) \(longPoint)")
            if number == 1 { lines.append("  - Unterpunkt zu eins") }
        }
        lines += ["", "| A | B |", "|---|---|", "| 1 | 2 |", "", "Ein Schlusssatz bleibt auch."]
        return lines.joined(separator: "\n")
    }

    @Test func splittingKeepsEverythingThatIsNoPoint() async throws {
        let id = emptyDeck()
        let result = try await h.call("presenter.slide.setText", ["deck": .string(id.uuidString), "slideIndex": 1, "markdown": .string(Self.mixedSlide), "splitOverflow": true])
        #expect(result["fit"]?["fits"] == true)
        let slides = deck(id).slides
        #expect(slides.count > 1)
        let all = slides.map(\.markdown).joined(separator: "\n")
        // Every line but the heading is there exactly once.
        for line in Self.mixedSlide.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
            #expect(all.components(separatedBy: "\n").filter { $0 == line }.count == 1, "\(line)")
        }
        #expect(slides[0].markdown.contains("Ein Satz vorweg"))
        #expect(slides[0].markdown.contains("- Punkt 1 \(Self.longPoint)\n  - Unterpunkt zu eins"))
        #expect(slides.last?.markdown.hasSuffix("| 1 | 2 |\n\nEin Schlusssatz bleibt auch.") == true)
        #expect(slides.dropFirst().allSatisfy { $0.markdown.hasPrefix("# Gemischt (Forts.)") })
    }

    @Test func continuationsKeepTheSlidesOwnBackground() async throws {
        let id = emptyDeck()
        let slideID = deck(id).slides[0].id
        let lines = ["# Viele Punkte", ""] + (1...16).map { "- Punkt \($0) \(Self.longPoint)" }
        h.app.updateSlide(id, slideID, markdown: lines.joined(separator: "\n"))
        h.app.setSlideBackground(id, slideID, .color("#204060"))
        let document = try #require(h.app.document(id))
        let parts = SlideFit.split(try #require(document.deck?.slide(slideID)), in: try #require(document.deck), family: document.font)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.background == .color("#204060") })
    }

    // MARK: The model makes the slides

    @Test func whatIsWrittenWhileTheModelOutlinesStays() async throws {
        try await withServer { server in
            server.respond = Self.answers
            let id = emptyDeck()
            let titleID = deck(id).slides[0].id
            h.app.generatePresentation(id, instruction: "Wasser", withNotes: false, presents: false)
            // The outline takes a while; meanwhile the person writes the title.
            h.app.updateSlide(id, titleID, markdown: "# Mein eigener Titel")
            await h.app.deckGenerationTask?.value
            let slides = deck(id).slides
            #expect(slides.first?.markdown == "# Mein eigener Titel")
            #expect(slides.contains { $0.markdown.hasPrefix("# Erste Folie") })
            #expect(h.app.deckGeneration?.replacedEmpty == false)
        }
    }

    @Test func theModelLeavesASlideThePersonChanged() async throws {
        try await withServer { server in
            let id = emptyDeck()
            let app = h.app
            server.respond = { request in
                let text = Self.text(of: request)
                if text.contains("Du entwirfst die Gliederung") { return Self.outline }
                if text.contains("Folie: „Erste Folie“") {
                    // The person writes on the slide while the model works out its points.
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            if let slide = app.document(id)?.deck?.slides.first(where: { $0.markdown == "# Erste Folie" }) {
                                app.updateSlide(id, slide.id, markdown: "# Erste Folie\n\nMein eigener Text")
                            }
                        }
                    }
                }
                return Self.points
            }
            h.app.generatePresentation(id, instruction: "Wasser", withNotes: false, presents: false)
            await h.app.deckGenerationTask?.value
            let slides = deck(id).slides
            #expect(slides.first { $0.markdown.hasPrefix("# Erste Folie") }?.markdown == "# Erste Folie\n\nMein eigener Text")
            #expect(slides.first { $0.markdown.hasPrefix("# Zweite Folie") }?.markdown.contains("- Eins") == true)
        }
    }

    @Test func undoingAGenerationKeepsWhatCameAfterIt() async throws {
        try await withServer { server in
            server.respond = Self.answers
            let id = emptyDeck()
            let titleID = deck(id).slides[0].id
            h.app.generatePresentation(id, instruction: "Wasser", withNotes: false, presents: false)
            await h.app.deckGenerationTask?.value
            let generated = deck(id)
            #expect(generated.slides.count == 4)
            #expect(generated.slides[0].id == titleID)
            // Afterwards the person adds a slide of their own.
            let own = try #require(h.app.addSlide(to: id, after: generated.slides.last?.id, markdown: "# Meine Folie"))
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            h.app.undoDeckGeneration(undoManager: undo)
            undo.endUndoGrouping()
            let after = deck(id)
            #expect(after.slides.map(\.id) == [titleID, own])
            #expect(after.slides[0].markdown.isEmpty)
            // ⌘Z brings the model's slides back.
            undo.undo()
            #expect(deck(id).slides.map(\.id) == generated.slides.map(\.id) + [own])
        }
    }

    @Test func aPresentationFromADocumentKeepsWhatIsWrittenMeanwhile() async throws {
        try await withServer { server in
            server.respond = { _ in Self.points }
            let material = DeckMaterial(
                title: "Quelle \(UUID().uuidString)",
                markdown: "# Kapitel eins\n\n## Abschnitt A\n\nText hier.\n\n## Abschnitt B\n\nMehr Text.\n\n# Kapitel zwei\n\n## Abschnitt C\n\nNoch mehr.",
                sourceName: "Test"
            )
            h.app.createPresentation(from: material, options: DeckSourceOptions(notes: false, carriesObjects: false, presents: false))
            let id = try #require(h.app.selectedDocumentID)
            defer { h.app.closeDocument() }
            let titleID = deck(id).slides[0].id
            h.app.updateSlide(id, titleID, markdown: "# Eigener Titel")
            await h.app.deckGenerationTask?.value
            let slides = deck(id).slides
            #expect(slides.first?.markdown == "# Eigener Titel")
            #expect(slides.contains { $0.markdown.hasPrefix("# Abschnitt A\n\n- Eins") })
        }
    }

    // MARK: The model writes speaker cards

    private func deckWithSlides(_ count: Int) -> WriterDocument.ID {
        let id = emptyDeck()
        let first = deck(id).slides[0].id
        h.app.updateSlide(id, first, markdown: "# Titel")
        var last = first
        for number in 1..<count {
            last = h.app.addSlide(to: id, after: last, markdown: "# Folie \(number)")!
        }
        return id
    }

    @Test func cancellingStopsEveryCardThatWasAskedFor() async throws {
        try await withServer { server in
            server.respond = { _ in
                Thread.sleep(forTimeInterval: 0.2)
                return "Eine Karte."
            }
            let id = deckWithSlides(4)
            let slides = deck(id).slides.map(\.id)
            h.app.writeSpeakerNotes(id, slides: Array(slides[0...1]))
            h.app.writeSpeakerNotes(id, slides: Array(slides[2...3]))
            h.app.cancelSpeakerNotes()
            try await Task.sleep(for: .milliseconds(1_200))
            #expect(deck(id).slides.allSatisfy { $0.notes.isEmpty })
            #expect(h.app.notesWriting.isEmpty)
        }
    }

    @Test func aCardChangedWhileTheModelWritesStays() async throws {
        try await withServer { server in
            let id = deckWithSlides(2)
            let slideID = deck(id).slides[1].id
            let app = h.app
            server.respond = { request in
                guard Self.text(of: request).contains("Moderatorenkarte zu einer Folie") else { return nil }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { app.setSlideNotes(id, slideID, "Von Hand geschrieben.") }
                }
                return "Die Karte der KI."
            }
            h.app.writeSpeakerNotes(id, slides: [slideID])
            await h.app.notesTask?.value
            #expect(deck(id).slide(slideID)?.notes == "Von Hand geschrieben.")
            #expect(h.app.notesWriting.isEmpty)
        }
    }

    @Test func aRewrittenCardCanBeTakenBack() async throws {
        try await withServer { server in
            server.respond = { request in
                Self.text(of: request).contains("Moderatorenkarte zu einer Folie") ? "Die neue Karte der KI." : nil
            }
            let id = deckWithSlides(2)
            let slideID = deck(id).slides[1].id
            h.app.setSlideNotes(id, slideID, "Meine eigene Karte.")
            h.app.writeSpeakerNotes(id, slides: [slideID])
            await h.app.notesTask?.value
            #expect(deck(id).slide(slideID)?.notes == "Die neue Karte der KI.")
            #expect(h.app.replacedNotes[slideID] == "Meine eigene Karte.")

            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            h.app.restoreReplacedNotes(id, slideID, undoManager: undo)
            undo.endUndoGrouping()
            #expect(deck(id).slide(slideID)?.notes == "Meine eigene Karte.")
            undo.undo()
            #expect(deck(id).slide(slideID)?.notes == "Die neue Karte der KI.")
        }
    }

    @Test func theCardThePresentationNeedsIsWrittenFirst() async throws {
        try await withServer { server in
            server.respond = { request in
                Self.text(of: request).contains("Moderatorenkarte zu einer Folie") ? "Eine Karte." : nil
            }
            let id = deckWithSlides(3)
            let slides = deck(id).slides.map(\.id)
            h.app.writeSpeakerNotes(id, slides: slides)
            h.app.writeSpeakerNotes(id, slides: [slides[2]], first: true)
            await h.app.notesTask?.value
            #expect(deck(id).slides.allSatisfy { !$0.notes.isEmpty })
            let order = server.seenCompletions.map(Self.text(of:)).filter { $0.contains("Moderatorenkarte zu einer Folie") }
            #expect(order.count == 3)
            #expect(order.first?.contains("Folie 3 von 3") == true)
        }
    }
}
}
