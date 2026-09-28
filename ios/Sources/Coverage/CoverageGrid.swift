import Foundation
import simd

// Coverage grid: per-face evidence in one contiguous array (indexed like the caller's faces) and
// per-voxel evidence in a sparse hash map keyed by SIMD3<Int32> (10 cm default), used for
// "was anything seen near this point" (red detection). Quality = distance * incidence *
// confidence terms. Good >= 0.5, excellent >= 0.85; green = 3 good or 1 excellent; yellow = any
// observation with quality > 0; red = expected voxel still gray; gray = unknown. With nil depth
// confidence (0.8) green needs 3 good observations; faces only seen below 0.5 stay yellow.
//
// COST (numpy prototype plus a C scalar benchmark of this loop, 200k faces): about 25 flops per
// face (squared range, depth, projection, facing); C -O2 2.6 ms on a 2.1 GHz core. A15 Swift -O
// estimate 1.5 to 3 ms per call (3 to 9 ms/s at 2 to 3 Hz) plus about 1 ms to score up to 60k
// faces; Debug is 20 to 50 times slower. The frustum test walks ALL faces from a round-robin
// cursor and stops once maxFacesPerIntegrate faces are scored; the next call resumes after the
// last face tested (`truncated` reports the early stop).
//
// Each voxel is updated at most once per call with its best face (counting per face would turn
// dense-mesh voxels green after one frame). Faces larger than a voxel also mark voxel-spaced
// points inside their equal-area disk (at most 25) so 0.3 to 0.4 m triangles leave no false
// holes. Known limit: voxels of a seen surface count for adjoining unseen surfaces within the
// lookup radius, so missing clusters stop 0.2 to 0.3 m short of room corners.

/// Per-voxel or per-face accumulated evidence.
struct CoverageStats: Equatable {
    /// Observations with quality > 0 (saturating at UInt16.max).
    var observationCount: UInt16
    /// Observations with quality >= `CoverageGrid.goodQuality` (saturating).
    var goodObservationCount: UInt16
    /// Max over observations of dot(normal, direction to camera), 0 if none.
    var bestViewCosine: Float
    /// Distance of the best-quality observation in meters, `.infinity` if none.
    var bestDistance: Float
    /// Max observation quality, 0...1.
    var bestQuality: Float

    /// No evidence at all.
    static let empty = CoverageStats(observationCount: 0, goodObservationCount: 0,
                                     bestViewCosine: 0, bestDistance: .infinity, bestQuality: 0)

    /// Folds one observation (quality, view cosine, distance) into these stats.
    mutating func add(quality: Float, viewCosine: Float, distance: Float) {
        if quality > 0 && observationCount < UInt16.max { observationCount += 1 }
        if quality >= CoverageGrid.goodQuality && goodObservationCount < UInt16.max {
            goodObservationCount += 1
        }
        if viewCosine > bestViewCosine { bestViewCosine = viewCosine }
        if quality > bestQuality {
            bestQuality = quality
            bestDistance = distance
        }
    }
}

/// What one `CoverageGrid.integrate` call did.
struct CoverageIntegrateResult {
    /// Faces run through the frustum, range and facing test.
    var facesTested: Int
    /// Faces that passed and had their stats updated (at most `CoverageGrid.maxFacesPerIntegrate`).
    var facesUpdated: Int
    /// True when the call stopped early at the cap; the next call resumes where this one stopped.
    var truncated: Bool
}

/// Best hit of one voxel within a single integrate call.
private struct CGVoxelHit {
    var quality: Float
    var viewCosine: Float
    var distance: Float
}

/// Sparse voxel hash grid plus contiguous per-face stats. See the file header for thresholds
/// and the cost estimate.
struct CoverageGrid {
    // MARK: Constants

