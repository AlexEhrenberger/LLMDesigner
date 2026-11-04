import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterFigureActions() {
        register(WriterImageInsertAction.self)
        register(WriterImageSetWidthAction.self)
        register(WriterImageCaptionAction.self)
        register(WriterImageDeleteAction.self)
        register(WriterImageGenerateAction.self)
        register(WriterImageRegenerateAction.self)
        register(WriterImageCancelAction.self)
        register(WriterImageToSlideAction.self)
        register(WriterChartInsertAction.self)
        register(WriterChartEditAction.self)
        register(WriterMermaidInsertAction.self)
        register(WriterMermaidEditAction.self)
        register(WriterDrawingInsertAction.self)
        register(WriterDrawingEditAction.self)
        register(WriterFigureReadAction.self)
    }
}

/// A chart's series as an agent writes it.
struct WriterChartSeriesArg: Decodable, Sendable {
    var name: String
    var values: [Double?]
    var color: String?
}

/// A shape of a drawing as an agent writes it. Points are `[x, y]` in the canvas's own coordinates, top left 0, 0.
struct WriterDrawingElementArg: Decodable, Sendable {
    var kind: String
    var points: [[Double]]
    var stroke: String?
    var fill: String?
    var width: Double?
    var dashed: Bool?
    var text: String?
    var fontSize: Double?
}

struct WriterFigureArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var position: String?
    var image: String?
    var file: String?
    var width: Int?
    var caption: String?
    var prompt: String?
    var description: String?
    var style: String?
    var format: String?
    var deck: String?
    var slide: String?
    var slideIndex: Int?
    var kind: String?
    var title: String?
    var categories: [String]?
    var series: [WriterChartSeriesArg]?
    var legend: String?
    var aspect: String?
    var palette: String?
    var xTitle: String?
    var yTitle: String?
    var unit: String?
    var showValues: Bool?
    var type: String?
    var code: String?
    var instruction: String?
    var elements: [WriterDrawingElementArg]?
    var append: Bool?
    var canvasWidth: Double?
    var canvasHeight: Double?
    var background: String?

    init(from decoder: Decoder) throws {
        // On a Writer target `deck` and `slide` name the text. `writer.image.toSlide` means the target deck by them, so
        // its document stays in `doc`, and the two don't get in each other's way.
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        deck = try c.decodeIfPresent(String.self, forKey: .deck)
        slide = try c.decodeIfPresent(String.self, forKey: .slide)
        slideIndex = try c.decodeIfPresent(Int.self, forKey: .slideIndex)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        categories = try c.decodeIfPresent([String].self, forKey: .categories)
        series = try c.decodeIfPresent([WriterChartSeriesArg].self, forKey: .series)
        legend = try c.decodeIfPresent(String.self, forKey: .legend)
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect)
        palette = try c.decodeIfPresent(String.self, forKey: .palette)
        xTitle = try c.decodeIfPresent(String.self, forKey: .xTitle)
        yTitle = try c.decodeIfPresent(String.self, forKey: .yTitle)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        showValues = try c.decodeIfPresent(Bool.self, forKey: .showValues)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        elements = try c.decodeIfPresent([WriterDrawingElementArg].self, forKey: .elements)
        append = try c.decodeIfPresent(Bool.self, forKey: .append)
        canvasWidth = try c.decodeIfPresent(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decodeIfPresent(Double.self, forKey: .canvasHeight)
        background = try c.decodeIfPresent(String.self, forKey: .background)
    }

    enum Keys: String, CodingKey {
        case position, image, file, width, caption, prompt, description, style, format, deck, slide, slideIndex, kind, title, categories, series,
             legend, aspect, palette, xTitle, yTitle, unit, showValues, type, code, instruction, elements, append, canvasWidth, canvasHeight, background
    }

    static let imageReference: [String: JSONSchema] = ["image": .string("Bild: Nummer im Text ab 1 oder Block-ID; ohne Angabe das einzige")]
    static let placed: [String: JSONSchema] = WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }
    static let referenced: [String: JSONSchema] = WriterTargetArgs.schemaProperties.merging(imageReference) { _, new in new }
    static let look: [String: JSONSchema] = [
        "caption": .string("Bildunterschrift"),
        "width": .integer("Breite in Prozent der Spalte", minimum: 5, maximum: 100),
    ]
}

