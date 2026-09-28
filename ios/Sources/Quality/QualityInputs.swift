import Foundation
import simd

// Conversions from Mapper's recorded data to Coverage's plain inputs (docs/ARCHITECTURE.md 5.8):
// the clean room outline back to Coverage's world (x, z) boundary, mesh triangles to
// `CoverageFace`s (normals from the cross product, RESEARCH 3.8 gotcha 6), the 10 Hz pose track
// decimated to geometry observations, and keyframe records filtered by the light test to
// texture observations. Pure and nonisolated.

/// Builds Coverage inputs from a clean room, a mesh, the pose track and the keyframe records.
enum QualityInputs {
    /// Camera used for pose samples when a scan has no keyframe at all: a 1920 x 1440 ARKit frame
    /// with a typical iPhone wide-camera focal length (the frame format keyframes also use).
    static let defaultIntrinsics = Intrinsics(fx: 1440, fy: 1440, cx: 960, cy: 720, width: 1920, height: 1440)
    /// Timestamps this close to the next due time still count as due (ARKit timestamps jitter).
    static let decimationTolerance: Double = 0.02
    /// Ceiling height used when neither the clean room nor its walls give one, meters.
    static let fallbackCeilingHeight: Float = 2.4
    /// Most camera positions used to orient face normals (evenly picked from the track).
    static let maxOrientationViewpoints = 64
    /// Triangles smaller than this are skipped (no usable normal), square meters.
    static let minFaceArea: Float = 1e-8

    // MARK: - Boundary

    /// Plan outline (x, -z) back to Coverage's world (x, z); walls with base and height.
    static func boundary(for room: CleanRoom) -> CoverageRoomBoundary {
        boundaryWithWalls(for: room).boundary
    }

    /// `boundary(for:)` plus the clean wall index of every Coverage wall. A curved wall is split
    /// at RoomModel's arc samples (`RoomOutline.arcPoints`) into straight Coverage walls. The
    /// floor polygon is the clean outline converted with `PlanAxes` (plan y = -world z); the
    /// ceiling reuses it at floor elevation plus the ceiling height (else the tallest wall, else
    /// `fallbackCeilingHeight`).
    static func boundaryWithWalls(for room: CleanRoom) -> QualityBoundary {
        var walls: [CoverageWall] = []
        var wallIndex: [Int] = []
        for (index, wall) in room.walls.enumerated() {
            guard wall.height.isFinite, wall.height > 0, wall.start.y.isFinite else { continue }
            let a = PlanAxes.toPlan(wall.start.simd)
            let b = PlanAxes.toPlan(wall.end.simd)
            var points: [SIMD2<Float>] = [a, b]
            if let arc = wall.arc {
                points = RoomOutline.arcPoints(from: a, to: b, arc: arc)
            }
            guard points.count >= 2 else { continue }
            for i in 1..<points.count {
                let s = coverageXZ(plan: points[i - 1])
                let e = coverageXZ(plan: points[i])
                guard s.x.isFinite, s.y.isFinite, e.x.isFinite, e.y.isFinite, simd_distance(s, e) > 1e-4 else { continue }
                walls.append(CoverageWall(start: s, end: e, baseY: wall.start.y, height: wall.height))
                wallIndex.append(index)
            }
        }
        let polygon = room.floor.outline.map { coverageXZ(plan: $0.simd) }.filter { $0.x.isFinite && $0.y.isFinite }
        let floorY = room.floor.elevation.isFinite ? room.floor.elevation : 0
        let boundary = CoverageRoomBoundary(walls: walls, floorPolygon: polygon, floorY: floorY,
                                            ceilingPolygon: [], ceilingY: floorY + ceilingHeight(for: room))
        return QualityBoundary(boundary: boundary, wallIndex: wallIndex, floorY: floorY)
    }

    /// Coverage (x, z) of a plan point: plan (x, y) is world (x, -y).
    static func coverageXZ(plan p: SIMD2<Float>) -> SIMD2<Float> {
        let world = PlanAxes.toWorld(p, y: 0)
        return SIMD2<Float>(world.x, world.z)
    }

    /// The clean ceiling height when it is usable (over 0.1 m), else the tallest wall, else
    /// `fallbackCeilingHeight`.
    static func ceilingHeight(for room: CleanRoom) -> Float {
        let height = room.ceiling.height
        if height.isFinite, height > 0.1 { return height }
        let tallest = room.walls.map { $0.height }.filter { $0.isFinite }.max() ?? 0
        return tallest > 0.1 ? tallest : fallbackCeilingHeight
    }

