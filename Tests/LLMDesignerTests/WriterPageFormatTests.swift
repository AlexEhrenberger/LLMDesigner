import AppKit
import PDFKit
import Testing
@testable import LLMDesigner

/// Neutral filler text: paragraphs of different lengths from a fixed list of words.
private func fillerParagraphs(_ count: Int) -> [String] {
    let words = ["Der", "Morgen", "lag", "still", "über", "dem", "Hafen,", "und", "die", "Boote", "schaukelten", "leise",
                 "im", "grauen", "Wasser.", "Niemand", "sprach", "ein", "Wort,", "während", "die", "Möwen", "kreisten",
                 "und", "der", "Wind", "langsam", "drehte."]
    return (0..<count).map { index in
        let length = 25 + (index * 17) % 60
        return (0..<length).map { words[($0 + index * 7) % words.count] }.joined(separator: " ")
    }
}

@Suite("Seitenformat: Taschenbuch und Normseite")
struct WriterPageFormatTests {
    @Test func formatIsKeptInTheFrontMatter() {
        var document = WriterDocument()
        document.markdown = "Ein Absatz.\n"
        #expect(!WriterDocumentStore.encode(document).contains("format:"))
        for format in [WriterPageFormat.paperback, .manuscript] {
            document.pageFormat = format
            let decoded = WriterDocumentStore.decode(WriterDocumentStore.encode(document), fallbackID: nil)
            #expect(decoded?.pageFormat == format)
            #expect(decoded?.markdown == document.markdown)
        }
    }

    @Test func manuscriptIsSetInCourier() {
        var document = WriterDocument()
        document.font = .georgia
        document.pageFormat = .manuscript
        #expect(document.textFont == .courier)
        document.pageFormat = .paperback
        #expect(document.textFont == .georgia)
    }

