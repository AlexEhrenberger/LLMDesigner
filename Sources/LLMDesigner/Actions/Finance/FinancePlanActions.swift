import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerFinancePlanActions() {
        register(FinancePlanReadAction.self)
        register(FinancePlanConfigureAction.self)
        register(FinanceIncomeAddAction.self)
        register(FinanceFixedCostAddAction.self)
        register(FinanceProjectAddAction.self)
        register(FinanceGoalAddAction.self)
        register(FinancePlanUpdateAction.self)
        register(FinancePlanRemoveAction.self)
        register(FinanceGoalDepositAction.self)
    }
}

/// Where an item of the plan lives.
enum FinancePlanItem: Equatable {
    case income(UUID), fixedCost(UUID), project(UUID), goal(UUID)

    var id: UUID {
        switch self {
        case .income(let id), .fixedCost(let id), .project(let id), .goal(let id): id
        }
    }

    var kind: String {
        switch self {
        case .income: "einkommen"
        case .fixedCost: "fixkosten"
        case .project: "projekt"
        case .goal: "sparziel"
        }
    }
}

private let planItemProperty: JSONSchema = .string("Eintrag der Planung (ID oder Name): Einkommen, Fixkosten, Projekt oder Sparziel")

extension AppModel {
    func actionFinancePlanItem(_ reference: String) throws -> FinancePlanItem {
        finance.loadIfNeeded()
        let plan = finance.state.plan
        let reference = reference.trimmingCharacters(in: .whitespaces)
        var all: [(FinancePlanItem, String)] = []
        all += plan.income.map { (.income($0.id), $0.name) }
        all += plan.fixedCosts.map { (.fixedCost($0.id), $0.name) }
        all += plan.projects.map { (.project($0.id), $0.name) }
        all += plan.goals.map { (.goal($0.id), $0.name) }
        if let id = UUID(uuidString: reference), let found = all.first(where: { $0.0.id == id }) { return found.0 }
        let exact = all.filter { $0.1.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if exact.count == 1 { return exact[0].0 }
        let partial = exact.isEmpty ? all.filter { $0.1.localizedCaseInsensitiveContains(reference) } : exact
        if partial.count == 1 { return partial[0].0 }
        if partial.isEmpty { throw RPCError.notFound("In der Planung steht nichts mit „\(reference)“. finance.plan.read zeigt alles.") }
        throw RPCError.ambiguous("Mehreres in der Planung passt zu „\(reference)“. Bitte die ID verwenden.", candidates: partial.map { $0.0.id.uuidString })
    }
}

// MARK: - Output

struct FinancePlanEntryOutput: Encodable, Sendable {
    var id: String
    var name: String
    var amount: Double
    var interval: String
    var monthly: Double
    var day: Int?
    var category: String?
    var group: String?

    init(_ entry: FinancePlanEntry) {
        id = entry.id.uuidString
        name = entry.name
        amount = FinanceMoney.euros(entry.cents)
        interval = entry.interval.rawValue
        monthly = FinanceMoney.euros(entry.monthly)
        day = entry.dueDay
        category = entry.category
        group = entry.group
    }
}

struct FinanceProjectOutput: Encodable, Sendable {
    var id: String
    var name: String
    var amount: Double
    var saved: Double
    var missing: Double
    var targetDate: String?
    var priority: String
    var done: Bool
    var affordableFrom: String?
    var onTime: Bool?
    var note: String?

    init(_ line: FinancePlanSummary.ProjectLine) {
        let project = line.project
        id = project.id.uuidString
        name = project.name
        amount = FinanceMoney.euros(project.cents)
        saved = FinanceMoney.euros(project.saved)
        missing = FinanceMoney.euros(project.missing)
        targetDate = project.targetDay?.iso
        priority = project.priority.label
        done = project.done
        affordableFrom = line.affordable?.iso
        onTime = line.onTime
        note = project.note.nonEmpty
    }
}

struct FinanceGoalOutput: Encodable, Sendable {
    var id: String
    var name: String
    var target: Double
    var saved: Double
    var progress: Int
    var monthly: Double
    var targetDate: String?
    var reachedOn: String?
    var neededMonthly: Double?

