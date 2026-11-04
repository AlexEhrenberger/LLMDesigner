import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Writer-Tabellen", .serialized)
struct WriterTableActionTests {
    let h = ActionHarness()

    private let sample = """
    | Name | Menge |
    | --- | --- |
    | Birne | 3 |
    | Apfel | 12 |
    | Kirsche | 5 |
    """

    private func table(_ id: String) async throws -> JSONValue {
        try await h.call("writer.table.read", ["doc": .string(id)])
    }

    /// What the editor would write for this text: an action's table must not differ from it.
    private func editorForm(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown)).trimmingCharacters(in: .newlines)
    }

    private func cells(_ value: JSONValue) throws -> [[String]] {
        try #require(value["cells"]?.arrayValue).map { try #require($0.arrayValue).map { $0.stringValue ?? "" } }
    }

    @Test func insertWithDataAndRead() async throws {
        let id = try await h.document("# Titel\n\nText")
        let result = try await h.call("writer.table.insert", [
            "doc": .string(id), "heading": "Titel", "header": ["A", "B"], "data": [["x|y", "1"], ["*z*", "=SUMME(B2:B2)"]],
        ])
        #expect(result["block"]?.stringValue?.hasPrefix("b1-") == true)
        let read = try await table(id)
        #expect(read["rows"] == 3)
        #expect(read["columns"] == 2)
        #expect(try cells(read) == [["A", "B"], ["x|y", "1"], ["*z*", "1"]])
        #expect(read["formulas"]?["B3"] == "=SUMME(B2:B2)")
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))
        #expect(h.trimmed(id).hasPrefix("# Titel\n\n"))
        #expect(h.trimmed(id).hasSuffix("Text"))
    }

    @Test func insertEmptyTakesRowsAndColumns() async throws {
        let id = try await h.document("")
        try await h.call("writer.table.insert", ["doc": .string(id), "rows": 3, "columns": 2])
        let read = try await table(id)
        #expect(read["rows"] == 3)
        #expect(read["columns"] == 2)
        #expect(await h.errorCode("writer.table.insert", ["doc": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func tablesAreFoundByNumberBlockAndName() async throws {
        let id = try await h.document("\(sample)\n\nMitte\n\n| X |\n| --- |\n| Y |")
        // Two tables: without saying which is not a guess.
        #expect(await h.errorCode("writer.table.read", ["doc": .string(id)]) == RPCError.ambiguousCode)
        let second = try await h.call("writer.table.read", ["doc": .string(id), "table": "2"])
        #expect(second["cells"]?.arrayValue?.first == ["X"])
        let byBlock = try await h.call("writer.table.read", ["doc": .string(id), "table": .string(try #require(second["block"]?.stringValue))])
        #expect(byBlock["number"] == 2)
        #expect(await h.errorCode("writer.table.read", ["doc": .string(id), "table": "3"]) == RPCError.notFoundCode)
        let noTable = try await h.document("Nur Text")
        #expect(await h.errorCode("writer.table.read", ["doc": .string(noTable)]) == RPCError.notFoundCode)
    }

    @Test func cellSetEscapesAndBecomesFormula() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.cell.set", ["doc": .string(id), "cell": "A2", "text": "Pflaume | blau"])
        try await h.call("writer.table.cell.set", ["doc": .string(id), "row": 3, "column": 1, "markdown": "**Apfel**"])
        let before = try await table(id)
        #expect(try cells(before)[1][0] == "Pflaume | blau")
        #expect(before["markdown"]?.arrayValue?[2].arrayValue?[0] == "**Apfel**")
        try await h.call("writer.table.cell.set", ["doc": .string(id), "cell": "B2", "text": "=2*3"])
        let after = try await table(id)
        #expect(try cells(after)[1][1] == "6")
        #expect(after["formulas"]?["B2"] == "=2*3")
        // Typed over: the formula is gone, as in the editor.
        try await h.call("writer.table.cell.set", ["doc": .string(id), "cell": "B2", "text": "7"])
        #expect((try await table(id))["formulas"] == [:])
        #expect(await h.errorCode("writer.table.cell.set", ["doc": .string(id), "cell": "Z9", "text": "x"]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.table.cell.set", ["doc": .string(id), "cell": "Oben", "text": "x"]) == RPCError.invalidParamsCode)
    }

    @Test func rowsAndColumnsComeAndGo() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.row.insert", ["doc": .string(id), "at": 1, "position": "below"])
        #expect(try cells(try await table(id))[1] == ["", ""])
        try await h.call("writer.table.row.delete", ["doc": .string(id), "at": 2])
        #expect((try await table(id))["rows"] == 4)
        try await h.call("writer.table.column.insert", ["doc": .string(id), "at": 1, "position": "left"])
        #expect(try cells(try await table(id))[0] == ["", "Name", "Menge"])
        try await h.call("writer.table.column.delete", ["doc": .string(id), "at": 1])
        #expect(try cells(try await table(id))[0] == ["Name", "Menge"])
        #expect(h.trimmed(id) == editorForm(sample))
        // Row 9 isn't there.
        #expect(await h.errorCode("writer.table.row.delete", ["doc": .string(id), "at": 9]) == RPCError.notFoundCode)
    }

    @Test func theLastRowTakesTheTableAlong() async throws {
        let id = try await h.document("Davor\n\n| X |\n| --- |\n\nDanach")
        try await h.call("writer.table.column.delete", ["doc": .string(id), "at": 1])
        #expect(h.trimmed(id) == "Davor\n\nDanach")
        let rows = try await h.document("| X |\n| --- |")
        try await h.call("writer.table.row.delete", ["doc": .string(rows), "at": 1])
        #expect(h.trimmed(rows).isEmpty)
    }

    @Test func formulasMoveWithInsertedRows() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.sumRow", ["doc": .string(id)])
        let summed = try await table(id)
        #expect(try cells(summed)[4] == ["Summe", "20"])
        #expect(summed["formulas"]?["B5"] == "=SUMME(B2:B4)")
        try await h.call("writer.table.row.insert", ["doc": .string(id), "at": 2])
        let shifted = try await table(id)
        #expect(shifted["formulas"]?["B6"] != nil)
        #expect(try cells(shifted)[5][1] == "20")
    }

    @Test func mergeAndSplit() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.cells.merge", ["doc": .string(id), "from": "A2", "to": "B2"])
        var read = try await table(id)
        #expect(read["merged"]?.arrayValue?.first?["cell"] == "A2")
        #expect(read["merged"]?.arrayValue?.first?["columns"] == 2)
        #expect(try cells(read)[1] == ["Birne 3", ""])
        #expect(h.trimmed(id).contains("| Birne 3 | << |"))
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))

        try await h.call("writer.table.cell.split", ["doc": .string(id), "cell": "A2"])
        read = try await table(id)
        #expect(read["merged"] == [])
        #expect(await h.errorCode("writer.table.cell.split", ["doc": .string(id), "cell": "A2"]) == RPCError.invalidTargetCode)

        try await h.call("writer.table.cells.merge", ["doc": .string(id), "cell": "A3", "direction": "down"])
        read = try await table(id)
        #expect(read["merged"]?.arrayValue?.first?["rows"] == 2)
        #expect(h.trimmed(id).contains("| ^^ |"))
        // Deleting the row a merged cell begins in keeps its text.
        try await h.call("writer.table.row.delete", ["doc": .string(id), "at": 3])
        #expect(try cells(try await table(id))[2][0].hasPrefix("Apfel"))
    }

    @Test func alignmentAndWidths() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.align", ["doc": .string(id), "column": 2, "alignment": "right"])
        #expect((try await table(id))["alignments"] == ["left", "right"])
        try await h.call("writer.table.columns.setWidths", ["doc": .string(id), "widths": [3, 1]])
        let read = try await table(id)
        #expect(read["widths"]?.arrayValue?.count == 2)
        #expect(h.trimmed(id).contains(String(repeating: "-", count: 75)))
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))
        try await h.call("writer.table.columns.equalize", ["doc": .string(id)])
        #expect((try await table(id))["widths"] == nil)
        #expect(await h.errorCode("writer.table.columns.setWidths", ["doc": .string(id), "widths": [1, 2, 3]]) == RPCError.invalidParamsCode)
    }

    @Test func styleGoesIntoTheDiv() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.style", ["doc": .string(id), "lines": "grid", "lineWidth": 1, "from": "A1", "to": "B1", "fill": "#FFF2CC"])
        let read = try await table(id)
        #expect(read["lines"] == "grid")
        #expect(read["fills"]?["B1"] == "FFF2CC")
        #expect(h.trimmed(id).hasPrefix("::: {.table lines=grid line-width=1 fill=0.0:FFF2CC,0.1:FFF2CC}"))
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))
        // A table with a div is a table to everything else, too.
        let blocks = try await h.call("writer.blocks.list", ["doc": .string(id)])
        #expect(blocks["blocks"]?.arrayValue?.first?["type"] == "table")

        try await h.call("writer.table.style", ["doc": .string(id), "cell": "A1", "fill": "none"])
        #expect((try await table(id))["fills"]?["A1"] == nil)
        #expect(await h.errorCode("writer.table.style", ["doc": .string(id), "cell": "A1", "fill": "Quark"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.table.style", ["doc": .string(id)]) == RPCError.invalidParamsCode)
    }

    @Test func formulaSetAndRecalculate() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.formula.set", ["doc": .string(id), "cell": "B4", "formula": "=B2+B3"])
        #expect(try cells(try await table(id))[3][1] == "15")
        #expect(await h.errorCode("writer.table.formula.set", ["doc": .string(id), "cell": "B4", "formula": "=SUMME("]) == RPCError.invalidParamsCode)

        // A value changed behind the formula's back is caught by recalculating.
        let changed = h.text(id).replacingOccurrences(of: "| 15 |", with: "| 99 |")
        h.app.updateDocument(UUID(uuidString: id)!, markdown: changed)
        try await h.call("writer.table.recalculate", ["doc": .string(id)])
        #expect(try cells(try await table(id))[3][1] == "15")

        // Empty takes the formula away and the value stays.
        try await h.call("writer.table.formula.set", ["doc": .string(id), "cell": "B4", "formula": ""])
        let read = try await table(id)
        #expect(read["formulas"] == [:])
        #expect(try cells(read)[3][1] == "15")
    }

    @Test func sortKeepsTheSumRowAtTheEnd() async throws {
        let id = try await h.document(sample)
        try await h.call("writer.table.sumRow", ["doc": .string(id)])
        try await h.call("writer.table.sort", ["doc": .string(id), "column": 2, "ascending": false])
        let values = try cells(try await table(id)).map(\.[1])
        #expect(values == ["Menge", "12", "5", "3", "20"])
        try await h.call("writer.table.sort", ["doc": .string(id), "column": 1])
        #expect(try cells(try await table(id)).map(\.[0]) == ["Name", "Apfel", "Birne", "Kirsche", "Summe"])

        let short = try await h.document("| A |\n| --- |\n| 1 |")
        #expect(await h.errorCode("writer.table.sort", ["doc": .string(short), "column": 1]) == RPCError.invalidTargetCode)
    }

    @Test func deleteLeavesTheRest() async throws {
        let id = try await h.document("Davor\n\n\(sample)\n\nDanach")
        try await h.call("writer.table.delete", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Davor\n\nDanach")
    }

    @Test func aChartFollowsItsTable() async throws {
        let id = try await h.document(sample)
        let result = try await h.call("writer.table.toChart", ["doc": .string(id), "kind": "bar", "caption": "Obst"])
        #expect(result["block"]?.stringValue?.hasPrefix("b1-") == true)
        let name = try #require((try await table(id))["name"]?.stringValue)
        #expect(name.hasPrefix("tab-"))
        let line = try #require(PowerText.chunks(of: h.text(id)).last?.markdown)
        let reference = try #require(WriterImageReference.parse(line))
        #expect(reference.figure == .chart)
        #expect(reference.caption == "Obst")
        #expect(WriterImageStore.url(for: reference.source) != nil)
        var chart = try #require(WriterChart.decode(WriterImageStore.recipe(for: reference)))
        #expect(chart.kind == .bar)
        #expect(chart.series.first?.values == [3, 12, 5])

        try await h.call("writer.table.cell.set", ["doc": .string(id), "table": .string(name), "cell": "B2", "text": "30"])
        chart = try #require(WriterChart.decode(WriterImageStore.recipe(for: reference)))
        #expect(chart.series.first?.values == [30, 12, 5])

        let words = try await h.document("| A | B |\n| --- | --- |\n| x | y |")
        #expect(await h.errorCode("writer.table.toChart", ["doc": .string(words)]) == RPCError.invalidTargetCode)
    }

    @Test func aChangeIsOneUndoStepAndChecksTheVersion() async throws {
        let id = try await h.document(sample)
        let before = h.text(id)
        #expect(await h.errorCode("writer.table.sumRow", ["doc": .string(id), "ifVersion": "alt"]) == RPCError.versionConflictCode)
        try await h.call("writer.table.sumRow", ["doc": .string(id)])
        #expect(h.text(id) != before)
        try await h.call("writer.edit.undo")
        #expect(h.text(id) == before)
    }

    @Test func tablesWorkOnSlides() async throws {
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Tabellen \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("writer.table.insert", ["deck": .string(deck), "slideIndex": 1, "rows": 2, "columns": 2])
        let read = try await h.call("writer.table.read", ["deck": .string(deck), "slideIndex": 1])
        #expect(read["rows"] == 2)
    }

    @Test func foreignTablesMarkTheRun() async throws {
        let id = try await h.document(sample)
        var document = try #require(h.app.document(UUID(uuidString: id)!))
        document.provenance = .foreign
        h.app.restoreDocument(document)
        try await h.call("writer.table.read", ["doc": .string(id)], run: "tabellen-lauf")
        #expect(h.registry.runState(id: "tabellen-lauf", channel: .cli).hasReadUntrusted)
    }
}
}
