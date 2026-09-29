import Foundation
import simd

// Side coverage around a large object (docs/MODULES.md 3.39, D4, ARCHITECTURE 4.5): 8 azimuth
// sectors of 45 degrees plus the top around the object's gravity-aligned box, filled from camera
// poses (seconds the camera looked at each region, and from how far) and from the live face
// states inside the box, and turned into at most one camera-relative object message for
// Coverage's GuidanceEngine (CR-9). Pure value type: no ARKit, no clock, any thread.

/// One live face for sector scoring.
struct SectorFace: Equatable {
    /// World centroid, meters.
    var centroid: SIMD3<Float>
    /// Face normal (either winding; `SectorCoverage.updateFaces` turns it outward).
    var normal: SIMD3<Float>
    /// Face area, square meters.
    var area: Float
    /// Live coverage state of the face (CoverageLive).
    var state: CoverageState
}

/// 8 azimuth sectors (45 degrees each) plus the top around the box (D4). Azimuth is measured around
/// +Y from the front direction (box center toward the camera when the seed was set), positive toward
/// the viewer's right as seen from the front: sector 0 front, 1 front-right, 2 right, 3 back-right,
/// 4 back, 5 back-left, 6 left, 7 front-left; region 8 is the top. Pure value type.
struct SectorCoverage: Equatable {
    /// Side sectors around the box.
    static let sideCount = 8
    /// Index of the top region.
    static let topRegion = 8
    /// Least seconds of viewing before a region can count as covered.
    static let minViewSeconds: Double = 1.5
    /// Half angle of the view cone toward the box center (sides) or the top face center (top), degrees.
    static let viewConeDegrees: Float = 35
    /// Camera distance to the box surface that counts as viewing, meters.
    static let viewDistance: ClosedRange<Float> = 0.3...3.5
    /// Least elevation of the camera above the top face center for the top region, degrees.
    static let topElevationDegrees: Float = 25
    /// Highest box top above the floor that a person can look down on, meters.
    static let maxReachableTop: Float = 1.9
    /// Least face area in a region before its score counts, square meters.
    static let minFaceArea: Float = 0.05
    /// Least face score of a covered region.
    static let coveredScore: Float = 0.6
    /// Mean view distance above which an uncovered region asks the user to move closer, meters.
    static let closerDistance: Float = 1.6
    /// Seconds after the start during which "Move around the object slowly" leads while nothing is covered.
    static let startupSeconds: Double = 4

    // Additions (tunables used by the rules above).

    /// Regions in total (8 sides plus the top).
    static let regionCount = 9
    /// Growth of the box on every side before faces count toward the scores, meters.
    static let faceBoxGrowth: Float = 0.05
    /// Upward faces within this distance below the box top count toward the top, meters.
    static let topBand: Float = 0.15
    /// Least vertical normal component of an upward (top) or downward (ignored) face.
    static let verticalNormal: Float = 0.7
    /// Score weight of a yellow face (green counts 1, red and gray 0).
    static let yellowWeight: Float = 0.5
    /// Two azimuth differences closer than this are a tie (the right side wins), degrees.
    static let tieDegrees: Float = 1e-3

    /// The current box (gravity aligned: axis 1 is up).
    private(set) var box: OrientedBox
    /// Floor height under the object, meters.
    private(set) var floorY: Float
    /// Unit horizontal (x, z) front direction.
    let front: SIMD2<Float>
    /// Seconds the camera viewed each region (9 regions).
    private(set) var viewSeconds: [Double]
    /// Mean camera distance to the box surface while viewing each region (9 regions; nil before any view).
    private(set) var meanViewDistance: [Float?]
    /// Face score of each region (9 regions; nil under `minFaceArea`).
    private(set) var faceScores: [Float?]
    /// Seconds of poses observed since the start (tracking limited included).
    private(set) var elapsed: Double
    /// Per region, the sum of distance times seconds (numerator of the running mean).
    private var distanceSeconds: [Double]
    /// Highest point of the box, meters (cached from the corners).
    private var topY: Float

