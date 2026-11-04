import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

@MainActor
@Suite("Writer-Actions: Dokumente und Lesen", .serialized)
struct WriterDocumentActionTests {
    let h = ActionHarness()

    @Test func createListReadRenameMove() async throws {
        let id = try await h.document("# Titel\n\nEin Absatz.")
        let list = try await h.call("writer.doc.list", ["query": "Ein Absatz"])
        #expect(list["documents"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == true)

        let read = try await h.call("writer.doc.read", ["doc": .string(id)])
        #expect(read["text"]?.stringValue?.contains("# Titel") == true)
        #expect(read["version"]?.stringValue == ActionVersion.of(h.text(id)))
        let plain = try await h.call("writer.doc.read", ["doc": .string(id), "format": "plain"])
        #expect(plain["text"]?.stringValue?.contains("#") == false)

        try await h.call("writer.doc.rename", ["doc": .string(id), "title": .string("Neuer Name \(id)")])
        #expect(h.app.document(UUID(uuidString: id)!)?.hasCustomTitle == true)

        let folderName = "Testordner \(UUID().uuidString)"
        try await h.call("writer.doc.move", ["doc": .string(id), "newFolder": .string(folderName)])
        let folder = try #require(h.app.chatFolders.first { $0.name == folderName })
        #expect(h.app.document(UUID(uuidString: id)!)?.folderID == folder.id)
        let inFolder = try await h.call("writer.doc.list", ["folder": .string(folderName)])
        #expect(inFolder["documents"]?.arrayValue?.count == 1)
    }

    @Test func aNewDocumentDoesNotTakeTheScreen() async throws {
        let before = h.app.selectedDocumentID
        _ = try await h.document("Text")
        #expect(h.app.selectedDocumentID == before)
    }

    @Test func openShowsTheDocument() async throws {
        let id = try await h.document("Offen")
        try await h.call("writer.doc.open", ["doc": .string(id)])
        #expect(h.app.selectedDocumentID?.uuidString == id)
        let state = try await h.call("writer.state.get")
        #expect(state["openDocument"]?.stringValue == id)
        try await h.call("writer.doc.close")
        #expect(h.app.selectedDocumentID == nil)
    }

    @Test func aTitleCanFindADocumentButNeverGuesses() async throws {
        let title = "Doppelt \(UUID().uuidString)"
        let first = try await h.call("writer.doc.create", ["title": .string(title)])
        #expect(try await h.call("writer.doc.read", ["doc": .string(title)])["id"] == first["id"])
        try await h.call("writer.doc.create", ["title": .string(title)])
        #expect(await h.errorCode("writer.doc.read", ["doc": .string(title)]) == RPCError.ambiguousCode)
        #expect(await h.errorCode("writer.doc.read", ["doc": "gibt es nicht 42"]) == RPCError.notFoundCode)
    }

    @Test func deleteAsksAndDeletes() async throws {
        let id = try await h.document("Weg damit")
        var seen: [ApprovalRequest] = []
        h.registry.approval.presenter = { seen.append($0); return false }
        #expect(await h.errorCode("writer.doc.delete", ["doc": .string(id)]) == RPCError.deniedCode)
        #expect(h.text(id) != "<weg>")
        #expect(seen.first?.reason.isEmpty == false)
        #expect(seen.first?.target?.hasPrefix("Test ") == true)

        h.registry.approval.presenter = { _ in true }
        try await h.call("writer.doc.delete", ["doc": .string(id)])
        #expect(h.text(id) == "<weg>")
    }

    @Test func duplicateKeepsTheText() async throws {
        let id = try await h.document("Original")
        let copy = try await h.call("writer.doc.duplicate", ["doc": .string(id), "title": "Kopie X"])
        #expect(h.trimmed(try #require(copy["id"]?.stringValue)) == "Original")
    }

