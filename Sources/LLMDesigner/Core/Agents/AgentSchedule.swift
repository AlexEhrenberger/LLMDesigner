import Foundation

/// When a task runs by itself: never (by hand), once, daily, on some weekdays or every few minutes. The times of past
/// runs live in the runs (outside Git); the schedule only says when, so a run never changes the task's file.
struct AgentSchedule: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case manual = "manuell"
        case once = "einmalig"
        case daily = "taeglich"
        case weekly = "woechentlich"
        case interval = "intervall"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .manual: "Nur von Hand"
            case .once: "Einmalig"
            case .daily: "Täglich"
            case .weekly: "An Wochentagen"
            case .interval: "Im Abstand"
            }
        }
    }

    var kind: Kind = .manual
    /// `.once`: the moment.
    var date: Date?
    /// `.daily`, `.weekly`: "HH:mm".
    var time = "08:00"
    /// `.weekly`: 1 = Monday … 7 = Sunday.
    var weekdays: [Int] = [1, 2, 3, 4, 5]
    /// `.interval`: minutes between two runs.
    var intervalMinutes = 60
    /// A time missed while the app was closed or the Mac asleep is made up once, as soon as possible.
    var catchUp = true
    var isOn = true
    /// When the schedule was set. Times before it don't count, so a new daily task doesn't start at once for this
    /// morning's time.
    var since = Date()

    /// How late a time may still be met without `catchUp`.
    static let grace: TimeInterval = 120
    static let minimumInterval = 5

    private enum CodingKeys: String, CodingKey {
        case kind = "art", date = "zeitpunkt", time = "uhrzeit", weekdays = "wochentage", intervalMinutes = "alleMinuten"
        case catchUp = "nachholen", isOn = "aktiv", since = "seit"
    }

    init(kind: Kind = .manual) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.soft(.kind, .manual)
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        time = c.soft(.time, "08:00")
        weekdays = c.soft(.weekdays, [1, 2, 3, 4, 5])
        intervalMinutes = c.soft(.intervalMinutes, 60)
        catchUp = c.soft(.catchUp, true)
        isOn = c.soft(.isOn, true)
        since = c.soft(.since, Date())
    }

    var isRecurring: Bool { [.daily, .weekly, .interval].contains(kind) }
    var isTimed: Bool { kind != .manual }

    /// Hour and minute of `time`; nil when it isn't "HH:mm".
    var clock: (hour: Int, minute: Int)? {
        Self.clock(time)
    }

    static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// What is wrong with the schedule, or nil.
    var problem: String? {
        switch kind {
        case .manual: return nil
        case .once: return date == nil ? "Für „einmalig“ fehlt der Zeitpunkt." : nil
        case .daily: return clock == nil ? "Die Uhrzeit „\(time)“ ist nicht im Format HH:MM." : nil
        case .weekly:
            if clock == nil { return "Die Uhrzeit „\(time)“ ist nicht im Format HH:MM." }
            return weekdays.contains(where: { (1...7).contains($0) }) ? nil : "Es ist kein Wochentag gewählt."
        case .interval:
            return intervalMinutes >= Self.minimumInterval ? nil : "Der Abstand muss mindestens \(Self.minimumInterval) Minuten sein."
        }
    }

    // MARK: Times

    /// The latest planned time at or before `now`, not before `since`.
    func previousSlot(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        guard problem == nil else { return nil }
        let slot: Date?
        switch kind {
        case .manual:
            slot = nil
        case .once:
            slot = date.flatMap { $0 <= now ? $0 : nil }
        case .daily, .weekly:
            slot = (0...7).lazy.compactMap { back -> Date? in
                guard let day = calendar.date(byAdding: .day, value: -back, to: now), let candidate = self.slot(on: day, calendar: calendar),
                      candidate <= now, self.matches(candidate, calendar: calendar) else { return nil }
                return candidate
            }.first
        case .interval:
            let step = TimeInterval(intervalMinutes * 60)
            let passed = now.timeIntervalSince(since)
            guard passed >= step else { return nil }
            slot = since.addingTimeInterval((passed / step).rounded(.down) * step)
        }
        guard let slot, slot >= since.addingTimeInterval(-1) || kind == .once else { return nil }
        return slot
    }

    /// The next planned time after `now`.
    func nextSlot(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isOn, problem == nil else { return nil }
        switch kind {
        case .manual:
            return nil
        case .once:
            return date.flatMap { $0 > now ? $0 : nil }
        case .daily, .weekly:
            return (0...8).lazy.compactMap { ahead -> Date? in
                guard let day = calendar.date(byAdding: .day, value: ahead, to: now), let candidate = self.slot(on: day, calendar: calendar),
                      candidate > now, candidate >= since, self.matches(candidate, calendar: calendar) else { return nil }
                return candidate
            }.first
        case .interval:
            let step = TimeInterval(intervalMinutes * 60)
            let passed = max(0, now.timeIntervalSince(since))
            return since.addingTimeInterval(((passed / step).rounded(.down) + 1) * step)
        }
    }

    /// Whether a run should start now: a planned time has come that no run has met yet. `lastStart` is the start of
    /// the latest run the schedule made.
    func isDue(now: Date, lastStart: Date?, calendar: Calendar = .current) -> Bool {
        guard isOn, let slot = previousSlot(atOrBefore: now, calendar: calendar) else { return false }
        if let lastStart, lastStart >= slot { return false }
        // A once-only time before the schedule was set is not "missed": it was never meant.
        if kind == .once, slot < since.addingTimeInterval(-Self.grace) { return false }
        return catchUp || now.timeIntervalSince(slot) <= Self.grace
    }

    private func slot(on day: Date, calendar: Calendar) -> Date? {
        guard let clock else { return nil }
        return calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day)
    }

    private func matches(_ date: Date, calendar: Calendar) -> Bool {
        kind != .weekly || weekdays.contains(Self.weekday(of: date, calendar: calendar))
    }

    /// 1 = Monday … 7 = Sunday.
    static func weekday(of date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    static let weekdayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    // MARK: Words

    var summary: String {
        switch kind {
        case .manual:
            return "nur von Hand"
        case .once:
            guard let date else { return "einmalig, ohne Zeitpunkt" }
            return "einmalig am \(date.formatted(.dateTime.day().month().year())) um \(date.formatted(.dateTime.hour().minute()))"
        case .daily:
            return "täglich um \(time)"
        case .weekly:
            let days = weekdays.filter { (1...7).contains($0) }.sorted()
            if days == [1, 2, 3, 4, 5] { return "werktags um \(time)" }
            if days == [6, 7] { return "am Wochenende um \(time)" }
            return days.map { Self.weekdayNames[$0 - 1] }.joined(separator: ", ") + " um \(time)"
        case .interval:
            if intervalMinutes % 60 == 0 {
                let hours = intervalMinutes / 60
                return hours == 1 ? "stündlich" : "alle \(hours) Stunden"
            }
            return "alle \(intervalMinutes) Minuten"
        }
    }
}

