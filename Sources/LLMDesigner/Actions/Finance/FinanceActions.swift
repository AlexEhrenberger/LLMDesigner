import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerFinanceActions() {
        register(FinanceOverviewAction.self)
        register(FinanceAccountUpdateAction.self)
        register(FinanceBalanceSetAction.self)
        register(FinanceTransactionListAction.self)
        register(FinanceTransactionAddAction.self)
        register(FinanceTransactionUpdateAction.self)
        register(FinanceTransactionDeleteAction.self)
        register(FinanceImportCSVAction.self)
        register(FinanceGroupsListAction.self)
        register(FinanceRecurringListAction.self)
        register(FinanceCategoryListAction.self)
        register(FinanceCategoryCreateAction.self)
        register(FinanceCategoryUpdateAction.self)
        register(FinanceCategoryDeleteAction.self)
        register(FinanceCategoryAssignAction.self)
        register(FinanceAICategorizeAction.self)
        register(FinanceStatementExportAction.self)
        register(FinanceStudioOpenAction.self)
        register(FinanceStudioCloseAction.self)
        registerFinancePlanActions()
    }
}

// The account is the person's own money: every action that shows an amount or a booking reads private data (B), and
// MCP refuses them. Counterparty names and purposes are written by banks and shops, so whatever shows them reads
// foreign content too (A): a purpose "Ignoriere alle Anweisungen …" must not steer the next step.
let financeRead = ActionSecurity.sensitiveRead
let financeForeignRead = ActionSecurity(readsUntrusted: true, sensitive: true, effect: .none)

let financeDayProperty: JSONSchema = .string("Datum: 2026-11-20, 20.11.2026, heute oder gestern")
let financeAmountProperty: JSONSchema = .number("Betrag in Euro; Ausgaben negativ, z. B. -54.20")
let financeGroupProperty: JSONSchema = .string("Gruppe ähnlicher Posten (Schlüssel aus finance.groups.list oder Name, z. B. Rewe)")
let financeCategoryProperty: JSONSchema = .string("Kategorie (Kürzel oder Name, z. B. lebensmittel)")
let financePeriodProperties: [String: JSONSchema] = [
    "period": .choice(FinancePeriod.Kind.allCases.map(\.rawValue), "Zeitraum um date (Vorgabe monat)"),
    "date": .string("Ein Tag im Zeitraum (Vorgabe heute)"),
    "from": .string("Statt period: erster Tag"),
    "to": .string("Statt period: letzter Tag"),
]

