import Testing
import Foundation
@testable import LLMDesigner

@Suite("Suchen im Dokument")
struct TextSearchTests {
    private func found(_ query: String, in text: String, _ options: TextSearch.Options = .init()) -> [String] {
        let string = text as NSString
        return TextSearch.ranges(of: query, in: text, options: options).map { string.substring(with: $0) }
    }

    @Test func ignoresCaseUnlessAsked() {
        #expect(found("haus", in: "Das Haus und das HAUS am Hausberg") == ["Haus", "HAUS", "Haus"])
        #expect(found("Haus", in: "Das Haus und das HAUS", .init(matchesCase: true)) == ["Haus"])
    }

    @Test func wholeWordsOnly() {
        let text = "Haus, Hausberg und Baumhaus – ein Haus."
        #expect(found("Haus", in: text, .init(wholeWords: true)).count == 2)
        // A query that ends in a space or a sign only needs the word boundary on its letter side.
        #expect(found("Haus,", in: text, .init(wholeWords: true)) == ["Haus,"])
    }

    @Test func typographicQuotesAndDashesMatchThePlainKeys() {
        let text = "Er sagte „Hallo“ – und ging. Don’t panic."
        #expect(found("\"Hallo\"", in: text) == ["„Hallo“"])
        #expect(found("Hallo\" - und", in: text) == ["Hallo“ – und"])
        #expect(found("don't", in: text) == ["Don’t"])
    }

    @Test func rangesStayInTheOriginalText() {
        let text = "Ein Bild \u{FFFC} und 😀 dann Zitat „Wort“ hier"
        let ranges = TextSearch.ranges(of: "\"wort\"", in: text)
        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0]) == "„Wort“")
    }

    @Test func passagesOverASoftLineBreak() {
        let text = "Ende der Zeile\u{2028}nächste Zeile"
        #expect(found("Zeile nächste", in: text) == ["Zeile\u{2028}nächste"])
    }

    @Test func emptyQueriesAndOverlaps() {
        #expect(found("", in: "abc").isEmpty)
        #expect(found("   ", in: "a   b").isEmpty)
        #expect(found("aa", in: "aaaa").count == 2)
    }
}

/// Presentations count the places of the slides that are not open from their Markdown; they must be the same
/// places the editor finds once the slide is open.
@MainActor
@Suite("Suchen auf Folien")
struct SlideSearchTextTests {
    @Test func slideTextIsTheEditorsText() {
        let markdown = """
        # Überschrift mit **fett**

        - Punkt *eins* mit „Zitat“
        - Punkt zwei mit `Code`

        1. Nummer
        2. Nummer mit [Link](https://example.com)

        > Ein Zitat\\
        > über zwei Zeilen
        """
        let textView = WriterTextView.make()
        textView.slideLayout = WriterTextView.SlideLayout(slide: PresentationSlide(markdown: markdown), images: [])
        textView.load(markdown: markdown, family: .serif, palette: .slide(tone: .light, accent: nil))
        #expect(textView.textStorage?.string == WriterMarkdown.attributedString(from: markdown).string)
    }
}