    @Test func blocksHaveIdsThatGoStale() async throws {
        let id = try await h.document("# Titel\n\nErster.\n\nZweiter.")
        let list = try await h.call("writer.blocks.list", ["doc": .string(id)])
        let blocks = try #require(list["blocks"]?.arrayValue)
        #expect(blocks.map { $0["type"]?.stringValue } == ["heading", "paragraph", "paragraph"])
        #expect(blocks[0]["level"] == 1)
        let second = try #require(blocks[1]["id"]?.stringValue)
        try await h.call("writer.text.replace", ["doc": .string(id), "block": .string(second), "text": "Geändert."])
        #expect(h.trimmed(id) == "# Titel\n\nGeändert.\n\nZweiter.")
        // The block changed: its old id must not hit whatever is there now.
        #expect(await h.errorCode("writer.text.delete", ["doc": .string(id), "block": .string(second)]) == RPCError.versionConflictCode)
    }

    @Test func outlineFindStats() async throws {
        let id = try await h.document("# Kapitel\n\nEin Wort hier, ein Wort dort.\n\n## Unterpunkt\n\nAnderes.")
        let outline = try await h.call("writer.outline.get", ["doc": .string(id)])
        #expect(outline["headings"]?.arrayValue?.map { $0["title"]?.stringValue } == ["Kapitel", "Unterpunkt"])
        let found = try await h.call("writer.find", ["doc": .string(id), "query": "wort"])
        #expect(found["count"] == 2)
        let exact = try await h.call("writer.find", ["doc": .string(id), "query": "wort", "caseSensitive": true])
        #expect(exact["count"] == 0)
        let stats = try await h.call("writer.doc.stats", ["doc": .string(id)])
        #expect(stats["blocks"] == 4)
        #expect(stats["pages"] == 1)
    }

    @Test func readingASection() async throws {
        let id = try await h.document("# A\n\nText A.\n\n## A1\n\nText A1.\n\n# B\n\nText B.")
        let section = try await h.call("writer.doc.read", ["doc": .string(id), "heading": "A"])
        #expect(section["text"]?.stringValue?.contains("Text A1.") == true)
        #expect(section["text"]?.stringValue?.contains("Text B.") == false)
        let nested = try await h.call("writer.doc.read", ["doc": .string(id), "heading": "A/A1"])
        #expect(nested["text"]?.stringValue?.contains("Text A.") == false)
        #expect(await h.errorCode("writer.doc.read", ["doc": .string(id), "heading": "A/Fehlt"]) == RPCError.notFoundCode)
    }
}

@MainActor
@Suite("Writer-Actions: Adressen und Versionen", .serialized)
struct WriterAddressTests {
    let h = ActionHarness()

    @Test func onlyOneAddressForm() async throws {
        let id = try await h.document("Text")
        #expect(await h.errorCode("writer.text.delete", ["doc": .string(id), "match": "Text", "all": true]) == RPCError.invalidParamsCode)
    }

    @Test func aMissingAddressIsAnError() async throws {
        let id = try await h.document("Text")
        #expect(await h.errorCode("writer.text.delete", ["doc": .string(id)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func matchWithSeveralHitsNeedsAnOccurrence() async throws {
        let id = try await h.document("Wort und Wort und Wort.")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Wort"]) == RPCError.ambiguousCode)
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Wort", "occurrence": 2])
        #expect(h.trimmed(id) == "Wort und **Wort** und Wort.")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Wort", "occurrence": 9]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Fehlt"]) == RPCError.notFoundCode)
    }

    @Test func matchFindsTextAcrossMarks() async throws {
        let id = try await h.document("Ein **fettes** Wort.")
        try await h.call("writer.format.italic", ["doc": .string(id), "match": "fettes Wort"])
        #expect(h.trimmed(id) == "Ein ***fettes*** *Wort*.")
    }

