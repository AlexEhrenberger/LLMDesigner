import AppKit

/// A chart in a Writer Studio document: numbers in categories and series, how they are drawn and styled. It is a
/// picture in the text (`.chart`, light and dark PNG and a PDF for print) with this recipe next to it as JSON. A chart
/// made from a table keeps the table's name (`table`) and follows its numbers.
struct WriterChart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case column, stackedColumn, bar, line, area, pie, donut, scatter

        var id: String { rawValue }

        var label: String {
            switch self {
            case .column: "Säulen"
            case .stackedColumn: "Gestapelt"
            case .bar: "Balken"
            case .line: "Linien"
            case .area: "Flächen"
            case .pie: "Kreis"
            case .donut: "Ring"
            case .scatter: "Punkte"
            }
        }

        var symbol: String {
            switch self {
            case .column: "chart.bar"
            case .stackedColumn: "chart.bar.doc.horizontal"
            case .bar: "chart.bar.xaxis.ascending"
            case .line: "chart.xyaxis.line"
            case .area: "chart.line.uptrend.xyaxis"
            case .pie: "chart.pie"
            case .donut: "circle.dashed"
            case .scatter: "chart.dots.scatter"
            }
        }

        /// Pie and ring show one series, by category.
        var isRound: Bool { self == .pie || self == .donut }
    }

    enum Legend: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, bottom, top, trailing, hidden
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Automatisch"
            case .bottom: "Unten"
            case .top: "Oben"
            case .trailing: "Rechts"
            case .hidden: "Ohne"
            }
        }
    }

    enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
        case wide, classic, square, tall
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wide: "16 : 9"
            case .classic: "4 : 3"
            case .square: "1 : 1"
            case .tall: "3 : 4"
            }
        }
        /// Height per width.
        var ratio: CGFloat {
            switch self {
            case .wide: 9.0 / 16
            case .classic: 3.0 / 4
            case .square: 1
            case .tall: 4.0 / 3
            }
        }
    }

    struct Series: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var values: [Double?]
        /// Its own colour (six hex digits as printed); nil: the palette's.
        var color: String?
    }

    var kind: Kind = .column
    var title = ""
    var categories: [String] = []
    var series: [Series] = []
    var xTitle = ""
    var yTitle = ""
    var palette: WriterChartPalette = .writer
    var legend: Legend = .automatic
    var showsValues = false
    var showsGrid = true
    var smooth = false
    var showsPoints = true
    var startsAtZero = true
    var aspect: Aspect = .classic
    /// Set in the document's font; otherwise in the system's.
    var usesDocumentFont = true
    /// Written after the values ("€", "%").
    var unit = ""
    /// A card behind the chart (white on paper, dark on the dark sheet).
    var hasCard = false
    /// The table the numbers come from (`WriterTableStyle.id`); nil: typed in.
    var table: String?
    /// The table's columns are the categories (instead of its rows).
    var transposed = false

    /// What a new chart shows until the user types their numbers.
    static var sample: WriterChart {
        var chart = WriterChart()
        chart.title = "Umsatz nach Quartal"
        chart.categories = ["Q1", "Q2", "Q3", "Q4"]
        chart.series = [
            Series(name: "2025", values: [12, 15, 14, 19]),
            Series(name: "2026", values: [14, 17, 18, 23]),
        ]
        chart.yTitle = "Mio. €"
        return chart
    }

    /// The series the chart draws: a round chart only its first one.
    var drawnSeries: [Series] { kind.isRound ? Array(series.prefix(1)) : series }

    /// Whether there is anything to draw.
    var hasValues: Bool { drawnSeries.contains { $0.values.contains { $0 != nil } } }

    /// The colour of the n-th series (or, for a round chart, the n-th category), as printed.
    func color(at index: Int) -> String {
        if !kind.isRound, index < series.count, let own = series[index].color { return own }
        return palette.colors[index % palette.colors.count]
    }

    // MARK: From a table

    /// The numbers of a table: its header row names the series, its first column the categories (transposed: the other
    /// way round). Rows that add up other rows (a row of sums) are left out, so they don't tower over the rest.
    mutating func takeData(from cells: [[String]], formulas: [WriterCellPosition: String]) {
        guard let header = cells.first, header.count >= 2, cells.count >= 2 else {
            categories = []
            series = []
            return
        }
        let sumRows = Set(formulas.compactMap { place, formula in
            WriterTableCalc.referencedRows(formula).contains(where: { $0 != place.row }) ? place.row : nil
        })
        let rows = (1..<cells.count).filter { !sumRows.contains($0) }
        let columns = Array(1..<header.count)
        func value(_ row: Int, _ column: Int) -> Double? {
            column < cells[row].count ? WriterTableCalc.number(in: cells[row][column])?.value : nil
        }
        // Keep the colours the user gave to series of the same name.
        let ownColors = Dictionary(series.compactMap { entry in entry.color.map { (entry.name, $0) } }, uniquingKeysWith: { first, _ in first })
        if transposed {
            categories = columns.map { header[$0] }
            series = rows.map { row in
                let name = cells[row].first ?? ""
                return Series(name: name, values: columns.map { value(row, $0) }, color: ownColors[name])
            }
        } else {
            categories = rows.map { cells[$0].first ?? "" }
            series = columns.compactMap { column in
                let values = rows.map { value($0, column) }
                // Columns without any number (notes, names) are no series.
                guard values.contains(where: { $0 != nil }) else { return nil }
                return Series(name: header[column], values: values, color: ownColors[header[column]])
            }
        }
        // The unit the numbers share ("€", "%") goes to the values' labels unless one was chosen.
        if unit.isEmpty {
            let units = Set(rows.flatMap { row in columns.compactMap { column in
                column < cells[row].count ? WriterTableCalc.number(in: cells[row][column])?.unit : nil
            } })
            if units.count == 1, let only = units.first { unit = only }
        }
    }

    // MARK: Numbers as labels

    func label(for value: Double) -> String {
        let style = WriterTableCalc.Number(value: value, decimals: 0, usesComma: true, grouped: abs(value) >= 10_000, unit: unit)
        return WriterTableCalc.format(value, like: style)
    }

    // MARK: Stored

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data?) -> WriterChart? {
        data.flatMap { try? JSONDecoder().decode(WriterChart.self, from: $0) }
    }
}

