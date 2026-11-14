import Foundation
import LibraryMerge

/// What two versions of a thing differ in, in the form its studio shows.
enum Comparison: Sendable, Equatable {
    /// A Writer document: header fields as sentences, the text by blocks and words.
    case document(header: [String], blocks: [BlockDiff])
    /// A presentation: header fields and the slides, matched by their ids.
    case slides(header: [String], slides: [BlockDiff])
    /// A JSON record (note, project, novel world …): what changed, as sentences.
    case record([String])
    /// A picture on each side.
    case images(left: Data?, right: Data?)
    /// Anything else: only sizes.
    case binary(String)

    var changeCount: Int {
        switch self {
        case .document(let header, let blocks): header.count + blocks.filter(\.isChange).count
        case .slides(let header, let slides): header.count + slides.filter(\.isChange).count
        case .record(let sentences): sentences.count
        case .images(let left, let right): left == right ? 0 : 1
        case .binary: 1
        }
    }

    /// A short line for lists: "2 Absätze geändert, 1 neu".
    var summary: String {
        switch self {
        case .document(let header, let blocks):
            let text = TextDiff.summary(blocks)
            return text.isEmpty ? (header.isEmpty ? "unverändert" : header.prefix(2).joined(separator: ", ")) : text
        case .slides(let header, let slides):
            let text = TextDiff.summary(slides, noun: ("Folie", "Folien"))
            return text.isEmpty ? (header.isEmpty ? "unverändert" : header.prefix(2).joined(separator: ", ")) : text
        case .record(let sentences):
            if sentences.isEmpty { return "unverändert" }
            return sentences.count == 1 ? sentences[0] : "\(sentences[0]) und \(sentences.count - 1) weitere Änderung(en)"
        case .images: return "Bild geändert"
        case .binary(let text): return text
        }
    }
}

enum Comparer {
    /// Compares two versions of a file. Nil on one side: the file isn't there (new or deleted).
    static func compare(path: String, left: Data?, right: Data?) -> Comparison {
        let lower = path.lowercased()
        if lower.hasSuffix(".md") {
            let l = left.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let r = right.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return compareDocuments(l, r)
        }
        if lower.hasSuffix(".json") {
            return .record(RecordDiff.sentences(left: left, right: right))
        }
        if [".png", ".jpg", ".jpeg", ".gif", ".heic", ".tiff"].contains(where: lower.hasSuffix) {
            return .images(left: left, right: right)
        }
        if lower.hasSuffix(".plist") || lower.hasSuffix(".txt") || lower.hasSuffix(".css") || lower.hasSuffix(".gitignore") || lower.hasSuffix(".gitattributes") {
            let l = left.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let r = right.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let lines = TextDiff.compare(l.components(separatedBy: "\n"), r.components(separatedBy: "\n"))
            return .document(header: [], blocks: lines)
        }
        let format = ByteCountFormatter()
        switch (left, right) {
        case (nil, let r?): return .binary("neu, \(format.string(fromByteCount: Int64(r.count)))")
        case (let l?, nil): return .binary("entfernt, vorher \(format.string(fromByteCount: Int64(l.count)))")
        case (let l?, let r?): return .binary(l == r ? "unverändert" : "\(format.string(fromByteCount: Int64(l.count))) → \(format.string(fromByteCount: Int64(r.count)))")
        default: return .binary("–")
        }
    }

    // MARK: Documents and presentations

    /// Header fields that change on every save or say nothing to a reader.
    private static let quietHeaderKeys: Set<String> = ["updated", "outline", "id", "created"]

    private static func headerName(_ key: String) -> String {
        switch key {
        case "title": "Titel"
        case "customTitle": "Eigener Titel"
        case "font": "Schrift"
        case "folder": "Ordner"
        case "herkunft": "Herkunft"
        case "toc": "Inhaltsverzeichnis"
        case "format": "Seitenformat"
        case "page": "Seiteneinrichtung"
        case "running": "Kopf- und Fußzeile"
        case "kind": "Art"
        case "backgrounds": "Hintergründe"
        case "master": "Master"
        case "fassungVon": "Fassung von"
        default: key
        }
    }

