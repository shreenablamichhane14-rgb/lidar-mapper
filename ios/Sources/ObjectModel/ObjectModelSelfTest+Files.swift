import Foundation
import simd

/// ObjectModel self-test cases for the crop edit, the derived files, the step's hash and pure
/// rules, the export adapter and the ModelIO USDZ round trip. Temporary folders are removed
/// before returning.
extension ObjectModelSelfTest {
    /// A fresh empty folder under the temporary directory.
    static func makeTemporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A package folder `<id>.mapperproj` inside `base`, created.
    static func makePackage(in base: URL, id: UUID) throws -> ProjectPackage {
        let root = base.appendingPathComponent(id.uuidString + "." + ProjectPackage.fileExtension, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ProjectPackage(root: root)
    }

    /// Axis-aligned crop box record centered at `center` with half size `half`.
    static func cropRecord(_ center: SIMD3<Float>, _ half: Float) -> OrientedBoxRecord {
        OrientedBoxRecord(OrientedBox(center: center, axes: matrix_identity_float3x3,
                                      halfExtents: SIMD3<Float>(repeating: half)))
    }

    /// A crop edit of object `object`.
    static func cropEdit(_ object: UUID, _ box: OrientedBoxRecord) -> EditOperation {
        .cropObject(object: ElementID(uuid: object), box: box)
    }

    // MARK: - Crop edit

    /// `cropBox` takes the last active crop of the object (inside a batch too, never an undone
    /// one); `cropDigest` follows the crop.
    static func cropCases(_ r: Recorder) {
        let objectA = fixedID(10), objectB = fixedID(11)
        let first = cropRecord(SIMD3<Float>(0, 0.5, 0), 0.5)
        let second = cropRecord(SIMD3<Float>(1, 0.5, 0), 0.6)
        let third = cropRecord(SIMD3<Float>(2, 0.5, 0), 0.7)

        var log = EditLog()
        log.append(cropEdit(objectA, first))
        log.append(cropEdit(objectB, third))
        log.append(cropEdit(objectA, second))
        r.check("crop.last", ObjectModelStore.cropBox(for: objectA, in: log)?.center == second.center.simd)
        r.check("crop.perObject", ObjectModelStore.cropBox(for: objectB, in: log)?.center == third.center.simd)

        var batched = EditLog()
        batched.append(cropEdit(objectA, first))
        batched.append(.batch(operations: [.renameRoom(room: ElementID(uuid: fixedID(12)), name: "r"), cropEdit(objectA, third)]))
        r.check("crop.insideBatch", ObjectModelStore.cropBox(for: objectA, in: batched)?.center == third.center.simd)

        var undone = EditLog()
        undone.append(cropEdit(objectA, first))
        undone.append(cropEdit(objectA, second))
        undone.undo()
        r.check("crop.ignoresUndone", ObjectModelStore.cropBox(for: objectA, in: undone)?.center == first.center.simd)
        let halfExtents = ObjectModelStore.cropBox(for: objectA, in: undone)?.halfExtents
        r.check("crop.box", halfExtents == SIMD3<Float>(repeating: 0.5))
        r.check("crop.none", ObjectModelStore.cropBox(for: objectA, in: EditLog()) == nil
                && ObjectModelStore.cropBox(for: fixedID(13), in: log) == nil)

        let digestFirst = ObjectModelStore.cropDigest(for: objectA, in: undone)
        let digestSecond = ObjectModelStore.cropDigest(for: objectA, in: log)
        r.check("digest.changesWithCrop", digestFirst != digestSecond && digestFirst.hasPrefix("crop:"))
        r.check("digest.stable", digestSecond == ObjectModelStore.cropDigest(for: objectA, in: log))
        r.check("digest.none", ObjectModelStore.cropDigest(for: objectA, in: EditLog()) == "-")
    }

    // MARK: - Files

    /// dims.json and mesh.mchk round trips in a temp package; missing and foreign files load as
    /// nil; a write into a deleted package throws.
    static func fileCases(_ r: Recorder) {
        guard let record = measured(closedBox(.zero, SIMD3<Float>(1, 1, 1))) else {
            return r.check("files.fixture", false, "unit cube not measured")
        }
        let mesh = MeshWithAttributes(mesh: closedBox(.zero, SIMD3<Float>(1, 1, 1)))
        let object = record.objectID
        do {
            let base = try makeTemporaryFolder("ObjectModelSelfTest-files")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: fixedID(30))
            let dimsPath = ObjectModelStore.dimensionsURL(package, object: object).path
            r.check("files.dimsPath", dimsPath.hasSuffix("derived/objects/\(object.uuidString)/dims.json"))
            r.check("files.meshPath", ObjectModelStore.meshURL(package, object: object).lastPathComponent == "mesh.mchk")

            try ObjectModelStore.saveDimensions(record, to: package)
            r.check("files.dimsRoundTrip", ObjectModelStore.loadDimensions(package, object: object) == record)
            try ObjectModelStore.saveMesh(mesh, package: package, object: object)
            let loaded = try ObjectModelStore.loadMesh(package, object: object)
            r.check("files.meshRoundTrip", loaded == mesh, "\(loaded?.triangleCount ?? -1) triangles")

            let other = fixedID(31)
            r.check("files.missingDims", ObjectModelStore.loadDimensions(package, object: other) == nil)
            let missingMesh = try ObjectModelStore.loadMesh(package, object: other)
            r.check("files.missingMesh", missingMesh == nil)
            try ProjectStore.ensureDirectory(package.derivedObjectURL(other), inside: package.root)
            try ProjectStore.writeJSON(record, to: ObjectModelStore.dimensionsURL(package, object: other), createParents: false)
            r.check("files.foreignDimsIgnored", ObjectModelStore.loadDimensions(package, object: other) == nil)

            let gone = ProjectPackage(root: base.appendingPathComponent("gone.mapperproj", isDirectory: true))
            var refused = false
            do {
                try ObjectModelStore.saveDimensions(record, to: gone)
            } catch {
                refused = true
            }
            let recreated = FileManager.default.fileExists(atPath: gone.root.path)
            r.check("files.deletedPackageRefused", refused && !recreated)
        } catch {
            r.fail("files.io", error)
        }
    }

