import Foundation

/// A stretch of days the table, the chart and the statement look at.
struct FinancePeriod: Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case day = "tag", week = "woche", month = "monat", year = "jahr", all = "alles"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "Tag"
            case .week: "Woche"
            case .month: "Monat"
            case .year: "Jahr"
            case .all: "Alles"
            }
        }
    }

    var kind: Kind
    /// Any day inside the period.
    var anchor: FinanceDay

    init(_ kind: Kind, _ anchor: FinanceDay = .today) {
        self.kind = kind
        self.anchor = anchor
    }

    /// Nil for "Alles".
    var range: ClosedRange<FinanceDay>? {
        switch kind {
        case .day: anchor...anchor
        case .week: anchor.weekStart...anchor.weekStart.adding(days: 6)
        case .month: anchor.firstOfMonth...anchor.lastOfMonth
        case .year: anchor.firstOfYear...anchor.lastOfYear
        case .all: nil
        }
    }

    func contains(_ day: FinanceDay) -> Bool { range?.contains(day) ?? true }

    func shifted(by steps: Int) -> FinancePeriod {
        switch kind {
        case .day: FinancePeriod(kind, anchor.adding(days: steps))
        case .week: FinancePeriod(kind, anchor.adding(days: 7 * steps))
        case .month: FinancePeriod(kind, anchor.firstOfMonth.adding(months: steps))
        case .year: FinancePeriod(kind, FinanceDay(year: anchor.year + steps, month: 1, day: 1))
        case .all: self
        }
    }

    var title: String {
        switch kind {
        case .day: anchor.german
        case .week: "KW \(anchor.weekOfYear) · \(anchor.weekStart.short)–\(anchor.weekStart.adding(days: 6).german)"
        case .month: anchor.monthTitle
        case .year: String(anchor.year)
        case .all: "Alle Buchungen"
        }
    }
}

/// What the table shows.
struct FinanceFilter: Hashable, Sendable {
    enum Direction: String, CaseIterable, Identifiable, Sendable {
        case all = "alle", expenses = "ausgaben", income = "einnahmen"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Alle"
            case .expenses: "Ausgaben"
            case .income: "Einnahmen"
            }
        }
    }

    var period = FinancePeriod(.month)
    /// Instead of the period, from–to (a statement, an action).
    var from: FinanceDay?
    var to: FinanceDay?
    var direction: Direction = .all
    /// A category key, or `ohne` for bookings without one.
    var category: String?
    var group: String?
    var query = ""

    static let uncategorized = "ohne"

    func contains(_ day: FinanceDay) -> Bool {
        if from != nil || to != nil {
            if let from, day < from { return false }
            if let to, day > to { return false }
            return true
        }
        return period.contains(day)
    }
}

/// One bar of the chart: what came in and went out in a day, week or month.
struct FinanceBucket: Identifiable, Hashable, Sendable {
    var start: FinanceDay
    var end: FinanceDay
    var label: String
    var income = 0
    var expenses = 0
    var balance = 0

    var id: FinanceDay { start }
    var net: Int { income + expenses }
}

/// Income, expenses and transfers of a stretch of days. Transfers (to one's own savings) aren't spending.
struct FinanceTotals: Hashable, Sendable {
    var income = 0
    var expenses = 0
    var transfers = 0
    var count = 0

    var net: Int { income + expenses + transfers }
}

/// What the plan leaves each month, and when projects and goals come within reach.
struct FinancePlanSummary: Hashable, Sendable {
    struct ProjectLine: Hashable, Sendable {
        var project: FinanceProject
        /// The month from which it is paid for, if the money left over reaches it at all.
        var affordable: FinanceDay?
        /// Before its target day (nil without one).
        var onTime: Bool?
    }

    struct GoalLine: Hashable, Sendable {
        var goal: FinanceGoal
        /// When it is full at its monthly rate.
        var reached: FinanceDay?
        /// What it would need each month to be full by its target day.
        var neededMonthly: Int?
    }

    var income = 0
    var fixedCosts = 0
    /// Average of the other spending of the last three full months.
    var variable = 0
    var countsVariable = true
    var savingRates = 0
    var projects: [ProjectLine] = []
    var goals: [GoalLine] = []

