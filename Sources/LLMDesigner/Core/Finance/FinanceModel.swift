import Foundation

// FinanceStudio's data: one account, its bookings (one file per month), categories, the person's own assignments of
// groups to categories, and the plan (income, fixed costs, spending projects, savings goals). Amounts are whole cents
// everywhere: a sum of thousands of bookings must come out to the cent, which `Double` doesn't promise.

/// A calendar day without a time or time zone. A booking happens on a day at the bank, not at an instant, and a
/// `Date` would move it across midnight whenever the Mac travels.
struct FinanceDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date) {
        let parts = FinanceDay.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `2026-11-20`, `20.11.2026`, `20.11.26`, `20/11/2026`, `2026/11/20`. Anything else, or a day that doesn't exist, is nil.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        var year: Int, month: Int, day: Int
        if text.range(of: #"^\d{4}[-/.]"#, options: .regularExpression) != nil {
            (year, month, day) = (numbers[0], numbers[1], numbers[2])
        } else {
            (day, month, year) = (numbers[0], numbers[1], numbers[2])
            if year < 100 { year += 2000 }
        }
        guard (1...12).contains(month), day >= 1, day <= FinanceDay.daysIn(year: year, month: month), (1900...2200).contains(year) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = FinanceDay(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Kein Datum: \(text)"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    /// Weeks start on Monday, as in Germany.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }()

    static var today: FinanceDay { FinanceDay(Date()) }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func < (lhs: FinanceDay, rhs: FinanceDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Noon of the day, so time zone changes keep it on the same day.
    var date: Date {
        FinanceDay.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var german: String { String(format: "%02d.%02d.%04d", day, month, year) }
    var short: String { String(format: "%02d.%02d.", day, month) }
    var monthKey: String { String(format: "%04d-%02d", year, month) }
    var description: String { iso }

    func adding(days: Int) -> FinanceDay {
        FinanceDay(FinanceDay.calendar.date(byAdding: .day, value: days, to: date) ?? date)
    }

    /// The same day some months later; the 31st becomes the last day of a shorter month.
    func adding(months: Int) -> FinanceDay {
        let total = year * 12 + (month - 1) + months
        let newYear = total / 12
        let newMonth = total % 12 + 1
        return FinanceDay(year: newYear, month: newMonth, day: min(day, FinanceDay.daysIn(year: newYear, month: newMonth)))
    }

    var firstOfMonth: FinanceDay { FinanceDay(year: year, month: month, day: 1) }
    var lastOfMonth: FinanceDay { FinanceDay(year: year, month: month, day: FinanceDay.daysIn(year: year, month: month)) }
    var firstOfYear: FinanceDay { FinanceDay(year: year, month: 1, day: 1) }
    var lastOfYear: FinanceDay { FinanceDay(year: year, month: 12, day: 31) }

    /// The Monday of the day's week.
    var weekStart: FinanceDay {
        let weekday = FinanceDay.calendar.component(.weekday, from: date)
        // `weekday` counts Sunday as 1 whatever the first day of the week is.
        return adding(days: -((weekday + 5) % 7))
    }

    var weekOfYear: Int { FinanceDay.calendar.component(.weekOfYear, from: date) }

    /// Days from this one to another (positive when the other is later).
    func days(to other: FinanceDay) -> Int {
        FinanceDay.calendar.dateComponents([.day], from: date, to: other.date).day ?? 0
    }

    /// Whole months from this month to another's.
    func months(to other: FinanceDay) -> Int {
        (other.year * 12 + other.month) - (year * 12 + month)
    }

    static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
    static let shortMonthNames = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]

    var monthTitle: String { "\(FinanceDay.monthNames[month - 1]) \(year)" }
    var shortMonthTitle: String { "\(FinanceDay.shortMonthNames[month - 1]) \(String(year).suffix(2))" }
}

/// Amounts for people: `1.234,56 €`, `−54,20 €`.
enum FinanceMoney {
    private static func formatter(_ currency: String, fraction: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = fraction
        formatter.maximumFractionDigits = fraction
        formatter.minusSign = "−"
        return formatter
    }

    nonisolated(unsafe) private static var cache: [String: NumberFormatter] = [:]
    private static let lock = NSLock()

    /// `sign` writes a plus before income too, as in a statement.
    static func format(_ cents: Int, currency: String = "EUR", sign: Bool = false, whole: Bool = false) -> String {
        let key = "\(currency)|\(whole)"
        lock.lock()
        let formatter = cache[key] ?? formatter(currency, fraction: whole ? 0 : 2)
        cache[key] = formatter
        let text = formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents)"
        lock.unlock()
        return sign && cents > 0 ? "+" + text : text
    }

    /// A plain number with comma for tables and the CLI: `-54,20`.
    static func plain(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        let euros = value / 100
        var grouped = ""
        for (index, character) in String(euros).reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(".") }
            grouped.append(character)
        }
        return "\(sign)\(String(grouped.reversed())),\(String(format: "%02d", value % 100))"
    }

    /// An amount the person typed: `1.234,56`, `1234.56`, `-54,2`, `54,20 €`, `3500`. Nil when it isn't one.
    static func cents(_ text: String, decimalComma: Bool? = nil) -> Int? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
        text = text.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        text = text.replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive).replacingOccurrences(of: "€", with: "")
        var negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        if text.hasSuffix("-") { negative = true; text.removeLast() }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }
        let commas = text.filter { $0 == "," }.count
        let dots = text.filter { $0 == "." }.count
        let decimal: Character?
        if let lastComma = text.lastIndex(of: ","), let lastDot = text.lastIndex(of: ".") {
            decimal = lastComma > lastDot ? "," : "."
        } else if commas > 0 {
            // One comma is the German decimal comma; several are an English thousands separator.
            decimal = decimalComma == false || commas > 1 ? nil : ","
        } else if dots > 0, let lastDot = text.lastIndex(of: ".") {
            let digitsAfter = text.distance(from: lastDot, to: text.endIndex) - 1
            // `3.500` is three thousand five hundred in German writing; `12.5` and `54.20` are decimals.
            if decimalComma == true || dots > 1 {
                decimal = nil
            } else if decimalComma == false {
                decimal = "."
            } else {
                decimal = digitsAfter == 3 ? nil : "."
            }
        } else {
            decimal = nil
        }
        var whole = text
        var fraction = ""
        if let decimal, let index = text.lastIndex(of: decimal) {
            whole = String(text[..<index])
            fraction = String(text[text.index(after: index)...])
        }
        whole.removeAll { $0 == "." || $0 == "," }
        guard fraction.count <= 2 || fraction.dropFirst(2).allSatisfy({ $0 == "0" }) else { return nil }
        fraction = String((fraction + "00").prefix(2))
        guard let euros = Int(whole.isEmpty ? "0" : whole), let rest = Int(fraction) else { return nil }
        let value = euros * 100 + rest
        return negative ? -value : value
    }

    /// Euros from an action's number parameter, rounded to the cent.
    static func cents(euros: Double) -> Int { Int((euros * 100).rounded()) }
    static func euros(_ cents: Int) -> Double { Double(cents) / 100 }
}

