import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// What the person sees is what comes out: the PDF stacks pictures and text fields as the screen does, an instruction
/// in the bar does what it says (and nothing bigger), the handout writes out the section it means.
extension ActionSuites {
@MainActor
@Suite("Presenter: PDF wie am Bildschirm, Absicht und Handout treffen", .serialized)
struct PresenterFidelityTests {
    let h = ActionHarness()

    // MARK: The PDF stacks like the screen

    /// A plain, opaque picture of one colour, stored in the test library.
    private func picture(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> String {
        // AppKit draws only into bitmaps with an alpha channel; the fill makes it opaque all the same.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(deviceRed: red, green: green, blue: blue, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 60, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try WriterImageStore.importImage(.data(try #require(rep.representation(using: .png, properties: [:]))))
    }

    /// The colour in the middle of where the box and the picture overlap, as the printed slide has it.
    private func overlapColor(_ elements: [SlideImage]) async throws -> NSColor {
        var slide = PresentationSlide(role: .content)
        slide.background = .color("#000000")
        slide.images = elements
        let deck = PresentationDeck(slides: [slide])
        let data = try #require(await SlidePrinter.png(slide: slide, in: deck, family: .sans, citations: nil, scale: 1))
        let rep = try #require(NSBitmapImageRep(data: data))
        return try #require(rep.colorAt(x: 400, y: 202)?.usingColorSpace(.deviceRGB))
    }

    /// The picture's blue, unmixed (the colour space conversion adds a little green). The red box over it would
    /// bring about a fifth of red and take blue down to about 0.8.
    private func isBlue(_ color: NSColor) -> Bool {
        color.redComponent < 0.08 && color.blueComponent > 0.95
    }

    private func box(_ placement: SlideImage.Placement) -> SlideImage {
        var field = SlideImage(text: "", box: .achtung, frame: CGRect(x: 200, y: 120, width: 320, height: 165), placement: placement)
        field.boxFrame = .filled
        return field
    }

    private func bluePicture(_ placement: SlideImage.Placement) throws -> SlideImage {
        SlideImage(source: try picture(red: 0, green: 0, blue: 1), frame: CGRect(x: 300, y: 140, width: 200, height: 125), placement: placement)
    }

    @Test func aPictureAboveABoxStaysAboveItInThePDF() async throws {
        // The later element lies on top, as on the screen.
        #expect(isBlue(try await overlapColor([box(.front), try bluePicture(.front)])))
        #expect(!isBlue(try await overlapColor([try bluePicture(.front), box(.front)])))
    }

    @Test func behindTheTextTheOrderHoldsToo() async throws {
        #expect(isBlue(try await overlapColor([box(.behind), try bluePicture(.behind)])))
        #expect(!isBlue(try await overlapColor([try bluePicture(.behind), box(.behind)])))
    }

    // MARK: What an instruction in the bar means

    private struct Case: CustomTestStringConvertible {
        let text: String
        let kind: PresenterIntent.Kind?
        var withNotes = false
        var presents = false
        var anew = false
        var thisSlide = false
        var testDescription: String { text }
    }

    private static let cases: [Case] = [
        // A whole presentation.
        Case(text: "Erstelle mir eine Präsentation über Predictive Coding", kind: .createDeck),
        Case(text: "Mach eine Präsentation zum Thema Wasserkreislauf", kind: .createDeck),
        Case(text: "Bau mir zehn Folien zu Photosynthese", kind: .createDeck),
        Case(text: "Erstelle 8 Folien über das Sonnensystem", kind: .createDeck),
        Case(text: "Generiere einen Foliensatz über Kant", kind: .createDeck),
        Case(text: "Schreib eine Präsentation über Bienen und dazu Moderatorenkarten", kind: .createDeck, withNotes: true),
        Case(text: "Erstelle eine Präsentation über Vulkane und trag sie vor", kind: .createDeck, presents: true),
        Case(text: "Füge weitere Folien zur Geschichte Roms hinzu", kind: .createDeck),
        Case(text: "Kannst du eine Präsentation über Jazz erstellen?", kind: .createDeck),
        Case(text: "Entwirf einen Vortrag über den Klimawandel", kind: .createDeck),
        Case(text: "Leg eine neue Präsentation über Datenbanken an", kind: .createDeck),
        // Speaker cards.
        Case(text: "Schreib Moderatorenkarten", kind: .speakerNotes),
        Case(text: "Erstelle die Moderatorenkarten für alle Folien", kind: .speakerNotes),
        Case(text: "Schreib alle Moderatorenkarten neu", kind: .speakerNotes, anew: true),
        Case(text: "Moderatorenkarten bitte", kind: .speakerNotes),
        Case(text: "Schreib Moderatorenkarten und trag sie vor", kind: .speakerNotes, presents: true),
        Case(text: "Schreib die Moderatorenkarte für diese Folie", kind: .speakerNotes, thisSlide: true),
        Case(text: "Moderatorenkarten für alle Folien", kind: .speakerNotes),
        // Presenting.
        Case(text: "Trag die Präsentation vor", kind: .present, presents: true),
        Case(text: "Präsentiere die Folien", kind: .present, presents: true),
        Case(text: "Führ sie mir vor", kind: .present, presents: true),
        Case(text: "Starte den Vortrag", kind: .present, presents: true),
        Case(text: "Kannst du sie jetzt vortragen?", kind: .present, presents: true),
        // Text on this slide, questions, explanations: nothing about the whole presentation.
        Case(text: "Mach die Stichpunkte kürzer, wie in einer Präsentation über Biologie", kind: nil),
        Case(text: "Erkläre auf dieser Folie, wie man Daten präsentiert", kind: nil),
        Case(text: "Formuliere den Text präsentierbarer", kind: nil),
        Case(text: "Ergänze ein Beispiel zu den slides von gestern", kind: nil),
        Case(text: "Schreib einen Satz über Planeten unter die Überschrift", kind: nil),
        Case(text: "Das ist keine Präsentation über Politik, mach den Ton sachlicher", kind: nil),
        Case(text: "Trag das Datum vor dem Titel ein", kind: nil),
        Case(text: "Die Moderatorenkarte ist zu lang.", kind: nil),
        Case(text: "Was steht in der Moderatorenkarte?", kind: nil),
        Case(text: "Wie erstellt man eine gute Präsentation über Statistik?", kind: nil),
        Case(text: "Ergänze die Folien zur Einleitung um ein Beispiel", kind: nil),
        Case(text: "Schreib entweder drei Punkte oder zwei", kind: nil),
        Case(text: "Füge ein Bild vom Bauhaus ein", kind: nil),
    ]

    @Test(arguments: cases)
    private func anInstructionIsReadAsMeant(_ example: Case) {
        let intent = PresenterIntent.detect(example.text)
        #expect(intent?.kind == example.kind)
        guard let intent, example.kind != nil else { return }
        #expect(intent.withNotes == example.withNotes)
        #expect(intent.presents == example.presents)
        #expect(intent.rewritesNotes == example.anew)
        #expect(intent.thisSlide == example.thisSlide)
    }

    @Test func aCardForThisSlideIsWrittenForThisSlideOnly() async throws {
        let server = try FakeLLMServer()
        server.respond = { _ in "Eine Karte." }
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.cancelSpeakerNotes()
            h.app.closeDocument()
            h.app.endpoint = old
            server.stop()
        }
        h.app.newPresentation()
        let id = try #require(h.app.selectedDocumentID)
        let first = try #require(h.app.document(id)?.deck?.slides.first?.id)
        h.app.updateSlide(id, first, markdown: "# Titel")
        let second = try #require(h.app.addSlide(to: id, after: first, markdown: "# Zweite"))
        #expect(h.app.selectedSlideID == second)
        let intent = try #require(PresenterIntent.detect("Schreib die Moderatorenkarte für diese Folie"))
        h.app.runPresenterIntent(intent, instruction: "", in: id)
        await h.app.notesTask?.value
        let slides = try #require(h.app.document(id)?.deck?.slides)
        #expect(slides.first { $0.id == second }?.notes == "Eine Karte.")
        #expect(slides.first { $0.id == first }?.notes.isEmpty == true)
    }

