import Foundation
import CoreGraphics
import simd

// Pure snapping, plane corner, evidence and guidance rules of Quick Measure (MODULES 3.36,
// ARCHITECTURE 4.6, RESEARCH 3.8 "Snapping order"): existing points first, then plane corners
// (ARPlaneAnchor extent corners and wall-wall-floor intersections), then the
// `.existingPlaneGeometry` raycast hit, then the `.estimatedPlane` hit, within the smaller of
// 10 cm in the world and 24 pt on screen. No ARKit, no clock: the self-test drives it directly.

/// Where a snapped point came from, in priority order.
enum LiveMeasureSnapSource: Int, Comparable, Sendable {
    /// A point the user already placed, a plane corner, the plane-geometry hit, the estimated plane.
    case existingPoint = 0, planeCorner, planeGeometry, estimatedPlane

    /// Priority order: a lower raw value wins.
    static func < (lhs: LiveMeasureSnapSource, rhs: LiveMeasureSnapSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Tags shown as "Snapped to {target}"; raw values index `Copy.Measure.snapTargets`.
enum LiveMeasureSnapTag: Int, CaseIterable, Sendable {
    /// Same order as `Copy.Measure.snapTargets`.
    case corner = 0, wall, edge, floor, ceiling, door, window, objectEdge

    /// `Copy.Measure.snapTargets[rawValue]`, bounds-checked (empty string when out of range).
    var target: String {
        let targets = Copy.Measure.snapTargets
        guard rawValue >= 0, rawValue < targets.count else { return "" }
        return targets[rawValue]
    }
}

/// One place the reticle could snap to.
struct LiveMeasureCandidate: Equatable {
    /// World position, meters.
    var point: SIMD3<Float>
    /// `arView.project(point)`, nil when behind the camera.
    var screen: CGPoint?
    /// Where it came from.
    var source: LiveMeasureSnapSource
    /// Core snap kind stored with a committed point.
    var snap: SnapKind
    /// "Snapped to" tag, when there is one.
    var tag: LiveMeasureSnapTag?
}

/// The reticle's resolved point.
struct LiveMeasureResolution: Equatable {
    /// World position, meters.
    var point: SIMD3<Float>
    /// Where it came from.
    var source: LiveMeasureSnapSource
    /// Core snap kind stored with a committed point.
    var snap: SnapKind
    /// Coverage snap kind for the point's evidence.
    var measurementSnap: MeasurementSnapKind
    /// "Snapped to" tag, when there is one.
    var tag: LiveMeasureSnapTag?
    /// True for existing points and plane corners (a haptic and the "Snapped to" tag).
    var isSnapped: Bool
}

/// Snapping, plane corners and evidence. Pure.
enum LiveMeasureSnapping {
    /// World snap radius, meters.
    static let worldRadius: Float = 0.10
    /// Screen snap radius, points.
    static let screenRadius: CGFloat = 24
    /// A plane intersection counts as a corner within this distance of all three extents.
    static let cornerExtentSlack: Float = 0.30
    /// Corners farther than this from the camera are not offered.
    static let maxCornerDistance: Float = 4
    /// Two vertical planes form a corner only when their normals differ by more than 45 degrees:
    /// the absolute cosine of the angle between them must be below this.
    static let cornerMaxNormalCosine: Float = 0.70710678
    /// A plane-geometry hit farther from the camera than the estimated-plane hit by more than
    /// this lies behind something (the plane polygon continues behind an object), meters.
    static let occlusionSlack: Float = 0.10
    /// Evidence: samples of the last second count as observations.
    static let observationWindow: Double = 1
    /// Evidence: a sample observes the point when its depth is within this of the latest depth, meters.
    static let observationDepthTolerance: Float = 0.02
    /// Evidence: depth confidence applies when the latest depth is within this of the point distance, meters.
    static let depthAgreementTolerance: Float = 0.05
    /// Evidence: observations are clamped to 1...this.
    static let maxObservations = 9

    // MARK: Plane corners

    /// The 4 extent corners in world space: center plus the rotated half extents in the anchor's x-z plane, through `transform`.
    static func extentCorners(_ plane: LiveMeasurePlane) -> [SIMD3<Float>] {
        let halfWidth = plane.width * 0.5
        let halfLength = plane.length * 0.5
        let rotation = simd_quatf(angle: plane.rotationOnYAxis, axis: SIMD3<Float>(0, 1, 0))
        let offsets: [SIMD3<Float>] = [
            SIMD3<Float>(-halfWidth, 0, -halfLength), SIMD3<Float>(halfWidth, 0, -halfLength),
            SIMD3<Float>(halfWidth, 0, halfLength), SIMD3<Float>(-halfWidth, 0, halfLength),
        ]
        return offsets.map { offset in
            let local = plane.center + rotation.act(offset)
            return LiveMeasureMatrix.apply(plane.transform, local)
        }
    }

    /// Geometry `Plane` through the world extent center with the anchor's y axis as the normal.
    static func worldPlane(_ plane: LiveMeasurePlane) -> Plane {
        let center = LiveMeasureMatrix.apply(plane.transform, plane.center)
        let axis = plane.transform.columns.1
        return Plane(point: center, normal: SIMD3<Float>(axis.x, axis.y, axis.z))
    }

    /// Distance from `point` to the plane's extent rectangle (in-plane overshoot and the
    /// distance off the plane combined), meters; infinity for a degenerate transform.
    static func distanceToExtent(_ point: SIMD3<Float>, _ plane: LiveMeasurePlane) -> Float {
        let local = LiveMeasureMatrix.apply(plane.transform.inverse, point)
        let unrotate = simd_quatf(angle: -plane.rotationOnYAxis, axis: SIMD3<Float>(0, 1, 0))
        let relative = unrotate.act(local - plane.center)
        let dx = max(0, abs(relative.x) - plane.width * 0.5)
        let dz = max(0, abs(relative.z) - plane.length * 0.5)
        let squared: Float = dx * dx + dz * dz + relative.y * relative.y
        let distance = squared.squareRoot()
        return distance.isFinite ? distance : .infinity
    }

    /// `Plane.intersection(_:_:_:)` of every pair of vertical planes whose normals differ by more than
    /// 45 degrees with every horizontal plane, kept within `cornerExtentSlack` of all three extents.
    static func intersectionCorners(_ planes: [LiveMeasurePlane]) -> [SIMD3<Float>] {
        let verticals = planes.filter { $0.facing == .vertical }
        let horizontals = planes.filter { $0.facing == .horizontal }
        guard verticals.count >= 2, !horizontals.isEmpty else { return [] }
        let verticalPlanes = verticals.map { worldPlane($0) }
        let horizontalPlanes = horizontals.map { worldPlane($0) }
        var corners: [SIMD3<Float>] = []
        for i in 0..<(verticals.count - 1) {
            for j in (i + 1)..<verticals.count {
                let cosine = abs(simd_dot(verticalPlanes[i].normal, verticalPlanes[j].normal))
                guard cosine < cornerMaxNormalCosine else { continue }
                for k in 0..<horizontals.count {
                    guard let corner = Plane.intersection(verticalPlanes[i], verticalPlanes[j], horizontalPlanes[k]),
                          isFinite(corner) else { continue }
                    guard distanceToExtent(corner, verticals[i]) <= cornerExtentSlack,
                          distanceToExtent(corner, verticals[j]) <= cornerExtentSlack,
                          distanceToExtent(corner, horizontals[k]) <= cornerExtentSlack else { continue }
                    corners.append(corner)
                }
            }
        }
        return corners
    }

    /// Corner candidates (extent corners of every plane, then intersections) within `maxCornerDistance` of `camera`.
    static func cornerPoints(_ planes: [LiveMeasurePlane], camera: SIMD3<Float>) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for plane in planes {
            for corner in extentCorners(plane) where isFinite(corner) && simd_distance(corner, camera) <= maxCornerDistance {
                points.append(corner)
            }
        }
        for corner in intersectionCorners(planes) where simd_distance(corner, camera) <= maxCornerDistance {
            points.append(corner)
        }
        return points
    }

    // MARK: Resolution

    /// Existing points, then plane corners: the nearest on screen among those within `worldRadius` of the
    /// ray hit (`hit.point`) and within `screenRadius` of `reticle` (when projected); else `hit` (plane
    /// geometry); else `fallback` (estimated plane); else nil. Without a plane-geometry hit the
    /// estimated-plane hit is the reference point for the world radius.
    static func resolve(hit: LiveMeasureCandidate?, fallback: LiveMeasureCandidate?, candidates: [LiveMeasureCandidate],
                        reticle: CGPoint) -> LiveMeasureResolution? {
        if let reference = hit ?? fallback {
            for source in [LiveMeasureSnapSource.existingPoint, LiveMeasureSnapSource.planeCorner] {
                let group = candidates.filter { $0.source == source }
                if let best = nearest(group, to: reference.point, reticle: reticle) {
                    let inherited: MeasurementSnapKind? = source == .existingPoint ? measurementSnap(of: best.snap) : nil
                    return LiveMeasureResolution(point: best.point, source: source, snap: best.snap,
                                                 measurementSnap: measurementSnap(for: source, inherited: inherited),
                                                 tag: best.tag, isSnapped: true)
                }
            }
        }
        if let hit {
            return LiveMeasureResolution(point: hit.point, source: .planeGeometry, snap: .plane,
                                         measurementSnap: measurementSnap(for: .planeGeometry, inherited: nil),
                                         tag: hit.tag, isSnapped: false)
        }
        if let fallback {
            return LiveMeasureResolution(point: fallback.point, source: .estimatedPlane, snap: SnapKind.none,
                                         measurementSnap: measurementSnap(for: .estimatedPlane, inherited: nil),
                                         tag: nil, isSnapped: false)
        }
        return nil
    }

    /// The plane-geometry hit unless the estimated-plane hit is nearer the camera by more than
    /// `occlusionSlack` (then the plane polygon continues behind the surface the user aims at).
    static func unoccludedHit(_ hit: LiveMeasureCandidate?, fallback: LiveMeasureCandidate?,
                              camera: SIMD3<Float>) -> LiveMeasureCandidate? {
        guard let hit, let fallback else { return hit }
        let hitDistance = simd_distance(hit.point, camera)
        let fallbackDistance = simd_distance(fallback.point, camera)
        guard hitDistance.isFinite, fallbackDistance.isFinite else { return hit }
        return fallbackDistance + occlusionSlack < hitDistance ? nil : hit
    }

    /// wall -> .wall, floor -> .floor, ceiling -> .ceiling, door -> .door, window -> .window,
    /// table and seat -> .objectEdge, unknown -> nil.
    static func tag(for kind: LiveMeasurePlaneKind) -> LiveMeasureSnapTag? {
        switch kind {
        case .wall: return .wall
        case .floor: return .floor
        case .ceiling: return .ceiling
        case .door: return .door
        case .window: return .window
        case .table, .seat: return .objectEdge
        case .unknown: return nil
        }
    }

    /// existingPoint keeps the snapped point's kind; planeCorner and planeGeometry -> .plane; estimatedPlane -> .none.
    /// An existing point without an inherited kind counts as free (`.none`).
    static func measurementSnap(for source: LiveMeasureSnapSource, inherited: MeasurementSnapKind?) -> MeasurementSnapKind {
        switch source {
        case .existingPoint: return inherited ?? MeasurementSnapKind.none
        case .planeCorner, .planeGeometry: return .plane
        case .estimatedPlane: return MeasurementSnapKind.none
        }
    }

    /// Coverage snap kind of a committed point's Core snap kind (corners and planes of ARKit
    /// planes are fitted planes, never RoomPlan surfaces).
    static func measurementSnap(of kind: SnapKind) -> MeasurementSnapKind {
        switch kind {
        case .corner, .plane: return .plane
        case .edge: return .edge
        case .meshVertex: return .vertex
        case .meshSurface, .none: return MeasurementSnapKind.none
        }
    }

    // MARK: Evidence

    /// Evidence at commit time: distance from the latest camera to `point`; observations = recent
    /// samples (last second) whose depth is within 2 cm of the latest, 1...9; confidence = their mean
    /// when the latest depth is within 5 cm of that distance, else nil; tracking fraction over the window.
    /// When the latest depth does not agree with the point distance, the depth samples did not look
    /// at the point, so observations fall back to 1. Without any sample: the default distance,
    /// 1 observation, no confidence and a tracking fraction of 0 (no evidence at all).
    static func evidence(point: SIMD3<Float>, samples: [LiveMeasureDepthSample], snap: MeasurementSnapKind,
                         now: Double) -> MeasurementEvidence {
        guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }) else {
            return MeasurementEvidence(distance: ConfidenceAdapter.defaultDistance, depthConfidence: nil,
                                       observations: 1, trackingNormalFraction: 0, snap: snap)
        }
        var distance = simd_distance(LiveMeasureMatrix.translation(latest.cameraToWorld), point)
        if !distance.isFinite { distance = ConfidenceAdapter.defaultDistance }
        var observations = 1
        var confidence: Float?
        if let latestDepth = latest.distance, latestDepth.isFinite, abs(latestDepth - distance) <= depthAgreementTolerance {
            var count = 0
            var confidences: [Float] = []
            for sample in samples where sample.timestamp >= now - observationWindow {
                guard let depth = sample.distance, abs(depth - latestDepth) <= observationDepthTolerance else { continue }
                count += 1
                if let value = sample.confidence, value.isFinite { confidences.append(value) }
            }
            observations = min(max(count, 1), maxObservations)
            if !confidences.isEmpty {
                confidence = confidences.reduce(0, +) / Float(confidences.count)
            }
        }
        let window = samples.filter { $0.timestamp >= now - LiveMeasureProbe.windowSeconds }
        let normal = window.filter { $0.trackingNormal }.count
        let fraction: Float = window.isEmpty ? 0 : Float(normal) / Float(window.count)
        return MeasurementEvidence(distance: distance, depthConfidence: confidence, observations: observations,
                                   trackingNormalFraction: fraction, snap: snap)
    }

    // MARK: Guidance

    /// Tier 1 messages only (Quick Measure is not a coverage scan).
    static func filterGuidance(_ output: GuidanceOutput) -> GuidanceOutput {
        guard let kind = output.message else { return output }
        guard kind.message.tier == 1 else { return GuidanceOutput(message: nil, fireHaptic: false) }
        return output
    }

    /// The Mapper guidance input from a hub status (tracking, speeds, distance, light, depth confidence, heat).
    static func guidanceInput(time: Double, status: HubStatus) -> GuidanceInput {
        var input = GuidanceInput(time: time)
        input.tracking = GuidanceSignals.tracking(status.tracking)
        input.angularSpeed = status.angularSpeed
        input.linearSpeed = status.linearSpeed
        input.centerDistance = status.centerDistance
        input.depthConfidenceMean = status.depthConfidenceMean
        input.ambientIntensity = status.ambientIntensity
        input.deviceHot = status.thermal == .serious || status.thermal == .critical
        return input
    }

    // MARK: Helpers

    /// The candidate nearest the reticle on screen (then nearest the reference in the world)
    /// among those within `worldRadius` of `reference` and, when projected, `screenRadius` of `reticle`.
    private static func nearest(_ group: [LiveMeasureCandidate], to reference: SIMD3<Float>,
                                reticle: CGPoint) -> LiveMeasureCandidate? {
        var best: LiveMeasureCandidate?
        var bestScreen = CGFloat.infinity
        var bestWorld = Float.infinity
        for candidate in group {
            let world = simd_distance(candidate.point, reference)
            guard world.isFinite, world <= worldRadius else { continue }
            var screen = screenRadius
            if let projected = candidate.screen {
                let dx = projected.x - reticle.x
                let dy = projected.y - reticle.y
                screen = (dx * dx + dy * dy).squareRoot()
                guard screen <= screenRadius else { continue }
            }
            if screen < bestScreen || (screen == bestScreen && world < bestWorld) {
                best = candidate
                bestScreen = screen
                bestWorld = world
            }
        }
        return best
    }

    /// True when all three components are finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}
