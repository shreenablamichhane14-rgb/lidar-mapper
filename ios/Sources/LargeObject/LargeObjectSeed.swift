import Foundation
import simd

// Seed, floor, growth and box of a large object (docs/MODULES.md 3.39, D4, D14): the face
// samples near the tapped seed, the floor height from floor-classified faces (never from plane
// anchors), a 26-connected voxel flood fill from the seed over the faces above the floor with
// tall wall columns left out, the gravity-aligned box with margins, and the tap's ray pick
// against the live faces. Pure: no ARKit, no clock, any thread (the tracker queue or a detached
// task, never main or the hub queue).

/// One face sample for the growth: a face centroid and its class.
struct LargeObjectSample: Equatable { var position: SIMD3<Float>; var surface: SurfaceClass }

/// Result of the growth with the reason when it is empty (an addition to the 3.39 API, so the
/// model can tell "tapped a wall" from "nothing there").
struct LargeObjectGrowth: Equatable {
    /// Sample positions of the filled voxels (empty when nothing grew).
    var points: [SIMD3<Float>]
    /// True when the seed (or the nearest occupied voxel within the snap radius) lies in a wall column.
    var seedInWallColumn: Bool
    /// Occupied voxels filled from the seed.
    var voxelCount: Int
}

/// Seed, floor, growth and box. Pure.
enum LargeObjectSeed {
    /// Voxel edge of the growth, meters.
    static let voxelSize: Float = 0.10
    /// Samples at most this far above the floor are left out of the growth, meters.
    static let floorClearance: Float = 0.04
    /// Horizontal search radius from the seed, meters.
    static let searchRadius: Float = 4.0          // horizontal, from the seed
    /// Highest sample above the floor that the growth keeps, meters.
    static let maxHeight: Float = 3.0             // above the floor
    /// Largest distance from the seed to the nearest occupied voxel's samples, meters.
    static let snapRadius: Float = 0.3            // to the nearest occupied voxel
    /// Columns whose top is higher than this above the floor and whose samples are mostly wall,
    /// door or window are walls, meters.
    static let wallColumnHeight: Float = 2.3      // columns taller than this and mostly wall, door or window are walls
    /// Margin on every side of the box but the bottom, meters.
    static let boxMargin: Float = 0.05
    /// Fewest grown points for a box.
    static let minPoints = 30
    /// Least `.floor` samples within `floorSearchRadius` for the median rule.
    static let minFloorSamples = 20
    /// Horizontal radius of the floor samples, meters.
    static let floorSearchRadius: Float = 3.0
    /// Horizontal radius of the percentile fallback, meters.
    static let fallbackFloorRadius: Float = 1.5
    /// Floor samples higher than the seed by more than this are ignored (another level), meters.
    static let floorAboveSeedTolerance: Float = 0.1
    /// Percentile of the fallback floor height.
    static let fallbackPercentile: Double = 0.05

    // MARK: - Samples and floor

    /// Samples (face centroids with area > 0 and their class) of the anchors whose bounds come within
    /// `searchRadius` of the seed.
    static func samples(from anchors: [CoverageAnchorFaces], near seed: SIMD3<Float>) -> [LargeObjectSample] {
        var out: [LargeObjectSample] = []
        for anchor in anchors where horizontalDistance(from: seed, toBoundsMin: anchor.boundsMin,
                                                       max: anchor.boundsMax) <= searchRadius {
            out.reserveCapacity(out.count + anchor.faces.count)
            for face in anchor.faces where face.area > 0 && face.area.isFinite && isFinite(face.centroid) {
                out.append(LargeObjectSample(position: face.centroid, surface: face.surface))
            }
        }
        return out
    }

