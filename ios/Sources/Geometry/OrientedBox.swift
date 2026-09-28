import Foundation
import simd

/// A rectangle in 2D with a unit `axis` for its first side and the perpendicular
/// `(-axis.y, axis.x)` for its second side.
struct Rectangle2D: Equatable {
    /// Center of the rectangle.
    var center: SIMD2<Float>
    /// Unit direction of the first side.
    var axis: SIMD2<Float>
    /// Half the side lengths along `axis` and along its left perpendicular.
    var halfExtents: SIMD2<Float>

    /// Edges shorter than this are skipped by the calipers.
    static let epsilon: Float = 1e-9

    /// Area of the rectangle.
    var area: Float { 4 * halfExtents.x * halfExtents.y }

    /// Minimum-area enclosing rectangle by convex hull plus rotating calipers, O(n log n).
    /// One side of the optimum always lies along a hull edge, so each hull edge is tried
    /// while three calipers (max and min along the edge, max along its normal) advance
    /// monotonically around the hull. Nil for no points; collinear input gives a zero-width
    /// rectangle along the line.
    static func minimumArea(enclosing points: [SIMD2<Float>]) -> Rectangle2D? {
        let hull = Polygon2D.convexHull(points).points
        let n = hull.count
        guard n > 0 else { return nil }
        if n == 1 {
            return Rectangle2D(center: hull[0], axis: SIMD2<Float>(1, 0), halfExtents: .zero)
        }
        if n == 2 {
            let d = hull[1] - hull[0]
            let length = simd_length(d)
            let axis = length > epsilon ? d / length : SIMD2<Float>(1, 0)
            return Rectangle2D(center: (hull[0] + hull[1]) * 0.5, axis: axis,
                               halfExtents: SIMD2<Float>(length * 0.5, 0))
        }

        var best: Rectangle2D?
        var iMaxU = 0, iMinU = 0, iMaxN = 0
        var initialized = false
        for i in 0..<n {
            let edge = hull[(i + 1) % n] - hull[i]
            let length = simd_length(edge)
            guard length > epsilon else { continue }
            let u = edge / length
            let normal = SIMD2<Float>(-u.y, u.x) // Points into the CCW hull.
            if !initialized {
                for k in 0..<n {
                    if simd_dot(hull[k], u) > simd_dot(hull[iMaxU], u) { iMaxU = k }
                    if simd_dot(hull[k], u) < simd_dot(hull[iMinU], u) { iMinU = k }
                    if simd_dot(hull[k], normal) > simd_dot(hull[iMaxN], normal) { iMaxN = k }
                }
                initialized = true
            } else {
                // Each caliper only ever moves forward; the step cap guards against ties.
                iMaxU = advance(iMaxU, hull, u, towardLarger: true)
                iMinU = advance(iMinU, hull, u, towardLarger: false)
                iMaxN = advance(iMaxN, hull, normal, towardLarger: true)
            }
            let minU = simd_dot(hull[iMinU], u)
            let maxU = simd_dot(hull[iMaxU], u)
            let minN = simd_dot(hull[i], normal)
            let maxN = simd_dot(hull[iMaxN], normal)
            let half = SIMD2<Float>((maxU - minU) * 0.5, (maxN - minN) * 0.5)
            if best.map({ 4 * half.x * half.y < $0.area }) ?? true {
                let center = u * ((minU + maxU) * 0.5) + normal * ((minN + maxN) * 0.5)
                best = Rectangle2D(center: center, axis: u, halfExtents: half)
            }
        }
        return best
    }

    /// Moves a caliper index forward around the hull while the next vertex projects at
    /// least as far (or, for the minimum caliper, at most as far) along `direction`.
    private static func advance(_ start: Int, _ hull: [SIMD2<Float>], _ direction: SIMD2<Float>,
                                towardLarger: Bool) -> Int {
        let n = hull.count
        var index = start
        for _ in 0..<n {
            let next = (index + 1) % n
            let current = simd_dot(hull[index], direction)
            let candidate = simd_dot(hull[next], direction)
            guard towardLarger ? candidate >= current : candidate <= current else { break }
            index = next
        }
        return index
    }
}

/// A box with arbitrary orientation. `axes` columns are unit, mutually orthogonal and
/// right-handed; `halfExtents[i]` is the half size along column i.
struct OrientedBox: Equatable {
    /// Center of the box.
    var center: SIMD3<Float>
    /// Local axes as matrix columns (a rotation).
    var axes: simd_float3x3
    /// Half sizes along each local axis.
    var halfExtents: SIMD3<Float>

    /// Default slack for `contains`, absorbing float rounding on the faces.
    static let containsTolerance: Float = 1e-5

    /// Creates a box from center, axes and half extents.
    init(center: SIMD3<Float>, axes: simd_float3x3, halfExtents: SIMD3<Float>) {
        self.center = center
        self.axes = axes
        self.halfExtents = halfExtents
    }

    /// Enclosed volume.
    var volume: Float { 8 * halfExtents.x * halfExtents.y * halfExtents.z }

