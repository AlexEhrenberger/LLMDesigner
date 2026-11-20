import Testing
import Foundation
import PDFKit
import LLMDProtocol
@testable import LLMDesigner

private extension JSONValue {
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

extension ActionSuites {
/// Every finance action through the registry. The account is shared by the whole test run, so each test makes
/// counterparties of its own and compares what changed, not totals.
@MainActor
@Suite("FinanceStudio: Actions", .serialized)
struct FinanceActionTests {
    let h = ActionHarness()

    private func unique(_ name: String) -> String { "\(name) \(UUID().uuidString.prefix(6))" }

    private func booking(_ counterparty: String) -> FinanceTransaction? {
        h.app.finance.bookings.first { $0.counterparty == counterparty }
    }

    /// Balances only follow new bookings of today when the known balance lies before them.
    private func anchorInThePast() async throws {
        try await h.call("finance.balance.set", ["amount": 0, "date": "2000-01-01"])
    }

    @Test func bookingsAreAddedListedChangedAndDeleted() async throws {
        try await anchorInThePast()
        let before = try await h.call("finance.overview")["balance"]?.number ?? 0
        let name = unique("Bäckerei Beispiel")
        let made = try await h.call("finance.transaction.add", ["amount": .double(-4.8), "counterparty": .string(name), "purpose": "Brötchen", "category": "restaurants"])
        let id = try #require(made["id"]?.stringValue)
        #expect(made["amount"]?.number == -4.8)
        #expect(made["category"] == "restaurants")
        #expect(made["categorySource"] == "buchung")
        let after = try await h.call("finance.overview")["balance"]?.number ?? 0
        #expect(abs(after - before + 4.8) < 0.001)

        let listed = try await h.call("finance.transaction.list", ["period": "alles", "query": .string(name)])
        #expect(listed["total"] == 1)
        #expect(listed["transactions"]?.arrayValue?.first?["id"]?.stringValue == id)
        #expect(listed["totals"]?["expenses"]?.number == -4.8)
        let expenses = try await h.call("finance.transaction.list", ["direction": "einnahmen", "query": .string(name)])
        #expect(expenses["total"] == 0)

        try await h.call("finance.transaction.update", ["id": .string(String(id.prefix(8))), "amount": .double(-5.2), "note": "mit Kaffee"])
        #expect(booking(name)?.cents == -520)
        #expect(booking(name)?.note == "mit Kaffee")
        try await h.call("writer.edit.undo")
        #expect(booking(name)?.cents == -480)
        #expect(await h.errorCode("finance.transaction.update", ["id": .string(id), "category": "gehalt"]) == RPCError.invalidParamsCode, "eine Ausgabe ist kein Gehalt")
        try await h.call("finance.transaction.update", ["id": .string(id), "category": ""])
        #expect(booking(name)?.category == nil)

        try await h.call("finance.transaction.delete", ["ids": [.string(id)]])
        #expect(booking(name) == nil)
        try await h.call("writer.edit.undo")
        #expect(booking(name) != nil)
        #expect(await h.errorCode("finance.transaction.add", ["amount": 0]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("finance.transaction.add", ["amount": -1, "date": "32.13.2026"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("finance.transaction.update", ["id": "kein-solcher-eintrag"]) == RPCError.notFoundCode)
    }

    @Test func theBalanceIsSetAndTheAccountChanged() async throws {
        let set = try await h.call("finance.balance.set", ["amount": .double(1234.56), "date": "heute"])
        #expect(set["balance"]?.number == 1234.56)
        let overview = try await h.call("finance.overview", ["period": "monat"])
        #expect(overview["balance"]?.number == 1234.56)
        #expect(overview["balanceSetOn"]?.stringValue == FinanceDay.today.iso)
        try await h.call("writer.edit.undo")
        #expect(h.app.finance.state.account.anchor?.day != FinanceDay.today || h.app.finance.state.account.anchor?.cents != 123_456)

        let name = h.app.finance.state.account.name
        try await h.call("finance.account.update", ["name": "Testgiro", "iban": "de00 1234 5678 0000 0000 00", "bank": "Beispielbank"])
        #expect(h.app.finance.state.account.iban == "DE00123456780000000000")
        let masked = try await h.call("finance.overview")
        #expect(masked["account"]?["iban"]?.stringValue == "DE00 •••• 0000", "die IBAN nur gekürzt")
        #expect(await h.errorCode("finance.account.update", ["currency": "Euro"]) == RPCError.invalidParamsCode)
        try await h.call("finance.account.update", ["name": .string(name)])
    }

