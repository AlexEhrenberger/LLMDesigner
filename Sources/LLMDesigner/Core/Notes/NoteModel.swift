import Foundation

// Notes: a note has a title, a progress display, a list of to-dos (which may have to-dos of their own) and free
// text. It may belong to a Writer document, a presentation, a novel world or one of its parts; that link is kept in
// the note, so the documents and worlds stay as they are. Keys in the file are German, like the other new formats.

/// What a note belongs to.
enum NoteOwner: Hashable, Sendable {
    /// A Writer document or a presentation (both are documents in the library).
    case document(UUID)
    /// A novel world as a whole (`part` nil) or one of its books, acts, chapters or sections.
    case story(world: UUID, part: UUID?)

    var documentID: UUID? {
        if case .document(let id) = self { return id }
        return nil
    }

    var worldID: UUID? {
        if case .story(let world, _) = self { return world }
        return nil
    }
}

extension NoteOwner: Codable {
    private enum CodingKeys: String, CodingKey {
        case art, id, welt, teil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .art) {
        case "dokument": self = .document(try c.decode(UUID.self, forKey: .id))
        case "romanwelt": self = .story(world: try c.decode(UUID.self, forKey: .welt), part: c.lenient(.teil, UUID?.none))
        case let other: throw DecodingError.dataCorruptedError(forKey: .art, in: c, debugDescription: "Unbekannte Zugehörigkeit „\(other)“")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document(let id):
            try c.encode("dokument", forKey: .art)
            try c.encode(id, forKey: .id)
        case .story(let world, let part):
            try c.encode("romanwelt", forKey: .art)
            try c.encode(world, forKey: .welt)
            try c.encodeIfPresent(part, forKey: .teil)
        }
    }
}

/// One to-do. A to-do with to-dos of its own counts through them: it is done when all of them are.
struct NoteTodo: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
    var isDone = false
    /// Its own to-dos are folded away.
    var isCollapsed = false
    /// Writer documents and presentations this to-do is about ("Konzept ausarbeiten" → the concept).
    var documents: [UUID] = []
    var children: [NoteTodo] = []

    init(text: String = "", isDone: Bool = false, children: [NoteTodo] = []) {
        self.text = text
        self.isDone = isDone
        self.children = children
    }

    /// The to-dos that count: itself if it has none of its own, else theirs.
    var leafCounts: (done: Int, total: Int) {
        guard !children.isEmpty else { return (isDone ? 1 : 0, 1) }
        return children.reduce((0, 0)) { sum, child in
            let counts = child.leafCounts
            return (sum.0 + counts.done, sum.1 + counts.total)
        }
    }

    var progress: NoteProgress { NoteProgress(leafCounts) }

    /// This to-do and every one below it, depth first.
    var all: [NoteTodo] { [self] + children.flatMap(\.all) }

    func contains(_ id: UUID) -> Bool {
        self.id == id || children.contains { $0.contains(id) }
    }
}

extension NoteTodo: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, text, erledigt, zu, dokumente, unter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        text = c.lenient(.text, "")
        isDone = c.lenient(.erledigt, false)
        isCollapsed = c.lenient(.zu, false)
        documents = c.lenient(.dokumente, [])
        children = c.lenient(.unter, [Lenient<NoteTodo>]()).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(isDone, forKey: .erledigt)
        if isCollapsed { try c.encode(true, forKey: .zu) }
        if !documents.isEmpty { try c.encode(documents, forKey: .dokumente) }
        if !children.isEmpty { try c.encode(children, forKey: .unter) }
    }
}

/// How far a note or a to-do is: the to-dos without to-dos of their own, done and in all.
struct NoteProgress: Hashable, Sendable {
    var done: Int
    var total: Int

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    init(_ counts: (done: Int, total: Int)) {
        self.init(done: counts.done, total: counts.total)
    }

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percent: Int { Int((fraction * 100).rounded(.down)) }
    var isComplete: Bool { total > 0 && done == total }
    var open: Int { total - done }

    /// "3 von 7 erledigt", for the head of a note.
    var label: String {
        if total == 0 { return "Noch keine ToDos" }
        if isComplete { return total == 1 ? "1 ToDo – alles erledigt" : "Alle \(total) ToDos erledigt" }
        return "\(done) von \(total) erledigt"
    }
}

