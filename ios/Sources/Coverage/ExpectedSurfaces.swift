import Foundation
import simd

// Expected surfaces: what a room SHOULD contain (walls, floor, ceiling from a room
// boundary such as RoomPlan reports) versus what the coverage grid has observed.
// Unobserved samples are clustered into MissingArea values that drive the red overlay,
// the "missing areas" list on the scan quality screen and the guidance engine.
//
// Sampling rule (midpoint rule for partial cells): each element (one wall, the floor or
// the ceiling) is cut into cells of `spacing` meters, counted as ceil(L / s - 0.001) so a
// length that is an exact multiple of s does not gain a sliver cell. The last row or
// column may be partial: its sample sits at the midpoint of the partial cell and it is
// weighted by its true area. A 2.5 m wall at 0.2 m therefore has 13 rows, the top one at
// y = 2.45 weighted 0.02 m^2, and the wall area sums exactly to length * height.
// Floor and ceiling cells are laid on the s-grid anchored at the polygon bounding box
// minimum; a cell is kept when its center is inside the polygon (even-odd rule) and is
// weighted by its (bounding-box clipped) cell area.

/// One unobserved region of an expected surface, found by clustering missing samples.
struct MissingArea {
    /// Area-weighted centroid of the cluster, world meters.
    var centroid: SIMD3<Float>
    /// Unit normal of the surface, pointing into the room (toward where a viewer stands).
    var normal: SIMD3<Float>
    /// Total area of the cluster in square meters.
    var area: Float
    /// Surface class of the element (.wall, .floor or .ceiling).
    var surface: SurfaceClass
    /// Where the user should stand to see this area: eye height, inside the floor polygon.
    var suggestedViewpoint: SIMD3<Float>
}

/// One sample point on an expected surface.
struct ExpectedSample {
    /// World position of the sample (cell midpoint), meters.
    var position: SIMD3<Float>
    /// Unit normal pointing into the room.
    var normal: SIMD3<Float>
    /// Surface class of the element.
    var surface: SurfaceClass
    /// Element id: wall index >= 0, -1 floor, -2 ceiling.
    var element: Int
    /// Grid coordinates of the cell within its element, used for 4-neighbor adjacency.
    var cell: SIMD2<Int32>
    /// Area in square meters this sample stands for (s * s, less for partial cells).
    var area: Float = 0
}

/// Result of comparing the expected room shell with the coverage grid.
struct ExpectedSurfacesResult {
    /// All expected samples, walls first (in wall order), then floor, then ceiling.
    var samples: [ExpectedSample]
    /// observed[i] is true when samples[i] has observed coverage within `observedRadius`.
    var observed: [Bool]
    /// Missing clusters with area >= minMissingArea, sorted by area descending.
    var missing: [MissingArea]
    /// Expected area per class; keys .wall, .floor, .ceiling are always present.
    var expectedArea: [SurfaceClass: Float]
    /// Observed area per class; keys .wall, .floor, .ceiling are always present.
    var observedArea: [SurfaceClass: Float]
}

/// Samples the expected room shell, tests it against the coverage grid and clusters
/// what was never seen into missing areas.
enum ExpectedSurfaces {
    /// Grid spacing of expected samples, meters.
    static let sampleSpacing: Float = 0.20
    /// A sample counts as observed if the grid has an observed voxel center within this radius.
    static let observedRadius: Float = 0.15
    /// Clusters smaller than this (two full 0.2 m samples) are ignored, square meters.
    static let minMissingArea: Float = 0.08
    /// Eye height above the floor used for suggested viewpoints, meters.
    static let eyeHeight: Float = 1.4
    /// Distance from a missing wall area to the suggested viewpoint, meters.
    static let viewDistance: Float = 1.5
    /// Preferred distance of a suggested viewpoint from the floor polygon boundary, meters.
    static let viewpointInset: Float = 0.3
    /// Safety cap on cells per element axis, so a corrupt boundary cannot allocate without bound.
    static let maxCellsPerAxis = 2000

    // MARK: - Sampling

    /// Samples walls, floor and ceiling of `room` on a grid of `spacing` meters.
    /// Wall samples use cell midpoints along the length and up the height with a horizontal
    /// normal pointing into the room; floor samples have normal +Y at floorY and ceiling
    /// samples normal -Y at ceilingY. See the file header for the partial-cell rule.
    static func samples(for room: CoverageRoomBoundary, spacing: Float = sampleSpacing) -> [ExpectedSample] {
        guard spacing.isFinite, spacing > 0.001 else { return [] }
        var out: [ExpectedSample] = []
        for (index, wall) in room.walls.enumerated() {
            appendWallSamples(wall, index: index, polygon: room.floorPolygon, spacing: spacing, into: &out)
        }
        appendHorizontalSamples(polygon: room.floorPolygon, y: room.floorY,
                                normal: SIMD3<Float>(0, 1, 0), surface: .floor, element: -1,
                                spacing: spacing, into: &out)
        let ceilingPolygon = room.ceilingPolygon.count >= 3 ? room.ceilingPolygon : room.floorPolygon
        appendHorizontalSamples(polygon: ceilingPolygon, y: room.ceilingY,
                                normal: SIMD3<Float>(0, -1, 0), surface: .ceiling, element: -2,
                                spacing: spacing, into: &out)
        return out
    }

