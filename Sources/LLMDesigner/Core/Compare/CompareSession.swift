import Foundation
import Observation

// MARK: - Fassungen

extension AppModel {
    /// The document a "Fassung" was made from (the main version), if it still exists.
    func mainVersion(of document: WriterDocument) -> WriterDocument? {
        document.variantOf.flatMap { self.document($0) }
    }

    /// The Fassungen made from a document.
    func variants(of id: WriterDocument.ID) -> [WriterDocument] {
        documents.filter { $0.variantOf == id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// A copy to try something out: same text, same folder, marked as a Fassung of the main version. A Fassung of a
    /// Fassung still points at the main version, so all of them compare against one.
    @discardableResult
    func newVariant(of id: WriterDocument.ID) -> WriterDocument? {
        guard let source = document(id) else { return nil }
        savePendingDocuments()
        let main = source.variantOf.flatMap { document($0) } ?? source
        var copy = source
        copy.id = UUID()
        copy.variantOf = main.id
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.hasCustomTitle = true
        copy.outline = nil
        copy.title = "\(main.displayTitle) – Fassung \(variants(of: main.id).count + 2)"
        documents.insert(copy, at: 0)
        saveDocument(copy.id)
        selectDocument(copy.id)
        return copy
    }
}

// MARK: - Comparing

/// One comparison being looked at: both sides loaded, compared, and changes taken over into the right side.
@MainActor
@Observable
final class CompareSession {
    let request: CompareRequest
    private(set) var leftLabel = ""
    private(set) var rightLabel = ""
    private(set) var title = ""
    private(set) var comparison: Comparison?
    private(set) var isLoading = false
    private(set) var error: String?
    /// The document changes go into, when the right side can be edited.
    private(set) var rightDocumentID: UUID?
    private(set) var canUndo = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var leftBody = ""
    @ObservationIgnored private var rightBody = ""
    @ObservationIgnored private var undoStack: [WriterDocument] = []

    init(request: CompareRequest, app: AppModel) {
        self.request = request
        self.app = app
    }

    var canTakeOver: Bool { request.allowsTakingOver && rightDocumentID != nil }

    func load() async {
        guard let app else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        app.saveEverythingForGit()
        let path = request.item?.mainPath ?? request.item?.key ?? "Dokument.md"
        let left = await content(of: request.left, path: path, app: app)
        let right = await content(of: request.right, path: path, app: app)
        leftLabel = left.label
        rightLabel = right.label
        title = request.item?.title ?? right.title ?? left.title ?? "Vergleich"
        rightDocumentID = right.documentID
        leftBody = left.data.map { Comparer.split(String(decoding: $0, as: UTF8.self)).body } ?? ""
        rightBody = right.data.map { Comparer.split(String(decoding: $0, as: UTF8.self)).body } ?? ""
        if left.data == nil && right.data == nil {
            error = "Auf keiner der beiden Seiten gibt es diese Datei."
        }
        comparison = Comparer.compare(path: path, left: left.data, right: right.data)
    }

    private struct Side {
        var data: Data?
        var label: String
        var title: String?
        var documentID: UUID?
    }

    private func content(of side: CompareRequest.Side, path: String, app: AppModel) async -> Side {
        switch side {
        case .commit(let revision):
            let data = try? await app.git.content(of: path, at: revision)
            let commit = try? await app.git.log(paths: [], limit: 1, revision: revision).first
            let label = commit.map { "\($0.shortID) · \($0.subject) · \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? revision
            return Side(data: data, label: label, title: data.map { LibraryItemResolver.frontMatter($0)["title"] ?? "" })
        case .workingTree:
            let data = try? Data(contentsOf: app.git.root.appendingPathComponent(path))
            let id = request.item?.recordID.flatMap { app.document($0)?.id }
            return Side(data: data, label: "Jetzt", documentID: id)
        case .memory:
            if let id = request.item?.recordID, let document = app.document(id) {
                return Side(data: Data(WriterDocumentStore.encode(document).utf8), label: "Hier in LLM Designer (ungesichert)", title: document.displayTitle, documentID: id)
            }
            return await content(of: .workingTree, path: path, app: app)
        case .document(let id):
            guard let document = app.document(id) else { return Side(data: nil, label: "Dokument fehlt") }
            let label = document.variantOf == nil ? "\(document.displayTitle) (Hauptfassung)" : document.displayTitle
            return Side(data: Data(WriterDocumentStore.encode(document).utf8), label: label, title: document.displayTitle, documentID: id)
        }
    }

    // MARK: Taking over

    /// Takes one change from the left into the right document: a changed block gets the left text, a block only on
    /// the left is inserted, a block only on the right is removed.
    func takeOver(_ block: BlockDiff) async {
        guard canTakeOver, let comparison else { return }
        var lefts: [String], rights: [String]
        switch comparison {
        case .document:
            lefts = TextDiff.blocks(of: leftBody)
            rights = TextDiff.blocks(of: rightBody)
        case .slides:
            lefts = SlideChunk.parse(leftBody).map(\.raw)
            rights = SlideChunk.parse(rightBody).map(\.raw)
        default:
            return
        }
        switch (block.leftIndex, block.rightIndex) {
        case (let l?, let r?) where l < lefts.count && r < rights.count:
            rights[r] = lefts[l]
        case (let l?, nil) where l < lefts.count:
            rights.insert(lefts[l], at: min(block.insertAt ?? rights.count, rights.count))
        case (nil, let r?) where r < rights.count:
            rights.remove(at: r)
        default:
            return
        }
        await write(rights.joined(separator: "\n\n") + "\n")
    }

    /// The whole left text into the right document; its title and settings stay.
    func takeOverAll() async {
        guard canTakeOver else { return }
        await write(leftBody)
    }

    func undo() async {
        guard let app, let previous = undoStack.popLast() else { return }
        if app.selectedDocumentID == previous.id { app.writerFlush?() }
        if let deck = previous.deck {
            _ = app.modifyDeck(previous.id, saveAfter: nil) { $0 = deck; return true }
        } else {
            app.updateDocument(previous.id, markdown: previous.markdown)
        }
        app.saveDocument(previous.id)
        canUndo = !undoStack.isEmpty
        await load()
    }

    private func write(_ body: String) async {
        guard let app, let id = rightDocumentID, let before = app.document(id) else { return }
        undoStack.append(before)
        canUndo = true
        if app.selectedDocumentID == id { app.writerFlush?() }
        if let deck = before.deck {
            var next = PresentationDeck.parse(body)
            next.backgrounds = deck.backgrounds
            next.masterID = deck.masterID
            _ = app.modifyDeck(id, saveAfter: nil) { $0 = next; return true }
        } else {
            // The same path the power access takes: the open editor follows the model.
            app.updateDocument(id, markdown: body)
        }
        app.saveDocument(id)
        await load()
    }
}
