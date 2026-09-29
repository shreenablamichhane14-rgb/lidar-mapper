import Foundation
import simd

/// What a snapped point snapped to (RESEARCH 3.6 recommended 12).
enum PlanSnapKind: String, Equatable, Sendable { case endpoint, wall, angle, grid, none }

/// A snapped plan point, meters, and what it snapped to.
struct PlanSnapResult: Equatable, Sendable {
    /// The snapped point.
    var point: SIMD2<Float>
    /// What it snapped to.
    var kind: PlanSnapKind
}

/// Snap targets of one level.
struct PlanSnapTargets: Equatable {
    /// Wall ends and user dimension ends.
    var endpoints: [SIMD2<Float>]
    /// Straight wall lines (curved walls give only their ends).
    var segments: [Segment2D]
    /// Unit direction of the level's longest straight wall; (1, 0) without walls.
    var axis: SIMD2<Float>
}

/// Snapping of drawn and dragged points (RESEARCH 3.6 recommended 12), plan meters: wall ends
/// first, then wall lines, then 0, 45 and 90 degree directions from an anchor, then a grid aligned
/// with the level's main wall direction. Pure and safe on any thread.
enum PlanEditorSnapping {
    /// Snap radius of wall ends and wall lines, meters (the editor uses the larger of this and
    /// 12 screen points).
    static let endpointRadius: Float = 0.05
    /// Directions snap to multiples of this angle from the axis, degrees.
    static let angleStepDegrees: Float = 45
    /// A direction within this angle of a multiple snaps, degrees.
    static let angleToleranceDegrees: Float = 4
    /// Grid steps, meters: 100 mm (metric) and 1 inch (imperial).
    static let metricGrid: Float = 0.1
    static let imperialGrid: Float = 0.0254

    /// Targets of a level, leaving out the walls in `excluding` (the wall being dragged and the ends
    /// that move with it).
    static func targets(level: PlanLevel, excluding: Set<ElementID>) -> PlanSnapTargets {
        var endpoints: [SIMD2<Float>] = []
        var segments: [Segment2D] = []
        for wall in level.walls where !excluding.contains(wall.id) {
            let a = wall.a.simd
            let b = wall.b.simd
            guard PlanEditorOps.isFinite(a), PlanEditorOps.isFinite(b) else { continue }
            endpoints.append(a)
            endpoints.append(b)
            if wall.arc == nil, simd_distance(a, b) > 1e-4 {
                segments.append(Segment2D(a: a, b: b))
            }
        }
        for dimension in level.dimensions where dimension.isUser && !excluding.contains(dimension.id) {
            if PlanEditorOps.isFinite(dimension.a.simd) { endpoints.append(dimension.a.simd) }
            if PlanEditorOps.isFinite(dimension.b.simd) { endpoints.append(dimension.b.simd) }
        }
        return PlanSnapTargets(endpoints: endpoints, segments: segments, axis: referenceAxis(level))
    }

    /// Unit direction of the level's longest straight wall; (1, 0) without walls.
    static func referenceAxis(_ level: PlanLevel) -> SIMD2<Float> {
        var best = SIMD2<Float>(1, 0)
        var bestLength: Float = 0
        for wall in level.walls where wall.arc == nil {
            let d = wall.b.simd - wall.a.simd
            let length = simd_length(d)
            guard length.isFinite, length > bestLength, length > 1e-4 else { continue }
            bestLength = length
            best = d / length
        }
        return best
    }

    /// metricGrid for metric preferences, imperialGrid for imperial.
    static func gridStep(_ prefs: UnitPreferences) -> Float {
        switch prefs.system {
        case .metric: return metricGrid
        case .imperial: return imperialGrid
        }
    }

