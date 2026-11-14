import Foundation

/// Merges two versions of a library file against their common version, by the building blocks of its format:
/// documents by header field and paragraph, presentations by slide (and a slide's elements by id), JSON records by
/// the ids of their entries. Only real overlaps (the same paragraph, slide or field changed differently) become
/// conflicts. Unresolved conflicts keep "ours", so the result is always a valid file the app can open.
public enum LibraryMerge {
    public static func merge(path: String, base: String?, ours: String?, theirs: String?, choices: [Int: MergeChoice] = [:]) -> MergeResult {
        let context = MergeContext(choices: choices)
        let text = mergeFile(path: path, base: base, ours: ours, theirs: theirs, context: context)
        return MergeResult(text: text, conflicts: context.conflicts)
    }

    static func mergeFile(path: String, base: String?, ours: String?, theirs: String?, context: MergeContext) -> String? {
        if ours == theirs { return ours }
        if ours == base { return theirs }
        if theirs == base { return ours }
        // Deleted on one side, changed on the other, or added on both: the whole file is one choice.
        guard let ours, let theirs else {
            let choice = context.conflict(ours == nil ? "Datei hier gelöscht, auf der anderen Seite geändert" : "Datei hier geändert, auf der anderen Seite gelöscht",
                                          base: base, ours: ours, theirs: theirs, allowsBoth: false)
            return resolve(choice, ours: ours, theirs: theirs)
        }
        let lower = path.lowercased()
        if lower.hasSuffix(".md") {
            return mergeDocument(base: base ?? "", ours: ours, theirs: theirs, context: context)
        }
        if lower.hasSuffix(".json"), let merged = mergeJSONFile(base: base, ours: ours, theirs: theirs, context: context) {
            return merged
        }
        return mergeLines(base: base ?? "", ours: ours, theirs: theirs, context: context)
    }

    private static func resolve(_ choice: MergeChoice?, ours: String?, theirs: String?) -> String? {
        switch choice {
        case nil, .ours: ours
        case .theirs: theirs
        case .both: [ours, theirs].compactMap { $0 }.joined(separator: "\n")
        case .custom(let text): text
        }
    }

    // MARK: Plain text

    static func mergeLines(base: String, ours: String, theirs: String, context: MergeContext) -> String {
        let lines = mergeSequence(base: base.components(separatedBy: "\n"), ours: ours.components(separatedBy: "\n"),
                                  theirs: theirs.components(separatedBy: "\n"), context: context,
                                  label: { "Zeilen „\(MergeText.preview($0))“" }, separator: "\n", refineWords: false)
        return lines.joined(separator: "\n")
    }

    /// The core for lists of text blocks: changes of one side are taken, overlapping changes are conflicts. A single
    /// paragraph changed on both sides is first merged word by word; only if that overlaps too is it a conflict.
    static func mergeSequence(base: [String], ours: [String], theirs: [String], context: MergeContext,
                              label: (String?) -> String, separator: String, refineWords: Bool) -> [String] {
        var result: [String] = []
        for chunk in Diff3.chunks(base: base, ours: ours, theirs: theirs) {
            switch chunk {
            case .stable(let blocks):
                result += blocks
            case .changed(let b, let o, let t):
                if o == t || t == b {
                    result += o
                } else if o == b {
                    result += t
                } else if refineWords, o.count == 1, t.count == 1, b.count <= 1,
                          let words = Diff3.cleanMerge(base: MergeText.tokens(b.first ?? ""), ours: MergeText.tokens(o[0]), theirs: MergeText.tokens(t[0])) {
                    result.append(words.joined())
                } else {
                    let choice = context.conflict(label(o.first ?? t.first ?? b.first), base: b.isEmpty ? nil : b.joined(separator: separator),
                                                  ours: o.isEmpty ? nil : o.joined(separator: separator),
                                                  theirs: t.isEmpty ? nil : t.joined(separator: separator), allowsBoth: true)
                    switch choice {
                    case nil, .ours: result += o
                    case .theirs: result += t
                    case .both: result += o + t.filter { !o.contains($0) }
                    case .custom(let text): result += separator == "\n\n" ? MergeText.blocks(of: text) : text.components(separatedBy: "\n")
                    }
                }
            }
        }
        return result
    }