/// The pictures of a text, by the line they stand on.
@MainActor
enum WriterImageAddressing {
    static func find(_ reference: String?, in markdown: String, label: String = "Bild", matching: (WriterImageReference) -> Bool = { _ in true }) throws -> (lines: [String], line: Int, reference: WriterImageReference) {
        let lines = markdown.components(separatedBy: "\n")
        let images = WriterLines.images(in: lines).filter { matching($0.reference) }
        let hit = try WriterReference.pick(reference, from: images, label: label, markdown: markdown) { image, chunk in
            lines[image.line].trimmingCharacters(in: .whitespaces) == chunk
        }
        return (lines, hit.line, hit.reference)
    }

    /// The same text with the picture on this line changed.
    static func replacing(_ found: (lines: [String], line: Int, reference: WriterImageReference), with reference: WriterImageReference) -> String {
        var lines = found.lines
        lines[found.line] = reference.markdown
        return lines.joined(separator: "\n")
    }

    /// The paragraphs around a place, for the model (as `WriterTextView.surroundingText` does for the editor).
    static func context(at index: Int, in markdown: String) -> String {
        let chunks = PowerText.chunks(of: markdown)
        let before = chunks.prefix(index).map(\.plain).joined(separator: "\n\n")
        let after = chunks.dropFirst(index).map(\.plain).joined(separator: "\n\n")
        return String(before.suffix(1400)) + (after.isEmpty ? "" : "\n[Hier steht das Bild]\n" + String(after.prefix(500)))
    }
}

struct WriterImageInsertAction: LLMDAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.insert", summary: "Fügt ein Bild aus einer Datei ein", kind: .write, security: .localWrite,
        input: .object(Args.placed.merging(Args.look) { _, new in new }.merging(["file": .string("Pfad der Bilddatei")]) { _, new in new }, required: ["file"]),
        output: .freeObject(), example: "llmd writer image insert --doc X --file ~/Bilder/foto.png --width 50"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        var check = ActionPreflight(target: args.file)
        // A model or a client names a path: rendered afterwards, that would show it any picture on this Mac.
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Bild von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer sichtbar."
        }
        return check
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        let source = try WriterImageStore.importImage(.file(url))
        let reference = WriterImageReference(source: source, caption: args.caption ?? "", width: args.width)
        var result = try target.insertBlocks(reference.markdown, at: args.address, position: args.position, ifVersion: args.target.ifVersion, context: context)
        result.source = source
        return result
    }
}

struct WriterImageSetWidthAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.setWidth", summary: "Setzt die Breite eines Bildes; 0 ist seine eigene Größe", kind: .write, security: .localWrite,
        input: .object(Args.referenced.merging(["width": .integer("Prozent der Spalte", minimum: 0, maximum: 100)]) { _, new in new }, required: ["width"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let found = try WriterImageAddressing.find(args.image, in: markdown)
        var reference = found.reference
        reference.width = args.width == 0 ? nil : args.width
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}

struct WriterImageCaptionAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.caption", summary: "Setzt die Bildunterschrift", kind: .write, security: .localWrite,
        input: .object(Args.referenced.merging(["caption": .string("Der Text; leer nimmt sie weg")]) { _, new in new }, required: ["caption"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let found = try WriterImageAddressing.find(args.image, in: markdown)
        var reference = found.reference
        reference.caption = args.caption ?? ""
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}

struct WriterImageDeleteAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.delete", summary: "Nimmt ein Bild aus dem Text; die Datei bleibt für Rückgängig", kind: .write, security: .localWrite,
        input: .object(Args.referenced), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var found = try WriterImageAddressing.find(args.image, in: markdown)
        found.lines.remove(at: found.line)
        return (WriterLines.normalized(found.lines), nil)
    }
}

