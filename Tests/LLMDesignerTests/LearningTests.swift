import Testing
import Foundation
@testable import LLMDesigner

@Suite("Learning Studio: Algorithmus, Pausen, Karten aus Text")
struct LearningTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fsrsWalksANewCardThroughItsStepsAndStretchesIntervals() {
        let scheduler = LearningScheduler(settings: LearningSettings())
        var card = LearningCard(front: "F", back: "A")
        card = scheduler.answer(card, .good, at: start)
        #expect(card.state == .learning)
        #expect(abs(card.due.timeIntervalSince(start) - 600) < 1, "zweiter Lernschritt: 10 Minuten")
        card = scheduler.answer(card, .good, at: card.due)
        #expect(card.state == .review)
        #expect(card.interval >= 1)
        var last = card.interval
        var now = card.due
        for _ in 0..<4 {
            card = scheduler.answer(card, .good, at: now)
            #expect(card.interval > last, "Gut verlängert das Intervall")
            last = card.interval
            now = card.due
        }
        let stability = card.stability
        card = scheduler.answer(card, .again, at: now)
        #expect(card.state == .relearning)
        #expect(card.lapses == 1)
        #expect(card.stability < stability)
        #expect(card.due.timeIntervalSince(now) < 3_600)
        #expect(card.history.count == 7)
    }

    @Test func higherRetentionMeansShorterIntervals() {
        let card = LearningScheduler(settings: LearningSettings()).answer(LearningCard(), .easy, at: start)
        var strict = LearningSettings()
        strict.retention = 0.97
        var loose = LearningSettings()
        loose.retention = 0.8
        let a = LearningScheduler(settings: strict).answer(card, .good, at: card.due.addingTimeInterval(86_400 * 3))
        let b = LearningScheduler(settings: loose).answer(card, .good, at: card.due.addingTimeInterval(86_400 * 3))
        #expect(a.interval < b.interval)
    }

    @Test func sm2MultipliesByTheFactor() {
        var settings = LearningSettings()
        settings.algorithm = .sm2
        settings.learningSteps = [1]
        let scheduler = LearningScheduler(settings: settings)
        var card = scheduler.answer(LearningCard(), .good, at: start)
        #expect(card.state == .review)
        #expect(card.interval == 1)
        card = scheduler.answer(card, .good, at: card.due)
        #expect(card.interval == 3, "1 Tag × 2,5 → aufgerundet nach mindestens +1")
        card = scheduler.answer(card, .hard, at: card.due)
        #expect(card.ease < 2.5)
        let preview = scheduler.preview(card, at: card.due)
        #expect(preview[.easy]! > preview[.good]!)
        #expect(preview[.again]! < 3_600)
    }

    @Test func intervalLabelsAreGerman() {
        #expect(LearningScheduler.label(60) == "1 Min.")
        #expect(LearningScheduler.label(3 * 86_400) == "3 T.")
        #expect(LearningScheduler.label(75 * 86_400) == "2,5 Mon.")
    }

    @Test func cardsComeFromPlainText() {
        let parsed = LearningCardText.parse("""
        Hauptstadt von Frankreich ; Paris
        - Mitose – Zellteilung
        F: Was ist ein p-Wert?
        A: Die Wahrscheinlichkeit …
        Nur eine Zeile ohne Trenner
        """)
        #expect(parsed.map(\.front) == ["Hauptstadt von Frankreich", "Mitose", "Was ist ein p-Wert?"])
        #expect(parsed.last?.back == "Die Wahrscheinlichkeit …")
        let fromJSON = LearningPrompts.parseCards("Hier: ```json\n[{\"vorne\": \"A?\", \"hinten\": \"B\"},]\n```", material: nil)
        #expect(fromJSON.map(\.front) == ["A?"])
    }

    @Test func filesKeepGermanKeys() throws {
        var course = LearningCourse(name: "Statistik 2")
        course.cards = [LearningScheduler(settings: LearningSettings()).answer(LearningCard(front: "F", back: "A"), .good, at: start)]
        course.createdAt = start
        course.updatedAt = start
        course.examDate = ProjectDay.date("2027-02-10")
        let store = RecordStore<LearningCourse>(directory: FileManager.default.temporaryDirectory, root: "kurs", layout: .folder("kurs"))
        let json = try #require(String(data: try store.encode(course), encoding: .utf8))
        for key in ["\"kurs\"", "\"karten\"", "\"vorne\"", "\"faellig\"", "\"stabilitaet\"", "\"verlauf\"", "\"pruefung\" : \"2027-02-10\""] {
            #expect(json.contains(key), "\(key)")
        }
        let back = try store.decode(Data(json.utf8))
        #expect(back.cards.first?.history.first?.rating == .good)
        var state = LearningState()
        state.pauses = [LearningPause(start: start, end: nil, scope: .course(course.id), reason: "Urlaub")]
        let encoded = try JSONEncoder.iso.encode(state)
        let decoded = try JSONDecoder.iso.decode(LearningState.self, from: encoded)
        #expect(decoded.pauses.first?.scope == .course(course.id))
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
