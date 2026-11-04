import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerCitationActions() {
        register(CitationSearchAction.self)
        register(CitationSourceListAction.self)
        register(CitationSourceReadAction.self)
        register(CitationSourceLookupAction.self)
        register(CitationSourceImportAction.self)
        register(CitationSourceCreateAction.self)
        register(CitationSourceUpdateAction.self)
        register(CitationSourceDeleteAction.self)
        register(CitationQuoteListAction.self)
        register(CitationQuoteReadAction.self)
        register(CitationQuoteAddAction.self)
        register(CitationQuoteUpdateAction.self)
        register(CitationQuoteDeleteAction.self)
        register(CitationFormatInTextAction.self)
        register(CitationFormatReferenceAction.self)
        register(CitationFormatBibliographyAction.self)
        register(WriterCitationInsertAction.self)
        register(WriterQuoteInsertAction.self)
        register(WriterBibliographyInsertAction.self)
        registerCitationAttachmentActions()
        registerCitationStudioActions()
    }
}

extension AppModel {
    /// A source by citekey (readable, for agents) or id.
    func actionSource(_ reference: String) throws -> CitationSource {
        citations.loadIfNeeded()
        if let source = citations.source(citekey: reference) { return source }
        if let id = UUID(uuidString: reference), let source = citations.source(id) { return source }
        throw RPCError.notFound("Quelle „\(reference)“ gibt es nicht. citation.search findet Quellen.")
    }

    func actionQuote(_ reference: String) throws -> CitationQuote {
        citations.loadIfNeeded()
        guard let id = UUID(uuidString: reference), let quote = citations.quote(id) else { throw RPCError.notFound("Baustein \(reference) gibt es nicht.") }
        return quote
    }
}

/// A source's data as it goes out. Abstracts and notes of imports may hold anything; so these actions count as foreign.
struct SourceInfo: Encodable, Sendable {
    var id: String
    var citekey: String
    var type: String
    var short: String
    var title: String
    var authors: [String]
    var editors: [String]?
    var year: Int?
    var container: String?
    var publisher: String?
    var pages: String?
    var doi: String?
    var isbn: String?
    var url: String?
    var abstract: String?
    var notes: String?
    var tags: [String]?
    var attachments: [String]?

    init(_ source: CitationSource, full: Bool) {
        id = source.id.uuidString
        citekey = source.citekey
        type = source.type.rawValue
        short = "\(source.shortAuthors) (\(source.yearText))"
        title = source.fullTitle
        authors = source.authors.map(\.family)
        year = source.year
        guard full else { return }
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        editors = source.editors.isEmpty ? nil : source.editors.map(\.family)
        container = text(source.container)
        publisher = text(source.publisher)
        pages = text(source.pages)
        doi = text(source.doi)
        isbn = text(source.isbn)
        url = text(source.url)
        abstract = text(source.abstract)
        notes = text(source.notes)
        tags = source.tags.isEmpty ? nil : source.tags
        attachments = source.attachments.isEmpty ? nil : source.attachments.map(\.fileName)
    }
}

struct QuoteInfo: Encodable, Sendable {
    var id: String
    var source: String
    var exactText: String
    var paraphrase: String
    var page: String
    var tags: [String]
    var linked: [String]

    @MainActor init(_ quote: CitationQuote, library: CitationLibrary) {
        id = quote.id.uuidString
        source = library.source(quote.sourceID)?.citekey ?? ""
        exactText = quote.exactText
        paraphrase = quote.paraphrase
        page = quote.page
        tags = quote.tags
        linked = quote.linkedQuoteIDs.map(\.uuidString)
    }
}

