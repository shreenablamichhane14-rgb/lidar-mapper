import Foundation
import simd

/// MeshModel self-test cases for the fast mesh, the chunk conversion and the derived files,
/// the palette, the export adapter and the step's pure rules.
extension MeshModelSelfTest {
    // MARK: - Fast mesh

    /// `fastWorldMesh` transforms positions by the anchor transform and does not weld.
    static func fastMeshCases(_ r: Recorder) {
        let halves = cubeHalves()
        let fast = MeshConsolidator.fastWorldMesh(halves)
        r.check("fast.faces", fast.triangleCount == 16, "\(fast.triangleCount) faces")
        r.check("fast.noWeld", fast.mesh.positions.count == 16, "\(fast.mesh.positions.count) vertices")
        let corners = cubeCorners()
        var worst: Float = 0
        for (i, p) in fast.mesh.positions.enumerated() {
            worst = Swift.max(worst, simd_distance(p, corners[i % 8]))
        }
        r.check("fast.transformed", worst < 1e-4, "vertex off by \(worst) m")
        r.check("fast.classes", fast.faceClass?.count == 16 && fast.faceClass?.last == 2)
        r.check("fast.empty", MeshConsolidator.fastWorldMesh([]).triangleCount == 0)
    }

    // MARK: - Conversion and files

