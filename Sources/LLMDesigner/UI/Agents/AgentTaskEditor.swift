import LLMDProtocol
import SwiftUI

/// The building blocks of a task: goal, steps (KI-Schritte and actions from the catalog), schedule and options.
struct AgentTaskEditor: View {
    @Environment(AppModel.self) private var app
    let taskID: UUID
    @State private var pickingAction = false
    @State private var confirmDelete = false
    @State private var message: String?

    private var center: AgentCenter { app.agents }

    var body: some View {
        if let task = center.task(taskID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(task)
                    if let message {
                        Text(message).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                    if task.origin == .foreign {
                        Label("Diese Aufgabe hat ein Chat oder ein MCP-Client geschrieben. Ihre Läufe gelten als fremd und fragen vor jeder Änderung.", systemImage: "exclamationmark.shield")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StudioCard(title: "Ziel", symbol: "target") {
                        TextField("Wozu dient die Aufgabe? Jeder KI-Schritt liest das.", text: binding(\.goal), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(2...6)
                    }
                    StudioCard(title: "Bausteine", symbol: "square.stack.3d.up") {
                        VStack(alignment: .leading, spacing: 10) {
                            if task.steps.isEmpty {
                                Text("Noch keine Schritte. Füge einen KI-Schritt hinzu oder wähle eine Action aus dem Katalog.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            ForEach(Array(task.steps.enumerated()), id: \.element.id) { index, step in
                                AgentStepEditor(taskID: taskID, stepID: step.id, number: index + 1, count: task.steps.count)
                            }
                            HStack(spacing: 8) {
                                Button {
                                    addStep(AgentStepDefinition(kind: .agent, title: "KI-Schritt \(task.steps.count + 1)", instruction: "", tools: ["writer.core"]))
                                } label: { Label("KI-Schritt", systemImage: "sparkles") }
                                Button {
                                    pickingAction = true
                                } label: { Label("Action aus dem Katalog …", systemImage: "list.bullet.rectangle") }
                                Spacer(minLength: 0)
                            }
                            .controlSize(.small)
                            Text("In Parametern von Actions: {{schritt1.id}}, {{vorher.title}}, {{ziel}}, {{heute}}. KI-Schritte lesen das Ergebnis aller früheren Schritte von selbst.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    AgentScheduleEditor(taskID: taskID)
                    optionsCard(task)
                    runsCard(task)
                }
                .padding(18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $pickingAction) {
                AgentActionPicker { descriptor in
                    addStep(AgentStepDefinition(kind: .action, title: descriptor.summary, action: descriptor.id, arguments: AgentActionPicker.initialArguments(for: descriptor)))
                }
            }
            .confirmationDialog("„\(task.title)“ in den Papierkorb legen?", isPresented: $confirmDelete) {
                Button("In den Papierkorb", role: .destructive) {
                    do { try app.deleteAgentTask(taskID) } catch { message = error.localizedDescription }
                }
            } message: {
                Text("Die Aufgabe kommt aus dem Papierkorb zurück, solange er nicht geleert ist. Ihre Läufe und Commits bleiben.")
            }
        } else {
            StudioEmptyState(symbol: "questionmark.square.dashed", title: "Aufgabe nicht gefunden", text: "Sie wurde gelöscht oder kommt aus einer anderen Bibliothek.")
        }
    }

    private func header(_ task: AgentTask) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Titel", text: binding(\.title))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 8)
            if center.isActive(taskID) {
                Tag(text: "läuft", color: Theme.success)
            }
            Button {
                do {
                    let run = try app.enqueueAgentRun(taskID, trigger: .person)
                    center.selection = .run(run.id)
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
            } label: {
                Label("Jetzt starten", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(center.isActive(taskID) || task.steps.isEmpty)
            IconButton(systemName: "trash", help: "Aufgabe löschen", size: 13, frameSize: 28) { confirmDelete = true }
        }
    }

    private func optionsCard(_ task: AgentTask) -> some View {
        StudioCard(title: "Optionen", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Ohne Rückfrage", selection: binding(\.options.approval)) {
                    ForEach(ChatToolApproval.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 420)
                .disabled(task.origin == .foreign)
                Toggle("Jeder Lauf auf einem eigenen Git-Branch, ein Commit pro Schritt", isOn: binding(\.options.usesBranch))
                if !app.git.isEnabled, task.options.usesBranch {
                    Text("Git ist für diese Bibliothek aus. Ohne Git laufen Aufgaben ohne Branch und lassen sich nicht zurücknehmen. Einschalten: Power-Zugriff → Git.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Danach den Mac in den Ruhezustand versetzen", isOn: binding(\.options.sleepAfter))
                Text("Nach einem fertigen Lauf wartet der Mac eine Minute. Benutzt ihn in der Zeit jemand oder wartet ein weiterer Lauf, schläft er nicht ein. Während ein Agent arbeitet, bleibt der Mac immer wach.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Modell", selection: binding(\.options.model)) {
                    Text("Wie in den Chats").tag(String?.none)
                    ForEach(app.chatModels) { model in
                        Text(model.id).tag(String?.some(model.id))
                    }
                    if let model = task.options.model, !app.chatModels.contains(where: { $0.id == model }) {
                        Text(model).tag(String?.some(model))
                    }
                }
                .frame(maxWidth: 420)
            }
        }
    }

    private func runsCard(_ task: AgentTask) -> some View {
        let runs = center.runs(of: taskID)
        return StudioCard(title: "Läufe", symbol: "clock.arrow.circlepath") {
            if runs.isEmpty {
                Text("Noch kein Lauf.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(runs.prefix(8)) { run in
                        StudioListRow(symbol: AgentStyle.symbol(run.state), color: AgentStyle.color(run.state), title: (run.startedAt ?? run.queuedAt).formatted(date: .abbreviated, time: .shortened),
                                      subtitle: run.error ?? "\(run.doneCount)/\(run.steps.count) Schritte · \(run.state.label)", trailing: run.shortID, isSelected: false) {
                            center.selection = .run(run.id)
                        }
                    }
                }
            }
        }
    }

    private func addStep(_ step: AgentStepDefinition) {
        center.tasks.update(taskID) { $0.steps.append(step) }
    }

    private func binding<Value>(_ path: WritableKeyPath<AgentTask, Value>) -> Binding<Value> {
        Binding {
            center.task(taskID)?[keyPath: path] ?? AgentTask(title: "")[keyPath: path]
        } set: { value in
            center.tasks.update(taskID) { $0[keyPath: path] = value }
        }
    }
}

/// One step in the building blocks.
private struct AgentStepEditor: View {
    @Environment(AppModel.self) private var app
    let taskID: UUID
    let stepID: UUID
    let number: Int
    let count: Int
    @State private var showsTools = false

    private var center: AgentCenter { app.agents }
    private var step: AgentStepDefinition? { center.task(taskID)?.steps.first { $0.id == stepID } }

    var body: some View {
        if let step {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(step.kind == .agent ? Theme.accent : Theme.textTertiary))
                    Image(systemName: step.kind == .agent ? "sparkles" : "bolt.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Titel", text: binding(\.title))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Picker("", selection: binding(\.onError)) {
                        Text("Bei Fehler abbrechen").tag(AgentStepDefinition.OnError.stop)
                        Text("Bei Fehler weiter").tag(AgentStepDefinition.OnError.go)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                    IconButton(systemName: "chevron.up", help: "Nach oben", size: 10, frameSize: 22) { move(-1) }
                        .disabled(number == 1)
                    IconButton(systemName: "chevron.down", help: "Nach unten", size: 10, frameSize: 22) { move(1) }
                        .disabled(number == count)
                    IconButton(systemName: "xmark", help: "Schritt entfernen", size: 10, frameSize: 22) {
                        center.tasks.update(taskID) { $0.steps.removeAll { $0.id == stepID } }
                    }
                }
                switch step.kind {
                case .agent: agentFields(step)
                case .action: actionFields(step)
                }
                if let problem = step.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        }
    }

    @ViewBuilder private func agentFields(_ step: AgentStepDefinition) -> some View {
        TextField("Auftrag: Was genau soll das Modell tun, und was liegt danach vor?", text: Binding {
            self.step?.instruction ?? ""
        } set: { value in
            update { $0.instruction = value }
        }, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .lineLimit(2...8)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
        HStack(spacing: 6) {
            Button {
                showsTools.toggle()
            } label: {
                Label("Werkzeuge: \((step.tools ?? []).isEmpty ? "keine" : (step.tools ?? []).map(Self.groupLabel).joined(separator: ", "))", systemImage: "wrench.and.screwdriver")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .popover(isPresented: $showsTools) { toolPicker }
            Spacer(minLength: 0)
            Stepper("Höchstens \(step.rounds) Runden", value: Binding {
                self.step?.rounds ?? AgentStepDefinition.defaultRounds
            } set: { value in
                update { $0.maxRounds = value }
            }, in: 2...40)
            .font(.system(size: 11.5))
            .controlSize(.small)
            Toggle("Nachdenken", isOn: Binding { self.step?.thinking == true } set: { value in update { $0.thinking = value } })
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .help("Das Modell denkt vor jeder Runde nach: gründlicher, aber deutlich langsamer.")
        }
        if (step.tools ?? []).count > 2 {
            Text("Ein kleines Modell kommt mit ein bis zwei Gruppen am besten zurecht.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    static func groupLabel(_ id: String) -> String {
        AgentToolbox.groups.first { $0.id == id }.map { String($0.label.prefix { $0 != ":" }) } ?? id
    }

    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Werkzeuge dieses Schritts").font(.system(size: 12, weight: .semibold))
            ForEach(AgentToolbox.groups, id: \.id) { group in
                Toggle(isOn: Binding {
                    self.step?.tools?.contains(group.id) == true
                } set: { on in
                    update { step in
                        var tools = step.tools ?? []
                        if on { if !tools.contains(group.id) { tools.append(group.id) } } else { tools.removeAll { $0 == group.id } }
                        step.tools = tools
                    }
                }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.label).font(.system(size: 12))
                        Text(group.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private func actionFields(_ step: AgentStepDefinition) -> some View {
        if let id = step.action, let descriptor = app.actionRegistry?.descriptor(id) {
            HStack(spacing: 6) {
                Text(id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accent)
                Tag(text: descriptor.kind.label, color: descriptor.kind == .destructive ? Theme.danger : Theme.textSecondary)
                Text(descriptor.summary).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            AgentArgumentsEditor(schema: descriptor.input, arguments: Binding {
                self.step?.arguments ?? .object([:])
            } set: { value in
                update { $0.arguments = value }
            })
        } else {
            Text("Die Action „\(step.action ?? "")“ gibt es nicht.").font(.system(size: 12)).foregroundStyle(Theme.danger)
        }
    }

    private func update(_ change: (inout AgentStepDefinition) -> Void) {
        center.tasks.update(taskID) { task in
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return }
            change(&task.steps[index])
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<AgentStepDefinition, Value>) -> Binding<Value> {
        Binding {
            step?[keyPath: path] ?? AgentStepDefinition(kind: .agent, title: "")[keyPath: path]
        } set: { value in
            update { $0[keyPath: path] = value }
        }
    }

    private func move(_ offset: Int) {
        center.tasks.update(taskID) { task in
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return }
            let target = index + offset
            guard task.steps.indices.contains(target) else { return }
            task.steps.swapAt(index, target)
        }
    }
}

/// A form from an action's schema: text, numbers, yes/no and choices as fields; lists and objects as JSON.
struct AgentArgumentsEditor: View {
    let schema: JSONSchema
    @Binding var arguments: JSONValue

    var body: some View {
        let required = Set(schema.required ?? [])
        let properties = (schema.properties ?? [:]).sorted { lhs, rhs in
            let (a, b) = (required.contains(lhs.key), required.contains(rhs.key))
            return a != b ? a : lhs.key < rhs.key
        }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(properties, id: \.key) { key, property in
                GridRow {
                    Text(key + (required.contains(key) ? " *" : ""))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(required.contains(key) ? Theme.textPrimary : Theme.textTertiary)
                        .gridColumnAlignment(.trailing)
                    field(key, property)
                        .help(property.description ?? key)
                }
            }
        }
    }

    @ViewBuilder private func field(_ key: String, _ property: JSONSchema) -> some View {
        switch property.type {
        case "boolean":
            Picker("", selection: Binding<Int> {
                switch arguments[key]?.boolValue { case true?: 1; case false?: 2; case nil: 0 }
            } set: { choice in
                set(key, choice == 0 ? nil : .bool(choice == 1))
            }) {
                Text("–").tag(0)
                Text("ja").tag(1)
                Text("nein").tag(2)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
        case "string" where property.enumValues != nil:
            Picker("", selection: Binding<String> {
                arguments[key]?.stringValue ?? ""
            } set: { value in
                set(key, value.isEmpty ? nil : .string(value))
            }) {
                Text("–").tag("")
                ForEach(property.enumValues ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
        case "string":
            StudioField(placeholder: property.description ?? "", text: Binding {
                arguments[key]?.stringValue ?? ""
            } set: { value in
                set(key, value.isEmpty ? nil : .string(value))
            }, font: .system(size: 12))
        case "integer", "number":
            StudioField(placeholder: property.description ?? "Zahl", text: Binding {
                switch arguments[key] {
                case .int(let value)?: String(value)
                case .double(let value)?: String(value)
                case .string(let value)?: value
                default: ""
                }
            } set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { set(key, nil) } else if let int = Int(trimmed) { set(key, .int(int)) } else if let double = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { set(key, .double(double)) } else { set(key, .string(trimmed)) }
            }, font: .system(size: 12))
            .frame(maxWidth: 200, alignment: .leading)
        default:
            StudioField(placeholder: "JSON, z. B. [\"…\"]", text: Binding {
                arguments[key].map { $0.stringValue ?? $0.jsonLine() } ?? ""
            } set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { set(key, nil) } else { set(key, (try? JSONValue.parse(trimmed)) ?? .string(trimmed)) }
            }, monospaced: true)
        }
    }

    private func set(_ key: String, _ value: JSONValue?) {
        var object = arguments.objectValue ?? [:]
        object[key] = value
        arguments = .object(object)
    }
}

/// The catalog to choose an action from: every action the registry knows, except AgentSteps' own and private ones.
struct AgentActionPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let choose: (ActionDescriptor) -> Void
    @State private var query = ""

    static func initialArguments(for descriptor: ActionDescriptor) -> JSONValue {
        .object([:])
    }

    private var actions: [ActionDescriptor] {
        let all = (app.actionRegistry?.descriptors ?? []).filter { $0.module != "agents" && !$0.security.sensitive }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { action in
            let text = (action.id + " " + action.summary).lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    var body: some View {
        let grouped = Dictionary(grouping: actions, by: \.module).sorted { $0.key < $1.key }
        VStack(spacing: 0) {
            HStack {
                Text("Action aus dem Katalog").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(actions.count) Actions").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Button("Abbrechen") { dismiss() }
            }
            .padding(14)
            SearchField(text: $query, prompt: "Suchen, z. B. „dokument anlegen“ oder writer.export")
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            List {
                ForEach(grouped, id: \.key) { module, list in
                    Section(module) {
                        ForEach(list, id: \.id) { action in
                            Button {
                                choose(action)
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(action.id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accent)
                                    Text(action.summary).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Tag(text: action.kind.label, color: action.kind == .destructive ? Theme.danger : Theme.textSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 560)
    }
}

/// When a task runs by itself.
private struct AgentScheduleEditor: View {
    @Environment(AppModel.self) private var app
    let taskID: UUID

    private var schedule: AgentSchedule { app.agents.task(taskID)?.schedule ?? AgentSchedule() }

    var body: some View {
        let schedule = self.schedule
        StudioCard(title: "Zeitplan", symbol: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("", selection: binding(\.kind)) {
                    ForEach(AgentSchedule.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch schedule.kind {
                case .manual:
                    Text("Die Aufgabe läuft nur, wenn du sie startest (oder ein Chat oder das Terminal).")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                case .once:
                    DatePicker("Am", selection: Binding { schedule.date ?? Date().addingTimeInterval(3600) } set: { value in change { $0.date = value } })
                        .frame(maxWidth: 320)
                case .daily:
                    timeField
                case .weekly:
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            let on = schedule.weekdays.contains(day)
                            Button(AgentSchedule.weekdayNames[day - 1]) {
                                change { schedule in
                                    if on { schedule.weekdays.removeAll { $0 == day } } else { schedule.weekdays = (schedule.weekdays + [day]).sorted() }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                            .frame(width: 34, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent.opacity(0.22) : Theme.ink.opacity(0.04)))
                        }
                    }
                    timeField
                case .interval:
                    Stepper(value: binding(\.intervalMinutes), in: AgentSchedule.minimumInterval...10_080, step: schedule.intervalMinutes >= 60 ? 30 : 5) {
                        Text(schedule.summary.prefix(1).uppercased() + schedule.summary.dropFirst())
                            .font(.system(size: 12.5))
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
                if schedule.isTimed {
                    HStack(spacing: 14) {
                        Toggle("Zeitplan an", isOn: binding(\.isOn))
                        Toggle("Verpasste Zeit nachholen", isOn: binding(\.catchUp))
                            .help("War die App zu oder der Mac im Ruhezustand, läuft die Aufgabe einmal, sobald es wieder geht.")
                    }
                    .font(.system(size: 12))
                    if let problem = schedule.problem {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                    } else if let next = schedule.nextSlot(after: Date()) {
                        Label("Nächster Lauf: \(next.formatted(date: .complete, time: .shortened))", systemImage: "clock")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Zeitpläne laufen, solange LLM Designer geöffnet ist. Schläft der Mac zur geplanten Zeit, holt die App den Lauf nach dem Aufwachen nach.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var timeField: some View {
        let parts = schedule.clock ?? (8, 0)
        let date = Calendar.current.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: Date()) ?? Date()
        return DatePicker("Um", selection: Binding { date } set: { value in
            let components = Calendar.current.dateComponents([.hour, .minute], from: value)
            change { $0.time = String(format: "%02d:%02d", components.hour ?? 8, components.minute ?? 0) }
        }, displayedComponents: .hourAndMinute)
        .frame(maxWidth: 200)
    }

    /// A changed schedule counts from now: today's time that already passed doesn't start a run at once.
    private func change(_ edit: (inout AgentSchedule) -> Void) {
        app.agents.tasks.update(taskID) { task in
            edit(&task.schedule)
            task.schedule.since = Date()
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<AgentSchedule, Value>) -> Binding<Value> {
        Binding { schedule[keyPath: path] } set: { value in change { $0[keyPath: path] = value } }
    }
}

/// Symbols and colours of run states, the same everywhere.
enum AgentStyle {
    /// What kind of thing a run made, by the module of the action that made it.
    static func label(ofResult kind: String) -> String {
        switch kind {
        case "writer": "Dokument"
        case "presenter": "Präsentation"
        case "citation": "Quelle"
        case "stories": "Romanwelt"
        case "notes": "Note"
        case "projects": "Projekt"
        case "podcast": "Podcast"
        case "data": "Datenblock"
        case "research": "Recherche"
        case "learning": "Kurs"
        case "chat": "Chat"
        default: kind
        }
    }

    static func symbol(_ state: AgentRun.State) -> String {
        switch state {
        case .queued: "hourglass"
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .asking: "questionmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .interrupted: "bolt.horizontal.circle"
        case .undone: "arrow.uturn.backward.circle"
        }
    }

    static func color(_ state: AgentRun.State) -> Color {
        switch state {
        case .queued: Theme.textSecondary
        case .running: Theme.accent
        case .paused, .asking, .interrupted: Theme.warning
        case .finished: Theme.success
        case .failed: Theme.danger
        case .cancelled, .undone: Theme.textTertiary
        }
    }

    static func symbol(_ state: AgentRunStep.State) -> String {
        switch state {
        case .pending: "circle"
        case .running: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "arrow.right.circle"
        }
    }

    static func color(_ state: AgentRunStep.State) -> Color {
        switch state {
        case .pending, .skipped: Theme.textTertiary
        case .running: Theme.accent
        case .done: Theme.success
        case .failed: Theme.danger
        }
    }
}
