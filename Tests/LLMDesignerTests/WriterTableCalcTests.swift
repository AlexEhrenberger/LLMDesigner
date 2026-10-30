import Testing
import AppKit
@testable import LLMDesigner

@Suite("Rechnende Tabellen, Diagramme aus Tabellen und Figuren im Markdown")
struct WriterTableCalcTests {
    private func roundTrip(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown))
    }

    // MARK: Numbers

    @Test func readsNumbersAsWrittenInGermanAndEnglish() {
        #expect(WriterTableCalc.number(in: "12")?.value == 12)
        #expect(WriterTableCalc.number(in: "-3,5")?.value == -3.5)
        #expect(WriterTableCalc.number(in: "1.234,56 €")?.value == 1234.56)
        #expect(WriterTableCalc.number(in: "1.234,56 €")?.unit == "€")
        #expect(WriterTableCalc.number(in: "12 %")?.unit == "%")
        #expect(WriterTableCalc.number(in: "3.75")?.value == 3.75)
        #expect(WriterTableCalc.number(in: "$ 4.50")?.value == 4.5)
        #expect(WriterTableCalc.number(in: "Äpfel") == nil)
        #expect(WriterTableCalc.number(in: "Q1") == nil)
        #expect(WriterTableCalc.number(in: "") == nil)
    }

    @Test func formatsResultsLikeTheirInputs() {
        let euro = WriterTableCalc.number(in: "12,50 €")
        #expect(WriterTableCalc.format(25, like: euro) == "25,00 €")
        #expect(WriterTableCalc.format(1.5, like: nil) == "1,5")
        #expect(WriterTableCalc.format(-2, like: nil) == "−2")
        let point = WriterTableCalc.number(in: "1.25")
        #expect(WriterTableCalc.format(2.5, like: point) == "2.50")
    }

    @Test func namesCellsLikeASpreadsheet() {
        #expect(WriterTableCalc.cellName(row: 0, column: 0) == "A1")
        #expect(WriterTableCalc.cellName(row: 3, column: 1) == "B4")
        #expect(WriterTableCalc.columnName(26) == "AA")
        #expect(WriterTableCalc.column(named: "AA") == 26)
    }

    // MARK: Formulas

    private let cells = [
        ["Monat", "Umsatz", "Kosten"],
        ["Januar", "1.200 €", "800 €"],
        ["Februar", "1.500 €", "900 €"],
        ["März", "900 €", "1.000 €"],
        ["Summe", "", ""],
    ]

    @Test func calculatesSumsAveragesAndArithmetic() {
        let formulas: [WriterCellPosition: String] = [
            WriterCellPosition(row: 4, column: 1): "SUMME(B2:B4)",
            WriterCellPosition(row: 4, column: 2): "SUM(C2:C4)",
        ]
        let results = WriterTableCalc.evaluate(cells: cells, formulas: formulas)
        #expect(results[WriterCellPosition(row: 4, column: 1)] == "3.600 €")
        #expect(results[WriterCellPosition(row: 4, column: 2)] == "2.700 €")

        let more = WriterTableCalc.evaluate(cells: [["a", "b"], ["2", "4"], ["", ""]], formulas: [
            WriterCellPosition(row: 2, column: 0): "MITTELWERT(A2:B2)",
            WriterCellPosition(row: 2, column: 1): "=A2*B2+1",
        ])
        #expect(more[WriterCellPosition(row: 2, column: 0)] == "3")
        #expect(more[WriterCellPosition(row: 2, column: 1)] == "9")
    }

    @Test func roundsComparesAndReportsErrors() {
        let grid = [["x", "y"], ["10", "3"], ["", ""]]
        let results = WriterTableCalc.evaluate(cells: grid, formulas: [
            WriterCellPosition(row: 2, column: 0): "RUNDEN(A2/B2; 2)",
            WriterCellPosition(row: 2, column: 1): "WENN(A2>B2; 1; 0)",
        ])
        #expect(results[WriterCellPosition(row: 2, column: 0)] == "3,33")
        #expect(results[WriterCellPosition(row: 2, column: 1)] == "1")
        let errors = WriterTableCalc.evaluate(cells: grid, formulas: [
            WriterCellPosition(row: 2, column: 0): "A2/0",
            WriterCellPosition(row: 2, column: 1): "B3+1",
        ])
        #expect(errors[WriterCellPosition(row: 2, column: 0)] == "#DIV/0!")
        #expect(errors[WriterCellPosition(row: 2, column: 1)] == "#ZIRKEL!")
        let syntax = WriterTableCalc.evaluate(cells: grid, formulas: [WriterCellPosition(row: 2, column: 0): "SUMME(A2:"])
        #expect(syntax[WriterCellPosition(row: 2, column: 0)] == "#FORMEL!")
    }

    @Test func formulasFollowRowsAndColumnsThatComeAndGo() {
        #expect(WriterTableCalc.shifting("SUMME(B2:B4)", at: 2, isRow: true, delta: 1) == "SUMME(B2:B5)")
        #expect(WriterTableCalc.shifting("SUMME(B2:B4)", at: 3, isRow: true, delta: -1) == "SUMME(B2:B3)")
        #expect(WriterTableCalc.shifting("A2*C2", at: 1, isRow: false, delta: 1) == "A2*D2")
        #expect(WriterTableCalc.shifting("B3+1", at: 2, isRow: true, delta: -1) == "#BEZUG!+1")
        #expect(WriterTableCalc.movingRow("B3*C3", from: 2, to: 4) == "B5*C5")
        #expect(WriterTableCalc.referencedRows("SUMME(B2:B4)+C7") == [1, 2, 3, 6])

        let style = WriterTableStyle(formulas: [WriterCellPosition(row: 4, column: 1): "SUMME(B2:B4)"])
        let shifted = style.formulasShifted(at: 2, isRow: true, delta: 1)
        #expect(shifted == [WriterCellPosition(row: 5, column: 1): "SUMME(B2:B5)"])
    }

    @Test func sortsNumbersByValueAndTextAlphabetically() {
        #expect(WriterTableCalc.ascending("9", "10") == true)
        #expect(WriterTableCalc.ascending("1.200 €", "900 €") == false)
        #expect(WriterTableCalc.ascending("Äpfel", "Birnen") == true)
        #expect(WriterTableCalc.ascending("Datei 2", "Datei 10") == true)
    }

    // MARK: Storage

    @Test func formulasAndTheTablesNameRoundTrip() {
        let markdown = """
        ::: {.table #tab-1a2b3c4d calc-2-1="SUMME(B2:B2)"}
        | Ding | Wert |
        | --- | --- |
        | A | 2 |
        | Summe | 2 |
        :::

        """
        let text = WriterMarkdown.attributedString(from: markdown)
        let range = (text.string as NSString).range(of: "Summe")
        let table = text.attribute(.writerTable, at: range.location, effectiveRange: nil) as? WriterTable
        #expect(table?.style.id == "tab-1a2b3c4d")
        #expect(table?.style.formulas == [WriterCellPosition(row: 2, column: 1): "SUMME(B2:B2)"])
        #expect(roundTrip(markdown) == markdown)
    }

    @Test func figuresKeepTheirKind() {
        for kind in WriterFigureKind.allCases {
            let line = "![Bild](Bilder/\(kind.filePrefix)-1.png){width=80% .\(kind.rawValue)}"
            let reference = WriterImageReference.parse(line)
            #expect(reference?.figure == kind)
            #expect(reference?.hasVariants == true)
            #expect(reference?.markdown == line)
        }
    }

    // MARK: Charts

    @Test func chartsTakeTheNumbersOfATable() {
        var chart = WriterChart()
        chart.takeData(from: cells, formulas: [WriterCellPosition(row: 4, column: 1): "SUMME(B2:B4)"])
        #expect(chart.categories == ["Januar", "Februar", "März"])
        #expect(chart.series.map(\.name) == ["Umsatz", "Kosten"])
        #expect(chart.series[0].values == [1200, 1500, 900])
        #expect(chart.unit == "€")
        chart.transposed = true
        chart.takeData(from: cells, formulas: [:])
        #expect(chart.categories == ["Umsatz", "Kosten"])
        #expect(chart.series.map(\.name) == ["Januar", "Februar", "März", "Summe"])
    }

    @Test func mermaidStyleLivesInTheFrontMatter() {
        let code = WriterMermaid.template(.flowchart)
        var style = WriterMermaid.style(of: code)
        #expect(style.theme == nil)
        style.theme = .forest
        style.handDrawn = true
        style.curve = .linear
        let styled = WriterMermaid.applying(style, to: code)
        #expect(styled.hasPrefix("---\nconfig:\n  theme: forest\n  look: handDrawn\n  flowchart:\n    curve: linear\n---\nflowchart TD"))
        #expect(WriterMermaid.style(of: styled) == style)
        #expect(WriterMermaid.type(of: styled) == .flowchart)
        #expect(WriterMermaid.applying(WriterMermaid.Style(), to: styled) == code.trimmingCharacters(in: .newlines))
        #expect(WriterMermaid.setting(direction: "LR", in: code).hasPrefix("flowchart LR"))
        #expect(WriterMermaid.code(inAnswer: "Hier ist es:\n```mermaid\nflowchart LR\n  A --> B\n```\nViel Spaß") == "flowchart LR\n  A --> B")
    }

    @Test func drawingsHitTheirShapes() {
        let line = WriterDrawing.Shape(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], stroke: "1C1C1F", width: 2)
        #expect(line.hit(CGPoint(x: 50, y: 3), tolerance: 3))
        #expect(!line.hit(CGPoint(x: 50, y: 20), tolerance: 3))
        let box = WriterDrawing.Shape(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], stroke: "1C1C1F", width: 2)
        #expect(box.hit(CGPoint(x: 10, y: 25), tolerance: 3))
        #expect(!box.hit(CGPoint(x: 35, y: 25), tolerance: 3))
        var drawing = WriterDrawing()
        drawing.shapes = [line, box]
        #expect(WriterDrawing.decode(drawing.json) == drawing)
        #expect(drawing.images() != nil)
    }
}