    // MARK: - Step

    /// The input hash reads upstream stamps from derived/index.json and the crop digest; the
    /// budgets, the variant rule, the unit check path and the reduced pre-crop.
    static func stepCases(_ r: Recorder) {
        let objectID = fixedID(40)
        let small = ObjectRecord(id: objectID, name: "", size: .smallMedium, status: .captured, imageCount: 0, modelFile: nil)
        let large = ObjectRecord(id: objectID, name: "", size: .large, status: .captured, imageCount: 0, modelFile: nil)
        let noModel: (ProjectPackage, UUID) -> URL? = { _, _ in nil }
        let noExtents: (ProjectPackage, UUID) -> SIMD3<Float>? = { _, _ in nil }
        let smallStep = ObjectMetricsStep(object: small, modelFile: noModel, reportedExtents: noExtents)
        let largeStep = ObjectMetricsStep(object: large, modelFile: noModel, reportedExtents: noExtents)
        r.check("step.id", smallStep.id == .objectMetrics)
        r.check("step.budgets", smallStep.memoryBudgetBytes == 300_000_000 && smallStep.reducedMemoryBudgetBytes == 150_000_000)
        r.check("step.variantRule", ObjectMetricsStep.usesReducedVariant(availableMemory: 299_999_999)
                && !ObjectMetricsStep.usesReducedVariant(availableMemory: 300_000_000))
        r.check("step.upstream", ObjectMetricsStep.upstreamStep(for: .smallMedium) == .reconstructObject
                && ObjectMetricsStep.upstreamStep(for: .large) == .consolidateMesh)

        do {
            let base = try makeTemporaryFolder("ObjectModelSelfTest-step")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: fixedID(41))
            var manifest = ProjectManifest.new(kind: .object, name: "", now: fixedDate)
            manifest.id = fixedID(41)
            let ctx = StepContext(package: package, manifest: manifest, availableMemory: 4_000_000_000,
                                  isCancelled: { false }, progress: { _ in })
            let bare = try smallStep.inputHash(ctx)
            r.check("step.hashWithoutIndex", bare == ObjectMetricsStep.hash(size: .smallMedium, upstream: "-", cropDigest: "-"))
            let largeBare = try largeStep.inputHash(ctx)
            let stamps = [
                DerivedStamp(step: .reconstructObject, subject: objectID, pipelineVersion: 1, inputHash: "abc", createdAt: fixedDate),
                DerivedStamp(step: .consolidateMesh, subject: objectID, pipelineVersion: 1, inputHash: "def", createdAt: fixedDate)
            ]
            try ProjectStore.writeJSON(DerivedIndex(stamps: stamps), to: package.derivedIndexURL)
            let stamped = try smallStep.inputHash(ctx)
            r.check("step.hashReadsIndex", stamped != bare
                    && stamped == ObjectMetricsStep.hash(size: .smallMedium, upstream: "abc", cropDigest: "-"))
            let largeStamped = try largeStep.inputHash(ctx)
            r.check("step.largeHashReadsIndex", largeStamped != largeBare)
            var log = EditLog()
            log.append(cropEdit(objectID, cropRecord(SIMD3<Float>(0, 0.3, 0), 0.45)))
            try ProjectStore.writeJSON(log, to: package.editLogURL)
            let cropped = try largeStep.inputHash(ctx)
            let smallAgain = try smallStep.inputHash(ctx)
            r.check("step.hashFollowsCrop", cropped != largeStamped && smallAgain == stamped)
        } catch {
            r.fail("step.io", error)
        }

