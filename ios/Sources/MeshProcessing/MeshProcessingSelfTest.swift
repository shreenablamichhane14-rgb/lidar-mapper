import Foundation
import simd

/// Plain-Swift checks for the mesh processing module (no XCTest), run at launch like the
/// units and geometry self-tests. `run()` returns one line per failing case; empty means
/// all passed. Meshes are small (the largest has 5,120 triangles) so a full run stays well
/// under 3 s on an A15.
enum MeshProcessingSelfTest {
    /// Fewer checks than this means a section stopped early without reporting.
    private static let minimumChecks = 45

    /// Collects failing assertions and counts every check.
    private final class Recorder {
        /// Failure lines, "name: detail".
        var failures: [String] = []
        /// Number of checks run so far.
        var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        /// Records a failure when `actual` is nil or farther than `tolerance` from `expected`.
        func near(_ name: String, _ actual: Float?, _ expected: Float, _ tolerance: Float) {
            count += 1
            guard let actual = actual else { return failures.append("\(name): expected \(expected), got nil") }
            if !(abs(actual - expected) <= tolerance) { failures.append("\(name): expected \(expected), got \(actual)") }
        }
    }

    /// Failing cases as "name: detail".
    static func run() -> [String] {
        let r = Recorder()
        mergeCases(r)
        componentCases(r)
        windingCases(r)
        simplifyCases(r)
        holeCases(r)
        smoothCases(r)
        cropCases(r)
        isolationCases(r)
        if r.failures.isEmpty && r.count < minimumChecks {
            r.failures.append("selfTest: only \(r.count) cases ran")
        }
        return r.failures
    }

    /// One log line: "mesh processing self-test: all passed" or the failures joined.
    static func summary() -> String {
        let failures = run()
        if failures.isEmpty { return "mesh processing self-test: all passed" }
        return "mesh processing self-test: \(failures.count) failed: " + failures.joined(separator: "; ")
    }

    // MARK: - Mesh builders