    /// Default voxel edge in meters.
    static let defaultVoxelSize: Float = 0.10
    /// Farthest useful LiDAR range in meters.
    static let maxRange: Float = 5.0
    /// Nearest useful LiDAR range in meters (distance term is 0 below it).
    static let minRange: Float = 0.2
    /// An observation is good at or above this quality.
    static let goodQuality: Float = 0.5
    /// One observation at or above this quality makes a face green.
    static let excellentQuality: Float = 0.85
    /// Good observations needed for green.
    static let greenGoodCount = 3
    /// Cap on faces scored per integrate call (round-robin cursor over the rest).
    static let maxFacesPerIntegrate = 60_000
    /// Frustum margin as a fraction of image width (16 px at 1920 px), so faces straddling the
    /// image border still count.
    static let frustumMarginFraction: Float = 1.0 / 120.0
    /// Minimum camera-space depth in meters before dividing for projection.
    static let minProjectionDepth: Float = 0.05
    /// Faces whose equal-area disk radius exceeds this also mark neighboring voxels in their plane.
    static let largeFaceRadius: Float = 0.075
    /// Maximum extra points marked for one large face.
    static let maxLargeFacePoints = 25

    // MARK: Storage

    /// Voxel edge in meters.
    let voxelSize: Float
    /// Sparse per-voxel stats.
    private var voxels: [SIMD3<Int32>: CoverageStats] = [:]
    /// Voxels marked as expected surface (for red).
    private var expected: Set<SIMD3<Int32>> = []
    /// Per-face stats, indexed like the caller's face array.
    private var faces: [CoverageStats] = []
    /// Round-robin start index for the next integrate call.
    private var cursor: Int = 0

    /// Creates an empty grid. Non-positive or non-finite sizes fall back to the default.
    init(voxelSize: Float = CoverageGrid.defaultVoxelSize) {
        self.voxelSize = (voxelSize.isFinite && voxelSize > 0) ? voxelSize : CoverageGrid.defaultVoxelSize
    }

    // MARK: Quality

    /// Quality of one observation of a surface point, 0...1 = distance term * incidence term *
    /// confidence term.
    /// - distance: 0 below 0.2 m, ramps to 1 at 0.5 m, 1 on 0.5...2.5 m, falls linearly to 0 at 5.0 m.
    /// - incidence: clamp((viewCosine - 0.17) / (0.7 - 0.17), 0, 1): 0 beyond about 80 degrees,
    ///   1 within about 45 degrees.
    /// - confidence: nil -> 0.8, else 0.4 + 0.6 * clamp(conf, 0, 1).
    static func observationQuality(distance: Float, viewCosine: Float, depthConfidence: Float?) -> Float {
        guard distance.isFinite, viewCosine.isFinite else { return 0 }
        let distanceTerm: Float
        if distance < minRange {
            distanceTerm = 0
        } else if distance < 0.5 {
            distanceTerm = (distance - minRange) / (0.5 - minRange)
        } else if distance <= 2.5 {
            distanceTerm = 1
        } else if distance < maxRange {
            distanceTerm = (maxRange - distance) / (maxRange - 2.5)
        } else {
            distanceTerm = 0
        }
        let incidenceTerm = min(max((viewCosine - 0.17) / (0.7 - 0.17), 0), 1)
        let confidenceTerm: Float
        if let c = depthConfidence, c.isFinite {
            confidenceTerm = 0.4 + 0.6 * min(max(c, 0), 1)
        } else {
            confidenceTerm = 0.8
        }
        return min(max(distanceTerm * incidenceTerm * confidenceTerm, 0), 1)
    }

    // MARK: Integration