    init(_ line: FinancePlanSummary.GoalLine) {
        let goal = line.goal
        id = goal.id.uuidString
        name = goal.name
        target = FinanceMoney.euros(goal.target)
        saved = FinanceMoney.euros(goal.saved)
        progress = Int((goal.progress * 100).rounded())
        monthly = FinanceMoney.euros(goal.monthly)
        targetDate = goal.targetDay?.iso
        reachedOn = line.reached?.iso
        neededMonthly = line.neededMonthly.map(FinanceMoney.euros)
    }
}

struct FinancePlanOutput: Encodable, Sendable {
    var income: [FinancePlanEntryOutput]
    var fixedCosts: [FinancePlanEntryOutput]
    var projects: [FinanceProjectOutput]
    var goals: [FinanceGoalOutput]
    var monthlyIncome: Double
    var monthlyFixedCosts: Double
    var monthlyVariable: Double
    var countsVariable: Bool
    var monthlySavingRates: Double
    var freePerMonth: Double
    var forProjectsPerMonth: Double
}

extension FinanceLibrary {
    var planOutput: FinancePlanOutput {
        let analysis = analysis
        let summary = analysis.planSummary()
        return FinancePlanOutput(income: state.plan.income.map(FinancePlanEntryOutput.init), fixedCosts: state.plan.fixedCosts.map(FinancePlanEntryOutput.init),
                                 projects: summary.projects.map(FinanceProjectOutput.init), goals: summary.goals.map(FinanceGoalOutput.init),
                                 monthlyIncome: FinanceMoney.euros(summary.income), monthlyFixedCosts: FinanceMoney.euros(summary.fixedCosts),
                                 monthlyVariable: FinanceMoney.euros(summary.variable), countsVariable: summary.countsVariable,
                                 monthlySavingRates: FinanceMoney.euros(summary.savingRates), freePerMonth: FinanceMoney.euros(summary.free),
                                 forProjectsPerMonth: FinanceMoney.euros(summary.forProjects))
    }
}

// MARK: - Actions

struct FinancePlanReadAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "finance.plan.read",
        summary: "Liest die Planung: Einkommen, Fixkosten, Ausgabeprojekte (mit „machbar ab“), Sparziele (mit „erreicht am“) und was im Monat frei bleibt (private Daten)",
        kind: .read, security: financeRead, output: .freeObject(), example: "llmd finance plan read", groups: ["finance.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> FinancePlanOutput {
        context.app.finance.planOutput
    }
}

struct FinancePlanConfigureAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var countsVariable: Bool
    }
    static let descriptor = ActionDescriptor(
        id: "finance.plan.configure", summary: "Legt fest, ob der Durchschnitt der übrigen Ausgaben (letzte drei Monate) vom frei verfügbaren Betrag abgeht",
        kind: .write, security: .localWrite, input: .object(["countsVariable": .boolean("Übrige Ausgaben einrechnen")], required: ["countsVariable"]),
        output: .freeObject(), example: "llmd finance plan configure --counts-variable false"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        context.changeFinance("Planung einstellen") { context.app.finance.changeState { $0.plan.countsVariable = args.countsVariable } }
        return OKOutput()
    }
}

