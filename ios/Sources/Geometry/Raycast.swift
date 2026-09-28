import Foundation
import simd

/// A half-line from `origin` along `direction`. The direction need not be unit length;
/// queries that report distances normalize it first.
struct Ray: Equatable {
    /// Start point.
    var origin: SIMD3<Float>
    /// Direction of travel.
    var direction: SIMD3<Float>

    /// Creates a ray.
    init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        self.origin = origin
        self.direction = direction
    }

    /// The point `origin + direction * t`.
    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

/// Single-triangle queries shared by the BVH and brute-force checks.
enum TriangleQuery {
    /// Determinants below this mean the ray is parallel to the triangle plane.
    static let parallelEpsilon: Float = 1e-12

    /// Moller-Trumbore ray-triangle intersection, two-sided (back faces hit too).
    /// Returns the ray parameter `t` (a distance when `direction` is unit length) and the
    /// barycentric weights `u` (of b) and `v` (of c), for hits with
    /// `minDistance <= t <= maxDistance`.
    @inline(__always)
    static func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>,
                          _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                          minDistance: Float, maxDistance: Float) -> (t: Float, u: Float, v: Float)? {
        let e1 = b - a
        let e2 = c - a
        let p = simd_cross(direction, e2)
        let det = simd_dot(e1, p)
        guard abs(det) >= parallelEpsilon else { return nil }
        let inv = 1 / det
        let s = origin - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(direction, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        guard t >= minDistance, t <= maxDistance else { return nil }
        return (t, u, v)
    }

    /// Point of triangle (a, b, c) nearest to `p`, by Voronoi region classification
    /// (Ericson, Real-Time Collision Detection, 5.1.5). Handles degenerate triangles.
    @inline(__always)
    static func closestPoint(to p: SIMD3<Float>,
                             _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = p - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }
        let sum = va + vb + vc
        guard sum > 0 else { return a }
        let denom = 1 / sum
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    /// Unit geometric normal of (a, b, c) following the winding; zero if degenerate.
    static func normal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let length = simd_length(n)
        return length > 0 ? n / length : .zero
    }
}

/// Bounding volume hierarchy over a triangle mesh for raycasts and nearest-point queries.
///
/// Flat arrays only: nodes are 32-byte structs in one array, children of a node are stored
/// next to each other, and leaves reference a range of a triangle order array. Built top
/// down with binned SAH (12 bins, all three axes), O(n log n); leaves hold at most 4
/// triangles unless the depth cap is reached. Traversal is iterative with a fixed stack
/// allocated on the call stack, so queries do not touch the heap. Triangles with
/// out-of-range indices or non-finite corners are left out. Immutable after init, so
/// queries are safe from several threads at once.
final class MeshBVH {
    /// One tree node. `count > 0` marks a leaf holding triangles
    /// `order[leftOrFirst ..< leftOrFirst + count]`; otherwise the children are nodes
    /// `leftOrFirst` and `leftOrFirst + 1`.
    struct Node {
        var minX: Float, minY: Float, minZ: Float
        var maxX: Float, maxY: Float, maxZ: Float
        var leftOrFirst: UInt32
        var count: UInt32

        /// Lower corner of the node bounds.
        var boundsMin: SIMD3<Float> { SIMD3<Float>(minX, minY, minZ) }
        /// Upper corner of the node bounds.
        var boundsMax: SIMD3<Float> { SIMD3<Float>(maxX, maxY, maxZ) }
    }

    /// Target triangles per leaf.
    static let maxLeafSize = 4
    /// SAH bins per axis.
    static let binCount = 12
    /// Deepest level the builder creates; keeps the traversal stack bounded.
    static let maxDepth = 60
    /// Traversal stack slots (depth cap plus headroom).
    static let stackCapacity = 64
    /// Hits closer than this to the ray origin are ignored (avoids self-hits).
    static let minimumHitDistance: Float = 1e-6
    /// Relative widening of slab exits so rounding never culls a box the ray grazes.
    static let slabPadding: Float = 1 + 1e-6
    /// Zero ray direction components are replaced by this (with sign) before inverting.
    static let tinyDirection: Float = 1e-20

    /// Tree nodes; index 0 is the root. Empty when the mesh has no valid triangles.
    let nodes: [Node]
    /// Triangle ids in leaf order.
    let order: [UInt32]
    /// Vertex positions of the source mesh.
    let positions: [SIMD3<Float>]
    /// Triangle indices of the source mesh.
    let indices: [UInt32]

    /// Number of triangles in the tree.
    var triangleCount: Int { order.count }

    /// Builds the hierarchy for `mesh`.
    init(mesh: TriangleMesh) {
        positions = mesh.positions
        indices = mesh.indices
        let build = MeshBVHBuilder.build(mesh)
        nodes = build.nodes
        order = build.order
    }