    /// Endpoint within `radius`; else the foot on a segment within `radius`; else, with an anchor, the
    /// direction anchor -> p turned to the nearest multiple of 45 degrees from `axis` when within 4
    /// degrees (its length rounded to the grid); else p rounded to the grid in the frame of `axis`
    /// through plan (0, 0). `.none` (p unchanged) when `enabled` is false.
    static func snap(_ p: SIMD2<Float>, anchor: SIMD2<Float>?, targets: PlanSnapTargets, radius: Float,
                     grid: Float, enabled: Bool) -> PlanSnapResult {
        guard enabled, PlanEditorOps.isFinite(p) else { return PlanSnapResult(point: p, kind: .none) }
        let limit: Float = radius.isFinite ? max(0, radius) : 0
        if let end = nearest(targets.endpoints, to: p), simd_distance(end, p) <= limit {
            return PlanSnapResult(point: end, kind: .endpoint)
        }
        var bestFoot: SIMD2<Float>?
        var bestDistance = limit
        for segment in targets.segments {
            let foot = segment.closestPoint(to: p)
            let distance = simd_distance(foot, p)
            if distance <= bestDistance {
                bestDistance = distance
                bestFoot = foot
            }
        }
        if let foot = bestFoot { return PlanSnapResult(point: foot, kind: .wall) }
        let axis = unitAxis(targets.axis)
        if let anchor, let turned = angleSnap(p, anchor: anchor, axis: axis, grid: grid) {
            return PlanSnapResult(point: turned, kind: .angle)
        }
        guard grid.isFinite, grid > 0 else { return PlanSnapResult(point: p, kind: .none) }
        let normal = SIMD2<Float>(-axis.y, axis.x)
        let along = (simd_dot(p, axis) / grid).rounded() * grid
        let across = (simd_dot(p, normal) / grid).rounded() * grid
        return PlanSnapResult(point: axis * along + normal * across, kind: .grid)
    }

    /// A scalar move (Move Wall) rounded to the grid step when enabled.
    static func snapDistance(_ d: Float, grid: Float, enabled: Bool) -> Float {
        guard enabled, d.isFinite, grid.isFinite, grid > 0 else { return d }
        return (d / grid).rounded() * grid
    }

    /// `anchor -> p` turned to the nearest multiple of `angleStepDegrees` from `axis` when it is
    /// within `angleToleranceDegrees`, its length rounded to the grid (kept when that rounds to 0).
    static func angleSnap(_ p: SIMD2<Float>, anchor: SIMD2<Float>, axis: SIMD2<Float>, grid: Float) -> SIMD2<Float>? {
        guard PlanEditorOps.isFinite(anchor) else { return nil }
        let v = p - anchor
        let length = simd_length(v)
        guard length > 1e-5 else { return nil }
        let angle = atan2(Segment2D.cross(axis, v), simd_dot(axis, v))
        let step = angleStepDegrees * Float.pi / 180
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) <= angleToleranceDegrees * Float.pi / 180 else { return nil }
        let c: Float = cos(snapped)
        let s: Float = sin(snapped)
        let x: Float = axis.x * c - axis.y * s
        let y: Float = axis.x * s + axis.y * c
        let direction = SIMD2<Float>(x, y)
        var snappedLength = length
        if grid.isFinite, grid > 0 {
            let rounded = (length / grid).rounded() * grid
            if rounded > 0 { snappedLength = rounded }
        }
        return anchor + direction * snappedLength
    }

    /// The point of `points` nearest to `p`.
    private static func nearest(_ points: [SIMD2<Float>], to p: SIMD2<Float>) -> SIMD2<Float>? {
        var best: SIMD2<Float>?
        var bestDistance = Float.greatestFiniteMagnitude
        for point in points {
            let distance = simd_distance(point, p)
            if distance < bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best
    }

    /// `axis` normalized; (1, 0) when it is zero or not finite.
    private static func unitAxis(_ axis: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(axis)
        guard length.isFinite, length > 1e-6 else { return SIMD2<Float>(1, 0) }
        return axis / length
    }
}
