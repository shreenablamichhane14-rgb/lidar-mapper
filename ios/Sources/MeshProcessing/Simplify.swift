import Foundation
import simd

/// Quadric error metric edge-collapse simplification (Garland and Heckbert) for the clean
/// architectural and object meshes.
///
/// Every vertex carries the sum of the squared-distance quadrics of the face planes around
/// it (weighted by face area). Edges are collapsed cheapest first from a binary min-heap
/// with lazy deletion. Mesh boundaries are held by penalty planes through each boundary
/// edge; classification boundaries (wall to floor, for example) get the same treatment when
/// asked. Collapses that would fold a face over or break manifold topology are rejected.
/// All state lives in flat arrays; nothing is allocated per edge.
enum MeshSimplify {
    /// Settings for `simplify`.
    struct Options {
        /// Stop once the triangle count is at or below this. Nil means no count target.
        var targetTriangleCount: Int?
        /// Largest allowed error of a single collapse, in meters; collapses above it are
        /// skipped. The error is the RMS distance of the merged vertex to the planes it has
        /// absorbed: `sqrt(cost / accumulated area)`. The true surface deviation reaches
        /// about twice this value, so pass half the allowed deviation for a hard bound. Nil
        /// means no error limit.
        var maxError: Float?
        /// Weight of the boundary penalty planes, times the edge length squared.
        var boundaryWeight: Float
        /// When true, edges between faces of different `faceClass` are held like boundaries.
        var preserveClassBoundaries: Bool
        /// Weight of the class boundary penalty planes, times the edge length squared.
        var classBoundaryWeight: Float
        /// A collapse is rejected when any surviving face's new unit normal has a dot product
        /// below this with its current unit normal.
        var minimumNormalDot: Float

        /// Creates options. With both `targetTriangleCount` and `maxError` nil, `simplify`
        /// returns the input unchanged.
        init(targetTriangleCount: Int? = nil, maxError: Float? = nil, boundaryWeight: Float = 1000,
             preserveClassBoundaries: Bool = true, classBoundaryWeight: Float = 100, minimumNormalDot: Float = 0.2) {
            self.targetTriangleCount = targetTriangleCount
            self.maxError = maxError
            self.boundaryWeight = boundaryWeight
            self.preserveClassBoundaries = preserveClassBoundaries
            self.classBoundaryWeight = classBoundaryWeight
            self.minimumNormalDot = minimumNormalDot
        }
    }

    /// Outcome of `simplify`.
    struct SimplifyResult {
        /// The simplified mesh, compacted (dead faces and unused vertices dropped).
        var mesh: MeshWithAttributes
        /// Number of edge collapses performed.
        var collapses: Int
        /// Largest error of any performed collapse, in meters (same convention as
        /// `Options.maxError`); 0 when nothing was collapsed.
        var maxError: Float
    }

    /// Simplifies `input` by edge collapses until the triangle count is at or below
    /// `options.targetTriangleCount` or no valid collapse is left. Collapses whose error
    /// exceeds `options.maxError` are skipped rather than ending the run, because the heap
    /// is ordered by quadric cost (area weighted), not by error in meters, so the first
    /// over-limit entry does not mean every later one is over the limit too. A boundary
    /// collapse removes one face, so the result can land one below the target. The input
    /// is never mutated.
    ///
    /// Attributes: `faceClass` and `isInferred` follow their faces, a merged vertex keeps
    /// the `vertexColor` of the vertex that survives (a boundary vertex survives over an
    /// interior one). Faces with out-of-range indices, repeated corners or non-finite
    /// corners are dropped. When both limits are nil the input is returned unchanged.
    ///
    /// Positions, quadrics, costs and solves are in Double, relative to the mesh centroid, so
    /// meshes far from the origin keep their precision. Vertices that are never moved keep
    /// their exact input positions.
    ///
    /// Performance estimate, 1,000,000 to 200,000 triangles on an A15, single-threaded:
    /// about 400k collapses. Setup (face quadrics, the sorted edge table of 3M entries,
    /// 1.5M initial edge costs, heapify) is about 0.5 to 1 s. Each collapse costs about 7
    /// re-pushed edge costs (about 150 flops each for the quadric sum, 3x3 determinant,
    /// solve and evaluation), a link check over about 12 faces, about 11 normal-flip tests
    /// (30 flops each) and about 10 heap sift operations of about 20 levels, dominated by
    /// cache misses in the lower heap levels: roughly 3 to 4 thousand operations plus about
    /// 80 cache misses, so 5 to 8 microseconds, or 2 to 3.5 s for all collapses. Expect
    /// about 3 to 4 s in total; 5 s is a safe figure. Peak memory is about 200 MB (edge
    /// table during setup, heap of up to about 2M entries of 20 bytes, 80-byte quadric per
    /// vertex).
    static func simplify(_ input: MeshWithAttributes, options: Options) -> SimplifyResult {
        guard options.targetTriangleCount != nil || options.maxError != nil else {
            return SimplifyResult(mesh: input, collapses: 0, maxError: 0)
        }
        let work = SimplifyWorkspace(input: input, options: options)
        work.run()
        return work.result(input: input)
    }
}

