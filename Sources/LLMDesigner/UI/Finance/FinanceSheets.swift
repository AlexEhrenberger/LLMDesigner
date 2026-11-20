import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An entry of the plan being made or changed.
enum FinancePlanDraft {
    case income(FinancePlanEntry)
    case fixedCost(FinancePlanEntry)
    case project(FinanceProject)
    case goal(FinanceGoal)

    var id: UUID {
        switch self {
        case .income(let entry), .fixedCost(let entry): entry.id
        case .project(let project): project.id
        case .goal(let goal): goal.id
        }
    }

    var title: String {
        switch self {
        case .income: "Einkommen"
        case .fixedCost: "Fixkosten"
        case .project: "Ausgabeprojekt"
        case .goal: "Sparziel"
        }
    }

    /// A fixed cost or an income from a group whose rhythm the bookings show.
    static func from(group: FinanceGroup, analysis: FinanceAnalysis) -> FinancePlanDraft {
        let recurrence = group.recurrence
        let cents = abs(recurrence?.cents ?? group.average)
        let entry = FinancePlanEntry(name: group.name, cents: cents, interval: recurrence?.interval ?? .monthly, dueDay: recurrence?.dueDay,
                                     category: group.category, group: group.key)
        return (recurrence?.cents ?? group.total) < 0 ? .fixedCost(entry) : .income(entry)
    }
}

struct FinanceSheetView: View {
    let sheet: FinanceSheet
    let model: FinanceStudioModel

    var body: some View {
        switch sheet {
        case .booking(let booking): FinanceBookingEditor(original: booking)
        case .balance: FinanceBalanceSheet()
        case .account: FinanceAccountSheet()
        case .statement: FinanceStatementSheet(filter: model.filter)
        case .categories: FinanceCategoriesSheet()
        case .plan(let draft): FinancePlanEditor(draft: draft)
        }
    }
}

