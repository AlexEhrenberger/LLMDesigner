import Foundation

// What a chart block draws, worked out from the project or from the person's own values. Kept apart from the views
// so the actions can report the same numbers and tests can check them.

struct ProjectChartSlice: Identifiable, Hashable {
    let id: String
    let title: String
    let value: Double
    let color: FolderColor
}

struct ProjectGanttBar: Identifiable, Hashable {
    let id: UUID
    let title: String
    let start: Date
    let end: Date
    let color: FolderColor
    let isDone: Bool
    /// A milestone: a diamond on its day instead of a bar.
    let isMilestone: Bool
}

struct ProjectFlowNode: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let shape: ProjectFlowShape
    let color: FolderColor
    let isDone: Bool
}

extension Project {
    static let chartColors: [FolderColor] = [.purple, .blue, .teal, .green, .yellow, .orange, .red, .pink]

    /// Slices of a pie or bars of a bar chart.
    func chartSlices(_ chart: ProjectChart) -> [ProjectChartSlice] {
        func color(_ index: Int) -> FolderColor { Self.chartColors[index % Self.chartColors.count] }
        switch chart.source {
        case .columns:
            return columns.enumerated().map { index, column in
                ProjectChartSlice(id: column.id.uuidString, title: column.displayTitle, value: Double(tasks(in: column.id).count), color: column.color ?? color(index))
            }
        case .priorities:
            return ProjectPriority.allCases.reversed().map { priority in
                ProjectChartSlice(id: priority.rawValue, title: priority.title, value: Double(tasks.filter { $0.priority == priority }.count), color: priority.color)
            }
        case .tags:
            var counts: [String: Int] = [:]
            for tag in tasks.flatMap(\.tags) { counts[tag, default: 0] += 1 }
            let untagged = tasks.filter(\.tags.isEmpty).count
            var slices = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.enumerated().map { index, entry in
                ProjectChartSlice(id: entry.key, title: entry.key, value: Double(entry.value), color: color(index))
            }
            if untagged > 0 { slices.append(ProjectChartSlice(id: "-", title: "Ohne Etikett", value: Double(untagged), color: .blue)) }
            return slices
        case .todos:
            let todos = allTodos
            return [
                ProjectChartSlice(id: "erledigt", title: "Erledigt", value: Double(todos.filter(\.isDone).count), color: .green),
                ProjectChartSlice(id: "offen", title: "Offen", value: Double(todos.filter { !$0.isDone }.count), color: .orange),
            ]
        case .manual:
            return chart.entries.enumerated().map { index, entry in
                ProjectChartSlice(id: entry.id.uuidString, title: entry.title.isEmpty ? "Wert \(index + 1)" : entry.title, value: max(entry.value, 0), color: entry.color ?? color(index))
            }
        case .tasks, .milestones, .history:
            return []
        }
    }

    /// Bars of a Gantt chart: tasks with dates, milestones, or the person's own rows. A task with only a due date runs
    /// from when it was made; one with only a start lasts a day.
    func ganttBars(_ chart: ProjectChart) -> [ProjectGanttBar] {
        let day: TimeInterval = 86_400
        switch chart.source {
        case .tasks:
            let dated = tasks.filter { $0.start != nil || $0.due != nil }.map { task -> ProjectGanttBar in
                let start = task.start ?? min(ProjectDay.normalized(task.createdAt), task.due ?? task.createdAt)
                let end = max(task.due ?? start, start).addingTimeInterval(day)
                return ProjectGanttBar(id: task.id, title: task.displayTitle, start: start, end: end,
                                       color: column(task.column)?.color ?? task.priority.color, isDone: isFinished(task), isMilestone: false)
            }
            let marks = milestones.map { ProjectGanttBar(id: $0.id, title: "◆ " + $0.displayTitle, start: $0.date, end: $0.date.addingTimeInterval(day), color: $0.color ?? .red, isDone: $0.isDone, isMilestone: true) }
            return (dated + marks).sorted { $0.start < $1.start }
        case .milestones:
            let sorted = sortedMilestones
            return sorted.enumerated().map { index, milestone in
                // Each milestone is the end of the stretch since the one before.
                let start = index == 0 ? min(ProjectDay.normalized(createdAt), milestone.date) : sorted[index - 1].date
                return ProjectGanttBar(id: milestone.id, title: milestone.displayTitle, start: start, end: milestone.date.addingTimeInterval(day),
                                       color: milestone.color ?? Self.chartColors[index % Self.chartColors.count], isDone: milestone.isDone, isMilestone: false)
            }
        case .manual:
            return chart.entries.enumerated().compactMap { index, entry in
                guard let start = entry.start ?? entry.end else { return nil }
                let end = max(entry.end ?? start, start).addingTimeInterval(day)
                return ProjectGanttBar(id: entry.id, title: entry.title.isEmpty ? "Zeile \(index + 1)" : entry.title, start: start, end: end,
                                       color: entry.color ?? Self.chartColors[index % Self.chartColors.count], isDone: entry.isDone, isMilestone: false)
            }
        default:
            return []
        }
    }

    /// The steps of a flow: the board's columns with their tasks (the way work goes), or the person's own steps.
    func flowNodes(_ chart: ProjectChart) -> [ProjectFlowNode] {
        switch chart.source {
        case .columns:
            return columns.enumerated().map { index, column in
                let count = tasks(in: column.id).count
                return ProjectFlowNode(id: column.id.uuidString, title: column.displayTitle, detail: count == 1 ? "1 Aufgabe" : "\(count) Aufgaben",
                                       shape: index == 0 || index == columns.count - 1 ? .terminal : .step,
                                       color: column.color ?? Self.chartColors[index % Self.chartColors.count], isDone: column.isDone && count > 0)
            }
        default:
            return chart.entries.enumerated().map { index, entry in
                ProjectFlowNode(id: entry.id.uuidString, title: entry.title.isEmpty ? "Schritt \(index + 1)" : entry.title, detail: nil, shape: entry.shape,
                                color: entry.color ?? (entry.isDone ? .green : Self.chartColors[index % Self.chartColors.count]), isDone: entry.isDone)
            }
        }
    }

    /// The course: one point per recorded day, done and all, and today with the numbers as they are now.
    var courseDays: [(day: Date, done: Int, total: Int)] {
        var days = history.compactMap { entry in ProjectDay.date(entry.day).map { (day: $0, done: entry.done, total: entry.open + entry.done) } }
        let todayDone = tasks.filter(isFinished).count + allTodos.filter(\.isDone).count
        let todayTotal = tasks.count + allTodos.count
        let today = ProjectDay.normalized(Date())
        if let last = days.last, Calendar.current.isDate(last.day, inSameDayAs: today) { days.removeLast() }
        days.append((today, todayDone, todayTotal))
        return days
    }
}
