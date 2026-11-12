import Charts
import SwiftUI

/// A chart block: pie, bars, Gantt, course or flow, drawn with Swift Charts (the system's framework).
struct ProjectChartBlock: View {
    let projectID: UUID
    let block: ProjectBlock
    let project: Project

    var body: some View {
        let chart = block.chart ?? ProjectChart()
        switch chart.kind {
        case .pie: ProjectPieChart(slices: project.chartSlices(chart), font: project.design.font)
        case .bars: ProjectBarChart(slices: project.chartSlices(chart))
        case .gantt: ProjectGanttChart(bars: project.ganttBars(chart), accent: project.accent.color)
        case .course: ProjectCourseChart(days: project.courseDays, accent: project.accent.color)
        case .flow: ProjectFlowChart(nodes: project.flowNodes(chart), font: project.design.font)
        }
    }
}

private struct ChartEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Pie

private struct ProjectPieChart: View {
    let slices: [ProjectChartSlice]
    let font: WriterFont
    @State private var selected: Double?

    var body: some View {
        let shown = slices.filter { $0.value > 0 }
        let total = shown.reduce(0) { $0 + $1.value }
        if shown.isEmpty {
            ChartEmpty(text: "Noch keine Werte.")
        } else {
            GeometryReader { geometry in
                let wide = geometry.size.width > geometry.size.height * 1.4
                let layout = wide ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    Chart(shown) { slice in
                        SectorMark(angle: .value("Anzahl", slice.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                            .cornerRadius(4)
                            .foregroundStyle(slice.color.color)
                            .opacity(selectedSlice(shown)?.id == nil || selectedSlice(shown)?.id == slice.id ? 1 : 0.4)
                    }
                    .chartAngleSelection(value: $selected)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text(selectedSlice(shown).map { "\(Int($0.value))" } ?? "\(Int(total))")
                                .font(Font(WriterStyler.font(font, size: 20, weight: .bold)).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            Text(selectedSlice(shown)?.title ?? "gesamt")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    legend(shown, total: total)
                        .frame(maxWidth: wide ? 170 : .infinity, alignment: .leading)
                }
            }
        }
    }

    private func selectedSlice(_ shown: [ProjectChartSlice]) -> ProjectChartSlice? {
        guard let selected else { return nil }
        var sum = 0.0
        for slice in shown {
            sum += slice.value
            if selected <= sum { return slice }
        }
        return nil
    }

    private func legend(_ shown: [ProjectChartSlice], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { slice in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(slice.color.color).frame(width: 9, height: 9)
                    Text(slice.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int(slice.value)) · \(Int((slice.value / max(total, 1) * 100).rounded())) %")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

// MARK: - Bars

private struct ProjectBarChart: View {
    let slices: [ProjectChartSlice]

    var body: some View {
        if slices.isEmpty || slices.allSatisfy({ $0.value == 0 }) {
            ChartEmpty(text: "Noch keine Werte.")
        } else {
            Chart(slices) { slice in
                BarMark(x: .value("Wert", slice.title), y: .value("Anzahl", slice.value))
                    .foregroundStyle(slice.color.color.gradient)
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 3) {
                        Text(slice.value == slice.value.rounded() ? "\(Int(slice.value))" : slice.value.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.ink.opacity(0.08))
                    AxisValueLabel().foregroundStyle(Theme.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

// MARK: - Gantt

private struct ProjectGanttChart: View {
    let bars: [ProjectGanttBar]
    let accent: Color

    var body: some View {
        if bars.isEmpty {
            ChartEmpty(text: "Gib Aufgaben einen Start oder eine Fälligkeit, oder lege Meilensteine an – dann stehen sie hier auf der Zeitachse.")
        } else {
            Chart {
                ForEach(bars) { bar in
                    if bar.isMilestone {
                        PointMark(x: .value("Tag", bar.start), y: .value("Aufgabe", bar.title))
                            .symbol(.diamond)
                            .symbolSize(110)
                            .foregroundStyle(bar.color.color)
                    } else {
                        BarMark(xStart: .value("Start", bar.start), xEnd: .value("Ende", bar.end), y: .value("Aufgabe", bar.title), height: .ratio(0.62))
                            .foregroundStyle(bar.color.color.opacity(bar.isDone ? 0.45 : 0.9).gradient)
                            .cornerRadius(5)
                            .annotation(position: .overlay, alignment: .leading) {
                                if bar.isDone {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.leading, 5)
                                }
                            }
                    }
                }
                RuleMark(x: .value("Heute", ProjectDay.normalized(Date())))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("heute")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(accent)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Theme.ink.opacity(0.07))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

// MARK: - Course

/// Everything there is to do and what is done of it, day by day: the gap between the two lines is what is still open.
private struct ProjectCourseChart: View {
    let days: [(day: Date, done: Int, total: Int)]
    let accent: Color

    private struct Point: Identifiable {
        let day: Date
        let value: Int
        let series: String
        var id: String { "\(series)\(day.timeIntervalSince1970)" }
    }

    var body: some View {
        let points = days.flatMap { [Point(day: $0.day, value: $0.total, series: "Gesamt"), Point(day: $0.day, value: $0.done, series: "Erledigt")] }
        if days.count < 2 && (days.first?.total ?? 0) == 0 {
            ChartEmpty(text: "Der Verlauf füllt sich, sobald Aufgaben und ToDos dazukommen und erledigt werden – ein Punkt je Tag.")
        } else {
            Chart(points) { point in
                if point.series == "Erledigt" {
                    AreaMark(x: .value("Tag", point.day), y: .value("Anzahl", point.value))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.stepEnd)
                }
                LineMark(x: .value("Tag", point.day), y: .value("Anzahl", point.value))
                    .foregroundStyle(by: .value("Reihe", point.series))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: point.series == "Erledigt" ? 2.5 : 1.5, dash: point.series == "Gesamt" ? [4, 3] : []))
            }
            .chartForegroundStyleScale(["Erledigt": accent, "Gesamt": Theme.textTertiary])
            .chartLegend(position: .top, alignment: .trailing)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Theme.ink.opacity(0.07))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.ink.opacity(0.07))
                    AxisValueLabel().foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

// MARK: - Flow

/// A flow chart: steps left to right, wrapping into the next row, joined by arrows. Decisions are diamonds, start and
/// end are capsules.
private struct ProjectFlowChart: View {
    let nodes: [ProjectFlowNode]
    let font: WriterFont

    var body: some View {
        if nodes.isEmpty {
            ChartEmpty(text: "Lege unter „Gestalten“ die Schritte des Ablaufs an.")
        } else {
            GeometryReader { geometry in
                let nodeWidth: CGFloat = 130
                let arrow: CGFloat = 34
                let perRow = max(1, Int((geometry.size.width + arrow) / (nodeWidth + arrow)))
                let rows = stride(from: 0, to: nodes.count, by: perRow).map { Array(nodes[$0..<min($0 + perRow, nodes.count)]) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.element.id) { index, node in
                                    if index > 0 || rowIndex > 0 {
                                        Image(systemName: index == 0 ? "arrow.turn.down.right" : "arrow.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.textTertiary)
                                            .frame(width: arrow)
                                    }
                                    shape(node)
                                        .frame(width: nodeWidth, height: 62)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private func shape(_ node: ProjectFlowNode) -> some View {
        let color = node.color.color
        let label = VStack(spacing: 1) {
            Text(node.title)
                .font(Font(WriterStyler.font(font, size: 12, weight: .semibold)))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let detail = node.detail {
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        switch node.shape {
        case .decision:
            ZStack {
                Rectangle()
                    .fill(color.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1.5))
                    .rotationEffect(.degrees(45))
                    .scaleEffect(x: 1.25, y: 0.72)
                    .frame(width: 62, height: 62)
                label.scaleEffect(0.92)
            }
        case .terminal:
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(color.opacity(node.isDone ? 0.32 : 0.16)))
                .overlay(Capsule().strokeBorder(color.opacity(0.8), lineWidth: 1.5))
        case .step:
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(node.isDone ? 0.32 : 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.75), lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    if node.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.success)
                            .padding(4)
                    }
                }
        }
    }
}
