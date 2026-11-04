import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerCitationMoreActions() {
        register(CitationQuoteLinkedAction.self)
        register(CitationTagsListAction.self)
        register(CitationCollectionsListAction.self)
        register(CitationDuplicatesCheckAction.self)
        register(CitationUsagesAction.self)
        register(CitationSourceSetCitekeyAction.self)
        register(CitationSourceSuggestCitekeyAction.self)
        register(CitationSourceTagAction.self)
        register(CitationSourceMoveAction.self)
        register(CitationSourceMergeAction.self)
        register(CitationQuoteTagAction.self)
        register(CitationQuoteLinkAction.self)
        register(CitationQuoteUnlinkAction.self)
        register(CitationQuoteMoveAction.self)
        register(CitationGroupAddAction.self)
        register(CitationGroupRenameAction.self)
        register(CitationGroupDeleteAction.self)
        register(CitationFolderAddAction.self)
        register(CitationFolderRenameAction.self)
        register(CitationFolderMoveAction.self)
        register(CitationFolderDeleteAction.self)
        register(CitationExportBibtexAction.self)
        register(CitationExportCslAction.self)
        register(CitationImportBibtexAction.self)
    }
}

private let sourceReference: JSONSchema = .string("Quelle (Zitierschlüssel oder ID)")
private let quoteReference: JSONSchema = .string("Baustein (ID)")
private let groupReference: JSONSchema = .string("Gruppe (ID oder Name)")
private let folderReference: JSONSchema = .string("Ordner (ID oder Name)")
private let shelfChoice: JSONSchema = .choice(["sources", "quotes"], "Regal")

extension AppModel {
    func actionCitationFolder(_ reference: String, shelf: CitationShelf?) throws -> CitationFolder {
        citations.loadIfNeeded()
        let groups = shelf.map { [$0] } ?? [.sources, .quotes]
        let all = groups.flatMap { citations.groups($0) }.flatMap { citations.folders(in: $0.id) }
        if let id = UUID(uuidString: reference), let folder = all.first(where: { $0.id == id }) { return folder }
        let named = all.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw RPCError.notFound("Den Ordner „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Ordner heißen „\(reference)“.", candidates: named.map(\.id.uuidString))
    }

    func actionCitationGroup(_ reference: String, shelf: CitationShelf?) throws -> CitationGroup {
        citations.loadIfNeeded()
        let all = (shelf.map { [$0] } ?? [.sources, .quotes]).flatMap { citations.groups($0) }
        if let id = UUID(uuidString: reference), let group = all.first(where: { $0.id == id }) { return group }
        let named = all.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw RPCError.notFound("Die Gruppe „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Gruppen heißen „\(reference)“.", candidates: named.map(\.id.uuidString))
    }

    /// The documents and presentations that cite a key, with how many citations there are.
    func citationUses(of key: String) -> [(document: WriterDocument, count: Int)] {
        documents.compactMap { document in
            let texts = document.deck.map { $0.slides.flatMap { [$0.markdown, $0.notes] + $0.images.compactMap(\.text) } } ?? [document.markdown]
            let count = texts.reduce(0) { $0 + WriterCitationText.count(of: key, in: $1) }
            return count > 0 ? (document, count) : nil
        }
    }
}

/// Citations by key in a text. The same pattern reads them everywhere (`CitationMarkup.keys`).
enum WriterCitationText {
    private static let expression = try? NSRegularExpression(pattern: #"(?<!\\)\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()"#)

    static func count(of key: String, in markdown: String) -> Int {
        guard markdown.contains("@"), let expression else { return 0 }
        let text = markdown as NSString
        return expression.matches(in: markdown, range: NSRange(location: 0, length: text.length)).reduce(0) { sum, match in
            sum + (CitationMarkup.parse(text.substring(with: match.range(at: 1)))?.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.count ?? 0)
        }
    }

    /// The text with one key replaced by another in all citations.
    static func replacing(_ key: String, with new: String, in markdown: String) -> String {
        guard markdown.contains("@"), let expression else { return markdown }
        var result = markdown as NSString
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: result.length)).reversed() {
            guard var items = CitationMarkup.parse(result.substring(with: match.range(at: 1))),
                  items.contains(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { continue }
            for index in items.indices where items[index].key.caseInsensitiveCompare(key) == .orderedSame { items[index].key = new }
            result = result.replacingCharacters(in: match.range, with: CitationMarkup.markdown(items)) as NSString
        }
        return result as String
    }
}