/// Symmetric 4x4 quadric `sum w (n.p + d)^2`, stored as its 10 distinct entries. Internal
/// helper of `MeshSimplify`.
struct SimplifyQuadric {
    /// 3x3 part (a00, a01, a02, a11, a12, a22) then the first two linear entries (b0, b1).
    var lead = SIMD8<Double>(repeating: 0)
    /// Last linear entry b2 and the constant c.
    var rest = SIMD2<Double>(repeating: 0)

    /// The zero quadric.
    init() {}

    /// Quadric of the plane with unit normal `n` through `point`, times `w`.
    init(normal n: SIMD3<Double>, point: SIMD3<Double>, weight w: Double) {
        let d = -simd_dot(n, point)
        let xx = n.x * n.x, xy = n.x * n.y, xz = n.x * n.z
        let yy = n.y * n.y, yz = n.y * n.z, zz = n.z * n.z
        lead = w * SIMD8<Double>(xx, xy, xz, yy, yz, zz, n.x * d, n.y * d)
        rest = w * SIMD2<Double>(n.z * d, d * d)
    }

    /// Entry-wise sum.
    static func + (l: SimplifyQuadric, r: SimplifyQuadric) -> SimplifyQuadric {
        var s = l
        s.lead += r.lead
        s.rest += r.rest
        return s
    }

    /// The 3x3 part A as a matrix.
    var matrix: simd_double3x3 {
        simd_double3x3(SIMD3<Double>(lead[0], lead[1], lead[2]), SIMD3<Double>(lead[1], lead[3], lead[4]),
                       SIMD3<Double>(lead[2], lead[4], lead[5]))
    }

    /// The linear part b.
    var linear: SIMD3<Double> { SIMD3<Double>(lead[6], lead[7], rest[0]) }

    /// Quadric value at `p`: `p.A.p + 2 b.p + c`.
    func evaluate(_ p: SIMD3<Double>) -> Double {
        simd_dot(p, simd_mul(matrix, p)) + 2 * simd_dot(linear, p) + rest[1]
    }

    /// Minimizer `-A^-1 b`, or nil when A is ill-conditioned: non-positive trace, or a
    /// determinant below 1e-6 times (trace / 3)^3 (a scale-free test).
    func optimum() -> SIMD3<Double>? {
        let third = (lead[0] + lead[3] + lead[5]) / 3
        let m = matrix
        guard third > 0, simd_determinant(m) > 1e-6 * third * third * third else { return nil }
        let x = simd_mul(simd_inverse(m), -linear)
        guard x.x.isFinite, x.y.isFinite, x.z.isFinite else { return nil }
        return x
    }
}

/// One heap entry: a candidate edge (u, v) with its key and the vertex stamps at push time.
/// An entry is stale when either stamp no longer matches.
struct SimplifyHeapEntry {
    /// Collapse cost plus a tiny length tie-break.
    var key: Float
    /// First endpoint.
    var u: UInt32
    /// Second endpoint.
    var v: UInt32
    /// Stamp of `u` when pushed.
    var stampU: UInt32
    /// Stamp of `v` when pushed.
    var stampV: UInt32
}