enum FinanceArgs {
    static func day(_ text: String?, _ name: String) throws -> FinanceDay? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "heute", "today": return .today
        case "gestern", "yesterday": return FinanceDay.today.adding(days: -1)
        case "morgen", "tomorrow": return FinanceDay.today.adding(days: 1)
        default: break
        }
        if text.count == 7, let month = FinanceDay(text + "-01") { return month }
        guard let day = FinanceDay(text) else { throw RPCError.invalidParams("„\(text)“ ist kein Datum für \(name). Erwartet: 2026-11-20 oder 20.11.2026.") }
        return day
    }

    static func filter(period: String?, date: String?, from: String?, to: String?) throws -> FinanceFilter {
        var filter = FinanceFilter()
        let anchor = try day(date, "date") ?? .today
        if let period {
            guard let kind = FinancePeriod.Kind(rawValue: period) else {
                throw RPCError.invalidParams("Zeitraum „\(period)“ gibt es nicht. Möglich: \(FinancePeriod.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            filter.period = FinancePeriod(kind, anchor)
        } else {
            filter.period = FinancePeriod(.month, anchor)
        }
        filter.from = try day(from, "from")
        filter.to = try day(to, "to")
        if let start = filter.from, let end = filter.to, start > end { throw RPCError.invalidParams("from liegt nach to.") }
        return filter
    }

    static func cents(_ euros: Double?, _ name: String, positive: Bool = false) throws -> Int? {
        guard let euros else { return nil }
        guard euros.isFinite, abs(euros) < 1_000_000_000 else { throw RPCError.invalidParams("\(name) ist kein Betrag.") }
        let cents = FinanceMoney.cents(euros: euros)
        if positive, cents < 0 { throw RPCError.invalidParams("\(name) muss positiv sein.") }
        return cents
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ text: String?, _ type: T.Type, _ name: String) throws -> T? where T.RawValue == String {
        guard let text else { return nil }
        guard let value = T(rawValue: text) else {
            throw RPCError.invalidParams("\(name) „\(text)“ gibt es nicht. Möglich: \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }
}

extension AppModel {
    func actionFinanceBooking(_ reference: String) throws -> FinanceTransaction {
        finance.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: reference), let booking = finance.booking(id) { return booking }
        // The first characters of an id, as lists show them.
        let found = reference.count >= 6 ? finance.bookings.filter { $0.id.uuidString.lowercased().hasPrefix(reference.lowercased()) } : []
        if found.count == 1 { return found[0] }
        if found.count > 1 { throw RPCError.ambiguous("Mehrere Buchungen beginnen mit „\(reference)“.", candidates: found.map(\.id.uuidString)) }
        throw RPCError.notFound("Buchung \(reference) gibt es nicht. Die IDs stehen in finance.transaction.list.")
    }

    func actionFinanceCategory(_ reference: String) throws -> FinanceCategory {
        finance.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespaces)
        let categories = finance.state.categories
        if let category = categories.first(where: { $0.key == reference.lowercased() }) { return category }
        let found = categories.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let partial = categories.filter { $0.name.localizedCaseInsensitiveContains(reference) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw RPCError.ambiguous("Mehrere Kategorien passen zu „\(reference)“.", candidates: partial.map(\.key)) }
        throw RPCError.notFound("Kategorie „\(reference)“ gibt es nicht. finance.category.list zeigt alle.")
    }

    func actionFinanceGroup(_ reference: String) throws -> FinanceGroup {
        let groups = finance.analysis.groups
        let reference = reference.trimmingCharacters(in: .whitespaces)
        if let group = groups[reference] ?? groups[FinanceText.fold(reference)] { return group }
        let found = groups.values.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let folded = FinanceText.fold(reference)
        let partial = groups.values.filter { $0.key.contains(folded) || FinanceText.fold($0.name).contains(folded) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw RPCError.ambiguous("Mehrere Gruppen passen zu „\(reference)“.", candidates: partial.map(\.key).sorted()) }
        throw RPCError.notFound("Eine Gruppe „\(reference)“ gibt es nicht. finance.groups.list zeigt alle.")
    }
}

extension ActionContext {
    /// A change to FinanceStudio's data with its way back, as one call.
    func changeFinance(_ label: String, _ change: () throws -> Void) rethrows {
        let library = app.finance
        library.loadIfNeeded()
        let before = library.snapshot
        try change()
        let after = library.snapshot
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.restore(before) }, redo: { [weak library] in library?.restore(after) }))
        registry.eventSink?(ActionEvent(kind: "finance.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: nil))
    }
}

// MARK: - Output

struct FinanceBookingOutput: Encodable, Sendable {
    var id: String
    var date: String
    var amount: Double
    var formatted: String
    var counterparty: String
    var purpose: String?
    var type: String?
    var category: String?
    var categoryName: String?
    var categorySource: String
    var group: String
    var groupName: String
    var balanceAfter: Double
    var note: String?
    var source: String
}

extension FinanceAnalysis {
    func output(_ entry: FinanceEntry) -> FinanceBookingOutput {
        let booking = entry.booking
        return FinanceBookingOutput(id: booking.id.uuidString, date: booking.day.iso, amount: FinanceMoney.euros(booking.cents),
                                    formatted: FinanceMoney.format(booking.cents, currency: state.account.currency, sign: true),
                                    counterparty: booking.counterparty, purpose: booking.purpose.nonEmpty, type: booking.type.nonEmpty,
                                    category: entry.category, categoryName: state.category(entry.category)?.name, categorySource: entry.categorySource.rawValue,
                                    group: entry.group, groupName: groups[entry.group]?.name ?? booking.displayName,
                                    balanceAfter: FinanceMoney.euros(entry.balanceAfter), note: booking.note.nonEmpty, source: booking.source.rawValue)
    }

    func output(_ group: FinanceGroup) -> FinanceGroupOutput {
        FinanceGroupOutput(key: group.key, name: group.name, count: group.count, total: FinanceMoney.euros(group.total),
                           income: FinanceMoney.euros(group.income), expenses: FinanceMoney.euros(group.expenses),
                           category: group.category, categoryName: state.category(group.category)?.name, first: group.first.iso, last: group.last.iso,
                           recurrence: group.recurrence.map(FinanceRecurrenceOutput.init))
    }
}

struct FinanceRecurrenceOutput: Encodable, Sendable {
    var interval: String
    var amount: Double
    var monthly: Double
    var count: Int
    var last: String
    var next: String
    var dueDay: Int?

    init(_ recurrence: FinanceRecurrence) {
        interval = recurrence.interval.rawValue
        amount = FinanceMoney.euros(recurrence.cents)
        monthly = FinanceMoney.euros(recurrence.interval.monthly(recurrence.cents))
        count = recurrence.count
        last = recurrence.last.iso
        next = recurrence.next.iso
        dueDay = recurrence.dueDay
    }
}

struct FinanceGroupOutput: Encodable, Sendable {
    var key: String
    var name: String
    var count: Int
    var total: Double
    var income: Double
    var expenses: Double
    var category: String?
    var categoryName: String?
    var first: String
    var last: String
    var recurrence: FinanceRecurrenceOutput?
}

struct FinanceTotalsOutput: Encodable, Sendable {
    var income: Double
    var expenses: Double
    var transfers: Double
    var net: Double
    var count: Int

    init(_ totals: FinanceTotals) {
        income = FinanceMoney.euros(totals.income)
        expenses = FinanceMoney.euros(totals.expenses)
        transfers = FinanceMoney.euros(totals.transfers)
        net = FinanceMoney.euros(totals.net)
        count = totals.count
    }
}

struct FinanceCategoryOutput: Encodable, Sendable {
    var key: String
    var name: String
    var kind: String
    var symbol: String
    var color: String
    var keywords: [String]

    init(_ category: FinanceCategory) {
        key = category.key
        name = category.name
        kind = category.kind.rawValue
        symbol = category.symbol
        color = category.color.rawValue
        keywords = category.keywords
    }
}

private func periodTitle(_ filter: FinanceFilter) -> (title: String, from: String?, to: String?) {
    if filter.from != nil || filter.to != nil {
        return ("\(filter.from?.german ?? "Anfang") – \(filter.to?.german ?? "heute")", filter.from?.iso, filter.to?.iso)
    }
    let range = filter.period.range
    return (filter.period.title, range?.lowerBound.iso, range?.upperBound.iso)
}

// MARK: - Overview and account

struct FinanceOverviewAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var period: String?
        var date: String?
        var from: String?
        var to: String?
    }
    struct Output: Encodable, Sendable {
        struct Account: Encodable, Sendable {
            var name: String
            var bank: String?
            var iban: String?
            var currency: String
        }
        var account: Account
        var balance: Double
        var balanceFormatted: String
        var balanceDate: String
        var balanceSetOn: String?
        var period: String
        var from: String?
        var to: String?
        var totals: FinanceTotalsOutput
        var bookings: Int
        var latestBooking: String?
        var uncategorizedGroups: Int
        var freePerMonth: Double
        var forProjectsPerMonth: Double
    }
    static let descriptor = ActionDescriptor(
        id: "finance.overview", summary: "Kontostand, Einnahmen, Ausgaben und Umbuchungen eines Zeitraums und was der Plan im Monat frei lässt (private Daten)",
        kind: .read, security: financeRead,
        input: .object(financePeriodProperties), output: .freeObject(), example: "llmd finance overview --period monat", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.finance
        let filter = try FinanceArgs.filter(period: args.period, date: args.date, from: args.from, to: args.to)
        let analysis = library.analysis
        let account = library.state.account
        let totals = analysis.totals(analysis.filtered(filter))
        let summary = analysis.planSummary()
        let period = periodTitle(filter)
        let balance = analysis.currentBalance
        return Output(account: .init(name: account.name, bank: account.bank.nonEmpty, iban: account.iban.isEmpty ? nil : account.maskedIBAN, currency: account.currency),
                      balance: FinanceMoney.euros(balance), balanceFormatted: FinanceMoney.format(balance, currency: account.currency),
                      balanceDate: FinanceDay.today.iso, balanceSetOn: account.anchor?.day.iso, period: period.title, from: period.from, to: period.to,
                      totals: FinanceTotalsOutput(totals), bookings: analysis.entries.count, latestBooking: analysis.latestDay?.iso,
                      uncategorizedGroups: analysis.groups.values.filter { $0.category == nil }.count,
                      freePerMonth: FinanceMoney.euros(summary.free), forProjectsPerMonth: FinanceMoney.euros(summary.forProjects))
    }
}