    // MARK: - Faces

    /// One `CoverageFace` per usable mesh triangle: world centroid, unit normal from the cross
    /// product of the corners (the per-vertex normals are not used), area and
    /// `SurfaceClass(rawValue:)` of the face class (`.none` when absent or unknown). Triangles
    /// with an out-of-range index, a non-finite corner or no area are skipped.
    static func faces(_ mesh: MeshWithAttributes) -> [CoverageFace] {
        oriented(mesh, toward: [], limit: Int.max).faces
    }

    /// `faces(_:)` with at most `limit` faces (every n-th triangle when the mesh is larger) and
    /// every normal turned toward the nearest of `viewpoints` (LiDAR triangles have no reliable
    /// winding, RESEARCH 3.5; a surface was seen from the side a camera stood on). Returns the
    /// faces, how many normals were flipped and the stride used.
    static func oriented(_ mesh: MeshWithAttributes, toward viewpoints: [SIMD3<Float>],
                         limit: Int) -> (faces: [CoverageFace], flipped: Int, stride: Int) {
        let positions = mesh.mesh.positions
        let indices = mesh.mesh.indices
        let count = mesh.triangleCount
        let cap = Swift.max(1, limit)
        let stride = count > cap ? (count + cap - 1) / cap : 1
        let classes = mesh.faceClass.flatMap { $0.count == count ? $0 : nil }
        let vertexCount = positions.count
        var out: [CoverageFace] = []
        out.reserveCapacity(Swift.min(count / stride + 1, cap))
        var flipped = 0
        var t = 0
        while t < count {
            defer { t += stride }
            let i0 = Int(indices[3 * t]), i1 = Int(indices[3 * t + 1]), i2 = Int(indices[3 * t + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            let a = positions[i0], b = positions[i1], c = positions[i2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let area = length * 0.5
            guard area.isFinite, area > minFaceArea else { continue }
            let centroid = (a + b + c) / 3
            guard centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite else { continue }
            var normal = cross / length
            if let viewpoint = nearest(viewpoints, to: centroid), simd_dot(normal, viewpoint - centroid) < 0 {
                normal = -normal
                flipped += 1
            }
            let surface = classes.flatMap { SurfaceClass(rawValue: $0[t]) } ?? SurfaceClass.none
            out.append(CoverageFace(centroid: centroid, normal: normal, area: area, surface: surface))
        }
        return (out, flipped, stride)
    }

    /// The expected room shell as faces, one per Coverage sample (position, inward normal,
    /// area, class). Used when a room has no recorded mesh (`meshStripped`), so coverage still
    /// says which parts of the room the camera looked at.
    static func faces(fromSamples samples: [ExpectedSample]) -> [CoverageFace] {
        samples.map { CoverageFace(centroid: $0.position, normal: $0.normal, area: $0.area, surface: $0.surface) }
    }

    /// At most `maxOrientationViewpoints` camera positions picked evenly from the observations.
    static func viewpoints(_ observations: [CoverageObservation]) -> [SIMD3<Float>] {
        let valid = observations.filter { QualityMath.isFinite($0.cameraToWorld) }
        guard !valid.isEmpty else { return [] }
        let step = Swift.max(1, (valid.count + maxOrientationViewpoints - 1) / maxOrientationViewpoints)
        var out: [SIMD3<Float>] = []
        var i = 0
        while i < valid.count {
            out.append(QualityMath.position(valid[i].cameraToWorld))
            i += step
        }
        return out
    }

    /// The point of `points` nearest to `p`, nil when empty.
    private static func nearest(_ points: [SIMD3<Float>], to p: SIMD3<Float>) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        var bestDistance = Float.greatestFiniteMagnitude
        for q in points {
            let d = simd_length_squared(q - p)
            if d < bestDistance {
                bestDistance = d
                best = q
            }
        }
        return best
    }

    // MARK: - Observations

    /// Pose samples decimated to `hz`, trackingNormal = code 2; intrinsics from the nearest
    /// keyframe record (fallback: the first keyframe).
    /// Samples with a non-finite timestamp or transform are skipped; keyframes with unusable
    /// intrinsics are ignored; with no usable keyframe `defaultIntrinsics` is used. Depth
    /// confidence is unknown (nil).
    static func observations(poses: [PoseSample], keyframes: [KeyframeRecord], hz: Double = 2) -> [CoverageObservation] {
        let cameras = keyframes.filter { usable($0.intrinsics) && $0.timestamp.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        let fallback = keyframes.first(where: { usable($0.intrinsics) })?.intrinsics ?? defaultIntrinsics
        return decimated(poses, hz: hz).map { (sample: PoseSample) -> CoverageObservation in
            let k = nearestIntrinsics(cameras, at: sample.timestamp) ?? fallback
            return CoverageObservation(cameraToWorld: sample.transform, intrinsics: k.matrix,
                                       imageResolution: SIMD2<Float>(Float(k.width), Float(k.height)),
                                       trackingNormal: sample.tracking == 2, depthConfidenceMean: nil,
                                       timestamp: sample.timestamp)
        }
    }

    /// Texture observations: a keyframe counts only when tracking was normal, `ambientIntensity`
    /// >= `QualityEvaluator.darkAmbientIntensity` and `exposureDuration` <=
    /// `QualityEvaluator.longExposureSeconds` (dark or blurred frames do not color a surface well).
    static func observations(keyframes: [KeyframeRecord]) -> [CoverageObservation] {
        keyframes.compactMap { (record: KeyframeRecord) -> CoverageObservation? in
            let transform = record.transform.simd
            guard record.trackingNormal, passesLightTest(record), usable(record.intrinsics),
                  QualityMath.isFinite(transform) else { return nil }
            let k = record.intrinsics
            return CoverageObservation(cameraToWorld: transform, intrinsics: k.matrix,
                                       imageResolution: SIMD2<Float>(Float(k.width), Float(k.height)),
                                       trackingNormal: true, depthConfidenceMean: nil, timestamp: record.timestamp)
        }
    }

    /// Fraction of keyframes failing the light test above.
    static func darkFraction(_ keyframes: [KeyframeRecord]) -> Float {
        guard !keyframes.isEmpty else { return 0 }
        let dark = keyframes.filter { !passesLightTest($0) }.count
        return Float(dark) / Float(keyframes.count)
    }

    /// True when a keyframe was taken in usable light: ambient intensity at least
    /// `darkAmbientIntensity` and exposure at most `longExposureSeconds` (NaN fails).
    static func passesLightTest(_ record: KeyframeRecord) -> Bool {
        record.ambientIntensity >= QualityEvaluator.darkAmbientIntensity
            && record.exposureDuration <= QualityEvaluator.longExposureSeconds
    }

    /// Samples in time order, keeping one per 1 / `hz` seconds: the first sample, then the first
    /// one at or after each due time (less `decimationTolerance`). A gap in the track restarts
    /// the schedule at the next sample. `hz` <= 0 or non-finite keeps every usable sample.
    static func decimated(_ poses: [PoseSample], hz: Double) -> [PoseSample] {
        let valid = poses.filter { $0.timestamp.isFinite && QualityMath.isFinite($0.transform) }
            .sorted { $0.timestamp < $1.timestamp }
        guard hz.isFinite, hz > 0 else { return valid }
        let interval = 1 / hz
        let tolerance = Swift.min(decimationTolerance, interval * 0.1)
        var kept: [PoseSample] = []
        kept.reserveCapacity(valid.count / 2 + 1)
        var due = -Double.infinity
        for sample in valid where sample.timestamp >= due - tolerance {
            kept.append(sample)
            due = due.isFinite ? due + interval : sample.timestamp + interval
            if due <= sample.timestamp { due = sample.timestamp + interval }
        }
        return kept
    }

    /// True when the intrinsics can project (positive focal lengths and image size).
    static func usable(_ k: Intrinsics) -> Bool {
        k.fx.isFinite && k.fy.isFinite && k.cx.isFinite && k.cy.isFinite && k.fx > 0 && k.fy > 0 && k.width > 0 && k.height > 0
    }

    /// Intrinsics of the keyframe nearest in time (binary search over time-sorted records).
    private static func nearestIntrinsics(_ sorted: [KeyframeRecord], at time: Double) -> Intrinsics? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].timestamp < time { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return sorted[0].intrinsics }
        if lo == sorted.count { return sorted[sorted.count - 1].intrinsics }
        let before = sorted[lo - 1]
        let after = sorted[lo]
        return (time - before.timestamp) <= (after.timestamp - time) ? before.intrinsics : after.intrinsics
    }
}