struct CitationQuoteChangeArgs: Decodable, Sendable {
    var quote: String
    var with: String?
    var from: String?
    var add: [String]?
    var remove: [String]?
    var folder: String?
}

struct CitationSourceChangeArgs: Decodable, Sendable {
    var source: String
    var key: String?
    var add: [String]?
    var remove: [String]?
    var folder: String?
}

/// A source's change with its way back.
@MainActor
private func changeSource(_ id: UUID, context: ActionContext, label: String, _ change: (inout CitationSource) -> Void) {
    let library = context.app.citations
    guard let before = library.source(id) else { return }
    library.updateSource(id, change)
    guard let after = library.source(id), after != before else { return }
    context.undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.updateSource(id) { $0 = before } }, redo: { [weak library] in library?.updateSource(id) { $0 = after } }))
}

@MainActor
private func changeQuote(_ id: UUID, context: ActionContext, label: String, _ change: (inout CitationQuote) -> Void) {
    let library = context.app.citations
    guard let before = library.quote(id) else { return }
    library.updateQuote(id, change)
    guard let after = library.quote(id), after != before else { return }
    context.undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.updateQuote(id) { $0 = before } }, redo: { [weak library] in library?.updateQuote(id) { $0 = after } }))
}

private func tags(_ current: [String], add: [String]?, remove: [String]?) -> [String] {
    var result = current
    for tag in add ?? [] where !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { result.append(tag) }
    let gone = remove ?? []
    return result.filter { tag in !gone.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
}

// MARK: Reading

struct CitationQuoteLinkedAction: LLMDAction {
    typealias Args = CitationQuoteChangeArgs
    struct Output: Encodable, Sendable {
        var quotes: [QuoteInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.quote.linked", summary: "Listet die mit einem Baustein verknüpften Bausteine", kind: .read, security: .foreignRead,
        input: .object(["quote": quoteReference], required: ["quote"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let quote = try context.app.actionQuote(args.quote)
        return Output(quotes: quote.linkedQuoteIDs.compactMap { library.quote($0) }.map { QuoteInfo($0, library: library) })
    }
}

struct CitationTagsListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var shelf: String?
    }
    struct Item: Encodable, Sendable {
        var tag: String
        var count: Int
    }
    struct Output: Encodable, Sendable {
        var tags: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.tags.list", summary: "Listet die Schlagworte mit ihrer Häufigkeit", kind: .read, security: .foreignRead,
        input: .object(["shelf": .choice(["sources", "quotes", "both"], "Standard: both")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        guard let shelf = args.shelf, shelf != "both" else { return Output(tags: library.allTags.map { Item(tag: $0.tag, count: $0.count) }) }
        let all = shelf == "sources" ? library.sources.flatMap(\.tags) : library.quotes.flatMap(\.tags)
        var counts: [String: Int] = [:]
        for tag in all { counts[tag, default: 0] += 1 }
        return Output(tags: counts.map { Item(tag: $0.key, count: $0.value) }.sorted { ($0.count, $1.tag) > ($1.count, $0.tag) })
    }
}

struct CitationCollectionsListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var shelf: String
    }
    struct Folder: Encodable, Sendable {
        var id: String
        var name: String
    }
    struct Group: Encodable, Sendable {
        var id: String
        var name: String
        var folders: [Folder]
    }
    struct Output: Encodable, Sendable {
        var groups: [Group]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.collections.list", summary: "Listet Gruppen und Ordner eines Regals", kind: .read, security: .plainRead,
        input: .object(["shelf": shelfChoice], required: ["shelf"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let shelf = CitationShelf(rawValue: args.shelf) ?? .sources
        return Output(groups: library.groups(shelf).map { group in
            Group(id: group.id.uuidString, name: group.name, folders: library.folders(in: group.id).map { Folder(id: $0.id.uuidString, name: $0.name) })
        })
    }
}

struct CitationDuplicatesCheckAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var fields: SourceFields
        var identifier: String?
        init(from decoder: Decoder) throws {
            fields = try SourceFields(from: decoder)
            identifier = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .identifier)
        }
        enum Keys: String, CodingKey { case identifier }
    }
    struct Item: Encodable, Sendable {
        var citekey: String
        var title: String
        var reason: String
    }
    struct Output: Encodable, Sendable {
        var duplicates: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.duplicates.check", summary: "Sucht mögliche Dubletten zu Angaben oder einer Kennung, ohne Netz und ohne etwas anzulegen", kind: .read, security: .foreignRead,
        input: .object(SourceFields.schema.merging(["identifier": .string("DOI, ISBN, arXiv-ID oder Adresse")]) { _, new in new }), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var candidate = CitationSource()
        args.fields.apply(to: &candidate)
        if let identifier = args.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if identifier.lowercased().hasPrefix("http") {
                candidate.url = identifier
            } else if identifier.lowercased().hasPrefix("arxiv:") {
                candidate.arxiv = String(identifier.dropFirst(6))
            } else if identifier.hasPrefix("10.") {
                candidate.doi = identifier
            } else {
                candidate.isbn = identifier
            }
        }
        let library = context.app.citations
        return Output(duplicates: library.duplicates(of: candidate).compactMap { duplicate in
            library.source(duplicate.sourceID).map { Item(citekey: $0.citekey, title: $0.fullTitle, reason: duplicate.reasons.map(\.label).joined(separator: ", ")) }
        })
    }
}

