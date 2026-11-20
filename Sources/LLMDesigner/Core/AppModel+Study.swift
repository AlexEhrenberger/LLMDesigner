import Foundation

extension AppModel {
    // MARK: Showing and setting up

    var study: LearningStudy? { learning.state.study }

    var studyCatalog: StudyCatalog? { study.flatMap { StudyCatalog.named($0.catalog) } }

    /// Shows or hides the study tab of this library. Shown for the first time, the study is set up with its modules,
    /// so they are there when the tab opens; hidden, everything stays.
    func setStudyShown(_ shown: Bool) {
        learning.loadIfNeeded()
        learning.changeState { $0.settings.showsStudy = shown }
        if shown, learning.state.study == nil { setUpStudy() }
    }

    /// The study with a course for every compulsory module, in a discipline of its own, planned month by month after
    /// the study model. Electives come when they are chosen.
    @discardableResult
    func setUpStudy(_ catalog: StudyCatalog = .iuAppliedAI, start: StudyMonth = StudyMonth(Date()), pace: StudyPace = .fullTime) -> LearningStudy {
        learning.loadIfNeeded()
        if let existing = learning.state.study { return existing }
        var study = LearningStudy(catalog: catalog.id, start: start, pace: pace)
        study.discipline = studyDiscipline(catalog, study).id
        for module in catalog.compulsory {
            let course = makeStudyCourse(module, catalog: catalog, study: study)
            study.modules.append(StudyModule(code: module.code, course: course.id))
        }
        let months = StudyPlanner.distribute(catalog, study)
        for index in study.modules.indices { study.modules[index].month = months[study.modules[index].code] }
        let made = study
        learning.changeState { $0.study = made }
        return made
    }

    /// The study's discipline; made again when it was removed.
    private func studyDiscipline(_ catalog: StudyCatalog, _ study: LearningStudy) -> LearningDiscipline {
        if let discipline = learning.discipline(study.discipline) { return discipline }
        if let named = learning.state.disciplines.first(where: { $0.name == catalog.shortName }) { return named }
        return newDiscipline(name: catalog.shortName, tree: .ahorn, color: .blue)
    }

    /// The course of a module: one of the study's discipline with the module's name that no other module uses, else a
    /// new one with the module's description, its exam and the lessons of its script.
    private func makeStudyCourse(_ module: StudyCatalog.Module, catalog: StudyCatalog, study: LearningStudy) -> LearningCourse {
        let discipline = studyDiscipline(catalog, study).id
        let used = Set(study.modules.compactMap(\.course))
        if let existing = learning.courses(in: discipline).first(where: { $0.name == module.title && !used.contains($0.id) }) {
            return existing
        }
        var course = LearningCourse(discipline: discipline, name: module.title)
        course.summary = module.courseSummary(in: catalog)
        course.creditPoints = module.ects
        course.examForm = module.exam.label
        course.symbol = module.kind.symbol
        course.color = Self.studyColor(module, in: catalog)
        course.lessons = module.lessons.map { lesson in
            var made = LearningLesson(title: lesson.title)
            made.sections = lesson.sections.map { LessonSection(title: $0) }
            return made
        }
        // The garden lists a discipline's courses by creation; a few milliseconds apart keep the curriculum's order.
        course.createdAt = Date().addingTimeInterval(Double(learning.courses.records.count) * 0.001)
        course.updatedAt = course.createdAt
        return learning.courses.add(course)
    }

    /// One colour per semester, so the plans read at a glance.
    static func studyColor(_ module: StudyCatalog.Module, in catalog: StudyCatalog) -> FolderColor {
        if module.kind == .thesis { return .red }
        if module.area == "D" { return .yellow }
        switch StudyPlanner.semester(of: module, in: catalog) ?? 0 {
        case 1: return .green
        case 2: return .teal
        case 3: return .blue
        case 4: return .purple
        case 5: return .pink
        case 6: return .orange
        default: return .yellow
        }
    }

    private func changeStudy(_ change: (inout LearningStudy) -> Void) {
        learning.changeState { state in
            guard var study = state.study else { return }
            change(&study)
            state.study = study
        }
    }