struct FinanceAccountUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String?
        var bank: String?
        var iban: String?
        var holder: String?
        var currency: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.account.update", summary: "Ändert Name, Bank, Inhaber, IBAN oder Währung des Kontos", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name, z. B. Girokonto"), "bank": .string("Bank"), "holder": .string("Kontoinhaber"), "iban": .string("IBAN"),
                        "currency": .string("Währung (ISO, Vorgabe EUR)")]),
        output: .freeObject(), example: "llmd finance account update --name Girokonto --bank \"Beispielbank\""
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        if let currency = args.currency, currency.count != 3 { throw RPCError.invalidParams("Die Währung ist ein ISO-Kürzel mit drei Buchstaben, z. B. EUR.") }
        context.changeFinance("Konto ändern") {
            context.app.finance.changeState { state in
                if let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { state.account.name = name }
                if let bank = args.bank { state.account.bank = bank }
                if let holder = args.holder { state.account.holder = holder }
                if let iban = args.iban { state.account.iban = iban.replacingOccurrences(of: " ", with: "").uppercased() }
                if let currency = args.currency { state.account.currency = currency.uppercased() }
            }
        }
        return OKOutput(message: context.app.finance.state.account.name)
    }
}

struct FinanceBalanceSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var amount: Double
        var date: String?
    }
    struct Output: Encodable, Sendable {
        var balance: Double
        var date: String
        var opening: Double
    }
    static let descriptor = ActionDescriptor(
        id: "finance.balance.set", summary: "Gleicht den Kontostand ab: so viel stand am Ende des Tages auf dem Konto; alle anderen Tage folgen aus den Buchungen",
        kind: .write, security: .localWrite,
        input: .object(["amount": .number("Kontostand in Euro"), "date": financeDayProperty], required: ["amount"]),
        output: .freeObject(), example: "llmd finance balance set --amount 2345.67 --date heute"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let day = try FinanceArgs.day(args.date, "date") ?? .today
        let cents = try FinanceArgs.cents(args.amount, "amount") ?? 0
        context.changeFinance("Kontostand abgleichen") {
            context.app.finance.changeState { $0.account.anchor = FinanceBalanceAnchor(cents: cents, day: day) }
        }
        let analysis = context.app.finance.analysis
        return Output(balance: FinanceMoney.euros(analysis.balance(at: day)), date: day.iso, opening: FinanceMoney.euros(analysis.opening))
    }
}

