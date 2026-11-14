import Foundation

/// Three-way merging of sequences: what both sides kept of the common version stays as an anchor; between anchors
/// each side's change is taken when only one side changed, and is a conflict when both changed differently.
public enum Diff3 {
    public enum Chunk<Element: Hashable>: Equatable {
        case stable([Element])
        case changed(base: [Element], ours: [Element], theirs: [Element])
    }

    /// For every element of `base` that `other` kept unchanged: where it stands in `other`.
    static func mapping<Element: Hashable>(_ base: [Element], _ other: [Element]) -> [Int?] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in other.difference(from: base) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map = [Int?](repeating: nil, count: base.count)
        var j = 0
        for i in base.indices {
            if removed.contains(i) { continue }
            while j < other.count, inserted.contains(j) { j += 1 }
            map[i] = j
            j += 1
        }
        return map
    }

    public static func chunks<Element: Hashable>(base: [Element], ours: [Element], theirs: [Element]) -> [Chunk<Element>] {
        let toOurs = mapping(base, ours), toTheirs = mapping(base, theirs)
        var result: [Chunk<Element>] = []
        var stable: [Element] = []
        var b = 0, o = 0, t = 0
        func flush() {
            if !stable.isEmpty { result.append(.stable(stable)) }
            stable = []
        }
        for i in base.indices {
            guard let oi = toOurs[i], let ti = toTheirs[i] else { continue }
            if i > b || oi > o || ti > t {
                flush()
                result.append(.changed(base: Array(base[b..<i]), ours: Array(ours[o..<oi]), theirs: Array(theirs[t..<ti])))
            }
            stable.append(base[i])
            b = i + 1
            o = oi + 1
            t = ti + 1
        }
        flush()
        if b < base.count || o < ours.count || t < theirs.count {
            result.append(.changed(base: Array(base[b...]), ours: Array(ours[o...]), theirs: Array(theirs[t...])))
        }
        return result
    }

    /// The merged sequence when no chunk conflicts; nil otherwise.
    public static func cleanMerge<Element: Hashable>(base: [Element], ours: [Element], theirs: [Element]) -> [Element]? {
        var result: [Element] = []
        for chunk in chunks(base: base, ours: ours, theirs: theirs) {
            switch chunk {
            case .stable(let elements):
                result += elements
            case .changed(let b, let o, let t):
                if o == t || t == b { result += o } else if o == b { result += t } else { return nil }
            }
        }
        return result
    }
}

/// One place where both sides changed the same thing differently.
public struct MergeConflict: Identifiable, Hashable, Sendable {
    public let id: Int
    /// Where it is, in words: "Absatz „Die Regression …“", "Folie „Ergebnisse“", "todos „Lesen“ · erledigt".
    public let label: String
    /// The three versions as text; nil where a side doesn't have it (deleted or never there).
    public let base: String?
    public let ours: String?
    public let theirs: String?
    /// Whether "beide" makes sense (two texts in a row); not for a single value.
    public let allowsBoth: Bool
}

/// How a conflict is resolved.
public enum MergeChoice: Hashable, Sendable, Codable {
    case ours, theirs, both
    case custom(String)
}

public struct MergeResult: Sendable {
    /// The merged file; nil when it is to be deleted. Unresolved conflicts keep "ours", so the file is always valid.
    public let text: String?
    public let conflicts: [MergeConflict]

    public var isClean: Bool { conflicts.isEmpty }
}

/// Collects conflicts while a file is merged and answers with the choice made for them so far.
final class MergeContext {
    private(set) var conflicts: [MergeConflict] = []
    let choices: [Int: MergeChoice]

    init(choices: [Int: MergeChoice]) {
        self.choices = choices
    }

    /// Records a conflict; returns the choice for it, or nil when none was made yet (then "ours" holds).
    func conflict(_ label: String, base: String?, ours: String?, theirs: String?, allowsBoth: Bool) -> MergeChoice? {
        let id = conflicts.count
        conflicts.append(MergeConflict(id: id, label: label, base: base, ours: ours, theirs: theirs, allowsBoth: allowsBoth))
        return choices[id]
    }
}