struct CitationSearchAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String
        var shelf: String?
        var limit: Int?
    }
    struct Output: Encodable, Sendable {
        var sources: [SourceInfo]?
        var quotes: [QuoteInfo]?
    }
    static let descriptor = ActionDescriptor(
        id: "citation.search", summary: "Sucht in Quellen und Bausteinen: müller #lernen @kahneman 2010-2020 typ:buch", kind: .read, security: .foreignRead,
        input: .object(["query": .string("Suchsyntax: Wörter, #Schlagwort, @Autor, Jahr, typ:"), "shelf": .choice(["sources", "quotes", "both"], "Standard: both"), "limit": .integer("Höchstens so viele je Regal", minimum: 1)], required: ["query"]),
        output: .freeObject(), example: "llmd citation search '#lernen @kahneman'", groups: ["core", "citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let result = library.search(args.query)
        let limit = args.limit ?? 50
        let shelf = args.shelf ?? "both"
        return Output(
            sources: shelf == "quotes" ? nil : result.sourceIDs.prefix(limit).compactMap { library.source($0).map { SourceInfo($0, full: false) } },
            quotes: shelf == "sources" ? nil : result.quoteIDs.prefix(limit).compactMap { library.quote($0).map { QuoteInfo($0, library: library) } }
        )
    }
}

struct CitationSourceListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var tag: String?
        var type: String?
    }
    struct Output: Encodable, Sendable {
        var sources: [SourceInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.list", summary: "Listet Quellen kurz", kind: .read, security: .foreignRead,
        input: .object(["tag": .string("Nur mit diesem Schlagwort"), "type": .choice(SourceType.allCases.map(\.rawValue), "Nur dieser Typ")]),
        output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        context.app.citations.loadIfNeeded()
        return Output(sources: context.app.citations.sources
            .filter { (args.tag == nil || $0.tags.contains(args.tag!)) && (args.type == nil || $0.type.rawValue == args.type) }
            .map { SourceInfo($0, full: false) })
    }
}

struct CitationSourceRefArgs: Decodable, Sendable {
    var source: String
}

private let sourceProperty: [String: JSONSchema] = ["source": .string("Quelle (Zitierschlüssel oder ID)")]

struct CitationSourceReadAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var source: SourceInfo
        var quotes: [QuoteInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.read", summary: "Liest eine Quelle mit allen Feldern und Bausteinen", kind: .read, security: .foreignRead,
        input: .object(sourceProperty, required: ["source"]), output: .freeObject(), example: "llmd citation source read mueller2020", groups: ["core", "citation.core"]
    )
    static func run(_ args: CitationSourceRefArgs, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        let library = context.app.citations
        return Output(source: SourceInfo(source, full: true), quotes: library.quotes(of: source.id).map { QuoteInfo($0, library: library) })
    }
}

/// A DOI, ISBN or arXiv id goes to a known service; a web address goes wherever it says. Both leave the app.
@MainActor
private func identifierPreflight(_ text: String, context: ActionContext) throws -> ActionPreflight {
    guard let identifier = CitationIdentifier.detect(text) else {
        throw RPCError.invalidParams("„\(text)“ ist weder DOI noch ISBN, arXiv-ID oder Web-Adresse.")
    }
    var check = ActionPreflight(target: text)
    if case .url = identifier {} else { check.isInSafePlace = true }
    // The record comes back from a service on the net.
    check.readsUntrusted = true
    return check
}

struct CitationSourceLookupAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var identifier: String
    }
    struct Output: Encodable, Sendable {
        var source: SourceInfo
        var duplicates: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.lookup", summary: "Holt Metadaten zu DOI, ISBN, arXiv oder Adresse, ohne anzulegen", kind: .destructive, security: .outbound,
        input: .object(["identifier": .string("DOI, ISBN, arXiv-ID oder URL")], required: ["identifier"]), output: .freeObject(), groups: ["citation.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try identifierPreflight(args.identifier, context: context)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let identifier = CitationIdentifier.detect(args.identifier) else { throw RPCError.invalidParams("Keine gültige Kennung.") }
        let found = try await CitationLookup.lookup(identifier)
        return Output(source: SourceInfo(found, full: true), duplicates: context.app.citations.duplicates(of: found).compactMap { context.app.citations.source($0.sourceID)?.citekey })
    }
}

