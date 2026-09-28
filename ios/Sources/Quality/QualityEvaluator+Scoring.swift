import Foundation
import simd

// Room-path scoring pieces of `QualityEvaluator`: which wall samples fall inside doors, windows
// and openings, the per-wall weighted walls score, the missing-area clusters with openings
// taken out, and the per-wall capture evidence for MeasureCore. Pure functions.

/// Per-wall result of the walls score.
struct QualityWallScores {
    /// Area-weighted mean of observed fraction times soft factor, 0...1 (0 when no wall area
    /// is expected: no walls were found).
    var score: Double
    /// Expected wall area after openings were dropped, square meters.
    var expectedArea: Float
    /// Observed fraction per clean wall; nil for a wall with no expected samples.
    var fractions: [Float?]
    /// Soft factor per clean wall.
    var factors: [Float]
    /// Expected area per clean wall after openings were dropped, square meters.
    var areas: [Float]
}

/// Cell of one unobserved sample within its element (wall index, -1 floor, -2 ceiling).
private struct QualityCellKey: Hashable {
    /// Element id of the sample.
    var element: Int
    /// Column of the cell.
    var i: Int32
    /// Row of the cell.
    var j: Int32
}

/// One door, window or opening as a rectangle in (distance along the wall, height above the
/// floor), meters, margin included.
private struct QualityOpeningRect {
    /// Lower corner.
    var lo: SIMD2<Float>
    /// Upper corner.
    var hi: SIMD2<Float>
}

/// Running sums of one cluster of unobserved samples.
private struct QualityCluster {
    /// First sample index (tie-breaker when sorting).
    var first: Int
    /// Surface class of the cluster's samples.
    var surface: SurfaceClass
    /// Total sample area, square meters.
    var area: Float = 0
    /// Sum of sample positions times their area.
    var weightedPosition = SIMD3<Float>(0, 0, 0)
    /// Sum of sample normals times their area.
    var weightedNormal = SIMD3<Float>(0, 0, 0)
    /// Normal of the first sample (fallback when the weighted normal cancels out).
    var firstNormal = SIMD3<Float>(0, 1, 0)
    /// Number of samples added.
    var count = 0

    /// An empty cluster started by sample `first`.
    init(first: Int, surface: SurfaceClass) {
        self.first = first
        self.surface = surface
    }

    /// Adds one sample weighted by its area.
    mutating func add(_ s: ExpectedSample) {
        if count == 0 { firstNormal = s.normal }
        count += 1
        area += s.area
        weightedPosition += s.position * s.area
        weightedNormal += s.normal * s.area
    }
}

extension QualityEvaluator {
    // MARK: - Openings

    /// True for each wall sample that lies inside a door, window or opening of its clean wall
    /// (plus `openingMargin`): the sample's distance along the wall's plan chord from its start
    /// (the same measure as `CleanOpening.offsetAlongWall`) and its height above the floor are
    /// tested against the opening rectangle. Openings without a wall are ignored.
    static func openingMask(_ samples: [ExpectedSample], boundary: QualityBoundary, room: CleanRoom) -> [Bool] {
        var mask = [Bool](repeating: false, count: samples.count)
        let wallCount = room.walls.count
        var origins = [SIMD2<Float>](repeating: .zero, count: wallCount)
        var directions = [SIMD2<Float>](repeating: .zero, count: wallCount)
        var rectangles = [[QualityOpeningRect]](repeating: [], count: wallCount)
        for (w, wall) in room.walls.enumerated() {
            let a = PlanAxes.toPlan(wall.start.simd)
            let d = PlanAxes.toPlan(wall.end.simd) - a
            let length = simd_length(d)
            guard length.isFinite, length > 1e-4 else { continue }
            origins[w] = a
            directions[w] = d / length
        }
        let m = openingMargin
        for opening in room.openings {
            guard let wallID = opening.wallID, let w = room.walls.firstIndex(where: { $0.id == wallID }),
                  directions[w] != .zero else { continue }
            let start = opening.offsetAlongWall
            let end = opening.offsetAlongWall + opening.width
            guard start.isFinite, end.isFinite, opening.sillHeight.isFinite, opening.headHeight.isFinite,
                  end > start, opening.headHeight > opening.sillHeight else { continue }
            let lo = SIMD2<Float>(start - m, opening.sillHeight - m)
            let hi = SIMD2<Float>(end + m, opening.headHeight + m)
            rectangles[w].append(QualityOpeningRect(lo: lo, hi: hi))
        }
        for (k, s) in samples.enumerated() where s.surface == .wall && s.element >= 0 && s.element < boundary.wallIndex.count {
            let w = boundary.wallIndex[s.element]
            guard w >= 0, w < wallCount, !rectangles[w].isEmpty else { continue }
            let along = simd_dot(PlanAxes.toPlan(s.position) - origins[w], directions[w])
            let height = s.position.y - boundary.floorY
            for r in rectangles[w] where along >= r.lo.x && along <= r.hi.x && height >= r.lo.y && height <= r.hi.y {
                mask[k] = true
                break
            }
        }
        return mask
    }