    /// Left after fixed costs (and the usual other spending).
    var free: Int { income - fixedCosts - (countsVariable ? variable : 0) }
    /// Left after the savings rates too: what projects can count on.
    var forProjects: Int { free - savingRates }
}

/// FinanceStudio's data: `Finanzen/finanzen.json` and one file per month in `Finanzen/Buchungen/`. Kept in memory,
/// written half a second after a change on a queue of its own. Everything the views show about a booking (its group,
/// its category, the balance after it) is worked out again after each change, so a new rule applies to all bookings
/// at once and nothing derived can go stale in a file.
@MainActor
@Observable
final class FinanceLibrary {
    private(set) var state = FinanceState()
    private(set) var bookings: [FinanceTransaction] = []
    private(set) var revision = 0
    /// Groups the model is sorting into categories right now.
    var categorizing = false

    @ObservationIgnored let folder: URL
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stateDirty = false
    @ObservationIgnored private var bookingsDirty = false
    /// What each month file holds on disk, so a save only writes the months that changed.
    @ObservationIgnored private var written: [String: [FinanceTransaction]] = [:]
    @ObservationIgnored private let writer = DispatchQueue(label: "LLMDesigner.FinanceLibrary", qos: .utility)
    @ObservationIgnored private var cachedAnalysis: (revision: Int, value: FinanceAnalysis)?

    init(folder: URL = AppLibrary.current.folder("Finanzen")) {
        self.folder = folder
    }

    var stateURL: URL { folder.appendingPathComponent("finanzen.json") }
    var bookingsFolder: URL { folder.appendingPathComponent("Buchungen", isDirectory: true) }

