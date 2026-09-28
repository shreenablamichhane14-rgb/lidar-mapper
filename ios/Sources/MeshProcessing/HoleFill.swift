import Foundation
import simd

/// Finds boundary loops and closes the small ones (LiDAR dropouts, tiny gaps between
/// chunks) with new triangles flagged INFERRED. Large holes are never filled, because
/// guessing a big missing surface would misrepresent the scan.
///
/// Each small loop is projected onto its best-fit plane (`Plane.fit`), triangulated by ear
/// clipping in 2D, and falls back to a fan around a new centroid vertex when ear clipping
/// fails. New faces traverse every loop edge in the direction opposite to the existing
/// face on that edge, so the winding matches the neighbors whatever their orientation.
enum HoleFill {
    /// Loops with a perimeter at or above this many meters are left open.
    static let defaultMaxPerimeter: Float = 0.5

    /// Relative tolerance for zero-area ears and collinear corners (times scale squared).
    private static let areaEpsilon: Double = 1e-10
    /// Relative tolerance for the closed point-in-triangle test (times scale squared).
    private static let insideEpsilon: Double = 1e-12
    /// Below this ratio of (plane normal . Newell normal) to |Newell normal| the fitted
    /// plane is nearly edge-on to the loop and the Newell normal is used instead.
    private static let minimumNormalAgreement: Float = 0.5

    /// One closed boundary of the mesh.
    struct BoundaryLoop: Equatable {
        /// Vertex indices in the order of the existing faces' boundary half-edges: the face
        /// on edge (vertices[i], vertices[i + 1]) traverses it in that same direction.
        var vertices: [UInt32]
        /// Sum of the 3D edge lengths, closing edge included, in meters.
        var perimeter: Float
    }

    /// Outcome of `fillSmallHoles`.
    struct Result {
        /// The mesh with the new faces appended after the existing ones.
        var mesh: MeshWithAttributes
        /// Number of loops that were closed.
        var filledLoops: Int
        /// Number of loops left open (too large, or impossible to triangulate).
        var skippedLoops: Int
        /// Number of triangles added.
        var addedTriangles: Int
    }

    /// Every closed boundary loop of `mesh`. A boundary half-edge is a directed face edge
    /// whose reverse is used by no face. Pinched boundaries (a vertex with several
    /// outgoing boundary edges) are split into separate simple loops; open chains from
    /// broken input are dropped. Loops with fewer than 3 vertices are dropped.
    static func boundaryLoops(_ mesh: TriangleMesh) -> [BoundaryLoop] {
        boundaryData(mesh).loops
    }

