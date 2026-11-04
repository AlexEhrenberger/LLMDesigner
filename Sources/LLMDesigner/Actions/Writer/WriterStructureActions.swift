import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterStructureActions() {
        register(WriterTOCInsertAction.self)
        register(WriterTOCSetModeAction.self)
        register(WriterTOCExpandAction.self)
        register(WriterTOCRemoveAction.self)
        register(WriterBookmarksListAction.self)
        register(WriterBookmarkAddAction.self)
        register(WriterBookmarkRenameAction.self)
        register(WriterBookmarkRemoveAction.self)
        register(WriterCommentsListAction.self)
        register(WriterCommentAddAction.self)
        register(WriterCommentReplyAction.self)
        register(WriterCommentEditAction.self)
        register(WriterCommentResolveAction.self)
        register(WriterCommentDeleteAction.self)
        register(WriterCitationsListAction.self)
        register(WriterCitationEditAction.self)
    }
}

struct WriterStructureArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var position: String?
    var mode: String?
    var name: String?
    var bookmark: String?
    var comment: String?
    var text: String?
    var entry: Int?
    var resolved: Bool?
    var citation: String?
    var page: String?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        entry = try c.decodeIfPresent(Int.self, forKey: .entry)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved)
        citation = try c.decodeIfPresent(String.self, forKey: .citation)
        page = try c.decodeIfPresent(String.self, forKey: .page)
    }
    enum Keys: String, CodingKey { case position, mode, name, bookmark, comment, text, entry, resolved, citation, page }

    static func properties(_ extra: [String: JSONSchema]) -> [String: JSONSchema] {
        WriterTargetArgs.schemaProperties.merging(extra) { _, new in new }
    }
}

/// Text with an attribute object (a bookmark, a comment) changed wherever it stands.
@MainActor
private func changingObjects<T: NSObject>(_ key: NSAttributedString.Key, of type: T.Type, in markdown: String, matching: (T) -> Bool, _ change: (T) -> T?) -> (text: String, found: Bool) {
    var editor = BlockEditor(markdown: markdown)
    var found = false
    for index in editor.blocks.indices.reversed() {
        let original = editor.blocks[index]
        var hit = false
        let attributed = WriterMarkdown.attributedString(from: original)
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let object = value as? T, matching(object) { hit = true }
        }
        guard hit else { continue }
        found = true
        editor.edit(index) { text in
            var changes: [(NSRange, T?)] = []
            text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let object = value as? T, matching(object) { changes.append((range, change(object))) }
            }
            for (range, new) in changes {
                if let new { text.addAttribute(key, value: new, range: range) } else { text.removeAttribute(key, range: range) }
            }
        }
    }
    return (editor.markdown, found)
}

// MARK: Table of contents

struct WriterTOCInsertAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.toc.insert", summary: "Fügt das Inhaltsverzeichnis ein: aus den Überschriften oder aus den Themen des Modells", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging([
            "mode": .choice(["formal", "dynamic"], "formal: aus den Überschriften (Standard); dynamic: Themen des Modells"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd writer toc insert --doc X --mode formal"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        let marker = args.mode == "dynamic" ? WriterTOCAttachment.dynamicMarker : WriterTOCAttachment.marker
        return (PowerText.inserting(marker, at: index, into: markdown), index)
    }
}

struct WriterTOCSetModeAction: LLMDAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.toc.setMode", summary: "Stellt das Inhaltsverzeichnis um: Überschriften oder Themen des Modells", kind: .write, security: .localWrite,
        input: .object(Args.properties(["mode": .choice(["formal", "dynamic"], "Die Art")]), required: ["mode"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let before = target.document
        let marker = args.mode == "dynamic" ? WriterTOCAttachment.dynamicMarker : WriterTOCAttachment.marker
        let text = target.markdown.components(separatedBy: "\n").map { WriterTOCAttachment.kind(of: $0) != nil ? marker : $0 }.joined(separator: "\n")
        // The side panel's list follows as well; both are the document's table of contents.
        if target.part == .document { context.app.setDocumentTOCMode(target.documentID, args.mode == "dynamic" ? .dynamic : .headings) }
        let result = try target.replaceText(with: text, ifVersion: args.target.ifVersion, context: context)
        if let before, before.tocMode != target.document?.tocMode { context.noteChange(of: target.documentID, before: before) }
        return result
    }
}