    /// Integrates one observation. Ignores it when !trackingNormal. Tests faces against the
    /// frustum built from intrinsics + imageResolution (with a 1/120-of-width margin), range
    /// (0.2...maxRange) and facing (viewCosine > 0). The faces array may grow between calls
    /// (mesh updates): per-face stats are kept by index and extended. Also updates the voxel
    /// containing each updated face centroid (once per voxel per call, best face wins).
    @discardableResult
    mutating func integrate(observation: CoverageObservation, faces input: [CoverageFace]) -> CoverageIntegrateResult {
        let n = input.count
        guard observation.trackingNormal, n > 0 else {
            return CoverageIntegrateResult(facesTested: 0, facesUpdated: 0, truncated: false)
        }
        if faces.count < n {
            faces.append(contentsOf: repeatElement(CoverageStats.empty, count: n - faces.count))
        }

        // Camera pose: world -> camera is R^T (p - t) for a rigid camera-to-world transform.
        let m = observation.cameraToWorld
        let axisX = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let axisY = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let axisZ = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        let k = observation.intrinsics
        let fx = k.columns.0.x
        let fy = k.columns.1.y
        let cx = k.columns.2.x
        let cy = k.columns.2.y
        let width = observation.imageResolution.x
        let height = observation.imageResolution.y
        guard fx > 0, fy > 0, width > 0, height > 0 else {
            return CoverageIntegrateResult(facesTested: 0, facesUpdated: 0, truncated: false)
        }
        let margin = width * CoverageGrid.frustumMarginFraction
        let uMin = -margin, uMax = width + margin
        let vMin = -margin, vMax = height + margin
        let minRange2 = CoverageGrid.minRange * CoverageGrid.minRange
        let maxRange2 = CoverageGrid.maxRange * CoverageGrid.maxRange
        let minDepth = CoverageGrid.minProjectionDepth
        let confidence = observation.depthConfidenceMean
        let cap = CoverageGrid.maxFacesPerIntegrate

        var hits: [SIMD3<Int32>: CGVoxelHit] = [:]
        var tested = 0
        var updated = 0
        var truncated = false
        var index = cursor < n ? cursor : 0

        while tested < n {
            let i = index
            index += 1
            if index == n { index = 0 }
            tested += 1

            let face = input[i]
            let d = face.centroid - origin
            let dist2 = simd_dot(d, d)
            if dist2 < minRange2 || dist2 > maxRange2 { continue }
            let depth = -simd_dot(axisZ, d)
            if depth <= minDepth { continue }
            let inv = 1 / depth
            let u = fx * simd_dot(axisX, d) * inv + cx
            if u < uMin || u > uMax { continue }
            let v = fy * -simd_dot(axisY, d) * inv + cy
            if v < vMin || v > vMax { continue }
            let dist = dist2.squareRoot()
            let viewCosine = -simd_dot(face.normal, d) / dist
            if !(viewCosine > 0) { continue }

            let q = CoverageGrid.observationQuality(distance: dist, viewCosine: viewCosine,
                                                    depthConfidence: confidence)
            faces[i].add(quality: q, viewCosine: viewCosine, distance: dist)
            updated += 1

            let hit = CGVoxelHit(quality: q, viewCosine: viewCosine, distance: dist)
            recordHit(hit, at: key(for: face.centroid), in: &hits)
            if face.area.isFinite && face.area > 0 {
                let radius = (face.area / Float.pi).squareRoot()
                if radius > CoverageGrid.largeFaceRadius {
                    recordLargeFace(face, radius: radius, hit: hit, in: &hits)
                }
            }

            if updated >= cap {
                truncated = tested < n
                break
            }
        }
        cursor = index

        for (voxelKey, hit) in hits {
            var s = voxels[voxelKey] ?? CoverageStats.empty
            s.add(quality: hit.quality, viewCosine: hit.viewCosine, distance: hit.distance)
            voxels[voxelKey] = s
        }
        return CoverageIntegrateResult(facesTested: tested, facesUpdated: updated, truncated: truncated)
    }

    /// Keeps the best-quality hit per voxel within one call.
    private func recordHit(_ hit: CGVoxelHit, at voxelKey: SIMD3<Int32>, in hits: inout [SIMD3<Int32>: CGVoxelHit]) {
        if let old = hits[voxelKey] {
            var merged = old
            if hit.quality > old.quality {
                merged.quality = hit.quality
                merged.distance = hit.distance
            }
            if hit.viewCosine > old.viewCosine { merged.viewCosine = hit.viewCosine }
            hits[voxelKey] = merged
        } else {
            hits[voxelKey] = hit
        }
    }

