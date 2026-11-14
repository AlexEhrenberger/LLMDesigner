import Foundation

/// What a file in the library belongs to, so lists show "Hausarbeit Statistik" instead of `Documents/3BC4….md`.
enum LibraryItemKind: String, Sendable, CaseIterable, Comparable {
    case document, presentation, source, world, note, project, podcast, dataBlock, template, research, course
    case learning, skills, designs, library, other

    var label: String {
        switch self {
        case .document: "Dokument"
        case .presentation: "Präsentation"
        case .source: "Quelle"
        case .world: "Romanwelt"
        case .note: "Note"
        case .project: "Projekt"
        case .podcast: "Podcast"
        case .dataBlock: "Datenblock"
        case .template: "Vorlage"
        case .research: "Recherche"
        case .course: "Kurs"
        case .learning: "Lernen"
        case .skills: "Skills"
        case .designs: "Folien-Designs"
        case .library: "Bibliothek"
        case .other: "Datei"
        }
    }

    /// The studio it belongs to, for grouping.
    var studio: String {
        switch self {
        case .document: "Writer Studio"
        case .presentation, .designs: "Presenter Studio"
        case .source: "Citation Studio"
        case .world: "Stories Studio"
        case .note: "Notes"
        case .project: "Projekte"
        case .podcast: "PodcastStudio"
        case .dataBlock, .template: "Data Studio"
        case .research: "Rechercherista"
        case .course, .learning: "Learning Studio"
        case .skills: "Skills"
        case .library, .other: "Bibliothek"
        }
    }