struct WriterTOCExpandAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.toc.expand", summary: "Schreibt das Inhaltsverzeichnis als gewöhnlichen Text aus, mit Links zu den Überschriften", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        guard WriterTOCAttachment.kind(in: markdown) != nil else { throw RPCError.notFound("In diesem Text steht kein Inhaltsverzeichnis.") }
        return (WriterMarkdownExport.expandTableOfContents(in: markdown, outline: target.document?.outline), nil)
    }
}

struct WriterTOCRemoveAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.toc.remove", summary: "Nimmt das Inhaltsverzeichnis aus dem Text", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        guard WriterTOCAttachment.kind(in: markdown) != nil else { throw RPCError.notFound("In diesem Text steht kein Inhaltsverzeichnis.") }
        return (WriterLines.normalized(markdown.components(separatedBy: "\n").filter { WriterTOCAttachment.kind(of: $0) == nil }), nil)
    }
}

// MARK: Bookmarks

struct WriterBookmarksListAction: LLMDAction {
    typealias Args = WriterStructureArgs
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var excerpt: String
        var section: String?
    }
    struct Output: Encodable, Sendable {
        var bookmarks: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.bookmarks.list", summary: "Listet die Lesezeichen eines Textes", kind: .read, security: .plainRead,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try WriterTarget(args.target, app: context.app).readPreflight }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let markdown = try WriterTarget(args.target, app: context.app).markdown
        return Output(bookmarks: WriterBookmark.entries(in: markdown).map { Item(id: $0.id, title: $0.title, excerpt: $0.excerpt, section: $0.section) })
    }
}

@MainActor
private func bookmarkIDMatches(_ reference: String?, in markdown: String) throws -> String {
    let entries = WriterBookmark.entries(in: markdown)
    guard let entry = entries.first(where: { $0.id == reference }) ?? entries.first(where: { $0.title == reference }) else {
        throw RPCError.notFound("Das Lesezeichen „\(reference ?? "")“ gibt es nicht.")
    }
    return entry.id
}

struct WriterBookmarkAddAction: LLMDAction {
    typealias Args = WriterStructureArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.bookmark.add", summary: "Setzt ein Lesezeichen auf eine Stelle", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["name": .string("Name")]), required: ["name"]),
        output: .freeObject(), example: "llmd writer bookmark add --doc X --match Wort --name Merker"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        var editor = BlockEditor(markdown: markdown)
        let bookmark = WriterBookmark(title: args.name ?? "")
        // One passage; several blocks share the object.
        for stretch in try WriterSelection.stretches(args.address, in: markdown).reversed() {
            editor.edit(stretch.block) { text in
                text.addAttribute(.writerBookmark, value: bookmark, range: stretch.range ?? BlockEditor.fullRange(of: text))
            }
        }
        _ = try target.replaceText(with: editor.markdown, ifVersion: args.target.ifVersion, context: context)
        return OKOutput(id: bookmark.id)
    }
}

struct WriterBookmarkRenameAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.bookmark.rename", summary: "Benennt ein Lesezeichen um", kind: .write, security: .localWrite,
        input: .object(Args.properties(["bookmark": .string("ID oder Titel"), "name": .string("Neuer Name")]), required: ["bookmark", "name"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let id = try bookmarkIDMatches(args.bookmark, in: markdown)
        let name = args.name ?? ""
        return (changingObjects(.writerBookmark, of: WriterBookmark.self, in: markdown, matching: { $0.id == id }) { WriterBookmark(id: $0.id, title: name) }.text, nil)
    }
}

struct WriterBookmarkRemoveAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.bookmark.remove", summary: "Entfernt ein Lesezeichen; der Text bleibt", kind: .write, security: .localWrite,
        input: .object(Args.properties(["bookmark": .string("ID oder Titel")]), required: ["bookmark"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let id = try bookmarkIDMatches(args.bookmark, in: markdown)
        return (changingObjects(.writerBookmark, of: WriterBookmark.self, in: markdown, matching: { $0.id == id }) { _ in nil }.text, nil)
    }
}

// MARK: Comments

/// Comments an agent writes carry this name when no model wrote them.
private let agentCommentAuthor = "Agent"