    // MARK: Loading and saving

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: stateURL) {
            do {
                state = try decoder.decode(FinanceState.self, from: data)
            } catch {
                print("LLMDesigner: finanzen.json konnte nicht gelesen werden: \(error)")
            }
        }
        var all: [FinanceTransaction] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: bookingsFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let month = try decoder.decode(FinanceMonthFile.self, from: Data(contentsOf: file))
                written[file.deletingPathExtension().lastPathComponent] = month.transactions
                all += month.transactions
            } catch {
                print("LLMDesigner: \(file.path) konnte nicht gelesen werden: \(error)")
            }
        }
        bookings = Self.sorted(all)
        revision += 1
    }

    /// Oldest first; bookings of one day in the order they came.
    private static func sorted(_ bookings: [FinanceTransaction]) -> [FinanceTransaction] {
        bookings.sorted { ($0.day, $0.createdAt, $0.id.uuidString) < ($1.day, $1.createdAt, $1.id.uuidString) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save(wait: false)
        }
    }

    private func save(wait: Bool) {
        saveTask = nil
        var work: [@Sendable () -> Void] = []
        if stateDirty {
            stateDirty = false
            let state = state
            let url = stateURL
            work.append {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.encoder.encode(state).write(to: url, options: .atomic)
                } catch {
                    print("LLMDesigner: finanzen.json konnte nicht gespeichert werden: \(error)")
                }
            }
        }
        if bookingsDirty {
            bookingsDirty = false
            let months = Dictionary(grouping: bookings, by: \.day.monthKey)
            let folder = bookingsFolder
            for (month, list) in months where written[month] != list {
                written[month] = list
                work.append {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try Self.encoder.encode(FinanceMonthFile(month: month, transactions: list)).write(to: folder.appendingPathComponent("\(month).json"), options: .atomic)
                    } catch {
                        print("LLMDesigner: Buchungen \(month) konnten nicht gespeichert werden: \(error)")
                    }
                }
            }
            for month in written.keys where months[month] == nil {
                written[month] = nil
                work.append { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(month).json")) }
            }
        }
        guard !work.isEmpty else { return }
        let steps = work
        let job: @Sendable () -> Void = { for step in steps { step() } }
        if wait { writer.sync(execute: job) } else { writer.async(execute: job) }
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    var hasPendingSave: Bool { saveTask != nil }

    func saveAll() {
        guard saveTask != nil || stateDirty || bookingsDirty else { return }
        saveTask?.cancel()
        save(wait: true)
    }

    // MARK: Changing

    /// The state and bookings at one moment, for undo.
    struct Snapshot: Sendable {
        var state: FinanceState
        var bookings: [FinanceTransaction]
    }

    var snapshot: Snapshot { Snapshot(state: state, bookings: bookings) }

    func restore(_ snapshot: Snapshot) {
        loadIfNeeded()
        if snapshot.state != state { state = snapshot.state; stateDirty = true }
        if snapshot.bookings != bookings { bookings = snapshot.bookings; bookingsDirty = true }
        changed()
    }

    private func changed() {
        revision += 1
        scheduleSave()
    }

    func changeState(_ change: (inout FinanceState) -> Void) {
        loadIfNeeded()
        var copy = state
        change(&copy)
        guard copy != state else { return }
        state = copy
        stateDirty = true
        changed()
    }

    func changeBookings(_ change: (inout [FinanceTransaction]) -> Void) {
        loadIfNeeded()
        var copy = bookings
        change(&copy)
        guard copy != bookings else { return }
        bookings = Self.sorted(copy)
        bookingsDirty = true
        changed()
    }

    /// A change the person can take back with ⌘Z.
    func change(_ label: String, undo undoManager: UndoManager?, _ change: () -> Void) {
        let before = snapshot
        change()
        let after = snapshot
        guard before.state != after.state || before.bookings != after.bookings else { return }
        registerUndo(undoManager, label: label, restoring: before, over: after)
    }

    private func registerUndo(_ undoManager: UndoManager?, label: String, restoring old: Snapshot, over new: Snapshot) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated {
                library.restore(old)
                library.registerUndo(undoManager, label: label, restoring: new, over: old)
            }
        }
        undoManager.setActionName(label)
    }

    func booking(_ id: UUID) -> FinanceTransaction? {
        bookings.first { $0.id == id }
    }

    @discardableResult
    func add(_ booking: FinanceTransaction) -> FinanceTransaction {
        changeBookings { $0.append(booking) }
        return booking
    }

    func update(_ id: UUID, _ change: (inout FinanceTransaction) -> Void) {
        changeBookings { list in
            if let index = list.firstIndex(where: { $0.id == id }) { change(&list[index]) }
        }
    }

    func remove(_ ids: Set<UUID>) {
        changeBookings { $0.removeAll { ids.contains($0.id) } }
    }

    /// What an import added and what it left out.
    struct ImportResult: Sendable {
        var added: [FinanceTransaction]
        var duplicates: Int
    }

    /// Adds bookings that aren't there yet. Two equal coffees on one day are two bookings: a booking counts as known
    /// only as often as it is already there, so importing an overlapping export adds what is new and nothing twice.
    func importBookings(_ incoming: [FinanceTransaction]) -> ImportResult {
        loadIfNeeded()
        var known: [String: Int] = [:]
        for booking in bookings { known[booking.duplicateKey, default: 0] += 1 }
        var added: [FinanceTransaction] = []
        var duplicates = 0
        for booking in incoming {
            let key = booking.duplicateKey
            if let count = known[key], count > 0 {
                known[key] = count - 1
                duplicates += 1
            } else {
                added.append(booking)
            }
        }
        if !added.isEmpty { changeBookings { $0 += added } }
        return ImportResult(added: added, duplicates: duplicates)
    }

    /// The person's choice for all bookings of a group; nil takes it back.
    func assign(group: String, category: String?, source: FinanceAssignment.Source = .person) {
        changeState { state in
            state.assignments.removeAll { $0.group == group && (source == .person || $0.source == .model) }
            if let category { state.assignments.append(FinanceAssignment(group: group, category: category, source: source)) }
        }
    }

    // MARK: What follows from the bookings

    var analysis: FinanceAnalysis {
        loadIfNeeded()
        if let cached = cachedAnalysis, cached.revision == revision { return cached.value }
        let value = FinanceAnalysis(state: state, bookings: bookings, today: .today)
        cachedAnalysis = (revision, value)
        return value
    }

    var currency: String { state.account.currency }

    func format(_ cents: Int, sign: Bool = false, whole: Bool = false) -> String {
        state.hidesAmounts ? "•••• \(currency == "EUR" ? "€" : currency)" : FinanceMoney.format(cents, currency: currency, sign: sign, whole: whole)
    }
}