    // MARK: Modules

    /// Takes an elective: its course is made (or found again) and it gets the month the model has for it.
    @discardableResult
    func chooseStudyModule(_ code: String) -> LearningCourse? {
        guard let study, let catalog = studyCatalog, let module = catalog.module(code) else { return nil }
        if let taken = study.module(code), let course = taken.course.flatMap(learning.course) { return course }
        if let area = catalog.area(module.area), area.semester != nil {
            let chosen = study.modules.filter { catalog.module($0.code)?.area == area.id }.count
            guard chosen < area.picks else { return nil }
        }
        let course = makeStudyCourse(module, catalog: catalog, study: study)
        changeStudy { study in
            if let index = study.modules.firstIndex(where: { $0.code == code }) {
                study.modules[index].course = course.id
            } else {
                study.modules.append(StudyModule(code: code, course: course.id))
            }
            if study.module(code)?.month == nil {
                let month = StudyPlanner.distribute(catalog, study)[code]
                study.updateModule(code) { $0.month = month }
            }
        }
        return course
    }

    /// Takes a module back out of the study; its course stays in the garden with everything learned.
    func removeStudyModule(_ code: String) {
        changeStudy { $0.modules.removeAll { $0.code == code } }
    }

    /// A course for a module whose course was deleted.
    @discardableResult
    func recreateStudyCourse(_ code: String) -> LearningCourse? {
        guard let study, let catalog = studyCatalog, let module = catalog.module(code), study.module(code) != nil else { return nil }
        changeStudy { $0.updateModule(code) { $0.course = nil } }
        guard let current = self.study else { return nil }
        let course = makeStudyCourse(module, catalog: catalog, study: current)
        changeStudy { $0.updateModule(code) { $0.course = course.id } }
        return course
    }

    /// Area D: the six modules or the internship. Switching takes the other choice's modules out; their courses stay.
    func setStudyPractical(_ choice: StudyPractical?) {
        guard let catalog = studyCatalog else { return }
        let options = catalog.options(of: "D")
        let keep = options.filter { choice == .internship ? $0.kind == .internship : (choice == .modules && $0.kind != .internship) }
        changeStudy { study in
            study.practical = choice
            study.modules.removeAll { entry in options.contains { $0.code == entry.code } && !keep.contains { $0.code == entry.code } }
        }
        for module in keep { chooseStudyModule(module.code) }
    }

    // MARK: Plan

    /// Plans a module for a month (nil: not planned).
    func planStudyModule(_ code: String, month: StudyMonth?) {
        changeStudy { $0.updateModule(code) { $0.month = month } }
    }

    /// Every module gets the month the study model has for it.
    func distributeStudyPlan() {
        guard let catalog = studyCatalog else { return }
        changeStudy { study in
            let months = StudyPlanner.distribute(catalog, study)
            for index in study.modules.indices { study.modules[index].month = months[study.modules[index].code] }
        }
    }

    /// A new beginning moves the whole plan by as many months.
    func setStudyStart(_ month: StudyMonth) {
        changeStudy { study in
            let shift = study.start.distance(to: month)
            guard shift != 0 else { return }
            study.start = month
            for index in study.modules.indices { study.modules[index].month = study.modules[index].month?.adding(shift) }
        }
    }

    func setStudyPace(_ pace: StudyPace) {
        changeStudy { $0.pace = pace }
    }

    // MARK: Timetable

    @discardableResult
    func addStudySlot(_ slot: StudySlot) -> StudySlot {
        let made = slot.normalized()
        changeStudy { $0.timetable.append(made) }
        return made
    }

    func updateStudySlot(_ id: UUID, _ change: (inout StudySlot) -> Void) {
        changeStudy { study in
            guard let index = study.timetable.firstIndex(where: { $0.id == id }) else { return }
            change(&study.timetable[index])
            study.timetable[index] = study.timetable[index].normalized()
        }
    }

    func removeStudySlot(_ id: UUID) {
        changeStudy { $0.timetable.removeAll { $0.id == id } }
    }
}