struct WriterImageGenerateAction: LLMDAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.generate", summary: "Lässt Draw Things ein Bild machen; bis es fertig ist, steht dort ein Platzhalter", kind: .write, security: .localWrite,
        input: .object(Args.placed.merging([
            "prompt": .string("Englischer Prompt für das Bildmodell"),
            "description": .string("Was das Bild zeigen soll, in eigenen Worten"),
            "caption": .string("Bildunterschrift"),
            "width": .integer("Breite in Prozent der Spalte; Standard 75", minimum: 5, maximum: 100),
            "style": .choice(ImageStyle.allCases.map(\.rawValue), "Stil"),
            "format": .choice(ImageFormat.allCases.map(\.rawValue), "Format"),
        ]) { _, new in new }, required: ["prompt"]),
        output: .freeObject(), example: "llmd writer image generate --doc X --prompt 'a lighthouse at dawn'"
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let prompt = (args.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        var info = context.app.imageGeneration.defaults
        info.prompt = prompt
        info.description = args.description ?? ""
        if let style = args.style.flatMap(ImageStyle.init(rawValue:)) { info.style = style }
        if let format = args.format.flatMap(ImageFormat.init(rawValue:)) { info.format = format }
        info.seed = nil
        let source = WriterImageStore.newGeneratedSource()
        WriterImageStore.saveGenerationInfo(info, for: source)
        let reference = WriterImageReference(source: source, caption: args.caption ?? "", width: args.width ?? 75, generated: true)
        var result = try target.insertBlocks(reference.markdown, at: args.address, position: args.position, ifVersion: args.target.ifVersion, context: context)
        context.app.imageGeneration.generate(source: source, info: info)
        result.source = source
        return result
    }
}

struct WriterImageRegenerateAction: LLMDAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.image.regenerate", summary: "Macht ein generiertes Bild neu, mit neuem Seed oder neuem Prompt", kind: .write, security: .localWrite,
        input: .object(Args.referenced.merging(["prompt": .string("Neuer Prompt; ohne Angabe der alte")]) { _, new in new }),
        output: .freeObject()
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let center = context.app.imageGeneration
        let found = try WriterImageAddressing.find(args.image, in: target.markdown, label: "Generiertes Bild") { $0.generated }
        var info = WriterImageStore.generationInfo(for: found.reference.source) ?? center.defaults
        if let prompt = args.prompt { info.prompt = prompt }
        guard !info.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        info.seed = nil
        // A new file; the old picture shows (dimmed) until the new one is there, and undo brings it back.
        center.cancel(found.reference.source)
        info.previous = found.reference.isPlaceholder ? info.previous : found.reference.source
        let source = WriterImageStore.newGeneratedSource()
        WriterImageStore.saveGenerationInfo(info, for: source)
        var reference = found.reference
        reference.source = source
        var result = try target.replaceText(with: WriterImageAddressing.replacing(found, with: reference), ifVersion: args.target.ifVersion, context: context)
        center.generate(source: source, info: info)
        result.source = source
        return result
    }
}

struct WriterImageCancelAction: LLMDAction {
    typealias Args = WriterFigureArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.image.cancel", summary: "Bricht das Generieren eines Bildes ab; der Platzhalter bleibt", kind: .write, security: .localWrite,
        input: .object(Args.referenced), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).writePreflight
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let found = try WriterImageAddressing.find(args.image, in: target.markdown, label: "Generiertes Bild") { $0.generated }
        context.app.imageGeneration.cancel(found.reference.source)
        return OKOutput(id: found.reference.source)
    }
}