// MARK: - Bookings

struct FinanceTransactionListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var period: String?
        var date: String?
        var from: String?
        var to: String?
        var direction: String?
        var category: String?
        var group: String?
        var query: String?
        var limit: Int?
        var offset: Int?
    }
    struct Output: Encodable, Sendable {
        var period: String
        var from: String?
        var to: String?
        var total: Int
        var totals: FinanceTotalsOutput
        var transactions: [FinanceBookingOutput]
        var more: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "finance.transaction.list",
        summary: "Listet Buchungen nach Zeitraum (tag, woche, monat, jahr, alles oder from/to), Richtung, Kategorie, Gruppe oder Suche, neueste zuerst (private Daten, Texte von Banken und Händlern)",
        kind: .read, security: financeForeignRead,
        input: .object(financePeriodProperties.merging([
            "direction": .choice(FinanceFilter.Direction.allCases.map(\.rawValue), "alle, ausgaben oder einnahmen"),
            "category": .string("Kategorie (Kürzel oder Name); ohne: Buchungen ohne Kategorie"), "group": financeGroupProperty,
            "query": .string("Suche in Empfänger, Verwendungszweck, Notiz und Betrag"),
            "limit": .integer("Höchstens so viele (Vorgabe 50)", minimum: 1, maximum: 1000), "offset": .integer("Überspringt so viele", minimum: 0),
        ]) { first, _ in first }),
        output: .freeObject(), example: "llmd finance transaction list --period monat --direction ausgaben --limit 20", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var filter = try FinanceArgs.filter(period: args.period, date: args.date, from: args.from, to: args.to)
        filter.direction = try FinanceArgs.choice(args.direction, FinanceFilter.Direction.self, "direction") ?? .all
        if let category = args.category {
            filter.category = category == FinanceFilter.uncategorized ? category : try app.actionFinanceCategory(category).key
        }
        if let group = args.group { filter.group = try app.actionFinanceGroup(group).key }
        filter.query = args.query ?? ""
        let analysis = app.finance.analysis
        let found = analysis.filtered(filter)
        let limit = args.limit ?? 50
        let offset = args.offset ?? 0
        let page = found.reversed().dropFirst(offset).prefix(limit)
        let period = periodTitle(filter)
        return Output(period: period.title, from: period.from, to: period.to, total: found.count, totals: FinanceTotalsOutput(analysis.totals(found)),
                      transactions: page.map { analysis.output($0) }, more: offset + page.count < found.count)
    }
}

struct FinanceTransactionAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var amount: Double
        var date: String?
        var counterparty: String?
        var purpose: String?
        var category: String?
        var note: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.transaction.add", summary: "Trägt eine Buchung von Hand ein (Ausgaben negativ)", kind: .write, security: .localWrite,
        input: .object(["amount": financeAmountProperty, "date": financeDayProperty, "counterparty": .string("Empfänger oder Auftraggeber"),
                        "purpose": .string("Verwendungszweck"), "category": financeCategoryProperty, "note": .string("Notiz")], required: ["amount"]),
        output: .freeObject(), example: "llmd finance transaction add --amount -12.50 --counterparty Bäckerei --category restaurants", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceBookingOutput {
        let app = context.app
        let cents = try FinanceArgs.cents(args.amount, "amount") ?? 0
        guard cents != 0 else { throw RPCError.invalidParams("Eine Buchung über 0 € gibt es nicht.") }
        var booking = FinanceTransaction(day: try FinanceArgs.day(args.date, "date") ?? .today, cents: cents,
                                         counterparty: args.counterparty?.trimmingCharacters(in: .whitespaces) ?? "", purpose: args.purpose ?? "")
        if let category = args.category {
            let found = try app.actionFinanceCategory(category)
            guard found.kind.fits(cents) else { throw RPCError.invalidParams("„\(found.name)“ ist eine Kategorie für \(found.kind == .income ? "Einnahmen" : "Ausgaben").") }
            booking.category = found.key
        }
        booking.note = args.note ?? ""
        context.changeFinance("Buchung eintragen") { app.finance.add(booking) }
        let analysis = app.finance.analysis
        guard let entry = analysis.entry(booking.id) else { throw RPCError.internal("Die Buchung ist verschwunden.") }
        return analysis.output(entry)
    }
}