    /// Marks voxels on a voxel-spaced grid inside the face's equal-area disk (in its plane),
    /// at most `maxLargeFacePoints` points, so large triangles do not leave false holes.
    private func recordLargeFace(_ face: CoverageFace, radius: Float, hit: CGVoxelHit,
                                 in hits: inout [SIMD3<Int32>: CGVoxelHit]) {
        let len = simd_length(face.normal)
        guard len > 1e-6, len.isFinite else { return }
        let normal = face.normal / len
        let helper = abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t1 = simd_normalize(simd_cross(normal, helper))
        let t2 = simd_cross(normal, t1)
        let steps = min(Int(radius / voxelSize), 3)
        guard steps >= 1 else { return }
        let r2 = radius * radius
        var marked = 0
        for j in -steps...steps {
            for i in -steps...steps {
                if i == 0 && j == 0 { continue }
                let a = Float(i) * voxelSize
                let b = Float(j) * voxelSize
                if a * a + b * b > r2 { continue }
                let p = face.centroid + t1 * a + t2 * b
                recordHit(hit, at: key(for: p), in: &hits)
                marked += 1
                if marked >= CoverageGrid.maxLargeFacePoints { return }
            }
        }
    }

    // MARK: Keys and lookups

    /// Voxel key containing `point`: floor(point / voxelSize), clamped to the Int32 range.
    func key(for point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(cgVoxelIndex(point.x, voxelSize), cgVoxelIndex(point.y, voxelSize),
                     cgVoxelIndex(point.z, voxelSize))
    }

    /// World-space center of a voxel.
    func center(of key: SIMD3<Int32>) -> SIMD3<Float> {
        SIMD3<Float>((Float(key.x) + 0.5) * voxelSize, (Float(key.y) + 0.5) * voxelSize,
                     (Float(key.z) + 0.5) * voxelSize)
    }

    /// Stats of one voxel, nil if it was never touched.
    func voxelStats(_ key: SIMD3<Int32>) -> CoverageStats? {
        voxels[key]
    }

    /// Stats of one face, nil if the index has no slot yet or the face was never inside a view.
    func faceStats(_ index: Int) -> CoverageStats? {
        guard index >= 0, index < faces.count else { return nil }
        let s = faces[index]
        return s == CoverageStats.empty ? nil : s
    }

    /// State of one face; gray if unknown.
    func state(ofFace index: Int) -> CoverageState {
        guard index >= 0, index < faces.count else { return .gray }
        return CoverageGrid.state(for: faces[index])
    }

    /// State of one voxel; red if marked expected and still unobserved.
    func state(atVoxel key: SIMD3<Int32>) -> CoverageState {
        let s = voxels[key].map { CoverageGrid.state(for: $0) } ?? .gray
        if s == .gray && expected.contains(key) { return .red }
        return s
    }

    /// Green: good >= 3 or best >= excellent; yellow: good 1 to 2 or at least one observation;
    /// else gray. Never returns red (red needs the expected-surface marks).
    static func state(for stats: CoverageStats) -> CoverageState {
        if Int(stats.goodObservationCount) >= greenGoodCount || stats.bestQuality >= excellentQuality {
            return .green
        }
        if stats.goodObservationCount >= 1 || stats.observationCount >= 1 { return .yellow }
        return .gray
    }

