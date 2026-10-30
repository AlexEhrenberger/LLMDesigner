import Testing
import Foundation
@testable import LLMDesigner

@Suite("Stories Studio")
struct StoryWorldTests {
    /// A small world: one book with two acts, chapters, a section, and elements linked all over.
    private func sample() -> (world: StoryWorld, book: UUID, act1: UUID, act2: UUID, ch1: UUID, ch2: UUID, ch3: UUID, sec: UUID,
                              hero: StoryRef, castle: StoryRef, fall: StoryRef) {
        var world = StoryWorld(title: "Testwelt")
        let book = world.addPart(.book, under: nil, title: "Erstes Buch")!.id
        let act1 = world.addPart(.act, under: book)!.id
        let act2 = world.addPart(.act, under: book)!.id
        let ch1 = world.addPart(.chapter, under: act1)!.id
        let ch2 = world.addPart(.chapter, under: act1)!.id
        let ch3 = world.addPart(.chapter, under: act2, title: "Der Fall")!.id
        let sec = world.addPart(.section, under: ch3)!.id
        let hero = world.addElement(.figure, name: "Aria")
        let castle = world.addElement(.place, name: "Rabenfels")
        let fall = world.addElement(.event, name: "Sturz des Königs")
        return (world, book, act1, act2, ch1, ch2, ch3, sec, hero, castle, fall)
    }

    @Test func levelsOnlyNestInOrder() {
        var world = StoryWorld()
        #expect(world.addPart(.chapter, under: nil) == nil)
        let book = world.addPart(.book, under: nil)!.id
        #expect(world.addPart(.chapter, under: book) == nil)
        let act = world.addPart(.act, under: book)!.id
        #expect(world.addPart(.chapter, under: act) != nil)
        #expect(world.part(book)?.children.count == 1)
    }

    @Test func numbering() {
        let s = sample()
        #expect(s.world.number(of: s.book) == "Buch 1")
        #expect(s.world.number(of: s.act2) == "Akt II")
        // Chapters count through the whole book, across acts.
        #expect(s.world.number(of: s.ch3) == "Kapitel 3")
        #expect(s.world.number(of: s.sec) == "Abschnitt 3.1")
        #expect(s.world.displayTitle(of: s.world.part(s.ch1)!) == "Kapitel 1")
        #expect(s.world.displayTitle(of: s.world.part(s.ch3)!) == "Der Fall")
        #expect(StoryWorld.roman(14) == "XIV")
        #expect(s.world.allParts.map(\.depth) == [0, 1, 2, 2, 1, 2, 3])
        #expect(s.world.allParts.last?.path == "Erstes Buch › Akt II › Der Fall › Abschnitt 3.1")
    }

    @Test func moveAndRemoveParts() {
        var s = sample()
        #expect(!s.world.canMovePart(s.act1, by: -1))
        s.world.movePart(s.act2, by: -1)
        #expect(s.world.part(s.book)?.children.map(\.id) == [s.act2, s.act1])
        #expect(s.world.number(of: s.ch3) == "Kapitel 1")

        let purpose = s.world.addElement(.purpose, name: "Vorausdeutung")
        s.world.updateElement(StoryPurpose.self, purpose.id) {
            $0.setupPartIDs = [s.ch1]
            $0.payoffPartIDs = [s.sec]
        }
        s.world.removePart(s.ch3)
        #expect(s.world.part(s.ch3) == nil)
        #expect(s.world.part(s.sec) == nil)
        #expect(s.world.element(StoryPurpose.self, purpose.id)?.payoffPartIDs == [])
        #expect(s.world.element(StoryPurpose.self, purpose.id)?.setupPartIDs == [s.ch1])
        #expect(s.world.element(StoryPurpose.self, purpose.id)?.isOpenPromise == true)
    }