struct CitationUsagesAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var isPresentation: Bool
        var citations: Int
    }
    struct Output: Encodable, Sendable {
        var usages: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.usages", summary: "Listet die Dokumente und Präsentationen, die eine Quelle zitieren", kind: .read, security: .plainRead,
        input: .object(["source": sourceReference], required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        return Output(usages: context.app.citationUses(of: source.citekey).map {
            Item(id: $0.document.id.uuidString, title: $0.document.displayTitle, isPresentation: $0.document.isPresentation, citations: $0.count)
        })
    }
}

// MARK: Sources

struct CitationSourceSetCitekeyAction: LLMDAction {
    typealias Args = CitationSourceChangeArgs
    struct Output: Encodable, Sendable {
        var citekey: String
        /// Texts that still cite the old key: the citations stay as written, as in the studio.
        var citedIn: Int
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.setCitekey", summary: "Ändert den Zitierschlüssel einer Quelle; bestehende Belege in Texten ändern sich nicht", kind: .write, security: .localWrite,
        input: .object(["source": sourceReference, "key": .string("Der neue Schlüssel")], required: ["source", "key"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let source = try context.app.actionSource(args.source)
        let uses = context.app.citationUses(of: source.citekey).count
        do {
            try library.setCitekey(args.key ?? "", for: source.id)
        } catch {
            throw RPCError.invalidParams(error.localizedDescription)
        }
        let old = source.citekey
        let id = source.id
        let new = library.source(id)?.citekey ?? old
        context.undoGroup.add(UndoStep(label: "Zitierschlüssel ändern", undo: { [weak library] in try? library?.setCitekey(old, for: id) }, redo: { [weak library] in try? library?.setCitekey(new, for: id) }))
        return Output(citekey: new, citedIn: uses)
    }
}

struct CitationSourceSuggestCitekeyAction: LLMDAction {
    typealias Args = CitationSourceChangeArgs
    struct Output: Encodable, Sendable {
        var citekey: String?
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.suggestCitekey", summary: "Schlägt einen Zitierschlüssel vor, ohne ihn zu setzen", kind: .read, security: .plainRead,
        input: .object(["source": sourceReference], required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        Output(citekey: context.app.citations.suggestedCitekey(for: try context.app.actionSource(args.source).id))
    }
}

struct CitationSourceTagAction: LLMDAction {
    typealias Args = CitationSourceChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.source.tag", summary: "Gibt einer Quelle Schlagworte oder nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(["source": sourceReference, "add": .array(of: .string(), "Hinzu"), "remove": .array(of: .string(), "Weg")], required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        changeSource(source.id, context: context, label: "Schlagworte") { $0.tags = tags($0.tags, add: args.add, remove: args.remove) }
        return OKOutput(id: source.id.uuidString)
    }
}

struct CitationSourceMoveAction: LLMDAction {
    typealias Args = CitationSourceChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.source.move", summary: "Legt eine Quelle in einen Ordner; ohne folder wird sie unsortiert", kind: .write, security: .localWrite,
        input: .object(["source": sourceReference, "folder": folderReference], required: ["source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let source = try context.app.actionSource(args.source)
        let folder = try args.folder.map { try context.app.actionCitationFolder($0, shelf: .sources) }
        let old = source.folderID
        let id = source.id
        library.file(source: id, in: folder?.id)
        context.undoGroup.add(UndoStep(label: "Quelle verschieben", undo: { [weak library] in library?.file(source: id, in: old) }, redo: { [weak library] in library?.file(source: id, in: folder?.id) }))
        return OKOutput(id: id.uuidString)
    }
}

struct CitationSourceMergeAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var keep: String
        var remove: String
    }
    struct Output: Encodable, Sendable {
        var citekey: String
        var movedQuotes: Int
        var changedTexts: Int
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.merge", summary: "Führt eine Dublette zusammen: Felder, Schlagworte, Bausteine und Anhänge wandern, Belege in Texten zeigen auf die bleibende Quelle", kind: .destructive, security: .destructive,
        input: .object(["keep": .string("Die Quelle, die bleibt"), "remove": .string("Die Dublette, die verschwindet")], required: ["keep", "remove"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let keep = try context.app.actionSource(args.keep), gone = try context.app.actionSource(args.remove)
        guard keep.id != gone.id else { throw RPCError.invalidParams("Eine Quelle lässt sich nicht mit sich selbst zusammenführen.") }
        return ActionPreflight(target: gone.citekey + " → " + keep.citekey, detail: gone.fullTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let library = app.citations
        let keep = try app.actionSource(args.keep), gone = try app.actionSource(args.remove)
        guard keep.id != gone.id else { throw RPCError.invalidParams("Eine Quelle lässt sich nicht mit sich selbst zusammenführen.") }
        // What the source that stays doesn't have yet comes from the other; what it has wins.
        library.updateSource(keep.id) { kept in
            func fill(_ path: WritableKeyPath<CitationSource, String>) { if kept[keyPath: path].isEmpty { kept[keyPath: path] = gone[keyPath: path] } }
            for path in [\CitationSource.subtitle, \.date, \.container, \.publisher, \.place, \.edition, \.volume, \.issue, \.pages, \.doi, \.isbn, \.url, \.arxiv, \.language, \.abstract, \.notes] { fill(path) }
            if kept.authors.isEmpty { kept.authors = gone.authors }
            if kept.editors.isEmpty { kept.editors = gone.editors }
            if kept.year == nil { kept.year = gone.year }
            kept.tags = tags(kept.tags, add: gone.tags, remove: nil)
        }
        let quotes = library.quotes(of: gone.id)
        for quote in quotes { library.updateQuote(quote.id) { $0.sourceID = keep.id } }
        for attachment in gone.attachments {
            let url = library.attachmentURL(attachment, of: gone.id)
            if FileManager.default.fileExists(atPath: url.path) { try? library.attach(url, to: keep.id) }
        }
        var changed = 0
        for use in app.citationUses(of: gone.citekey) {
            let before = use.document
            if var deck = before.deck {
                for index in deck.slides.indices {
                    deck.slides[index].markdown = WriterCitationText.replacing(gone.citekey, with: keep.citekey, in: deck.slides[index].markdown)
                    deck.slides[index].notes = WriterCitationText.replacing(gone.citekey, with: keep.citekey, in: deck.slides[index].notes)
                    for image in deck.slides[index].images.indices {
                        if let text = deck.slides[index].images[image].text {
                            deck.slides[index].images[image].text = WriterCitationText.replacing(gone.citekey, with: keep.citekey, in: text)
                        }
                    }
                }
                let updated = deck
                app.modifyDeck(before.id) { $0 = updated; return true }
            } else {
                app.updateDocument(before.id, markdown: WriterCitationText.replacing(gone.citekey, with: keep.citekey, in: before.markdown))
            }
            context.noteChange(of: before.id, before: before)
            changed += 1
        }
        library.deleteSource(gone.id)
        return Output(citekey: keep.citekey, movedQuotes: quotes.count, changedTexts: changed)
    }
}

// MARK: Quotes

struct CitationQuoteTagAction: LLMDAction {
    typealias Args = CitationQuoteChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.quote.tag", summary: "Gibt einem Baustein Schlagworte oder nimmt sie weg", kind: .write, security: .localWrite,
        input: .object(["quote": quoteReference, "add": .array(of: .string(), "Hinzu"), "remove": .array(of: .string(), "Weg")], required: ["quote"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let quote = try context.app.actionQuote(args.quote)
        changeQuote(quote.id, context: context, label: "Schlagworte") { $0.tags = tags($0.tags, add: args.add, remove: args.remove) }
        return OKOutput(id: quote.id.uuidString)
    }
}

struct CitationQuoteLinkAction: LLMDAction {
    typealias Args = CitationQuoteChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.quote.link", summary: "Verknüpft zwei Bausteine", kind: .write, security: .localWrite,
        input: .object(["quote": quoteReference, "with": quoteReference], required: ["quote", "with"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let first = try context.app.actionQuote(args.quote), second = try context.app.actionQuote(args.with ?? "")
        guard first.id != second.id else { throw RPCError.invalidParams("Ein Baustein lässt sich nicht mit sich selbst verknüpfen.") }
        library.link(first.id, second.id)
        context.undoGroup.add(UndoStep(label: "Verknüpfen", undo: { [weak library] in library?.unlink(first.id, second.id) }, redo: { [weak library] in library?.link(first.id, second.id) }))
        return OKOutput(id: first.id.uuidString)
    }
}

struct CitationQuoteUnlinkAction: LLMDAction {
    typealias Args = CitationQuoteChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.quote.unlink", summary: "Löst die Verknüpfung zweier Bausteine", kind: .write, security: .localWrite,
        input: .object(["quote": quoteReference, "from": quoteReference], required: ["quote", "from"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let first = try context.app.actionQuote(args.quote), second = try context.app.actionQuote(args.from ?? "")
        library.unlink(first.id, second.id)
        context.undoGroup.add(UndoStep(label: "Verknüpfung lösen", undo: { [weak library] in library?.link(first.id, second.id) }, redo: { [weak library] in library?.unlink(first.id, second.id) }))
        return OKOutput(id: first.id.uuidString)
    }
}

struct CitationQuoteMoveAction: LLMDAction {
    typealias Args = CitationQuoteChangeArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.quote.move", summary: "Legt einen Baustein in einen Ordner; ohne folder wird er unsortiert", kind: .write, security: .localWrite,
        input: .object(["quote": quoteReference, "folder": folderReference], required: ["quote"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let quote = try context.app.actionQuote(args.quote)
        let folder = try args.folder.map { try context.app.actionCitationFolder($0, shelf: .quotes) }
        let old = quote.folderID
        let id = quote.id
        library.file(quote: id, in: folder?.id)
        context.undoGroup.add(UndoStep(label: "Baustein verschieben", undo: { [weak library] in library?.file(quote: id, in: old) }, redo: { [weak library] in library?.file(quote: id, in: folder?.id) }))
        return OKOutput(id: id.uuidString)
    }
}

// MARK: Groups and folders

struct CitationCollectionArgs: Decodable, Sendable {
    var shelf: String?
    var group: String?
    var folder: String?
    var name: String?
}

struct CitationGroupAddAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.group.add", summary: "Legt eine Gruppe in einem Regal an", kind: .write, security: .localWrite,
        input: .object(["shelf": shelfChoice, "name": .string("Name")], required: ["shelf", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let group = library.addGroup(CitationShelf(rawValue: args.shelf ?? "") ?? .sources, name: args.name ?? "")
        context.undoGroup.add(UndoStep(label: "Gruppe anlegen", undo: { [weak library] in library?.deleteGroup(group.id) }, redo: { [weak library] in _ = library?.addGroup(group.shelf, name: group.name) }))
        return OKOutput(id: group.id.uuidString)
    }
}

struct CitationGroupRenameAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.group.rename", summary: "Benennt eine Gruppe um", kind: .write, security: .localWrite,
        input: .object(["group": groupReference, "name": .string("Neuer Name")], required: ["group", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let group = try context.app.actionCitationGroup(args.group ?? "", shelf: nil)
        let name = args.name ?? ""
        library.renameGroup(group.id, to: name)
        context.undoGroup.add(UndoStep(label: "Gruppe umbenennen", undo: { [weak library] in library?.renameGroup(group.id, to: group.name) }, redo: { [weak library] in library?.renameGroup(group.id, to: name) }))
        return OKOutput(id: group.id.uuidString)
    }
}

struct CitationGroupDeleteAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.group.delete", summary: "Löscht eine Gruppe; ihre Quellen und Bausteine bleiben unsortiert erhalten", kind: .destructive, security: .destructive,
        input: .object(["group": groupReference], required: ["group"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionCitationGroup(args.group ?? "", shelf: nil).name)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let group = try context.app.actionCitationGroup(args.group ?? "", shelf: nil)
        context.app.citations.deleteGroup(group.id)
        return OKOutput(id: group.id.uuidString)
    }
}

struct CitationFolderAddAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.folder.add", summary: "Legt einen Ordner in einer Gruppe an", kind: .write, security: .localWrite,
        input: .object(["group": groupReference, "name": .string("Name")], required: ["group", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let group = try context.app.actionCitationGroup(args.group ?? "", shelf: nil)
        guard let folder = library.addFolder(in: group.id, name: args.name ?? "") else { throw RPCError.internal("Der Ordner ließ sich nicht anlegen.") }
        context.undoGroup.add(UndoStep(label: "Ordner anlegen", undo: { [weak library] in library?.deleteFolder(folder.id) }, redo: { [weak library] in _ = library?.addFolder(in: group.id, name: folder.name) }))
        return OKOutput(id: folder.id.uuidString)
    }
}

struct CitationFolderRenameAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.folder.rename", summary: "Benennt einen Ordner um", kind: .write, security: .localWrite,
        input: .object(["folder": folderReference, "name": .string("Neuer Name")], required: ["folder", "name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let folder = try context.app.actionCitationFolder(args.folder ?? "", shelf: nil)
        let name = args.name ?? ""
        library.renameFolder(folder.id, to: name)
        context.undoGroup.add(UndoStep(label: "Ordner umbenennen", undo: { [weak library] in library?.renameFolder(folder.id, to: folder.name) }, redo: { [weak library] in library?.renameFolder(folder.id, to: name) }))
        return OKOutput(id: folder.id.uuidString)
    }
}

struct CitationFolderMoveAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.folder.move", summary: "Legt einen Ordner in eine andere Gruppe desselben Regals", kind: .write, security: .localWrite,
        input: .object(["folder": folderReference, "group": groupReference], required: ["folder", "group"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        let folder = try context.app.actionCitationFolder(args.folder ?? "", shelf: nil)
        let group = try context.app.actionCitationGroup(args.group ?? "", shelf: folder.shelf)
        library.moveFolder(folder.id, to: group.id)
        context.undoGroup.add(UndoStep(label: "Ordner verschieben", undo: { [weak library] in library?.moveFolder(folder.id, to: folder.groupID) }, redo: { [weak library] in library?.moveFolder(folder.id, to: group.id) }))
        return OKOutput(id: folder.id.uuidString)
    }
}

struct CitationFolderDeleteAction: LLMDAction {
    typealias Args = CitationCollectionArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "citation.folder.delete", summary: "Löscht einen Ordner; sein Inhalt bleibt unsortiert erhalten", kind: .destructive, security: .destructive,
        input: .object(["folder": folderReference], required: ["folder"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionCitationFolder(args.folder ?? "", shelf: nil).name)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let folder = try context.app.actionCitationFolder(args.folder ?? "", shelf: nil)
        context.app.citations.deleteFolder(folder.id)
        return OKOutput(id: folder.id.uuidString)
    }
}

// MARK: Exchange

struct CitationExportArgs: Decodable, Sendable {
    var keys: [String]?
    var folder: String?
    var all: Bool?
    var path: String?
    var overwrite: Bool?

    static let properties: [String: JSONSchema] = [
        "keys": .array(of: .string(), "Zitierschlüssel"), "folder": folderReference, "all": .boolean("Alle Quellen"),
        "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen"),
    ]

    @MainActor
    func sources(app: AppModel) throws -> [CitationSource] {
        app.citations.loadIfNeeded()
        if all == true { return app.citations.sources }
        if let folder {
            let id = try app.actionCitationFolder(folder, shelf: .sources).id
            return app.citations.sources.filter { $0.folderID == id }
        }
        guard let keys, !keys.isEmpty else { throw RPCError.invalidParams("Bitte keys, folder oder all angeben.") }
        return try keys.map { try app.actionSource($0) }
    }

    @MainActor
    func preflight(context: ActionContext) -> ActionPreflight {
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let inFolder = path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        // Abstracts of imports may hold anything.
        return ActionPreflight(readsUntrusted: true, isInSafePlace: inFolder, target: path ?? folder.path)
    }

    @MainActor
    func write(_ text: String, name: String, extension fileExtension: String, context: ActionContext) throws -> WriterExportAction.Output {
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let url = path.map(ActionExportFolder.expanded) ?? ActionExportFolder.freeFile(named: name, extension: fileExtension, in: folder)
        guard path == nil || overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
            throw RPCError.invalidTarget("Die Datei gibt es schon: \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        return WriterExportAction.Output(path: url.path, bytes: data.count)
    }
}

struct CitationExportBibtexAction: LLMDAction {
    typealias Args = CitationExportArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "citation.export.bibtex", summary: "Schreibt Quellen in eine BibTeX-Datei", kind: .destructive, security: .outbound,
        input: .object(Args.properties), output: .freeObject(), example: "llmd citation export bibtex --all true"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { args.preflight(context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try args.write(CitationBibTeX.export(try args.sources(app: context.app)), name: "Literatur", extension: "bib", context: context)
    }
}

struct CitationExportCslAction: LLMDAction {
    typealias Args = CitationExportArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "citation.export.csl", summary: "Schreibt Quellen als CSL-JSON, z. B. für Zotero", kind: .destructive, security: .outbound,
        input: .object(Args.properties), output: .freeObject(), example: "llmd citation export csl --all true"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { args.preflight(context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try args.write(try CitationCSL.export(try args.sources(app: context.app)), name: "Literatur", extension: "json", context: context)
    }
}

struct CitationImportBibtexAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var file: String
        var allowDuplicates: Bool?
    }
    struct Output: Encodable, Sendable {
        var added: [String]
        var duplicates: [String]
        var skipped: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.import.bibtex", summary: "Liest Quellen aus einer BibTeX-Datei; Dubletten bleiben draußen", kind: .write, security: .localWrite,
        input: .object(["file": .string("Pfad der Datei"), "allowDuplicates": .boolean("Auch mögliche Dubletten anlegen")], required: ["file"]),
        output: .freeObject(), example: "llmd citation import bibtex --file ~/literatur.bib"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        // A file from elsewhere: what it says counts as foreign, and only the person names an arbitrary path.
        var check = ActionPreflight(readsUntrusted: true, target: args.file)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Eine Datei von dieser Stelle der Festplatte würde gelesen und ihr Inhalt für den Aufrufer sichtbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let url = ActionExportFolder.expanded(args.file)
        guard let data = try? Data(contentsOf: url) else { throw RPCError.notFound("Die Datei \(url.path) lässt sich nicht lesen.") }
        let parsed = CitationBibTeX.parse(String(decoding: data, as: UTF8.self))
        guard !parsed.sources.isEmpty || !parsed.skipped.isEmpty else { throw RPCError.invalidTarget("In dieser Datei stehen keine BibTeX-Einträge.") }
        var added: [String] = []
        var duplicates: [String] = []
        for source in parsed.sources {
            if args.allowDuplicates != true, !library.duplicates(of: source).isEmpty {
                duplicates.append(source.citekey)
                continue
            }
            let made = library.addSource(source)
            added.append(made.citekey)
            context.undoGroup.add(UndoStep(label: "Quelle importieren", undo: { [weak library] in library?.deleteSource(made.id) }, redo: { [weak library] in library?.addSource(made) }))
        }
        return Output(added: added, duplicates: duplicates, skipped: parsed.skipped)
    }
}
