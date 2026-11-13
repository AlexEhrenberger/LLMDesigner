import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterPageActions() {
        register(WriterPageFormatAction.self)
        register(WriterPageSetupAction.self)
        register(WriterPageRunningHeadsAction.self)
        register(WriterDocFontAction.self)
        register(WriterPageTemplateSaveAction.self)
        register(WriterPageTemplateDeleteAction.self)
        register(WriterSpeechReadAction.self)
        register(WriterSpeechStopAction.self)
        register(WriterDictationStartAction.self)
        register(WriterDictationStopAction.self)
        register(WriterPrintAction.self)
    }
}

struct WriterLineArg: Decodable, Sendable {
    var left: String?
    var center: String?
    var right: String?
}

struct WriterPageArgs: Decodable, Sendable {
    var doc: String?
    var format: String?
    var template: String?
    var name: String?
    var paperWidth: Double?
    var paperHeight: Double?
    var top: Double?
    var bottom: Double?
    var left: Double?
    var right: Double?
    var fontSize: Double?
    var lineSpacing: Double?
    var landscape: Bool?
    var header: WriterLineArg?
    var footer: WriterLineArg?
    var skipFirstPage: Bool?
    var rules: Bool?
    var clear: Bool?
    var font: String?

    static let docProperty: [String: JSONSchema] = ["doc": .string("Dokument (ID oder Titel)")]
    static let setupProperties: [String: JSONSchema] = [
        "paperWidth": .number("Blattbreite in Millimetern", minimum: WriterPageSetup.paperRange.lowerBound, maximum: WriterPageSetup.paperRange.upperBound),
        "paperHeight": .number("Blatthöhe in Millimetern", minimum: WriterPageSetup.paperRange.lowerBound, maximum: WriterPageSetup.paperRange.upperBound),
        "top": .number("Rand oben in Millimetern", minimum: WriterPageSetup.marginRange.lowerBound, maximum: WriterPageSetup.marginRange.upperBound),
        "bottom": .number("Rand unten in Millimetern", minimum: WriterPageSetup.marginRange.lowerBound, maximum: WriterPageSetup.marginRange.upperBound),
        "left": .number("Rand links in Millimetern", minimum: WriterPageSetup.marginRange.lowerBound, maximum: WriterPageSetup.marginRange.upperBound),
        "right": .number("Rand rechts in Millimetern", minimum: WriterPageSetup.marginRange.lowerBound, maximum: WriterPageSetup.marginRange.upperBound),
        "fontSize": .number("Schriftgröße in Punkt", minimum: 6, maximum: 24),
        "lineSpacing": .number("Zeilenabstand", minimum: 0.8, maximum: 4),
        "landscape": .boolean("Querformat"),
    ]

    @MainActor
    func applied(to base: WriterPageSetup) -> WriterPageSetup {
        var setup = base
        if let name { setup.name = name }
        if let paperWidth { setup.paperWidth = paperWidth }
        if let paperHeight { setup.paperHeight = paperHeight }
        if let top { setup.top = top }
        if let bottom { setup.bottom = bottom }
        if let left { setup.left = left }
        if let right { setup.right = right }
        if let fontSize { setup.fontSize = fontSize }
        if let lineSpacing { setup.lineSpacing = lineSpacing }
        if let landscape, landscape != (setup.paperWidth > setup.paperHeight) { swap(&setup.paperWidth, &setup.paperHeight) }
        return setup
    }
}

/// A change to the document (not its text) with undo and event.
@MainActor
private func changeDocument(_ reference: String?, context: ActionContext, _ change: (WriterDocument) throws -> Void) throws -> OKOutput {
    guard let reference else { throw RPCError.invalidParams("Bitte doc angeben.") }
    let document = try context.app.actionDocument(reference)
    try change(document)
    context.noteChange(of: document.id, before: document)
    return OKOutput(id: document.id.uuidString)
}