struct CitationSourceImportAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var identifier: String
        var allowDuplicate: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var citekey: String
        var title: String
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.import", summary: "Legt eine Quelle aus DOI, ISBN, arXiv oder Adresse an", kind: .destructive, security: .outbound,
        input: .object(["identifier": .string("DOI, ISBN, arXiv-ID oder URL"), "allowDuplicate": .boolean("Auch bei möglicher Dublette anlegen")], required: ["identifier"]),
        output: .freeObject(), example: "llmd citation source import 10.1000/xyz", groups: ["core", "citation.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try identifierPreflight(args.identifier, context: context)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let identifier = CitationIdentifier.detect(args.identifier) else { throw RPCError.invalidParams("Keine gültige Kennung.") }
        let library = context.app.citations
        library.loadIfNeeded()
        let found = try await CitationLookup.lookup(identifier)
        return try add(found, allowDuplicate: args.allowDuplicate == true, context: context)
    }

    static func add(_ source: CitationSource, allowDuplicate: Bool, context: ActionContext) throws -> Output {
        let library = context.app.citations
        if !allowDuplicate, let duplicate = library.duplicates(of: source).first, let key = library.source(duplicate.sourceID)?.citekey {
            throw RPCError.ambiguous("Die Quelle gibt es vermutlich schon: \(key). Mit allowDuplicate trotzdem anlegen.", candidates: [key])
        }
        let added = library.addSource(source)
        context.undoGroup.add(UndoStep(label: "Quelle anlegen", undo: { [weak library] in library?.deleteSource(added.id) }, redo: { [weak library] in library?.addSource(added) }))
        return Output(id: added.id.uuidString, citekey: added.citekey, title: added.fullTitle)
    }
}

/// The fields a source can be given by hand.
struct SourceFields: Decodable, Sendable {
    var type: String?
    var title: String?
    var subtitle: String?
    var authors: [String]?
    var editors: [String]?
    var year: Int?
    var container: String?
    var publisher: String?
    var place: String?
    var pages: String?
    var doi: String?
    var isbn: String?
    var url: String?
    var abstract: String?
    var notes: String?
    var tags: [String]?

    static let schema: [String: JSONSchema] = [
        "type": .choice(SourceType.allCases.map(\.rawValue), "Typ der Quelle"),
        "title": .string("Titel"), "subtitle": .string("Untertitel"),
        "authors": .array(of: .string(), "Autor:innen als „Nachname, Vorname“"),
        "editors": .array(of: .string(), "Herausgeber:innen als „Nachname, Vorname“"),
        "year": .integer("Jahr"), "container": .string("Zeitschrift, Sammelband oder Website"), "publisher": .string("Verlag oder Institution"),
        "place": .string("Verlagsort"), "pages": .string("Seiten"), "doi": .string("DOI"), "isbn": .string("ISBN"), "url": .string("Adresse"),
        "abstract": .string("Zusammenfassung"), "notes": .string("Notizen"), "tags": .array(of: .string(), "Schlagworte"),
    ]

    static func person(_ text: String) -> PersonName {
        let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? PersonName(family: parts[0], given: parts[1]) : PersonName(family: text.trimmingCharacters(in: .whitespaces))
    }

    func apply(to source: inout CitationSource) {
        if let type { source.type = SourceType(rawValue: type) ?? source.type }
        if let title { source.title = title }
        if let subtitle { source.subtitle = subtitle }
        if let authors { source.authors = authors.map(Self.person) }
        if let editors { source.editors = editors.map(Self.person) }
        if let year { source.year = year }
        if let container { source.container = container }
        if let publisher { source.publisher = publisher }
        if let place { source.place = place }
        if let pages { source.pages = pages }
        if let doi { source.doi = doi }
        if let isbn { source.isbn = isbn }
        if let url { source.url = url }
        if let abstract { source.abstract = abstract }
        if let notes { source.notes = notes }
        if let tags { source.tags = tags }
    }
}