    /// Median y of `.floor` samples within 3 m (horizontal) when at least 20, else the 5th percentile of
    /// all samples within 1.5 m, else nil. Floor samples more than 0.1 m above the seed are ignored.
    static func floorHeight(seed: SIMD3<Float>, samples: [LargeObjectSample]) -> Float? {
        guard isFinite(seed) else { return nil }
        let floorRadius2 = floorSearchRadius * floorSearchRadius
        let fallbackRadius2 = fallbackFloorRadius * fallbackFloorRadius
        let highestFloor = seed.y + floorAboveSeedTolerance
        var floorHeights: [Float] = []
        var nearHeights: [Float] = []
        for sample in samples {
            let p = sample.position
            let dx = p.x - seed.x
            let dz = p.z - seed.z
            let d2 = dx * dx + dz * dz
            if sample.surface == .floor && d2 <= floorRadius2 && p.y <= highestFloor { floorHeights.append(p.y) }
            if d2 <= fallbackRadius2 { nearHeights.append(p.y) }
        }
        if floorHeights.count >= minFloorSamples {
            floorHeights.sort()
            let middle = floorHeights.count / 2
            if floorHeights.count % 2 == 1 { return floorHeights[middle] }
            return (floorHeights[middle - 1] + floorHeights[middle]) * 0.5
        }
        guard !nearHeights.isEmpty else { return nil }
        nearHeights.sort()
        let rank = (Double(nearHeights.count - 1) * fallbackPercentile).rounded()
        let index = min(max(Int(rank), 0), nearHeights.count - 1)
        return nearHeights[index]
    }

    // MARK: - Growth

    /// Occupied voxels above floorY + floorClearance and below floorY + maxHeight within searchRadius,
    /// `.floor` and `.ceiling` samples ignored, wall columns removed; 26-connected flood fill from the seed
    /// voxel or the nearest occupied voxel within snapRadius. Returns the sample positions of the filled
    /// voxels; empty when the seed is in a wall column or nothing is near.
    static func grow(seed: SIMD3<Float>, samples: [LargeObjectSample], floorY: Float) -> [SIMD3<Float>] {
        growDetailed(seed: seed, samples: samples, floorY: floorY).points
    }

