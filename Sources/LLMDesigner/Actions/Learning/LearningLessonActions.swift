import Foundation
import LLMDProtocol

/// Lessons of a course, the automatic creation from a PDF and the results of lesson tests.
extension ActionRegistry {
    func registerLearningLessonActions() {
        register(LearningLessonListAction.self)
        register(LearningLessonCreateAction.self)
        register(LearningLessonUpdateAction.self)
        register(LearningLessonDeleteAction.self)
        register(LearningBuildStartAction.self)
        register(LearningBuildStatusAction.self)
        register(LearningBuildCancelAction.self)
        register(LearningTestListAction.self)
    }
}

let lessonProperty: JSONSchema = .string("Lektion (ID, Nummer ab 1 oder Titel)")

extension LearningCourse {
    func actionLesson(_ reference: String) throws -> LearningLesson {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let lesson = lesson(id) { return lesson }
        if let number = Int(reference), number >= 1, number <= lessons.count { return lessons[number - 1] }
        let found = lessons.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let partial = lessons.filter { $0.displayTitle.localizedCaseInsensitiveContains(reference) }
        if found.isEmpty, partial.count == 1 { return partial[0] }
        if found.isEmpty, partial.isEmpty { throw RPCError.notFound("Lektion „\(reference)“ gibt es in „\(displayName)“ nicht.") }
        throw RPCError.ambiguous("Mehrere Lektionen passen zu „\(reference)“. Bitte die Nummer oder ID verwenden.", candidates: (found.isEmpty ? partial : found).map(\.id.uuidString))
    }

    func actionMaterial(_ reference: String) throws -> LearningMaterial {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = materials.first(where: { $0.id.uuidString == reference || $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }) { return found }
        throw RPCError.notFound("Material „\(reference)“ gibt es in „\(displayName)“ nicht.")
    }
}

// MARK: - Lessons

struct LearningLessonListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var abstracts: Bool?
    }
    struct Lesson: Encodable, Sendable {
        var id: String
        var number: Int
        var title: String
        var abstract: String?
        var pages: String?
        var sections: [String]
        var due: Int
        var cards: Int
        var built: [String]
        var summaryDocument: String?
        var presentation: String?
        var grade: String?
        var score: Int?
    }
    struct Output: Encodable, Sendable {
        var course: String
        var title: String
        var lessons: [Lesson]
        var standing: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.lesson.list", summary: "Listet die Lektionen eines Kurses: Abschnitte, Seiten, fällige und alle Karten, was erstellt ist und die letzte Testnote",
        kind: .read, security: learningRead,
        input: .object(["course": courseProperty, "abstracts": .boolean("Die Abstracts mitliefern")], required: ["course"]), output: .freeObject(),
        groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let lessons = course.lessons.enumerated().map { index, lesson in
            let counts = app.learning.lessonCounts(course.id, lesson: lesson.id)
            let test = course.latestGrade(of: lesson.id)
            return Lesson(id: lesson.id.uuidString, number: index + 1, title: lesson.displayTitle, abstract: args.abstracts == true ? lesson.abstract : nil,
                          pages: lesson.pageLabel, sections: lesson.sections.enumerated().map { app.sectionLabel($1, index: $0, lessonNumber: index + 1) },
                          due: counts.due, cards: counts.total, built: LessonBuildStep.allCases.filter(lesson.built.contains).map(\.rawValue),
                          summaryDocument: lesson.summaryDocument?.uuidString, presentation: lesson.presentation?.uuidString,
                          grade: test?.grade?.rawValue, score: test?.score.map { Int(($0 * 100).rounded()) })
        }
        let standing = app.learning.standing(course.id).map { "\($0.grade.rawValue) (\($0.tested) von \($0.lessons) Lektionen getestet)" }
        return Output(course: course.id.uuidString, title: course.titleWithFacts, lessons: lessons, standing: standing)
    }
}

struct LearningLessonCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var title: String
        var abstract: String?
        var position: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.lesson.create", summary: "Legt eine Lektion in einem Kurs an (am Ende oder an einer Stelle ab 1)", kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "title": .string("Titel"), "abstract": .string("Abstract"), "position": .integer("Stelle ab 1 (Vorgabe: am Ende)", minimum: 1, maximum: 500)],
                       required: ["course", "title"]), output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RPCError.invalidParams("title ist leer.") }
        let lesson = LearningLesson(title: title, abstract: args.abstract ?? "")
        try context.changeCourse(course.id, label: "Lektion anlegen") { course in
            course.lessons.insert(lesson, at: min(max(0, (args.position ?? (course.lessons.count + 1)) - 1), course.lessons.count))
        }
        return OKOutput(id: lesson.id.uuidString)
    }
}

