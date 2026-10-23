import Testing
import AppKit
@testable import LLMDesigner

@Suite("Präsentation aus Dokument")
struct DocumentDeckTests {
    private func plan(_ markdown: String, title: String = "Titel") -> DeckPlan? {
        DocumentDeckPlanner.plan(for: DeckMaterial(title: title, markdown: markdown, sourceName: "x"))
    }

    @Test func chaptersAndHeadings() {
        let markdown = """
        # Erstes Kapitel {.chapter}

        Einleitung des Kapitels.

        # Grundlagen

        Text über Grundlagen mit **fetten** Begriffen.

        # Methoden

        Text über Methoden.

        # Zweites Kapitel {.chapter}

        # Ergebnisse

        Die Ergebnisse sind klar.
        """
        let plan = plan(markdown)
        #expect(plan?.chapterCount == 2)
        #expect(plan?.slideCount == 3)
        #expect(plan?.chapters.map(\.title) == ["Erstes Kapitel", "Zweites Kapitel"])
        #expect(plan?.chapters[0].slides.map(\.title) == ["Grundlagen", "Methoden"])
        #expect(plan?.chapters[0].introduction == "Einleitung des Kapitels.")
    }

    @Test func h1AsChaptersH2AsSlides() {
        let markdown = """
        # Teil A

        ## Eins

        Text eins.

        ## Zwei

        Text zwei.

        # Teil B

        ## Drei

        Text drei mit Formel:

        $$
        E = m c^2
        $$
        """
        let plan = plan(markdown)
        #expect(plan?.chapters.map(\.title) == ["Teil A", "Teil B"])
        #expect(plan?.slideCount == 3)
        let objects = DeckObjects.extract(from: plan?.chapters[1].slides[0].passage ?? "")
        #expect(objects.math == ["$$\nE = m c^2\n$$"])
    }

    @Test func titleAndSectionsWithoutChapters() {
        let markdown = """
        # Mein Aufsatz

        Ein kurzer Untertitel

        ## Einleitung

        Viel Text hier.

        ## Hauptteil

        ### Unterpunkt

        Noch mehr Text.

        ## Schluss

        Fazit.
        """
        let plan = plan(markdown, title: "")
        #expect(plan?.title == "Mein Aufsatz")
        #expect(plan?.chapters.count == 1)
        #expect(plan?.chapters[0].title == nil)
        #expect(plan?.chapters[0].slides.map(\.title) == ["Einleitung", "Hauptteil", "Schluss"])
        // The deeper heading is part of its slide.
        #expect(plan?.chapters[0].slides[1].passage.contains("**Unterpunkt**") == true)
    }

    @Test func noHeadingsNoPlan() {
        #expect(plan("Nur ein langer Absatz ohne jede Überschrift.\n\nUnd noch einer.") == nil)
        #expect(plan("# Nur eine Überschrift\n\nText") == nil)
    }

    @Test func headingsInCodeAreNoHeadings() {
        let markdown = "## A\n\n```python\n# kein Kapitel\nx = 1\n```\n\n## B\n\nText"
        let plan = plan(markdown)
        #expect(plan?.slideCount == 2)
        #expect(plan?.chapters[0].slides[0].passage.contains("# kein Kapitel") == true)
    }

    @Test func objectsAreFound() {
        let passage = """
        Text davor.

        ```sql
        SELECT 1;
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |

        $$ x^2 $$

        ![Ein Bild](Bilder/x.png){width=50%}
        """
        let objects = DeckObjects.extract(from: passage)
        #expect(objects.code == ["```sql\nSELECT 1;\n```"])
        #expect(objects.tables.count == 1)
        #expect(objects.math == ["$$ x^2 $$"])
        #expect(objects.images.first?.source == "Bilder/x.png")
        let text = DeckObjects.textForModel(passage, limit: 1000)
        #expect(text.contains("[Code-Block]") && text.contains("[Tabelle]") && text.contains("[Formel]") && text.contains("[Bild: Ein Bild]"))
        #expect(!text.contains("SELECT"))
    }

    @Test func richTextHeadings() {
        let text = NSMutableAttributedString()
        func add(_ string: String, size: CGFloat, bold: Bool = false) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font]))
        }
        add("Hauptüberschrift", size: 24, bold: true)
        add("Dies ist ein langer Absatz mit vielen Wörtern, der als normaler Text gilt und deutlich länger ist als jede Überschrift.", size: 12)
        add("Zwischenüberschrift", size: 16, bold: true)
        add("Noch ein langer Absatz mit ausreichend vielen Wörtern, damit die Schriftgröße des Fließtextes überwiegt, ganz klar.", size: 12)
        let markdown = DocumentText.headingsMarkdown(from: text)
        #expect(markdown.hasPrefix("# Hauptüberschrift"))
        #expect(markdown.contains("## Zwischenüberschrift"))
        #expect(!markdown.contains("# Dies ist"))
    }

    @Test func notesAreRemovedFromPoints() {
        #expect(DeckObjects.removingNotes(from: "[Code-Block]") == nil)
        #expect(DeckObjects.removingNotes(from: "[Formel]") == nil)
        #expect(DeckObjects.removingNotes(from: "Die Formel [Formel] gilt überall") == "Die Formel gilt überall")
        #expect(DeckObjects.removingNotes(from: "Bild zeigt Ablauf") == "Bild zeigt Ablauf")
        #expect(DeckObjects.removingNotes(from: "Ergebnis (Tabelle)") == "Ergebnis")
    }
}