    // MARK: Documents and presentations

    /// Header fields that change on every save: the later wins, no question.
    static let latestWins: Set<String> = ["updated"]
    /// Header fields the app makes again by itself: ours wins, no question.
    static let regenerated: Set<String> = ["outline"]

    static func mergeDocument(base: String, ours: String, theirs: String, context: MergeContext) -> String {
        let b = MergeText.split(base), o = MergeText.split(ours), t = MergeText.split(theirs)
        let header = mergeHeader(b.header, o.header, t.header, context: context)
        let isPresentation = [b.header, o.header, t.header].contains { $0?["kind"] == "presentation" }
        let body: String
        if o.body == t.body || t.body == b.body {
            body = o.body
        } else if o.body == b.body {
            body = t.body
        } else if isPresentation {
            body = mergeSlides(base: b.body, ours: o.body, theirs: t.body, context: context)
        } else {
            let blocks = mergeSequence(base: MergeText.blocks(of: b.body), ours: MergeText.blocks(of: o.body), theirs: MergeText.blocks(of: t.body),
                                       context: context, label: { "Absatz „\(MergeText.preview($0))“" }, separator: "\n\n", refineWords: true)
            body = blocks.joined(separator: "\n\n") + "\n"
        }
        return MergeText.join(header: header, body: body)
    }

    static func mergeHeader(_ base: MergeText.Header?, _ ours: MergeText.Header?, _ theirs: MergeText.Header?, context: MergeContext) -> MergeText.Header? {
        guard let ours else { return theirs }
        guard let theirs else { return ours }
        let b = base?.dictionary ?? [:], o = ours.dictionary, t = theirs.dictionary
        var keys = ours.entries.map(\.key)
        for key in theirs.entries.map(\.key) where !keys.contains(key) { keys.append(key) }
        var entries: [(key: String, value: String)] = []
        for key in keys {
            let value: String?
            switch (b[key], o[key], t[key]) {
            case let (_, x, y) where x == y: value = x
            case let (old, x, y) where old == x: value = y
            case let (old, x, y) where old == y: value = x
            case let (_, x?, y?) where latestWins.contains(key): value = max(x, y)
            case let (_, x, _) where regenerated.contains(key): value = x
            case let (old, x, y):
                let choice = context.conflict("Kopf: \(headerName(key))", base: old, ours: x, theirs: y, allowsBoth: false)
                switch choice {
                case nil, .ours, .both: value = x
                case .theirs: value = y
                case .custom(let text): value = text.replacingOccurrences(of: "\n", with: " ")
                }
            }
            if let value { entries.append((key, value)) }
        }
        return MergeText.Header(entries: entries)
    }

    static func headerName(_ key: String) -> String {
        switch key {
        case "title": "Titel"
        case "font": "Schrift"
        case "folder": "Ordner"
        case "herkunft": "Herkunft"
        case "format": "Seitenformat"
        case "page": "Seiteneinrichtung"
        case "running": "Kopf- und Fußzeile"
        case "backgrounds": "Hintergründe"
        case "master": "Master"
        case "fassungVon": "Fassung von"
        case "customTitle": "Eigener Titel"
        default: key
        }
    }