    /// Fills every boundary loop whose perimeter is strictly below `maxPerimeter`. New
    /// faces go at the end with `isInferred` true (the array is created when absent, with
    /// false for existing faces); their class is the most common class of the faces along
    /// the loop. A fan fallback may add one vertex per loop (its color is the loop's mean
    /// color). The input is never mutated.
    static func fillSmallHoles(_ input: MeshWithAttributes, maxPerimeter: Float = HoleFill.defaultMaxPerimeter) -> Result {
        let mesh = input.mesh
        let data = boundaryData(mesh)
        let faceCount = mesh.triangleCount
        guard !data.loops.isEmpty else {
            return Result(mesh: input, filledLoops: 0, skippedLoops: 0, addedTriangles: 0)
        }

        // Undirected edges already in the mesh: ear diagonals must avoid them.
        var usedEdges = Set<UInt64>()
        usedEdges.reserveCapacity(faceCount * 2)
        let n = UInt32(mesh.positions.count)
        for t in 0..<faceCount {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            guard a < n, b < n, c < n else { continue }
            usedEdges.insert(MeshTopology.edgeKey(a, b))
            usedEdges.insert(MeshTopology.edgeKey(b, c))
            usedEdges.insert(MeshTopology.edgeKey(c, a))
        }

        var positions = mesh.positions
        var colors = input.vertexColor
        var newIndices: [UInt32] = []
        var newClasses: [UInt8] = []
        var filled = 0
        var skipped = 0

        for loop in data.loops {
            guard loop.perimeter < maxPerimeter, loop.vertices.count >= 3 else {
                skipped += 1
                continue
            }
            // A loop of 3 vertices that already form a face is the rim of a lone triangle:
            // filling it would only add a back face. Zero-area loops (slits) are skipped too,
            // because any fill of them is degenerate.
            if isExistingFace(loop.vertices, mesh: mesh, edgeFace: data.edgeFace)
                || !hasArea(loop.vertices, positions: mesh.positions, perimeter: loop.perimeter) {
                skipped += 1
                continue
            }
            let reversed = Array(loop.vertices.reversed())
            var triangles: [UInt32] = []
            if let local = triangulate(reversed, positions: positions, usedEdges: usedEdges) {
                triangles.reserveCapacity(local.count)
                for k in local { triangles.append(reversed[k]) }
            } else if let center = loopCentroid(reversed, positions: positions) {
                // Fan around a new centroid vertex: (loop[i], loop[i + 1], center).
                let centerIndex = UInt32(positions.count)
                positions.append(center)
                if let source = colors {
                    colors?.append(meanColor(reversed, colors: source))
                }
                let count = reversed.count
                for i in 0..<count {
                    triangles.append(reversed[i])
                    triangles.append(reversed[(i + 1) % count])
                    triangles.append(centerIndex)
                }
            } else {
                skipped += 1
                continue
            }
            let loopClass = dominantClass(loop.vertices, edgeFace: data.edgeFace, faceClass: input.faceClass)
            let added = triangles.count / 3
            for t in 0..<added {
                let a = triangles[3 * t], b = triangles[3 * t + 1], c = triangles[3 * t + 2]
                usedEdges.insert(MeshTopology.edgeKey(a, b))
                usedEdges.insert(MeshTopology.edgeKey(b, c))
                usedEdges.insert(MeshTopology.edgeKey(c, a))
                newClasses.append(loopClass)
            }
            newIndices.append(contentsOf: triangles)
            filled += 1
        }

        let addedTriangles = newIndices.count / 3
        guard addedTriangles > 0 else {
            return Result(mesh: input, filledLoops: 0, skippedLoops: skipped, addedTriangles: 0)
        }
        var inferred = input.isInferred ?? [Bool](repeating: false, count: faceCount)
        if inferred.count != faceCount {
            let old = inferred
            inferred = (0..<faceCount).map { $0 < old.count ? old[$0] : false }
        }
        inferred.append(contentsOf: [Bool](repeating: true, count: addedTriangles))
        var classes = input.faceClass
        if let source = classes {
            var fixed = source.count == faceCount
                ? source
                : (0..<faceCount).map { $0 < source.count ? source[$0] : MeshWithAttributes.unclassified }
            fixed.append(contentsOf: newClasses)
            classes = fixed
        }
        if let c = colors, c.count != positions.count { colors = nil }
        let output = MeshWithAttributes(
            mesh: TriangleMesh(positions: positions, indices: Array(mesh.indices.prefix(3 * faceCount)) + newIndices),
            faceClass: classes, vertexColor: colors, isInferred: inferred)
        return Result(mesh: output, filledLoops: filled, skippedLoops: skipped, addedTriangles: addedTriangles)
    }

    // MARK: - Boundary extraction

    /// Directed edge key: `from` in the high 32 bits, `to` in the low 32 bits.
    private static func directedKey(_ from: UInt32, _ to: UInt32) -> UInt64 {
        UInt64(from) << 32 | UInt64(to)
    }

    /// Boundary loops plus, for every boundary half-edge (directed key), the index of the
    /// face that uses it.
    private static func boundaryData(_ mesh: TriangleMesh) -> (loops: [BoundaryLoop], edgeFace: [UInt64: Int]) {
        let faceCount = mesh.triangleCount
        let n = UInt32(mesh.positions.count)
        var directed = Set<UInt64>()
        directed.reserveCapacity(faceCount * 3)
        for t in 0..<faceCount {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            guard a < n, b < n, c < n else { continue }
            if a != b { directed.insert(directedKey(a, b)) }
            if b != c { directed.insert(directedKey(b, c)) }
            if c != a { directed.insert(directedKey(c, a)) }
        }

        // Outgoing boundary edges per vertex, in first-seen order for determinism.
        var outgoing: [UInt32: [UInt32]] = [:]
        var startOrder: [UInt32] = []
        var edgeFace: [UInt64: Int] = [:]
        for t in 0..<faceCount {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            guard a < n, b < n, c < n else { continue }
            for (from, to) in [(a, b), (b, c), (c, a)] where from != to {
                guard !directed.contains(directedKey(to, from)) else { continue }
                let key = directedKey(from, to)
                guard edgeFace[key] == nil else { continue }
                edgeFace[key] = t
                if outgoing[from] == nil { startOrder.append(from) }
                outgoing[from, default: []].append(to)
            }
        }

        var loops: [BoundaryLoop] = []
        for start in startOrder {
            while let first = outgoing[start], !first.isEmpty {
                var path: [UInt32] = [start]
                var position: [UInt32: Int] = [start: 0]
                var current = start
                while true {
                    guard var outs = outgoing[current], !outs.isEmpty else {
                        // Open chain (broken input): drop what is left of the path.
                        break
                    }
                    let next = outs.removeFirst()
                    outgoing[current] = outs
                    if let index = position[next] {
                        // Closed a loop (at the start, or at a pinch vertex on the path).
                        let cycle = Array(path[index...])
                        if cycle.count >= 3 {
                            loops.append(BoundaryLoop(vertices: cycle, perimeter: perimeter(cycle, mesh.positions)))
                        }
                        for v in path[(index + 1)...] { position[v] = nil }
                        path.removeSubrange((index + 1)...)
                        current = next
                        if path.count == 1 && (outgoing[current]?.isEmpty ?? true) { break }
                    } else {
                        position[next] = path.count
                        path.append(next)
                        current = next
                    }
                }
            }
        }
        return (loops, edgeFace)
    }

