import Foundation
import Testing
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
    /// AgentSteps through the registry on the shared test library: runs with Git branches, model steps against
    /// `FakeLLMServer`, the question inbox, pausing for the person's chat, undo, the schedule and sleeping after.
    @Suite("AgentSteps-Actions")
    @MainActor
    struct AgentActionTests {
        let h = ActionHarness()

        private var center: AgentCenter { h.app.agents }

        /// The runner works through the harness's registry, and nothing of an earlier test is in the queue.
        private func prepare() {
            h.app.actionRegistryOverride = h.registry
            center.isHalted = false
            center.personUsesModelOverride = nil
            center.sleeper = { Issue.record("Der Mac darf in diesem Test nicht schlafen.") }
            center.notify = { _, _ in }
        }

        private func finish() {
            h.app.actionRegistryOverride = nil
            center.personUsesModelOverride = nil
            center.cancelSleep()
        }

        private func cleanGit() async throws -> LibraryGit {
            let git = h.app.git
            git.environment = GitTestSupport.environment
            if !git.isEnabled { try await h.call("git.enable") }
            h.app.saveEverythingForGit()
            await git.refresh()
            if !git.changes.isEmpty { try await h.call("git.commit", ["message": "Vorher"]) }
            return git
        }

        @discardableResult
        private func waitFor(_ id: UUID, timeout: TimeInterval = 30, _ condition: (AgentRun) -> Bool) async throws -> AgentRun {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let run = center.run(id), condition(run) { return run }
                try await Task.sleep(for: .milliseconds(40))
            }
            let run = center.run(id)
            Issue.record("Der Lauf kam nicht an: \(run?.state.rawValue ?? "weg") – \(run?.log.suffix(8).map(\.text).joined(separator: " | ") ?? "")")
            throw CancellationError()
        }

        private func waitUntilIdle() async throws {
            let deadline = Date().addingTimeInterval(30)
            while center.activeRunID != nil || !center.queued.isEmpty {
                guard Date() < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(40))
            }
        }

        private func withServer(_ script: [FakeLLMServer.Turn] = [], _ body: (FakeLLMServer) async throws -> Void) async throws {
            let server = try FakeLLMServer(script: script)
            let old = h.app.endpoint
            h.app.endpoint = server.endpoint
            await h.app.refreshModels()
            defer {
                h.app.endpoint = old
                server.stop()
            }
            try await body(server)
        }

        private func createTask(_ title: String, steps: [JSONValue], extra: [String: JSONValue] = [:]) async throws -> String {
            var args: [String: JSONValue] = ["title": .string(title), "goal": "Ein neutraler Test", "steps": .array(steps)]
            args.merge(extra) { _, new in new }
            let result = try await h.call("agents.task.create", .object(args))
            return try #require(result["id"]?.stringValue)
        }

        private func start(_ task: String) async throws -> UUID {
            let run = try await h.call("agents.run.start", ["task": .string(task)])
            return try #require(run["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        }

        // MARK: Runs

        @Test func actionStepsRunOnTheirOwnBranchCommitPerStepAndComeBack() async throws {
            prepare()
            defer { finish() }
            let git = try await cleanGit()
            let base = try #require(git.branch)
            let title = "Agentenbericht \(UUID().uuidString.prefix(6))"
            let task = try await createTask("Bericht bauen", steps: [
                ["kind": "action", "title": "Dokument anlegen", "action": "writer.doc.create", "arguments": ["title": .string(title), "markdown": "# Start"]],
                ["kind": "action", "title": "Weiterschreiben", "action": "writer.text.insertMarkdown", "arguments": ["doc": "{{schritt1.id}}", "markdown": "Zweiter Absatz zu {{ziel}}"]],
            ])
            let id = try await start(task)
            let run = try await waitFor(id) { $0.state.isOver }
            #expect(run.state == .finished, "\(run.error ?? "")")
            #expect(run.steps.allSatisfy { $0.state == .done })
            let doc = try #require(run.steps[0].output?["id"]?.stringValue)
            #expect(h.text(doc).contains("Zweiter Absatz zu Ein neutraler Test"), "der Platzhalter nimmt die ID aus Schritt 1")
            #expect(run.results.contains { $0.id == doc && $0.kind == "writer" })

            // Git: a branch of its own, one commit per step with trailers, merged back, the library on its branch again.
            let branch = try #require(run.branch)
            #expect(branch.hasPrefix("agent/bericht-bauen-"))
            #expect(run.baseBranch == base)
            #expect(git.branch == base)
            #expect(run.commits.count == 2)
            let merge = try #require(run.mergeCommit)
            let head = try #require(try await git.log(limit: 1).first)
            #expect(head.id == merge && head.isMerge)
            #expect(head.trailer("Lauf") == run.id.uuidString)
            let steps = try await git.log(limit: 6, revision: branch)
            #expect(steps.contains { $0.trailer("Schritt") == "2/2" && $0.trailer("Auftrag")?.contains(run.shortID) == true })
            #expect(steps.first?.author == "AgentSteps")
            let ignore = try String(contentsOf: git.root.appendingPathComponent(".gitignore"), encoding: .utf8)
            #expect(ignore.contains("/AgentSteps/Protokolle/"))
            #expect(git.changes.isEmpty, "das Protokoll des Laufs liegt außerhalb von Git")

            // Taking the run back: one commit that does the opposite, the document's file is gone.
            let file = git.root.appendingPathComponent("Documents/\(doc).md")
            #expect(FileManager.default.fileExists(atPath: file.path))
            let undone = try await h.call("agents.run.undo", ["id": .string(id.uuidString)])
            #expect(undone["state"] == "zurueckgenommen")
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(await h.errorCode("agents.run.undo", ["id": .string(id.uuidString)]) == RPCError.invalidTargetCode, "zweimal geht nicht")
            #expect(git.branch == base)
        }

        @Test func aModelStepUsesToolsAndEndsWithItsResult() async throws {
            prepare()
            defer { finish() }
            let title = "KI-Notiz \(UUID().uuidString.prefix(6))"
            try await withServer([
                .tools([("writer_doc_create", #"{"title":"\#(title)","markdown":"Hallo"}"#)]),
                .tools([("schritt_fertig", #"{"ergebnis":"Dokument \#(title) angelegt"}"#)]),
            ]) { server in
                let task = try await createTask("KI schreibt", steps: [
                    ["kind": "agent", "title": "Notiz anlegen", "instruction": "Lege eine Notiz an.", "tools": ["writer.core"]],
                ], extra: ["branch": false])
                let id = try await start(task)
                let run = try await waitFor(id) { $0.state.isOver }
                #expect(run.state == .finished, "\(run.error ?? "")")
                #expect(run.steps[0].summary == "Dokument \(title) angelegt")
                #expect(run.steps[0].calls.map(\.action) == ["writer.doc.create"])
                #expect(run.results.contains { $0.title == title })
                #expect(run.branch == nil)
                #expect(h.app.documents.contains { $0.title == title })

                let request = try #require(server.requests.first)
                let tools = request["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue } ?? []
                #expect(tools.contains("schritt_fertig") && tools.contains("writer_doc_create"))
                #expect(!tools.contains { $0.hasPrefix("agents_") }, "Agenten bekommen keine Agenten-Werkzeuge")
                let user = request["messages"]?.arrayValue?.first { $0["role"] == "user" }?["content"]?.stringValue ?? ""
                #expect(user.contains("Dein Schritt (1 von 1): Notiz anlegen"))
                #expect(user.contains("Auftrag: Ein neutraler Test"))
                #expect(request["temperature"] == .double(0.2))
            }
        }

        @Test func callsWrittenAsTextRunAndProseEndsTheStepAfterOneReminder() async throws {
            prepare()
            defer { finish() }
            let title = "Leck \(UUID().uuidString.prefix(6))"
            try await withServer([
                .text("Ich lege es an.\n<tool_call>\n{\"name\": \"writer_doc_create\", \"arguments\": {\"title\": \"\(title)\"}}\n</tool_call>"),
                .text("Erledigt."),
            ]) { server in
                server.fallback = "Alles erledigt: das Dokument steht."
                let task = try await createTask("Leckt", steps: [
                    ["kind": "agent", "title": "Anlegen", "instruction": "Lege ein Dokument an.", "tools": ["writer.core"]],
                ], extra: ["branch": false])
                let run = try await waitFor(try await start(task)) { $0.state.isOver }
                #expect(run.state == .finished)
                #expect(h.app.documents.contains { $0.title == title }, "der Aufruf aus dem Text lief")
                #expect(run.steps[0].summary == "Alles erledigt: das Dokument steht.")
                #expect(run.steps[0].rounds == 3, "einmal erinnert, dann zählt der Text")
            }
        }

        /// Found on 2026-11-15 with the real Qwen 3.5 9B: the findings stood in the model's text, `schritt_fertig` only
        /// had a count, and the next step wrote "ToDo 1, ToDo 2".
        @Test func theNextStepGetsTheFindingsNotOnlyTheirCount() async throws {
            prepare()
            defer { finish() }
            try await withServer([
                .text("Offen sind Brot, Äpfel und Statistik Übung 3 – das sind alle offenen ToDos aus beiden Notes.\n<tool_call>{\"name\": \"schritt_fertig\", \"arguments\": {\"ergebnis\": \"3 offene ToDos gefunden\"}}</tool_call>"),
                .tools([("schritt_fertig", #"{"ergebnis":"Bericht steht"}"#)]),
            ]) { server in
                let task = try await createTask("Übergabe", steps: [
                    ["kind": "agent", "title": "Sammeln", "instruction": "Sammle die offenen ToDos.", "tools": ["notes.core"]],
                    ["kind": "agent", "title": "Schreiben", "instruction": "Schreibe sie auf.", "tools": ["writer.core"]],
                ], extra: ["branch": false])
                let run = try await waitFor(try await start(task)) { $0.state.isOver }
                #expect(run.state == .finished)
                #expect(run.steps[0].summary?.contains("Statistik Übung 3") == true)
                let second = try #require(server.requests.last)
                let user = second["messages"]?.arrayValue?.first { $0["role"] == "user" }?["content"]?.stringValue ?? ""
                #expect(user.contains("Brot, Äpfel und Statistik Übung 3"), "der zweite Schritt kennt die Dinge selbst")
            }
            #expect(AppModel.agentHandOver(result: "Dokument „Bericht“ angelegt (ID 1)", notes: "Fertig.") == "Dokument „Bericht“ angelegt (ID 1)")
            #expect(AppModel.agentHandOver(result: "", notes: "") == "Schritt beendet.")
            let listed = "Offene ToDos:\n- Einkauf: Brot, Äpfel\n- Uni: Statistik Übung 3"
            #expect(AppModel.agentHandOver(result: listed, notes: String(repeating: "Ich denke laut nach. ", count: 20)) == listed, "eine Liste reicht")
        }

        @Test func aQuestionWaitsInTheInboxAndOnlyThatRunWaits() async throws {
            prepare()
            defer { finish() }
            let doc = try await h.document("Wird gelöscht.")
            let task = try await createTask("Aufräumen", steps: [
                ["kind": "action", "title": "Löschen", "action": "writer.doc.delete", "arguments": ["doc": .string(doc)]],
            ], extra: ["branch": false])
            let id = try await start(task)
            let asking = try await waitFor(id) { $0.state == .asking }
            #expect(asking.question?.action == "writer.doc.delete")
            #expect(asking.question?.reason.isEmpty == false)
            let list = try await h.call("agents.approvals.list")
            #expect(list["questions"]?.arrayValue?.contains { $0["run"]?.stringValue == id.uuidString } == true)
            // Nothing but the interface answers: there is no action for it, and the app stays usable meanwhile.
            #expect(!h.registry.descriptors.contains { $0.module == "agents" && ($0.id.contains("answer") || $0.id.contains("approve")) })
            #expect(try await h.call("writer.doc.list")["documents"] != nil)
            center.answer(id, allow: true)
            let run = try await waitFor(id) { $0.state.isOver }
            #expect(run.state == .finished)
            #expect(h.app.document(UUID(uuidString: doc)!) == nil)
        }

        @Test func aDeniedQuestionFailsTheStep() async throws {
            prepare()
            defer { finish() }
            let doc = try await h.document("Bleibt.")
            let task = try await createTask("Nicht löschen", steps: [
                ["kind": "action", "title": "Löschen", "action": "writer.doc.delete", "arguments": ["doc": .string(doc)]],
            ], extra: ["branch": false])
            let id = try await start(task)
            _ = try await waitFor(id) { $0.state == .asking }
            center.answer(id, allow: false)
            let run = try await waitFor(id) { $0.state.isOver }
            #expect(run.state == .failed)
            #expect(run.steps[0].calls.first?.ok == false)
            #expect(h.app.document(UUID(uuidString: doc)!) != nil)
        }

        @Test func theRunWaitsWhileThePersonUsesTheModel() async throws {
            prepare()
            defer { finish() }
            try await withServer([.tools([("schritt_fertig", #"{"ergebnis":"Nichts zu tun."}"#)])]) { server in
                center.personUsesModelOverride = true
                let task = try await createTask("Geduldig", steps: [
                    ["kind": "agent", "title": "Warten", "instruction": "Beende den Schritt.", "tools": ["notes.core"]],
                ], extra: ["branch": false])
                let id = try await start(task)
                _ = try await waitFor(id) { _ in center.yielding.contains(id) }
                try await Task.sleep(for: .milliseconds(400))
                #expect(server.requests.isEmpty, "solange die Person chattet, fragt der Agent das Modell nicht")
                #expect(center.run(id)?.log.contains { $0.text.hasPrefix("Pausiert") } == true)
                center.personUsesModelOverride = false
                let run = try await waitFor(id) { $0.state.isOver }
                #expect(run.state == .finished)
                #expect(run.log.contains { $0.text.hasPrefix("Weiter") })
                #expect(server.requests.count == 1)
            }
        }

        @Test func sleepsAfterARunOnlyWhenNoOneIsThere() async throws {
            prepare()
            defer { finish() }
            var slept = 0
            center.sleeper = { slept += 1 }
            center.sleepDelay = .milliseconds(200)
            defer { center.sleepDelay = .seconds(60); center.idleSeconds = { MacSleep.idleSeconds() } }
            let task = try await createTask("Und dann schlafen", steps: [
                ["kind": "action", "title": "Lesen", "action": "writer.doc.list"],
            ], extra: ["branch": false, "sleepAfter": true])

            center.idleSeconds = { 0 }
            let first = try await waitFor(try await start(task)) { $0.state.isOver }
            #expect(first.state == .finished)
            try await Task.sleep(for: .milliseconds(500))
            #expect(slept == 0, "jemand arbeitet am Mac")
            #expect(center.run(first.id)?.log.contains { $0.text.contains("Jemand arbeitet") } == true)

            center.idleSeconds = { 600 }
            _ = try await waitFor(try await start(task)) { $0.state.isOver }
            try await Task.sleep(for: .milliseconds(500))
            #expect(slept == 1)
        }

        @Test func theScheduleStartsADueTaskOnce() async throws {
            prepare()
            defer { finish() }
            let task = try await createTask("Geplant \(UUID().uuidString.prefix(4))", steps: [
                ["kind": "action", "title": "Lesen", "action": "writer.doc.list"],
            ], extra: ["branch": false, "schedule": ["kind": "intervall", "everyMinutes": 30]])
            let taskID = UUID(uuidString: task)!
            #expect(center.nextRun(of: center.task(taskID)!) != nil)
            let later = Date().addingTimeInterval(31 * 60)
            h.app.tickAgentSchedules(now: later)
            try await waitUntilIdle()
            let runs = center.runs(of: taskID)
            #expect(runs.count == 1)
            #expect(runs.first?.trigger == .schedule)
            #expect(runs.first?.state == .finished)
            h.app.tickAgentSchedules(now: later.addingTimeInterval(60))
            #expect(center.runs(of: taskID).count == 1, "dieselbe Zeit startet nicht zweimal")
            try await h.call("agents.schedule.set", ["task": .string(task), "schedule": ["kind": "manuell"]])
        }

        @Test func anInterruptedRunGoesOnFromItsFirstOpenStep() async throws {
            prepare()
            defer { finish() }
            let task = try await createTask("Unterbrochen", steps: [
                ["kind": "action", "title": "Eins", "action": "writer.doc.list"],
                ["kind": "action", "title": "Zwei", "action": "writer.doc.list"],
            ], extra: ["branch": false])
            var run = AgentRun(task: center.task(UUID(uuidString: task)!)!, trigger: .person)
            run.state = .running
            run.startedAt = Date()
            run.steps[0].state = .done
            run.steps[0].summary = "schon erledigt"
            run.steps[1].state = .running
            center.runs.add(run)
            center.recoverAfterLaunch()
            #expect(center.run(run.id)?.state == .interrupted)
            #expect(center.run(run.id)?.steps[1].state == .pending)
            try await h.call("agents.run.resume", ["id": .string(run.id.uuidString)])
            let done = try await waitFor(run.id) { $0.state.isOver }
            #expect(done.state == .finished)
            #expect(done.steps[0].summary == "schon erledigt", "der erledigte Schritt lief nicht noch einmal")
            #expect(done.steps[1].state == .done)
        }

        // MARK: The catalog of actions

        @Test func everyAgentsActionThroughTheRegistry() async throws {
            prepare()
            defer { finish() }
            let catalog = try await h.call("agents.catalog")
            #expect(catalog["groups"]?.arrayValue?.contains { $0["id"] == "web" } == true)
            #expect(catalog["groups"]?.arrayValue?.contains { $0["id"] == "chat.private" } == false, "private Daten sind kein Werkzeug für Agenten")

            let task = try await createTask("Baukasten \(UUID().uuidString.prefix(4))", steps: [
                ["kind": "agent", "title": "Lesen", "instruction": "Lies die Dokumente.", "tools": ["writer.core"]],
            ])
            #expect(await h.errorCode("agents.task.create", ["title": "X", "steps": [["kind": "action", "title": "?", "action": "gibt.es.nicht"]]]) == RPCError.invalidParamsCode)
            #expect(await h.errorCode("agents.task.create", ["title": "X", "steps": [["kind": "agent", "title": "?", "tools": ["zauberei"]]]]) == RPCError.invalidParamsCode)

            try await h.call("agents.step.add", ["task": .string(task), "step": ["kind": "action", "title": "Liste", "action": "writer.doc.list"], "position": 1])
            var read = try await h.call("agents.task.read", ["task": .string(task)])
            #expect(read["task"]?["schritte"]?.arrayValue?.first?["titel"] == "Liste")
            try await h.call("agents.step.move", ["task": .string(task), "step": "Liste", "to": 2])
            read = try await h.call("agents.task.read", ["task": .string(task)])
            #expect(read["task"]?["schritte"]?.arrayValue?.map { $0["titel"]?.stringValue ?? "" } == ["Lesen", "Liste"])
            try await h.call("agents.step.remove", ["task": .string(task), "step": "2"])
            try await h.call("agents.task.update", ["task": .string(task), "goal": "Neues Ziel", "sleepAfter": true])
            read = try await h.call("agents.task.read", ["task": .string(task)])
            #expect(read["task"]?["ziel"] == "Neues Ziel")
            #expect(read["summary"]?["sleepAfter"] == true)
            #expect(read["summary"]?["steps"] == 1)

            let scheduled = try await h.call("agents.schedule.set", ["task": .string(task), "schedule": ["kind": "woechentlich", "time": "06:45", "weekdays": [6, 7]]])
            #expect(scheduled["schedule"] == "am Wochenende um 06:45")
            #expect(scheduled["nextRun"] != nil)
            #expect(await h.errorCode("agents.schedule.set", ["task": .string(task), "schedule": ["kind": "taeglich", "time": "25:00"]]) == RPCError.invalidParamsCode)
            let list = try await h.call("agents.task.list")
            #expect(list["tasks"]?.arrayValue?.contains { $0["id"]?.stringValue == task } == true)

            // Halted: a run waits in the queue, can be paused, resumed and cancelled there.
            try await h.call("agents.halt", ["halted": true])
            let started = try await h.call("agents.run.start", ["task": .string(task)])
            let run = try #require(started["id"]?.stringValue)
            #expect(started["state"] == "wartet")
            #expect(await h.errorCode("agents.run.start", ["task": .string(task)]) == RPCError.invalidTargetCode, "eine Aufgabe läuft nur einmal zugleich")
            var status = try await h.call("agents.status")
            #expect(status["halted"] == true)
            #expect(status["queued"]?.arrayValue?.contains { $0["id"]?.stringValue == run } == true)
            #expect(try await h.call("agents.run.pause", ["id": .string(run)])["state"] == "pausiert")
            #expect(try await h.call("agents.run.resume", ["id": .string(run)])["state"] == "wartet")
            #expect(try await h.call("agents.run.cancel", ["id": .string(run)])["state"] == "abgebrochen")
            try await h.call("agents.halt", ["halted": false])
            status = try await h.call("agents.status")
            #expect(status["halted"] == false)
            let runs = try await h.call("agents.run.list", ["task": .string(task)])
            #expect(runs["runs"]?.arrayValue?.first?["id"]?.stringValue == run)
            let detail = try await h.call("agents.run.read", ["id": .string(String(run.prefix(8)).lowercased())])
            #expect(detail["run"]?["id"]?.stringValue == run)
            #expect(detail["log"]?.arrayValue?.isEmpty == false)

            try await withServer() { server in
                server.completions = [#"{"absicht":"entwurf","titel":"Wochenrückblick","ziel":"Was diese Woche geschah","schritte":[{"titel":"Sammeln","auftrag":"Lies die Notes.","werkzeuge":["notes.core"]}],"zeitplan":{"art":"woechentlich","uhrzeit":"17:00","wochentage":[5],"alleMinuten":0,"datum":""},"ruhezustand":false,"antwort":"Ein Schritt reicht."}"#]
                let plan = try await h.call("agents.plan", ["description": "Jeden Freitag um 17 Uhr einen Wochenrückblick aus meinen Notes"])
                #expect(plan["draft"]?["title"] == "Wochenrückblick")
                #expect(plan["draft"]?["schedule"] == "Fr um 17:00")
                let sent = try #require(server.rawCompletions.last)
                #expect(sent.contains("json_schema") && sent.contains("agentenaufgabe"))
            }

            try await h.call("agents.task.delete", ["task": .string(task)])
            #expect(center.task(UUID(uuidString: task)!) == nil)
        }

        @Test func agentsDontRunAgentsAndStrangersOnlyWriteForeignTasks() async throws {
            prepare()
            defer { finish() }
            let task = try await createTask("Geschützt \(UUID().uuidString.prefix(4))", steps: [["kind": "action", "title": "Lesen", "action": "writer.doc.list"]])
            for id in ["agents.run.start", "agents.task.delete", "agents.halt"] {
                let args: JSONValue = id == "agents.halt" ? ["halted": true] : ["task": .string(task)]
                #expect(await h.errorCode(id, args, channel: .agent) == RPCError.deniedCode, "\(id) über einen Agenten")
            }
            #expect(await h.errorCode("agents.task.create", ["title": "Rekursion"], channel: .agent) == RPCError.deniedCode)
            // A chat may write a task, but not raise what it may do; it becomes foreign and asks before every change.
            #expect(await h.errorCode("agents.task.create", ["title": "Frech", "approval": "allowAll"], channel: .chat) == RPCError.deniedCode)
            let foreign = try await h.call("agents.task.create", ["title": .string("Vom Chat \(UUID().uuidString.prefix(4))")], channel: .chat)
            #expect(foreign["origin"] == "fremd")
            let stored = try #require(center.task(UUID(uuidString: foreign["id"]!.stringValue!)!))
            #expect(stored.options.approval == ChatToolApproval.ask)
            // Starting from a chat needs the person's yes; with no one to say it, no run starts.
            h.registry.approval.presenter = { _ in false }
            #expect(await h.errorCode("agents.run.start", ["task": .string(task)], channel: .chat) == RPCError.deniedCode)
            h.registry.approval.presenter = { _ in true }
            #expect(!center.isActive(UUID(uuidString: task)!))
            try await h.call("agents.task.delete", ["task": .string(task)])
            try await h.call("agents.task.delete", ["task": .string(stored.id.uuidString)])
        }
    }
}