    /// Grid patch with vertex (i, j) at `origin + u * i / nu + v * j / nv`. Cell (i, j) owns
    /// faces `2 * (i * nv + j)` and the next one; every face normal points along cross(u, v).
    private static func patch(_ origin: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ nu: Int, _ nv: Int) -> TriangleMesh {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((nu + 1) * (nv + 1))
        for i in 0...nu {
            for j in 0...nv {
                positions.append(origin + u * (Float(i) / Float(nu)) + v * (Float(j) / Float(nv)))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * nu * nv)
        for i in 0..<nu {
            for j in 0..<nv {
                let a = UInt32(i * (nv + 1) + j)
                let b = UInt32((i + 1) * (nv + 1) + j)
                indices.append(contentsOf: [a, b, b + 1, a, b + 1, a + 1])
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Closed, welded box from `minimum` with edge lengths `size`, `n` cells per face side,
    /// outward counter-clockwise winding (12 n^2 triangles).
    private static func box(_ minimum: SIMD3<Float>, _ size: SIMD3<Float>, _ n: Int) -> TriangleMesh {
        let x = SIMD3<Float>(size.x, 0, 0), y = SIMD3<Float>(0, size.y, 0), z = SIMD3<Float>(0, 0, size.z)
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (minimum, z, y), (minimum + x, y, z), (minimum, x, z),
            (minimum + y, z, x), (minimum, y, x), (minimum + z, x, y)]
        var mesh = TriangleMesh()
        for face in faces {
            mesh = mesh.merged(with: patch(face.0, face.1, face.2, n, n))
        }
        return mesh.welded(tolerance: 1e-5)
    }

    /// Icosphere of `radius` around the origin: 20 * 4^subdivisions triangles, outward winding.
    private static func icosphere(_ subdivisions: Int, radius: Float) -> TriangleMesh {
        let g: Float = (1 + Float(5).squareRoot()) / 2
        var positions: [SIMD3<Float>] = [
            SIMD3<Float>(-1, g, 0), SIMD3<Float>(1, g, 0), SIMD3<Float>(-1, -g, 0), SIMD3<Float>(1, -g, 0),
            SIMD3<Float>(0, -1, g), SIMD3<Float>(0, 1, g), SIMD3<Float>(0, -1, -g), SIMD3<Float>(0, 1, -g),
            SIMD3<Float>(g, 0, -1), SIMD3<Float>(g, 0, 1), SIMD3<Float>(-g, 0, -1), SIMD3<Float>(-g, 0, 1)].map { simd_normalize($0) }
        var indices: [UInt32] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                                 3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        for _ in 0..<subdivisions {
            var midpoints: [UInt64: UInt32] = [:]
            var next: [UInt32] = []
            next.reserveCapacity(indices.count * 4)
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = MeshTopology.edgeKey(a, b)
                if let known = midpoints[key] { return known }
                let index = UInt32(positions.count)
                positions.append(simd_normalize(positions[Int(a)] + positions[Int(b)]))
                midpoints[key] = index
                return index
            }
            for t in 0..<(indices.count / 3) {
                let a = indices[3 * t], b = indices[3 * t + 1], c = indices[3 * t + 2]
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next.append(contentsOf: [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
            }
            indices = next
        }
        let mesh = TriangleMesh(positions: positions.map { $0 * radius }, indices: indices)
        return mesh.signedVolume >= 0 ? mesh : flipped(mesh) { _ in true }
    }

    /// `mesh` with corners 1 and 2 swapped on every face `t` where `which(t)` is true.
    private static func flipped(_ mesh: TriangleMesh, _ which: (Int) -> Bool) -> TriangleMesh {
        var result = mesh
        for t in 0..<mesh.triangleCount where which(t) {
            result.indices.swapAt(3 * t + 1, 3 * t + 2)
        }
        return result
    }

    /// `mesh` with every face in class `faceClass` and a distinct color per vertex.
    private static func attributed(_ mesh: TriangleMesh, _ faceClass: UInt8) -> MeshWithAttributes {
        let colors = (0..<mesh.positions.count).map { SIMD4<UInt8>(UInt8(truncatingIfNeeded: $0), 128, 64, 255) }
        return MeshWithAttributes(mesh: mesh, faceClass: [UInt8](repeating: faceClass, count: mesh.triangleCount), vertexColor: colors)
    }

    /// Rigid transform with the given rotation columns and translation.
    private static func rigid(_ rotation: simd_float3x3, _ translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(rotation.columns.0, 0), SIMD4<Float>(rotation.columns.1, 0),
                      SIMD4<Float>(rotation.columns.2, 0), SIMD4<Float>(translation, 1))
    }

    /// True when no directed edge appears twice, which on a closed manifold mesh means the
    /// winding is consistent.
    private static func directedEdgesUnique(_ mesh: TriangleMesh) -> Bool {
        var seen = Set<UInt64>()
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let key = UInt64(mesh.indices[3 * t + k]) << 32 | UInt64(mesh.indices[3 * t + (k + 1) % 3])
                if !seen.insert(key).inserted { return false }
            }
        }
        return true
    }

    /// Total length of the boundary edges.
    private static func boundaryLength(_ mesh: TriangleMesh) -> Float {
        mesh.boundaryEdges.reduce(Float(0)) { $0 + simd_distance(mesh.positions[Int($1.0)], mesh.positions[Int($1.1)]) }
    }

    /// Number of faces whose area vector points along +Y.
    private static func upFaces(_ mesh: TriangleMesh, from start: Int = 0) -> Int {
        (start..<mesh.triangleCount).filter { MeshTopology.areaVector(mesh, $0).y > 0 }.count
    }

    // MARK: - Cases

    /// Chunk merge, degenerate and duplicate removal, and weldMap.
    private static func mergeCases(_ r: Recorder) {
        let offset = SIMD3<Float>(2, 0, 1)
        let world = attributed(box(offset, SIMD3<Float>(1, 1, 1), 2), 0)
        var inA: [Bool] = [], inB: [Bool] = []
        for t in 0..<world.triangleCount {
            let x = (MeshTopology.centroid(world.mesh, t)?.x ?? 0) - offset.x
            inA.append(x < 0.7)
            inB.append(x > 0.3)
        }
        let partA = world.keepingFaces(inA), partB = world.keepingFaces(inB)
        let shiftA = SIMD3<Float>(1, 0.5, 0), shiftB = SIMD3<Float>(2, 0, 3)
        let turn = simd_float3x3(SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0))
        let chunkA = MeshChunk(localMesh: TriangleMesh(positions: partA.mesh.positions.map { $0 - shiftA }, indices: partA.mesh.indices),
                               anchorTransform: rigid(matrix_identity_float3x3, shiftA),
                               faceClass: [UInt8](repeating: 1, count: partA.triangleCount), vertexColor: partA.vertexColor)
        let localB = partB.mesh.positions.map { simd_mul(simd_transpose(turn), $0 - shiftB) }
        let chunkB = MeshChunk(localMesh: TriangleMesh(positions: localB, indices: partB.mesh.indices),
                               anchorTransform: rigid(turn, shiftB),
                               faceClass: [UInt8](repeating: 2, count: partB.triangleCount), vertexColor: partB.vertexColor)
        let onlyB = (0..<world.triangleCount).filter { inB[$0] && !inA[$0] }.count
        let merged = ChunkMerge.merge([chunkA, chunkB])
        r.check("merge.chunksOverlap", partA.triangleCount + partB.triangleCount > world.triangleCount, "")
        r.check("merge.triangleCount", merged.triangleCount == world.triangleCount, "got \(merged.triangleCount)")
        r.check("merge.vertexCount", merged.mesh.positions.count == world.mesh.positions.count, "got \(merged.mesh.positions.count)")
        r.check("merge.watertight", merged.mesh.isWatertight, "")
        r.near("merge.volume", merged.mesh.signedVolume, 1, 1e-3)
        r.check("merge.windingConsistent", directedEdgesUnique(merged.mesh), "")
        r.check("merge.attributes", merged.isConsistent && merged.faceClass != nil && merged.vertexColor != nil, "")
        r.check("merge.keepsFirstDuplicate", merged.faceClass?.filter { $0 == 2 }.count == onlyB, "expected \(onlyB) class-2 faces")
        r.check("merge.empty", ChunkMerge.merge([]).triangleCount == 0, "")

        let corners: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(2, 0, 0)]
        let messy = MeshWithAttributes(mesh: TriangleMesh(positions: corners, indices: [0, 1, 2, 0, 2, 1, 1, 2, 0, 0, 0, 1, 0, 1, 99, 0, 1, 3, 1, 3, 2]),
                                       faceClass: [1, 2, 3, 4, 5, 6, 7])
        let snapshot = messy
        let tidy = ChunkMerge.removingDegenerateAndDuplicateFaces(messy)
        r.check("merge.dropDegenerateDuplicate", tidy.triangleCount == 2 && tidy.faceClass == [1, 7], "got \(tidy.faceClass ?? [])")
        r.check("merge.tidyConsistent", tidy.isConsistent, "")
        r.check("merge.inputUnchanged", messy == snapshot, "")