/// A note: title, progress display, to-dos and free text.
struct Note: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var style: NoteProgressStyle = .bar
    /// Thoughts and jottings below the list; they don't count towards the progress.
    var text = ""
    /// Documents, presentations, novel worlds and their parts this note belongs to. Empty: a note of its own.
    var owners: [NoteOwner] = []
    var todos: [NoteTodo] = []
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String = "", style: NoteProgressStyle = .bar, owners: [NoteOwner] = []) {
        self.title = title
        self.style = style
        self.owners = owners
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Unbenanntes Note" : title
    }

    var progress: NoteProgress {
        NoteProgress(todos.reduce((0, 0)) { sum, todo in
            let counts = todo.leafCounts
            return (sum.0 + counts.done, sum.1 + counts.total)
        })
    }

    /// Every to-do, depth first.
    var allTodos: [NoteTodo] { todos.flatMap(\.all) }

    func belongs(to owner: NoteOwner) -> Bool { owners.contains(owner) }

    /// The title, the free text and every to-do's text.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedStandardContains(query) || text.localizedStandardContains(query)
            || allTodos.contains { $0.text.localizedStandardContains(query) }
    }
}

extension Note: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, titel, anzeige, text, gehoertZu, todos, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        title = c.lenient(.titel, "")
        // A display this version doesn't know becomes the bar, so the note still opens.
        style = NoteProgressStyle(rawValue: c.lenient(.anzeige, "")) ?? .bar
        text = c.lenient(.text, "")
        owners = c.lenient(.gehoertZu, [Lenient<NoteOwner>]()).compactMap(\.value)
        todos = c.lenient(.todos, [Lenient<NoteTodo>]()).compactMap(\.value)
        createdAt = c.lenient(.erstellt, Date())
        updatedAt = c.lenient(.geaendert, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .titel)
        try c.encode(style.rawValue, forKey: .anzeige)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if !owners.isEmpty { try c.encode(owners, forKey: .gehoertZu) }
        try c.encode(todos, forKey: .todos)
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

/// The pictures of how far a note is, from the plain bar to the snail on its way to the lettuce.
enum NoteProgressStyle: String, CaseIterable, Identifiable, Sendable {
    case bar = "balken"
    case rings = "ringe"
    case glass = "glas"
    case plant = "pflanze"
    case rocket = "rakete"
    case summit = "gipfel"
    case battery = "akku"
    case moon = "mond"
    case pizza = "pizza"
    case snail = "schnecke"
    case gauge = "tacho"
    case pixel = "pixel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar: "Balken"
        case .rings: "Ringe"
        case .glass: "Glas"
        case .plant: "Pflanze"
        case .rocket: "Rakete"
        case .summit: "Gipfel"
        case .battery: "Akku"
        case .moon: "Mond"
        case .pizza: "Pizza"
        case .snail: "Schnecke"
        case .gauge: "Tacho"
        case .pixel: "Pixel"
        }
    }

    /// One line on what it shows, for the picker.
    var tagline: String {
        switch self {
        case .bar: "Schlicht und klar"
        case .rings: "Ein Ring je Hauptaufgabe"
        case .glass: "Füllt sich bis zum Rand"
        case .plant: "Wächst und blüht am Ende"
        case .rocket: "Von der Erde zum Mond"
        case .summit: "Fahne auf dem Gipfel"
        case .battery: "Lädt sich auf"
        case .moon: "Vom Neumond zum Vollmond"
        case .pizza: "Stück für Stück"
        case .snail: "Langsam, aber sie kommt an"
        case .gauge: "Gib Gas"
        case .pixel: "Lädt wie 1989"
        }
    }

    /// Wide pictures stand under the title, the others beside it.
    var isWide: Bool {
        switch self {
        case .bar, .rocket, .snail, .pixel: true
        default: false
        }
    }
}

// MARK: - Editing

/// The to-dos of one level, found and changed by id anywhere in the tree.
extension Array where Element == NoteTodo {
    func find(_ id: UUID) -> NoteTodo? {
        for todo in self {
            if todo.id == id { return todo }
            if let found = todo.children.find(id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func update(_ id: UUID, _ change: (inout NoteTodo) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                change(&self[index])
                return true
            }
            if self[index].children.update(id, change) { return true }
        }
        return false
    }

    mutating func remove(_ id: UUID) -> NoteTodo? {
        if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
        for index in indices {
            if let removed = self[index].children.remove(id) { return removed }
        }
        return nil
    }

    /// A parent's done state follows its to-dos, so the tree never says something else than its leaves.
    mutating func normalize() {
        for index in indices where !self[index].children.isEmpty {
            self[index].children.normalize()
            self[index].isDone = self[index].children.allSatisfy(\.isDone)
        }
    }
}

/// A to-do as the list shows it: its depth and number ("2.1").
struct NoteRow: Identifiable, Hashable {
    let todo: NoteTodo
    let depth: Int
    let number: String
    var id: UUID { todo.id }
}

extension Note {
    func todo(_ id: UUID) -> NoteTodo? { todos.find(id) }