    /// Closed 3D length of the loop through `vertices`.
    private static func perimeter(_ vertices: [UInt32], _ positions: [SIMD3<Float>]) -> Float {
        var sum: Float = 0
        let count = vertices.count
        for i in 0..<count {
            sum += simd_distance(positions[Int(vertices[i])], positions[Int(vertices[(i + 1) % count])])
        }
        return sum
    }

    // MARK: - Triangulation

    /// True when `loop` has exactly 3 vertices and the face on one of its boundary edges
    /// uses exactly those 3 vertices (an isolated triangle's own rim).
    private static func isExistingFace(_ loop: [UInt32], mesh: TriangleMesh, edgeFace: [UInt64: Int]) -> Bool {
        guard loop.count == 3 else { return false }
        let wanted = Set(loop)
        for i in 0..<3 {
            guard let face = edgeFace[directedKey(loop[i], loop[(i + 1) % 3])],
                  3 * face + 2 < mesh.indices.count else { continue }
            let corners: Set<UInt32> = [mesh.indices[3 * face], mesh.indices[3 * face + 1], mesh.indices[3 * face + 2]]
            if corners == wanted { return true }
        }
        return false
    }

    /// True when the loop encloses a real area: the Newell area vector is finite and larger
    /// than a tiny fraction of the perimeter squared.
    private static func hasArea(_ loop: [UInt32], positions: [SIMD3<Float>], perimeter: Float) -> Bool {
        guard let center = loopCentroid(loop, positions: positions) else { return false }
        var newell = SIMD3<Float>.zero
        let count = loop.count
        for i in 0..<count {
            newell += simd_cross(positions[Int(loop[i])] - center, positions[Int(loop[(i + 1) % count])] - center)
        }
        let area = 0.5 * simd_length(newell)
        return area.isFinite && area > Swift.max(1e-12, 1e-6 * perimeter * perimeter)
    }

    /// Triangulates the loop `vertices` (already in fill order) by ear clipping on its
    /// projection. Returns local corner indices, 3 per triangle, each triangle in loop
    /// order, or nil when the loop is degenerate or ear clipping fails.
    private static func triangulate(_ vertices: [UInt32], positions: [SIMD3<Float>], usedEdges: Set<UInt64>) -> [Int]? {
        let count = vertices.count
        guard count >= 3 else { return nil }
        let points = vertices.map { positions[Int($0)] }
        guard let center = loopCentroid(vertices, positions: positions) else { return nil }

        // Newell area vector of the fill-order loop, relative to the centroid.
        var newell = SIMD3<Float>.zero
        for i in 0..<count {
            newell += simd_cross(points[i] - center, points[(i + 1) % count] - center)
        }
        newell *= 0.5
        let newellLength = simd_length(newell)
        guard newellLength.isFinite, newellLength > 1e-12 else { return nil }
        let newellUnit = newell / newellLength

        var normal = newellUnit
        if count > 3, let fit = Plane.fit(points) {
            var fitted = fit.plane.normal
            if simd_dot(fitted, newell) < 0 { fitted = -fitted }
            if simd_dot(fitted, newellUnit) >= minimumNormalAgreement { normal = fitted }
        }

        // Right-handed frame (u, v, normal): the fill-order loop projects counter-clockwise.
        let axis: SIMD3<Float> = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(axis - normal * simd_dot(axis, normal))
        let v = simd_cross(normal, u)
        let uD = SIMD3<Double>(u), vD = SIMD3<Double>(v), cD = SIMD3<Double>(center)
        let flat: [SIMD2<Double>] = points.map { p in
            let d = SIMD3<Double>(p) - cD
            return SIMD2<Double>(simd_dot(d, uD), simd_dot(d, vD))
        }
        guard signedArea(flat) > 0 else { return nil }
        return earClip(flat, vertices: vertices, usedEdges: usedEdges)
    }