    /// Nearest hit along `ray` within `maxDistance` (measured along the normalized
    /// direction). Returns the distance, the triangle id in the source mesh, the hit point
    /// and the triangle's unit geometric normal (following its winding, not flipped toward
    /// the ray). Nil when nothing is hit or the direction is zero.
    func raycast(_ ray: Ray, maxDistance: Float) -> (distance: Float, triangle: Int, point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard !nodes.isEmpty, maxDistance > 0 else { return nil }
        let length = simd_length(ray.direction)
        guard length > 0, length.isFinite else { return nil }
        let origin = ray.origin
        let direction = ray.direction / length
        let safe = SIMD3<Float>(
            direction.x == 0 ? Float(signOf: direction.x, magnitudeOf: MeshBVH.tinyDirection) : direction.x,
            direction.y == 0 ? Float(signOf: direction.y, magnitudeOf: MeshBVH.tinyDirection) : direction.y,
            direction.z == 0 ? Float(signOf: direction.z, magnitudeOf: MeshBVH.tinyDirection) : direction.z)
        let inverse = 1 / safe
        var best = maxDistance
        var bestTriangle = -1

        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: MeshBVH.stackCapacity) { (stack: UnsafeMutableBufferPointer<UInt32>) -> Void in
            guard MeshBVH.slabEntry(nodes[0], origin, inverse, best) < .infinity else { return }
            stack[0] = 0
            var top = 1
            while top > 0 {
                top -= 1
                let node = nodes[Int(stack[top])]
                if MeshBVH.slabEntry(node, origin, inverse, best) == .infinity { continue }
                if node.count > 0 {
                    let first = Int(node.leftOrFirst)
                    for k in first..<(first + Int(node.count)) {
                        let t = Int(order[k])
                        let a = positions[Int(indices[3 * t])]
                        let b = positions[Int(indices[3 * t + 1])]
                        let c = positions[Int(indices[3 * t + 2])]
                        if let hit = TriangleQuery.intersect(origin: origin, direction: direction, a, b, c,
                                                             minDistance: MeshBVH.minimumHitDistance,
                                                             maxDistance: best) {
                            best = hit.t
                            bestTriangle = t
                        }
                    }
                    continue
                }
                var near = Int(node.leftOrFirst)
                var far = near + 1
                var nearT = MeshBVH.slabEntry(nodes[near], origin, inverse, best)
                var farT = MeshBVH.slabEntry(nodes[far], origin, inverse, best)
                if nearT > farT {
                    swap(&near, &far)
                    swap(&nearT, &farT)
                }
                // Depth <= maxDepth keeps top <= maxDepth + 1 < stackCapacity.
                if farT < .infinity {
                    stack[top] = UInt32(far)
                    top += 1
                }
                if nearT < .infinity {
                    stack[top] = UInt32(near)
                    top += 1
                }
            }
        }

        guard bestTriangle >= 0 else { return nil }
        let a = positions[Int(indices[3 * bestTriangle])]
        let b = positions[Int(indices[3 * bestTriangle + 1])]
        let c = positions[Int(indices[3 * bestTriangle + 2])]
        return (best, bestTriangle, origin + direction * best, TriangleQuery.normal(a, b, c))
    }

    /// Closest point on the mesh surface to `p` within `maxDistance` (pass `.infinity` for
    /// no limit). Returns the point, its triangle id and the distance; nil when no
    /// triangle is that close.
    func nearestPoint(to p: SIMD3<Float>, maxDistance: Float) -> (point: SIMD3<Float>, triangle: Int, distance: Float)? {
        guard !nodes.isEmpty, maxDistance >= 0 else { return nil }
        var bestSquared = maxDistance * maxDistance
        var bestPoint = p
        var bestTriangle = -1

        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: MeshBVH.stackCapacity) { (stack: UnsafeMutableBufferPointer<UInt32>) -> Void in
            guard MeshBVH.boxDistanceSquared(nodes[0], p) <= bestSquared else { return }
            stack[0] = 0
            var top = 1
            while top > 0 {
                top -= 1
                let node = nodes[Int(stack[top])]
                if MeshBVH.boxDistanceSquared(node, p) > bestSquared { continue }
                if node.count > 0 {
                    let first = Int(node.leftOrFirst)
                    for k in first..<(first + Int(node.count)) {
                        let t = Int(order[k])
                        let q = TriangleQuery.closestPoint(to: p,
                                                           positions[Int(indices[3 * t])],
                                                           positions[Int(indices[3 * t + 1])],
                                                           positions[Int(indices[3 * t + 2])])
                        let d = simd_distance_squared(p, q)
                        if d <= bestSquared {
                            bestSquared = d
                            bestPoint = q
                            bestTriangle = t
                        }
                    }
                    continue
                }
                var near = Int(node.leftOrFirst)
                var far = near + 1
                var nearD = MeshBVH.boxDistanceSquared(nodes[near], p)
                var farD = MeshBVH.boxDistanceSquared(nodes[far], p)
                if nearD > farD {
                    swap(&near, &far)
                    swap(&nearD, &farD)
                }
                if farD <= bestSquared {
                    stack[top] = UInt32(far)
                    top += 1
                }
                if nearD <= bestSquared {
                    stack[top] = UInt32(near)
                    top += 1
                }
            }
        }

        guard bestTriangle >= 0 else { return nil }
        return (bestPoint, bestTriangle, bestSquared.squareRoot())
    }

    /// Ray parameter where the ray enters the node box (clamped to 0 when the origin is
    /// inside), or infinity when it misses or enters beyond `limit`.
    @inline(__always)
    private static func slabEntry(_ node: Node, _ origin: SIMD3<Float>, _ inverse: SIMD3<Float>,
                                  _ limit: Float) -> Float {
        let t1 = (node.boundsMin - origin) * inverse
        let t2 = (node.boundsMax - origin) * inverse
        let tNear = simd_reduce_max(simd_min(t1, t2))
        let tFar = simd_reduce_min(simd_max(t1, t2)) * slabPadding
        guard tNear <= tFar, tFar >= 0, tNear <= limit else { return .infinity }
        return Swift.max(tNear, 0)
    }

    /// Squared distance from `p` to the node box (0 inside).
    @inline(__always)
    private static func boxDistanceSquared(_ node: Node, _ p: SIMD3<Float>) -> Float {
        simd_distance_squared(simd_clamp(p, node.boundsMin, node.boundsMax), p)
    }
}
