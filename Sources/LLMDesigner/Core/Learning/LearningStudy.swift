import Foundation

// A study program in Learning Studio (`studium` in `Lernen/lernen.json`): which catalog it follows, when it began and
// how fast, the modules taken (each with its course and the month it is planned for) and the week's timetable. The
// modules themselves are ordinary courses of one discipline, so cards, lessons and the garden work as for any course.

/// A month of the plan; "2027-03" in the file.
struct StudyMonth: Hashable, Comparable, Sendable {
    var year: Int
    /// 1 to 12.
    var month: Int

    init(year: Int, month: Int) {
        let index = year * 12 + (month - 1)
        self.year = Int((Double(index) / 12).rounded(.down))
        self.month = index - self.year * 12 + 1
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    var key: String { String(format: "%04d-%02d", year, month) }

    /// Months counted from year 0, for distances.
    var index: Int { year * 12 + month - 1 }

    func adding(_ months: Int) -> StudyMonth { StudyMonth(year: year, month: month + months) }

    func distance(to other: StudyMonth) -> Int { other.index - index }

    /// Its first day.
    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    static let names = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    /// "März 2027"
    var label: String { "\(Self.names[month - 1]) \(year)" }
    /// "Mär 27"
    var shortLabel: String { "\(Self.names[month - 1].prefix(3)) \(String(format: "%02d", year % 100))" }

    static func < (a: StudyMonth, b: StudyMonth) -> Bool { a.index < b.index }
}

extension StudyMonth: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let month = StudyMonth(key: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Monat „\(text)“"))
        }
        self = month
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

/// The study model: how many months the 180 ECTS take.
enum StudyPace: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullTime = "vollzeit"
    case partTime = "teilzeit1"
    case partTimeLong = "teilzeit2"

    var id: String { rawValue }

    var months: Int {
        switch self {
        case .fullTime: 36
        case .partTime: 48
        case .partTimeLong: 72
        }
    }

    var label: String {
        switch self {
        case .fullTime: "Vollzeit (36 Monate)"
        case .partTime: "Teilzeit I (48 Monate)"
        case .partTimeLong: "Teilzeit II (72 Monate)"
        }
    }

    var short: String {
        switch self {
        case .fullTime: "Vollzeit"
        case .partTime: "Teilzeit I"
        case .partTimeLong: "Teilzeit II"
        }
    }

    func ectsPerMonth(total: Int) -> Double { Double(total) / Double(months) }

    /// 30 hours per ECTS spread over the weeks of the model.
    func hoursPerWeek(total: Int) -> Double { Double(total * 30) / (Double(months) * 52 / 12) }
}

/// Elective area D: the internship or its modules; mixing is not allowed.
enum StudyPractical: String, Codable, Sendable {
    case modules = "module"
    case internship = "praktikum"
}

/// A module taken: the catalog's code, the course made for it and the month it is planned for.
struct StudyModule: Hashable, Sendable, Identifiable {
    var code: String
    var course: UUID?
    var month: StudyMonth?

    var id: String { code }
}

extension StudyModule: Codable {
    private enum CodingKeys: String, CodingKey { case code, kurs, monat }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.soft(.code, "")
        course = c.soft(.kurs, UUID?.none)
        month = c.soft(.monat, StudyMonth?.none)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encodeIfPresent(course, forKey: .kurs)
        try c.encodeIfPresent(month, forKey: .monat)
    }
}

/// A block of the week's timetable.
struct StudySlot: Hashable, Sendable, Identifiable {
    var id = UUID()
    /// 1 Monday … 7 Sunday.
    var weekday = 1
    /// Minutes after midnight.
    var start = 18 * 60
    var end = 19 * 60
    /// The module's course; nil: a block without a module (e.g. "Bibliothek").
    var course: UUID?
    /// What happens: "Lernen", "Live-Session", "Tutorium" …
    var title = ""

    var minutes: Int { max(0, end - start) }

    static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

    /// "18:30"
    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), (0...24).contains(hours), (0..<60).contains(minutes) else { return nil }
        return min(24 * 60, hours * 60 + minutes)
    }

    /// Weekday from 1 to 7, start before end, within the day, in steps of five minutes.
    func normalized() -> StudySlot {
        var slot = self
        slot.weekday = min(7, max(1, weekday))
        slot.start = min(24 * 60 - 5, max(0, start / 5 * 5))
        slot.end = min(24 * 60, max(slot.start + 5, end / 5 * 5))
        return slot
    }
}

extension StudySlot: Codable {
    private enum CodingKeys: String, CodingKey { case id, tag, von, bis, kurs, titel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        weekday = c.soft(.tag, 1)
        start = StudySlot.minutes(c.soft(.von, "18:00")) ?? 18 * 60
        end = StudySlot.minutes(c.soft(.bis, "19:00")) ?? 19 * 60
        course = c.soft(.kurs, UUID?.none)
        title = c.soft(.titel, "")
        self = normalized()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(weekday, forKey: .tag)
        try c.encode(StudySlot.time(start), forKey: .von)
        try c.encode(StudySlot.time(end), forKey: .bis)
        try c.encodeIfPresent(course, forKey: .kurs)
        if !title.isEmpty { try c.encode(title, forKey: .titel) }
    }
}

struct LearningStudy: Hashable, Sendable {
    /// The catalog's id (`StudyCatalog.named`).
    var catalog = StudyCatalog.iuAppliedAI.id
    /// The discipline the modules' courses live in.
    var discipline: UUID?
    var start = StudyMonth(Date())
    var pace: StudyPace = .fullTime
    /// Elective area D; nil while undecided.
    var practical: StudyPractical?
    var modules: [StudyModule] = []
    var timetable: [StudySlot] = []
    var createdAt = Date()

