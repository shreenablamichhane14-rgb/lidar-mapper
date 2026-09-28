import Foundation
import simd

/// What a snapped measurement point attached to. The associated value is the index into
/// the candidate list that was passed in.
enum SnapTarget: Equatable {
    case corner(Int)
    case edge(Int)
    case plane(Int)
    case none
}

/// Result of a snap: the point to use and what it came from. For `.none`, `point` is the
/// input point unchanged and `distance` is 0.
struct SnapResult: Equatable {
    /// Snapped point (or the original point when nothing was in range).
    var point: SIMD3<Float>
    /// Candidate that was used.
    var target: SnapTarget
    /// Distance from the input point to `point`.
    var distance: Float
}

/// Snapping helpers for the measurement tool. Each function picks the nearest candidate
/// within `radius` (inclusive); ties keep the lowest index. Radii are in meters.
enum Snap {
    /// Default corner snap radius: 3 cm.
    static let defaultCornerRadius: Float = 0.03
    /// Default edge snap radius: 2 cm.
    static let defaultEdgeRadius: Float = 0.02
    /// Default plane snap radius: 5 cm.
    static let defaultPlaneRadius: Float = 0.05
    /// Squared edge lengths below this treat the edge as a single point.
    static let degenerateEdgeSquared: Float = 1e-12

    /// Snaps to the nearest corner within `radius`.
    static func toCorner(_ p: SIMD3<Float>, corners: [SIMD3<Float>],
                         radius: Float = defaultCornerRadius) -> SnapResult {
        var best = SnapResult(point: p, target: .none, distance: 0)
        var bestDistance = radius
        for (i, corner) in corners.enumerated() {
            let d = simd_distance(p, corner)
            if d <= bestDistance && (best.target == .none || d < bestDistance) {
                bestDistance = d
                best = SnapResult(point: corner, target: .corner(i), distance: d)
            }
        }
        return best
    }

    /// Snaps to the nearest point on the nearest edge (3D segment) within `radius`.
    static func toEdge(_ p: SIMD3<Float>, edges: [(SIMD3<Float>, SIMD3<Float>)],
                       radius: Float = defaultEdgeRadius) -> SnapResult {
        var best = SnapResult(point: p, target: .none, distance: 0)
        var bestDistance = radius
        for (i, edge) in edges.enumerated() {
            let q = closestPointOnSegment(p, edge.0, edge.1)
            let d = simd_distance(p, q)
            if d <= bestDistance && (best.target == .none || d < bestDistance) {
                bestDistance = d
                best = SnapResult(point: q, target: .edge(i), distance: d)
            }
        }
        return best
    }

    /// Snaps onto the nearest plane (projection) within `radius`.
    static func toPlane(_ p: SIMD3<Float>, planes: [Plane],
                        radius: Float = defaultPlaneRadius) -> SnapResult {
        var best = SnapResult(point: p, target: .none, distance: 0)
        var bestDistance = radius
        for (i, plane) in planes.enumerated() {
            let d = abs(plane.signedDistance(to: p))
            if d <= bestDistance && (best.target == .none || d < bestDistance) {
                bestDistance = d
                best = SnapResult(point: plane.project(p), target: .plane(i), distance: d)
            }
        }
        return best
    }

    /// Tries corners, then edges, then planes, and returns the first that is in range.
    /// Corners win over edges even when an edge is closer, since corners are what people
    /// measure between.
    static func best(_ p: SIMD3<Float>,
                     corners: [SIMD3<Float>], edges: [(SIMD3<Float>, SIMD3<Float>)], planes: [Plane],
                     cornerRadius: Float = defaultCornerRadius,
                     edgeRadius: Float = defaultEdgeRadius,
                     planeRadius: Float = defaultPlaneRadius) -> SnapResult {
        let corner = toCorner(p, corners: corners, radius: cornerRadius)
        if corner.target != .none { return corner }
        let edge = toEdge(p, edges: edges, radius: edgeRadius)
        if edge.target != .none { return edge }
        return toPlane(p, planes: planes, radius: planeRadius)
    }

    /// Point of segment (a, b) nearest to `p`.
    static func closestPointOnSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let d = b - a
        let lengthSquared = simd_length_squared(d)
        guard lengthSquared > degenerateEdgeSquared else { return a }
        let t = simd_clamp(simd_dot(p - a, d) / lengthSquared, 0, 1)
        return a + d * t
    }
}