    @Test func staleVersionIsRefused() async throws {
        let id = try await h.document("Alt.")
        let version = ActionVersion.of(h.text(id))
        try await h.call("writer.text.replace", ["doc": .string(id), "match": "Alt", "text": "Neu", "ifVersion": .string(version)])
        #expect(await h.errorCode("writer.text.replace", ["doc": .string(id), "match": "Neu", "text": "Neuer", "ifVersion": .string(version)]) == RPCError.versionConflictCode)
        #expect(h.trimmed(id) == "Neu.")
    }

    @Test func headingPathFindsNestedHeading() async throws {
        let id = try await h.document("# A\n\n## Ende\n\nx\n\n# B\n\n## Ende\n\ny")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "heading": "Ende"]) == RPCError.ambiguousCode)
        try await h.call("writer.text.replace", ["doc": .string(id), "heading": "B/Ende", "text": "Schluss"])
        #expect(h.trimmed(id) == "# A\n\n## Ende\n\nx\n\n# B\n\n## Schluss\n\ny")
    }

    @Test func rangeWorksOnTheSource() async throws {
        let id = try await h.document("0123456789")
        try await h.call("writer.text.delete", ["doc": .string(id), "range": "2:3"])
        #expect(h.trimmed(id) == "0156789")
        #expect(await h.errorCode("writer.text.delete", ["doc": .string(id), "range": "x"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.text.delete", ["doc": .string(id), "range": "99:1"]) == RPCError.invalidParamsCode)
    }

    @Test func rangeFormatsTheRightRepeat() async throws {
        let id = try await h.document("Wort Wort Wort")
        try await h.call("writer.format.bold", ["doc": .string(id), "range": "5:4", "state": "on"])
        #expect(h.trimmed(id) == "Wort **Wort** Wort")
    }
}

@MainActor
@Suite("Writer-Actions: Text", .serialized)
struct WriterTextActionTests {
    let h = ActionHarness()