    @Test func aCSVExportIsImportedOnceAndTakenBackWithUndo() async throws {
        let shop = unique("Beispiel Markt")
        let csv = """
        Buchungstag;Verwendungszweck;Beguenstigter/Zahlungspflichtiger;Betrag;Saldo
        02.11.2026;Einkauf;\(shop);-12,34;
        03.11.2026;Einkauf;\(shop);-7,66;
        """
        let first = try await h.call("finance.import.csv", ["text": .string(csv), "useBalance": false])
        #expect(first["added"] == 2)
        #expect(first["columns"]?["betrag"] == "Betrag")
        #expect(first["from"] == "2026-11-02")
        let again = try await h.call("finance.import.csv", ["text": .string(csv), "useBalance": false])
        #expect(again["added"] == 0)
        #expect(again["duplicates"] == 2)
        #expect(h.app.finance.bookings.filter { $0.counterparty == shop }.count == 2)
        try await h.call("writer.edit.undo")
        try await h.call("writer.edit.undo")
        #expect(h.app.finance.bookings.filter { $0.counterparty == shop }.isEmpty)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Umsaetze-\(UUID().uuidString.prefix(6)).csv")
        try Data(csv.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fromFile = try await h.call("finance.import.csv", ["file": .string(file.path), "useBalance": false])
        #expect(fromFile["added"] == 2)
        #expect(await h.errorCode("finance.import.csv", ["text": "Name;Wert\nA;1"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("finance.import.csv") == RPCError.invalidParamsCode)
    }

    @Test func importsAskThePersonOutsideTheApp() async throws {
        var asked: [ApprovalRequest] = []
        h.registry.approval.presenter = { request in
            asked.append(request)
            return false
        }
        defer { h.registry.approval.presenter = { _ in true } }
        // Bank texts are foreign and private at once: whoever imports them outside the app's own controls asks.
        #expect(await h.errorCode("finance.import.csv", ["file": "/tmp/irgendwas.csv"], channel: .chat) == RPCError.deniedCode)
        #expect(await h.errorCode("finance.import.csv", ["text": "Buchungstag;Betrag\n01.11.2026;-1,00"], channel: .cli) == RPCError.deniedCode)
        #expect(asked.map(\.action) == ["finance.import.csv", "finance.import.csv"])
        #expect(asked.first?.target == "/tmp/irgendwas.csv")
        try await h.call("finance.import.csv", ["text": "Buchungstag;Betrag\n01.11.2026;-1,00"], channel: .ui)
        #expect(asked.count == 2, "die Oberfläche fragt nicht")
        try await h.call("writer.edit.undo", channel: .ui)
    }

    @Test func privateFinancesAreClosedToMCP() async throws {
        #expect(await h.errorCode("finance.overview", channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("finance.transaction.list", channel: .mcp) == RPCError.deniedCode)
        #expect(await h.errorCode("finance.plan.read", channel: .mcp) == RPCError.deniedCode)
        let list = try await h.call("finance.category.list", channel: .mcp)
        #expect(list["categories"]?.arrayValue?.isEmpty == false)
        for id in ["finance.transaction.list", "finance.groups.list", "finance.recurring.list"] {
            let security = h.registry.descriptor(id)?.security
            #expect(security?.sensitive == true && security?.readsUntrusted == true, "\(id): Texte von Banken und Händlern sind fremd und privat")
        }
        #expect(h.registry.descriptor("finance.transaction.delete")?.kind == .destructive)
        #expect(h.registry.descriptor("finance.statement.export")?.security.effect == .outbound)
    }

    @Test func similarBookingsBecomeAGroupWithARhythmAndAFixedCost() async throws {
        let service = unique("Streamingdienst Beispiel")
        let today = FinanceDay.today
        let lines = (1...4).reversed().map { offset in "\(today.adding(months: -offset).german);Abo;\(service) GmbH;-9,99" }.joined(separator: "\n")
        try await h.call("finance.import.csv", ["text": .string("Buchungstag;Verwendungszweck;Empfänger;Betrag\n" + lines), "useBalance": false])
        let key = FinanceGrouping.key(counterparty: service, purpose: "", type: "")
        let groups = try await h.call("finance.groups.list", ["direction": "ausgaben", "limit": 500])
        let group = try #require(groups["groups"]?.arrayValue?.first { $0["key"]?.stringValue == key })
        #expect(group["count"] == 4)
        #expect(group["recurrence"]?["interval"] == "monatlich")
        #expect(group["recurrence"]?["amount"]?.number == -9.99)

        let recurring = try await h.call("finance.recurring.list")
        let item = try #require(recurring["recurring"]?.arrayValue?.first { $0["group"]?["key"]?.stringValue == key })
        #expect(item["inPlan"] == false)

        let cost = try await h.call("finance.fixedCost.add", ["group": .string(key)])
        #expect(cost["amount"]?.number == 9.99)
        #expect(cost["interval"] == "monatlich")
        #expect(cost["group"]?.stringValue == key)
        let planned = try await h.call("finance.recurring.list")
        #expect(planned["recurring"]?.arrayValue?.first { $0["group"]?["key"]?.stringValue == key }?["inPlan"] == true)
        try await h.call("finance.plan.remove", ["item": .string(try #require(cost["id"]?.stringValue))])
    }

    @Test func categoriesAreMadeAssignedAndDeleted() async throws {
        let name = unique("Haustier")
        let made = try await h.call("finance.category.create", ["name": .string(name), "keywords": ["Tierfutter Beispiel"]])
        let key = try #require(made["key"]?.stringValue)
        #expect(made["kind"] == "ausgabe")
        #expect(made["keywords"]?.arrayValue == ["tierfutter beispiel"])
        let shop = unique("Tierfutter Beispiel")
        let booked = try await h.call("finance.transaction.add", ["amount": -20, "counterparty": .string(shop)])
        #expect(booked["category"]?.stringValue == key, "das Stichwort ordnet ein")
        #expect(booked["categorySource"] == "stichwort")

        try await h.call("finance.category.update", ["category": .string(key), "removeKeywords": ["tierfutter beispiel"], "addKeywords": ["napf"]])
        #expect(h.app.finance.state.category(key)?.keywords == ["napf"])
        let groupKey = try #require(booked["group"]?.stringValue)
        let assigned = try await h.call("finance.category.assign", ["group": .string(groupKey), "category": .string(name)])
        #expect(assigned["affected"] == 1)
        #expect(h.app.finance.analysis.entries.first { $0.booking.counterparty == shop }?.categorySource == .person)
        let one = try await h.call("finance.category.assign", ["transaction": .string(try #require(booked["id"]?.stringValue)), "category": "freizeit"])
        #expect(one["category"] == "freizeit")
        #expect(await h.errorCode("finance.category.assign", ["category": "freizeit"]) == RPCError.invalidParamsCode)

        try await h.call("finance.category.delete", ["category": .string(key)])
        #expect(h.app.finance.state.category(key) == nil)
        #expect(!h.app.finance.state.assignments.contains { $0.category == key })
        try await h.call("writer.edit.undo")
        #expect(h.app.finance.state.category(key) != nil)
        #expect(await h.errorCode("finance.category.create", ["name": "Neu", "key": "lebensmittel"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("finance.category.update", ["category": "gibt es nicht"]) == RPCError.notFoundCode)
    }

    @Test func theModelSortsGroupsIntoExistingCategoriesOnly() async throws {
        let club = unique("Kletterhalle Beispiel")
        let odd = unique("Unbekannt Beispiel")
        try await h.call("finance.transaction.add", ["amount": .double(-98765.43), "counterparty": .string(club), "date": "2001-01-02"])
        try await h.call("finance.transaction.add", ["amount": .double(-98765.42), "counterparty": .string(odd), "date": "2001-01-03"])
        let clubKey = FinanceGrouping.key(counterparty: club, purpose: "", type: "")
        let oddKey = FinanceGrouping.key(counterparty: odd, purpose: "", type: "")
        let server = try FakeLLMServer()
        // The prompt names groups as the studio does, without store numbers.
        let clubName = try #require(h.app.finance.analysis.groups[clubKey]?.name)
        let oddName = try #require(h.app.finance.analysis.groups[oddKey]?.name)
        server.respond = { request in
            guard request["response_format"]?["json_schema"]?["name"] == "finanzposten" else { return nil }
            let user = request["messages"]?.arrayValue?.last?["content"]?.stringValue ?? ""
            func number(_ name: String) -> Int? {
                user.components(separatedBy: "\n").first { $0.contains(name) }.flatMap { Int($0.prefix { $0.isNumber }) }
            }
            var items: [String] = []
            if let n = number(clubName) { items.append(#"{"nr": \#(n), "kategorie": "freizeit"}"#) }
            // An income category for an expense must be ignored.
            if let n = number(oddName) { items.append(#"{"nr": \#(n), "kategorie": "gehalt"}"#) }
            return #"{"zuordnungen": [\#(items.joined(separator: ","))]}"#
        }
        let old = h.app.endpoint
        h.app.endpoint = server.endpoint
        await h.app.refreshModels()
        defer {
            h.app.endpoint = old
            server.stop()
        }
        let result = try await h.call("finance.ai.categorize", ["limit": 200])
        #expect(result["assigned"]?.arrayValue?.contains { $0["group"]?.stringValue == clubKey && $0["category"] == "freizeit" } == true)
        #expect(result["assigned"]?.arrayValue?.contains { $0["group"]?.stringValue == oddKey } == false)
        #expect(h.app.finance.analysis.groups[clubKey]?.category == "freizeit")
        #expect(h.app.finance.analysis.entries.first { $0.group == clubKey }?.categorySource == .model)
        try await h.call("writer.edit.undo")
        #expect(h.app.finance.analysis.groups[clubKey]?.category == nil)
    }

    @Test func aStatementIsWrittenAsPDF() async throws {
        let name = unique("Kontoauszug Beispiel")
        try await h.call("finance.transaction.add", ["amount": -42, "counterparty": .string(name), "date": "2026-10-15"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Auszug-\(UUID().uuidString.prefix(6)).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let written = try await h.call("finance.statement.export", ["from": "2026-10-01", "to": "2026-10-31", "path": .string(file.path)])
        #expect(written["path"]?.stringValue == file.path)
        #expect((written["bookings"]?.intValue ?? 0) >= 1)
        let pdf = try #require(PDFDocument(url: file))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        #expect(text.contains(name))
        #expect(text.contains("01.10.2026"))
        #expect(await h.errorCode("finance.statement.export", ["from": "2026-11-01", "to": "2026-10-01"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("finance.statement.export", ["path": .string(file.path)]) == RPCError.invalidTargetCode, "die Datei gibt es schon")
    }

    @Test func thePlanTakesIncomeCostsProjectsAndGoals() async throws {
        let income = try await h.call("finance.income.add", ["name": .string(unique("Gehalt")), "amount": 3200, "day": 28])
        #expect(income["monthly"]?.number == 3200)
        let insurance = try await h.call("finance.fixedCost.add", ["name": .string(unique("Versicherung")), "amount": 240, "interval": "jaehrlich", "category": "versicherungen"])
        #expect(insurance["monthly"]?.number == 20)
        let mac = unique("Mac mini M5 Pro")
        let project = try await h.call("finance.project.add", ["name": .string(mac), "amount": 3500, "targetDate": "2030-03-01", "priority": "hoch"])
        let projectID = try #require(project["id"]?.stringValue)
        #expect(project["missing"]?.number == 3500)
        let goal = try await h.call("finance.goal.add", ["name": .string(unique("Notgroschen")), "target": 6000, "monthly": 250])
        let goalID = try #require(goal["id"]?.stringValue)
        #expect(goal["reachedOn"]?.stringValue != nil)

        let plan = try await h.call("finance.plan.read")
        #expect(plan["projects"]?.arrayValue?.contains { $0["id"]?.stringValue == projectID } == true)
        #expect(plan["goals"]?.arrayValue?.contains { $0["id"]?.stringValue == goalID } == true)
        #expect(plan["monthlyIncome"]?.number ?? 0 >= 3200)

        let changed = try await h.call("finance.plan.update", ["item": .string(mac), "saved": 500, "priority": "mittel"])
        #expect(changed["changed"]?.arrayValue == ["priority", "saved"])
        #expect(h.app.finance.state.plan.projects.first { $0.id.uuidString == projectID }?.saved == 50_000)
        #expect(await h.errorCode("finance.plan.update", ["item": .string(mac), "monthly": 10]) == RPCError.invalidParamsCode, "Projekte haben keine Sparrate")
        #expect(await h.errorCode("finance.plan.update", ["item": .string(mac)]) == RPCError.invalidParamsCode)

        let deposit = try await h.call("finance.goal.deposit", ["goal": .string(goalID), "amount": 1000])
        #expect(deposit["saved"]?.number == 1000)
        let withdraw = try await h.call("finance.goal.deposit", ["goal": .string(goalID), "amount": -5000])
        #expect(withdraw["saved"]?.number == 0, "nicht unter null")
        #expect(await h.errorCode("finance.goal.deposit", ["goal": .string(try #require(income["id"]?.stringValue)), "amount": 1]) == RPCError.invalidParamsCode)

        try await h.call("finance.plan.configure", ["countsVariable": false])
        #expect(h.app.finance.state.plan.countsVariable == false)
        try await h.call("finance.plan.configure", ["countsVariable": true])

        for id in [income["id"], insurance["id"], project["id"], goal["id"]].compactMap({ $0?.stringValue }) {
            try await h.call("finance.plan.remove", ["item": .string(id)])
        }
        #expect(!h.app.finance.state.plan.projects.contains { $0.id.uuidString == projectID })
        try await h.call("writer.edit.undo")
        #expect(h.app.finance.state.plan.goals.contains { $0.id.uuidString == goalID }, "das zuletzt Entfernte kommt zurück")
        try await h.call("finance.plan.remove", ["item": .string(goalID)])
        #expect(await h.errorCode("finance.plan.remove", ["item": "gibt es sicher nicht"]) == RPCError.notFoundCode)
    }

    @Test func theStudioOpensAtATabAndCloses() async throws {
        try await h.call("finance.studio.open", ["tab": "planung", "period": "jahr", "date": "2026-05-01"])
        #expect(h.app.financeStudioOpen)
        #expect(h.app.activeApplication == .finance)
        #expect(h.app.financeStudioCommand?.tab == .planning)
        #expect(h.app.financeStudioCommand?.period == FinancePeriod(.year, FinanceDay(year: 2026, month: 5, day: 1)))
        try await h.call("finance.studio.close")
        #expect(!h.app.financeStudioOpen)
        h.app.financeStudioCommand = nil
        #expect(await h.errorCode("finance.studio.open", ["tab": "kasse"]) == RPCError.invalidParamsCode)
    }
}
}