struct FinanceTransactionUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var id: String
        var amount: Double?
        var date: String?
        var counterparty: String?
        var purpose: String?
        var category: String?
        var note: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.transaction.update", summary: "Ändert eine Buchung; category \"\" nimmt die eigene Kategorie weg (dann gilt wieder die der Gruppe)",
        kind: .write, security: .localWrite,
        input: .object(["id": .string("ID der Buchung (oder ihr Anfang)"), "amount": financeAmountProperty, "date": financeDayProperty,
                        "counterparty": .string("Empfänger oder Auftraggeber"), "purpose": .string("Verwendungszweck"), "category": financeCategoryProperty,
                        "note": .string("Notiz")], required: ["id"]),
        output: .freeObject(), example: "llmd finance transaction update --id 1a2b3c4d --category freizeit"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceBookingOutput {
        let app = context.app
        let booking = try app.actionFinanceBooking(args.id)
        var changed = booking
        if let cents = try FinanceArgs.cents(args.amount, "amount") {
            guard cents != 0 else { throw RPCError.invalidParams("Eine Buchung über 0 € gibt es nicht.") }
            changed.cents = cents
        }
        if let day = try FinanceArgs.day(args.date, "date") { changed.day = day }
        if let counterparty = args.counterparty { changed.counterparty = counterparty }
        if let purpose = args.purpose { changed.purpose = purpose }
        if let note = args.note { changed.note = note }
        if let category = args.category {
            if category.isEmpty {
                changed.category = nil
            } else {
                let found = try app.actionFinanceCategory(category)
                guard found.kind.fits(changed.cents) else { throw RPCError.invalidParams("„\(found.name)“ passt nicht zum Vorzeichen der Buchung.") }
                changed.category = found.key
            }
        }
        let result = changed
        context.changeFinance("Buchung ändern") { app.finance.update(booking.id) { $0 = result } }
        let analysis = app.finance.analysis
        guard let entry = analysis.entry(booking.id) else { throw RPCError.internal("Die Buchung ist verschwunden.") }
        return analysis.output(entry)
    }
}

struct FinanceTransactionDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var ids: [String]
    }
    struct Output: Encodable, Sendable {
        var deleted: Int
    }
    static let descriptor = ActionDescriptor(
        id: "finance.transaction.delete", summary: "Löscht Buchungen (rückgängig machbar, solange die App läuft)", kind: .destructive, security: .destructive,
        input: .object(["ids": .array(of: .string("ID"), "IDs der Buchungen")], required: ["ids"]), output: .freeObject(),
        example: "llmd finance transaction delete --ids '[\"1a2b3c4d\"]'"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: "\(args.ids.count) Buchungen")
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let ids = Set(try args.ids.map { try app.actionFinanceBooking($0).id })
        context.changeFinance("Buchungen löschen") { app.finance.remove(ids) }
        return Output(deleted: ids.count)
    }
}

struct FinanceImportCSVAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var file: String?
        var text: String?
        var useBalance: Bool?
    }
    struct Output: Encodable, Sendable {
        var added: Int
        var duplicates: Int
        var skipped: Int
        var from: String?
        var to: String?
        var columns: [String: String]
        var balance: Double?
        var balanceDate: String?
        var message: String
    }
    static let descriptor = ActionDescriptor(
        id: "finance.import.csv",
        summary: "Liest den CSV-Export der Bank (Datei oder Text): erkennt Spalten, Trennzeichen und Kodierung, übernimmt nur neue Buchungen und den Saldo der Datei",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: true, effect: .local),
        input: .object(["file": .string("Pfad der CSV-Datei"), "text": .string("Inhalt der CSV statt einer Datei (z. B. mit --stdin)"),
                        "useBalance": .boolean("Saldo-Spalte als Kontostand übernehmen (Vorgabe ja)")]),
        output: .freeObject(), example: "llmd finance import csv --file ~/Downloads/Umsaetze.csv"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.file ?? "CSV-Text")
        // Only the person names an arbitrary file: a chat, an agent or an MCP client could otherwise read any file into the app.
        if args.file != nil, context.channel.asksBeforeReadingFiles {
            check.needsConsent = "Eine Datei von dieser Stelle der Festplatte würde gelesen und als Buchungen übernommen."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let data: Data
        if let file = args.file {
            let url = ActionExportFolder.expanded(file)
            guard let read = try? Data(contentsOf: url) else { throw RPCError.notFound("Die Datei \(url.path) lässt sich nicht lesen.") }
            data = read
        } else if let text = args.text, !text.isEmpty {
            data = Data(text.utf8)
        } else {
            throw RPCError.invalidParams("Gib file oder text an.")
        }
        var summary: FinanceImportSummary?
        do {
            try context.changeFinance("CSV importieren") {
                summary = try context.app.importFinanceCSV(data, useBalance: args.useBalance ?? true)
            }
        } catch let problem as FinanceCSV.Problem {
            throw RPCError.invalidTarget(problem.localizedDescription)
        }
        guard let summary else { throw RPCError.internal("Der Import hat nichts geliefert.") }
        return Output(added: summary.added, duplicates: summary.duplicates, skipped: summary.skipped, from: summary.from?.iso, to: summary.to?.iso,
                      columns: summary.columns, balance: summary.balance.map { FinanceMoney.euros($0.cents) }, balanceDate: summary.balance?.day.iso,
                      message: summary.message)
    }
}

// MARK: - Groups

