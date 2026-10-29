import Foundation

/// A page of the user's own making (`WriterPageFormat.custom`): paper, margins, text size and line spacing. A
/// document carries its own copy (front matter `page:`); the library keeps the ones saved as templates, so they can
/// be chosen for other documents.
struct WriterPageSetup: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = "Eigenes Format"
    /// The sheet in millimetres.
    var paperWidth: Double = 210
    var paperHeight: Double = 297
    /// From the sheet's edges to the text, in millimetres.
    var top: Double = 25
    var bottom: Double = 25
    var left: Double = 25
    var right: Double = 25
    /// The text size in points of print.
    var fontSize: Double = 11
    /// Times LaTeX's normal distance of the lines.
    var lineSpacing: Double = 1

    static let fontSizes: [Double] = [9, 10, 11, 12]
    static let marginRange: ClosedRange<Double> = 5...80
    static let paperRange: ClosedRange<Double> = 70...600

    /// Paper sizes to start from.
    struct Paper: Identifiable, Hashable {
        let name: String
        let width: Double
        let height: Double
        var id: String { name }
    }

    static let papers: [Paper] = [
        Paper(name: "DIN A4", width: 210, height: 297),
        Paper(name: "DIN A5", width: 148, height: 210),
        Paper(name: "DIN A6", width: 105, height: 148),
        Paper(name: "DIN B5", width: 176, height: 250),
        Paper(name: "US Letter", width: 215.9, height: 279.4),
        Paper(name: "US Legal", width: 215.9, height: 355.6),
        Paper(name: "Taschenbuch", width: 125, height: 190),
        Paper(name: "Großes Taschenbuch", width: 135, height: 215),
        Paper(name: "Quadrat 21 cm", width: 210, height: 210),
    ]

    /// The paper this sheet is (turned or not); nil for a size of its own.
    var paper: Paper? {
        Self.papers.first { (abs($0.width - paperWidth) < 0.6 && abs($0.height - paperHeight) < 0.6)
            || (abs($0.height - paperWidth) < 0.6 && abs($0.width - paperHeight) < 0.6) }
    }

    var isLandscape: Bool { paperWidth > paperHeight }

    /// The text block in points of print.
    var textWidth: CGFloat { CGFloat(paperWidth - left - right) * WriterPageFormat.pointsPerMillimetre }
    var textHeight: CGFloat { CGFloat(paperHeight - top - bottom) * WriterPageFormat.pointsPerMillimetre }
    /// The sheet in points of print.
    var paperSize: CGSize {
        CGSize(width: CGFloat(paperWidth) * WriterPageFormat.pointsPerMillimetre, height: CGFloat(paperHeight) * WriterPageFormat.pointsPerMillimetre)
    }

    /// Margins that leave at least 4 cm of text each way, sizes in their ranges.
    func normalized() -> WriterPageSetup {
        var setup = self
        setup.paperWidth = min(max(paperWidth, Self.paperRange.lowerBound), Self.paperRange.upperBound)
        setup.paperHeight = min(max(paperHeight, Self.paperRange.lowerBound), Self.paperRange.upperBound)
        for keyPath in [\WriterPageSetup.top, \.bottom, \.left, \.right] {
            setup[keyPath: keyPath] = min(max(setup[keyPath: keyPath], Self.marginRange.lowerBound), Self.marginRange.upperBound)
        }
        func fit(_ size: Double, _ a: WritableKeyPath<WriterPageSetup, Double>, _ b: WritableKeyPath<WriterPageSetup, Double>) {
            let room = size - setup[keyPath: a] - setup[keyPath: b]
            guard room < 40 else { return }
            let scale = max(0, size - 40) / max(1, setup[keyPath: a] + setup[keyPath: b])
            setup[keyPath: a] *= scale
            setup[keyPath: b] *= scale
        }
        fit(setup.paperWidth, \.left, \.right)
        fit(setup.paperHeight, \.top, \.bottom)
        setup.fontSize = min(max(fontSize, 8), 14)
        setup.lineSpacing = min(max(lineSpacing, 0.8), 3)
        return setup
    }

    /// "DIN A4 · 2,5 cm Rand · 11 pt": what the format is, for menus.
    var summary: String {
        let paperName = paper.map { $0.name + (isLandscape ? " quer" : "") } ?? "\(Self.mm(paperWidth)) × \(Self.mm(paperHeight)) mm"
        let margins = Set([top, bottom, left, right]).count == 1
            ? WriterParagraphFormat.label(cm: top / 10) + " Rand"
            : "Ränder \(Self.mm(top))/\(Self.mm(right))/\(Self.mm(bottom))/\(Self.mm(left)) mm"
        var parts = [paperName, margins, "\(WriterSpanStyle.format(fontSize)) pt"]
        if abs(lineSpacing - 1) > 0.001 { parts.append("Zeilen × " + WriterParagraphFormat.number(lineSpacing).replacingOccurrences(of: ".", with: ",")) }
        return parts.joined(separator: " · ")
    }

    static func mm(_ value: Double) -> String {
        WriterParagraphFormat.number((value * 10).rounded() / 10).replacingOccurrences(of: ".", with: ",")
    }

    /// The setup a built-in format starts from when the user adjusts it.
    static func starting(from format: WriterPageFormat, paper: PaperSize, current: WriterPageSetup?) -> WriterPageSetup {
        switch format {
        case .custom:
            return current ?? WriterPageSetup()
        case .paperback:
            return WriterPageSetup(name: "Taschenbuch (angepasst)", paperWidth: 125, paperHeight: 190, top: 16, bottom: 19, left: 15, right: 15, fontSize: 10, lineSpacing: 1.05)
        case .manuscript:
            return WriterPageSetup(name: "Manuskript", paperWidth: 210, paperHeight: 297, top: 25, bottom: 25, left: 25, right: 30, fontSize: 12, lineSpacing: 1.5)
        case .standard:
            switch paper {
            case .a4: return WriterPageSetup(name: "DIN A4 (angepasst)")
            case .a5: return WriterPageSetup(name: "DIN A5 (angepasst)", paperWidth: 148, paperHeight: 210, top: 18, bottom: 18, left: 18, right: 18)
            case .letter: return WriterPageSetup(name: "US Letter (angepasst)", paperWidth: 215.9, paperHeight: 279.4, top: 25.4, bottom: 25.4, left: 25.4, right: 25.4)
            }
        }
    }

    // MARK: LaTeX

    /// The `geometry` options. The running heads sit in the margins: the head a little above the text, the foot
    /// below it, each at most as far as half its margin.
    var geometry: String {
        let format = { (value: Double) in WriterPageFormat.format(CGFloat(value)) }
        let headSep = min(top * 0.4, 9)
        let footSkip = min(bottom * 0.55, 13)
        return "paperwidth=\(format(paperWidth))mm,paperheight=\(format(paperHeight))mm,top=\(format(top))mm,bottom=\(format(bottom))mm,"
            + "left=\(format(left))mm,right=\(format(right))mm,headheight=14pt,headsep=\(format(headSep))mm,footskip=\(format(footSkip))mm"
    }
}

