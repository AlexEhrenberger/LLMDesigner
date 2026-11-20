import Testing
import Foundation
import PDFKit
@testable import LLMDesigner

/// FinanceStudio without the registry: amounts, days, the CSV reader, groups, rhythms, categories, balances, the
/// plan, storage and the statement. The libraries here have folders of their own, so nothing meets the shared model.
@MainActor
@Suite("FinanceStudio")
struct FinanceTests {
    private func library() -> FinanceLibrary {
        FinanceLibrary(folder: FileManager.default.temporaryDirectory.appendingPathComponent("Finanzen-\(UUID().uuidString)", isDirectory: true))
    }

    private func day(_ text: String) -> FinanceDay { FinanceDay(text)! }

    @Test func amountsAreReadAsGermansWriteThem() {
        let cases: [(String, Int?)] = [
            ("1.234,56", 123_456), ("-54,20", -5_420), ("54.20", 5_420), ("3.500", 350_000), ("3500", 350_000), ("12,5", 1_250),
            ("1,234.56", 123_456), ("54,20 €", 5_420), ("−12,00", -1_200), ("+7,99 EUR", 799), ("12,00-", -1_200), ("abc", nil), ("", nil), ("1,2,3", 12_300),
        ]
        for (text, expected) in cases {
            #expect(FinanceMoney.cents(text) == expected, "\(text)")
        }
        #expect(FinanceMoney.cents("1.234", decimalComma: true) == 123_400)
        #expect(FinanceMoney.cents("1.234", decimalComma: false) == nil, "mehr als zwei Stellen nach dem Komma sind kein Betrag")
        #expect(FinanceMoney.plain(-123_456) == "-1.234,56")
        // The formatter keeps the amount and the sign of the currency together with a no-break space.
        #expect(FinanceMoney.format(123_456, sign: true) == "+1.234,56\u{00A0}€")
        #expect(FinanceMoney.format(-5_420) == "−54,20\u{00A0}€")
    }

    @Test func daysKnowTheCalendar() {
        #expect(FinanceDay("20.11.2026") == FinanceDay(year: 2026, month: 11, day: 20))
        #expect(FinanceDay("2026-11-20") == FinanceDay(year: 2026, month: 11, day: 20))
        #expect(FinanceDay("20.11.26") == FinanceDay(year: 2026, month: 11, day: 20))
        #expect(FinanceDay("31.02.2026") == nil)
        #expect(FinanceDay("Buchungstag") == nil)
        #expect(day("2026-01-31").adding(months: 1) == day("2026-02-28"))
        #expect(day("2024-01-31").adding(months: 1) == day("2024-02-29"))
        #expect(day("2026-11-20").weekStart == day("2026-11-16"), "Wochen beginnen am Montag")
        #expect(day("2026-11-16").weekStart == day("2026-11-16"))
        #expect(day("2026-11-22").weekStart == day("2026-11-16"), "Sonntag gehört zur Woche davor")
        #expect(day("2026-11-20").days(to: day("2026-12-20")) == 30)
        #expect(FinancePeriod(.week, day("2026-11-20")).range == day("2026-11-16")...day("2026-11-22"))
        #expect(FinancePeriod(.month, day("2026-11-20")).shifted(by: -11).range?.lowerBound == day("2025-12-01"))
    }

    // MARK: CSV

    @Test func aSavingsBankExportInWindows1252IsRead() throws {
        let csv = """
        "Auftragskonto";"Buchungstag";"Valutadatum";"Buchungstext";"Verwendungszweck";"Glaeubiger ID";"Beguenstigter/Zahlungspflichtiger";"Kontonummer/IBAN";"Betrag";"Waehrung";"Info"
        "DE00123";"03.11.26";"03.11.26";"LASTSCHRIFT";"Einkauf 0815 Grüße";"";"Bäckerei Beispiel";"DE11000000000000000001";"-4,80";"EUR";"Umsatz gebucht"
        "DE00123";"01.11.26";"01.11.26";"GUTSCHRIFT";"Lohn November";"";"Beispiel GmbH";"DE22000000000000000002";"2.450,00";"EUR";"Umsatz gebucht"
        "DE00123";"30.10.26";"30.10.26";"ENTGELT";"Kontoführung";"";"";"";"-5,90";"EUR";"Umsatz gebucht"
        """
        let data = try #require(csv.data(using: .windowsCP1252))
        let result = try FinanceCSV.parse(data)
        #expect(result.separator == ";")
        #expect(result.bookings.count == 3)
        let bakery = try #require(result.bookings.first)
        #expect(bakery.day == day("2026-11-03"))
        #expect(bakery.cents == -480)
        #expect(bakery.counterparty == "Bäckerei Beispiel", "Umlaute aus Windows-1252")
        #expect(bakery.purpose == "Einkauf 0815 Grüße")
        #expect(bakery.type == "LASTSCHRIFT")
        #expect(bakery.iban == "DE11000000000000000001")
        #expect(result.bookings[1].cents == 245_000)
        #expect(result.columns[.amount] == "Betrag")
        #expect(result.columns[.counterparty] == "Beguenstigter/Zahlungspflichtiger")
        #expect(result.balance == nil)
    }

