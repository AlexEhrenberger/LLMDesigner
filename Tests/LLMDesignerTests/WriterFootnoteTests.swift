import Testing
import AppKit
import PDFKit
@testable import LLMDesigner

@Suite("Fußnoten, Unterstreichung im Druck und Code-Ansicht")
struct WriterFootnoteTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    private func notes(in text: NSAttributedString) -> [String] {
        var result: [String] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let note = value as? WriterFootnoteAttachment { result.append(note.text) }
        }
        return result
    }

    private func body(_ markdown: String, typeface: WriterFont? = nil) -> String {
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        let tex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native, typeface: typeface)
        return tex.components(separatedBy: "\\begin{document}").last ?? ""
    }

    // MARK: Markdown

    @Test func footnoteBecomesOneObjectAndRoundTrips() {
        let markdown = "Ein Satz mit Anmerkung.^[Eine *kursive* Anmerkung mit [Klammern] und $x^2$.] Weiter.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(notes(in: text) == ["Eine *kursive* Anmerkung mit [Klammern] und $x^2$."])
        #expect(!text.string.contains("^["))
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func severalFootnotesKeepTheirOrder() {
        let markdown = "Erstens.^[Eins.] Zweitens.^[Zwei.]\n\n- Punkt^[Drei.]\n"
        #expect(notes(in: WriterMarkdown.attributedString(from: markdown)) == ["Eins.", "Zwei.", "Drei."])
        #expect(WriterFootnotes.notes(in: markdown) == ["Eins.", "Zwei.", "Drei."])
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func escapedOrEmptyCaretBracketStaysText() {
        for markdown in ["Kein ^\\[Hinweis\\] hier.\n", "Leer ^[] bleibt.\n", "Offen ^[ohne Ende\n"] {
            let text = WriterMarkdown.attributedString(from: markdown)
            #expect(notes(in: text).isEmpty)
        }
        // Text the user typed that looks like a footnote is escaped when it is written.
        let typed = NSAttributedString(string: "Potenz ^[a]", attributes: [.writerBlock: WriterBlock.paragraph.rawValue])
        let written = WriterMarkdown.markdown(from: typed)
        #expect(notes(in: WriterMarkdown.attributedString(from: written)).isEmpty)
    }

    @Test func footnoteLeavesTheUnderline() {
        let text = WriterMarkdown.attributedString(from: "<u>unterstrichen^[Anmerkung.] weiter</u>\n")
        #expect(notes(in: text) == ["Anmerkung."])
        let written = roundTrip("<u>unterstrichen^[Anmerkung.] weiter</u>\n")
        #expect(written.contains("</u>^[Anmerkung.]"))
        #expect(!written.contains("<u>unterstrichen^["))
    }

    @Test func unbalancedBracketsAreEscaped() {
        #expect(WriterFootnotes.markdown("Siehe ] oben") == "^[Siehe \\] oben]")
        #expect(WriterFootnotes.markdown("Zeile\nzwei") == "^[Zeile zwei]")
        #expect(WriterFootnotes.markdown("Mit [Link](https://example.org)") == "^[Mit [Link](https://example.org)]")
        let markdown = "Text" + WriterFootnotes.markdown("Siehe ] oben") + "\n"
        #expect(notes(in: WriterMarkdown.attributedString(from: markdown)).count == 1)
    }

    // MARK: LaTeX

    @Test func footnoteBecomesLaTeXFootnote() {
        let tex = body("Satz.^[Eine *kursive* Anmerkung mit {Klammer}.] Weiter.\n")
        #expect(tex.contains("Satz.\\protect\\footnote{Eine \\emph{kursive} Anmerkung mit \\{Klammer\\}.} Weiter."))
        #expect(tex.filter { $0 == "{" }.count == tex.filter { $0 == "}" }.count)
    }

    @Test func footnoteInsideUnderlineAndColourStandsOutside() {
        let tex = body("<span style=\"color:#C0392B\"><u>rot^[Notiz.] weiter</u></span>\n")
        #expect(tex.contains("\\textcolor[HTML]{C0392B}{\\uline{rot}}\\protect\\footnote{Notiz.}"))
        #expect(tex.filter { $0 == "{" }.count == tex.filter { $0 == "}" }.count)
    }

    /// The bug from the screenshot: an underlined passage in a font span ran out of the page in one line, because the
    /// font's group inside \uline made it one unbreakable box.
    @Test func underlineInsideFontSpanCanBreak() {
        let tex = body("<span style=\"font-family:'Hoefler Text'\">Vorher. <u>Ein langer unterstrichener Satz.</u> Danach.</span>\n")
        #expect(tex.contains("\\uline{Ein langer unterstrichener Satz.}"))
        #expect(!tex.contains("\\uline{{"))
    }

    @Test func underlinedPassageBreaksInPrint() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let sentence = String(repeating: "Hier waren sie nun gleich unter den Gleichen, frei unter den Freien. ", count: 4)
        let markdown = "<span style=\"font-family:'Georgia'\">Anfang. <u>\(sentence)</u> Ende.^[Eine Fußnote unten.]</span>\n"
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        let pdf = try await engine.makePDF(parts: [part], paper: .a5, typeface: .serif)
        let document = try #require(PDFDocument(data: pdf))
        let page = try #require(document.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("Eine Fußnote unten."))
        // Every line of the passage stays on the page: nothing runs past its right edge.
        let bounds = page.bounds(for: .mediaBox)
        for index in 0..<(page.string?.count ?? 0) {
            let character = page.characterBounds(at: index)
            guard character.width > 0 else { continue }
            #expect(character.maxX <= bounds.maxX)
        }
    }

    // MARK: Editor

    @MainActor @Test func editorNumbersInsertsChangesAndRemovesNotes() throws {
        let textView = WriterTextView.make()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        textView.load(markdown: "Alpha.^[Erste.] Beta.^[Zweite.]\n", family: .serif, palette: .light)
        let storage = try #require(textView.textStorage)
        func numbered() -> [String] {
            var result: [String] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let note = value as? WriterFootnoteAttachment { result.append("\(textView.footnoteNumber(of: note)):\(note.text)") }
            }
            return result
        }
        #expect(numbered() == ["1:Erste.", "2:Zweite."])

        // A note in front of the others takes number 1; the others move up.
        textView.insertFootnote("Neue.", at: NSRange(location: 0, length: 0))
        #expect(numbered() == ["1:Neue.", "2:Erste.", "3:Zweite."])
        #expect(textView.markdown.hasPrefix("^[Neue.]Alpha.^[Erste.]"))

        let second = (storage.string as NSString).range(of: "\u{FFFC}", options: [], range: NSRange(location: 1, length: storage.length - 1)).location
        textView.replaceFootnote(at: second, with: "Geändert.")
        #expect(numbered() == ["1:Neue.", "2:Geändert.", "3:Zweite."])
        textView.replaceFootnote(at: 0, with: "")
        #expect(numbered() == ["1:Geändert.", "2:Zweite."])
        #expect(textView.markdown == "Alpha.^[Geändert.] Beta.^[Zweite.]\n")
    }

    // MARK: Code view

    @MainActor @Test func engineErrorLine() {
        #expect(WriterCodeModel.line(in: "error: export.tex:42: Undefined control sequence") == 42)
        #expect(WriterCodeModel.line(in: "! Undefined control sequence.\nl.17 \\foo") == 17)
        #expect(WriterCodeModel.line(in: "LaTeX konnte das Dokument nicht setzen.") == nil)
    }
}