    @Test func insertWithoutAddressAppends() async throws {
        let id = try await h.document("Erster.")
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "*kein* Markdown"])
        #expect(h.trimmed(id) == "Erster.\n\n\\*kein\\* Markdown")
    }

    @Test func insertAtAMatch() async throws {
        let id = try await h.document("Ein Wort hier.")
        try await h.call("writer.text.insert", ["doc": .string(id), "match": "Wort", "text": " mehr"])
        #expect(h.trimmed(id) == "Ein Wort mehr hier.")
        try await h.call("writer.text.insert", ["doc": .string(id), "match": "Ein", "text": "Noch ", "position": "before"])
        #expect(h.trimmed(id) == "Noch Ein Wort mehr hier.")
    }

    @Test func insertedTextTakesTheMarksOfItsPlace() async throws {
        let id = try await h.document("Ein **fettes** Wort.")
        try await h.call("writer.text.insert", ["doc": .string(id), "match": "fettes", "text": " und"])
        #expect(h.trimmed(id) == "Ein **fettes und** Wort.")
    }

    @Test func insertMarkdownInPlaces() async throws {
        let id = try await h.document("# Titel\n\nAbsatz.")
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "markdown": "- a\n- b"])
        #expect(h.trimmed(id) == "# Titel\n\nAbsatz.\n\n- a\n- b")
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "heading": "Titel", "markdown": "Vorwort."])
        #expect(h.trimmed(id) == "# Titel\n\nVorwort.\n\nAbsatz.\n\n- a\n- b")
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "heading": "Titel", "markdown": "Davor.", "position": "before"])
        #expect(h.trimmed(id).hasPrefix("Davor.\n\n# Titel"))
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "match": "Vorwort", "markdown": " **fett**"])
        #expect(h.trimmed(id).contains("Vorwort **fett**."))
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "all": true, "markdown": "Alles neu.", "position": "replace"])
        #expect(h.trimmed(id) == "Alles neu.")
    }

    @Test func blocksCannotReplaceAWordInAParagraph() async throws {
        let id = try await h.document("Ein Wort hier.")
        #expect(await h.errorCode("writer.text.insertMarkdown", ["doc": .string(id), "match": "Wort", "markdown": "# Titel\n\nText", "position": "replace"]) == RPCError.invalidTargetCode)
        #expect(h.trimmed(id) == "Ein Wort hier.")
    }

    @Test func replaceAndDelete() async throws {
        let id = try await h.document("Alt und **fett alt** hier.\n\nZweiter.")
        try await h.call("writer.text.replace", ["doc": .string(id), "match": "fett alt", "text": "fett neu"])
        #expect(h.trimmed(id).contains("**fett neu**"))
        try await h.call("writer.text.replace", ["doc": .string(id), "match": "Alt", "markdown": "*Neu*"])
        #expect(h.trimmed(id).hasPrefix("*Neu* und"))
        try await h.call("writer.text.delete", ["doc": .string(id), "match": " und"])
        #expect(h.trimmed(id).hasPrefix("*Neu* **fett"))
        #expect(await h.errorCode("writer.text.replace", ["doc": .string(id), "match": "Neu"]) == RPCError.invalidParamsCode)
        try await h.call("writer.text.delete", ["doc": .string(id), "all": true])
        #expect(h.trimmed(id) == "")
    }

    @Test func replaceAll() async throws {
        let id = try await h.document("rot und rot, nicht blau.")
        try await h.call("writer.text.replaceAll", ["doc": .string(id), "find": "rot", "replace": "grün"])
        #expect(h.trimmed(id) == "grün und grün, nicht blau.")
        #expect(await h.errorCode("writer.text.replaceAll", ["doc": .string(id), "find": "gelb", "replace": "x"]) == RPCError.notFoundCode)
    }

    @Test func newParagraphs() async throws {
        let id = try await h.document("Vorne hinten.")
        try await h.call("writer.paragraph.new", ["doc": .string(id), "match": "Vorne"])
        #expect(h.trimmed(id) == "Vorne\n\nhinten.")
        try await h.call("writer.paragraph.new", ["doc": .string(id), "text": "Am Ende."])
        #expect(h.trimmed(id) == "Vorne\n\nhinten.\n\nAm Ende.")
        #expect(await h.errorCode("writer.paragraph.new", ["doc": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func moveBlock() async throws {
        let id = try await h.document("Eins.\n\nZwei.\n\nDrei.")
        let blocks = try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue ?? []
        try await h.call("writer.block.move", ["doc": .string(id), "block": blocks[2]["id"]!, "before": blocks[0]["id"]!])
        #expect(h.trimmed(id) == "Drei.\n\nEins.\n\nZwei.")
    }

    @Test func headingInsert() async throws {
        let id = try await h.document("Text.")
        try await h.call("writer.heading.insert", ["doc": .string(id), "level": 2, "text": "Mehr"])
        try await h.call("writer.heading.insert", ["doc": .string(id), "level": 0, "text": "Kapitel"])
        #expect(h.trimmed(id) == "Text.\n\n## Mehr\n\n# Kapitel {.chapter}")
    }

    @Test func otherBlocksStayByteForByte() async throws {
        // A table with its compact separator isn't touched by a change next to it.
        let id = try await h.document("| A | B |\n|---|---|\n| 1 | 2 |\n\nWort.")
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Wort", "state": "on"])
        #expect(h.trimmed(id) == "| A | B |\n|---|---|\n| 1 | 2 |\n\n**Wort**.")
    }

    @Test func aChangeReachesTheModelWhileTheDocumentIsOpen() async throws {
        let id = try await h.document("Offen.")
        try await h.call("writer.doc.open", ["doc": .string(id)])
        var flushed = 0
        h.app.writerFlush = { flushed += 1 }
        defer { h.app.writerFlush = nil }
        try await h.call("writer.text.replace", ["doc": .string(id), "match": "Offen", "text": "Geändert"])
        // The editor's unsaved text is brought in first; what it then shows comes from the model.
        #expect(flushed >= 1)
        #expect(h.app.selectedDocument?.markdown.contains("Geändert") == true)
        try await h.call("writer.doc.close")
    }
}

