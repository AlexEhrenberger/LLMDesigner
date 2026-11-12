import SwiftUI

/// What Learning Studio shows.
@MainActor
@Observable
final class LearningStudioModel {
    var disciplineID: UUID?
    var courseID: UUID?
    var tab: CourseTab = .overview
    var showsSettings = false
    var showsPause = false
}

/// Learning Studio: a garden with one tree per discipline that grows with what is learned; each discipline holds
/// courses with flash cards, material, quizzes and the person's own documents.
struct LearningStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = LearningStudioModel()

    var body: some View {
        let library = app.learning
        VStack(spacing: 0) {
            StudioTopBar(symbol: StudioApplication.learning.symbol, title: "Learning Studio", detail: detail, close: { app.closeLearningStudio() }) {
                if let courseID = model.courseID, let course = library.course(courseID) {
                    breadcrumb(course)
                }
            } trailing: {
                Button {
                    model.showsPause = true
                } label: {
                    Image(systemName: library.activePauses.isEmpty ? "pause.circle" : "pause.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(library.activePauses.isEmpty ? Theme.textSecondary : Theme.warning)
                        .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lernpause (Urlaub): Karten ruhen, nichts staut sich")
                .popover(isPresented: $model.showsPause) { LearningPauseView() }
                Button {
                    model.showsSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lernalgorithmus und Tagesgrenzen")
                .popover(isPresented: $model.showsSettings) { LearningSettingsView() }
                IconMenu(systemName: "plus", help: "Neue Disziplin oder neuer Kurs", frameSize: Theme.titleBarControlSize) {
                    Button("Neue Disziplin", systemImage: "leaf") {
                        let discipline = app.newDiscipline(name: "Neue Disziplin")
                        model.disciplineID = discipline.id
                        model.courseID = nil
                    }
                    Button("Neuer Kurs", systemImage: "book") {
                        let course = app.newCourse(name: "", in: model.disciplineID ?? library.state.disciplines.first?.id)
                        model.courseID = course.id
                        model.tab = .overview
                    }
                }
                PowerButton()
            }
            Group {
                if let courseID = model.courseID, library.course(courseID) != nil {
                    LearningCoursePage(courseID: courseID, model: model)
                        .id(courseID)
                } else {
                    LearningGarden(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .onAppear {
            library.loadIfNeeded()
            take(app.learningStudioCommand)
        }
        .onChange(of: app.learningStudioCommand) { _, command in take(command) }
    }

    private var detail: String {
        let library = app.learning
        let due = library.courses.records.reduce(0) { $0 + library.queue($1.id).count }
        let streak = library.streak()
        return "\(library.state.disciplines.count) Disziplinen · \(library.courses.records.count) Kurse · \(due) fällig" + (streak > 0 ? " · \(streak) Tage in Folge" : "")
    }

    private func breadcrumb(_ course: LearningCourse) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.courseID = nil }
            } label: {
                Label("Garten", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            if let discipline = app.learning.discipline(course.discipline) {
                Text(discipline.displayName).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }
            Text(course.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .fixedSize()
    }

    private func take(_ command: LearningStudioCommand?) {
        guard let command else { return }
        if let discipline = command.discipline { model.disciplineID = discipline; model.courseID = nil }
        if let course = command.course {
            model.courseID = course
            model.disciplineID = app.learning.course(course)?.discipline
        }
        if let tab = command.tab { model.tab = tab }
        if command.review { model.tab = .review }
        app.learningStudioCommand = nil
    }
}

// MARK: - Garden

/// The landing page: a landscape with every discipline's tree, then the courses of the chosen one.
private struct LearningGarden: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LearningStudioModel
    @State private var newName = ""

    var body: some View {
        let library = app.learning
        let disciplines = library.state.disciplines
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                landscape(disciplines)
                if !library.activePauses.isEmpty { pauseBanner }
                if disciplines.isEmpty {
                    firstDiscipline
                } else {
                    let selected = model.disciplineID.flatMap { id in disciplines.first { $0.id == id } } ?? disciplines.first
                    if let selected { disciplinePanel(selected) }
                    let loose = library.courses(in: nil)
                    if !loose.isEmpty {
                        StudioSectionHeader(title: "Ohne Disziplin", symbol: "tray", count: loose.count)
                        courseGrid(loose, discipline: nil)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
    }

    private func landscape(_ disciplines: [LearningDiscipline]) -> some View {
        ZStack(alignment: .bottom) {
            GardenSky()
            if disciplines.isEmpty {
                LearningTreeView(growth: TreeGrowth(stage: 0.05), kind: .eiche, color: .green, seed: 1)
                    .frame(width: 260, height: 300)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: disciplines.count > 3 ? 0 : 30) {
                        ForEach(disciplines) { discipline in
                            gardenTree(discipline, wide: disciplines.count <= 2)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(minWidth: 900)
                }
            }
        }
        .frame(height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
        .overlay(alignment: .topLeading) { gardenStats.padding(16) }
        .padding(.top, 4)
    }

    private var gardenStats: some View {
        let library = app.learning
        let streak = library.streak()
        let known = library.courses.records.reduce(0) { sum, course in sum + course.cards.filter { $0.state == .review }.count }
        return HStack(spacing: 10) {
            statPill(symbol: "flame.fill", value: "\(streak)", label: streak == 1 ? "Tag in Folge" : "Tage in Folge", tint: Color(hex: 0xF27A3D))
            statPill(symbol: "brain.head.profile", value: "\(known)", label: "Karten gelernt", tint: Color(hex: 0x6A54E0))
            if !library.activePauses.isEmpty {
                statPill(symbol: "beach.umbrella", value: "Pause", label: "Karten ruhen", tint: Color(hex: 0xC27C0E))
            }
        }
    }

    private func statPill(symbol: String, value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.system(size: 13, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 11.5))
        }
        .foregroundStyle(Color(hex: 0x1C1C1F))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.78)))
    }

    private func gardenTree(_ discipline: LearningDiscipline, wide: Bool) -> some View {
        let growth = app.learning.growth(of: discipline.id)
        let selected = (model.disciplineID ?? app.learning.state.disciplines.first?.id) == discipline.id
        let due = app.learning.courses(in: discipline.id).reduce(0) { $0 + app.learning.queue($1.id).count }
        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.disciplineID = discipline.id }
        } label: {
            VStack(spacing: 4) {
                LearningTreeView(growth: growth, kind: discipline.tree, color: discipline.color, seed: discipline.id.treeSeed)
                    .frame(width: wide ? 360 : 260, height: 340)
                HStack(spacing: 6) {
                    Text(discipline.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(Int(growth.stage * 100)) %")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(0.7)
                    if due > 0 {
                        Text("\(due) fällig")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: discipline.color.hex).opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                }
                .foregroundStyle(Color(hex: 0x1C1C1F))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(selected ? 0.95 : 0.65)))
                .overlay(Capsule().strokeBorder(Color(hex: discipline.color.hex), lineWidth: selected ? 2 : 0))
                .padding(.bottom, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(discipline.displayName): wächst mit gelernten Karten, Wiederholungen, Material, Abfragen und abgeschlossenen Kursen")
    }

    private var pauseBanner: some View {
        let pauses = app.learning.activePauses
        return HStack(spacing: 10) {
            Image(systemName: "beach.umbrella.fill").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lernpause").font(.system(size: 13, weight: .semibold))
                Text(pauses.map { pause in
                    "\(pauseScope(pause)) seit \(pause.start.formatted(date: .abbreviated, time: .omitted))" + (pause.end.map { " bis \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                }.joined(separator: " · ") + ". Fällige Karten warten und rücken danach um die Pausenlänge weiter.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            ForEach(pauses) { pause in
                Button("Pause beenden") { app.learning.endPause(pause.id) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.1)))
    }

    private func pauseScope(_ pause: LearningPause) -> String {
        switch pause.scope {
        case .all: "Alles"
        case .discipline(let id): app.learning.discipline(id)?.displayName ?? "Disziplin"
        case .course(let id): app.learning.course(id)?.displayName ?? "Kurs"
        }
    }

    private var firstDiscipline: some View {
        StudioCard(title: "Pflanze deinen ersten Baum", symbol: "leaf") {
            Text("Eine Disziplin ist ein Baum – etwa Psychologie oder Informatik. Darin legst du Kurse an, mit Karteikarten, Material, Lernzetteln und Abfragen. Je mehr du lernst, desto größer und bunter wird der Baum.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                StudioField(placeholder: "z. B. Psychologie", text: $newName)
                    .frame(width: 280)
                    .onSubmit(plant)
                Button("Pflanzen", action: plant)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func plant() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.disciplineID = app.newDiscipline(name: name).id
        newName = ""
    }

    private func disciplinePanel(_ discipline: LearningDiscipline) -> some View {
        let courses = app.learning.courses(in: discipline.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: discipline.symbol)
                    .foregroundStyle(Color(hex: discipline.color.hex))
                TextField("Name der Disziplin", text: Binding(get: { discipline.displayName }, set: { name in
                    app.learning.changeState { state in if let i = state.disciplines.firstIndex(where: { $0.id == discipline.id }) { state.disciplines[i].name = name } }
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: 360)
                Picker("Baum", selection: Binding(get: { discipline.tree }, set: { tree in
                    app.learning.changeState { state in if let i = state.disciplines.firstIndex(where: { $0.id == discipline.id }) { state.disciplines[i].tree = tree } }
                })) {
                    ForEach(TreeKind.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 180)
                Menu {
                    ForEach(FolderColor.allCases, id: \.self) { color in
                        Button(color.name) {
                            app.learning.changeState { state in if let i = state.disciplines.firstIndex(where: { $0.id == discipline.id }) { state.disciplines[i].color = color } }
                        }
                    }
                } label: {
                    Circle().fill(Color(hex: discipline.color.hex)).frame(width: 14, height: 14)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Farbe der Blüten")
                Spacer()
                Menu {
                    Button("Disziplin pausieren", systemImage: "pause.circle") { app.learning.startPause(scope: .discipline(discipline.id)) }
                    Divider()
                    Button("Disziplin entfernen (Kurse bleiben)", systemImage: "trash", role: .destructive) {
                        app.deleteDiscipline(discipline.id)
                        model.disciplineID = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            courseGrid(courses, discipline: discipline.id)
        }
    }

    private func courseGrid(_ courses: [LearningCourse], discipline: UUID?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(courses) { course in
                CourseCard(courseID: course.id) {
                    model.courseID = course.id
                    model.tab = .overview
                } learn: {
                    model.courseID = course.id
                    model.tab = .review
                }
            }
            Button {
                let course = app.newCourse(name: "", in: discipline)
                model.courseID = course.id
                model.tab = .overview
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle").font(.system(size: 22, weight: .light))
                    Text("Kurs anlegen").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A course in the garden's grid: its progress ring, what is due, the exam countdown.
struct CourseCard: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let open: () -> Void
    let learn: () -> Void
    @State private var hovering = false

    var body: some View {
        if let course = app.learning.course(courseID) {
            let stats = app.learning.stats(courseID)
            let paused = app.learning.activePause(for: course) != nil
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        ProgressRing(value: stats.progress, color: Color(hex: course.color.hex))
                            .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(course.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                            Text("\(stats.total) Karten · \(course.materials.count) Material").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        if course.finished {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success).help("Abgeschlossen")
                        }
                    }
                    HStack(spacing: 6) {
                        if let exam = course.examDate {
                            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: exam).day ?? 0
                            Label(days >= 0 ? "Prüfung in \(days) T." : "Prüfung vorbei", systemImage: "calendar")
                                .font(.system(size: 11)).foregroundStyle(days <= 7 && days >= 0 ? Theme.warning : Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if paused {
                            Label("Pause", systemImage: "pause.circle").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.warning)
                        } else if stats.dueNow > 0 {
                            Button(action: learn) {
                                Label("Lernen (\(stats.dueNow))", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if stats.total > 0 {
                            Label("Alles erledigt", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.success)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.hover : Theme.ink.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: course.color.hex).opacity(0.35)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

struct ProgressRing: View {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded())) %")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Settings and pauses

private struct LearningSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var steps = ""
    @State private var relearn = ""

    var body: some View {
        let settings = app.learning.settings
        VStack(alignment: .leading, spacing: 12) {
            Text("Lernalgorithmus").font(.system(size: 14, weight: .semibold))
            Picker("Algorithmus", selection: binding(\.algorithm)) {
                ForEach(LearningSettings.Algorithm.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.algorithm == .fsrs
                 ? "FSRS schätzt für jede Karte, wie stabil sie im Gedächtnis ist, und fragt, kurz bevor die Erinnerung unter die gewünschte Behaltensrate fällt."
                 : "SM-2 wie in Anki: Jede Karte hat einen Faktor; „Gut“ vervielfacht das Intervall damit, „Nochmal“ senkt ihn.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if settings.algorithm == .fsrs {
                HStack {
                    Text("Behaltensrate").frame(width: 130, alignment: .leading)
                    Slider(value: binding(\.retention), in: 0.8...0.97, step: 0.01)
                    Text("\(Int(settings.retention * 100)) %").monospacedDigit().frame(width: 44)
                }
                Text("Höher heißt: öfter wiederholen, sicherer wissen.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            } else {
                HStack {
                    Text("Startfaktor").frame(width: 130, alignment: .leading)
                    Slider(value: binding(\.startingEase), in: 1.3...3.5, step: 0.05)
                    Text(String(format: "%.2f", settings.startingEase)).monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("Intervall-Faktor").frame(width: 130, alignment: .leading)
                    Slider(value: binding(\.intervalModifier), in: 0.5...2, step: 0.05)
                    Text(String(format: "%.2f", settings.intervalModifier)).monospacedDigit().frame(width: 44)
                }
            }
            Divider()
            Stepper("Neue Karten pro Tag und Kurs: \(settings.newPerDay)", value: binding(\.newPerDay), in: 0...200, step: 5)
            Stepper("Wiederholungen pro Tag und Kurs: \(settings.reviewsPerDay)", value: binding(\.reviewsPerDay), in: 10...1_000, step: 10)
            Stepper("Längstes Intervall: \(Int(settings.maxInterval)) Tage", value: binding(\.maxInterval), in: 7...3_650, step: 30)
            HStack {
                Text("Lernschritte (Min.)").frame(width: 130, alignment: .leading)
                StudioField(placeholder: "1 10", text: $steps).onSubmit { apply() }
            }
            HStack {
                Text("Neu-lernen (Min.)").frame(width: 130, alignment: .leading)
                StudioField(placeholder: "10", text: $relearn).onSubmit { apply() }
            }
            Text("Wiederholungen pro Tag begrenzen auch den Rückstau nach einer Pause, ohne dass Karten verloren gehen.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(16)
        .frame(width: 420)
        .onAppear {
            steps = settings.learningSteps.map { String(Int($0)) }.joined(separator: " ")
            relearn = settings.relearningSteps.map { String(Int($0)) }.joined(separator: " ")
        }
        .onDisappear { apply() }
    }

    private func apply() {
        let parsedSteps = steps.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }.filter { $0 > 0 }
        let parsedRelearn = relearn.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }.filter { $0 > 0 }
        app.learning.changeState { state in
            if !parsedSteps.isEmpty { state.settings.learningSteps = parsedSteps }
            if !parsedRelearn.isEmpty { state.settings.relearningSteps = parsedRelearn }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<LearningSettings, T>) -> Binding<T> {
        Binding(get: { app.learning.settings[keyPath: keyPath] }, set: { value in app.learning.changeState { $0.settings[keyPath: keyPath] = value } })
    }
}

private struct LearningPauseView: View {
    @Environment(AppModel.self) private var app
    @State private var scope = "alles"
    @State private var target: UUID?
    @State private var start = Date()
    @State private var hasEnd = true
    @State private var end = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var reason = "Urlaub"

    var body: some View {
        let library = app.learning
        VStack(alignment: .leading, spacing: 12) {
            Text("Lernpause").font(.system(size: 14, weight: .semibold))
            Text("Während einer Pause kommen keine Karten. Endet sie, rücken alle Karten, die danach fällig waren, um die Pausenlänge weiter – nach zwei Wochen Urlaub wartet kein Berg.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(library.state.pauses.filter { !$0.applied }) { pause in
                HStack {
                    Image(systemName: pause.isActive() ? "pause.circle.fill" : "calendar.badge.clock").foregroundStyle(Theme.warning)
                    Text((pause.reason.isEmpty ? "Pause" : pause.reason) + " · ab " + pause.start.formatted(date: .abbreviated, time: .omitted)
                         + (pause.end.map { " bis " + $0.formatted(date: .abbreviated, time: .omitted) } ?? " (offen)"))
                        .font(.system(size: 12))
                    Spacer()
                    Button(pause.isActive() ? "Beenden" : "Absagen") {
                        if pause.isActive() { library.endPause(pause.id) } else { library.changeState { $0.pauses.removeAll { $0.id == pause.id } } }
                    }
                }
            }
            Divider()
            Picker("Für", selection: $scope) {
                Text("Alles").tag("alles")
                Text("Eine Disziplin").tag("disziplin")
                Text("Einen Kurs").tag("kurs")
            }
            .pickerStyle(.segmented)
            if scope == "disziplin" {
                Picker("Disziplin", selection: $target) {
                    ForEach(library.state.disciplines) { Text($0.displayName).tag(Optional($0.id)) }
                }
            } else if scope == "kurs" {
                Picker("Kurs", selection: $target) {
                    ForEach(library.courses.records) { Text($0.displayName).tag(Optional($0.id)) }
                }
            }
            DatePicker("Ab", selection: $start, displayedComponents: .date)
            Toggle("Mit Ende", isOn: $hasEnd)
            if hasEnd { DatePicker("Bis", selection: $end, in: start..., displayedComponents: .date) }
            StudioField(placeholder: "Grund (z. B. Urlaub)", text: $reason)
            HStack {
                Spacer()
                Button("Pause planen") {
                    let pauseScope: LearningPause.Scope = switch scope {
                    case "disziplin": target.map(LearningPause.Scope.discipline) ?? .all
                    case "kurs": target.map(LearningPause.Scope.course) ?? .all
                    default: .all
                    }
                    let begin = Calendar.current.isDateInToday(start) ? Date() : Calendar.current.startOfDay(for: start)
                    library.startPause(scope: pauseScope, start: begin, end: hasEnd ? Calendar.current.startOfDay(for: end).addingTimeInterval(LearningScheduler.day) : nil, reason: reason)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 12.5))
        .padding(16)
        .frame(width: 400)
        .environment(\.locale, Locale(identifier: "de_DE"))
    }
}
