import Foundation
import simd

/// id .objectMetrics, subject = object id; required in both object plans; budget 300 MB.
/// `modelFile` (AppShell passes `PhotogrammetryStore.modelURLIfPresent`) and `reportedExtents`
/// (`PhotogrammetryStore.loadInfo(...)?.boundsExtents`) come from ObjectCapture, the same wave.
///
/// Small and medium: reads the model with ModelIO, or with the RealityKit fallback when ModelIO
/// cannot (logged with the path taken; the step fails only when both fail), applies the unit
/// check against the photogrammetry bounds, measures and writes `mesh.mchk` then `dims.json`.
/// Large: isolates the object from its consolidated LiDAR mesh inside the crop box (LargeObject's
/// `cropObject` edit) and writes the same two files. Every result is logged.
///
/// Reduced variant (150 MB, picked when `ctx.availableMemory < memoryBudgetBytes`, as the
/// runner does after a death or on a hot phone): a large object's consolidated mesh is first
/// cropped to the box grown by `reducedCropMargin` (centroid test, a superset of the faces the
/// isolation keeps) and released before the isolation, so the result is the same with a lower
/// peak. A small or medium model (Object Capture `.reduced`, under 50k triangles) needs far less
/// than either budget, so both variants run the same code for it.
///
/// ModelIO guard: before calling ModelIO the step writes `modelio_attempt` into the object's
/// derived folder and removes it when ModelIO returns or throws. A marker found at the start
/// means ModelIO never returned on this file (the app died inside it), so that run and every
/// later one go straight to the RealityKit loader.
final class ObjectMetricsStep: ProcessingStep {
    /// Version tag of the measuring rules in the input hash; bump it to remeasure every object.
    static let rulesVersion = "objectMetrics-rules=1"
    /// Peak memory of the full variant, bytes.
    static let fullBudgetBytes: UInt64 = 300_000_000
    /// Peak memory of the reduced variant, bytes.
    static let reducedBudgetBytes: UInt64 = 150_000_000
    /// Margin added on every side of the crop box for the reduced pre-crop, meters.
    static let reducedCropMargin: Float = 0.25
    /// File name of the ModelIO guard marker inside `derived/objects/<id>/`.
    static let modelIOMarkerName = "modelio_attempt"

    /// Always `.objectMetrics`.
    let id: PipelineStepID = .objectMetrics
    /// The object this step measures (the stamp subject is its id).
    let object: ObjectRecord
    /// The finished Object Capture model file of an object, nil when there is none.
    private let modelFile: (ProjectPackage, UUID) -> URL?
    /// The photogrammetry `.bounds` extents of an object (meters), nil when not reported.
    private let reportedExtents: (ProjectPackage, UUID) -> SIMD3<Float>?

    /// Full budget, 300 MB.
    var memoryBudgetBytes: UInt64 { ObjectMetricsStep.fullBudgetBytes }
    /// Reduced budget, 150 MB.
    var reducedMemoryBudgetBytes: UInt64? { ObjectMetricsStep.reducedBudgetBytes }

    /// A loaded model mesh and the loader that produced it.
    private struct LoadedModel {
        /// The welded mesh in the file's frame.
        var mesh: MeshWithAttributes
        /// "ModelIO" or "RealityKit".
        let loader: String
    }

    /// modelFile and reportedExtents: ObjectCapture's closures, wired by AppShell.
    init(object: ObjectRecord,
         modelFile: @escaping (ProjectPackage, UUID) -> URL?,
         reportedExtents: @escaping (ProjectPackage, UUID) -> SIMD3<Float>?) {
        self.object = object
        self.modelFile = modelFile
        self.reportedExtents = reportedExtents
    }

    // MARK: - Pure rules

    /// True when the reduced variant runs for this much available memory (Core's rule: below
    /// the full budget).
    static func usesReducedVariant(availableMemory: UInt64) -> Bool {
        availableMemory < fullBudgetBytes
    }

    /// The step whose stamp feeds the input hash: `.reconstructObject` for small and medium,
    /// `.consolidateMesh` (subject = object id) for large objects.
    static func upstreamStep(for size: ObjectSize) -> PipelineStepID {
        switch size {
        case .smallMedium:
            return .reconstructObject
        case .large:
            return .consolidateMesh
        }
    }