struct WriterPageFormatAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.page.format", summary: "Setzt das Seitenformat: Standard, Taschenbuch, Normseite oder eine eigene Vorlage", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging([
            "format": .choice(WriterPageFormat.allCases.map(\.rawValue), "Das Format; eigen braucht template oder ein gesetztes Format"),
            "template": .string("Name einer eigenen Vorlage"),
        ]) { _, new in new }, required: ["doc"]),
        output: .freeObject(), example: "llmd writer page format --doc X --format taschenbuch"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeDocument(args.doc, context: context) { document in
            if let name = args.template {
                guard let template = context.app.writerPageTemplates.first(where: { $0.name == name }) else { throw RPCError.notFound("Die Vorlage „\(name)“ gibt es nicht.") }
                context.app.setPageSetup(document.id, template)
                return
            }
            guard let format = args.format.flatMap(WriterPageFormat.init(rawValue:)) else { throw RPCError.invalidParams("Bitte format oder template angeben.") }
            guard format != .custom || document.pageSetup != nil else { throw RPCError.invalidTarget("Dieses Dokument hat noch kein eigenes Format. writer.page.setup legt es an.") }
            context.app.setPageFormat(document.id, format)
        }
    }
}

struct WriterPageSetupAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.page.setup", summary: "Setzt ein eigenes Seitenformat: Blatt, Ränder, Ausrichtung, Schriftgröße, Zeilenabstand", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging(Args.setupProperties) { _, new in new }, required: ["doc"]),
        output: .freeObject(), example: "llmd writer page setup --doc X --top 30 --landscape true"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeDocument(args.doc, context: context) { document in
            context.app.setPageSetup(document.id, args.applied(to: document.pageSetup ?? WriterPageSetup()))
        }
    }
}

struct WriterPageRunningHeadsAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    private static let line: JSONSchema = .object(["left": .string("Links"), "center": .string("Mitte"), "right": .string("Rechts")], "Platzhalter: " + WriterRunningHeads.placeholders.map(\.token).joined(separator: ", "))
    static let descriptor = ActionDescriptor(
        id: "writer.page.runningHeads", summary: "Setzt Kopf- und Fußzeile der gedruckten Seiten; clear nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging([
            "header": line, "footer": line,
            "skipFirstPage": .boolean("Die erste Seite bleibt ohne"),
            "rules": .boolean("Dünne Linie unter dem Kopf und über dem Fuß"),
            "clear": .boolean("Kopf- und Fußzeile entfernen"),
        ]) { _, new in new }, required: ["doc"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeDocument(args.doc, context: context) { document in
            if args.clear == true {
                context.app.setRunningHeads(document.id, nil)
                return
            }
            var heads = document.runningHeads ?? WriterRunningHeads()
            func apply(_ line: WriterLineArg?, to target: inout WriterRunningHeads.Line) {
                if let left = line?.left { target.left = left }
                if let center = line?.center { target.center = center }
                if let right = line?.right { target.right = right }
            }
            apply(args.header, to: &heads.header)
            apply(args.footer, to: &heads.footer)
            if let skip = args.skipFirstPage { heads.skipsFirstPage = skip }
            if let rules = args.rules { heads.hasRules = rules }
            context.app.setRunningHeads(document.id, heads)
        }
    }
}

struct WriterDocFontAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.doc.font", summary: "Setzt die Grundschrift des Dokuments", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging(["font": .choice(WriterFont.allCases.map(\.rawValue), "Die Schrift")]) { _, new in new }, required: ["doc", "font"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeDocument(args.doc, context: context) { document in
            guard let font = args.font.flatMap(WriterFont.init(rawValue:)) else { throw RPCError.invalidParams("Diese Schrift gibt es nicht.") }
            context.app.setDocumentFont(document.id, font)
        }
    }
}

struct WriterPageTemplateSaveAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.page.template.save", summary: "Speichert ein Seitenformat als Vorlage der Bibliothek; ohne Maße das des Dokuments", kind: .write, security: .localWrite,
        input: .object(Args.docProperty.merging(Args.setupProperties) { _, new in new }.merging(["name": .string("Name der Vorlage")]) { _, new in new }, required: ["name"]),
        output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let base = try args.doc.map { try app.actionDocument($0).pageSetup ?? WriterPageSetup() } ?? WriterPageSetup()
        let before = app.writerPageTemplates
        var setup = args.applied(to: base)
        setup.id = UUID()
        app.savePageTemplate(setup)
        let after = app.writerPageTemplates
        context.undoGroup.add(UndoStep(label: context.undoGroup.label, undo: { app.writerPageTemplates = before }, redo: { app.writerPageTemplates = after }))
        return OKOutput(id: app.writerPageTemplates.first { $0.name == args.name }?.id.uuidString)
    }
}

struct WriterPageTemplateDeleteAction: LLMDAction {
    typealias Args = WriterPageArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.page.template.delete", summary: "Löscht eine Vorlage der Bibliothek; Dokumente behalten ihr Format", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name der Vorlage")], required: ["name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        guard let template = app.writerPageTemplates.first(where: { $0.name == args.name }) else { throw RPCError.notFound("Die Vorlage „\(args.name ?? "")“ gibt es nicht.") }
        let before = app.writerPageTemplates
        app.deletePageTemplate(template.id)
        let after = app.writerPageTemplates
        context.undoGroup.add(UndoStep(label: context.undoGroup.label, undo: { app.writerPageTemplates = before }, redo: { app.writerPageTemplates = after }))
        return OKOutput(id: template.id.uuidString)
    }
}

// MARK: Audio

struct WriterSpeechReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
        }
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.speech.read", summary: "Liest einen Text oder eine Stelle vor", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties()), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        var text = target.markdown
        if !args.address.isEmpty {
            switch try WriterAddressing.resolve(args.address, in: text) {
            case .whole: break
            case .blocks(let range): text = PowerText.chunks(of: text)[range].map(\.markdown).joined(separator: "\n\n")
            case .text(let block, let range): text = (WriterMarkdown.attributedString(from: PowerText.chunks(of: text)[block].markdown).string as NSString).substring(with: range)
            case .source(let range): text = String(text[range])
            }
        }
        guard !SpeakableText.from(markdown: text).isEmpty else { throw RPCError.invalidTarget("Hier gibt es nichts vorzulesen.") }
        context.app.toggleReading(text, id: target.documentID)
        return OKOutput(id: target.documentID.uuidString)
    }
}

struct WriterSpeechStopAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.speech.stop", summary: "Hört auf vorzulesen", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.speechReader.stop()
        context.app.stopReadingDocument()
        return OKOutput()
    }
}

/// The microphone hears the room, so nobody but the person starts it without asking.
private let microphoneConsent = "Das Mikrofon geht an und nimmt auf, was im Raum gesprochen wird."

struct WriterDictationStartAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.dictation.start", summary: "Startet das Diktat in das offene Dokument; fragt immer nach", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func preflight(_ args: NoArgs, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: context.app.selectedDocument?.displayTitle)
        if context.channel != .ui { check.needsConsent = microphoneConsent }
        return check
    }
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        guard context.app.selectedDocumentID != nil else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        if !context.app.isDictating { context.app.toggleDictation() }
        return OKOutput()
    }
}

struct WriterDictationStopAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.dictation.stop", summary: "Beendet das Diktat", kind: .write, security: .localWrite, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        await context.app.stopDictation()
        return OKOutput()
    }
}

struct WriterPrintAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
    }
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.print", summary: "Öffnet den Druckdialog für ein Dokument; drucken muss die Person selbst", kind: .destructive, security: .outbound,
        input: .object(["doc": .string("Dokument (ID oder Titel)")], required: ["doc"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        return ActionPreflight(readsUntrusted: document.isForeign, target: document.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.doc)
        context.app.printWriterDocument(document.id)
        return OKOutput(id: document.id.uuidString)
    }
}
