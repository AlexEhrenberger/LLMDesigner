import Testing
import Foundation
@testable import LLMDesigner

@Suite("Power-Zugriff: Blöcke")
struct PowerTextTests {
    private let document = """
    # Kapitel eins {.chapter}

    Ein **fetter** Absatz mit *Kursivem*
    über zwei Zeilen.

    - Punkt eins
    - Punkt zwei

    ```swift
    let a = 1

    let b = 2
    ```

    ::: {.box kind=merksatz}
    Im Kasten.

    Zweiter Absatz im Kasten.
    :::

    | A | B |
    |---|---|
    | 1 | 2 |
    """

    @Test func splitsIntoWholeBlocks() {
        let chunks = PowerText.chunks(of: document)
        #expect(chunks.count == 6)
        #expect(chunks[0].kind == .heading(1))
        #expect(chunks[1].kind == .paragraph)
        #expect(chunks[2].kind == .list)
        #expect(chunks[3].kind == .code)
        #expect(chunks[3].markdown.contains("let b = 2"))
        #expect(chunks[4].kind == .box)
        #expect(chunks[4].markdown.contains("Zweiter Absatz"))
        #expect(chunks[5].kind == .table)
    }

    @Test func plainTextDropsTheMarks() {
        let chunks = PowerText.chunks(of: document)
        #expect(chunks[0].plain == "Kapitel eins")
        #expect(chunks[1].plain == "Ein fetter Absatz mit Kursivem\nüber zwei Zeilen.")
        #expect(chunks[2].plain == "• Punkt eins\n• Punkt zwei")
        #expect(chunks[4].plain == "Im Kasten.\n\nZweiter Absatz im Kasten.")
        #expect(chunks[5].plain == "A  ·  B\n1  ·  2")
    }

    @Test func insertingMovingAndReplacingKeepTheRest() {
        let inserted = PowerText.inserting("Neu dazwischen.", at: 1, into: document)
        let chunks = PowerText.chunks(of: inserted)
        #expect(chunks.count == 7)
        #expect(chunks[1].markdown == "Neu dazwischen.")
        #expect(chunks[4].markdown.contains("let b = 2"))

        let moved = PowerText.chunks(of: PowerText.moving(0, to: 3, in: document))
        #expect(moved[2].kind == .heading(1))
        #expect(moved[0].kind == .paragraph)

        let removed = PowerText.chunks(of: PowerText.replacing(2, with: "", in: document))
        #expect(removed.count == 5)
        #expect(!removed.contains { $0.kind == .list })
    }

    @MainActor @Test func slideFromDroppedText() {
        #expect(AppModel.slideMarkdown(from: "Titel\nerster Punkt\nzweiter Punkt") == "# Titel\n\n- erster Punkt\n- zweiter Punkt")
        #expect(AppModel.slideMarkdown(from: "## Schon eine Überschrift\n\nText") == "## Schon eine Überschrift\n\nText")
    }

    @Test func searchSnippets() {
        let text = String(repeating: "Füllwort ", count: 30) + "Prädiktive Verarbeitung" + String(repeating: " danach", count: 30)
        let snippet = PowerText.snippet(of: text, around: "prädiktive")
        #expect(snippet?.contains("Prädiktive Verarbeitung") == true)
        #expect(snippet?.hasPrefix("…") == true)
        #expect(PowerText.matches("Ärger", "arger"))
    }
}
