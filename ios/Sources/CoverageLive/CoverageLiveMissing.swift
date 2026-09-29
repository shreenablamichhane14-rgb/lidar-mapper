import Foundation
import simd

// Missing areas during capture (docs/MODULES.md 3.31): the D19 filter (windows, doors and
// openings are never missing), the "Do not overwhelm the user" rules that decide which areas
// reach guidance (only after 30 s, only areas missing for 15 s, only within 3 m, at most 3),
// the ages that make those rules work, the watched-set fractions MissingAreas reads, and the
// completeness rule behind "Looks good" (SPEC LIVE SCANNING EXPERIENCE, SCAN QUALITY SYSTEM).

/// First-seen times of missing areas across evaluations. A key is the surface raw value plus the
/// centroid rounded to 0.5 m (clusters drift as coverage grows).
struct CoverageLiveMissingAges: Equatable {
    /// Grid of the centroid rounding, meters.
    static let keyStep: Float = 0.5
    /// An area whose rounded key changed still keeps its age when a forgotten area of the same
    /// surface was within this distance, meters (a centroid that crossed a rounding edge).
    static let matchRadius: Float = 0.5

    /// Tracked areas by key.
    private var entries: [CoverageLiveAgeKey: CoverageLiveAgeEntry] = [:]

    /// No areas tracked.
    init() {}

    /// Ages in seconds, one per area in the same order; keys not seen this time are forgotten.
    mutating func update(_ areas: [MissingArea], now: Double) -> [Double] {
        var next: [CoverageLiveAgeKey: CoverageLiveAgeEntry] = [:]
        var unclaimed = entries
        var ages: [Double] = []
        ages.reserveCapacity(areas.count)
        for area in areas {
            let key = CoverageLiveMissingAges.key(for: area)
            var firstSeen = now
            if let same = next[key] {
                firstSeen = same.firstSeen
            } else if let known = unclaimed.removeValue(forKey: key) {
                firstSeen = known.firstSeen
            } else if let near = CoverageLiveMissingAges.nearest(to: area, in: unclaimed) {
                unclaimed.removeValue(forKey: near.key)
                firstSeen = near.entry.firstSeen
            }
            if next[key] == nil {
                next[key] = CoverageLiveAgeEntry(firstSeen: firstSeen, centroid: area.centroid,
                                                 surface: area.surface.rawValue)
            }
            let age = now - firstSeen
            ages.append(age.isFinite ? max(age, 0) : 0)
        }
        entries = next
        return ages
    }

    /// The key of one area: surface raw value and the centroid rounded to `keyStep`.
    static func key(for area: MissingArea) -> CoverageLiveAgeKey {
        let c = area.centroid / keyStep
        return CoverageLiveAgeKey(surface: area.surface.rawValue,
                                  cell: SIMD3<Int32>(rounded(c.x), rounded(c.y), rounded(c.z)))
    }

    /// The closest unclaimed entry of the same surface within `matchRadius`, nil when none.
    private static func nearest(to area: MissingArea,
                                in pool: [CoverageLiveAgeKey: CoverageLiveAgeEntry])
        -> (key: CoverageLiveAgeKey, entry: CoverageLiveAgeEntry)? {
        var best: (key: CoverageLiveAgeKey, entry: CoverageLiveAgeEntry, distance: Float)?
        for (key, entry) in pool where entry.surface == area.surface.rawValue {
            let distance = simd_distance(entry.centroid, area.centroid)
            guard distance.isFinite, distance <= matchRadius else { continue }
            if let current = best {
                let closer = distance < current.distance
                let tie = distance == current.distance && entry.firstSeen < current.entry.firstSeen
                if !closer && !tie { continue }
            }
            best = (key: key, entry: entry, distance: distance)
        }
        guard let found = best else { return nil }
        return (key: found.key, entry: found.entry)
    }

    /// `value` rounded to the nearest integer as Int32; 0 when not finite or out of range.
    private static func rounded(_ value: Float) -> Int32 {
        let r = value.rounded()
        guard r.isFinite, abs(r) < 1_000_000_000 else { return 0 }
        return Int32(r)
    }
}

/// Key of one tracked missing area: surface raw value and rounded centroid.
struct CoverageLiveAgeKey: Hashable {
    /// `SurfaceClass.rawValue` of the area.
    var surface: UInt8
    /// Centroid divided by `CoverageLiveMissingAges.keyStep`, rounded.
    var cell: SIMD3<Int32>
}

/// One tracked missing area: when it was first seen and where it was last seen.
struct CoverageLiveAgeEntry: Equatable {
    /// Evaluation time the area first appeared, seconds.
    var firstSeen: Double
    /// Centroid at the latest evaluation, world meters.
    var centroid: SIMD3<Float>
    /// `SurfaceClass.rawValue` of the area.
    var surface: UInt8
}

