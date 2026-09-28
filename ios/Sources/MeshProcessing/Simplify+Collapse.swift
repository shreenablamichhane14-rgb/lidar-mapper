import Foundation
import simd

// Edge cost, heap, topology checks and the collapse step of `MeshSimplify`, split from
// Simplify.swift to keep both files short.

extension SimplifyWorkspace {
    /// Cost and position of collapsing edge (u, v). Uses the solved optimum when it is well
    /// conditioned and within twice max(edge length, mean edge length) of the midpoint;
    /// otherwise the cheapest of the endpoints, the midpoint and the 1D optimum on the edge.
    func cost(_ u: Int, _ v: Int) -> (cost: Double, position: SIMD3<Double>) {
        let q = quadrics[u] + quadrics[v]
        let pu = positions[u], pv = positions[v]
        let d = pv - pu
        let mid = (pu + pv) * 0.5
        let reach = 2 * Swift.max(simd_length(d), meanEdgeLength)
        if let x = q.optimum(), simd_distance(x, mid) <= reach {
            return (Swift.max(q.evaluate(x), 0), x)
        }
        var best = pu
        var bestCost = q.evaluate(pu)
        /// Keeps `p` when it is cheaper than the best so far.
        func consider(_ p: SIMD3<Double>) {
            let value = q.evaluate(p)
            if value < bestCost {
                bestCost = value
                best = p
            }
        }
        consider(pv)
        consider(mid)
        let m = q.matrix
        let denominator = simd_dot(d, simd_mul(m, d))
        if denominator > 0 {
            let t = -simd_dot(d, simd_mul(m, pu) + q.linear) / denominator
            if t > 0 && t < 1 { consider(pu + t * d) }
        }
        return (Swift.max(bestCost, 0), best)
    }

    /// Error in meters for a collapse cost of edge (u, v): RMS distance to absorbed planes.
    func errorMeters(_ cost: Double, _ u: Int, _ v: Int) -> Double {
        (Swift.max(cost, 0) / Swift.max(weights[u] + weights[v], 1e-30)).squareRoot()
    }

    /// Heap entry for edge (u, v) with a length tie-break added to the cost, so exactly flat
    /// regions (all costs zero) collapse short edges first instead of in index order.
    func makeEntry(_ u: Int, _ v: Int) -> SimplifyHeapEntry {
        let value = cost(u, v).cost
        let lengthSquared: Double = simd_distance_squared(positions[u], positions[v])
        let tieBreak: Double = 1e-8 * lengthSquared * (weights[u] + weights[v])
        return SimplifyHeapEntry(key: Float(value + tieBreak), u: UInt32(u), v: UInt32(v),
                                 stampU: stamps[u], stampV: stamps[v])
    }

    /// Restores heap order downward from `start`.
    func siftDown(_ start: Int) {
        let count = heap.count
        let item = heap[start]
        var i = start
        while true {
            let left = 2 * i + 1
            if left >= count { break }
            var child = left
            if left + 1 < count && heap[left + 1].key < heap[left].key { child = left + 1 }
            guard heap[child].key < item.key else { break }
            heap[i] = heap[child]
            i = child
        }
        heap[i] = item
    }

