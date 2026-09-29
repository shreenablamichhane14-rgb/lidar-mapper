import Foundation
import simd

// QualitySelfTest checks that touch files: a sealed room folder (pose track, keyframe log, one
// mesh chunk, capture log, no capturedroom.json) in a temporary package, the Done evaluation of
// it, QualityStore's save and load with the manifest update, and QualityStep's hash and run.
// CR-10: in a second package, a room scanned without looking at wall 2 plus mesh-pass folders
// (one sealed pass looking at wall 2, an unsealed one, one of another room, a missing one).
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
        do {
            try passChecks(&c, base: base)
        } catch {
            c.check("passes.run", false, "\(error)")
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

    // MARK: - Mesh passes (CR-10)

    /// Mesh-pass folders in their own temporary package: loading and concatenation, the skip
    /// rules, the walls score an extra pass raises, the Done evaluation and hashes with and
    /// without passes, and QualityStep with passes.
    private static func passChecks(_ c: inout QualitySelfTestChecker, base: URL) throws {
        let projectID = Fx.fixedID(901)
        let sessionID = Fx.fixedID(801)
        let roomID = Fx.fixedID(2)
        let name = projectID.uuidString + "." + ProjectPackage.fileExtension
        let package = ProjectPackage(root: base.appendingPathComponent(name, isDirectory: true))
        for folder in [package.rawURL, package.derivedURL] {
            try ProjectStore.ensureDirectory(folder)
        }
        let record = RoomRecord(id: roomID, name: "", sessionID: sessionID, floorIndex: 0, status: .captured,
                                capturedRoomID: nil, quality: nil, hasMeshPass: true, keyframeCount: 28,
                                capturedAt: Fx.fixedDate, frameLink: .projectFrame(sessionID: sessionID))
        var manifest = ProjectManifest.new(kind: .room, name: "Quality Pass Self Test", now: Fx.fixedDate)
        manifest.id = projectID
        manifest.rooms = [record]
        try ProjectStore.writeManifest(manifest, to: package)

        /// scan.json of a mesh pass of `room`.
        func passInfo(_ pass: UUID, room: UUID) -> InProgressScanInfo {
            InProgressScanInfo(scanID: pass, projectID: projectID, sessionID: sessionID, roomID: room, kind: .meshPass,
                               mode: .room, startedAt: Fx.fixedDate)
        }
        let hidden = Fx.walkHidingWall2()
        let looks = Fx.walk().filter { abs($0.heading - 90) <= 30 && abs($0.pitch) < 70 }
        let roomFolder = CapturedRoomStore.rawFolder(package, room: record)
        let roomSeal = try writeRawFolder(roomFolder, walk: hidden, timeOffset: 0, withMesh: true, withLog: true,
                                          info: nil, seal: true)
        let passA = RawScanFolder(url: package.rawMeshPassURL(session: sessionID, pass: Fx.fixedID(810)))
        let passSeal = try writeRawFolder(passA, walk: looks, timeOffset: 100, withMesh: false, withLog: false,
                                          info: passInfo(Fx.fixedID(810), room: roomID), seal: true)
        let unsealed = RawScanFolder(url: package.rawMeshPassURL(session: sessionID, pass: Fx.fixedID(811)))
        _ = try writeRawFolder(unsealed, walk: looks, timeOffset: 200, withMesh: false, withLog: false,
                               info: passInfo(Fx.fixedID(811), room: roomID), seal: false)
        let foreign = RawScanFolder(url: package.rawMeshPassURL(session: sessionID, pass: Fx.fixedID(812)))
        _ = try writeRawFolder(foreign, walk: looks, timeOffset: 300, withMesh: false, withLog: false,
                               info: passInfo(Fx.fixedID(812), room: Fx.fixedID(3)), seal: true)
        let missing = RawScanFolder(url: package.rawMeshPassURL(session: sessionID, pass: Fx.fixedID(813)))

        let alone = QualitySealedInputs.load(room: roomFolder, roomID: roomID, passes: [])
        let joined = QualitySealedInputs.load(room: roomFolder, roomID: roomID, passes: [passA])
        let total: Int = hidden.count + looks.count
        let times: [Double] = joined.poses.map { $0.timestamp }
        let firstTime: Double = times.first ?? -1
        let lastTime: Double = times.last ?? -1
        let poseCountOK: Bool = times.count == total
        let roomFirst: Bool = firstTime == 0 && lastTime >= 100
        c.check("passes.posesRoomFirst", poseCountOK && roomFirst, "count \(times.count) first \(firstTime) last \(lastTime)")
        let joinedFrames: Int = joined.keyframes.count
        let aloneFrames: Int = alone.keyframes.count
        c.check("passes.keyframesJoined", joinedFrames == total && aloneFrames == hidden.count, "\(joinedFrames) \(aloneFrames)")
        let expectedFolders: [RawScanFolder] = [roomFolder, passA]
        let expectedSeals: [SealFile?] = [roomSeal, passSeal]
        let foldersOK: Bool = joined.folders == expectedFolders
        let sealsOK: Bool = joined.seals == expectedSeals
        let roomLogRead: Bool = joined.room.log != nil
        let onePass: Bool = joined.passes.count == 1
        let passLogNil: Bool = joined.passes.first?.log == nil
        let logsOK: Bool = roomLogRead && onePass && passLogNil
        c.check("passes.foldersSealsAndRoomLog", foldersOK && sealsOK && logsOK)

        let sealedCount = { (list: [RawScanFolder]) -> Int in
            QualityPassFolders.sealed(list, roomFolder: roomFolder, roomID: roomID, logSkips: false).count
        }
        c.check("passes.unsealedSkipped", sealedCount([unsealed]) == 0)
        c.check("passes.missingSkipped", sealedCount([missing]) == 0)
        c.check("passes.otherRoomSkipped", sealedCount([foreign]) == 0)
        c.check("passes.repeatsSkipped", sealedCount([roomFolder, passA, passA]) == 1)
        let mixed = QualitySealedInputs.load(room: roomFolder, roomID: roomID, passes: [unsealed, missing, foreign, passA])
        c.check("passes.skipCount", mixed.passes.count == 1 && mixed.skippedPasses == 3,
                "read \(mixed.passes.count) skipped \(mixed.skippedPasses)")

        let box = Fx.boxRoom()
        let aloneRun = evaluateInputs(alone, room: box)
        let joinedRun = evaluateInputs(joined, room: box)
        let aloneWalls = aloneRun.evaluation.summary.walls
        let joinedWalls = joinedRun.evaluation.summary.walls
        let raised: Bool = joinedWalls > aloneWalls + 0.1
        c.check("passes.wallsRaisedByPass", raised && joinedWalls >= 0.9, "\(aloneWalls) -> \(joinedWalls)")
        let aloneGap = wall2MissingArea(aloneRun.evaluation)
        let joinedGap = wall2MissingArea(joinedRun.evaluation)
        c.check("passes.wall2MissingAreaFilled", aloneGap > 3 && joinedGap == 0, "\(aloneGap) -> \(joinedGap)")

        let before = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, now: Fx.fixedDate)
        let empty = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, passes: [], now: Fx.fixedDate)
        c.check("passes.emptyEqualsRoomOnly", empty == before)
        let roomOnlySeals: [SealFile?] = [roomSeal]
        let singleHash = QualityEvaluator.doneInputHash(seal: roomSeal)
        let listHash = QualityEvaluator.doneInputHash(seals: roomOnlySeals)
        c.check("passes.emptyKeepsDoneHash", before.inputHash == singleHash && before.inputHash == listHash)
        let withPass = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, passes: [passA],
                                                               now: Fx.fixedDate)
        let passDoneHash = QualityEvaluator.doneInputHash(seals: expectedSeals)
        c.check("passes.doneHashDiffers", withPass.inputHash != before.inputHash && withPass.inputHash == passDoneHash)
        let beforeShape = Float(before.summary.shape)
        let passShape = Float(withPass.summary.shape)
        c.check("passes.doneShapeRises", passShape > beforeShape + 0.02, "\(beforeShape) -> \(passShape)")
        let beforeTexture = Float(before.summary.texture)
        let passTexture = Float(withPass.summary.texture)
        c.check("passes.doneTextureRises", passTexture > beforeTexture + 0.02, "\(beforeTexture) -> \(passTexture)")
        let skipped = try QualityEvaluator.evaluateSealedRoom(package: package, record: record,
                                                              passes: [unsealed, missing, foreign], now: Fx.fixedDate)
        c.check("passes.skippedPassesChangeNothing", skipped == before)
        let nilFirst: [SealFile?] = [nil, roomSeal]
        let noSeals: [SealFile?] = []
        let nilSkipped: Bool = QualityEvaluator.doneInputHash(seals: nilFirst) == before.inputHash
        let emptyIsNoSeal: Bool = QualityEvaluator.doneInputHash(seals: noSeals) == QualityEvaluator.doneInputHash(seal: nil)
        c.check("passes.doneHashSkipsNil", nilSkipped && emptyIsNoSeal)

        let ctx = StepContext(package: package, manifest: manifest, availableMemory: 2_000_000_000,
                              isCancelled: { false }, progress: { _ in })
        let plain = QualityStep(room: record)
        let passStep = QualityStep(room: record, passes: [passA, unsealed, missing])
        c.check("passes.stepDefaultsToNoPasses", plain.passes.isEmpty && passStep.passes.count == 3)
        let plainHash = try plain.inputHash(ctx)
        let passHash = try passStep.inputHash(ctx)
        let roomOnlyStepHash = QualityStep.inputHash(seal: roomSeal, buildRoomStamp: nil, consolidateMeshStamp: nil)
        let passStepHash = QualityStep.inputHash(seals: expectedSeals, buildRoomStamp: nil, consolidateMeshStamp: nil)
        c.check("passes.stepRoomOnlyHashUnchanged", plainHash == roomOnlyStepHash)
        c.check("passes.stepHashAddsSealedPassOnly", passHash != plainHash && passHash == passStepHash)
        c.check("passes.stepHashDiffersFromDone", passHash != withPass.inputHash)
        try passStep.evaluateAndSave(ctx)
        let stepped = QualityStore.load(package, room: roomID)
        c.check("passes.stepSavesPassHash", stepped?.inputHash == passHash)
        let steppedShape = stepped.map { Float($0.summary.shape) } ?? -1
        c.near("passes.stepUsesPassRecords", steppedShape, passShape, 1e-5)
    }

    /// Evaluates loaded inputs with `room` and their fast mesh, as `evaluateSealedRoom` does.
    private static func evaluateInputs(_ inputs: QualitySealedInputs, room: CleanRoom?) -> QualityRun {
        let mesh = MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: inputs.folders))
        return QualityEvaluator.evaluateRecords(roomID: Fx.fixedID(2), room: room, mesh: mesh, poses: inputs.poses,
                                                keyframes: inputs.keyframes, log: inputs.room.log, inputHash: "test",
                                                now: Fx.fixedDate, faceLimit: QualityEvaluator.maxEvaluationFaces)
    }

    /// Total missing wall area on wall 2 (z = 5), square meters.
    private static func wall2MissingArea(_ evaluation: QualityEvaluation) -> Float {
        let onWall2 = evaluation.missingAreas.filter { $0.surface == SurfaceClass.wall.rawValue && $0.centroid.z > 4.9 }
        return onWall2.reduce(Float(0)) { $0 + $1.area }
    }

    /// Writes a raw scan folder: the walk's pose track and keyframe log with every timestamp
    /// shifted by `timeOffset` seconds, the box mesh as one chunk when `withMesh`, a capture log
    /// when `withLog` and `scan.json` when `info` is set; seals it when `seal` (nil otherwise).
    private static func writeRawFolder(_ folder: RawScanFolder, walk: [Fx.WalkPose], timeOffset: Double, withMesh: Bool,
                                       withLog: Bool, info: InProgressScanInfo?, seal: Bool) throws -> SealFile? {
        try ProjectStore.ensureDirectory(folder.url)
        var writer = ByteWriter()
        PoseTrackFile.appendHeader(to: &writer)
        for sample in Fx.poses(walk) {
            var shifted = sample
            shifted.timestamp += timeOffset
            PoseTrackFile.append(shifted, to: &writer)
        }
        try writer.data.write(to: folder.poseTrackURL)
        var lines = Data()
        for frame in Fx.keyframes(walk, ambient: 1000) {
            var shifted = frame
            shifted.timestamp += timeOffset
            lines.append(try ProjectStore.encoder.encode(shifted))
            lines.append(0x0A)
        }
        try lines.write(to: folder.keyframesLogURL)
        if withMesh {
            try ProjectStore.ensureDirectory(folder.meshURL)
            let mesh = Fx.boxMesh()
            let anchor = Fx.fixedID(701)
            let chunk = MeshChunk(anchorID: anchor, transform: matrix_identity_float4x4, updateCount: 1,
                                  positions: mesh.mesh.positions, indices: mesh.mesh.indices, classes: mesh.faceClass ?? [])
            try MeshChunkFile.encode(chunk).write(to: folder.meshChunkURL(anchor: anchor))
        }
        if withLog {
            let log = RoomCaptureLog(seconds: 14, instructionSeconds: [:], error: nil, relocalizations: 0,
                                     limitedTrackingFraction: 0, degraded: .allGood)
            try ProjectStore.writeJSON(log, to: folder.roomLogURL)
        }
        if let info {
            let url = folder.url.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false)
            try ProjectStore.writeJSON(info, to: url)
        }
        guard seal else { return nil }
        return try ProjectStore.sealRawFolder(folder.url, now: Fx.fixedDate)
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
