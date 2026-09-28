import Foundation
import simd

/// Plain-Swift checks for the geometry module (no XCTest), run at launch like the units
/// self-test. `run()` returns one line per failing case; empty means all passed.
enum GeometrySelfTest {
    /// Deterministic random numbers (SplitMix64) so failures reproduce.
    private struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [lo, hi).
        mutating func float(_ lo: Float, _ hi: Float) -> Float {
            lo + (hi - lo) * Float(next() >> 40) / Float(1 << 24)
        }

        mutating func vector(_ lo: Float, _ hi: Float) -> SIMD3<Float> {
            SIMD3<Float>(float(lo, hi), float(lo, hi), float(lo, hi))
        }
    }

    /// Unit cube [0, 1]^3, vertex index x + 2y + 4z, outward counter-clockwise winding.
    /// Triangles 6 and 7 are the top (y = 1) face.
    static let unitCube = TriangleMesh(
        positions: (0..<8).map { SIMD3<Float>(Float($0 & 1), Float(($0 >> 1) & 1), Float(($0 >> 2) & 1)) },
        indices: [0, 6, 2, 0, 4, 6, 1, 3, 7, 1, 7, 5, 0, 1, 5, 0, 5, 4,
                  2, 7, 3, 2, 6, 7, 0, 3, 1, 0, 2, 3, 4, 5, 7, 4, 7, 6])

    /// Collects failing assertions.
    private final class Recorder {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        func near(_ name: String, _ actual: Float?, _ expected: Float, _ tolerance: Float = 1e-5) {
            guard let actual = actual else { return failures.append("\(name): expected \(expected), got nil") }
            if !(abs(actual - expected) <= tolerance) { failures.append("\(name): expected \(expected), got \(actual)") }
        }

        func near2(_ name: String, _ actual: SIMD2<Float>?, _ expected: SIMD2<Float>, _ tolerance: Float = 1e-5) {
            guard let actual = actual else { return failures.append("\(name): expected \(expected), got nil") }
            if !(simd_distance(actual, expected) <= tolerance) { failures.append("\(name): expected \(expected), got \(actual)") }
        }

        func near3(_ name: String, _ actual: SIMD3<Float>?, _ expected: SIMD3<Float>, _ tolerance: Float = 1e-5) {
            guard let actual = actual else { return failures.append("\(name): expected \(expected), got nil") }
            if !(simd_distance(actual, expected) <= tolerance) { failures.append("\(name): expected \(expected), got \(actual)") }
        }
    }

    /// Failing cases as "name: detail".
    static func run() -> [String] {
        let r = Recorder()
        polygonCases(r)
        segmentCases(r)
        eigenAndPlaneCases(r)
        boxCases(r)
        meshCases(r)
        raycastCases(r)
        snapCases(r)
        return r.failures
    }

    private static func polygonCases(_ r: Recorder) {
        let square = Polygon2D(points: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        let clockwise = Polygon2D(points: square.points.reversed())
        let ell = Polygon2D(points: [SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(1, 1), SIMD2(1, 2), SIMD2(0, 2)])
        r.near("polygon.squareArea", square.area, 1, 1e-6)
        r.near("polygon.squareSignedArea", square.signedArea, 1, 1e-6)
        r.near("polygon.clockwiseSignedArea", clockwise.signedArea, -1, 1e-6)
        r.check("polygon.isClockwise", clockwise.isClockwise && !square.isClockwise, "")
        r.near("polygon.perimeter", square.perimeter, 4, 1e-6)
        r.near("polygon.lArea", ell.area, 3, 1e-6)
        r.near2("polygon.lCentroid", ell.centroid, SIMD2(2.5 / 3, 2.5 / 3), 1e-5)
        r.check("polygon.containsInside", ell.contains(point: SIMD2(0.5, 0.5)), "")
        r.check("polygon.containsNotch", !ell.contains(point: SIMD2(1.5, 1.5)), "")
        r.check("polygon.containsOutside", !ell.contains(point: SIMD2(-1, 0.5)), "")
        r.near2("polygon.boundsMin", ell.boundingBox?.min, SIMD2(0, 0), 0)
        r.near2("polygon.boundsMax", ell.boundingBox?.max, SIMD2(2, 2), 0)
        let noisy = Polygon2D(points: [SIMD2(0, 0), SIMD2(1, 0.001), SIMD2(2, 0), SIMD2(2, 1), SIMD2(2, 2), SIMD2(1, 2), SIMD2(0, 2)])
        let simple = noisy.simplified(tolerance: 0.01)
        r.check("polygon.simplifyCount", simple.points.count == 4, "got \(simple.points.count)")
        r.near("polygon.simplifyArea", simple.area, 4, 1e-5)
        r.check("polygon.simplifyKeepsL", ell.simplified(tolerance: 0.01).points.count == 6, "")
        let hull = Polygon2D.convexHull(square.points + [SIMD2(0.5, 0.5), SIMD2(0.5, 0), SIMD2(0.2, 0.7)])
        r.check("polygon.hullCount", hull.points.count == 4, "got \(hull.points.count)")
        r.near("polygon.hullSignedArea", hull.signedArea, 1, 1e-6)
        r.check("polygon.hullCollinear", Polygon2D.convexHull([SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2)]).points.count == 2, "")
        r.near("polygon.offsetOut", square.offset(by: 0.5).area, 4, 1e-5)
        r.near("polygon.offsetOutClockwise", clockwise.offset(by: 0.5).area, 4, 1e-5)
        r.near("polygon.offsetIn", square.offset(by: -0.25).area, 0.25, 1e-5)
        let spike = Polygon2D(points: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 0.5)]).offset(by: 0.1)
        r.check("polygon.offsetMiterLimitBevels", spike.points.count == 4, "got \(spike.points.count)")
    }

    private static func segmentCases(_ r: Recorder) {
        let s = Segment2D(a: SIMD2(0, 0), b: SIMD2(3, 4))
        let axis = Segment2D(a: SIMD2(0, 0), b: SIMD2(2, 0))
        r.near("segment.length", s.length, 5, 1e-6)
        r.near2("segment.direction", s.direction, SIMD2(0.6, 0.8), 1e-6)
        r.near2("segment.closest", axis.closestPoint(to: SIMD2(1, 1)), SIMD2(1, 0), 1e-6)
        r.near2("segment.closestClamped", axis.closestPoint(to: SIMD2(5, 1)), SIMD2(2, 0), 1e-6)
        r.near("segment.distance", axis.distance(to: SIMD2(1, 1)), 1, 1e-6)
        r.near2("segment.cross", Segment2D(a: SIMD2(0, 0), b: SIMD2(2, 2)).intersection(with: Segment2D(a: SIMD2(0, 2), b: SIMD2(2, 0))), SIMD2(1, 1), 1e-5)
        let unit = Segment2D(a: SIMD2(0, 0), b: SIMD2(1, 0))
        r.check("segment.parallelNil", unit.intersection(with: Segment2D(a: SIMD2(0, 1), b: SIMD2(1, 1))) == nil, "")
        r.check("segment.disjointNil", unit.intersection(with: Segment2D(a: SIMD2(2, -1), b: SIMD2(2, 1))) == nil, "")
        r.near2("segment.collinearOverlap", axis.intersection(with: Segment2D(a: SIMD2(1, 0), b: SIMD2(3, 0))), SIMD2(1, 0), 1e-6)
        r.check("segment.collinearDisjoint", unit.intersection(with: Segment2D(a: SIMD2(2, 0), b: SIMD2(3, 0))) == nil, "")
        r.near2("segment.touchEndpoint", unit.intersection(with: Segment2D(a: SIMD2(1, 0), b: SIMD2(1, 1))), SIMD2(1, 0), 1e-6)
        r.near("segment.anglePerpendicular", unit.angle(between: Segment2D(a: SIMD2(5, 5), b: SIMD2(5, 7))), Float.pi / 2, 1e-6)
        r.near("segment.angleOpposite", unit.angle(between: Segment2D(a: SIMD2(1, 0), b: SIMD2(0, 0))), Float.pi, 1e-6)
        r.near("segment.angleParallel", unit.angle(between: Segment2D(a: SIMD2(0, 3), b: SIMD2(4, 3))), 0, 1e-6)
    }

    /// Pure translation matrix.
    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1))
    }

    /// Rotation about a unit axis.
    private static func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }

    private static func eigenAndPlaneCases(_ r: Recorder) {
        let diagonal = SymmetricEigen3.decompose(simd_float3x3(diagonal: SIMD3(3, 1, 2)))
        r.near3("eigen.diagonalValues", diagonal.values, SIMD3(1, 2, 3), 1e-6)
        r.near("eigen.diagonalVector", abs(diagonal.vectors.columns.0.y), 1, 1e-6)
        let q = rotation(0.7, SIMD3(1, 2, 3))
        let m = q * simd_float3x3(diagonal: SIMD3(9, 1, 4)) * q.transpose
        let rotated = SymmetricEigen3.decompose(m)
        r.near3("eigen.rotatedValues", rotated.values, SIMD3(1, 4, 9), 1e-4)
        var residual: Float = 0
        for i in 0..<3 {
            let v = rotated.vectors[i]
            residual = max(residual, simd_length(m * v - rotated.values[i] * v))
        }
        r.near("eigen.rotatedResidual", residual, 0, 1e-4)
        r.near("eigen.rightHanded", simd_determinant(rotated.vectors), 1, 1e-5)
        r.near3("eigen.repeated", SymmetricEigen3.decompose(simd_float3x3(diagonal: SIMD3(2, 2, 2))).values, SIMD3(2, 2, 2), 1e-6)

        let floor = Plane(point: SIMD3(0, 1, 0), normal: SIMD3(0, 2, 0))
        r.near("plane.signedDistance", floor.signedDistance(to: SIMD3(0, 3, 0)), 2, 1e-6)
        r.near3("plane.project", floor.project(SIMD3(5, 3, 7)), SIMD3(5, 1, 7), 1e-6)
        r.near3("plane.ray", floor.intersection(with: Ray(origin: SIMD3(0, 5, 0), direction: SIMD3(0, -2, 0))), SIMD3(0, 1, 0), 1e-6)
        r.check("plane.rayParallel", floor.intersection(with: Ray(origin: SIMD3(0, 5, 0), direction: SIMD3(1, 0, 0))) == nil, "")
        r.check("plane.rayAway", floor.intersection(with: Ray(origin: SIMD3(0, 5, 0), direction: SIMD3(0, 1, 0))) == nil, "")
        let px = Plane(point: SIMD3(1, 0, 0), normal: SIMD3(1, 0, 0))
        let pz = Plane(point: SIMD3(0, 0, 3), normal: SIMD3(0, 0, -1))
        let py = Plane(point: SIMD3(0, 2, 0), normal: SIMD3(0, 1, 0))
        r.near3("plane.threePlanes", Plane.intersection(px, py, pz), SIMD3(1, 2, 3), 1e-5)
        r.check("plane.threePlanesSingular", Plane.intersection(px, floor, py) == nil, "")
        r.near3("plane.throughPoints", Plane(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1))?.normal, SIMD3(0, 1, 0), 1e-6)

        var random = Random(state: 7)
        let trueNormal = simd_normalize(SIMD3<Float>(1, 2, 0.5))
        let truePlane = Plane(point: SIMD3(2, 1, -3), normal: trueNormal)
        let u = simd_normalize(simd_cross(trueNormal, SIMD3(0, 0, 1)))
        let v = simd_cross(trueNormal, u)
        let samples = (0..<500).map { _ -> SIMD3<Float> in
            truePlane.project(SIMD3(2, 1, -3)) + u * random.float(-2, 2) + v * random.float(-2, 2)
                + trueNormal * random.float(-0.001, 0.001)
        }
        let fit = Plane.fit(samples)
        r.near("plane.fitNormal", fit.map { abs(simd_dot($0.plane.normal, trueNormal)) }, 1, 1e-5)
        r.check("plane.fitRms", (fit?.rms ?? 1) < 0.001, "rms \(fit?.rms ?? -1)")
        r.near("plane.fitOffset", fit.map { abs($0.plane.signedDistance(to: SIMD3(2, 1, -3))) }, 0, 5e-4)
        r.check("plane.fitCollinearNil", Plane.fit([SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(2, 2, 2), SIMD3(3, 3, 3)]) == nil, "")
        r.check("plane.fitTooFewNil", Plane.fit([SIMD3(0, 0, 0), SIMD3(1, 0, 0)]) == nil, "")
    }

    private static func boxCases(_ r: Recorder) {
        let half = SIMD3<Float>(0.5, 1.0, 2.0)
        let center = SIMD3<Float>(1, 2, 3)
        let truth = OrientedBox(center: center, axes: rotation(0.9, SIMD3(0.3, -1, 0.6)), halfExtents: half)
        let fitted = OrientedBox.fit(truth.corners, gravityAligned: false)
        let sortedHalf = fitted.map { h -> SIMD3<Float> in
            let s = [h.halfExtents.x, h.halfExtents.y, h.halfExtents.z].sorted()
            return SIMD3(s[0], s[1], s[2])
        }
        r.near3("obb.freeExtents", sortedHalf, half, 1e-3)
        r.near3("obb.freeCenter", fitted?.center, center, 1e-3)
        r.near("obb.freeVolume", fitted?.volume, 8, 1e-2)

        let yawed = OrientedBox(center: center, axes: rotation(0.52, SIMD3(0, 1, 0)), halfExtents: half)
        let upright = OrientedBox.fit(yawed.corners, gravityAligned: true)
        r.near("obb.gravityHeight", upright?.halfExtents.y, 1.0, 1e-3)
        r.near("obb.gravityFootprint", upright.map { $0.halfExtents.x * $0.halfExtents.z }, 1.0, 1e-3)
        r.near3("obb.gravityUpAxis", upright?.axes.columns.1, SIMD3(0, 1, 0), 0)
        r.check("obb.containsCenter", truth.contains(center) && !truth.contains(center + SIMD3(0, 0, 5)), "")
        r.check("obb.cornersContained", truth.corners.count == 8 && truth.corners.allSatisfy { truth.contains($0) }, "")
        r.check("obb.emptyNil", OrientedBox.fit([], gravityAligned: true) == nil, "")

        let diamond = [SIMD2<Float>(0, -1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)]
        r.near("rect.diamondArea", Rectangle2D.minimumArea(enclosing: diamond)?.area, 2, 1e-5)

        var box = AABB3.empty
        r.check("aabb.emptyIsEmpty", box.isEmpty && box.size == .zero, "")
        box.expand(SIMD3(1, 2, 3))
        box.expand(SIMD3(-1, 0, 1))
        r.near3("aabb.center", box.center, SIMD3(0, 1, 2), 0)
        r.near3("aabb.size", box.size, SIMD3(2, 2, 2), 0)
        let joined = box.union(AABB3(min: SIMD3(5, 5, 5), max: SIMD3(6, 6, 6)))
        r.near3("aabb.unionMax", joined.max, SIMD3(6, 6, 6), 0)
        r.check("aabb.contains", joined.contains(SIMD3(3, 3, 3)) && !box.contains(SIMD3(3, 3, 3)), "")
    }

    private static func meshCases(_ r: Recorder) {
        let cube = unitCube
        r.check("mesh.cubeTriangles", cube.triangleCount == 12, "")
        r.check("mesh.cubeWatertight", cube.isWatertight, "")
        r.near("mesh.cubeVolume", cube.signedVolume, 1, 1e-6)
        r.near("mesh.cubeArea", cube.surfaceArea, 6, 1e-6)
        r.near3("mesh.cubeBoundsMax", cube.boundingBox.max, SIMD3(1, 1, 1), 0)
        var open = cube
        open.indices.removeSubrange(18..<24)
        r.check("mesh.openNotWatertight", !open.isWatertight, "")
        r.check("mesh.openBoundaryEdges", open.boundaryEdges.count == 4, "got \(open.boundaryEdges.count)")
        r.check("mesh.closedNoBoundary", cube.boundaryEdges.isEmpty, "")

        let quad = TriangleMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                indices: [0, 1, 2, 0, 2, 3])
        r.check("mesh.quadNormals", quad.vertexNormals.allSatisfy { simd_distance($0, SIMD3(0, 0, 1)) < 1e-6 }, "")
        let moved = cube.transformed(by: translation(SIMD3(10, 0, 0)))
        r.near("mesh.translatedVolume", moved.signedVolume, 1, 1e-4)
        r.near3("mesh.translatedBounds", moved.boundingBox.min, SIMD3(10, 0, 0), 0)
        let mirrored = cube.transformed(by: simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1)))
        r.near("mesh.mirroredVolumePositive", mirrored.signedVolume, 1, 1e-6)
        let both = cube.merged(with: moved)
        r.check("mesh.merged", both.triangleCount == 24 && both.positions.count == 16 && both.isWatertight, "")
        r.near("mesh.mergedVolume", both.signedVolume, 2, 1e-4)

        var soup = TriangleMesh()
        for t in 0..<cube.triangleCount {
            for k in 0..<3 {
                soup.positions.append(cube.positions[Int(cube.indices[3 * t + k])] + SIMD3(repeating: Float(k) * 1e-6))
                soup.indices.append(UInt32(soup.positions.count - 1))
            }
        }
        r.check("mesh.soupNotWatertight", !soup.isWatertight, "")
        let welded = soup.welded(tolerance: 1e-4)
        r.check("mesh.weldVertices", welded.positions.count == 8, "got \(welded.positions.count)")
        r.check("mesh.weldWatertight", welded.isWatertight && welded.triangleCount == 12, "")
    }

    private static func raycastCases(_ r: Recorder) {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, 0), c = SIMD3<Float>(0, 1, 0)
        let down = SIMD3<Float>(0, 0, -1)
        r.near("ray.triangleHit", TriangleQuery.intersect(origin: SIMD3(0.2, 0.2, 1), direction: down, a, b, c, minDistance: 0, maxDistance: 10)?.t, 1, 1e-6)
        r.check("ray.triangleMiss", TriangleQuery.intersect(origin: SIMD3(0.8, 0.8, 1), direction: down, a, b, c, minDistance: 0, maxDistance: 10) == nil, "")
        r.check("ray.triangleParallel", TriangleQuery.intersect(origin: SIMD3(0.2, 0.2, 1), direction: SIMD3(1, 0, 0), a, b, c, minDistance: 0, maxDistance: 10) == nil, "")
        r.near3("tri.closestVertex", TriangleQuery.closestPoint(to: SIMD3(-1, -1, 0), a, b, c), a, 1e-6)
        r.near3("tri.closestEdge", TriangleQuery.closestPoint(to: SIMD3(1, 1, 0), a, b, c), SIMD3(0.5, 0.5, 0), 1e-6)
        r.near3("tri.closestFace", TriangleQuery.closestPoint(to: SIMD3(0.2, 0.3, 5), a, b, c), SIMD3(0.2, 0.3, 0), 1e-6)

        let cubeTree = MeshBVH(mesh: unitCube)
        let out = cubeTree.raycast(Ray(origin: SIMD3(0.3, 0.5, 0.6), direction: SIMD3(0, 3, 0)), maxDistance: 10)
        r.near("bvh.cubeInsideHit", out?.distance, 0.5, 1e-6)
        r.near3("bvh.cubeNormal", out?.normal, SIMD3(0, 1, 0), 1e-6)
        r.check("bvh.emptyNil", MeshBVH(mesh: TriangleMesh()).raycast(Ray(origin: .zero, direction: down), maxDistance: 10) == nil, "")

        var random = Random(state: 42)
        var soup = TriangleMesh()
        for t in 0..<10_000 {
            let center = random.vector(-10, 10)
            for _ in 0..<3 {
                soup.positions.append(center + random.vector(-0.5, 0.5))
            }
            soup.indices.append(contentsOf: [UInt32(3 * t), UInt32(3 * t + 1), UInt32(3 * t + 2)])
        }
        let tree = MeshBVH(mesh: soup)
        r.check("bvh.allTrianglesIndexed", tree.triangleCount == 10_000, "")
        var rayMismatches = 0, hits = 0
        for i in 0..<200 {
            let origin = random.vector(-12, 12)
            var direction = random.vector(-1, 1)
            if i % 10 == 0 { direction = SIMD3(0, 0, 1) }
            let unit = simd_normalize(direction)
            var best: Float = 100
            var found = false
            for t in 0..<soup.triangleCount {
                guard let corners = soup.triangle(t) else { continue }
                if let hit = TriangleQuery.intersect(origin: origin, direction: unit, corners.0, corners.1, corners.2,
                                                     minDistance: MeshBVH.minimumHitDistance, maxDistance: best) {
                    best = hit.t
                    found = true
                }
            }
            let fast = tree.raycast(Ray(origin: origin, direction: direction), maxDistance: 100)
            if found { hits += 1 }
            if found != (fast != nil) || (found && abs((fast?.distance ?? 0) - best) > 1e-5) { rayMismatches += 1 }
        }
        r.check("bvh.raycastMatchesBruteForce", rayMismatches == 0, "\(rayMismatches) of 200 rays differ")
        r.check("bvh.raycastHitsSome", hits > 20, "only \(hits) hits")

        var nearMismatches = 0
        for i in 0..<100 {
            let p = random.vector(-12, 12)
            let limit: Float = i % 2 == 0 ? .infinity : 0.5
            var best = Float.infinity
            for t in 0..<soup.triangleCount {
                guard let corners = soup.triangle(t) else { continue }
                best = min(best, simd_distance(p, TriangleQuery.closestPoint(to: p, corners.0, corners.1, corners.2)))
            }
            let fast = tree.nearestPoint(to: p, maxDistance: limit)
            if best > limit {
                if fast != nil { nearMismatches += 1 }
            } else if abs((fast?.distance ?? .infinity) - best) > 1e-5 {
                nearMismatches += 1
            }
        }
        r.check("bvh.nearestMatchesBruteForce", nearMismatches == 0, "\(nearMismatches) of 100 points differ")
        r.check("bvh.nearestOutOfRangeNil", cubeTree.nearestPoint(to: SIMD3(5, 5, 5), maxDistance: 1) == nil, "")
        r.near("bvh.nearestCube", cubeTree.nearestPoint(to: SIMD3(0.5, 3, 0.5), maxDistance: 10)?.distance, 2, 1e-6)
    }

    private static func snapCases(_ r: Recorder) {
        let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let hit = Snap.toCorner(SIMD3(0.99, 0.01, 0), corners: corners, radius: 0.03)
        r.check("snap.corner", hit.target == .corner(1) && hit.point == corners[1], "\(hit.target)")
        r.check("snap.cornerOutOfRadius", Snap.toCorner(SIMD3(0.5, 0, 0), corners: corners, radius: 0.03).target == .none, "")
        let edges = [(SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 2, 0))]
        let onEdge = Snap.toEdge(SIMD3(0.01, 1, 0), edges: edges, radius: 0.02)
        r.check("snap.edge", onEdge.target == .edge(0), "\(onEdge.target)")
        r.near3("snap.edgePoint", onEdge.point, SIMD3(0, 1, 0), 1e-6)
        r.check("snap.edgeOutOfRadius", Snap.toEdge(SIMD3(0.05, 1, 0), edges: edges, radius: 0.02).target == .none, "")
        let planes = [Plane(point: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0)), Plane(point: SIMD3(0, 3, 0), normal: SIMD3(0, 1, 0))]
        let onPlane = Snap.toPlane(SIMD3(4, 2.97, 1), planes: planes, radius: 0.05)
        r.check("snap.plane", onPlane.target == .plane(1), "\(onPlane.target)")
        r.near3("snap.planePoint", onPlane.point, SIMD3(4, 3, 1), 1e-5)
        let prefer = Snap.best(SIMD3(0.01, 0.01, 0), corners: corners, edges: edges, planes: planes)
        r.check("snap.cornerBeatsEdge", prefer.target == .corner(0), "\(prefer.target)")
        let none = Snap.best(SIMD3(5, 1.5, 5), corners: corners, edges: edges, planes: planes)
        r.check("snap.none", none.target == .none && none.point == SIMD3(5, 1.5, 5), "")
    }
}