struct LearningLessonUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var lesson: String
        var title: String?
        var abstract: String?
        var position: Int?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.lesson.update", summary: "Ändert Titel oder Abstract einer Lektion oder verschiebt sie an eine andere Stelle", kind: .write, security: .localWrite,
        input: .object(["course": courseProperty, "lesson": lessonProperty, "title": .string("Titel"), "abstract": .string("Abstract"),
                        "position": .integer("Neue Stelle ab 1", minimum: 1, maximum: 500)], required: ["course", "lesson"]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let lesson = try course.actionLesson(args.lesson)
        if let title = args.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RPCError.invalidParams("title ist leer.") }
        try context.changeCourse(course.id, label: "Lektion ändern") { course in
            course.updateLesson(lesson.id) { lesson in
                if let title = args.title { lesson.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let abstract = args.abstract { lesson.abstract = abstract }
            }
            if let position = args.position, let from = course.lessons.firstIndex(where: { $0.id == lesson.id }) {
                let moved = course.lessons.remove(at: from)
                course.lessons.insert(moved, at: min(max(0, position - 1), course.lessons.count))
            }
        }
        return OKOutput(id: lesson.id.uuidString)
    }
}

struct LearningLessonDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var lesson: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.lesson.delete", summary: "Entfernt eine Lektion; ihre Karten und ihr Material bleiben im Kurs, ihre Dokumente in der Seitenleiste",
        kind: .destructive, security: .destructive,
        input: .object(["course": courseProperty, "lesson": lessonProperty], required: ["course", "lesson"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let course = try context.app.actionCourse(args.course)
        let lesson = try course.actionLesson(args.lesson)
        return ActionPreflight(target: lesson.displayTitle, detail: "\(course.cards(of: lesson.id).count) Karten bleiben ohne Lektion im Kurs")
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let course = try context.app.actionCourse(args.course)
        let lesson = try course.actionLesson(args.lesson)
        let library = context.app.learning.courses
        context.app.deleteLesson(lesson.id, from: course.id)
        context.undoGroup.add(UndoStep(label: "Lektion entfernen", undo: { [weak library] in library?.restore(course) }, redo: {}))
        return OKOutput(id: lesson.id.uuidString)
    }
}

// MARK: - Creation from a PDF

struct LearningBuildStartAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var material: String?
        var lessons: [String]?
        var summary: Bool?
        var cards: Bool?
        var cardsPerSection: Int?
        var analysis: Bool?
        var presentation: Bool?
        var speakerNotes: Bool?
    }
    struct Output: Encodable, Sendable {
        var lessons: [String]
        var source: String?
        var message: String
    }
    static let descriptor = ActionDescriptor(
        id: "learning.build.start",
        summary: "Erstellt Lektionen aus dem Skript (PDF-Material des Kurses): Gliederung aus der PDF, dann je Lektion Lernnotizen, ausführliche Zusammenfassung, Karten, Inhaltsanalyse und Präsentation mit Moderatorenkarten; läuft im Hintergrund",
        kind: .write, security: ActionSecurity(readsUntrusted: true, sensitive: false, effect: .local),
        input: .object([
            "course": courseProperty,
            "material": .string("PDF des Kurses (ID oder Titel); ohne: die Lektionen, die der Kurs schon hat"),
            "lessons": .array(of: .string(), "Nur diese Lektionen (ID, Nummer oder Titel)"),
            "summary": .boolean("Zusammenfassung (Vorgabe ja)"), "cards": .boolean("Karteikarten (Vorgabe ja)"),
            "cardsPerSection": .integer("Karten je Abschnitt (Vorgabe 5)", minimum: 1, maximum: 12),
            "analysis": .boolean("Inhaltsanalyse (Vorgabe ja)"), "presentation": .boolean("Präsentation (Vorgabe ja)"),
            "speakerNotes": .boolean("Moderatorenkarten (Vorgabe ja)"),
        ], required: ["course"]),
        output: .freeObject(), example: "llmd learning build start --course Statistik --material Skript"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var course = try app.actionCourse(args.course)
        var options = course.buildOptions ?? CourseBuildOptions()
        if let value = args.summary { options.summary = value }
        if let value = args.cards { options.cards = value }
        if let value = args.cardsPerSection { options.cardsPerSection = min(12, max(1, value)) }
        if let value = args.analysis { options.analysis = value }
        if let value = args.presentation { options.presentation = value }
        if let value = args.speakerNotes { options.speakerNotes = value }
        var source: String?
        if let reference = args.material {
            let material = try course.actionMaterial(reference)
            guard material.kind == .pdf || material.kind == .probeklausur, material.file != nil else {
                throw RPCError.invalidParams("„\(material.displayTitle)“ ist keine PDF des Kurses.")
            }
            let result = try await app.detectLessons(material: material.id, in: course.id)
            guard !result.lessons.filter(\.included).isEmpty else {
                throw RPCError.invalidParams("In „\(material.displayTitle)“ ließ sich keine Gliederung finden. Lege die Lektionen mit learning.lesson.create an.")
            }
            if course.name.trimmingCharacters(in: .whitespaces).isEmpty, let title = result.title {
                try context.changeCourse(course.id, label: "Kursname") { $0.name = title }
            }
            let before = course
            await app.addDetectedLessons(result.lessons, material: material.id, to: course.id)
            let library = app.learning.courses
            context.undoGroup.add(UndoStep(label: "Lektionen aus PDF", undo: { [weak library] in library?.restore(before) }, redo: {}))
            source = result.source == .bookmarks ? "Lesezeichen der PDF" : "Überschriften der Seiten"
            course = try app.actionCourse(course.id.uuidString)
        }
        let wanted = try args.lessons.map { try $0.map { try course.actionLesson($0) } } ?? course.lessons
        let buildable = wanted.filter { $0.material != nil }
        guard !buildable.isEmpty else {
            throw RPCError.invalidParams("Keine Lektion hat PDF-Seiten. Gib material an (eine PDF des Kurses), damit die Gliederung daraus entsteht.")
        }
        app.buildLessons(buildable.map(\.id), in: course.id, options: options)
        return Output(lessons: buildable.map(\.displayTitle), source: source,
                      message: "\(buildable.count) Lektion(en) werden im Hintergrund erstellt; den Stand zeigt learning.build.status.")
    }
}