    @Test func removingAnElementRemovesEveryLink() {
        var s = sample()
        let other = s.world.addElement(.figure, name: "Bren")
        s.world.updatePart(s.ch1) {
            $0.focus.link(s.hero.id, as: .figure)
            $0.focus.link(s.fall.id, as: .event)
            $0.povFigureID = s.hero.id
            $0.timeline.entries.append(TimelineEntry(ref: s.hero, start: 1))
        }
        s.world.timeline.entries.append(TimelineEntry(ref: s.hero, start: 3, end: 5))
        s.world.updateElement(StoryFigure.self, other.id) { $0.relations.append(StoryRelation(target: s.hero, attitude: -2)) }
        s.world.updateElement(StoryPlace.self, s.castle.id) { $0.residentIDs = [s.hero.id] }
        s.world.updateElement(StoryEvent.self, s.fall.id) { event in
            event.figureIDs = [s.hero.id, other.id]
            event.consequences = [EventConsequence(affected: [s.hero, s.castle])]
        }
        #expect(s.world.usages(of: s.hero).count == 4)

        s.world.removeElement(s.hero)
        let chapter = s.world.part(s.ch1)!
        #expect(chapter.focus.ids(.figure).isEmpty)
        #expect(chapter.focus.ids(.event) == [s.fall.id])
        #expect(chapter.povFigureID == nil)
        #expect(chapter.timeline.entries.isEmpty)
        #expect(s.world.timeline.entries.isEmpty)
        #expect(s.world.element(StoryFigure.self, other.id)?.relations.isEmpty == true)
        #expect(s.world.element(StoryPlace.self, s.castle.id)?.residentIDs.isEmpty == true)
        #expect(s.world.element(StoryEvent.self, s.fall.id)?.figureIDs == [other.id])
        #expect(s.world.element(StoryEvent.self, s.fall.id)?.consequences.first?.affected == [s.castle])
    }

    @Test func causeAndEffect() {
        var s = sample()
        let war = s.world.addElement(.event, name: "Krieg der Häuser")
        let plot = s.world.addElement(.event, name: "Verschwörung")
        s.world.updateElement(StoryEvent.self, s.fall.id) { event in
            event.causeEventIDs = [plot.id]
            event.consequences = [EventConsequence(text: "Die Häuser greifen nach der Krone", followEventID: war.id)]
        }
        #expect(s.world.causes(of: s.fall.id).map(\.id) == [plot.id])
        #expect(s.world.followers(of: s.fall.id).map(\.id) == [war.id])
        #expect(s.world.causes(of: war.id).map(\.id) == [s.fall.id])
        #expect(s.world.followers(of: plot.id).map(\.id) == [s.fall.id])

        s.world.removeElement(war)
        #expect(s.world.element(StoryEvent.self, s.fall.id)?.consequences.first?.followEventID == nil)
    }

    @Test func placesNestWithoutLoops() {
        var world = StoryWorld()
        let land = world.addElement(.place, name: "Westland")
        let city = world.addElement(.place, name: "Hafenstadt")
        let tower = world.addElement(.place, name: "Turm")
        world.updateElement(StoryPlace.self, city.id) { $0.parentID = land.id }
        world.updateElement(StoryPlace.self, tower.id) { $0.parentID = city.id }
        #expect(world.placePath(tower.id) == "Westland › Hafenstadt › Turm")
        // The land can't move into a place that lies within it.
        #expect(Set(world.possibleParents(of: land.id).map(\.id)) == [])
        #expect(Set(world.possibleParents(of: tower.id).map(\.id)) == [land.id, city.id])
        world.removeElement(city)
        #expect(world.element(StoryPlace.self, tower.id)?.parentID == nil)
    }

    @Test func personalityCode() {
        var profile = PersonalityProfile()
        #expect(profile.code == "")
        profile.values[.energy] = 0.7
        profile.values[.perception] = 0.4
        #expect(profile.code == "INxx")
        profile.values[.decisions] = -0.5
        profile.values[.lifestyle] = -0.2
        profile.neuroticism = 0.8
        #expect(profile.code == "INTJ-T")
        #expect(profile.temperament == "Rationalist (NT)")
        profile.values[.perception] = -0.3
        #expect(profile.temperament == "Bewahrer (SJ)")
    }

