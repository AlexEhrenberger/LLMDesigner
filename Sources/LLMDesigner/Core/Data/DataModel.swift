import Foundation

// Data Studio: named blocks of data ("Absender", "User 1", "Finanzamt") whose fields go into documents,
// presentations, notes and projects as `{{absender.strasse}}`. The text keeps the reference; whatever shows it
// looks the value up, so a change in Data Studio reaches every place at once. Keys in the file are German.

/// What a field holds; it decides the input and how the value is written out.
enum DataFieldKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, mehrzeilig, datum, zahl, email, telefon, link

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .mehrzeilig: "Mehrzeilig"
        case .datum: "Datum"
        case .zahl: "Zahl"
        case .email: "E-Mail"
        case .telefon: "Telefon"
        case .link: "Link"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .mehrzeilig: "text.alignleft"
        case .datum: "calendar"
        case .zahl: "number"
        case .email: "envelope"
        case .telefon: "phone"
        case .link: "link"
        }
    }
}

/// One field of a block: "Straße" with the key `strasse`.
struct DataField: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var name: String
    var kind: DataFieldKind = .text
    /// A date is kept as `2026-11-12` and written out as „12.11.2026“.
    var value = ""

    init(key: String, name: String, kind: DataFieldKind = .text, value: String = "") {
        self.key = key
        self.name = name
        self.kind = kind
        self.value = value
    }

    /// The value as it goes into a text.
    var output: String {
        guard kind == .datum, let date = DataDay.date(value) else { return value }
        return DataDay.german(date)
    }
}

extension DataField: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kuerzel, name, art, wert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        key = c.soft(.kuerzel, "")
        name = c.soft(.name, "")
        kind = c.soft(.art, DataFieldKind.text)
        value = c.soft(.wert, "")
        if key.isEmpty { key = DataKey.make(from: name, fallback: "feld") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .kuerzel)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .art)
        try c.encode(value, forKey: .wert)
    }
}

/// A block of data with a name the person chose and a key the texts use.
struct DataBlock: StoredRecord {
    var id = UUID()
    var name = ""
    var key = ""
    /// Where it is listed: "Personen", "Firmen", "Bank" … free text.
    var group = ""
    var symbol = "person.text.rectangle"
    var color: FolderColor = .blue
    var fields: [DataField] = []
    /// How `{{key}}` shows the whole block: field keys in single braces, `{vorname} {nachname}\n{strasse}`.
    /// Empty: the filled fields one per line.
    var display = ""
    var note = ""
    var createdAt = Date()
    var updatedAt = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ohne Namen" : trimmed
    }

    func field(_ key: String) -> DataField? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The whole block as one text, by its `display` pattern; lines left empty by empty fields are dropped.
    var composed: String {
        let pattern = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return fields.map(\.output).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        }
        let lines = pattern.components(separatedBy: "\n").map { line -> String in
            var result = ""
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "{") {
                result += rest[..<open]
                guard let close = rest[open...].firstIndex(of: "}") else {
                    result += rest[open...]
                    rest = ""
                    break
                }
                let key = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                result += field(key)?.output ?? ""
                rest = rest[rest.index(after: close)...]
            }
            result += rest
            // "  " left by an empty first name.
            return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([name, key, group, note] + fields.flatMap { [$0.name, $0.key, $0.value] }).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// A key for a new field that the block doesn't have yet.
    func freeFieldKey(for name: String, except id: UUID? = nil) -> String {
        DataKey.unique(DataKey.make(from: name, fallback: "feld"), taken: Set(fields.filter { $0.id != id }.map { $0.key.lowercased() }))
    }
}

extension DataBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kuerzel, gruppe, symbol, farbe, felder, darstellung, notiz, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        key = c.soft(.kuerzel, "")
        group = c.soft(.gruppe, "")
        symbol = c.soft(.symbol, "person.text.rectangle")
        color = c.soft(.farbe, FolderColor.blue)
        fields = c.soft(.felder, [DataField]())
        display = c.soft(.darstellung, "")
        note = c.soft(.notiz, "")
        createdAt = c.soft(.erstellt, Date())
        updatedAt = c.soft(.geaendert, createdAt)
        if key.isEmpty { key = DataKey.make(from: name, fallback: "daten") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(key, forKey: .kuerzel)
        try c.encode(group, forKey: .gruppe)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .farbe)
        try c.encode(fields, forKey: .felder)
        try c.encode(display, forKey: .darstellung)
        try c.encode(note, forKey: .notiz)
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

// MARK: - Keys

enum DataKey {
    /// "Straße" → `strasse`, "User 1" → `user1`, "Meine Adresse" → `meine-adresse`.
    static func make(from name: String, fallback: String) -> String {
        var text = name.lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { text = text.replacingOccurrences(of: from, with: to) }
        text = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        var result = ""
        var pending: (dash: Bool, onlySpaces: Bool)?
        for scalar in text.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                if let gap = pending, !result.isEmpty {
                    // "User 1" reads as `user1`: a number after a space joins the word; "kunde-83" keeps its dash.
                    let joins = gap.onlySpaces && ("0"..."9").contains(scalar)
                    if !joins { result += "-" }
                }
                pending = nil
                result.unicodeScalars.append(scalar)
            } else {
                let space = scalar == " "
                pending = (true, (pending?.onlySpaces ?? true) && space)
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? fallback : String(result.prefix(40))
    }

