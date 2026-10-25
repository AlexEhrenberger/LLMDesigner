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