struct WriterImageToSlideAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var image: String?
        var deck: String
        var slide: String?
        var slideIndex: Int?
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.image.toSlide", summary: "Legt ein Bild eines Dokuments als freies Element auf eine Folie", kind: .write, security: .localWrite,
        input: .object([
            "doc": .string("Dokument (ID oder Titel)"),
            "image": WriterFigureArgs.imageReference["image"]!,
            "deck": .string("Präsentation (ID oder Titel)"),
            "slide": .string("Folie (ID)"),
            "slideIndex": .integer("Folie nach Position, ab 1", minimum: 1),
        ], required: ["doc", "deck"]),
        output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.doc)
        let reference = try WriterImageAddressing.find(args.image, in: document.markdown).reference
        let size = WriterImageStore.url(for: reference.source).flatMap(WriterImageStore.naturalSize(of:))
        let aspect = size.map { Double($0.width / max(1, $0.height)) } ?? 1.5
        var made: UUID?
        _ = try changeDeck(args.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
            let image = SlideImage(source: reference.source, caption: reference.caption, frame: SlideImage.defaultFrame(aspect: aspect), generated: reference.generated)
            made = image.id
            deck.slides[deck.index(of: slide.id)!].images.append(image)
        }
        return OKOutput(id: made?.uuidString)
    }
}

// MARK: Charts

extension WriterFigureArgs {
    /// The chart with what this call says.
    @MainActor
    func apply(to chart: inout WriterChart) throws {
        if let value = kind.flatMap(WriterChart.Kind.init(rawValue:)) { chart.kind = value }
        if let title { chart.title = title }
        if let categories { chart.categories = categories }
        if let series {
            chart.series = try series.map { WriterChart.Series(name: $0.name, values: $0.values, color: try $0.color.map(actionColor)) }
            // Numbers given by hand: the chart no longer follows a table.
            chart.table = nil
        }
        if let value = legend.flatMap(WriterChart.Legend.init(rawValue:)) { chart.legend = value }
        if let value = aspect.flatMap(WriterChart.Aspect.init(rawValue:)) { chart.aspect = value }
        if let value = palette.flatMap(WriterChartPalette.init(rawValue:)) { chart.palette = value }
        if let xTitle { chart.xTitle = xTitle }
        if let yTitle { chart.yTitle = yTitle }
        if let unit { chart.unit = unit }
        if let showValues { chart.showsValues = showValues }
    }

    static let chartProperties: [String: JSONSchema] = [
        "kind": .choice(WriterChart.Kind.allCases.map(\.rawValue), "Diagrammart"),
        "title": .string("Titel im Diagramm"),
        "categories": .array(of: .string(), "Kategorien, z. B. Q1, Q2"),
        "series": .array(of: .object(["name": .string("Name"), "values": .array(of: .any("Zahl oder null")), "color": .string("Eigene Farbe")], required: ["name", "values"]), "Reihen mit einem Wert je Kategorie"),
        "legend": .choice(WriterChart.Legend.allCases.map(\.rawValue), "Legende"),
        "aspect": .choice(WriterChart.Aspect.allCases.map(\.rawValue), "Seitenverhältnis"),
        "palette": .choice(WriterChartPalette.allCases.map(\.rawValue), "Farben"),
        "xTitle": .string("Beschriftung der x-Achse"),
        "yTitle": .string("Beschriftung der y-Achse"),
        "unit": .string("Einheit hinter den Werten, z. B. €"),
        "showValues": .boolean("Werte im Diagramm zeigen"),
    ]
}

struct WriterChartInsertAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.chart.insert", summary: "Fügt ein Diagramm aus Zahlen ein", kind: .write, security: .localWrite,
        input: .object(Args.placed.merging(Args.look) { _, new in new }.merging(Args.chartProperties) { _, new in new }, required: ["categories", "series"]),
        output: .freeObject(), example: "llmd call writer.chart.insert --json '{\"doc\":\"X\",\"categories\":[\"A\",\"B\"],\"series\":[{\"name\":\"2026\",\"values\":[1,2]}]}'"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var chart = WriterChart()
        try args.apply(to: &chart)
        guard chart.hasValues else { throw RPCError.invalidParams("Das Diagramm hat keine Werte.") }
        let reference = try WriterFigureActions.store(chart, caption: args.caption ?? "", width: args.width ?? 80, family: target.document?.font ?? .serif)
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        return (PowerText.inserting(reference.markdown, at: index, into: markdown), index)
    }
}