    @Test func anExportWithAccountLinesBeforeTheHeaderAndAPayerColumnIsRead() throws {
        let csv = """
        "Konto:";"Girokonto DE00 0000"
        "Kontostand vom 20.11.2026:";"1.000,00 €"
        ""
        "Buchungsdatum";"Wertstellung";"Status";"Zahlungspflichtige*r";"Zahlungsempfänger*in";"Verwendungszweck";"Umsatztyp";"IBAN";"Betrag (€)";"Kontostand"
        "20.11.26";"20.11.26";"Gebucht";"Mara Beispiel";"Stromwerk Beispiel";"Abschlag November";"Ausgang";"DE33";"-62,00";"1.000,00"
        "18.11.26";"18.11.26";"Gebucht";"Beispiel Verein";"Mara Beispiel";"Rückzahlung";"Eingang";"DE44";"15,00";"1.062,00"
        """
        let result = try FinanceCSV.parse(Data(csv.utf8))
        #expect(result.bookings.count == 2)
        #expect(result.bookings[0].counterparty == "Stromwerk Beispiel", "bei Ausgaben der Empfänger")
        #expect(result.bookings[1].counterparty == "Beispiel Verein", "bei Eingängen, wer gezahlt hat")
        #expect(result.balance == FinanceBalanceAnchor(cents: 100_000, day: day("2026-11-20")), "Saldo der neuesten Buchung")
    }

    @Test func commaSeparatedExportsWithDecimalPointsAndDebitCreditMarksAreRead() throws {
        let points = """
        "Datum","Empfänger","Kontonummer","Transaktionstyp","Verwendungszweck","Betrag (EUR)"
        "2026-11-02","Beispiel Kino","","MasterCard Zahlung","","-12.50"
        "2026-11-01","Mara Beispiel","DE55","Gutschrift","Danke","1250.00"
        """
        let first = try FinanceCSV.parse(Data(points.utf8))
        #expect(first.separator == ",")
        #expect(first.bookings.map(\.cents) == [-1_250, 125_000])

        let marks = """
        Buchungstag;Valuta;Auftraggeber/Zahlungsempfänger;Vorgang/Verwendungszweck;Umsatz;Soll/Haben
        05.11.2026;05.11.2026;Beispiel Versicherung;Beitrag;89,00;S
        06.11.2026;06.11.2026;Beispiel Versicherung;Erstattung;20,00;H
        """
        let second = try FinanceCSV.parse(Data(marks.utf8))
        #expect(second.bookings.map(\.cents) == [-8_900, 2_000])
        #expect(second.bookings[0].counterparty == "Beispiel Versicherung")

        #expect(throws: FinanceCSV.Problem.self) { try FinanceCSV.parse(Data("Name;Wert\nA;1\n".utf8)) }
        #expect(throws: FinanceCSV.Problem.self) { try FinanceCSV.parse(Data()) }
    }

    @Test func recordsKeepQuotedSeparatorsAndLineBreaks() {
        let rows = FinanceCSV.records("a;\"b;c\";\"zwei\nZeilen\";\"sagt \"\"hallo\"\"\"\nd;e;f;g", separator: ";")
        #expect(rows == [["a", "b;c", "zwei\nZeilen", "sagt \"hallo\""], ["d", "e", "f", "g"]])
    }

    // MARK: Groups and rhythms