struct FinanceGroupsListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var period: String?
        var date: String?
        var from: String?
        var to: String?
        var direction: String?
        var uncategorized: Bool?
        var limit: Int?
    }
    struct Output: Encodable, Sendable {
        var period: String
        var groups: [FinanceGroupOutput]
        var total: Int
    }
    static let descriptor = ActionDescriptor(
        id: "finance.groups.list", summary: "Fasst ähnliche Posten zu Gruppen zusammen (Rewe, Miete, Netflix …) mit Summe, Kategorie und Rhythmus; ohne Zeitraum alle (private Daten)",
        kind: .read, security: financeForeignRead,
        input: .object(financePeriodProperties.merging([
            "direction": .choice(FinanceFilter.Direction.allCases.map(\.rawValue), "alle, ausgaben oder einnahmen"),
            "uncategorized": .boolean("Nur Gruppen ohne Kategorie"), "limit": .integer("Höchstens so viele (Vorgabe 40)", minimum: 1, maximum: 500),
        ]) { first, _ in first }),
        output: .freeObject(), example: "llmd finance groups list --period jahr --direction ausgaben", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var filter = try FinanceArgs.filter(period: args.period ?? FinancePeriod.Kind.all.rawValue, date: args.date, from: args.from, to: args.to)
        filter.direction = try FinanceArgs.choice(args.direction, FinanceFilter.Direction.self, "direction") ?? .all
        let analysis = context.app.finance.analysis
        var groups = analysis.groups(of: analysis.filtered(filter))
        if args.uncategorized == true { groups = groups.filter { $0.category == nil } }
        return Output(period: periodTitle(filter).title, groups: groups.prefix(args.limit ?? 40).map { analysis.output($0) }, total: groups.count)
    }
}

struct FinanceRecurringListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            var group: FinanceGroupOutput
            var inPlan: Bool
        }
        var recurring: [Item]
        var monthlyExpenses: Double
        var monthlyIncome: Double
    }
    static let descriptor = ActionDescriptor(
        id: "finance.recurring.list", summary: "Zeigt wiederkehrende Zahlungen und Eingänge (Abos, Miete, Gehalt) mit Rhythmus, üblichem Betrag und nächstem Termin (private Daten)",
        kind: .read, security: financeForeignRead, output: .freeObject(), example: "llmd finance recurring list"
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let analysis = context.app.finance.analysis
        let planned = analysis.plannedGroups
        let recurring = analysis.recurring
        let monthly = recurring.compactMap { $0.recurrence.map { $0.interval.monthly($0.cents) } }
        return Output(recurring: recurring.map { Output.Item(group: analysis.output($0), inPlan: planned.contains($0.key)) },
                      monthlyExpenses: FinanceMoney.euros(monthly.filter { $0 < 0 }.reduce(0, +)), monthlyIncome: FinanceMoney.euros(monthly.filter { $0 > 0 }.reduce(0, +)))
    }
}

// MARK: - Categories

struct FinanceCategoryListAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var categories: [FinanceCategoryOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "finance.category.list", summary: "Listet die Kategorien mit Art (ausgabe, einnahme, umbuchung) und Stichworten", kind: .read, security: .plainRead,
        output: .freeObject(), example: "llmd finance category list"
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.finance.loadIfNeeded()
        return Output(categories: context.app.finance.state.categories.map(FinanceCategoryOutput.init))
    }
}

struct FinanceCategoryCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var kind: String?
        var key: String?
        var keywords: [String]?
        var symbol: String?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.category.create", summary: "Legt eine Kategorie an; Buchungen mit einem ihrer Stichworte landen darin", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "kind": .choice(FinanceCategory.Kind.allCases.map(\.rawValue), "Art (Vorgabe ausgabe)"),
                        "key": .string("Kürzel (sonst aus dem Namen)"), "keywords": .array(of: .string("Stichwort"), "Stichworte"),
                        "symbol": .string("SF Symbol"), "color": .choice(FolderColor.allCases.map(\.rawValue), "Farbe")], required: ["name"]),
        output: .freeObject(), example: "llmd finance category create --name Haustier --keywords '[\"fressnapf\",\"tierarzt\"]'"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceCategoryOutput {
        let library = context.app.finance
        library.loadIfNeeded()
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RPCError.invalidParams("Die Kategorie braucht einen Namen.") }
        let taken = Set(library.state.categories.map(\.key)).union([FinanceFilter.uncategorized])
        let key: String
        if let wanted = args.key {
            key = DataKey.make(from: wanted, fallback: "kategorie")
            guard !taken.contains(key) else { throw RPCError.invalidParams("Das Kürzel „\(key)“ gibt es schon.") }
        } else {
            key = DataKey.unique(DataKey.make(from: name, fallback: "kategorie"), taken: taken)
        }
        let category = FinanceCategory(key: key, name: name, kind: try FinanceArgs.choice(args.kind, FinanceCategory.Kind.self, "kind") ?? .expense,
                                       symbol: args.symbol ?? "tag", color: try FinanceArgs.choice(args.color, FolderColor.self, "color") ?? .blue,
                                       keywords: (args.keywords ?? []).map(FinanceText.fold).filter { !$0.isEmpty })
        context.changeFinance("Kategorie anlegen") { library.changeState { $0.categories.append(category) } }
        return FinanceCategoryOutput(category)
    }
}

