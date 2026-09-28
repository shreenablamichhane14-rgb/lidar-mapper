import Foundation
import simd

// QualitySelfTest checks that touch files: a sealed room folder (pose track, keyframe log, one
// mesh chunk, capture log, no capturedroom.json) in a temporary package, the Done evaluation of
// it, QualityStore's save and load with the manifest update, and QualityStep's hash and run.
// Everything lives under FileManager.default.temporaryDirectory and is removed afterwards.
extension QualitySelfTest {
    /// Folder of the temporary package, removed before and after the checks.
    static let fileTestFolderName = "MapperQualitySelfTest"

    /// Runs the file checks in a fresh temporary folder.
    static func checkFiles(_ c: inout QualitySelfTestChecker) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(fileTestFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try fileChecks(&c, base: base)
        } catch {
            c.check("files.run", false, "\(error)")
        }
    }

    /// The file checks proper; any unexpected throw fails `files.run`.
    private static func fileChecks(_ c: inout QualitySelfTestChecker, base: URL) throws {
        let projectID = Fx.fixedID(900)
        let sessionID = Fx.fixedID(800)
        let roomID = Fx.fixedID(1)
        let name = projectID.uuidString + "." + ProjectPackage.fileExtension
        let package = ProjectPackage(root: base.appendingPathComponent(name, isDirectory: true))
        for folder in [package.rawURL, package.derivedURL] {
            try ProjectStore.ensureDirectory(folder)
        }
        let record = RoomRecord(id: roomID, name: "", sessionID: sessionID, floorIndex: 0, status: .captured,
                                capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 34,
                                capturedAt: Fx.fixedDate, frameLink: .projectFrame(sessionID: sessionID))
        var manifest = ProjectManifest.new(kind: .room, name: "Quality Self Test", now: Fx.fixedDate)
        manifest.id = projectID
        manifest.rooms = [record]
        try ProjectStore.writeManifest(manifest, to: package)
        let seal = try writeSealedRoom(package: package, record: record)

        let done = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, now: Fx.fixedDate)
        c.check("sealed.noCapturedRoomIsRoomPlanFailed", done.degraded == .roomPlanFailed, "\(done.degraded)")
        c.check("sealed.doneHash", done.inputHash == QualityEvaluator.doneInputHash(seal: seal))
        c.between("sealed.shapeFromRawMesh", Float(done.summary.shape), 0.9, 1)
        c.between("sealed.textureFromKeyframes", Float(done.summary.texture), 0.9, 1)
        c.check("sealed.logRead", done.evidence.trackingNormalFraction == 1 && done.darkKeyframeFraction == 0)
        var stranger = record
        stranger.id = Fx.fixedID(55)
        c.check("sealed.missingFolderThrows", throwsError {
            _ = try QualityEvaluator.evaluateSealedRoom(package: package, record: stranger, now: Fx.fixedDate)
        })

        try QualityStore.save(done, package: package)
        c.check("store.roundTrip", QualityStore.load(package, room: roomID) == done)
        let afterSave = try ManifestWriter.read(package)
        c.check("store.setsRoomRecordQuality", afterSave.rooms.first?.quality == done.summary)
        let expectedPath = "derived/rooms/" + roomID.uuidString + "/quality.json"
        c.check("store.path", QualityStore.url(package, room: roomID).path.hasSuffix(expectedPath))
        var stray = done
        stray.roomID = Fx.fixedID(99)
        try QualityStore.save(stray, package: package)
        let rooms = try ManifestWriter.read(package).rooms
        let strayWritten = QualityStore.load(package, room: stray.roomID) != nil
        let roomsUnchanged = rooms.count == 1 && rooms.first?.id == roomID
        c.check("store.roomNotListedWritesFileOnly", strayWritten && roomsUnchanged)
        c.check("store.missingIsNil", QualityStore.load(package, room: Fx.fixedID(98)) == nil)
        try ProjectStore.ensureDirectory(package.derivedRoomURL(Fx.fixedID(97)))
        try Data("not json".utf8).write(to: QualityStore.url(package, room: Fx.fixedID(97)))
        c.check("store.corruptIsNil", QualityStore.load(package, room: Fx.fixedID(97)) == nil)

        var index = DerivedIndex()
        index.record(DerivedStamp(step: .consolidateMesh, subject: roomID, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                  inputHash: "mesh-1", createdAt: Fx.fixedDate))
        try ProjectStore.writeJSON(index, to: package.derivedIndexURL)
        let step = QualityStep(room: record)
        let current = try ManifestWriter.read(package)
        let ctx = StepContext(package: package, manifest: current, availableMemory: 2_000_000_000,
                              isCancelled: { false }, progress: { _ in })
        let stepHash = try step.inputHash(ctx)
        c.check("step.hashUsesStamps",
                stepHash == QualityStep.inputHash(seal: seal, buildRoomStamp: nil, consolidateMeshStamp: "mesh-1"))
        c.check("step.hashDiffersFromDone", stepHash != done.inputHash)
        try step.evaluateAndSave(ctx)
        let stepped = QualityStore.load(package, room: roomID)
        c.check("step.supersedesDone", stepped?.inputHash == stepHash)
        c.check("step.fastMeshWithoutConsolidated", (stepped?.summary.shape ?? 0) >= 0.9)
        let afterStep = try ManifestWriter.read(package)
        c.check("step.updatesRoomRecord", afterStep.rooms.first?.quality == stepped?.summary)
        let fullBudget: UInt64 = 300 * 1024 * 1024
        let reducedBudget: UInt64 = 150 * 1024 * 1024
        c.check("step.id", step.id == PipelineStepID.quality)
        c.check("step.budgets", step.memoryBudgetBytes == fullBudget && step.reducedMemoryBudgetBytes == reducedBudget)
        c.check("step.reducedBelowFullBudget", QualityStep.usesReducedVariant(availableMemory: 200_000_000)
                && !QualityStep.usesReducedVariant(availableMemory: 400_000_000))
        let cancelled = StepContext(package: package, manifest: ctx.manifest, availableMemory: 2_000_000_000,
                                    isCancelled: { true }, progress: { _ in })
        c.check("step.cancelThrows", throwsError { try step.evaluateAndSave(cancelled) })
    }

    /// Writes the walk's pose track and keyframe log, the box mesh as one raw chunk and a
    /// capture log into the room's raw folder, then seals it.
    private static func writeSealedRoom(package: ProjectPackage, record: RoomRecord) throws -> SealFile {
        let url = package.rawRoomURL(session: record.sessionID, room: record.id)
        let folder = RawScanFolder(url: url)
        try ProjectStore.ensureDirectory(folder.meshURL)
        let walk = Fx.walk()
        var writer = ByteWriter()
        PoseTrackFile.appendHeader(to: &writer)
        for sample in Fx.poses(walk) {
            PoseTrackFile.append(sample, to: &writer)
        }
        try writer.data.write(to: folder.poseTrackURL)
        var lines = Data()
        for frame in Fx.keyframes(walk, ambient: 1000) {
            lines.append(try ProjectStore.encoder.encode(frame))
            lines.append(0x0A)
        }
        try lines.write(to: folder.keyframesLogURL)
        let mesh = Fx.boxMesh()
        let anchor = Fx.fixedID(700)
        let chunk = MeshChunk(anchorID: anchor, transform: matrix_identity_float4x4, updateCount: 1,
                              positions: mesh.mesh.positions, indices: mesh.mesh.indices, classes: mesh.faceClass ?? [])
        try MeshChunkFile.encode(chunk).write(to: folder.meshChunkURL(anchor: anchor))
        let log = RoomCaptureLog(seconds: 17, instructionSeconds: [:], error: nil, relocalizations: 0,
                                 limitedTrackingFraction: 0, degraded: .allGood)
        try ProjectStore.writeJSON(log, to: folder.roomLogURL)
        return try ProjectStore.sealRawFolder(url, now: Fx.fixedDate)
    }

    /// True when `body` throws.
    static func throwsError(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }
}
