import Foundation
import LLMDProtocol

/// The chat in which the person develops a task. The model only proposes: a draft becomes a task when the person
/// saves it, and pausing or stopping runs through what the interface does anyway.
@MainActor
@Observable
final class AgentPlanningChat {
    struct Message: Identifiable, Hashable {
        enum Role: String { case person, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var time = Date()
    }

    var messages: [Message] = []
    var draft: AgentDraft?
    var input = ""
    var isWorking = false
    var error: String?
    /// The chat asked whether to cancel this run; a button confirms it.
    var cancelOffer: UUID?
    @ObservationIgnored var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        messages = []
        draft = nil
        input = ""
        isWorking = false
        error = nil
        cancelOffer = nil
    }
}

/// A task as the chat proposes it, before the person saves it.
struct AgentDraft: Hashable, Sendable {
    var title: String
    var goal: String
    var steps: [AgentStepDefinition]
    var schedule: AgentSchedule
    var sleepAfter: Bool

    func task(origin: AgentTaskOrigin = .own) -> AgentTask {
        var task = AgentTask(title: title.isEmpty ? "Neue Aufgabe" : title, goal: goal, steps: steps)
        task.schedule = schedule
        task.schedule.since = Date()
        task.options.sleepAfter = sleepAfter
        task.origin = origin
        return task
    }
}

@MainActor
enum AgentPlanner {
    enum Intent: String, CaseIterable {
        case draft = "entwurf"
        case pause = "pausieren"
        case resume = "fortsetzen"
        case cancel = "abbrechen"
        case none = "keine"
    }

    struct Reply {
        var text: String
        var intent: Intent
        var draft: AgentDraft?
    }

    /// The order of the keys is the order the model writes in: the plan first, the sentence to the person last, so
    /// that sentence describes what is really in the plan.
    static var schemaJSON: String {
        let groups = AgentToolbox.groups.map { "\"\($0.id)\"" }.joined(separator: ",")
        return """
        {"type":"object","additionalProperties":false,"required":["absicht","titel","ziel","schritte","zeitplan","ruhezustand","antwort"],"properties":{\
        "absicht":{"type":"string","enum":["entwurf","pausieren","fortsetzen","abbrechen","keine"]},\
        "titel":{"type":"string"},\
        "ziel":{"type":"string"},\
        "schritte":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["titel","auftrag","werkzeuge"],"properties":{\
        "titel":{"type":"string"},"auftrag":{"type":"string"},"werkzeuge":{"type":"array","items":{"type":"string","enum":[\(groups)]}}}}},\
        "zeitplan":{"type":"object","additionalProperties":false,"required":["art","uhrzeit","wochentage","alleMinuten","datum"],"properties":{\
        "art":{"type":"string","enum":["manuell","einmalig","taeglich","woechentlich","intervall"]},"uhrzeit":{"type":"string"},\
        "wochentage":{"type":"array","items":{"type":"integer"}},"alleMinuten":{"type":"integer"},"datum":{"type":"string"}}},\
        "ruhezustand":{"type":"boolean"},\
        "antwort":{"type":"string"}}}
        """
    }

    static func systemPrompt(draft: AgentDraft?, status: String, now: Date = Date()) -> String {
        let groups = AgentToolbox.groups.map { "- \($0.id): \($0.label)" }.joined(separator: "\n")
        return """
        Du hilfst der Person, in der App LLM Designer eine agentische Aufgabe zu planen. Ein kleines Sprachmodell führt sie später allein aus, Schritt für Schritt, jeder Schritt mit frischem Kopf.
        Regeln für den Plan:
        1. 1 bis 6 Schritte. Jeder Schritt ist eine klar begrenzte Arbeit.
        2. Der Auftrag eines Schritts sagt genau, was zu tun ist und was danach vorliegt, z. B. „Lege ein Dokument mit dem Titel X an und schreibe …“. Plane nur, was die Person verlangt: keine Schritte zum Aufräumen, Löschen oder Abschließen, die sie nicht genannt hat.
        3. Jeder Schritt bekommt nur die nötigen Werkzeuggruppen, höchstens zwei:
        \(groups)
        4. Zeitplan: art „manuell“, wenn die Person keine Zeit nennt. Beispiele: „jeden Freitag um 17 Uhr“ = woechentlich, wochentage [5], uhrzeit 17:00; „werktags 7:30“ = woechentlich, [1,2,3,4,5], 07:30; „täglich um 8“ = taeglich, 08:00; „alle 2 Stunden“ = intervall, alleMinuten 120. uhrzeit als HH:MM. wochentage 1 = Montag bis 7 = Sonntag. alleMinuten für „intervall“. datum als JJJJ-MM-TT nur für „einmalig“. Unbenutztes leer oder 0.
        5. ruhezustand: true nur, wenn die Person sagt, der Mac soll danach schlafen gehen.
        6. absicht: „entwurf“, wenn du einen Plan vorschlägst oder änderst; „pausieren“, „fortsetzen“ oder „abbrechen“, wenn die Person die laufenden Agenten anhalten, weiterlaufen lassen oder abbrechen will; sonst „keine“. Bei „keine“ übernimm den bisherigen Entwurf unverändert.
        7. antwort: ein bis drei Sätze an die Person, auf Deutsch. Fehlt etwas Wichtiges, frage danach.
        Heute ist \(now.formatted(date: .complete, time: .shortened)).
        Bisheriger Entwurf: \(draft.map(describe) ?? "keiner")
        Stand der Agenten: \(status)
        """
    }