@MainActor
@Suite("Writer-Actions: Format und Blöcke", .serialized)
struct WriterFormatActionTests {
    let h = ActionHarness()

    static let marks: [(String, String)] = [
        ("bold", "**Wort**"), ("italic", "*Wort*"), ("underline", "<u>Wort</u>"), ("strikethrough", "~~Wort~~"),
        ("code", "`Wort`"), ("superscript", "<sup>Wort</sup>"), ("subscript", "<sub>Wort</sub>"),
    ]

    @Test(arguments: marks)
    func markOnIsIdempotentAndOffRemoves(_ name: String, _ marked: String) async throws {
        let id = try await h.document("Ein Wort hier.")
        let action = "writer.format.\(name)"
        try await h.call(action, ["doc": .string(id), "match": "Wort", "state": "on"])
        #expect(h.trimmed(id) == "Ein \(marked) hier.")
        try await h.call(action, ["doc": .string(id), "match": "Wort", "state": "on"])
        #expect(h.trimmed(id) == "Ein \(marked) hier.")
        try await h.call(action, ["doc": .string(id), "match": "Wort", "state": "off"])
        #expect(h.trimmed(id) == "Ein Wort hier.")
        try await h.call(action, ["doc": .string(id), "match": "Wort"])
        #expect(h.trimmed(id) == "Ein \(marked) hier.")
        try await h.call(action, ["doc": .string(id), "match": "Wort"])
        #expect(h.trimmed(id) == "Ein Wort hier.")
    }

    @Test func raisedAndLoweredExcludeEachOther() async throws {
        let id = try await h.document("H2O")
        try await h.call("writer.format.superscript", ["doc": .string(id), "match": "2", "state": "on"])
        try await h.call("writer.format.subscript", ["doc": .string(id), "match": "2", "state": "on"])
        #expect(h.trimmed(id) == "H<sub>2</sub>O")
    }

    @Test func wholeBlockAndWholeDocument() async throws {
        let id = try await h.document("Eins.\n\nZwei.\n\n```\ncode\n```")
        try await h.call("writer.format.bold", ["doc": .string(id), "all": true, "state": "on"])
        #expect(h.trimmed(id) == "**Eins.**\n\n**Zwei.**\n\n```\ncode\n```")
        try await h.call("writer.format.clear", ["doc": .string(id), "all": true])
        #expect(h.trimmed(id) == "Eins.\n\nZwei.\n\n```\ncode\n```")
    }

