import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterViewActions() {
        register(WriterSelectionGetAction.self)
        register(WriterCaretSetAction.self)
        register(WriterSelectAction.self)
        register(WriterSelectAllAction.self)
        register(WriterFindNextAction.self)
        register(WriterFindPreviousAction.self)
        register(WriterJumpHeadingAction.self)
        register(WriterJumpBookmarkAction.self)
        register(WriterJumpCommentAction.self)
        register(WriterViewRevealAction.self)
        register(WriterViewHighlightAction.self)
        register(WriterViewTabAction.self)
        register(WriterViewPanelAction.self)
    }
}

/// The open editor. These actions show the person something or work with what they see: the caret and the selection
/// exist only there. Everything else works on the Markdown and needs no editor.
@MainActor
enum WriterEditorAccess {
    static func controller(_ doc: String?, app: AppModel) throws -> WriterEditorController {
        if let doc {
            let document = try app.actionDocumentOrDeck(doc)
            guard app.selectedDocumentID == document.id else {
                throw RPCError.invalidTarget("„\(document.displayTitle)“ ist nicht offen. writer.doc.open öffnet es.")
            }
        }
        guard app.canFindInDocument, let controller = app.documentFind?.controller, controller.textView != nil else {
            throw RPCError.invalidTarget("Es ist kein Dokument offen. writer.doc.open öffnet eines.")
        }
        if app.writerTab != .document { app.showWriterTab(.document) }
        return controller
    }

    static func view(_ doc: String?, app: AppModel) throws -> WriterTextView {
        guard let view = try controller(doc, app: app).textView else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        return view
    }

    /// Where an address lies in the editor's text. Blocks are found one after the other, so a repeated text can't
    /// send a later block to an earlier place.
    static func range(_ address: WriterAddress, in view: WriterTextView) throws -> NSRange {
        guard let storage = view.textStorage else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        let markdown = WriterMarkdown.markdown(from: storage)
        let chunks = PowerText.chunks(of: markdown)
        let string = storage.string as NSString
        func placement(of block: Int) throws -> NSRange {
            var position = 0
            var found = NSRange(location: 0, length: 0)
            for chunk in chunks[...block] {
                let text = WriterMarkdown.attributedString(from: chunk.markdown).string.trimmingCharacters(in: .newlines)
                found = string.range(of: text, options: [], range: NSRange(location: position, length: string.length - position))
                guard found.location != NSNotFound else { throw RPCError.invalidTarget("Diese Stelle steht so nicht im Editor.") }
                position = NSMaxRange(found)
            }
            return found
        }
        switch try WriterAddressing.resolve(address, in: markdown) {
        case .whole:
            return BlockEditor.fullRange(of: storage)
        case .blocks(let range):
            return NSUnionRange(try placement(of: range.lowerBound), try placement(of: range.upperBound - 1))
        case .text(let block, let range):
            return NSRange(location: try placement(of: block).location + range.location, length: range.length)
        case .source(let range):
            let stretch = try WriterAddressing.textStretch(for: range, in: markdown)
            return NSRange(location: try placement(of: stretch.block).location + stretch.range.location, length: stretch.range.length)
        }
    }
}

struct WriterViewArgs: Decodable, Sendable {
    var doc: String?
    var address: WriterAddress
    var edge: String?
    var query: String?
    var bookmark: String?
    var comment: String?
    var tab: String?
    var panel: String?

    init(from decoder: Decoder) throws {
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        doc = try c.decodeIfPresent(String.self, forKey: .doc)
        edge = try c.decodeIfPresent(String.self, forKey: .edge)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        tab = try c.decodeIfPresent(String.self, forKey: .tab)
        panel = try c.decodeIfPresent(String.self, forKey: .panel)
    }

    enum Keys: String, CodingKey { case doc, edge, query, bookmark, comment, tab, panel }

    static let docProperty: [String: JSONSchema] = ["doc": .string("Das offene Dokument (ID oder Titel), zur Sicherheit; ohne Angabe das offene")]
    static func addressed(_ extra: [String: JSONSchema] = [:], required: [String] = []) -> JSONSchema {
        .object(docProperty.merging(WriterAddress.schemaProperties) { _, new in new }.merging(extra) { _, new in new }, required: required)
    }
}

/// Where the caret or selection is after an action.
struct WriterCaretOutput: Encodable, Sendable {
    var doc: String?
    var location: Int
    var length: Int
    var text: String

    @MainActor
    init(_ view: WriterTextView, app: AppModel) {
        let range = view.selectedRange()
        doc = app.selectedDocumentID?.uuidString
        location = range.location
        length = range.length
        text = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
    }
}