    /// True if any voxel whose center is within `radius` of `point` has observationCount > 0.
    /// Scans keys from floor((p - r) / vs) to floor((p + r) / vs) on each axis (up to 64 lookups
    /// at radius 0.15 m and 0.1 m voxels), falling back to a full scan for very large radii.
    func isObserved(near point: SIMD3<Float>, radius: Float) -> Bool {
        guard radius.isFinite, radius >= 0 else { return false }
        let r2 = radius * radius
        let lo = key(for: point - SIMD3<Float>(repeating: radius))
        let hi = key(for: point + SIMD3<Float>(repeating: radius))
        let nx = Int(hi.x) - Int(lo.x) + 1
        let ny = Int(hi.y) - Int(lo.y) + 1
        let nz = Int(hi.z) - Int(lo.z) + 1
        let wide = nx > 1024 || ny > 1024 || nz > 1024
        if wide || nx * ny * nz > max(voxels.count, 512) {
            for (k, s) in voxels where s.observationCount > 0 {
                if simd_length_squared(center(of: k) - point) <= r2 { return true }
            }
            return false
        }
        for z in Int(lo.z)...Int(hi.z) {
            for y in Int(lo.y)...Int(hi.y) {
                for x in Int(lo.x)...Int(hi.x) {
                    let k = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    if let s = voxels[k], s.observationCount > 0,
                       simd_length_squared(center(of: k) - point) <= r2 { return true }
                }
            }
        }
        return false
    }

    // MARK: Expected surface

    /// Marks voxels containing these points as expected surface (used for red state).
    mutating func markExpected(_ points: [SIMD3<Float>]) {
        for p in points { expected.insert(key(for: p)) }
    }

    /// Removes all expected-surface marks.
    mutating func clearExpected() {
        expected.removeAll()
    }

    // MARK: Summaries

    /// Number of voxels holding stats.
    var voxelCount: Int { voxels.count }

    /// Number of per-face stat slots.
    var faceCount: Int { faces.count }

    /// Area-weighted fraction (0...1) of faces with at least one good observation. Pass the faces
    /// of the last integrate call (same indexing). 0 when the total area is 0.
    func goodFaceAreaFraction(faces input: [CoverageFace]) -> Float {
        var total: Float = 0
        var good: Float = 0
        for (i, f) in input.enumerated() where f.area.isFinite && f.area > 0 {
            total += f.area
            if i < faces.count && faces[i].goodObservationCount >= 1 { good += f.area }
        }
        return total > 0 ? min(good / total, 1) : 0
    }

    /// Area-weighted fraction of faces of a class (nil = all classes) whose state is yellow or
    /// green. 0 when the total area is 0.
    func observedAreaFraction(faces input: [CoverageFace], surface: SurfaceClass?) -> Float {
        var total: Float = 0
        var seen: Float = 0
        for (i, f) in input.enumerated() where f.area.isFinite && f.area > 0 {
            if let wanted = surface, f.surface != wanted { continue }
            total += f.area
            if i < faces.count {
                let s = CoverageGrid.state(for: faces[i])
                if s == .yellow || s == .green { seen += f.area }
            }
        }
        return total > 0 ? min(seen / total, 1) : 0
    }

    /// Voxel counts per state over every voxel with stats or an expected mark. All four states
    /// are present as keys.
    func stateCounts() -> [CoverageState: Int] {
        var counts: [CoverageState: Int] = [.gray: 0, .red: 0, .yellow: 0, .green: 0]
        for k in voxels.keys {
            counts[state(atVoxel: k), default: 0] += 1
        }
        for k in expected where voxels[k] == nil {
            counts[.red, default: 0] += 1
        }
        return counts
    }

    /// Clears all voxel, face and expected-surface evidence and the round-robin cursor.
    mutating func reset() {
        voxels.removeAll()
        expected.removeAll()
        faces.removeAll()
        cursor = 0
    }
}

/// floor(value / size) as Int32, clamped to the Int32 range; non-finite values map to 0.
private func cgVoxelIndex(_ value: Float, _ size: Float) -> Int32 {
    let f = (value / size).rounded(.down)
    guard f.isFinite else { return 0 }
    if f >= 2_147_483_520 { return Int32.max }
    if f <= -2_147_483_520 { return Int32.min }
    return Int32(f)
}
