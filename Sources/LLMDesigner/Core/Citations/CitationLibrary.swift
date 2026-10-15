import Foundation

/// Citation Studio's files in the library: `Zitate/Quellen/<id>.json` holds one source with its quotes (written
/// as one piece, so a source and its quotes never disagree), `Zitate/Anhänge/<id>/` the source's files.
struct CitationStore: Sendable {
    static let formatVersion = 1

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store of the open library.
    static func library() -> CitationStore {
        CitationStore(directory: AppLibrary.current.folder("Zitate"))
    }

    var sourcesDirectory: URL { directory.appendingPathComponent("Quellen", isDirectory: true) }
    var attachmentsDirectory: URL { directory.appendingPathComponent("Anhänge", isDirectory: true) }

    /// What one file holds.
    struct Record: Codable {
        var format = CitationStore.formatVersion
        var source: CitationSource
        var quotes: [CitationQuote]
    }

    func loadAll() -> (sources: [CitationSource], quotes: [CitationQuote]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)) ?? []
        var sources: [CitationSource] = []
        var quotes: [CitationQuote] = []
        for file in files where file.pathExtension == "json" {
            do {
                let record = try Self.decoder.decode(Record.self, from: Data(contentsOf: file))
                sources.append(record.source)
                // A quote always belongs to the source of its file.
                quotes += record.quotes.map { quote in
                    var quote = quote
                    quote.sourceID = record.source.id
                    return quote
                }
            } catch {
                print("LLMDesigner: Quelle \(file.lastPathComponent) konnte nicht gelesen werden: \(error)")
            }
        }
        return (sources, quotes)
    }

    /// Groups and folders of both shelves, in one small file.
    struct Collections: Codable {
        var format = CitationStore.formatVersion
        var groups: [CitationGroup] = []
        var folders: [CitationFolder] = []
    }

    var collectionsURL: URL { directory.appendingPathComponent("Ordner.json") }

    func loadCollections() -> Collections {
        guard let data = try? Data(contentsOf: collectionsURL) else { return Collections() }
        do {
            return try Self.decoder.decode(Collections.self, from: data)
        } catch {
            print("LLMDesigner: Ordner der Zitate konnten nicht gelesen werden: \(error)")
            return Collections()
        }
    }

    func saveCollections(_ collections: Collections) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(collections).write(to: collectionsURL, options: .atomic)
        } catch {
            print("LLMDesigner: Ordner der Zitate konnten nicht gespeichert werden: \(error)")
        }
    }

    func save(_ source: CitationSource, quotes: [CitationQuote]) throws {
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Record(source: source, quotes: quotes))
        try data.write(to: recordURL(for: source.id), options: .atomic)
    }

    /// Removes the source's file; its attachments go to the Trash, so a PDF is never lost by accident.
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: recordURL(for: id))
        let folder = attachmentFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }

    func recordURL(for id: UUID) -> URL {
        sourcesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    func attachmentFolder(for id: UUID) -> URL {
        attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func attachmentURL(_ attachment: CitationAttachment, of id: UUID) -> URL {
        attachmentFolder(for: id).appendingPathComponent(attachment.fileName)
    }

    /// Copies a file into the source's folder (a second file of the same name gets a number).
    func importAttachment(_ url: URL, for id: UUID) throws -> CitationAttachment {
        let folder = attachmentFolder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var name = url.lastPathComponent
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            number += 1
        }
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        return CitationAttachment(fileName: name)
    }

    func removeAttachment(_ attachment: CitationAttachment, of id: UUID) {
        let url = attachmentURL(attachment, of: id)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum CitationError: LocalizedError, Equatable {
    case invalidCitekey(String)
    case citekeyTaken(String)
    case noSource

    var errorDescription: String? {
        switch self {
        case .invalidCitekey(let key):
            "„\(key)“ taugt nicht als Zitierschlüssel: Er beginnt mit einem Buchstaben und enthält nur Buchstaben, Ziffern und _ - : ."
        case .citekeyTaken(let key):
            "Den Zitierschlüssel „\(key)“ hat schon eine andere Quelle."
        case .noSource:
            "Die Quelle gibt es nicht mehr."
        }
    }
}

/// All sources and quotes of the open library, kept in memory and written back a moment after each change.
@MainActor
@Observable
final class CitationLibrary {
    /// Newest first.
    private(set) var sources: [CitationSource] = []
    /// In the order they were made.
    private(set) var quotes: [CitationQuote] = []
    /// Groups and folders of both shelves.
    private(set) var groups: [CitationGroup] = []
    private(set) var folders: [CitationFolder] = []

    @ObservationIgnored private let store: CitationStore
    @ObservationIgnored private var index = CitationSearchIndex(sources: [], quotes: [])
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isLoaded = false

    init(store: CitationStore) {
        self.store = store
    }

    /// Reads the files the first time Citation Studio (or a citation in a document) needs them.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let loaded = store.loadAll()
        sources = loaded.sources.sorted { $0.createdAt > $1.createdAt }
        quotes = loaded.quotes.sorted { $0.createdAt < $1.createdAt }
        index = CitationSearchIndex(sources: sources, quotes: quotes)
        let collections = store.loadCollections()
        groups = collections.groups
        folders = collections.folders.filter { folder in collections.groups.contains { $0.id == folder.groupID } }
    }

    // MARK: Reading

    func source(_ id: UUID) -> CitationSource? {
        loadIfNeeded()
        return sources.first { $0.id == id }
    }

    func source(citekey: String) -> CitationSource? {
        loadIfNeeded()
        return sources.first { $0.citekey.caseInsensitiveCompare(citekey) == .orderedSame }
    }

    func quote(_ id: UUID) -> CitationQuote? {
        loadIfNeeded()
        return quotes.first { $0.id == id }
    }

    func quotes(of sourceID: UUID) -> [CitationQuote] {
        loadIfNeeded()
        return quotes.filter { $0.sourceID == sourceID }
    }

    /// Tags of quotes and sources with how often they are used, most used first.
    var allTags: [(tag: String, count: Int)] {
        loadIfNeeded()
        var counts: [String: (tag: String, count: Int)] = [:]
        for tag in quotes.flatMap(\.tags) + sources.flatMap(\.tags) {
            let key = tag.lowercased()
            counts[key, default: (tag, 0)].count += 1
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    func search(_ text: String) -> CitationSearchIndex.Result {
        loadIfNeeded()
        return index.search(CitationQuery(text), order: sources.map(\.id), quoteOrder: quotes.map(\.id))
    }

    func duplicates(of candidate: CitationSource) -> [CitationDuplicate] {
        loadIfNeeded()
        return CitationMatching.duplicates(of: candidate, in: sources)
    }

    // MARK: Sources

    /// Adds a source; it gets a citekey if it has none (or a taken or invalid one).
    @discardableResult
    func addSource(_ source: CitationSource) -> CitationSource {
        loadIfNeeded()
        var source = Self.cleaned(source)
        let taken = Set(sources.map(\.citekey))
        if source.citekey.isEmpty || !Citekey.isValid(source.citekey) || taken.contains(where: { $0.caseInsensitiveCompare(source.citekey) == .orderedSame }) {
            source.citekey = Citekey.make(for: source, taken: taken)
        }
        source.createdAt = Date()
        source.updatedAt = source.createdAt
        sources.insert(source, at: 0)
        index.update(source)
        scheduleSave(source.id)
        return source
    }

    /// Changes a source. Its citekey only changes through `setCitekey`, so citations in documents stay valid.
    func updateSource(_ id: UUID, _ change: (inout CitationSource) -> Void) {
        loadIfNeeded()
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return }
        var source = sources[position]
        let key = source.citekey
        change(&source)
        source = Self.cleaned(source)
        source.id = id
        source.citekey = key
        guard source != sources[position] else { return }
        source.updatedAt = Date()
        sources[position] = source
        index.update(source)
        scheduleSave(id)
    }

    func setCitekey(_ key: String, for id: UUID) throws {
        loadIfNeeded()
        let key = key.trimmingCharacters(in: .whitespaces)
        guard Citekey.isValid(key) else { throw CitationError.invalidCitekey(key) }
        guard let position = sources.firstIndex(where: { $0.id == id }) else { throw CitationError.noSource }
        if sources.contains(where: { $0.id != id && $0.citekey.caseInsensitiveCompare(key) == .orderedSame }) { throw CitationError.citekeyTaken(key) }
        guard sources[position].citekey != key else { return }
        sources[position].citekey = key
        sources[position].updatedAt = Date()
        index.update(sources[position])
        scheduleSave(id)
    }

    /// The key the source would get now (from its current authors and year).
    func suggestedCitekey(for id: UUID) -> String? {
        guard let source = source(id) else { return nil }
        return Citekey.make(for: source, taken: Set(sources.filter { $0.id != id }.map(\.citekey)))
    }

    /// Removes a source with its quotes; links from other quotes to them go too.
    func deleteSource(_ id: UUID) {
        loadIfNeeded()
        guard sources.contains(where: { $0.id == id }) else { return }
        let removed = Set(quotes.filter { $0.sourceID == id }.map(\.id))
        sources.removeAll { $0.id == id }
        quotes.removeAll { removed.contains($0.id) }
        index.removeSource(id)
        removed.forEach { index.removeQuote($0) }
        unlinkEverywhere(removed)
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        store.delete(id)
    }

    // MARK: Quotes

    @discardableResult
    func addQuote(_ quote: CitationQuote) -> CitationQuote? {
        loadIfNeeded()
        guard sources.contains(where: { $0.id == quote.sourceID }) else { return nil }
        var quote = Self.cleaned(quote)
        quote.createdAt = Date()
        quote.updatedAt = quote.createdAt
        quote.linkedQuoteIDs = quote.linkedQuoteIDs.filter { id in quotes.contains { $0.id == id } }
        quotes.append(quote)
        index.update(quote)
        for other in quote.linkedQuoteIDs { addLink(from: other, to: quote.id) }
        touchSource(quote.sourceID)
        return quote
    }

    /// Changes a quote; moving it to another source writes both sources.
    func updateQuote(_ id: UUID, _ change: (inout CitationQuote) -> Void) {
        loadIfNeeded()
        guard let position = quotes.firstIndex(where: { $0.id == id }) else { return }
        let old = quotes[position]
        var quote = old
        change(&quote)
        quote = Self.cleaned(quote)
        quote.id = id
        if !sources.contains(where: { $0.id == quote.sourceID }) { quote.sourceID = old.sourceID }
        // Links are kept on both sides.
        quote.linkedQuoteIDs = quote.linkedQuoteIDs.filter { target in target != id && quotes.contains { $0.id == target } }
        guard quote != old else { return }
        quote.updatedAt = Date()
        quotes[position] = quote
        index.update(quote)
        for added in Set(quote.linkedQuoteIDs).subtracting(old.linkedQuoteIDs) { addLink(from: added, to: id) }
        for removed in Set(old.linkedQuoteIDs).subtracting(quote.linkedQuoteIDs) { removeLink(from: removed, to: id) }
        touchSource(quote.sourceID)
        if quote.sourceID != old.sourceID { touchSource(old.sourceID) }
    }

    func deleteQuote(_ id: UUID) {
        loadIfNeeded()
        guard let quote = quotes.first(where: { $0.id == id }) else { return }
        quotes.removeAll { $0.id == id }
        index.removeQuote(id)
        unlinkEverywhere([id])
        touchSource(quote.sourceID)
    }

    /// A cross-reference between two quotes, in both directions.
    func link(_ first: UUID, _ second: UUID) {
        guard first != second, quote(first) != nil, quote(second) != nil else { return }
        addLink(from: first, to: second)
        addLink(from: second, to: first)
    }

    func unlink(_ first: UUID, _ second: UUID) {
        removeLink(from: first, to: second)
        removeLink(from: second, to: first)
    }

    private func addLink(from id: UUID, to target: UUID) {
        guard let position = quotes.firstIndex(where: { $0.id == id }), !quotes[position].linkedQuoteIDs.contains(target) else { return }
        quotes[position].linkedQuoteIDs.append(target)
        touchSource(quotes[position].sourceID)
    }

    private func removeLink(from id: UUID, to target: UUID) {
        guard let position = quotes.firstIndex(where: { $0.id == id }), quotes[position].linkedQuoteIDs.contains(target) else { return }
        quotes[position].linkedQuoteIDs.removeAll { $0 == target }
        touchSource(quotes[position].sourceID)
    }

    private func unlinkEverywhere(_ removed: Set<UUID>) {
        guard !removed.isEmpty else { return }
        for position in quotes.indices where quotes[position].linkedQuoteIDs.contains(where: removed.contains) {
            quotes[position].linkedQuoteIDs.removeAll(where: removed.contains)
            touchSource(quotes[position].sourceID)
        }
    }

    // MARK: Groups and folders

    func groups(_ shelf: CitationShelf) -> [CitationGroup] {
        loadIfNeeded()
        return groups.filter { $0.shelf == shelf }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folders(in groupID: UUID) -> [CitationFolder] {
        folders.filter { $0.groupID == groupID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folder(_ id: UUID?) -> CitationFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func group(_ id: UUID?) -> CitationGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// "Masterarbeit › Kapitel 2".
    func folderPath(_ id: UUID?) -> String? {
        guard let folder = folder(id) else { return nil }
        return [group(folder.groupID)?.name, folder.name].compactMap { $0 }.joined(separator: " › ")
    }

    @discardableResult
    func addGroup(_ shelf: CitationShelf, name: String = "Neue Gruppe") -> CitationGroup {
        loadIfNeeded()
        let group = CitationGroup(name: Self.unique(name, among: groups.filter { $0.shelf == shelf }.map(\.name)), shelf: shelf)
        groups.append(group)
        saveCollections()
        return group
    }

    @discardableResult
    func addFolder(in groupID: UUID, name: String = "Neuer Ordner") -> CitationFolder? {
        guard let group = group(groupID) else { return nil }
        let folder = CitationFolder(name: Self.unique(name, among: folders(in: groupID).map(\.name)), groupID: groupID, shelf: group.shelf)
        folders.append(folder)
        if let index = groups.firstIndex(where: { $0.id == groupID }) { groups[index].isCollapsed = false }
        saveCollections()
        return folder
    }

    func renameGroup(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }), groups[index].name != name else { return }
        groups[index].name = name
        saveCollections()
    }

    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }), folders[index].name != name else { return }
        folders[index].name = name
        saveCollections()
    }

    func setCollapsed(group id: UUID, _ collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].isCollapsed != collapsed else { return }
        groups[index].isCollapsed = collapsed
        saveCollections()
    }

    func setCollapsed(folder id: UUID, _ collapsed: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].isCollapsed != collapsed else { return }
        folders[index].isCollapsed = collapsed
        saveCollections()
    }

    func moveFolder(_ id: UUID, to groupID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }), let group = group(groupID), group.shelf == folders[index].shelf,
              folders[index].groupID != groupID else { return }
        folders[index].groupID = groupID
        saveCollections()
    }

    /// Removes a folder; what was in it becomes unsorted (nothing is deleted).
    func deleteFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        for source in sources where source.folderID == id { updateSource(source.id) { $0.folderID = nil } }
        for quote in quotes where quote.folderID == id { updateQuote(quote.id) { $0.folderID = nil } }
        folders.removeAll { $0.id == id }
        saveCollections()
    }

    /// Removes a group with its folders; their sources or quotes become unsorted.
    func deleteGroup(_ id: UUID) {
        for folder in folders where folder.groupID == id { deleteFolder(folder.id) }
        groups.removeAll { $0.id == id }
        saveCollections()
    }

    /// Files a source in a folder of the sources shelf (nil: unsorted).
    func file(source id: UUID, in folderID: UUID?) {
        if let folderID, folder(folderID)?.shelf != .sources { return }
        updateSource(id) { $0.folderID = folderID }
    }

    /// Files a quote in a folder of the knowledge shelf (nil: unsorted).
    func file(quote id: UUID, in folderID: UUID?) {
        if let folderID, folder(folderID)?.shelf != .quotes { return }
        updateQuote(id) { $0.folderID = folderID }
    }

    private func saveCollections() {
        store.saveCollections(CitationStore.Collections(groups: groups, folders: folders))
    }

    private static func unique(_ name: String, among names: [String]) -> String {
        guard names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return name }
        var number = 2
        while names.contains(where: { $0.caseInsensitiveCompare("\(name) \(number)") == .orderedSame }) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Attachments

    func attach(_ file: URL, to sourceID: UUID) throws {
        guard source(sourceID) != nil else { throw CitationError.noSource }
        let attachment = try store.importAttachment(file, for: sourceID)
        updateSource(sourceID) { $0.attachments.append(attachment) }
    }

    func removeAttachment(_ attachment: CitationAttachment, from sourceID: UUID) {
        store.removeAttachment(attachment, of: sourceID)
        updateSource(sourceID) { $0.attachments.removeAll { $0.fileName == attachment.fileName } }
    }

    func attachmentURL(_ attachment: CitationAttachment, of sourceID: UUID) -> URL {
        store.attachmentURL(attachment, of: sourceID)
    }

    // MARK: Saving

    /// A source's file holds its quotes, so a changed quote writes its source.
    private func touchSource(_ id: UUID) {
        scheduleSave(id)
    }

    private func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.write(id)
        }
    }

    private func write(_ id: UUID) {
        saveTasks[id] = nil
        guard let source = sources.first(where: { $0.id == id }) else { return }
        do {
            try store.save(source, quotes: quotes.filter { $0.sourceID == id })
        } catch {
            print("LLMDesigner: Quelle \(source.citekey) konnte nicht gespeichert werden: \(error)")
        }
    }

    /// Writes everything that is still waiting (before the library closes).
    func saveAll() {
        for id in Array(saveTasks.keys) {
            saveTasks[id]?.cancel()
            write(id)
        }
    }

    // MARK: Cleaning

    /// Tags without "#", trimmed, each once (ignoring case).
    static func cleanedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }

    private static func cleaned(_ source: CitationSource) -> CitationSource {
        var source = source
        source.tags = cleanedTags(source.tags)
        source.authors = source.authors.filter { !$0.isEmpty }
        source.editors = source.editors.filter { !$0.isEmpty }
        if let doi = CitationIdentifier.normalizedDOI(source.doi) { source.doi = doi }
        if let arxiv = CitationIdentifier.normalizedArXiv(source.arxiv) { source.arxiv = arxiv }
        source.title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return source
    }

    private static func cleaned(_ quote: CitationQuote) -> CitationQuote {
        var quote = quote
        quote.tags = cleanedTags(quote.tags)
        quote.page = quote.page.trimmingCharacters(in: .whitespaces)
        var seen = Set<UUID>()
        quote.linkedQuoteIDs = quote.linkedQuoteIDs.filter { seen.insert($0).inserted }
        return quote
    }
}