// MARK: - Bookings

/// One movement on the account: negative is money going out.
struct FinanceTransaction: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case manual = "manuell", csv
    }

    var id = UUID()
    var day: FinanceDay
    var cents: Int
    /// Who got the money or sent it.
    var counterparty = ""
    var purpose = ""
    /// The bank's word for the booking: Lastschrift, Gutschrift, Kartenzahlung.
    var type = ""
    var iban = ""
    /// A category the person chose for this one booking; nil follows the group and the keywords.
    var category: String?
    var note = ""
    var source: Source = .manual
    var importedAt: Date?
    var createdAt = Date()

    init(day: FinanceDay, cents: Int, counterparty: String = "", purpose: String = "", type: String = "", iban: String = "", source: Source = .manual) {
        self.day = day
        self.cents = cents
        self.counterparty = counterparty
        self.purpose = purpose
        self.type = type
        self.iban = iban
        self.source = source
    }

    var isIncome: Bool { cents > 0 }

    /// What to show as its name when it has no counterparty (cash, bank fees).
    var displayName: String {
        let name = counterparty.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        if !type.isEmpty { return type }
        return purpose.isEmpty ? "Ohne Empfänger" : String(purpose.prefix(40))
    }

    /// Two bookings with the same key are the same booking imported twice.
    var duplicateKey: String {
        "\(day.iso)|\(cents)|\(FinanceText.fold(counterparty))|\(FinanceText.fold(purpose).prefix(40))"
    }

    private enum Key: String, CodingKey {
        case id, day = "datum", cents = "cent", counterparty = "gegenpartei", purpose = "zweck", type = "art", iban, category = "kategorie"
        case note = "notiz", source = "quelle", importedAt = "importiert", createdAt = "erstellt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = c.soft(.id, UUID())
        day = try c.decode(FinanceDay.self, forKey: .day)
        cents = try c.decode(Int.self, forKey: .cents)
        counterparty = c.soft(.counterparty, "")
        purpose = c.soft(.purpose, "")
        type = c.soft(.type, "")
        iban = c.soft(.iban, "")
        category = c.soft(.category, String?.none)
        note = c.soft(.note, "")
        source = c.soft(.source, Source.manual)
        importedAt = c.soft(.importedAt, Date?.none)
        createdAt = c.soft(.createdAt, Date(timeIntervalSince1970: 0))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(day, forKey: .day)
        try c.encode(cents, forKey: .cents)
        if !counterparty.isEmpty { try c.encode(counterparty, forKey: .counterparty) }
        if !purpose.isEmpty { try c.encode(purpose, forKey: .purpose) }
        if !type.isEmpty { try c.encode(type, forKey: .type) }
        if !iban.isEmpty { try c.encode(iban, forKey: .iban) }
        try c.encodeIfPresent(category, forKey: .category)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(importedAt, forKey: .importedAt)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Categories

struct FinanceCategory: Codable, Identifiable, Hashable, Sendable {
    /// Income and expenses count in the totals; a transfer to one's own savings moves money without spending it.
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case expense = "ausgabe", income = "einnahme", transfer = "umbuchung"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .expense: "Ausgabe"
            case .income: "Einnahme"
            case .transfer: "Umbuchung"
            }
        }

        /// Whether a booking with this sign may get a category of this kind.
        func fits(_ cents: Int) -> Bool {
            switch self {
            case .expense: cents < 0
            case .income: cents > 0
            case .transfer: true
            }
        }
    }

    var key: String
    var name: String
    var kind: Kind
    var symbol: String
    var color: FolderColor
    /// Words in the counterparty or purpose that put a booking here (lower case, without accents).
    var keywords: [String]

    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key = "kuerzel", name, kind = "art", symbol, color = "farbe", keywords = "stichworte"
    }

    init(key: String, name: String, kind: Kind, symbol: String, color: FolderColor, keywords: [String] = []) {
        self.key = key
        self.name = name
        self.kind = kind
        self.symbol = symbol
        self.color = color
        self.keywords = keywords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = c.soft(.name, key)
        kind = c.soft(.kind, Kind.expense)
        symbol = c.soft(.symbol, "tag")
        color = c.soft(.color, FolderColor.blue)
        keywords = c.soft(.keywords, [String]())
    }

    /// The categories a new account starts with. Their keywords are the usual German merchants and words of bank
    /// statements; short ones (`dm`, `o2`) only match as whole words.
    static let defaults: [FinanceCategory] = [
        FinanceCategory(key: "lebensmittel", name: "Lebensmittel", kind: .expense, symbol: "cart", color: .green,
                        keywords: ["rewe", "edeka", "aldi", "lidl", "netto", "penny", "kaufland", "norma", "tegut", "globus", "denns", "alnatura", "bio company", "supermarkt", "marktkauf", "hit markt", "nahkauf", "picnic", "flink"]),
        FinanceCategory(key: "drogerie", name: "Drogerie", kind: .expense, symbol: "drop", color: .teal, keywords: ["dm", "dm drogerie", "rossmann", "budni"]),
        FinanceCategory(key: "wohnen", name: "Wohnen & Energie", kind: .expense, symbol: "house", color: .orange,
                        keywords: ["miete", "hausverwaltung", "wohnungsbau", "wohnungsgesellschaft", "nebenkosten", "stadtwerke", "strom", "vattenfall", "e.on", "eon", "enbw", "rwe", "yello", "lichtblick", "gasag", "beitragsservice", "rundfunk"]),
        FinanceCategory(key: "mobilitaet", name: "Mobilität", kind: .expense, symbol: "car", color: .blue,
                        keywords: ["deutsche bahn", "db vertrieb", "db fernverkehr", "bvg", "mvg", "hvv", "vrs", "kvb", "rmv", "flixbus", "uber", "bolt", "aral", "shell", "esso", "jet tankstelle", "totalenergies", "tankstelle", "sixt", "share now", "miles mobility", "parkhaus", "parken", "adac", "deutschlandticket"]),
        FinanceCategory(key: "versicherungen", name: "Versicherungen", kind: .expense, symbol: "shield", color: .purple,
                        keywords: ["versicherung", "allianz", "huk", "axa", "ergo", "debeka", "generali", "devk", "signal iduna", "r+v", "barmenia", "gothaer", "hanse merkur", "haftpflicht"]),
        FinanceCategory(key: "abos", name: "Abos & Medien", kind: .expense, symbol: "play.rectangle", color: .pink,
                        keywords: ["netflix", "spotify", "disney", "prime video", "amazon prime", "apple.com/bill", "apple services", "itunes", "youtube", "dazn", "sky deutschland", "audible", "icloud", "adobe", "microsoft", "openai", "anthropic", "github", "zeit online", "spiegel"]),
        FinanceCategory(key: "telefon", name: "Telefon & Internet", kind: .expense, symbol: "wifi", color: .teal,
                        keywords: ["telekom", "vodafone", "o2", "telefonica", "1&1", "congstar", "freenet", "mobilcom", "pyur", "m-net", "netcologne"]),
        FinanceCategory(key: "gesundheit", name: "Gesundheit", kind: .expense, symbol: "cross.case", color: .red,
                        keywords: ["apotheke", "arztpraxis", "zahnarzt", "praxis dr", "klinik", "krankenhaus", "optiker", "fielmann", "physiotherapie"]),
        FinanceCategory(key: "restaurants", name: "Restaurants & Cafés", kind: .expense, symbol: "fork.knife", color: .yellow,
                        keywords: ["restaurant", "lieferando", "wolt", "cafe", "café", "mcdonalds", "mc donalds", "burger king", "starbucks", "pizza", "imbiss", "baeckerei", "backerei", "bäckerei", "kantine", "mensa", "doner", "döner"]),
        FinanceCategory(key: "shopping", name: "Shopping", kind: .expense, symbol: "bag", color: .orange,
                        keywords: ["amazon", "zalando", "otto", "ebay", "ikea", "mediamarkt", "media markt", "saturn", "apple store", "h&m", "zara", "decathlon", "about you", "thalia", "hugendubel", "galeria", "tk maxx", "primark", "obi", "bauhaus", "hornbach", "toom"]),
        FinanceCategory(key: "freizeit", name: "Freizeit & Sport", kind: .expense, symbol: "figure.run", color: .green,
                        keywords: ["kino", "cinemaxx", "theater", "fitness", "mcfit", "fitx", "urban sports", "steam", "playstation", "nintendo", "eventim", "ticketmaster", "museum", "verein", "schwimmbad", "bowling"]),
        FinanceCategory(key: "bargeld", name: "Bargeld", kind: .expense, symbol: "banknote", color: .yellow,
                        keywords: ["bargeldauszahlung", "geldautomat", "auszahlung", "atm", "bargeld"]),
        FinanceCategory(key: "gebuehren", name: "Gebühren & Zinsen", kind: .expense, symbol: "building.columns", color: .red,
                        keywords: ["entgelt", "gebühr", "gebuehr", "kontoführung", "kontofuehrung", "rechnungsabschluss", "abschluss", "sollzins", "dispozins", "kartengebühr"]),
        FinanceCategory(key: "steuern", name: "Steuern & Abgaben", kind: .expense, symbol: "doc.text", color: .purple, keywords: ["finanzamt", "steuer", "kfz-steuer", "bundeskasse", "landeshauptkasse"]),
        FinanceCategory(key: "sparen", name: "Sparen & Umbuchung", kind: .transfer, symbol: "arrow.left.arrow.right", color: .blue,
                        keywords: ["umbuchung", "übertrag", "uebertrag", "sparplan", "tagesgeld", "depot", "trade republic", "scalable", "eigenes konto", "eigenuebertrag"]),
        FinanceCategory(key: "gehalt", name: "Gehalt & Lohn", kind: .income, symbol: "briefcase", color: .green, keywords: ["gehalt", "lohn", "bezüge", "bezuege", "besoldung", "salary", "honorar"]),
        FinanceCategory(key: "einnahmen", name: "Sonstige Einnahmen", kind: .income, symbol: "plus.circle", color: .teal,
                        keywords: ["erstattung", "gutschrift", "rückzahlung", "rueckzahlung", "zinsen", "dividende", "kindergeld", "familienkasse", "rente", "bafög", "bafoeg", "elterngeld"]),
    ]
}