    /// The to-dos from the top down to this one, itself included.
    func path(to id: UUID) -> [NoteTodo] {
        func search(_ list: [NoteTodo], _ trail: [NoteTodo]) -> [NoteTodo]? {
            for todo in list {
                if todo.id == id { return trail + [todo] }
                if let found = search(todo.children, trail + [todo]) { return found }
            }
            return nil
        }
        return search(todos, []) ?? []
    }

    /// The to-do it is under (nil at the top) and its place there.
    func location(of id: UUID) -> (parent: UUID?, index: Int)? {
        func search(_ list: [NoteTodo], _ parent: UUID?) -> (UUID?, Int)? {
            if let index = list.firstIndex(where: { $0.id == id }) { return (parent, index) }
            for todo in list {
                if let found = search(todo.children, todo.id) { return found }
            }
            return nil
        }
        return search(todos, nil).map { (parent: $0.0, index: $0.1) }
    }

    /// The to-dos of one level: the top (nil) or those under a to-do.
    func children(of parent: UUID?) -> [NoteTodo] {
        guard let parent else { return todos }
        return todo(parent)?.children ?? []
    }

    private mutating func changeChildren(of parent: UUID?, _ change: (inout [NoteTodo]) -> Void) {
        if let parent {
            todos.update(parent) { change(&$0.children) }
        } else {
            change(&todos)
        }
    }

    mutating func updateTodo(_ id: UUID, _ change: (inout NoteTodo) -> Void) {
        todos.update(id, change)
    }

    /// Puts a to-do under `parent` (nil: the top) at `index` (nil: at the end). A parent that isn't there takes nothing.
    @discardableResult
    mutating func insert(_ todo: NoteTodo, parent: UUID?, at index: Int? = nil) -> Bool {
        if let parent, self.todo(parent) == nil { return false }
        changeChildren(of: parent) { list in
            list.insert(todo, at: Swift.min(Swift.max(index ?? list.count, 0), list.count))
        }
        if let parent { todos.update(parent) { $0.isCollapsed = false } }
        todos.normalize()
        return true
    }

    /// A new to-do under `parent`, or right after the to-do `after` on its level.
    @discardableResult
    mutating func addTodo(_ text: String = "", parent: UUID? = nil, after sibling: UUID? = nil) -> UUID? {
        let todo = NoteTodo(text: text)
        if let sibling, let place = location(of: sibling) {
            return insert(todo, parent: place.parent, at: place.index + 1) ? todo.id : nil
        }
        return insert(todo, parent: parent) ? todo.id : nil
    }

    @discardableResult
    mutating func removeTodo(_ id: UUID) -> NoteTodo? {
        let removed = todos.remove(id)
        todos.normalize()
        return removed
    }

    /// Ticks a to-do off or opens it again, with every to-do below it.
    mutating func setDone(_ id: UUID, _ done: Bool) {
        func mark(_ todo: inout NoteTodo) {
            todo.isDone = done
            for index in todo.children.indices { mark(&todo.children[index]) }
        }
        todos.update(id) { mark(&$0) }
        todos.normalize()
    }

    /// Makes a to-do the last of the one above it.
    @discardableResult
    mutating func indent(_ id: UUID) -> Bool {
        guard let place = location(of: id), place.index > 0, let todo = todo(id) else { return false }
        let newParent = children(of: place.parent)[place.index - 1].id
        _ = todos.remove(id)
        return insert(todo, parent: newParent)
    }

    /// Takes a to-do out of the one it is under and puts it right after that one.
    @discardableResult
    mutating func outdent(_ id: UUID) -> Bool {
        guard let place = location(of: id), let parent = place.parent, let parentPlace = location(of: parent), let todo = todo(id) else { return false }
        _ = todos.remove(id)
        return insert(todo, parent: parentPlace.parent, at: parentPlace.index + 1)
    }

    /// Up (negative) or down on its own level.
    @discardableResult
    mutating func move(_ id: UUID, by offset: Int) -> Bool {
        guard let place = location(of: id) else { return false }
        let target = place.index + offset
        guard offset != 0, target >= 0, target < children(of: place.parent).count else { return false }
        changeChildren(of: place.parent) { list in
            let todo = list.remove(at: place.index)
            list.insert(todo, at: target)
        }
        return true
    }

    /// Puts a to-do under another one (nil: the top); never under itself or one of its own.
    @discardableResult
    mutating func reparent(_ id: UUID, to parent: UUID?, at index: Int? = nil) -> Bool {
        guard let todo = todo(id) else { return false }
        if let parent, todo.contains(parent) || self.todo(parent) == nil { return false }
        _ = todos.remove(id)
        return insert(todo, parent: parent, at: index)
    }

