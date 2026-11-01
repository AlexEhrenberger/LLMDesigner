import SwiftUI

/// The state of the chart editor: the chart, and while it is typed in, its numbers as text.
@MainActor
@Observable
final class ChartEditorModel {
    var chart: WriterChart
    /// Header row (series names after an empty corner) and rows (category, values), as typed.
    var grid: [[String]]
    var caption: String
    var previewDark = true
    let isExisting: Bool
    let family: WriterFont

    init(request: WriterFigureRequest) {
        chart = request.chart
        caption = request.reference?.caption ?? ""
        isExisting = request.isExisting
        family = request.family
        grid = Self.grid(of: request.chart)
    }

    var isLinked: Bool { chart.table != nil }

    static func grid(of chart: WriterChart) -> [[String]] {
        var grid = [[""] + chart.series.map(\.name)]
        for (index, category) in chart.categories.enumerated() {
            grid.append([category] + chart.series.map { series in
                index < series.values.count ? series.values[index].map { WriterTableCalc.format($0, like: WriterTableCalc.Number(value: $0, decimals: Self.decimals($0), usesComma: true)) } ?? "" : ""
            })
        }
        return grid
    }

    private static func decimals(_ value: Double) -> Int {
        var decimals = 0
        while decimals < 4, abs(value * pow(10, Double(decimals)) - (value * pow(10, Double(decimals))).rounded()) > 1e-9 { decimals += 1 }
        return decimals
    }

    /// The typed numbers into the chart.
    func gridChanged() {
        guard !isLinked, let header = grid.first else { return }
        let old = chart.series
        chart.categories = grid.dropFirst().map { $0.first ?? "" }
        chart.series = (1..<max(1, header.count)).map { column in
            let values = grid.dropFirst().map { row in column < row.count ? WriterTableCalc.number(in: row[column])?.value : nil }
            let color = column - 1 < old.count ? old[column - 1].color : nil
            return WriterChart.Series(name: header[column], values: values, color: color)
        }
    }

    func cell(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self, row < self.grid.count, column < self.grid[row].count else { return "" }
                return self.grid[row][column]
            },
            set: { [weak self] value in
                guard let self, row < self.grid.count else { return }
                while self.grid[row].count <= column { self.grid[row].append("") }
                self.grid[row][column] = value
                self.gridChanged()
            }
        )
    }

    func addRow() {
        let columns = grid.first?.count ?? 2
        grid.append(["Neu"] + Array(repeating: "", count: max(1, columns - 1)))
        gridChanged()
    }

    func addSeries() {
        for row in grid.indices { grid[row].append(row == 0 ? "Reihe \(grid[0].count)" : "") }
        gridChanged()
    }

    func removeRow(_ row: Int) {
        guard row > 0, row < grid.count, grid.count > 2 else { return }
        grid.remove(at: row)
        gridChanged()
    }

    func removeSeries(_ column: Int) {
        guard column > 0, (grid.first?.count ?? 0) > 2 else { return }
        for row in grid.indices where column < grid[row].count { grid[row].remove(at: column) }
        gridChanged()
    }

    /// Rows of tab-, semicolon- or comma-separated numbers from the clipboard (e.g. copied from a spreadsheet).
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return }
        let separator: Character = text.contains("\t") ? "\t" : text.contains(";") ? ";" : ","
        let rows = lines.map { $0.split(separator: separator, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        let width = rows.map(\.count).max() ?? 2
        grid = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        gridChanged()
    }

    /// The chart's own colour for a series, or the palette's.
    func color(of index: Int) -> Binding<Color> {
        Binding(
            get: { [weak self] in
                guard let self else { return .gray }
                return Color(nsColor: WriterChartPalette.display(self.chart.color(at: index), onDark: false))
            },
            set: { [weak self] color in
                guard let self, index < self.chart.series.count, let hex = WriterColors.hex(of: NSColor(color)) else { return }
                self.chart.series[index].color = hex
            }
        )
    }
}