struct WriterChartEditAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.chart.edit", summary: "Ändert ein Diagramm; es bekommt neue Dateien, Rückgängig bringt das alte zurück", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.look) { _, new in new }.merging(Args.chartProperties) { _, new in new }.merging(["image": .string("Diagramm: Nummer unter den Diagrammen ab 1 oder Block-ID; ohne Angabe das einzige")]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let found = try WriterImageAddressing.find(args.image, in: markdown, label: "Diagramm") { $0.figure == .chart }
        guard var chart = WriterChart.decode(WriterImageStore.recipe(for: found.reference)) else {
            throw RPCError.invalidTarget("Die Daten dieses Diagramms fehlen.")
        }
        try args.apply(to: &chart)
        // A chart of a table shows the table's numbers as they are now.
        if let id = chart.table, let table = WriterTableAddressing.tables(in: markdown).first(where: { $0.table.style.id == id })?.table {
            chart.takeData(from: table.plainCells, formulas: table.style.formulas)
        }
        var reference = try WriterFigureActions.store(chart, caption: args.caption ?? found.reference.caption, width: args.width ?? found.reference.width, family: target.document?.font ?? .serif)
        reference.plot = found.reference.plot
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}

// MARK: Mermaid

func mermaidImages(_ code: String) async throws -> (WriterFigureImages, CGSize) {
    do {
        let result = try await FlowImageRenderer.shared.images(mermaid: code)
        return (WriterFigureImages(light: result.light, dark: result.dark, pdf: result.pdf), result.size)
    } catch MermaidRenderer.RenderError.failed(let message) {
        throw RPCError.invalidParams("Mermaid kann diesen Code nicht zeichnen: \(message)")
    } catch {
        throw RPCError.unavailable(error.localizedDescription)
    }
}

struct WriterMermaidInsertAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.mermaid.insert", summary: "Fügt ein Mermaid-Diagramm ein: aus Code, oder das geladene Modell schreibt es nach einer Anweisung", kind: .write, security: .localWrite,
        input: .object(Args.placed.merging(Args.look) { _, new in new }.merging([
            "type": .choice(WriterMermaid.DiagramType.allCases.map(\.rawValue), "Art; ohne code und instruction die Vorlage dieser Art"),
            "code": .string("Mermaid-Code"),
            "instruction": .string("Was das Diagramm zeigen soll; das Modell schreibt den Code"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer mermaid insert --doc X --code 'flowchart TD; A-->B'"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        // With an instruction the model reads the text around the place.
        return args.instruction == nil ? target.writePreflight : target.readPreflight
    }

    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let type = args.type.flatMap(WriterMermaid.DiagramType.init(rawValue:))
        let code: String
        if let given = args.code {
            code = given
        } else if let instruction = args.instruction {
            guard let client = context.app.client, let model = context.app.currentModelId else {
                throw RPCError.unavailable("Kein Sprachmodell gewählt.")
            }
            let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
            code = try await WriterMermaid.written(client: client, model: model, description: instruction, type: type,
                                                   context: WriterImageAddressing.context(at: index, in: markdown), current: nil)
            guard !code.isEmpty else { throw RPCError.internal("Das Modell hat kein Diagramm geschrieben.") }
        } else if let type {
            code = WriterMermaid.template(type)
        } else {
            throw RPCError.invalidParams("Bitte code, instruction oder type angeben.")
        }
        let (images, size) = try await mermaidImages(code)
        let source = try WriterImageStore.storeFigure(.mermaid, images: images, recipe: Data(code.utf8))
        let width = args.width ?? min(100, max(30, Int((size.width / WriterImageStore.referenceColumnWidth * 100).rounded())))
        let reference = WriterImageReference(source: source, caption: args.caption ?? "", width: width, figure: .mermaid)
        // The person may have typed while the model wrote.
        let current = target.markdown
        let index = try WriterPlacement.index(args.address, position: args.position, in: current)
        return (PowerText.inserting(reference.markdown, at: index, into: current), index)
    }
}

struct WriterMermaidEditAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.mermaid.edit", summary: "Zeichnet ein Mermaid-Diagramm mit neuem Code", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.look) { _, new in new }.merging([
            "image": .string("Diagramm: Nummer unter den Mermaid-Diagrammen ab 1 oder Block-ID; ohne Angabe das einzige"),
            "code": .string("Neuer Mermaid-Code; ohne Angabe bleibt er"),
        ]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let before = try WriterImageAddressing.find(args.image, in: markdown, label: "Mermaid-Diagramm") { $0.figure == .mermaid }
        var reference = before.reference
        reference.caption = args.caption ?? reference.caption
        reference.width = args.width ?? reference.width
        if let code = args.code {
            let (images, _) = try await mermaidImages(code)
            reference.source = try WriterImageStore.storeFigure(.mermaid, images: images, recipe: Data(code.utf8))
        }
        // The person may have typed while it was drawn.
        let found = try WriterImageAddressing.find(args.image, in: target.markdown, label: "Mermaid-Diagramm") { $0.figure == .mermaid }
        guard found.reference.source == before.reference.source else { throw RPCError.versionConflict(current: target.version) }
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}

