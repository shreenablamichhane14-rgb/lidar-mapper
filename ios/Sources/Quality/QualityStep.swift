import Foundation

/// Re-evaluates with the consolidated mesh (falls back to the fast mesh when there is none) and
/// the rebuilt room. `inputHash` = InputHasher.hash(seals: [room seal], editRevision: nil,
/// extra: [buildRoom stamp hash or "-", consolidateMesh stamp hash or "-"]), so it runs after
/// the Done evaluation (extra ["done"]) and again whenever the room or mesh is rebuilt.
///
/// Pipeline step `.quality` for one room (docs/ARCHITECTURE.md 5.2): reads the room's sealed
/// folder (pose track, keyframes, capture log), RoomPlan's saved room (raw or rebuilt
/// `capturedroom.json`, never RoomBuilder) and `mesh.mchk`, then writes `quality.json` and
/// `RoomRecord.quality` through `QualityStore`. Optional in every plan: a room that left the
/// project or has no raw folder completes without output. The runner calls `run` off main and
/// records the stamp.
final class QualityStep: ProcessingStep {
    /// Peak memory of the full variant, bytes (300 MB).
    static let fullBudgetBytes: UInt64 = 300 * 1024 * 1024
    /// Peak memory of the reduced variant, bytes (150 MB).
    static let reducedBudgetBytes: UInt64 = 150 * 1024 * 1024
    /// Most faces the reduced variant scores (the full variant uses
    /// `QualityEvaluator.maxEvaluationFaces`).
    static let reducedFaceLimit = 60_000

    /// Always `.quality`.
    let id: PipelineStepID = .quality
    /// The room this step evaluates (the stamp subject).
    let room: RoomRecord

    /// Full budget, 300 MB.
    var memoryBudgetBytes: UInt64 { QualityStep.fullBudgetBytes }
    /// Reduced budget, 150 MB: the same evaluation over fewer faces.
    var reducedMemoryBudgetBytes: UInt64? { QualityStep.reducedBudgetBytes }

    /// A step for one room.
    init(room: RoomRecord) {
        self.room = room
    }

    // MARK: - Hash

    /// The room seal plus the room's current `buildRoom` and `consolidateMesh` stamp hashes
    /// from `derived/index.json` ("-" when absent). The variant is not hashed.
    func inputHash(_ ctx: StepContext) throws -> String {
        let folder = CapturedRoomStore.rawFolder(ctx.package, room: room)
        let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        let index = try? ProjectStore.readJSON(DerivedIndex.self, from: ctx.package.derivedIndexURL)
        let built = index?.stamp(step: .buildRoom, subject: room.id)?.inputHash
        let mesh = index?.stamp(step: .consolidateMesh, subject: room.id)?.inputHash
        return QualityStep.inputHash(seal: seal, buildRoomStamp: built, consolidateMeshStamp: mesh)
    }

    /// The step hash for a seal and the two stamp hashes (nil stamps hash as "-").
    static func inputHash(seal: SealFile?, buildRoomStamp: String?, consolidateMeshStamp: String?) -> String {
        InputHasher.hash(seals: seal.map { [$0] } ?? [], editRevision: nil,
                         extra: [buildRoomStamp ?? "-", consolidateMeshStamp ?? "-"])
    }

    // MARK: - Run

    /// True when the reduced variant runs for this much available memory (below the full budget).
    static func usesReducedVariant(availableMemory: UInt64) -> Bool {
        availableMemory < fullBudgetBytes
    }

    /// Loads the inputs, evaluates and saves. Throws `MapperError.cancelled` when cancelled,
    /// `MapperError.outOfMemory` below the reduced budget and `MapperError.ioFailed` when the
    /// result cannot be written (for example the project was deleted meanwhile).
    func run(_ ctx: StepContext) async throws {
        try evaluateAndSave(ctx)
    }

    /// The synchronous body of `run` (it never suspends); the self-test calls it directly.
    func evaluateAndSave(_ ctx: StepContext) throws {
        let started = ProcessInfo.processInfo.systemUptime
        try ctx.checkCancelled()
        let reduced = QualityStep.usesReducedVariant(availableMemory: ctx.availableMemory)
        if reduced && ctx.availableMemory < QualityStep.reducedBudgetBytes {
            throw MapperError.outOfMemory(step: id)
        }
        guard let record = ctx.manifest.rooms.first(where: { $0.id == room.id }) else {
            log("no longer in the project; nothing written")
            ctx.progress(1)
            return
        }
        let folder = CapturedRoomStore.rawFolder(ctx.package, room: record)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("raw folder missing; nothing written")
            ctx.progress(1)
            return
        }
        ctx.progress(0.05)
        let files = QualityRoomFiles.load(folder, roomID: record.id)
        try ctx.checkCancelled()
        ctx.progress(0.15)

        var source = "consolidated"
        var mesh: MeshWithAttributes?
        do {
            mesh = try MeshModelStore.loadMeasured(ctx.package, room: record.id)
        } catch {
            log("mesh.mchk unreadable (\(error)); using the raw chunks")
        }
        if mesh.map({ $0.triangleCount == 0 }) ?? true {
            source = "fast"
            mesh = MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [folder]))
        }
        let worldMesh = mesh ?? MeshWithAttributes(mesh: TriangleMesh())
        try ctx.checkCancelled()
        ctx.progress(0.35)

        let cleanRoom = QualityEvaluator.cleanRoom(package: ctx.package, record: record, mesh: worldMesh,
                                                   findFurniture: ctx.manifest.settings.findFurniture)
        let hash = try inputHash(ctx)
        try ctx.checkCancelled()
        ctx.progress(0.45)
        let loaded = ProcessInfo.processInfo.systemUptime

        let limit = reduced ? QualityStep.reducedFaceLimit : QualityEvaluator.maxEvaluationFaces
        let result = QualityEvaluator.evaluateRecords(roomID: record.id, room: cleanRoom, mesh: worldMesh, poses: files.poses,
                                                      keyframes: files.keyframes, log: files.log, inputHash: hash,
                                                      now: Date(), faceLimit: limit)
        let scored = ProcessInfo.processInfo.systemUptime
        try ctx.checkCancelled()
        ctx.progress(0.9)

        do {
            try QualityStore.save(result.evaluation, package: ctx.package)
        } catch {
            throw MapperError.ioFailed("quality save failed: \(error)")
        }
        ctx.progress(1)
        let variant = reduced ? "reduced" : "full"
        let timings = [("load", loaded - started), ("score", scored - loaded),
                       ("save", ProcessInfo.processInfo.systemUptime - scored)]
        QualityEvaluator.logSummary(label: "quality step (\(variant), \(source) mesh)", result: result,
                                    meshTriangles: worldMesh.triangleCount, timings: timings)
    }

    /// Writes a log line for this room.
    private func log(_ message: String) {
        LogStore.shared.write("quality step room \(room.id): \(message)", category: QualityEvaluator.logCategory)
    }
}