struct FinanceIncomeAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var amount: Double
        var interval: String?
        var day: Int?
        var group: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.income.add", summary: "Trägt ein regelmäßiges Einkommen in die Planung ein (Gehalt, Kindergeld …)", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name, z. B. Gehalt"), "amount": .number("Betrag je Zahlung in Euro", minimum: 0),
                        "interval": .choice(FinanceInterval.allCases.map(\.rawValue), "Rhythmus (Vorgabe monatlich)"),
                        "day": .integer("Tag im Monat", minimum: 1, maximum: 31), "group": financeGroupProperty], required: ["name", "amount"]),
        output: .freeObject(), example: "llmd finance income add --name Gehalt --amount 3200 --day 28"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinancePlanEntryOutput {
        var entry = FinancePlanEntry(name: args.name, cents: try FinanceArgs.cents(args.amount, "amount", positive: true) ?? 0,
                                     interval: try FinanceArgs.choice(args.interval, FinanceInterval.self, "interval") ?? .monthly, dueDay: args.day)
        entry.group = try args.group.map { try context.app.actionFinanceGroup($0).key }
        let made = entry
        context.changeFinance("Einkommen eintragen") { context.app.finance.changeState { $0.plan.income.append(made) } }
        return FinancePlanEntryOutput(made)
    }
}

struct FinanceFixedCostAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String?
        var amount: Double?
        var interval: String?
        var day: Int?
        var category: String?
        var group: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.fixedCost.add",
        summary: "Trägt Fixkosten in die Planung ein (Miete, Versicherung, Abo); mit group übernimmt sie Name, Betrag, Rhythmus und Tag aus den erkannten Buchungen",
        kind: .write, security: .localWrite,
        input: .object(["name": .string("Name, z. B. Miete"), "amount": .number("Betrag je Zahlung in Euro (positiv)", minimum: 0),
                        "interval": .choice(FinanceInterval.allCases.map(\.rawValue), "Rhythmus (Vorgabe monatlich)"),
                        "day": .integer("Tag im Monat", minimum: 1, maximum: 31), "category": financeCategoryProperty, "group": financeGroupProperty]),
        output: .freeObject(), example: "llmd finance fixed-cost add --name Miete --amount 950 --day 1"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinancePlanEntryOutput {
        let app = context.app
        let group = try args.group.map { try app.actionFinanceGroup($0) }
        let recurrence = group?.recurrence
        guard let name = args.name ?? group?.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw RPCError.invalidParams("Gib name oder group an.") }
        guard let cents = try FinanceArgs.cents(args.amount, "amount", positive: true) ?? recurrence.map({ abs($0.cents) }) else {
            throw RPCError.invalidParams("Gib amount an; die Gruppe hat keinen erkannten Rhythmus.")
        }
        var entry = FinancePlanEntry(name: name, cents: cents, interval: try FinanceArgs.choice(args.interval, FinanceInterval.self, "interval") ?? recurrence?.interval ?? .monthly,
                                     dueDay: args.day ?? recurrence?.dueDay, category: try args.category.map { try app.actionFinanceCategory($0).key } ?? group?.category,
                                     group: group?.key)
        entry.note = ""
        let made = entry
        context.changeFinance("Fixkosten eintragen") { app.finance.changeState { $0.plan.fixedCosts.append(made) } }
        return FinancePlanEntryOutput(made)
    }
}