    @Test func similarCounterpartiesShareAGroup() {
        func key(_ counterparty: String, _ purpose: String = "") -> String { FinanceGrouping.key(counterparty: counterparty, purpose: purpose, type: "") }
        #expect(key("REWE Markt GmbH") == key("REWE City 1234 Berlin"))
        #expect(key("REWE Markt GmbH") == "rewe")
        #expect(key("Netflix International B.V.") == "netflix")
        #expect(key("AMAZON PAYMENTS EUROPE S.C.A.") == key("Amazon EU S.a.r.l."))
        #expect(key("Deutsche Bahn AG") != key("Deutsche Telekom AG"))
        #expect(key("dm-drogerie markt") == "dm drogerie")
        #expect(key("PayPal (Europe) S.a.r.l. et Cie., S.C.A.", "1234567 PP.1234.PP . Spotify AB, Ihr Einkauf bei Spotify AB") == "spotify")
        #expect(key("PayPal (Europe) S.a.r.l. et Cie., S.C.A.", "1234567 PP.1234.PP") == "paypal")
        #expect(key("", "") == "ohne-namen")
        #expect(FinanceGrouping.displayName(of: ["REWE Markt GmbH", "REWE Markt GmbH", "Rewe"]) == "REWE")
        #expect(FinanceGrouping.displayName(of: ["Beispiel Versicherung AG"]) == "Beispiel Versicherung")
    }

    @Test func steadyPaymentsAreFoundAndStrayOnesAreNot() {
        let today = day("2026-11-20")
        func bookings(_ days: [String], _ cents: [Int]) -> [FinanceTransaction] {
            zip(days, cents).map { FinanceTransaction(day: day($0), cents: $1, counterparty: "Beispiel Abo") }
        }
        let monthly = FinanceRecurrence.detect(bookings(["2026-08-03", "2026-09-03", "2026-10-02", "2026-11-03"], [-1_299, -1_299, -1_299, -1_499]), today: today)
        #expect(monthly?.interval == .monthly)
        #expect(monthly?.cents == -1_299)
        #expect(monthly?.next == day("2026-12-03"))
        #expect(monthly?.dueDay == 3)
        let yearly = FinanceRecurrence.detect(bookings(["2025-03-01", "2026-03-02"], [-8_900, -8_900]), today: today)
        #expect(yearly?.interval == .yearly)
        #expect(FinanceRecurrence.detect(bookings(["2026-10-01", "2026-10-09", "2026-11-17"], [-500, -2_300, -900]), today: today) == nil, "zufällige Beträge")
        #expect(FinanceRecurrence.detect(bookings(["2026-01-03", "2026-02-03", "2026-03-03"], [-1_299, -1_299, -1_299]), today: today) == nil, "seit Monaten nicht mehr")
        #expect(FinanceRecurrence.detect(bookings(["2026-10-03", "2026-11-03"], [-1_299, -1_299]), today: today) == nil, "zwei Monate sind noch kein Rhythmus")
    }

    @Test func categoriesComeFromTheBookingThenTheGroupThenTheKeywords() {
        var state = FinanceState()
        let groceries = FinanceTransaction(day: day("2026-11-01"), cents: -2_340, counterparty: "REWE Markt GmbH")
        let salary = FinanceTransaction(day: day("2026-11-01"), cents: 250_000, counterparty: "Beispiel GmbH", purpose: "Gehalt November")
        let refund = FinanceTransaction(day: day("2026-11-02"), cents: 1_000, counterparty: "REWE Markt GmbH", purpose: "Pfand")
        var categorizer = FinanceCategorizer(state: state)
        #expect(categorizer.category(of: groceries, group: "rewe").key == "lebensmittel")
        #expect(categorizer.category(of: groceries, group: "rewe").source == .keyword)
        #expect(categorizer.category(of: salary, group: "beispiel").key == "gehalt")
        #expect(categorizer.category(of: refund, group: "rewe").key == nil, "eine Ausgaben-Kategorie nimmt keine Einnahme")
        #expect(categorizer.category(of: FinanceTransaction(day: day("2026-11-01"), cents: -500, counterparty: "Admiral Kiosk"), group: "admiral").key == nil,
                "„dm“ steckt nicht in „Admiral“")