    /// Starts with nothing viewed; `firstCamera` sets the front direction.
    init(box: OrientedBox, floorY: Float, firstCamera: SIMD3<Float>) {
        self.box = box
        self.floorY = floorY
        front = SectorCoverage.frontDirection(box: box, camera: firstCamera)
        viewSeconds = Array(repeating: 0, count: SectorCoverage.regionCount)
        meanViewDistance = Array(repeating: nil, count: SectorCoverage.regionCount)
        faceScores = Array(repeating: nil, count: SectorCoverage.regionCount)
        distanceSeconds = Array(repeating: 0, count: SectorCoverage.regionCount)
        elapsed = 0
        topY = SectorCoverage.highestPoint(of: box)
    }

    /// A new box from the latest growth (the front direction and the viewing history stay).
    mutating func updateBox(_ box: OrientedBox, floorY: Float) {
        self.box = box
        if floorY.isFinite { self.floorY = floorY }
        topY = SectorCoverage.highestPoint(of: box)
    }

    // MARK: - Camera poses

    /// Adds `seconds` to the region the camera sees: a side sector when the camera looks at the box
    /// center within `viewConeDegrees` from `viewDistance` of its surface; the top when the camera is at
    /// least `topElevationDegrees` above the top face center and looks down at it. Nothing unless tracking is normal.
    mutating func observe(cameraToWorld: simd_float4x4, seconds: Double, trackingNormal: Bool) {
        guard seconds.isFinite, seconds > 0 else { return }
        elapsed += seconds
        guard trackingNormal, let seen = viewedRegion(cameraToWorld) else { return }
        let index = seen.region
        viewSeconds[index] += seconds
        distanceSeconds[index] += Double(seen.distance) * seconds
        meanViewDistance[index] = Float(distanceSeconds[index] / viewSeconds[index])
    }

    /// The region a camera pose views and the camera's distance to the box surface, or nil. The top
    /// wins when both apply (one region per pose).
    func viewedRegion(_ cameraToWorld: simd_float4x4) -> (region: Int, distance: Float)? {
        let m = cameraToWorld
        let position = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let back = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let backLength = simd_length(back)
        guard SectorCoverage.isFinite(position), backLength.isFinite, backLength > 1e-6 else { return nil }
        let forward = -back / backLength
        let distance = surfaceDistance(position)
        guard distance.isFinite, SectorCoverage.viewDistance.contains(distance) else { return nil }
        let topCenter = SIMD3<Float>(box.center.x, topY, box.center.z)
        let toTop = topCenter - position
        let horizontal = simd_length(SIMD2<Float>(toTop.x, toTop.z))
        let above = position.y - topY
        let elevation = atan2(above, horizontal) * 180 / Float.pi
        if elevation >= SectorCoverage.topElevationDegrees,
           SectorCoverage.angleDegrees(forward, toTop) <= SectorCoverage.viewConeDegrees {
            return (region: SectorCoverage.topRegion, distance: distance)
        }
        let toCenter = box.center - position
        guard SectorCoverage.angleDegrees(forward, toCenter) <= SectorCoverage.viewConeDegrees else { return nil }
        return (region: SectorCoverage.sector(azimuthDegrees: azimuthDegrees(of: position)), distance: distance)
    }

    // MARK: - Face scores

    /// Face scores: faces inside the box grown by 0.05 m, normals turned outward from the box center;
    /// top = normal.y > 0.7 within 0.15 m of the top; bottom-facing faces ignored; side sector from the
    /// normal's horizontal azimuth. Score = (green area + 0.5 x yellow area) / area.
    mutating func updateFaces(_ faces: [SectorFace]) {
        var total = [Float](repeating: 0, count: SectorCoverage.regionCount)
        var weighted = [Float](repeating: 0, count: SectorCoverage.regionCount)
        let grown = OrientedBox(center: box.center, axes: box.axes,
                                halfExtents: box.halfExtents + SIMD3<Float>(repeating: SectorCoverage.faceBoxGrowth))
        for face in faces {
            guard face.area.isFinite, face.area > 0, SectorCoverage.isFinite(face.centroid),
                  grown.contains(face.centroid), let slot = self.region(of: face) else { continue }
            total[slot] += face.area
            weighted[slot] += face.area * SectorCoverage.weight(face.state)
        }
        for index in 0..<SectorCoverage.regionCount {
            faceScores[index] = total[index] >= SectorCoverage.minFaceArea ? weighted[index] / total[index] : nil
        }
    }