/// Colour sets for charts. Each colour is the printed one; on the dark sheet charts brighten them.
enum WriterChartPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case writer, ocean, forest, sunset, earth, mono, vivid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .writer: "Writer"
        case .ocean: "Ozean"
        case .forest: "Wald"
        case .sunset: "Abendrot"
        case .earth: "Erde"
        case .mono: "Graustufen"
        case .vivid: "Kräftig"
        }
    }

    var colors: [String] {
        switch self {
        case .writer: ["7B3FC4", "1F5FBF", "148F8F", "1E8449", "B7791F", "D35400", "C0392B", "C2185B"]
        case .ocean: ["0B3C5D", "1F5FBF", "328CC1", "4FB0C6", "8FD3E8", "0E7C86", "1B998B", "7FB7BE"]
        case .forest: ["1E5631", "2E8540", "4C9A2A", "76B041", "A4C639", "556B2F", "8F9779", "C5D86D"]
        case .sunset: ["6A1B9A", "AD1457", "D84315", "EF6C00", "F9A825", "C62828", "8E24AA", "FF7043"]
        case .earth: ["7F5539", "9C6644", "B08968", "DDB892", "6B705C", "A5A58D", "CB997E", "8D6E63"]
        case .mono: ["262626", "4D4D4D", "737373", "999999", "BFBFBF", "595959", "8C8C8C", "D9D9D9"]
        case .vivid: ["4E79A7", "F28E2B", "E15759", "76B7B2", "59A14F", "EDC948", "B07AA1", "FF9DA7"]
        }
    }

    /// A colour as shown on the dark sheet: the Writer colours their bright versions, others lighter.
    static func display(_ hex: String, onDark: Bool) -> NSColor {
        if let color = WriterColors.display(hex, onDark: onDark), !onDark || WriterColors.palette.contains(where: { $0.printHex == hex }) {
            return color
        }
        let base = NSColor(hex: UInt32(hex, radix: 16) ?? 0x7B3FC4)
        guard onDark, let rgb = base.usingColorSpace(.sRGB) else { return base }
        // Dark colours would vanish on the dark sheet: lift them.
        let brightness = max(rgb.brightnessComponent, 0.62)
        return NSColor(hue: rgb.hueComponent, saturation: min(rgb.saturationComponent, 0.75), brightness: min(1, brightness * 1.12), alpha: 1)
    }
}
