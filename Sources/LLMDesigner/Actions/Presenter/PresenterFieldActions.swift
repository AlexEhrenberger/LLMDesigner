import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterFieldActions() {
        register(PresenterFieldAddBoxAction.self)
        register(PresenterFieldAddTableAction.self)
        register(PresenterFieldAddCodeAction.self)
        register(PresenterFieldAddFigureAction.self)
        register(PresenterFieldGenerateImageAction.self)
        register(PresenterFieldRegenerateImageAction.self)
        register(PresenterFieldDetachSelectionAction.self)
        register(PresenterFieldResizeAction.self)
        register(PresenterFieldRestoreAspectAction.self)
        register(PresenterFieldAlignAction.self)
        register(PresenterFieldPlacementAction.self)
        register(PresenterFieldOrderAction.self)
        register(PresenterFieldBoxAction.self)
        register(PresenterFieldCaptionAction.self)
        register(PresenterFieldEditAction.self)
        register(PresenterFieldEndEditAction.self)
        register(PresenterFieldToSlideAction.self)
    }
}

private let frameSchema: [String: JSONSchema] = [
    "x": .number("Linke Kante, Anteil der Folie 0–1", minimum: 0, maximum: 1),
    "y": .number("Obere Kante, Anteil der Folie 0–1", minimum: 0, maximum: 1),
    "width": .number("Breite, Anteil der Folie", minimum: 0.04, maximum: 1),
    "height": .number("Höhe, Anteil der Folie", minimum: 0.02, maximum: 1),
]
private let fieldProperty: JSONSchema = .string("Element (ID)")

struct PresenterFieldArgs: Decodable, Sendable {
    var deck: String
    var slide: String?
    var slideIndex: Int?
    var field: String?
    var kind: String?
    var frame: String?
    var markdown: String?
    var language: String?
    var code: String?
    var rows: Int?
    var columns: Int?
    var header: [String]?
    var data: [[String]]?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var dx: Double?
    var dy: Double?
    var fitText: Bool?
    var edge: String?
    var placement: String?
    var order: String?
    var caption: String?
    var prompt: String?
    var style: String?
    var format: String?

    /// A free element's frame from fractions of the slide, with a default for what is missing.
    @MainActor
    func frame(default fallback: CGRect) -> CGRect {
        let canvas = SlideImage.canvas
        return CGRect(x: x.map { $0 * canvas.width } ?? fallback.minX, y: y.map { $0 * canvas.height } ?? fallback.minY,
                      width: width.map { $0 * canvas.width } ?? fallback.width, height: height.map { $0 * canvas.height } ?? fallback.height)
    }
}

/// A free element by its id, wherever in the deck it is.
@MainActor
private func changeField(_ deck: String, _ field: String?, context: ActionContext, _ change: (inout SlideImage) throws -> Void) throws {
    _ = try changeDeck(deck, context: context) { deck in
        for slide in deck.slides.indices {
            guard let index = deck.slides[slide].images.firstIndex(where: { $0.id.uuidString == field }) else { continue }
            try change(&deck.slides[slide].images[index])
            return
        }
        throw RPCError.notFound("Element \(field ?? "") gibt es nicht.")
    }
}

/// A new free element on a slide, as the "Frei platzieren" menu makes them.
@MainActor
private func addField(_ args: PresenterFieldArgs, text: String, box: WriterBoxKind? = nil, size: CGSize, context: ActionContext) throws -> OKOutput {
    var made: UUID?
    _ = try changeDeck(args.deck, context: context) { deck in
        let slide = try deck.actionSlide(id: args.slide, index: args.slideIndex)
        let offset = slide.images.filter(\.isText).count % 5
        let field = SlideImage(text: text, box: box, frame: args.frame(default: SlideImage.defaultTextFrame(width: size.width, height: size.height, offset: offset)))
        made = field.id
        deck.slides[deck.index(of: slide.id)!].images.append(field)
    }
    return OKOutput(id: made?.uuidString)
}

private let framedSlide: [String: JSONSchema] = presenterSlideProperties.merging(frameSchema) { _, new in new }

struct PresenterFieldAddBoxAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addBox", summary: "Legt einen Kasten frei auf die Folie", kind: .write, security: .localWrite,
        input: .object(framedSlide.merging([
            "kind": .choice(WriterBoxKind.allCases.map(\.rawValue), "Art des Kastens"), "markdown": .string("Inhalt"),
        ]) { _, new in new }, required: ["deck", "kind", "markdown"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try addField(args, text: args.markdown ?? "", box: args.kind.flatMap(WriterBoxKind.init(rawValue:)), size: CGSize(width: 300, height: 90), context: context)
    }
}

struct PresenterFieldAddTableAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addTable", summary: "Legt eine Tabelle frei auf die Folie; danach wirken die writer.table-Actions mit field", kind: .write, security: .localWrite,
        input: .object(framedSlide.merging([
            "rows": .integer("Zeilen samt Kopfzeile", minimum: 1, maximum: 60), "columns": .integer("Spalten", minimum: 1, maximum: 12),
            "header": .array(of: .string(), "Kopfzeile"), "data": .array(of: .array(of: .string()), "Zeilen"),
        ]) { _, new in new }, required: ["deck"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var content = (args.header.map { [$0] } ?? []) + (args.data ?? [])
        let width = max(args.columns ?? 0, content.map(\.count).max() ?? 0, content.isEmpty ? 3 : 1)
        let rows = max(args.rows ?? (content.isEmpty ? 3 : content.count), 1)
        if rows > content.count { content += Array(repeating: [], count: rows - content.count) }
        let table = MarkdownTable(cells: content.map { row in (row + Array(repeating: "", count: width - row.count)).map { MarkdownTable.cell(text: $0) } })
        return try addField(args, text: table.markdown, size: CGSize(width: 360, height: 120), context: context)
    }
}

struct PresenterFieldAddCodeAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addCode", summary: "Legt einen Code-Block frei auf die Folie", kind: .write, security: .localWrite,
        input: .object(framedSlide.merging(["language": .string("Sprache"), "code": .string("Der Code")]) { _, new in new }, required: ["deck", "code"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try addField(args, text: "```\(args.language ?? "")\n\(args.code ?? "")\n```", size: CGSize(width: 360, height: 130), context: context)
    }
}

/// A figure in a field of its own, as the menu makes it: the picture is the field's text, so it opens in its editor.
struct PresenterFieldAddFigureAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var field: PresenterFieldArgs
        var figure: WriterFigureArgs
        var type: String
        init(from decoder: Decoder) throws {
            figure = try WriterFigureArgs(from: decoder)
            type = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .figureKind)
            // The figure's own `width` is a percentage, the frame's a fraction; only the frame's position counts here.
            let c = try decoder.container(keyedBy: Frame.self)
            field = PresenterFieldArgs(deck: figure.deck ?? "", slide: figure.slide, slideIndex: figure.slideIndex,
                                       x: try c.decodeIfPresent(Double.self, forKey: .x), y: try c.decodeIfPresent(Double.self, forKey: .y))
        }
        enum Keys: String, CodingKey { case figureKind }
        enum Frame: String, CodingKey { case x, y }
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.addFigure", summary: "Legt ein Diagramm, eine Mermaid-Grafik oder eine Zeichnung frei auf die Folie", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties.merging([
            "figureKind": .choice(["chart", "mermaid", "drawing"], "Was es wird"),
            "x": frameSchema["x"]!, "y": frameSchema["y"]!, "caption": .string("Bildunterschrift"),
            "code": .string("Mermaid-Code"),
            "kind": .choice(WriterChart.Kind.allCases.map(\.rawValue), "Diagrammart"), "title": .string("Titel im Diagramm"),
            "categories": .array(of: .string(), "Kategorien"),
            "series": .array(of: .object(["name": .string("Name"), "values": .array(of: .any("Zahl oder null")), "color": .string("Farbe")], required: ["name", "values"]), "Reihen"),
            "elements": .array(of: .freeObject(), "Formen, wie bei writer.drawing.insert"),
        ]) { _, new in new }, required: ["deck", "figureKind"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.field.deck, presentation: true)
        let figure = args.figure
        var reference: WriterImageReference
        switch args.type {
        case "chart":
            var chart = WriterChart()
            try figure.apply(to: &chart)
            guard chart.hasValues else { throw RPCError.invalidParams("Das Diagramm hat keine Werte.") }
            reference = try WriterFigureActions.store(chart, caption: figure.caption ?? "", width: 100, family: document.font)
        case "mermaid":
            guard let code = figure.code else { throw RPCError.invalidParams("Bitte code angeben.") }
            let (images, _) = try await mermaidImages(code)
            reference = WriterImageReference(source: try WriterImageStore.storeFigure(.mermaid, images: images, recipe: Data(code.utf8)), caption: figure.caption ?? "", width: 100, figure: .mermaid)
        default:
            var drawing = WriterDrawing()
            try figure.apply(to: &drawing)
            guard !drawing.shapes.isEmpty else { throw RPCError.invalidParams("Die Zeichnung hat keine Formen.") }
            reference = WriterImageReference(source: try WriterFigureArgs.store(drawing), caption: figure.caption ?? "", width: 100, figure: .drawing)
        }
        reference.plot = nil
        return try addField(args.field, text: reference.markdown, size: CGSize(width: 380, height: 230), context: context)
    }
}

struct PresenterFieldGenerateImageAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.generateImage", summary: "Lässt Draw Things ein freies Bild für die Folie machen; bis dahin steht dort ein Platzhalter", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties.merging([
            "prompt": .string("Englischer Prompt"), "caption": .string("Beschreibung"),
            "style": .choice(ImageStyle.allCases.map(\.rawValue), "Stil"), "format": .choice(ImageFormat.allCases.map(\.rawValue), "Format"),
        ]) { _, new in new }, required: ["deck", "prompt"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let prompt = (args.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let slide = try document.deck?.actionSlide(id: args.slide, index: args.slideIndex) else { throw RPCError.invalidTarget("Diese Präsentation hat keine Folien.") }
        var info = app.imageGeneration.defaults
        info.prompt = prompt
        if let style = args.style.flatMap(ImageStyle.init(rawValue:)) { info.style = style }
        if let format = args.format.flatMap(ImageFormat.init(rawValue:)) { info.format = format }
        info.seed = nil
        let made = app.addGeneratedSlideImage(document.id, slide.id, info: info, caption: args.caption ?? "", generate: true, undoManager: nil)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterFieldRegenerateImageAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.regenerateImage", summary: "Macht ein generiertes Bild der Folie neu, mit neuem Seed oder Prompt", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty, "prompt": .string("Neuer Prompt; ohne Angabe der alte")], required: ["deck", "field"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let (slide, image) = document.deck?.slides.lazy.compactMap({ slide in slide.images.first { $0.id.uuidString == args.field }.map { (slide, $0) } }).first else {
            throw RPCError.notFound("Element \(args.field ?? "") gibt es nicht.")
        }
        guard image.generated else { throw RPCError.invalidTarget("Dieses Bild ist nicht generiert.") }
        var info = WriterImageStore.generationInfo(for: image.source) ?? app.imageGeneration.defaults
        if let prompt = args.prompt { info.prompt = prompt }
        info.seed = nil
        guard !info.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError.invalidParams("Bitte einen Prompt angeben.") }
        app.updateGeneratedSlideImage(document.id, slide.id, image.id, info: info, caption: image.caption, generate: true, undoManager: nil)
        context.noteChange(of: document.id, before: document)
        return OKOutput(id: image.id.uuidString)
    }
}

struct PresenterFieldDetachSelectionAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var field: PresenterFieldArgs
        var address: WriterAddress
        init(from decoder: Decoder) throws {
            field = try PresenterFieldArgs(from: decoder)
            address = try WriterAddress(from: decoder)
        }
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.detachSelection", summary: "Löst eine Stelle des Folientexts als eigenes Textfeld heraus", kind: .write, security: .localWrite,
        input: .object(framedSlide.merging(WriterAddress.schemaProperties) { _, new in new }, required: ["deck"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard !args.address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, welche Stelle: match, block, heading oder range.") }
        var made: UUID?
        _ = try changeDeck(args.field.deck, context: context) { deck in
            let slide = try deck.actionSlide(id: args.field.slide, index: args.field.slideIndex)
            var passage = ""
            switch try WriterAddressing.resolve(args.address, in: slide.markdown) {
            case .whole: passage = slide.markdown
            case .blocks(let range): passage = PowerText.chunks(of: slide.markdown)[range].map(\.markdown).joined(separator: "\n\n")
            case .text(let block, let range):
                let text = WriterMarkdown.attributedString(from: PowerText.chunks(of: slide.markdown)[block].markdown)
                passage = WriterMarkdown.inlineMarkdown(text.attributedSubstring(from: range))
            case .source(let range): passage = String(slide.markdown[range])
            }
            let rest = try WriterTextInsertMarkdownAction.place("", at: args.address, position: "replace", in: slide.markdown)
            let height = min(SlideImage.canvas.height * 0.6, CGFloat(passage.components(separatedBy: "\n").count) * 26 + 24)
            let field = SlideImage(text: passage, frame: args.field.frame(default: SlideImage.defaultTextFrame(width: 320, height: height, offset: slide.images.filter(\.isText).count % 5)))
            made = field.id
            let index = deck.index(of: slide.id)!
            deck.slides[index].markdown = rest
            deck.slides[index].images.append(field)
        }
        return OKOutput(id: made?.uuidString)
    }
}

struct PresenterFieldResizeAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.resize", summary: "Ändert die Größe eines Elements; fitText richtet die Höhe eines Textfelds grob an seinem Text aus", kind: .write, security: .localWrite,
        input: .object([
            "deck": presenterDeckProperty, "field": fieldProperty, "width": frameSchema["width"]!, "height": frameSchema["height"]!,
            "fitText": .boolean("Höhe nach dem Text; genau wird es erst im Editor, der das Feld bei Bedarf weiter wachsen lässt"),
        ], required: ["deck", "field"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { field in
            if let width = args.width { field.width = width }
            if let height = args.height { field.height = height }
            if args.fitText == true {
                guard let text = field.text else { throw RPCError.invalidTarget("Nur Textfelder richten sich nach ihrem Text.") }
                let plain = WriterMarkdown.attributedString(from: text).string
                // The slide's text size is about 18 points; the editor measures exactly when the field is opened.
                let bounds = (plain as NSString).boundingRect(with: CGSize(width: field.frame.width - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                              attributes: [.font: NSFont.systemFont(ofSize: 18)])
                field.height = min(1 - field.y, Double((bounds.height + 28) / SlideImage.canvas.height))
            }
        }
        return OKOutput()
    }
}

struct PresenterFieldRestoreAspectAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.restoreAspect", summary: "Gibt einem Bild sein ursprüngliches Seitenverhältnis zurück", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty], required: ["deck", "field"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { field in
            guard !field.isText, let url = WriterImageStore.url(for: field.source), let size = WriterImageStore.naturalSize(of: url), size.height > 0 else {
                throw RPCError.invalidTarget("Dieses Element hat kein Bild, dessen Größe bekannt ist.")
            }
            var frame = field.frame
            let middle = frame.midY
            frame.size.height = frame.width * size.height / size.width
            frame.origin.y = max(0, min(SlideImage.canvas.height - frame.height, middle - frame.height / 2))
            field.frame = frame
        }
        return OKOutput()
    }
}

struct PresenterFieldAlignAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.align", summary: "Richtet ein Element an der Folie aus", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty, "edge": .choice(["center", "middle", "left", "right", "top", "bottom"], "center waagrecht, middle senkrecht")], required: ["deck", "field", "edge"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { field in
            switch args.edge {
            case "left": field.x = 0
            case "right": field.x = 1 - field.width
            case "top": field.y = 0
            case "bottom": field.y = 1 - field.height
            case "middle": field.y = (1 - field.height) / 2
            default: field.x = (1 - field.width) / 2
            }
        }
        return OKOutput()
    }
}

struct PresenterFieldPlacementAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.placement", summary: "Bestimmt, wie ein Element und der Folientext sich die Folie teilen", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty, "placement": .choice(SlideImage.Placement.allCases.map(\.rawValue), "Die Lage")], required: ["deck", "field", "placement"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { $0.placement = args.placement.flatMap(SlideImage.Placement.init(rawValue:)) ?? $0.placement }
        return OKOutput()
    }
}