/// The person (or the model, on request) said: bookings of this group belong to this category.
struct FinanceAssignment: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case person, model = "ki"
    }

    var group: String
    var category: String
    var source: Source

    private enum CodingKeys: String, CodingKey {
        case group = "gruppe", category = "kategorie", source = "quelle"
    }

    init(group: String, category: String, source: Source) {
        self.group = group
        self.category = category
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decode(String.self, forKey: .group)
        category = try c.decode(String.self, forKey: .category)
        source = c.soft(.source, Source.person)
    }
}

// MARK: - Plan

enum FinanceInterval: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly = "woechentlich", monthly = "monatlich", quarterly = "vierteljaehrlich", halfYearly = "halbjaehrlich", yearly = "jaehrlich"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: "wöchentlich"
        case .monthly: "monatlich"
        case .quarterly: "vierteljährlich"
        case .halfYearly: "halbjährlich"
        case .yearly: "jährlich"
        }
    }

    /// What one payment costs per month on average, in cents.
    func monthly(_ cents: Int) -> Int {
        switch self {
        case .weekly: Int((Double(cents) * 52 / 12).rounded())
        case .monthly: cents
        case .quarterly: Int((Double(cents) / 3).rounded())
        case .halfYearly: Int((Double(cents) / 6).rounded())
        case .yearly: Int((Double(cents) / 12).rounded())
        }
    }

    /// Days between two payments, for spotting the rhythm in bookings.
    var days: ClosedRange<Int> {
        switch self {
        case .weekly: 6...8
        case .monthly: 26...35
        case .quarterly: 84...98
        case .halfYearly: 175...190
        case .yearly: 350...380
        }
    }

    var nominalDays: Int {
        switch self {
        case .weekly: 7
        case .monthly: 30
        case .quarterly: 91
        case .halfYearly: 182
        case .yearly: 365
        }
    }
}

