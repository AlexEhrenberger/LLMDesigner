import Testing
import AppKit
@testable import LLMDesigner

/// Writer actions work on the Markdown of a document through `WriterMarkdown`, also while no editor is open. So
/// everything has to survive Markdown → attributed text → Markdown. The cases are the block types and inline formats
/// the actions can touch or have to leave alone.
@MainActor
@Suite("Writer: Rundlauf Markdown ⇄ attributierter Text")
struct MarkdownRoundTripTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .newlines)
    }

    static let blocks: [(String, String)] = [
        ("Absatz", "Ein ganz normaler Absatz."),
        ("Zwei Absätze", "Erster Absatz.\n\nZweiter Absatz."),
        ("Überschrift 1", "# Titel"),
        ("Überschrift 2", "## Titel"),
        ("Überschrift 3", "### Titel"),
        ("Kapitel", "# Titel {.chapter}"),
        ("Aufzählung", "- eins\n- zwei"),
        ("Nummeriert", "1. eins\n2. zwei"),
        ("Verschachtelte Liste", "- eins\n  - unter\n- zwei"),
        ("Zitat", "> Ein Zitat."),
        ("Code", "```swift\nlet a = 1\n\nlet b = 2\n```"),
        ("Trennlinie", "Davor.\n\n---\n\nDanach."),
        ("Seitenumbruch", "Davor.\n\n\\newpage\n\nDanach."),
        ("Formel", "$$\nE = mc^2\n$$"),
        // The separator comes back as `| --- | --- |`, the one normal form the editor writes (see below).
        ("Tabelle", "| A | B |\n| --- | --- |\n| 1 | 2 |"),
        ("Tabelle mit Ausrichtung", "| A | B |\n| :---: | ---: |\n| 1 | 2 |"),
        ("Bild", "![Beschriftung](bild.png)"),
        ("Inhaltsverzeichnis", "[TOC]"),
        ("Kasten", "::: {.box kind=merksatz}\nIm Kasten.\n:::"),
        ("Zentriert", "::: {.center}\nMittig.\n:::"),
        ("Spalten", "::: {.columns count=2}\nLinks und rechts.\n:::"),
    ]

    static let inlines: [(String, String)] = [
        ("Fett", "Ein **fettes** Wort."),
        ("Kursiv", "Ein *kursives* Wort."),
        ("Unterstrichen", "Ein <u>unterstrichenes</u> Wort."),
        ("Durchgestrichen", "Ein ~~gestrichenes~~ Wort."),
        ("Code", "Ein `code` Wort."),
        ("Hochgestellt", "x<sup>2</sup> gilt."),
        ("Tiefgestellt", "H<sub>2</sub>O ist Wasser."),
        ("Fett und kursiv", "Ein ***beides*** Wort."),
        ("Link", "Ein [Link](https://example.org) hier."),
        ("Formel im Text", "Es gilt $a^2$ hier."),
        ("Zitation", "Laut [@mueller2020, S. 12] stimmt das."),
        ("Farbe", "Ein <span style=\"color:#C0392B\">rotes</span> Wort."),
        ("Größe", "Ein <span style=\"font-size:14pt\">großes</span> Wort."),
        ("Fett in Farbe", "Ein <span style=\"color:#C0392B\">**rotes**</span> Wort."),
        ("Sonderzeichen", "Ein \\*Stern\\* und 3 \\* 4."),
    ]

    @Test(arguments: blocks)
    func blockSurvives(_ name: String, _ markdown: String) {
        #expect(normalized(roundTrip(markdown)) == normalized(markdown), "\(name)")
    }

    @Test(arguments: inlines)
    func inlineSurvives(_ name: String, _ markdown: String) {
        #expect(normalized(roundTrip(markdown)) == normalized(markdown), "\(name)")
    }

    /// The one known difference: a table's separator line gets its normal form. Nothing is lost, and actions only
    /// convert the block they change, so the tables of a document stay as they are.
    @Test func tableSeparatorGetsItsNormalForm() {
        #expect(normalized(roundTrip("| A | B |\n|---|---|\n| 1 | 2 |")) == "| A | B |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func aSecondRoundChangesNothing() {
        let all = (Self.blocks + Self.inlines).map(\.1).joined(separator: "\n\n")
        let once = roundTrip(all)
        #expect(roundTrip(once) == once)
    }
}