// MARK: Drawings

extension WriterFigureArgs {
    @MainActor
    func shapes() throws -> [WriterDrawing.Shape] {
        try (elements ?? []).map { element in
            guard let kind = WriterDrawing.Kind(rawValue: element.kind) else { throw RPCError.invalidParams("Es gibt keine Form „\(element.kind)“.") }
            guard element.points.allSatisfy({ $0.count == 2 }) else { throw RPCError.invalidParams("Punkte sind Paare [x, y].") }
            let points = element.points.map { CGPoint(x: $0[0], y: $0[1]) }
            let needed = kind == .text ? 1 : 2
            guard kind.isTwoPoint ? points.count == 2 : points.count >= needed else {
                throw RPCError.invalidParams("„\(element.kind)“ braucht \(kind.isTwoPoint ? "genau zwei Punkte" : "mindestens \(needed) Punkt(e)").")
            }
            if kind == .text, (element.text ?? "").isEmpty { throw RPCError.invalidParams("Ein Text braucht text.") }
            return WriterDrawing.Shape(kind: kind, points: points, stroke: try actionColor(element.stroke ?? "222222"),
                                       fill: kind.canFill ? try element.fill.map(actionColor) : nil, width: CGFloat(element.width ?? 2),
                                       dashed: element.dashed ?? false, text: element.text ?? "", fontSize: CGFloat(element.fontSize ?? 22))
        }
    }

    @MainActor
    func apply(to drawing: inout WriterDrawing) throws {
        if let width = canvasWidth { drawing.size.width = width }
        if let height = canvasHeight { drawing.size.height = height }
        if let value = background.flatMap(WriterDrawing.Background.init(rawValue:)) { drawing.background = value }
        guard elements != nil else { return }
        let new = try shapes()
        drawing.shapes = append == true ? drawing.shapes + new : new
    }

    static let drawingProperties: [String: JSONSchema] = [
        "elements": .array(of: .object([
            "kind": .choice(WriterDrawing.Kind.allCases.map(\.rawValue), "Form"),
            "points": .array(of: .array(of: .number()), "Punkte [x, y] in der Leinwand; zwei für Linien und Formen, einer für Text"),
            "stroke": .string("Linienfarbe"), "fill": .string("Füllung"), "width": .number("Linienstärke"),
            "dashed": .boolean("Gestrichelt"), "text": .string("Der Text"), "fontSize": .number("Schriftgröße"),
        ], required: ["kind", "points"]), "Die Formen"),
        "canvasWidth": .number("Breite der Leinwand; Standard 800", minimum: 100, maximum: 4000),
        "canvasHeight": .number("Höhe der Leinwand; Standard 500", minimum: 100, maximum: 4000),
        "background": .choice(WriterDrawing.Background.allCases.map(\.rawValue), "Hintergrund"),
    ]

