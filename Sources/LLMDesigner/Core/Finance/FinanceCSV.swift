import Foundation

/// Reads the CSV export of a bank. Banks differ in everything: encoding (UTF-8 or Windows-1252), separator, lines of
/// account data before the header, the names of the columns, one amount column or debit and credit apart, decimal
/// comma or point. The reader finds the header by its words and the meaning of each column by its name, so a new
/// bank usually works without code; what it can't read, it counts and reports instead of guessing.
enum FinanceCSV {
    enum Field: String, CaseIterable, Sendable {
        case day = "datum", valueDay = "valuta", amount = "betrag", debit = "soll", credit = "haben", sign = "sollHaben"
        case counterparty = "gegenpartei", payer = "zahler", purpose = "zweck", type = "art", iban, balance = "saldo", currency = "waehrung"

        var label: String {
            switch self {
            case .day: "Datum"
            case .valueDay: "Wertstellung"
            case .amount: "Betrag"
            case .debit: "Soll"
            case .credit: "Haben"
            case .sign: "Soll/Haben"
            case .counterparty: "Empfänger/Auftraggeber"
            case .payer: "Zahlungspflichtige*r"
            case .purpose: "Verwendungszweck"
            case .type: "Buchungstext"
            case .iban: "IBAN"
            case .balance: "Saldo"
            case .currency: "Währung"
            }
        }

        /// Header words, folded, in the order they are tried. The first column that matches wins.
        var names: [String] {
            switch self {
            case .day: ["buchungstag", "buchungsdatum", "buchung", "datum", "date", "booking date", "transaction date"]
            case .valueDay: ["valutadatum", "valuta", "wertstellung", "wertstellungsdatum", "value date"]
            case .amount: ["betrag (eur)", "betrag (euro)", "betrag (€)", "betrag", "umsatz", "amount", "umsatz in eur", "betrag eur"]
            case .debit: ["soll", "ausgang", "belastung", "debit"]
            case .credit: ["haben", "eingang", "gutschrift", "credit"]
            case .sign: ["soll/haben", "s/h", "soll / haben"]
            case .counterparty: ["beguenstigter/zahlungspflichtiger", "zahlungsempfaenger*in", "zahlungsempfaenger", "empfaenger", "auftraggeber / beguenstigter",
                                 "auftraggeber/beguenstigter", "auftraggeber/empfaenger", "auftraggeber", "beguenstigter", "name zahlungsbeteiligter", "gegenpartei", "partner name", "payee", "name"]
            // DKB names the payer of income in a column of its own.
            case .payer: ["zahlungspflichtige*r", "zahlungspflichtiger", "zahlungspflichtige"]
            case .purpose: ["verwendungszweck", "buchungsdetails", "beschreibung", "zweck", "vorgang/verwendungszweck", "reference", "description", "notiz", "kommentar"]
            case .type: ["buchungstext", "umsatzart", "umsatztyp", "vorgang", "transaktionstyp", "transaction type", "type", "art"]
            case .iban: ["kontonummer/iban", "iban zahlungsbeteiligter", "iban auftraggeber", "iban", "kontonummer", "account number"]
            case .balance: ["saldo nach buchung", "kontostand", "saldo"]
            case .currency: ["waehrung", "currency"]
            }
        }
    }

    struct Result: Sendable {
        var bookings: [FinanceTransaction]
        /// Which column was read as what, for the person to check.
        var columns: [Field: String]
        /// Rows that had no readable day or amount.
        var skipped: Int
        /// The balance after the newest booking, if the file has a balance column.
        var balance: FinanceBalanceAnchor?
        var separator: Character
    }

    enum Problem: LocalizedError {
        case empty, noHeader, noAmount

        var errorDescription: String? {
            switch self {
            case .empty: "Die Datei ist leer."
            case .noHeader: "In der Datei steht keine Kopfzeile mit Datum und Betrag. Ist es der CSV-Export der Bank?"
            case .noAmount: "Es fehlt eine Spalte mit dem Betrag (oder Soll und Haben)."
            }
        }
    }