    /// The 8 corners. Corner i uses sign bit 0 for axis 0, bit 1 for axis 1, bit 2 for
    /// axis 2 (bit set means the positive side).
    var corners: [SIMD3<Float>] {
        (0..<8).map { i in
            let s = SIMD3<Float>(i & 1 == 0 ? -1 : 1, i & 2 == 0 ? -1 : 1, i & 4 == 0 ? -1 : 1)
            return center + axes * (s * halfExtents)
        }
    }

    /// True when `p` is inside the box or within `tolerance` of its faces.
    func contains(_ p: SIMD3<Float>, tolerance: Float = OrientedBox.containsTolerance) -> Bool {
        let local = simd_mul(simd_transpose(axes), p - center)
        return all(simd_abs(local) .<= halfExtents + tolerance)
    }

    /// Tight box around `points` along the given right-handed orthonormal axes.
    static func enclosing(_ points: [SIMD3<Float>], axes: simd_float3x3) -> OrientedBox? {
        guard let reference = points.first else { return nil }
        let toLocal = simd_transpose(axes)
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for p in points {
            let local = simd_mul(toLocal, p - reference)
            lo = simd_min(lo, local)
            hi = simd_max(hi, local)
        }
        guard all(lo .<= hi) else { return nil }
        let mid = (lo + hi) * 0.5
        return OrientedBox(center: reference + simd_mul(axes, mid), axes: axes, halfExtents: (hi - lo) * 0.5)
    }

    /// Fits a box around `points`.
    ///
    /// Gravity aligned: axis 1 is world up (0, 1, 0); axis 0 and axis 2 come from the
    /// minimum-area rectangle of the XZ projection, so the footprint is tight.
    ///
    /// Free: PCA gives three candidate "height" axes; for each, the minimum-area rectangle
    /// of the projection on the other two eigenvectors sets the remaining axes, and the
    /// smallest-volume candidate wins. This recovers any box whose extents are not all
    /// equal; it is a fast approximation, not the global minimum-volume box.
    ///
    /// Nil for an empty set or non-finite points.
    static func fit(_ points: [SIMD3<Float>], gravityAligned: Bool) -> OrientedBox? {
        guard !points.isEmpty else { return nil }
        for p in points where !(p.x.isFinite && p.y.isFinite && p.z.isFinite) {
            return nil
        }
        if gravityAligned {
            let flat = points.map { SIMD2<Float>($0.x, $0.z) }
            guard let rect = Rectangle2D.minimumArea(enclosing: flat) else { return nil }
            let up = SIMD3<Float>(0, 1, 0)
            let first = SIMD3<Float>(rect.axis.x, 0, rect.axis.y)
            return enclosing(points, axes: simd_float3x3(first, up, simd_cross(first, up)))
        }

        guard let stats = SymmetricEigen3.covariance(of: points) else { return nil }
        let eigen = SymmetricEigen3.decompose(stats.covariance).vectors
        let basis = [eigen.columns.0, eigen.columns.1, eigen.columns.2]
        var best: OrientedBox?
        for height in 0..<3 {
            let b1 = basis[(height + 1) % 3]
            let b2 = basis[(height + 2) % 3]
            let flat = points.map { p -> SIMD2<Float> in
                let r = p - stats.mean
                return SIMD2<Float>(simd_dot(r, b1), simd_dot(r, b2))
            }
            guard let rect = Rectangle2D.minimumArea(enclosing: flat) else { continue }
            let first = simd_normalize(b1 * rect.axis.x + b2 * rect.axis.y)
            let second = simd_normalize(b1 * -rect.axis.y + b2 * rect.axis.x)
            let axes = simd_float3x3(first, second, simd_cross(first, second))
            if let box = enclosing(points, axes: axes), best.map({ box.volume < $0.volume }) ?? true {
                best = box
            }
        }
        return best
    }
}

/// An axis-aligned 3D box. `empty` has inverted bounds so any union or expand fixes it.
struct AABB3: Equatable {
    /// Lowest corner.
    var min: SIMD3<Float>
    /// Highest corner.
    var max: SIMD3<Float>

    /// The empty box (min = +infinity, max = -infinity).
    static let empty = AABB3(min: SIMD3<Float>(repeating: .infinity), max: SIMD3<Float>(repeating: -.infinity))

    /// Creates a box from its corners.
    init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// Smallest box containing all `points`; `empty` for none.
    init<S: Sequence>(points: S) where S.Element == SIMD3<Float> {
        self = .empty
        for p in points {
            expand(p)
        }
    }

    /// True when the box holds no points.
    var isEmpty: Bool { any(min .> max) }

    /// Center point; zero for an empty box.
    var center: SIMD3<Float> { isEmpty ? .zero : (min + max) * 0.5 }

    /// Size along each axis; zero for an empty box.
    var size: SIMD3<Float> { isEmpty ? .zero : max - min }

    /// Smallest box containing both boxes.
    func union(_ other: AABB3) -> AABB3 {
        AABB3(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }

    /// Grows the box to include `p`.
    mutating func expand(_ p: SIMD3<Float>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    /// The box grown by `margin` on every side (shrunk for negative margins).
    func expanded(by margin: Float) -> AABB3 {
        isEmpty ? self : AABB3(min: min - margin, max: max + margin)
    }

    /// True when `p` is inside or on the boundary.
    func contains(_ p: SIMD3<Float>) -> Bool {
        all(p .>= min) && all(p .<= max)
    }
}