struct WriterCommentsListAction: LLMDAction {
    typealias Args = WriterStructureArgs
    struct Entry: Encodable, Sendable {
        var author: String
        var isAI: Bool
        var date: Date
        var text: String
    }
    struct Item: Encodable, Sendable {
        var id: String
        var resolved: Bool
        var excerpt: String
        var entries: [Entry]
    }
    struct Output: Encodable, Sendable {
        var comments: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.comments.list", summary: "Listet die Kommentare eines Textes mit ihrem Verlauf", kind: .read, security: .plainRead,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try WriterTarget(args.target, app: context.app).readPreflight }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var items: [Item] = []
        var index: [String: Int] = [:]
        for chunk in PowerText.chunks(of: try WriterTarget(args.target, app: context.app).markdown) where chunk.markdown.contains("data-comment") {
            let text = WriterMarkdown.attributedString(from: chunk.markdown)
            text.enumerateAttribute(.writerComment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let comment = value as? WriterComment else { return }
                let piece = (text.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                if let at = index[comment.id] {
                    items[at].excerpt += " " + piece
                } else {
                    index[comment.id] = items.count
                    items.append(Item(id: comment.id, resolved: comment.isResolved, excerpt: piece,
                                      entries: comment.entries.map { Entry(author: $0.author, isAI: $0.isAI, date: $0.date, text: $0.text) }))
                }
            }
        }
        return Output(comments: items)
    }
}

struct WriterCommentAddAction: LLMDAction {
    typealias Args = WriterStructureArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "writer.comment.add", summary: "Setzt einen Kommentar auf eine Stelle", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["text": .string("Der Kommentar")]), required: ["text"]),
        output: .freeObject(), example: "llmd writer comment add --doc X --match Wort --text 'Stimmt das?'"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(args.target, app: context.app)
        try target.checkVersion(args.target.ifVersion)
        return target.writePreflight
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let target = try WriterTarget(args.target, app: context.app)
        let markdown = target.markdown
        let text = (args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError.invalidParams("Der Kommentar ist leer.") }
        let comment = WriterComment(entries: [WriterComment.Entry(author: agentCommentAuthor, isAI: true, date: Date(), text: text)])
        var editor = BlockEditor(markdown: markdown)
        for stretch in try WriterSelection.stretches(args.address, in: markdown).reversed() {
            editor.edit(stretch.block) { attributed in
                attributed.addAttribute(.writerComment, value: comment, range: stretch.range ?? BlockEditor.fullRange(of: attributed))
            }
        }
        _ = try target.replaceText(with: editor.markdown, ifVersion: args.target.ifVersion, context: context)
        return OKOutput(id: comment.id)
    }
}

/// A change to one comment, wherever its passage stands.
@MainActor
private func changeComment(_ args: WriterStructureArgs, in markdown: String, _ change: (WriterComment) throws -> WriterComment?) throws -> String {
    var failure: Error?
    let result = changingObjects(.writerComment, of: WriterComment.self, in: markdown, matching: { $0.id == args.comment }) { comment in
        do {
            return try change(comment)
        } catch {
            failure = error
            return comment
        }
    }
    if let failure { throw failure }
    guard result.found else { throw RPCError.notFound("Den Kommentar „\(args.comment ?? "")“ gibt es nicht. writer.comments.list zeigt sie.") }
    return result.text
}

struct WriterCommentReplyAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.comment.reply", summary: "Antwortet in einem Kommentar", kind: .write, security: .localWrite,
        input: .object(Args.properties(["comment": .string("ID des Kommentars"), "text": .string("Die Antwort")]), required: ["comment", "text"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let text = (args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError.invalidParams("Die Antwort ist leer.") }
        return (try changeComment(args, in: markdown) { $0.with(entries: $0.entries + [WriterComment.Entry(author: agentCommentAuthor, isAI: true, date: Date(), text: text)]) }, nil)
    }
}

