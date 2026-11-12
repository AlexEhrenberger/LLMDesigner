import Foundation

/// How far a course is, for its page, the power access and the chat.
struct CourseStats: Equatable, Sendable {
    var total = 0
    var new = 0
    var learning = 0
    var young = 0
    var mature = 0
    var suspended = 0
    /// What comes up now, within the day's limits.
    var dueNow = 0
    /// Reviews due by the end of today (without limits).
    var dueToday = 0
    var reviewsToday = 0
    /// Share of reviews of known cards answered without "Nochmal" in the last 30 days.
    var retention: Double?
    /// Reviews per day of the last 30 days, oldest first.
    var history: [Int] = []
    /// Cards due on each of the next 14 days.
    var forecast: [Int] = []
    var quizScore: Double?

    var known: Int { young + mature }
    /// Cards that have left the learning steps, as a share.
    var progress: Double { total == 0 ? 0 : Double(known) / Double(total) }
}

/// How big and colourful a discipline's tree is.
struct TreeGrowth: Equatable, Sendable {
    /// 0 a seedling, 1 a full tree.
    var stage = 0.03
    /// How full of leaves (known cards).
    var leaves = 0.0
    /// Blossoms: steady learning (streak, retention).
    var blossoms = 0.0
    /// Fruits: finished courses and good quizzes.
    var fruits = 0
    var score = 0.0
}

/// Learning Studio's data: `Lernen/lernen.json` (disciplines, settings, pauses) and one folder per course
/// (`Lernen/<id>/kurs.json` and `Material/`).
@MainActor
@Observable
final class LearningLibrary {
    let courses = RecordLibrary<LearningCourse>(store: RecordStore(directory: AppLibrary.current.folder("Lernen"), root: "kurs", layout: .folder("kurs")))
    private(set) var state = LearningState()
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var stateSave: Task<Void, Never>?

