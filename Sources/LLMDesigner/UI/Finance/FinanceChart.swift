import Charts
import SwiftUI

enum FinanceChartMode: String, CaseIterable, Identifiable {
    case flow, balance

    var id: String { rawValue }
    var title: String { self == .flow ? "Einnahmen & Ausgaben" : "Kontostand" }
    var symbol: String { self == .flow ? "chart.bar.xaxis" : "chart.line.uptrend.xyaxis" }
}

/// The course of income and expenses (bars above and below one baseline) or of the balance (one line), around the
/// period the table shows. The period's own bar stands out; a click on another bar shows that one in the table.
struct FinanceChartCard: View {
    @Environment(AppModel.self) private var app
    let buckets: [FinanceBucket]
    let selected: FinancePeriod
    @Binding var mode: FinanceChartMode
    let choose: (FinanceBucket) -> Void
    @State private var hovered: FinanceDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(mode.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if mode == .flow {
                    legendItem("Einnahmen", FinanceColors.income)
                    legendItem("Ausgaben", FinanceColors.expense)
                }
                Spacer(minLength: 0)
                StudioTabPicker(tabs: FinanceChartMode.allCases, selection: $mode, title: { $0 == .flow ? "Verlauf" : "Kontostand" }, symbol: \.symbol)
            }
            if buckets.allSatisfy({ $0.income == 0 && $0.expenses == 0 }) && mode == .flow {
                Text("In diesem Zeitraum gibt es keine Buchungen.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart
                    .frame(height: 170)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func isSelected(_ bucket: FinanceBucket) -> Bool {
        guard let range = selected.range else { return true }
        return range.contains(bucket.start) || (bucket.start...bucket.end).contains(range.lowerBound)
    }

    private var chart: some View {
        let hidden = app.finance.state.hidesAmounts
        return Chart {
            ForEach(buckets) { bucket in
                let emphasis = isSelected(bucket) || hovered == bucket.start ? 1.0 : 0.45
                switch mode {
                case .flow:
                    BarMark(x: .value("Zeitraum", bucket.label), y: .value("Einnahmen", FinanceMoney.euros(bucket.income)), width: .fixed(barWidth))
                        .foregroundStyle(FinanceColors.income)
                        .cornerRadius(3)
                        .opacity(emphasis)
                    BarMark(x: .value("Zeitraum", bucket.label), y: .value("Ausgaben", FinanceMoney.euros(bucket.expenses)), width: .fixed(barWidth))
                        .foregroundStyle(FinanceColors.expense)
                        .cornerRadius(3)
                        .opacity(emphasis)
                case .balance:
                    AreaMark(x: .value("Zeitraum", bucket.label), y: .value("Kontostand", FinanceMoney.euros(bucket.balance)))
                        .foregroundStyle(FinanceColors.income.opacity(0.1))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Zeitraum", bucket.label), y: .value("Kontostand", FinanceMoney.euros(bucket.balance)))
                        .foregroundStyle(FinanceColors.income)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    if isSelected(bucket), selected.range != nil {
                        PointMark(x: .value("Zeitraum", bucket.label), y: .value("Kontostand", FinanceMoney.euros(bucket.balance)))
                            .foregroundStyle(FinanceColors.income)
                            .symbolSize(60)
                    }
                }
            }
            if mode == .flow {
                RuleMark(y: .value("Null", 0))
                    .foregroundStyle(FinanceColors.baseline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let hovered, let bucket = buckets.first(where: { $0.start == hovered }) {
                RuleMark(x: .value("Zeitraum", bucket.label))
                    .foregroundStyle(Theme.ink.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(bucket)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisLabels) { _ in
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(FinanceColors.grid)
                AxisValueLabel {
                    if let euros = value.as(Double.self) {
                        Text(hidden ? "•••" : Self.compact(euros))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bucket(at: location, proxy: proxy, geometry: geometry)?.start
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        if let bucket = bucket(at: location, proxy: proxy, geometry: geometry) { choose(bucket) }
                    }
            }
        }
    }

    /// Bars stay thin, with air between them, however wide the window is.
    private var barWidth: CGFloat { buckets.count > 20 ? 8 : 18 }

    /// Every label when they fit, else every second or third.
    private var axisLabels: [String] {
        let step = buckets.count > 24 ? Int((Double(buckets.count) / 12).rounded(.up)) : buckets.count > 13 ? 2 : 1
        return buckets.enumerated().filter { $0.offset % step == (buckets.count - 1) % step }.map(\.element.label)
    }

    private func bucket(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> FinanceBucket? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        guard frame.contains(CGPoint(x: location.x, y: frame.midY)) else { return nil }
        // The bar whose middle is nearest to the pointer.
        return buckets.min { a, b in
            abs((proxy.position(forX: a.label) ?? .infinity) + frame.minX - location.x) < abs((proxy.position(forX: b.label) ?? .infinity) + frame.minX - location.x)
        }
    }

    private func tooltip(_ bucket: FinanceBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title(of: bucket))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if mode == .flow {
                row("Einnahmen", bucket.income, FinanceColors.income)
                row("Ausgaben", bucket.expenses, FinanceColors.expense)
                row("Saldo", bucket.net, nil)
            } else {
                row("Kontostand", bucket.balance, FinanceColors.income)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .fixedSize()
    }

    private func row(_ title: String, _ cents: Int, _ color: Color?) -> some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) } else { Color.clear.frame(width: 8, height: 8) }
            Text(title).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 10)
            Text(app.finance.format(cents, sign: title == "Saldo"))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func title(of bucket: FinanceBucket) -> String {
        if bucket.start == bucket.end { return bucket.start.german }
        if bucket.start.day == 1, bucket.end == bucket.start.lastOfMonth { return bucket.start.monthTitle }
        if bucket.start.month == 1, bucket.start.day == 1, bucket.end == bucket.start.lastOfYear { return String(bucket.start.year) }
        return "\(bucket.start.short) – \(bucket.end.german)"
    }

    /// `1.200 €`, `12 T€`, `1,2 Mio. €` on the axis.
    static func compact(_ euros: Double) -> String {
        let value = abs(euros)
        let sign = euros < 0 ? "−" : ""
        if value >= 1_000_000 { return sign + String(format: "%.1f Mio. €", value / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if value >= 10_000 { return sign + "\(Int((value / 1000).rounded())) T€" }
        return sign + FinanceMoney.format(Int((value * 100).rounded()), whole: true).replacingOccurrences(of: "−", with: "")
    }
}