    @Test func markInACodeBlockIsAnError() async throws {
        let id = try await h.document("```\ncode\n```")
        let block = try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue?.first?["id"]
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "block": block ?? ""]) == RPCError.invalidTargetCode)
    }

    @Test func clearAtAMatch() async throws {
        let id = try await h.document("Ein **fettes** und *kursives* Wort.")
        try await h.call("writer.format.clear", ["doc": .string(id), "match": "fettes"])
        #expect(h.trimmed(id) == "Ein fettes und *kursives* Wort.")
    }

    static let blockTypes: [(String, String)] = [
        ("heading1", "# Zeile"), ("heading2", "## Zeile"), ("heading3", "### Zeile"), ("chapter", "# Zeile {.chapter}"),
        ("bullet", "- Zeile"), ("numbered", "1. Zeile"), ("quote", "> Zeile"), ("code", "```\nZeile\n```"), ("paragraph", "Zeile"),
    ]

    @Test(arguments: blockTypes)
    func setBlockType(_ type: String, _ result: String) async throws {
        let id = try await h.document("Zeile")
        try await h.call("writer.block.set", ["doc": .string(id), "match": "Zeile", "type": .string(type)])
        #expect(h.trimmed(id) == result)
    }

    @Test func blockTypeCanComeBack() async throws {
        let id = try await h.document("# Zeile")
        try await h.call("writer.block.set", ["doc": .string(id), "heading": "Zeile", "type": "paragraph"])
        #expect(h.trimmed(id) == "Zeile")
        #expect(await h.errorCode("writer.block.set", ["doc": .string(id), "match": "Zeile", "type": "wolke"]) == RPCError.invalidParamsCode)
    }

    @Test func listLevels() async throws {
        let id = try await h.document("- eins\n- zwei")
        try await h.call("writer.list.level", ["doc": .string(id), "match": "zwei", "step": 1])
        #expect(h.trimmed(id) == "- eins\n  - zwei")
        try await h.call("writer.list.level", ["doc": .string(id), "match": "zwei", "step": -1])
        #expect(h.trimmed(id) == "- eins\n- zwei")
        let other = try await h.document("Kein Punkt")
        #expect(await h.errorCode("writer.list.level", ["doc": .string(other), "match": "Kein", "step": 1]) == RPCError.invalidTargetCode)
    }

    @Test func alignment() async throws {
        let id = try await h.document("Mittig.")
        try await h.call("writer.paragraph.align", ["doc": .string(id), "match": "Mittig", "alignment": "center"])
        #expect(h.trimmed(id) == "::: {.center}\nMittig.\n:::")
        try await h.call("writer.paragraph.align", ["doc": .string(id), "match": "Mittig", "alignment": "left"])
        #expect(h.trimmed(id) == "Mittig.")
    }

    @Test func ruleAndPageBreak() async throws {
        let id = try await h.document("Davor.\n\nDanach.")
        try await h.call("writer.insert.rule", ["doc": .string(id), "match": "Davor"])
        try await h.call("writer.insert.pageBreak", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Davor.\n\n---\n\nDanach.\n\n\\newpage")
    }
}

@MainActor
@Suite("Writer-Actions: Undo, Stapel, Export", .serialized)
struct WriterUndoExportTests {
    let h = ActionHarness()

    @Test func actionPlusUndoGivesTheOriginalBack() async throws {
        let id = try await h.document("Ein Wort.")
        let original = h.text(id)
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Wort", "state": "on"])
        let changed = h.text(id)
        #expect(changed != original)
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(h.text(id) == original)
        try await h.call("writer.edit.redo", ["doc": .string(id)])
        #expect(h.text(id) == changed)
    }

    @Test func undoInADocumentLeavesOthersAlone() async throws {
        let first = try await h.document("Eins.")
        let second = try await h.document("Zwei.")
        try await h.call("writer.text.replace", ["doc": .string(first), "match": "Eins", "text": "Geändert"])
        try await h.call("writer.text.replace", ["doc": .string(second), "match": "Zwei", "text": "Auch"])
        try await h.call("writer.edit.undo", ["doc": .string(first)])
        #expect(h.trimmed(first) == "Eins.")
        #expect(h.trimmed(second) == "Auch.")
    }

    @Test func undoOfCreateRemovesTheDocument() async throws {
        let id = try await h.document("Neu.")
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(h.text(id) == "<weg>")
        try await h.call("writer.edit.redo")
        #expect(h.trimmed(id) == "Neu.")
    }

    @Test func nothingToUndoIsAnError() async throws {
        #expect(await h.errorCode("writer.edit.redo") == RPCError.notFoundCode)
    }

    @Test func batchIsOneGroup() async throws {
        let id = try await h.document("Ein Wort.")
        let original = h.text(id)
        let results = try await h.registry.runBatch([
            ("writer.format.bold", ["doc": .string(id), "match": "Wort", "state": "on"]),
            ("writer.text.insert", ["doc": .string(id), "text": "Zweiter."]),
        ], app: h.app, channel: .cli)
        #expect(results.count == 2)
        #expect(h.trimmed(id) == "Ein **Wort**.\n\nZweiter.")
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        #expect(h.text(id) == original)
    }

