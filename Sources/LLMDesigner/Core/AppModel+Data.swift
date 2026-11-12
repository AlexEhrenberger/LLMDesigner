import AppKit
import SwiftUI

/// The values the text views draw: the cells of data fields in Writer and on slides, and the plain-text views of
/// Notes and Projects, read them here. Data Studio replaces it after every change.
@MainActor
enum DataFields {
    static var resolver = DataResolver()
    /// Counts the changes, so text views know when to draw their fields again.
    static var revision = 0
    /// Posted after a change; open text views lay out their data fields anew.
    static let changed = Notification.Name("LLMDesigner.DataFields.changed")
    /// The open library's Data Studio, for drawing masters where there is no model at hand (the PDF).
    static weak var studio: DataStudio?
}

/// Data Studio's two collections: the data blocks and the templates.
@MainActor
@Observable
final class DataStudio {
    let blocks = RecordLibrary<DataBlock>(store: RecordStore(directory: AppLibrary.current.folder("Daten"), root: "datenblock"))
    let templates = RecordLibrary<DataTemplate>(store: RecordStore(directory: AppLibrary.current.folder("Vorlagen"), root: "vorlage", layout: .folder("vorlage")))

    init() {
        blocks.onChange = { [weak self] in self?.publish() }
        DataFields.studio = self
    }

    /// The master of a presentation, and the logo it shows.
    func master(of deck: PresentationDeck) -> (master: SlideMaster, logo: URL?)? {
        guard let id = deck.masterID, let template = template(id) else { return nil }
        return (template.master, logoURL(of: template))
    }

    func loadIfNeeded() {
        blocks.loadIfNeeded()
        templates.loadIfNeeded()
    }

    private func publish() {
        DataFields.resolver = DataResolver(blocks: blocks.records)
        DataFields.blocks = blocks.records
        DataFields.revision += 1
        NotificationCenter.default.post(name: DataFields.changed, object: nil)
    }

    var resolver: DataResolver {
        blocks.loadIfNeeded()
        return DataResolver(blocks: blocks.records)
    }

    func block(_ id: UUID) -> DataBlock? { blocks.record(id) }