    /// Slides by id. The order is ours, with the slides only the other side added put after the slide they followed
    /// there. A slide deleted on one side and changed on the other is a question; changed on both sides, its
    /// metadata merges as JSON (elements by id), its text by paragraph, its speaker notes by line.
    static func mergeSlides(base: String, ours: String, theirs: String, context: MergeContext) -> String {
        let b = MergeText.slides(of: base), o = MergeText.slides(of: ours), t = MergeText.slides(of: theirs)
        let baseByID = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let theirsByID = Dictionary(t.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let oursIDs = Set(o.map(\.id))
        var result: [String] = []
        var placed: [String] = []
        for (index, slide) in o.enumerated() {
            let old = baseByID[slide.id], other = theirsByID[slide.id]
            switch (old, other) {
            case (nil, _):
                // Added here (or on both sides with the same id, which only a copy makes).
                if let other, other.raw != slide.raw {
                    result.append(mergeSlide(base: nil, ours: slide, theirs: other, index: index, context: context))
                } else {
                    result.append(slide.raw)
                }
            case (let old?, nil):
                if old.raw == slide.raw { continue }
                let choice = context.conflict("Folie „\(slide.title(at: index))“: hier geändert, auf der anderen Seite gelöscht",
                                              base: old.raw, ours: slide.raw, theirs: nil, allowsBoth: false)
                if choice == .theirs { continue }
                result.append(slide.raw)
            case (let old?, let other?):
                result.append(mergeSlide(base: old, ours: slide, theirs: other, index: index, context: context))
            }
            placed.append(slide.id)
        }
        // What only the other side added, or changed after this side deleted it.
        for (index, slide) in t.enumerated() where !oursIDs.contains(slide.id) {
            if let old = baseByID[slide.id] {
                if old.raw == slide.raw { continue }
                let choice = context.conflict("Folie „\(slide.title(at: index))“: hier gelöscht, auf der anderen Seite geändert",
                                              base: old.raw, ours: nil, theirs: slide.raw, allowsBoth: false)
                guard choice == .theirs else { continue }
            }
            let previous = t[..<index].reversed().first { placed.contains($0.id) }?.id
            let position = previous.flatMap { id in placed.firstIndex(of: id).map { $0 + 1 } } ?? 0
            result.insert(slide.raw, at: position)
            placed.insert(slide.id, at: position)
        }
        return result.joined(separator: "\n\n") + "\n"
    }

    static func mergeSlide(base: MergeText.Slide?, ours: MergeText.Slide, theirs: MergeText.Slide, index: Int, context: MergeContext) -> String {
        if ours.raw == theirs.raw || theirs.raw == base?.raw { return ours.raw }
        if ours.raw == base?.raw { return theirs.raw }
        let title = ours.title(at: index)
        let metaLine: String
        if ours.metaLine == theirs.metaLine || theirs.metaLine == base?.metaLine {
            metaLine = ours.metaLine
        } else if ours.metaLine == base?.metaLine {
            metaLine = theirs.metaLine
        } else {
            let merged = mergeJSON(base?.meta, ours.meta, theirs.meta, path: "Folie „\(title)“", context: context)
            metaLine = compactJSON(merged ?? ours.meta) ?? ours.metaLine
        }
        let text = mergeSequence(base: MergeText.blocks(of: base?.text ?? ""), ours: MergeText.blocks(of: ours.text), theirs: MergeText.blocks(of: theirs.text),
                                 context: context, label: { "Folie „\(title)“: „\(MergeText.preview($0))“" }, separator: "\n\n", refineWords: true)
            .joined(separator: "\n\n")
        let notes = mergeSequence(base: (base?.notes ?? "").components(separatedBy: "\n"), ours: ours.notes.components(separatedBy: "\n"),
                                  theirs: theirs.notes.components(separatedBy: "\n"), context: context,
                                  label: { _ in "Folie „\(title)“: Moderatorenkarte" }, separator: "\n", refineWords: true)
            .joined(separator: "\n")
        return MergeText.Slide.assemble(metaLine: metaLine, text: text, notes: notes)
    }

    // MARK: JSON

    static func mergeJSONFile(base: String?, ours: String, theirs: String, context: MergeContext) -> String? {
        func parse(_ text: String?) -> Any? {
            text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        }
        guard let o = parse(ours), let t = parse(theirs) else { return nil }
        let merged = mergeJSON(parse(base), o, t, path: "", context: context) ?? o
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fields that change without the content changing: the later time stamp wins.
    static let timeStamps: Set<String> = ["geaendert", "updated", "updatedAt", "modified", "zuletzt"]

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (nil, _), (_, nil): false
        case let (x?, y?): (x as AnyObject).isEqual(y)
        }
    }

    /// The key that tells entries of a list apart: `id`, or `tag` for daily counts.
    static func identityKey(_ list: [Any]) -> String? {
        let objects = list.compactMap { $0 as? [String: Any] }
        guard objects.count == list.count, !objects.isEmpty else { return nil }
        for key in ["id", "tag"] where objects.allSatisfy({ $0[key] is String }) { return key }
        return nil
    }

    static func label(of object: [String: Any]) -> String? {
        for key in ["titel", "title", "name", "text", "vorne", "frage", "exactText", "citekey", "tag"] {
            if let value = object[key] as? String, !value.isEmpty { return MergeText.preview(value) }
        }
        return nil
    }