        var huge = MeshWithAttributes(mesh: closedBox(SIMD3<Float>(-30, 0, -20), SIMD3<Float>(60, 30, 40)))
        let fixed = ObjectMetricsStep.smallMediumRecord(&huge, reportedExtents: SIMD3<Float>(0.6, 0.3, 0.4), objectID: objectID,
                                                        inputHash: "selftest", now: fixedDate)
        r.check("step.scaleCorrection", fixed?.scaleCorrection == 0.01)
        r.near("step.scaledWidth", fixed?.width, 0.6, 1e-3)
        r.near("step.scaledMesh", huge.mesh.boundingBox.size.x, 0.6, 1e-3)

        let floor = MeshWithAttributes(mesh: floorMesh())
        let scene = floor.appending(MeshWithAttributes(mesh: closedBox(SIMD3<Float>(-0.25, 0, -0.25), SIMD3<Float>(0.5, 0.5, 0.5), cells: 4)))
        let crop = OrientedBox(center: SIMD3<Float>(0, 0.3, 0), axes: matrix_identity_float3x3, halfExtents: SIMD3<Float>(0.45, 0.45, 0.45))
        let direct = ObjectDimensions.isolate(scene, box: crop, objectID: objectID, inputHash: "h", now: fixedDate)
        let pre = ObjectMetricsStep.preCropped(scene, box: crop)
        let reduced = ObjectDimensions.isolate(pre, box: crop, objectID: objectID, inputHash: "h", now: fixedDate)
        let same: Bool = direct != nil && direct?.record == reduced?.record && direct?.mesh == reduced?.mesh
        r.check("step.reducedSameResult", same && pre.triangleCount < scene.triangleCount)
    }

    // MARK: - Export and USDZ

    /// The untextured export scene validates and carries one gray material.
    static func exportCases(_ r: Recorder) {
        let scene = ObjectExportAdapter.scene(MeshWithAttributes(mesh: closedBox(.zero, SIMD3<Float>(1, 1, 1))), name: "Box")
        do {
            try scene.validate()
            r.check("export.validates", true)
        } catch {
            r.fail("export.validates", error)
        }
        let first = scene.meshes.first
        r.check("export.oneMesh", scene.meshes.count == 1 && first?.triangleCount == 12 && first?.materialIndex == 0)
        r.check("export.normals", first?.normals?.count == first?.positions.count)
        r.check("export.material", scene.materials.count == 1 && scene.materials.first?.baseColor == ObjectExportAdapter.neutralGray)
        var emptyRefused = false
        do {
            try ObjectExportAdapter.scene(MeshWithAttributes(mesh: TriangleMesh()), name: "Empty").validate()
        } catch {
            emptyRefused = true
        }
        r.check("export.emptyRefused", emptyRefused)
    }

    /// USDZ round trip: `USDZWriter` of a box read back through `mesh(fromUSDZ:)` with 12
    /// triangles and the same bounds (only when ModelIO can read USDZ; otherwise one failure line).
    static func usdzCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("ObjectModelSelfTest-usdz")
            defer { try? FileManager.default.removeItem(at: base) }
            let missing = base.appendingPathComponent("missing.usdz", isDirectory: false)
            var missingRefused = false
            do {
                _ = try ObjectModelLoader.mesh(fromUSDZ: missing)
            } catch let error as ObjectModelError {
                if case .cannotImport = error { missingRefused = true }
            }
            r.check("usdz.missingFile", missingRefused)

            guard ObjectModelLoader.canReadUSDZ else {
                return r.check("usdz.modelIO", false, "ModelIO cannot read USDZ on this device")
            }
            let box = closedBox(SIMD3<Float>(-0.3, 0, -0.2), SIMD3<Float>(0.6, 0.3, 0.4))
            let data = try USDZWriter.data(for: ObjectExportAdapter.scene(MeshWithAttributes(mesh: box), name: "Box"),
                                           modified: fixedDate)
            let url = base.appendingPathComponent("box.usdz", isDirectory: false)
            try data.write(to: url)
            let loaded = try ObjectModelLoader.mesh(fromUSDZ: url)
            r.check("usdz.triangles", loaded.triangleCount == 12, "\(loaded.triangleCount) triangles")
            let read = loaded.mesh.boundingBox
            let written = box.boundingBox
            let lowError: Float = simd_reduce_max(simd_abs(read.min - written.min))
            let highError: Float = simd_reduce_max(simd_abs(read.max - written.max))
            r.check("usdz.bounds", !read.isEmpty && lowError < 1e-4 && highError < 1e-4, "read \(read.min) ... \(read.max)")
            r.check("usdz.watertight", loaded.mesh.isWatertight)
        } catch {
            r.fail("usdz.roundTrip", error)
        }
    }
}
