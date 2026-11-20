import SwiftUI

/// FinanceStudio in small: the balance, this month's income and expenses, the latest bookings (each drags into a
/// document or the chat as a line of text), the savings goals and projects, and a quick booking by hand.
struct PowerFinance: View {
    @Environment(AppModel.self) private var app
    @State private var amount: Int?
    @State private var counterparty = ""
    @State private var isExpense = true

    var body: some View {
        let finance = app.finance
        let _ = finance.loadIfNeeded()
        let analysis = finance.analysis
        let query = app.power.query
        let month = FinanceFilter(period: FinancePeriod(.month))
        let totals = analysis.totals(analysis.filtered(month))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Kontostand")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        IconButton(systemName: finance.state.hidesAmounts ? "eye.slash" : "eye", help: finance.state.hidesAmounts ? "Beträge zeigen" : "Beträge verbergen",
                                   size: 11, frameSize: 22) {
                            finance.changeState { $0.hidesAmounts.toggle() }
                        }
                    }
                    Text(finance.format(analysis.currentBalance))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .powerDrag(markdown: balanceLine(analysis), plain: balanceLine(analysis))
                        .help("Ziehen: der Kontostand als Text")
                    HStack(spacing: 12) {
                        monthItem("Einnahmen", totals.income, FinanceColors.income)
                        monthItem("Ausgaben", totals.expenses, FinanceColors.expense)
                    }
                    Text("\(finance.state.account.name) · \(FinanceDay.today.monthTitle)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.035)))
                .padding(.bottom, 6)

                quickAdd

                let shown = query.isEmpty ? Array(analysis.entries.suffix(15).reversed()) : Array(analysis.filtered(FinanceFilter(period: FinancePeriod(.all), query: query)).suffix(40).reversed())
                StudioSectionHeader(title: query.isEmpty ? "Letzte Buchungen" : "Gefunden", symbol: "list.bullet", count: shown.count)
                ForEach(shown) { entry in bookingRow(entry, analysis: analysis) }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Buchungen. Importiere in FinanceStudio die CSV deiner Bank." : "Keine Buchung passt zur Suche.")
                }

                if query.isEmpty {
                    let summary = analysis.planSummary()
                    if !summary.goals.isEmpty {
                        StudioSectionHeader(title: "Sparziele", symbol: "target", count: summary.goals.count)
                        ForEach(summary.goals, id: \.goal.id) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(line.goal.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Spacer()
                                    Text("\(Int((line.goal.progress * 100).rounded())) %").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                }
                                FinanceMeter(progress: line.goal.progress, color: FinanceColors.slots[2], height: 5)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .powerDrag(markdown: goalLine(line), plain: goalLine(line))
                        }
                    }
                    let projects = summary.projects.filter { !$0.project.done }
                    if !projects.isEmpty {
                        StudioSectionHeader(title: "Ausgabeprojekte", symbol: "shippingbox", count: projects.count)
                        ForEach(projects, id: \.project.id) { line in
                            PowerListRow(title: line.project.name,
                                         subtitle: "\(finance.format(line.project.cents)) · " + (line.affordable.map { $0 <= FinanceDay.today ? "jetzt machbar" : "machbar ab \($0.monthTitle)" } ?? "nicht absehbar"),
                                         symbol: "shippingbox") {
                                app.openFinanceStudio(FinanceStudioCommand(tab: .planning))
                            }
                        }
                    }
                    StudioSectionHeader(title: "Frei im Monat", symbol: "chart.bar.doc.horizontal")
                    HStack {
                        Text("nach Fixkosten\(summary.countsVariable ? ", übrigen Ausgaben" : "") und Sparraten")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(finance.format(summary.forProjects)).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                HStack(spacing: 12) {
                    Button {
                        app.openFinanceStudio()
                    } label: {
                        Label("FinanceStudio", systemImage: "arrow.up.forward.app").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    Button {
                        app.openFinanceStudio(FinanceStudioCommand(tab: .planning))
                    } label: {
                        Label("Planung", systemImage: "chart.bar.doc.horizontal").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 10)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func monthItem(_ title: String, _ cents: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(app.finance.format(cents, sign: cents > 0)).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }

    /// A booking by hand: amount, who, Return.
    private var quickAdd: some View {
        HStack(spacing: 6) {
            Picker("", selection: $isExpense) {
                Image(systemName: "minus").tag(true).help("Ausgabe")
                Image(systemName: "plus").tag(false).help("Einnahme")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            FinanceAmountField(placeholder: "Betrag", cents: $amount, width: 86)
            StudioField(placeholder: isExpense ? "Empfänger" : "Von wem", text: $counterparty)
                .onSubmit(add)
            IconButton(systemName: "return", help: "Buchung eintragen", size: 11, frameSize: 24, action: add)
                .disabled((amount ?? 0) == 0)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
    }

    private func add() {
        guard let amount, amount != 0 else { return }
        let finance = app.finance
        let booking = FinanceTransaction(day: .today, cents: isExpense ? -abs(amount) : abs(amount), counterparty: counterparty.trimmingCharacters(in: .whitespaces))
        finance.add(booking)
        let id = booking.id
        app.power.lastChange = PowerAccess.Change(label: "Buchung eingetragen") { [weak finance] in finance?.remove([id]) }
        self.amount = nil
        counterparty = ""
    }

    private func bookingRow(_ entry: FinanceEntry, analysis: FinanceAnalysis) -> some View {
        let finance = app.finance
        let booking = entry.booking
        let line = bookingLine(entry, analysis: analysis)
        return HStack(spacing: 8) {
            Image(systemName: finance.state.category(entry.category)?.symbol ?? "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(analysis.groups[entry.group]?.name ?? booking.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text([booking.day.german, finance.state.category(entry.category)?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            FinanceAmount(cents: booking.cents, size: 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .powerDrag(markdown: line, plain: line)
        .help("Ziehen: die Buchung als Text")
        .contextMenu {
            Button("Alle von „\(analysis.groups[entry.group]?.name ?? booking.displayName)“ in FinanceStudio", systemImage: "list.bullet") {
                app.openFinanceStudio(FinanceStudioCommand(tab: .account, period: FinancePeriod(.all), group: entry.group))
            }
            Button("An der Schreibmarke einfügen", systemImage: "text.insert") { _ = powerInsertAtCaret(line, app: app) }
                .disabled(!app.canFormatText)
        }
    }

    // What goes out of the panel is plain text: a document doesn't follow later changes of the account.
    private func bookingLine(_ entry: FinanceEntry, analysis: FinanceAnalysis) -> String {
        let booking = entry.booking
        let name = analysis.groups[entry.group]?.name ?? booking.displayName
        return "\(booking.day.german) · \(name) · \(app.finance.format(booking.cents, sign: true))"
    }

    private func balanceLine(_ analysis: FinanceAnalysis) -> String {
        "Kontostand \(app.finance.state.account.name) am \(FinanceDay.today.german): \(app.finance.format(analysis.currentBalance))"
    }

    private func goalLine(_ line: FinancePlanSummary.GoalLine) -> String {
        let finance = app.finance
        return "\(line.goal.name): \(finance.format(line.goal.saved)) von \(finance.format(line.goal.target)) (\(Int((line.goal.progress * 100).rounded())) %)"
    }
}