    /// `grow` with the reason when it is empty. A column is the set of voxels sharing (x, z); its
    /// height is the highest sample above the floor, so a wall partly hidden behind the object still
    /// counts as a wall.
    static func growDetailed(seed: SIMD3<Float>, samples: [LargeObjectSample], floorY: Float) -> LargeObjectGrowth {
        let nothing = LargeObjectGrowth(points: [], seedInWallColumn: false, voxelCount: 0)
        guard isFinite(seed), floorY.isFinite else { return nothing }
        let grid = LargeObjectVoxels.build(seed: seed, samples: samples, floorY: floorY)
        guard !grid.keys.isEmpty else { return nothing }
        let seedKey = voxelKey(seed)
        var start: Int?
        if let index = grid.index[seedKey] {
            start = index
        } else if let nearest = grid.nearestToSeed {
            start = nearest
        }
        guard let first = start else { return nothing }
        if grid.isWall[first] || grid.columnIsWall(seedKey) {
            return LargeObjectGrowth(points: [], seedInWallColumn: true, voxelCount: 0)
        }
        var visited = [Bool](repeating: false, count: grid.keys.count)
        var queue: [Int] = [first]
        visited[first] = true
        var head = 0
        while head < queue.count {
            let current = grid.keys[queue[head]]
            head += 1
            for dx in Int32(-1)...Int32(1) {
                for dy in Int32(-1)...Int32(1) {
                    for dz in Int32(-1)...Int32(1) {
                        let key = SIMD3<Int32>(current.x &+ dx, current.y &+ dy, current.z &+ dz)
                        guard let next = grid.index[key], !visited[next], !grid.isWall[next] else { continue }
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }
        }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(grid.sampleVoxel.count)
        for (offset, voxel) in grid.sampleVoxel.enumerated() where visited[voxel] {
            points.append(grid.samplePositions[offset])
        }
        return LargeObjectGrowth(points: points, seedInWallColumn: false, voxelCount: queue.count)
    }

    // MARK: - Box

    /// `OrientedBox.fit(points, gravityAligned: true)`, bottom extended down to floorY, `boxMargin` on every
    /// side (the bottom stays on the floor); nil under `minPoints` points.
    static func box(points: [SIMD3<Float>], floorY: Float) -> OrientedBox? {
        guard points.count >= minPoints, floorY.isFinite,
              let fitted = OrientedBox.fit(points, gravityAligned: true) else { return nil }
        let halfHeight = fitted.halfExtents.y
        let top = fitted.center.y + halfHeight + boxMargin
        let bottom = min(fitted.center.y - halfHeight, floorY)
        guard top > bottom else { return nil }
        let center = SIMD3<Float>(fitted.center.x, (top + bottom) * 0.5, fitted.center.z)
        let half = SIMD3<Float>(fitted.halfExtents.x + boxMargin, (top - bottom) * 0.5, fitted.halfExtents.z + boxMargin)
        return OrientedBox(center: center, axes: fitted.axes, halfExtents: half)
    }

    // MARK: - Ray pick

    /// Anchors whose world bounds the ray crosses within `maxDistance` (slab test).
    static func anchorsOnRay(_ ray: Ray, anchors: [CoverageAnchorFaces], maxDistance: Float) -> [CoverageAnchorFaces] {
        let length = simd_length(ray.direction)
        guard length.isFinite, length > 0, maxDistance > 0 else { return [] }
        let direction = ray.direction / length
        return anchors.filter { anchor in
            slabEntry(origin: ray.origin, direction: direction, boundsMin: anchor.boundsMin,
                      boundsMax: anchor.boundsMax).map { $0 <= maxDistance } ?? false
        }
    }

    /// World triangles of `anchors` (local positions through their transforms), merged.
    static func worldMesh(_ anchors: [CoverageAnchorFaces]) -> TriangleMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for anchor in anchors {
            let offset = positions.count
            guard offset + anchor.localPositions.count < Int(UInt32.max) else { break }
            let t = anchor.transform
            for p in anchor.localPositions {
                let h = simd_mul(t, SIMD4<Float>(p, 1))
                positions.append(SIMD3<Float>(h.x, h.y, h.z))
            }
            let count = anchor.localPositions.count
            let triangles = anchor.indices.count / 3
            for f in 0..<triangles {
                let a = Int(anchor.indices[3 * f])
                let b = Int(anchor.indices[3 * f + 1])
                let c = Int(anchor.indices[3 * f + 2])
                guard a < count, b < count, c < count else { continue }
                indices.append(UInt32(offset + a))
                indices.append(UInt32(offset + b))
                indices.append(UInt32(offset + c))
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Nearest hit on `mesh` (MeshBVH) within `maxDistance`.
    static func pick(_ ray: Ray, mesh: TriangleMesh, maxDistance: Float) -> SIMD3<Float>? {
        guard mesh.triangleCount > 0 else { return nil }
        return MeshBVH(mesh: mesh).raycast(ray, maxDistance: maxDistance)?.point
    }

    // MARK: - Helpers

    /// Voxel of a point (floor of point / voxelSize), clamped to the Int32 range.
    static func voxelKey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(cell(p.x), cell(p.y), cell(p.z))
    }

    /// One voxel index along an axis.
    static func cell(_ value: Float) -> Int32 {
        let scaled = (value / voxelSize).rounded(.down)
        guard scaled.isFinite else { return 0 }
        return Int32(min(max(scaled, -1_000_000), 1_000_000))
    }

    /// Horizontal distance from a point to an axis-aligned box's (x, z) rectangle (0 inside).
    static func horizontalDistance(from p: SIMD3<Float>, toBoundsMin low: SIMD3<Float>, max high: SIMD3<Float>) -> Float {
        let dx = Swift.max(low.x - p.x, 0, p.x - high.x)
        let dz = Swift.max(low.z - p.z, 0, p.z - high.z)
        let d = (dx * dx + dz * dz).squareRoot()
        return d.isFinite ? d : Float.greatestFiniteMagnitude
    }

    /// Distance along a unit direction at which a ray enters an axis-aligned box (0 when it starts
    /// inside), or nil when it misses or the box lies behind the origin.
    static func slabEntry(origin: SIMD3<Float>, direction: SIMD3<Float>, boundsMin: SIMD3<Float>,
                          boundsMax: SIMD3<Float>) -> Float? {
        var enter: Float = 0
        var exit = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = origin[axis]
            let d = direction[axis]
            let low = boundsMin[axis]
            let high = boundsMax[axis]
            if abs(d) < 1e-12 {
                if o < low || o > high { return nil }
                continue
            }
            let t1 = (low - o) / d
            let t2 = (high - o) / d
            enter = Swift.max(enter, Swift.min(t1, t2))
            exit = Swift.min(exit, Swift.max(t1, t2))
            if enter > exit { return nil }
        }
        return enter.isFinite ? enter : nil
    }

    /// True when every component is finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}

/// The occupied voxels of one growth: keys, their samples and wall columns. Built once per growth.
struct LargeObjectVoxels {
    /// Voxel keys in insertion order.
    var keys: [SIMD3<Int32>] = []
    /// Voxel index of each key.
    var index: [SIMD3<Int32>: Int] = [:]
    /// True for voxels in a wall column.
    var isWall: [Bool] = []
    /// Candidate sample positions and the voxel each falls in.
    var samplePositions: [SIMD3<Float>] = []
    var sampleVoxel: [Int] = []
    /// Wall columns by their (x, z) voxel indices.
    var wallColumns = Set<SIMD2<Int32>>()
    /// The occupied voxel whose nearest sample is closest to the seed within the snap radius.
    var nearestToSeed: Int?

    /// Classes that make a column a wall when they are the majority of its samples.
    static let wallClasses: Set<SurfaceClass> = [.wall, .door, .window]

    /// Column facts while building: highest sample, sample count and wall-like samples.
    private struct Column {
        var top: Float
        var count: Int
        var wallLike: Int
    }

    /// Groups the candidate samples (inside the search cylinder and the height band, not floor or
    /// ceiling) into voxels and marks wall columns.
    static func build(seed: SIMD3<Float>, samples: [LargeObjectSample], floorY: Float) -> LargeObjectVoxels {
        var grid = LargeObjectVoxels()
        let low = floorY + LargeObjectSeed.floorClearance
        let high = floorY + LargeObjectSeed.maxHeight
        let radius2 = LargeObjectSeed.searchRadius * LargeObjectSeed.searchRadius
        let snap2 = LargeObjectSeed.snapRadius * LargeObjectSeed.snapRadius
        var columns: [SIMD2<Int32>: Column] = [:]
        var nearestDistance2 = Float.greatestFiniteMagnitude
        for sample in samples {
            let p = sample.position
            guard sample.surface != .floor, sample.surface != .ceiling, LargeObjectSeed.isFinite(p),
                  p.y > low, p.y < high else { continue }
            let dx = p.x - seed.x
            let dz = p.z - seed.z
            guard dx * dx + dz * dz <= radius2 else { continue }
            let key = LargeObjectSeed.voxelKey(p)
            let voxel: Int
            if let existing = grid.index[key] {
                voxel = existing
            } else {
                voxel = grid.keys.count
                grid.index[key] = voxel
                grid.keys.append(key)
            }
            grid.samplePositions.append(p)
            grid.sampleVoxel.append(voxel)
            let columnKey = SIMD2<Int32>(key.x, key.z)
            let wallLike = LargeObjectVoxels.wallClasses.contains(sample.surface)
            var column = columns[columnKey] ?? Column(top: p.y, count: 0, wallLike: 0)
            column.top = Swift.max(column.top, p.y)
            column.count += 1
            if wallLike { column.wallLike += 1 }
            columns[columnKey] = column
            let seedDistance2 = simd_distance_squared(p, seed)
            if seedDistance2 <= snap2 && seedDistance2 < nearestDistance2 {
                nearestDistance2 = seedDistance2
                grid.nearestToSeed = voxel
            }
        }
        for (key, column) in columns where column.top - floorY > LargeObjectSeed.wallColumnHeight
            && column.wallLike * 2 > column.count {
            grid.wallColumns.insert(key)
        }
        let walls = grid.wallColumns
        grid.isWall = grid.keys.map { walls.contains(SIMD2<Int32>($0.x, $0.z)) }
        return grid
    }

    /// True when the (x, z) column of `key` is a wall column.
    func columnIsWall(_ key: SIMD3<Int32>) -> Bool {
        wallColumns.contains(SIMD2<Int32>(key.x, key.z))
    }
}
