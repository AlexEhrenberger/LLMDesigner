import Testing
import AppKit
@testable import LLMDesigner

@Suite("Farben und Schriften im Markdown")
struct WriterStyleTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    @Test func colourSpanRoundTrip() {
        let markdown = "Ein <span style=\"color:#C0392B\">roter</span> Text.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(text.attribute(.writerColor, at: 5, effectiveRange: nil) as? String == "C0392B")
        #expect(text.attribute(.writerColor, at: 0, effectiveRange: nil) == nil)
        #expect(WriterMarkdown.markdown(from: text) == markdown)
    }

    @Test func fontSpanRoundTrip() {
        let markdown = "Ein <span style=\"font-family:'Georgia'\">Wort</span> hier.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(text.attribute(.writerFont, at: 5, effectiveRange: nil) as? String == "georgia")
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func colourAndFontTogether() {
        let markdown = "<span style=\"color:#1F5FBF;font-family:ui-serif\">Titel</span>\n"
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func spanWithBoldAndLink() {
        #expect(roundTrip("Ein <span style=\"color:#1E8449\">**fetter** Text</span>\n")
                == "Ein <span style=\"color:#1E8449\">**fetter**</span><span style=\"color:#1E8449\"> Text</span>\n"
                || roundTrip("Ein <span style=\"color:#1E8449\">**fetter** Text</span>\n") == "Ein <span style=\"color:#1E8449\">**fetter** Text</span>\n")
    }

    @Test func bookmarkInsideColour() {
        let markdown = "Ein <span style=\"color:#C0392B\">rot <span id=\"lz-abc12345\" title=\"Marke\">markiert</span> weiter</span>.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        let marked = (text.string as NSString).range(of: "markiert")
        #expect((text.attribute(.writerBookmark, at: marked.location, effectiveRange: nil) as? WriterBookmark)?.id == "lz-abc12345")
        #expect(text.attribute(.writerColor, at: marked.location, effectiveRange: nil) as? String == "C0392B")
        #expect(WriterBookmark.entries(in: markdown).first?.title == "Marke")
        let again = roundTrip(markdown)
        #expect(again.contains("id=\"lz-abc12345\""))
        #expect(again.contains("color:#C0392B"))
    }

    @Test func plainMarkdownDropsStyles() {
        let markdown = "Ein <span style=\"color:#C0392B\">roter</span> und <span id=\"lz-1\" title=\"x\">markierter</span> Text.\n"
        let plain = WriterSpans.strippingStyles(markdown)
        #expect(plain == "Ein roter und <span id=\"lz-1\" title=\"x\">markierter</span> Text.\n")
    }

    @Test func cssNames() {
        let text = WriterMarkdown.attributedString(from: "<span style=\"color: rgb(255, 0, 0); font-family: 'Hoefler Text', serif\">x</span>\n")
        #expect(text.attribute(.writerColor, at: 0, effectiveRange: nil) as? String == "FF0000")
        #expect(text.attribute(.writerFont, at: 0, effectiveRange: nil) as? String == "hoefler")
    }

    @Test func latexColourAndFont() {
        var part = LaTeXWriter.Part(text: "Ein <span style=\"color:#C0392B;font-family:'Georgia'\">roter **fetter** Text</span> hier.\n")
        part.figures = [:]
        let tex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native, typeface: .palatino)
        #expect(tex.contains("\\setmainfont{Palatino}"))
        #expect(tex.contains("\\newfontfamily\\llmdfontgeorgia{Georgia}"))
        #expect(tex.contains("\\textcolor[HTML]{C0392B}{{\\llmdfontgeorgia{}roter }}"))
        #expect(tex.contains("\\textbf{\\textcolor[HTML]{C0392B}{{\\llmdfontgeorgia{}fetter}}}"))
    }

    @Test func latexUnderlineAcrossRuns() {
        var part = LaTeXWriter.Part(text: "<u>a **b** c</u>\n")
        part.figures = [:]
        let tex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native)
        let body = tex.components(separatedBy: "\\begin{document}").last ?? ""
        // Braces balance, and all three words are underlined.
        #expect(body.filter { $0 == "{" }.count == body.filter { $0 == "}" }.count)
        #expect(body.contains("\\uline{a }"))
        #expect(body.contains("\\textbf{\\uline{b}}"))
    }
}
