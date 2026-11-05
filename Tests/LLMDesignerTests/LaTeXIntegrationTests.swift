import Testing
import Foundation
@testable import LLMDesigner

/// Sets documents with the real LaTeX engine (skipped where none is installed).
@Suite("LaTeX-Satz")
struct LaTeXIntegrationTests {
    private func typeset(_ markdown: String, typeface: WriterFont?) async throws -> Data? {
        guard let engine = LaTeXEngine.locate() else { return nil }
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        return try await engine.makePDF(parts: [part], paper: .a4, typeface: typeface)
    }

    @Test func coloursAndFontsCompile() async throws {
        let markdown = """
        # Farben und Schriften

        Normaler Text mit <span style="color:#C0392B">rotem</span>, <span style="color:#1F5FBF;font-family:'Georgia'">blauem Georgia</span> und <span style="font-family:'Futura'">**fettem** Futura</span>.

        - Liste mit <span style="color:#1E8449">grünem Wort</span>
        - <u>unterstrichen **fett** weiter</u>

        | Spalte | <span style="color:#7B3FC4">Violett</span> |
        | --- | --- |
        | a | b |

        """
        for typeface in [WriterFont.serif, .sans, .georgia, .mono] {
            guard let pdf = try await typeset(markdown, typeface: typeface) else { return }
            #expect(pdf.count > 5_000)
            if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
                try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("style-\(typeface.rawValue).pdf"))
            }
        }
    }

    @Test func emojiBecomePictures() async throws {
        #expect(LaTeXWriter.escape("Gut 😀") == "Gut \\texorpdfstring{\\llmdemoji{llmdemoji-1F600}}{}")
        // A sequence with a skin tone stays one picture.
        let thumb: Character = "👍🏽"
        #expect(LaTeXEmoji.character(fromName: LaTeXEmoji.name(thumb)) == thumb)
        #expect(LaTeXEmoji.png("😀").map { $0.count > 1_000 } == true)

        let markdown = "# Titel 🎉\n\nEin Satz mit 😀 und 👍🏽 im Text.\n\n- Liste ✅\n"
        guard let pdf = try await typeset(markdown, typeface: .georgia) else { return }
        #expect(pdf.count > 5_000)
        if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("emoji.pdf"))
        }
    }

    @Test func alignmentSizesAndColumnWidthsCompile() async throws {
        let wide = String(repeating: "-", count: 70)
        let narrow = String(repeating: "-", count: 30)
        let markdown = """
        [TOC]

        ::: {.center}
        # Zentrierter Titel {.chapter}
        :::

        ## Rechts

        Linksbündiger Text, wie im Editor, mit einem <span style="font-size:20pt">großen</span> und einem <span style="font-size:8pt">kleinen</span> Wort, und so weiter, damit die Zeile umbricht und man den Flattersatz sieht.

        ::: {.justify}
        Ein Absatz im Blocksatz, lang genug, dass er über mehrere Zeilen geht und man sieht, dass beide Ränder gerade sind. Noch ein Satz für die zweite Zeile.
        :::

        ::: {.center}
        Zentriert.

        > Ein zentriertes Zitat
        :::

        ::: {.right}
        ### Rechtsbündige Überschrift

        Rechtsbündig.
        :::

        | Schmal | Breit |
        | \(narrow) | :\(wide): |
        | a | ein längerer Text in der breiten Spalte, der umbricht |

        """
        guard let pdf = try await typeset(markdown, typeface: .palatino) else { return }
        #expect(pdf.count > 5_000)
        if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("layout.pdf"))
        }
    }

    @Test func codeCompilesWithColours() async throws {
        let markdown = """
        # Code

        ```python
        import math


        def f(x, a):
            r\"\"\"f(x) = a x^2 % Test\"\"\"
            data = {"key": [1, 2.5], 'b': "tab\\n"}  # Kommentar mit {Klammern} und \\ Backslash
            return a * x ** 2 + math.sqrt(x) if x > 0 else float('nan')
        ```

        ```sql
        -- Umsatz pro Kunde
        SELECT k.name, COUNT(*) AS n, 'it''s' AS s
        FROM kunden k
        WHERE k.alter >= 18 AND k.note LIKE '100%'; /* Ende */
        ```

        ```
        Code ohne Sprache { } \\ bleibt einfach grau
        ```

        """
        guard let pdf = try await typeset(markdown, typeface: .serif) else { return }
        #expect(pdf.count > 5_000)
        if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("code.pdf"))
        }
    }
}

@Suite("LaTeX-Satz: Seiten, Tabellen, Absätze")
struct LaTeXFormattingIntegrationTests {
    @Test func pagesTablesAndParagraphsCompile() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let markdown = """
        # Erstes Kapitel

        Ein Absatz mit x<sup>2</sup>, H<sub>2</sub>O und ~~durchgestrichen~~.

        ::: {.justify line-spacing=1.5 indent=1cm right-indent=0.5cm first-line=-0.75cm}
        Ein hängender Absatz mit anderthalbfachem Zeilenabstand, lang genug für mehrere Zeilen, damit man den Einzug und die Einrückung links und rechts sieht. Noch ein Satz.
        :::

        ::: {line-spacing=2}
        - Doppelt
        - Gesetzt
        :::

        \\newpage

        # Zweites Kapitel

        ::: {.table lines=grid line-width=1 fill=0.0:FFF2CC,1.0:E2EFDA,2.1:DDEBF7}
        | Name | Werte | << |
        | --- | --- | --- |
        | a | 1 | 2 |
        | ^^ | 3 | 4 |
        | b | 5 | 6 |
        :::

        ::: {.table lines=horizontal}
        | A | B | C |
        | :-: | --- | --: |
        | über zwei | << | x |
        | y | z | ^^ |
        :::

        ::: {.table lines=frame}
        | A | B |
        | --- | --- |
        | 1 | 2 |
        :::

        ::: {.table lines=none}
        | A | B |
        | --- | --- |
        | 1 | 2 |
        :::

        | Buch | Satz | << |
        | ---- | -------------- | ------------------------------------------------------------------------------------ |
        | ^^ | eins | zwei |
        | drei | vier | fünf |

        """
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        let setup = WriterPageSetup(name: "A5", paperWidth: 148, paperHeight: 210, top: 20, bottom: 22, left: 18, right: 16, fontSize: 10.5, lineSpacing: 1.15)
        let heads = WriterRunningHeads(header: .init(left: "{Titel}", center: "", right: "{Kapitel}"),
                                       footer: .init(left: "{Datum}", center: "Seite {Seite} von {Seiten}", right: ""), skipsFirstPage: true, hasRules: true)
        for (format, design) in [(WriterPageFormat.custom, WriterPageDesign(setup: setup, runningHeads: heads, title: "Bericht & Co")),
                                 (.standard, WriterPageDesign(runningHeads: heads, title: "Bericht")), (.paperback, WriterPageDesign()),
                                 (.manuscript, WriterPageDesign(runningHeads: heads, title: "Roman"))] {
            let pdf = try await engine.makePDF(parts: [part], paper: .a4, typeface: .serif, format: format, design: design)
            #expect(pdf.count > 5_000)
            if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
                try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("formatting-\(format.rawValue).pdf"))
            }
        }
    }
}