    /// Number of cells covering `length` at `spacing`: ceil(L / s - 0.001), capped.
    static func cellCount(length: Float, spacing: Float) -> Int {
        guard length.isFinite, length > 0, spacing > 0 else { return 0 }
        let n = min((length / spacing - 0.001).rounded(.up), Float(maxCellsPerAxis))
        guard n.isFinite else { return 0 }
        return max(Int(n), 1)
    }

    /// Start and width of cell `index` along an axis of total `length` (last cell may be partial).
    static func cellSpan(index: Int, length: Float, spacing: Float) -> (start: Float, width: Float) {
        let start = Float(index) * spacing
        let end = min(start + spacing, length)
        return (start, max(end - start, 0))
    }

    /// Horizontal unit normal of a wall pointing into the room: the perpendicular whose side
    /// (midpoint + 0.05 m * n) lies inside the floor polygon; otherwise the one toward the
    /// polygon vertex average; the left perpendicular when there is no polygon.
    static func inwardNormal(of wall: CoverageWall, polygon: [SIMD2<Float>]) -> SIMD2<Float>? {
        let d = wall.end - wall.start
        let len = simd_length(d)
        guard len > 1e-4, len.isFinite else { return nil }
        let dir = d / len
        let left = SIMD2<Float>(-dir.y, dir.x)
        let right = -left
        guard polygon.count >= 3 else { return left }
        let mid = (wall.start + wall.end) * 0.5
        let leftIn = pointInPolygon(mid + left * 0.05, polygon)
        let rightIn = pointInPolygon(mid + right * 0.05, polygon)
        if leftIn && !rightIn { return left }
        if rightIn && !leftIn { return right }
        var sum = SIMD2<Float>(0, 0)
        for p in polygon { sum += p }
        let center = sum / Float(polygon.count)
        return simd_dot(center - mid, left) >= 0 ? left : right
    }

    /// Appends the samples of one wall.
    private static func appendWallSamples(_ wall: CoverageWall, index: Int, polygon: [SIMD2<Float>],
                                          spacing: Float, into out: inout [ExpectedSample]) {
        guard let n2 = inwardNormal(of: wall, polygon: polygon) else { return }
        let d = wall.end - wall.start
        let length = simd_length(d)
        let dir = d / length
        let height = wall.height
        guard height.isFinite, height > 0, wall.baseY.isFinite else { return }
        let cols = cellCount(length: length, spacing: spacing)
        let rows = cellCount(length: height, spacing: spacing)
        let normal = SIMD3<Float>(n2.x, 0, n2.y)
        for j in 0..<rows {
            let row = cellSpan(index: j, length: height, spacing: spacing)
            guard row.width > 0 else { continue }
            let y = wall.baseY + row.start + row.width * 0.5
            for i in 0..<cols {
                let col = cellSpan(index: i, length: length, spacing: spacing)
                guard col.width > 0 else { continue }
                let p2 = wall.start + dir * (col.start + col.width * 0.5)
                out.append(ExpectedSample(position: SIMD3<Float>(p2.x, y, p2.y), normal: normal,
                                          surface: .wall, element: index,
                                          cell: SIMD2<Int32>(Int32(i), Int32(j)),
                                          area: col.width * row.width))
            }
        }
    }

