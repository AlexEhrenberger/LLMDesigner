import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// The study program in Learning Studio: the built-in catalog, the month plan, the file format and what setting the
/// study up makes in a library. Courses and lessons for the PDF test are made up here.
@Suite("Learning Studio: Studium", .serialized)
@MainActor
struct LearningStudyTests {
    let catalog = StudyCatalog.iuAppliedAI

    // MARK: Catalog

    @Test func theCatalogAddsUpTo180ECTSAndThirtyPerSemester() {
        let codes = catalog.modules.map(\.code)
        #expect(Set(codes).count == codes.count, "jeder Code nur einmal")
        let compulsory = catalog.compulsory.reduce(0) { $0 + $1.ects }
        let electives = catalog.areas.filter { $0.semester != nil }.reduce(0) { $0 + $1.picks * 5 }
        let practical = catalog.options(of: "D").filter { $0.kind != .internship }.reduce(0) { $0 + $1.ects }
        #expect(compulsory == 120)
        #expect(compulsory + electives + practical == catalog.ects)
        #expect(catalog.internship?.ects == practical, "das Praktikum ersetzt die sechs Module")

        var study = LearningStudy(start: StudyMonth(year: 2026, month: 10))
        study.modules = catalog.compulsory.map { StudyModule(code: $0.code) }
        for semester in 1...6 {
            let ects = StudyPlanner.slots(catalog, study).filter { $0.semester == semester }.reduce(0) { $0 + $1.ects }
            #expect(ects == 30, "\(semester). Semester")
        }
    }

