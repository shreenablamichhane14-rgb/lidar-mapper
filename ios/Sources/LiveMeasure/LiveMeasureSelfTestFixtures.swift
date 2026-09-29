import Foundation
import CoreGraphics
import simd

/// Fixed inputs of LiveMeasureSelfTest: planes, candidates, samples and records with fixed
/// identifiers and dates (no randomness, no clock). Pure.
enum LiveMeasureSelfTestFixtures {
    /// A fixed date on a whole second (ISO 8601 round trips exactly).
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// A fixed identifier whose last byte is `n`.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    /// `m` with its translation replaced by `t`.
    static func moved(_ m: simd_float4x4, _ t: SIMD3<Float>) -> simd_float4x4 {
        var result = m
        result.columns.3 = SIMD4<Float>(t, 1)
        return result
    }

    /// A plane record with a zero local center and no extent rotation.
    static func plane(_ transform: simd_float4x4, width: Float, length: Float, facing: LiveMeasurePlaneFacing,
                      kind: LiveMeasurePlaneKind = .unknown, id: UInt8) -> LiveMeasurePlane {
        LiveMeasurePlane(id: fixedID(id), transform: transform, center: SIMD3<Float>(0, 0, 0), width: width, length: length,
                         rotationOnYAxis: 0, facing: facing, kind: kind)
    }

    /// A 4 x 4 m wall in the plane x = position.x (normal +x: the anchor's y axis turned onto x).
    static func wallX(at position: SIMD3<Float>, id: UInt8) -> LiveMeasurePlane {
        let rotation = simd_float4x4(simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(0, 0, 1)))
        return plane(moved(rotation, position), width: 4, length: 4, facing: .vertical, kind: .wall, id: id)
    }

    /// A 4 x 4 m wall in the plane z = position.z (normal +z: the anchor's y axis turned onto z).
    static func wallZ(at position: SIMD3<Float>, id: UInt8) -> LiveMeasurePlane {
        let rotation = simd_float4x4(simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        return plane(moved(rotation, position), width: 4, length: 4, facing: .vertical, kind: .wall, id: id)
    }

    /// A candidate at (dx, 0, -1).
    static func candidate(_ dx: Float, screen: CGPoint?, source: LiveMeasureSnapSource, snap: SnapKind,
                          tag: LiveMeasureSnapTag?) -> LiveMeasureCandidate {
        LiveMeasureCandidate(point: SIMD3<Float>(dx, 0, -1), screen: screen, source: source, snap: snap, tag: tag)
    }

    /// A center sample from a camera at the origin; confidence 1 when there is depth.
    static func sample(_ timestamp: Double, depth: Float?, normal: Bool = true) -> LiveMeasureDepthSample {
        LiveMeasureDepthSample(timestamp: timestamp, distance: depth, confidence: depth == nil ? nil : 1,
                               trackingNormal: normal, cameraToWorld: matrix_identity_float4x4)
    }

    /// Two distances with fixed ids, points and dates.
    static func records() -> [MeasurementRecord] {
        let evidence = MeasurementEvidence(distance: 1.2, depthConfidence: 0.9, observations: 6,
                                           trackingNormalFraction: 1, snap: .plane)
        let a = LiveMeasurePoint(position: SIMD3<Float>(0.25, 0, -1), snap: .corner, evidence: evidence)
        let b = LiveMeasurePoint(position: SIMD3<Float>(1.5, 0, -1.25), snap: .plane, evidence: evidence)
        let c = LiveMeasurePoint(position: SIMD3<Float>(0, 1.25, -2), snap: SnapKind.none, evidence: evidence)
        let first = LiveMeasureSegment.make(start: a, end: b, id: fixedID(21), createdAt: fixedDate)
        let second = LiveMeasureSegment.make(start: b, end: c, id: fixedID(22), createdAt: fixedDate.addingTimeInterval(5))
        return [first.record(), second.record()]
    }

    /// True when `resolution` exists with this source and snapped flag.
    static func matches(_ resolution: LiveMeasureResolution?, _ source: LiveMeasureSnapSource, snapped: Bool) -> Bool {
        guard let resolution else { return false }
        return resolution.source == source && resolution.isSnapped == snapped
    }

    /// True when `points` has a point within 1e-4 m of `p`.
    static func contains(_ points: [SIMD3<Float>], _ p: SIMD3<Float>) -> Bool {
        points.contains { simd_distance($0, p) < 1e-4 }
    }

    /// True when both lists hold the same points (within 1e-4 m), in any order.
    static func sameSet(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Bool {
        guard a.count == b.count else { return false }
        return a.allSatisfy { contains(b, $0) } && b.allSatisfy { contains(a, $0) }
    }
}