    // MARK: - Walls

    /// Per clean wall: expected and observed sample area (openings dropped), the observed
    /// fraction and the soft factor; the score is sum(area x factor x fraction) / sum(area).
    static func wallScores(_ result: ExpectedSurfacesResult, excluded: [Bool], boundary: QualityBoundary,
                           room: CleanRoom) -> QualityWallScores {
        let n = room.walls.count
        var expected = [Float](repeating: 0, count: n)
        var observed = [Float](repeating: 0, count: n)
        for (k, s) in result.samples.enumerated() where s.surface == .wall && k < excluded.count && !excluded[k] {
            guard s.element >= 0, s.element < boundary.wallIndex.count, s.area.isFinite else { continue }
            let w = boundary.wallIndex[s.element]
            guard w >= 0, w < n else { continue }
            expected[w] += s.area
            if k < result.observed.count && result.observed[k] { observed[w] += s.area }
        }
        var fractions: [Float?] = []
        var factors: [Float] = []
        var weighted: Double = 0
        var total: Double = 0
        for w in 0..<n {
            let wall = room.walls[w]
            let factor = wallFactor(confidence: wall.confidence, completedEdges: wall.completedEdges)
            factors.append(factor)
            guard expected[w] > ScanQuality.minExpectedArea else {
                fractions.append(nil)
                continue
            }
            let fraction = QualityMath.unit(observed[w] / expected[w])
            fractions.append(fraction)
            let area = Double(expected[w])
            weighted += area * Double(factor) * Double(fraction)
            total += area
        }
        let score = total > Double(ScanQuality.minExpectedArea) ? QualityMath.unit(weighted / total) : 0
        return QualityWallScores(score: score, expectedArea: Float(total), fractions: fractions, factors: factors,
                                 areas: expected)
    }

    // MARK: - Missing areas

    /// Coverage's clustering (4-neighbor cells of the same element, union-find, clusters of at
    /// least `ExpectedSurfaces.minMissingArea`, largest first) over the unobserved samples that
    /// are not inside an opening. With no opening this equals `ExpectedSurfacesResult.missing`;
    /// with openings, a region split by a window stays honest instead of vanishing because its
    /// centroid happened to fall on the glass.
    static func missingAreas(_ result: ExpectedSurfacesResult, excluded: [Bool],
                             room: CoverageRoomBoundary) -> [MissingArea] {
        let samples = result.samples
        let count = samples.count
        guard result.observed.count == count, excluded.count == count else { return [] }
        var cellIndex: [QualityCellKey: Int] = [:]
        for (k, s) in samples.enumerated() where !result.observed[k] && !excluded[k] {
            cellIndex[QualityCellKey(element: s.element, i: s.cell.x, j: s.cell.y)] = k
        }
        var parent = [Int](0..<count)
        for (k, s) in samples.enumerated() where !result.observed[k] && !excluded[k] {
            let right = QualityCellKey(element: s.element, i: s.cell.x &+ 1, j: s.cell.y)
            let up = QualityCellKey(element: s.element, i: s.cell.x, j: s.cell.y &+ 1)
            if let r = cellIndex[right] { union(&parent, k, r) }
            if let u = cellIndex[up] { union(&parent, k, u) }
        }
        var clusters: [Int: QualityCluster] = [:]
        var order: [Int] = []
        for (k, s) in samples.enumerated() where !result.observed[k] && !excluded[k] {
            let root = find(&parent, k)
            var cluster = clusters[root] ?? QualityCluster(first: k, surface: s.surface)
            if clusters[root] == nil { order.append(root) }
            cluster.add(s)
            clusters[root] = cluster
        }
        var built: [(area: MissingArea, first: Int)] = []
        for root in order {
            guard let c = clusters[root], c.area + 1e-5 >= ExpectedSurfaces.minMissingArea, c.area > 0 else { continue }
            let centroid = c.weightedPosition / c.area
            let length = simd_length(c.weightedNormal)
            let normal = length > 1e-6 ? c.weightedNormal / length : c.firstNormal
            let view = ExpectedSurfaces.suggestedViewpoint(centroid: centroid, normal: normal, room: room)
            let area = MissingArea(centroid: centroid, normal: normal, area: c.area, surface: c.surface,
                                   suggestedViewpoint: view)
            built.append((area: area, first: c.first))
        }
        built.sort { a, b in
            if a.area.area != b.area.area { return a.area.area > b.area.area }
            return a.first < b.first
        }
        return built.map { $0.area }
    }