    var symbol: String {
        switch self {
        case .document: StudioApplication.writer.symbol
        case .presentation, .designs: StudioApplication.presenter.symbol
        case .source: StudioApplication.citation.symbol
        case .world: StudioApplication.stories.symbol
        case .note: StudioApplication.notes.symbol
        case .project: StudioApplication.projects.symbol
        case .podcast: StudioApplication.podcast.symbol
        case .dataBlock, .template: StudioApplication.data.symbol
        case .research: StudioApplication.research.symbol
        case .course, .learning: StudioApplication.learning.symbol
        case .skills: "sparkles"
        case .library: "books.vertical"
        case .other: "doc"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// One thing of the library with all its files: a document with its analysis, a novel world with its pictures.
struct LibraryItem: Sendable, Hashable, Identifiable {
    var kind: LibraryItemKind
    /// The record's id, or the path for things without one.
    var key: String
    var title: String
    /// The file that holds the title and the content; nil when the item only has side files.
    var mainPath: String?

    var id: String { "\(kind.rawValue):\(key)" }
    var recordID: UUID? { UUID(uuidString: key) }
}

/// Maps paths to items. Titles come from the files themselves (front matter or the JSON envelope), so the same code
/// names an old version from `git show` and a file that is gone.
struct LibraryItemResolver {
    /// The content of a file at the version in question.
    var read: (String) -> Data?

    /// Where an item lives: kind, key and the file that names it.
    static func place(of path: String) -> (kind: LibraryItemKind, key: String, mainPath: String?) {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return (.other, path, nil) }
        let second = parts.count > 1 ? parts[1] : nil
        func uuid(_ text: String?) -> String? {
            guard let text else { return nil }
            let stem = text.hasSuffix(".json") || text.hasSuffix(".md") ? String(text[..<text.lastIndex(of: ".")!]) : text
            return UUID(uuidString: stem)?.uuidString
        }
        switch first {
        case "Documents":
            if parts.count == 2, let id = uuid(second) { return (.document, id, path) }
            // Side files carry the document's id in their name, as the content analyses do.
            if let id = firstUUID(in: path) { return (.document, id, "Documents/\(id).md") }
            return (.document, "Documents/\(second ?? "")", nil)
        case "Zitate":
            if second == "Quellen", let id = uuid(parts.count > 2 ? parts[2] : nil) { return (.source, id, path) }
            if second == "Anhänge" || second == "Anh\u{0061}\u{0308}nge", let id = uuid(parts.count > 2 ? parts[2] : nil) {
                return (.source, id, "Zitate/Quellen/\(id).json")
            }
            return (.source, path, nil)
        case "Geschichten":
            if parts.count == 2, let id = uuid(second) { return (.world, id, path) }
            if parts.count > 2, let id = uuid(parts[2]) { return (.world, id, "Geschichten/\(id).json") }
            return (.world, path, nil)
        case "Notizen":
            if let id = uuid(second) { return (.note, id, path) }
        case "Projekte":
            if parts.count == 2, let id = uuid(second) { return (.project, id, path) }
            if parts.count > 2, let id = uuid(parts[2]) { return (.project, id, "Projekte/\(id).json") }
        case "Podcasts":
            if let id = uuid(second) { return (.podcast, id, "Podcasts/\(id)/podcast.json") }
        case "Daten":
            if let id = uuid(second) { return (.dataBlock, id, path) }
        case "Vorlagen":
            if let id = uuid(second) { return (.template, id, "Vorlagen/\(id)/vorlage.json") }
        case "Recherchen":
            if let id = uuid(second) { return (.research, id, "Recherchen/\(id)/recherche.json") }
        case "Lernen":
            if let id = uuid(second) { return (.course, id, "Lernen/\(id)/kurs.json") }
            return (.learning, "Lernen", "Lernen/lernen.json")
        case "Skills.json":
            return (.skills, "Skills", path)
        case "Präsentationen", "Pra\u{0308}sentationen":
            return (.designs, "Designs", nil)
        case "Bibliothek.json", ".gitignore", ".gitattributes":
            return (.library, path, path)
        default:
            break
        }
        return (.other, path, nil)
    }

    private static func firstUUID(in text: String) -> String? {
        guard let range = text.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression) else { return nil }
        return UUID(uuidString: String(text[range]))?.uuidString
    }

    func item(for path: String) -> LibraryItem {
        let place = Self.place(of: path)
        var kind = place.kind
        var title: String?
        if let main = place.mainPath, let data = read(main) {
            if main.hasSuffix(".md") {
                let head = Self.frontMatter(data)
                title = head["title"]
                if head["kind"] == "presentation" { kind = .presentation }
            } else if main.hasSuffix(".json") {
                title = Self.jsonTitle(data)
            }
        }
        let fallback: String
        switch kind {
        case .skills: fallback = "Skills"
        case .learning: fallback = "Lerneinstellungen"
        case .designs: fallback = "Eigene Folien-Designs"
        case .library, .other: fallback = path
        default:
            // A side file whose owner is unknown (a picture in `Documents/Bilder/`) is named by its file.
            fallback = place.mainPath == nil || (place.mainPath != path && read(place.mainPath!) == nil)
                ? "\((path as NSString).lastPathComponent) (\(kind.label))"
                : "\(kind.label) ohne Titel"
        }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryItem(kind: kind, key: place.key, title: (name?.isEmpty ?? true) ? fallback : name!, mainPath: place.mainPath)
    }

    /// The `key: value` lines between the `---` fences at the top of a document.
    static func frontMatter(_ data: Data) -> [String: String] {
        let text = String(decoding: data.prefix(8192), as: UTF8.self)
        guard text.hasPrefix("---") else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        return values
    }

    /// The title in `{"format": 1, "<root>": {"titel": …}}` or in a plain object.
    static func jsonTitle(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = ["titel", "title", "name", "titleText"]
        func title(in dictionary: [String: Any]) -> String? {
            for key in keys { if let value = dictionary[key] as? String, !value.isEmpty { return value } }
            return nil
        }
        for (key, value) in object.sorted(by: { $0.key < $1.key }) where key != "format" {
            if let inner = value as? [String: Any], let found = title(in: inner) { return found }
        }
        return title(in: object)
    }

    /// Paths grouped into items, in the order of the studios, then by title.
    func group(_ paths: [String]) -> [(item: LibraryItem, paths: [String])] {
        var order: [String] = []
        var groups: [String: (LibraryItem, [String])] = [:]
        for path in paths {
            let item = item(for: path)
            if groups[item.id] == nil {
                order.append(item.id)
                groups[item.id] = (item, [path])
            } else {
                groups[item.id]!.1.append(path)
            }
        }
        return order.compactMap { groups[$0] }
            .sorted { $0.0.kind != $1.0.kind ? $0.0.kind < $1.0.kind : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
            .map { (item: $0.0, paths: $0.1) }
    }
}
