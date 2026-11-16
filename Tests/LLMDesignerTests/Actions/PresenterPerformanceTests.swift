import Testing
import AppKit
@testable import LLMDesigner

/// What keeps Presenter Studio light: caches with a limit and one thumbnail per slide, designs looked up without the
/// disk, the speaker card handed over after a pause, the PDF drawn with a count and a way to stop.
extension ActionSuites {
@MainActor
@Suite("Presenter: Speicher und Tempo", .serialized)
struct PresenterPerformanceTests {
    let h = ActionHarness()

    init() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_SLIDE_DESIGNS", root.appendingPathComponent("Resources/SlideDesigns").path, 1)
    }

    private func image() -> NSImage { NSImage(size: NSSize(width: 10, height: 10)) }

    // MARK: Caches

    @Test func theCacheKeepsToItsLimitAndDropsTheOldestFirst() {
        var cache = DrawingCache(costLimit: 300)
        cache.insert(image(), for: "a", cost: 100)
        cache.insert(image(), for: "b", cost: 100)
        cache.insert(image(), for: "c", cost: 100)
        // "a" was used again, so "b" is the oldest now.
        _ = cache.image("a")
        cache.insert(image(), for: "d", cost: 100)
        #expect(cache.totalCost == 300)
        #expect(cache.image("b") == nil)
        #expect(cache.image("a") != nil && cache.image("c") != nil && cache.image("d") != nil)
    }

    @Test func aSlotKeepsOnlyItsLatestPicture() {
        var cache = DrawingCache(costLimit: 10_000)
        for version in 0..<50 { cache.insert(image(), for: "folie-1|v\(version)", cost: 10, slot: "folie-1") }
        #expect(cache.count == 1)
        #expect(cache.image("folie-1|v49") != nil)
        // Two slides with the same text share the picture: changing one leaves the other's.
        cache.insert(image(), for: "gleich", cost: 10, slot: "folie-2")
        cache.insert(image(), for: "gleich", cost: 10, slot: "folie-3")
        cache.insert(image(), for: "anders", cost: 10, slot: "folie-2")
        #expect(cache.image("gleich") != nil)
    }

    @Test func typingOnASlideLeavesOneThumbnail() {
        SlideThumbnailRenderer.removeAll()
        let slot = UUID().uuidString
        let palette = SlideLook.palette(.standard, role: .content)
        let layout = WriterTextView.SlideLayout(slide: PresentationSlide(role: .content))
        for pause in 0..<30 {
            autoreleasepool {
                _ = SlideThumbnailRenderer.image(markdown: "# Folie\n\n- Punkt \(pause)", family: .sans, palette: palette, layout: layout, citations: nil, slot: slot)
            }
        }
        #expect(SlideThumbnailRenderer.count == 1)
        // 720 × 405 pixels.
        #expect(SlideThumbnailRenderer.totalCost == 720 * 405 * 4)
    }

    // MARK: Designs

    @Test func lookingUpADesignDoesNotAskTheDisk() {
        _ = SlideLook.palette(.standard, role: .content)
        let start = Date()
        for _ in 0..<10_000 { _ = SlideLook.palette(.standard, role: .content) }
        // It took about 140 µs a call, two hundred calls a drawing of the slide list.
        #expect(Date().timeIntervalSince(start) < 0.3)
    }

    @Test func aDesignSavedInPlaceShowsWithinASecond() async throws {
        let folder = SlideDesignLibrary.userFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "probe-\(UUID().uuidString.prefix(8).lowercased())"
        let file = folder.appendingPathComponent(id + ".css")
        defer { try? FileManager.default.removeItem(at: file) }
        try "/*\n * @name Probe\n */\nbody { background: #111111; }".write(to: file, atomically: true, encoding: .utf8)
        SlideDesignLibrary.shared.reloadIfNeeded(force: true)
        #expect(SlideDesignLibrary.shared.design(id)?.css.contains("#111111") == true)
        // Saved in place, as editors do: the folder's own date stays.
        try await Task.sleep(for: .milliseconds(20))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("/*\n * @name Probe\n */\nbody { background: #222222; }".utf8))
        try handle.close()
        try await Task.sleep(for: .seconds(SlideDesignLibrary.lookInterval + 0.2))
        #expect(SlideDesignLibrary.shared.design(id)?.css.contains("#222222") == true)
    }

    // MARK: The speaker card

    @Test func theCardIsHandedOverAfterAPause() async throws {
        let coordinator = SpeakerNotesEditor.Coordinator()
        let textView = NSTextView()
        coordinator.textView = textView
        var written: [String] = []
        coordinator.onChange = { written.append($0) }
        for letter in "Zwanzig Buchstaben.." {
            textView.string.append(letter)
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        }
        #expect(written.isEmpty)
        #expect(coordinator.hasPendingEdits)
        try await Task.sleep(for: .milliseconds(600))
        #expect(written == ["Zwanzig Buchstaben.."])
        #expect(!coordinator.hasPendingEdits)
    }

    @Test func anythingThatChangesThePresentationTakesTheCardFirst() {
        let coordinator = SpeakerNotesEditor.Coordinator()
        let textView = NSTextView()
        coordinator.textView = textView
        var written: [String] = []
        coordinator.onChange = { written.append($0) }
        coordinator.register(in: h.app)
        defer { coordinator.unregister() }
        textView.string = "Noch nicht übergeben"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        // The model writing a card, a slide added, an export: all call flushEdits first.
        h.app.flushEdits()
        #expect(written == ["Noch nicht übergeben"])
    }

    // MARK: The PDF

    private func deck(_ count: Int) -> PresentationDeck {
        var deck = PresentationDeck(slides: (1...count).map { PresentationSlide(role: .content, markdown: "# Folie \($0)") })
        deck.backgrounds = .all(.color("#202020"))
        return deck
    }

    @Test func thePDFCountsItsSlides() async throws {
        var counted: [Int] = []
        let data = await SlidePrinter.pdf(deck: deck(3), title: "Zählen", family: .sans, citations: nil) { done, total in
            #expect(total == 3)
            counted.append(done)
        }
        #expect(data != nil)
        #expect(counted == [0, 1, 2])
    }

    @Test func aStoppedPDFWritesNothing() async throws {
        let task = Task { @MainActor in await SlidePrinter.pdf(deck: deck(5), title: "Stopp", family: .sans, citations: nil) }
        task.cancel()
        #expect(await task.value == nil)
    }
}
}