/// A regular income or a fixed cost. Amounts are positive; the list says which it is.
struct FinancePlanEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var cents: Int
    var interval: FinanceInterval = .monthly
    /// Day of the month it is due, if known.
    var dueDay: Int?
    var category: String?
    /// The group of bookings it was taken from (or matches), so its real payments are known.
    var group: String?
    var note = ""

    init(name: String, cents: Int, interval: FinanceInterval = .monthly, dueDay: Int? = nil, category: String? = nil, group: String? = nil) {
        self.name = name
        self.cents = cents
        self.interval = interval
        self.dueDay = dueDay
        self.category = category
        self.group = group
    }

    var monthly: Int { interval.monthly(cents) }

    private enum CodingKeys: String, CodingKey {
        case id, name, cents = "cent", interval = "intervall", dueDay = "tag", category = "kategorie", group = "gruppe", note = "notiz"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        cents = c.soft(.cents, 0)
        interval = c.soft(.interval, FinanceInterval.monthly)
        dueDay = c.soft(.dueDay, Int?.none)
        category = c.soft(.category, String?.none)
        group = c.soft(.group, String?.none)
        note = c.soft(.note, "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(cents, forKey: .cents)
        try c.encode(interval, forKey: .interval)
        try c.encodeIfPresent(dueDay, forKey: .dueDay)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(group, forKey: .group)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
    }
}

