import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What FinanceStudio shows.
@MainActor
@Observable
final class FinanceStudioModel {
    var tab: FinanceStudioTab = .account
    var filter = FinanceFilter()
    /// Similar bookings as one row each.
    var grouped = false
    var chartMode: FinanceChartMode = .flow
    var chartShown = true
    var selection: Set<UUID> = []
    var groupSelection: Set<String> = []
    var sort = [KeyPathComparator(\FinanceEntry.booking.day, order: .reverse)]
    var groupSort = [KeyPathComparator(\FinanceGroup.magnitude, order: .reverse)]
    var sheet: FinanceSheet?
    /// What the last import or the model did; shown over the table until it is closed.
    var message: String?
    var messageIsError = false
}

enum FinanceSheet: Identifiable {
    case booking(FinanceTransaction?)
    case balance
    case account
    case statement
    case categories
    case plan(FinancePlanDraft)

    var id: String {
        switch self {
        case .booking(let booking): "booking-\(booking?.id.uuidString ?? "neu")"
        case .balance: "balance"
        case .account: "account"
        case .statement: "statement"
        case .categories: "categories"
        case .plan(let draft): "plan-\(draft.id)"
        }
    }
}

extension FinanceGroup {
    /// For sorting the groups by how much money they move.
    var magnitude: Int { abs(total) }
}

/// FinanceStudio: the balance in large figures, the course of income and expenses, every booking in a table that
/// filters by day, week, month or year and by kind, category or group, and the plan of income, fixed costs,
/// spending projects and savings goals.
struct FinanceStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = FinanceStudioModel()

    var body: some View {
        let finance = app.finance
        VStack(spacing: 0) {
            StudioTopBar(symbol: StudioApplication.finance.symbol, title: "FinanceStudio", detail: detail, close: { app.closeFinanceStudio() }) {
                StudioTabPicker(tabs: FinanceStudioTab.allCases, selection: $model.tab, title: \.title, symbol: \.symbol)
            } trailing: {
                IconButton(systemName: finance.state.hidesAmounts ? "eye.slash" : "eye", help: finance.state.hidesAmounts ? "Beträge zeigen" : "Beträge verbergen",
                           size: 13, frameSize: Theme.titleBarControlSize) {
                    finance.changeState { $0.hidesAmounts.toggle() }
                }
                FinanceImportButton(model: model)
                IconButton(systemName: "doc.text", help: "Kontoauszug als PDF …", size: 13, frameSize: Theme.titleBarControlSize) { model.sheet = .statement }
                FinanceNewMenu(model: model)
                PowerButton()
            }
            switch model.tab {
            case .account: FinanceAccountTab(model: model)
            case .planning: FinancePlanningView(model: model)
            }
        }
        .background(Theme.canvas)
        .sheet(item: $model.sheet) { sheet in
            FinanceSheetView(sheet: sheet, model: model)
                .environment(app)
        }
        .onAppear {
            finance.loadIfNeeded()
            // Open where the newest booking is, not in an empty month after a long pause.
            if let latest = finance.analysis.latestDay, latest < FinanceDay.today.firstOfMonth { model.filter.period = FinancePeriod(.month, latest) }
            take(app.financeStudioCommand)
        }
        .onChange(of: app.financeStudioCommand) { _, command in take(command) }
    }

    private var detail: String {
        let finance = app.finance
        let count = finance.bookings.count
        var parts = [finance.state.account.name, "\(count) \(count == 1 ? "Buchung" : "Buchungen")"]
        if let latest = finance.analysis.latestDay { parts.append("bis \(latest.german)") }
        return parts.joined(separator: " · ")
    }

    private func take(_ command: FinanceStudioCommand?) {
        guard let command else { return }
        if let tab = command.tab { model.tab = tab }
        if let period = command.period { model.filter.period = period; model.filter.from = nil; model.filter.to = nil }
        if let category = command.category { model.filter.category = category; model.tab = .account }
        if let group = command.group { model.filter.group = group; model.grouped = false; model.tab = .account }
        app.financeStudioCommand = nil
    }
}

private struct FinanceNewMenu: View {
    @Environment(AppModel.self) private var app
    let model: FinanceStudioModel