@MainActor
private func viewPreflight(_ doc: String?, app: AppModel) -> ActionPreflight {
    // What the editor shows comes back in the result: the same rule as for reading the document.
    let document = (doc.flatMap { try? app.actionDocumentOrDeck($0) }) ?? app.selectedDocument
    return ActionPreflight(readsUntrusted: document?.isForeign == true, target: document?.displayTitle)
}

struct WriterSelectionGetAction: LLMDAction {
    typealias Args = WriterViewArgs
    struct Output: Encodable, Sendable {
        var doc: String?
        var location: Int
        var length: Int
        var text: String
        var marks: [String]
        var block: String
        var fontSize: Double
        var hasLink: Bool
        var bookmark: String?
        var comment: String?
        var table: String?
    }
    static let descriptor = ActionDescriptor(
        id: "writer.selection.get", summary: "Liest Schreibmarke, Auswahl und aktive Formate im offenen Editor", kind: .read, security: .plainRead,
        input: .object(Args.docProperty), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        let state = view.state
        let caret = WriterCaretOutput(view, app: context.app)
        var marks: [String] = []
        for (mark, name) in [(WriterInline.bold, "bold"), (.italic, "italic"), (.underline, "underline"), (.strikethrough, "strikethrough"),
                             (.code, "code"), (.superscript, "superscript"), (.subscript, "subscript")] where state.marks.contains(mark) {
            marks.append(name)
        }
        return Output(doc: caret.doc, location: caret.location, length: caret.length, text: caret.text, marks: marks, block: state.block.rawValue,
                      fontSize: state.fontSize, hasLink: state.hasLink, bookmark: state.bookmarkID, comment: view.commentAtCaret?.id,
                      table: state.table?.cellName)
    }
}

struct WriterCaretSetAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.caret.set", summary: "Setzt die Schreibmarke im offenen Editor an den Anfang oder das Ende einer Stelle", kind: .read, security: .plainRead,
        input: Args.addressed(["edge": .choice(["start", "end"], "Standard: start")]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        let range = try WriterEditorAccess.range(args.address, in: view)
        let place = NSRange(location: args.edge == "end" ? NSMaxRange(range) : range.location, length: 0)
        view.setSelectedRange(place)
        view.scrollRangeToVisible(place)
        return WriterCaretOutput(view, app: context.app)
    }
}

struct WriterSelectAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.select", summary: "Markiert eine Stelle im offenen Editor", kind: .read, security: .plainRead,
        input: Args.addressed(), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        let range = try WriterEditorAccess.range(args.address, in: view)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        return WriterCaretOutput(view, app: context.app)
    }
}

struct WriterSelectAllAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.select.all", summary: "Markiert den ganzen Text im offenen Editor", kind: .read, security: .plainRead,
        input: .object(Args.docProperty), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        return WriterCaretOutput(view, app: context.app)
    }
}

/// The find bar's next or previous place.
@MainActor
private func stepFind(_ args: WriterViewArgs, _ command: DocumentFind.Command, context: ActionContext) throws -> WriterFindOutput {
    let controller = try WriterEditorAccess.controller(args.doc, app: context.app)
    let find = controller.find
    if !find.isShown { find.isShown = true }
    if let query = args.query { find.query = query }
    guard !find.query.isEmpty else { throw RPCError.invalidParams("Es wird noch nichts gesucht. Bitte query angeben.") }
    context.app.findInDocument(command)
    return WriterFindOutput(query: find.query, matches: find.matches.count, current: find.current.map { $0 + 1 })
}

struct WriterFindOutput: Encodable, Sendable {
    var query: String
    var matches: Int
    var current: Int?
}

struct WriterFindNextAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterFindOutput
    static let descriptor = ActionDescriptor(
        id: "writer.find.next", summary: "Springt im offenen Editor zum nächsten Treffer der Suche", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["query": .string("Neuer Suchtext; ohne Angabe der bisherige")]) { _, new in new }), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output { try stepFind(args, .next, context: context) }
}

struct WriterFindPreviousAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterFindOutput
    static let descriptor = ActionDescriptor(
        id: "writer.find.previous", summary: "Springt im offenen Editor zum vorigen Treffer der Suche", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["query": .string("Neuer Suchtext; ohne Angabe der bisherige")]) { _, new in new }), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output { try stepFind(args, .previous, context: context) }
}

struct WriterJumpHeadingAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.jump.heading", summary: "Springt im offenen Editor zu einer Überschrift", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["heading": WriterAddress.schemaProperties["heading"]!]) { _, new in new }, required: ["heading"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        view.reveal(try WriterEditorAccess.range(args.address, in: view))
        return WriterCaretOutput(view, app: context.app)
    }
}