    static func split(_ text: String) -> (header: [String: String], body: String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return ([:], text)
        }
        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (LibraryItemResolver.frontMatter(Data(text.utf8)), body)
    }

    static func headerSentences(_ left: [String: String], _ right: [String: String]) -> [String] {
        let keys = Set(left.keys).union(right.keys).subtracting(quietHeaderKeys).sorted()
        return keys.compactMap { key in
            let a = left[key], b = right[key]
            guard a != b else { return nil }
            let name = headerName(key)
            switch (a, b) {
            case (nil, let b?): return "\(name): \(diffShort(b)) (neu)"
            case (let a?, nil): return "\(name): \(diffShort(a)) entfernt"
            case (let a?, let b?): return a.count > 60 || b.count > 60 ? "\(name) geändert" : "\(name): \(a) → \(b)"
            default: return nil
            }
        }
    }

    static func compareDocuments(_ left: String, _ right: String) -> Comparison {
        let l = split(left), r = split(right)
        let header = headerSentences(l.header, r.header)
        if l.header["kind"] == "presentation" || r.header["kind"] == "presentation" {
            return .slides(header: header, slides: compareSlides(SlideChunk.parse(l.body), SlideChunk.parse(r.body)))
        }
        return .document(header: header, blocks: TextDiff.compare(TextDiff.blocks(of: l.body), TextDiff.blocks(of: r.body)))
    }

    /// Slides matched by id: order changes become moves, the text is compared by words, the metadata as sentences.
    static func compareSlides(_ left: [SlideChunk], _ right: [SlideChunk]) -> [BlockDiff] {
        let leftIDs = left.map(\.id), rightIDs = right.map(\.id)
        let common = rightIDs.filter(leftIDs.contains)
        // Which common slides kept their order: the longest common subsequence of the ids.
        let orderDifference = common.difference(from: leftIDs.filter(rightIDs.contains))
        var movedIDs = Set<String>()
        for change in orderDifference {
            if case .insert(_, let id, _) = change { movedIDs.insert(id) }
        }
        var result: [BlockDiff] = []
        var lastRight = -1
        for (rIndex, slide) in right.enumerated() {
            // Removed slides that stood before this one on the left come first.
            if let lIndex = leftIDs.firstIndex(of: slide.id) {
                for (removedIndex, removed) in left.enumerated() where removedIndex < lIndex && !rightIDs.contains(removed.id)
                    && !result.contains(where: { $0.leftIndex == removedIndex }) {
                    result.append(BlockDiff(id: result.count, kind: .removed, left: removed.raw, right: nil, leftIndex: removedIndex,
                                            insertAt: lastRight + 1, label: removed.title))
                }
                let old = left[lIndex]
                var block = BlockDiff(id: result.count, kind: .same, left: old.raw, right: slide.raw, leftIndex: lIndex, rightIndex: rIndex, label: slide.title)
                block.details = metaSentences(old.meta, slide.meta)
                if old.text != slide.text { block.segments = TextDiff.segments(old.text, slide.text) }
                if old.notes != slide.notes { block.noteSegments = TextDiff.segments(old.notes, slide.notes) }
                if old.raw != slide.raw { block.kind = .changed }
                if movedIDs.contains(slide.id) {
                    block.kind = .moved
                    block.details.insert("an eine andere Stelle verschoben", at: 0)
                }
                if block.segments.isEmpty { block.segments = [DiffSegment(text: slide.text, kind: .same)] }
                result.append(block)
            } else {
                result.append(BlockDiff(id: result.count, kind: .added, left: nil, right: slide.raw, rightIndex: rIndex,
                                        segments: [DiffSegment(text: slide.text, kind: .added)], label: slide.title))
            }
            lastRight = rIndex
        }
        for (removedIndex, removed) in left.enumerated() where !rightIDs.contains(removed.id) && !result.contains(where: { $0.leftIndex == removedIndex }) {
            result.append(BlockDiff(id: result.count, kind: .removed, left: removed.raw, right: nil, leftIndex: removedIndex,
                                    insertAt: right.count, segments: [DiffSegment(text: removed.text, kind: .removed)], label: removed.title))
        }
        return result
    }

    /// What changed in a slide's metadata line, in words.
    static func metaSentences(_ left: [String: Any], _ right: [String: Any]) -> [String] {
        var sentences: [String] = []
        func string(_ value: Any?) -> String? {
            guard let value else { return nil }
            if let text = value as? String { return text }
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
        if string(left["rolle"]) != string(right["rolle"]) { sentences.append("Rolle: \(string(left["rolle"]) ?? "folie") → \(string(right["rolle"]) ?? "folie")") }
        if string(left["hintergrund"]) != string(right["hintergrund"]) { sentences.append("Hintergrund geändert") }
        if string(left["textbereich"]) != string(right["textbereich"]) { sentences.append("Textbereich verschoben oder vergrößert") }
        let a = (left["bilder"] as? [[String: Any]]) ?? [], b = (right["bilder"] as? [[String: Any]]) ?? []
        func name(_ element: [String: Any]) -> String { element["inhalt"] != nil ? (element["kasten"] != nil ? "Kasten" : "Textfeld") : "Bild" }
        let aByID = Dictionary(a.compactMap { e in (e["id"] as? String).map { ($0, e) } }, uniquingKeysWith: { x, _ in x })
        let bByID = Dictionary(b.compactMap { e in (e["id"] as? String).map { ($0, e) } }, uniquingKeysWith: { x, _ in x })
        for (id, element) in bByID where aByID[id] == nil { sentences.append("\(name(element)) neu") }
        for (id, element) in aByID where bByID[id] == nil { sentences.append("\(name(element)) entfernt") }
        for (id, new) in bByID {
            guard let old = aByID[id] else { continue }
            let frame = ["x", "y", "b", "h"]
            if frame.contains(where: { string(old[$0]) != string(new[$0]) }) { sentences.append("\(name(new)) verschoben oder in der Größe geändert") }
            if string(old["inhalt"]) != string(new["inhalt"]) { sentences.append("Text in \(name(new) == "Kasten" ? "einem Kasten" : "einem Textfeld") geändert") }
            if string(old["quelle"]) != string(new["quelle"]) { sentences.append("Bild ausgetauscht") }
            let style = ["zuschnitt", "rand", "randfarbe", "schatten", "lage", "kasten", "rahmen"]
            if style.contains(where: { string(old[$0]) != string(new[$0]) }) { sentences.append("Darstellung von \(name(new) == "Bild" ? "einem Bild" : "einem Feld") geändert") }
        }
        return sentences.sorted()
    }
}

