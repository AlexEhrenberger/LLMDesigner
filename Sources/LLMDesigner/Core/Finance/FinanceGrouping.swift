import Foundation

/// Text of bookings made comparable: lower case, umlauts written out, no accents, single spaces.
enum FinanceText {
    static func fold(_ text: String) -> String {
        var text = text.lowercased()
        for (umlaut, plain) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            text = text.replacingOccurrences(of: umlaut, with: plain)
        }
        text = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `keyword` stands in `text` as a word of its own (both already folded). `dm` must not match "admiral".
    static func contains(_ text: String, word keyword: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        var start = text.startIndex
        while let range = text.range(of: keyword, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let isBoundary: (Character?) -> Bool = { character in
                guard let character else { return true }
                return !(character.isLetter || character.isNumber)
            }
            // Long keywords may begin a longer word ("versicherung" in "versicherungsbeitrag"); short ones may not.
            if isBoundary(before), isBoundary(after) || keyword.count >= 6 { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }
}

/// Finding bookings that belong together: the same shop under three spellings, the monthly rent, the subscription.
enum FinanceGrouping {
    /// Legal forms, filler and payment words that say nothing about who it is.
    private static let noise: Set<String> = [
        "gmbh", "mbh", "ag", "se", "kg", "kgaa", "ohg", "ug", "ek", "eg", "ev", "gbr", "co", "und", "inc", "ltd", "llc", "limited",
        "sarl", "sa", "sca", "bv", "nv", "ab", "as", "plc", "corp", "corporation", "company", "holding", "group",
        "deutschland", "germany", "europe", "eu", "international", "services", "service", "payments", "payment", "zahlung", "sagt", "danke", "dankt",
        "filiale", "fil", "markt", "nr", "sepa", "lastschrift", "kartenzahlung", "girocard", "debitk", "visa", "mastercard", "et", "cie", "the",
        "online", "www", "com", "de", "net", "org",
    ]

    /// First words that need the next one to say who it is ("Deutsche Bahn", "Cafe Kranzler").
    private static let generic: Set<String> = ["deutsche", "die", "der", "das", "stadt", "cafe", "restaurant", "hotel", "praxis", "dr", "baeckerei", "autohaus", "apotheke", "bistro", "bar", "kiosk", "bio"]

    /// Who stands behind a payment through these is in the purpose: "PayPal … Ihr Einkauf bei Spotify".
    private static let processors = ["paypal", "klarna", "sumup", "stripe", "adyen", "google pay", "apple pay", "unzer", "mollie", "computop", "payone", "concardis", "worldline"]

    /// Whether the counterparty only passes the money on; the group then takes its name from the purpose.
    static func isProcessor(_ counterparty: String) -> Bool {
        let name = FinanceText.fold(counterparty)
        return processors.contains { name.contains($0) }
    }

    /// The key of a booking's group. Bookings without a counterparty (cash, fees) group by their type.
    static func key(counterparty: String, purpose: String, type: String) -> String {
        var name = FinanceText.fold(counterparty)
        if name.isEmpty { name = FinanceText.fold(type.isEmpty ? String(purpose.prefix(30)) : type) }
        if let processor = processors.first(where: { name.contains($0) }) {
            if let merchant = merchant(in: FinanceText.fold(purpose)) {
                name = merchant
            } else {
                return processor
            }
        }
        let words = tokens(name)
        guard let first = words.first else { return name.isEmpty ? "ohne-namen" : name }
        if first.count >= 4, !generic.contains(first) || words.count == 1 { return first }
        return words.prefix(2).joined(separator: " ")
    }

    /// Words that name someone: no legal forms, no numbers or store ids, no single letters.
    static func tokens(_ folded: String) -> [String] {
        // `amazon.de` is Amazon, `e.on` is one word, `h&m` too.
        var text = folded.replacingOccurrences(of: #"\.(de|com|net|org|eu|io|at|ch)\b"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=[a-z0-9])[.&](?=[a-z0-9])"#, with: "", options: .regularExpression)
        return text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { word in
            word.count > 1 && !noise.contains(word) && !word.contains(where: \.isNumber)
        }
    }

    private static func merchant(in purpose: String) -> String? {
        let patterns = [#"(?:ihr einkauf bei|einkauf bei|zahlung an|bei)\s+([a-z0-9&.\- ]{2,40})"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: purpose, range: NSRange(purpose.startIndex..., in: purpose)),
                  let range = Range(match.range(at: 1), in: purpose) else { continue }
            let found = String(purpose[range]).components(separatedBy: CharacterSet(charactersIn: ",/")).first ?? ""
            let words = tokens(found)
            if !words.isEmpty { return words.prefix(3).joined(separator: " ") }
        }
        return nil
    }

    /// A name for people: the most frequent spelling, without legal forms, in the case it was written.
    static func displayName(of names: [String]) -> String {
        var counts: [String: Int] = [:]
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            counts[trimmed, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.count > $1.key.count) })?.key else { return "Ohne Namen" }
        // Legal forms and store numbers ("REWE City 0815") say nothing about who it is.
        let words = best.split(separator: " ").filter { word in
            !noise.contains(FinanceText.fold(String(word)).replacingOccurrences(of: ".", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ",()")))
                && !word.contains(where: \.isNumber)
        }
        let cleaned = words.prefix(4).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.-/*"))
        return cleaned.isEmpty ? best : cleaned
    }
}

/// How often and how much a group comes back.
struct FinanceRecurrence: Hashable, Sendable {
    var interval: FinanceInterval
    /// The usual amount (negative for expenses).
    var cents: Int
    var count: Int
    var last: FinanceDay
    var next: FinanceDay
    /// Usual day of the month, for monthly ones.
    var dueDay: Int?

    /// Bookings of one group (all of one sign) that come back at a steady rhythm with a similar amount. Three are
    /// needed for weekly and monthly ones, two for the longer rhythms. A rhythm that stopped (nothing in one and a
    /// half intervals before `today`) isn't a fixed cost any more.
    static func detect(_ bookings: [FinanceTransaction], today: FinanceDay) -> FinanceRecurrence? {
        guard bookings.count >= 2 else { return nil }
        let sorted = bookings.sorted { $0.day < $1.day }
        // The amounts of a subscription may change a little (a price rise), not by half.
        let amounts = sorted.map(\.cents).sorted()
        let median = amounts[amounts.count / 2]
        let similar = sorted.filter { abs($0.cents - median) <= max(200, abs(median) / 7) }
        // A fixed cost is most of what a group pays; a supermarket visited every week with a similar bill once a
        // month is not one.
        guard similar.count >= 2, Double(similar.count) >= Double(sorted.count) * 0.75 else { return nil }
        // Several bookings on one day are one payment for the rhythm.
        var days: [FinanceDay] = []
        for booking in similar where days.last != booking.day { days.append(booking.day) }
        guard days.count >= 2 else { return nil }
        let gaps = zip(days, days.dropFirst()).map { $0.days(to: $1) }.sorted()
        let gap = gaps[gaps.count / 2]
        guard let interval = FinanceInterval.allCases.first(where: { $0.days.contains(gap) }) else { return nil }
        let needed = interval == .weekly || interval == .monthly ? 3 : 2
        guard days.count >= needed else { return nil }
        // Most gaps must fit the rhythm, or it is chance (three coffees a month apart).
        let fitting = gaps.filter { interval.days.contains($0) || interval.days.contains($0 / 2) }.count
        guard Double(fitting) >= Double(gaps.count) * 0.6 else { return nil }
        let last = days.last!
        guard last.days(to: today) <= interval.nominalDays * 3 / 2 + 5 else { return nil }
        let typical = similar.map(\.cents).sorted()[similar.count / 2]
        let next: FinanceDay
        switch interval {
        case .weekly: next = last.adding(days: 7)
        case .monthly: next = last.adding(months: 1)
        case .quarterly: next = last.adding(months: 3)
        case .halfYearly: next = last.adding(months: 6)
        case .yearly: next = last.adding(months: 12)
        }
        let dueDay: Int? = interval == .monthly ? days.map(\.day).sorted()[days.count / 2] : nil
        return FinanceRecurrence(interval: interval, cents: typical, count: similar.count, last: last, next: next, dueDay: dueDay)
    }
}

/// Where a booking's category comes from, strongest first.
enum FinanceCategorySource: String, Sendable {
    case booking = "buchung", person, model = "ki", keyword = "stichwort", none = "keine"

    var label: String {
        switch self {
        case .booking: "von dir für diese Buchung"
        case .person: "von dir für alle dieser Gruppe"
        case .model: "vom Modell vorgeschlagen"
        case .keyword: "aus einem Stichwort"
        case .none: "keine"
        }
    }
}

/// Puts bookings into categories: the person's choice for one booking, then their choice for its group, then the
/// model's suggestion, then the keywords of the categories. A category only takes bookings of its sign.
struct FinanceCategorizer: Sendable {
    let categories: [FinanceCategory]
    private let byKey: [String: FinanceCategory]
    private let assigned: [String: FinanceAssignment]

    init(state: FinanceState) {
        categories = state.categories
        byKey = Dictionary(state.categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var assigned: [String: FinanceAssignment] = [:]
        // The person's word beats the model's for the same group.
        for assignment in state.assignments where assigned[assignment.group]?.source != .person {
            assigned[assignment.group] = assignment
        }
        self.assigned = assigned
    }

    func category(of booking: FinanceTransaction, group: String) -> (key: String?, source: FinanceCategorySource) {
        if let key = booking.category, byKey[key] != nil { return (key, .booking) }
        if let assignment = assigned[group], let category = byKey[assignment.category], category.kind.fits(booking.cents) {
            return (assignment.category, assignment.source == .person ? .person : .model)
        }
        let name = FinanceText.fold(booking.counterparty)
        let rest = FinanceText.fold(booking.purpose + " " + booking.type)
        // The counterparty says more than the purpose: a refund from Amazon is still Amazon.
        for text in [name, rest] where !text.isEmpty {
            for category in categories where category.kind.fits(booking.cents) {
                if category.keywords.contains(where: { FinanceText.contains(text, word: FinanceText.fold($0)) }) { return (category.key, .keyword) }
            }
        }
        return (nil, .none)
    }
}

/// A booking with what the app worked out about it.
struct FinanceEntry: Identifiable, Hashable, Sendable {
    var booking: FinanceTransaction
    var group: String
    var category: String?
    var categorySource: FinanceCategorySource
    /// Balance at the end of this booking (bookings of a day in their order).
    var balanceAfter: Int

    var id: UUID { booking.id }
}

/// Bookings of one group, summed up.
struct FinanceGroup: Identifiable, Hashable, Sendable {
    var key: String
    var name: String
    var count: Int
    var income: Int
    var expenses: Int
    var category: String?
    var first: FinanceDay
    var last: FinanceDay
    var recurrence: FinanceRecurrence?

    var id: String { key }
    var total: Int { income + expenses }
    var average: Int { count == 0 ? 0 : total / count }
}
