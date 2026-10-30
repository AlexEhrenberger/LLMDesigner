import Testing
import AppKit
@testable import LLMDesigner

@Suite("Freie Textfelder auf Folien")
struct SlideFieldTests {
    @Test func fieldsAndTextAreaSurviveSaving() {
        var slide = PresentationSlide(role: .content, markdown: "# Titel\n\nText der Folie.")
        let field = SlideImage(text: "| A | B |\n|---|---|\n| 1 | 2 |", box: .merksatz, frame: CGRect(x: 100, y: 200, width: 300, height: 90))
        let picture = SlideImage(source: "Bilder/x.png", frame: CGRect(x: 400, y: 100, width: 200, height: 150))
        slide.images = [picture, field]
        slide.textArea = SlideArea(frame: CGRect(x: 30, y: 20, width: 400, height: 300))
        let deck = PresentationDeck(slides: [slide])

        let back = PresentationDeck.parse(deck.serialized)
        let read = try! #require(back.slides.first)
        #expect(read.markdown == slide.markdown)
        #expect(read.images.count == 2)
        #expect(read.images[0].isText == false)
        #expect(read.images[0].source == "Bilder/x.png")
        #expect(read.images[1].text == field.text)
        #expect(read.images[1].box == .merksatz)
        #expect(read.images[1].source.isEmpty)
        #expect(abs(read.images[1].frame.minX - 100) < 0.1)
        #expect(abs(read.textFrame.width - 400) < 0.1)
        #expect(read.fullMarkdown.contains("Text der Folie."))
        #expect(read.fullMarkdown.contains("| 1 | 2 |"))
    }

    @Test func oldSlidesKeepTheStandardTextArea() {
        let deck = PresentationDeck.parse("<!-- folie {\"id\":\"\(UUID().uuidString)\",\"rolle\":\"folie\"} -->\n\n# Alt\n")
        let slide = try! #require(deck.slides.first)
        #expect(slide.textArea == nil)
        #expect(slide.textFrame == SlideArea.standardFrame)
    }

    @MainActor @Test func fieldLayoutUsesItsOwnCanvas() {
        let field = SlideImage(text: "Hallo", frame: CGRect(x: 10, y: 10, width: 200, height: 80))
        let layout = WriterTextView.SlideLayout(field: field)
        #expect(layout.size == CGSize(width: 200, height: 80))
        #expect(layout.textRect.width < 200 && layout.textRect.width > 180)
        let textView = WriterTextView.make()
        textView.slideLayout = layout
        textView.load(markdown: "Hallo", family: .serif, palette: .slide(tone: .light, accent: nil))
        #expect(textView.columnWidth == layout.textRect.width)
        #expect(textView.frame.width == 200)
    }
}