    // MARK: The handout writes out the section it means

    private func section(_ heading: String, points: String) -> HandoutSection {
        HandoutSection(slideID: UUID(), headingLine: heading, title: heading, chapter: nil, points: points, notes: "")
    }

    @Test func aChangedSectionIsLeftAloneAndNotAnotherOneWithTheSamePoints() {
        let markdown = "# Eins\n\nMein eigener Text.\n\n# Zwei\n\n- A\n- B\n"
        #expect(HandoutBuilder.replacing(section("# Eins", points: "- A\n- B"), with: "Prosa.", in: markdown) == nil)
    }

    @Test func sectionsWithTheSameHeadingAreFoundInTurn() throws {
        var markdown = "# Gleich\n\n- A\n\n# Gleich\n\n- A\n"
        markdown = try #require(HandoutBuilder.replacing(section("# Gleich", points: "- A"), with: "Erste.", in: markdown))
        markdown = try #require(HandoutBuilder.replacing(section("# Gleich", points: "- A"), with: "Zweite.", in: markdown))
        #expect(markdown == "# Gleich\n\nErste.\n\n# Gleich\n\nZweite.\n")
    }

    @Test func aSlidePictureBetweenHeadingAndPointsIsNoObstacle() {
        let markdown = "**Titel**\n\n# Thema\n\n![Folie 2](Bilder/folie.png)\n\n- A\n- B\n\nKarte.\n"
        #expect(HandoutBuilder.replacing(section("# Thema", points: "- A\n- B"), with: "Prosa.", in: markdown)
            == "**Titel**\n\n# Thema\n\n![Folie 2](Bilder/folie.png)\n\nProsa.\n\nKarte.\n")
    }
}
}
