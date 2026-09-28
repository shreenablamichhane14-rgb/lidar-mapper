import Foundation
import simd

/// Pipeline step `.consolidateMesh` for one room (docs/ARCHITECTURE.md 5.2 and 5.4): reads the
/// raw mesh chunks of the room folder and its mesh passes, consolidates them and writes
/// `mesh.mchk`, `mesh_inferred.mchk`, `mesh_view.mchk`, `mesh_floaters.mchk` and
/// `mesh_stats.json` under `derived/rooms/<room>/`. Optional in every plan: a room without
/// chunks (`meshStripped`) completes, writes nothing and logs.
///
/// Budget 700 MB full, 350 MB reduced. The step picks the variant with the runner's rule
/// (full when `ctx.availableMemory` is at least the full budget plus 300 MB headroom), so a
/// runner that caps `availableMemory` just under that forces the reduced variant: each chunk
/// halved before merging and a 150k view budget. It holds one room's mesh at a time and
/// releases the decoded chunks before the heavy stages.
final class ConsolidateMeshStep: ProcessingStep {
    /// Peak memory of the full variant, bytes.
    static let fullBudgetBytes: UInt64 = 700_000_000
    /// Peak memory of the reduced variant, bytes.
    static let reducedBudgetBytes: UInt64 = 350_000_000
    /// Headroom the runner requires above a budget (Pipeline `ProcessingGuards.headroomBytes`,
    /// same wave, so repeated here).
    static let headroomBytes: UInt64 = 300_000_000
    /// View mesh budget of the reduced variant.
    static let reducedViewTriangleBudget = 150_000
    /// Version tag of the consolidation settings in the input hash; bump it when the defaults
    /// of `ConsolidationOptions` change so every room reruns.
    static let settingsTag = "consolidate-v1"
    /// Pose tracks larger than this are not read for the depth window crop.
    static let maxPoseTrackBytes: Int64 = 64 * 1024 * 1024

    /// Always `.consolidateMesh`.
    let id: PipelineStepID = .consolidateMesh
    /// The room this step consolidates (the stamp subject).
    let roomID: UUID
    /// The room folder plus its mesh passes, oldest first (later folders win per anchor).
    let folders: [RawScanFolder]

    /// Full budget, 700 MB.
    var memoryBudgetBytes: UInt64 { ConsolidateMeshStep.fullBudgetBytes }
    /// Reduced budget, 350 MB.
    var reducedMemoryBudgetBytes: UInt64? { ConsolidateMeshStep.reducedBudgetBytes }

    /// folders: the room folder plus its mesh passes.
    init(roomID: UUID, folders: [RawScanFolder]) {
        self.roomID = roomID
        self.folders = folders
    }

    // MARK: - Pure rules

    /// True when the reduced variant runs for this much available memory.
    static func usesReducedVariant(availableMemory: UInt64) -> Bool {
        availableMemory < fullBudgetBytes + headroomBytes
    }

    /// Options of the full or reduced variant, with the Advanced depth window when given.
    static func options(reduced: Bool, depthWindow: ClosedRange<Float>?,
                        viewpoints: [SIMD3<Float>] = []) -> ConsolidationOptions {
        var options = ConsolidationOptions()
        if reduced {
            options.simplifyChunksBeforeMerge = true
            options.viewTriangleBudget = reducedViewTriangleBudget
        }
        if let window = depthWindow {
            options.depthWindow = window
            options.viewpoints = viewpoints
        }
        return options
    }

    /// The distance crop for a project: `ScanSettings.depthWindow` for the Advanced modes (the
    /// only place the user picks a scanning distance, build 6), nil for every other mode.
    static func depthWindow(for manifest: ProjectManifest) -> ClosedRange<Float>? {
        switch manifest.kind {
        case .advancedSpace, .advancedObject:
            return manifest.settings.depthWindow
        case .room, .house, .object, .quickMeasure:
            return nil
        }
    }

    /// Input hash text of a depth window ("none" without one).
    static func cropTag(_ window: ClosedRange<Float>?) -> String {
        guard let window = window else { return "crop=none" }
        return "crop=\(window.lowerBound)...\(window.upperBound)"
    }