    func block(key: String) -> DataBlock? {
        blocks.loadIfNeeded()
        return blocks.records.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The built-in templates first, then the person's own.
    var allTemplates: [DataTemplate] {
        templates.loadIfNeeded()
        return DataTemplate.builtIns + templates.records
    }

    func template(_ id: UUID) -> DataTemplate? {
        DataTemplate.builtIns.first { $0.id == id } ?? templates.record(id)
    }

    /// The groups of the list in their order, "Ohne Gruppe" last.
    var groups: [String] {
        var seen: [String] = []
        for block in blocks.records where !seen.contains(block.group) { seen.append(block.group) }
        return seen.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
    }

    /// A key no other block has.
    func freeKey(for name: String, except id: UUID? = nil) -> String {
        let taken = Set(blocks.records.filter { $0.id != id }.map { $0.key.lowercased() }).union(DataKey.reserved)
        return DataKey.unique(DataKey.make(from: name, fallback: "daten"), taken: taken)
    }

    /// The logo file of a template, if it has one.
    func logoURL(of template: DataTemplate) -> URL? {
        guard let logo = template.master.logo, !template.isBuiltIn else { return nil }
        let url = templates.store.folder(of: template.id).appendingPathComponent(logo)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func saveAll() {
        blocks.saveAll()
        templates.saveAll()
    }
}

/// What an action or another studio wants Data Studio to show.
struct DataStudioCommand: Equatable {
    var tab: DataStudioTab?
    var block: UUID?
    var template: UUID?
}

enum DataStudioTab: String, CaseIterable, Identifiable {
    case blocks, templates

    var id: String { rawValue }
    var title: String { self == .blocks ? "Datenblöcke" : "Vorlagen" }
    var symbol: String { self == .blocks ? "tablecells" : "doc.on.doc" }
}

extension AppModel {
    // MARK: Opening

    func openDataStudio(_ command: DataStudioCommand? = nil) {
        closeDocument()
        showChats()
        dataStudio.loadIfNeeded()
        if let command { dataStudioCommand = command }
        dataStudioOpen = true
    }

    func closeDataStudio() {
        dataStudio.saveAll()
        dataStudioOpen = false
    }

    // MARK: Blocks

    /// A new block with the fields of a structure; its name and key follow the structure ("Person", `person2`).
    @discardableResult
    func newDataBlock(_ structure: DataStructure = .person, name: String? = nil, undo: UndoManager? = nil) -> DataBlock {
        dataStudio.loadIfNeeded()
        let name = name ?? (structure == .frei ? "Neuer Datenblock" : structure.label)
        var block = DataBlock(name: name, key: dataStudio.freeKey(for: name), group: structure.group, symbol: structure.symbol,
                              color: FolderColor.allCases[dataStudio.blocks.records.count % FolderColor.allCases.count],
                              fields: structure.fields, display: structure.display)
        block.createdAt = Date()
        let made = dataStudio.blocks.add(block)
        if let undo {
            let library = dataStudio.blocks
            undo.registerUndo(withTarget: library) { library in MainActor.assumeIsolated { library.remove(made.id) } }
            undo.setActionName("Datenblock anlegen")
        }
        return made
    }

    @discardableResult
    func duplicateDataBlock(_ id: UUID) -> DataBlock? {
        guard var copy = dataStudio.block(id) else { return nil }
        copy.id = UUID()
        copy.name += " (Kopie)"
        copy.key = dataStudio.freeKey(for: copy.name)
        copy.fields = copy.fields.map { field in
            var field = field
            field.id = UUID()
            return field
        }
        copy.createdAt = Date()
        let index = (dataStudio.blocks.records.firstIndex { $0.id == id } ?? -1) + 1
        return dataStudio.blocks.add(copy, at: index)
    }

    /// Changes a block's key and, if wanted, every text that used the old one: documents, presentations, notes,
    /// projects and templates. Returns how many places were rewritten.
    @discardableResult
    func renameDataKey(_ id: UUID, to newKey: String, rewrite: Bool) -> Int {
        guard let block = dataStudio.block(id) else { return 0 }
        let key = DataKey.make(from: newKey, fallback: block.key)
        let free = dataStudio.freeKey(for: key, except: id)
        guard free.caseInsensitiveCompare(block.key) != .orderedSame else { return 0 }
        let old = block.key
        dataStudio.blocks.update(id) { $0.key = free }
        guard rewrite else { return 0 }
        return rewriteDataReferences { ref in
            ref.block.caseInsensitiveCompare(old) == .orderedSame ? DataRef(block: free, field: ref.field) : nil
        }
    }

    /// Changes a field's key and the texts that used it.
    @discardableResult
    func renameDataFieldKey(_ blockID: UUID, field fieldID: UUID, to newKey: String, rewrite: Bool) -> Int {
        guard let block = dataStudio.block(blockID), let field = block.fields.first(where: { $0.id == fieldID }) else { return 0 }
        let free = block.freeFieldKey(for: newKey, except: fieldID)
        guard free != field.key else { return 0 }
        let old = field.key
        dataStudio.blocks.update(blockID) { block in
            if let index = block.fields.firstIndex(where: { $0.id == fieldID }) { block.fields[index].key = free }
            block.display = block.display.replacingOccurrences(of: "{\(old)}", with: "{\(free)}")
        }
        guard rewrite else { return 0 }
        return rewriteDataReferences { ref in
            guard ref.block.caseInsensitiveCompare(block.key) == .orderedSame, ref.field?.caseInsensitiveCompare(old) == .orderedSame else { return nil }
            return DataRef(block: block.key, field: free)
        }
    }

    /// Rewrites references in every text of the library; returns the number of documents, notes and projects changed.
    private func rewriteDataReferences(_ map: (DataRef) -> DataRef?) -> Int {
        func rewritten(_ text: String) -> String? {
            let new = DataTokens.replace(in: text) { ref in map(ref)?.token }
            return new == text ? nil : new
        }
        var count = 0
        for document in documents {
            if var deck = document.deck {
                var changed = false
                for index in deck.slides.indices {
                    if let new = rewritten(deck.slides[index].markdown) { deck.slides[index].markdown = new; changed = true }
                    for image in deck.slides[index].images.indices {
                        if let text = deck.slides[index].images[image].text, let new = rewritten(text) { deck.slides[index].images[image].text = new; changed = true }
                    }
                }
                if changed { modifyDocument(document.id) { $0.deck = deck }; count += 1 }
            } else if let new = rewritten(document.markdown) {
                modifyDocument(document.id) { $0.markdown = new }
                count += 1
            }
        }
        notes.loadIfNeeded()
        for note in notes.notes {
            var copy = note
            var changed = false
            if let new = rewritten(copy.text) { copy.text = new; changed = true }
            if let new = rewritten(copy.title) { copy.title = new; changed = true }
            func walk(_ todos: inout [NoteTodo]) {
                for index in todos.indices {
                    if let new = rewritten(todos[index].text) { todos[index].text = new; changed = true }
                    walk(&todos[index].children)
                }
            }
            walk(&copy.todos)
            if changed { notes.update(note.id) { $0 = copy }; count += 1 }
        }
        projects.loadIfNeeded()
        for project in projects.projects {
            var copy = project
            var changed = false
            for index in copy.blocks.indices {
                if let new = rewritten(copy.blocks[index].text) { copy.blocks[index].text = new; changed = true }
                if let new = rewritten(copy.blocks[index].title) { copy.blocks[index].title = new; changed = true }
            }
            if changed { projects.update(project.id) { $0 = copy }; count += 1 }
        }
        for template in dataStudio.templates.records {
            var copy = template
            var changed = false
            if let new = rewritten(copy.markdown) { copy.markdown = new; changed = true }
            if let new = rewritten(copy.master.header) { copy.master.header = new; changed = true }
            if let new = rewritten(copy.master.footer) { copy.master.footer = new; changed = true }
            if changed { dataStudio.templates.update(template.id) { $0 = copy } }
        }
        return count
    }

    /// Where a block is used: documents, presentations, notes and projects whose text names it.
    func dataBlockUsages(_ key: String) -> [ProjectRef] {
        func uses(_ text: String) -> Bool {
            DataTokens.find(in: text).contains { $0.ref.block.caseInsensitiveCompare(key) == .orderedSame }
        }
        var refs: [ProjectRef] = documents.filter { document in
            if let deck = document.deck { return deck.slides.contains { uses($0.markdown) || $0.images.contains { uses($0.text ?? "") } } }
            return uses(document.markdown)
        }.map { .document($0.id) }
        notes.loadIfNeeded()
        refs += notes.notes.filter { uses($0.markdown) }.map { .note($0.id) }
        return refs
    }

    // MARK: Templates

    /// The person's blocks a role could take: those whose key is the role's, then those of its structure's group.
    func suggestedBlock(for slot: TemplateSlot) -> DataBlock? {
        dataStudio.loadIfNeeded()
        let blocks = dataStudio.blocks.records
        if let exact = blocks.first(where: { $0.key.caseInsensitiveCompare(slot.key) == .orderedSame }) { return exact }
        let ofGroup = blocks.filter { $0.group == slot.structure.group }
        return ofGroup.count == 1 ? ofGroup[0] : nil
    }

    /// A Writer document from a template. `choices` maps each role to a block key; roles without one stay as they are
    /// and show as open fields. The references stay live: change the block, the document follows.
    @discardableResult
    func createDocument(from templateID: UUID, choices: [String: String] = [:], title: String? = nil, open: Bool = true) -> WriterDocument? {
        guard let template = dataStudio.template(templateID), template.kind == .writer else { return nil }
        var choices = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.lowercased(), $0.value) })
        for slot in template.slots where choices[slot.key.lowercased()] == nil {
            if let block = suggestedBlock(for: slot) { choices[slot.key.lowercased()] = block.key }
        }
        var document = WriterDocument()
        document.markdown = template.markdown(filling: choices)
        if let font = template.font.flatMap(WriterFont.init(rawValue:)) { document.font = font }
        if let format = template.pageFormat.flatMap(WriterPageFormat.init(rawValue:)) { document.pageFormat = format }
        document.title = title ?? template.displayName
        document.hasCustomTitle = true
        document.folderID = newChatFolderID
        if open { closeDocument() }
        documents.insert(document, at: 0)
        saveDocument(document.id)
        if open {
            if let folderID = document.folderID { expandFolder(folderID) }
            showChats()
            writerTab = .document
            selectedDocumentID = document.id
        }
        return document
    }

    /// A presentation from a master: its design and its slides, with the master put on every slide.
    @discardableResult
    func createPresentation(from templateID: UUID, choices: [String: String] = [:], title: String? = nil, open: Bool = true) -> WriterDocument? {
        guard let template = dataStudio.template(templateID), template.kind == .presenter else { return nil }
        var document = WriterDocument.newPresentation()
        var deck = template.slides.isEmpty ? PresentationDeck.new() : PresentationDeck.parse(DataTemplate.fill(template.slides, choices.lowercasedKeys))
        if let backgrounds = template.backgrounds { deck.backgrounds = backgrounds }
        deck.masterID = template.id
        if let title, !title.isEmpty, deck.slides.first?.markdown.isEmpty != false {
            deck.slides[0].markdown = "# " + WriterMarkdown.escape(title, atLineStart: true)
        }
        document.deck = deck
        document.title = title ?? template.displayName
        document.hasCustomTitle = title != nil
        document.folderID = newChatFolderID
        if open { closeDocument() }
        documents.insert(document, at: 0)
        saveDocument(document.id)
        if open {
            showChats()
            writerTab = .document
            selectedSlideID = deck.slides.first?.id
            selectedDocumentID = document.id
        }
        return document
    }

    /// Puts a master on a presentation (nil takes it off); with `design` its backgrounds too.
    func applyMaster(_ templateID: UUID?, to documentID: UUID, design: Bool = false) {
        guard let document = document(documentID), var deck = document.deck else { return }
        deck.masterID = templateID
        if design, let templateID, let backgrounds = dataStudio.template(templateID)?.backgrounds { deck.backgrounds = backgrounds }
        modifyDocument(documentID) { $0.deck = deck }
    }

    /// A new template made from an open document or presentation: its text, page format and design.
    @discardableResult
    func saveAsTemplate(_ documentID: UUID, name: String? = nil) -> DataTemplate? {
        guard let document = document(documentID) else { return nil }
        dataStudio.loadIfNeeded()
        var template = DataTemplate(name: name ?? document.displayTitle, kind: document.isPresentation ? .presenter : .writer)
        template.createdAt = Date()
        if let deck = document.deck {
            template.backgrounds = deck.backgrounds
            template.slides = deck.serialized
            if let master = deck.masterID.flatMap({ dataStudio.template($0) }) { template.master = master.master }
            template.symbol = "rectangle.on.rectangle"
        } else {
            template.markdown = document.markdown
            template.font = document.font.rawValue
            template.pageFormat = document.pageFormat.rawValue
        }
        // The blocks the text uses become its roles.
        var slots: [TemplateSlot] = []
        for (_, ref) in DataTokens.find(in: template.markdown + template.slides) {
            let key = ref.block.lowercased()
            guard !DataKey.reserved.contains(key), !slots.contains(where: { $0.key == key }) else { continue }
            let block = dataStudio.block(key: key)
            slots.append(TemplateSlot(key: key, name: block?.displayName ?? key, structure: DataStructure.allCases.first { $0.group == block?.group && $0 != .frei } ?? .frei))
        }
        template.slots = slots
        return dataStudio.templates.add(template)
    }

    @discardableResult
    func duplicateTemplate(_ id: UUID) -> DataTemplate? {
        guard var copy = dataStudio.template(id) else { return nil }
        let original = copy
        copy.id = UUID()
        copy.builtIn = nil
        copy.name = original.isBuiltIn ? original.name : original.name + " (Kopie)"
        copy.createdAt = Date()
        let made = dataStudio.templates.add(copy)
        // The logo comes along.
        if let logo = dataStudio.logoURL(of: original), let name = original.master.logo {
            let folder = dataStudio.templates.store.folder(of: made.id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: logo, to: folder.appendingPathComponent(name))
        }
        return made
    }

    /// Copies a picture into the template's folder as its logo.
    func setTemplateLogo(_ templateID: UUID, from file: URL) throws {
        guard let template = dataStudio.template(templateID), !template.isBuiltIn else { return }
        guard let image = NSImage(contentsOf: file), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw LLMError.server("Das Bild ließ sich nicht lesen.")
        }
        let folder = dataStudio.templates.store.folder(of: templateID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("logo.png"), options: .atomic)
        dataStudio.templates.update(templateID) { $0.master.logo = "logo.png" }
        SlideMasterImageCache.clear()
    }

    func removeTemplateLogo(_ templateID: UUID) {
        guard let template = dataStudio.template(templateID), !template.isBuiltIn else { return }
        let url = dataStudio.templates.store.folder(of: templateID).appendingPathComponent("logo.png")
        try? FileManager.default.removeItem(at: url)
        dataStudio.templates.update(templateID) { $0.master.logo = nil }
        SlideMasterImageCache.clear()
    }

    func master(of deck: PresentationDeck) -> (master: SlideMaster, logo: URL?)? {
        dataStudio.master(of: deck)
    }

    /// Text with every data field filled in, for exports and the model.
    func resolvingData(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        return dataStudio.resolver.resolveMarkdown(text)
    }
}

extension Dictionary where Key == String, Value == String {
    var lowercasedKeys: [String: String] { Dictionary(uniqueKeysWithValues: map { ($0.key.lowercased(), $0.value) }) }
}

/// Logos are read once and kept while the slides are drawn.
@MainActor
enum SlideMasterImageCache {
    private static var images: [URL: NSImage] = [:]

    static func image(_ url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }

    static func clear() { images = [:] }
}

/// The sheet's item: a template id.
struct TemplateUseRequest: Identifiable {
    let id: UUID
}

extension AppModel {
    /// One of the newer studios (Data, Rechercherista, Learning) holds the main area.
    var newStudioOpen: Bool { dataStudioOpen || researchStudioOpen || learningStudioOpen }
}