/// Mutable working state of one `MeshSimplify.simplify` call: a single object holding flat
/// arrays that never escapes the call. Only `MeshSimplify` uses it. The cost, heap, link,
/// flip and collapse steps are in Simplify+Collapse.swift.
final class SimplifyWorkspace {
    /// Settings.
    var options = MeshSimplify.Options()
    /// Mesh centroid subtracted from all working positions.
    var center = SIMD3<Double>(repeating: 0)
    /// Working positions relative to `center`.
    var positions: [SIMD3<Double>] = []
    /// Triangle corner indices, rewritten as vertices merge.
    var indices: [UInt32] = []
    /// Per face: false for removed or invalid faces.
    var faceAlive: [Bool] = []
    /// Per vertex: moved by a collapse, still alive, on a boundary or non-manifold edge.
    var moved: [Bool] = [], vertexAlive: [Bool] = [], isBoundary: [Bool] = []
    /// Accumulated quadric per vertex.
    var quadrics: [SimplifyQuadric] = []
    /// Accumulated face area per vertex (for the error in meters).
    var weights: [Double] = []
    /// Version stamp per vertex, bumped on every collapse touching it.
    var stamps: [UInt32] = []
    /// Corner lists (corner = 3 * face + k): first and last corner per vertex and next
    /// corner per corner, -1 for none. Dead faces are skipped lazily.
    var head: [Int32] = [], tail: [Int32] = [], next: [Int32] = []
    /// Scratch marks for neighbor sets, compared against `generation`.
    var mark: [Int] = []
    /// Current mark generation.
    var generation = 0
    /// Binary min-heap on `key`.
    var heap: [SimplifyHeapEntry] = []
    /// Mean edge length, the scale for the solve distance guard.
    var meanEdgeLength = 0.0
    /// Number of live faces, number of collapses done.
    var liveFaces = 0, collapses = 0
    /// Largest error of a performed collapse, in meters.
    var maxErrorSeen = 0.0

    /// Sets up quadrics, corner lists, boundary penalties and the initial heap.
    init(input: MeshWithAttributes, options: MeshSimplify.Options) {
        self.options = options
        let mesh = input.mesh
        let vertexCount = mesh.positions.count
        let faceCount = mesh.triangleCount
        var sum = SIMD3<Double>(repeating: 0)
        var finiteCount = 0
        for p in mesh.positions where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            sum += SIMD3<Double>(p)
            finiteCount += 1
        }
        let origin = finiteCount > 0 ? sum / Double(finiteCount) : SIMD3<Double>(repeating: 0)
        center = origin
        positions = mesh.positions.map { SIMD3<Double>($0) - origin }
        moved = [Bool](repeating: false, count: vertexCount)
        indices = Array(mesh.indices.prefix(faceCount * 3))
        vertexAlive = [Bool](repeating: true, count: vertexCount)
        isBoundary = [Bool](repeating: false, count: vertexCount)
        quadrics = [SimplifyQuadric](repeating: SimplifyQuadric(), count: vertexCount)
        weights = [Double](repeating: 0, count: vertexCount)
        stamps = [UInt32](repeating: 0, count: vertexCount)
        head = [Int32](repeating: -1, count: vertexCount)
        tail = [Int32](repeating: -1, count: vertexCount)
        next = [Int32](repeating: -1, count: faceCount * 3)
        mark = [Int](repeating: 0, count: vertexCount)
        faceAlive = [Bool](repeating: false, count: faceCount)

        let n = UInt32(vertexCount)
        for f in 0..<faceCount {
            let a = indices[3 * f], b = indices[3 * f + 1], c = indices[3 * f + 2]
            guard a < n, b < n, c < n, a != b, b != c, a != c else { continue }
            guard isFinitePoint(Int(a)), isFinitePoint(Int(b)), isFinitePoint(Int(c)) else { continue }
            faceAlive[f] = true
            liveFaces += 1
            for k in 0..<3 {
                let corner = Int32(3 * f + k)
                let v = Int(indices[3 * f + k])
                if head[v] < 0 { head[v] = corner } else { next[Int(tail[v])] = corner }
                tail[v] = corner
            }
            let cross = faceCross(f)
            let doubleArea = simd_length(cross)
            guard doubleArea > 0 else { continue }
            let q = SimplifyQuadric(normal: cross / doubleArea, point: positions[Int(a)], weight: 0.5 * doubleArea)
            for k in 0..<3 {
                let v = Int(indices[3 * f + k])
                quadrics[v] = quadrics[v] + q
                weights[v] += 0.5 * doubleArea
            }
        }