    /// The region a face scores for, or nil (bottom-facing, upward below the top band, or no
    /// horizontal direction).
    func region(of face: SectorFace) -> Int? {
        let length = simd_length(face.normal)
        guard length.isFinite, length > 1e-6 else { return nil }
        var normal = face.normal / length
        if simd_dot(normal, face.centroid - box.center) < 0 { normal = -normal }
        if normal.y > SectorCoverage.verticalNormal {
            return topY - face.centroid.y <= SectorCoverage.topBand ? SectorCoverage.topRegion : nil
        }
        if normal.y < -SectorCoverage.verticalNormal { return nil }
        let horizontal = SIMD2<Float>(normal.x, normal.z)
        guard simd_length(horizontal) > 1e-3 else { return nil }
        return SectorCoverage.sector(azimuthDegrees: directionAzimuth(horizontal))
    }

    // MARK: - Azimuth

    /// Degrees in (-180, 180], 0 front, +90 right.
    func azimuthDegrees(of point: SIMD3<Float>) -> Float {
        directionAzimuth(SIMD2<Float>(point.x - box.center.x, point.z - box.center.z))
    }

    /// Azimuth of a horizontal (x, z) direction, degrees in (-180, 180]; 0 for a zero or non-finite direction.
    func directionAzimuth(_ direction: SIMD2<Float>) -> Float {
        let right = SIMD2<Float>(front.y, -front.x)
        let ahead = simd_dot(direction, front)
        let side = simd_dot(direction, right)
        guard ahead.isFinite, side.isFinite else { return 0 }
        var degrees = atan2(side, ahead) * 180 / Float.pi
        if degrees <= -180 { degrees += 360 }
        return degrees
    }

    /// Sector of an azimuth: sector i spans [45 i - 22.5, 45 i + 22.5) degrees.
    static func sector(azimuthDegrees: Float) -> Int {
        guard azimuthDegrees.isFinite else { return 0 }
        var degrees = azimuthDegrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        let index = Int(((degrees + 22.5) / 45).rounded(.down))
        return ((index % sideCount) + sideCount) % sideCount
    }

    // MARK: - Coverage

    /// False when the box top is more than `maxReachableTop` above the floor (a person cannot see it).
    var topRequired: Bool { topY - floorY <= SectorCoverage.maxReachableTop }

    /// viewSeconds >= minViewSeconds and (no score or score >= coveredScore).
    func isCovered(_ region: Int) -> Bool {
        guard region >= 0, region < SectorCoverage.regionCount else { return false }
        guard viewSeconds[region] >= SectorCoverage.minViewSeconds else { return false }
        if let score = faceScores[region] { return score >= SectorCoverage.coveredScore }
        return true
    }

    /// Covered sides plus the top when it is required and covered.
    var coveredCount: Int {
        var count = 0
        for side in 0..<SectorCoverage.sideCount where isCovered(side) { count += 1 }
        if topRequired && isCovered(SectorCoverage.topRegion) { count += 1 }
        return count
    }

    /// 8 or 9.
    var requiredCount: Int { SectorCoverage.sideCount + (topRequired ? 1 : 0) }

    // MARK: - Guidance

