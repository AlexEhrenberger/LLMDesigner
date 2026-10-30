import Charts
import SwiftUI

/// A chart as Swift Charts draws it, for the editor's preview and for the pictures in the document.
struct WriterChartView: View {
    let chart: WriterChart
    var dark = false
    var family: WriterFont = .serif

    /// The width charts are drawn at; the height follows the chart's format.
    static let width: CGFloat = 640

    private struct Point: Identifiable {
        let id: Int
        let category: String
        let categoryIndex: Int
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var points: [Point] = []
        for (seriesIndex, series) in chart.drawnSeries.enumerated() {
            for (index, category) in chart.categories.enumerated() where index < series.values.count {
                guard let value = series.values[index], value.isFinite else { continue }
                // Round charts have no negative slices.
                if chart.kind.isRound, value <= 0 { continue }
                points.append(Point(id: seriesIndex * 10_000 + index, category: category.isEmpty ? "–" : category, categoryIndex: index,
                                    series: series.name.isEmpty ? "Reihe \(seriesIndex + 1)" : series.name, value: value))
            }
        }
        return points
    }

    private var ink: Color { dark ? Color(nsColor: NSColor(hex: 0xE8E8EC)) : Color(nsColor: NSColor(hex: 0x1C1C1F)) }
    private var faint: Color { dark ? Color.white.opacity(0.13) : Color.black.opacity(0.1) }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(WriterStyler.font(chart.usesDocumentFont ? family : .sans, size: size, weight: weight) as CTFont)
    }

    /// The legend's names and colours: the categories of a round chart, otherwise the series.
    private var scale: (names: [String], colors: [Color]) {
        let names = chart.kind.isRound
            ? chart.categories.enumerated().map { $0.element.isEmpty ? "–" : $0.element }
            : chart.drawnSeries.enumerated().map { $0.element.name.isEmpty ? "Reihe \($0.offset + 1)" : $0.element.name }
        let colors = names.indices.map { Color(nsColor: WriterChartPalette.display(chart.color(at: $0), onDark: dark)) }
        return (names, colors)
    }

    private var legendHidden: Bool {
        switch chart.legend {
        case .hidden: true
        case .automatic: !chart.kind.isRound && chart.drawnSeries.count < 2
        default: false
        }
    }

    private var legendPosition: AnnotationPosition {
        switch chart.legend {
        case .top: .top
        case .trailing: .trailing
        default: .bottom
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chart.title.isEmpty {
                Text(chart.title)
                    .font(font(17, .semibold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if chart.hasValues {
                plot
            } else {
                Text("Noch keine Zahlen")
                    .font(font(13))
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(chart.hasCard ? 22 : 10)
        .background {
            if chart.hasCard {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dark ? Color(nsColor: NSColor(hex: 0x1D1D22)) : .white)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(faint))
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    @ViewBuilder
    private var plot: some View {
        let scale = scale
        let base = Chart(points) { point in
            marks(for: point)
        }
        .chartForegroundStyleScale(domain: scale.names, range: scale.colors)
        .chartLegend(legendHidden ? .hidden : .visible)
        .chartLegend(position: legendPosition, alignment: .center, spacing: 12)
        .foregroundStyle(ink)
        .font(font(11.5))
        if chart.kind.isRound {
            base
        } else {
            base
                .chartXAxis {
                    if chart.kind == .bar {
                        AxisMarks(position: .bottom) { _ in
                            if chart.showsGrid { AxisGridLine().foregroundStyle(faint) }
                            AxisValueLabel().font(font(11)).foregroundStyle(ink.opacity(0.8))
                        }
                    } else {
                        AxisMarks { _ in
                            AxisTick().foregroundStyle(faint)
                            AxisValueLabel().font(font(11)).foregroundStyle(ink.opacity(0.8))
                        }
                    }
                }
                .chartYAxis {
                    if chart.kind == .bar {
                        AxisMarks { _ in AxisValueLabel().font(font(11)).foregroundStyle(ink.opacity(0.8)) }
                    } else {
                        AxisMarks(position: .leading) { _ in
                            if chart.showsGrid { AxisGridLine().foregroundStyle(faint) }
                            AxisValueLabel().font(font(11)).foregroundStyle(ink.opacity(0.8))
                        }
                    }
                }
                .chartXAxisLabel(position: .bottom, alignment: .center) {
                    if !chart.xTitle.isEmpty { Text(chart.xTitle).font(font(12, .medium)).foregroundStyle(ink.opacity(0.85)) }
                }
                .chartYAxisLabel(position: chart.kind == .bar ? .bottom : .leading, alignment: .center) {
                    if !chart.yTitle.isEmpty, chart.kind != .bar { Text(chart.yTitle).font(font(12, .medium)).foregroundStyle(ink.opacity(0.85)) }
                }
                .chartYScale(domain: .automatic(includesZero: chart.startsAtZero || chart.kind != .line && chart.kind != .scatter))
        }
    }

    @ChartContentBuilder
    private func marks(for point: Point) -> some ChartContent {
        switch chart.kind {
        case .column:
            BarMark(x: .value("Kategorie", point.category), y: .value("Wert", point.value))
                .foregroundStyle(by: .value("Reihe", point.series))
                .position(by: .value("Reihe", point.series))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) { valueLabel(point.value) }
        case .stackedColumn:
            BarMark(x: .value("Kategorie", point.category), y: .value("Wert", point.value))
                .foregroundStyle(by: .value("Reihe", point.series))
                .annotation(position: .overlay) { valueLabel(point.value, onColor: true) }
        case .bar:
            BarMark(x: .value("Wert", point.value), y: .value("Kategorie", point.category))
                .foregroundStyle(by: .value("Reihe", point.series))
                .position(by: .value("Reihe", point.series))
                .cornerRadius(3)
                .annotation(position: .trailing, spacing: 4) { valueLabel(point.value) }
        case .line:
            LineMark(x: .value("Kategorie", point.category), y: .value("Wert", point.value))
                .foregroundStyle(by: .value("Reihe", point.series))
                .interpolationMethod(chart.smooth ? .catmullRom : .linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .symbol(by: .value("Reihe", point.series))
                .symbolSize(chart.showsPoints ? 36 : 0)
                .annotation(position: .top, spacing: 4) { valueLabel(point.value) }
        case .area:
            AreaMark(x: .value("Kategorie", point.category), y: .value("Wert", point.value))
                .foregroundStyle(by: .value("Reihe", point.series))
                .interpolationMethod(chart.smooth ? .catmullRom : .linear)
                .opacity(0.85)
        case .pie, .donut:
            SectorMark(angle: .value("Wert", point.value), innerRadius: .ratio(chart.kind == .donut ? 0.56 : 0), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(by: .value("Kategorie", point.category))
                .annotation(position: .overlay) { valueLabel(point.value, onColor: true) }
        case .scatter:
            PointMark(x: .value("x", Double(point.category.replacingOccurrences(of: ",", with: ".")) ?? Double(point.categoryIndex + 1)),
                      y: .value("Wert", point.value))
                .foregroundStyle(by: .value("Reihe", point.series))
                .symbolSize(60)
                .annotation(position: .top, spacing: 3) { valueLabel(point.value) }
        }
    }

    @ViewBuilder
    private func valueLabel(_ value: Double, onColor: Bool = false) -> some View {
        if chart.showsValues {
            Text(chart.label(for: value))
                .font(font(10.5, .medium))
                .foregroundStyle(onColor ? Color.white : ink.opacity(0.85))
        }
    }
}

/// Draws figures for the document: PNGs (two pixels per point) for white paper and the dark sheet, a vector PDF for print.
@MainActor
enum WriterFigureRenderer {
    static func images(of chart: WriterChart, family: WriterFont) -> WriterFigureImages? {
        let size = CGSize(width: WriterChartView.width, height: (WriterChartView.width * chart.aspect.ratio).rounded()
                          + (chart.title.isEmpty ? 0 : 34))
        func view(dark: Bool) -> some View {
            WriterChartView(chart: chart, dark: dark, family: family).frame(width: size.width, height: size.height)
        }
        guard let light = png(view(dark: false), size: size), let dark = png(view(dark: true), size: size),
              let pdf = pdf(view(dark: false), size: size) else { return nil }
        return WriterFigureImages(light: light, dark: dark, pdf: pdf)
    }

    static func png<Content: View>(_ content: Content, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        // 144 dpi: the picture's size in points is the size it was drawn at.
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    static func pdf<Content: View>(_ content: Content, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        let data = NSMutableData()
        var result: Data?
        renderer.render { renderedSize, draw in
            var box = CGRect(origin: .zero, size: renderedSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            result = data as Data
        }
        return result
    }
}