/// One slide of a presentation file: its metadata line, text and speaker notes, and the raw chunk for taking over.
struct SlideChunk {
    var id: String
    var meta: [String: Any]
    var text: String
    var notes: String
    var raw: String
    var title: String

    /// Splits a presentation's body at its `<!-- folie {…} -->` lines, as the merge driver does.
    static func parse(_ body: String) -> [SlideChunk] {
        MergeText.slides(of: body).enumerated().map { index, slide in
            SlideChunk(id: slide.id, meta: slide.meta, text: slide.text, notes: slide.notes, raw: slide.raw, title: slide.title(at: index))
        }
    }
}

/// What changed in a JSON record, as sentences. Lists of objects with an `id` are matched by it, so a moved to-do
/// isn't "everything changed".
enum RecordDiff {
    /// Fields that change without the content changing (time stamps, daily counts).
    static let quietKeys: Set<String> = ["geaendert", "erstellt", "updated", "updatedAt", "created", "createdAt", "verlauf", "modified", "zuletzt"]
    static let limit = 300

    static func sentences(left: Data?, right: Data?) -> [String] {
        let a = left.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let b = right.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        switch (a, b) {
        case (nil, nil): return []
        case (nil, _): return ["neu angelegt"]
        case (_, nil): return ["gelöscht"]
        default: break
        }
        var result: [String] = []
        compare(unwrap(a!), unwrap(b!), context: "", into: &result)
        if result.count > limit { result = Array(result.prefix(limit)) + ["… und weitere Änderungen"] }
        return result
    }