/// The frame of every sheet here: a title, the form, and the buttons at the bottom.
private struct FinanceSheetFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 440
    var canSave = true
    var saveTitle = "Sichern"
    var destructive: (title: String, action: () -> Void)?
    let save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack {
                if let destructive {
                    Button(destructive.title, role: .destructive) {
                        destructive.action()
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

private struct FinanceFormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 118, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Booking

private struct FinanceBookingEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let original: FinanceTransaction?
    @State private var day = FinanceDay.today
    @State private var amount: Int?
    @State private var isExpense = true
    @State private var counterparty = ""
    @State private var purpose = ""
    @State private var category: String?
    @State private var note = ""

    var body: some View {
        let finance = app.finance
        let signed = amount.map { isExpense ? -abs($0) : abs($0) }
        FinanceSheetFrame(title: original == nil ? "Buchung eintragen" : "Buchung bearbeiten",
                          subtitle: original?.source == .csv ? "Aus dem CSV-Import vom \(original?.importedAt.map { FinanceDay($0).german } ?? "–")." : nil,
                          canSave: (signed ?? 0) != 0,
                          destructive: original.map { booking in ("Löschen", { finance.change("Buchung löschen", undo: undoManager) { finance.remove([booking.id]) } }) },
                          save: save) {
            VStack(alignment: .leading, spacing: 10) {
                FinanceFormRow(label: "Art") {
                    Picker("", selection: $isExpense) {
                        Text("Ausgabe").tag(true)
                        Text("Einnahme").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                FinanceFormRow(label: "Betrag") {
                    HStack(spacing: 6) {
                        FinanceAmountField(placeholder: "0,00", cents: $amount, width: 130)
                        Text(finance.currency).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                FinanceFormRow(label: "Datum") {
                    DatePicker("", selection: FinanceDay.binding($day), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                }
                FinanceFormRow(label: isExpense ? "Empfänger" : "Auftraggeber") { StudioField(placeholder: "z. B. Bäckerei Beispiel", text: $counterparty) }
                FinanceFormRow(label: "Verwendungszweck") { StudioField(placeholder: "optional", text: $purpose) }
                FinanceFormRow(label: "Kategorie") {
                    Menu {
                        FinanceCategoryItems(categories: finance.state.categories, cents: signed ?? (isExpense ? -1 : 1), none: "Nach Gruppe und Stichworten") { category = $0 }
                    } label: {
                        FinanceCategoryChip(category: finance.state.category(category))
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                FinanceFormRow(label: "Notiz") { StudioField(placeholder: "optional", text: $note) }
            }
        }
        .onAppear {
            guard let original else { return }
            day = original.day
            amount = abs(original.cents)
            isExpense = original.cents < 0
            counterparty = original.counterparty
            purpose = original.purpose
            category = original.category
            note = original.note
        }
    }

    private func save() {
        guard let amount else { return }
        let finance = app.finance
        let cents = isExpense ? -abs(amount) : abs(amount)
        let fits = finance.state.category(category)?.kind.fits(cents) ?? true
        if var booking = original {
            booking.day = day
            booking.cents = cents
            booking.counterparty = counterparty.trimmingCharacters(in: .whitespaces)
            booking.purpose = purpose
            booking.category = fits ? category : nil
            booking.note = note
            let changed = booking
            finance.change("Buchung ändern", undo: undoManager) { finance.update(changed.id) { $0 = changed } }
        } else {
            var booking = FinanceTransaction(day: day, cents: cents, counterparty: counterparty.trimmingCharacters(in: .whitespaces), purpose: purpose)
            booking.category = fits ? category : nil
            booking.note = note
            finance.change("Buchung eintragen", undo: undoManager) { finance.add(booking) }
        }
    }
}

// MARK: - Balance and account

private struct FinanceBalanceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var amount: Int?
    @State private var day = FinanceDay.today
    @State private var negative = false

    var body: some View {
        let finance = app.finance
        let computed = finance.analysis.balance(at: day)
        FinanceSheetFrame(title: "Kontostand abgleichen",
                          subtitle: "Trag ein, was die Bank am Ende dieses Tages als Kontostand zeigt. Alle anderen Tage rechnet FinanceStudio aus den Buchungen vor- und rückwärts.",
                          canSave: amount != nil, save: {
                              guard let amount else { return }
                              let cents = negative ? -abs(amount) : abs(amount)
                              finance.change("Kontostand abgleichen", undo: undoManager) {
                                  finance.changeState { $0.account.anchor = FinanceBalanceAnchor(cents: cents, day: day) }
                              }
                          }) {
            VStack(alignment: .leading, spacing: 10) {
                FinanceFormRow(label: "Kontostand") {
                    HStack(spacing: 6) {
                        Toggle("im Minus", isOn: $negative).toggleStyle(.checkbox)
                        FinanceAmountField(placeholder: "0,00", cents: $amount, width: 130)
                        Text(finance.currency).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                FinanceFormRow(label: "am Ende von") {
                    DatePicker("", selection: FinanceDay.binding($day), displayedComponents: .date).labelsHidden().fixedSize()
                }
                FinanceFormRow(label: "") {
                    FinanceHint(text: "Aus den Buchungen ergibt sich für diesen Tag bisher \(FinanceMoney.format(computed, currency: finance.currency)).")
                }
            }
        }
        .onAppear {
            if let anchor = finance.state.account.anchor {
                amount = abs(anchor.cents)
                negative = anchor.cents < 0
            }
        }
    }
}

private struct FinanceAccountSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var account = FinanceAccount()

    var body: some View {
        let finance = app.finance
        FinanceSheetFrame(title: "Konto", subtitle: "Diese Angaben stehen im Kopf des Kontoauszugs.", canSave: !account.name.trimmingCharacters(in: .whitespaces).isEmpty, save: {
            let changed = account
            finance.change("Konto ändern", undo: undoManager) {
                finance.changeState { state in
                    let anchor = state.account.anchor
                    state.account = changed
                    state.account.anchor = anchor
                    state.account.iban = changed.iban.replacingOccurrences(of: " ", with: "").uppercased()
                    state.account.currency = changed.currency.uppercased()
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                FinanceFormRow(label: "Name") { StudioField(placeholder: "Girokonto", text: $account.name) }
                FinanceFormRow(label: "Inhaber") { StudioField(placeholder: "optional", text: $account.holder) }
                FinanceFormRow(label: "Bank") { StudioField(placeholder: "optional", text: $account.bank) }
                FinanceFormRow(label: "IBAN") { StudioField(placeholder: "optional", text: $account.iban, monospaced: true) }
                FinanceFormRow(label: "Währung") { StudioField(placeholder: "EUR", text: $account.currency).frame(width: 80) }
            }
        }
        .onAppear { account = finance.state.account }
    }
}

// MARK: - Statement

private struct FinanceStatementSheet: View {
    @Environment(AppModel.self) private var app
    let filter: FinanceFilter
    @State private var from = FinanceDay.today.firstOfMonth
    @State private var to = FinanceDay.today
    @State private var openAfter = true
    @State private var error: String?

    private enum Preset: String, CaseIterable, Identifiable {
        case shown, thisMonth, lastMonth, thisQuarter, thisYear, lastYear

        var id: String { rawValue }
        var title: String {
            switch self {
            case .shown: "Wie in der Tabelle"
            case .thisMonth: "Dieser Monat"
            case .lastMonth: "Letzter Monat"
            case .thisQuarter: "Dieses Quartal"
            case .thisYear: "Dieses Jahr"
            case .lastYear: "Letztes Jahr"
            }
        }
    }

    var body: some View {
        let finance = app.finance
        let analysis = finance.analysis
        let valid = from <= to
        let statement = valid ? FinanceStatement.make(analysis, from: from, to: to) : nil
        FinanceSheetFrame(title: "Kontoauszug als PDF", subtitle: "Anfangssaldo, alle Buchungen mit dem Saldo danach und der Endsaldo – für einen Zeitraum, den du wählst.",
                          canSave: valid, saveTitle: "Sichern …", save: { export() }) {
            VStack(alignment: .leading, spacing: 10) {
                FinanceFormRow(label: "Zeitraum") {
                    Menu("Schnellwahl") {
                        ForEach(Preset.allCases) { preset in Button(preset.title) { apply(preset) } }
                    }
                    .fixedSize()
                }
                FinanceFormRow(label: "Von") { DatePicker("", selection: FinanceDay.binding($from), displayedComponents: .date).labelsHidden().fixedSize() }
                FinanceFormRow(label: "Bis") { DatePicker("", selection: FinanceDay.binding($to), displayedComponents: .date).labelsHidden().fixedSize() }
                if let statement {
                    FinanceFormRow(label: "") {
                        FinanceHint(text: "\(statement.rows.count) Buchungen · Anfangssaldo \(FinanceMoney.format(statement.opening, currency: finance.currency)) · Endsaldo \(FinanceMoney.format(statement.closing, currency: finance.currency))",
                                    symbol: "doc.text")
                    }
                } else {
                    FinanceFormRow(label: "") { FinanceHint(text: "„Von“ liegt nach „Bis“.", symbol: "exclamationmark.triangle") }
                }
                FinanceFormRow(label: "") { Toggle("Danach öffnen", isOn: $openAfter).toggleStyle(.checkbox) }
                if let error { FinanceFormRow(label: "") { FinanceHint(text: error, symbol: "exclamationmark.triangle") } }
            }
        }
        .onAppear { apply(.shown) }
    }

    private func apply(_ preset: Preset) {
        let today = FinanceDay.today
        switch preset {
        case .shown:
            if filter.from != nil || filter.to != nil {
                from = filter.from ?? app.finance.analysis.entries.first?.booking.day ?? today
                to = filter.to ?? today
            } else if let range = filter.period.range {
                from = range.lowerBound
                to = min(range.upperBound, max(today, range.lowerBound))
            } else {
                from = app.finance.analysis.entries.first?.booking.day ?? today
                to = today
            }
        case .thisMonth: from = today.firstOfMonth; to = today
        case .lastMonth: from = today.firstOfMonth.adding(months: -1); to = from.lastOfMonth
        case .thisQuarter: from = FinanceDay(year: today.year, month: (today.month - 1) / 3 * 3 + 1, day: 1); to = today
        case .thisYear: from = today.firstOfYear; to = today
        case .lastYear: from = FinanceDay(year: today.year - 1, month: 1, day: 1); to = from.lastOfYear
        }
    }

    private func export() {
        let made = app.financeStatementPDF(from: from, to: to)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = made.statement.fileName + ".pdf"
        panel.directoryURL = ActionExportFolder.url(settings: app.settings)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try made.data.write(to: url, options: .atomic)
            if openAfter { NSWorkspace.shared.open(url) }
        } catch {
            app.exportError = "Der Kontoauszug ließ sich nicht sichern: \(error.localizedDescription)"
        }
    }
}

// MARK: - Categories

private struct FinanceCategoriesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var categories: [FinanceCategory] = []
    @State private var keywordTexts: [String: String] = [:]

    var body: some View {
        let finance = app.finance
        FinanceSheetFrame(title: "Kategorien", subtitle: "Buchungen kommen in eine Kategorie, wenn ein Stichwort im Empfänger oder Verwendungszweck steht – außer du hast der Buchung oder ihrer Gruppe selbst eine gegeben.",
                          width: 640, save: save) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($categories) { $category in
                        HStack(alignment: .top, spacing: 8) {
                            Menu {
                                ForEach(FolderColor.allCases, id: \.self) { color in
                                    Button { category.color = color } label: { Label { Text(color.name) } icon: { Image(nsImage: color.swatch) } }
                                }
                            } label: {
                                Image(systemName: category.symbol).foregroundStyle(category.color.color).frame(width: 22, height: 22)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    StudioField(placeholder: "Name", text: $category.name)
                                    Picker("", selection: $category.kind) {
                                        ForEach(FinanceCategory.Kind.allCases) { kind in Text(kind.label).tag(kind) }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                StudioField(placeholder: "Stichworte, mit Komma getrennt", text: Binding(
                                    get: { keywordTexts[category.key] ?? category.keywords.joined(separator: ", ") },
                                    set: { keywordTexts[category.key] = $0 }), font: .system(size: 11.5))
                            }
                            IconButton(systemName: "trash", help: "Kategorie löschen", size: 11, frameSize: 24) {
                                let key = category.key
                                categories.removeAll { $0.key == key }
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .frame(height: 380)
            Button {
                let taken = Set(categories.map(\.key))
                let key = DataKey.unique("kategorie", taken: taken)
                categories.append(FinanceCategory(key: key, name: "Neue Kategorie", kind: .expense, symbol: "tag", color: FolderColor.allCases[categories.count % FolderColor.allCases.count]))
            } label: {
                Label("Kategorie hinzufügen", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { categories = finance.state.categories }
    }

    private func save() {
        let finance = app.finance
        var result = categories
        for index in result.indices {
            if let text = keywordTexts[result[index].key] {
                result[index].keywords = text.split(separator: ",").map { FinanceText.fold(String($0)) }.filter { !$0.isEmpty }
            }
            if result[index].name.trimmingCharacters(in: .whitespaces).isEmpty { result[index].name = result[index].key }
        }
        let kept = Set(result.map(\.key))
        finance.change("Kategorien ändern", undo: undoManager) {
            finance.changeState { state in
                state.categories = result
                state.assignments.removeAll { !kept.contains($0.category) }
            }
            finance.changeBookings { list in
                for index in list.indices where list[index].category.map({ !kept.contains($0) }) ?? false { list[index].category = nil }
            }
        }
    }
}

// MARK: - Plan

struct FinancePlanEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let draft: FinancePlanDraft
    @State private var name = ""
    @State private var amount: Int?
    @State private var interval = FinanceInterval.monthly
    @State private var dueDay = 0
    @State private var category: String?
    @State private var targetDay = FinanceDay.today.adding(months: 6)
    @State private var hasTarget = false
    @State private var saved: Int?
    @State private var monthly: Int?
    @State private var priority = FinanceProject.Priority.medium
    @State private var done = false
    @State private var note = ""

    private var exists: Bool {
        let plan = app.finance.state.plan
        let id = draft.id
        return plan.income.contains { $0.id == id } || plan.fixedCosts.contains { $0.id == id } || plan.projects.contains { $0.id == id } || plan.goals.contains { $0.id == id }
    }

    var body: some View {
        let finance = app.finance
        FinanceSheetFrame(title: (exists ? "" : "Neu: ") + draft.title, subtitle: subtitle,
                          canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && (amount ?? 0) > 0,
                          destructive: exists ? ("Entfernen", { remove() }) : nil, save: save) {
            VStack(alignment: .leading, spacing: 10) {
                FinanceFormRow(label: "Name") { StudioField(placeholder: placeholder, text: $name) }
                FinanceFormRow(label: amountLabel) {
                    HStack(spacing: 6) {
                        FinanceAmountField(placeholder: "0,00", cents: $amount, width: 130)
                        Text(finance.currency).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                switch draft {
                case .income, .fixedCost:
                    FinanceFormRow(label: "Rhythmus") {
                        Picker("", selection: $interval) { ForEach(FinanceInterval.allCases) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                    }
                    FinanceFormRow(label: "Fällig am") {
                        Picker("", selection: $dueDay) {
                            Text("–").tag(0)
                            ForEach(1...31, id: \.self) { Text("\($0).").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if case .fixedCost = draft {
                        FinanceFormRow(label: "Kategorie") {
                            Menu {
                                FinanceCategoryItems(categories: finance.state.categories, cents: -1, none: "Keine") { category = $0 }
                            } label: {
                                FinanceCategoryChip(category: finance.state.category(category))
                            }
                            .menuStyle(.button)
                            .fixedSize()
                        }
                    }
                    if let amount, interval != .monthly {
                        FinanceFormRow(label: "") { FinanceHint(text: "Das sind im Monat \(FinanceMoney.format(interval.monthly(amount), currency: finance.currency)).") }
                    }
                case .project:
                    FinanceFormRow(label: "Priorität") {
                        Picker("", selection: $priority) { ForEach(FinanceProject.Priority.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    targetRow
                    FinanceFormRow(label: "Schon zurückgelegt") { FinanceAmountField(placeholder: "0,00", cents: $saved, width: 130) }
                    if exists { FinanceFormRow(label: "") { Toggle("Erledigt (gekauft)", isOn: $done).toggleStyle(.checkbox) } }
                case .goal:
                    FinanceFormRow(label: "Schon gespart") { FinanceAmountField(placeholder: "0,00", cents: $saved, width: 130) }
                    FinanceFormRow(label: "Sparrate je Monat") { FinanceAmountField(placeholder: "0,00", cents: $monthly, width: 130) }
                    targetRow
                    if hasTarget, let amount {
                        let months = max(1, FinanceDay.today.months(to: targetDay))
                        let needed = Int((Double(max(0, amount - (saved ?? 0))) / Double(months)).rounded(.up))
                        FinanceFormRow(label: "") { FinanceHint(text: "Bis dahin wären \(FinanceMoney.format(needed, currency: finance.currency)) im Monat nötig.") }
                    }
                }
                FinanceFormRow(label: "Notiz") { StudioField(placeholder: "optional", text: $note) }
            }
        }
        .onAppear(perform: load)
    }

    private var targetRow: some View {
        FinanceFormRow(label: "Zieldatum") {
            HStack(spacing: 8) {
                Toggle("", isOn: $hasTarget).toggleStyle(.checkbox).labelsHidden()
                DatePicker("", selection: FinanceDay.binding($targetDay), displayedComponents: .date).labelsHidden().fixedSize().disabled(!hasTarget)
            }
        }
    }

    private var subtitle: String {
        switch draft {
        case .income: "Was regelmäßig hereinkommt. Die Planung rechnet alles auf einen Monat um."
        case .fixedCost: "Was regelmäßig abgeht: Miete, Versicherungen, Abos."
        case .project: "Etwas, das du kaufen willst. Die Planung sagt, ab wann es mit dem frei verfügbaren Geld machbar ist."
        case .goal: "Ein Betrag, auf den du hinsparst. Mit einer Monatsrate zeigt die Planung, wann er voll ist."
        }
    }

    private var placeholder: String {
        switch draft {
        case .income: "Gehalt"
        case .fixedCost: "Miete"
        case .project: "Mac mini M5 Pro"
        case .goal: "Notgroschen"
        }
    }

    private var amountLabel: String {
        switch draft {
        case .income, .fixedCost: "Betrag je Zahlung"
        case .project: "Kostenpunkt"
        case .goal: "Zielbetrag"
        }
    }

    private func load() {
        switch draft {
        case .income(let entry), .fixedCost(let entry):
            name = entry.name
            amount = entry.cents > 0 ? entry.cents : nil
            interval = entry.interval
            dueDay = entry.dueDay ?? 0
            category = entry.category
            note = entry.note
        case .project(let project):
            name = project.name
            amount = project.cents > 0 ? project.cents : nil
            hasTarget = project.targetDay != nil
            if let day = project.targetDay { targetDay = day }
            saved = project.saved > 0 ? project.saved : nil
            priority = project.priority
            done = project.done
            note = project.note
        case .goal(let goal):
            name = goal.name
            amount = goal.target > 0 ? goal.target : nil
            saved = goal.saved > 0 ? goal.saved : nil
            monthly = goal.monthly > 0 ? goal.monthly : nil
            hasTarget = goal.targetDay != nil
            if let day = goal.targetDay { targetDay = day }
            note = goal.note
        }
    }

    private func save() {
        let finance = app.finance
        let name = name.trimmingCharacters(in: .whitespaces)
        let amount = abs(amount ?? 0)
        let target = hasTarget ? targetDay : nil
        let label = exists ? "\(draft.title) ändern" : "\(draft.title) planen"
        finance.change(label, undo: undoManager) {
            finance.changeState { state in
                switch draft {
                case .income(var entry), .fixedCost(var entry):
                    entry.name = name
                    entry.cents = amount
                    entry.interval = interval
                    entry.dueDay = dueDay == 0 ? nil : dueDay
                    entry.note = note
                    if case .fixedCost = draft {
                        entry.category = category
                        upsert(entry, into: &state.plan.fixedCosts)
                    } else {
                        upsert(entry, into: &state.plan.income)
                    }
                case .project(var project):
                    project.name = name
                    project.cents = amount
                    project.targetDay = target
                    project.saved = saved ?? 0
                    project.priority = priority
                    project.done = done
                    project.note = note
                    upsert(project, into: &state.plan.projects)
                case .goal(var goal):
                    goal.name = name
                    goal.target = amount
                    goal.saved = saved ?? 0
                    goal.monthly = monthly ?? 0
                    goal.targetDay = target
                    goal.note = note
                    upsert(goal, into: &state.plan.goals)
                }
            }
        }
    }

    private func upsert<T: Identifiable>(_ item: T, into list: inout [T]) where T.ID == UUID {
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
    }

    private func remove() {
        let finance = app.finance
        let id = draft.id
        finance.change("Aus der Planung nehmen", undo: undoManager) {
            finance.changeState { state in
                state.plan.income.removeAll { $0.id == id }
                state.plan.fixedCosts.removeAll { $0.id == id }
                state.plan.projects.removeAll { $0.id == id }
                state.plan.goals.removeAll { $0.id == id }
            }
        }
    }
}
