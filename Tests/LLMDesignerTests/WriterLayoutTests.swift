import Testing
import AppKit
@testable import LLMDesigner

@Suite("Ausrichtung, Schriftgröße und Spaltenbreiten im Markdown")
struct WriterLayoutTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    private func alignment(in text: NSAttributedString, of word: String) -> String? {
        let range = (text.string as NSString).range(of: word)
        return text.attribute(.writerAlignment, at: range.location, effectiveRange: nil) as? String
    }

    // MARK: Alignment

    @Test func alignedParagraphsRoundTrip() {
        let markdown = "Links.\n\n::: {.center}\nMitte eins.\n\nMitte zwei.\n:::\n\n::: {.justify}\nBlocksatz.\n:::\n\n# Titel\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(alignment(in: text, of: "Links") == nil)
        #expect(alignment(in: text, of: "Mitte eins") == "center")
        #expect(alignment(in: text, of: "Mitte zwei") == "center")
        #expect(alignment(in: text, of: "Blocksatz") == "justify")
        #expect(alignment(in: text, of: "Titel") == nil)
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func alignedHeadingAndQuote() {
        let markdown = "::: {.center}\n# Das Buch {.chapter}\n:::\n\n::: {.right}\n> Ein Zitat\n:::\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(alignment(in: text, of: "Das Buch") == "center")
        #expect(text.attribute(.writerBlock, at: 0, effectiveRange: nil) as? String == WriterBlock.chapter.rawValue)
        #expect(alignment(in: text, of: "Ein Zitat") == "right")
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func divFencesAreNoBlocks() {
        // Block numbers (anchors of the outline, jumps from the analysis) don't change when text is aligned.
        let plain = MarkdownParser.parse("Eins\n\nZwei\n")
        let aligned = MarkdownParser.parse("Eins\n\n::: {.center}\nZwei\n:::\n")
        #expect(plain == aligned)
        // A lone ":::" without an open div stays text.
        #expect(MarkdownParser.parse(":::\n") == [.paragraph(":::")])
    }

    @Test func listsAndCodeTakeNoAlignment() {
        let text = WriterMarkdown.attributedString(from: "::: {.center}\n- Punkt\n\n```\ncode\n```\n:::\n")
        #expect(alignment(in: text, of: "Punkt") == nil)
        #expect(alignment(in: text, of: "code") == nil)
    }

    @Test func colonsAtLineStartAreEscaped() {
        let markdown = "\\:::\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(text.string == ":::")
        #expect(roundTrip(markdown) == markdown)
    }

    // MARK: Size

    @Test func sizeSpanRoundTrip() {
        let markdown = "Klein und <span style=\"font-size:18pt\">groß</span> und <span style=\"color:#C0392B;font-size:10.5pt\">rot</span>.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        let big = (text.string as NSString).range(of: "groß")
        #expect(text.attribute(.writerFontSize, at: big.location, effectiveRange: nil) as? Double == 18)
        #expect(text.attribute(.writerFontSize, at: 0, effectiveRange: nil) == nil)
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func cssSizes() {
        #expect(WriterSpanStyle.parseSize("14px") == 14)
        #expect(WriterSpanStyle.parseSize(" 12 ") == 12)
        #expect(WriterSpanStyle.parseSize("2em") == 22)
        #expect(WriterSpanStyle.parseSize("50%") == 5.5)
        #expect(WriterSpanStyle.parseSize("9000pt") == WriterSpanStyle.sizeRange.upperBound)
        #expect(WriterSpanStyle.parseSize("groß") == nil)
    }

    @Test func sizeIsShownLargerOnScreen() {
        let storage = NSTextStorage(attributedString: WriterMarkdown.attributedString(from: "Text <span style=\"font-size:22pt\">doppelt</span>\n"))
        WriterStyler.restyleAll(storage, family: .palatino, palette: .dark)
        let body = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        let big = (storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        // 11 pt in print is the family's body size on screen; 22 pt twice that.
        #expect(abs(body - WriterFont.palatino.bodySize) < 0.01)
        #expect(abs(big - 2 * WriterFont.palatino.bodySize) < 0.01)
        #expect(WriterStyler.printedSize(of: storage.attributes(at: 0, effectiveRange: nil), block: .paragraph, family: .palatino, palette: .dark) == 11)
    }

    @Test func alignmentBecomesParagraphStyle() {
        let storage = NSTextStorage(attributedString: WriterMarkdown.attributedString(from: "::: {.justify}\nText\n:::\n\nNoch einer\n"))
        WriterStyler.restyleAll(storage, family: .serif, palette: .dark)
        let justified = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let natural = storage.attribute(.paragraphStyle, at: storage.length - 2, effectiveRange: nil) as? NSParagraphStyle
        #expect(justified?.alignment == .justified)
        #expect(natural?.alignment == .natural)
    }

    // MARK: Column widths

    @Test func columnWidthsRoundTrip() {
        let table = WriterTable(columns: 3, alignments: [.leading, .center, .trailing], widths: [0.2, 0.3, 0.5])
        let dashes = WriterTable.dashCounts(table.widths ?? [])
        #expect(dashes == [20, 30, 50])
        let first = String(repeating: "-", count: 20)
        let second = String(repeating: "-", count: 30)
        let third = String(repeating: "-", count: 50)
        let markdown = "| A | B | C |\n| \(first) | :\(second): | \(third): |\n| 1 | 2 | 3 |\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        let parsed = text.attribute(.writerTable, at: 0, effectiveRange: nil) as? WriterTable
        #expect(parsed?.widths.map { $0.map { ($0 * 100).rounded() } } == [20, 30, 50])
        #expect(parsed?.alignments == [.leading, .center, .trailing])
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func dashesFromElsewhereKeepEqualColumns() {
        // Only dashes that add up to 100 are widths; a table from a model or another program keeps equal columns.
        let text = WriterMarkdown.attributedString(from: "| Name | Beschreibung |\n|------|--------------|\n| a | b |\n")
        #expect((text.attribute(.writerTable, at: 0, effectiveRange: nil) as? WriterTable)?.widths == nil)
        #expect(roundTrip("| a | b |\n| --- | --- |\n| 1 | 2 |\n") == "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
    }

    @Test func dashCountsAddUpToHundred() {
        let third: CGFloat = 1 / 3
        let cases: [[CGFloat]] = [[third, third, third + 0.0001], [0.07, 0.93], [0.125, 0.125, 0.25, 0.5], [0.06, 0.06, 0.06, 0.82]]
        for widths in cases {
            let counts = WriterTable.dashCounts(widths)
            #expect(counts.reduce(0, +) == 100)
            #expect(counts.allSatisfy { $0 > 0 })
        }
    }

    @Test func equalWidthsAreNone() {
        #expect(WriterTable.normalized([0.5, 0.5], columns: 2) == nil)
        #expect(WriterTable.normalized([1, 3], columns: 2) == [0.25, 0.75])
        #expect(WriterTable.normalized([0.2, 0.8], columns: 3) == nil)
    }

    // MARK: LaTeX

    @Test func latexAlignmentSizesAndWidths() {
        let markdown = """
        ::: {.center}
        # Titel
        :::

        Normal mit <span style="font-size:18pt">großem</span> Wort.

        ::: {.justify}
        Im Blocksatz.
        :::

        | A | B |
        | \(String(repeating: "-", count: 25)) | \(String(repeating: "-", count: 75)) |
        | 1 | 2 |

        """
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        let latex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native)
        #expect(latex.contains("\\begin{document}\n\\raggedright"))
        #expect(latex.contains("\\section*{\\centering Titel}"))
        #expect(latex.contains("\\fontsize{18pt}{21.6pt}\\selectfont{}"))
        #expect(latex.contains("\\setlength{\\baselineskip}{21.6pt}"))
        #expect(latex.contains("{\\llmdjustify Im Blocksatz.\\par}"))
        #expect(latex.contains("\\hsize=0.500\\hsize"))
        #expect(latex.contains("\\hsize=1.500\\hsize"))
    }

    @Test func chatExportKeepsLaTeXDefaults() {
        let latex = LaTeXWriter.document(parts: [LaTeXWriter.Part(text: "Ein Absatz.")], paper: .a4, math: .native)
        #expect(!latex.contains("\\begin{document}\n\\raggedright"))
    }
}

@Suite("Ausrichtung und Größen in anderem Satz")
struct WriterLayoutTransferTests {
    @Test func titleSkipsDivFences() {
        #expect(WriterDocument.makeTitle(from: "::: {.left}\n# Testfolie Ausrichtung\n:::\n") == "Testfolie Ausrichtung")
    }

    @Test func fencesAndSizesGoForOtherLayouts() {
        let markdown = "::: {.center}\nEin <span style=\"font-size:24pt\">großes</span> und <span style=\"color:#C0392B;font-size:9pt\">rotes</span> Wort.\n:::\n"
        #expect(WriterMarkdown.forOtherLayout(markdown) == "Ein großes und <span style=\"color:#C0392B\">rotes</span> Wort.\n")
        #expect(WriterMarkdownExport.plain(markdown).hasPrefix("Ein "))
    }
}