    static func describe(_ draft: AgentDraft) -> String {
        var lines = ["„\(draft.title)“ – Ziel: \(draft.goal)", "Zeitplan: \(draft.schedule.summary)\(draft.sleepAfter ? ", danach Ruhezustand" : "")"]
        for (index, step) in draft.steps.enumerated() {
            lines.append("\(index + 1). \(step.title): \(step.instruction ?? step.action ?? "") [\((step.tools ?? []).joined(separator: ", "))]")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the model's JSON. A model that wrote text around it, or no JSON at all, still gets its words shown.
    static func parse(_ text: String, previous: AgentDraft?, now: Date = Date()) -> Reply {
        guard let object = StudioJSON.object(in: text) else {
            let plain = ThinkingSplitter.split(text).content.trimmingCharacters(in: .whitespacesAndNewlines)
            return Reply(text: plain.isEmpty ? "Ich habe keinen Plan bekommen. Beschreibe die Aufgabe bitte noch einmal." : plain, intent: .none, draft: previous)
        }
        let intent = (object["absicht"] as? String).flatMap(Intent.init(rawValue:)) ?? .none
        let answer = (object["antwort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard intent == .draft else {
            return Reply(text: answer.isEmpty ? "In Ordnung." : answer, intent: intent, draft: previous)
        }
        let known = Set(AgentToolbox.groups.map(\.id))
        let steps: [AgentStepDefinition] = ((object["schritte"] as? [[String: Any]]) ?? []).prefix(8).compactMap { entry in
            let title = (entry["titel"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let instruction = (entry["auftrag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || !instruction.isEmpty else { return nil }
            let tools = Array(((entry["werkzeuge"] as? [String]) ?? []).filter(known.contains).prefix(3))
            return AgentStepDefinition(kind: .agent, title: title.isEmpty ? "Schritt" : title, instruction: instruction, tools: tools)
        }
        var schedule = AgentSchedule()
        if let plan = object["zeitplan"] as? [String: Any] {
            schedule.kind = (plan["art"] as? String).flatMap(AgentSchedule.Kind.init(rawValue:)) ?? .manual
            if let time = plan["uhrzeit"] as? String, AgentSchedule.clock(time) != nil {
                let clock = AgentSchedule.clock(time)!
                schedule.time = String(format: "%02d:%02d", clock.hour, clock.minute)
            }
            if let days = plan["wochentage"] as? [Int] {
                let valid = days.filter { (1...7).contains($0) }
                if !valid.isEmpty { schedule.weekdays = Array(Set(valid)).sorted() }
            }
            if let minutes = plan["alleMinuten"] as? Int, minutes >= AgentSchedule.minimumInterval { schedule.intervalMinutes = minutes }
            if schedule.kind == .once {
                let day = (plan["datum"] as? String).flatMap(Self.day)
                if let day, let clock = schedule.clock {
                    schedule.date = Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day)
                }
                if schedule.date == nil { schedule.kind = .manual }
            }
        }
        let draft = AgentDraft(
            title: (object["titel"] as? String)?.trimmingCharacters(in: .whitespaces) ?? previous?.title ?? "Neue Aufgabe",
            goal: (object["ziel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? previous?.goal ?? "",
            steps: steps.isEmpty ? (previous?.steps ?? []) : steps,
            schedule: schedule,
            sleepAfter: object["ruhezustand"] as? Bool ?? false
        )
        return Reply(text: answer.isEmpty ? "Hier ist ein Entwurf." : answer, intent: .draft, draft: draft)
    }

    /// What the rules read from the person's own messages wins over the model's schedule; the newest message first.
    static func applyWords(_ draft: AgentDraft?, personTexts: [String], now: Date = Date()) -> AgentDraft? {
        guard var draft else { return nil }
        if let schedule = personTexts.reversed().lazy.compactMap({ AgentScheduleWords.parse($0, now: now) }).first {
            draft.schedule = schedule
        }
        if personTexts.contains(where: AgentScheduleWords.wantsSleep) { draft.sleepAfter = true }
        return draft
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
