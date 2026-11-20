import AppKit

/// A statement of the account for a stretch of days: the balance before, every booking with the balance after it,
/// and the balance at the end.
struct FinanceStatement: Sendable {
    struct Row: Sendable {
        var day: FinanceDay
        var name: String
        var purpose: String
        var category: String
        var cents: Int
        var balance: Int
    }

    var account: FinanceAccount
    var from: FinanceDay
    var to: FinanceDay
    var opening: Int
    var closing: Int
    var credits = 0
    var debits = 0
    var rows: [Row] = []

    static func make(_ analysis: FinanceAnalysis, from: FinanceDay, to: FinanceDay) -> FinanceStatement {
        var statement = FinanceStatement(account: analysis.state.account, from: from, to: to,
                                         opening: analysis.balance(at: from.adding(days: -1)), closing: analysis.balance(at: to))
        for entry in analysis.entries(from: from, to: to) {
            let booking = entry.booking
            if booking.cents > 0 { statement.credits += booking.cents } else { statement.debits += booking.cents }
            let name = analysis.groups[entry.group]?.name ?? booking.displayName
            let purpose = [booking.counterparty == name ? "" : booking.counterparty, booking.type, booking.purpose].filter { !$0.isEmpty }.joined(separator: " · ")
            statement.rows.append(Row(day: booking.day, name: name, purpose: purpose, category: analysis.state.category(entry.category)?.name ?? "",
                                      cents: booking.cents, balance: entry.balanceAfter))
        }
        return statement
    }

    var fileName: String { "Kontoauszug \(account.name) \(from.iso) bis \(to.iso)" }
}

/// Draws a statement onto A4 pages with Core Graphics: no LaTeX needed, and the layout is the same on every Mac.
enum FinanceStatementPDF {
    private static let page = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 46
    private static let footerHeight: CGFloat = 30

    private struct Column {
        var x: CGFloat
        var width: CGFloat
        var alignment: NSTextAlignment = .left
    }