    @Test func everyTheoryModuleHasLessonsAndADescriptionOfTheWork() {
        for module in catalog.modules {
            if module.kind == .theory { #expect(!module.lessons.isEmpty, "\(module.title) hat Lektionen") }
            let summary = module.courseSummary(in: catalog)
            #expect(summary.contains(module.code))
            #expect(summary.contains("Prüfung: \(module.exam.detail)"))
            #expect(summary.contains("Was zu tun ist:\n1. "))
            #expect(!module.about.isEmpty)
        }
        let ai = catalog.module("DLBDSEAIS01-01_D")
        #expect(ai?.lessons.first?.title == "Geschichte der KI")
        #expect(ai?.semester == 1 && ai?.exam == .klausur)
        #expect(catalog.options(of: "A").count >= 8 && catalog.options(of: "B").count >= 16 && catalog.options(of: "C").count >= 14)
    }

    // MARK: Months and plan

    @Test func monthsCountAcrossTheYearAndKeepTheirKey() {
        let october = StudyMonth(year: 2026, month: 10)
        #expect(october.adding(3) == StudyMonth(year: 2027, month: 1))
        #expect(october.adding(-10) == StudyMonth(year: 2025, month: 12))
        #expect(october.distance(to: StudyMonth(year: 2029, month: 9)) == 35)
        #expect(october.key == "2026-10")
        #expect(StudyMonth(key: "2027-03") == StudyMonth(year: 2027, month: 3))
        #expect(StudyMonth(key: "2027-13") == nil)
        #expect(StudyMonth(year: 2027, month: 3).label == "März 2027")
    }

    @Test func fullTimeTakesOneModuleAMonthAndEndsWithTheThesis() {
        var study = LearningStudy(start: StudyMonth(year: 2026, month: 10), pace: .fullTime)
        study.modules = catalog.compulsory.map { StudyModule(code: $0.code) }
        let months = StudyPlanner.distribute(catalog, study)
        #expect(months["DLBDSEAIS01-01_D"] == StudyMonth(year: 2026, month: 10), "das erste Modul im ersten Monat")
        #expect(months["DLBDSIPWP01_D"] == StudyMonth(year: 2026, month: 11))
        #expect(months["BBAK"] == StudyMonth(year: 2029, month: 9), "die Bachelorarbeit im 36. Monat")
        #expect(Set(months.values).count == months.count, "kein Monat doppelt, freie Wahlplätze halten ihren Monat frei")

        study.pace = .partTimeLong
        #expect(StudyPlanner.distribute(catalog, study)["BBAK"] == StudyMonth(year: 2026, month: 10).adding(71))
    }

    @Test func theInternshipTakesTheMonthOfTheLastPlaceItReplaces() {
        var study = LearningStudy(start: StudyMonth(year: 2026, month: 10))
        study.modules = catalog.compulsory.map { StudyModule(code: $0.code) }
        study.practical = .internship
        study.modules.append(StudyModule(code: "DLBDSCIBDSC01-01_D"))
        let months = StudyPlanner.distribute(catalog, study)
        #expect(months["DLBDSCIBDSC01-01_D"] == StudyMonth(year: 2029, month: 7), "Platz D des 6. Semesters, vor der Bachelorarbeit")
    }

    // MARK: File

    @Test func theStudyIsWrittenWithGermanKeysAndReadBack() throws {
        var state = LearningState()
        var study = LearningStudy(start: StudyMonth(year: 2026, month: 10), pace: .partTime)
        let course = UUID()
        study.modules = [StudyModule(code: "DLBBIMD01", course: course, month: StudyMonth(year: 2026, month: 12))]
        study.timetable = [StudySlot(weekday: 2, start: 18 * 60 + 30, end: 20 * 60, course: course, title: "Lernen")]
        study.practical = .modules
        state.study = study
        state.settings.showsStudy = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"studium\""))
        #expect(text.contains("\"beginn\":\"2026-10\""))
        #expect(text.contains("\"modell\":\"teilzeit1\""))
        #expect(text.contains("\"monat\":\"2026-12\""))
        #expect(text.contains("\"von\":\"18:30\"") && text.contains("\"bis\":\"20:00\""))
        #expect(text.contains("\"studiumAnzeigen\":true"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(LearningState.self, from: data)
        #expect(read.study?.modules == study.modules)
        #expect(read.study?.timetable == study.timetable)
        #expect(read.study?.pace == .partTime && read.study?.practical == .modules)
        #expect(read.settings.showsStudy)
    }

    @Test func anOlderFileWithoutAStudyStaysWithoutOne() throws {
        let old = #"{"format":1,"disziplinen":[],"einstellungen":{"algorithmus":"fsrs"},"pausen":[]}"#
        let read = try JSONDecoder().decode(LearningState.self, from: Data(old.utf8))
        #expect(read.study == nil)
        #expect(!read.settings.showsStudy)
    }

    @Test func slotsStayWithinTheDay() {
        let slot = StudySlot(weekday: 9, start: 23 * 60 + 58, end: 22 * 60, title: "").normalized()
        #expect(slot.weekday == 7)
        #expect(slot.start == 23 * 60 + 55 && slot.end == 24 * 60)
        #expect(StudySlot.minutes("7:05") == 425 && StudySlot.minutes("25:00") == nil)
    }

    // MARK: In a library

    private func freshStudy(_ app: AppModel) -> LearningStudy {
        app.learning.loadIfNeeded()
        app.learning.changeState { $0.study = nil }
        return app.setUpStudy(start: StudyMonth(year: 2026, month: 10))
    }

    @Test func settingUpMakesACourseForEveryCompulsoryModule() throws {
        let app = TestApp.model()
        let study = freshStudy(app)
        let discipline = try #require(app.learning.discipline(study.discipline))
        #expect(discipline.name == "Angewandte KI (B.Sc.)")
        #expect(study.modules.count == catalog.compulsory.count)
        let entry = try #require(study.module("DLBDSSPDS01-01_D"))
        let course = try #require(entry.course.flatMap(app.learning.course))
        #expect(course.name == "Statistik - Wahrscheinlichkeit und deskriptive Statistik")
        #expect(course.discipline == discipline.id)
        #expect(course.creditPoints == 5 && course.examForm == "Klausur")
        #expect(course.summary.contains("Was zu tun ist"))
        #expect(course.lessons.map(\.title).first == "Wahrscheinlichkeitsrechnung")
        #expect(!(course.lessons.first?.sections.isEmpty ?? true))
        #expect(entry.month == StudyMonth(year: 2027, month: 5), "8. Platz im Vollzeitplan: fünf Module und Platz D im 1. Semester, dann Lineare Algebra")
        #expect(app.setUpStudy().modules == study.modules, "ein zweites Einrichten legt nichts doppelt an")
    }

    @Test func showingTheStudySetsItUpOnceAndHidingKeepsIt() {
        let app = TestApp.model()
        app.learning.loadIfNeeded()
        app.learning.changeState { $0.study = nil }
        app.setStudyShown(true)
        #expect(app.learning.settings.showsStudy)
        let first = app.study
        #expect(first != nil)
        app.setStudyShown(false)
        #expect(!app.learning.settings.showsStudy)
        #expect(app.study == first, "ausgeblendet bleibt alles")
        app.setStudyShown(true)
        #expect(app.study?.modules == first?.modules)
    }

    @Test func electivesAreChosenUpToTheAreasLimitAndLeaveTheirCourseWhenTakenBack() throws {
        let app = TestApp.model()
        _ = freshStudy(app)
        let options = catalog.options(of: "A")
        let first = try #require(app.chooseStudyModule(options[0].code))
        #expect(app.chooseStudyModule(options[1].code) != nil)
        #expect(app.chooseStudyModule(options[2].code) == nil, "Bereich A hat zwei Plätze")
        #expect(app.study?.module(options[0].code)?.month != nil, "ein gewähltes Modul bekommt einen Monat")
        app.removeStudyModule(options[0].code)
        #expect(app.study?.module(options[0].code) == nil)
        #expect(app.learning.course(first.id) != nil, "der Kurs bleibt")
        let again = try #require(app.chooseStudyModule(options[0].code))
        #expect(again.id == first.id, "erneut gewählt kommt derselbe Kurs zurück")
    }

    @Test func areaDIsEitherTheSixModulesOrTheInternship() {
        let app = TestApp.model()
        _ = freshStudy(app)
        let practical = catalog.options(of: "D")
        app.setStudyPractical(.modules)
        #expect(app.study?.practical == .modules)
        #expect(practical.filter { $0.kind != .internship }.allSatisfy { app.study?.module($0.code) != nil })
        app.setStudyPractical(.internship)
        #expect(practical.filter { $0.kind != .internship }.allSatisfy { app.study?.module($0.code) == nil })
        #expect(app.study?.module("DLBDSCIBDSC01-01_D")?.course != nil)
    }

    @Test func aLaterBeginningMovesThePlanAndTheTimetableKeepsItsBlocks() throws {
        let app = TestApp.model()
        let study = freshStudy(app)
        let before = try #require(study.module("BBAK")?.month)
        app.setStudyStart(StudyMonth(year: 2027, month: 1))
        #expect(app.study?.module("BBAK")?.month == before.adding(3))
        app.planStudyModule("BBAK", month: nil)
        #expect(app.study?.module("BBAK")?.month == nil)
        app.distributeStudyPlan()
        #expect(app.study?.module("BBAK")?.month == StudyMonth(year: 2027, month: 1).adding(35))

        let slot = app.addStudySlot(StudySlot(weekday: 3, start: 19 * 60, end: 21 * 60, title: "Lernen"))
        app.updateStudySlot(slot.id) { $0.end = 18 * 60 }
        #expect(app.study?.timetable.first { $0.id == slot.id }?.end == 19 * 60 + 5, "das Ende bleibt nach dem Anfang")
        #expect(app.study?.weeklyMinutes == 5)
        app.removeStudySlot(slot.id)
        #expect(app.study?.timetable.isEmpty == true)
    }

    // MARK: Course from a PDF

    @Test func lessonsFromThePDFTakeOverPlannedLessonsAtTheirPlace() async throws {
        let app = TestApp.model()
        let course = app.newCourse(name: "Wolkenkunde \(UUID().uuidString.prefix(6))", in: nil)
        let planned = try #require(app.addLesson(title: "Luftdruck und Wind", to: course.id))
        let named = try #require(app.addLesson(title: "Wolken", to: course.id))
        let material = LearningMaterial(kind: .pdf, title: "Skript", file: "fehlt.pdf")
        app.learning.courses.update(course.id) { $0.materials.append(material) }
        let detected = [
            DetectedLesson(title: "Luftdruck", firstPage: 3, lastPage: 9),
            DetectedLesson(title: "Wolken", firstPage: 10, lastPage: 18),
            DetectedLesson(title: "Niederschlag", firstPage: 19, lastPage: 25),
        ]
        let ids = await app.addDetectedLessons(detected, material: material.id, to: course.id)
        let lessons = try #require(app.learning.course(course.id)?.lessons)
        #expect(lessons.count == 3, "nichts doppelt")
        #expect(ids[0] == planned.id && lessons[0].title == "Luftdruck" && lessons[0].firstPage == 3, "die geplante Lektion übernimmt Titel und Seiten des Skripts")
        #expect(ids[1] == named.id && lessons[1].firstPage == 10, "gleichnamige Lektion wie bisher")
        #expect(lessons[2].title == "Niederschlag")
        app.learning.courses.delete(course.id, label: "", undo: nil)
    }
}