    /// The one object message for now (camera-relative):
    /// startup with nothing covered -> .objectMoveAround; all required covered -> .objectLooksComplete;
    /// the camera's own sector uncovered: mean view distance > closerDistance -> .objectMoveCloserToArea,
    /// else a score below coveredScore after minViewSeconds -> .objectNeedsDetail, else nil (keep going);
    /// otherwise the uncovered side with the smallest |delta| from the camera's azimuth (ties to the right):
    /// |delta| > 135 -> .objectCaptureBack, delta > 0 -> .objectCaptureRight, delta < 0 -> .objectCaptureLeft;
    /// only the top left -> .objectCaptureTop.
    func guidance(cameraToWorld: simd_float4x4) -> GuidanceKind? {
        let covered = coveredCount
        if elapsed < SectorCoverage.startupSeconds && covered == 0 { return .objectMoveAround }
        if covered >= requiredCount { return .objectLooksComplete }
        let m = cameraToWorld
        let position = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        guard SectorCoverage.isFinite(position) else { return nil }
        let azimuth = azimuthDegrees(of: position)
        let own = SectorCoverage.sector(azimuthDegrees: azimuth)
        if !isCovered(own) {
            if let distance = meanViewDistance[own], distance > SectorCoverage.closerDistance {
                return .objectMoveCloserToArea
            }
            if viewSeconds[own] >= SectorCoverage.minViewSeconds, let score = faceScores[own],
               score < SectorCoverage.coveredScore {
                return .objectNeedsDetail
            }
            return nil
        }
        if let delta = nearestUncoveredDelta(from: azimuth) {
            if abs(delta) > 135 { return .objectCaptureBack }
            return delta > 0 ? .objectCaptureRight : .objectCaptureLeft
        }
        if topRequired && !isCovered(SectorCoverage.topRegion) { return .objectCaptureTop }
        return .objectLooksComplete
    }

    /// Signed degrees from `azimuth` to the center of the nearest uncovered side (ties to the
    /// positive, right-hand one), or nil when every side is covered.
    func nearestUncoveredDelta(from azimuth: Float) -> Float? {
        var best: Float?
        for side in 0..<SectorCoverage.sideCount where !isCovered(side) {
            let delta = SectorCoverage.signedDegrees(Float(side) * 45 - azimuth)
            guard let current = best else {
                best = delta
                continue
            }
            let gap = abs(delta) - abs(current)
            if gap < -SectorCoverage.tieDegrees || (abs(gap) <= SectorCoverage.tieDegrees && delta > current) {
                best = delta
            }
        }
        return best
    }

    // MARK: - Helpers

    /// Signed distance from `point` to the box surface (negative inside), meters.
    func surfaceDistance(_ point: SIMD3<Float>) -> Float {
        let local = simd_mul(simd_transpose(box.axes), point - box.center)
        let q = simd_abs(local) - box.halfExtents
        let outside = simd_length(simd_max(q, SIMD3<Float>(repeating: 0)))
        let inside = min(max(q.x, max(q.y, q.z)), 0)
        return outside + inside
    }

    /// Horizontal unit vector from the box center toward the camera; the box's third axis, then +Z,
    /// when the camera is straight above the center.
    static func frontDirection(box: OrientedBox, camera: SIMD3<Float>) -> SIMD2<Float> {
        let toward = SIMD2<Float>(camera.x - box.center.x, camera.z - box.center.z)
        let length = simd_length(toward)
        if length.isFinite, length > 1e-4 { return toward / length }
        let axis = SIMD2<Float>(box.axes.columns.2.x, box.axes.columns.2.z)
        let axisLength = simd_length(axis)
        if axisLength.isFinite, axisLength > 1e-4 { return axis / axisLength }
        return SIMD2<Float>(0, 1)
    }

    /// Highest y of the box corners.
    static func highestPoint(of box: OrientedBox) -> Float {
        box.corners.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.y) }
    }

    /// Angle between two vectors, degrees; 180 when either is zero or not finite.
    static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let lengths = simd_length(a) * simd_length(b)
        guard lengths.isFinite, lengths > 1e-9 else { return 180 }
        let cosine = min(max(simd_dot(a, b) / lengths, -1), 1)
        return acos(cosine) * 180 / Float.pi
    }

    /// Degrees wrapped into (-180, 180].
    static func signedDegrees(_ degrees: Float) -> Float {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// Score weight of a face state: green 1, yellow 0.5, red and gray 0.
    static func weight(_ state: CoverageState) -> Float {
        switch state {
        case .green: return 1
        case .yellow: return yellowWeight
        case .red, .gray: return 0
        }
    }

    /// True when every component is finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}