    var stateURL: URL { courses.store.directory.appendingPathComponent("lernen.json") }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        courses.loadIfNeeded()
        if let data = try? Data(contentsOf: stateURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode(LearningState.self, from: data) { state = loaded }
        }
        applyFinishedPauses()
    }

    func changeState(_ change: (inout LearningState) -> Void) {
        loadIfNeeded()
        var copy = state
        change(&copy)
        guard copy != state else { return }
        state = copy
        scheduleStateSave()
    }

    private func scheduleStateSave() {
        stateSave?.cancel()
        stateSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    private func saveState() {
        stateSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            print("LLMDesigner: lernen.json konnte nicht gespeichert werden: \(error)")
        }
    }

    func saveAll() {
        if stateSave != nil {
            stateSave?.cancel()
            saveState()
        }
        courses.saveAll()
    }

    var settings: LearningSettings { state.settings }
    var scheduler: LearningScheduler { LearningScheduler(settings: state.settings) }

    func discipline(_ id: UUID?) -> LearningDiscipline? {
        guard let id else { return nil }
        return state.disciplines.first { $0.id == id }
    }

    func course(_ id: UUID) -> LearningCourse? { courses.record(id) }

    func courses(in discipline: UUID?) -> [LearningCourse] {
        courses.records.filter { $0.discipline == discipline }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The folder of a course's files.
    func materialFolder(_ courseID: UUID) -> URL {
        courses.store.folder(of: courseID).appendingPathComponent("Material", isDirectory: true)
    }

    func materialURL(_ material: LearningMaterial, in courseID: UUID) -> URL? {
        guard let file = material.file else { return nil }
        let url = materialFolder(courseID).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Pauses

    /// The pause a course is in right now, if any.
    func activePause(for course: LearningCourse, at date: Date = Date()) -> LearningPause? {
        state.pauses.first { $0.isActive(at: date) && $0.covers(course) }
    }

    var activePauses: [LearningPause] { state.pauses.filter { $0.isActive() } }

    /// A pause from now (or `start`) until `end`, or open-ended.
    @discardableResult
    func startPause(scope: LearningPause.Scope = .all, start: Date = Date(), end: Date? = nil, reason: String = "") -> LearningPause {
        let pause = LearningPause(start: start, end: end, scope: scope, reason: reason)
        changeState { $0.pauses.append(pause) }
        return pause
    }

    /// Ends a pause now: every card in its range that is due after its start moves on by its length.
    func endPause(_ id: UUID, at now: Date = Date()) {
        guard let index = state.pauses.firstIndex(where: { $0.id == id }), !state.pauses[index].applied else { return }
        var pause = state.pauses[index]
        let end = min(pause.end ?? now, now)
        pause.end = max(pause.start, end)
        apply(pause)
        pause.applied = true
        changeState { $0.pauses[index] = pause }
    }

    /// Pauses whose planned end has passed are applied when the library is opened.
    func applyFinishedPauses(now: Date = Date()) {
        for pause in state.pauses where !pause.applied {
            guard let end = pause.end, end <= now else { continue }
            endPause(pause.id, at: end)
        }
    }

    private func apply(_ pause: LearningPause) {
        guard let end = pause.end else { return }
        let shift = end.timeIntervalSince(pause.start)
        guard shift > 0 else { return }
        for course in courses.records where pause.covers(course) {
            courses.update(course.id, touch: false) { course in
                for index in course.cards.indices where course.cards[index].state != .new && course.cards[index].due >= pause.start {
                    course.cards[index].due = course.cards[index].due.addingTimeInterval(shift)
                }
            }
        }
    }

    // MARK: The queue

    /// The cards that come up now in this course, in order: steps first, then reviews by how overdue they are, then new
    /// cards up to the day's limit. A paused course has none.
    func queue(_ courseID: UUID, at now: Date = Date()) -> [LearningCard] {
        guard let course = course(courseID), activePause(for: course, at: now) == nil else { return [] }
        let calendar = Calendar.current
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(LearningScheduler.day)
        let active = course.cards.filter { !$0.suspended }
        let steps = active.filter { ($0.state == .learning || $0.state == .relearning) && $0.due <= now.addingTimeInterval(60) }.sorted { $0.due < $1.due }
        let reviewedToday = active.filter { card in card.history.contains { calendar.isDate($0.date, inSameDayAs: now) && $0.state == .review } }.count
        let reviews = active.filter { $0.state == .review && $0.due < endOfDay }.sorted { $0.due < $1.due }
            .prefix(max(0, settings.reviewsPerDay - reviewedToday))
        let introducedToday = active.filter { card in card.history.first.map { calendar.isDate($0.date, inSameDayAs: now) } ?? false }.count
        let fresh = active.filter { $0.state == .new }.sorted { $0.createdAt < $1.createdAt }.prefix(max(0, settings.newPerDay - introducedToday))
        return steps + reviews + fresh
    }

    /// Steps still waiting a few minutes (shown as "gleich wieder").
    func waitingSteps(_ courseID: UUID, at now: Date = Date()) -> [LearningCard] {
        guard let course = course(courseID) else { return [] }
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(LearningScheduler.day)
        return course.cards.filter { !$0.suspended && ($0.state == .learning || $0.state == .relearning) && $0.due > now.addingTimeInterval(60) && $0.due < endOfDay }
    }

    /// Answers a card and returns it as it is now.
    @discardableResult
    func answer(_ cardID: UUID, in courseID: UUID, _ rating: CardRating, at now: Date = Date()) -> LearningCard? {
        guard let card = course(courseID)?.card(cardID) else { return nil }
        let next = scheduler.answer(card, rating, at: now)
        courses.update(courseID) { $0.updateCard(cardID) { $0 = next } }
        return next
    }

    // MARK: Statistics

    func stats(_ courseID: UUID, at now: Date = Date()) -> CourseStats {
        guard let course = course(courseID) else { return CourseStats() }
        return Self.stats(of: course, queue: queue(courseID, at: now).count, at: now)
    }

    nonisolated static func stats(of course: LearningCourse, queue: Int, at now: Date) -> CourseStats {
        var stats = CourseStats()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        stats.total = course.cards.count
        stats.dueNow = queue
        var recent: (kept: Int, all: Int) = (0, 0)
        var perDay = [Int](repeating: 0, count: 30)
        var forecast = [Int](repeating: 0, count: 14)
        for card in course.cards {
            if card.suspended { stats.suspended += 1; continue }
            switch card.state {
            case .new: stats.new += 1
            case .learning, .relearning: stats.learning += 1
            case .review: if card.isMature { stats.mature += 1 } else { stats.young += 1 }
            }
            if card.state != .new, card.due < today.addingTimeInterval(LearningScheduler.day) { stats.dueToday += 1 }
            if card.state == .review {
                let days = Int(floor(card.due.timeIntervalSince(today) / LearningScheduler.day))
                if days >= 0, days < 14 { forecast[days] += 1 }
            }
            for review in card.history {
                let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: review.date), to: today).day ?? 999
                if age == 0 { stats.reviewsToday += 1 }
                if age >= 0, age < 30 {
                    perDay[29 - age] += 1
                    if review.state == .review {
                        recent.all += 1
                        if review.rating != .again { recent.kept += 1 }
                    }
                }
            }
        }
        stats.retention = recent.all == 0 ? nil : Double(recent.kept) / Double(recent.all)
        stats.history = perDay
        stats.forecast = forecast
        let scores = course.quizzes.compactMap(\.score)
        stats.quizScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        return stats
    }

    /// Days in a row with at least one answered card, up to today; days of a pause don't break it.
    func streak(at now: Date = Date()) -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for course in courses.records {
            for card in course.cards { for review in card.history { days.insert(calendar.startOfDay(for: review.date)) } }
        }
        var paused = Set<Date>()
        for pause in state.pauses {
            var day = calendar.startOfDay(for: pause.start)
            let end = calendar.startOfDay(for: pause.end ?? now)
            while day <= end, paused.count < 4_000 {
                paused.insert(day)
                day = day.addingTimeInterval(LearningScheduler.day)
            }
        }
        var count = 0
        var day = calendar.startOfDay(for: now)
        // Today without answers yet doesn't break the run.
        if !days.contains(day) { day = day.addingTimeInterval(-LearningScheduler.day) }
        while days.contains(day) || paused.contains(day) {
            if days.contains(day) { count += 1 }
            day = day.addingTimeInterval(-LearningScheduler.day)
            if count > 3_650 { break }
        }
        return count
    }

    /// How a discipline's tree grows: known cards, answers, material, quizzes and finished courses count.
    func growth(of disciplineID: UUID?, at now: Date = Date()) -> TreeGrowth {
        let members = courses(in: disciplineID)
        var growth = TreeGrowth()
        var known = 0
        var total = 0
        var retentions: [Double] = []
        for course in members {
            let stats = Self.stats(of: course, queue: 0, at: now)
            let reviews = course.cards.reduce(0) { $0 + $1.history.count }
            growth.score += Double(stats.mature) * 1.0 + Double(stats.young) * 0.5 + Double(stats.learning) * 0.2 + Double(reviews) * 0.03
                + Double(course.materials.count) * 0.5 + Double(course.quizzes.count) * 1 + (course.finished ? 12 : 0) + 1
            known += stats.known
            total += stats.total
            if let retention = stats.retention { retentions.append(retention) }
            growth.fruits += (course.finished ? 1 : 0) + course.quizzes.filter { ($0.score ?? 0) >= 0.8 }.count
        }
        growth.stage = members.isEmpty ? 0.03 : max(0.08, 1 - exp(-growth.score / 70))
        growth.leaves = total == 0 ? 0.15 : min(1, 0.2 + 0.8 * Double(known) / Double(max(total, 1)))
        let retention = retentions.isEmpty ? 0.5 : retentions.reduce(0, +) / Double(retentions.count)
        growth.blossoms = min(1, Double(streak(at: now)) / 14) * 0.6 + (growth.stage > 0.3 ? retention * 0.4 : 0)
        growth.fruits = min(growth.fruits, 24)
        return growth
    }
}
