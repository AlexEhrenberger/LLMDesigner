import Foundation
import Testing
@testable import LLMDesigner

@Suite("Vergleichen")
struct CompareTests {
    @Test func blocksKeepFencesAndBoxesWhole() {
        let markdown = "# Titel\n\nErster Absatz.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n::: {.box kind=merksatz}\nMerk dir das.\n\nZweite Zeile.\n:::\n\nLetzter."
        let blocks = TextDiff.blocks(of: markdown)
        #expect(blocks.count == 5)
        #expect(blocks[2].hasPrefix("```swift") && blocks[2].hasSuffix("```"))
        #expect(blocks[3].hasPrefix(":::") && blocks[3].contains("Zweite Zeile."))
    }

    @Test func wordsAreMarkedNotWholeParagraphs() {
        let segments = TextDiff.segments("Die Regression ist ein sehr altes Verfahren.", "Die Regression ist ein bewährtes Verfahren.")
        let removed = segments.filter { $0.kind == .removed }.map(\.text).joined()
        let added = segments.filter { $0.kind == .added }.map(\.text).joined()
        #expect(removed.contains("sehr") && removed.contains("altes"))
        #expect(added.contains("bewährtes"))
        #expect(segments.first?.kind == .same)
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == "Die Regression ist ein bewährtes Verfahren.")
    }

    @Test func blocksAreAlignedChangedAddedRemovedMoved() {
        let old = ["Einleitung zum Thema Regression.", "Ein Absatz, der wegfällt.", "Methode mit Daten.", "Schluss."]
        let new = ["Schluss.", "Einleitung zum Thema lineare Regression.", "Methode mit Daten.", "Ein ganz neuer Absatz über Ergebnisse."]
        let diff = TextDiff.compare(old, new)
        let kinds = diff.map(\.kind)
        #expect(kinds.contains(.changed))
        #expect(kinds.filter { $0 == .moved }.count == 2)
        #expect(diff.contains { $0.kind == .removed && $0.left == "Ein Absatz, der wegfällt." })
        #expect(diff.contains { $0.kind == .added && $0.right?.contains("Ergebnisse") == true })
        #expect(TextDiff.summary(diff).contains("1 Absatz geändert"))
    }

    @Test func slidesAreMatchedByID() {
        func deck(_ slides: [(String, String, String?)]) -> String {
            "---\nid: x\ntitle: Referat\nkind: presentation\nbackgrounds: {}\n---\n\n" + slides.map { id, text, notes in
                "<!-- folie {\"id\":\"\(id)\",\"rolle\":\"folie\"} -->\n\n\(text)" + (notes.map { "\n\n<!-- moderation\n\($0)\n-->" } ?? "")
            }.joined(separator: "\n\n")
        }
        let left = deck([("a", "# Start\n\n- eins", nil), ("b", "# Mitte\n\n- R² = 0,61", "Hier erklären"), ("c", "# Ende", nil)])
        let right = deck([("a", "# Start\n\n- eins", nil), ("b", "# Mitte\n\n- R² = 0,64", "Hier genau erklären"), ("d", "# Neu", nil)])
        guard case .slides(_, let slides) = Comparer.compareDocuments(left, right) else { Issue.record("keine Folien"); return }
        #expect(slides.map(\.kind) == [.same, .changed, .added, .removed])
        #expect(slides[1].label == "Mitte")
        #expect(slides[1].segments.contains { $0.kind == .added && $0.text.contains("64") })
        #expect(slides[1].noteSegments.contains { $0.kind == .added && $0.text.contains("genau") })
        #expect(slides[3].label == "Ende")
    }

    @Test func recordsAreComparedByEntryIDs() throws {
        let old = #"{"format":1,"note":{"titel":"Plan","geaendert":"2026-01-01","todos":[{"id":"1","text":"Lesen","erledigt":false},{"id":"2","text":"Schreiben","erledigt":false}]}}"#
        let new = #"{"format":1,"note":{"titel":"Plan","geaendert":"2026-02-02","todos":[{"id":"2","text":"Schreiben","erledigt":false},{"id":"1","text":"Lesen","erledigt":true},{"id":"3","text":"Abgeben","erledigt":false}]}}"#
        let sentences = RecordDiff.sentences(left: Data(old.utf8), right: Data(new.utf8))
        #expect(sentences.contains("todos: „Abgeben“ neu"))
        #expect(sentences.contains("todos „Lesen“ · erledigt: nein → ja"))
        #expect(sentences.contains("todos: Reihenfolge geändert"))
        #expect(!sentences.contains { $0.contains("geaendert") })
        #expect(RecordDiff.sentences(left: nil, right: Data(new.utf8)) == ["neu angelegt"])
    }

    @Test func headerChangesAreSentences() {
        let left = "---\nid: x\ntitle: Alt\nupdated: 2026-01-01\nfont: serif\n---\n\nText\n"
        let right = "---\nid: x\ntitle: Neu\nupdated: 2026-02-02\nfont: sans\n---\n\nText\n"
        guard case .document(let header, let blocks) = Comparer.compareDocuments(left, right) else { Issue.record("kein Dokument"); return }
        #expect(header == ["Schrift: serif → sans", "Titel: Alt → Neu"])
        #expect(blocks.allSatisfy { !$0.isChange })
    }
}