    /// Appends floor or ceiling samples: s-grid cells over the polygon bounding box whose
    /// center is inside the polygon.
    private static func appendHorizontalSamples(polygon: [SIMD2<Float>], y: Float, normal: SIMD3<Float>,
                                                surface: SurfaceClass, element: Int, spacing: Float,
                                                into out: inout [ExpectedSample]) {
        guard polygon.count >= 3, y.isFinite else { return }
        var lo = SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var hi = -lo
        for p in polygon {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let size = hi - lo
        guard size.x.isFinite, size.y.isFinite else { return }
        let nx = cellCount(length: size.x, spacing: spacing)
        let nz = cellCount(length: size.y, spacing: spacing)
        for j in 0..<nz {
            let zc = cellSpan(index: j, length: size.y, spacing: spacing)
            guard zc.width > 0 else { continue }
            for i in 0..<nx {
                let xc = cellSpan(index: i, length: size.x, spacing: spacing)
                guard xc.width > 0 else { continue }
                let c = SIMD2<Float>(lo.x + xc.start + xc.width * 0.5, lo.y + zc.start + zc.width * 0.5)
                guard pointInPolygon(c, polygon) else { continue }
                out.append(ExpectedSample(position: SIMD3<Float>(c.x, y, c.y), normal: normal,
                                          surface: surface, element: element,
                                          cell: SIMD2<Int32>(Int32(i), Int32(j)),
                                          area: xc.width * zc.width))
            }
        }
    }

    // MARK: - Evaluation

    /// Samples the room, marks each sample observed via grid.isObserved(near:radius:),
    /// clusters unobserved samples of the same element over 4-neighbor cells (union-find)
    /// and returns one MissingArea per cluster of at least minMissingArea, largest first.
    static func evaluate(room: CoverageRoomBoundary, grid: CoverageGrid,
                         spacing: Float = sampleSpacing) -> ExpectedSurfacesResult {
        let all = samples(for: room, spacing: spacing)
        var observed = [Bool](repeating: false, count: all.count)
        var expectedArea: [SurfaceClass: Float] = [.wall: 0, .floor: 0, .ceiling: 0]
        var observedArea: [SurfaceClass: Float] = [.wall: 0, .floor: 0, .ceiling: 0]
        var cellIndex: [ExpSurfCellKey: Int] = [:]
        for (k, s) in all.enumerated() {
            let seen = grid.isObserved(near: s.position, radius: observedRadius)
            observed[k] = seen
            expectedArea[s.surface, default: 0] += s.area
            if seen {
                observedArea[s.surface, default: 0] += s.area
            } else {
                cellIndex[ExpSurfCellKey(element: s.element, i: s.cell.x, j: s.cell.y)] = k
            }
        }

        // Union-find over unobserved samples (indices into `all`).
        var parent = [Int](0..<all.count)
        for (k, s) in all.enumerated() where !observed[k] {
            let right = ExpSurfCellKey(element: s.element, i: s.cell.x &+ 1, j: s.cell.y)
            let up = ExpSurfCellKey(element: s.element, i: s.cell.x, j: s.cell.y &+ 1)
            if let r = cellIndex[right] { expSurfUnion(&parent, k, r) }
            if let u = cellIndex[up] { expSurfUnion(&parent, k, u) }
        }

        var clusters: [Int: ExpSurfCluster] = [:]
        var order: [Int] = []
        for (k, s) in all.enumerated() where !observed[k] {
            let root = expSurfFind(&parent, k)
            if var c = clusters[root] {
                c.add(s)
                clusters[root] = c
            } else {
                var c = ExpSurfCluster(first: k, surface: s.surface)
                c.add(s)
                clusters[root] = c
                order.append(root)
            }
        }

        var built: [(area: MissingArea, first: Int)] = []
        for root in order {
            guard let c = clusters[root], c.area + 1e-5 >= minMissingArea, c.area > 0 else { continue }
            let centroid = c.weightedPosition / c.area
            let nLen = simd_length(c.weightedNormal)
            let normal = nLen > 1e-6 ? c.weightedNormal / nLen : c.firstNormal
            let view = suggestedViewpoint(centroid: centroid, normal: normal, room: room)
            built.append((area: MissingArea(centroid: centroid, normal: normal, area: c.area,
                                            surface: c.surface, suggestedViewpoint: view), first: c.first))
        }
        built.sort { a, b in
            if a.area.area != b.area.area { return a.area.area > b.area.area }
            return a.first < b.first
        }
        return ExpectedSurfacesResult(samples: all, observed: observed, missing: built.map { $0.area },
                                      expectedArea: expectedArea, observedArea: observedArea)
    }

    // MARK: - Viewpoint

    /// Where to stand to see a missing area. Walls (mostly horizontal normal): centroid plus
    /// the horizontal normal times viewDistance. Floor and ceiling: straight above or below
    /// the centroid. Height is floorY + eyeHeight. The result is then pulled inside the floor
    /// polygon, viewpointInset from its boundary where possible (less in narrow spots).
    static func suggestedViewpoint(centroid: SIMD3<Float>, normal: SIMD3<Float>,
                                   room: CoverageRoomBoundary) -> SIMD3<Float> {
        var p = SIMD2<Float>(centroid.x, centroid.z)
        let h = SIMD2<Float>(normal.x, normal.z)
        let hLen = simd_length(h)
        if abs(normal.y) < 0.7, hLen > 1e-4 {
            p += (h / hLen) * viewDistance
        }
        let y = room.floorY + eyeHeight
        let polygon = room.floorPolygon
        guard polygon.count >= 3 else { return SIMD3<Float>(p.x, y, p.y) }
        for inset in [viewpointInset, viewpointInset * 0.5, 0.05] {
            if let q = clampInside(p, polygon, inset: inset) {
                return SIMD3<Float>(q.x, y, q.y)
            }
        }
        if pointInPolygon(p, polygon) { return SIMD3<Float>(p.x, y, p.y) }
        let near = expSurfNearestBoundary(p, polygon)
        return SIMD3<Float>(near.point.x, y, near.point.y)
    }

    /// Moves `p` inside `polygon` so it is at least `inset` from every edge, pushing along
    /// the inward normal of the nearest edge a few times; nil when that does not converge.
    static func clampInside(_ p: SIMD2<Float>, _ polygon: [SIMD2<Float>], inset: Float) -> SIMD2<Float>? {
        let ccw = expSurfSignedArea(polygon) >= 0
        var q = p
        for _ in 0..<8 {
            let inside = pointInPolygon(q, polygon)
            let near = expSurfNearestBoundary(q, polygon)
            if inside && near.distance >= inset - 1e-4 { return q }
            let a = polygon[near.edge]
            let b = polygon[(near.edge + 1) % polygon.count]
            let e = b - a
            let eLen = simd_length(e)
            guard eLen > 1e-6 else { return nil }
            let left = SIMD2<Float>(-e.y, e.x) / eLen
            let inward = ccw ? left : -left
            q = near.point + inward * inset
        }
        let near = expSurfNearestBoundary(q, polygon)
        return pointInPolygon(q, polygon) && near.distance >= inset - 1e-4 ? q : nil
    }

    // MARK: - Geometry

    /// Even-odd point in polygon test on the (x, z) plane; polygon in either winding.
    static func pointInPolygon(_ p: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (p.y - a.y) / (b.y - a.y)
                let x = a.x + t * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Private helpers

/// Hash key of one cell within one element.
private struct ExpSurfCellKey: Hashable {
    var element: Int
    var i: Int32
    var j: Int32
}

/// Running sums of one cluster of unobserved samples.
private struct ExpSurfCluster {
    /// First sample index, surface class, total area and area-weighted sums of the cluster.
    var first: Int
    var surface: SurfaceClass
    var area: Float = 0
    var weightedPosition = SIMD3<Float>(0, 0, 0)
    var weightedNormal = SIMD3<Float>(0, 0, 0)
    var firstNormal = SIMD3<Float>(0, 1, 0)
    var count = 0

    /// Initializes an empty cluster started by sample `first`.
    init(first: Int, surface: SurfaceClass) {
        self.first = first
        self.surface = surface
    }

    /// Adds one sample, weighted by its area.
    mutating func add(_ s: ExpectedSample) {
        if count == 0 { firstNormal = s.normal }
        count += 1
        area += s.area
        weightedPosition += s.position * s.area
        weightedNormal += s.normal * s.area
    }
}

/// Union-find root with path halving.
private func expSurfFind(_ parent: inout [Int], _ x: Int) -> Int {
    var x = x
    while parent[x] != x {
        parent[x] = parent[parent[x]]
        x = parent[x]
    }
    return x
}

/// Union-find merge; the smaller root index becomes the root (deterministic).
private func expSurfUnion(_ parent: inout [Int], _ a: Int, _ b: Int) {
    let ra = expSurfFind(&parent, a)
    let rb = expSurfFind(&parent, b)
    if ra == rb { return }
    if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
}

/// Signed area of a polygon in (x, z) (positive for counterclockwise in that plane).
private func expSurfSignedArea(_ polygon: [SIMD2<Float>]) -> Float {
    var sum: Float = 0
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i]
        let b = polygon[(i + 1) % n]
        sum += a.x * b.y - b.x * a.y
    }
    return sum * 0.5
}

/// Nearest point on the polygon boundary to `p`, its distance and the edge index it lies on.
private func expSurfNearestBoundary(_ p: SIMD2<Float>,
                                    _ polygon: [SIMD2<Float>]) -> (point: SIMD2<Float>, distance: Float, edge: Int) {
    var best = (point: p, distance: Float.greatestFiniteMagnitude, edge: 0)
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i]
        let b = polygon[(i + 1) % n]
        let e = b - a
        let len2 = simd_dot(e, e)
        var t: Float = 0
        if len2 > 1e-12 { t = min(max(simd_dot(p - a, e) / len2, 0), 1) }
        let q = a + e * t
        let d = simd_length(p - q)
        if d < best.distance { best = (point: q, distance: d, edge: i) }
    }
    return best
}