    private static var contentWidth: CGFloat { page.width - 2 * margin }
    private static var columns: [Column] {
        let x = margin
        return [
            Column(x: x, width: 58),
            Column(x: x + 62, width: 236),
            Column(x: x + 302, width: 78),
            Column(x: x + 384, width: 60, alignment: .right),
            Column(x: x + 448, width: contentWidth - 448, alignment: .right),
        ]
    }

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, digits: Bool = false) -> NSFont {
        digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static let ink = NSColor(calibratedWhite: 0.08, alpha: 1)
    private static let secondary = NSColor(calibratedWhite: 0.38, alpha: 1)
    private static let rule = NSColor(calibratedWhite: 0.82, alpha: 1)
    private static let band = NSColor(calibratedWhite: 0.955, alpha: 1)

    private static func text(_ string: String, _ font: NSFont, _ color: NSColor = ink, alignment: NSTextAlignment = .left, truncate: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func height(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private static func draw(_ string: NSAttributedString, in rect: CGRect) {
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }

    private static func money(_ cents: Int, _ currency: String) -> String { FinanceMoney.format(cents, currency: currency) }

    @MainActor
    static func render(_ statement: FinanceStatement, created: Date = Date()) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: statement.fileName, kCGPDFContextCreator as String: "LLM Designer"] as CFDictionary)
        else { return Data() }
        let currency = statement.account.currency

        // Rows with their heights first, so the pages can be counted for the footer.
        struct Line { var row: FinanceStatement.Row; var name: NSAttributedString; var purpose: NSAttributedString?; var height: CGFloat }
        let lines: [Line] = statement.rows.map { row in
            let name = text(row.name, font(8.5, .medium), truncate: true)
            let purpose = row.purpose.isEmpty ? nil : text(String(row.purpose.prefix(220)), font(7.2), secondary)
            let purposeHeight = purpose.map { min(height($0, width: columns[1].width), 27) } ?? 0
            return Line(row: row, name: name, purpose: purpose, height: max(16, 11 + purposeHeight + 6))
        }
        let firstTop: CGFloat = 248
        let laterTop: CGFloat = 96
        let bottom = page.height - margin - footerHeight
        var pages: [[Line]] = [[]]
        var y = firstTop
        for line in lines {
            if y + line.height > bottom {
                pages.append([])
                y = laterTop
            }
            pages[pages.count - 1].append(line)
            y += line.height
        }

        for (pageIndex, pageLines) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics

            var top: CGFloat
            if pageIndex == 0 {
                top = drawHeader(statement, created: created, currency: currency)
            } else {
                draw(text("Kontoauszug \(statement.account.name) · \(statement.from.german) – \(statement.to.german)", font(9, .semibold)), in: CGRect(x: margin, y: margin, width: contentWidth, height: 14))
                top = laterTop - 26
            }
            top = drawTableHeader(at: top)
            for (index, line) in pageLines.enumerated() {
                if index % 2 == 1 {
                    band.setFill()
                    CGRect(x: margin - 4, y: top, width: contentWidth + 8, height: line.height).fill()
                }
                let row = line.row
                draw(text(row.day.german, font(8, digits: true), secondary), in: CGRect(x: columns[0].x, y: top + 4, width: columns[0].width, height: 11))
                draw(line.name, in: CGRect(x: columns[1].x, y: top + 3, width: columns[1].width, height: 12))
                if let purpose = line.purpose {
                    draw(purpose, in: CGRect(x: columns[1].x, y: top + 14, width: columns[1].width, height: line.height - 17))
                }
                draw(text(row.category, font(7.5), secondary, truncate: true), in: CGRect(x: columns[2].x, y: top + 4, width: columns[2].width, height: 11))
                draw(text(FinanceMoney.format(row.cents, currency: currency, sign: true), font(8.5, .medium, digits: true), alignment: .right), in: CGRect(x: columns[3].x - 20, y: top + 3, width: columns[3].width + 20, height: 12))
                draw(text(money(row.balance, currency), font(8, digits: true), secondary, alignment: .right), in: CGRect(x: columns[4].x, y: top + 4, width: columns[4].width, height: 11))
                top += line.height
            }
            if pageIndex == pages.count - 1 {
                rule.setFill()
                CGRect(x: margin, y: top + 4, width: contentWidth, height: 0.8).fill()
                draw(text("Endsaldo am \(statement.to.german)", font(9, .semibold)), in: CGRect(x: columns[1].x, y: top + 10, width: 260, height: 14))
                draw(text(money(statement.closing, currency), font(9.5, .bold, digits: true), alignment: .right), in: CGRect(x: columns[3].x, y: top + 10, width: page.width - margin - columns[3].x, height: 14))
                if statement.rows.isEmpty {
                    draw(text("In diesem Zeitraum gibt es keine Buchungen.", font(9), secondary), in: CGRect(x: margin, y: top + 34, width: contentWidth, height: 14))
                }
            }
            drawFooter(page: pageIndex + 1, of: pages.count, created: created)

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Title, account and the four sums; returns where the table begins.
    @MainActor
    private static func drawHeader(_ statement: FinanceStatement, created: Date, currency: String) -> CGFloat {
        let account = statement.account
        draw(text("Kontoauszug", font(22, .bold)), in: CGRect(x: margin, y: margin, width: contentWidth, height: 28))
        draw(text("\(statement.from.german) – \(statement.to.german)", font(11, .medium), secondary), in: CGRect(x: margin, y: margin + 30, width: contentWidth, height: 16))
        var details = [account.name]
        if !account.holder.isEmpty { details.append(account.holder) }
        if !account.bank.isEmpty { details.append(account.bank) }
        if !account.iban.isEmpty { details.append("IBAN \(formattedIBAN(account.iban))") }
        draw(text(details.joined(separator: "  ·  "), font(9), secondary), in: CGRect(x: margin, y: margin + 50, width: contentWidth, height: 14))

        let boxTop = margin + 78
        let boxHeight: CGFloat = 58
        band.setFill()
        NSBezierPath(roundedRect: CGRect(x: margin, y: boxTop, width: contentWidth, height: boxHeight), xRadius: 6, yRadius: 6).fill()
        let sums: [(String, Int)] = [
            ("Anfangssaldo \(statement.from.adding(days: -1).german)", statement.opening),
            ("Gutschriften", statement.credits),
            ("Belastungen", statement.debits),
            ("Endsaldo \(statement.to.german)", statement.closing),
        ]
        let width = contentWidth / CGFloat(sums.count)
        for (index, sum) in sums.enumerated() {
            let x = margin + CGFloat(index) * width + 12
            draw(text(sum.0, font(7.5, .medium), secondary, truncate: true), in: CGRect(x: x, y: boxTop + 11, width: width - 20, height: 11))
            draw(text(FinanceMoney.format(sum.1, currency: currency, sign: index == 1), font(12.5, .semibold, digits: true)), in: CGRect(x: x, y: boxTop + 27, width: width - 16, height: 18))
        }
        let count = statement.rows.count
        draw(text("\(count) \(count == 1 ? "Buchung" : "Buchungen")", font(8.5), secondary), in: CGRect(x: margin, y: boxTop + boxHeight + 14, width: contentWidth, height: 12))
        return boxTop + boxHeight + 34
    }

    private static func drawTableHeader(at top: CGFloat) -> CGFloat {
        let titles = ["Datum", "Empfänger / Auftraggeber · Verwendungszweck", "Kategorie", "Betrag", "Saldo"]
        for (column, title) in zip(columns, titles) {
            draw(text(title, font(7.5, .semibold), secondary, alignment: column.alignment), in: CGRect(x: column.x, y: top, width: column.width, height: 11))
        }
        rule.setFill()
        CGRect(x: margin, y: top + 14, width: contentWidth, height: 0.8).fill()
        return top + 18
    }

    private static func drawFooter(page number: Int, of total: Int, created: Date) {
        let y = page.height - margin - 12
        rule.setFill()
        CGRect(x: margin, y: y - 8, width: contentWidth, height: 0.5).fill()
        let made = "Erstellt am \(FinanceDay(created).german) aus den Buchungen in LLM Designer – kein Dokument der Bank"
        draw(text(made, font(7), secondary), in: CGRect(x: margin, y: y, width: contentWidth - 80, height: 10))
        draw(text("Seite \(number) von \(total)", font(7), secondary, alignment: .right), in: CGRect(x: page.width - margin - 80, y: y, width: 80, height: 10))
    }

    static func formattedIBAN(_ iban: String) -> String {
        let compact = iban.replacingOccurrences(of: " ", with: "").uppercased()
        return stride(from: 0, to: compact.count, by: 4).map { offset -> String in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }
}