    /// Mean position of the loop vertices, or nil when it is not finite.
    private static func loopCentroid(_ vertices: [UInt32], positions: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !vertices.isEmpty else { return nil }
        var sum = SIMD3<Float>.zero
        for v in vertices { sum += positions[Int(v)] }
        let center = sum / Float(vertices.count)
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }
        return center
    }

    /// Shoelace signed area, positive for counter-clockwise rings.
    private static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        let count = ring.count
        for i in 0..<count {
            let a = ring[i], b = ring[(i + 1) % count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum * 0.5
    }

    /// Twice the signed area of triangle (a, b, c): positive when counter-clockwise.
    private static func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Cosine of the largest angle of triangle (a, b, c) (the smallest corner cosine).
    private static func worstCosine(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        func cosine(_ o: SIMD2<Double>, _ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
            let e1 = p - o, e2 = q - o
            let lengths = simd_length(e1) * simd_length(e2)
            return lengths > 0 ? simd_dot(e1, e2) / lengths : -1
        }
        return Swift.min(cosine(a, b, c), Swift.min(cosine(b, c, a), cosine(c, a, b)))
    }

    /// Ear clipping of a counter-clockwise ring. Each round clips the best-shaped valid
    /// ear: strictly convex (collinear corners are never clipped), no other remaining
    /// vertex inside or on it (compared by index), and a diagonal that is not already a
    /// mesh edge. Returns local indices, 3 per triangle, or nil when no ear is found.
    private static func earClip(_ ring: [SIMD2<Double>], vertices: [UInt32], usedEdges: Set<UInt64>) -> [Int]? {
        let count = ring.count
        guard count >= 3 else { return nil }
        var lo = ring[0], hi = ring[0]
        for p in ring {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let extent = hi - lo
        let scale = Swift.max(extent.x, extent.y)
        guard scale > 0, scale.isFinite else { return nil }
        let areaTolerance = areaEpsilon * scale * scale
        let insideTolerance = insideEpsilon * scale * scale

        var remaining = Array(0..<count)
        var result: [Int] = []
        result.reserveCapacity(3 * (count - 2))
        while remaining.count > 3 {
            let m = remaining.count
            var bestSlot = -1
            var bestScore = -Double.infinity
            for r in 0..<m {
                let p = remaining[(r + m - 1) % m], j = remaining[r], q = remaining[(r + 1) % m]
                let a = ring[p], b = ring[j], c = ring[q]
                guard cross2(a, b, c) > areaTolerance else { continue }
                guard vertices[p] != vertices[q],
                      !usedEdges.contains(MeshTopology.edgeKey(vertices[p], vertices[q])) else { continue }
                var blocked = false
                for other in remaining where other != p && other != j && other != q {
                    let x = ring[other]
                    if cross2(a, b, x) >= -insideTolerance && cross2(b, c, x) >= -insideTolerance
                        && cross2(c, a, x) >= -insideTolerance {
                        blocked = true
                        break
                    }
                }
                if blocked { continue }
                let score = worstCosine(a, b, c)
                if score > bestScore {
                    bestScore = score
                    bestSlot = r
                }
            }
            guard bestSlot >= 0 else { return nil }
            result.append(remaining[(bestSlot + m - 1) % m])
            result.append(remaining[bestSlot])
            result.append(remaining[(bestSlot + 1) % m])
            remaining.remove(at: bestSlot)
        }
        let a = remaining[0], b = remaining[1], c = remaining[2]
        guard cross2(ring[a], ring[b], ring[c]) > areaTolerance else { return nil }
        result.append(a)
        result.append(b)
        result.append(c)
        return result
    }

    // MARK: - Attributes

    /// Most common class of the existing faces along the loop's boundary edges (ties go to
    /// the smaller value); unclassified when the mesh has no classes.
    private static func dominantClass(_ loop: [UInt32], edgeFace: [UInt64: Int], faceClass: [UInt8]?) -> UInt8 {
        guard let classes = faceClass else { return MeshWithAttributes.unclassified }
        var votes = [Int](repeating: 0, count: 256)
        let count = loop.count
        for i in 0..<count {
            guard let face = edgeFace[directedKey(loop[i], loop[(i + 1) % count])], face < classes.count else { continue }
            votes[Int(classes[face])] += 1
        }
        var best = 0
        for value in 1..<256 where votes[value] > votes[best] {
            best = value
        }
        return votes[best] > 0 ? UInt8(best) : MeshWithAttributes.unclassified
    }

    /// Per-channel mean color of the loop vertices (white when none are in range).
    private static func meanColor(_ loop: [UInt32], colors: [SIMD4<UInt8>]) -> SIMD4<UInt8> {
        var sum = SIMD4<Int>(repeating: 0)
        var used = 0
        for v in loop where Int(v) < colors.count {
            let c = colors[Int(v)]
            sum &+= SIMD4<Int>(Int(c.x), Int(c.y), Int(c.z), Int(c.w))
            used += 1
        }
        guard used > 0 else { return SIMD4<UInt8>(255, 255, 255, 255) }
        let mean = sum / SIMD4<Int>(repeating: used)
        return SIMD4<UInt8>(UInt8(clamping: mean.x), UInt8(clamping: mean.y), UInt8(clamping: mean.z), UInt8(clamping: mean.w))
    }
}
