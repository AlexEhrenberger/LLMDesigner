import Foundation

/// The calendar of a timeline: what one step of the axis is called and what follows a number. Fantasy worlds count
/// their own way ("298 n. A. E."), a chapter perhaps in hours.
struct TimelineScale: Hashable, Codable, Sendable {
    var unit = "Jahr"
    var suffix = ""

    init(unit: String = "Jahr", suffix: String = "") {
        self.unit = unit
        self.suffix = suffix
    }

    /// "298 n. A. E.", "3,5".
    func label(_ value: Double, step: Double = 1) -> String {
        let number = TimelineAxis.format(value, step: step)
        return suffix.isEmpty ? number : number + " " + suffix
    }

    /// "Jahr 298 – 305 n. A. E." for a span, "Jahr 298" for a point.
    func describe(start: Double, end: Double?) -> String {
        let unit = unit.trimmingCharacters(in: .whitespaces)
        let lead = unit.isEmpty ? "" : unit + " "
        guard let end, end != start else { return lead + label(start, step: 0.01) }
        return lead + TimelineAxis.format(start, step: 0.01) + " – " + label(end, step: 0.01)
    }
}

/// Something pinned to a timeline: a figure, place or event at a point in time, or over a span (Gantt-like).
struct TimelineEntry: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var ref: StoryRef
    var start: Double
    /// nil: a single point in time.
    var end: Double?
    var note = ""

    init(ref: StoryRef, start: Double, end: Double? = nil, note: String = "") {
        self.ref = ref
        self.start = start
        self.end = end
        self.note = note
    }

    var isSpan: Bool { end != nil }
    var last: Double { max(start, end ?? start) }
}

/// The timeline of a world, book, act or chapter.
struct StoryTimeline: Hashable, Codable, Sendable {
    /// nil: the world's calendar.
    var scale: TimelineScale?
    var entries: [TimelineEntry] = []

    var isEmpty: Bool { scale == nil && entries.isEmpty }

    /// One row per pinned element: events first, then figures, then places; each kind by its first point in time.
    var rows: [StoryRef] {
        var firsts: [StoryRef: Double] = [:]
        for entry in entries {
            firsts[entry.ref] = min(firsts[entry.ref] ?? .infinity, entry.start)
        }
        let order = StoryElementKind.pinnable
        return firsts.keys.sorted { a, b in
            let ka = order.firstIndex(of: a.kind) ?? 9, kb = order.firstIndex(of: b.kind) ?? 9
            if ka != kb { return ka < kb }
            if firsts[a] != firsts[b] { return firsts[a]! < firsts[b]! }
            return a.id.uuidString < b.id.uuidString
        }
    }

    func entries(of ref: StoryRef) -> [TimelineEntry] {
        entries.filter { $0.ref == ref }.sorted { $0.start < $1.start }
    }

    /// From the earliest to the latest point, nil while nothing is pinned.
    var extent: ClosedRange<Double>? {
        guard let first = entries.map(\.start).min(), let last = entries.map(\.last).max() else { return nil }
        return first...last
    }
}

/// Numbers on the axis: a step of 1, 2 or 5 times a power of ten, so labels stay round.
enum TimelineAxis {
    /// The smallest round step that is at least `minimum`.
    static func niceStep(atLeast minimum: Double) -> Double {
        guard minimum > 0, minimum.isFinite else { return 1 }
        let power = pow(10, floor(log10(minimum)))
        for factor in [1.0, 2, 5, 10] where factor * power >= minimum * 0.999_999 {
            return factor * power
        }
        return 10 * power
    }

    /// The axis step for a zoom of `pointsPerUnit`, keeping labels at least `spacing` points apart.
    static func step(pointsPerUnit: Double, spacing: Double = 72) -> Double {
        niceStep(atLeast: spacing / max(pointsPerUnit, 0.000_001))
    }

    /// What a drag snaps to: a fifth of the step, but whole units once the step is at least one.
    static func snap(for step: Double) -> Double {
        let fine = niceStep(atLeast: step / 5)
        return step >= 1 ? max(1, fine) : fine
    }

    static func snapped(_ value: Double, to snap: Double) -> Double {
        guard snap > 0 else { return value }
        let result = (value / snap).rounded() * snap
        // Avoid -0 and float dust such as 2.9999999.
        return abs(result) < snap / 1000 ? 0 : (result * 1_000_000).rounded() / 1_000_000
    }

    /// The tick values from `range.lowerBound` to `range.upperBound`.
    static func ticks(in range: ClosedRange<Double>, step: Double) -> [Double] {
        guard step > 0, range.upperBound >= range.lowerBound else { return [] }
        var value = (range.lowerBound / step).rounded(.up) * step
        var ticks: [Double] = []
        while value <= range.upperBound + step / 1000, ticks.count < 2000 {
            ticks.append(abs(value) < step / 1000 ? 0 : value)
            value += step
        }
        return ticks
    }

    /// The range a timeline shows: its entries in the middle with some room on both sides, at least
    /// `minimumSpan` wide.
    static func visibleRange(of extent: ClosedRange<Double>?, minimumSpan: Double = 10) -> ClosedRange<Double> {
        guard let extent else { return 0...minimumSpan }
        let width = max((extent.upperBound - extent.lowerBound) * 1.24, minimumSpan)
        let middle = (extent.lowerBound + extent.upperBound) / 2
        return (middle - width / 2)...(middle + width / 2)
    }

    /// "298", "3,5", "−12"; as many decimals as the step needs.
    static func format(_ value: Double, step: Double) -> String {
        let decimals = step >= 1 ? 0 : min(4, Int(ceil(-log10(step))))
        let style = FloatingPointFormatStyle<Double>.number
            .grouping(.never)
            .precision(.fractionLength(0...decimals))
            .locale(Locale(identifier: "de_DE"))
        return value.formatted(style)
    }
}

// MARK: - Coding (lenient, see StoryModel.swift)

extension TimelineScale {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(unit: c.lenient(.unit, "Jahr"), suffix: c.lenient(.suffix, ""))
    }
}

extension TimelineEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ref: try c.decode(StoryRef.self, forKey: .ref), start: c.lenient(.start, 0), end: c.lenient(.end, Double?.none),
                  note: c.lenient(.note, ""))
        id = c.lenient(.id, id)
    }
}

extension StoryTimeline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = c.lenient(.scale, TimelineScale?.none)
        // An entry of a kind this version doesn't know is left out rather than failing the whole timeline.
        entries = (c.lenient(.entries, [Lenient<TimelineEntry>]())).compactMap(\.value)
    }
}

/// Decodes one element of an array, or nothing if it can't be read.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
