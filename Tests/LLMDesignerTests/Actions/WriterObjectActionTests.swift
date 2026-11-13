import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Writer-Kästen, Bilder, Formeln, Code", .serialized)
struct WriterObjectActionTests {
    let h = ActionHarness()

    init() {
        // Bundled with the app only; a test finds mermaid.js in the repository.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_MERMAID_JS", root.appendingPathComponent("Resources/Mermaid/mermaid.min.js").path, 1)
    }

    private func editorForm(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown)).trimmingCharacters(in: .newlines)
    }

    /// A neutral picture made for the test.
    private func pictureFile() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func reference(_ id: String, line: Int = 0) throws -> WriterImageReference {
        let lines = h.text(id).components(separatedBy: "\n")
        let images = lines.compactMap { WriterImageReference.parse($0) }
        return try #require(images.indices.contains(line) ? images[line] : nil)
    }

    // MARK: Boxes

    @Test func boxInsertStyleRemove() async throws {
        let id = try await h.document("Davor\n\nDanach")
        let made = try await h.call("writer.box.insert", ["doc": .string(id), "match": "Davor", "kind": "merksatz", "title": "Merke", "markdown": "Wasser ist nass.\n\n- Punkt"])
        #expect(made["block"]?.stringValue?.hasPrefix("b1-") == true)
        #expect(h.trimmed(id) == "Davor\n\n::: {.box kind=merksatz title=\"Merke\"}\nWasser ist nass.\n\n- Punkt\n:::\n\nDanach")
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))

        try await h.call("writer.box.style", ["doc": .string(id), "position": "right", "width": 40, "wrap": true, "frame": "outline", "color": "Blau"])
        #expect(h.text(id).contains("::: {.box kind=merksatz title=\"Merke\" position=right width=40 wrap=true color=1F5FBF frame=outline}"))
        try await h.call("writer.box.style", ["doc": .string(id), "kind": "achtung", "color": "none"])
        #expect(h.text(id).contains("kind=achtung position=right"))

        try await h.call("writer.box.remove", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Davor\n\nWasser ist nass.\n\n- Punkt\n\nDanach")
        #expect(await h.errorCode("writer.box.remove", ["doc": .string(id)]) == RPCError.notFoundCode)
    }

    @Test func boxAroundBlocksAndDropWithText() async throws {
        let id = try await h.document("Eins\n\nZwei\n\nDrei")
        let blocks = try #require(try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue)
        try await h.call("writer.box.insert", ["doc": .string(id), "kind": "hinweis", "around": true, "block": .string(try #require(blocks[0]["id"]?.stringValue)), "count": 2])
        #expect(h.trimmed(id) == "::: {.box kind=hinweis}\nEins\n\nZwei\n:::\n\nDrei")
        try await h.call("writer.box.remove", ["doc": .string(id), "box": "1", "keepText": false])
        #expect(h.trimmed(id) == "Drei")
    }

    @Test func aBoxHoldsNoCodeAndIsNotEmpty() async throws {
        let id = try await h.document("Text")
        #expect(await h.errorCode("writer.box.insert", ["doc": .string(id), "kind": "beispiel", "markdown": "```\nx\n```"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("writer.box.insert", ["doc": .string(id), "kind": "beispiel"]) == RPCError.invalidParamsCode)
        #expect(h.trimmed(id) == "Text")
    }

    @Test func aBoxInColumnsIsFound() async throws {
        let id = try await h.document("::: {.columns count=2}\n::: {.box kind=hinweis}\nInnen\n:::\n\nDaneben\n:::")
        try await h.call("writer.box.style", ["doc": .string(id), "frame": "filled"])
        #expect(h.text(id).contains("::: {.box kind=hinweis frame=filled}"))
        try await h.call("writer.columns.remove", ["doc": .string(id)])
        #expect(h.trimmed(id).hasPrefix("::: {.box"))
    }

    // MARK: Columns

    @Test func columnsSetBreakRemove() async throws {
        let id = try await h.document("# Eins\n\nA\n\nB\n\n# Zwei\n\nC")
        try await h.call("writer.columns.set", ["doc": .string(id), "heading": "Eins", "columns": 2, "rule": true])
        #expect(h.trimmed(id).hasPrefix("::: {.columns count=2 rule=true}\n# Eins"))
        #expect(h.trimmed(id).hasSuffix(":::\n\n# Zwei\n\nC"))

        try await h.call("writer.columns.break", ["doc": .string(id), "after": 2])
        #expect(h.text(id).contains("A\n\n\\columnbreak\n\nB"))
        #expect(await h.errorCode("writer.columns.break", ["doc": .string(id), "after": 9]) == RPCError.notFoundCode)

        // An address on the section changes it.
        let blocks = try #require(try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue)
        try await h.call("writer.columns.set", ["doc": .string(id), "block": .string(try #require(blocks[0]["id"]?.stringValue)), "columns": 3])
        #expect(h.text(id).contains("count=3"))
        try await h.call("writer.columns.set", ["doc": .string(id), "section": "1", "rule": false])
        #expect(!h.text(id).contains("rule=true"))

        try await h.call("writer.columns.remove", ["doc": .string(id), "section": "1"])
        #expect(h.trimmed(id) == "# Eins\n\nA\n\nB\n\n# Zwei\n\nC")
    }

    // MARK: Pictures

    @Test func imageInsertAndChange() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await h.document("Text")
        let made = try await h.call("writer.image.insert", ["doc": .string(id), "file": .string(file.path), "width": 50, "caption": "Ein Bild"])
        let source = try #require(made["source"]?.stringValue)
        #expect(WriterImageStore.url(for: source) != nil)
        #expect(try reference(id).width == 50)

        try await h.call("writer.image.setWidth", ["doc": .string(id), "width": 75])
        #expect(try reference(id).width == 75)
        try await h.call("writer.image.setWidth", ["doc": .string(id), "width": 0])
        #expect(try reference(id).width == nil)
        try await h.call("writer.image.caption", ["doc": .string(id), "caption": "Anders"])
        #expect(try reference(id).caption == "Anders")

        try await h.call("writer.image.delete", ["doc": .string(id)])
        #expect(h.trimmed(id) == "Text")
        #expect(await h.errorCode("writer.image.delete", ["doc": .string(id)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.image.insert", ["doc": .string(id), "file": "/gibt/es/nicht.png"]) == RPCError.notFoundCode)
    }

    @Test func aModelNamingAPictureFileNeedsConsent() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await h.document("Text")
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("writer.image.insert", ["doc": .string(id), "file": .string(file.path)], channel: .chat) == RPCError.deniedCode)
        #expect(h.trimmed(id) == "Text")
    }

    @Test func picturesAreFoundInsideBoxesNotInCode() async throws {
        let id = try await h.document("```\n![Nein](Bilder/code.png)\n```\n\n::: {.box kind=hinweis}\n![Ja](Bilder/box.png)\n:::")
        try await h.call("writer.image.caption", ["doc": .string(id), "caption": "Geändert"])
        #expect(h.text(id).contains("![Nein](Bilder/code.png)"))
        #expect(h.text(id).contains("![Geändert](Bilder/box.png)"))
    }

    @Test func generatedPictures() async throws {
        // A port where nothing listens, so a running Draw Things isn't bothered.
        let address = h.app.imageGeneration.address
        h.app.imageGeneration.address = "http://127.0.0.1:9"
        defer { h.app.imageGeneration.address = address }
        let id = try await h.document("Text")
        let made = try await h.call("writer.image.generate", ["doc": .string(id), "prompt": "a lighthouse", "format": .string(ImageFormat.allCases[0].rawValue), "caption": "Leuchtturm"])
        let source = try #require(made["source"]?.stringValue)
        #expect(try reference(id).generated)
        #expect(WriterImageStore.generationInfo(for: source)?.prompt == "a lighthouse")
        #expect(h.app.imageGeneration.phase(for: source) != nil)

        let read = try await h.call("writer.figure.read", ["doc": .string(id)])
        #expect(read["kind"] == "generated")
        #expect(read["prompt"] == "a lighthouse")

        let again = try await h.call("writer.image.regenerate", ["doc": .string(id), "prompt": "a harbour"])
        let second = try #require(again["source"]?.stringValue)
        #expect(second != source)
        #expect(h.app.imageGeneration.phase(for: source) == nil)
        #expect(try reference(id).source == second)
        #expect(WriterImageStore.generationInfo(for: second)?.prompt == "a harbour")

        try await h.call("writer.image.cancel", ["doc": .string(id)])
        #expect(h.app.imageGeneration.phase(for: second) == nil)
        #expect(await h.errorCode("writer.image.generate", ["doc": .string(id), "prompt": "  "]) == RPCError.invalidParamsCode)

        let plain = try await h.document("![Foto](Bilder/foto.png)")
        #expect(await h.errorCode("writer.image.regenerate", ["doc": .string(plain)]) == RPCError.notFoundCode)
    }

    @Test func imageGoesToASlide() async throws {
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await h.document("Text")
        try await h.call("writer.image.insert", ["doc": .string(id), "file": .string(file.path), "caption": "Für die Folie"])
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Bilder \(UUID().uuidString)")])["id"]?.stringValue)
        let result = try await h.call("writer.image.toSlide", ["doc": .string(id), "deck": .string(deck), "slideIndex": 1])
        let slide = try #require(h.app.document(UUID(uuidString: deck)!)?.deck?.slides.first)
        #expect(slide.images.first?.id.uuidString == result["id"]?.stringValue)
        #expect(slide.images.first?.caption == "Für die Folie")
    }

    // MARK: Charts

    @Test func chartInsertReadEdit() async throws {
        let id = try await h.document("Text")
        try await h.call("writer.chart.insert", [
            "doc": .string(id), "kind": "line", "title": "Verlauf", "categories": ["A", "B"], "series": [["name": "X", "values": [1, nil]]], "caption": "Bild 1", "palette": "ocean",
        ])
        let first = try reference(id)
        #expect(first.figure == .chart)
        #expect(first.width == 80)
        var chart = try #require(WriterChart.decode(WriterImageStore.recipe(for: first)))
        #expect(chart.kind == .line)
        #expect(chart.palette == .ocean)
        #expect(chart.series[0].values == [1, nil])

        let read = try await h.call("writer.figure.read", ["doc": .string(id)])
        #expect(read["kind"] == "chart")
        #expect(read["chart"]?["title"] == "Verlauf")

        try await h.call("writer.chart.edit", ["doc": .string(id), "kind": "bar", "unit": "€", "caption": "Bild 2"])
        let second = try reference(id)
        #expect(second.source != first.source)
        #expect(second.caption == "Bild 2")
        chart = try #require(WriterChart.decode(WriterImageStore.recipe(for: second)))
        #expect(chart.kind == .bar)
        #expect(chart.unit == "€")
        #expect(chart.series[0].name == "X")

        // Undo brings the old files back.
        try await h.call("writer.edit.undo")
        #expect(try reference(id).source == first.source)
        #expect(await h.errorCode("writer.chart.insert", ["doc": .string(id), "categories": ["A"], "series": []]) == RPCError.invalidParamsCode)
    }

    // MARK: Mermaid

    @Test func mermaidFromCodeTemplateAndEdit() async throws {
        let id = try await h.document("Text")
        try await h.call("writer.mermaid.insert", ["doc": .string(id), "code": "flowchart TD\n  A-->B", "caption": "Ablauf"])
        let first = try reference(id)
        #expect(first.figure == .mermaid)
        #expect(WriterImageStore.url(for: first.source) != nil)
        #expect((try await h.call("writer.figure.read", ["doc": .string(id)]))["code"] == "flowchart TD\n  A-->B")

        try await h.call("writer.mermaid.edit", ["doc": .string(id), "code": "flowchart LR\n  A-->C", "width": 40])
        let second = try reference(id)
        #expect(second.source != first.source)
        #expect(second.width == 40)
        #expect(String(data: try #require(WriterImageStore.recipe(for: second)), encoding: .utf8) == "flowchart LR\n  A-->C")

        #expect(await h.errorCode("writer.mermaid.edit", ["doc": .string(id), "code": "das ist kein diagramm %%%"]) == RPCError.invalidParamsCode)
        #expect(try reference(id).source == second.source)

        let template = try await h.document("")
        try await h.call("writer.mermaid.insert", ["doc": .string(template), "type": "pie"])
        let recipe = try #require(WriterImageStore.recipe(for: try reference(template)))
        #expect(String(data: recipe, encoding: .utf8)?.hasPrefix("pie") == true)
        #expect(await h.errorCode("writer.mermaid.insert", ["doc": .string(template)]) == RPCError.invalidParamsCode)
    }

    @Test func theModelWritesAMermaidDiagram() async throws {
        let server = try FakeLLMServer()
        server.completions = ["```mermaid\nflowchart TD\n  X-->Y\n```"]
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        let id = try await h.document("Ein Text über den Ablauf.")
        try await h.call("writer.mermaid.insert", ["doc": .string(id), "instruction": "Zeig den Ablauf"])
        let recipe = try #require(WriterImageStore.recipe(for: try reference(id)))
        #expect(String(data: recipe, encoding: .utf8) == "flowchart TD\n  X-->Y")
        #expect(h.trimmed(id).hasPrefix("Ein Text über den Ablauf."))
    }

    // MARK: Drawings

    @Test func drawingInsertEdit() async throws {
        let id = try await h.document("Text")
        try await h.call("writer.drawing.insert", [
            "doc": .string(id), "background": "grid", "canvasWidth": 400, "canvasHeight": 300,
            "elements": [
                ["kind": "rectangle", "points": [[10, 10], [100, 80]], "fill": "Blau"],
                ["kind": "text", "points": [[20, 100]], "text": "Hallo"],
            ],
        ])
        let first = try reference(id)
        #expect(first.figure == .drawing)
        var drawing = try #require(WriterDrawing.decode(WriterImageStore.recipe(for: first)))
        #expect(drawing.size == CGSize(width: 400, height: 300))
        #expect(drawing.background == .grid)
        #expect(drawing.shapes.map(\.kind) == [.rectangle, .text])
        #expect(drawing.shapes[0].fill == "1F5FBF")

        try await h.call("writer.drawing.edit", ["doc": .string(id), "append": true, "elements": [["kind": "arrow", "points": [[0, 0], [50, 50]]]]])
        drawing = try #require(WriterDrawing.decode(WriterImageStore.recipe(for: try reference(id))))
        #expect(drawing.shapes.count == 3)
        try await h.call("writer.drawing.edit", ["doc": .string(id), "elements": [["kind": "ellipse", "points": [[0, 0], [50, 50]]]]])
        drawing = try #require(WriterDrawing.decode(WriterImageStore.recipe(for: try reference(id))))
        #expect(drawing.shapes.map(\.kind) == [.ellipse])
        #expect((try await h.call("writer.figure.read", ["doc": .string(id)]))["kind"] == "drawing")

        #expect(await h.errorCode("writer.drawing.insert", ["doc": .string(id), "elements": [["kind": "line", "points": [[0, 0]]]]]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.drawing.insert", ["doc": .string(id), "elements": [["kind": "wolke", "points": [[0, 0], [1, 1]]]]]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.drawing.insert", ["doc": .string(id), "elements": [["kind": "text", "points": [[0, 0]]]]]) == RPCError.invalidParamsCode)
    }

    // MARK: Formulas

    @Test func formulasInBlockAndText() async throws {
        let id = try await h.document("Die Energie ist groß.")
        try await h.call("writer.formula.insert", ["doc": .string(id), "latex": "E = mc^2"])
        #expect(h.trimmed(id).hasSuffix("$$\nE = mc^2\n$$"))
        try await h.call("writer.formula.insert", ["doc": .string(id), "latex": "x^2", "display": "inline", "match": "Energie"])
        #expect(h.text(id).contains("Die Energie$x^2$ ist groß."))
        #expect(await h.errorCode("writer.formula.insert", ["doc": .string(id), "latex": "x", "display": "inline"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.formula.insert", ["doc": .string(id), "latex": "  "]) == RPCError.invalidParamsCode)

        let list = try await h.call("writer.formula.list", ["doc": .string(id)])
        #expect(list["formulas"]?.arrayValue?.map { $0["display"]?.stringValue } == ["inline", "block"])
        #expect(list["formulas"]?.arrayValue?[0]["latex"] == "x^2")

        #expect(await h.errorCode("writer.formula.edit", ["doc": .string(id), "latex": "y"]) == RPCError.ambiguousCode)
        try await h.call("writer.formula.edit", ["doc": .string(id), "formula": "1", "latex": "y^3"])
        #expect(h.text(id).contains("$y^3$"))
        try await h.call("writer.formula.edit", ["doc": .string(id), "formula": "2", "latex": "F = ma"])
        #expect(h.text(id).contains("$$\nF = ma\n$$"))

        try await h.call("writer.formula.edit", ["doc": .string(id), "formula": "1", "latex": ""])
        #expect(h.trimmed(id).hasPrefix("Die Energie ist groß."))
        try await h.call("writer.formula.edit", ["doc": .string(id), "latex": ""])
        #expect(h.trimmed(id) == "Die Energie ist groß.")
    }

    @Test func plotsAreDrawnWhenPythonIsThere() async throws {
        let id = try await h.document("")
        let arguments: JSONValue = ["doc": .string(id), "expression": "f(x) = x^2", "x": "-3:3", "caption": "Parabel"]
        guard await PlotRenderer.shared.pythonExecutable() != nil else {
            #expect(await h.errorCode("writer.plot.insert", arguments) == RPCError.unavailableCode)
            return
        }
        do {
            try await h.call("writer.plot.insert", arguments)
        } catch let error as RPCError where error.code == RPCError.unavailableCode || error.code == RPCError.invalidTargetCode {
            // Python without numpy or matplotlib can't draw; the action says so and leaves the text alone.
            #expect(h.trimmed(id).isEmpty)
            return
        }
        #expect(h.text(id).contains("$$\nf(x) = x^2\n$$"))
        let first = try reference(id)
        #expect(first.plot?.x == PlotRange(-3, 3))
        #expect(first.caption == "Parabel")

        // Only the caption: no new picture.
        try await h.call("writer.plot.edit", ["doc": .string(id), "caption": "Normalparabel", "width": 50])
        #expect(try reference(id).source == first.source)
        #expect(try reference(id).width == 50)
        // Another range: drawn anew.
        try await h.call("writer.plot.edit", ["doc": .string(id), "x": "-1:1"])
        #expect(try reference(id).source != first.source)
        #expect(try reference(id).plot?.x == PlotRange(-1, 1))
        #expect(await h.errorCode("writer.plot.edit", ["doc": .string(id), "x": "weit"]) == RPCError.invalidParamsCode)

        // A plot for a formula there is goes below it, and replaces the old one.
        try await h.call("writer.plot.insert", ["doc": .string(id), "x": "0:2"])
        #expect(h.text(id).components(separatedBy: "\n").compactMap { WriterImageReference.parse($0) }.count == 1)
        #expect(try reference(id).plot?.x == PlotRange(0, 2))

        // An emptied formula takes its plot along.
        try await h.call("writer.formula.edit", ["doc": .string(id), "latex": ""])
        #expect(h.trimmed(id).isEmpty)
    }

    @Test func plotOfTextThatIsNoFormula() async throws {
        let id = try await h.document("Text ohne Formel.")
        #expect(await h.errorCode("writer.plot.insert", ["doc": .string(id)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.plot.edit", ["doc": .string(id)]) == RPCError.notFoundCode)
    }

    // MARK: Code

    @Test func codeInsertLanguageFormat() async throws {
        let id = try await h.document("Text")
        let made = try await h.call("writer.code.insert", ["doc": .string(id), "language": "sql", "code": "select a,b from t where a=1"])
        #expect(made["block"]?.stringValue?.hasPrefix("b1-") == true)
        #expect(h.trimmed(id).hasSuffix("```sql\nselect a,b from t where a=1\n```"))

        try await h.call("writer.code.format", ["doc": .string(id)])
        #expect(h.text(id).contains("SELECT"))

        try await h.call("writer.code.setLanguage", ["doc": .string(id), "language": "none"])
        #expect(h.text(id).contains("```\nSELECT"))
        try await h.call("writer.code.setLanguage", ["doc": .string(id), "codeBlock": "1", "language": "rust"])
        #expect(h.text(id).contains("```rust\n"))
        #expect(await h.errorCode("writer.code.format", ["doc": .string(id)]) == RPCError.invalidTargetCode)
        // Code that shows a fence gets a longer one instead of being refused.
        try await h.call("writer.code.insert", ["doc": .string(id), "code": "a\n```\nb"])
        #expect(h.text(id).contains("````\na\n```\nb\n````"))
    }

    @Test func flowchartGoesBelowTheCode() async throws {
        let id = try await h.document("Davor\n\n```python\ndef f(x):\n    if x:\n        return 1\n    return 2\n```\n\nDanach")
        try await h.call("writer.code.flowchart", ["doc": .string(id)])
        let found = try reference(id)
        #expect(found.isDiagram)
        #expect(WriterImageStore.url(for: found.source) != nil)
        let chunks = PowerText.chunks(of: h.text(id))
        #expect(chunks[1].kind == .code)
        #expect(chunks[2].kind == .image)
        #expect(chunks[3].markdown == "Danach")

        let plain = try await h.document("```rust\nfn main() {}\n```")
        #expect(await h.errorCode("writer.code.flowchart", ["doc": .string(plain)]) == RPCError.invalidTargetCode)
    }
}
}