        let nan = Float.nan
        let weldInput = TriangleMesh(positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.001, 0, 0), SIMD3<Float>(1, 0, 0),
                                                 SIMD3<Float>(0, 0, 0.002), SIMD3<Float>(nan, 0, 0), SIMD3<Float>(nan, 0, 0)])
        let weld = weldInput.weldMap(tolerance: 0.005)
        r.check("weldMap.remap", weld.remap == [0, 0, 1, 0, 2, 3], "got \(weld.remap)")
        r.check("weldMap.positions", weld.positions.count == 4 && weld.positions[1] == SIMD3<Float>(1, 0, 0), "")
    }

    /// Connected components, floaters, largest component and non-manifold edges.
    private static func componentCases(_ r: Recorder) {
        let big = attributed(box(.zero, SIMD3<Float>(1, 1, 1), 4), 1)
        let small = attributed(box(SIMD3<Float>(3, 0, 0), SIMD3<Float>(0.05, 0.05, 0.05), 1), 2)
        let fan = attributed(TriangleMesh(positions: [SIMD3<Float>(5, 0, 0), SIMD3<Float>(6, 0, 0), SIMD3<Float>(5, 1, 0),
                                                      SIMD3<Float>(4, 0, 0), SIMD3<Float>(5, -1, 0)], indices: [0, 1, 2, 0, 3, 4]), 3)
        let all = big.appending(small).appending(fan)
        let components = MeshCleanup.connectedComponents(all.mesh)
        r.check("components.count", components.count == 4, "got \(components.count)")
        r.check("components.ids", components.faceComponent.count == all.triangleCount
                    && components.faceComponent.allSatisfy { $0 >= 0 && Int($0) < components.count }, "")
        let broken = TriangleMesh(positions: all.mesh.positions, indices: all.mesh.indices + [0, 1, 999_999])
        let brokenComponents = MeshCleanup.connectedComponents(broken)
        r.check("components.outOfRange", brokenComponents.faceComponent.last == -1 && brokenComponents.count == 4, "")

        let noFloaters = MeshCleanup.removingFloaters(all)
        r.check("floaters.removed", noFloaters.triangleCount == big.triangleCount, "got \(noFloaters.triangleCount)")
        r.near("floaters.area", noFloaters.mesh.surfaceArea, 6, 1e-3)
        r.check("floaters.consistent", noFloaters.isConsistent && noFloaters.faceClass?.allSatisfy { $0 == 1 } == true, "")
        r.check("floaters.keepsLargest", MeshCleanup.removingFloaters(small).triangleCount == small.triangleCount, "")
        let lenient = MeshCleanup.removingFloaters(all, minimumArea: 0.001, minimumTriangles: 10)
        r.check("floaters.thresholds", lenient.triangleCount == big.triangleCount + small.triangleCount, "got \(lenient.triangleCount)")
        r.check("components.largest", MeshCleanup.largestComponent(all).triangleCount == big.triangleCount, "")

        let finPoints: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                                         SIMD3<Float>(0.5, 0, 2), SIMD3<Float>(0.5, 0, -4)]
        let fins = MeshWithAttributes(mesh: TriangleMesh(positions: finPoints, indices: [0, 1, 2, 1, 0, 3, 0, 1, 4]), faceClass: [1, 2, 3])
        let manifold = MeshCleanup.removingNonManifoldEdges(fins)
        r.check("nonManifold.keepsTwoLargest", manifold.triangleCount == 2 && manifold.faceClass == [2, 3], "got \(manifold.faceClass ?? [])")
        r.near("nonManifold.area", manifold.mesh.surfaceArea, 3, 1e-4)
        r.check("nonManifold.cubeUnchanged", MeshCleanup.removingNonManifoldEdges(big).triangleCount == big.triangleCount, "")
    }

    /// Winding repair, normals and the combined cleanup.
    private static func windingCases(_ r: Recorder) {
        let cube = box(.zero, SIMD3<Float>(1, 1, 1), 2)
        let mixed = attributed(flipped(cube) { $0 % 3 == 0 }, 1)
        let snapshot = mixed
        let fixed = MeshCleanup.fixingWinding(mixed)
        r.check("winding.inputInconsistent", !directedEdgesUnique(mixed.mesh), "")
        r.check("winding.consistent", directedEdgesUnique(fixed.mesh), "")
        r.check("winding.watertight", fixed.mesh.isWatertight, "")
        r.near("winding.volume", fixed.mesh.signedVolume, 1, 1e-4)
        var sameCorners = fixed.triangleCount == mixed.triangleCount && fixed.mesh.positions == mixed.mesh.positions
        for t in 0..<Swift.min(fixed.triangleCount, mixed.triangleCount) {
            let a = fixed.mesh.indices[(3 * t)..<(3 * t + 3)].sorted(), b = mixed.mesh.indices[(3 * t)..<(3 * t + 3)].sorted()
            if a != b { sameCorners = false }
        }
        r.check("winding.onlyCornerOrder", sameCorners && fixed.faceClass == mixed.faceClass && fixed.isConsistent, "")
        r.check("winding.inputUnchanged", mixed == snapshot, "")
        let inverted = MeshCleanup.fixingWinding(MeshWithAttributes(mesh: flipped(cube) { _ in true }))
        r.near("winding.invertedVolume", inverted.mesh.signedVolume, 1, 1e-4)

        let sphere = icosphere(2, radius: 1)
        let normals = MeshCleanup.normals(sphere)
        let aligned = normals.count == sphere.positions.count
            && zip(normals, sphere.positions).allSatisfy { simd_dot($0, simd_normalize($1)) > 0.99 }
        r.check("normals.sphere", aligned, "")

        let messy = attributed(flipped(cube) { $0 % 4 == 1 }, 1).appending(attributed(box(SIMD3<Float>(4, 0, 0), SIMD3<Float>(0.02, 0.02, 0.02), 1), 2))
        let clean = MeshCleanup.cleaned(messy)
        r.check("cleaned.cube", clean.triangleCount == cube.triangleCount && clean.mesh.isWatertight && clean.isConsistent, "got \(clean.triangleCount)")
        r.near("cleaned.volume", clean.mesh.signedVolume, 1, 1e-4)
    }

    /// Quadric simplification: sphere radius, target count, plane boundary.
    private static func simplifyCases(_ r: Recorder) {
        let sphere = attributed(icosphere(4, radius: 1), 0)
        let target = 1000
        let result = MeshSimplify.simplify(sphere, options: MeshSimplify.Options(targetTriangleCount: target))
        let count = result.mesh.triangleCount
        r.check("simplify.sphereStart", sphere.triangleCount == 5120, "got \(sphere.triangleCount)")
        r.check("simplify.reachesTarget", count <= target && count >= target - 10, "got \(count)")
        let radii = result.mesh.mesh.positions.map { simd_length($0) }
        r.check("simplify.radius", radii.allSatisfy { $0 > 0.99 && $0 < 1.01 }, "range \(radii.min() ?? 0) to \(radii.max() ?? 0)")
        r.check("simplify.watertight", result.mesh.mesh.isWatertight && result.mesh.isConsistent, "")
        r.check("simplify.collapses", result.collapses > 0 && result.maxError >= 0, "")
        let untouched = MeshSimplify.simplify(sphere, options: MeshSimplify.Options())
        r.check("simplify.noLimits", untouched.mesh == sphere && untouched.collapses == 0, "")

        let plate = attributed(patch(.zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), 20, 20), 2)
        let reduced = MeshSimplify.simplify(plate, options: MeshSimplify.Options(targetTriangleCount: 100)).mesh
        r.check("simplify.plateTarget", reduced.triangleCount <= 100 && reduced.triangleCount > 0, "got \(reduced.triangleCount)")
        r.near("simplify.boundaryLength", boundaryLength(reduced.mesh), 4, 1e-3)
        r.near("simplify.plateArea", reduced.mesh.surfaceArea, 1, 1e-3)
        let onRim = reduced.mesh.boundaryEdges.allSatisfy { edge in
            [edge.0, edge.1].allSatisfy { i in
                let p = reduced.mesh.positions[Int(i)]
                return Swift.min(abs(p.x), abs(p.x - 1), abs(p.z), abs(p.z - 1)) < 1e-4
            }
        }
        r.check("simplify.boundaryOnRim", onRim, "")
        r.check("simplify.plateFlat", reduced.mesh.positions.allSatisfy { abs($0.y) < 1e-5 } && upFaces(reduced.mesh) == reduced.triangleCount, "")
        let bounded = MeshSimplify.simplify(plate, options: MeshSimplify.Options(maxError: 1e-4))
        r.check("simplify.maxError", bounded.maxError <= 1e-4 && bounded.mesh.triangleCount < plate.triangleCount, "error \(bounded.maxError)")
    }

    /// Hole filling: a 10 cm hole is filled and flagged, a 1 m hole stays open.
    private static func holeCases(_ r: Recorder) {
        let nu = 28, nv = 40
        let grid = attributed(patch(.zero, SIMD3<Float>(0, 0, 1.4), SIMD3<Float>(2, 0, 0), nu, nv), 2)
        var keep = [Bool](repeating: true, count: grid.triangleCount)
        for i in 0..<nu {
            for j in 0..<nv where (2..<4).contains(i) && (2..<4).contains(j) || (2..<22).contains(i) && (10..<30).contains(j) {
                keep[2 * (i * nv + j)] = false
                keep[2 * (i * nv + j) + 1] = false
            }
        }
        let holed = grid.keepingFaces(keep)
        let loops = HoleFill.boundaryLoops(holed.mesh)
        r.check("holes.loopCount", loops.count == 3, "got \(loops.count)")
        r.check("holes.smallLoop", loops.contains { abs($0.perimeter - 0.4) < 1e-3 && $0.vertices.count == 8 }, "")
        let fill = HoleFill.fillSmallHoles(holed)
        let out = fill.mesh
        let before = holed.triangleCount
        r.check("holes.filledOne", fill.filledLoops == 1 && fill.skippedLoops == 2, "filled \(fill.filledLoops), skipped \(fill.skippedLoops)")
        r.check("holes.added", fill.addedTriangles >= 6 && out.triangleCount == before + fill.addedTriangles, "added \(fill.addedTriangles)")
        r.check("holes.inferredFlags", out.inferredCount == fill.addedTriangles && out.isInferred?.prefix(before).allSatisfy { !$0 } == true, "")
        r.near("holes.filledArea", out.mesh.surfaceArea - holed.mesh.surfaceArea, 0.01, 1e-4)
        r.check("holes.windingMatches", upFaces(out.mesh, from: before) == fill.addedTriangles && directedEdgesUnique(out.mesh), "")
        r.check("holes.class", out.faceClass?.suffix(fill.addedTriangles).allSatisfy { $0 == 2 } == true, "")
        r.check("holes.consistent", out.isConsistent, "")
        let remaining = HoleFill.boundaryLoops(out.mesh)
        r.check("holes.bigStaysOpen", remaining.count == 2 && remaining.contains { abs($0.perimeter - 4) < 1e-3 }, "got \(remaining.count) loops")
        r.check("holes.inputUnchanged", holed.isInferred == nil && holed.triangleCount == before, "")
    }

    /// Taubin smoothing keeps the volume and the boundary.
    private static func smoothCases(_ r: Recorder) {
        let base = icosphere(3, radius: 1)
        let bumpy = base.positions.enumerated().map { k, p in p * (1 + 0.01 * Float(sin(Double(k) * 12.9898))) }
        let noisy = attributed(TriangleMesh(positions: bumpy, indices: base.indices), 3)
        let smooth = MeshSmooth.taubin(noisy)
        let v0 = noisy.mesh.signedVolume, v1 = smooth.mesh.signedVolume
        r.check("smooth.volume", v0 > 0 && abs(v1 / v0 - 1) < 0.02, "from \(v0) to \(v1)")
        r.check("smooth.topology", smooth.mesh.indices == noisy.mesh.indices && smooth.mesh.positions.count == noisy.mesh.positions.count, "")
        r.check("smooth.attributes", smooth.faceClass == noisy.faceClass && smooth.vertexColor == noisy.vertexColor && smooth.isConsistent, "")
        func spread(_ points: [SIMD3<Float>]) -> Float {
            let radii = points.map { simd_length($0) }
            let mean = radii.reduce(0, +) / Float(radii.count)
            return radii.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(radii.count)
        }
        r.check("smooth.reducesNoise", spread(smooth.mesh.positions) < spread(noisy.mesh.positions), "")

        let flat = patch(.zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), 10, 10)
        let wavy = flat.positions.enumerated().map { k, p in p + SIMD3<Float>(0, 0.01 * Float(sin(Double(k) * 7.31)), 0) }
        let sheet = MeshWithAttributes(mesh: TriangleMesh(positions: wavy, indices: flat.indices))
        let smoothed = MeshSmooth.taubin(sheet).mesh.positions
        var rimFixed = smoothed.count == wavy.count
        var before: Float = 0, after: Float = 0
        for k in 0..<Swift.min(smoothed.count, wavy.count) {
            let p = wavy[k]
            if Swift.min(p.x, p.z, 1 - p.x, 1 - p.z) < 1e-6 {
                if smoothed[k] != p { rimFixed = false }
            } else {
                before += p.y * p.y
                after += smoothed[k].y * smoothed[k].y
            }
        }
        r.check("smooth.boundaryFixed", rimFixed, "")
        r.check("smooth.flattensInterior", after < before, "from \(before) to \(after)")
    }

    /// Cropping by box, oriented box and half-space in both modes.
    private static func cropCases(_ r: Recorder) {
        let plate = attributed(patch(.zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), 10, 10), 2)
        let snapshot = plate
        let region = CropRegion.box(AABB3(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(0.55, 1, 1)))
        func inside(_ region: CropRegion, _ test: MeshCrop.FaceTest) -> Int {
            MeshCrop.insideMask(plate.mesh, region: region, test: test).filter { $0 }.count
        }
        r.check("crop.centroid", inside(region, .centroid) == 110, "got \(inside(region, .centroid))")
        r.check("crop.allCorners", inside(region, .allCorners) == 100, "got \(inside(region, .allCorners))")
        r.check("crop.anyCorner", inside(region, .anyCorner) == 120, "got \(inside(region, .anyCorner))")
        let kept = MeshCrop.crop(plate, region: region, mode: .keepInside)
        let removed = MeshCrop.crop(plate, region: region, mode: .removeInside)
        r.check("crop.boxKeep", kept.triangleCount == 110 && kept.isConsistent, "got \(kept.triangleCount)")
        r.check("crop.boxRemove", removed.triangleCount == 90 && removed.isConsistent, "got \(removed.triangleCount)")
        r.check("crop.boxRemoveSide", removed.mesh.positions.allSatisfy { $0.x >= 0.5 - 1e-6 }, "")

        let half = CropRegion.halfSpace(Plane(point: SIMD3<Float>(0, 0, 0.3), normal: SIMD3<Float>(0, 0, 1)))
        r.check("crop.halfSpaceKeep", MeshCrop.crop(plate, region: half, mode: .keepInside).triangleCount == 140, "")
        r.check("crop.halfSpaceRemove", MeshCrop.crop(plate, region: half, mode: .removeInside).triangleCount == 60, "")
        r.check("crop.containsOnPlane", MeshCrop.contains(half, SIMD3<Float>(0, 0, 0.3)) && !MeshCrop.contains(half, SIMD3<Float>(0, 0, 0.29)), "")

        let c = Float(0.5).squareRoot()
        let axes = simd_float3x3(SIMD3<Float>(c, 0, -c), SIMD3<Float>(0, 1, 0), SIMD3<Float>(c, 0, c))
        let center = SIMD3<Float>(0.5, 0, 0.5), halfExtents = SIMD3<Float>(0.25, 0.5, 0.25)
        let oriented = CropRegion.orientedBox(OrientedBox(center: center, axes: axes, halfExtents: halfExtents))
        var expected = 0
        for t in 0..<plate.triangleCount {
            guard let p = MeshTopology.centroid(plate.mesh, t) else { continue }
            let local = simd_mul(simd_transpose(axes), p - center)
            if all(simd_abs(local) .<= halfExtents + 1e-5) { expected += 1 }
        }
        let orientedKept = MeshCrop.crop(plate, region: oriented, mode: .keepInside)
        r.check("crop.orientedBox", expected > 0 && orientedKept.triangleCount == expected && inside(oriented, .centroid) == expected,
                "expected \(expected), got \(orientedKept.triangleCount)")
        r.check("crop.inputUnchanged", plate == snapshot, "")
    }

    /// Object isolation of a 0.4 x 0.2 x 0.3 m box on a 3 x 3 m floor.
    private static func isolationCases(_ r: Recorder) {
        let floor = attributed(patch(SIMD3<Float>(-1.5, 0, -1.5), SIMD3<Float>(0, 0, 3), SIMD3<Float>(3, 0, 0), 30, 30), 2)
        let size = SIMD3<Float>(0.4, 0.2, 0.3)
        let resting = floor.appending(attributed(box(SIMD3<Float>(-0.2, 0, -0.15), size, 4), 4))
        let raised = floor.appending(attributed(box(SIMD3<Float>(-0.2, 0.05, -0.15), size, 4), 4))
        let selection = CropRegion.box(AABB3(min: SIMD3<Float>(-0.35, -0.1, -0.3), max: SIMD3<Float>(0.35, 0.5, 0.3)))

        let plane = ObjectIsolation.findSupportPlane(resting.mesh)
        r.check("isolate.supportPlaneFound", plane != nil, "")
        if let plane = plane {
            r.check("isolate.supportPlaneFloor", abs(plane.normal.y) > 0.99 && abs(plane.signedDistance(to: .zero)) < 0.005,
                    "normal \(plane.normal), d \(plane.d)")
        }

        let onFloor = ObjectIsolation.isolate(resting, selection: selection)
        r.check("isolate.restingFound", onFloor != nil, "")
        if let result = onFloor {
            r.near("isolate.width", result.width, 0.4, 0.01)
            r.near("isolate.depth", result.depth, 0.3, 0.01)
            r.near("isolate.height", result.height, 0.2, 0.01)
            r.near("isolate.openArea", result.surfaceArea, 0.40, 0.005)
            var open = false
            if case .notWatertight? = result.volumeUnavailableReason { open = true }
            r.check("isolate.openNoVolume", result.volume == nil && open, "")
            r.check("isolate.restingConsistent", result.mesh.isConsistent && result.supportPlane != nil, "")
        }

        let lifted = ObjectIsolation.isolate(raised, selection: selection)
        r.check("isolate.raisedFound", lifted != nil, "")
        if let result = lifted {
            r.near("isolate.volume", result.volume, 0.024, 2e-4)
            r.near("isolate.closedArea", result.surfaceArea, 0.52, 0.005)
            r.check("isolate.closedReason", result.volumeUnavailableReason == nil && result.mesh.mesh.isWatertight, "")
            r.check("isolate.closedDimensions", abs(result.width - 0.4) < 0.01 && abs(result.depth - 0.3) < 0.01
                        && abs(result.height - 0.2) < 0.01 && result.width >= result.depth, "")
        }
        let nothing = CropRegion.box(AABB3(min: SIMD3<Float>(10, 10, 10), max: SIMD3<Float>(11, 11, 11)))
        r.check("isolate.emptySelection", ObjectIsolation.isolate(resting, selection: nothing) == nil, "")
    }
}