/// Something the person wants to buy: a Mac mini for 3.500 €.
struct FinanceProject: Codable, Identifiable, Hashable, Sendable {
    enum Priority: Int, Codable, CaseIterable, Identifiable, Sendable {
        case high = 1, medium = 2, low = 3

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .high: "hoch"
            case .medium: "mittel"
            case .low: "niedrig"
            }
        }
    }

    var id = UUID()
    var name: String
    var cents: Int
    var targetDay: FinanceDay?
    /// What is already put aside for it.
    var saved = 0
    var priority: Priority = .medium
    var note = ""
    var done = false
    var createdAt = Date()

    init(name: String, cents: Int, targetDay: FinanceDay? = nil, priority: Priority = .medium) {
        self.name = name
        self.cents = cents
        self.targetDay = targetDay
        self.priority = priority
    }

    var missing: Int { max(0, cents - saved) }

    private enum CodingKeys: String, CodingKey {
        case id, name, cents = "cent", targetDay = "zieldatum", saved = "angespart", priority = "prioritaet", note = "notiz", done = "erledigt", createdAt = "erstellt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        cents = c.soft(.cents, 0)
        targetDay = c.soft(.targetDay, FinanceDay?.none)
        saved = c.soft(.saved, 0)
        priority = c.soft(.priority, Priority.medium)
        note = c.soft(.note, "")
        done = c.soft(.done, false)
        createdAt = c.soft(.createdAt, Date(timeIntervalSince1970: 0))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(cents, forKey: .cents)
        try c.encodeIfPresent(targetDay, forKey: .targetDay)
        if saved != 0 { try c.encode(saved, forKey: .saved) }
        try c.encode(priority, forKey: .priority)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if done { try c.encode(done, forKey: .done) }
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// An amount to save up: an emergency fund, a holiday.
struct FinanceGoal: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var target: Int
    var saved = 0
    /// What goes into it every month.
    var monthly = 0
    var targetDay: FinanceDay?
    var symbol = "target"
    var color: FolderColor = .blue
    var note = ""
    var createdAt = Date()

    init(name: String, target: Int, saved: Int = 0, monthly: Int = 0, targetDay: FinanceDay? = nil) {
        self.name = name
        self.target = target
        self.saved = saved
        self.monthly = monthly
        self.targetDay = targetDay
    }

    var missing: Int { max(0, target - saved) }
    var progress: Double { target <= 0 ? 1 : min(1, max(0, Double(saved) / Double(target))) }
    var isReached: Bool { saved >= target && target > 0 }

    private enum CodingKeys: String, CodingKey {
        case id, name, target = "ziel", saved = "angespart", monthly = "monatlich", targetDay = "zieldatum", symbol, color = "farbe", note = "notiz", createdAt = "erstellt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        target = c.soft(.target, 0)
        saved = c.soft(.saved, 0)
        monthly = c.soft(.monthly, 0)
        targetDay = c.soft(.targetDay, FinanceDay?.none)
        symbol = c.soft(.symbol, "target")
        color = c.soft(.color, FolderColor.blue)
        note = c.soft(.note, "")
        createdAt = c.soft(.createdAt, Date(timeIntervalSince1970: 0))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(target, forKey: .target)
        try c.encode(saved, forKey: .saved)
        try c.encode(monthly, forKey: .monthly)
        try c.encodeIfPresent(targetDay, forKey: .targetDay)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .color)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        try c.encode(createdAt, forKey: .createdAt)
    }
}