    /// Camera positions from the pose tracks of `folders` (unreadable tracks are skipped).
    static func viewpoints(in folders: [RawScanFolder]) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for folder in folders {
            let url = folder.poseTrackURL
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  Int64(values.fileSize ?? 0) <= maxPoseTrackBytes,
                  let data = try? Data(contentsOf: url),
                  let samples = try? PoseTrackFile.decode(data) else { continue }
            points.reserveCapacity(points.count + samples.count)
            for sample in samples {
                let c = sample.transform.columns.3
                points.append(SIMD3<Float>(c.x, c.y, c.z))
            }
        }
        return points
    }

    // MARK: - ProcessingStep

    /// `InputHasher.hash` over the seals of all given folders (a folder without `SEAL.json` is
    /// listed on the fly and marked, a missing folder is marked), plus the settings tag and
    /// the depth window. The variant is not hashed: the runner may cap memory after hashing.
    func inputHash(_ ctx: StepContext) throws -> String {
        var seals: [SealFile] = []
        var extra: [String] = ["step=\(ConsolidateMeshStep.settingsTag)"]
        for folder in folders {
            let name = folder.url.lastPathComponent
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL) {
                seals.append(seal)
            } else if let listed = try? SealFile.make(folder: folder.url) {
                seals.append(listed)
                extra.append("unsealed=\(name)")
            } else {
                extra.append("missing=\(name)")
            }
        }
        extra.append(ConsolidateMeshStep.cropTag(ConsolidateMeshStep.depthWindow(for: ctx.manifest)))
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// Decodes, consolidates and saves. Throws `MapperError.cancelled` when cancelled,
    /// `MapperError.outOfMemory` below the reduced budget and `MapperError.ioFailed` when the
    /// outputs cannot be written (for example the project was deleted meanwhile).
    func run(_ ctx: StepContext) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        try ctx.checkCancelled()
        let reduced = ConsolidateMeshStep.usesReducedVariant(availableMemory: ctx.availableMemory)
        if reduced && ctx.availableMemory < ConsolidateMeshStep.reducedBudgetBytes {
            throw MapperError.outOfMemory(step: id)
        }
        let window = ConsolidateMeshStep.depthWindow(for: ctx.manifest)
        let points = window == nil ? [] : ConsolidateMeshStep.viewpoints(in: folders)
        let options = ConsolidateMeshStep.options(reduced: reduced, depthWindow: window, viewpoints: points)
        ctx.progress(0.02)

        guard let stage = try mergeStage(ctx, options: options) else {
            LogStore.shared.write("consolidateMesh room \(roomID.uuidString): no mesh chunks in \(folders.count) folder(s), nothing written",
                                  category: MeshConsolidator.logCategory)
            ctx.progress(1)
            return
        }
        ctx.progress(0.45)
        try ctx.checkCancelled()

        let inputFaces = stage.inputFaces
        guard let result = MeshConsolidator.finish(stage.mesh, chunkCount: stage.chunkCount, options: options,
                                                   isCancelled: ctx.isCancelled) else {
            throw MapperError.cancelled
        }
        try ctx.checkCancelled()
        ctx.progress(0.9)

        do {
            try MeshModelStore.save(result, package: ctx.package, room: roomID)
        } catch {
            throw MapperError.ioFailed("consolidateMesh save failed: \(error)")
        }
        ctx.progress(1)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let stats = result.stats
        let variant = reduced ? "reduced" : "full"
        let parts: [String] = [
            "consolidateMesh room \(roomID.uuidString) \(variant)",
            "\(stats.chunkCount) chunks",
            "\(inputFaces) raw faces",
            "\(stats.triangleCount) measured",
            "\(stats.viewTriangleCount) view",
            "\(stats.inferredTriangleCount) inferred",
            "\(result.floaters.triangleCount) floaters",
            String(format: "%.1f s", seconds),
            "available \(ctx.availableMemory / 1_000_000) MB at start"
        ]
        let summary = parts.joined(separator: ", ")
        LogStore.shared.write(summary, category: MeshConsolidator.logCategory)
    }

    /// Decodes the latest chunks (one folder at a time) and merges them; the chunks are
    /// released when this returns. Nil when there are no chunks; throws when cancelled.
    private func mergeStage(_ ctx: StepContext,
                            options: ConsolidationOptions) throws -> (mesh: MeshWithAttributes, chunkCount: Int, inputFaces: Int)? {
        let chunks = MeshConsolidator.latestChunks(in: folders)
        guard !chunks.isEmpty else { return nil }
        try ctx.checkCancelled()
        ctx.progress(0.2)
        let inputFaces = chunks.reduce(0) { $0 + $1.faceCount }
        guard let merged = MeshConsolidator.mergedWorldMesh(chunks, options: options, isCancelled: ctx.isCancelled) else {
            throw MapperError.cancelled
        }
        return (merged, chunks.count, inputFaces)
    }
}