struct CitationSourceCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var fields: SourceFields
        var citekey: String?
        var allowDuplicate: Bool?
        init(from decoder: Decoder) throws {
            fields = try SourceFields(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            citekey = try container.decodeIfPresent(String.self, forKey: .citekey)
            allowDuplicate = try container.decodeIfPresent(Bool.self, forKey: .allowDuplicate)
        }
        enum Keys: String, CodingKey { case citekey, allowDuplicate }
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.create", summary: "Legt eine Quelle von Hand an", kind: .write, security: .localWrite,
        input: .object(SourceFields.schema.merging(["citekey": .string("Zitierschlüssel; sonst vorgeschlagen"), "allowDuplicate": .boolean("Auch bei möglicher Dublette anlegen")]) { _, new in new }, required: ["title"]),
        output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> CitationSourceImportAction.Output {
        context.app.citations.loadIfNeeded()
        var source = CitationSource()
        args.fields.apply(to: &source)
        if let key = args.citekey { source.citekey = key }
        return try CitationSourceImportAction.add(source, allowDuplicate: args.allowDuplicate == true, context: context)
    }
}

struct CitationSourceUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String
        var fields: SourceFields
        init(from decoder: Decoder) throws {
            fields = try SourceFields(from: decoder)
            source = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .source)
        }
        enum Keys: String, CodingKey { case source }
    }
    static let descriptor = ActionDescriptor(
        id: "citation.source.update", summary: "Ändert Felder einer Quelle", kind: .write, security: .localWrite,
        input: .object(SourceFields.schema.merging(sourceProperty) { _, new in new }, required: ["source"]), output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let before = try context.app.actionSource(args.source)
        let library = context.app.citations
        library.updateSource(before.id) { args.fields.apply(to: &$0) }
        if let after = library.source(before.id) {
            context.undoGroup.add(UndoStep(label: "Quelle ändern", undo: { [weak library] in library?.updateSource(before.id) { $0 = before } }, redo: { [weak library] in library?.updateSource(before.id) { $0 = after } }))
        }
        return OKOutput(id: before.id.uuidString)
    }
}

struct CitationSourceDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "citation.source.delete", summary: "Löscht eine Quelle mit ihren Bausteinen", kind: .destructive, security: .destructive,
        input: .object(sourceProperty, required: ["source"]), output: .freeObject()
    )
    static func preflight(_ args: CitationSourceRefArgs, context: ActionContext) throws -> ActionPreflight {
        let source = try context.app.actionSource(args.source)
        return ActionPreflight(target: source.citekey, detail: source.fullTitle)
    }
    static func run(_ args: CitationSourceRefArgs, context: ActionContext) async throws -> OKOutput {
        let source = try context.app.actionSource(args.source)
        context.app.citations.deleteSource(source.id)
        return OKOutput(id: source.id.uuidString)
    }
}

struct CitationQuoteListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String?
        var tag: String?
    }
    struct Output: Encodable, Sendable {
        var quotes: [QuoteInfo]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.quote.list", summary: "Listet Bausteine", kind: .read, security: .foreignRead,
        input: .object(["source": .string("Nur von dieser Quelle"), "tag": .string("Nur mit diesem Schlagwort")]), output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let source = try args.source.map { try context.app.actionSource($0).id }
        return Output(quotes: library.quotes
            .filter { (source == nil || $0.sourceID == source) && (args.tag == nil || $0.tags.contains(args.tag!)) }
            .map { QuoteInfo($0, library: library) })
    }
}

struct CitationQuoteRefArgs: Decodable, Sendable {
    var quote: String
}

private let quoteProperty: [String: JSONSchema] = ["quote": .string("Baustein (ID)")]