struct PresenterFieldOrderAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.order", summary: "Ordnet ein Element vor oder hinter die anderen", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty, "order": .choice(["front", "back", "forward", "backward"], "Wohin")], required: ["deck", "field", "order"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        _ = try changeDeck(args.deck, context: context) { deck in
            for slide in deck.slides.indices {
                guard let index = deck.slides[slide].images.firstIndex(where: { $0.id.uuidString == args.field }) else { continue }
                let count = deck.slides[slide].images.count
                let target: Int
                switch args.order {
                case "front": target = count - 1
                case "back": target = 0
                case "forward": target = min(count - 1, index + 1)
                default: target = max(0, index - 1)
                }
                let field = deck.slides[slide].images.remove(at: index)
                deck.slides[slide].images.insert(field, at: target)
                return
            }
            throw RPCError.notFound("Element \(args.field ?? "") gibt es nicht.")
        }
        return OKOutput()
    }
}

struct PresenterFieldBoxAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.box", summary: "Macht ein Textfeld zum Kasten oder ändert ihn; none nimmt den Kasten weg", kind: .write, security: .localWrite,
        input: .object([
            "deck": presenterDeckProperty, "field": fieldProperty,
            "kind": .choice(WriterBoxKind.allCases.map(\.rawValue) + ["none"], "Art"),
            "frame": .choice(WriterBoxStyle.Frame.allCases.map(\.rawValue), "Rahmen"),
        ], required: ["deck", "field"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { field in
            guard field.isText else { throw RPCError.invalidTarget("Nur Textfelder können Kästen sein.") }
            if let kind = args.kind { field.box = WriterBoxKind(rawValue: kind) }
            if let frame = args.frame.flatMap(WriterBoxStyle.Frame.init(rawValue:)) { field.boxFrame = frame }
        }
        return OKOutput()
    }
}

struct PresenterFieldCaptionAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.caption", summary: "Setzt die Beschreibung eines Bildes", kind: .write, security: .localWrite,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty, "caption": .string("Der Text")], required: ["deck", "field", "caption"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeField(args.deck, args.field, context: context) { $0.caption = args.caption ?? "" }
        return OKOutput()
    }
}

struct PresenterFieldEditAction: LLMDAction {
    typealias Args = PresenterFieldArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.edit", summary: "Setzt den Editor der offenen Präsentation in ein Textfeld", kind: .read, security: .plainRead,
        input: .object(["deck": presenterDeckProperty, "field": fieldProperty], required: ["deck", "field"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.deck, presentation: true)
        guard let (slide, field) = document.deck?.slides.lazy.compactMap({ slide in slide.images.first { $0.id.uuidString == args.field }.map { (slide, $0) } }).first else {
            throw RPCError.notFound("Element \(args.field ?? "") gibt es nicht.")
        }
        guard field.isText else { throw RPCError.invalidTarget("Das Element hat keinen Text.") }
        if app.selectedDocumentID != document.id { app.selectDocument(document.id) }
        app.selectSlide(slide.id)
        app.selectedSlideImageID = field.id
        app.editingSlideTextArea = false
        app.editingSlideFieldID = field.id
        return OKOutput(id: field.id.uuidString)
    }
}

struct PresenterFieldEndEditAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.endEdit", summary: "Holt den Editor aus dem Textfeld zurück zum Folientext", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.endSlideFieldEditing()
        return OKOutput()
    }
}

/// `writer.image.toSlide` from the other side, under the name the Presenter catalog lists it.
struct PresenterFieldToSlideAction: LLMDAction {
    typealias Args = WriterImageToSlideAction.Args
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "presenter.field.toSlide", summary: "Holt ein Bild aus einem Dokument als freies Element auf eine Folie", kind: .write, security: .localWrite,
        input: WriterImageToSlideAction.descriptor.input, output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try WriterImageToSlideAction.preflight(args, context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output { try await WriterImageToSlideAction.run(args, context: context) }
}