extension ActionSuites {
    @Suite("Fassungen und Übernehmen")
    @MainActor
    struct VariantTests {
        let harness = ActionHarness()

        @Test func variantPointsAtTheMainVersionAndSurvivesSaving() async throws {
            let id = UUID(uuidString: try await harness.document("Einleitung lang.\n\nZweiter Absatz."))!
            let variant = try #require(harness.app.newVariant(of: id))
            #expect(variant.variantOf == id)
            let second = try #require(harness.app.newVariant(of: variant.id))
            #expect(second.variantOf == id)
            #expect(harness.app.variants(of: id).map(\.id) == [variant.id, second.id])
            let text = WriterDocumentStore.encode(variant)
            #expect(text.contains("fassungVon: \(id.uuidString)"))
            #expect(WriterDocumentStore.decode(text, fallbackID: nil)?.variantOf == id)
            harness.app.closeDocument()
        }

        @Test func takingOverChangesTheMainVersion() async throws {
            let id = UUID(uuidString: try await harness.document("Einleitung lang und ausführlich.\n\nZweiter Absatz.\n\nDritter Absatz."))!
            let variant = try #require(harness.app.newVariant(of: id))
            harness.app.closeDocument()
            harness.app.updateDocument(variant.id, markdown: "Einleitung kurz und ausführlich.\n\nDritter Absatz.\n\nVierter Absatz neu.")
            let session = CompareSession(request: CompareRequest(item: nil, left: .document(variant.id), right: .document(id)), app: harness.app)
            await session.load()
            #expect(session.canTakeOver)
            guard case .document(_, let blocks) = session.comparison else { Issue.record("kein Vergleich"); return }
            let changed = try #require(blocks.first { $0.kind == .changed })
            await session.takeOver(changed)
            #expect(harness.app.document(id)?.markdown.contains("Einleitung kurz") == true)
            #expect(harness.app.document(id)?.markdown.contains("Zweiter Absatz.") == true)
            guard case .document(_, let after) = session.comparison else { Issue.record("kein Vergleich"); return }
            let onlyRight = try #require(after.first { $0.kind == .added })
            await session.takeOver(onlyRight)
            #expect(harness.app.document(id)?.markdown.contains("Zweiter Absatz.") == false)
            await session.undo()
            #expect(harness.app.document(id)?.markdown.contains("Zweiter Absatz.") == true)
            await session.takeOverAll()
            #expect(harness.app.document(id)?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) == "Einleitung kurz und ausführlich.\n\nDritter Absatz.\n\nVierter Absatz neu.")
            #expect(harness.app.document(id)?.variantOf == nil)
        }
    }
}