struct CitationQuoteReadAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "citation.quote.read", summary: "Liest einen Baustein", kind: .read, security: .foreignRead,
        input: .object(quoteProperty, required: ["quote"]), output: .freeObject(), groups: ["core", "citation.core"]
    )
    static func run(_ args: CitationQuoteRefArgs, context: ActionContext) async throws -> QuoteInfo {
        QuoteInfo(try context.app.actionQuote(args.quote), library: context.app.citations)
    }
}

struct CitationQuoteAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var source: String
        var exactText: String?
        var paraphrase: String?
        var page: String?
        var tags: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "citation.quote.add", summary: "Legt einen Baustein an: wörtlich, Paraphrase, Fundstelle", kind: .write, security: .localWrite,
        input: .object(sourceProperty.merging(["exactText": .string("Wörtlicher Text"), "paraphrase": .string("Paraphrase oder eigener Gedanke"), "page": .string("Seite oder Fundstelle"), "tags": .array(of: .string(), "Schlagworte")]) { _, new in new }, required: ["source"]),
        output: .freeObject(), example: "llmd citation quote add mueller2020 --exact-text '…' --page 12", groups: ["core", "citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let source = try context.app.actionSource(args.source)
        guard args.exactText?.isEmpty == false || args.paraphrase?.isEmpty == false else {
            throw RPCError.invalidParams("Bitte exactText oder paraphrase angeben.")
        }
        var quote = CitationQuote(sourceID: source.id)
        quote.exactText = args.exactText ?? ""
        quote.paraphrase = args.paraphrase ?? ""
        quote.page = args.page ?? ""
        quote.tags = args.tags ?? []
        let library = context.app.citations
        guard let added = library.addQuote(quote) else { throw RPCError.internal("Der Baustein wurde nicht angelegt.") }
        context.undoGroup.add(UndoStep(label: "Baustein anlegen", undo: { [weak library] in library?.deleteQuote(added.id) }, redo: { [weak library] in library?.addQuote(added) }))
        return OKOutput(id: added.id.uuidString)
    }
}

struct CitationQuoteUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var quote: String
        var exactText: String?
        var paraphrase: String?
        var page: String?
        var tags: [String]?
    }
    static let descriptor = ActionDescriptor(
        id: "citation.quote.update", summary: "Ändert einen Baustein", kind: .write, security: .localWrite,
        input: .object(quoteProperty.merging(["exactText": .string("Wörtlicher Text"), "paraphrase": .string("Paraphrase"), "page": .string("Fundstelle"), "tags": .array(of: .string(), "Schlagworte")]) { _, new in new }, required: ["quote"]),
        output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let before = try context.app.actionQuote(args.quote)
        let library = context.app.citations
        library.updateQuote(before.id) { quote in
            if let text = args.exactText { quote.exactText = text }
            if let text = args.paraphrase { quote.paraphrase = text }
            if let text = args.page { quote.page = text }
            if let tags = args.tags { quote.tags = tags }
        }
        if let after = library.quote(before.id) {
            context.undoGroup.add(UndoStep(label: "Baustein ändern", undo: { [weak library] in library?.updateQuote(before.id) { $0 = before } }, redo: { [weak library] in library?.updateQuote(before.id) { $0 = after } }))
        }
        return OKOutput(id: before.id.uuidString)
    }
}

struct CitationQuoteDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "citation.quote.delete", summary: "Löscht einen Baustein", kind: .destructive, security: .destructive,
        input: .object(quoteProperty, required: ["quote"]), output: .freeObject()
    )
    static func run(_ args: CitationQuoteRefArgs, context: ActionContext) async throws -> OKOutput {
        let quote = try context.app.actionQuote(args.quote)
        context.app.citations.deleteQuote(quote.id)
        return OKOutput(id: quote.id.uuidString)
    }
}