        state.assignments = [FinanceAssignment(group: "rewe", category: "restaurants", source: .model), FinanceAssignment(group: "rewe", category: "shopping", source: .person)]
        categorizer = FinanceCategorizer(state: state)
        #expect(categorizer.category(of: groceries, group: "rewe").key == "shopping", "die Person vor dem Modell")
        #expect(categorizer.category(of: groceries, group: "rewe").source == .person)
        var own = groceries
        own.category = "freizeit"
        #expect(categorizer.category(of: own, group: "rewe").key == "freizeit")
        #expect(categorizer.category(of: own, group: "rewe").source == .booking)
    }

    @Test func theBalanceFollowsFromTheAnchorBothWays() {
        var state = FinanceState()
        state.account.anchor = FinanceBalanceAnchor(cents: 100_000, day: day("2026-11-10"))
        let bookings = [
            FinanceTransaction(day: day("2026-11-01"), cents: -10_000, counterparty: "A"),
            FinanceTransaction(day: day("2026-11-10"), cents: -5_000, counterparty: "B"),
            FinanceTransaction(day: day("2026-11-15"), cents: 20_000, counterparty: "C"),
        ]
        let analysis = FinanceAnalysis(state: state, bookings: bookings, today: day("2026-11-20"))
        #expect(analysis.balance(at: day("2026-11-10")) == 100_000)
        #expect(analysis.balance(at: day("2026-11-09")) == 105_000)
        #expect(analysis.balance(at: day("2026-10-31")) == 115_000)
        #expect(analysis.currentBalance == 120_000)
        #expect(analysis.entries.map(\.balanceAfter) == [105_000, 100_000, 120_000])
        let november = analysis.totals(analysis.filtered(FinanceFilter(period: FinancePeriod(.month, day("2026-11-05")))))
        #expect(november.income == 20_000)
        #expect(november.expenses == -15_000)
        let buckets = analysis.buckets(around: FinancePeriod(.month, day("2026-11-05")))
        #expect(buckets.count == 12)
        #expect(buckets.last?.income == 20_000)
        #expect(buckets.last?.balance == 120_000)
    }

    @Test func transfersAreNotSpending() {
        let state = FinanceState()
        let bookings = [
            FinanceTransaction(day: day("2026-11-01"), cents: -30_000, counterparty: "Mara Beispiel", purpose: "Umbuchung Tagesgeld"),
            FinanceTransaction(day: day("2026-11-02"), cents: -2_000, counterparty: "Beispiel Kino"),
        ]
        let analysis = FinanceAnalysis(state: state, bookings: bookings, today: day("2026-11-20"))
        let totals = analysis.totals(analysis.entries)
        #expect(totals.expenses == -2_000)
        #expect(totals.transfers == -30_000)
        #expect(totals.net == -32_000)
    }

    @Test func thePlanSaysWhenAProjectIsPaidFor() {
        var state = FinanceState()
        state.plan.countsVariable = false
        state.plan.income = [FinancePlanEntry(name: "Gehalt", cents: 300_000)]
        state.plan.fixedCosts = [FinancePlanEntry(name: "Miete", cents: 90_000), FinancePlanEntry(name: "Versicherung", cents: 120_000, interval: .yearly)]
        state.plan.goals = [FinanceGoal(name: "Notgroschen", target: 600_000, saved: 100_000, monthly: 50_000, targetDay: day("2027-05-20"))]
        var mac = FinanceProject(name: "Mac mini M5 Pro", cents: 350_000, targetDay: day("2027-01-31"), priority: .high)
        mac.saved = 50_000
        let bike = FinanceProject(name: "Fahrrad", cents: 150_000, priority: .low)
        state.plan.projects = [bike, mac]
        let analysis = FinanceAnalysis(state: state, bookings: [], today: day("2026-11-20"))
        let summary = analysis.planSummary()
        #expect(summary.fixedCosts == 100_000, "jährliche Kosten zählen mit einem Zwölftel")
        #expect(summary.free == 200_000)
        #expect(summary.forProjects == 150_000)
        let first = summary.projects[0]
        #expect(first.project.name == "Mac mini M5 Pro", "hohe Priorität zuerst")
        #expect(first.affordable == day("2027-01-01"), "3.000 € fehlen, 1.500 € im Monat")
        #expect(first.onTime == true)
        #expect(summary.projects[1].affordable == day("2027-02-01"), "das Fahrrad wartet auf den Mac")
        let goal = summary.goals[0]
        #expect(goal.reached == day("2027-09-01"))
        #expect(goal.neededMonthly == 83_334)
    }

    @Test func otherSpendingIsTheAverageOfThreeMonthsWithoutFixedCosts() {
        var state = FinanceState()
        state.plan.fixedCosts = [FinancePlanEntry(name: "Miete", cents: 90_000, group: "wohnbau")]
        var bookings: [FinanceTransaction] = []
        for month in ["2026-08", "2026-09", "2026-10"] {
            bookings.append(FinanceTransaction(day: day(month + "-01"), cents: -90_000, counterparty: "Wohnbau Beispiel"))
            bookings.append(FinanceTransaction(day: day(month + "-12"), cents: -30_000, counterparty: "REWE Markt"))
        }
        bookings.append(FinanceTransaction(day: day("2026-11-05"), cents: -99_999, counterparty: "REWE Markt"))
        let analysis = FinanceAnalysis(state: state, bookings: bookings, today: day("2026-11-20"))
        #expect(analysis.variableSpending() == 30_000, "der laufende Monat und die Miete zählen nicht")
        #expect(analysis.groups["wohnbau"]?.recurrence?.interval == .monthly)
        #expect(analysis.planSuggestions.contains { $0.key == "wohnbau" } == false, "schon geplant")
    }

    // MARK: Storage

    @Test func bookingsAreStoredOneFilePerMonthAndReadBack() throws {
        let first = library()
        first.loadIfNeeded()
        first.add(FinanceTransaction(day: day("2026-10-31"), cents: -1_000, counterparty: "Oktober"))
        first.add(FinanceTransaction(day: day("2026-11-01"), cents: 2_000, counterparty: "November"))
        first.changeState { $0.account.name = "Testkonto"; $0.plan.goals.append(FinanceGoal(name: "Urlaub", target: 100_000)) }
        first.saveAll()
        let files = try FileManager.default.contentsOfDirectory(atPath: first.bookingsFolder.path).sorted()
        #expect(files == ["2026-10.json", "2026-11.json"])
        let text = try String(contentsOf: first.bookingsFolder.appendingPathComponent("2026-11.json"), encoding: .utf8)
        #expect(text.contains("\"cent\" : 2000"))
        #expect(text.contains("\"datum\" : \"2026-11-01\""))
        #expect(text.contains("\"monat\" : \"2026-11\""))

        let second = FinanceLibrary(folder: first.folder)
        second.loadIfNeeded()
        #expect(second.bookings.map(\.counterparty) == ["Oktober", "November"])
        #expect(second.state.account.name == "Testkonto")
        #expect(second.state.plan.goals.first?.name == "Urlaub")
        #expect(second.state.categories == FinanceCategory.defaults)

        second.remove(Set(second.bookings.filter { $0.counterparty == "Oktober" }.map(\.id)))
        second.saveAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.bookingsFolder.path) == ["2026-11.json"], "ein leerer Monat verliert seine Datei")
    }

    @Test func anOverlappingImportAddsOnlyWhatIsNew() {
        let finance = library()
        let coffee = FinanceTransaction(day: day("2026-11-03"), cents: -350, counterparty: "Beispiel Café")
        var second = coffee
        second.id = UUID()
        let first = finance.importBookings([coffee, second])
        #expect(first.added.count == 2, "zwei gleiche Kaffees an einem Tag sind zwei Buchungen")
        var again = coffee
        again.id = UUID()
        let lunch = FinanceTransaction(day: day("2026-11-04"), cents: -990, counterparty: "Beispiel Kantine")
        let overlap = finance.importBookings([again, again, lunch])
        #expect(overlap.added.map(\.counterparty) == ["Beispiel Kantine"])
        #expect(overlap.duplicates == 2)
    }

    @Test func undoPutsBookingsAndStateBack() {
        let finance = library()
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        finance.change("Buchung eintragen", undo: undo) { finance.add(FinanceTransaction(day: day("2026-11-03"), cents: -100, counterparty: "Rückgängig")) }
        undo.endUndoGrouping()
        #expect(finance.bookings.count == 1)
        undo.undo()
        #expect(finance.bookings.isEmpty)
        undo.redo()
        #expect(finance.bookings.first?.counterparty == "Rückgängig")
    }

    @Test func aStatementIsAPDFWithTheBalances() throws {
        var state = FinanceState()
        state.account.name = "Testkonto"
        state.account.iban = "DE00123456780000000000"
        state.account.anchor = FinanceBalanceAnchor(cents: 50_000, day: day("2026-10-31"))
        var bookings: [FinanceTransaction] = []
        for index in 0..<80 {
            bookings.append(FinanceTransaction(day: day("2026-11-01").adding(days: index % 28), cents: -(100 + index), counterparty: "Beispiel Laden \(index % 7)", purpose: "Einkauf Nummer \(index)"))
        }
        let analysis = FinanceAnalysis(state: state, bookings: bookings, today: day("2026-11-30"))
        let statement = FinanceStatement.make(analysis, from: day("2026-11-01"), to: day("2026-11-30"))
        #expect(statement.opening == 50_000)
        #expect(statement.rows.count == 80)
        #expect(statement.closing == 50_000 + bookings.reduce(0) { $0 + $1.cents })
        #expect(statement.debits == bookings.reduce(0) { $0 + $1.cents })
        let data = FinanceStatementPDF.render(statement)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 2, "80 Buchungen passen nicht auf eine Seite")
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Kontoauszug"))
        #expect(text.contains("Endsaldo"))
        #expect(text.contains("DE00 1234 5678"))
        #expect(text.contains("Seite 2 von \(pdf.pageCount)"))
        #expect(text.contains("kein Dokument der Bank"))
    }
}
