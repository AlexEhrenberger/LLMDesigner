import Testing
import AppKit
import Darwin
@testable import LLMDesigner

/// Measurements of Presenter Studio's costs, run only with `LLMD_BENCH=1 scripts/test.sh --filter PresenterBenchmark`:
/// they take a while and print numbers instead of checking them. What they measure is what happens on the main thread
/// while the person works on a presentation of 40 slides.
extension ActionSuites {
@MainActor
@Suite("Presenter: Messungen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LLMD_BENCH"] != nil))
struct PresenterBenchmarkTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    /// The memory the process uses, as Activity Monitor counts it.
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// A presentation of 40 slides: title, 4 chapters, 35 slides with a heading and four points.
    private func fortySlides() -> WriterDocument.ID {
        var slides = [PresentationSlide(role: .title, markdown: "# Messung {.chapter}\n\nVierzig Folien")]
        for chapter in 1...4 {
            slides.append(PresentationSlide(role: .chapter, markdown: "# Kapitel \(chapter) {.chapter}"))
            for number in 1...(chapter == 4 ? 8 : 9) {
                slides.append(PresentationSlide(role: .content, markdown: "# Folie \(chapter).\(number)\n\n" + (1...4).map { "- Punkt \($0) mit ein paar Wörtern" }.joined(separator: "\n")))
            }
        }
        var document = WriterDocument.newPresentation()
        document.title = "Messung \(UUID().uuidString)"
        document.hasCustomTitle = true
        document.deck = PresentationDeck(slides: slides)
        h.app.documents.insert(document, at: 0)
        return document.id
    }

    /// What the slide list asks for each of its rows when it is drawn again.
    private func stripPass(_ document: WriterDocument) -> Int {
        guard let deck = document.deck else { return 0 }
        var drawn = 0
        for slide in deck.slides {
            let background = deck.background(of: slide)
            let palette = SlideLook.palette(background, role: slide.role)
            _ = SlideLook.fieldLook(of: slide, in: deck, family: document.font)
            _ = deck.chapter(of: slide.id)
            // As `SlideThumbnail` asks: one picture per slide and font.
            if SlideThumbnailRenderer.image(markdown: slide.markdown, family: document.font, palette: palette,
                                            layout: WriterTextView.SlideLayout(slide: slide), citations: nil,
                                            slot: "\(slide.id.uuidString)|\(document.font.rawValue)") != nil { drawn += 1 }
        }
        return drawn
    }

    @Test func typingOnASlideForFiveMinutes() throws {
        let id = fortySlides()
        defer { h.app.deleteDocument(id) }
        let slideID = try #require(h.app.document(id)?.deck?.slides[6].id)
        _ = stripPass(try #require(h.app.document(id)))
        let before = footprintMB()
        let started = Date()
        // One flush per pause of 350 ms: about 850 in five minutes.
        var markdown = h.app.document(id)!.deck!.slide(slideID)!.markdown
        for word in 0..<850 {
            markdown += word % 8 == 0 ? "\n- Neuer Punkt" : " wort\(word)"
            // The app's run loop empties the pool after each event; a loop in a test has to do it itself.
            autoreleasepool {
                h.app.updateSlide(id, slideID, markdown: markdown)
                _ = stripPass(h.app.document(id)!)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "MESSUNG Tippen 5 min (850 Pausen, 40 Folien): Speicher +%.0f MB, %.1f ms je Pause", footprintMB() - before, seconds / 850 * 1000))
    }

    @Test func oneFlushWithFortySlides() throws {
        let id = fortySlides()
        defer { h.app.deleteDocument(id) }
        let slideID = try #require(h.app.document(id)?.deck?.slides[6].id)
        _ = stripPass(try #require(h.app.document(id)))
        // The model's part (the change, the title, the text of the whole presentation) and the list's part without
        // drawing: the slide with the change is drawn anew each time, measured above.
        var model = 0.0
        var list = 0.0
        for round in 0..<200 {
            var start = Date()
            h.app.updateSlide(id, slideID, markdown: "# Folie 1.6\n\n- Punkt \(round)")
            model += Date().timeIntervalSince(start)
            let document = try #require(h.app.document(id))
            start = Date()
            for slide in document.deck!.slides {
                let deck = document.deck!
                _ = SlideLook.palette(deck.background(of: slide), role: slide.role)
                _ = SlideLook.fieldLook(of: slide, in: deck, family: document.font)
                _ = deck.chapter(of: slide.id)
            }
            list += Date().timeIntervalSince(start)
        }
        print(String(format: "MESSUNG Pause mit 40 Folien: Modell %.3f ms, Folienleiste ohne Zeichnen %.3f ms", model / 200 * 1000, list / 200 * 1000))
    }

    @Test func typingTwentyLettersOnTheCard() async throws {
        let id = fortySlides()
        defer { h.app.deleteDocument(id) }
        let slideID = try #require(h.app.document(id)?.deck?.slides[6].id)
        // The card as the editor below the slide has it; every change of the presentation redraws the whole screen.
        let coordinator = SpeakerNotesEditor.Coordinator()
        let textView = NSTextView()
        coordinator.textView = textView
        var changes = 0
        coordinator.onChange = { [h] notes in
            changes += 1
            h.app.setSlideNotes(id, slideID, notes)
        }
        for letter in "Zwanzig Buchstaben.." {
            textView.string.append(letter)
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        }
        try await Task.sleep(for: .milliseconds(600))
        print("MESSUNG Karte 20 Tasten: \(changes) Änderung(en) der Präsentation")
    }

    @Test func lookingUpDesigns() {
        let background = SlideBackground.design(SlideDesign.defaultID)
        let start = Date()
        for _ in 0..<10_000 { _ = SlideLook.palette(background, role: .content) }
        print(String(format: "MESSUNG Design nachschlagen: %.2f µs je Aufruf", Date().timeIntervalSince(start) / 10_000 * 1_000_000))
    }

    @Test func aPDFOfThirteenSlides() async throws {
        let id = fortySlides()
        defer { h.app.deleteDocument(id) }
        let document = try #require(h.app.document(id))
        let deck = PresentationDeck(slides: Array(document.deck!.slides.prefix(13)), backgrounds: document.deck!.backgrounds)
        let start = Date()
        let data = await SlidePrinter.pdf(deck: deck, title: "Messung", family: document.font, citations: nil)
        print(String(format: "MESSUNG PDF 13 Folien zeichnen: %.1f s, %.0f KB", Date().timeIntervalSince(start), Double(data?.count ?? 0) / 1024))
    }
}
}
