import Testing
import Foundation
@testable import LLMDesigner

/// Lessons in Learning Studio: the structure found in a PDF, the text the model reads, the line formats it answers in,
/// the test's plan and grade, and the lesson's cards. All test material is made up here.
@Suite("Learning Studio: Lektionen, Gliederung, Test")
struct LearningLessonTests {
    // MARK: Structure

    @Test func bookmarksGiveLessonsAndSectionsAndLeaveOutFrontAndBackMatter() {
        let entries = [
            CourseOutline.Entry(title: "Wetterkunde für Einsteiger", page: 1, children: [
                CourseOutline.Entry(title: "Inhaltsverzeichnis", page: 3),
                CourseOutline.Entry(title: "Einleitung", page: 5, children: [CourseOutline.Entry(title: "Wegweiser", page: 6)]),
                CourseOutline.Entry(title: "Lektion 1: Luftdruck", page: 9, children: [
                    CourseOutline.Entry(title: "Hoch und Tief", page: 10),
                    CourseOutline.Entry(title: "Isobaren", page: 14),
                ]),
                CourseOutline.Entry(title: "WOLKEN", page: 20, children: [CourseOutline.Entry(title: "Wolkenarten", page: 21)]),
                CourseOutline.Entry(title: "Anhang", page: 30, children: [CourseOutline.Entry(title: "Literaturverzeichnis", page: 31)]),
            ]),
        ]
        let lessons = CourseOutline.lessons(fromBookmarks: entries, pageCount: 34)
        #expect(lessons.map(\.title) == ["Inhaltsverzeichnis", "Einleitung", "Luftdruck", "Wolken", "Anhang"], "die Buchklammer fällt weg, Großschrift wird gemildert")
        #expect(lessons.filter(\.included).map(\.title) == ["Luftdruck", "Wolken"])
        let first = lessons[2]
        #expect(first.firstPage == 9 && first.lastPage == 19)
        #expect(first.sections.map(\.title) == ["Hoch und Tief", "Isobaren"])
        #expect(first.sections[0].firstPage == 10 && first.sections[0].lastPage == 13)
        #expect(first.sections[1].lastPage == 19)
        #expect(lessons[4].lastPage == 34)
    }

    @Test func headingsOnPagesGiveLessonsWhenThereAreNoBookmarks() {
        var pages = Array(repeating: "Fließtext über das Wetter. ", count: 14)
        pages[0] = "WETTERKUNDE\nEin Skript"
        pages[1] = "INHALTSVERZEICHNIS\nLektion 1\nLuftdruck . . . . . 3\n1.1 Hoch und Tief . . . . 3\nLektion 2\nWolken und Niederschlag . . . . 8"
        pages[2] = "Literaturempfehlungen\nLektion 2\nMeier, K. (2019). Wolkenatlas. Berlin: Verlag."
        pages[3] = "LEKTION 1\nLUFTDRUCK\nLERNZIELE\nNach der Bearbeitung dieser Lektion werden Sie in der Lage sein, …\n– Hoch- und Tiefdruckgebiete zu\nunterscheiden.\n– Isobaren zu lesen."
        pages[4] = "1. LUFTDRUCK\n1.1 Hoch und Tief\nIm Hoch sinkt die Luft ab."
        pages[6] = "1.2 Wichtige regionale\nWindsysteme\nDer Föhn ist ein warmer Fallwind."
        pages[8] = "LEKTION 2\nWOLKEN UND NIEDERSCHLAG\nLERNZIELE"
        pages[9] = "2.1 Wolkenarten\nCumulus und Stratus."
        let lessons = CourseOutline.lessons(fromPages: pages)
        #expect(lessons.map(\.title) == ["Luftdruck", "Wolken und Niederschlag"], "die Schreibweise kommt aus dem Inhaltsverzeichnis, die Literaturliste zählt nicht")
        #expect(lessons[0].firstPage == 4 && lessons[0].lastPage == 8)
        #expect(lessons[0].sections.map(\.title) == ["1.1 Hoch und Tief", "1.2 Wichtige regionale Windsysteme"], "die zweite Zeile eines Titels gehört dazu")
        #expect(lessons[1].firstPage == 9)
        #expect(CourseOutline.goals(in: pages[3]) == ["Hoch- und Tiefdruckgebiete zu unterscheiden.", "Isobaren zu lesen."])
    }