    /// UTF-8 if it is valid, else Windows-1252, which German banks (Sparkasse, Volksbank) still write.
    static func text(of data: Data) -> String {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ data: Data, importedAt: Date = Date()) throws -> Result {
        try parse(text: text(of: data), importedAt: importedAt)
    }

    static func parse(text: String, importedAt: Date = Date()) throws -> Result {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !lines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.empty }
        let separator = guessSeparator(lines)
        let rows = records(lines, separator: separator)
        // The header is the first row that names a day and an amount; lines above it describe the account.
        guard let headerIndex = rows.prefix(40).firstIndex(where: { row in
            let folded = row.map(FinanceText.fold)
            let hasDay = folded.contains { cell in Field.day.names.contains(cell) || Field.valueDay.names.contains(cell) || cell.contains("datum") || cell.contains("buchungstag") }
            let hasAmount = folded.contains { cell in Field.amount.names.contains(cell) || cell.hasPrefix("betrag") || cell.hasPrefix("umsatz") || Field.debit.names.contains(cell) }
            return hasDay && hasAmount
        }) else { throw Problem.noHeader }
        let header = rows[headerIndex].map(FinanceText.fold)
        var columns: [Field: Int] = [:]
        var taken = Set<Int>()
        for field in Field.allCases {
            for name in field.names {
                if let index = header.indices.first(where: { !taken.contains($0) && header[$0] == name }) {
                    columns[field] = index
                    taken.insert(index)
                    break
                }
            }
        }
        // Looser second pass: "Betrag (EUR)" as "betrag", "Buchungstag (Datum)" as a day.
        for field in [Field.day, .amount, .counterparty, .purpose, .balance] where columns[field] == nil {
            if let index = header.indices.first(where: { index in !taken.contains(index) && field.names.contains { name in name.count >= 4 && header[index].hasPrefix(name) } }) {
                columns[field] = index
                taken.insert(index)
            }
        }
        if columns[.day] == nil, let value = columns[.valueDay] { columns[.day] = value }
        guard columns[.day] != nil else { throw Problem.noHeader }
        guard columns[.amount] != nil || columns[.debit] != nil || columns[.credit] != nil else { throw Problem.noAmount }

        let body = Array(rows[(headerIndex + 1)...])
        let decimalComma = guessDecimalComma(body, columns: [columns[.amount], columns[.debit], columns[.credit], columns[.balance]].compactMap { $0 })
        func cell(_ row: [String], _ field: Field) -> String {
            guard let index = columns[field], index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var bookings: [FinanceTransaction] = []
        var skipped = 0
        var newest: (day: FinanceDay, cents: Int)?
        let newestFirst = isNewestFirst(body, columns[.day])
        for (order, row) in body.enumerated() {
            guard row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            guard let day = FinanceDay(cell(row, .day)) ?? FinanceDay(cell(row, .valueDay)) else { skipped += 1; continue }
            var cents: Int?
            if columns[.amount] != nil {
                cents = FinanceMoney.cents(cell(row, .amount), decimalComma: decimalComma)
            } else {
                let debit = FinanceMoney.cents(cell(row, .debit), decimalComma: decimalComma).map { -abs($0) }
                let credit = FinanceMoney.cents(cell(row, .credit), decimalComma: decimalComma).map { abs($0) }
                cents = (debit ?? 0) + (credit ?? 0)
                if debit == nil, credit == nil { cents = nil }
            }
            // Volksbank style: the amount is positive and a column says S (Soll) or H (Haben).
            if var value = cents, columns[.sign] != nil {
                let mark = FinanceText.fold(cell(row, .sign))
                if mark.hasPrefix("s") || mark == "debit" { value = -abs(value) } else if mark.hasPrefix("h") || mark == "credit" { value = abs(value) }
                cents = value
            }
            guard let cents, cents != 0 else { skipped += 1; continue }
            let currency = cell(row, .currency)
            var counterparty = clean(cell(row, .counterparty))
            let payer = clean(cell(row, .payer))
            if !payer.isEmpty, cents > 0 || counterparty.isEmpty { counterparty = payer }
            let purpose = clean(cell(row, .purpose))
            let type = clean(cell(row, .type))
            if counterparty.isEmpty { counterparty = named(in: type + " " + purpose) ?? "" }
            var booking = FinanceTransaction(day: day, cents: cents, counterparty: counterparty, purpose: purpose,
                                             type: type, iban: cell(row, .iban).replacingOccurrences(of: " ", with: ""), source: .csv)
            if !currency.isEmpty, currency.uppercased() != "EUR", currency.uppercased() != "€" { booking.note = "Währung: \(currency)" }
            booking.importedAt = importedAt
            booking.createdAt = importedAt.addingTimeInterval(Double(order) / 1000)
            bookings.append(booking)
            if let balance = FinanceMoney.cents(cell(row, .balance), decimalComma: decimalComma) {
                // Banks list the newest first or last; the later day wins, and on one day the row nearest the top
                // when the file is newest first. Without knowing the order, the later row of that day is a guess.
                if newest == nil || day > newest!.day || (day == newest!.day && newestFirst != true) {
                    newest = (day, balance)
                }
            }
        }
        var names: [Field: String] = [:]
        for (field, index) in columns where index < rows[headerIndex].count { names[field] = rows[headerIndex][index] }
        return Result(bookings: bookings, columns: names, skipped: skipped, balance: newest.map { FinanceBalanceAnchor(cents: $0.cents, day: $0.day) }, separator: separator)
    }