struct FinanceProjectAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var amount: Double
        var targetDate: String?
        var priority: String?
        var saved: Double?
        var note: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.project.add", summary: "Trägt ein Ausgabeprojekt ein (z. B. Mac mini M5 Pro für 3500 €); die Planung sagt, ab wann es machbar ist",
        kind: .write, security: .localWrite,
        input: .object(["name": .string("Was es ist"), "amount": .number("Kostenpunkt in Euro", minimum: 0), "targetDate": .string("Bis wann (optional)"),
                        "priority": .choice(["hoch", "mittel", "niedrig"], "Priorität (Vorgabe mittel)"), "saved": .number("Schon zurückgelegt in Euro", minimum: 0),
                        "note": .string("Notiz")], required: ["name", "amount"]),
        output: .freeObject(), example: "llmd finance project add --name \"Mac mini M5 Pro\" --amount 3500 --target-date 2027-03-01", groups: ["finance.core"]
    )
    static func priority(_ text: String?) throws -> FinanceProject.Priority? {
        guard let text else { return nil }
        guard let found = FinanceProject.Priority.allCases.first(where: { $0.label == text.lowercased() }) else {
            throw RPCError.invalidParams("Priorität „\(text)“ gibt es nicht. Möglich: hoch, mittel, niedrig.")
        }
        return found
    }
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceProjectOutput {
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RPCError.invalidParams("Das Projekt braucht einen Namen.") }
        var project = FinanceProject(name: name, cents: try FinanceArgs.cents(args.amount, "amount", positive: true) ?? 0,
                                     targetDay: try FinanceArgs.day(args.targetDate, "targetDate"), priority: try priority(args.priority) ?? .medium)
        project.saved = try FinanceArgs.cents(args.saved, "saved", positive: true) ?? 0
        project.note = args.note ?? ""
        let made = project
        let library = context.app.finance
        context.changeFinance("Projekt eintragen") { library.changeState { $0.plan.projects.append(made) } }
        let line = library.analysis.planSummary().projects.first { $0.project.id == made.id } ?? .init(project: made, affordable: nil, onTime: nil)
        return FinanceProjectOutput(line)
    }
}

struct FinanceGoalAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String
        var target: Double
        var saved: Double?
        var monthly: Double?
        var targetDate: String?
    }
    static let descriptor = ActionDescriptor(
        id: "finance.goal.add", summary: "Legt ein Sparziel an (Notgroschen, Urlaub) mit Zielbetrag, Monatsrate und Zieldatum", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "target": .number("Zielbetrag in Euro", minimum: 0), "saved": .number("Schon gespart in Euro", minimum: 0),
                        "monthly": .number("Sparrate je Monat in Euro", minimum: 0), "targetDate": .string("Bis wann (optional)")], required: ["name", "target"]),
        output: .freeObject(), example: "llmd finance goal add --name Notgroschen --target 6000 --monthly 250", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> FinanceGoalOutput {
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RPCError.invalidParams("Das Sparziel braucht einen Namen.") }
        let goal = FinanceGoal(name: name, target: try FinanceArgs.cents(args.target, "target", positive: true) ?? 0,
                               saved: try FinanceArgs.cents(args.saved, "saved", positive: true) ?? 0, monthly: try FinanceArgs.cents(args.monthly, "monthly", positive: true) ?? 0,
                               targetDay: try FinanceArgs.day(args.targetDate, "targetDate"))
        let library = context.app.finance
        context.changeFinance("Sparziel anlegen") { library.changeState { $0.plan.goals.append(goal) } }
        let line = library.analysis.planSummary().goals.first { $0.goal.id == goal.id } ?? .init(goal: goal, reached: nil, neededMonthly: nil)
        return FinanceGoalOutput(line)
    }
}

