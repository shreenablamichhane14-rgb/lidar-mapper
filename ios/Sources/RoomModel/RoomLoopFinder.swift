import Foundation
import simd

/// Finds the closed wall loop of a room (D12) for `RoomOutline.build`. Wall endpoints within
/// the join tolerance become one junction; walls are graph edges between junctions. Dangling
/// walls (stubs, partitions touching nothing) are pruned repeatedly, then the simple cycle
/// with the largest enclosed area is kept. Deterministic: every iteration runs over arrays in
/// index order. Pure, safe on any queue.
enum RoomLoopFinder {
    /// One wall of the loop and the direction it is walked in.
    struct LoopStep: Equatable, Sendable {
        /// Index into the segment array given to `findLoop`.
        var wall: Int
        /// True when the loop walks the wall from its end to its start.
        var reversed: Bool
    }

    /// Upper bound on search steps, so a pathological wall set cannot stall processing.
    static let maxSearchSteps = 50_000

    /// The largest-area closed loop, in walking order (orientation not normalized), or nil when
    /// no loop of at least `minimumArea` square meters exists.
    static func findLoop(_ segments: [WallSegment], tolerance: Float, minimumArea: Float) -> [LoopStep]? {
        guard segments.count >= 2 else { return nil }
        let junctions = junctionIndices(segments, tolerance: tolerance)
        let positions = junctionPositions(segments, junctions: junctions)
        var alive = [Bool](repeating: true, count: segments.count)
        for w in segments.indices where junctions[2 * w] == junctions[2 * w + 1] {
            alive[w] = false
        }
        pruneDangling(junctions: junctions, junctionCount: positions.count, alive: &alive)
        var adjacency = [[(wall: Int, other: Int)]](repeating: [], count: positions.count)
        for w in segments.indices where alive[w] {
            let a = junctions[2 * w]
            let b = junctions[2 * w + 1]
            adjacency[a].append((w, b))
            adjacency[b].append((w, a))
        }
        var search = CycleSearch(adjacency: adjacency, positions: positions, segments: segments, junctions: junctions)
        search.run()
        guard let best = search.best, best.area >= minimumArea else { return nil }
        return best.steps
    }

    /// Junction index of every endpoint (2 * wall for the start, 2 * wall + 1 for the end):
    /// single-linkage clusters of endpoints of different walls within `tolerance`, numbered in
    /// order of first appearance.
    static func junctionIndices(_ segments: [WallSegment], tolerance: Float) -> [Int] {
        let count = segments.count * 2
        var parent = Array(0..<count)
        /// Root of an endpoint's cluster, with path halving.
        func root(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        /// Endpoint position.
        func point(_ e: Int) -> SIMD2<Float> { e % 2 == 0 ? segments[e / 2].start : segments[e / 2].end }
        for i in 0..<count {
            for j in (i + 1)..<Swift.max(i + 1, count) where i / 2 != j / 2 {
                if simd_distance(point(i), point(j)) <= tolerance {
                    let ri = root(i)
                    let rj = root(j)
                    if ri != rj { parent[Swift.max(ri, rj)] = Swift.min(ri, rj) }
                }
            }
        }
        var numbering: [Int: Int] = [:]
        var result: [Int] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let r = root(i)
            if let n = numbering[r] {
                result.append(n)
            } else {
                let n = numbering.count
                numbering[r] = n
                result.append(n)
            }
        }
        return result
    }

    /// Mean position of the endpoints of each junction.
    static func junctionPositions(_ segments: [WallSegment], junctions: [Int]) -> [SIMD2<Float>] {
        let count = (junctions.max() ?? -1) + 1
        var sums = [SIMD2<Float>](repeating: .zero, count: count)
        var counts = [Float](repeating: 0, count: count)
        for (e, j) in junctions.enumerated() {
            let p = e % 2 == 0 ? segments[e / 2].start : segments[e / 2].end
            sums[j] += p
            counts[j] += 1
        }
        return (0..<count).map { counts[$0] > 0 ? sums[$0] / counts[$0] : .zero }
    }

    /// Removes walls attached to a junction used by only one live wall, until none is left
    /// (the 2-core of the junction graph).
    static func pruneDangling(junctions: [Int], junctionCount: Int, alive: inout [Bool]) {
        var changed = true
        while changed {
            changed = false
            var degree = [Int](repeating: 0, count: junctionCount)
            for w in alive.indices where alive[w] {
                degree[junctions[2 * w]] += 1
                degree[junctions[2 * w + 1]] += 1
            }
            for w in alive.indices where alive[w] {
                if degree[junctions[2 * w]] < 2 || degree[junctions[2 * w + 1]] < 2 {
                    alive[w] = false
                    changed = true
                }
            }
        }
    }

    /// Depth-first enumeration of simple cycles, keeping the one with the largest area.
    private struct CycleSearch {
        /// Live walls at each junction, in wall order.
        let adjacency: [[(wall: Int, other: Int)]]
        /// Junction positions, plan meters.
        let positions: [SIMD2<Float>]
        /// The walls.
        let segments: [WallSegment]
        /// Junction of every endpoint.
        let junctions: [Int]
        /// Best cycle so far.
        var best: (steps: [LoopStep], area: Float)?
        /// Steps taken, capped by `maxSearchSteps`.
        var stepCount = 0

        /// Runs the search from every junction in order; each cycle is rooted at its smallest
        /// junction so it is found only from there.
        mutating func run() {
            for start in adjacency.indices where adjacency[start].count >= 2 {
                var visited = [Bool](repeating: false, count: adjacency.count)
                visited[start] = true
                var path: [(wall: Int, from: Int)] = []
                extend(from: start, root: start, visited: &visited, path: &path)
                if stepCount >= RoomLoopFinder.maxSearchSteps {
                    LogStore.shared.write("wall loop search stopped at \(stepCount) steps", category: RoomOutline.logCategory)
                    return
                }
            }
        }

        /// Extends the current path from `node`; records a cycle when a wall leads back to `root`.
        mutating func extend(from node: Int, root: Int, visited: inout [Bool], path: inout [(wall: Int, from: Int)]) {
            for edge in adjacency[node] {
                if stepCount >= RoomLoopFinder.maxSearchSteps { return }
                stepCount += 1
                if path.contains(where: { $0.wall == edge.wall }) { continue }
                if edge.other == root {
                    if !path.isEmpty { record(path + [(edge.wall, node)]) }
                    continue
                }
                guard edge.other > root, !visited[edge.other] else { continue }
                visited[edge.other] = true
                path.append((edge.wall, node))
                extend(from: edge.other, root: root, visited: &visited, path: &path)
                path.removeLast()
                visited[edge.other] = false
            }
        }

        /// Keeps `cycle` when it encloses more area than the best so far.
        mutating func record(_ cycle: [(wall: Int, from: Int)]) {
            let ring = cycle.map { positions[$0.from] }
            let area = Polygon2D(points: ring).area
            if let current = best, current.area >= area { return }
            let steps = cycle.map { LoopStep(wall: $0.wall, reversed: junctions[2 * $0.wall] != $0.from) }
            best = (steps, area)
        }
    }
}
