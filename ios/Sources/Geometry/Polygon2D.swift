import Foundation
import simd

/// A closed 2D ring of points (the last point connects back to the first), used for floor
/// plan outlines on the XZ plane. Points are not repeated at the end. Counter-clockwise
/// rings have positive signed area.
struct Polygon2D: Equatable {
    /// Ring vertices in order, without a closing duplicate.
    var points: [SIMD2<Float>]

    /// Areas and lengths below this are treated as zero.
    static let epsilon: Float = 1e-9
    /// Default cap on how far a miter corner may reach, as a multiple of the offset distance.
    static let defaultMiterLimit: Float = 4

    /// Creates a ring from its vertices.
    init(points: [SIMD2<Float>]) {
        self.points = points
    }

    /// Shoelace area: positive for counter-clockwise rings, negative for clockwise.
    var signedArea: Float {
        guard points.count >= 3 else { return 0 }
        var sum: Float = 0
        var previous = points[points.count - 1]
        for current in points {
            sum += previous.x * current.y - current.x * previous.y
            previous = current
        }
        return sum * 0.5
    }

    /// Enclosed area, always non-negative.
    var area: Float { abs(signedArea) }

    /// Length of the closed outline, including the closing edge.
    var perimeter: Float {
        guard points.count >= 2 else { return 0 }
        var sum: Float = 0
        var previous = points[points.count - 1]
        for current in points {
            sum += simd_distance(previous, current)
            previous = current
        }
        return sum
    }

    /// Area centroid. Falls back to the vertex average for degenerate (zero-area) rings,
    /// and to the origin for an empty ring.
    var centroid: SIMD2<Float> {
        guard !points.isEmpty else { return .zero }
        let a = signedArea
        if abs(a) <= Polygon2D.epsilon {
            return points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        }
        // Shift to the first vertex to keep the products small for far-from-origin rings.
        let origin = points[0]
        var c = SIMD2<Float>.zero
        var previous = points[points.count - 1] - origin
        for point in points {
            let current = point - origin
            let cross = previous.x * current.y - current.x * previous.y
            c += (previous + current) * cross
            previous = current
        }
        return origin + c / (6 * a)
    }

    /// True when the vertices run clockwise (negative signed area).
    var isClockwise: Bool { signedArea < 0 }