    /// Chunk and mesh round trip through `MeshChunkFile`; `save` then every loader in a temp
    /// package; missing files load as nil and corrupt ones throw.
    static func storeCases(_ r: Recorder) {
        guard let cube = consolidated(cubeHalves()) else {
            return r.check("store.cube", false, "nil without cancellation")
        }
        let room = fixedID(20)
        let chunk = MeshModelStore.chunk(from: cube.measured, id: room)
        r.check("store.chunkIdentity", chunk.anchorID == room && Transform4(chunk.transform) == Transform4.identity)
        r.check("store.chunkNormals", chunk.normals.count == chunk.positions.count)
        do {
            let decoded = try MeshChunkFile.decode(MeshChunkFile.encode(chunk))
            let back = MeshModelStore.mesh(from: decoded)
            r.check("store.roundTripGeometry", back.mesh == cube.measured.mesh)
            r.check("store.roundTripClasses", back.faceClass == cube.measured.faceClass)
            r.check("store.roundTripFlags", back.isInferred == nil && back.vertexColor == nil)
        } catch {
            r.fail("store.roundTrip", error)
        }

        guard let holes = consolidated([holeChunk()]), let floaters = consolidated(floaterChunks()) else {
            return r.check("store.fixtures", false, "nil without cancellation")
        }
        var result = holes
        result.floaters = floaters.floaters
        do {
            let base = try makeTemporaryFolder("MeshModelSelfTest-store")
            defer { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent(fixedID(21).uuidString + "." + ProjectPackage.fileExtension,
                                                   isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let package = ProjectPackage(root: root)
            try MeshModelStore.save(result, package: package, room: room)

            let measured = try MeshModelStore.loadMeasured(package, room: room)
            let sameGeometry = measured?.mesh == result.measured.mesh
            r.check("store.measured", sameGeometry && measured?.faceClass == result.measured.faceClass)
            let inferred = try MeshModelStore.loadInferred(package, room: room)
            let inferredFlags = inferred?.isInferred ?? []
            let allInferred = !inferredFlags.isEmpty && !inferredFlags.contains(false)
            r.check("store.inferred", allInferred && inferred?.triangleCount == result.inferred.triangleCount)
            let view = try MeshModelStore.loadView(package, room: room)
            r.check("store.viewNotInferred", view != nil && view?.isInferred == nil)
            r.check("store.view", view?.triangleCount == result.view.triangleCount)
            let loadedFloaters = try MeshModelStore.loadFloaters(package, room: room)
            r.check("store.floaters", loadedFloaters?.triangleCount == 30)
            r.check("store.stats", MeshModelStore.loadStats(package, room: room) == result.stats)

            let other = fixedID(22)
            let missing = try MeshModelStore.loadMeasured(package, room: other)
            r.check("store.missingMesh", missing == nil)
            r.check("store.missingStats", MeshModelStore.loadStats(package, room: other) == nil)

            try Data("not a mesh".utf8).write(to: MeshModelStore.viewURL(package, room: room))
            var threw = false
            do {
                _ = try MeshModelStore.loadView(package, room: room)
            } catch {
                threw = true
            }
            r.check("store.corruptThrows", threw)

            let gone = ProjectPackage(root: base.appendingPathComponent("deleted.mapperproj", isDirectory: true))
            var refused = false
            do {
                try MeshModelStore.save(result, package: gone, room: room)
            } catch {
                refused = true
            }
            r.check("store.noGhostPackage", refused && !FileManager.default.fileExists(atPath: gone.root.path))
        } catch {
            r.fail("store.files", error)
        }
    }

    // MARK: - Palette

    /// Eight distinct class colors, `bytes` matches `color`, Inferred differs from all.
    static func paletteCases(_ r: Recorder) {
        r.check("palette.count", MeshClassPalette.all.count == 8)
        var distinct: [SIMD4<Float>] = []
        for value in UInt8(0)...UInt8(7) {
            let color = MeshClassPalette.color(for: value)
            if !distinct.contains(color) { distinct.append(color) }
        }
        r.check("palette.distinct", distinct.count == 8, "\(distinct.count) distinct colors")
        var worst: Float = 0
        for value in UInt8(0)...UInt8(7) {
            let color = MeshClassPalette.color(for: value)
            let bytes = MeshClassPalette.bytes(for: value)
            let back = SIMD4<Float>(Float(bytes.x), Float(bytes.y), Float(bytes.z), Float(bytes.w)) / 255
            worst = Swift.max(worst, simd_reduce_max(simd_abs(back - color)))
        }
        r.check("palette.bytes", worst <= 0.5 / 255 + 1e-6, "off by \(worst)")
        r.check("palette.inferredDistinct", !distinct.contains(MeshClassPalette.inferred))
        r.check("palette.wall", MeshClassPalette.color(for: 1) == SIMD4<Float>(0.45, 0.62, 0.85, 1))
        r.check("palette.unknown", MeshClassPalette.color(for: 200) == MeshClassPalette.color(for: 0))
    }

    // MARK: - Export

    /// Per-vertex class colors only when asked; every face keeps its own class color; the
    /// scenes validate.
    static func exportCases(_ r: Recorder) {
        guard let cube = consolidated(cubeHalves()), let holes = consolidated([holeChunk()]) else {
            return r.check("export.fixtures", false, "nil without cancellation")
        }
        let colored = MeshExportAdapter.exportMesh(cube.measured, name: "cube", colorByClass: true)
        let colorCount = colored.colors?.count ?? -1
        r.check("export.colors", colorCount == colored.positions.count && colorCount > 0)
        r.check("export.faceOrder", colored.triangleCount == cube.measured.triangleCount)
        var faceColorsMatch = colored.colors != nil
        if let colors = colored.colors, let classes = cube.measured.faceClass {
            for t in 0..<colored.triangleCount {
                let expected = MeshClassPalette.bytes(for: classes[t])
                for k in 0..<3 where colors[Int(colored.indices[3 * t + k])] != expected {
                    faceColorsMatch = false
                }
            }
        }
        r.check("export.faceColors", faceColorsMatch, "a vertex shared across classes was not split")
        let plain = MeshExportAdapter.exportMesh(cube.measured, name: "cube", colorByClass: false)
        r.check("export.noColors", plain.colors == nil && plain.positions.count == cube.measured.mesh.positions.count)
        r.check("export.normals", plain.normals?.count == plain.positions.count)

        let coloredScene = MeshExportAdapter.scene(measured: holes.measured, inferred: holes.inferred, colorByClass: true)
        let plainScene = MeshExportAdapter.scene(measured: holes.measured, inferred: holes.inferred, colorByClass: false)
        do {
            try coloredScene.validate()
            try plainScene.validate()
            r.check("export.validate", true)
        } catch {
            r.fail("export.validate", error)
        }
        let unbound = coloredScene.meshes.allSatisfy { $0.materialIndex == nil }
        r.check("export.sceneMeshes", coloredScene.meshes.count == 2 && coloredScene.materials.isEmpty && unbound)
        let inferredColors = coloredScene.meshes.last?.colors ?? []
        let orange = MeshClassPalette.inferredBytes
        r.check("export.inferredColor", !inferredColors.isEmpty && !inferredColors.contains { $0 != orange })
        let inferredMaterial = plainScene.materials.last?.baseColor == MeshClassPalette.inferred
        let bound = plainScene.meshes.last?.materialIndex == 1
        r.check("export.materials", plainScene.materials.count == 2 && inferredMaterial && bound)
        let alone = MeshExportAdapter.scene(measured: cube.measured, inferred: nil, colorByClass: true)
        r.check("export.noInferred", alone.meshes.count == 1)
    }

    // MARK: - Step

    /// The step's id, budgets, variant rule, options, depth window rule and input hash.
    static func stepCases(_ r: Recorder) {
        let step = ConsolidateMeshStep(roomID: fixedID(30), folders: [])
        r.check("step.id", step.id == .consolidateMesh)
        r.check("step.budgets", step.memoryBudgetBytes == 700_000_000 && step.reducedMemoryBudgetBytes == 350_000_000)
        r.check("step.fullVariant", !ConsolidateMeshStep.usesReducedVariant(availableMemory: 1_000_000_000))
        r.check("step.reducedVariant", ConsolidateMeshStep.usesReducedVariant(availableMemory: 999_999_999))
        let reduced = ConsolidateMeshStep.options(reduced: true, depthWindow: nil)
        r.check("step.reducedOptions", reduced.simplifyChunksBeforeMerge && reduced.viewTriangleBudget == 150_000)
        r.check("step.fullOptions", ConsolidateMeshStep.options(reduced: false, depthWindow: nil) == ConsolidationOptions())

        let epoch = Date(timeIntervalSince1970: 0)
        var roomManifest = ProjectManifest.new(kind: .room, name: "", now: epoch)
        roomManifest.id = fixedID(31)
        var advanced = ProjectManifest.new(kind: .advancedSpace, name: "", now: epoch)
        advanced.id = fixedID(32)
        r.check("step.noCropForRooms", ConsolidateMeshStep.depthWindow(for: roomManifest) == nil)
        r.check("step.cropForAdvanced", ConsolidateMeshStep.depthWindow(for: advanced) == advanced.settings.depthWindow)

        do {
            let base = try makeTemporaryFolder("MeshModelSelfTest-step")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = ProjectPackage(root: base.appendingPathComponent("p.mapperproj", isDirectory: true))
            let folderA = RawScanFolder(url: base.appendingPathComponent("a", isDirectory: true))
            let folderB = RawScanFolder(url: base.appendingPathComponent("b", isDirectory: true))
            let halves = cubeHalves()
            try writeChunk(halves[0], into: folderA, fileName: "a.mchk")
            try writeChunk(halves[1], into: folderB, fileName: "b.mchk")
            try ProjectStore.sealRawFolder(folderA.url, now: epoch)
            try ProjectStore.sealRawFolder(folderB.url, now: epoch)
            /// A never-cancelled context for `manifest` with plenty of memory.
            func context(_ manifest: ProjectManifest) -> StepContext {
                StepContext(package: package, manifest: manifest, availableMemory: 2_000_000_000,
                            isCancelled: { false }, progress: { _ in })
            }
            let one = ConsolidateMeshStep(roomID: fixedID(30), folders: [folderA, folderB])
            let first = try one.inputHash(context(roomManifest))
            let again = try one.inputHash(context(roomManifest))
            r.check("step.hashStable", first == again && first.count == 16)
            let fewer = try ConsolidateMeshStep(roomID: fixedID(30), folders: [folderA]).inputHash(context(roomManifest))
            r.check("step.hashFolders", fewer != first)
            let cropped = try one.inputHash(context(advanced))
            r.check("step.hashCrop", cropped != first)
        } catch {
            r.fail("step.hash", error)
        }
    }
}