    @Test func timelineRowsAndAxis() {
        let s = sample()
        var timeline = StoryTimeline()
        timeline.entries = [
            TimelineEntry(ref: s.hero, start: 290),
            TimelineEntry(ref: s.fall, start: 298, end: 300),
            TimelineEntry(ref: s.castle, start: 283),
            TimelineEntry(ref: s.hero, start: 284),
        ]
        // Events first, then figures, then places.
        #expect(timeline.rows == [s.fall, s.hero, s.castle])
        #expect(timeline.entries(of: s.hero).map(\.start) == [284, 290])
        #expect(timeline.extent == 283...300)

        #expect(TimelineAxis.niceStep(atLeast: 3) == 5)
        #expect(TimelineAxis.niceStep(atLeast: 0.13) == 0.2)
        #expect(TimelineAxis.niceStep(atLeast: 20) == 20)
        #expect(TimelineAxis.snap(for: 10) == 2)
        #expect(TimelineAxis.snap(for: 2) == 1)
        #expect(TimelineAxis.snap(for: 0.5) == 0.1)
        #expect(TimelineAxis.snapped(3.26, to: 0.1) == 3.3)
        #expect(TimelineAxis.ticks(in: 283...300, step: 5) == [285, 290, 295, 300])
        let range = TimelineAxis.visibleRange(of: timeline.extent)
        #expect(range.lowerBound < 283 && range.upperBound > 300)
        #expect(TimelineAxis.visibleRange(of: nil) == 0...10)

        let scale = TimelineScale(unit: "Jahr", suffix: "n. A. E.")
        #expect(scale.describe(start: 298, end: 300) == "Jahr 298 – 300 n. A. E.")
        #expect(scale.describe(start: 3.5, end: nil) == "Jahr 3,5 n. A. E.")
        #expect(scale.label(-12, step: 1) == "-12 n. A. E.")
    }

    @Test func roundTripAndLenientReading() throws {
        var s = sample()
        s.world.calendar = TimelineScale(unit: "Jahr", suffix: "n. A. E.")
        s.world.updatePart(s.ch1) { part in
            part.focus.setText("Aria flieht", for: .event)
            part.focus.link(s.hero.id, as: .figure)
            part.timeline.scale = TimelineScale(unit: "Stunde")
            part.timeline.entries = [TimelineEntry(ref: s.fall, start: 1, end: 3, note: "Nacht")]
        }
        s.world.updateElement(StoryFigure.self, s.hero.id) { figure in
            figure.wants = "Rache"
            figure.personality.values[.energy] = 0.5
            figure.personality.notes[.energy] = "Zieht sich zurück"
            figure.scenes = [SceneNote(kind: .quote, text: "„Nie wieder.“")]
            figure.relations = [StoryRelation(target: s.castle, attitude: 2, label: "Heimat")]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(StoryStore.Record(world: s.world))
        let decoded = try decoder.decode(StoryStore.Record.self, from: data).world
        #expect(decoded.part(s.ch1)?.focus.text(.event) == "Aria flieht")
        #expect(decoded.part(s.ch1)?.timeline.entries.first?.end == 3)
        #expect(decoded.element(StoryFigure.self, s.hero.id)?.personality.notes[.energy] == "Zieht sich zurück")
        #expect(decoded.element(StoryFigure.self, s.hero.id)?.relations.first?.label == "Heimat")
        #expect(decoded.allParts.map(\.id) == s.world.allParts.map(\.id))
        // The questions are written as named keys, so the file stays readable.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"event\" : \"Aria flieht\"") || json.contains("\"event\":\"Aria flieht\""))

        // Missing fields take their defaults, unknown values and entries are skipped.
        let id = UUID()
        let figureID = UUID()
        let sparse = """
        {"format": 1, "world": {"id": "\(id.uuidString)", "title": "Alt",
          "figures": [{"id": "\(figureID.uuidString)", "name": "Kai", "role": "zauberer"}],
          "timeline": {"entries": [{"ref": {"kind": "monster", "id": "\(UUID().uuidString)"}, "start": 1},
                                   {"ref": {"kind": "figure", "id": "\(figureID.uuidString)"}, "start": 2}]}}}
        """
        let old = try decoder.decode(StoryStore.Record.self, from: Data(sparse.utf8)).world
        #expect(old.title == "Alt")
        #expect(old.calendar.unit == "Jahr")
        #expect(old.element(StoryFigure.self, figureID)?.role == FigureRole.none)
        #expect(old.timeline.entries.count == 1)
        #expect(old.books.isEmpty)
    }

    @Test func storeWritesAndReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StoryStore(directory: folder)
        var world = StoryWorld(title: "Ablage")
        world.addPart(.book, under: nil)
        try store.save(world)
        #expect(store.loadAll().map(\.title) == ["Ablage"])
        #expect(store.loadAll().first?.books.count == 1)
    }
}
