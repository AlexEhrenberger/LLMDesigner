import SwiftUI

/// Texts the study shares between its page and the settings.
enum StudyTexts {
    static let settingFooter = "Zeigt im Learning Studio neben dem Garten den Tab „Studium“: IU · Angewandte Künstliche Intelligenz (B.Sc.) mit allen Modulen als Kurse, Stundenplan und Monatsplan. Beim ersten Einschalten werden die Pflichtmodule angelegt; ausgeschaltet bleibt alles erhalten. Gilt nur für diese Bibliothek."
}

/// The study program: its modules as courses (like the garden), the week's timetable and the month plan.
struct LearningStudyPage: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LearningStudioModel

    var body: some View {
        if let study = app.study, let catalog = app.studyCatalog {
            VStack(spacing: 0) {
                StudyHeader(study: study, catalog: catalog)
                HStack {
                    StudioTabPicker(tabs: StudyTab.allCases, selection: $model.studyTab, title: \.title, symbol: \.symbol) { tab in
                        switch tab {
                        case .modules: study.modules.count
                        case .week: study.timetable.count
                        case .months: nil
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                Divider()
                Group {
                    switch model.studyTab {
                    case .modules: StudyModulesView(model: model)
                    case .week: StudyWeekView(model: model)
                    case .months: StudyMonthsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            StudioEmptyState(symbol: "graduationcap", title: "Studium einrichten",
                             text: "Legt IU · Angewandte Künstliche Intelligenz (B.Sc.) mit allen Pflichtmodulen als Kurse an, mit Beschreibung, Prüfungsform und Lektionen – dazu einen Monatsplan nach Vollzeitmodell, der sich verschieben lässt.",
                             actionTitle: "Einrichten") { app.setUpStudy() }
        }
    }
}

/// Helpers the study's views share.
@MainActor
enum StudyInfo {
    static func ectsDone(_ study: LearningStudy, _ catalog: StudyCatalog, _ library: LearningLibrary) -> Int {
        study.modules.reduce(0) { sum, entry in
            guard let module = catalog.module(entry.code), let course = entry.course.flatMap(library.course), course.finished else { return sum }
            return sum + module.ects
        }
    }

    static func color(_ entry: StudyModule, _ catalog: StudyCatalog, _ library: LearningLibrary) -> Color {
        if let course = entry.course.flatMap(library.course) { return Color(hex: course.color.hex) }
        return catalog.module(entry.code).map { Color(hex: AppModel.studyColor($0, in: catalog).hex) } ?? Theme.accent
    }

    static func name(_ entry: StudyModule, _ catalog: StudyCatalog) -> String { catalog.module(entry.code)?.title ?? entry.code }

    static func finished(_ entry: StudyModule, _ library: LearningLibrary) -> Bool { entry.course.flatMap(library.course)?.finished ?? false }

    static func hours(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Header

private struct StudyHeader: View {
    @Environment(AppModel.self) private var app
    let study: LearningStudy
    let catalog: StudyCatalog

    var body: some View {
        let done = StudyInfo.ectsDone(study, catalog, app.learning)
        let finished = study.modules.filter { StudyInfo.finished($0, app.learning) }.count
        HStack(alignment: .center, spacing: 14) {
            ProgressRing(value: Double(done) / Double(max(catalog.ects, 1)), color: Theme.accent, lineWidth: 5)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(catalog.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("\(catalog.university) · Fernstudium · \(done) von \(catalog.ects) ECTS · \(finished) von \(study.modules.count) Modulen abgeschlossen")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .help(catalog.source)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Beginn").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    IconButton(systemName: "chevron.left", help: "Einen Monat früher – der ganze Plan rückt mit", size: 10, frameSize: 20) {
                        app.setStudyStart(study.start.adding(-1))
                    }
                    Text(study.start.label).font(.system(size: 12, weight: .medium).monospacedDigit()).frame(minWidth: 96)
                    IconButton(systemName: "chevron.right", help: "Einen Monat später – der ganze Plan rückt mit", size: 10, frameSize: 20) {
                        app.setStudyStart(study.start.adding(1))
                    }
                }
                Picker("Studienmodell", selection: Binding(get: { study.pace }, set: { app.setStudyPace($0) })) {
                    ForEach(StudyPace.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Das Studienmodell bestimmt die Wochenstunden und die Verteilung im Monatsplan")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - Modules

/// The modules semester by semester, as cards like the garden's; electives not chosen yet are places to choose from.
private struct StudyModulesView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LearningStudioModel

    var body: some View {
        if let study = app.study, let catalog = app.studyCatalog {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(1...catalog.semesters, id: \.self) { semester in
                        semesterSection(semester, study, catalog)
                    }
                    if study.practical == .internship, let internship = catalog.internship {
                        section(title: "Praktikum", detail: "Wahlpflichtbereich D · \(internship.ects) ECTS · begleitend statt der sechs Module") {
                            card(for: internship, study, catalog)
                        }
                    }
                    Text("Quelle: \(catalog.source). Die Beschreibungen sind Zusammenfassungen; verbindlich sind die Unterlagen der IU in myCampus.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .padding(24)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func semesterSection(_ semester: Int, _ study: LearningStudy, _ catalog: StudyCatalog) -> some View {
        let compulsory = catalog.compulsory.filter { $0.semester == semester }
        let areas = catalog.areas.filter { $0.semester == semester }
        let practical = catalog.options(of: "D").filter { $0.semester == semester }
        let taken = study.modules.compactMap { catalog.module($0.code) }.filter { StudyPlanner.semester(of: $0, in: catalog) == semester }
        let done = taken.filter { module in study.module(module.code).map { StudyInfo.finished($0, app.learning) } ?? false }
        let ects = StudyPlanner.slots(catalog, study).filter { $0.semester == semester }.reduce(0) { $0 + $1.ects }
        return section(title: "\(semester). Semester", detail: "\(ects) ECTS · \(done.count) von \(max(taken.count, 1)) abgeschlossen") {
            ForEach(compulsory.filter { $0.kind != .thesis }) { card(for: $0, study, catalog) }
            ForEach(areas) { area in
                let chosen = study.modules.compactMap { catalog.module($0.code) }.filter { $0.area == area.id }
                ForEach(chosen) { card(for: $0, study, catalog) }
                ForEach(chosen.count..<max(chosen.count, area.picks), id: \.self) { place in
                    ElectiveChoiceCard(area: area, place: place + 1, catalog: catalog, study: study)
                }
            }
            switch study.practical {
            case .modules: ForEach(practical) { card(for: $0, study, catalog) }
            case .internship: EmptyView()
            case nil: if !practical.isEmpty { PracticalChoiceCard(catalog: catalog, first: semester == 1) }
            }
            ForEach(compulsory.filter { $0.kind == .thesis }) { card(for: $0, study, catalog) }
        }
    }

    private func section<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)], alignment: .leading, spacing: 14) {
                content()
            }
        }
    }

    @ViewBuilder
    private func card(for module: StudyCatalog.Module, _ study: LearningStudy, _ catalog: StudyCatalog) -> some View {
        let entry = study.module(module.code)
        if let entry, let courseID = entry.course, app.learning.course(courseID) != nil {
            let caption = [module.code, "\(module.ects) ECTS", module.exam.label, entry.month?.label].compactMap { $0 }.joined(separator: " · ")
            CourseCard(courseID: courseID, caption: caption) {
                model.courseID = courseID
                model.tab = .overview
            } learn: {
                model.courseID = courseID
                model.tab = .review
            }
            .contextMenu {
                if module.area != nil, module.area != "D" {
                    Button("Wahl zurücknehmen (der Kurs bleibt im Garten)", systemImage: "arrow.uturn.backward") { app.removeStudyModule(module.code) }
                }
                Button("Im Monatsplan zeigen", systemImage: "calendar") { model.studyTab = .months }
            }
        } else {
            // The course was deleted: the module stays in the study and can get a new one.
            VStack(alignment: .leading, spacing: 8) {
                Text(module.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text("\(module.code) · \(module.ects) ECTS · \(module.exam.label)").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                HStack {
                    Button("Kurs wieder anlegen", systemImage: "plus") { app.recreateStudyCourse(module.code) }
                    if module.area != nil, module.area != "D" {
                        Button("Wahl zurücknehmen") { app.removeStudyModule(module.code) }.buttonStyle(.borderless)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
    }
}

/// A free place of an elective area: the menu offers its modules.
private struct ElectiveChoiceCard: View {
    @Environment(AppModel.self) private var app
    let area: StudyCatalog.Area
    let place: Int
    let catalog: StudyCatalog
    let study: LearningStudy

    var body: some View {
        let options = catalog.options(of: area.id).filter { study.module($0.code) == nil }
        Menu {
            ForEach(options) { module in
                Button("\(module.title) · \(module.exam.label)\(module.english ? " · englisch" : "")") { app.chooseStudyModule(module.code) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "square.dashed").font(.system(size: 18, weight: .light))
                    Spacer()
                    Text("Platz \(place) von \(area.picks)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Text(area.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("\(options.count) Module zur Wahl · \(catalog.options(of: area.id).first?.ects ?? 5) ECTS").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Label("Modul wählen …", systemImage: "chevron.down.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(area.note)
    }
}

/// Area D before the decision: the internship or all six modules.
private struct PracticalChoiceCard: View {
    @Environment(AppModel.self) private var app
    let catalog: StudyCatalog
    /// The first semester's card explains; the others only remind.
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text("Wahlpflichtbereich D").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(first ? (catalog.area("D")?.note ?? "") : "Praktikum oder Modul – noch nicht entschieden.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Sechs Module") { app.setStudyPractical(.modules) }
                    .help(catalog.options(of: "D").filter { $0.kind != .internship }.map(\.title).joined(separator: "\n"))
                Button("Praktikum") { app.setStudyPractical(.internship) }
                    .help(catalog.internship?.about ?? "")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

// MARK: - Month plan

/// Which module in which month: one card per month from the beginning to the end of the model, modules dragged between
/// them; what has no month waits above.
private struct StudyMonthsView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LearningStudioModel
    @State private var confirmsDistribution = false

    var body: some View {
        if let study = app.study, let catalog = app.studyCatalog {
            let months = monthRange(study)
            let perMonth = study.pace.ectsPerMonth(total: catalog.ects)
            let unplanned = study.modules.filter { $0.month == nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Im Schnitt \(String(format: "%.1f", perMonth).replacingOccurrences(of: ".", with: ",")) ECTS pro Monat (\(study.pace.short)) – Module per Ziehen in einen Monat legen.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Nach Studienmodell verteilen …", systemImage: "wand.and.stars") { confirmsDistribution = true }
                    }
                    MonthDropZone(month: nil, title: "Ohne Monat", detail: unplanned.isEmpty ? "Alle Module sind eingeplant." : (unplanned.count == 1 ? "1 Modul" : "\(unplanned.count) Module"),
                                  entries: unplanned, current: false, past: false, load: 0, model: model)
                    ForEach(years(months), id: \.self) { year in
                        Text(String(year)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.top, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(months.filter { $0.year == year }, id: \.self) { month in
                                let entries = study.modules(in: month)
                                let ects = entries.compactMap { catalog.module($0.code)?.ects }.reduce(0, +)
                                MonthDropZone(month: month, title: month.label, detail: "Monat \(study.start.distance(to: month) + 1) · \(ects) ECTS",
                                              entries: entries, current: month == StudyMonth(Date()), past: month < StudyMonth(Date()),
                                              load: perMonth > 0 ? Double(ects) / perMonth : 0, model: model)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .confirmationDialog("Alle Module nach dem Studienmodell verteilen?", isPresented: $confirmsDistribution) {
                Button("Verteilen") { app.distributeStudyPlan() }
            } message: {
                Text("Jedes Modul bekommt den Monat, in dem es bei \(study.pace.label) ab \(study.start.label) dran ist. Eigene Verschiebungen gehen dabei verloren.")
            }
        }
    }

    /// From the beginning to the end of the model, widened to every planned month.
    private func monthRange(_ study: LearningStudy) -> [StudyMonth] {
        let planned = study.modules.compactMap(\.month)
        let first = min(study.start, planned.min() ?? study.start)
        let last = max(study.plannedEnd, planned.max() ?? study.plannedEnd)
        return (0...max(0, first.distance(to: last))).map { first.adding($0) }
    }

    private func years(_ months: [StudyMonth]) -> [Int] {
        Array(Set(months.map(\.year))).sorted()
    }
}

/// One month (or the tray without a month): its modules as chips, a target for dragged ones.
private struct MonthDropZone: View {
    @Environment(AppModel.self) private var app
    let month: StudyMonth?
    let title: String
    let detail: String
    let entries: [StudyModule]
    let current: Bool
    let past: Bool
    /// ECTS of the month against the model's average: above 1.5 the month is marked as full.
    let load: Double
    @Bindable var model: LearningStudioModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(current ? Theme.accent : Theme.textPrimary)
                    if current { Text("jetzt").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                }
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(load > 1.5 ? Theme.warning : Theme.textTertiary)
            }
            if let catalog = app.studyCatalog {
                if month == nil {
                    FlowChips(entries: entries, catalog: catalog, model: model)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entries) { entry in ModuleChip(entry: entry, catalog: catalog, model: model) }
                    }
                }
            }
            if entries.isEmpty, month != nil {
                Text("frei").font(.system(size: 11)).foregroundStyle(Theme.textTertiary.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: month == nil ? 60 : 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? Theme.accent.opacity(0.12) : Theme.ink.opacity(past ? 0.02 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(current ? Theme.accent : (targeted ? Theme.accent.opacity(0.6) : Theme.border), lineWidth: current ? 1.5 : 1))
        .opacity(past && !current ? 0.75 : 1)
        .dropDestination(for: String.self) { codes, _ in
            for code in codes { app.planStudyModule(code, month: month) }
            return !codes.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// The tray's chips side by side.
private struct FlowChips: View {
    let entries: [StudyModule]
    let catalog: StudyCatalog
    @Bindable var model: LearningStudioModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(entries) { ModuleChip(entry: $0, catalog: catalog, model: model) }
        }
    }
}

/// A module in the month plan: drag it to another month, click it to open its course.
private struct ModuleChip: View {
    @Environment(AppModel.self) private var app
    let entry: StudyModule
    let catalog: StudyCatalog
    @Bindable var model: LearningStudioModel

    var body: some View {
        let finished = StudyInfo.finished(entry, app.learning)
        let color = StudyInfo.color(entry, catalog, app.learning)
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
            Text(StudyInfo.name(entry, catalog)).font(.system(size: 11.5, weight: .medium)).lineLimit(1).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            if finished { Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(Theme.success) }
            Text("\(catalog.module(entry.code)?.ects ?? 0)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(finished ? 0.08 : 0.16)))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .draggable(entry.code) {
            Text(StudyInfo.name(entry, catalog)).font(.system(size: 12, weight: .medium)).padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.3)))
        }
        .contextMenu {
            Button("Kurs öffnen", systemImage: "book") { open() }
            if let month = entry.month {
                Button("Einen Monat früher", systemImage: "chevron.left") { app.planStudyModule(entry.code, month: month.adding(-1)) }
                Button("Einen Monat später", systemImage: "chevron.right") { app.planStudyModule(entry.code, month: month.adding(1)) }
                Button("Aus dem Plan nehmen", systemImage: "calendar.badge.minus") { app.planStudyModule(entry.code, month: nil) }
            }
        }
        .help("\(entry.code) – ziehen zum Verschieben, klicken zum Öffnen")
    }

    private func open() {
        guard let id = entry.course, app.learning.course(id) != nil else { return }
        model.courseID = id
        model.tab = .overview
    }
}

// MARK: - Timetable

/// The week: Monday to Sunday from 6 to 24 o'clock with blocks per module; a click into a free hour adds one.
private struct StudyWeekView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LearningStudioModel
    @State private var editing: UUID?

    static let firstHour = 6
    static let lastHour = 24
    static let hourHeight: CGFloat = 44

    var body: some View {
        if let study = app.study, let catalog = app.studyCatalog {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    dayHeader
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            HStack(alignment: .top, spacing: 0) {
                                hourLabels
                                ForEach(1...7, id: \.self) { day in
                                    dayColumn(day, study, catalog)
                                }
                            }
                            .padding(.bottom, 12)
                        }
                        .onAppear { proxy.scrollTo(8, anchor: .top) }
                    }
                }
                Divider()
                StudyWeekSidebar(study: study, catalog: catalog, editing: $editing)
                    .frame(width: 280)
            }
        }
    }

    private var dayHeader: some View {
        let today = (Calendar.current.component(.weekday, from: Date()) + 5) % 7 + 1
        return HStack(spacing: 0) {
            Color.clear.frame(width: 50, height: 1)
            ForEach(1...7, id: \.self) { day in
                Text(StudySlot.weekdays[day - 1])
                    .font(.system(size: 12, weight: day == today ? .bold : .semibold))
                    .foregroundStyle(day == today ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(Self.firstHour..<Self.lastHour, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 50, height: Self.hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    .offset(y: -6)
                    .id(hour)
            }
        }
        .frame(width: 50)
    }

    private func dayColumn(_ day: Int, _ study: LearningStudy, _ catalog: StudyCatalog) -> some View {
        let height = CGFloat(Self.lastHour - Self.firstHour) * Self.hourHeight
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Self.firstHour..<Self.lastHour, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Rectangle().fill(Theme.border).frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.hourHeight)
                }
            }
            ForEach(study.timetable.filter { $0.weekday == day }) { slot in
                SlotBlock(slot: slot, catalog: catalog, editing: $editing)
                    .padding(.horizontal, 2)
                    .frame(height: max(18, CGFloat(slot.minutes) / 60 * Self.hourHeight - 2))
                    .offset(y: CGFloat(slot.start - Self.firstHour * 60) / 60 * Self.hourHeight + 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            let hour = Self.firstHour + Int(location.y / Self.hourHeight)
            let start = min(Self.lastHour - 1, max(Self.firstHour, hour)) * 60
            // The month plan's first module for now, so a click mostly needs no choosing.
            let current = study.modules(in: StudyMonth(Date())).first?.course
            let slot = app.addStudySlot(StudySlot(weekday: day, start: start, end: start + 60, course: current, title: "Lernen"))
            editing = slot.id
        }
    }
}

/// A block of the timetable; a click opens its editor.
private struct SlotBlock: View {
    @Environment(AppModel.self) private var app
    let slot: StudySlot
    let catalog: StudyCatalog
    @Binding var editing: UUID?

    var body: some View {
        let course = slot.course.flatMap(app.learning.course)
        let color = course.map { Color(hex: $0.color.hex) } ?? Theme.accent
        Button {
            editing = slot.id
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(course?.displayName ?? (slot.title.isEmpty ? "Lernzeit" : slot.title))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    Text("\(StudySlot.time(slot.start))–\(StudySlot.time(slot.end))\(course != nil && !slot.title.isEmpty ? " · \(slot.title)" : "")")
                        .font(.system(size: 10).monospacedDigit()).lineLimit(1)
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.2)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { editing == slot.id }, set: { if !$0, editing == slot.id { editing = nil } }), arrowEdge: .trailing) {
            SlotEditor(slotID: slot.id, catalog: catalog, editing: $editing)
        }
    }
}

/// Module, kind, day and time of a block.
private struct SlotEditor: View {
    @Environment(AppModel.self) private var app
    let slotID: UUID
    let catalog: StudyCatalog
    @Binding var editing: UUID?

    static let kinds = ["Lernen", "Live-Session", "Tutorium", "Karten wiederholen", "Projektarbeit", "Prüfungsvorbereitung", "Schreiben"]

    var body: some View {
        if let study = app.study, let slot = study.timetable.first(where: { $0.id == slotID }) {
            let now = study.modules(in: StudyMonth(Date())).filter { $0.course != nil }
            let others = study.modules.filter { entry in entry.course != nil && !now.contains(where: { $0.code == entry.code }) }
            VStack(alignment: .leading, spacing: 10) {
                Text("Block im Stundenplan").font(.system(size: 13, weight: .semibold))
                Picker("Modul", selection: binding(slot, \.course)) {
                    Text("Ohne Modul").tag(UUID?.none)
                    if !now.isEmpty {
                        Section("Diesen Monat geplant") {
                            ForEach(now) { Text(StudyInfo.name($0, catalog)).tag($0.course) }
                        }
                    }
                    Section("Alle Module") {
                        ForEach(others) { Text(StudyInfo.name($0, catalog)).tag($0.course) }
                    }
                }
                HStack {
                    StudioField(placeholder: "Was, z. B. Lernen", text: binding(slot, \.title))
                    Menu {
                        ForEach(Self.kinds, id: \.self) { kind in Button(kind) { app.updateStudySlot(slotID) { $0.title = kind } } }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.button)
                    .fixedSize()
                }
                Picker("Tag", selection: binding(slot, \.weekday)) {
                    ForEach(1...7, id: \.self) { Text(StudySlot.weekdays[$0 - 1]).tag($0) }
                }
                HStack {
                    DatePicker("Von", selection: time(slot, \.start), displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: time(slot, \.end), displayedComponents: .hourAndMinute)
                }
                HStack {
                    Button("Löschen", role: .destructive) {
                        editing = nil
                        app.removeStudySlot(slotID)
                    }
                    Spacer()
                    Button("Fertig") { editing = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(.system(size: 12.5))
            .padding(16)
            .frame(width: 340)
            .environment(\.locale, Locale(identifier: "de_DE"))
        }
    }

    private func binding<T>(_ slot: StudySlot, _ keyPath: WritableKeyPath<StudySlot, T>) -> Binding<T> {
        Binding(get: { app.study?.timetable.first { $0.id == slotID }?[keyPath: keyPath] ?? slot[keyPath: keyPath] },
                set: { value in app.updateStudySlot(slotID) { $0[keyPath: keyPath] = value } })
    }

    /// Minutes after midnight as a time of a fixed day, for the date picker.
    private func time(_ slot: StudySlot, _ keyPath: WritableKeyPath<StudySlot, Int>) -> Binding<Date> {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 0))
        return Binding(get: { day.addingTimeInterval(Double(binding(slot, keyPath).wrappedValue * 60)) },
                       set: { date in
                           let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                           let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                           app.updateStudySlot(slotID) { slot in
                               let length = slot.minutes
                               slot[keyPath: keyPath] = minutes
                               // Moving the start keeps the length, so a block isn't squeezed to five minutes.
                               if keyPath == \StudySlot.start { slot.end = minutes + length }
                           }
                       })
    }
}

/// Hours of the week against the model, per module, and what the month plan has for now.
private struct StudyWeekSidebar: View {
    @Environment(AppModel.self) private var app
    let study: LearningStudy
    let catalog: StudyCatalog
    @Binding var editing: UUID?

    var body: some View {
        let target = study.pace.hoursPerWeek(total: catalog.ects)
        let planned = Double(study.weeklyMinutes) / 60
        let month = StudyMonth(Date())
        let now = study.modules(in: month)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diese Woche").font(.system(size: 13, weight: .semibold))
                    Text("\(StudyInfo.hours(study.weeklyMinutes)) geplant · Ziel ca. \(Int(target.rounded())) h (\(study.pace.short))")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    ProgressView(value: min(1, planned / max(target, 1)))
                        .tint(planned >= target * 0.9 ? Theme.success : Theme.accent)
                    Text("Ein Klick in eine freie Stunde legt einen Block an.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nach Modul").font(.system(size: 13, weight: .semibold))
                    let courses = Array(Set(study.timetable.compactMap(\.course)))
                    if courses.isEmpty && study.timetable.isEmpty {
                        Text("Noch keine Blöcke.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(courses.sorted { study.weeklyMinutes(course: $0) > study.weeklyMinutes(course: $1) }, id: \.self) { id in
                        HStack {
                            Circle().fill(Color(hex: app.learning.course(id)?.color.hex ?? 0x888888)).frame(width: 7, height: 7)
                            Text(app.learning.course(id)?.displayName ?? "Gelöschter Kurs").font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(StudyInfo.hours(study.weeklyMinutes(course: id))).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    let loose = study.timetable.filter { $0.course == nil }.reduce(0) { $0 + $1.minutes }
                    if loose > 0 {
                        HStack {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                            Text("Ohne Modul").font(.system(size: 12))
                            Spacer()
                            Text(StudyInfo.hours(loose)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Im \(month.label) geplant").font(.system(size: 13, weight: .semibold))
                    if now.isEmpty {
                        Text("Der Monatsplan hat für diesen Monat kein Modul.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(now) { entry in
                        HStack {
                            Circle().fill(StudyInfo.color(entry, catalog, app.learning)).frame(width: 7, height: 7)
                            Text(StudyInfo.name(entry, catalog)).font(.system(size: 12)).lineLimit(2)
                            Spacer()
                            if let course = entry.course, app.learning.course(course) != nil {
                                IconButton(systemName: "plus", help: "Block für dieses Modul am nächsten freien Abend", size: 10, frameSize: 20) {
                                    let slot = app.addStudySlot(nextFreeEvening(study, course: course))
                                    editing = slot.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// 18–20 o'clock on the first weekday whose evening is free, else Saturday morning.
    private func nextFreeEvening(_ study: LearningStudy, course: UUID) -> StudySlot {
        for day in 1...5 where !study.timetable.contains(where: { $0.weekday == day && $0.start < 20 * 60 && $0.end > 18 * 60 }) {
            return StudySlot(weekday: day, start: 18 * 60, end: 20 * 60, course: course, title: "Lernen")
        }
        return StudySlot(weekday: 6, start: 9 * 60, end: 11 * 60, course: course, title: "Lernen")
    }
}