/// The lines at the top and the bottom of every printed page, each in three places. Placeholders stand for what
/// changes: `{Seite}`, `{Seiten}`, `{Titel}`, `{Kapitel}`, `{Datum}`. A document keeps them in its front matter
/// (`running:`); without them the page number sits in the middle of the foot, as before.
struct WriterRunningHeads: Codable, Hashable, Sendable {
    struct Line: Codable, Hashable, Sendable {
        var left = ""
        var center = ""
        var right = ""

        var isEmpty: Bool { [left, center, right].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    var header = Line()
    var footer = Line()
    /// The first page goes without head and foot (a title page).
    var skipsFirstPage = false
    /// A thin line under the head and above the foot.
    var hasRules = false

    var isEmpty: Bool { header.isEmpty && footer.isEmpty }

    static let placeholders: [(token: String, label: String)] = [
        ("{Seite}", "Seitenzahl"), ("{Seiten}", "Seitenanzahl"), ("{Titel}", "Titel"), ("{Kapitel}", "Kapitel"), ("{Datum}", "Datum"),
    ]

    var usesChapter: Bool {
        [header.left, header.center, header.right, footer.left, footer.center, footer.right].contains { $0.contains("{Kapitel}") }
    }

    /// The text with its placeholders filled in, as the editor shows it.
    static func resolve(_ text: String, page: Int, pages: Int?, title: String, chapter: String, date: Date = Date()) -> String {
        text.replacingOccurrences(of: "{Seite}", with: String(page))
            .replacingOccurrences(of: "{Seiten}", with: pages.map(String.init) ?? "–")
            .replacingOccurrences(of: "{Titel}", with: title)
            .replacingOccurrences(of: "{Kapitel}", with: chapter)
            .replacingOccurrences(of: "{Datum}", with: date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "de_DE"))))
    }

    /// Ready-made heads and feet to start from.
    static let presets: [(label: String, heads: WriterRunningHeads)] = [
        ("Seitenzahl unten Mitte", WriterRunningHeads(footer: Line(center: "{Seite}"))),
        ("Seite x von y unten rechts", WriterRunningHeads(footer: Line(right: "Seite {Seite} von {Seiten}"))),
        ("Titel oben, Seitenzahl unten", WriterRunningHeads(header: Line(center: "{Titel}"), footer: Line(center: "{Seite}"), hasRules: false)),
        ("Kapitel oben links, Seite oben rechts", WriterRunningHeads(header: Line(left: "{Kapitel}", right: "{Seite}"), hasRules: true)),
        ("Titel und Datum unten", WriterRunningHeads(footer: Line(left: "{Titel}", right: "{Datum}"))),
    ]

    // MARK: LaTeX

    /// The fancyhdr setup: the six places and the rules, on every page or from the second on. Chapter pages (the
    /// plain style) get the same.
    func latexSetup(title: String) -> String {
        func place(_ text: String) -> String {
            var output = LaTeXWriter.escape(text)
            for (token, command) in [("{Seite}", "\\thepage{}"), ("{Seiten}", "\\pageref*{LastPage}"), ("{Kapitel}", "\\leftmark{}"),
                                     ("{Datum}", "\\today{}"), ("{Titel}", LaTeXWriter.escape(title))] {
                output = output.replacingOccurrences(of: LaTeXWriter.escape(token), with: command)
            }
            guard !output.isEmpty else { return "" }
            return skipsFirstPage ? "\\ifnum\\value{page}>1 \(output)\\fi" : output
        }
        func rule(_ shown: Bool) -> String {
            guard shown else { return "0pt" }
            return skipsFirstPage ? "\\ifnum\\value{page}>1 0.4pt\\else 0pt\\fi" : "0.4pt"
        }
        let definitions = [
            "\\fancyhf{}",
            "\\fancyhead[L]{\(place(header.left))}", "\\fancyhead[C]{\(place(header.center))}", "\\fancyhead[R]{\(place(header.right))}",
            "\\fancyfoot[L]{\(place(footer.left))}", "\\fancyfoot[C]{\(place(footer.center))}", "\\fancyfoot[R]{\(place(footer.right))}",
            "\\renewcommand{\\headrulewidth}{\(rule(hasRules && !header.isEmpty))}",
            "\\renewcommand{\\footrulewidth}{\(rule(hasRules && !footer.isEmpty))}",
        ].joined()
        return definitions + "\n\\fancypagestyle{plain}{" + definitions + "}\n"
    }
}

