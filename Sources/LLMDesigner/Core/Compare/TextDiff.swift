import Foundation
import LibraryMerge

/// A piece of text in a comparison: unchanged, only on the left (removed) or only on the right (added).
struct DiffSegment: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case same, removed, added }
    var text: String
    var kind: Kind
}

/// One block (paragraph, table, code, slide) of a comparison, with where it stands on each side.
struct BlockDiff: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case same, added, removed, changed
        /// The same text, at another place.
        case moved
    }

    var id: Int
    var kind: Kind
    var left: String?
    var right: String?
    var leftIndex: Int?
    var rightIndex: Int?
    /// For a removed block: the right-hand index it would go before when taken over.
    var insertAt: Int?
    /// Word by word, for changed blocks.
    var segments: [DiffSegment] = []
    /// Sentences about what isn't text (a slide's pictures and fields), and a label (the slide's title).
    var details: [String] = []
    var label: String?
    var noteSegments: [DiffSegment] = []

    var isChange: Bool { kind != .same }
}

/// Comparing texts with the standard library's difference (Myers), first by blocks, then by words.
enum TextDiff {
    /// Markdown split into blocks at blank lines; code fences, formulas and `:::` boxes stay whole. The same
    /// split as the merge driver uses, so a comparison and a merge talk about the same paragraphs.
    static func blocks(of markdown: String) -> [String] { MergeText.blocks(of: markdown) }

    /// Words, spaces and punctuation as their own tokens, so a changed comma doesn't mark the whole word.
    static func tokens(_ text: String) -> [String] { MergeText.tokens(text) }

    /// The words of two texts, as runs of the same kind.
    static func segments(_ old: String, _ new: String) -> [DiffSegment] {
        let a = tokens(old), b = tokens(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffSegment] = []
        func add(_ text: String, _ kind: DiffSegment.Kind) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text += text
            } else {
                result.append(DiffSegment(text: text, kind: kind))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                add(a[i], .removed)
                i += 1
            } else if j < b.count, inserted.contains(j) {
                add(b[j], .added)
                j += 1
            } else {
                if j < b.count { add(b[j], .same) }
                i += 1
                j += 1
            }
        }
        return result
    }

    /// How alike two texts are, from 0 to 1, by the share of unchanged words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let segments = segments(a, b)
        let same = segments.filter { $0.kind == .same }.map(\.text.count).reduce(0, +)
        let total = max(a.count, b.count)
        return total == 0 ? 1 : Double(same) / Double(total)
    }

    /// Two lists of blocks, aligned. A removed and an added block in the same place that look alike are one changed
    /// block; the same text removed in one place and added in another has moved.
    static func compare(_ old: [String], _ new: [String]) -> [BlockDiff] {
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [BlockDiff] = []
        var i = 0, j = 0
        func next(_ kind: BlockDiff.Kind, left: Int?, right: Int?, insertAt: Int? = nil) {
            var block = BlockDiff(id: result.count, kind: kind, left: left.map { old[$0] }, right: right.map { new[$0] },
                                  leftIndex: left, rightIndex: right, insertAt: insertAt)
            if kind == .changed, let l = left, let r = right { block.segments = segments(old[l], new[r]) }
            result.append(block)
        }
        while i < old.count || j < new.count {
            let isRemoved = i < old.count && removed.contains(i)
            let isInserted = j < new.count && inserted.contains(j)
            guard isRemoved || isInserted else {
                if i < old.count, j < new.count { next(.same, left: i, right: j) }
                i += 1
                j += 1
                continue
            }
            // A hunk: the removed blocks and the inserted blocks that stand together here.
            var removedRun: [Int] = []
            while i + removedRun.count < old.count, removed.contains(i + removedRun.count) { removedRun.append(i + removedRun.count) }
            var insertedRun: [Int] = []
            while j + insertedRun.count < new.count, inserted.contains(j + insertedRun.count) { insertedRun.append(j + insertedRun.count) }
            // Pairs that look alike become changed blocks, in order on both sides.
            var pairs: [(Int, Int)] = []
            var from = 0
            for r in removedRun {
                var best: (index: Int, score: Double)?
                for k in from..<insertedRun.count {
                    let score = similarity(old[r], new[insertedRun[k]])
                    if score >= 0.35, score > (best?.score ?? 0) { best = (k, score) }
                }
                if let best {
                    pairs.append((r, insertedRun[best.index]))
                    from = best.index + 1
                }
            }
            var r = 0, q = 0
            for (left, right) in pairs {
                while removedRun[r] < left { next(.removed, left: removedRun[r], right: nil, insertAt: insertedRun.indices.contains(q) ? insertedRun[q] : j + insertedRun.count); r += 1 }
                while insertedRun[q] < right { next(.added, left: nil, right: insertedRun[q]); q += 1 }
                next(.changed, left: left, right: right)
                r += 1
                q += 1
            }
            while r < removedRun.count { next(.removed, left: removedRun[r], right: nil, insertAt: j + insertedRun.count); r += 1 }
            while q < insertedRun.count { next(.added, left: nil, right: insertedRun[q]); q += 1 }
            i += removedRun.count
            j += insertedRun.count
        }
        // A paragraph that was changed and moved: the difference keeps another block in common and sees it removed
        // in one place and added in another. Very alike pairs become one changed block where it stands now.
        for index in result.indices where result[index].kind == .removed {
            guard let text = result[index].left else { continue }
            var best: (index: Int, score: Double)?
            for candidate in result.indices where result[candidate].kind == .added {
                guard let other = result[candidate].right, other != text else { continue }
                let score = similarity(text, other)
                if score >= 0.6, score > (best?.score ?? 0) { best = (candidate, score) }
            }
            guard let best else { continue }
            result[best.index].kind = .changed
            result[best.index].left = text
            result[best.index].leftIndex = result[index].leftIndex
            result[best.index].segments = segments(text, result[best.index].right!)
            result[best.index].details = ["an eine andere Stelle verschoben"]
            result[index].kind = .same
            result[index].left = nil
        }
        result.removeAll { $0.kind == .same && $0.left == nil && $0.right == nil }
        for index in result.indices { result[index].id = index }
        // Moves: a removed block whose text was added elsewhere.
        var addedByText: [String: [Int]] = [:]
        for block in result where block.kind == .added { addedByText[block.right!, default: []].append(block.id) }
        for index in result.indices where result[index].kind == .removed {
            guard let text = result[index].left, var candidates = addedByText[text], let match = candidates.first else { continue }
            candidates.removeFirst()
            addedByText[text] = candidates
            result[index].kind = .moved
            result[match].kind = .moved
        }
        return result
    }

    /// A short count of the changes, as in "2 Absätze geändert, 1 neu".
    static func summary(_ blocks: [BlockDiff], noun: (singular: String, plural: String) = ("Absatz", "Absätze")) -> String {
        let changed = blocks.filter { $0.kind == .changed }.count
        let added = blocks.filter { $0.kind == .added }.count
        let removed = blocks.filter { $0.kind == .removed }.count
        let moved = blocks.filter { $0.kind == .moved && $0.right != nil }.count
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) \(changed == 1 ? noun.singular : noun.plural) geändert") }
        if added > 0 { parts.append("\(added) neu") }
        if removed > 0 { parts.append("\(removed) entfernt") }
        if moved > 0 { parts.append("\(moved) verschoben") }
        return parts.joined(separator: ", ")
    }
}