    init(catalog: String = StudyCatalog.iuAppliedAI.id, discipline: UUID? = nil, start: StudyMonth = StudyMonth(Date()), pace: StudyPace = .fullTime) {
        self.catalog = catalog
        self.discipline = discipline
        self.start = start
        self.pace = pace
    }

    func module(_ code: String) -> StudyModule? { modules.first { $0.code == code } }

    func module(course id: UUID) -> StudyModule? { modules.first { $0.course == id } }

    mutating func updateModule(_ code: String, _ change: (inout StudyModule) -> Void) {
        guard let index = modules.firstIndex(where: { $0.code == code }) else { return }
        change(&modules[index])
    }

    /// Planned minutes per week, all blocks and per course.
    var weeklyMinutes: Int { timetable.reduce(0) { $0 + $1.minutes } }

    func weeklyMinutes(course id: UUID) -> Int { timetable.filter { $0.course == id }.reduce(0) { $0 + $1.minutes } }

    /// The modules planned for a month.
    func modules(in month: StudyMonth) -> [StudyModule] { modules.filter { $0.month == month } }

    /// The month the standard model ends in.
    var plannedEnd: StudyMonth { start.adding(pace.months - 1) }
}

extension LearningStudy: Codable {
    private enum CodingKeys: String, CodingKey { case format, programm, disziplin, beginn, modell, wahlpflichtD, module, stundenplan, angelegt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalog = c.soft(.programm, StudyCatalog.iuAppliedAI.id)
        discipline = c.soft(.disziplin, UUID?.none)
        start = c.soft(.beginn, StudyMonth(Date()))
        pace = c.soft(.modell, StudyPace.fullTime)
        practical = c.soft(.wahlpflichtD, StudyPractical?.none)
        // Entries without a code (from a damaged file) are dropped, not the whole list.
        modules = c.soft(.module, [StudyModule]()).filter { !$0.code.isEmpty }
        timetable = c.soft(.stundenplan, [StudySlot]())
        createdAt = c.soft(.angelegt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .format)
        try c.encode(catalog, forKey: .programm)
        try c.encodeIfPresent(discipline, forKey: .disziplin)
        try c.encode(start, forKey: .beginn)
        try c.encode(pace, forKey: .modell)
        try c.encodeIfPresent(practical, forKey: .wahlpflichtD)
        try c.encode(modules, forKey: .module)
        try c.encode(timetable, forKey: .stundenplan)
        try c.encode(createdAt, forKey: .angelegt)
    }
}

/// Where modules belong in the curriculum and in which month they fall when the study follows its model.
enum StudyPlanner {
    /// A place in the curriculum: a module taken, or an elective not chosen yet.
    struct Slot: Hashable, Sendable {
        var semester: Int
        var ects: Int
        var code: String?
        var area: String?
    }

    /// The semester a module is shown in: its own, else its area's; the internship has none.
    static func semester(of module: StudyCatalog.Module, in catalog: StudyCatalog) -> Int? {
        module.semester ?? catalog.area(module.area)?.semester
    }

    /// The curriculum in order: per semester the compulsory modules, the electives of the semester (chosen ones first,
    /// then free places), the place of area D, and the thesis last.
    static func slots(_ catalog: StudyCatalog, _ study: LearningStudy) -> [Slot] {
        let taken = Set(study.modules.map(\.code))
        var slots: [Slot] = []
        for semester in 1...catalog.semesters {
            let compulsory = catalog.compulsory.filter { $0.semester == semester }
            for module in compulsory where module.kind != .thesis {
                slots.append(Slot(semester: semester, ects: module.ects, code: module.code))
            }
            for area in catalog.areas where area.semester == semester {
                let chosen = study.modules.compactMap { catalog.module($0.code) }.filter { $0.area == area.id }.prefix(area.picks)
                for module in chosen { slots.append(Slot(semester: semester, ects: module.ects, code: module.code, area: area.id)) }
                // A free place counts with the size of the area's first option.
                let size = catalog.options(of: area.id).first?.ects ?? 5
                for _ in chosen.count..<area.picks { slots.append(Slot(semester: semester, ects: size, area: area.id)) }
            }
            for area in catalog.areas where area.semester == nil {
                let fixed = catalog.options(of: area.id).filter { $0.semester == semester }
                for module in fixed {
                    let code = study.practical != .internship && taken.contains(module.code) ? module.code : nil
                    slots.append(Slot(semester: semester, ects: module.ects, code: code, area: area.id))
                }
            }
            for module in compulsory where module.kind == .thesis {
                slots.append(Slot(semester: semester, ects: module.ects, code: module.code))
            }
        }
        return slots
    }

    /// The month every module taken falls in when the ECTS are spread evenly over the model's months: a module's month
    /// is the one in which its last ECTS is reached. The internship takes the month of the last place it replaces.
    static func distribute(_ catalog: StudyCatalog, _ study: LearningStudy) -> [String: StudyMonth] {
        let perMonth = study.pace.ectsPerMonth(total: catalog.ects)
        var months: [String: StudyMonth] = [:]
        var total = 0
        var lastPracticalMonth: StudyMonth?
        for slot in slots(catalog, study) {
            total += slot.ects
            let index = max(0, Int((Double(total) / perMonth - 1e-9).rounded(.up)) - 1)
            let month = study.start.adding(index)
            if let code = slot.code { months[code] = month }
            if let area = slot.area, catalog.area(area)?.semester == nil { lastPracticalMonth = month }
        }
        if study.practical == .internship, let internship = catalog.internship, study.module(internship.code) != nil {
            months[internship.code] = lastPracticalMonth ?? study.plannedEnd
        }
        return months
    }
}
