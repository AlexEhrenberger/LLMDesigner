import SwiftUI

/// The plan: what comes in each month, what goes out for sure, what the other spending usually is, what goes into
/// savings goals and what is left for spending projects, with the month from which each project is paid for.
struct FinancePlanningView: View {
    @Environment(AppModel.self) private var app
    let model: FinanceStudioModel

    var body: some View {
        let finance = app.finance
        let analysis = finance.analysis
        let summary = analysis.planSummary()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FinanceBudgetCard(summary: summary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    FinanceEntriesCard(title: "Monatliches Einkommen", symbol: "briefcase", entries: finance.state.plan.income, isIncome: true, model: model,
                                       suggestions: analysis.planSuggestions.filter { analysis.kind(ofGroup: $0) == .income }, analysis: analysis)
                    FinanceEntriesCard(title: "Fixkosten", symbol: "repeat", entries: finance.state.plan.fixedCosts, isIncome: false, model: model,
                                       suggestions: analysis.planSuggestions.filter { analysis.kind(ofGroup: $0) == .expense }, analysis: analysis)
                    FinanceGoalsCard(lines: summary.goals, model: model)
                    FinanceProjectsCard(lines: summary.projects, forProjects: summary.forProjects, model: model)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
    }
}

/// Where the monthly income goes, as one bar split into its parts, with the figures beside it.
private struct FinanceBudgetCard: View {
    @Environment(AppModel.self) private var app
    let summary: FinancePlanSummary