/// Missing areas, guidance inputs and watched fractions. Pure.
enum CoverageLiveMissing {
    /// Least in-view face area for a view coverage value, square meters.
    static let minimumViewArea: Float = 0.05
    /// Observed share of the expected area at which a room counts as complete.
    static let completeFraction: Float = 0.9
    /// Most missing areas handed to guidance at once.
    static let maxNearby = 3
    /// Most voxel lookups for one point in `isWellObserved` (a larger radius counts as unobserved).
    static let maxLookupsPerPoint = 4096

    /// Drops areas whose surface is `.window` or `.door`, or whose centroid lies in an exclusion (D19).
    static func filtered(_ areas: [MissingArea], exclusions: [OrientedBox]) -> [MissingArea] {
        areas.filter { area in
            if area.surface == .window || area.surface == .door { return false }
            return !CoverageLiveBoundary.isExcluded(area.centroid, exclusions: exclusions)
        }
    }

    /// Empty before `options.nearbyAfterSeconds`; then areas at least `nearbyMinAgeSeconds` old within
    /// `nearbyRadius` (horizontal, camera to centroid), nearest first, at most 3.
    static func nearby(_ areas: [MissingArea], ages: [Double], camera: SIMD3<Float>, elapsed: Double,
                       options: CoverageLiveOptions) -> [MissingArea] {
        guard elapsed >= options.nearbyAfterSeconds else { return [] }
        var picks: [(area: MissingArea, distance: Float, index: Int)] = []
        for (index, area) in areas.enumerated() {
            guard index < ages.count, ages[index] >= options.nearbyMinAgeSeconds else { continue }
            let dx = area.centroid.x - camera.x
            let dz = area.centroid.z - camera.z
            let distance = (dx * dx + dz * dz).squareRoot()
            guard distance.isFinite, distance <= options.nearbyRadius else { continue }
            picks.append((area: area, distance: distance, index: index))
        }
        picks.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            return a.index < b.index
        }
        return picks.prefix(maxNearby).map { $0.area }
    }

    /// Area-weighted share of `faces` whose state is green; nil when their total area is under 0.05 m^2.
    static func greenFraction(faces: [CoverageFace], states: [CoverageState]) -> Float? {
        var total: Float = 0
        var green: Float = 0
        let count = min(faces.count, states.count)
        for i in 0..<count {
            let area = faces[i].area
            guard area.isFinite, area > 0 else { continue }
            total += area
            if states[i] == .green { green += area }
        }
        return fraction(green: green, total: total, minimumTotal: minimumViewArea)
    }

    /// green / total clamped to 0...1; nil when `total` is under `minimumTotal` or not finite.
    static func fraction(green: Float, total: Float, minimumTotal: Float) -> Float? {
        guard total.isFinite, total >= minimumTotal, total > 0 else { return nil }
        return min(max(green / total, 0), 1)
    }

    /// A point counts when a voxel within `radius` of it has `goodObservationCount >= 1`.
    static func wellObservedFraction(_ points: [SIMD3<Float>], grid: CoverageGrid, radius: Float) -> Float {
        guard !points.isEmpty else { return 0 }
        var good = 0
        for point in points where isWellObserved(point, grid: grid, radius: radius) { good += 1 }
        return Float(good) / Float(points.count)
    }

    /// True when a voxel whose center is within `radius` of `point` has at least one good
    /// observation (up to 64 lookups at 0.15 m and 0.1 m voxels).
    static func isWellObserved(_ point: SIMD3<Float>, grid: CoverageGrid, radius: Float) -> Bool {
        guard radius.isFinite, radius >= 0, CoverageLiveFaces.isFinite(point) else { return false }
        let r2 = radius * radius
        let low = grid.key(for: point - SIMD3<Float>(repeating: radius))
        let high = grid.key(for: point + SIMD3<Float>(repeating: radius))
        let nx = Int(high.x) - Int(low.x) + 1
        let ny = Int(high.y) - Int(low.y) + 1
        let nz = Int(high.z) - Int(low.z) + 1
        guard nx > 0, ny > 0, nz > 0, nx <= 64, ny <= 64, nz <= 64, nx * ny * nz <= maxLookupsPerPoint else { return false }
        for z in Int(low.z)...Int(high.z) {
            for y in Int(low.y)...Int(high.y) {
                for x in Int(low.x)...Int(high.x) {
                    let key = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    guard let stats = grid.voxelStats(key), stats.goodObservationCount >= 1 else { continue }
                    if simd_length_squared(grid.center(of: key) - point) <= r2 { return true }
                }
            }
        }
        return false
    }

    /// Observed at least 0.9 of the expected area and no missing area left.
    static func isComplete(observedFraction: Float, missingCount: Int) -> Bool {
        observedFraction.isFinite && observedFraction >= completeFraction && missingCount == 0
    }
}