struct FinancePlanUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var item: String
        var name: String?
        var amount: Double?
        var interval: String?
        var day: Int?
        var category: String?
        var group: String?
        var targetDate: String?
        var priority: String?
        var saved: Double?
        var monthly: Double?
        var target: Double?
        var done: Bool?
        var note: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var kind: String
        var changed: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "finance.plan.update",
        summary: "Ändert einen Eintrag der Planung; es gilt, was zur Art passt: amount (Einkommen, Fixkosten, Projekt), interval/day/category/group, targetDate, priority, saved, monthly/target (Sparziel), done (Projekt)",
        kind: .write, security: .localWrite,
        input: .object(["item": planItemProperty, "name": .string("Name"), "amount": .number("Betrag in Euro", minimum: 0),
                        "interval": .choice(FinanceInterval.allCases.map(\.rawValue), "Rhythmus"), "day": .integer("Tag im Monat", minimum: 1, maximum: 31),
                        "category": financeCategoryProperty, "group": financeGroupProperty, "targetDate": .string("Zieldatum; \"\" nimmt es weg"),
                        "priority": .choice(["hoch", "mittel", "niedrig"], "Priorität"), "saved": .number("Angespart in Euro", minimum: 0),
                        "monthly": .number("Sparrate je Monat in Euro", minimum: 0), "target": .number("Zielbetrag in Euro", minimum: 0),
                        "done": .boolean("Projekt erledigt (gekauft)"), "note": .string("Notiz")], required: ["item"]),
        output: .freeObject(), example: "llmd finance plan update --item \"Mac mini M5 Pro\" --saved 500"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let item = try app.actionFinancePlanItem(args.item)
        let amount = try FinanceArgs.cents(args.amount, "amount", positive: true)
        let saved = try FinanceArgs.cents(args.saved, "saved", positive: true)
        let monthly = try FinanceArgs.cents(args.monthly, "monthly", positive: true)
        let target = try FinanceArgs.cents(args.target, "target", positive: true)
        let interval = try FinanceArgs.choice(args.interval, FinanceInterval.self, "interval")
        let category = try args.category.flatMap { $0.isEmpty ? nil : try app.actionFinanceCategory($0).key }
        let group = try args.group.flatMap { $0.isEmpty ? nil : try app.actionFinanceGroup($0).key }
        let clearsTarget = args.targetDate?.isEmpty == true
        let targetDay = clearsTarget ? nil : try FinanceArgs.day(args.targetDate, "targetDate")
        let priority = try FinanceProjectAddAction.priority(args.priority)
        var changed: [String] = []
        func note(_ field: String, _ applies: Bool) throws {
            guard applies else { throw RPCError.invalidParams("\(field) passt nicht zu einem Eintrag der Art „\(item.kind)“.") }
            changed.append(field)
        }
        var state = app.finance.state
        func entry(_ entry: inout FinancePlanEntry) throws {
            if let name = args.name { entry.name = name; changed.append("name") }
            if let amount { entry.cents = amount; changed.append("amount") }
            if let interval { entry.interval = interval; changed.append("interval") }
            if let day = args.day { entry.dueDay = day; changed.append("day") }
            if args.category != nil { entry.category = category; changed.append("category") }
            if args.group != nil { entry.group = group; changed.append("group") }
            if let text = args.note { entry.note = text; changed.append("note") }
            for (field, given) in [("targetDate", args.targetDate != nil), ("priority", args.priority != nil), ("saved", saved != nil), ("monthly", monthly != nil),
                                   ("target", target != nil), ("done", args.done != nil)] where given { try note(field, false) }
        }
        switch item {
        case .income(let id):
            guard let index = state.plan.income.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Den Eintrag gibt es nicht mehr.") }
            try entry(&state.plan.income[index])
        case .fixedCost(let id):
            guard let index = state.plan.fixedCosts.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Den Eintrag gibt es nicht mehr.") }
            try entry(&state.plan.fixedCosts[index])
        case .project(let id):
            guard let index = state.plan.projects.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Das Projekt gibt es nicht mehr.") }
            var project = state.plan.projects[index]
            if let name = args.name { project.name = name; changed.append("name") }
            if let amount { project.cents = amount; changed.append("amount") }
            if args.targetDate != nil { project.targetDay = targetDay; changed.append("targetDate") }
            if let priority { project.priority = priority; changed.append("priority") }
            if let saved { project.saved = saved; changed.append("saved") }
            if let done = args.done { project.done = done; changed.append("done") }
            if let text = args.note { project.note = text; changed.append("note") }
            for (field, given) in [("interval", interval != nil), ("day", args.day != nil), ("category", args.category != nil), ("group", args.group != nil),
                                   ("monthly", monthly != nil), ("target", target != nil)] where given { try note(field, false) }
            state.plan.projects[index] = project
        case .goal(let id):
            guard let index = state.plan.goals.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Das Sparziel gibt es nicht mehr.") }
            var goal = state.plan.goals[index]
            if let name = args.name { goal.name = name; changed.append("name") }
            if let target = target ?? amount { goal.target = target; changed.append("target") }
            if let saved { goal.saved = saved; changed.append("saved") }
            if let monthly { goal.monthly = monthly; changed.append("monthly") }
            if args.targetDate != nil { goal.targetDay = targetDay; changed.append("targetDate") }
            if let text = args.note { goal.note = text; changed.append("note") }
            for (field, given) in [("interval", interval != nil), ("day", args.day != nil), ("category", args.category != nil), ("group", args.group != nil),
                                   ("priority", priority != nil), ("done", args.done != nil)] where given { try note(field, false) }
            state.plan.goals[index] = goal
        }
        guard !changed.isEmpty else { throw RPCError.invalidParams("Es ist nichts zu ändern angegeben.") }
        let result = state
        context.changeFinance("Planung ändern") { app.finance.changeState { $0 = result } }
        return Output(id: item.id.uuidString, kind: item.kind, changed: changed)
    }
}