struct WriterJumpBookmarkAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.jump.bookmark", summary: "Springt im offenen Editor zu einem Lesezeichen", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["bookmark": .string("ID oder Titel des Lesezeichens")]) { _, new in new }, required: ["bookmark"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        guard let storage = view.textStorage else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        let entries = WriterBookmark.entries(in: WriterMarkdown.markdown(from: storage))
        guard let entry = entries.first(where: { $0.id == args.bookmark || $0.title == args.bookmark }) else {
            throw RPCError.notFound("Das Lesezeichen „\(args.bookmark ?? "")“ gibt es nicht.")
        }
        view.jumpToBookmark(entry.id)
        return WriterCaretOutput(view, app: context.app)
    }
}

struct WriterJumpCommentAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = WriterCaretOutput
    static let descriptor = ActionDescriptor(
        id: "writer.jump.comment", summary: "Springt im offenen Editor zu einem Kommentar", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["comment": .string("ID des Kommentars")]) { _, new in new }, required: ["comment"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { viewPreflight(args.doc, app: context.app) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        guard view.comments.contains(where: { $0.comment.id == args.comment }) else { throw RPCError.notFound("Den Kommentar „\(args.comment ?? "")“ gibt es nicht.") }
        view.jumpToComment(args.comment ?? "")
        return WriterCaretOutput(view, app: context.app)
    }
}

struct WriterViewRevealAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.view.reveal", summary: "Scrollt eine Stelle im offenen Editor in Sicht; die Schreibmarke bleibt", kind: .read, security: .plainRead,
        input: Args.addressed(), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        view.scrollRangeToVisible(try WriterEditorAccess.range(args.address, in: view))
        return OKOutput()
    }
}

struct WriterViewHighlightAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = OKOutput
    /// Long enough to find the place, short enough not to stay in the way.
    static let seconds = 2.5
    static let descriptor = ActionDescriptor(
        id: "writer.view.highlight", summary: "Lässt eine Stelle im offenen Editor kurz aufleuchten", kind: .read, security: .plainRead,
        input: Args.addressed(), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let view = try WriterEditorAccess.view(args.doc, app: context.app)
        view.markPassage(try WriterEditorAccess.range(args.address, in: view))
        Task { [weak view] in
            try? await Task.sleep(for: .seconds(seconds))
            view?.markPassage(nil)
        }
        return OKOutput()
    }
}

struct WriterViewTabAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.view.tab", summary: "Zeigt einen Reiter des offenen Dokuments", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["tab": .choice(WriterTab.allCases.map(\.rawValue), "Der Reiter")]) { _, new in new }, required: ["tab"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let tab = args.tab.flatMap(WriterTab.init(rawValue:)) else { throw RPCError.invalidParams("Diesen Reiter gibt es nicht.") }
        let app = context.app
        if let doc = args.doc {
            guard app.selectedDocumentID == (try app.actionDocumentOrDeck(doc)).id else { throw RPCError.invalidTarget("Dieses Dokument ist nicht offen.") }
        }
        guard app.canFindInDocument else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        app.showWriterTab(tab)
        return OKOutput()
    }
}

extension AppModel {
    /// Shows a tab of the panel on the right of an open document or presentation.
    func showDocumentPanel(_ panel: String) throws {
        guard canFindInDocument else { throw RPCError.invalidTarget("Es ist kein Dokument offen.") }
        switch panel {
        case "analysis":
            showWriterTab(.analysis)
            return
        case "power":
            if !power.isOn { togglePower() }
            if !isPanelShown { toggleOutlinePanel() }
            return
        case "outline": documentPanelTab = .contents
        case "bookmarks": documentPanelTab = .bookmarks
        case "sources": documentPanelTab = .sources
        case "comments": documentPanelTab = .comments
        default: throw RPCError.invalidParams("Diese Seitenleiste gibt es nicht.")
        }
        if power.isOn { togglePower() }
        if !isPanelShown { toggleOutlinePanel() }
    }
}

struct WriterViewPanelAction: LLMDAction {
    typealias Args = WriterViewArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.view.panel", summary: "Zeigt eine Seitenleiste des offenen Dokuments", kind: .read, security: .plainRead,
        input: .object(Args.docProperty.merging(["panel": .choice(["outline", "bookmarks", "sources", "comments", "analysis", "power"], "Die Seitenleiste")]) { _, new in new }, required: ["panel"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try context.app.showDocumentPanel(args.panel ?? "")
        return OKOutput()
    }
}