/// Makes or edits a chart: its kind, title, axes, colours, legend and numbers, with a preview on the dark sheet or on
/// white paper. A chart of a table takes the table's numbers and follows them.
struct ChartEditorSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model: ChartEditorModel
    let onCommit: (_ images: WriterFigureImages, _ recipe: Data, _ caption: String, _ linkedTable: String?) -> Void
    let onCancel: () -> Void

    init(request: WriterFigureRequest, onCommit: @escaping (WriterFigureImages, Data, String, String?) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: ChartEditorModel(request: request))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FigureSheetHeader(symbol: "chart.bar.xaxis", title: model.isExisting ? "Diagramm bearbeiten" : "Neues Diagramm") {
                Picker("", selection: $model.previewDark) {
                    Text("Dunkles Blatt").tag(true)
                    Text("Weißes Papier").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("So sieht das Diagramm auf dem dunklen Blatt und auf weißem Papier (und im Druck) aus")
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    preview
                    data
                }
                .frame(width: 560)
                ScrollView {
                    settings
                        .padding(.trailing, 8)
                }
                .frame(width: 320)
            }
            FigureSheetFooter(
                hint: model.isLinked ? "Das Diagramm folgt der Tabelle: ändern sich ihre Zahlen, zeichnet es sich neu." : "Doppelklick auf das Diagramm öffnet diesen Editor wieder.",
                commitTitle: model.isExisting ? "Übernehmen" : "Einfügen",
                canCommit: model.chart.hasValues,
                onCancel: onCancel,
                onCommit: commit
            )
        }
        .padding(20)
        .frame(width: 940, height: 680)
        .background(Theme.surface)
        // In the light design the sheet is always white.
        .onAppear { if colorScheme == .light { model.previewDark = false } }
    }

    private var preview: some View {
        let height = min(330, 560 * model.chart.aspect.ratio + (model.chart.title.isEmpty ? 0 : 30))
        return WriterChartView(chart: model.chart, dark: model.previewDark, family: model.family)
            .frame(width: 540, height: height)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(model.previewDark ? Color(nsColor: WriterPalette.dark.page) : .white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
            .animation(.easeInOut(duration: 0.25), value: model.chart)
    }

    @ViewBuilder
    private var data: some View {
        if model.isLinked {
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Zahlen aus der Tabelle", detail: "\(model.chart.categories.count) Kategorien · \(model.chart.series.count) Reihen")
                Text("Die erste Zeile der Tabelle benennt die Reihen, die erste Spalte die Kategorien. Zeilen mit Summen über andere bleiben draußen.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Toggle("Zeilen und Spalten tauschen", isOn: Binding(get: { model.chart.transposed }, set: { value in
                        model.chart.transposed = value
                        // The numbers come anew from the table when the chart is inserted; here they are swapped at once.
                        model.chart = Self.swapped(model.chart)
                    }))
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Verknüpfung lösen") {
                        model.chart.table = nil
                        model.grid = ChartEditorModel.grid(of: model.chart)
                    }
                    .help("Das Diagramm behält die Zahlen von jetzt und folgt der Tabelle nicht mehr; dann lassen sie sich hier ändern")
                }
                .font(.system(size: 12))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.03)))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    FigureSectionTitle("Zahlen", detail: "erste Zeile: Reihen · erste Spalte: Kategorien")
                    Spacer()
                    Button("Aus Zwischenablage", systemImage: "doc.on.clipboard") { model.paste() }
                        .controlSize(.small)
                        .help("Zeilen aus einer Tabellenkalkulation oder mit ; getrennt einfügen")
                }
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(model.grid.indices, id: \.self) { row in
                            GridRow {
                                ForEach(0..<(model.grid.first?.count ?? 1), id: \.self) { column in
                                    if row == 0, column == 0 {
                                        Text("").frame(width: 110)
                                    } else {
                                        TextField(row == 0 ? "Reihe" : column == 0 ? "Kategorie" : "–", text: model.cell(row, column))
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12, weight: row == 0 || column == 0 ? .semibold : .regular).monospacedDigit())
                                            .multilineTextAlignment(column == 0 ? .leading : .trailing)
                                            .padding(.horizontal, 6)
                                            .frame(width: column == 0 ? 110 : 76, height: 24)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(row == 0 || column == 0 ? 0.07 : 0.035)))
                                            .contextMenu {
                                                if row > 0 { Button("Zeile löschen") { model.removeRow(row) } }
                                                if column > 0 { Button("Reihe löschen") { model.removeSeries(column) } }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 190)
                HStack(spacing: 8) {
                    Button("Zeile", systemImage: "plus") { model.addRow() }
                    Button("Reihe", systemImage: "plus") { model.addSeries() }
                    Text("Rechtsklick auf ein Feld löscht Zeile oder Reihe.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .controlSize(.small)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Art")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(WriterChart.Kind.allCases) { kind in
                        FigureChip(title: kind.label, symbol: kind.symbol, isSelected: model.chart.kind == kind) { model.chart.kind = kind }
                    }
                }
                if model.chart.kind.isRound, model.chart.series.count > 1 {
                    Text("Kreis und Ring zeigen nur die erste Reihe.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Beschriftung")
                FigureField(placeholder: "Titel (im Bild)", text: $model.chart.title)
                if !model.chart.kind.isRound {
                    HStack(spacing: 6) {
                        FigureField(placeholder: "x-Achse", text: $model.chart.xTitle)
                        FigureField(placeholder: "y-Achse", text: $model.chart.yTitle)
                    }
                }
                HStack(spacing: 6) {
                    FigureField(placeholder: "Einheit (€, %)", text: $model.chart.unit)
                    FigureField(placeholder: "Bildunterschrift", text: $model.caption)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Farben")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(WriterChartPalette.allCases) { palette in
                        Button {
                            model.chart.palette = palette
                            for index in model.chart.series.indices { model.chart.series[index].color = nil }
                        } label: {
                            HStack(spacing: 2) {
                                ForEach(palette.colors.prefix(5), id: \.self) { hex in
                                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: UInt32(hex, radix: 16) ?? 0))).frame(width: 9, height: 14)
                                }
                                Text(palette.label).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).padding(.leading, 4)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(model.chart.palette == palette ? 0.1 : 0.03)))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.chart.palette == palette ? Theme.accent.opacity(0.6) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !model.chart.kind.isRound, !model.chart.series.isEmpty {
                    ForEach(model.chart.series.indices, id: \.self) { index in
                        HStack {
                            ColorPicker(selection: model.color(of: index), supportsOpacity: false) {
                                Text(model.chart.series[index].name.isEmpty ? "Reihe \(index + 1)" : model.chart.series[index].name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Legende")
                Picker("", selection: $model.chart.legend) {
                    ForEach(WriterChart.Legend.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                FigureSectionTitle("Darstellung")
                Toggle("Werte an den Säulen und Punkten", isOn: $model.chart.showsValues)
                if !model.chart.kind.isRound {
                    Toggle("Gitternetzlinien", isOn: $model.chart.showsGrid)
                }
                if model.chart.kind == .line || model.chart.kind == .area {
                    Toggle("Geschwungene Linien", isOn: $model.chart.smooth)
                }
                if model.chart.kind == .line {
                    Toggle("Punkte auf den Linien", isOn: $model.chart.showsPoints)
                }
                if model.chart.kind == .line || model.chart.kind == .scatter {
                    Toggle("Achse beginnt bei null", isOn: $model.chart.startsAtZero)
                }
                Toggle("Karte hinter dem Diagramm", isOn: $model.chart.hasCard)
                Toggle("In der Schrift des Dokuments", isOn: $model.chart.usesDocumentFont)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 8) {
                FigureSectionTitle("Format")
                Picker("", selection: $model.chart.aspect) {
                    ForEach(WriterChart.Aspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    /// The chart with rows and columns swapped (for the preview; inserted, it takes the table's numbers anew).
    private static func swapped(_ chart: WriterChart) -> WriterChart {
        var result = chart
        result.categories = chart.series.map(\.name)
        result.series = chart.categories.enumerated().map { index, category in
            WriterChart.Series(name: category, values: chart.series.map { index < $0.values.count ? $0.values[index] : nil })
        }
        return result
    }

    private func commit() {
        guard let images = WriterFigureRenderer.images(of: model.chart, family: model.family) else { return }
        onCommit(images, model.chart.json, model.caption.trimmingCharacters(in: .whitespacesAndNewlines), model.chart.table)
    }
}