    /// `{"format": 1, "note": {…}}` → the note.
    private static func unwrap(_ value: Any) -> Any {
        guard let dictionary = value as? [String: Any], dictionary["format"] != nil else { return value }
        let others = dictionary.filter { $0.key != "format" }
        if others.count == 1, let inner = others.first?.value as? [String: Any] { return inner }
        return value
    }

    static func label(of object: [String: Any]) -> String? {
        for key in ["titel", "title", "name", "text", "vorne", "frage", "exactText", "citekey"] {
            if let value = object[key] as? String, !value.isEmpty { return diffShort(value, 40) }
        }
        return nil
    }

    private static func compare(_ a: Any, _ b: Any, context: String, into result: inout [String]) {
        guard result.count <= limit else { return }
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            for key in Set(a.keys).union(b.keys).sorted() where !quietKeys.contains(key) {
                let field = context.isEmpty ? key : "\(context) · \(key)"
                switch (a[key], b[key]) {
                case (nil, let new?): if !isEmpty(new) { result.append("\(field): \(describe(new)) (neu)") }
                case (let old?, nil): if !isEmpty(old) { result.append("\(field) entfernt") }
                case (let old?, let new?): compare(old, new, context: field, into: &result)
                default: break
                }
            }
            return
        }
        if let a = a as? [Any], let b = b as? [Any] {
            let objectsA = a.compactMap { $0 as? [String: Any] }, objectsB = b.compactMap { $0 as? [String: Any] }
            if objectsA.count == a.count, objectsB.count == b.count, (objectsA + objectsB).allSatisfy({ $0["id"] is String }) {
                let byIDa = Dictionary(objectsA.map { ($0["id"] as! String, $0) }, uniquingKeysWith: { x, _ in x })
                let idsB = objectsB.map { $0["id"] as! String }
                for object in objectsB where byIDa[object["id"] as! String] == nil {
                    result.append("\(context): „\(label(of: object) ?? "Eintrag")“ neu")
                }
                for object in objectsA where !idsB.contains(object["id"] as! String) {
                    result.append("\(context): „\(label(of: object) ?? "Eintrag")“ entfernt")
                }
                for object in objectsB {
                    guard let old = byIDa[object["id"] as! String] else { continue }
                    compare(old, object, context: "\(context) „\(label(of: object) ?? label(of: old) ?? "Eintrag")“", into: &result)
                }
                let commonA = objectsA.map { $0["id"] as! String }.filter(idsB.contains)
                let commonB = idsB.filter { byIDa[$0] != nil }
                if commonA != commonB { result.append("\(context): Reihenfolge geändert") }
                return
            }
            if !equal(a, b) { result.append("\(context) geändert (\(a.count) → \(b.count) Einträge)") }
            return
        }
        if !equal(a, b) {
            let old = describe(a), new = describe(b)
            result.append(old.count + new.count > 90 ? "\(context) geändert" : "\(context): \(old) → \(new)")
        }
    }

    private static func isEmpty(_ value: Any) -> Bool {
        if let text = value as? String { return text.isEmpty }
        if let list = value as? [Any] { return list.isEmpty }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        return value is NSNull
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b)
    }

    static func describe(_ value: Any) -> String {
        if let text = value as? String { return "„\(diffShort(text, 40))“" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "ja" : "nein" }
            return number.stringValue
        }
        if let list = value as? [Any] { return "\(list.count) Einträge" }
        if let object = value as? [String: Any] { return label(of: object).map { "„\($0)“" } ?? "Eintrag" }
        return "–"
    }
}

func diffShort(_ text: String, _ limit: Int = 60) -> String {
    let line = text.replacingOccurrences(of: "\n", with: " ")
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}