@Suite("Zeichenfläche")
struct DrawingCanvasTests {
    @MainActor private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor @Test func strokesShapesUndoAndEraser() {
        let model = DrawingEditorModel(request: WriterFigureRequest(kind: .drawing))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = DrawingCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        canvas.model = model
        window.contentView = canvas
        // A pen stroke.
        model.tool = .pen
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 100, y: 400), in: window))
        for x in stride(from: 110, through: 300, by: 10) {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: CGFloat(x), y: 380), in: window))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 300, y: 380), in: window))
        #expect(model.drawing.shapes.count == 1)
        #expect(model.drawing.shapes.first?.points.count ?? 0 > 10)
        // A rectangle, drawn from corner to corner.
        model.tool = .rectangle
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 400, y: 400), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 600, y: 250), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 600, y: 250), in: window))
        #expect(model.drawing.shapes.count == 2)
        #expect(model.drawing.shapes.last?.kind == .rectangle)
        // Undo and redo.
        model.undo()
        #expect(model.drawing.shapes.count == 1)
        model.redo()
        #expect(model.drawing.shapes.count == 2)
        // Select and move the rectangle.
        model.tool = .select
        let before = model.drawing.shapes[1].bounds
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 400, y: 330), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 420, y: 310), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 420, y: 310), in: window))
        #expect(model.selection.count == 1)
        #expect(model.drawing.shapes[1].bounds.minX > before.minX)
        // The eraser takes the stroke away.
        model.tool = .eraser
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 200, y: 380), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 200, y: 380), in: window))
        #expect(model.drawing.shapes.count == 1)
        #expect(model.drawing.shapes.first?.kind == .rectangle)
    }
}
