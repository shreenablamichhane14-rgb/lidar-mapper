import Foundation
import simd

// Cropping and object isolation.
extension MeshProcessingSelfTest {
    /// Cropping by box, oriented box and half-space in both modes.
    static func cropCases(_ r: Recorder) {
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
    static func isolationCases(_ r: Recorder) {
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