    /// Removes every finished to-do (a parent goes with all of its to-dos, since then they are all done).
    @discardableResult
    mutating func removeDone() -> Int {
        func prune(_ list: inout [NoteTodo]) -> Int {
            var count = 0
            list.removeAll { todo in
                if todo.isDone { count += todo.all.count }
                return todo.isDone
            }
            for index in list.indices { count += prune(&list[index].children) }
            return count
        }
        let removed = prune(&todos)
        todos.normalize()
        return removed
    }

    /// The to-dos as the list shows them; folded ones hide what is under them.
    func rows(showingCollapsed: Bool = false) -> [NoteRow] {
        var rows: [NoteRow] = []
        func walk(_ list: [NoteTodo], depth: Int, prefix: String) {
            for (index, todo) in list.enumerated() {
                let number = prefix.isEmpty ? "\(index + 1)" : "\(prefix).\(index + 1)"
                rows.append(NoteRow(todo: todo, depth: depth, number: number))
                if showingCollapsed || !todo.isCollapsed { walk(todo.children, depth: depth + 1, prefix: number) }
            }
        }
        walk(todos, depth: 0, prefix: "")
        return rows
    }

    /// "2.1": the second to-do's first.
    func number(of id: UUID) -> String? {
        rows(showingCollapsed: true).first { $0.id == id }?.number
    }

    /// The to-do at "2.1".
    func todo(atNumber number: String) -> NoteTodo? {
        let steps = number.split(separator: ".").compactMap { Int($0) }
        guard !steps.isEmpty, steps.count == number.split(separator: ".").count else { return nil }
        var level = todos
        var found: NoteTodo?
        for step in steps {
            guard step >= 1, step <= level.count else { return nil }
            found = level[step - 1]
            level = level[step - 1].children
        }
        return found
    }

    /// The progress of each top-level to-do that has to-dos of its own, for the rings.
    var groups: [(title: String, progress: NoteProgress)] {
        todos.filter { !$0.children.isEmpty }.map { ($0.text, $0.progress) }
    }
}

// MARK: - Text

extension Note {
    /// The note as a Markdown task list, for other programs and for dragging into a document.
    var markdown: String {
        var lines = ["# " + displayTitle, ""]
        lines += Self.markdownLines(todos, depth: 0)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines += ["", text] }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdownLines(_ todos: [NoteTodo], depth: Int) -> [String] {
        todos.flatMap { todo in
            [String(repeating: "  ", count: depth) + (todo.isDone ? "- [x] " : "- [ ] ") + todo.text]
                + markdownLines(todo.children, depth: depth + 1)
        }
    }

    /// To-dos from lines of text: a task list, a bulleted or numbered list, or plain lines. Indentation (two spaces or
    /// a tab per step) makes to-dos of to-dos; "[x]" makes one done. Empty lines and headings are left out. Once the
    /// text has a list, only its lines count: the paragraphs around it (a note's free text) don't become to-dos.
    static func todos(fromText text: String) -> [NoteTodo] {
        let lines = text.components(separatedBy: .newlines)
        let hasList = lines.contains { isListLine($0.trimmingCharacters(in: .whitespaces)) }
        var roots: [NoteTodo] = []
        // The path of open to-dos by indentation: (indent, index path).
        var stack: [(indent: Int, path: [Int])] = []
        for raw in lines {
            let expanded = raw.replacingOccurrences(of: "\t", with: "  ")
            let indent = expanded.prefix { $0 == " " }.count
            var line = expanded.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !hasList || isListLine(line) else { continue }
            var done = false
            for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
                line.removeFirst(marker.count)
                break
            }
            if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { line.removeSubrange(match) }
            if line.hasPrefix("[ ] ") || line.hasPrefix("☐ ") {
                line.removeFirst(line.hasPrefix("☐ ") ? 2 : 4)
            } else if line.lowercased().hasPrefix("[x] ") || line.hasPrefix("☑ ") || line.hasPrefix("✓ ") {
                line.removeFirst(line.hasPrefix("[") ? 4 : 2)
                done = true
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let todo = NoteTodo(text: line, isDone: done)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let parent = stack.last {
                func append(_ list: inout [NoteTodo], at path: ArraySlice<Int>) -> Int {
                    guard let first = path.first else { return -1 }
                    if path.count == 1 {
                        list[first].children.append(todo)
                        return list[first].children.count - 1
                    }
                    return append(&list[first].children, at: path.dropFirst())
                }
                let index = append(&roots, at: parent.path[...])
                stack.append((indent, parent.path + [index]))
            } else {
                roots.append(todo)
                stack.append((indent, [roots.count - 1]))
            }
        }
        roots.normalize()
        return roots
    }

    /// A line of a bulleted, numbered or task list.
    private static func isListLine(_ line: String) -> Bool {
        ["- ", "* ", "+ ", "• ", "☐ ", "☑ ", "✓ ", "[ ] ", "[x] ", "[X] "].contains { line.hasPrefix($0) }
            || line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
    }
}