    static func describe(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "ja" : "nein" }
        return compactJSON(value) ?? "\(value)"
    }

    static func compactJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The three-way merge of JSON values. Nil means "not there".
    static func mergeJSON(_ base: Any?, _ ours: Any?, _ theirs: Any?, path: String, context: MergeContext) -> Any? {
        if same(ours, theirs) { return ours }
        if same(base, ours) { return theirs }
        if same(base, theirs) { return ours }
        let key = path.components(separatedBy: " · ").last ?? path
        if timeStamps.contains(key), let x = ours as? String, let y = theirs as? String { return max(x, y) }
        if let o = ours as? [String: Any], let t = theirs as? [String: Any] {
            let b = base as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            for name in Set(o.keys).union(t.keys).sorted() {
                let field = path.isEmpty ? name : "\(path) · \(name)"
                if let value = mergeJSON(b[name], o[name], t[name], path: field, context: context) { result[name] = value }
            }
            return result
        }
        if let o = ours as? [Any], let t = theirs as? [Any] {
            let b = base as? [Any] ?? []
            if let identity = identityKey(o + t + b) {
                return mergeList(b, o, t, identity: identity, path: path, context: context)
            }
            if (o + t + b).allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
                // A set of values (tags): what one side added comes in, what one side removed goes.
                let removed = b.filter { item in !t.contains { same($0, item) } || !o.contains { same($0, item) } }
                var result = o.filter { item in !removed.contains { same($0, item) } }
                for item in t where !result.contains(where: { same($0, item) }) && !b.contains(where: { same($0, item) }) { result.append(item) }
                return result
            }
        }
        let label = path.isEmpty ? "Inhalt" : path
        let choice = context.conflict(label, base: describe(base), ours: describe(ours), theirs: describe(theirs), allowsBoth: false)
        switch choice {
        case nil, .ours, .both: return ours
        case .theirs: return theirs
        case .custom(let text):
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
        }
    }

    /// A list of entries with ids (to-dos, figures, cards, tasks): ours' order, the other side's new entries after
    /// the entry they followed there, each entry merged on its own.
    static func mergeList(_ base: [Any], _ ours: [Any], _ theirs: [Any], identity: String, path: String, context: MergeContext) -> [Any] {
        func key(_ value: Any) -> String { (value as? [String: Any])?[identity] as? String ?? "" }
        let baseByID = Dictionary(base.map { (key($0), $0) }, uniquingKeysWith: { x, _ in x })
        let theirsByID = Dictionary(theirs.map { (key($0), $0) }, uniquingKeysWith: { x, _ in x })
        let oursIDs = Set(ours.map(key))
        var result: [Any] = []
        var placed: [String] = []
        for item in ours {
            let id = key(item)
            let entry = "\(path) „\(label(of: item as? [String: Any] ?? [:]) ?? id)“"
            switch (baseByID[id], theirsByID[id]) {
            case (let old?, nil):
                if same(old, item) { continue }
                let choice = context.conflict("\(entry): hier geändert, auf der anderen Seite gelöscht", base: describe(old), ours: describe(item), theirs: nil, allowsBoth: false)
                if choice == .theirs { continue }
                result.append(item)
            case (let old, let other?):
                result.append(mergeJSON(old, item, other, path: entry, context: context) ?? item)
            case (nil, nil):
                result.append(item)
            }
            placed.append(id)
        }
        for (index, item) in theirs.enumerated() where !oursIDs.contains(key(item)) {
            let id = key(item)
            if let old = baseByID[id] {
                if same(old, item) { continue }
                let entry = "\(path) „\(label(of: item as? [String: Any] ?? [:]) ?? id)“"
                let choice = context.conflict("\(entry): hier gelöscht, auf der anderen Seite geändert", base: describe(old), ours: nil, theirs: describe(item), allowsBoth: false)
                guard choice == .theirs else { continue }
            }
            let previous = theirs[..<index].reversed().map(key).first { placed.contains($0) }
            let position = previous.flatMap { placed.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            result.insert(item, at: position)
            placed.insert(id, at: position)
        }
        return result
    }
}
