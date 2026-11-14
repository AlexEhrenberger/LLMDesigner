import Foundation

/// The lanes of the commit tree, one row per commit (newest first, in topological order). Each lane waits for one
/// commit; a commit sits on the lane that waited for it, and its parents take over that lane and, for a merge, more.
/// Lanes keep their place, so lines that pass a row stay straight.
struct GitGraphRow: Hashable, Sendable {
    /// The lane of the commit's dot.
    var lane: Int
    /// Lanes that come down from above into the dot (the commit's children).
    var incoming: [Int]
    /// Lanes the commit's parents continue on, below the dot.
    var outgoing: [Int]
    /// Lanes that pass this row without touching the dot.
    var passing: [Int]
    /// How many lanes the row needs drawn.
    var width: Int
}

enum GitGraph {
    static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        let known = Set(commits.map(\.id))
        for commit in commits {
            let incoming = lanes.indices.filter { lanes[$0] == commit.id }
            let lane: Int
            if let first = incoming.first {
                lane = first
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
            } else {
                lanes.append(nil)
                lane = lanes.count - 1
            }
            let before = lanes
            // The children's lanes end here; the first parent continues on the commit's lane.
            for index in incoming { lanes[index] = nil }
            var outgoing: [Int] = []
            // Parents outside the loaded page end the line here, so it doesn't run on forever.
            for (number, parent) in commit.parents.enumerated() where known.contains(parent) {
                if let waiting = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing.append(waiting)
                } else if number == 0 {
                    lanes[lane] = parent
                    outgoing.append(lane)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = parent
                    outgoing.append(free)
                } else {
                    lanes.append(parent)
                    outgoing.append(lanes.count - 1)
                }
            }
            let passing = before.indices.filter { index in
                before[index] != nil && before[index] != commit.id && index < lanes.count && lanes[index] == before[index]
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            let width = max(lane + 1, (incoming + outgoing + passing).map { $0 + 1 }.max() ?? 1)
            rows.append(GitGraphRow(lane: lane, incoming: incoming, outgoing: outgoing, passing: passing, width: width))
        }
        return rows
    }
}
