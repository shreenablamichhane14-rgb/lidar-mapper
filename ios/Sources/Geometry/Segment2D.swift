import Foundation
import simd

/// A 2D line segment from `a` to `b`, used for wall edges in floor plans.
struct Segment2D: Equatable {
    /// Start point.
    var a: SIMD2<Float>
    /// End point.
    var b: SIMD2<Float>

    /// Lengths and cross products below this (scaled by the segment lengths) count as zero.
    static let epsilon: Float = 1e-6

    /// Creates a segment between two points.
    init(a: SIMD2<Float>, b: SIMD2<Float>) {
        self.a = a
        self.b = b
    }

    /// Distance from `a` to `b`.
    var length: Float { simd_distance(a, b) }

    /// Unit vector from `a` to `b`, or zero for a degenerate segment.
    var direction: SIMD2<Float> {
        let d = b - a
        let l = simd_length(d)
        return l > Segment2D.epsilon ? d / l : .zero
    }

    /// Point on the segment nearest to `p`.
    func closestPoint(to p: SIMD2<Float>) -> SIMD2<Float> {
        let d = b - a
        let lengthSquared = simd_length_squared(d)
        guard lengthSquared > Segment2D.epsilon * Segment2D.epsilon else { return a }
        let t = simd_clamp(simd_dot(p - a, d) / lengthSquared, 0, 1)
        return a + d * t
    }

    /// Distance from `p` to the nearest point of the segment.
    func distance(to p: SIMD2<Float>) -> Float {
        simd_distance(p, closestPoint(to: p))
    }

    /// Intersection point with another segment, endpoints included, or nil when they do not
    /// touch. Parallel segments that are collinear and overlap return the overlap point
    /// nearest to this segment's `a`; parallel disjoint segments return nil. Degenerate
    /// (point) segments intersect when the point lies on the other segment.
    func intersection(with other: Segment2D) -> SIMD2<Float>? {
        let r = b - a
        let s = other.b - other.a
        let rLength = simd_length(r)
        let sLength = simd_length(s)
        let eps = Segment2D.epsilon

        if rLength <= eps && sLength <= eps {
            return simd_distance(a, other.a) <= eps ? a : nil
        }
        if rLength <= eps {
            return other.distance(to: a) <= eps ? a : nil
        }
        if sLength <= eps {
            return distance(to: other.a) <= eps ? other.a : nil
        }

        let qp = other.a - a
        let denom = Segment2D.cross(r, s)
        if abs(denom) <= eps * rLength * sLength {
            // Parallel. Collinear only when other.a lies on this segment's line.
            guard abs(Segment2D.cross(qp, r)) <= eps * rLength * max(1, simd_length(qp)) else { return nil }
            let rr = rLength * rLength
            let t0 = simd_dot(qp, r) / rr
            let t1 = simd_dot(other.b - a, r) / rr
            let lo = max(0, min(t0, t1))
            let hi = min(1, max(t0, t1))
            let slack = eps / rLength
            guard lo <= hi + slack else { return nil }
            return a + r * min(lo, 1)
        }
        let t = Segment2D.cross(qp, s) / denom
        let u = Segment2D.cross(qp, r) / denom
        let tSlack = eps / rLength
        let uSlack = eps / sLength
        guard t >= -tSlack, t <= 1 + tSlack, u >= -uSlack, u <= 1 + uSlack else { return nil }
        return a + r * simd_clamp(t, 0, 1)
    }

    /// Unsigned angle between the two segment directions, in radians, from 0 to pi.
    /// Returns 0 when either segment is degenerate.
    func angle(between other: Segment2D) -> Float {
        let u = direction
        let v = other.direction
        guard u != .zero, v != .zero else { return 0 }
        return atan2(abs(Segment2D.cross(u, v)), simd_dot(u, v))
    }

    /// Z component of the 3D cross product of two 2D vectors.
    static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
        u.x * v.y - u.y * v.x
    }
}