    var body: some View {
        IconMenu(systemName: "plus", help: "Buchung, Kontostand, Planung", frameSize: Theme.titleBarControlSize) {
            Button("Buchung eintragen …", systemImage: "square.and.pencil") { model.sheet = .booking(nil) }
            Button("Kontostand abgleichen …", systemImage: "scalemass") { model.sheet = .balance }
            Divider()
            Button("Einkommen …", systemImage: "briefcase") { model.tab = .planning; model.sheet = .plan(.income(FinancePlanEntry(name: "", cents: 0))) }
            Button("Fixkosten …", systemImage: "repeat") { model.tab = .planning; model.sheet = .plan(.fixedCost(FinancePlanEntry(name: "", cents: 0))) }
            Button("Ausgabeprojekt …", systemImage: "shippingbox") { model.tab = .planning; model.sheet = .plan(.project(FinanceProject(name: "", cents: 0))) }
            Button("Sparziel …", systemImage: "target") { model.tab = .planning; model.sheet = .plan(.goal(FinanceGoal(name: "", target: 0))) }
            Divider()
            Button("Konto …", systemImage: "building.columns") { model.sheet = .account }
            Button("Kategorien …", systemImage: "tag") { model.sheet = .categories }
        }
    }
}

/// Opens a bank's CSV export and reports what came in.
struct FinanceImportButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let model: FinanceStudioModel?

    var body: some View {
        IconButton(systemName: "square.and.arrow.down", help: "CSV der Bank importieren …", size: 13, frameSize: Theme.titleBarControlSize) {
            FinanceImport.run(app: app, undo: undoManager) { message, isError in
                model?.message = message
                model?.messageIsError = isError
                if !isError { model?.tab = .account }
            }
        }
    }
}

@MainActor
enum FinanceImport {
    static func run(app: AppModel, undo: UndoManager?, report: @escaping (String, Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "CSV der Bank importieren"
        panel.message = "Wähle den CSV-Export deines Kontos. Buchungen, die es schon gibt, werden übersprungen."
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var messages: [String] = []
        for url in panel.urls {
            do {
                let summary = try app.importFinanceCSV(Data(contentsOf: url), undo: undo)
                messages.append("\(url.lastPathComponent): \(summary.message)")
            } catch {
                report("\(url.lastPathComponent): \(error.localizedDescription)", true)
                return
            }
        }
        report(messages.joined(separator: "\n"), false)
    }
}

// MARK: - Account tab

private struct FinanceAccountTab: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: FinanceStudioModel