    /// Input hash from its parts: small and medium hash the upstream stamp hash and
    /// `rulesVersion`; large objects add `cropDigest` (not the edit revision, so only crop edits
    /// remeasure).
    static func hash(size: ObjectSize, upstream: String, cropDigest: String) -> String {
        switch size {
        case .smallMedium:
            return InputHasher.hash(seals: [], editRevision: nil, extra: ["reconstructObject=" + upstream, rulesVersion])
        case .large:
            return InputHasher.hash(seals: [], editRevision: nil,
                                    extra: ["consolidateMesh=" + upstream, "crop=" + cropDigest, rulesVersion])
        }
    }

    /// The current stamp `inputHash` of `step` for `subject` in `derived/index.json`, "-" when the
    /// index or the stamp is missing (an unreadable index is logged).
    static func upstreamHash(_ package: ProjectPackage, step: PipelineStepID, subject: UUID) -> String {
        let url = package.derivedIndexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return "-" }
        do {
            let index = try ProjectStore.readJSON(DerivedIndex.self, from: url)
            return index.stamp(step: step, subject: subject)?.inputHash ?? "-"
        } catch {
            LogStore.shared.write("objectMetrics: derived index unreadable (\(error)); upstream hash taken as missing",
                                  category: ObjectModelLoader.logCategory)
            return "-"
        }
    }

    /// Scales every position by `scale` about the origin (the file frame), in place. Nothing
    /// changes for 1 or an unusable factor.
    static func applyScale(_ mesh: inout MeshWithAttributes, _ scale: Float) {
        guard scale != 1, scale.isFinite, scale > 0 else { return }
        for i in mesh.mesh.positions.indices {
            mesh.mesh.positions[i] *= scale
        }
    }

    /// The small and medium measurement: unit check of the mesh's axis-aligned extents against
    /// `reportedExtents`, positions scaled in place when the correction is not 1, then
    /// `ObjectDimensions.measure`. Nil when the mesh has nothing to measure.
    static func smallMediumRecord(_ mesh: inout MeshWithAttributes, reportedExtents: SIMD3<Float>?, objectID: UUID,
                                  inputHash: String, now: Date) -> ObjectDimensionsRecord? {
        let extents: SIMD3<Float> = mesh.mesh.boundingBox.size
        let scale = ObjectDimensions.scaleCorrection(meshExtents: extents, reportedExtents: reportedExtents)
        applyScale(&mesh, scale)
        return ObjectDimensions.measure(mesh, objectID: objectID, source: .smallMedium, scaleCorrection: scale,
                                        inputHash: inputHash, now: now)
    }

    /// The consolidated mesh cropped to `box` grown by `reducedCropMargin` (face centroids), a
    /// superset of the faces `ObjectIsolation` keeps inside `box`.
    static func preCropped(_ mesh: MeshWithAttributes, box: OrientedBox) -> MeshWithAttributes {
        var grown = box
        grown.halfExtents += SIMD3<Float>(repeating: reducedCropMargin)
        return MeshCrop.crop(mesh, region: .orientedBox(grown), mode: .keepInside, test: .centroid)
    }

    /// `derived/objects/<id>/modelio_attempt`.
    static func modelIOMarkerURL(_ package: ProjectPackage, object: UUID) -> URL {
        package.derivedObjectURL(object).appendingPathComponent(modelIOMarkerName, isDirectory: false)
    }

    // MARK: - ProcessingStep

    /// Small and medium: the object's `reconstructObject` stamp hash ("-" when none) plus
    /// `rulesVersion`. Large: its `consolidateMesh` stamp hash plus `cropDigest` plus
    /// `rulesVersion`. Stamps are read from `derived/index.json`.
    func inputHash(_ ctx: StepContext) throws -> String {
        let upstream = ObjectMetricsStep.upstreamHash(ctx.package, step: ObjectMetricsStep.upstreamStep(for: object.size),
                                                      subject: object.id)
        switch object.size {
        case .smallMedium:
            return ObjectMetricsStep.hash(size: .smallMedium, upstream: upstream, cropDigest: "-")
        case .large:
            let digest = ObjectModelStore.cropDigest(for: object.id, in: EditStore.load(ctx.package))
            return ObjectMetricsStep.hash(size: .large, upstream: upstream, cropDigest: digest)
        }
    }

    /// Measures and saves. Throws `MapperError.cancelled` when cancelled, `.outOfMemory` below
    /// the reduced budget, `.processingFailed` when there is no input (no model file, no crop
    /// box, no consolidated mesh), both loaders fail or nothing is measurable, and `.ioFailed`
    /// when the outputs cannot be written (for example the project was deleted meanwhile).
    func run(_ ctx: StepContext) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        try ctx.checkCancelled()
        let reduced = ObjectMetricsStep.usesReducedVariant(availableMemory: ctx.availableMemory)
        if reduced && ctx.availableMemory < ObjectMetricsStep.reducedBudgetBytes {
            throw MapperError.outOfMemory(step: id)
        }
        let hash = (try? inputHash(ctx)) ?? "-"
        ctx.progress(0.02)
        switch object.size {
        case .smallMedium:
            try await runSmallMedium(ctx, hash: hash, reduced: reduced, started: started)
        case .large:
            try runLarge(ctx, hash: hash, reduced: reduced, started: started)
        }
        ctx.progress(1)
    }

    // MARK: - Small and medium

    /// Loads, checks units, measures and saves the Object Capture model.
    private func runSmallMedium(_ ctx: StepContext, hash: String, reduced: Bool, started: Double) async throws {
        guard let url = modelFile(ctx.package, object.id), ObjectMetricsStep.isRegularFile(url) else {
            throw MapperError.processingFailed(step: id, reason: "no model file for object \(object.id.uuidString)")
        }
        var loaded = try await loadModelMesh(url, package: ctx.package)
        try ctx.checkCancelled()
        ctx.progress(0.5)
        let loadedExtents: SIMD3<Float> = loaded.mesh.mesh.boundingBox.size
        let reported = reportedExtents(ctx.package, object.id)
        guard let record = ObjectMetricsStep.smallMediumRecord(&loaded.mesh, reportedExtents: reported, objectID: object.id,
                                                              inputHash: hash, now: Date()) else {
            throw MapperError.processingFailed(step: id, reason: "model of object \(object.id.uuidString) has nothing to measure")
        }
        try ctx.checkCancelled()
        ctx.progress(0.8)
        try save(loaded.mesh, record: record, package: ctx.package)
        let reportedText = reported.map { ObjectModelLoader.vectorText($0) } ?? "none"
        let extra: [String] = [
            "loader \(loaded.loader)",
            "model extents " + ObjectModelLoader.vectorText(loadedExtents),
            "reported extents " + reportedText
        ]
        logResult(record, reduced: reduced, extra: extra, started: started)
    }

    /// The model mesh from ModelIO, or from the RealityKit fallback when ModelIO cannot import
    /// USDZ, throws, or died on this file before (marker present). Throws
    /// `MapperError.processingFailed` only when both loaders fail.
    private func loadModelMesh(_ url: URL, package: ProjectPackage) async throws -> LoadedModel {
        let short = String(object.id.uuidString.prefix(8))
        let marker = ObjectMetricsStep.modelIOMarkerURL(package, object: object.id)
        let problem: String
        if FileManager.default.fileExists(atPath: marker.path) {
            problem = "ModelIO skipped: it did not return on this file in an earlier run"
        } else if !ObjectModelLoader.canReadUSDZ {
            problem = "ModelIO cannot import usdz"
        } else {
            let marked = ObjectMetricsStep.writeMarker(marker, package: package)
            do {
                let mesh = try ObjectModelLoader.mesh(fromUSDZ: url)
                if marked { ObjectMetricsStep.removeMarker(marker) }
                LogStore.shared.write("objectMetrics \(short): mesh from the ModelIO loader", category: ObjectModelLoader.logCategory)
                return LoadedModel(mesh: mesh, loader: "ModelIO")
            } catch {
                if marked { ObjectMetricsStep.removeMarker(marker) }
                problem = "ModelIO failed: \(error)"
            }
        }
        LogStore.shared.write("objectMetrics \(short): \(problem); trying the RealityKit loader",
                              category: ObjectModelLoader.logCategory)
        do {
            let mesh = try await ObjectModelLoader.meshFromEntity(at: url)
            LogStore.shared.write("objectMetrics \(short): mesh from the RealityKit loader", category: ObjectModelLoader.logCategory)
            return LoadedModel(mesh: mesh, loader: "RealityKit")
        } catch {
            throw MapperError.processingFailed(step: .objectMetrics, reason: "\(problem); RealityKit failed: \(error)")
        }
    }

    // MARK: - Large

    /// Isolates the object inside its crop box and saves it.
    private func runLarge(_ ctx: StepContext, hash: String, reduced: Bool, started: Double) throws {
        let log = EditStore.load(ctx.package)
        guard let box = ObjectModelStore.cropBox(for: object.id, in: log) else {
            throw MapperError.processingFailed(step: id, reason: "no crop box")
        }
        let result = try isolateLarge(ctx.package, box: box, reduced: reduced, hash: hash)
        try ctx.checkCancelled()
        ctx.progress(0.8)
        try save(result.mesh, record: result.record, package: ctx.package)
        let extra: [String] = [
            "crop box half extents " + ObjectModelLoader.vectorText(box.halfExtents),
            "open side \(result.record.provenance == .estimated ? "yes" : "no")"
        ]
        logResult(result.record, reduced: reduced, extra: extra, started: started)
    }

    /// `ObjectDimensions.isolate` of the consolidated mesh; the consolidated mesh is released
    /// when this returns.
    private func isolateLarge(_ package: ProjectPackage, box: OrientedBox, reduced: Bool,
                              hash: String) throws -> (record: ObjectDimensionsRecord, mesh: MeshWithAttributes) {
        let source = try loadLargeSource(package, box: box, reduced: reduced)
        guard let result = ObjectDimensions.isolate(source, box: box, objectID: object.id, inputHash: hash, now: Date()) else {
            throw MapperError.processingFailed(step: id, reason: "nothing inside the crop box")
        }
        return result
    }

    /// The object's consolidated mesh (LargeObject's ConsolidateMeshStep uses the object id as
    /// its subject), pre-cropped in the reduced variant.
    private func loadLargeSource(_ package: ProjectPackage, box: OrientedBox, reduced: Bool) throws -> MeshWithAttributes {
        let loaded: MeshWithAttributes?
        do {
            loaded = try MeshModelStore.loadMeasured(package, room: object.id)
        } catch {
            throw MapperError.processingFailed(step: id, reason: "consolidated mesh unreadable: \(error)")
        }
        guard let full = loaded, full.triangleCount > 0 else {
            throw MapperError.processingFailed(step: id, reason: "no consolidated mesh")
        }
        return reduced ? ObjectMetricsStep.preCropped(full, box: box) : full
    }

    // MARK: - Files and log

    /// Writes mesh.mchk, then dims.json (so a dims.json always has its mesh).
    private func save(_ mesh: MeshWithAttributes, record: ObjectDimensionsRecord, package: ProjectPackage) throws {
        do {
            try ObjectModelStore.saveMesh(mesh, package: package, object: object.id)
            try ObjectModelStore.saveDimensions(record, to: package)
        } catch {
            throw MapperError.ioFailed("objectMetrics save failed: \(error)")
        }
    }

    /// True when `url` names an existing file (not a folder).
    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Writes the ModelIO guard marker; false (logged) when it cannot be written.
    private static func writeMarker(_ url: URL, package: ProjectPackage) -> Bool {
        do {
            try ProjectStore.ensureDirectory(url.deletingLastPathComponent(), inside: package.root)
            try ProjectStore.writeData(Data("ModelIO read started\n".utf8), to: url, createParents: false)
            return true
        } catch {
            LogStore.shared.write("objectMetrics: ModelIO marker not written (\(error))", category: ObjectModelLoader.logCategory)
            return false
        }
    }

    /// Removes the ModelIO guard marker (a failure is logged).
    private static func removeMarker(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogStore.shared.write("objectMetrics: ModelIO marker not removed (\(error))", category: ObjectModelLoader.logCategory)
        }
    }

    /// One log line with the sides, surface area, watertightness, volume or its reason,
    /// triangles, scale correction, provenance, variant and time.
    private func logResult(_ record: ObjectDimensionsRecord, reduced: Bool, extra: [String], started: Double) {
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let sides = String(format: "%.4f x %.4f x %.4f m", Double(record.width), Double(record.height), Double(record.depth))
        let volumeText: String
        if let volume = record.volume {
            volumeText = String(format: "volume %.6f m3", Double(volume))
        } else {
            volumeText = "volume unavailable (\(record.volumeUnavailableReason?.rawValue ?? "unknown"))"
        }
        var fields: [String] = [
            "objectMetrics object \(object.id.uuidString) \(object.size.rawValue) \(reduced ? "reduced" : "full")",
            "sides " + sides,
            String(format: "surface area %.4f m2", Double(record.surfaceArea)),
            "watertight \(record.isWatertight ? "yes" : "no")",
            volumeText,
            "\(record.triangleCount) triangles",
            "scale correction \(record.scaleCorrection)",
            "provenance \(record.provenance.rawValue)"
        ]
        fields.append(contentsOf: extra)
        fields.append(String(format: "%.2f s", seconds))
        LogStore.shared.write(fields.joined(separator: ", "), category: ObjectModelLoader.logCategory)
    }
}