struct WriterCommentEditAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.comment.edit", summary: "Ändert einen Eintrag eines Kommentars", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "comment": .string("ID des Kommentars"), "text": .string("Der neue Text"),
            "entry": .integer("Welcher Eintrag, ab 1; Standard: der letzte", minimum: 1),
        ]), required: ["comment", "text"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        (try changeComment(args, in: markdown) { comment in
            let index = (args.entry ?? comment.entries.count) - 1
            guard comment.entries.indices.contains(index) else { throw RPCError.notFound("Der Kommentar hat \(comment.entries.count) Einträge.") }
            var entries = comment.entries
            entries[index].text = args.text ?? ""
            return comment.with(entries: entries)
        }, nil)
    }
}

struct WriterCommentResolveAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.comment.resolve", summary: "Markiert einen Kommentar als erledigt, oder öffnet ihn wieder", kind: .write, security: .localWrite,
        input: .object(Args.properties(["comment": .string("ID des Kommentars"), "resolved": .boolean("Standard: true")]), required: ["comment"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        (try changeComment(args, in: markdown) { $0.with(isResolved: args.resolved ?? true) }, nil)
    }
}

struct WriterCommentDeleteAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.comment.delete", summary: "Löscht einen Kommentar; der Text bleibt", kind: .write, security: .localWrite,
        input: .object(Args.properties(["comment": .string("ID des Kommentars")]), required: ["comment"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        (try changeComment(args, in: markdown) { _ in nil }, nil)
    }
}

// MARK: Citations

/// The citations in the text, each `[…]` with its items.
private func citationMatches(in markdown: String) -> [(range: NSRange, items: [CitationItem])] {
    guard let expression = try? NSRegularExpression(pattern: #"(?<!\\)\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()"#) else { return [] }
    let text = markdown as NSString
    return expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)).compactMap { match in
        CitationMarkup.parse(text.substring(with: match.range(at: 1))).map { (match.range, $0) }
    }
}

struct WriterCitationsListAction: LLMDAction {
    typealias Args = WriterStructureArgs
    struct Item: Encodable, Sendable {
        var number: Int
        var key: String
        var page: String
        var known: Bool
    }
    struct Output: Encodable, Sendable {
        var keys: [String]
        var citations: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.citations.list", summary: "Listet die Belege eines Textes", kind: .read, security: .plainRead,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try WriterTarget(args.target, app: context.app).readPreflight }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let markdown = try WriterTarget(args.target, app: context.app).markdown
        context.app.citations.loadIfNeeded()
        var items: [Item] = []
        for (index, match) in citationMatches(in: markdown).enumerated() {
            for item in match.items {
                items.append(Item(number: index + 1, key: item.key, page: item.locator, known: context.app.citations.source(citekey: item.key) != nil))
            }
        }
        return Output(keys: CitationMarkup.keys(in: markdown), citations: items)
    }
}

struct WriterCitationEditAction: WriterTargetedAction {
    typealias Args = WriterStructureArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.citation.edit", summary: "Ändert die Seitenangabe eines Belegs", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "citation": .string("Beleg: Nummer aus writer.citations.list oder Zitierschlüssel"),
            "page": .string("Die Seite; leer nimmt sie weg"),
        ]), required: ["citation", "page"]), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let matches = citationMatches(in: markdown)
        let reference = args.citation ?? ""
        let hit: (range: NSRange, items: [CitationItem])
        if let number = Int(reference) {
            guard matches.indices.contains(number - 1) else { throw RPCError.notFound("Beleg \(number) gibt es nicht (\(matches.count) vorhanden).") }
            hit = matches[number - 1]
        } else {
            let found = matches.filter { $0.items.contains { $0.key.caseInsensitiveCompare(reference) == .orderedSame } }
            guard let first = found.first else { throw RPCError.notFound("Einen Beleg „\(reference)“ gibt es hier nicht.") }
            guard found.count == 1 else { throw RPCError.ambiguous("„\(reference)“ ist \(found.count)-mal belegt. Bitte die Nummer aus writer.citations.list nehmen.") }
            hit = first
        }
        var items = hit.items
        // In a citation with several sources, the one named; otherwise its only one.
        let index = items.firstIndex { $0.key.caseInsensitiveCompare(reference) == .orderedSame } ?? 0
        let page = args.page ?? ""
        items[index].locator = page.isEmpty ? "" : CitationMarkup.locator(page)
        return ((markdown as NSString).replacingCharacters(in: hit.range, with: CitationMarkup.markdown(items)), nil)
    }
}