struct FinanceCategoryUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var category: String
        var name: String?
        var kind: String?
        var keywords: [String]?
        var addKeywords: [String]?
        var removeKeywords: [String]?
        var symbol: String?
        var color: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.category.update", summary: "Ändert eine Kategorie: Name, Art, Stichworte (ersetzen, hinzufügen, entfernen), Symbol, Farbe", kind: .write, security: .localWrite,
        input: .object(["category": financeCategoryProperty, "name": .string("Neuer Name"), "kind": .choice(FinanceCategory.Kind.allCases.map(\.rawValue), "Art"),
                        "keywords": .array(of: .string("Stichwort"), "Alle Stichworte neu"), "addKeywords": .array(of: .string("Stichwort"), "Stichworte dazu"),
                        "removeKeywords": .array(of: .string("Stichwort"), "Stichworte weg"), "symbol": .string("SF Symbol"),
                        "color": .choice(FolderColor.allCases.map(\.rawValue), "Farbe")], required: ["category"]),
        output: .freeObject(), example: "llmd finance category update --category lebensmittel --add-keywords '[\"wochenmarkt\"]'"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceCategoryOutput {
        let library = context.app.finance
        let found = try context.app.actionFinanceCategory(args.category)
        let kind = try FinanceArgs.choice(args.kind, FinanceCategory.Kind.self, "kind")
        let color = try FinanceArgs.choice(args.color, FolderColor.self, "color")
        context.changeFinance("Kategorie ändern") {
            library.changeState { state in
                guard let index = state.categories.firstIndex(where: { $0.key == found.key }) else { return }
                var category = state.categories[index]
                if let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { category.name = name }
                if let kind { category.kind = kind }
                if let keywords = args.keywords { category.keywords = keywords.map(FinanceText.fold).filter { !$0.isEmpty } }
                for word in (args.addKeywords ?? []).map(FinanceText.fold) where !word.isEmpty && !category.keywords.contains(word) { category.keywords.append(word) }
                let removed = Set((args.removeKeywords ?? []).map(FinanceText.fold))
                category.keywords.removeAll { removed.contains(FinanceText.fold($0)) }
                if let symbol = args.symbol { category.symbol = symbol }
                if let color { category.color = color }
                state.categories[index] = category
            }
        }
        return FinanceCategoryOutput(library.state.category(found.key) ?? found)
    }
}

struct FinanceCategoryDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var category: String
    }
    static let descriptor = ActionDescriptor(
        id: "finance.category.delete", summary: "Löscht eine Kategorie; ihre Buchungen und Zuordnungen verlieren sie", kind: .destructive, security: .destructive,
        input: .object(["category": financeCategoryProperty], required: ["category"]), output: .freeObject(), example: "llmd finance category delete --category haustier"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let library = context.app.finance
        let found = try context.app.actionFinanceCategory(args.category)
        context.changeFinance("Kategorie löschen") {
            library.changeState { state in
                state.categories.removeAll { $0.key == found.key }
                state.assignments.removeAll { $0.category == found.key }
                for index in state.plan.fixedCosts.indices where state.plan.fixedCosts[index].category == found.key { state.plan.fixedCosts[index].category = nil }
            }
            library.changeBookings { list in
                for index in list.indices where list[index].category == found.key { list[index].category = nil }
            }
        }
        return OKOutput(id: found.key)
    }
}

struct FinanceCategoryAssignAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var category: String?
        var group: String?
        var transaction: String?
    }
    struct Output: Encodable, Sendable {
        var category: String?
        var affected: Int
    }
    static let descriptor = ActionDescriptor(
        id: "finance.category.assign",
        summary: "Ordnet einer Gruppe (alle ihre Buchungen, auch künftige) oder einer einzelnen Buchung eine Kategorie zu; ohne category wird die Zuordnung gelöst",
        kind: .write, security: .localWrite,
        input: .object(["category": financeCategoryProperty, "group": financeGroupProperty, "transaction": .string("ID einer einzelnen Buchung")]),
        output: .freeObject(), example: "llmd finance category assign --group rewe --category lebensmittel"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let library = app.finance
        let category = try args.category.flatMap { $0.isEmpty ? nil : try app.actionFinanceCategory($0) }
        if let reference = args.transaction {
            let booking = try app.actionFinanceBooking(reference)
            if let category, !category.kind.fits(booking.cents) { throw RPCError.invalidParams("„\(category.name)“ passt nicht zum Vorzeichen der Buchung.") }
            context.changeFinance("Kategorie zuordnen") { library.update(booking.id) { $0.category = category?.key } }
            return Output(category: category?.key, affected: 1)
        }
        guard let reference = args.group else { throw RPCError.invalidParams("Gib group oder transaction an.") }
        let group = try app.actionFinanceGroup(reference)
        context.changeFinance("Kategorie zuordnen") { library.assign(group: group.key, category: category?.key) }
        let affected = library.analysis.entries.filter { $0.group == group.key && $0.category == category?.key }.count
        return Output(category: category?.key, affected: affected)
    }
}