        // Edges: boundary and class boundary penalties, and the candidate list.
        let table = EdgeTable(mesh: mesh)
        let classes = options.preserveClassBoundaries ? input.faceClass : nil
        var candidates: [UInt64] = []
        candidates.reserveCapacity(table.edgeCount)
        var lengthSum = 0.0
        for e in 0..<table.edgeCount {
            var uses = 0, face0 = -1, face1 = -1
            for k in table.run(e) {
                let face = Int(table.slots[k]) / 3
                guard faceAlive[face] else { continue }
                if uses == 0 { face0 = face } else if uses == 1 { face1 = face }
                uses += 1
            }
            guard uses > 0 else { continue }
            let key = table.keys[table.runStarts[e]]
            let (lo, hi) = MeshTopology.edgeVertices(key)
            let a = Int(lo), b = Int(hi)
            if uses > 2 {
                isBoundary[a] = true
                isBoundary[b] = true
                continue
            }
            lengthSum += simd_distance(positions[a], positions[b])
            candidates.append(key)
            if uses == 1 {
                isBoundary[a] = true
                isBoundary[b] = true
                addEdgePenalty(a, b, face: face0, weight: Double(options.boundaryWeight), line: true)
            } else if let c = classes, face0 < c.count, face1 < c.count, c[face0] != c[face1] {
                addEdgePenalty(a, b, face: face0, weight: Double(options.classBoundaryWeight), line: false)
                addEdgePenalty(a, b, face: face1, weight: Double(options.classBoundaryWeight), line: false)
            }
        }
        meanEdgeLength = candidates.isEmpty ? 0 : lengthSum / Double(candidates.count)

        heap.reserveCapacity(candidates.count + candidates.count / 2)
        for key in candidates {
            let (lo, hi) = MeshTopology.edgeVertices(key)
            heap.append(makeEntry(Int(lo), Int(hi)))
        }
        var i = heap.count / 2 - 1
        while i >= 0 {
            siftDown(i)
            i -= 1
        }
    }

    /// True when working position `i` has only finite coordinates.
    func isFinitePoint(_ i: Int) -> Bool {
        let p = positions[i]
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
    }

    /// Unnormalized normal (length = 2 x area) of face `f` at the working positions.
    func faceCross(_ f: Int) -> SIMD3<Double> {
        let p0 = positions[Int(indices[3 * f])]
        let p1 = positions[Int(indices[3 * f + 1])]
        let p2 = positions[Int(indices[3 * f + 2])]
        return simd_cross(p1 - p0, p2 - p0)
    }

    /// Adds to both endpoints the plane through edge (a, b) perpendicular to face `face`
    /// and, when `line` is true, a second plane through the edge perpendicular to the first,
    /// so together they penalize distance to the edge line. Weight is `weight` times the edge
    /// length squared, which matches the area units of the face quadrics.
    func addEdgePenalty(_ a: Int, _ b: Int, face: Int, weight: Double, line: Bool) {
        let pa = positions[a]
        let e = positions[b] - pa
        let lengthSquared = simd_length_squared(e)
        let side = simd_cross(e, faceCross(face))
        let sideLength = simd_length(side)
        guard lengthSquared > 0, weight > 0, sideLength > 0 else { return }
        let sideNormal = side / sideLength
        var q = SimplifyQuadric(normal: sideNormal, point: pa, weight: weight * lengthSquared)
        if line {
            let up = simd_cross(e, sideNormal)
            let upLength = simd_length(up)
            if upLength > 0 {
                q = q + SimplifyQuadric(normal: up / upLength, point: pa, weight: weight * lengthSquared)
            }
        }
        quadrics[a] = quadrics[a] + q
        quadrics[b] = quadrics[b] + q
    }

    /// Pops candidates cheapest first and collapses the valid ones until a limit is hit.
    func run() {
        let target = Swift.max(options.targetTriangleCount ?? 0, 0)
        let limit: Double? = options.maxError.map { Double($0) }
        while liveFaces > target, let entry = pop() {
            var u = Int(entry.u), v = Int(entry.v)
            guard vertexAlive[u], vertexAlive[v], stamps[u] == entry.stampU, stamps[v] == entry.stampV else { continue }
            let candidate = cost(u, v)
            let error = errorMeters(candidate.cost, u, v)
            if let limit = limit, error > limit { continue }
            if isBoundary[v] && !isBoundary[u] { swap(&u, &v) }
            guard linkAllows(u, v), flipsAllowed(u, v, candidate.position) else { continue }
            collapse(u, v, candidate.position)
            collapses += 1
            maxErrorSeen = Swift.max(maxErrorSeen, error)
        }
    }

    /// The compacted output: moved vertices written back in Float, dead faces and unused
    /// vertices dropped with attributes following.
    func result(input: MeshWithAttributes) -> MeshSimplify.SimplifyResult {
        var outPositions = input.mesh.positions
        for i in 0..<outPositions.count where moved[i] {
            outPositions[i] = SIMD3<Float>(positions[i] + center)
        }
        var working = input
        working.mesh = TriangleMesh(positions: outPositions, indices: indices)
        return MeshSimplify.SimplifyResult(mesh: working.keepingFaces(faceAlive), collapses: collapses,
                                           maxError: Float(maxErrorSeen))
    }
}