    /// comdirect writes counterparty and purpose into one text: "Auftraggeber: Mara Beispiel Buchungstext: Miete".
    private static func named(in text: String) -> String? {
        let pattern = #"(?:Auftraggeber|Empf(?:ä|ae)nger|Zahlungsempf(?:ä|ae)nger|Beg(?:ü|ue)nstigter)\s*:\s*(.+?)(?=\s+(?:Buchungstext|Verwendungszweck|Ref\.|IBAN|BIC|Kto|End-to-End)\b|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Bank texts come padded and with line breaks inside the purpose.
    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isNewestFirst(_ rows: [[String]], _ column: Int?) -> Bool? {
        guard let column else { return nil }
        let days = rows.compactMap { $0.indices.contains(column) ? FinanceDay($0[column]) : nil }
        guard let first = days.first, let last = days.last, first != last else { return nil }
        return first > last
    }

    /// The separator that splits the first lines into the most equal number of columns.
    private static func guessSeparator(_ text: String) -> Character {
        let sample = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(30)
        var best: (Character, Int) = (";", 0)
        for candidate in [";", ",", "\t", "|"] as [Character] {
            let counts = sample.map { line in records(String(line), separator: candidate).first?.count ?? 1 }
            let common = Dictionary(grouping: counts.filter { $0 > 1 }, by: { $0 }).max { $0.value.count < $1.value.count }
            let score = (common?.value.count ?? 0) * (common?.key ?? 0)
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }

    /// Decimal comma or point, by what the amounts of the file mostly end in.
    private static func guessDecimalComma(_ rows: [[String]], columns: [Int]) -> Bool? {
        var comma = 0
        var point = 0
        for row in rows.prefix(200) {
            for index in columns where index < row.count {
                let value = row[index].trimmingCharacters(in: .whitespaces)
                if value.range(of: #",\d{1,2}(\s*(€|EUR))?$"#, options: .regularExpression) != nil { comma += 1 }
                if value.range(of: #"\.\d{1,2}(\s*(€|EUR))?$"#, options: .regularExpression) != nil { point += 1 }
            }
        }
        if comma == 0, point == 0 { return nil }
        return comma >= point
    }

    /// RFC 4180 records: quotes around fields, doubled quotes inside, line breaks inside quotes.
    static func records(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                quoted = true
            } else if character == separator {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
