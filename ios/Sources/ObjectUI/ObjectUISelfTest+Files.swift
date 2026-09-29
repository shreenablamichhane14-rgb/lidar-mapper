import Foundation
import simd

/// ObjectUI self-test cases for the size rows, the textured choice, the viewer parts and the
/// demo object. Temporary folders are removed before returning.
extension ObjectUISelfTest {
    /// The demo box measured as a small or medium object (0.40 x 0.30 x 0.25 m, closed).
    static func boxRecord() -> ObjectDimensionsRecord? {
        ObjectDimensions.measure(MeshWithAttributes(mesh: ObjectDemo.weldedMesh()), objectID: fixedID(4), source: .smallMedium,
                                 scaleCorrection: 1, inputHash: "selftest", now: fixedDate)
    }

    /// Number of plus-minus signs in `text`.
    static func plusMinusCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.filter { $0 == "\u{00B1}" }.count
    }

    // MARK: - Rows

    /// Five rows with one plus-minus accuracy each in metric and imperial, the titles and ids in
    /// order, the unavailable volume (open and degenerate), and the Estimated note.
    static func rowCases(_ r: Recorder) {
        guard let record = boxRecord() else {
            return r.check("rows.fixture", false, "demo box not measured")
        }
        r.near("rows.fixtureWidth", record.width, 0.40, 1e-3)
        r.near("rows.fixtureVolume", record.volume, 0.03, 1e-4)
        let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)
        let imperial = UnitPreferences(system: .imperial, fraction: .eighth, showBoth: true)
        for (name, prefs) in [("metric", metric), ("imperial", imperial)] {
            let rows = ObjectPresentation.rows(for: record, prefs: prefs)
            let counts: [Int] = rows.map { plusMinusCount($0.accuracyText) }
            r.check("rows.\(name).onePlusMinusEach", rows.count == 5 && counts == [1, 1, 1, 1, 1], "\(counts)")
            let lowFlags: [Bool] = rows.map { $0.isLowConfidence }
            r.check("rows.\(name).notLowConfidence", !lowFlags.contains(true))
            let spoken: Bool = rows.allSatisfy { !$0.accessibility.isEmpty && !$0.valueText.isEmpty }
            r.check("rows.\(name).spoken", spoken)
        }
        let rows = ObjectPresentation.rows(for: record, prefs: metric)
        let ids: [String] = rows.map { $0.id }
        r.check("rows.ids", ids == ["object.width", "object.height", "object.depth", "object.area", "object.volume"], "\(ids)")
        let titles: [String] = rows.map { $0.title }
        let expectedTitles: [String] = [Copy.Viewer.width, Copy.Viewer.height, Copy.Viewer.depth, Copy.Measure.surfaceArea,
                                        Copy.Viewer.volume]
        r.check("rows.titles", titles == expectedTitles)
        let measuredNotes: [String?] = rows.map { $0.note }
        r.check("rows.measuredNoNote", measuredNotes.allSatisfy { $0 == nil })

        var open = record
        open.volume = nil
        open.volumeUnavailableReason = .notWatertight
        open.isWatertight = false
        let openRows = ObjectPresentation.rows(for: open, prefs: metric)
        let volumeRow: ObjectDimensionRow? = openRows.last
        let unavailable: Bool = volumeRow?.valueText == Copy.Viewer.volumeUnavailable && volumeRow?.accuracyText == nil
        r.check("rows.volumeUnavailable", openRows.count == 5 && unavailable && volumeRow?.id == "object.volume")
        var thin = open
        thin.volumeUnavailableReason = .degenerate
        thin.isWatertight = true
        let thinRow: ObjectDimensionRow? = ObjectPresentation.rows(for: thin, prefs: metric).last
        r.check("rows.volumeTooThin", thinRow?.valueText == Copy.ObjectUI.volumeTooThin && thinRow?.accuracyText == nil)

        var estimated = record
        estimated.provenance = .estimated
        let estimatedRows = ObjectPresentation.rows(for: estimated, prefs: metric)
        let notes: [String?] = estimatedRows.map { $0.note }
        r.check("rows.estimatedNote", notes.count == 5 && notes.allSatisfy { $0 == Copy.Measure.estimated })
    }

    // MARK: - Textured

    /// `canShowTextured` per size, and `texturedParts` keeps only faces inside the box.
    static func texturedCases(_ r: Recorder) {
        let small = files(size: .smallMedium, model: true, mesh: true, dims: true)
        let smallNoModel = files(size: .smallMedium, model: false, mesh: true, dims: true)
        let largeTextured = files(size: .large, model: false, mesh: true, dims: true, texture: true)
        let largePlain = files(size: .large, model: false, mesh: true, dims: true, texture: false)
        let flags: [Bool] = [small, smallNoModel, largeTextured, largePlain].map { ObjectPresentation.canShowTextured(files: $0) }
        r.check("textured.canShow", flags == [true, false, true, false], "\(flags)")

        let box = OrientedBox(center: SIMD3<Float>(0, 0.5, 0), axes: matrix_identity_float3x3,
                              halfExtents: SIMD3<Float>(0.5, 0.5, 0.5))
        let inside: [SIMD3<Float>] = [SIMD3<Float>(-0.1, 0.4, 0), SIMD3<Float>(0.1, 0.4, 0), SIMD3<Float>(0, 0.6, 0)]
        let outside: [SIMD3<Float>] = [SIMD3<Float>(3, 0.4, 0), SIMD3<Float>(3.2, 0.4, 0), SIMD3<Float>(3.1, 0.6, 0)]
        let uvs: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0.5, 1),
                                   SIMD2<Float>(0.2, 0.2), SIMD2<Float>(0.3, 0.2), SIMD2<Float>(0.25, 0.3)]
        let mixed = TexturedPagePart(page: 0, positions: inside + outside, texcoords: uvs, indices: [0, 1, 2, 3, 4, 5])
        let away = TexturedPagePart(page: 1, positions: outside, texcoords: Array(uvs.prefix(3)), indices: [0, 1, 2])
        let kept = ObjectPresentation.texturedParts([mixed, away], inside: box)
        let first: TexturedPagePart? = kept.first
        let keptFaces: Bool = kept.count == 1 && first?.page == 0 && first?.indices == [0, 1, 2]
        r.check("textured.partsInsideBox", keptFaces && first?.positions == inside && first?.texcoords == Array(uvs.prefix(3)),
                "\(kept.count) parts")
    }

    // MARK: - Parts

    /// The untextured part (lit gray on `.raw`, pickable) and the box parts (on `.overlay`, not
    /// pickable), and the scale transform.
    static func partCases(_ r: Recorder) {
        let mesh = MeshWithAttributes(mesh: ObjectDemo.weldedMesh())
        let part = ObjectPresentation.untexturedPart(mesh)
        let lit: Bool = part.material == ViewerMaterial.lit(ViewerContentBuilder.solidColor)
        r.check("parts.untextured", part.layer == .raw && part.pickTag == .rawMesh && lit && part.triangleCount == 12)
        let box = OrientedBox(center: SIMD3<Float>(0, 0.15, 0), axes: matrix_identity_float3x3,
                              halfExtents: SIMD3<Float>(0.2, 0.15, 0.125))
        let boxParts = ObjectPresentation.boxParts(box)
        let onOverlay: Bool = boxParts.allSatisfy { $0.layer == .overlay && $0.pickTag == nil }
        r.check("parts.box", boxParts.count == 2 && onOverlay)
        let scaled: simd_float4x4 = ObjectPresentation.scaleTransform(0.01)
        let identity: simd_float4x4 = ObjectPresentation.scaleTransform(Float.nan)
        let scaleOK: Bool = abs(scaled.columns.0.x - 0.01) < 1e-7 && scaled.columns.3.w == 1
        let diagonal = SIMD4<Float>(identity.columns.0.x, identity.columns.1.y, identity.columns.2.z, identity.columns.3.w)
        r.check("parts.scaleTransform", scaleOK && diagonal == SIMD4<Float>(1, 1, 1, 1))
    }

    // MARK: - Demo

    /// `ObjectDemo.makeDemoObject` in a temp package writes model.usdz, dims.json and mesh.mchk
    /// that load back through ObjectModel and a sealed raw folder `verifyRawFolder` accepts; the
    /// result's viewer content builds from them; a deleted package is refused and not recreated.
    static func demoCases(_ r: Recorder) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ObjectUISelfTest-demo", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        do {
            if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
            let root = base.appendingPathComponent(fixedID(20).uuidString + "." + ProjectPackage.fileExtension, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let package = ProjectPackage(root: root)
            let objectID = fixedID(21)
            let record = try ObjectDemo.makeDemoObject(package: package, objectID: objectID, now: fixedDate)
            let recordOK: Bool = record.status == .processed && record.modelFile == PhotogrammetryStore.modelFileName
            r.check("demo.record", recordOK && record.size == .smallMedium && record.id == objectID)
            let modelURL = PhotogrammetryStore.modelURLIfPresent(package, object: objectID)
            var modelSize = 0
            if let url = modelURL, let attributes = try? fm.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber {
                modelSize = size.intValue
            }
            r.check("demo.modelUSDZ", modelURL != nil && modelSize > 0, "\(modelSize) bytes")
            let dims = ObjectModelStore.loadDimensions(package, object: objectID)
            r.near("demo.width", dims?.width, 0.40, 1e-3)
            r.near("demo.height", dims?.height, 0.30, 1e-3)
            r.near("demo.depth", dims?.depth, 0.25, 1e-3)
            r.near("demo.volume", dims?.volume, 0.03, 1e-4)
            let mesh = try ObjectModelStore.loadMesh(package, object: objectID)
            r.check("demo.mesh", mesh?.triangleCount == 12, "\(mesh?.triangleCount ?? -1) triangles")
            let problems = ProjectStore.verifyRawFolder(package.rawObjectURL(objectID))
            r.check("demo.sealVerifies", problems.isEmpty, problems.joined(separator: "; "))
            let logExists = fm.fileExists(atPath: package.rawObjectURL(objectID)
                .appendingPathComponent(ObjectCaptureLog.fileName, isDirectory: false).path)
            r.check("demo.objectLog", logExists)

            let built = ObjectResultModel.buildContent(package: package, objectID: objectID, dimensions: dims, largeTexture: false)
            let partsOK: Bool = built.content.parts.count == 3 && built.pickMesh?.triangleCount == 12
            r.check("demo.viewerContent", partsOK && built.problems.isEmpty, "\(built.content.parts.count) parts")

            var files = ObjectResultFiles()
            files.hasModel = modelURL != nil
            files.hasMesh = mesh != nil
            files.hasDimensions = dims != nil
            let shown = ObjectPresentation.availability(files: files, processing: ProjectProcessingState(), status: .ready,
                                                        progress: nil)
            r.check("demo.ready", shown == ObjectResultAvailability.ready && ObjectPresentation.canShowTextured(files: files))

            let gone = ProjectPackage(root: base.appendingPathComponent("gone.mapperproj", isDirectory: true))
            var refused = false
            do {
                _ = try ObjectDemo.makeDemoObject(package: gone, objectID: objectID, now: fixedDate)
            } catch {
                refused = true
            }
            r.check("demo.deletedPackageRefused", refused && !fm.fileExists(atPath: gone.root.path))
        } catch {
            r.fail("demo.io", error)
        }
    }
}