    /// `absender`, `absender2`, `absender3` …
    static func unique(_ key: String, taken: Set<String>) -> String {
        guard taken.contains(key.lowercased()) else { return key }
        var number = 2
        while taken.contains("\(key)\(number)".lowercased()) { number += 1 }
        return "\(key)\(number)"
    }

    /// Letters, digits, `-` and `_`; what a placeholder can name.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Keys that are not blocks: `{{heute}}` is today's date.
    static let reserved: Set<String> = ["heute", "titel", "folie", "folien"]
}

enum DataDay {
    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = iso.date(from: trimmed) { return date }
        let german = DateFormatter()
        german.locale = Locale(identifier: "de_DE")
        german.dateFormat = "d.M.yyyy"
        return german.date(from: trimmed)
    }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// „12.11.2026“
    static func german(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "de_DE")))
    }

    /// „12. November 2026“
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "de_DE")))
    }
}

// MARK: - References in texts

/// `{{absender}}` or `{{absender.strasse}}`.
struct DataRef: Hashable, Sendable {
    var block: String
    var field: String?

    var token: String { "{{" + block + (field.map { "." + $0 } ?? "") + "}}" }

    /// A token's inside without the braces: `absender.strasse`.
    init?(inner: String) {
        let parts = inner.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), DataKey.isValid(parts[0]), parts.count == 1 || DataKey.isValid(parts[1]) else { return nil }
        block = parts[0]
        field = parts.count == 2 ? parts[1] : nil
    }

    init(block: String, field: String? = nil) {
        self.block = block
        self.field = field
    }
}

enum DataTokens {
    /// Every `{{…}}` in a text with its range, in order.
    static func find(in text: String) -> [(range: Range<String.Index>, ref: DataRef)] {
        var found: [(Range<String.Index>, DataRef)] = []
        var search = text.startIndex
        while let open = text.range(of: "{{", range: search..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            let inner = String(text[open.upperBound..<close.lowerBound])
            if !inner.contains("\n"), !inner.contains("{"), let ref = DataRef(inner: inner) {
                found.append((open.lowerBound..<close.upperBound, ref))
                search = close.upperBound
            } else {
                search = open.upperBound
            }
        }
        return found
    }

    /// The text with every reference replaced by what `value` gives; nil keeps the token as it is.
    static func replace(in text: String, _ value: (DataRef) -> String?) -> String {
        let tokens = find(in: text)
        guard !tokens.isEmpty else { return text }
        var result = ""
        var last = text.startIndex
        for (range, ref) in tokens {
            result += text[last..<range.lowerBound]
            result += value(ref) ?? String(text[range])
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    /// The token at a character offset (for clicks into plain text views).
    static func token(in text: String, at offset: Int) -> (range: NSRange, ref: DataRef)? {
        for (range, ref) in find(in: text) {
            let nsRange = NSRange(range, in: text)
            if NSLocationInRange(offset, nsRange) { return (nsRange, ref) }
        }
        return nil
    }
}

/// A snapshot of all blocks for looking values up, also off the main actor (exports).
struct DataResolver: Sendable {
    private var blocks: [String: DataBlock] = [:]
    /// The deck's title and slide numbers in headers and footers.
    var extras: [String: String] = [:]
    var today = Date()

    init(blocks: [DataBlock] = []) {
        for block in blocks where self.blocks[block.key.lowercased()] == nil { self.blocks[block.key.lowercased()] = block }
    }

    func block(_ key: String) -> DataBlock? { blocks[key.lowercased()] }

    var isEmpty: Bool { blocks.isEmpty }

    /// The value of a reference, nil if its block or field doesn't exist.
    func value(_ ref: DataRef) -> String? {
        let key = ref.block.lowercased()
        if ref.field == nil, let extra = extras[key] { return extra }
        if key == "heute" {
            switch ref.field?.lowercased() {
            case nil, "lang": return DataDay.long(today)
            case "kurz": return DataDay.german(today)
            case "iso": return DataDay.string(today)
            case "jahr": return String(Calendar.current.component(.year, from: today))
            default: return nil
            }
        }
        guard let block = blocks[key] else { return nil }
        guard let field = ref.field else { return block.composed }
        return block.field(field)?.output
    }

    /// What a reference is called: „Absender › Straße“.
    func label(_ ref: DataRef) -> String {
        if ref.block.lowercased() == "heute" { return "Heutiges Datum" }
        guard let block = blocks[ref.block.lowercased()] else { return ref.token }
        guard let key = ref.field else { return block.displayName }
        return block.displayName + " › " + (block.field(key)?.name ?? key)
    }

    func resolve(_ text: String) -> String {
        DataTokens.replace(in: text) { value($0) }
    }

    /// For Markdown: line breaks of a multi-line value become hard breaks, so the lines stay in one paragraph.
    func resolveMarkdown(_ text: String) -> String {
        DataTokens.replace(in: text) { ref in
            // The editor and the export read lines of one paragraph as line breaks.
            value(ref).map { text in
                // Escaped as at a line start everywhere: a "\#" in the middle of a line still reads as "#".
                text.components(separatedBy: "\n").enumerated().map { WriterMarkdown.escape($1, atLineStart: true) }.joined(separator: "\n")
            }
        }
    }
}