struct CitationFormatInTextAction: LLMDAction {
    struct Item: Decodable, Sendable {
        var key: String
        var page: String?
    }
    struct Args: Decodable, Sendable {
        var items: [Item]
    }
    struct Output: Encodable, Sendable {
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "citation.format.inText", summary: "Formatiert einen Textbeleg nach APA 7", kind: .read, security: .plainRead,
        input: .object(["items": .array(of: .object(["key": .string("Zitierschlüssel"), "page": .string("Seite")], required: ["key"]), "Die Belege")], required: ["items"]),
        output: .freeObject(), example: #"llmd citation format in-text --items '[{"key":"mueller2020","page":"12"}]'"#, groups: ["core", "citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        for item in args.items where library.source(citekey: item.key) == nil { throw RPCError.notFound("Quelle „\(item.key)“ gibt es nicht.") }
        let style = CitationStyle(sources: library.sources, cited: args.items.map(\.key))
        return Output(text: style.inText(args.items.map { CitationItem(key: $0.key, locator: $0.page.map(CitationMarkup.locator) ?? "") }))
    }
}

struct CitationFormatReferenceAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var text: String
    }
    static let descriptor = ActionDescriptor(
        id: "citation.format.reference", summary: "Formatiert eine Literaturangabe nach APA 7", kind: .read, security: .foreignRead,
        input: .object(sourceProperty, required: ["source"]), output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: CitationSourceRefArgs, context: ActionContext) async throws -> Output {
        let source = try context.app.actionSource(args.source)
        return Output(text: CitationStyle(sources: context.app.citations.sources, cited: [source.citekey]).reference(source).markdown)
    }
}

struct CitationFormatBibliographyAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var keys: [String]?
        var doc: String?
    }
    struct Output: Encodable, Sendable {
        var entries: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "citation.format.bibliography", summary: "Erstellt ein sortiertes Literaturverzeichnis", kind: .read, security: .foreignRead,
        input: .object(["keys": .array(of: .string(), "Zitierschlüssel"), "doc": .string("Alles, was dieses Dokument zitiert")]), output: .freeObject(), groups: ["citation.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.citations
        library.loadIfNeeded()
        let keys: [String]
        if let keyList = args.keys {
            keys = keyList
        } else if let doc = args.doc {
            keys = CitationMarkup.keys(in: try context.app.actionAnyDocument(doc).markdown)
        } else {
            throw RPCError.invalidParams("Bitte keys oder doc angeben.")
        }
        let style = CitationStyle(sources: library.sources, cited: keys)
        return Output(entries: style.bibliography(keys).map(\.text.markdown))
    }
}

// MARK: Into documents

struct WriterCitationInsertAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var key: String
        var page: String?
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            key = try container.decode(String.self, forKey: .key)
            page = try container.decodeIfPresent(String.self, forKey: .page)
        }
        enum Keys: String, CodingKey { case key, page }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.citation.insert", summary: "Fügt einen Beleg ein: hinter der Stelle oder am Textende", kind: .write, security: .localWrite,
        input: .object(WriterEditArgs.properties(["key": .string("Zitierschlüssel"), "page": .string("Seite")]), required: ["key"]),
        output: .freeObject(), example: "llmd writer citation insert --doc X --match Satzende --key mueller2020 --page 12", groups: ["core", "writer.core", "citation.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let source = try context.app.actionSource(args.key)
        let mark = CitationMarkup.markdown([CitationItem(key: source.citekey, locator: args.page.map(CitationMarkup.locator) ?? "")])
        return try insertInline(mark, address: args.address, markdown: markdown)
    }
}