    @Test func aFailingStepLeavesNothingChanged() async throws {
        let id = try await h.document("Ein Wort.")
        let original = h.text(id)
        do {
            _ = try await h.registry.runBatch([
                ("writer.format.bold", ["doc": .string(id), "match": "Wort", "state": "on"]),
                ("writer.text.insert", ["doc": .string(id), "text": "Zweiter."]),
                ("writer.text.delete", ["doc": .string(id), "match": "Gibt es nicht"]),
                ("writer.text.insert", ["doc": .string(id), "text": "Vierter."]),
            ], app: h.app, channel: .cli)
            Issue.record("hätte scheitern müssen")
        } catch let error as RPCError {
            #expect(error.code == RPCError.notFoundCode)
            #expect(error.message.hasPrefix("Schritt 3"))
            #expect(error.data?["step"] == 2)
        }
        #expect(h.text(id) == original)
    }

    private func exportFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        return folder
    }

    @Test func exportToTheFolderNeedsNoQuestion() async throws {
        let folder = exportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var asked = 0
        h.registry.approval.presenter = { _ in asked += 1; return true }
        let id = try await h.document("# Bericht\n\nInhalt.")
        let result = try await h.call("writer.export", ["doc": .string(id), "format": "markdown"])
        #expect(asked == 0)
        let path = try #require(result["path"]?.stringValue)
        #expect(path.hasPrefix(folder.resolvingSymlinksInPath().path) || path.hasPrefix(folder.path))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("Inhalt."))
    }

    @Test func exportElsewhereAsksAndCanBeRefused() async throws {
        let folder = exportFolder()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Anderswo-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        var seen: [ApprovalRequest] = []
        h.registry.approval.presenter = { seen.append($0); return false }
        let id = try await h.document("Inhalt.")
        #expect(await h.errorCode("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(outside.path)]) == RPCError.deniedCode)
        #expect(seen.first?.target == outside.path)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        h.registry.approval.presenter = { _ in true }
        try await h.call("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(outside.path)])
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(await h.errorCode("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(outside.path)]) == RPCError.invalidTargetCode)
        try await h.call("writer.export", ["doc": .string(id), "format": "markdown", "path": .string(outside.path), "overwrite": true])
    }

    @Test func aPathCannotClimbOutOfTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/exporte", isDirectory: true)
        #expect(ActionExportFolder.contains(URL(fileURLWithPath: "/tmp/exporte/a.pdf"), folder: folder))
        #expect(ActionExportFolder.contains(URL(fileURLWithPath: "/tmp/exporte/unter/a.pdf"), folder: folder))
        #expect(!ActionExportFolder.contains(URL(fileURLWithPath: "/tmp/exporte/../a.pdf"), folder: folder))
        #expect(!ActionExportFolder.contains(URL(fileURLWithPath: "/tmp/exporte-nicht/a.pdf"), folder: folder))
        #expect(!ActionExportFolder.contains(URL(fileURLWithPath: "/etc/a.pdf"), folder: folder))
    }

    @Test func aLinkInTheFolderCannotLeadOut() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Link-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("exporte", isDirectory: true)
        let outside = base.appendingPathComponent("draussen", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let link = folder.appendingPathComponent("tuer")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!ActionExportFolder.contains(link.appendingPathComponent("a.pdf"), folder: folder))
    }
}

@MainActor
@Suite("Sicherheit: Herkunft von Dokumenten", .serialized)
struct ProvenanceTests {
    let h = ActionHarness()

    private func provenance(_ id: String) -> DocumentProvenance? {
        h.app.document(UUID(uuidString: id)!)?.provenance
    }

    private func foreignDocument(_ markdown: String = "Fremder Text.") async throws -> String {
        let id = try await h.call("writer.doc.create", ["title": .string("Fremd \(UUID().uuidString)"), "markdown": .string(markdown)], channel: .mcp)
        return try #require(id["id"]?.stringValue)
    }

    @Test func ownByDefault() async throws {
        #expect(provenance(try await h.document("Text")) == nil)
    }

    @Test func anMcpClientsTextIsForeign() async throws {
        #expect(provenance(try await foreignDocument()) == .foreign)
    }

