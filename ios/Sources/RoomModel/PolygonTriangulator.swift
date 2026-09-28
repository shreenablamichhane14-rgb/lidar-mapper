import Foundation
import simd

/// Triangulates simple 2D polygons (floor and ceiling outlines, object footprints). Pure,
/// safe on any queue.
enum PolygonTriangulator {
    /// Points closer than this are treated as duplicates, meters.
    static let duplicateTolerance: Float = 1e-6
    /// Rings with less area than this are degenerate, square meters.
    static let minimumArea: Float = 1e-8

    /// Ear clipping of a simple polygon (either winding); triangle indices into `polygon`, empty on failure.
    /// Every returned triangle is counter-clockwise in the polygon's own coordinates whatever
    /// the input winding (so plan outlines give upward-facing floors). Consecutive duplicate and
    /// collinear points are skipped; a self-intersecting ring that leaves no ear returns empty.
    static func triangulate(_ polygon: [SIMD2<Float>]) -> [UInt32] {
        guard polygon.count >= 3, polygon.count < Int(UInt32.max) else { return [] }
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var ring: [Int] = []
        ring.reserveCapacity(polygon.count)
        for i in polygon.indices {
            if let last = ring.last, simd_distance(polygon[last], polygon[i]) <= duplicateTolerance { continue }
            ring.append(i)
        }
        if ring.count > 1, let first = ring.first, let last = ring.last,
           simd_distance(polygon[first], polygon[last]) <= duplicateTolerance {
            ring.removeLast()
        }
        guard ring.count >= 3 else { return [] }
        let signed = Polygon2D(points: ring.map { polygon[$0] }).signedArea
        guard abs(signed) > minimumArea else { return [] }
        if signed < 0 { ring.reverse() }

        var result: [UInt32] = []
        result.reserveCapacity((ring.count - 2) * 3)
        while ring.count > 3 {
            guard let k = nextEar(ring, polygon) else { return [] }
            let m = ring.count
            let prev = ring[(k + m - 1) % m]
            let current = ring[k]
            let next = ring[(k + 1) % m]
            if turn(polygon[prev], polygon[current], polygon[next]) > 0 {
                result.append(contentsOf: [UInt32(prev), UInt32(current), UInt32(next)])
            }
            ring.remove(at: k)
        }
        if turn(polygon[ring[0]], polygon[ring[1]], polygon[ring[2]]) > 0 {
            result.append(contentsOf: [UInt32(ring[0]), UInt32(ring[1]), UInt32(ring[2])])
        }
        return result
    }

    /// Index in `ring` of the next vertex to remove: a collinear vertex (dropped without a
    /// triangle) or a convex ear containing no other ring vertex; nil when there is none.
    private static func nextEar(_ ring: [Int], _ polygon: [SIMD2<Float>]) -> Int? {
        let m = ring.count
        for k in 0..<m {
            let a = polygon[ring[(k + m - 1) % m]]
            let b = polygon[ring[k]]
            let c = polygon[ring[(k + 1) % m]]
            let scale = simd_length(b - a) * simd_length(c - b)
            let cross = turn(a, b, c)
            if abs(cross) <= 1e-6 * scale { return k }
        }
        for k in 0..<m {
            let ia = ring[(k + m - 1) % m]
            let ib = ring[k]
            let ic = ring[(k + 1) % m]
            let a = polygon[ia]
            let b = polygon[ib]
            let c = polygon[ic]
            guard turn(a, b, c) > 0 else { continue }
            var blocked = false
            for other in ring where other != ia && other != ib && other != ic {
                if contains(polygon[other], a, b, c) {
                    blocked = true
                    break
                }
            }
            if !blocked { return k }
        }
        return nil
    }

    /// Twice the signed area of triangle (a, b, c): positive when counter-clockwise.
    static func turn(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        Segment2D.cross(b - a, c - b)
    }

    /// True when `p` lies inside or on counter-clockwise triangle (a, b, c).
    private static func contains(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let tolerance: Float = -1e-9
        let d1 = Segment2D.cross(b - a, p - a)
        let d2 = Segment2D.cross(c - b, p - b)
        let d3 = Segment2D.cross(a - c, p - c)
        return d1 >= tolerance && d2 >= tolerance && d3 >= tolerance
    }

    /// Sum of the areas of the triangles (for checks).
    static func area(of indices: [UInt32], in polygon: [SIMD2<Float>]) -> Float {
        var total: Float = 0
        var t = 0
        while t + 2 < indices.count {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            if i0 < polygon.count, i1 < polygon.count, i2 < polygon.count {
                total += turn(polygon[i0], polygon[i1], polygon[i2]) * 0.5
            }
            t += 3
        }
        return total
    }
}