extension ActionSuites {
@MainActor
@Suite("Learning Studio: Studium über learning.settings und learning.studio.open", .serialized)
struct LearningStudyActionTests {
    let h = ActionHarness()

    @Test func theStudyOpensOnlyWhenTheLibraryShowsIt() async throws {
        h.app.learning.loadIfNeeded()
        let shown = h.app.learning.settings.showsStudy
        defer { h.app.learning.changeState { $0.settings.showsStudy = shown } }
        try await h.call("learning.settings", ["showsStudy": false])
        #expect(await h.errorCode("learning.studio.open", ["study": "stundenplan"]) == RPCError.invalidParamsCode)
        let settings = try await h.call("learning.settings", ["showsStudy": true])
        #expect(settings["studiumAnzeigen"] == true)
        #expect(h.app.study != nil, "eingeschaltet ist das Studium angelegt")
        try await h.call("learning.studio.open", ["study": "monatsplan"])
        #expect(h.app.learningStudioOpen)
        #expect(h.app.learningStudioCommand?.study == .months)
        #expect(await h.errorCode("learning.studio.open", ["study": "semester"]) == RPCError.invalidParamsCode)
        let course = try #require(h.app.study?.modules.first?.course)
        #expect(await h.errorCode("learning.studio.open", ["study": "module", "course": .string(course.uuidString)]) == RPCError.invalidParamsCode)
        try await h.call("learning.studio.close")
    }
}
}