    /// Union-find root with path halving.
    private static func find(_ parent: inout [Int], _ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    /// Union-find merge; the smaller root index becomes the root (deterministic).
    private static func union(_ parent: inout [Int], _ a: Int, _ b: Int) {
        let ra = find(&parent, a)
        let rb = find(&parent, b)
        if ra == rb { return }
        if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
    }

    // MARK: - Evidence

    /// One `WallEvidence` per clean wall that has expected samples: the median `bestDistance`
    /// and the lower-median `goodObservationCount` of the best geometry voxel near each of the
    /// wall's samples (openings dropped when any sample remains). A wall no camera saw gets
    /// `ConfidenceAdapter.defaultDistance` and 0 observations, which MeasureCore flags as low
    /// confidence.
    static func wallEvidence(_ result: ExpectedSurfacesResult, excluded: [Bool], boundary: QualityBoundary,
                             room: CleanRoom, grid: CoverageGrid) -> [WallEvidence] {
        let n = room.walls.count
        var inside = [[Int]](repeating: [], count: n)
        var all = [[Int]](repeating: [], count: n)
        for (k, s) in result.samples.enumerated() where s.surface == .wall {
            guard s.element >= 0, s.element < boundary.wallIndex.count else { continue }
            let w = boundary.wallIndex[s.element]
            guard w >= 0, w < n else { continue }
            all[w].append(k)
            if k < excluded.count && !excluded[k] { inside[w].append(k) }
        }
        var out: [WallEvidence] = []
        for w in 0..<n {
            let indices = inside[w].isEmpty ? all[w] : inside[w]
            guard !indices.isEmpty else { continue }
            var distances: [Float] = []
            var counts: [Int] = []
            for k in indices {
                guard let stats = bestVoxel(grid, near: result.samples[k].position,
                                            radius: ExpectedSurfaces.observedRadius) else { continue }
                distances.append(stats.bestDistance)
                counts.append(Int(stats.goodObservationCount))
            }
            var distance = QualityMath.median(distances) ?? ConfidenceAdapter.defaultDistance
            if !(distance.isFinite && distance > 0) { distance = ConfidenceAdapter.defaultDistance }
            let observations = QualityMath.lowerMedian(counts) ?? 0
            out.append(WallEvidence(wallID: room.walls[w].id, medianDistance: distance, observations: observations))
        }
        return out
    }

    /// The observed voxel (observationCount > 0, finite best distance) whose center lies within
    /// `radius` of `p` with the most good observations (ties: the higher best quality); nil
    /// when there is none. The same neighborhood `CoverageGrid.isObserved` scans.
    static func bestVoxel(_ grid: CoverageGrid, near p: SIMD3<Float>, radius: Float) -> CoverageStats? {
        guard radius.isFinite, radius >= 0, p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
        let r2 = radius * radius
        let lo = grid.key(for: p - SIMD3<Float>(repeating: radius))
        let hi = grid.key(for: p + SIMD3<Float>(repeating: radius))
        let spanX = Int(hi.x) - Int(lo.x)
        let spanY = Int(hi.y) - Int(lo.y)
        let spanZ = Int(hi.z) - Int(lo.z)
        guard spanX >= 0, spanY >= 0, spanZ >= 0, spanX <= 16, spanY <= 16, spanZ <= 16 else { return nil }
        var best: CoverageStats?
        for z in Int(lo.z)...Int(hi.z) {
            for y in Int(lo.y)...Int(hi.y) {
                for x in Int(lo.x)...Int(hi.x) {
                    let key = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    guard let stats = grid.voxelStats(key), stats.observationCount > 0, stats.bestDistance.isFinite,
                          simd_length_squared(grid.center(of: key) - p) <= r2 else { continue }
                    if let current = best {
                        let more = stats.goodObservationCount > current.goodObservationCount
                        let tie = stats.goodObservationCount == current.goodObservationCount
                        if more || (tie && stats.bestQuality > current.bestQuality) { best = stats }
                    } else {
                        best = stats
                    }
                }
            }
        }
        return best
    }
}