struct LearningBuildStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var running: Bool
        var course: String?
        var lesson: String?
        var step: String?
        var detail: String?
        var progress: Int?
        var waiting: [String]
        var errors: [String: String]
        var stopped: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.build.status", summary: "Zeigt, woran die Kurserstellung gerade arbeitet: Lektion, Schritt, Fortschritt, wartende Lektionen und Fehler",
        kind: .read, security: .plainRead, output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        let build = app.courseBuild
        func title(_ job: CourseBuildCenter.Job) -> String { app.learning.course(job.course)?.lesson(job.lesson)?.displayTitle ?? job.lesson.uuidString }
        var errors: [String: String] = [:]
        for (lesson, error) in build.errors {
            let name = app.learning.courses.records.lazy.compactMap { $0.lesson(lesson)?.displayTitle }.first ?? lesson.uuidString
            errors[name] = error
        }
        return Output(running: build.isRunning, course: build.current.flatMap { app.learning.course($0.course)?.displayName },
                      lesson: build.current.map(title), step: build.step?.label, detail: build.detail.isEmpty ? nil : build.detail,
                      progress: build.current == nil ? nil : Int((build.fraction * 100).rounded()), waiting: build.queue.map(title), errors: errors, stopped: build.stopped)
    }
}

struct LearningBuildCancelAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.build.cancel", summary: "Hält die Kurserstellung an (eines Kurses oder ganz); Fertiges bleibt, Fortsetzen geht mit learning.build.start",
        kind: .write, security: .localWrite, input: .object(["course": courseProperty]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let course = try args.course.map { try app.actionCourse($0).id }
        let running = course.map { app.courseBuild.isBuilding(course: $0) } ?? app.courseBuild.isRunning
        app.cancelCourseBuild(course: course)
        return OKOutput(message: running ? "Angehalten." : "Es lief keine Erstellung.")
    }
}

// MARK: - Tests

struct LearningTestListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var course: String
        var lesson: String?
        var details: Bool?
    }
    struct Question: Encodable, Sendable {
        var question: String
        var kind: String
        var section: String?
        var answer: String?
        var verdict: String?
        var feedback: String?
    }
    struct Test: Encodable, Sendable {
        var id: String
        var lesson: String
        var date: String
        var finished: Bool
        var grade: String?
        var score: Int?
        var answered: Int
        var planned: Int
        var assessment: String?
        var questions: [Question]?
    }
    struct Output: Encodable, Sendable {
        var tests: [Test]
        var standing: String?
    }
    static let descriptor = ActionDescriptor(
        id: "learning.test.list", summary: "Ergebnisse der KI-Tests eines Kurses oder einer Lektion: Note A–F, Prozent, Einschätzung und (mit details) die Fragen",
        kind: .read, security: learningRead,
        input: .object(["course": courseProperty, "lesson": lessonProperty, "details": .boolean("Fragen, Antworten und Bewertungen mitliefern")], required: ["course"]),
        output: .freeObject(), groups: ["learning.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let course = try app.actionCourse(args.course)
        let lesson = try args.lesson.map { try course.actionLesson($0).id }
        let tests = course.quizzes.filter { $0.isTest && (lesson == nil || $0.lesson == lesson) }.map { test in
            Test(id: test.id.uuidString, lesson: course.lesson(test.lesson)?.displayTitle ?? "", date: test.date.formatted(.iso8601), finished: test.finishedAt != nil,
                 grade: test.grade?.rawValue, score: test.score.map { Int(($0 * 100).rounded()) }, answered: test.answeredCount, planned: test.planned,
                 assessment: test.assessment.isEmpty ? nil : test.assessment,
                 questions: args.details == true ? test.items.map {
                     Question(question: $0.question, kind: $0.kind.rawValue, section: $0.section.isEmpty ? nil : $0.section,
                              answer: $0.isAnswered ? $0.answerText : nil, verdict: $0.verdict?.rawValue, feedback: $0.feedback.isEmpty ? nil : $0.feedback)
                 } : nil)
        }
        let standing = app.learning.standing(course.id).map { "\($0.grade.rawValue) (\($0.tested) von \($0.lessons) Lektionen getestet)" }
        return Output(tests: tests, standing: standing)
    }
}