/// Text behind the address, or as the end of the last paragraph without one. Works on the source, because a citation
/// is Markdown syntax that attributed text only knows as an attachment.
@MainActor
func insertInline(_ text: String, address: WriterAddress, markdown: String) throws -> String {
    var blocks = BlockEditor(markdown: markdown)
    guard !address.isEmpty else {
        guard let last = blocks.blocks.indices.last else { return text + "\n" }
        blocks.blocks[last] += " " + text
        return blocks.markdown
    }
    switch try WriterAddressing.resolve(address, in: markdown) {
    case .whole:
        return try insertInline(text, address: WriterAddress(), markdown: markdown)
    case .blocks(let range):
        blocks.blocks[range.upperBound - 1] += " " + text
        return blocks.markdown
    case .text(let block, let range):
        blocks.edit(block) { attributed in
            let marks = attributed.attributes(at: max(0, min(NSMaxRange(range) - 1, attributed.length - 1)), effectiveRange: nil)
            let fragment = NSMutableAttributedString(attributedString: WriterMarkdown.inline(" " + text))
            let keep = marks.filter { WriterMarkdown.paragraphKeys.contains($0.key) }
            fragment.addAttributes(keep, range: NSRange(location: 0, length: fragment.length))
            attributed.insert(fragment, at: NSMaxRange(range))
        }
        return blocks.markdown
    case .source(let range):
        var result = markdown
        result.insert(contentsOf: " " + text, at: range.upperBound)
        return result
    }
}

struct WriterQuoteInsertAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        var address: WriterAddress
        var quote: String
        init(from decoder: Decoder) throws {
            target = try WriterTargetArgs(from: decoder)
            address = try WriterAddress(from: decoder)
            quote = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .quote)
        }
        enum Keys: String, CodingKey { case quote }
    }
    typealias Output = WriterWriteResult
    /// From 40 words on APA sets a block quote without quotation marks.
    static let blockQuoteWords = 40
    static let descriptor = ActionDescriptor(
        id: "writer.quote.insert", summary: "Fügt ein wörtliches Zitat mit Beleg ein", kind: .write, security: .foreignRead.asWrite,
        input: .object(WriterEditArgs.properties(["quote": .string("Baustein (ID)")]), required: ["quote"]), output: .freeObject(), groups: ["writer.core", "citation.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        let quote = try context.app.actionQuote(args.quote)
        guard let source = context.app.citations.source(quote.sourceID) else { throw RPCError.notFound("Die Quelle des Bausteins fehlt.") }
        let exact = quote.exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty else { throw RPCError.invalidTarget("Dieser Baustein hat keinen wörtlichen Text.") }
        let mark = CitationMarkup.markdown([CitationItem(key: source.citekey, locator: quote.locator)])
        if exact.split(whereSeparator: \.isWhitespace).count >= blockQuoteWords {
            let line = "> " + WriterMarkdown.escape(exact.replacingOccurrences(of: "\n", with: " "), atLineStart: false) + " " + mark
            return PowerText.inserting(line, at: .max, into: markdown)
        }
        return try insertInline("„\(WriterMarkdown.escape(exact, atLineStart: false))“ \(mark)", address: args.address, markdown: markdown)
    }
}

extension ActionSecurity {
    /// A write whose content comes from a foreign source.
    var asWrite: ActionSecurity { ActionSecurity(readsUntrusted: readsUntrusted, sensitive: sensitive, effect: .local) }
}

struct WriterBibliographyInsertAction: WriterEditAction {
    struct Args: Decodable, Sendable {
        var target: WriterTargetArgs
        init(from decoder: Decoder) throws { target = try WriterTargetArgs(from: decoder) }
    }
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.bibliography.insert", summary: "Fügt das Literaturverzeichnis (APA 7) ein", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties), output: .freeObject(), groups: ["core", "writer.core", "citation.core"]
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func edit(_ args: Args, markdown: String, context: ActionContext) throws -> String {
        guard !markdown.components(separatedBy: "\n").contains(where: WriterBibliographyAttachment.isMarker) else {
            throw RPCError.invalidTarget("Das Dokument hat schon ein Literaturverzeichnis.")
        }
        return PowerText.inserting(WriterBibliographyAttachment.marker, at: .max, into: markdown)
    }
}
