import Foundation
import simd

// Connected components, floaters, non-manifold edges, winding and the full cleanup pass.
extension MeshProcessingSelfTest {
    /// Connected components, floaters, largest component and non-manifold edges.
    static func componentCases(_ r: Recorder) {
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
    static func windingCases(_ r: Recorder) {
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
        var aligned = normals.count == sphere.positions.count
        for (normal, position) in zip(normals, sphere.positions) {
            let cosine: Float = simd_dot(normal, simd_normalize(position))
            if !(cosine > 0.99) { aligned = false }
        }
        r.check("normals.sphere", aligned, "")

        let messy = attributed(flipped(cube) { $0 % 4 == 1 }, 1).appending(attributed(box(SIMD3<Float>(4, 0, 0), SIMD3<Float>(0.02, 0.02, 0.02), 1), 2))
        let clean = MeshCleanup.cleaned(messy)
        r.check("cleaned.cube", clean.triangleCount == cube.triangleCount && clean.mesh.isWatertight && clean.isConsistent, "got \(clean.triangleCount)")
        r.near("cleaned.volume", clean.mesh.signedVolume, 1, 1e-4)
    }

    /// Component statistics, open-surface and multi-component winding, empty input, input
    /// immutability and face normals.
    static func cleanupExtraCases(_ r: Recorder) {
        let big = box(.zero, SIMD3<Float>(1, 1, 1), 2)
        let small = box(SIMD3<Float>(3, 0, 0), SIMD3<Float>(0.5, 0.5, 0.5), 1)
        let pair = MeshWithAttributes(mesh: big.merged(with: small))
        let stats = MeshCleanup.connectedComponents(pair.mesh)
        r.check("components.stats", stats.count == 2 && stats.triangleCounts == [48, 12] && stats.largest == 0,
                "got \(stats.triangleCounts)")
        r.near("components.areas", stats.areas.reduce(0, +), 7.5, 1e-3)
        let snapshot = pair
        _ = MeshCleanup.cleaned(pair)
        r.check("cleaned.inputUnchanged", pair == snapshot, "")

        let sheet = MeshWithAttributes(mesh: flipped(patch(.zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), 6, 6)) { $0 % 5 == 0 })
        let oriented = MeshCleanup.fixingWinding(sheet)
        r.check("winding.openMajority", upFaces(oriented.mesh) == sheet.triangleCount && directedEdgesUnique(oriented.mesh),
                "got \(upFaces(oriented.mesh)) up")
        let inverted = flipped(big) { _ in true }
        let twoSolids = MeshWithAttributes(mesh: inverted.merged(with: flipped(small) { $0 % 2 == 0 }))
        r.near("winding.twoComponents", MeshCleanup.fixingWinding(twoSolids).mesh.signedVolume, 1.125, 1e-4)

        let empty = MeshCleanup.cleaned(MeshWithAttributes(mesh: TriangleMesh(), faceClass: []))
        r.check("cleaned.empty", empty.triangleCount == 0 && empty.isConsistent, "")

        let normals = MeshCleanup.faceNormals(big)
        let axisAligned = normals.count == big.triangleCount && normals.allSatisfy { (n: SIMD3<Float>) -> Bool in
            let length: Float = simd_length(n)
            let magnitudes: [Float] = [abs(n.x), abs(n.y), abs(n.z)]
            let dominant: Int = magnitudes.filter { $0 > 0.999 }.count
            return abs(length - 1) < 1e-5 && dominant == 1
        }
        r.check("normals.faces", axisAligned, "")
        let outward = normals.count == big.triangleCount && (0..<big.triangleCount).allSatisfy { t in
            guard let c = MeshTopology.centroid(big, t) else { return false }
            return simd_dot(normals[t], c - SIMD3<Float>(repeating: 0.5)) > 0
        }
        r.check("normals.outward", outward, "")
    }
}
