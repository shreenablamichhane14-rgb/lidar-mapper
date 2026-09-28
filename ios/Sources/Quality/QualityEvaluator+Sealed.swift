import Foundation
import simd

// Reading a sealed room folder for the quality check at Done (`evaluateSealedRoom`) and for
// `QualityStep`: pose track, keyframe records and capture log through Store's RawScanReader,
// the room from RoomPlan's saved JSON through RoomModel (never RoomBuilder), and the raw mesh
// chunks through MeshModel. Unreadable optional files are logged and treated as absent, so a
// damaged scan still gets an honest (low) evaluation instead of none.

/// The recorded inputs of one sealed room folder.
struct QualityRoomFiles {
    /// The folder they came from.
    var folder: RawScanFolder
    /// `SEAL.json`, nil when missing or unreadable.
    var seal: SealFile?
    /// The 10 Hz pose track.
    var poses: [PoseSample]
    /// Keyframe records (unsafe paths already dropped by the reader).
    var keyframes: [KeyframeRecord]
    /// RoomPlan capture diagnostics, nil for a recovered scan.
    var log: RoomCaptureLog?

    /// Reads the folder with `RawScanReader`; a pose track or keyframe log that cannot be read
    /// is logged and read as empty.
    static func load(_ folder: RawScanFolder, roomID: UUID) -> QualityRoomFiles {
        let reader = RawScanReader(folder: folder)
        var poses: [PoseSample] = []
        do {
            poses = try reader.poseSamples()
        } catch {
            LogStore.shared.write("room \(roomID): pose track unreadable (\(error)); geometry coverage from none",
                                  category: QualityEvaluator.logCategory)
        }
        var keyframes: [KeyframeRecord] = []
        do {
            keyframes = try reader.keyframes()
        } catch {
            LogStore.shared.write("room \(roomID): keyframe log unreadable (\(error)); texture coverage from none",
                                  category: QualityEvaluator.logCategory)
        }
        let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        if seal == nil {
            LogStore.shared.write("room \(roomID): SEAL.json missing or unreadable", category: QualityEvaluator.logCategory)
        }
        return QualityRoomFiles(folder: folder, seal: seal, poses: poses, keyframes: keyframes, log: reader.roomLog())
    }
}

extension QualityEvaluator {
    /// Extra input-hash string of the quick evaluation at Done.
    static let doneHashExtra = "done"

    /// Reads the sealed folder (RawScanReader), builds the clean room with RoomModel (mesh nil) and
    /// MeshConsolidator.fastWorldMesh, then `evaluate` with inputHash extra ["done"].
    /// Throws `CoreError.missingFile` when the room's raw folder does not exist; every other
    /// problem (no CapturedRoom, no mesh, unreadable logs) lowers the evaluation instead.
    /// Does IO and runs for up to a few seconds: call it off the main thread.
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation {
        let started = ProcessInfo.processInfo.systemUptime
        let folder = CapturedRoomStore.rawFolder(package, room: record)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError.missingFile("raw room " + record.id.uuidString)
        }
        let files = QualityRoomFiles.load(folder, roomID: record.id)
        let room = cleanRoom(package: package, record: record, mesh: nil, findFurniture: true)
        let loaded = ProcessInfo.processInfo.systemUptime
        let mesh = MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [folder]))
        let meshed = ProcessInfo.processInfo.systemUptime
        let result = evaluateRecords(roomID: record.id, room: room, mesh: mesh, poses: files.poses,
                                     keyframes: files.keyframes, log: files.log, inputHash: doneInputHash(seal: files.seal),
                                     now: now, faceLimit: maxEvaluationFaces)
        let finished = ProcessInfo.processInfo.systemUptime
        let timings = [("read", loaded - started), ("mesh", meshed - loaded), ("score", finished - meshed)]
        logSummary(label: "done check", result: result, meshTriangles: mesh.triangleCount, timings: timings)
        return result.evaluation
    }

    /// Input hash of the quick evaluation at Done: the room seal plus extra ["done"], so it never
    /// equals a `QualityStep` hash and the pipeline always replaces it.
    static func doneInputHash(seal: SealFile?) -> String {
        InputHasher.hash(seals: seal.map { [$0] } ?? [], editRevision: nil, extra: [doneHashExtra])
    }

    /// The clean room of a record from RoomPlan's saved JSON (raw, rebuilt, then provisional;
    /// `CapturedRoomStore.loadInput`, never RoomBuilder) built by `CleanModelBuilder` with
    /// `mesh` for measured floor and ceiling heights; nil (logged) when no CapturedRoom loads.
    static func cleanRoom(package: ProjectPackage, record: RoomRecord, mesh: MeshWithAttributes?,
                          findFurniture: Bool) -> CleanRoom? {
        let input: RoomInput
        do {
            input = try CapturedRoomStore.loadInput(package, room: record)
        } catch {
            LogStore.shared.write("room \(record.id): no CapturedRoom (\(error)); quality without walls",
                                  category: logCategory)
            return nil
        }
        var options = CleanBuildOptions()
        options.findFurniture = findFurniture
        return CleanModelBuilder.buildRoom(input, recordID: record.id, name: record.name, floorIndex: record.floorIndex,
                                           mesh: mesh, options: options)
    }

    /// One log line with the scores, the inputs and the timings of an evaluation.
    static func logSummary(label: String, result: (evaluation: QualityEvaluation, detail: QualityScoreDetail),
                           meshTriangles: Int, timings: [(String, Double)]) {
        let e = result.evaluation
        let d = result.detail
        let s = e.summary
        var parts: [String] = []
        parts.append("shape \(percentText(s.shape)) walls \(percentText(s.walls)) floor \(percentText(s.floor))")
        parts.append("ceiling \(percentText(s.ceiling)) texture \(percentText(s.texture)) verdict \(s.verdict.rawValue)")
        parts.append("missing \(s.missingAreas), degraded \(e.degraded.rawValue)")
        parts.append("dark keyframes \(percentText(Double(e.darkKeyframeFraction)))")
        parts.append("mesh \(meshTriangles) triangles, faces \(d.faceCount) stride \(d.faceStride) flipped \(d.flippedFaceCount)")
        if d.usedShellFaces { parts.append("room shell stood in for the missing mesh") }
        if d.usedNoRoomPath { parts.append("no usable room") }
        parts.append("observations \(d.geometryObservationCount) geometry, \(d.textureObservationCount) texture")
        parts.append("truncated \(d.truncatedIntegrations), samples in openings \(d.excludedSampleCount)")
        for (name, seconds) in timings {
            parts.append("\(name) \(Int((seconds * 1000).rounded())) ms")
        }
        LogStore.shared.write("\(label) room \(e.roomID): " + parts.joined(separator: "; "), category: logCategory)
    }

    /// A 0...1 score as whole percent text for logs (never UI).
    private static func percentText(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        return "\(Int((value * 100).rounded()))%"
    }
}