/// Everything worked out from the bookings: groups, categories, balances. Made once per change.
struct FinanceAnalysis: Sendable {
    let state: FinanceState
    /// Oldest first.
    let entries: [FinanceEntry]
    let groups: [String: FinanceGroup]
    let today: FinanceDay
    /// The balance before the first booking.
    let opening: Int
    private let index: [UUID: Int]

    init(state: FinanceState, bookings: [FinanceTransaction], today: FinanceDay) {
        self.state = state
        self.today = today
        let categorizer = FinanceCategorizer(state: state)
        var keyCache: [String: String] = [:]
        var keys: [String] = []
        keys.reserveCapacity(bookings.count)
        for booking in bookings {
            let cacheKey = booking.counterparty + "\u{1F}" + booking.type + "\u{1F}" + (booking.counterparty.isEmpty || FinanceGrouping.isProcessor(booking.counterparty) ? booking.purpose : "")
            if let key = keyCache[cacheKey] {
                keys.append(key)
            } else {
                let key = FinanceGrouping.key(counterparty: booking.counterparty, purpose: booking.purpose, type: booking.type)
                keyCache[cacheKey] = key
                keys.append(key)
            }
        }
        // The anchor fixes the balance at the end of its day; everything before and after follows from the bookings.
        var opening = 0
        if let anchor = state.account.anchor {
            let upToAnchor = bookings.reduce(0) { $1.day <= anchor.day ? $0 + $1.cents : $0 }
            opening = anchor.cents - upToAnchor
        }
        self.opening = opening
        var running = opening
        var entries: [FinanceEntry] = []
        entries.reserveCapacity(bookings.count)
        for (booking, key) in zip(bookings, keys) {
            running += booking.cents
            let category = categorizer.category(of: booking, group: key)
            entries.append(FinanceEntry(booking: booking, group: key, category: category.key, categorySource: category.source, balanceAfter: running))
        }
        self.entries = entries
        index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })

        var groups: [String: FinanceGroup] = [:]
        let byGroup = Dictionary(grouping: entries, by: \.group)
        for (key, members) in byGroup {
            // A shop paid through PayPal is named after the shop, which only the key knows.
            let direct = members.map(\.booking).filter { !FinanceGrouping.isProcessor($0.counterparty) }
            let name = direct.isEmpty && !FinanceGrouping.isProcessor(key) ? key.capitalized
                : FinanceGrouping.displayName(of: (direct.isEmpty ? members.map(\.booking) : direct).map(\.displayName))
            let expenses = members.filter { $0.booking.cents < 0 }
            let income = members.filter { $0.booking.cents > 0 }
            // The bigger side decides the rhythm: a refund now and then doesn't make rent irregular.
            let side = expenses.count >= income.count ? expenses : income
            var categoryCounts: [String: Int] = [:]
            for member in members { if let category = member.category { categoryCounts[category, default: 0] += 1 } }
            groups[key] = FinanceGroup(key: key, name: name, count: members.count,
                                       income: income.reduce(0) { $0 + $1.booking.cents }, expenses: expenses.reduce(0) { $0 + $1.booking.cents },
                                       category: categoryCounts.max { $0.value < $1.value }?.key,
                                       first: members.first!.booking.day, last: members.last!.booking.day,
                                       recurrence: FinanceRecurrence.detect(side.map(\.booking), today: today))
        }
        self.groups = groups
    }

    func entry(_ id: UUID) -> FinanceEntry? { index[id].map { entries[$0] } }

    var latestDay: FinanceDay? { entries.last?.booking.day }

    /// The balance at the end of a day.
    func balance(at day: FinanceDay) -> Int {
        // The last entry on or before the day; the entries are sorted by day.
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].booking.day <= day { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? opening : entries[low - 1].balanceAfter
    }

    /// Now: after every booking up to today (bookings dated later are announced, not done).
    var currentBalance: Int { balance(at: max(today, state.account.anchor?.day ?? today)) }

    func kind(of entry: FinanceEntry) -> FinanceCategory.Kind {
        state.category(entry.category)?.kind ?? (entry.booking.cents < 0 ? .expense : .income)
    }

    func totals(_ entries: some Sequence<FinanceEntry>) -> FinanceTotals {
        var totals = FinanceTotals()
        for entry in entries {
            totals.count += 1
            switch kind(of: entry) {
            case .transfer: totals.transfers += entry.booking.cents
            case .income, .expense:
                if entry.booking.cents < 0 { totals.expenses += entry.booking.cents } else { totals.income += entry.booking.cents }
            }
        }
        return totals
    }

    func filtered(_ filter: FinanceFilter) -> [FinanceEntry] {
        let query = FinanceText.fold(filter.query.trimmingCharacters(in: .whitespaces))
        return entries.filter { entry in
            let booking = entry.booking
            guard filter.contains(booking.day) else { return false }
            switch filter.direction {
            case .all: break
            case .expenses: guard booking.cents < 0 else { return false }
            case .income: guard booking.cents > 0 else { return false }
            }
            if let category = filter.category {
                if category == FinanceFilter.uncategorized { guard entry.category == nil else { return false } } else { guard entry.category == category else { return false } }
            }
            if let group = filter.group, entry.group != group { return false }
            if !query.isEmpty {
                let text = FinanceText.fold(booking.counterparty + " " + booking.purpose + " " + booking.type + " " + booking.note + " " + (groups[entry.group]?.name ?? ""))
                guard text.contains(query) || FinanceMoney.plain(booking.cents).contains(query) else { return false }
            }
            return true
        }
    }

    /// Groups of the entries, biggest amount first.
    func groups(of entries: [FinanceEntry]) -> [FinanceGroup] {
        let byGroup = Dictionary(grouping: entries, by: \.group)
        return byGroup.compactMap { key, members -> FinanceGroup? in
            guard var group = groups[key] else { return nil }
            group.count = members.count
            group.income = members.filter { $0.booking.cents > 0 }.reduce(0) { $0 + $1.booking.cents }
            group.expenses = members.filter { $0.booking.cents < 0 }.reduce(0) { $0 + $1.booking.cents }
            group.first = members.first!.booking.day
            group.last = members.last!.booking.day
            return group
        }.sorted { abs($0.total) > abs($1.total) }
    }

    /// The bars of the chart around a period: 14 days, 12 weeks, 12 months, or all months.
    func buckets(around period: FinancePeriod) -> [FinanceBucket] {
        var starts: [(FinanceDay, FinanceDay, String)] = []
        switch period.kind {
        case .day:
            for offset in stride(from: -13, through: 0, by: 1) {
                let day = period.anchor.adding(days: offset)
                starts.append((day, day, day.short))
            }
        case .week:
            for offset in stride(from: -11, through: 0, by: 1) {
                let start = period.anchor.weekStart.adding(days: 7 * offset)
                starts.append((start, start.adding(days: 6), "KW \(start.weekOfYear)"))
            }
        case .month:
            for offset in stride(from: -11, through: 0, by: 1) {
                let start = period.anchor.firstOfMonth.adding(months: offset)
                starts.append((start, start.lastOfMonth, start.shortMonthTitle))
            }
        case .year:
            for month in 1...12 {
                let start = FinanceDay(year: period.anchor.year, month: month, day: 1)
                starts.append((start, start.lastOfMonth, FinanceDay.shortMonthNames[month - 1]))
            }
        case .all:
            guard let first = entries.first?.booking.day else { return [] }
            let last = max(today, entries.last!.booking.day)
            let months = first.months(to: last)
            if months > 48 {
                for year in first.year...last.year {
                    let start = FinanceDay(year: year, month: 1, day: 1)
                    starts.append((start, start.lastOfYear, String(year)))
                }
            } else {
                for offset in 0...months {
                    let start = first.firstOfMonth.adding(months: offset)
                    starts.append((start, start.lastOfMonth, start.shortMonthTitle))
                }
            }
        }
        return starts.map { start, end, label in
            let sum = totals(entries(from: start, to: end))
            return FinanceBucket(start: start, end: end, label: label, income: sum.income, expenses: sum.expenses, balance: balance(at: end))
        }
    }

    /// The entries from one day to another, both included.
    func entries(from: FinanceDay, to: FinanceDay) -> ArraySlice<FinanceEntry> {
        func firstIndex(after day: FinanceDay, inclusive: Bool) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                let current = entries[middle].booking.day
                if inclusive ? current < day : current <= day { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let start = firstIndex(after: from, inclusive: true)
        let end = firstIndex(after: to, inclusive: false)
        return start < end ? entries[start..<end] : []
    }

    /// Groups that come back at a steady rhythm, the biggest first.
    var recurring: [FinanceGroup] {
        groups.values.filter { $0.recurrence != nil }.sorted { abs($0.recurrence!.interval.monthly($0.recurrence!.cents)) > abs($1.recurrence!.interval.monthly($1.recurrence!.cents)) }
    }

    // MARK: The plan

    func planSummary() -> FinancePlanSummary {
        let plan = state.plan
        var summary = FinancePlanSummary()
        summary.income = plan.income.reduce(0) { $0 + $1.monthly }
        summary.fixedCosts = plan.fixedCosts.reduce(0) { $0 + $1.monthly }
        summary.countsVariable = plan.countsVariable
        summary.variable = variableSpending()
        summary.savingRates = plan.goals.filter { !$0.isReached }.reduce(0) { $0 + $1.monthly }

        // Projects in the order of their priority and day: each waits for the ones before it.
        let monthStart = today.firstOfMonth
        var needed = 0
        for project in plan.projects.sorted(by: { ($0.done ? 1 : 0, $0.priority.rawValue, $0.targetDay ?? FinanceDay(year: 2200, month: 1, day: 1), $0.createdAt) < ($1.done ? 1 : 0, $1.priority.rawValue, $1.targetDay ?? FinanceDay(year: 2200, month: 1, day: 1), $1.createdAt) }) {
            guard !project.done else {
                summary.projects.append(.init(project: project, affordable: nil, onTime: nil))
                continue
            }
            needed += project.missing
            var affordable: FinanceDay?
            if needed == 0 {
                affordable = today
            } else if summary.forProjects > 0 {
                let months = Int((Double(needed) / Double(summary.forProjects)).rounded(.up))
                affordable = monthStart.adding(months: months)
            }
            let onTime = project.targetDay.map { target in affordable.map { $0 <= target } ?? false }
            summary.projects.append(.init(project: project, affordable: affordable, onTime: onTime))
        }

        for goal in plan.goals {
            var reached: FinanceDay?
            if goal.isReached {
                reached = today
            } else if goal.monthly > 0 {
                reached = monthStart.adding(months: Int((Double(goal.missing) / Double(goal.monthly)).rounded(.up)))
            }
            var neededMonthly: Int?
            if let target = goal.targetDay, !goal.isReached {
                let months = max(1, today.months(to: target))
                neededMonthly = Int((Double(goal.missing) / Double(months)).rounded(.up))
            }
            summary.goals.append(.init(goal: goal, reached: reached, neededMonthly: neededMonthly))
        }
        return summary
    }

    /// The groups the fixed costs and the income of the plan stand for: their bookings aren't "other" spending.
    var plannedGroups: Set<String> {
        Set((state.plan.fixedCosts + state.plan.income).compactMap(\.group))
    }

    /// Average spending per month of the last three full months, without fixed costs and transfers.
    func variableSpending() -> Int {
        let planned = plannedGroups
        let end = today.firstOfMonth.adding(days: -1)
        let start = today.firstOfMonth.adding(months: -3)
        guard let first = entries.first?.booking.day, first <= end else { return 0 }
        let months = max(1, min(3, max(first, start).months(to: end) + 1))
        let spent = entries(from: max(first, start), to: end).filter { entry in
            entry.booking.cents < 0 && kind(of: entry) == .expense && !planned.contains(entry.group)
        }.reduce(0) { $0 + $1.booking.cents }
        return -spent / months
    }

    /// Rhythms of the bookings that the plan doesn't have yet: candidates for fixed costs and income.
    var planSuggestions: [FinanceGroup] {
        let planned = plannedGroups
        return recurring.filter { !planned.contains($0.key) && kind(ofGroup: $0) != .transfer }
    }

    func kind(ofGroup group: FinanceGroup) -> FinanceCategory.Kind {
        state.category(group.category)?.kind ?? ((group.recurrence?.cents ?? group.total) < 0 ? .expense : .income)
    }
}