    @Test func lessonHeadingsNeedANumberAndNoRunningText() {
        #expect(CourseOutline.lessonHeading("LEKTION 3")?.number == 3)
        #expect(CourseOutline.lessonHeading("Kapitel 2: Böden")?.rest == "Böden")
        #expect(CourseOutline.lessonHeading("Kapitel 3 behandelt die Böden") == nil)
        #expect(CourseOutline.lessonHeading("Lektionen über das Wetter") == nil)
        #expect(CourseOutline.sectionHeading("1.1 Definitionen 12") == nil, "Seitenzahl am Ende: Inhaltsverzeichnis")
        #expect(CourseOutline.sectionHeading("3.4 Bedingte Verteilungen")?.key == "3.4")
        #expect(CourseOutline.sectionHeading("1.5 kg Mehl") == nil)
    }

    // MARK: Text

    @Test func pageTextIsCleanedAndCutIntoPieces() {
        let text = LessonText.clean([(page: 3, text: "Die Wahrschein-\nlichkeit eines Corona-\nSchnelltests\n17"), (page: 4, text: "\n\n")])
        #expect(text == "[Seite 3]\nDie Wahrscheinlichkeit eines Corona-Schnelltests")
        let page = String(repeating: "Ein Satz über Wolken. ", count: 120)
        let pages = (1...10).map { (page: $0, text: page) }
        let pieces = LessonText.pieces(LessonText.clean(pages), limit: 7_000)
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.count <= 8_750 })
        #expect(pieces.joined().contains("[Seite 10]"))
        #expect(LessonText.pieces("kurz", limit: 7_000) == ["kurz"])
    }

    // MARK: The model's line formats

    @Test func questionsAreReadAlsoWhenTheModelBendsTheForm() {
        let answer = """
        FRAGE: Was ist ein Hochdruckgebiet?
        LÖSUNG: Ein Gebiet, in dem die Luft absinkt und der Druck hoch ist.
        ERWARTUNG: Luft sinkt ab | hoher Druck

        ---

        **FRAGE:** Welche Wolke bringt Gewitter?
        RICHTIG: Cumulonimbus
        FALSCH: Cirrus
        FALSCH: Stratus | Altocumulus
        LÖSUNG: Nur die Cumulonimbus reicht hoch genug.
        ---
        FRAGE: Welche Aussage über Isobaren stimmt?
        A) Sie verbinden Orte gleicher Temperatur.
        B) Sie verbinden Orte gleichen Luftdrucks.
        C) Sie zeigen die Windstärke direkt an.
        RICHTIG: B
        FALSCH: A (das beschreibt Isothermen)
        LÖSUNG: Isobaren verbinden Orte gleichen Drucks.
        FRAGE: Berechne den Druckunterschied
        zwischen 1020 hPa und 995 hPa.
        LÖSUNG: Es sind 25 hPa.
        """
        let parsed = LessonPrompts.parseQuestions(answer)
        #expect(parsed.count == 4, "auch ohne --- vor einer neuen FRAGE")
        #expect(parsed[0].expected == "Luft sinkt ab | hoher Druck")
        #expect(!parsed[0].isChoice)
        #expect(parsed[1].right == "Cumulonimbus")
        #expect(parsed[1].wrong == ["Cirrus", "Stratus", "Altocumulus"])
        #expect(parsed[2].right == "Sie verbinden Orte gleichen Luftdrucks.")
        #expect(parsed[2].wrong.count == 2)
        #expect(parsed[3].question == "Berechne den Druckunterschied\nzwischen 1020 hPa und 995 hPa.")

        let slot = LessonPrompts.QuestionSlot(kind: .choice, level: "Wissen")
        let item = LessonPrompts.item(from: parsed[1], slot: slot, section: "1.1 Wolken") { $0.reverse() }
        #expect(item.kind == .choice)
        #expect(item.options.count == 4)
        #expect(item.correctText == "Cumulonimbus", "die richtige Antwort wird nach dem Mischen wiedergefunden")
        #expect(item.correctOption == 3)
        let open = LessonPrompts.item(from: parsed[0], slot: LessonPrompts.QuestionSlot(kind: .open, level: "Wissen"), section: "1.1")
        #expect(open.kind == .open && open.solution.hasPrefix("Ein Gebiet"))
    }

    @Test func gradesAreRead() {
        #expect(LessonPrompts.parseGrade("BEWERTUNG: richtig\nRÜCKMELDUNG: Stimmt genau.").verdict == .richtig)
        let partly = LessonPrompts.parseGrade("**BEWERTUNG:** teilweise richtig\nRÜCKMELDUNG: Der Ansatz stimmt,\naber das Ergebnis fehlt.")
        #expect(partly.verdict == .teilweise)
        #expect(partly.feedback == "Der Ansatz stimmt, aber das Ergebnis fehlt.")
        #expect(LessonPrompts.parseGrade("Die Antwort ist falsch.").verdict == .falsch)
    }

    @Test func gradeScaleRunsFromAToF() {
        #expect(LessonGrade(score: 1) == .a)
        #expect(LessonGrade(score: 0.9) == .a)
        #expect(LessonGrade(score: 0.8999) == .b)
        #expect(LessonGrade(score: 0.7) == .c)
        #expect(LessonGrade(score: 0.6) == .d)
        #expect(LessonGrade(score: 0.5) == .e)
        #expect(LessonGrade(score: 0.4999) == .f)
        #expect(!LessonGrade.f.passed && LessonGrade.e.passed)
    }

    @Test func aTestMixesOpenAndChoiceQuestionsOverTheWholeLesson() {
        let slots = LessonPrompts.slots(count: 20)
        let choices = slots.filter { $0.kind == .choice }.count
        #expect(choices == 6, "etwa ein Drittel mit Auswahl")
        #expect(Set(slots.filter { $0.kind == .open }.map(\.level)) == ["Wissen", "Verständnis", "Anwendung"])

        let sources = [(section: "1.1 Kurz", text: String(repeating: "a", count: 500)),
                       (section: "1.2 Lang", text: String(repeating: "b", count: 6_000)),
                       (section: "1.2 Lang", text: String(repeating: "c", count: 6_000)),
                       (section: "1.3 Mittel", text: String(repeating: "d", count: 2_500))]
        let plan = AppModel.testPlan(sources: sources, count: 20)
        #expect(plan.reduce(0) { $0 + $1.slots.count } == 20)
        #expect(plan.allSatisfy { $0.slots.count <= 3 })
        #expect(Set(plan.map(\.section)) == ["1.1 Kurz", "1.2 Lang", "1.3 Mittel"], "jeder Teil bekommt Fragen")
        #expect(plan.map(\.slots).joined().map(\.kind) == slots.map(\.kind), "die Arten bleiben in ihrer Reihenfolge")
        #expect(AppModel.testPlan(sources: sources, count: 2).reduce(0) { $0 + $1.slots.count } == 2)
    }

    @Test func repeatedQuestionsAreDropped() {
        var first = QuizItem(question: "Was beschreibt eine Isobare auf der Wetterkarte?")
        first.section = "1.1"
        let again = QuizItem(question: "Was beschreibt eine Isobare auf der Wetterkarte genau?")
        let other = QuizItem(question: "Wie entsteht Föhn an den Alpen?")
        let kept = AppModel.withoutRepeats([again, other], asked: [first.question])
        #expect(kept.map(\.question) == [other.question])
    }

    @MainActor
    @Test func sectionsOfTheSummaryAreTidied() {
        let raw = """
        ## 1.1 Hoch und Tief
        Im Hoch sinkt die Luft ab.
        ### Druck
        $$ p = \\rho R T $$
        #### Merke
        Text.
        """
        let clean = LessonPrompts.cleanSection(raw)
        #expect(!clean.contains("## 1.1"))
        #expect(clean.contains("$$\np = \\rho R T\n$$"))
        #expect(clean.contains("**Merke**"))
        #expect(LessonPrompts.cleanAbstract("## Abstract\n- Erster Satz.\n- Zweiter **Satz**.") == "Erster Satz. Zweiter Satz.")
        #expect(AppModel.slideLine("1.3 Bedingte Wahrscheinlichkeiten") == "Bedingte Wahrscheinlichkeiten")
        #expect(AppModel.slideLine("2. Folie") == "Folie" && AppModel.slideLine("2024 im Rückblick") == "2024 im Rückblick")
        #expect(LessonPrompts.cleanNotes("Hier sind die Lernnotizen:\n\n### Kernaussagen\nA") == "### Kernaussagen\nA")
        #expect(LessonPrompts.cleanNotes("### Begriffe\n- B") == "### Begriffe\n- B")
        let loop = String(repeating: "Bei welcher Variante spielt die Reihenfolge eine Rolle? ", count: 5)
        #expect(LessonPrompts.isRepetitive(loop))
        #expect(!LessonPrompts.isRepetitive("Ein Satz. Ein anderer Satz. Noch ein dritter Satz."))
    }

    // MARK: Format

    @Test func olderCoursesStillLoadAndLessonsRoundTrip() throws {
        let old = #"{"id":"6D2B7E26-2B4F-4C7B-9F0E-5D4E0E9A0C11","name":"Alt","karten":[{"vorne":"F","hinten":"A"}],"abfragen":[{"fragen":[{"frage":"Q","bewertung":"richtig"}]}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let course = try decoder.decode(LearningCourse.self, from: Data(old.utf8))
        #expect(course.lessons.isEmpty && course.cards.first?.lesson == nil && course.quizzes.first?.isTest == false)

        var lesson = LearningLesson(title: "Luftdruck", abstract: "Kurz.")
        lesson.sections = [LessonSection(title: "Hoch und Tief", firstPage: 10, lastPage: 13)]
        lesson.built = [.summary, .reading]
        lesson.firstPage = 9
        var next = course
        next.creditPoints = 5
        next.examForm = "Klausur"
        next.lessons = [lesson]
        next.cards[0].lesson = lesson.id
        var test = QuizSession(lesson: lesson.id, planned: 15)
        var item = QuizItem(question: "Welche?", kind: .choice)
        item.options = ["x", "y"]
        item.correctOption = 1
        item.chosenOption = 1
        item.verdict = .richtig
        test.items = [item]
        test.grade = .b
        test.assessment = "Gut."
        next.quizzes.append(test)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(next)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""erstellt":["lesen","zusammenfassung"]"#), "Schritte in fester Reihenfolge")
        let back = try decoder.decode(LearningCourse.self, from: data)
        #expect(back.titleWithFacts == "Alt (5 CP, Klausur)")
        #expect(back.lessons.first?.sections.first?.lastPage == 13)
        #expect(back.lessons.first?.built == [.reading, .summary])
        #expect(back.lessons.first?.pageLabel == "S. 9")
        #expect(back.cards.first?.lesson == lesson.id)
        #expect(back.quizzes.last?.grade == .b && back.quizzes.last?.items.first?.correctText == "y")
        #expect(back.latestGrade(of: lesson.id)?.assessment == "Gut.")
    }
}
