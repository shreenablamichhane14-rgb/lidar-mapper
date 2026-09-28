import Foundation
import simd

/// Plain-Swift checks for the mesh processing module (no XCTest), run at launch like the
/// units and geometry self-tests. `run()` returns one line per failing case; empty means
/// all passed. Meshes are small (the largest has 5,120 triangles) so a full run stays well
/// under 3 s on an A15. The cases live in the MeshProcessingSelfTest+*.swift extensions.
enum MeshProcessingSelfTest {
    /// Fewer checks than this means a section stopped early without reporting.
    private static let minimumChecks = 45

    /// Collects failing assertions and counts every check.
    final class Recorder {
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
        cleanupExtraCases(r)
        simplifyCases(r)
        holeCases(r)
        smoothCases(r)
        cropCases(r)
        isolationCases(r)
        isolationExtraCases(r)
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
    static func patch(_ origin: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ nu: Int, _ nv: Int) -> TriangleMesh {
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
    static func box(_ minimum: SIMD3<Float>, _ size: SIMD3<Float>, _ n: Int) -> TriangleMesh {
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
    static func icosphere(_ subdivisions: Int, radius: Float) -> TriangleMesh {
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
    static func flipped(_ mesh: TriangleMesh, _ which: (Int) -> Bool) -> TriangleMesh {
        var result = mesh
        for t in 0..<mesh.triangleCount where which(t) {
            result.indices.swapAt(3 * t + 1, 3 * t + 2)
        }
        return result
    }

    /// `mesh` with every face in class `faceClass` and a distinct color per vertex.
    static func attributed(_ mesh: TriangleMesh, _ faceClass: UInt8) -> MeshWithAttributes {
        let colors = (0..<mesh.positions.count).map { SIMD4<UInt8>(UInt8(truncatingIfNeeded: $0), 128, 64, 255) }
        return MeshWithAttributes(mesh: mesh, faceClass: [UInt8](repeating: faceClass, count: mesh.triangleCount), vertexColor: colors)
    }

    /// Rigid transform with the given rotation columns and translation.
    static func rigid(_ rotation: simd_float3x3, _ translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(rotation.columns.0, 0), SIMD4<Float>(rotation.columns.1, 0),
                      SIMD4<Float>(rotation.columns.2, 0), SIMD4<Float>(translation, 1))
    }

    /// True when no directed edge appears twice, which on a closed manifold mesh means the
    /// winding is consistent.
    static func directedEdgesUnique(_ mesh: TriangleMesh) -> Bool {
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
    static func boundaryLength(_ mesh: TriangleMesh) -> Float {
        mesh.boundaryEdges.reduce(Float(0)) { $0 + simd_distance(mesh.positions[Int($1.0)], mesh.positions[Int($1.1)]) }
    }

    /// Number of faces whose area vector points along +Y.
    static func upFaces(_ mesh: TriangleMesh, from start: Int = 0) -> Int {
        (start..<mesh.triangleCount).filter { MeshTopology.areaVector(mesh, $0).y > 0 }.count
    }

    // MARK: - Cases

    /// Chunk merge, degenerate and duplicate removal, and weldMap.
    static func mergeCases(_ r: Recorder) {
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
        let chunkA = MergeChunk(localMesh: TriangleMesh(positions: partA.mesh.positions.map { $0 - shiftA }, indices: partA.mesh.indices),
                               anchorTransform: rigid(matrix_identity_float3x3, shiftA),
                               faceClass: [UInt8](repeating: 1, count: partA.triangleCount), vertexColor: partA.vertexColor)
        let localB = partB.mesh.positions.map { simd_mul(simd_transpose(turn), $0 - shiftB) }
        let chunkB = MergeChunk(localMesh: TriangleMesh(positions: localB, indices: partB.mesh.indices),
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
}