struct FinancePlan: Codable, Hashable, Sendable {
    var income: [FinancePlanEntry] = []
    var fixedCosts: [FinancePlanEntry] = []
    var projects: [FinanceProject] = []
    var goals: [FinanceGoal] = []
    /// Whether the average of the other spending of the last three months comes off what is free each month.
    var countsVariable = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case income = "einkommen", fixedCosts = "fixkosten", projects = "projekte", goals = "sparziele", countsVariable = "variableEinrechnen"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        income = c.soft(.income, [FinancePlanEntry]())
        fixedCosts = c.soft(.fixedCosts, [FinancePlanEntry]())
        projects = c.soft(.projects, [FinanceProject]())
        goals = c.soft(.goals, [FinanceGoal]())
        countsVariable = c.soft(.countsVariable, true)
    }
}

// MARK: - The account

/// The balance the bank showed at the end of a day. Every other day's balance follows from it and the bookings,
/// forwards and backwards, so old bookings can be imported later without the balance going wrong.
struct FinanceBalanceAnchor: Codable, Hashable, Sendable {
    var cents: Int
    var day: FinanceDay

    private enum CodingKeys: String, CodingKey {
        case cents = "cent", day = "datum"
    }
}

struct FinanceAccount: Codable, Hashable, Sendable {
    var name = "Girokonto"
    var bank = ""
    var iban = ""
    var holder = ""
    var currency = "EUR"
    var anchor: FinanceBalanceAnchor?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case name, bank, iban, holder = "inhaber", currency = "waehrung", anchor = "saldo"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.soft(.name, "Girokonto")
        bank = c.soft(.bank, "")
        iban = c.soft(.iban, "")
        holder = c.soft(.holder, "")
        currency = c.soft(.currency, "EUR")
        anchor = c.soft(.anchor, FinanceBalanceAnchor?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !bank.isEmpty { try c.encode(bank, forKey: .bank) }
        if !iban.isEmpty { try c.encode(iban, forKey: .iban) }
        if !holder.isEmpty { try c.encode(holder, forKey: .holder) }
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(anchor, forKey: .anchor)
    }