    var body: some View {
        let finance = app.finance
        let variable = summary.countsVariable ? summary.variable : 0
        let parts: [(String, Int, Color)] = [
            ("Fixkosten", summary.fixedCosts, FinanceColors.slots[0]),
            ("Übrige Ausgaben", variable, FinanceColors.slots[1]),
            ("Sparraten", summary.savingRates, FinanceColors.slots[2]),
            ("Frei für Projekte", max(0, summary.forProjects), FinanceColors.slots[3]),
        ]
        let whole = max(summary.income, parts.reduce(0) { $0 + $1.1 })
        StudioCard(title: "Monatsbudget", symbol: "chart.bar.doc.horizontal") {
            HStack(spacing: 8) {
                FinanceStatTile(title: "Einkommen", cents: summary.income, footnote: "je Monat")
                FinanceStatTile(title: "Fixkosten", cents: -summary.fixedCosts, swatch: FinanceColors.slots[0], footnote: "je Monat")
                FinanceStatTile(title: "Übrige Ausgaben", cents: -summary.variable, swatch: FinanceColors.slots[1],
                                footnote: summary.countsVariable ? "Ø der letzten 3 Monate" : "nicht eingerechnet")
                FinanceStatTile(title: "Sparraten", cents: -summary.savingRates, swatch: FinanceColors.slots[2], footnote: "in Sparziele")
                FinanceStatTile(title: "Frei für Projekte", cents: summary.forProjects, swatch: FinanceColors.slots[3], footnote: "je Monat")
            }
            if whole > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            if part.1 > 0 {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(part.2)
                                    .frame(width: max(4, (geometry.size.width - 6) * CGFloat(part.1) / CGFloat(whole)))
                                    .help("\(part.0): \(finance.format(part.1))")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 14)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(FinanceColors.meterTrack))
            }
            HStack(spacing: 14) {
                Toggle("Übrige Ausgaben einrechnen", isOn: Binding(get: { finance.state.plan.countsVariable }, set: { on in
                    finance.changeState { $0.plan.countsVariable = on }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Der Durchschnitt aller Ausgaben der letzten drei vollen Monate, die keine geplanten Fixkosten und keine Umbuchungen sind.")
                Spacer(minLength: 0)
                if summary.forProjects < 0 {
                    Label("Der Plan gibt im Monat \(finance.format(-summary.forProjects)) mehr aus, als hereinkommt.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .symbolRenderingMode(.multicolor)
                } else if summary.income == 0 {
                    FinanceHint(text: "Trag dein Einkommen ein – oder übernimm es aus den erkannten Eingängen.")
                }
            }
        }
    }
}

private struct FinanceEntriesCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let title: String
    let symbol: String
    let entries: [FinancePlanEntry]
    let isIncome: Bool
    let model: FinanceStudioModel
    let suggestions: [FinanceGroup]
    let analysis: FinanceAnalysis

    var body: some View {
        let finance = app.finance
        let monthly = entries.reduce(0) { $0 + $1.monthly }
        StudioCard(title: title, symbol: symbol, trailing: AnyView(
            HStack(spacing: 8) {
                Text("\(finance.format(monthly)) / Monat").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                IconButton(systemName: "plus", help: isIncome ? "Einkommen hinzufügen" : "Fixkosten hinzufügen", size: 12, frameSize: 24) {
                    let entry = FinancePlanEntry(name: "", cents: 0)
                    model.sheet = .plan(isIncome ? .income(entry) : .fixedCost(entry))
                }
            })) {
            VStack(spacing: 2) {
                if entries.isEmpty {
                    FinanceHint(text: isIncome ? "Noch kein Einkommen eingetragen." : "Noch keine Fixkosten eingetragen.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                ForEach(entries) { entry in
                    FinancePlanRow(symbol: finance.state.category(entry.category)?.symbol ?? (isIncome ? "arrow.down.circle" : "arrow.up.circle"),
                                   title: entry.name, detail: detail(entry), cents: entry.cents, note: entry.interval == .monthly ? nil : "\(finance.format(entry.monthly)) / Monat") {
                        model.sheet = .plan(isIncome ? .income(entry) : .fixedCost(entry))
                    }
                }
                if !suggestions.isEmpty {
                    StudioSectionHeader(title: "Erkannt in deinen Buchungen", symbol: "sparkle.magnifyingglass", count: suggestions.count)
                    ForEach(suggestions.prefix(6)) { group in
                        if let recurrence = group.recurrence {
                            HStack(spacing: 8) {
                                Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(group.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Text("\(recurrence.interval.label), zuletzt \(recurrence.last.german) · \(recurrence.count)×")
                                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(finance.format(abs(recurrence.cents))).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                Button("Übernehmen") { adopt(group) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ entry: FinancePlanEntry) -> String {
        var parts = [entry.interval.label]
        if let day = entry.dueDay { parts.append("am \(day).") }
        if let group = entry.group, let found = analysis.groups[group], let recurrence = found.recurrence {
            parts.append("nächste um den \(recurrence.next.german)")
        }
        return parts.joined(separator: " · ")
    }

    private func adopt(_ group: FinanceGroup) {
        let finance = app.finance
        let draft = FinancePlanDraft.from(group: group, analysis: analysis)
        finance.change(isIncome ? "Einkommen übernehmen" : "Fixkosten übernehmen", undo: undoManager) {
            finance.changeState { state in
                switch draft {
                case .income(let entry): state.plan.income.append(entry)
                case .fixedCost(let entry): state.plan.fixedCosts.append(entry)
                default: break
                }
            }
        }
    }
}

private struct FinancePlanRow: View {
    @Environment(AppModel.self) private var app
    let symbol: String
    let title: String
    let detail: String
    let cents: Int
    var note: String?
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(app.finance.format(cents)).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    if let note { Text(note).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Bearbeiten")
    }
}

private struct FinanceGoalsCard: View {
    @Environment(AppModel.self) private var app
    let lines: [FinancePlanSummary.GoalLine]
    let model: FinanceStudioModel

    var body: some View {
        StudioCard(title: "Sparziele", symbol: "target", trailing: AnyView(
            IconButton(systemName: "plus", help: "Sparziel anlegen", size: 12, frameSize: 24) { model.sheet = .plan(.goal(FinanceGoal(name: "", target: 0))) })) {
            VStack(spacing: 8) {
                if lines.isEmpty { FinanceHint(text: "Noch keine Sparziele, etwa ein Notgroschen von drei Monatsausgaben.").frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(lines, id: \.goal.id) { line in FinanceGoalRow(line: line, model: model) }
            }
        }
    }
}

private struct FinanceGoalRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let line: FinancePlanSummary.GoalLine
    let model: FinanceStudioModel
    @State private var depositing = false
    @State private var deposit: Int?

    var body: some View {
        let finance = app.finance
        let goal = line.goal
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: goal.symbol).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text(goal.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(finance.format(goal.saved)) von \(finance.format(goal.target))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Text("\(Int((goal.progress * 100).rounded())) %")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, alignment: .trailing)
            }
            FinanceMeter(progress: goal.progress, color: FinanceColors.slots[2])
            HStack(spacing: 8) {
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Einzahlen …") { depositing = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .popover(isPresented: $depositing, arrowEdge: .bottom) {
                        HStack(spacing: 8) {
                            FinanceAmountField(placeholder: "Betrag", cents: $deposit, width: 110)
                            Button("Einzahlen") { put(deposit ?? 0) }.disabled((deposit ?? 0) == 0)
                            Button("Abheben") { put(-(deposit ?? 0)) }.disabled((deposit ?? 0) == 0)
                        }
                        .padding(12)
                    }
                Button("Bearbeiten …") { model.sheet = .plan(.goal(goal)) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.025)))
    }

    private var status: String {
        let finance = app.finance
        let goal = line.goal
        if goal.isReached { return "Erreicht" }
        var parts: [String] = []
        if goal.monthly > 0 { parts.append("\(finance.format(goal.monthly)) / Monat") }
        if let reached = line.reached { parts.append("voll im \(reached.monthTitle)") } else { parts.append("ohne Sparrate") }
        if let target = goal.targetDay {
            parts.append("Ziel \(target.monthTitle)")
            if let needed = line.neededMonthly, needed > goal.monthly { parts.append("dafür \(finance.format(needed)) / Monat nötig") }
        }
        return parts.joined(separator: " · ")
    }

    private func put(_ cents: Int) {
        let finance = app.finance
        let id = line.goal.id
        finance.change(cents >= 0 ? "Einzahlen" : "Abheben", undo: undoManager) {
            finance.changeState { state in
                if let index = state.plan.goals.firstIndex(where: { $0.id == id }) { state.plan.goals[index].saved = max(0, state.plan.goals[index].saved + cents) }
            }
        }
        deposit = nil
        depositing = false
    }
}

private struct FinanceProjectsCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let lines: [FinancePlanSummary.ProjectLine]
    let forProjects: Int
    let model: FinanceStudioModel

    var body: some View {
        let finance = app.finance
        let open = lines.filter { !$0.project.done }
        StudioCard(title: "Ausgabeprojekte", symbol: "shippingbox", trailing: AnyView(
            HStack(spacing: 8) {
                Text("\(finance.format(open.reduce(0) { $0 + $1.project.missing })) offen").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                IconButton(systemName: "plus", help: "Ausgabeprojekt anlegen", size: 12, frameSize: 24) { model.sheet = .plan(.project(FinanceProject(name: "", cents: 0))) }
            })) {
            VStack(spacing: 8) {
                if lines.isEmpty {
                    FinanceHint(text: "Noch keine Projekte – etwa „Mac mini M5 Pro, 3.500 €“. Die Planung zeigt dann, ab wann er sich mit dem frei verfügbaren Geld ausgeht.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if forProjects <= 0, !open.isEmpty {
                    FinanceHint(text: "Im Monat bleibt nichts für Projekte übrig; ohne Erspartes ist keines absehbar.", symbol: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(lines, id: \.project.id) { line in
                    let project = line.project
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                finance.change(project.done ? "Projekt offen" : "Projekt erledigt", undo: undoManager) {
                                    finance.changeState { state in
                                        if let index = state.plan.projects.firstIndex(where: { $0.id == project.id }) { state.plan.projects[index].done.toggle() }
                                    }
                                }
                            } label: {
                                Image(systemName: project.done ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(project.done ? Theme.success : Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help(project.done ? "Wieder offen" : "Als erledigt (gekauft) markieren")
                            Text(project.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(project.done ? Theme.textTertiary : Theme.textPrimary)
                                .strikethrough(project.done).lineLimit(1)
                            Text(project.priority.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6).frame(height: 17)
                                .background(Capsule().fill(Theme.selection))
                            Spacer(minLength: 6)
                            Text(finance.format(project.cents)).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                        }
                        if !project.done {
                            if project.saved > 0 {
                                FinanceMeter(progress: Double(project.saved) / Double(max(1, project.cents)), color: FinanceColors.slots[3])
                            }
                            HStack(spacing: 6) {
                                statusLabel(line)
                                Spacer(minLength: 6)
                                Button("Bearbeiten …") { model.sheet = .plan(.project(project)) }.buttonStyle(.borderless).font(.system(size: 11.5))
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.025)))
                }
            }
        }
    }

    /// Status in words with an icon, never by colour alone.
    @ViewBuilder
    private func statusLabel(_ line: FinancePlanSummary.ProjectLine) -> some View {
        let finance = app.finance
        let project = line.project
        let saved = project.saved > 0 ? " · \(finance.format(project.saved)) zurückgelegt" : ""
        let target = project.targetDay.map { " · Ziel \($0.monthTitle)" } ?? ""
        if let affordable = line.affordable {
            let when = affordable <= FinanceDay.today ? "jetzt machbar" : "machbar ab \(affordable.monthTitle)"
            Label {
                Text(when + target + saved).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } icon: {
                Image(systemName: line.onTime == false ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(line.onTime == false ? Theme.warning : Theme.success)
            }
            .help(line.onTime == false ? "Zum Zieldatum reicht das frei verfügbare Geld noch nicht." : "Rechnet mit dem, was im Monat für Projekte frei ist, nach den Projekten davor.")
        } else {
            Label {
                Text("nicht absehbar" + target + saved).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } icon: {
                Image(systemName: "questionmark.circle").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