    @Test func manuscriptLaTeX() {
        var part = LaTeXWriter.Part(text: "# Kapitel\n\nErster Absatz.\n\nZweiter Absatz.\n")
        part.figures = [:]
        let latex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native, typeface: .courier, format: .manuscript)
        #expect(latex.contains("\\documentclass[12pt]"))
        // 60 characters of 7.2 pt and a hair; 30 lines of 20.4 pt below the first line's 12 pt, and a point of slack.
        #expect(latex.contains("textwidth=433.00pt"))
        #expect(latex.contains("textheight=604.60pt"))
        #expect(latex.contains("\\linespread{1.4069}"))
        #expect(latex.contains("\\setmainfont{Courier New}"))
        #expect(!latex.contains("\\usepackage{parskip}"))
        #expect(latex.contains("\\begin{document}\n\\raggedright\n\\setlength{\\parindent}{36.00pt}"))
        #expect(latex.contains("\\hyphenpenalty=10000"))
    }

    @Test func paperbackLaTeX() {
        var part = LaTeXWriter.Part(text: "Ein Absatz im Blocksatz.\n\n::: {.left}\nEin Absatz links.\n:::\n")
        part.figures = [:]
        let latex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native, format: .paperback)
        #expect(latex.contains("\\documentclass[10pt]"))
        #expect(latex.contains("paperwidth=125mm,paperheight=190mm"))
        #expect(latex.contains("textheight=426.80pt"))
        #expect(latex.contains("\\setlength{\\parindent}{1em}"))
        #expect(!latex.contains("\\begin{document}\n\\raggedright"))
        #expect(latex.contains("{\\raggedright Ein Absatz links.\\par}"))
    }

    @Test func standardStaysAsItWas() {
        var part = LaTeXWriter.Part(text: "Ein Absatz.\n")
        part.figures = [:]
        let latex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native)
        #expect(latex.contains("\\documentclass[11pt]"))
        #expect(latex.contains("a4paper,margin=2.5cm"))
        #expect(latex.contains("\\usepackage{parskip}"))
        #expect(!latex.contains("\\linespread"))
    }

    /// The editor sets a Normseite as the print does: lines of at most 60 characters, 30 of them on a page.
    @MainActor @Test func editorCountsNormseiten() throws {
        let markdown = fillerParagraphs(40).joined(separator: "\n\n") + "\n"
        let textView = WriterTextView.make()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        textView.load(markdown: markdown, family: .courier, palette: WriterPalette.dark.with(format: .manuscript))
        textView.updatePages()
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let string = textView.string as NSString
        var lines: [(text: String, top: CGFloat)] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append((string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), rect.minY))
        }
        #expect(lines.allSatisfy { $0.text.count <= 60 })
        // The lines are filled: a long paragraph has lines close to 60 characters.
        #expect(lines.map(\.text.count).max() ?? 0 >= 56)
        let breaks = textView.pageBreaks
        #expect(breaks.count == (lines.count - 1) / 30)
        // The second page begins with the 31st line.
        if let first = breaks.first, lines.count > 30 {
            #expect(first.y > lines[29].top && first.y <= lines[30].top + 0.5)
        }
        #expect(textView.reportedPageCount?.pages == breaks.count + 1)
    }

    /// Chapters, headings, lists, quotes, tables and formulas set in both book formats (skipped without a LaTeX engine).
    @Test func booksWithChaptersCompile() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let paragraphs = fillerParagraphs(12)
        let markdown = """
        # Erstes Kapitel {.chapter}

        \(paragraphs[0])

        \(paragraphs[1])

        ## Ein Abschnitt

        \(paragraphs[2])

        - Ein Punkt
        - Noch ein Punkt

        > \(paragraphs[3])

        ---

        \(paragraphs[4])

        ### Ein Unterabschnitt

        | A | B |
        | --- | --- |
        | 1 | 2 |

        $$a^2 + b^2 = c^2$$

        # Zweites Kapitel {.chapter}

        \(paragraphs[5...].joined(separator: "\n\n"))

        """
        for format in [WriterPageFormat.paperback, .manuscript] {
            var part = LaTeXWriter.Part(text: markdown)
            part.figures = [:]
            let pdf = try await engine.makePDF(parts: [part], paper: .a4, typeface: format.font(.georgia), format: format)
            if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
                try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("buch-\(format.rawValue).pdf"))
            }
            let document = try #require(PDFDocument(data: pdf))
            // The second chapter begins a page of its own.
            #expect(document.pageCount >= 2)
            // The editor counts the pages of the print: exactly on a Normseite, about in a paperback (TeX justifies
            // and hyphenates its own way).
            let editorPages = await MainActor.run { () -> Int? in
                let textView = WriterTextView.make()
                textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
                textView.load(markdown: markdown, family: format.font(.georgia), palette: WriterPalette.dark.with(format: format))
                textView.updatePages()
                return textView.reportedPageCount?.pages
            }
            print("Seiten \(format.rawValue): Editor \(editorPages ?? 0), Druck \(document.pageCount)")
            if format == .manuscript {
                #expect(editorPages == document.pageCount)
            } else {
                #expect(abs((editorPages ?? 0) - document.pageCount) <= 1)
            }
            let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
            if format == .paperback {
                #expect(abs(size.width - 125 * 72 / 25.4) < 1 && abs(size.height - 190 * 72 / 25.4) < 1)
            } else {
                #expect(abs(size.width - 595.28) < 1)
            }
        }
    }

    /// The print of a Normseite has 30 lines of at most 60 characters on a page (skipped without a LaTeX engine).
    @Test func printedNormseite() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        var part = LaTeXWriter.Part(text: fillerParagraphs(40).joined(separator: "\n\n") + "\n")
        part.figures = [:]
        let pdf = try await engine.makePDF(parts: [part], paper: .a4, typeface: .courier, format: .manuscript)
        if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("normseite.pdf"))
        }
        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount >= 2)
        let page = try #require(document.page(at: 0)?.string)
        // The page number stands above the text.
        let lines = page.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Int($0) == nil }
        #expect(lines.count == 30)
        #expect(lines.allSatisfy { $0.count <= 60 })
        #expect(lines.map(\.count).max() ?? 0 >= 56)

        // The editor breaks the same lines and counts the same pages.
        let markdown = part.text
        let (editorLines, editorPages) = await MainActor.run { () -> ([String], Int?) in
            let textView = WriterTextView.make()
            textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
            textView.load(markdown: markdown, family: .courier, palette: WriterPalette.dark.with(format: .manuscript))
            textView.updatePages()
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return ([], nil) }
            let string = textView.string as NSString
            var lines: [String] = []
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                lines.append(string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (lines, textView.reportedPageCount?.pages)
        }
        #expect(Array(editorLines.prefix(30)) == lines)
        #expect(editorPages == document.pageCount)
    }
}