    @Test func readingForeignMarksTheRun() async throws {
        let id = try await foreignDocument()
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("writer.doc.read", ["doc": .string(id)], run: run)
        #expect(h.registry.runState(id: run, channel: .cli).hasReadUntrusted)
    }

    @Test func readingOwnDoesNotMarkTheRun() async throws {
        let id = try await h.document("Eigener Text.")
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("writer.doc.read", ["doc": .string(id)], run: run)
        #expect(!h.registry.runState(id: run, channel: .cli).hasReadUntrusted)
    }

    @Test func aMarkedRunInfectsWhatItWrites() async throws {
        let foreign = try await foreignDocument()
        let own = try await h.document("Mein Text.")
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("writer.doc.read", ["doc": .string(foreign)], run: run)
        try await h.call("writer.text.insert", ["doc": .string(own), "text": "Übernommen."], run: run)
        #expect(provenance(own) == .foreign)
    }

    @Test func aCleanRunLeavesOriginAlone() async throws {
        let own = try await h.document("Mein Text.")
        try await h.call("writer.text.insert", ["doc": .string(own), "text": "Mehr."])
        #expect(provenance(own) == nil)
    }

    @Test func aCleanEditDoesNotLaunderAForeignDocument() async throws {
        let foreign = try await foreignDocument()
        try await h.call("writer.text.insert", ["doc": .string(foreign), "text": "Auch von mir."])
        #expect(provenance(foreign) == .foreign)
    }

    @Test func undoAlsoTakesBackTheInfection() async throws {
        let foreign = try await foreignDocument()
        let own = try await h.document("Mein Text.")
        let run = "lauf-\(UUID().uuidString)"
        try await h.call("writer.doc.read", ["doc": .string(foreign)], run: run)
        try await h.call("writer.text.insert", ["doc": .string(own), "text": "Übernommen."], run: run)
        try await h.call("writer.edit.undo", ["doc": .string(own)])
        #expect(provenance(own) == nil)
    }

    @Test func exportingForeignAsks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { try? FileManager.default.removeItem(at: folder) }
        let foreign = try await foreignDocument()
        var seen: [ApprovalRequest] = []
        h.registry.approval.presenter = { seen.append($0); return false }
        #expect(await h.errorCode("writer.export", ["doc": .string(foreign), "format": "markdown"]) == RPCError.deniedCode)
        #expect(seen.first?.reason.contains("fremde") == true)
    }

    @Test func confirmationAlwaysAsksAndClears() async throws {
        let foreign = try await foreignDocument()
        var seen: [ApprovalRequest] = []
        h.registry.approval.presenter = { seen.append($0); return false }
        #expect(await h.errorCode("writer.doc.confirmReviewed", ["doc": .string(foreign)]) == RPCError.deniedCode)
        #expect(provenance(foreign) == .foreign)
        #expect(seen.count == 1)

        h.registry.approval.presenter = { _ in true }
        try await h.call("writer.doc.confirmReviewed", ["doc": .string(foreign)])
        #expect(provenance(foreign) == .own)
    }

    @Test func anMcpRunCannotConfirmEvenIfSomeoneClicks() async throws {
        let foreign = try await foreignDocument()
        #expect(await h.errorCode("writer.doc.confirmReviewed", ["doc": .string(foreign)], channel: .mcp) == RPCError.deniedCode)
        #expect(provenance(foreign) == .foreign)
    }

    @Test func provenanceSurvivesTheFile() throws {
        var document = WriterDocument()
        document.markdown = "Text"
        document.title = "Titel"
        document.provenance = .foreign
        let encoded = WriterDocumentStore.encode(document)
        #expect(encoded.contains("herkunft: fremd"))
        #expect(WriterDocumentStore.decode(encoded, fallbackID: nil)?.provenance == .foreign)

        document.provenance = nil
        let own = WriterDocumentStore.encode(document)
        #expect(!own.contains("herkunft"))
        #expect(WriterDocumentStore.decode(own, fallbackID: nil)?.provenance == nil)
    }
}