/// The schedule in the person's own words: "jeden Freitag um 17 Uhr", "werktags 7:30", "alle 2 Stunden",
/// "morgen um 9". Read by rules, because Qwen 9B answered "stündlich" to "jeden Freitag um 17 Uhr" (2026-11-15);
/// the model's choice only counts where these rules find nothing.
enum AgentScheduleWords {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentSchedule? {
        let lower = text.lowercased()
        func matches(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
            return (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: lower).map { String(lower[$0]) } ?? ""
            }
        }
        var schedule = AgentSchedule()
        schedule.since = now

        // The time of day: "um 7:30", "17.15", "um 17 uhr", "9 uhr".
        var clock: String?
        if let found = matches(#"(?<![\d.])(\d{1,2})[:.](\d{2})(?![\d.])"#), let hour = Int(found[1]), let minute = Int(found[2]), hour < 24, minute < 60 {
            clock = String(format: "%02d:%02d", hour, minute)
        } else if let found = matches(#"(?:um\s+(\d{1,2})(?!\s*(?:minuten|stunden|tage))\b|\b(\d{1,2})\s*uhr)"#),
                  let hour = Int(found[1].isEmpty ? found[2] : found[1]), hour < 24 {
            clock = String(format: "%02d:00", hour)
        }

        if let found = matches(#"alle\s+(\d+)\s+(minuten|stunden)"#), let count = Int(found[1]) {
            schedule.kind = .interval
            schedule.intervalMinutes = found[2] == "stunden" ? count * 60 : count
            return schedule.problem == nil ? schedule : nil
        }
        if lower.contains("halbstündlich") || lower.contains("jede halbe stunde") || lower.contains("alle halbe stunde") {
            schedule.kind = .interval
            schedule.intervalMinutes = 30
            return schedule
        }
        if lower.contains("stündlich") || lower.contains("jede stunde") {
            schedule.kind = .interval
            schedule.intervalMinutes = 60
            return schedule
        }

        let days: [(Int, [String])] = [(1, ["montag"]), (2, ["dienstag"]), (3, ["mittwoch"]), (4, ["donnerstag"]), (5, ["freitag"]),
                                       (6, ["samstag", "sonnabend"]), (7, ["sonntag"])]
        var weekdays = days.filter { _, names in names.contains { lower.contains($0) } }.map(\.0)
        if lower.contains("werktag") || lower.contains("wochentags") || lower.contains("unter der woche") { weekdays += [1, 2, 3, 4, 5] }
        if lower.contains("wochenende") { weekdays += [6, 7] }
        let recurring = ["jeden", "jede ", "immer", "werktag", "wochentags", "wochenende", "montags", "dienstags", "mittwochs", "donnerstags",
                         "freitags", "samstags", "sonntags", "wöchentlich"].contains { lower.contains($0) }
        if !weekdays.isEmpty, recurring {
            schedule.kind = .weekly
            schedule.weekdays = Array(Set(weekdays)).sorted()
            schedule.time = clock ?? "08:00"
            return schedule
        }
        if ["täglich", "jeden tag", "jeden morgen", "jeden abend", "jede nacht", "jeden mittag", "allmorgendlich"].contains(where: lower.contains) {
            schedule.kind = .daily
            schedule.time = clock ?? (lower.contains("abend") ? "19:00" : lower.contains("nacht") ? "23:00" : "08:00")
            return schedule
        }

        // Once: "heute um 22 uhr", "morgen um 9", "übermorgen 7:30", "am 20.11. um 8".
        guard let clock, let parts = AgentSchedule.clock(clock) else { return nil }
        var day: Date?
        if lower.contains("übermorgen") {
            day = calendar.date(byAdding: .day, value: 2, to: now)
        } else if lower.range(of: #"\bmorgen\b"#, options: .regularExpression) != nil, !lower.contains("jeden morgen") {
            day = calendar.date(byAdding: .day, value: 1, to: now)
        } else if lower.contains("heute") {
            day = now
        } else if let found = matches(#"am\s+(\d{1,2})\.(\d{1,2})\.(\d{4})?"#), let dayNumber = Int(found[1]), let month = Int(found[2]) {
            var components = calendar.dateComponents([.year], from: now)
            components.year = Int(found[3]) ?? components.year
            components.month = month
            components.day = dayNumber
            day = calendar.date(from: components)
            // "am 3.1." in December means next January.
            if let date = day, date < calendar.startOfDay(for: now), found[3].isEmpty {
                day = calendar.date(byAdding: .year, value: 1, to: date)
            }
        } else if let index = weekdays.first {
            // "am Freitag um 17 Uhr" without "jeden": the next such day.
            day = (0...7).lazy.compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
                .first { AgentSchedule.weekday(of: $0, calendar: calendar) == index }
        }
        guard let day, let date = calendar.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: day) else { return nil }
        schedule.kind = .once
        // "am Freitag um 17 Uhr", said on a Friday evening, means next week.
        schedule.date = date <= now && !weekdays.isEmpty ? calendar.date(byAdding: .day, value: 7, to: date) : date
        schedule.time = clock
        return schedule
    }

    /// The person asked for the Mac to sleep afterwards.
    static func wantsSleep(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["schlafen", "ruhezustand", "schlafmodus", "in den schlaf"].contains { lower.contains($0) }
    }
}