    var body: some View {
        let finance = app.finance
        let analysis = finance.analysis
        if analysis.entries.isEmpty {
            StudioEmptyState(symbol: StudioApplication.finance.symbol, title: "Noch keine Buchungen",
                             text: "Importiere den CSV-Export deiner Bank (Umsätze als CSV). FinanceStudio erkennt Datum, Betrag, Empfänger und Verwendungszweck selbst, fasst ähnliche Posten zusammen und ordnet sie Kategorien zu. Buchungen von Hand gehen über „+“.",
                             actionTitle: "CSV importieren") {
                FinanceImport.run(app: app, undo: nil) { message, isError in
                    model.message = message
                    model.messageIsError = isError
                }
            }
            .overlay(alignment: .bottom) { if let message = model.message { FinanceMessageBar(model: model, text: message).padding(16) } }
        } else {
            let entries = analysis.filtered(model.filter)
            let totals = analysis.totals(entries)
            VStack(spacing: 12) {
                FinanceHeader(model: model, analysis: analysis, totals: totals, filter: model.filter)
                if model.chartShown {
                    FinanceChartCard(buckets: analysis.buckets(around: model.filter.period), selected: model.filter.period, mode: $model.chartMode) { bucket in
                        choose(bucket)
                    }
                }
                FinanceFilterBar(model: model, analysis: analysis)
                if let message = model.message { FinanceMessageBar(model: model, text: message) }
                Group {
                    if model.grouped {
                        FinanceGroupTable(model: model, analysis: analysis, groups: analysis.groups(of: entries))
                    } else {
                        FinanceBookingTable(model: model, analysis: analysis, entries: entries)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    /// A click on a bar shows its period in the table: a month of the year or of all becomes that month.
    private func choose(_ bucket: FinanceBucket) {
        var kind = model.filter.period.kind
        if kind == .year || kind == .all {
            kind = bucket.start.month == 1 && bucket.end == bucket.start.lastOfYear ? .year : .month
        }
        model.filter.from = nil
        model.filter.to = nil
        model.filter.period = FinancePeriod(kind, bucket.start)
    }
}

/// The balance in large figures, and the sums of what the table shows.
private struct FinanceHeader: View {
    @Environment(AppModel.self) private var app
    let model: FinanceStudioModel
    let analysis: FinanceAnalysis
    let totals: FinanceTotals
    let filter: FinanceFilter

    var body: some View {
        let finance = app.finance
        let account = finance.state.account
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kontostand")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(finance.format(analysis.currentBalance))
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .help("Stand am \(FinanceDay.today.german)")
                HStack(spacing: 6) {
                    Text(accountLine(account))
                        .foregroundStyle(Theme.textTertiary)
                    // Without a known balance the figure is only the sum of the bookings.
                    Button(account.anchor == nil ? "Kontostand abgleichen" : "Abgleichen") { model.sheet = .balance }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(periodTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                HStack(alignment: .top, spacing: 8) {
                    FinanceStatTile(title: "Einnahmen", cents: totals.income, sign: true, swatch: FinanceColors.income,
                                    footnote: "\(totals.count) Buchungen")
                    FinanceStatTile(title: "Ausgaben", cents: totals.expenses, swatch: FinanceColors.expense,
                                    footnote: totals.transfers != 0 ? "Umbuchungen \(finance.format(totals.transfers, sign: true))" : "ohne Umbuchungen")
                    FinanceStatTile(title: "Saldo", cents: totals.income + totals.expenses, sign: true, footnote: "Einnahmen − Ausgaben")
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(.top, 4)
    }

    private var periodTitle: String {
        if filter.from != nil || filter.to != nil { return "\(filter.from?.german ?? "Anfang") – \(filter.to?.german ?? "heute")" }
        return filter.period.title
    }

    private func accountLine(_ account: FinanceAccount) -> String {
        var parts = [account.name]
        if !account.iban.isEmpty { parts.append(account.maskedIBAN) }
        if let anchor = account.anchor {
            parts.append("abgeglichen am \(anchor.day.german)")
        } else {
            parts.append("noch nicht abgeglichen")
        }
        return parts.joined(separator: " · ")
    }
}

/// One row over the table: period, direction, category, group, single or grouped, search.
private struct FinanceFilterBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: FinanceStudioModel
    let analysis: FinanceAnalysis

    var body: some View {
        let filter = model.filter
        HStack(spacing: 8) {
            Picker("Zeitraum", selection: Binding(get: { filter.from == nil && filter.to == nil ? filter.period.kind : nil }, set: { kind in
                guard let kind else { return }
                model.filter.from = nil
                model.filter.to = nil
                model.filter.period = FinancePeriod(kind, model.filter.period.anchor)
            })) {
                ForEach(FinancePeriod.Kind.allCases) { kind in Text(kind.label).tag(Optional(kind)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if filter.period.kind != .all, filter.from == nil, filter.to == nil {
                HStack(spacing: 0) {
                    IconButton(systemName: "chevron.left", help: "Davor", size: 11, frameSize: 24) { model.filter.period = filter.period.shifted(by: -1) }
                    Text(filter.period.title)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 96)
                        .lineLimit(1)
                    IconButton(systemName: "chevron.right", help: "Danach", size: 11, frameSize: 24) { model.filter.period = filter.period.shifted(by: 1) }
                }
                if !filter.period.contains(.today) {
                    Button("Heute") { model.filter.period = FinancePeriod(filter.period.kind, .today) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            } else if filter.from != nil || filter.to != nil {
                chip("\(filter.from?.german ?? "…") – \(filter.to?.german ?? "…")") { model.filter.from = nil; model.filter.to = nil }
            }
            Divider().frame(height: 18)
            Picker("Richtung", selection: $model.filter.direction) {
                ForEach(FinanceFilter.Direction.allCases) { direction in Text(direction.label).tag(direction) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Alle Kategorien") { model.filter.category = nil }
                Button("Ohne Kategorie", systemImage: "questionmark.circle") { model.filter.category = FinanceFilter.uncategorized }
                Divider()
                FinanceCategoryItems(categories: app.finance.state.categories, none: nil) { key in model.filter.category = key }
            } label: {
                Label(categoryTitle, systemImage: "tag")
                    .font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            if let group = filter.group {
                chip(analysis.groups[group]?.name ?? group) { model.filter.group = nil }
            }
            Spacer(minLength: 6)
            if app.finance.categorizing {
                ProgressView().controlSize(.small)
                Text("Modell ordnet ein …").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            } else if analysis.groups.values.contains(where: { $0.category == nil }) {
                Button {
                    categorize()
                } label: {
                    Label("Mit KI einordnen", systemImage: "sparkles").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Das lokale Modell schlägt für Gruppen ohne Kategorie eine vor. Du kannst jede Zuordnung ändern.")
            }
            Picker("Ansicht", selection: $model.grouped) {
                Image(systemName: "list.bullet").tag(false).help("Einzelne Buchungen")
                Image(systemName: "square.stack.3d.up").tag(true).help("Ähnliche Posten gruppiert")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            SearchField(text: $model.filter.query, prompt: "Suchen")
                .frame(width: 170)
            IconButton(systemName: model.chartShown ? "chevron.up" : "chart.bar", help: model.chartShown ? "Diagramm ausblenden" : "Diagramm zeigen", size: 11, frameSize: 24) {
                withAnimation(.snappy(duration: 0.2)) { model.chartShown.toggle() }
            }
        }
    }

    private var categoryTitle: String {
        guard let key = model.filter.category else { return "Kategorie" }
        if key == FinanceFilter.uncategorized { return "Ohne Kategorie" }
        return app.finance.state.category(key)?.name ?? key
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.selection))
    }

    private func categorize() {
        Task {
            do {
                let made = try await app.categorizeFinanceWithModel()
                model.message = made.isEmpty ? "Das Modell hat keine weitere Zuordnung gefunden." : "Das Modell hat \(made.count) \(made.count == 1 ? "Gruppe" : "Gruppen") eingeordnet. Jede Zuordnung lässt sich über das Kontextmenü ändern."
                model.messageIsError = false
            } catch {
                model.message = error.localizedDescription
                model.messageIsError = true
            }
        }
    }
}

struct FinanceMessageBar: View {
    let model: FinanceStudioModel
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.messageIsError ? Theme.warning : Theme.success)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", help: "Schließen", size: 10, frameSize: 20) { model.message = nil }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Tables

private struct FinanceBookingTable: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: FinanceStudioModel
    let analysis: FinanceAnalysis
    let entries: [FinanceEntry]

    var body: some View {
        let finance = app.finance
        let rows = entries.sorted(using: model.sort)
        Table(rows, selection: $model.selection, sortOrder: $model.sort) {
            TableColumn("Datum", value: \.booking.day) { entry in
                Text(entry.booking.day.german)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(entry.booking.day > analysis.today ? Theme.textTertiary : Theme.textSecondary)
            }
            .width(min: 76, ideal: 84, max: 96)
            TableColumn("Empfänger / Auftraggeber", value: \.booking.counterparty) { entry in
                // Paid through PayPal and the like, the shop is the name and the processor goes into the line below.
                let viaProcessor = FinanceGrouping.isProcessor(entry.booking.counterparty) && !FinanceGrouping.isProcessor(entry.group)
                let name = viaProcessor ? (analysis.groups[entry.group]?.name ?? entry.booking.displayName) : entry.booking.displayName
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    let via = viaProcessor ? "über \(FinanceGrouping.displayName(of: [entry.booking.counterparty]))" : ""
                    let detail = [via, entry.booking.type == name ? "" : entry.booking.type, entry.booking.purpose, entry.booking.note].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .help(entry.booking.purpose)
            }
            .width(min: 200, ideal: 360)
            TableColumn("Kategorie") { entry in
                Menu {
                    FinanceCategoryItems(categories: finance.state.categories, cents: entry.booking.cents, none: "Keine eigene Kategorie") { key in
                        finance.change("Kategorie ändern", undo: undoManager) { finance.update(entry.booking.id) { $0.category = key } }
                    }
                } label: {
                    FinanceCategoryChip(category: finance.state.category(entry.category), source: entry.categorySource)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Kategorie: \(entry.categorySource.label)")
            }
            .width(min: 120, ideal: 160, max: 220)
            TableColumn("Betrag", value: \.booking.cents) { entry in
                FinanceAmount(cents: entry.booking.cents)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn("Saldo") { entry in
                Text(finance.format(entry.balanceAfter))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            bookingMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let booking = finance.booking(id) { model.sheet = .booking(booking) }
        }
        .onDeleteCommand { delete(model.selection) }
        .overlay {
            if rows.isEmpty {
                Text(model.filter.query.isEmpty ? "In diesem Zeitraum gibt es keine passenden Buchungen." : "Keine Buchung passt zur Suche.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func bookingMenu(_ ids: Set<UUID>) -> some View {
        let finance = app.finance
        let chosen = ids.compactMap { analysis.entry($0) }
        let groups = Set(chosen.map(\.group))
        if let first = chosen.first {
            if chosen.count == 1 {
                Button("Bearbeiten …", systemImage: "pencil") { model.sheet = .booking(first.booking) }
            }
            Menu("Kategorie für \(chosen.count == 1 ? "diese Buchung" : "diese \(chosen.count) Buchungen")") {
                FinanceCategoryItems(categories: finance.state.categories, cents: first.booking.cents, none: "Keine eigene Kategorie") { key in
                    finance.change("Kategorie ändern", undo: undoManager) {
                        finance.changeBookings { list in for index in list.indices where ids.contains(list[index].id) { list[index].category = key } }
                    }
                }
            }
            if groups.count == 1, let group = analysis.groups[first.group] {
                Menu("Kategorie für alle von „\(group.name)“") {
                    FinanceCategoryItems(categories: finance.state.categories, cents: first.booking.cents, none: "Zuordnung lösen") { key in
                        finance.change("Kategorie für Gruppe", undo: undoManager) { finance.assign(group: group.key, category: key) }
                    }
                }
                Button("Nur „\(group.name)“ zeigen", systemImage: "line.3.horizontal.decrease.circle") {
                    model.filter.group = group.key
                    model.filter.period = FinancePeriod(.all)
                }
                if group.recurrence != nil, !analysis.plannedGroups.contains(group.key) {
                    Button(first.booking.cents < 0 ? "Als Fixkosten planen …" : "Als Einkommen planen …", systemImage: "repeat") {
                        model.sheet = .plan(FinancePlanDraft.from(group: group, analysis: analysis))
                    }
                }
            }
            Divider()
            Button("Kopieren", systemImage: "doc.on.doc") {
                let text = chosen.map { "\($0.booking.day.german)\t\($0.booking.displayName)\t\($0.booking.purpose)\t\(FinanceMoney.plain($0.booking.cents))" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Löschen", systemImage: "trash", role: .destructive) { delete(ids) }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let finance = app.finance
        finance.change(ids.count == 1 ? "Buchung löschen" : "Buchungen löschen", undo: undoManager) { finance.remove(ids) }
        model.selection = []
    }
}

private struct FinanceGroupTable: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: FinanceStudioModel
    let analysis: FinanceAnalysis
    let groups: [FinanceGroup]

    var body: some View {
        let finance = app.finance
        let rows = groups.sorted(using: model.groupSort)
        Table(rows, selection: $model.groupSelection, sortOrder: $model.groupSort) {
            TableColumn("Posten", value: \.name) { group in
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let recurrence = analysis.groups[group.key]?.recurrence {
                        Label(recurrence.interval.label, systemImage: "repeat")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .labelStyle(.titleAndIcon)
                            .help("Wiederkehrend, zuletzt \(recurrence.last.german), nächstes Mal um den \(recurrence.next.german)")
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Kategorie") { group in
                Menu {
                    FinanceCategoryItems(categories: finance.state.categories, cents: group.total == 0 ? -1 : group.total, none: "Zuordnung lösen") { key in
                        finance.change("Kategorie für Gruppe", undo: undoManager) { finance.assign(group: group.key, category: key) }
                    }
                } label: {
                    FinanceCategoryChip(category: finance.state.category(group.category))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .width(min: 120, ideal: 160, max: 220)
            TableColumn("Anzahl", value: \.count) { group in
                Text("\(group.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 70)
            TableColumn("Ø Betrag", value: \.average) { group in
                Text(finance.format(group.average, sign: true))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100, max: 130)
            TableColumn("Summe", value: \.magnitude) { group in
                FinanceAmount(cents: group.total)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 120, max: 150)
            TableColumn("Zuletzt", value: \.last) { group in
                Text(group.last.german)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .width(min: 76, ideal: 84, max: 96)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let group = analysis.groups[key] {
                Button("Buchungen von „\(group.name)“ zeigen", systemImage: "list.bullet") { show(key) }
                if group.recurrence != nil, !analysis.plannedGroups.contains(key) {
                    Button(group.total < 0 ? "Als Fixkosten planen …" : "Als Einkommen planen …", systemImage: "repeat") {
                        model.sheet = .plan(FinancePlanDraft.from(group: group, analysis: analysis))
                    }
                }
            }
        } primaryAction: { keys in
            if let key = keys.first { show(key) }
        }
        .overlay {
            if rows.isEmpty {
                Text("In diesem Zeitraum gibt es keine passenden Posten.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func show(_ key: String) {
        model.filter.group = key
        model.grouped = false
    }
}
