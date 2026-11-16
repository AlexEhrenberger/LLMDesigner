import Foundation
import Testing
import LLMDProtocol
@testable import LLMDesigner

/// AgentSteps without the app: schedules, the parser for calls written as text, placeholders, the planner's JSON and
/// the file format.
@Suite("AgentSteps")
@MainActor
struct AgentStepsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    // MARK: Schedule

    @Test func dailyRunsOnceAtItsTimeAndNotForTimesBeforeItWasSet() {
        var schedule = AgentSchedule(kind: .daily)
        schedule.time = "07:30"
        schedule.since = date("2026-11-16 09:00")
        // Set after this morning's time: today doesn't count, tomorrow does.
        #expect(!schedule.isDue(now: date("2026-11-16 09:05"), lastStart: nil, calendar: calendar))
        #expect(schedule.nextSlot(after: date("2026-11-16 09:05"), calendar: calendar) == date("2026-11-17 07:30"))
        #expect(schedule.isDue(now: date("2026-11-17 07:30"), lastStart: nil, calendar: calendar))
        #expect(!schedule.isDue(now: date("2026-11-17 07:31"), lastStart: date("2026-11-17 07:30"), calendar: calendar), "schon gelaufen")
        // Missed while the Mac slept: made up once, or not at all without catch-up.
        #expect(schedule.isDue(now: date("2026-11-17 11:00"), lastStart: nil, calendar: calendar))
        schedule.catchUp = false
        #expect(!schedule.isDue(now: date("2026-11-17 11:00"), lastStart: nil, calendar: calendar))
        #expect(schedule.isDue(now: date("2026-11-17 07:31"), lastStart: nil, calendar: calendar), "innerhalb der Kulanz")
        schedule.isOn = false
        #expect(!schedule.isDue(now: date("2026-11-17 07:30"), lastStart: nil, calendar: calendar))
        #expect(schedule.nextSlot(after: date("2026-11-17 07:00"), calendar: calendar) == nil)
    }

    @Test func weeklyOnlyOnItsDays() {
        var schedule = AgentSchedule(kind: .weekly)
        schedule.time = "18:00"
        schedule.weekdays = [1, 3, 5]
        schedule.since = date("2026-11-01 00:00")
        // 2026-11-17 is a Tuesday.
        #expect(AgentSchedule.weekday(of: date("2026-11-17 12:00"), calendar: calendar) == 2)
        #expect(schedule.nextSlot(after: date("2026-11-17 12:00"), calendar: calendar) == date("2026-11-18 18:00"))
        #expect(schedule.previousSlot(atOrBefore: date("2026-11-17 12:00"), calendar: calendar) == date("2026-11-16 18:00"))
        #expect(schedule.summary == "Mo, Mi, Fr um 18:00")
        schedule.weekdays = [1, 2, 3, 4, 5]
        #expect(schedule.summary == "werktags um 18:00")
        schedule.weekdays = []
        #expect(schedule.problem != nil)
        #expect(schedule.nextSlot(after: date("2026-11-17 12:00"), calendar: calendar) == nil)
    }

    @Test func intervalAndOnce() {
        var schedule = AgentSchedule(kind: .interval)
        schedule.intervalMinutes = 90
        schedule.since = date("2026-11-16 08:00")
        #expect(!schedule.isDue(now: date("2026-11-16 09:00"), lastStart: nil, calendar: calendar), "erst nach dem ersten Abstand")
        #expect(schedule.isDue(now: date("2026-11-16 09:31"), lastStart: nil, calendar: calendar))
        #expect(schedule.nextSlot(after: date("2026-11-16 09:31"), calendar: calendar) == date("2026-11-16 11:00"))
        #expect(schedule.summary == "alle 90 Minuten")
        schedule.intervalMinutes = 120
        #expect(schedule.summary == "alle 2 Stunden")
        schedule.intervalMinutes = 2
        #expect(schedule.problem != nil)

        var once = AgentSchedule(kind: .once)
        once.since = date("2026-11-16 08:00")
        once.date = date("2026-11-16 22:00")
        #expect(!once.isDue(now: date("2026-11-16 21:00"), lastStart: nil, calendar: calendar))
        #expect(once.isDue(now: date("2026-11-17 07:00"), lastStart: nil, calendar: calendar), "verpasst, wird nachgeholt")
        #expect(!once.isDue(now: date("2026-11-17 07:00"), lastStart: date("2026-11-16 22:00"), calendar: calendar))
        once.date = date("2026-11-15 22:00")
        #expect(!once.isDue(now: date("2026-11-16 09:00"), lastStart: nil, calendar: calendar), "ein Zeitpunkt vor dem Einstellen war nie gemeint")
    }

    @Test func readsTheScheduleFromThePersonsWords() {
        let now = date("2026-11-17 12:00") // a Tuesday
        func parse(_ text: String) -> AgentSchedule? { AgentScheduleWords.parse(text, now: now, calendar: calendar) }
        let friday = parse("Jeden Freitag um 17 Uhr: Lies meine Notes und schreib einen Wochenrückblick.")
        #expect(friday?.kind == .weekly && friday?.weekdays == [5] && friday?.time == "17:00")
        let workdays = parse("Fasse mir werktags um 7:30 meine offenen ToDos zusammen")
        #expect(workdays?.kind == .weekly && workdays?.weekdays == [1, 2, 3, 4, 5] && workdays?.time == "07:30")
        #expect(parse("montags und donnerstags 18.15")?.weekdays == [1, 4])
        #expect(parse("am Wochenende um 9 Uhr")?.weekdays == [6, 7])
        let daily = parse("Jeden Morgen um 6:45 die Quellen prüfen")
        #expect(daily?.kind == .daily && daily?.time == "06:45")
        #expect(parse("täglich")?.time == "08:00")
        #expect(parse("alle 2 Stunden nach neuen Notes schauen")?.intervalMinutes == 120)
        #expect(parse("alle 15 Minuten")?.intervalMinutes == 15)
        #expect(parse("stündlich")?.intervalMinutes == 60)
        let tomorrow = parse("morgen um 9 den Bericht schreiben")
        #expect(tomorrow?.kind == .once && tomorrow?.date == date("2026-11-18 09:00"))
        #expect(parse("am 20.11. um 8 Uhr")?.date == date("2026-11-20 08:00"))
        #expect(parse("am Freitag um 17 Uhr")?.date == date("2026-11-20 17:00"))
        #expect(parse("Schreib einen Bericht über Statistik.") == nil)
        #expect(AgentScheduleWords.wantsSleep("und schick den Mac danach schlafen"))

        let draft = AgentDraft(title: "X", goal: "", steps: [], schedule: AgentSchedule(kind: .interval), sleepAfter: false)
        let fixed = AgentPlanner.applyWords(draft, personTexts: ["Jeden Freitag um 17 Uhr, danach Ruhezustand"], now: now)
        #expect(fixed?.schedule.kind == .weekly && fixed?.sleepAfter == true, "die Worte der Person gehen vor der Wahl des Modells")
        #expect(AgentPlanner.applyWords(draft, personTexts: ["Schreib einen Bericht."], now: now)?.schedule.kind == .interval)
    }

    // MARK: Calls written as text

    @Test func parsesQwensCallsFromText() {
        let json = """
        Ich lege das Dokument an.
        <tool_call>
        {"name": "writer_doc_create", "arguments": {"title": "Bericht", "markdown": "# Hallo"}}
        </tool_call>
        """
        let calls = AgentCallParser.calls(in: json)
        #expect(calls.count == 1)
        #expect(calls.first?.function.name == "writer_doc_create")
        #expect((try? JSONValue.parse(calls[0].function.arguments))?["title"] == "Bericht")

        let xml = """
        <tool_call>
        <function=notes_todo_add>
        <parameter=note>
        Einkauf
        </parameter>
        <parameter=position>
        2
        </parameter>
        </function>
        </tool_call>
        <tool_call><function=schritt_fertig><parameter=ergebnis>Fertig mit allem</parameter></function></tool_call>
        """
        let parsed = AgentCallParser.calls(in: xml)
        #expect(parsed.map(\.function.name) == ["notes_todo_add", "schritt_fertig"])
        let args = try? JSONValue.parse(parsed[0].function.arguments)
        #expect(args?["note"] == "Einkauf")
        #expect(args?["position"] == 2)
        #expect((try? JSONValue.parse(parsed[1].function.arguments))?["ergebnis"] == "Fertig mit allem")
        #expect(AgentCallParser.calls(in: "Nur Text, kein Aufruf.").isEmpty)
    }

    @Test func argumentsAreFittedToTheSchema() {
        let schema: JSONSchema = .object([
            "general": .boolean(), "position": .integer(), "share": .number(), "title": .string(), "tags": .array(of: .string()), "widths": .array(of: .number()),
        ], required: ["title"])
        let (args, dropped) = AgentArguments.coerce(["general": "true", "position": "3", "share": "0,5", "title": 2026, "tags": "Uni", "widths": "[2, 1]",
                                                     "erfunden": "x", "position2": .null], schema: schema)
        #expect(args["general"] == true)
        #expect(args["position"] == 3)
        #expect(args["share"] == .double(0.5))
        #expect(args["title"] == "2026")
        #expect(args["tags"] == ["Uni"])
        #expect(args["widths"] == [2, 1])
        #expect(dropped == ["erfunden", "position2"])
        #expect(AgentArguments.coerce(["general": "vielleicht"], schema: schema).args["general"] == "vielleicht", "Unklares bleibt, die Registry meldet es")
    }

    // MARK: Placeholders

    @Test func placeholdersTakeEarlierResults() {
        var first = AgentRunStep(definition: AgentStepDefinition(kind: .action, title: "Anlegen"))
        first.output = ["id": "ABC", "title": "Bericht", "count": 3]
        first.summary = "Dokument angelegt"
        let second = AgentRunStep(definition: AgentStepDefinition(kind: .action, title: "Schreiben"))
        let args: JSONValue = ["doc": "{{schritt1.id}}", "markdown": "Zu {{vorher.title}}: {{ziel}}", "n": "{{schritt1.count}}", "later": "{{schritt2.id}}"]
        let resolved = AgentPlaceholders.resolve(args, steps: [first, second], current: 1, goal: "Überblick")
        #expect(resolved["doc"] == "ABC")
        #expect(resolved["markdown"] == "Zu Bericht: Überblick")
        #expect(resolved["n"] == 3, "ein reiner Platzhalter behält den Typ")
        #expect(resolved["later"] == "{{schritt2.id}}", "spätere Schritte gibt es noch nicht")
        #expect(AgentPlaceholders.smallValues(of: ["id": "x", "markdown": .string(String(repeating: "a", count: 500)), "list": [1]]) == ["id": "x"])
    }

    // MARK: Planner

    @Test func plannerReadsTheDraftAndKeepsItForOtherIntents() {
        let raw = """
        {"absicht":"entwurf","titel":"Morgenbericht","ziel":"Überblick über offene ToDos",
         "schritte":[{"titel":"ToDos sammeln","auftrag":"Lies alle Notes und liste offene ToDos.","werkzeuge":["notes.core","gibtsnicht"]},
                     {"titel":"Bericht schreiben","auftrag":"Lege ein Dokument an.","werkzeuge":["writer.core"]}],
         "zeitplan":{"art":"woechentlich","uhrzeit":"7:30","wochentage":[1,2,3,4,5,9],"alleMinuten":0,"datum":""},
         "ruhezustand":true,"antwort":"So könnte es gehen."}
        """
        let reply = AgentPlanner.parse(raw, previous: nil)
        #expect(reply.intent == .draft)
        let draft = try! #require(reply.draft)
        #expect(draft.title == "Morgenbericht")
        #expect(draft.steps.count == 2)
        #expect(draft.steps[0].tools == ["notes.core"], "unbekannte Gruppen fallen weg")
        #expect(draft.schedule.kind == .weekly)
        #expect(draft.schedule.time == "07:30")
        #expect(draft.schedule.weekdays == [1, 2, 3, 4, 5])
        #expect(draft.sleepAfter)
        let task = draft.task()
        #expect(task.options.sleepAfter && task.origin == .own)

        let pause = AgentPlanner.parse(#"{"absicht":"pausieren","titel":"","ziel":"","schritte":[],"zeitplan":{"art":"manuell","uhrzeit":"","wochentage":[],"alleMinuten":0,"datum":""},"ruhezustand":false,"antwort":"Halte an."}"#, previous: draft)
        #expect(pause.intent == .pause)
        #expect(pause.draft == draft)
        let prose = AgentPlanner.parse("Das weiß ich nicht.", previous: draft)
        #expect(prose.intent == .none && prose.text == "Das weiß ich nicht.")
        #expect(AgentPlanner.schemaJSON.contains("\"web\""), "die Websuche ist eine wählbare Gruppe")
        #expect((try? JSONValue.parse(AgentPlanner.schemaJSON)) != nil, "das Schema ist gültiges JSON")
    }

    // MARK: Format

    @Test func filesUseTheAgreedGermanKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentFormat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecordStore<AgentTask>(directory: folder, root: "aufgabe")
        var task = AgentTask(title: "Morgenbericht", goal: "Überblick", steps: [
            AgentStepDefinition(kind: .agent, title: "Sammeln", instruction: "Lies die Notes.", tools: ["notes.core"]),
            AgentStepDefinition(kind: .action, title: "Anlegen", action: "writer.doc.create", arguments: ["title": "Bericht {{heute}}"]),
        ])
        task.schedule.kind = .daily
        task.schedule.time = "07:30"
        task.options.sleepAfter = true
        try store.save(task)
        let text = try String(contentsOf: store.recordURL(for: task.id), encoding: .utf8)
        for key in ["\"aufgabe\"", "\"titel\"", "\"ziel\"", "\"schritte\"", "\"art\" : \"agent\"", "\"auftrag\"", "\"werkzeuge\"", "\"parameter\"",
                    "\"zeitplan\"", "\"uhrzeit\" : \"07:30\"", "\"danachRuhezustand\" : true", "\"herkunft\" : \"eigen\""] {
            #expect(text.contains(key), "\(key) fehlt")
        }
        let loaded = try #require(store.loadAll().first)
        // Dates keep whole seconds in the file; everything else comes back as it was.
        #expect(try store.encode(loaded) == store.encode(task))

        var run = AgentRun(task: task, trigger: .schedule)
        run.append(.git, "Branch angelegt")
        let runs = RecordStore<AgentRun>(directory: folder.appendingPathComponent("Protokolle"), root: "lauf")
        try runs.save(run)
        let runText = try String(contentsOf: runs.recordURL(for: run.id), encoding: .utf8)
        for key in ["\"lauf\"", "\"zustand\" : \"wartet\"", "\"anlass\" : \"zeitplan\"", "\"protokoll\"", "\"plan\""] {
            #expect(runText.contains(key), "\(key) fehlt")
        }
        #expect(try runs.encode(#require(runs.loadAll().first)) == runs.encode(run))
        #expect(GitSetup.ignoreFileContent.contains("/\(AgentCenter.runsPath)/"))
        #expect(LibraryItemResolver.place(of: "AgentSteps/Aufgaben/\(task.id.uuidString).json").kind == .agentTask)
    }

    @Test func branchNamesAreSafe() {
        var run = AgentRun(task: AgentTask(title: "Größte Übersicht: ÄÖÜ & Co. / 2026"), trigger: .person)
        run.id = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!
        let name = AppModel.agentBranchName(run)
        #expect(name.hasPrefix("agent/gro") && name.hasSuffix("-co-2026-1a2b3c4d"), "\(name)")
        #expect(AppModel.agentBranchName(run).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-/".contains($0)) })
        run.title = "???"
        #expect(AppModel.agentBranchName(run) == "agent/lauf-1a2b3c4d")
    }

    @Test func historyGivesWayToTheBudget() {
        var messages = [
            ChatPayloadMessage(role: "system", content: "Regeln"),
            ChatPayloadMessage(role: "user", content: "Auftrag"),
            ChatPayloadMessage(role: "tool", content: String(repeating: "a", count: 5_000)),
            ChatPayloadMessage(role: "tool", content: String(repeating: "b", count: 5_000)),
        ]
        AppModel.trimAgentHistory(&messages, budget: 6_000)
        #expect(messages[2].content.hasPrefix("[Älteres"))
        #expect(messages[3].content.count == 5_000, "das neueste Ergebnis bleibt")
        #expect(messages[1].content == "Auftrag")
    }
}
