import Testing
import AppKit
@testable import LLMDesigner

@Suite("Kästen, Spalten und Kommentare")
struct WriterBoxColumnTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    private let filler = "Ein Satz, der lang genug ist, damit er über mehrere Zeilen umbricht und man das Fließen sieht. "

    // MARK: Storage

    @Test func boxesAndColumnsRoundTripNested() {
        let markdown = """
        Davor.

        ::: {.columns count=2 rule=true}
        Spalte eins.

        ::: {.box kind=merksatz title="Merke" position=right width=40 wrap=true}
        ::: {.center}
        Im Kasten.
        :::

        - Punkt im Kasten
        :::

        \\columnbreak

        Spalte zwei.
        :::

        ::: {.box kind=definition frame=outline}
        **Definition:** Ein Kasten allein.
        :::

        Danach.

        """
        let text = WriterMarkdown.attributedString(from: markdown)
        let string = text.string as NSString
        let box = text.attribute(.writerBox, at: string.range(of: "Im Kasten").location, effectiveRange: nil) as? WriterBox
        #expect(box?.style.kind == .merksatz)
        #expect(box?.style.title == "Merke")
        #expect(box?.style.floats == true)
        #expect(box?.style.width == 40)
        #expect(text.attribute(.writerBox, at: string.range(of: "Punkt").location, effectiveRange: nil) as? WriterBox === box)
        let section = text.attribute(.writerColumns, at: string.range(of: "Spalte zwei").location, effectiveRange: nil) as? WriterColumnSection
        #expect(section?.style.rule == true)
        #expect(text.attribute(.writerColumns, at: string.range(of: "Im Kasten").location, effectiveRange: nil) as? WriterColumnSection === section)
        #expect(text.attribute(.writerColumns, at: string.range(of: "Danach").location, effectiveRange: nil) == nil)
        let other = text.attribute(.writerBox, at: string.range(of: "allein").location, effectiveRange: nil) as? WriterBox
        #expect(other !== box)
        #expect(other?.style.frame == .outline)
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func tablesStayOutOfBoxes() {
        let text = WriterMarkdown.attributedString(from: "::: {.box kind=hinweis}\n| a | b |\n| --- | --- |\n| 1 | 2 |\n:::\n")
        let range = (text.string as NSString).range(of: "1")
        #expect(text.attribute(.writerBox, at: range.location, effectiveRange: nil) == nil)
    }

    @Test func commentsRoundTripWithTheirThread() {
        let comment = WriterComment(id: "k-1a2b3c4d", entries: [
            WriterComment.Entry(author: "Ich", isAI: false, date: Date(timeIntervalSince1970: 1_800_000_000), text: "Stimmt das \"wirklich\"?"),
            WriterComment.Entry(author: "Gemma", isAI: true, date: Date(timeIntervalSince1970: 1_800_000_100), text: "Laut Quelle: 330 m.\nZweite Zeile & <Zeichen>."),
        ])
        let text = NSMutableAttributedString(string: "Der Turm ist 400 m hoch.", attributes: [.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0])
        text.addAttribute(.writerComment, value: comment, range: NSRange(location: 4, length: 4))
        let markdown = WriterMarkdown.markdown(from: text)
        #expect(markdown.contains("<span class=\"comment\" data-comment=\"k-1a2b3c4d\""))
        let back = WriterMarkdown.attributedString(from: markdown)
        let parsed = back.attribute(.writerComment, at: 5, effectiveRange: nil) as? WriterComment
        #expect(parsed == comment)
        #expect(back.string == text.string)
        #expect(WriterComment.openCount(in: markdown) == 1)
        #expect(WriterComment.strip(markdown) == "Der Turm ist 400 m hoch.\n")
        // Comments are no bookmarks, and LaTeX leaves them out.
        #expect(WriterBookmark.entries(in: markdown).isEmpty)
        #expect(!LaTeXWriter.convertSpans(markdown).text.contains("comment"))
    }

    // MARK: Layout

    @MainActor private func lines(_ markdown: String) throws -> (view: WriterTextView, lines: [(text: String, rect: NSRect)]) {
        let textView = WriterTextView.make()
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        textView.load(markdown: markdown, family: .serif, palette: .light)
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        // A section is laid out a second time once its heights are known.
        textView.settleLayout()
        let string = textView.string as NSString
        var result: [(String, NSRect)] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            result.append((string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), rect))
        }
        if ProcessInfo.processInfo.environment["LLMD_DEBUG_LINES"] != nil {
            for line in result { print(String(format: "x=%6.1f y=%6.1f w=%6.1f h=%5.1f ", line.1.minX, line.1.minY, line.1.width, line.1.height) + line.0.prefix(40)) }
        }
        return (textView, result)
    }

    @MainActor @Test func textFlowsAroundAFloatingBox() throws {
        let markdown = """
        Davor. \(filler)

        ::: {.box kind=hinweis position=right width=40 wrap=true}
        Ein Hinweis im Kasten, der rechts steht und ein paar Zeilen lang ist.
        :::

        Danach fließt der Text links am Kasten vorbei. \(filler)\(filler)\(filler)\(filler)
        """
        let (view, lines) = try lines(markdown)
        let width = try #require(view.textContainer).size.width
        let boxLines = lines.filter { $0.text.contains("Hinweis im Kasten") }
        let boxLine = try #require(boxLines.first)
        // The box stands right, in 40 % of the column.
        #expect(boxLine.rect.minX > width * 0.55)
        let after = try #require(lines.firstIndex { $0.text.hasPrefix("Danach") })
        // The text after it goes up beside it and is narrower there…
        #expect(lines[after].rect.minY < boxLine.rect.maxY)
        #expect(lines[after].rect.maxX < width * 0.62)
        // …and full width again below it.
        let last = try #require(lines.last)
        #expect(last.rect.width > width * 0.9 || last.text.count < 40)
    }

    @MainActor @Test func sectionsFlowIntoTwoBalancedColumns() throws {
        let markdown = """
        Davor.

        ::: {.columns count=2}
        Erster Absatz. \(filler)\(filler)

        Zweiter Absatz. \(filler)\(filler)

        Dritter Absatz. \(filler)\(filler)
        :::

        Danach.
        """
        let (view, lines) = try lines(markdown)
        let width = try #require(view.textContainer).size.width
        let section = lines.filter { $0.text != "Davor." && $0.text != "Danach." }
        let left = section.filter { $0.rect.minX < width / 2 }
        let right = section.filter { $0.rect.minX >= width / 2 }
        #expect(!left.isEmpty && !right.isEmpty)
        // Both columns are narrower than half the column and start at the same height.
        #expect(section.allSatisfy { $0.rect.width <= width / 2 })
        let leftTop = try #require(left.map(\.rect.minY).min()), rightTop = try #require(right.map(\.rect.minY).min())
        #expect(abs(leftTop - rightTop) < 30)
        // Balanced: the columns differ by at most two lines.
        #expect(abs(left.count - right.count) <= 2)
        // The text after the section starts below its longer column.
        let after = try #require(lines.last { $0.text == "Danach." })
        #expect(after.rect.minY >= max(left.map(\.rect.maxY).max() ?? 0, right.map(\.rect.maxY).max() ?? 0) - 0.5)
    }

    @MainActor @Test func columnsStayWhenTextAboveChanges() throws {
        let markdown = """
        Davor.

        ::: {.box kind=definition}
        Ein Kasten über den Spalten.
        :::

        ::: {.columns count=2}
        Erster Absatz. \(filler)\(filler)

        Zweiter Absatz. \(filler)\(filler)
        :::
        """
        let (view, _) = try lines(markdown)
        let storage = try #require(view.textStorage)
        // Text typed into the box above, and the box turned into a floating one.
        let place = (storage.string as NSString).range(of: "Spalten.").location
        view.insertText(" Mit mehr Text, der die Spalten nach unten schiebt.", replacementRange: NSRange(location: place + 8, length: 0))
        view.setSelectedRange(NSRange(location: place, length: 0))
        if var style = view.boxAtCaret?.box.style {
            style.position = .right
            style.wraps = true
            view.setBoxStyle(style)
        }
        view.settleLayout()
        let layoutManager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let width = container.size.width
        var right = 0
        var left = 0
        let string = view.string as NSString
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard storage.attribute(.writerColumns, at: range.location, effectiveRange: nil) != nil,
                  !string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if rect.minX >= width / 2 { right += 1 } else { left += 1 }
        }
        #expect(right > 0)
        #expect(abs(left - right) <= 2)
    }

    @MainActor @Test func textKeepsFlowingAroundABoxWhileTyping() throws {
        let markdown = """
        ::: {.box kind=hinweis position=right width=40 wrap=true}
        Kastenwort steht rechts im Kasten, über ein paar Zeilen hin.
        :::

        Danebenwort fließt links vorbei. \(filler)\(filler)\(filler)

        ::: {.columns count=2}
        Linkswort. \(filler)\(filler)

        Rechtswort. \(filler)\(filler)
        :::
        """
        let (view, _) = try lines(markdown)
        let storage = try #require(view.textStorage)
        let place = (storage.string as NSString).range(of: "fließt links").location
        view.insertText("XY", replacementRange: NSRange(location: place, length: 0))
        view.settleLayout()
        let layoutManager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let width = container.size.width
        var after: NSRect?
        var box: NSRect?
        var right = 0
        let string = view.string as NSString
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let text = string.substring(with: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            if text.hasPrefix("Danebenwort") { after = rect }
            if text.hasPrefix("Kastenwort") { box = rect }
            if storage.attribute(.writerColumns, at: layoutManager.characterIndexForGlyph(at: glyphs.location), effectiveRange: nil) != nil,
               rect.minX >= width / 2 { right += 1 }
        }
        let first = try #require(after), boxLine = try #require(box)
        #expect(first.minY < boxLine.maxY)
        #expect(first.maxX < width * 0.62)
        #expect(right > 0)
        // Drawing a rect over the second column finds its glyphs.
        let rightLine = try #require({ () -> NSRect? in
            var found: NSRect?
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { rect, _, _, _, stop in
                if rect.minX >= width / 2 { found = rect; stop.pointee = true }
            }
            return found
        }())
        let drawn = layoutManager.glyphRange(forBoundingRect: rightLine.insetBy(dx: 2, dy: 2), in: container)
        let glyphAtRight = layoutManager.glyphIndex(for: NSPoint(x: rightLine.midX, y: rightLine.midY), in: container)
        #expect(NSLocationInRange(glyphAtRight, drawn))
        #expect(layoutManager.lineFragmentRect(forGlyphAt: glyphAtRight, effectiveRange: nil).minX >= width / 2)
    }

    @MainActor @Test func clicksFindLinesSideBySide() throws {
        let markdown = """
        ::: {.box kind=hinweis position=right width=40 wrap=true}
        Kastenwort steht rechts im Kasten.
        :::

        Danebenwort fließt links vorbei. \(filler)\(filler)

        ::: {.columns count=2}
        Linkswort. \(filler)\(filler)

        Rechtswort. \(filler)\(filler)
        :::
        """
        let (view, lines) = try lines(markdown)
        let string = view.string as NSString
        func click(on word: String) throws -> Int {
            let line = try #require(lines.first { $0.text.contains(word) })
            let origin = view.textContainerOrigin
            return view.characterIndexForInsertion(at: NSPoint(x: origin.x + line.rect.minX + 30, y: origin.y + line.rect.maxY - 8))
        }
        // A click on the box's line lands in the box, one on the second column in it.
        #expect(string.range(of: "Kastenwort").location <= (try click(on: "Kastenwort")))
        #expect(try click(on: "Kastenwort") < string.range(of: "Danebenwort").location)
        let right = try click(on: "Rechtswort")
        #expect(right >= string.range(of: "Rechtswort").location)
    }

    @MainActor @Test func aColumnBreakStartsTheSecondColumn() throws {
        let markdown = """
        ::: {.columns count=2}
        Kurz links.

        \\columnbreak

        Rechts. \(filler)\(filler)\(filler)
        :::
        """
        let (view, lines) = try lines(markdown)
        let width = try #require(view.textContainer).size.width
        let rechts = try #require(lines.first { $0.text.hasPrefix("Rechts") })
        #expect(rechts.rect.minX >= width / 2)
        #expect(try #require(lines.first { $0.text.hasPrefix("Kurz") }).rect.minX < width / 2)
    }

    // MARK: LaTeX

    @Test func boxesAndColumnsBecomeTcolorboxAndMulticols() {
        var part = LaTeXWriter.Part(text: """
        ::: {.columns count=2 gap=1cm rule=true}
        Links.

        \\columnbreak

        Rechts.
        :::

        ::: {.box kind=definition title="Satz" position=right width=40 wrap=true}
        Im Kasten.
        :::

        Daneben.
        """)
        part.figures = [:]
        let latex = LaTeXWriter.document(parts: [part], paper: .a4, math: .native)
        #expect(latex.contains("\\begin{multicols}{2}"))
        #expect(latex.contains("\\setlength{\\columnsep}{1cm}\\setlength{\\columnseprule}{0.4pt}"))
        #expect(latex.contains("\\columnbreak"))
        #expect(latex.contains("\\end{multicols}}"))
        #expect(latex.contains("\\begin{wrapfigure}{r}{0.40\\linewidth}"))
        #expect(latex.contains("\\begin{tcolorbox}["))
        #expect(latex.contains("\\textcolor{llmdbox"))
        #expect(latex.contains("Satz"))
        #expect(latex.contains("\\end{tcolorbox}\n\\end{wrapfigure}"))
    }

    @Test func boxesColumnsAndFiguresCompile() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let markdown = """
        # Kästen und Spalten

        ::: {.box kind=definition}
        **Primzahl:** eine natürliche Zahl größer als 1, die nur durch 1 und sich selbst teilbar ist.
        :::

        ::: {.box kind=merksatz position=right width=40 wrap=true}
        Merke: 2 ist die einzige gerade Primzahl.
        :::

        \(filler)\(filler)\(filler)\(filler)\(filler)

        ::: {.columns count=2 rule=true}
        \(filler)\(filler)

        ::: {.box kind=achtung frame=outline}
        Ein Kasten in der Spalte.
        :::

        \\columnbreak

        \(filler)\(filler)
        :::

        ::: {.box kind=beispiel position=center width=60 frame=filled title="Rechnung"}
        - 7 ist prim
        - 9 ist es nicht
        :::
        """
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        let pdf = try await engine.makePDF(parts: [part], paper: .a4, typeface: .serif)
        #expect(pdf.count > 5_000)
        if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("kaesten-spalten.pdf"))
        }
    }
}