struct FinanceAICategorizeAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var limit: Int?
    }
    struct Output: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            var group: String
            var name: String
            var category: String
        }
        var assigned: [Item]
        var stillUncategorized: Int
    }
    static let descriptor = ActionDescriptor(
        id: "finance.ai.categorize", summary: "Lässt das lokale Modell Gruppen ohne Kategorie einordnen; die Vorschläge lassen sich mit finance.category.assign ändern",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: true, effect: .local),
        input: .object(["limit": .integer("Höchstens so viele Gruppen (Vorgabe 60)", minimum: 1, maximum: 200)]), output: .freeObject(),
        example: "llmd finance ai categorize"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let library = app.finance
        library.loadIfNeeded()
        guard !library.categorizing else { throw RPCError.unavailable("Das Modell ordnet gerade schon ein.") }
        let before = library.snapshot
        let made = try await app.categorizeFinanceWithModel(limit: args.limit ?? 60)
        let after = library.snapshot
        context.undoGroup.add(UndoStep(label: "Mit KI einordnen", undo: { [weak library] in library?.restore(before) }, redo: { [weak library] in library?.restore(after) }))
        let analysis = library.analysis
        return Output(assigned: made.map { Output.Item(group: $0.group, name: analysis.groups[$0.group]?.name ?? $0.group, category: $0.category) },
                      stillUncategorized: analysis.groups.values.filter { $0.category == nil }.count)
    }
}

// MARK: - Statement and studio

struct FinanceStatementExportAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var from: String?
        var to: String?
        var period: String?
        var date: String?
        var path: String?
        var overwrite: Bool?
    }
    struct Output: Encodable, Sendable {
        var path: String
        var bytes: Int
        var bookings: Int
        var opening: Double
        var closing: Double
    }
    static let descriptor = ActionDescriptor(
        id: "finance.statement.export", summary: "Schreibt einen Kontoauszug als PDF: Anfangssaldo, alle Buchungen mit Saldo, Endsaldo (Vorgabe: der laufende Monat)",
        kind: .destructive, security: .outbound,
        input: .object(financePeriodProperties.merging([
            "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen"),
        ]) { first, _ in first }),
        output: .freeObject(), example: "llmd finance statement export --from 2026-10-01 --to 2026-10-31"
    )
    static func range(_ args: Args) throws -> ClosedRange<FinanceDay> {
        let filter = try FinanceArgs.filter(period: args.period, date: args.date, from: args.from, to: args.to)
        if filter.from != nil || filter.to != nil {
            return (filter.from ?? FinanceDay(year: 1900, month: 1, day: 1))...(filter.to ?? .today)
        }
        return filter.period.range ?? (FinanceDay(year: 1900, month: 1, day: 1)...FinanceDay.today)
    }
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let range = try range(args)
        // The statement carries the account's bookings, with names and purposes written by others.
        return context.exportPreflight(path: args.path, readsUntrusted: true, readsSensitive: true, detail: "Kontoauszug \(range.lowerBound.german) – \(range.upperBound.german)")
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var range = try range(args)
        let analysis = context.app.finance.analysis
        // "Alles" begins with the first booking, not in 1900.
        if range.lowerBound.year == 1900, let first = analysis.entries.first?.booking.day { range = first...range.upperBound }
        let made = context.app.financeStatementPDF(from: range.lowerBound, to: range.upperBound)
        let url = try context.exportURL(named: made.statement.fileName, extension: "pdf", path: args.path, overwrite: args.overwrite)
        try made.data.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: made.data.count, bookings: made.statement.rows.count,
                      opening: FinanceMoney.euros(made.statement.opening), closing: FinanceMoney.euros(made.statement.closing))
    }
}

struct FinanceStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var tab: String?
        var period: String?
        var date: String?
        var category: String?
        var group: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.studio.open", summary: "Öffnet FinanceStudio, auf Wunsch bei Konto oder Planung, einem Zeitraum, einer Kategorie oder Gruppe", kind: .read, security: .plainRead,
        input: .object(["tab": .choice(FinanceStudioTab.allCases.map(\.rawValue), "konto oder planung"),
                        "period": .choice(FinancePeriod.Kind.allCases.map(\.rawValue), "Zeitraum"), "date": financeDayProperty,
                        "category": financeCategoryProperty, "group": financeGroupProperty]),
        output: .freeObject(), example: "llmd finance studio open --tab planung", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        var command = FinanceStudioCommand()
        command.tab = try FinanceArgs.choice(args.tab, FinanceStudioTab.self, "tab")
        if let period = try FinanceArgs.choice(args.period, FinancePeriod.Kind.self, "period") {
            command.period = FinancePeriod(period, try FinanceArgs.day(args.date, "date") ?? .today)
        }
        command.category = try args.category.map { try app.actionFinanceCategory($0).key }
        command.group = try args.group.map { try app.actionFinanceGroup($0).key }
        app.openFinanceStudio(command)
        return OKOutput()
    }
}

struct FinanceStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "finance.studio.close", summary: "Schließt FinanceStudio", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeFinanceStudio()
        return OKOutput()
    }
}
