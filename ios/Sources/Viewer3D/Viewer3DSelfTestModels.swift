import Foundation
import simd

/// Self-test cases of the build 5 model support (wave 5a0): `ViewerBoundsMath`, the pick entry
/// of a model's mesh, picking over content and model entries, the framing of their union and
/// the model file check. Pure Swift, no ARView or RealityKit; one tiny temporary file.
extension Viewer3DSelfTest {
    /// Runs every model case.
    static func modelCases(_ r: Recorder) {
        boundsUnionCases(r)
        boundsTransformCases(r)
        modelPickCases(r)
        modelFramingCases(r)
        modelFileCases(r)
    }

    /// True when two vectors agree within `tolerance` on every axis.
    static func nearlyEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
        let d = simd_abs(a - b)
        return d.x <= tolerance && d.y <= tolerance && d.z <= tolerance
    }

    /// `ViewerBoundsMath.union`: empty and non-finite boxes are ignored.
    static func boundsUnionCases(_ r: Recorder) {
        let a = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 1, 1))
        let b = AABB3(min: SIMD3<Float>(2, -1, 0.5), max: SIMD3<Float>(3, 0.5, 4))
        r.check("bounds.unionIgnoresEmpty", ViewerBoundsMath.union(a, .empty) == a && ViewerBoundsMath.union(.empty, b) == b)
        r.check("bounds.unionOfEmpties", ViewerBoundsMath.union(.empty, .empty).isEmpty)
        let both = ViewerBoundsMath.union(a, b)
        let expected = AABB3(min: SIMD3<Float>(0, -1, 0), max: SIMD3<Float>(3, 1, 4))
        r.check("bounds.unionOfTwo", both == expected, "\(both.min) \(both.max)")
        let broken = AABB3(min: SIMD3<Float>(Float.nan, 0, 0), max: SIMD3<Float>(1, 1, 1))
        let infinite = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(Float.infinity, 1, 1))
        r.check("bounds.unionIgnoresNonFinite", ViewerBoundsMath.union(a, broken) == a && ViewerBoundsMath.union(infinite, b) == b)
        let flat = ViewerBoundsMath.box(min: SIMD3<Float>(1, 1, 1), max: SIMD3<Float>(0, 0, 0))
        r.check("bounds.invertedBoxEmpty", flat.isEmpty && !ViewerBoundsMath.isUsable(flat))
    }

    /// `ViewerBoundsMath.transformed`: a 90 degree yaw keeps the size, a uniform scale of 2
    /// doubles it, a translation moves it.
    static func boundsTransformCases(_ r: Recorder) {
        let unit = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 1, 1))
        // Rotation of 90 degrees about +Y: x' = z, z' = -x.
        let yaw = simd_float4x4(columns: (SIMD4<Float>(0, 0, -1, 0), SIMD4<Float>(0, 1, 0, 0),
                                          SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, 0, 1)))
        let turned = ViewerBoundsMath.transformed(unit, by: yaw)
        let turnedOK = nearlyEqual(turned.size, SIMD3<Float>(1, 1, 1)) && nearlyEqual(turned.center, SIMD3<Float>(0.5, 0.5, -0.5))
        r.check("transform.yawKeepsUnitSize", turnedOK, "\(turned.min) \(turned.max)")
        let long = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 2, 3))
        let longTurned = ViewerBoundsMath.transformed(long, by: yaw)
        r.check("transform.yawSwapsXZ", nearlyEqual(longTurned.size, SIMD3<Float>(3, 2, 1)), "\(longTurned.size)")
        let double = simd_float4x4(columns: (SIMD4<Float>(2, 0, 0, 0), SIMD4<Float>(0, 2, 0, 0),
                                             SIMD4<Float>(0, 0, 2, 0), SIMD4<Float>(0, 0, 0, 1)))
        let scaled = ViewerBoundsMath.transformed(unit, by: double)
        let scaledOK = nearlyEqual(scaled.size, SIMD3<Float>(2, 2, 2)) && nearlyEqual(scaled.min, SIMD3<Float>(0, 0, 0))
        r.check("transform.scaleTwoDoubles", scaledOK, "\(scaled.size)")
        let shift = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                            SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(1, 2, 3, 1)))
        let moved = ViewerBoundsMath.transformed(unit, by: shift)
        r.check("transform.translationMoves", nearlyEqual(moved.min, SIMD3<Float>(1, 2, 3)) && nearlyEqual(moved.max, SIMD3<Float>(2, 3, 4)))
        r.check("transform.emptyStaysEmpty", ViewerBoundsMath.transformed(.empty, by: double).isEmpty)
    }

    /// `ViewerPicking.entry(for:partID:pickTag:layer:)` found by `nearestHit` while its layer is
    /// visible, and searched together with the content's entries.
    static func modelPickCases(_ r: Recorder) {
        let quad = TriangleMesh(positions: [SIMD3<Float>(-1, -1, 0), SIMD3<Float>(1, -1, 0),
                                            SIMD3<Float>(1, 1, 0), SIMD3<Float>(-1, 1, 0)],
                                indices: [0, 1, 2, 0, 2, 3])
        let tag = ViewerPickTag.element(ElementID(uuid: UUID(uuid: (9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6))))
        let modelID = "model.1.test.usdz"
        let entry = ViewerPicking.entry(for: quad, partID: modelID, pickTag: tag, layer: .realistic)
        let fieldsOK = entry.partID == modelID && entry.pickTag == tag && entry.layer == .realistic
        r.check("modelPick.entryFields", fieldsOK && entry.bvh.triangleCount == 2, "\(entry.bvh.triangleCount)")

        let ray = Ray(origin: SIMD3<Float>(0.2, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        let everything = Set(ViewerLayer.allCases)
        let hit = ViewerPicking.nearestHit(ray, entries: [entry], visibleLayers: [.realistic])
        let hitZ: Float = hit?.position.z ?? 9
        let hitTag: ViewerPickTag? = hit?.pickTag
        let hitPart: String = hit?.partID ?? "nil"
        let tagOK = hitTag == tag
        r.check("modelPick.hitWithTag", tagOK && hitPart == modelID && abs(hitZ) < 1e-5, hitPart)
        var hiddenLayers = everything
        hiddenLayers.remove(.realistic)
        r.check("modelPick.hiddenLayerMissed", ViewerPicking.nearestHit(ray, entries: [entry], visibleLayers: hiddenLayers) == nil)

        let behind = ViewerPart(id: "content", positions: [SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, -1, -1),
                                                           SIMD3<Float>(1, 1, -1), SIMD3<Float>(-1, 1, -1)],
                                indices: [0, 1, 2, 0, 2, 3], material: .lit(SIMD4<Float>(1, 1, 1, 1)), layer: .raw,
                                pickTag: .rawMesh)
        let combined = ViewerPicking.entries(for: [behind]) + [entry]
        let nearest = ViewerPicking.nearestHit(ray, entries: combined, visibleLayers: everything)
        r.check("modelPick.nearerModelWins", nearest?.partID == modelID)
        let fallback = ViewerPicking.nearestHit(ray, entries: combined, visibleLayers: hiddenLayers)
        let fallbackTag: ViewerPickTag? = fallback?.pickTag
        let fallbackPart: String = fallback?.partID ?? "nil"
        r.check("modelPick.contentWhenModelHidden", fallbackPart == "content" && fallbackTag == ViewerPickTag.rawMesh, fallbackPart)
    }

    /// `ViewerOrbitMath.framing` of the union of content and model bounds shows both boxes.
    static func modelFramingCases(_ r: Recorder) {
        let content = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 1, 1))
        let model = AABB3(min: SIMD3<Float>(3, 0, 2), max: SIMD3<Float>(4, 2, 3))
        let union = ViewerBoundsMath.union(content, model)
        let framing = ViewerOrbitMath.framing(union, fieldOfViewDegrees: 60)
        r.check("modelFraming.targetUnionCenter", nearlyEqual(framing.target, SIMD3<Float>(2, 1, 1.5)))
        let corners = ViewerBoundsMath.corners(of: content) + ViewerBoundsMath.corners(of: model)
        let halfAngle: Float = 30 * Float.pi / 180 + 1e-4
        var inside = true
        for yaw: Float in [0, 1.5, 3, 4.5] {
            for pitch in [ViewerOrbitMath.minPitch, 0.6, ViewerOrbitMath.maxPitch] {
                let eye = ViewerOrbitMath.eye(target: framing.target, yaw: yaw, pitch: pitch, distance: framing.distance)
                let axis = simd_normalize(framing.target - eye)
                for corner in corners {
                    let cosine = simd_dot(simd_normalize(corner - eye), axis)
                    if acos(Swift.min(cosine, 1)) > halfAngle { inside = false }
                }
            }
        }
        r.check("modelFraming.unionShowsBoth", inside)
    }

    /// `ViewerLoadedModels.fileSize(of:)`: nil for a missing file or a folder, the byte count
    /// of a regular file (the check behind `ViewerModelError.missingFile`).
    static func modelFileCases(_ r: Recorder) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewer3d-selftest-models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("model.usdz")
        r.check("modelFile.missingNil", ViewerLoadedModels.fileSize(of: file) == nil)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0x50, 0x4B, 3, 4, 0, 0, 0]).write(to: file, options: .atomic)
            r.check("modelFile.folderNil", ViewerLoadedModels.fileSize(of: folder) == nil)
            r.check("modelFile.size", ViewerLoadedModels.fileSize(of: file) == 7)
        } catch {
            r.check("modelFile.write", false, "\(error)")
        }
        r.check("modelFile.errorEquatable", ViewerModelError.missingFile != ViewerModelError.superseded)
    }
}