    @MainActor
    static func store(_ drawing: WriterDrawing) throws -> String {
        guard let images = drawing.images(), let recipe = try? JSONEncoder().encode(drawing) else { throw RPCError.internal("Die Zeichnung ließ sich nicht zeichnen.") }
        return try WriterImageStore.storeFigure(.drawing, images: images, recipe: recipe)
    }
}

struct WriterDrawingInsertAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.drawing.insert", summary: "Fügt eine Zeichnung aus Formen, Linien und Text ein", kind: .write, security: .localWrite,
        input: .object(Args.placed.merging(Args.look) { _, new in new }.merging(Args.drawingProperties) { _, new in new }, required: ["elements"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        var drawing = WriterDrawing()
        try args.apply(to: &drawing)
        guard !drawing.shapes.isEmpty else { throw RPCError.invalidParams("Die Zeichnung hat keine Formen.") }
        let reference = WriterImageReference(source: try Args.store(drawing), caption: args.caption ?? "", width: args.width ?? 80, figure: .drawing)
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        return (PowerText.inserting(reference.markdown, at: index, into: markdown), index)
    }
}

struct WriterDrawingEditAction: WriterTargetedAction {
    typealias Args = WriterFigureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.drawing.edit", summary: "Ändert eine Zeichnung: ersetzt ihre Formen oder hängt welche an", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(Args.look) { _, new in new }.merging(Args.drawingProperties) { _, new in new }.merging([
            "image": .string("Zeichnung: Nummer unter den Zeichnungen ab 1 oder Block-ID; ohne Angabe die einzige"),
            "append": .boolean("Die Formen anhängen statt ersetzen"),
        ]) { _, new in new }),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let found = try WriterImageAddressing.find(args.image, in: markdown, label: "Zeichnung") { $0.figure == .drawing }
        guard var drawing = WriterDrawing.decode(WriterImageStore.recipe(for: found.reference)) else {
            throw RPCError.invalidTarget("Die Daten dieser Zeichnung fehlen.")
        }
        try args.apply(to: &drawing)
        var reference = found.reference
        reference.source = try Args.store(drawing)
        reference.caption = args.caption ?? reference.caption
        reference.width = args.width ?? reference.width
        return (WriterImageAddressing.replacing(found, with: reference), nil)
    }
}

// MARK: Reading

/// Not in the catalog, but without it `writer.mermaid.edit` and the like would work blind: an agent has to see a figure's
/// recipe to change it.
struct WriterFigureReadAction: LLMDAction {
    typealias Args = WriterFigureArgs
    struct Output: Encodable, Sendable {
        var source: String
        var caption: String
        var width: Int?
        var kind: String
        var code: String?
        var chart: JSONValue?
        var drawing: JSONValue?
        var prompt: String?
        var phase: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.figure.read", summary: "Liest ein Bild samt dem, woraus es gemacht ist: Diagrammdaten, Mermaid-Code, Formen oder Prompt", kind: .read, security: .plainRead,
        input: .object(Args.referenced), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let reference = try WriterImageAddressing.find(args.image, in: target.markdown).reference
        var output = Output(source: reference.source, caption: reference.caption, width: reference.width,
                            kind: reference.figure?.rawValue ?? (reference.plot != nil ? "plot" : reference.isDiagram ? "diagram" : reference.generated ? "generated" : "image"))
        let recipe = WriterImageStore.recipe(for: reference)
        switch reference.figure {
        case .mermaid: output.code = recipe.flatMap { String(data: $0, encoding: .utf8) }
        case .chart: output.chart = recipe.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        case .drawing: output.drawing = recipe.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        case nil: break
        }
        if reference.generated {
            output.prompt = WriterImageStore.generationInfo(for: reference.source)?.prompt
            switch context.app.imageGeneration.phase(for: reference.source) {
            case .queued: output.phase = "wartet"
            case .running: output.phase = "läuft"
            case .failed(let message): output.phase = "Fehler: " + message
            case nil: output.phase = reference.isPlaceholder ? "Platzhalter" : "fertig"
            }
        }
        return output
    }
}
