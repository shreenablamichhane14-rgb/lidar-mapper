import Foundation
import simd

/// Pure geometry and uncertainty of the tools. Nonisolated, any queue.
enum MeasureMath {
    /// Arms shorter than this give an angle of 0, meters.
    static let minimumArm: Float = 0.001
    /// Newell sums shorter than this are degenerate (no normal), square meters times 2.
    static let degenerateNewell: Float = 1e-9

    /// Angle ABC at B, radians in 0...pi; 0 when an arm is shorter than 1 mm.
    static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ba = a - b
        let bc = c - b
        let lengthA = simd_length(ba)
        let lengthC = simd_length(bc)
        guard lengthA.isFinite, lengthC.isFinite, lengthA >= minimumArm, lengthC >= minimumArm else { return 0 }
        let cosine = simd_dot(ba, bc) / (lengthA * lengthC)
        let clamped = min(max(cosine, -1), 1)
        let result = acos(clamped)
        return result.isFinite ? result : 0
    }

    /// Area of a closed polygon in 3D: half the length of the Newell sum of p_i x p_(i+1). Exact for
    /// planar polygons, the area projected on the best-fit plane otherwise; 0 below 3 points.
    static func polygonArea(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        let area = simd_length(newellSum(points)) * 0.5
        return area.isFinite ? area : 0
    }

    /// Unit normal of the Newell sum; nil below 3 points or for a degenerate polygon.
    static func polygonNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard points.count >= 3 else { return nil }
        let sum = newellSum(points)
        let length = simd_length(sum)
        guard length.isFinite, length > degenerateNewell else { return nil }
        return sum / length
    }

    /// Label anchor of an area: the vertex mean (never outside a convex polygon).
    static func polygonCenter(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var total = SIMD3<Float>.zero
        for p in points { total += p }
        return total / Float(points.count)
    }

    /// |b.y - a.y|.
    static func verticalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        abs(b.y - a.y)
    }

    /// 1 sigma of a polygon area, square meters: sqrt(sum_i (s_i |p_(i+1) - p_(i-1)| / 2)^2 + (2 d A)^2),
    /// s_i the point sigmas (meters), d the drift rate (a fraction of length, so an area grows by 2 d).
    /// A missing point sigma counts as the largest given one; 0 below 3 points.
    static func areaSigma(_ points: [SIMD3<Float>], pointSigmas: [Float], driftRate: Float) -> Float {
        let n = points.count
        guard n >= 3 else { return 0 }
        let fallback: Float = pointSigmas.filter { $0.isFinite }.max() ?? 0
        var squares: Float = 0
        for i in 0..<n {
            let next = points[(i + 1) % n]
            let previous = points[(i + n - 1) % n]
            let given: Float = i < pointSigmas.count ? pointSigmas[i] : fallback
            let sigma: Float = given.isFinite ? abs(given) : fallback
            let term: Float = sigma * simd_length(next - previous) * 0.5
            squares += term * term
        }
        let rate: Float = driftRate.isFinite ? abs(driftRate) : 0
        let drift: Float = 2 * rate * polygonArea(points)
        let total = (squares + drift * drift).squareRoot()
        return total.isFinite ? total : 0
    }

    /// 1 sigma of the angle at B, radians, a first-order bound:
    /// sqrt((sA / |BA|)^2 + (sC / |BC|)^2 + sB^2 (1 / |BA|^2 + 1 / |BC|^2)).
    /// Pi (nothing known) when an arm is shorter than 1 mm.
    static func angleSigma(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           sigmaA: Float, sigmaB: Float, sigmaC: Float) -> Float {
        let armA = simd_length(a - b)
        let armC = simd_length(c - b)
        guard armA.isFinite, armC.isFinite, armA >= minimumArm, armC >= minimumArm else { return Float.pi }
        let termA: Float = abs(sigmaA) / armA
        let termC: Float = abs(sigmaC) / armC
        let inverse: Float = 1 / (armA * armA) + 1 / (armC * armC)
        let termB: Float = sigmaB * sigmaB * inverse
        let total = (termA * termA + termC * termC + termB).squareRoot()
        return total.isFinite ? min(total, Float.pi) : Float.pi
    }

    /// Newell sum of the polygon, computed relative to its first point so large world
    /// coordinates do not cost precision (the sum is translation invariant for a closed loop).
    private static func newellSum(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        let origin = points[0]
        var sum = SIMD3<Float>.zero
        let n = points.count
        for i in 0..<n {
            let p = points[i] - origin
            let q = points[(i + 1) % n] - origin
            sum += simd_cross(p, q)
        }
        return sum
    }
}
