import Foundation
import simd

// Simplification, hole filling and smoothing.
extension MeshProcessingSelfTest {
    /// Quadric simplification: sphere radius, target count, plane boundary.
    static func simplifyCases(_ r: Recorder) {
        let sphere = attributed(icosphere(4, radius: 1), 0)
        let target = 1000
        let result = MeshSimplify.simplify(sphere, options: MeshSimplify.Options(targetTriangleCount: target))
        let count = result.mesh.triangleCount
        r.check("simplify.sphereStart", sphere.triangleCount == 5120, "got \(sphere.triangleCount)")
        r.check("simplify.reachesTarget", count <= target && count >= target - 10, "got \(count)")
        let radii: [Float] = result.mesh.mesh.positions.map { (p: SIMD3<Float>) -> Float in simd_length(p) }
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
                let rimDistance: Float = Swift.min(abs(p.x), abs(p.x - 1), abs(p.z), abs(p.z - 1))
                return rimDistance < 1e-4
            }
        }
        r.check("simplify.boundaryOnRim", onRim, "")
        r.check("simplify.plateFlat", reduced.mesh.positions.allSatisfy { abs($0.y) < 1e-5 } && upFaces(reduced.mesh) == reduced.triangleCount, "")
        let bounded = MeshSimplify.simplify(plate, options: MeshSimplify.Options(maxError: 1e-4))
        r.check("simplify.maxError", bounded.maxError <= 1e-4 && bounded.mesh.triangleCount < plate.triangleCount, "error \(bounded.maxError)")
    }

    /// Hole filling: a 10 cm hole is filled and flagged, a 1 m hole stays open.
    static func holeCases(_ r: Recorder) {
        let nu = 28, nv = 40
        let grid = attributed(patch(.zero, SIMD3<Float>(0, 0, 1.4), SIMD3<Float>(2, 0, 0), nu, nv), 2)
        var keep = [Bool](repeating: true, count: grid.triangleCount)
        for i in 0..<nu {
            for j in 0..<nv {
                let smallHole: Bool = (2..<4).contains(i) && (2..<4).contains(j)
                let bigHole: Bool = (2..<22).contains(i) && (10..<30).contains(j)
                guard smallHole || bigHole else { continue }
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
    static func smoothCases(_ r: Recorder) {
        let base = icosphere(3, radius: 1)
        let bumpy: [SIMD3<Float>] = base.positions.indices.map { (k: Int) -> SIMD3<Float> in
            let p: SIMD3<Float> = base.positions[k]
            let wave: Double = sin(Double(k) * 12.9898)
            let scale: Float = 1 + 0.01 * Float(wave)
            return p * scale
        }
        let noisy = attributed(TriangleMesh(positions: bumpy, indices: base.indices), 3)
        let smooth = MeshSmooth.taubin(noisy)
        let v0 = noisy.mesh.signedVolume, v1 = smooth.mesh.signedVolume
        r.check("smooth.volume", v0 > 0 && abs(v1 / v0 - 1) < 0.02, "from \(v0) to \(v1)")
        r.check("smooth.topology", smooth.mesh.indices == noisy.mesh.indices && smooth.mesh.positions.count == noisy.mesh.positions.count, "")
        r.check("smooth.attributes", smooth.faceClass == noisy.faceClass && smooth.vertexColor == noisy.vertexColor && smooth.isConsistent, "")
        func spread(_ points: [SIMD3<Float>]) -> Float {
            let radii: [Float] = points.map { (p: SIMD3<Float>) -> Float in simd_length(p) }
            let mean: Float = radii.reduce(0, +) / Float(radii.count)
            var squares: Float = 0
            for radius in radii { squares += (radius - mean) * (radius - mean) }
            return squares / Float(radii.count)
        }
        r.check("smooth.reducesNoise", spread(smooth.mesh.positions) < spread(noisy.mesh.positions), "")

        let flat = patch(.zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), 10, 10)
        let wavy: [SIMD3<Float>] = flat.positions.indices.map { (k: Int) -> SIMD3<Float> in
            let p: SIMD3<Float> = flat.positions[k]
            let wave: Double = sin(Double(k) * 7.31)
            let lift: Float = 0.01 * Float(wave)
            return p + SIMD3<Float>(0, lift, 0)
        }
        let sheet = MeshWithAttributes(mesh: TriangleMesh(positions: wavy, indices: flat.indices))
        let smoothed = MeshSmooth.taubin(sheet).mesh.positions
        var rimFixed = smoothed.count == wavy.count
        var before: Float = 0, after: Float = 0
        for k in 0..<Swift.min(smoothed.count, wavy.count) {
            let p = wavy[k]
            let rimDistance: Float = Swift.min(p.x, p.z, 1 - p.x, 1 - p.z)
            if rimDistance < 1e-6 {
                if smoothed[k] != p { rimFixed = false }
            } else {
                before += p.y * p.y
                after += smoothed[k].y * smoothed[k].y
            }
        }
        r.check("smooth.boundaryFixed", rimFixed, "")
        r.check("smooth.flattensInterior", after < before, "from \(before) to \(after)")
    }
}