    /// `DE12 3456 …` with the middle hidden, for headers and the panel.
    var maskedIBAN: String {
        let compact = iban.replacingOccurrences(of: " ", with: "")
        guard compact.count > 8 else { return iban }
        return "\(compact.prefix(4)) •••• \(compact.suffix(4))"
    }
}

/// `Finanzen/finanzen.json`: everything but the bookings.
struct FinanceState: Codable, Hashable, Sendable {
    var format = 1
    var account = FinanceAccount()
    var categories = FinanceCategory.defaults
    var assignments: [FinanceAssignment] = []
    var plan = FinancePlan()
    /// Amounts show as dots (screen sharing, a café).
    var hidesAmounts = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case format, account = "konto", categories = "kategorien", assignments = "zuordnungen", plan = "planung", hidesAmounts = "verbergen"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.soft(.format, 1)
        account = c.soft(.account, FinanceAccount())
        categories = c.soft(.categories, FinanceCategory.defaults)
        assignments = c.soft(.assignments, [FinanceAssignment]())
        plan = c.soft(.plan, FinancePlan())
        hidesAmounts = c.soft(.hidesAmounts, false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(account, forKey: .account)
        try c.encode(categories, forKey: .categories)
        try c.encode(assignments, forKey: .assignments)
        try c.encode(plan, forKey: .plan)
        if hidesAmounts { try c.encode(hidesAmounts, forKey: .hidesAmounts) }
    }

    func category(_ key: String?) -> FinanceCategory? {
        guard let key else { return nil }
        return categories.first { $0.key == key }
    }
}

/// `Finanzen/Buchungen/<yyyy-MM>.json`: the bookings of one month.
struct FinanceMonthFile: Codable, Sendable {
    var format = 1
    var month: String
    var transactions: [FinanceTransaction]

    private enum CodingKeys: String, CodingKey {
        case format, month = "monat", transactions = "buchungen"
    }

    init(month: String, transactions: [FinanceTransaction]) {
        self.month = month
        self.transactions = transactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.soft(.format, 1)
        month = c.soft(.month, "")
        transactions = try c.decode([FinanceTransaction].self, forKey: .transactions)
    }
}
