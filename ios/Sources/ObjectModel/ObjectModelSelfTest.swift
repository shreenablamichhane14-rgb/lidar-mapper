import Foundation
import simd

/// Plain-Swift checks for the ObjectModel module (no XCTest), run from Settings > Diagnostics.
/// `run()` returns one line per failing check ("name: detail"); empty means all passed. No
/// ARKit, camera, network or RealityKit; files only under `FileManager.default.temporaryDirectory`,
/// removed afterwards; fixed ids and dates, so the result is deterministic. The largest scene is a
/// 1,800 triangle floor, so a run stays far under 2 s on an A15. The file, crop, step, export and
/// USDZ cases live in `ObjectModelSelfTest+Files.swift`.
enum ObjectModelSelfTest {
    /// Fewer checks than this means a section stopped early without reporting.
    private static let minimumChecks = 60

    /// Collects failing checks and counts every check.
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
            guard let value = actual else {
                failures.append("\(name): expected \(expected), got nil")
                return
            }
            if !(abs(value - expected) <= tolerance) {
                failures.append("\(name): expected \(expected), got \(value)")
            }
        }

        /// `near` for Double values.
        func nearDouble(_ name: String, _ actual: Double?, _ expected: Double, _ tolerance: Double) {
            count += 1
            guard let value = actual else {
                failures.append("\(name): expected \(expected), got nil")
                return
            }
            if !(abs(value - expected) <= tolerance) {
                failures.append("\(name): expected \(expected), got \(value)")
            }
        }

        /// Records a thrown error as a failure of check `name`.
        func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): threw \(error)")
        }
    }

    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        let r = Recorder()
        cubeCases(r)
        seamCases(r)
        rotatedCases(r)
        isolateCases(r)
        scaleCases(r)
        confidenceCases(r)
        indexCases(r)
        cropCases(r)
        fileCases(r)
        stepCases(r)
        exportCases(r)
        usdzCases(r)
        if r.failures.isEmpty && r.count < minimumChecks {
            r.failures.append("selfTest: only \(r.count) checks ran")
        }
        return r.failures
    }

    // MARK: - Fixtures

    /// Fixed date with whole seconds (survives the ISO 8601 round trip).
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// Deterministic id number `n`.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x4F, 0x42, 0x4A, 0x4D, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, n))
    }

    /// Grid of `n` x `n` cells from `origin` along `u` and `v`, faces facing cross(u, v).
    static func grid(_ origin: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ n: Int) -> TriangleMesh {
        let cells = Swift.max(n, 1)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((cells + 1) * (cells + 1))
        for i in 0...cells {
            let s: Float = Float(i) / Float(cells)
            for j in 0...cells {
                let t: Float = Float(j) / Float(cells)
                let p: SIMD3<Float> = origin + s * u + t * v
                positions.append(p)
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * cells * cells)
        for i in 0..<cells {
            for j in 0..<cells {
                let a = UInt32(i * (cells + 1) + j)
                let b = UInt32((i + 1) * (cells + 1) + j)
                indices.append(contentsOf: [a, b, b + 1, a, b + 1, a + 1])
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Box from `minimum` with edge lengths `size`, each face its own grid of `cells` x `cells`
    /// with its own vertices (UV seams, not welded), outward counter-clockwise winding. Face
    /// `skipping` (0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z) is left out when given.
    static func seamBox(_ minimum: SIMD3<Float>, _ size: SIMD3<Float>, cells: Int = 1, skipping: Int? = nil) -> TriangleMesh {
        let x = SIMD3<Float>(size.x, 0, 0), y = SIMD3<Float>(0, size.y, 0), z = SIMD3<Float>(0, 0, size.z)
        let minX: SIMD3<Float> = minimum + x
        let minY: SIMD3<Float> = minimum + y
        let minZ: SIMD3<Float> = minimum + z
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (minimum, z, y), (minX, y, z), (minimum, x, z),
            (minY, z, x), (minimum, y, x), (minZ, x, y)]
        var mesh = TriangleMesh()
        for (index, face) in faces.enumerated() where index != skipping {
            mesh = mesh.merged(with: grid(face.0, face.1, face.2, cells))
        }
        return mesh
    }

    /// `seamBox` welded: a closed box (open where a face is skipped).
    static func closedBox(_ minimum: SIMD3<Float>, _ size: SIMD3<Float>, cells: Int = 1, skipping: Int? = nil) -> TriangleMesh {
        seamBox(minimum, size, cells: cells, skipping: skipping).welded(tolerance: 1e-5)
    }

    /// Small and medium measurement with fixed id, hash and date.
    static func measured(_ mesh: TriangleMesh, scale: Float = 1) -> ObjectDimensionsRecord? {
        ObjectDimensions.measure(MeshWithAttributes(mesh: mesh), objectID: fixedID(1), source: .smallMedium,
                                 scaleCorrection: scale, inputHash: "selftest", now: fixedDate)
    }

    /// 1,800 triangle floor of 3 x 3 m at y = 0 facing up.
    static func floorMesh() -> TriangleMesh {
        grid(SIMD3<Float>(-1.5, 0, -1.5), SIMD3<Float>(0, 0, 3), SIMD3<Float>(3, 0, 0), 30)
    }

    // MARK: - Measuring

    /// Unit cube: sides, area, volume and watertightness; a missing face gives no volume.
    static func cubeCases(_ r: Recorder) {
        let cube = closedBox(.zero, SIMD3<Float>(1, 1, 1))
        let record = measured(cube)
        r.check("cube.record", record != nil)
        r.near("cube.width", record?.width, 1, 1e-3)
        r.near("cube.height", record?.height, 1, 1e-3)
        r.near("cube.depth", record?.depth, 1, 1e-3)
        r.near("cube.area", record?.surfaceArea, 6, 1e-3)
        r.near("cube.volume", record?.volume, 1, 1e-3)
        if let found = record {
            let closed: Bool = found.isWatertight && found.volumeUnavailableReason == nil
            r.check("cube.watertight", closed && found.provenance == .measured && found.source == .smallMedium)
            let twelve: Bool = found.triangleCount == 12
            let unscaled: Bool = found.scaleCorrection == 1
            let sameID: Bool = found.objectID == fixedID(1)
            r.check("cube.counts", twelve && unscaled && sameID)
        }

        let open = measured(closedBox(.zero, SIMD3<Float>(1, 1, 1), skipping: 3))
        let openReason: ObjectVolumeReason? = open?.volumeUnavailableReason
        let openVolume: Float? = open?.volume
        r.check("open.noVolume", open != nil && openVolume == nil && openReason == ObjectVolumeReason.notWatertight)
        r.check("open.notWatertight", open?.isWatertight == false)
        r.near("open.width", open?.width, 1, 1e-3)

        let corners = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)]
        let sliver = measured(TriangleMesh(positions: corners, indices: [0, 1, 2, 0, 2, 1]))
        let sliverReason: ObjectVolumeReason? = sliver?.volumeUnavailableReason
        let sliverVolume: Float? = sliver?.volume
        r.check("degenerate.reason", sliverVolume == nil && sliverReason == ObjectVolumeReason.degenerate)
        r.check("degenerate.watertight", sliver?.isWatertight == true)
        r.check("empty.nil", measured(TriangleMesh()) == nil)
        let mappedOpen: ObjectVolumeReason? = ObjectDimensions.volumeReason(ObjectIsolation.VolumeUnavailableReason.notWatertight)
        let mappedFlat: ObjectVolumeReason? = ObjectDimensions.volumeReason(ObjectIsolation.VolumeUnavailableReason.degenerate)
        let mappedNone: ObjectVolumeReason? = ObjectDimensions.volumeReason(nil)
        let openOK: Bool = mappedOpen == ObjectVolumeReason.notWatertight
        let flatOK: Bool = mappedFlat == ObjectVolumeReason.degenerate
        r.check("reason.mapping", openOK && flatOK && mappedNone == nil)
    }

    /// A cube whose faces have their own corner vertices is open until the loader's weld.
    static func seamCases(_ r: Recorder) {
        let seams = seamBox(.zero, SIMD3<Float>(1, 1, 1))
        r.check("seams.openBeforeWeld", !seams.isWatertight && seams.positions.count == 24)
        let welded = ObjectModelLoader.weldedModelMesh(seams)
        r.check("seams.welded", welded.triangleCount == 12 && welded.mesh.positions.count == 8,
                "\(welded.triangleCount) triangles, \(welded.mesh.positions.count) vertices")
        r.check("seams.watertight", welded.mesh.isWatertight)
        r.near("seams.volume", measured(welded.mesh)?.volume, 1, 1e-3)

        var stray = seams
        stray.positions.append(SIMD3<Float>(10, 10, 10))
        stray.positions.append(SIMD3<Float>(Float.nan, 0, 0))
        let bad = UInt32(stray.positions.count - 1)
        stray.indices.append(contentsOf: [0, 1, bad])
        let cleaned = ObjectModelLoader.weldedModelMesh(stray)
        let bounds = cleaned.mesh.boundingBox
        let edge: Float = 1.00001
        let inside: Bool = simd_reduce_max(bounds.max) <= edge
        r.check("weld.dropsStray", inside && cleaned.triangleCount == 12 && cleaned.mesh.positions.count == 8,
                "\(cleaned.triangleCount) triangles, bounds max \(bounds.max)")
    }

    /// A 0.6 x 0.3 x 0.4 box turned 30 degrees about +Y keeps its sides.
    static func rotatedCases(_ r: Recorder) {
        let box = closedBox(SIMD3<Float>(-0.3, -0.15, -0.2), SIMD3<Float>(0.6, 0.3, 0.4))
        let angle: Float = Float.pi / 6
        let c: Float = cos(angle), s: Float = sin(angle)
        let rotation = simd_float3x3(SIMD3<Float>(c, 0, -s), SIMD3<Float>(0, 1, 0), SIMD3<Float>(s, 0, c))
        let turned = TriangleMesh(positions: box.positions.map { simd_mul(rotation, $0) }, indices: box.indices)
        let record = measured(turned)
        r.near("rotated.width", record?.width, 0.6, 1e-3)
        r.near("rotated.depth", record?.depth, 0.4, 1e-3)
        r.near("rotated.height", record?.height, 0.3, 1e-3)
        r.near("rotated.volume", record?.volume, 0.072, 1e-4)
        let ordered: Bool = (record?.width ?? 0) >= (record?.depth ?? 1)
        let upright: Bool = record.map { abs($0.box.axisY.y - 1) < 1e-4 } ?? false
        r.check("rotated.widthAtLeastDepth", ordered && upright)
    }

    /// Large path: a 0.5 m box on a 3 x 3 m floor is isolated without the floor; open only at
    /// its base it stays measured, with a side missing it becomes estimated.
    static func isolateCases(_ r: Recorder) {
        let floor = MeshWithAttributes(mesh: floorMesh())
        let box = closedBox(SIMD3<Float>(-0.25, 0, -0.25), SIMD3<Float>(0.5, 0.5, 0.5), cells: 4)
        let scene = floor.appending(MeshWithAttributes(mesh: box))
        let crop = OrientedBox(center: SIMD3<Float>(0, 0.3, 0), axes: matrix_identity_float3x3,
                               halfExtents: SIMD3<Float>(0.45, 0.45, 0.45))
        let result = ObjectDimensions.isolate(scene, box: crop, objectID: fixedID(2), inputHash: "selftest", now: fixedDate)
        r.check("isolate.found", result != nil)
        r.near("isolate.width", result?.record.width, 0.5, 0.01)
        r.near("isolate.height", result?.record.height, 0.5, 0.01)
        r.near("isolate.depth", result?.record.depth, 0.5, 0.01)
        if let found = result {
            let positions = found.mesh.mesh.positions
            let limit: Float = 0.2501
            let noFloor: Bool = !positions.isEmpty && positions.allSatisfy { (p: SIMD3<Float>) -> Bool in
                abs(p.x) <= limit && abs(p.z) <= limit
            }
            r.check("isolate.floorRemoved", noFloor && found.mesh.triangleCount == 5 * 32,
                    "\(found.mesh.triangleCount) triangles")
            let record = found.record
            r.check("isolate.baseOnlyMeasured", record.provenance == .measured && record.source == .large,
                    "provenance \(record.provenance.rawValue)")
            r.check("isolate.openNoVolume", record.volume == nil && record.volumeUnavailableReason == .notWatertight)
            r.check("isolate.recordMesh", record.triangleCount == found.mesh.triangleCount && record.scaleCorrection == 1)
        }

        let openBox = closedBox(SIMD3<Float>(-0.25, 0, -0.25), SIMD3<Float>(0.5, 0.5, 0.5), cells: 4, skipping: 1)
        let openScene = floor.appending(MeshWithAttributes(mesh: openBox))
        let open = ObjectDimensions.isolate(openScene, box: crop, objectID: fixedID(2), inputHash: "selftest", now: fixedDate)
        r.check("isolate.openSideEstimated", open?.record.provenance == .estimated)
        r.near("isolate.openSideHeight", open?.record.height, 0.5, 0.01)
        let far = OrientedBox(center: SIMD3<Float>(10, 10, 10), axes: matrix_identity_float3x3, halfExtents: SIMD3<Float>(0.1, 0.1, 0.1))
        r.check("isolate.emptyCrop", ObjectDimensions.isolate(scene, box: far, objectID: fixedID(2), inputHash: "", now: fixedDate) == nil)
        r.check("openSide.closed", !ObjectDimensions.hasOpenSide(box, support: nil))
        r.check("openSide.noSupport", ObjectDimensions.hasOpenSide(openBox, support: nil))
    }

    // MARK: - Unit check and confidence

    /// Power-of-ten correction against the reported bounds.
    static func scaleCases(_ r: Recorder) {
        let reported = SIMD3<Float>(0.6, 0.3, 0.4)
        r.check("scale.hundredTimesTooLarge",
                ObjectDimensions.scaleCorrection(meshExtents: SIMD3<Float>(60, 30, 40), reportedExtents: reported) == 0.01)
        r.check("scale.tenTimesTooSmall",
                ObjectDimensions.scaleCorrection(meshExtents: SIMD3<Float>(0.06, 0.03, 0.04), reportedExtents: reported) == 10)
        r.check("scale.within20Percent",
                ObjectDimensions.scaleCorrection(meshExtents: SIMD3<Float>(0.5, 0.3, 0.4), reportedExtents: reported) == 1)
        r.check("scale.noReport", ObjectDimensions.scaleCorrection(meshExtents: SIMD3<Float>(60, 30, 40), reportedExtents: nil) == 1)
        r.check("scale.noPowerOfTen",
                ObjectDimensions.scaleCorrection(meshExtents: SIMD3<Float>(0.2, 0.1, 0.1), reportedExtents: reported) == 1)
        r.check("scale.zeroExtents", ObjectDimensions.scaleCorrection(meshExtents: .zero, reportedExtents: reported) == 1)
    }

    /// Sigma rule per size class and the measured values built from a record.
    static func confidenceCases(_ r: Recorder) {
        r.nearDouble("sigma.small30cm", ObjectDimensions.sigma(length: 0.3, source: .smallMedium), 0.0075, 1e-6)
        r.nearDouble("sigma.small2m", ObjectDimensions.sigma(length: 2, source: .smallMedium), 0.03, 1e-6)
        r.nearDouble("sigma.large2m", ObjectDimensions.sigma(length: 2, source: .large), 0.04, 1e-6)
        r.nearDouble("sigma.large10cm", ObjectDimensions.sigma(length: 0.1, source: .large), 0.01, 1e-6)

        guard let cube = measured(closedBox(.zero, SIMD3<Float>(1, 1, 1))) else {
            return r.check("values.fixture", false, "unit cube not measured")
        }
        let values = ObjectDimensions.measuredValues(cube)
        let lengths = [values.width, values.height, values.depth]
        let lowLength: Bool = lengths.contains { $0.isLowConfidence(length: $0.value) }
        r.check("values.oneMeterNotLow", !lowLength)
        r.nearDouble("values.widthSigma", values.width.sigma, 0.015, 1e-6)
        r.nearDouble("values.areaSigma", values.surfaceArea.sigma, 0.18, 1e-4)
        r.nearDouble("values.volumeSigma", values.volume?.sigma, 0.03, 1e-4)
        r.check("values.provenance", lengths.allSatisfy { $0.provenance == .measured } && values.surfaceArea.provenance == .measured)
        var open = cube
        open.volume = nil
        open.volumeUnavailableReason = .notWatertight
        r.check("values.noVolume", ObjectDimensions.measuredValues(open).volume == nil)
        var estimated = cube
        estimated.provenance = .estimated
        estimated.source = .large
        let large = ObjectDimensions.measuredValues(estimated)
        let largeEstimated: Bool = large.depth.provenance == Provenance.estimated
        let largeSigma: Double = large.depth.sigma ?? 0
        let largeSigmaOK: Bool = abs(largeSigma - 0.02) < 1e-6
        r.check("values.estimatedLarge", largeEstimated && largeSigmaOK)
    }

    // MARK: - Index buffers

    /// 16- and 32-bit buffers with a vertex base, unaligned reads and the nil cases.
    static func indexCases(_ r: Recorder) {
        let short: [UInt16] = [0, 1, 2, 2, 1, 3]
        var shortBytes = Data([0xAA])
        for value in short { withUnsafeBytes(of: value.littleEndian) { shortBytes.append(contentsOf: $0) } }
        let wide: [UInt32] = [5, 6, 7]
        var wideBytes = Data([0xAA])
        for value in wide { withUnsafeBytes(of: value.littleEndian) { wideBytes.append(contentsOf: $0) } }

        shortBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let unaligned = UnsafeRawBufferPointer(rebasing: raw[1...])
            let found = ObjectModelLoader.triangleIndices(unaligned, count: 6, bytesPerIndex: 2, vertexBase: 10)
            r.check("indices.16bit", found == [10, 11, 12, 12, 11, 13], "\(String(describing: found))")
            r.check("indices.fiveIsNil", ObjectModelLoader.triangleIndices(unaligned, count: 5, bytesPerIndex: 2, vertexBase: 0) == nil)
            r.check("indices.widthIsNil", ObjectModelLoader.triangleIndices(unaligned, count: 3, bytesPerIndex: 3, vertexBase: 0) == nil)
            r.check("indices.shortBufferIsNil", ObjectModelLoader.triangleIndices(unaligned, count: 9, bytesPerIndex: 2, vertexBase: 0) == nil)
        }
        wideBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let unaligned = UnsafeRawBufferPointer(rebasing: raw[1...])
            let found = ObjectModelLoader.triangleIndices(unaligned, count: 3, bytesPerIndex: 4, vertexBase: 100)
            r.check("indices.32bit", found == [105, 106, 107], "\(String(describing: found))")
            r.check("indices.overflowIsNil",
                    ObjectModelLoader.triangleIndices(unaligned, count: 3, bytesPerIndex: 4, vertexBase: UInt32.max) == nil)
        }
    }
}
