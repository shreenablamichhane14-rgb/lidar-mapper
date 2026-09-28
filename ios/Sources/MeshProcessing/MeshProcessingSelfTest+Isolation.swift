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
        let toLocal: simd_float3x3 = simd_transpose(axes)
        let slack: SIMD3<Float> = halfExtents + 1e-5
        for t in 0..<plate.triangleCount {
            guard let p = MeshTopology.centroid(plate.mesh, t) else { continue }
            let local: SIMD3<Float> = simd_mul(toLocal, p - center)
            if all(simd_abs(local) .<= slack) { expected += 1 }
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
            r.near("isolate.raisedHeightAboveSupport", result.heightAboveSupport, 0.25, 0.005)
            let widthOK: Bool = abs(result.width - 0.4) < 0.01
            let depthOK: Bool = abs(result.depth - 0.3) < 0.01
            let heightOK: Bool = abs(result.height - 0.2) < 0.01
            r.check("isolate.closedDimensions", widthOK && depthOK && heightOK && result.width >= result.depth, "")
        }
        let nothing = CropRegion.box(AABB3(min: SIMD3<Float>(10, 10, 10), max: SIMD3<Float>(11, 11, 11)))
        r.check("isolate.emptySelection", ObjectIsolation.isolate(resting, selection: nothing) == nil, "")
    }

    /// Generator and support plane determinism, an oriented selection, a rotated object,
    /// the height above the support and the measurement edge cases.
    static func isolationExtraCases(_ r: Recorder) {
        var first = MeshProcessingRandom(seed: 42), second = MeshProcessingRandom(seed: 42)
        var other = MeshProcessingRandom(seed: 43)
        let a = (0..<4).map { _ in first.next() }, b = (0..<4).map { _ in second.next() }
        let c = (0..<4).map { _ in other.next() }
        r.check("random.deterministic", a == b && a != c, "")
        let draws: [Int] = (0..<1000).map { _ in first.index(below: 7) }
        let inRange: Bool = draws.allSatisfy { $0 >= 0 && $0 < 7 }
        let distinct: Int = Set(draws).count
        let unitBound: Int = first.index(below: 1)
        r.check("random.indexRange", inRange && distinct == 7 && unitBound == 0, "")

        let floor = attributed(patch(SIMD3<Float>(-1.5, 0, -1.5), SIMD3<Float>(0, 0, 3), SIMD3<Float>(3, 0, 0), 30, 30), 2)
        let size = SIMD3<Float>(0.4, 0.2, 0.3)
        let resting = floor.appending(attributed(box(SIMD3<Float>(-0.2, 0, -0.15), size, 4), 4))
        let plane = ObjectIsolation.findSupportPlane(resting.mesh)
        r.check("isolate.supportDeterministic", plane != nil && plane == ObjectIsolation.findSupportPlane(resting.mesh), "")
        var reseeded = ObjectIsolation.PlaneOptions()
        reseeded.seed = 7
        let replanned = ObjectIsolation.findSupportPlane(resting.mesh, options: reseeded)
        var otherSeedFloor = false
        if let found = replanned {
            let offset: Float = abs(found.signedDistance(to: SIMD3<Float>(0, 0, 0)))
            otherSeedFloor = offset < 0.005 && found.normal.y > 0.99
        }
        r.check("isolate.otherSeedFloor", otherSeedFloor, "")
        r.check("isolate.maxHeight", ObjectIsolation.findSupportPlane(resting.mesh, maxHeight: -0.5) == nil, "")

        let turn: Float = Float.pi / 6
        let cosTurn: Float = cos(turn), sinTurn: Float = sin(turn)
        let axes = simd_float3x3(SIMD3<Float>(cosTurn, 0, -sinTurn), SIMD3<Float>(0, 1, 0), SIMD3<Float>(sinTurn, 0, cosTurn))
        let selection = OrientedBox(center: SIMD3<Float>(0, 0.2, 0), axes: axes, halfExtents: SIMD3<Float>(0.35, 0.3, 0.3))
        let picked = ObjectIsolation.isolate(resting, box: selection)
        var pickedDimensions = false
        if let found = picked {
            let widthOK: Bool = abs(found.width - 0.4) < 0.01
            let depthOK: Bool = abs(found.depth - 0.3) < 0.01
            let heightOK: Bool = abs(found.height - 0.2) < 0.01
            pickedDimensions = widthOK && depthOK && heightOK
        }
        r.check("isolate.orientedSelection", pickedDimensions, "")

        let spun = box(SIMD3<Float>(-0.2, 0, -0.15), size, 2)
        let rotated = TriangleMesh(positions: spun.positions.map { simd_mul(axes, $0) }, indices: spun.indices)
        let wide = AABB3(min: SIMD3<Float>(-0.4, -0.1, -0.4), max: SIMD3<Float>(0.4, 0.5, 0.4))
        let spunResult = ObjectIsolation.isolate(floor.appending(attributed(rotated, 4)), box: wide)
        r.check("isolate.rotatedFound", spunResult != nil, "")
        if let result = spunResult {
            r.near("isolate.rotatedWidth", result.width, 0.4, 0.01)
            r.near("isolate.rotatedDepth", result.depth, 0.3, 0.01)
            r.near("isolate.heightAboveSupport", result.heightAboveSupport, 0.2, 0.005)
            let widthAxis: SIMD3<Float> = result.box.axes.columns.0
            let alignment: Float = abs(simd_dot(widthAxis, axes.columns.0))
            let upright: Bool = result.box.axes.columns.1 == ObjectIsolation.up
            r.check("isolate.boxAxes", abs(alignment - 1) < 1e-3 && upright, "width axis \(widthAxis)")
        }

        let closed = attributed(box(SIMD3<Float>(1, 1, 1), size, 1), 4)
        let measured = ObjectIsolation.measure(closed, support: nil)
        var closedBox = false
        if let found = measured {
            let volume: Float = found.volume ?? 0
            let noHeight: Bool = found.heightAboveSupport == nil
            let noReason: Bool = found.volumeUnavailableReason == nil
            closedBox = abs(volume - 0.024) < 1e-4 && noHeight && noReason
        }
        r.check("measure.closedBox", closedBox, "")
        let corners = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)]
        let sliver = ObjectIsolation.measure(MeshWithAttributes(mesh: TriangleMesh(positions: corners, indices: [0, 1, 2, 0, 2, 1])),
                                             support: nil)
        r.check("measure.degenerate", sliver != nil && sliver?.volume == nil && sliver?.volumeUnavailableReason == .degenerate, "")
        r.check("measure.empty", ObjectIsolation.measure(MeshWithAttributes(mesh: TriangleMesh()), support: nil) == nil, "")
    }
}