    /// Adds an entry and restores heap order upward.
    func push(_ entry: SimplifyHeapEntry) {
        heap.append(entry)
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard entry.key < heap[parent].key else { break }
            heap[i] = heap[parent]
            i = parent
        }
        heap[i] = entry
    }

    /// Removes and returns the smallest entry, or nil when the heap is empty.
    func pop() -> SimplifyHeapEntry? {
        guard let last = heap.popLast() else { return nil }
        guard let top = heap.first else { return last }
        heap[0] = last
        siftDown(0)
        return top
    }

    /// Link condition and topology guards for collapsing (u, v): the edge must exist with 1
    /// or 2 faces, the common neighbors of u and v must be exactly the opposite vertices of
    /// those faces, an interior edge must not join two boundary vertices, and enough faces
    /// must stay around the merged vertex (this also stops a tetrahedron collapsing flat).
    func linkAllows(_ u: Int, _ v: Int) -> Bool {
        generation += 2
        let g = generation
        var facesU = 0, facesV = 0, shared = 0, common = 0
        var opposite0 = -1, opposite1 = -1, distinctOpposites = 0
        var c = head[u]
        while c >= 0 {
            let f = Int(c) / 3
            if faceAlive[f] {
                facesU += 1
                var hasV = false, other = -1
                for k in 0..<3 {
                    let w = Int(indices[3 * f + k])
                    if w == u { continue }
                    mark[w] = g
                    if w == v { hasV = true } else { other = w }
                }
                if hasV {
                    shared += 1
                    if other != opposite0 && other != opposite1 {
                        if distinctOpposites == 0 { opposite0 = other } else { opposite1 = other }
                        distinctOpposites += 1
                    }
                }
            }
            c = next[Int(c)]
        }
        guard shared == 1 || shared == 2 else { return false }
        c = head[v]
        while c >= 0 {
            let f = Int(c) / 3
            if faceAlive[f] {
                facesV += 1
                for k in 0..<3 {
                    let w = Int(indices[3 * f + k])
                    if w != v && mark[w] == g {
                        common += 1
                        mark[w] = g + 1
                    }
                }
            }
            c = next[Int(c)]
        }
        guard common == distinctOpposites else { return false }
        if shared == 2 && isBoundary[u] && isBoundary[v] { return false }
        let remaining = facesU + facesV - 2 * shared
        return remaining >= 2 && (shared == 1 || remaining >= 3)
    }

    /// True when moving u and v to `x` leaves every surviving face around them with a
    /// non-degenerate area and a unit normal whose dot with its current one is at least
    /// `options.minimumNormalDot`.
    func flipsAllowed(_ u: Int, _ v: Int, _ x: SIMD3<Double>) -> Bool {
        let minimumDot = Double(options.minimumNormalDot)
        for side in 0..<2 {
            let moving = side == 0 ? u : v
            var c = head[moving]
            while c >= 0 {
                let f = Int(c) / 3
                c = next[Int(c)]
                guard faceAlive[f] else { continue }
                let i0 = Int(indices[3 * f]), i1 = Int(indices[3 * f + 1]), i2 = Int(indices[3 * f + 2])
                let hasU = i0 == u || i1 == u || i2 == u
                let hasV = i0 == v || i1 == v || i2 == v
                if hasU && hasV { continue }
                let p0 = i0 == moving ? x : positions[i0]
                let p1 = i1 == moving ? x : positions[i1]
                let p2 = i2 == moving ? x : positions[i2]
                let before = faceCross(f)
                let after = simd_cross(p1 - p0, p2 - p0)
                let beforeLength = simd_length(before)
                let afterLength = simd_length(after)
                if beforeLength == 0 { continue }
                if afterLength <= 1e-6 * beforeLength { return false }
                if simd_dot(before, after) < minimumDot * beforeLength * afterLength { return false }
            }
        }
        return true
    }

    /// Merges v into u, placed at `x`: sums quadrics and weights, kills the faces on the
    /// edge, rewrites v to u elsewhere, joins and compacts the corner lists, bumps both
    /// stamps and re-pushes every edge around u.
    func collapse(_ u: Int, _ v: Int, _ x: SIMD3<Double>) {
        positions[u] = x
        moved[u] = true
        let absorbed = quadrics[v]
        quadrics[u] = quadrics[u] + absorbed
        weights[u] += weights[v]
        if isBoundary[v] { isBoundary[u] = true }
        vertexAlive[v] = false
        let newIndex = UInt32(u)
        var c = head[v]
        while c >= 0 {
            let corner = Int(c)
            let f = corner / 3
            if faceAlive[f] {
                let base = 3 * f
                if indices[base] == newIndex || indices[base + 1] == newIndex || indices[base + 2] == newIndex {
                    faceAlive[f] = false
                    liveFaces -= 1
                } else {
                    indices[corner] = newIndex
                }
            }
            c = next[corner]
        }
        if head[u] < 0 {
            head[u] = head[v]
        } else if head[v] >= 0 {
            next[Int(tail[u])] = head[v]
        }
        head[v] = -1
        tail[v] = -1
        // Compact u's list, dropping dead faces.
        var previous: Int32 = -1
        c = head[u]
        head[u] = -1
        while c >= 0 {
            let following = next[Int(c)]
            if faceAlive[Int(c) / 3] {
                if previous < 0 { head[u] = c } else { next[Int(previous)] = c }
                previous = c
            }
            c = following
        }
        if previous >= 0 { next[Int(previous)] = -1 }
        tail[u] = previous
        stamps[u] &+= 1
        stamps[v] &+= 1

        generation += 2
        let g = generation
        c = head[u]
        while c >= 0 {
            let f = Int(c) / 3
            for k in 0..<3 {
                let w = Int(indices[3 * f + k])
                if w != u && mark[w] != g {
                    mark[w] = g
                    push(makeEntry(u, w))
                }
            }
            c = next[Int(c)]
        }
    }
}
