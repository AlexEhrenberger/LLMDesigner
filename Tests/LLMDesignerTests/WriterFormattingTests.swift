import Testing
import AppKit
@testable import LLMDesigner

@Suite("Seiten, Absätze, Tabellen und Hochstellung im Markdown und im Druck")
struct WriterFormattingTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    private func attributes(in text: NSAttributedString, of word: String) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: word)
        return text.attributes(at: range.location, effectiveRange: nil)
    }

    private func latex(_ markdown: String, format: WriterPageFormat = .standard, design: WriterPageDesign = WriterPageDesign()) -> String {
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        return LaTeXWriter.document(parts: [part], paper: .a4, math: .native, format: format, design: design)
    }

    // MARK: Paragraph format

    @Test func paragraphFormatRoundTrips() {
        let markdown = "Normal.\n\n::: {.center line-spacing=1.5 indent=1cm first-line=-0.5cm}\nEingerückt eins.\n\nEingerückt zwei.\n:::\n\n::: {line-spacing=2}\n- Punkt\n- Noch einer\n:::\n\nWieder normal.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        let format = WriterParagraphFormat(attributes(in: text, of: "Eingerückt zwei"))
        #expect(format.alignment == .center)
        #expect(format.lineSpacing == 1.5)
        #expect(format.indent == 1)
        #expect(format.firstLine == -0.5)
        #expect(WriterParagraphFormat(attributes(in: text, of: "Punkt")).lineSpacing == 2)
        #expect(WriterParagraphFormat(attributes(in: text, of: "Wieder")).isEmpty)
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func headingsTakeOnlyTheirAlignment() {
        let text = WriterMarkdown.attributedString(from: "::: {.center line-spacing=2 indent=2cm}\n# Titel\n:::\n")
        let format = WriterParagraphFormat(attributes(in: text, of: "Titel")).applying(to: .heading1)
        #expect(format == WriterParagraphFormat(alignment: .center))
    }

    @Test func singleSpacingAndZeroIndentAreNone() {
        #expect(WriterParagraphFormat(lineSpacing: 1, indent: 0, firstLine: 0).isEmpty)
        #expect(WriterParagraphFormat(classes: [], attributes: ["indent": "15mm"]).indent == 1.5)
        #expect(WriterParagraphFormat(indent: 2.5).divOpening == "::: {indent=2.5cm}")
    }

    @Test func paragraphFormatInLaTeX() {
        let output = latex("::: {line-spacing=1.5 indent=1cm first-line=-0.5cm}\nHängender Absatz.\n:::\n")
        #expect(output.contains("\\linespread{1.5}\\selectfont"))
        #expect(output.contains("\\advance\\leftskip 1.5cm"))
        #expect(output.contains("\\parindent=-0.5cm"))
    }

    // MARK: Superscript, subscript, strikethrough

    @Test func raisedAndLoweredTextRoundTrips() {
        let markdown = "E = mc<sup>2</sup>, H<sub>2</sub>O und ~~weg~~.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(WriterInline(attributes(in: text, of: "2,")).contains(.superscript))
        #expect(WriterInline(attributes(in: text, of: "2O")).contains(.subscript))
        #expect(WriterInline(attributes(in: text, of: "weg")).contains(.strikethrough))
        #expect(!text.string.contains("<sup>"))
        #expect(roundTrip(markdown) == markdown)
        // An unclosed tag stays text.
        #expect(roundTrip("a <sup>b\n") == "a \\<sup>b\n")
    }

    @Test func raisedTextInLaTeX() {
        let output = latex("x<sup>2</sup> und CO<sub>2</sub>\n")
        #expect(output.contains("\\textsuperscript{2}"))
        #expect(output.contains("\\textsubscript{2}"))
        #expect(!output.contains("LLMDSU"))
    }

    // MARK: Page break

    @Test func pageBreakRoundTrips() {
        let markdown = "Seite eins.\n\n\\newpage\n\nSeite zwei.\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value is WriterPageBreakAttachment { found = true }
        }
        #expect(found)
        #expect(roundTrip(markdown) == markdown)
        #expect(roundTrip("Eins\n\n---\n\nZwei\n") == "Eins\n\n---\n\nZwei\n")
        #expect(latex(markdown).contains("\\clearpage"))
    }

    // MARK: Tables

    @Test func mergedCellsRoundTrip() {
        let markdown = """
        | Name | Wert | << |
        | --- | --- | --- |
        | a | 1 | 2 |
        | b | 3 | 4 |
        | ^^ | 5 | 6 |

        """
        let text = WriterMarkdown.attributedString(from: markdown)
        let table = text.attribute(.writerTable, at: 0, effectiveRange: nil) as? WriterTable
        #expect(table?.span(row: 0, column: 1) == WriterCellSpan(rows: 1, columns: 2))
        #expect(table?.span(row: 2, column: 0) == WriterCellSpan(rows: 2, columns: 1))
        #expect(table?.isCovered(row: 0, column: 2) == true)
        #expect(table?.isCovered(row: 3, column: 0) == true)
        // Covered places have no paragraph: 4 rows × 3 columns less the two covered ones.
        let cells = WriterMarkdown.paragraphs(of: text).filter { $0.cell != nil }
        #expect(cells.count == 10)
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func tableStyleRoundTrips() {
        let markdown = """
        ::: {.table lines=grid line-width=1 fill=0.0:FFF2CC,1.1:E2EFDA}
        | A | B |
        | --- | --- |
        | 1 | 2 |
        :::

        """
        let text = WriterMarkdown.attributedString(from: markdown)
        let table = text.attribute(.writerTable, at: 0, effectiveRange: nil) as? WriterTable
        #expect(table?.style.lines == .grid)
        #expect(table?.style.lineWidth == 1)
        #expect(table?.style.fills[WriterCellPosition(row: 1, column: 1)] == "E2EFDA")
        #expect(roundTrip(markdown) == markdown)
        // A standard table has no div.
        #expect(roundTrip("| A | B |\n| --- | --- |\n| 1 | 2 |\n") == "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
    }

    @Test func literalMarkerInCellIsEscaped() {
        let text = WriterMarkdown.attributedString(from: "| A | B |\n| --- | --- |\n| x | y |\n")
        let storage = NSMutableAttributedString(attributedString: text)
        let range = (storage.string as NSString).range(of: "y")
        storage.replaceCharacters(in: range, with: "^^")
        let markdown = WriterMarkdown.markdown(from: storage)
        #expect(markdown.contains("\\^\\^"))
        let again = WriterMarkdown.attributedString(from: markdown)
        let table = again.attribute(.writerTable, at: 0, effectiveRange: nil) as? WriterTable
        #expect(table?.spans.isEmpty == true)
        #expect(again.string.contains("^^"))
    }

    @Test func spansFollowRowsAndColumns() {
        let spans = [WriterCellPosition(row: 1, column: 0): WriterCellSpan(rows: 2, columns: 2)]
        let fills = [WriterCellPosition(row: 1, column: 0): "FFF2CC", WriterCellPosition(row: 3, column: 1): "DDEBF7"]
        // A row inside the merged cell makes it taller; one above moves it down.
        let inside = WriterTableMerge.inserting(at: 2, isRow: true, spans: spans, fills: fills)
        #expect(inside.0[WriterCellPosition(row: 1, column: 0)] == WriterCellSpan(rows: 3, columns: 2))
        #expect(inside.1[WriterCellPosition(row: 4, column: 1)] == "DDEBF7")
        let above = WriterTableMerge.inserting(at: 0, isRow: true, spans: spans, fills: fills)
        #expect(above.0[WriterCellPosition(row: 2, column: 0)] == WriterCellSpan(rows: 2, columns: 2))
        // Its first row going keeps it, one row shorter, with its colour.
        let removed = WriterTableMerge.removing(at: 1, isRow: true, spans: spans, fills: fills)
        #expect(removed.0.isEmpty == false)
        #expect(removed.0[WriterCellPosition(row: 1, column: 0)] == WriterCellSpan(rows: 1, columns: 2))
        #expect(removed.1[WriterCellPosition(row: 1, column: 0)] == "FFF2CC")
        #expect(removed.1[WriterCellPosition(row: 2, column: 1)] == "DDEBF7")
        // A column going makes a two-column cell a single one.
        let narrower = WriterTableMerge.removing(at: 1, isRow: false, spans: [WriterCellPosition(row: 0, column: 0): WriterCellSpan(rows: 1, columns: 2)], fills: [:])
        #expect(narrower.0.isEmpty)
        let area = WriterTableMerge.enclosingRectangle(WriterCellPosition(row: 0, column: 1), WriterCellPosition(row: 1, column: 1), spans: spans)
        #expect(area == (top: 0, left: 0, bottom: 2, right: 1))
    }

    @Test func styledTableInLaTeX() {
        let markdown = """
        ::: {.table lines=grid fill=1.0:FFF2CC}
        | Name | Wert | << |
        | --- | --- | --- |
        | a | 1 | 2 |
        | ^^ | 3 | 4 |
        :::

        """
        let output = latex(markdown)
        #expect(output.contains("\\multicolumn{2}"))
        #expect(output.contains("\\multirow{-2}{=}{\\raggedright a}"))
        #expect(output.contains("\\cellcolor[HTML]{FFF2CC}"))
        #expect(output.contains("\\cline{2-3}"))
        #expect(output.contains("{|L|L|L|}"))
        // Chats keep the book table, marks and all.
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = nil
        let chat = LaTeXWriter.document(parts: [part], paper: .a4, math: .native)
        #expect(chat.contains("\\toprule"))
        #expect(!chat.contains("\\multicolumn"))
    }

    // MARK: Pages

    @Test func pageSetupAndRunningHeadsAreStored() {
        var document = WriterDocument()
        document.markdown = "Text\n"
        document.pageFormat = .custom
        document.pageSetup = WriterPageSetup(name: "Bericht", paperWidth: 148, paperHeight: 210, top: 20, bottom: 22, left: 18, right: 18, fontSize: 12, lineSpacing: 1.5)
        document.runningHeads = WriterRunningHeads(header: .init(left: "{Titel}", center: "", right: "{Kapitel}"),
                                                   footer: .init(left: "", center: "Seite {Seite} von {Seiten}", right: ""), skipsFirstPage: true, hasRules: true)
        let decoded = WriterDocumentStore.decode(WriterDocumentStore.encode(document), fallbackID: nil)
        #expect(decoded?.pageFormat == .custom)
        #expect(decoded?.pageSetup == document.pageSetup)
        #expect(decoded?.runningHeads == document.runningHeads)
        #expect(decoded?.markdown == "Text\n")
    }

    @Test func customPageInLaTeX() {
        let setup = WriterPageSetup(name: "A5", paperWidth: 148, paperHeight: 210, top: 20, bottom: 22, left: 18, right: 16, fontSize: 12, lineSpacing: 1.5)
        let heads = WriterRunningHeads(header: .init(left: "{Titel}", center: "", right: "{Kapitel}"),
                                       footer: .init(left: "", center: "Seite {Seite} von {Seiten}", right: ""), skipsFirstPage: true)
        let output = latex("# Erstes\n\nText.\n", format: .custom, design: WriterPageDesign(setup: setup, runningHeads: heads, title: "Mein & Bericht"))
        #expect(output.contains("\\documentclass[12pt]"))
        #expect(output.contains("paperwidth=148.00mm,paperheight=210.00mm,top=20.00mm,bottom=22.00mm,left=18.00mm,right=16.00mm"))
        #expect(output.contains("\\linespread{1.5}"))
        #expect(output.contains("\\fancyhead[L]{\\ifnum\\value{page}>1 Mein \\& Bericht\\fi}"))
        #expect(output.contains("Seite \\thepage{} von \\pageref*{LastPage}"))
        #expect(output.contains("\\llmdmark{Erstes}"))
        #expect(output.contains("\\fancypagestyle{plain}"))
    }

    @Test func runningHeadsResolve() {
        let text = WriterRunningHeads.resolve("{Titel} – Seite {Seite} von {Seiten} – {Kapitel}", page: 2, pages: 9, title: "Roman", chapter: "Anfang")
        #expect(text == "Roman – Seite 2 von 9 – Anfang")
    }

    @Test func pageSetupKeepsRoomForText() {
        let setup = WriterPageSetup(paperWidth: 100, paperHeight: 120, top: 60, bottom: 60, left: 50, right: 50).normalized()
        #expect(setup.paperWidth - setup.left - setup.right >= 39.9)
        #expect(setup.paperHeight - setup.top - setup.bottom >= 39.9)
    }
}