struct FinancePlanRemoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var item: String
    }
    static let descriptor = ActionDescriptor(
        id: "finance.plan.remove", summary: "Nimmt einen Eintrag aus der Planung (Einkommen, Fixkosten, Projekt, Sparziel)", kind: .destructive, security: .destructive,
        input: .object(["item": planItemProperty], required: ["item"]), output: .freeObject(), example: "llmd finance plan remove --item Fitnessstudio"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let item = try context.app.actionFinancePlanItem(args.item)
        context.changeFinance("Aus der Planung nehmen") {
            context.app.finance.changeState { state in
                state.plan.income.removeAll { $0.id == item.id }
                state.plan.fixedCosts.removeAll { $0.id == item.id }
                state.plan.projects.removeAll { $0.id == item.id }
                state.plan.goals.removeAll { $0.id == item.id }
            }
        }
        return OKOutput(id: item.id.uuidString, message: item.kind)
    }
}

struct FinanceGoalDepositAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var goal: String
        var amount: Double
    }
    struct Output: Encodable, Sendable {
        var id: String
        var name: String
        var saved: Double
        var missing: Double
    }
    static let descriptor = ActionDescriptor(
        id: "finance.goal.deposit", summary: "Legt Geld in ein Sparziel oder ein Projekt (negativ nimmt es heraus)", kind: .write, security: .localWrite,
        input: .object(["goal": .string("Sparziel oder Projekt (ID oder Name)"), "amount": .number("Betrag in Euro")], required: ["goal", "amount"]),
        output: .freeObject(), example: "llmd finance goal deposit --goal Notgroschen --amount 250", groups: ["finance.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let item = try app.actionFinancePlanItem(args.goal)
        let cents = try FinanceArgs.cents(args.amount, "amount") ?? 0
        var result: Output?
        try context.changeFinance("Einzahlen") {
            var state = app.finance.state
            switch item {
            case .goal(let id):
                guard let index = state.plan.goals.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Das Sparziel gibt es nicht mehr.") }
                state.plan.goals[index].saved = max(0, state.plan.goals[index].saved + cents)
                let goal = state.plan.goals[index]
                result = Output(id: goal.id.uuidString, name: goal.name, saved: FinanceMoney.euros(goal.saved), missing: FinanceMoney.euros(goal.missing))
            case .project(let id):
                guard let index = state.plan.projects.firstIndex(where: { $0.id == id }) else { throw RPCError.notFound("Das Projekt gibt es nicht mehr.") }
                state.plan.projects[index].saved = max(0, state.plan.projects[index].saved + cents)
                let project = state.plan.projects[index]
                result = Output(id: project.id.uuidString, name: project.name, saved: FinanceMoney.euros(project.saved), missing: FinanceMoney.euros(project.missing))
            case .income, .fixedCost:
                throw RPCError.invalidParams("Einzahlen geht nur in ein Sparziel oder ein Projekt.")
            }
            let changed = state
            app.finance.changeState { $0 = changed }
        }
        guard let result else { throw RPCError.internal("Nichts eingezahlt.") }
        return result
    }
}