    /// Even-odd point-in-polygon test. Points exactly on an edge may go either way.
    func contains(point: SIMD2<Float>) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let pi = points[i]
            let pj = points[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let xCross = pj.x + (point.y - pj.y) / (pi.y - pj.y) * (pi.x - pj.x)
                if point.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Axis-aligned bounds of the vertices, or nil for an empty ring.
    var boundingBox: (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let first = points.first else { return nil }
        var lo = first
        var hi = first
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// Douglas-Peucker simplification of the closed ring: removes vertices closer than
    /// `tolerance` to the simplified outline. The ring is split at vertex 0 and the vertex
    /// farthest from it, so both anchors are always kept. Returns self when fewer than
    /// 4 points or when simplification would leave fewer than 3.
    func simplified(tolerance: Float) -> Polygon2D {
        let n = points.count
        guard n >= 4, tolerance > 0 else { return self }
        var far = 0
        var farDistance: Float = -1
        for i in 1..<n {
            let d = simd_distance_squared(points[0], points[i])
            if d > farDistance {
                farDistance = d
                far = i
            }
        }
        guard far > 0 else { return self }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[far] = true
        // Each range is (start, end) over indices modulo n; end may exceed n - 1.
        var ranges: [(Int, Int)] = [(0, far), (far, n)]
        while let range = ranges.popLast() {
            let (start, end) = range
            guard end - start >= 2 else { continue }
            let segment = Segment2D(a: points[start % n], b: points[end % n])
            var worst = -1
            var worstDistance: Float = tolerance
            for k in (start + 1)..<end {
                let d = segment.distance(to: points[k % n])
                if d > worstDistance {
                    worstDistance = d
                    worst = k
                }
            }
            if worst >= 0 {
                keep[worst % n] = true
                ranges.append((start, worst))
                ranges.append((worst, end))
            }
        }
        var result: [SIMD2<Float>] = []
        for i in 0..<n where keep[i] {
            result.append(points[i])
        }
        return result.count >= 3 ? Polygon2D(points: result) : self
    }

    /// Convex hull by Andrew's monotone chain, counter-clockwise, collinear points removed.
    /// Fewer than 3 distinct input points give a ring with those distinct points.
    static func convexHull(_ input: [SIMD2<Float>]) -> Polygon2D {
        let sorted = input.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        var unique: [SIMD2<Float>] = []
        unique.reserveCapacity(sorted.count)
        for p in sorted where unique.last != p {
            unique.append(p)
        }
        guard unique.count >= 3 else { return Polygon2D(points: unique) }

        func turn(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var hull: [SIMD2<Float>] = []
        hull.reserveCapacity(unique.count + 1)
        for p in unique {
            while hull.count >= 2 && turn(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        let lowerCount = hull.count + 1
        for p in unique.reversed().dropFirst() {
            while hull.count >= lowerCount && turn(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }
        hull.removeLast()
        return Polygon2D(points: hull)
    }

    /// Offsets the outline by `distance` (positive grows the ring outward, negative shrinks
    /// it) with miter joins. A corner whose miter would reach farther than
    /// `miterLimit * |distance|` is beveled into two points. Meant for simple convex or mildly
    /// concave rings; large negative offsets of concave rings can self-intersect.
    func offset(by distance: Float, miterLimit: Float = Polygon2D.defaultMiterLimit) -> Polygon2D {
        // Drop consecutive duplicates so every edge has a direction.
        var ring: [SIMD2<Float>] = []
        for p in points where ring.last.map({ simd_distance($0, p) > Polygon2D.epsilon }) ?? true {
            ring.append(p)
        }
        if ring.count >= 2, let first = ring.first, let last = ring.last,
           simd_distance(first, last) <= Polygon2D.epsilon {
            ring.removeLast()
        }
        let n = ring.count
        guard n >= 3, distance != 0 else { return Polygon2D(points: ring) }

        // Outward normal of edge direction u: right side for CCW rings, left side for CW.
        let sign: Float = Polygon2D(points: ring).signedArea >= 0 ? 1 : -1
        func outwardNormal(_ from: SIMD2<Float>, _ to: SIMD2<Float>) -> SIMD2<Float> {
            let u = simd_normalize(to - from)
            return SIMD2<Float>(u.y, -u.x) * sign
        }
        let limit = max(miterLimit, 1)
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(n * 2)
        for i in 0..<n {
            let prev = ring[(i + n - 1) % n]
            let current = ring[i]
            let next = ring[(i + 1) % n]
            let n1 = outwardNormal(prev, current)
            let n2 = outwardNormal(current, next)
            let sum = n1 + n2
            let sumLength = simd_length(sum)
            if sumLength <= Polygon2D.epsilon {
                // The ring doubles back on itself here; square off the spike.
                result.append(current + n1 * distance)
                result.append(current + n2 * distance)
                continue
            }
            let miter = sum / sumLength
            let cosHalf = simd_dot(miter, n1)
            if cosHalf <= Polygon2D.epsilon || 1 / cosHalf > limit {
                result.append(current + n1 * distance)
                result.append(current + n2 * distance)
            } else {
                result.append(current + miter * (distance / cosHalf))
            }
        }
        return Polygon2D(points: result)
    }

    /// The part of the ring on the left of the directed line through `a` and `b` (points on
    /// the line count as inside): Sutherland-Hodgman against one half-plane (CR-1, used by
    /// RoomModel and FloorPlan to split rooms with the same arithmetic). The ring keeps its
    /// winding. For a concave ring cut into several pieces the result is one ring whose pieces
    /// are joined along the line by zero-width edges; its area is still the area of the
    /// pieces. Empty when nothing is on the left, when `a == b`, or when the ring has fewer
    /// than 3 points.
    func clipped(leftOf a: SIMD2<Float>, _ b: SIMD2<Float>) -> Polygon2D {
        let direction = b - a
        guard points.count >= 3, direction != .zero else { return Polygon2D(points: []) }
        /// Twice the signed area of (a, b, p): positive on the left of a -> b, zero on the line.
        func side(_ p: SIMD2<Float>) -> Float {
            direction.x * (p.y - a.y) - direction.y * (p.x - a.x)
        }
        let sides = points.map(side)
        guard sides.contains(where: { $0 > 0 }) else { return Polygon2D(points: []) }
        if sides.allSatisfy({ $0 >= 0 }) { return self }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(points.count + 2)
        var previous = points[points.count - 1]
        var previousSide = sides[points.count - 1]
        for (i, current) in points.enumerated() {
            let currentSide = sides[i]
            let crosses = (previousSide > 0 && currentSide < 0) || (previousSide < 0 && currentSide > 0)
            if crosses {
                let t: Float = previousSide / (previousSide - currentSide)
                let crossing: SIMD2<Float> = previous + (current - previous) * t
                if result.last != crossing { result.append(crossing) }
            }
            if currentSide >= 0 && result.last != current {
                result.append(current)
            }
            previous = current
            previousSide = currentSide
        }
        if result.count >= 2, let first = result.first, result.last == first {
            result.removeLast()
        }
        return result.count >= 3 ? Polygon2D(points: result) : Polygon2D(points: [])
    }
}
