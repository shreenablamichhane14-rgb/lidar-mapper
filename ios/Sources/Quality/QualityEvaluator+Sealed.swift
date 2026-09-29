import Foundation
import simd

// Reading a sealed room folder for the quality check at Done (`evaluateSealedRoom`) and for
// `QualityStep`: pose track, keyframe records and capture log through Store's RawScanReader,
// the room from RoomPlan's saved JSON through RoomModel (never RoomBuilder), and the raw mesh
// chunks through MeshModel. Unreadable optional files are logged and treated as absent, so a
// damaged scan still gets an honest (low) evaluation instead of none.
//
// Build 5 (CR-10): a room may also own sealed mesh-pass folders (Show Missing Areas, the D16
// detail pass). Their pose samples and keyframe records join the room's (room first; one ARKit
// session, so one timebase), their chunks join the fast mesh, and their seals join the input
// hashes. A pass folder without a readable SEAL.json is never read.

/// The recorded inputs of one sealed room or mesh-pass folder.
struct QualityRoomFiles {
    /// The folder they came from.
    var folder: RawScanFolder
    /// `SEAL.json`, nil when missing or unreadable.
    var seal: SealFile?
    /// The 10 Hz pose track.
    var poses: [PoseSample]
    /// Keyframe records (unsafe paths already dropped by the reader).
    var keyframes: [KeyframeRecord]
    /// RoomPlan capture diagnostics, nil for a recovered scan (and always nil for a mesh pass).
    var log: RoomCaptureLog?

    /// Reads the folder with `RawScanReader`; a pose track or keyframe log that cannot be read
    /// is logged and read as empty.
    static func load(_ folder: RawScanFolder, roomID: UUID) -> QualityRoomFiles {
        let records = readRecords(folder, label: "room \(roomID)")
        let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        if seal == nil {
            LogStore.shared.write("room \(roomID): SEAL.json missing or unreadable", category: QualityEvaluator.logCategory)
        }
        return QualityRoomFiles(folder: folder, seal: seal, poses: records.poses, keyframes: records.keyframes,
                                log: RawScanReader(folder: folder).roomLog())
    }

    /// Reads a sealed mesh-pass folder whose `seal` was already read (`QualityPassFolders.sealed`):
    /// pose track and keyframe log only (the room's capture log is the one that counts).
    static func loadPass(_ folder: RawScanFolder, seal: SealFile, roomID: UUID) -> QualityRoomFiles {
        let records = readRecords(folder, label: "room \(roomID) pass \(folder.url.lastPathComponent)")
        return QualityRoomFiles(folder: folder, seal: seal, poses: records.poses, keyframes: records.keyframes, log: nil)
    }

    /// The pose track and keyframe log of a folder; each unreadable one is logged and read as empty.
    private static func readRecords(_ folder: RawScanFolder, label: String) -> (poses: [PoseSample], keyframes: [KeyframeRecord]) {
        let reader = RawScanReader(folder: folder)
        var poses: [PoseSample] = []
        do {
            poses = try reader.poseSamples()
        } catch {
            LogStore.shared.write("\(label): pose track unreadable (\(error)); geometry coverage from none",
                                  category: QualityEvaluator.logCategory)
        }
        var keyframes: [KeyframeRecord] = []
        do {
            keyframes = try reader.keyframes()
        } catch {
            LogStore.shared.write("\(label): keyframe log unreadable (\(error)); texture coverage from none",
                                  category: QualityEvaluator.logCategory)
        }
        return (poses: poses, keyframes: keyframes)
    }
}

/// Which of the mesh-pass folders handed to Quality it may read (CR-10). Stateless.
enum QualityPassFolders {
    /// The sealed passes among `passes`, in the given order (oldest first), each with its seal.
    /// Skipped, with a log line when `logSkips`: a folder that does not exist, has no SEAL.json
    /// or an unreadable one, whose `scan.json` says it is not a mesh pass or belongs to another
    /// room, that is the room folder itself, or that repeats an earlier entry. Never throws.
    static func sealed(_ passes: [RawScanFolder], roomFolder: RawScanFolder, roomID: UUID,
                       logSkips: Bool = true) -> [(folder: RawScanFolder, seal: SealFile)] {
        var seen: Set<String> = [key(roomFolder)]
        var out: [(folder: RawScanFolder, seal: SealFile)] = []
        for pass in passes {
            let name = pass.url.lastPathComponent
            guard seen.insert(key(pass)).inserted else {
                skip("pass \(name) repeats the room or an earlier pass", roomID: roomID, logSkips: logSkips)
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pass.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                skip("pass \(name) missing", roomID: roomID, logSkips: logSkips)
                continue
            }
            guard FileManager.default.fileExists(atPath: pass.sealURL.path) else {
                skip("pass \(name) has no SEAL.json", roomID: roomID, logSkips: logSkips)
                continue
            }
            let seal: SealFile
            do {
                seal = try ProjectStore.readJSON(SealFile.self, from: pass.sealURL)
            } catch {
                skip("pass \(name) SEAL.json unreadable (\(error))", roomID: roomID, logSkips: logSkips)
                continue
            }
            if let info = RawScanReader(folder: pass).info() {
                let otherRoom = info.roomID.map { $0 != roomID } ?? false
                guard info.kind == .meshPass, !otherRoom else {
                    let owner = info.roomID?.uuidString ?? "none"
                    skip("pass \(name) is not a mesh pass of this room (kind \(info.kind.rawValue), room \(owner))",
                         roomID: roomID, logSkips: logSkips)
                    continue
                }
            }
            out.append((folder: pass, seal: seal))
        }
        return out
    }

    /// The comparable path of a folder (standardized, no trailing slash).
    private static func key(_ folder: RawScanFolder) -> String {
        folder.url.standardizedFileURL.path
    }

    /// Logs one skipped pass folder.
    private static func skip(_ reason: String, roomID: UUID, logSkips: Bool) {
        guard logSkips else { return }
        LogStore.shared.write("room \(roomID): \(reason); skipped", category: QualityEvaluator.logCategory)
    }
}

/// A room folder's recorded inputs joined with those of its sealed mesh-pass folders (CR-10).
struct QualitySealedInputs {
    /// The room folder's own files (its seal and capture log count for the whole room).
    var room: QualityRoomFiles
    /// The sealed pass folders that were read, oldest first.
    var passes: [QualityRoomFiles]
    /// Pass folders handed in but not read (see `QualityPassFolders.sealed`).
    var skippedPasses: Int

    /// Pose samples of the room, then of every pass.
    var poses: [PoseSample] {
        var out = room.poses
        for pass in passes { out.append(contentsOf: pass.poses) }
        return out
    }

    /// Keyframe records of the room, then of every pass.
    var keyframes: [KeyframeRecord] {
        var out = room.keyframes
        for pass in passes { out.append(contentsOf: pass.keyframes) }
        return out
    }

    /// The room folder, then every pass folder read (for `MeshConsolidator.latestChunks(in:)`).
    var folders: [RawScanFolder] {
        [room.folder] + passes.map { $0.folder }
    }

    /// The room seal (nil when missing), then every pass seal (for the input hashes).
    var seals: [SealFile?] {
        [room.seal] + passes.map { $0.seal }
    }

    /// Reads the room folder and the sealed ones among `passes`.
    static func load(room folder: RawScanFolder, roomID: UUID, passes: [RawScanFolder]) -> QualitySealedInputs {
        let room = QualityRoomFiles.load(folder, roomID: roomID)
        let usable = QualityPassFolders.sealed(passes, roomFolder: folder, roomID: roomID)
        let files = usable.map { QualityRoomFiles.loadPass($0.folder, seal: $0.seal, roomID: roomID) }
        return QualitySealedInputs(room: room, passes: files, skippedPasses: passes.count - usable.count)
    }
}

extension QualityEvaluator {
    /// Extra input-hash string of the quick evaluation at Done.
    static let doneHashExtra = "done"

    /// Reads the sealed folder (RawScanReader), builds the clean room with RoomModel (mesh nil) and
    /// MeshConsolidator.fastWorldMesh, then `evaluate` with inputHash extra ["done"].
    /// Equals `evaluateSealedRoom(package:record:passes: [], now:)`.
    /// Throws `CoreError.missingFile` when the room's raw folder does not exist; every other
    /// problem (no CapturedRoom, no mesh, unreadable logs) lowers the evaluation instead.
    /// Does IO and runs for up to a few seconds: call it off the main thread.
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation {
        try evaluateSealedRoom(package: package, record: record, passes: [], now: now)
    }

    /// `evaluateSealedRoom(package:record:now:)` plus the room's sealed mesh-pass folders, oldest first:
    /// pose samples and keyframe records of all folders concatenated (room first; one ARKit session,
    /// so one timebase), mesh = `MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [room] + passes))`,
    /// log from the room folder, input hash `doneInputHash(seals:)` over the room seal and every pass seal.
    /// With `passes` empty it equals the existing function.
    /// A pass folder that is missing or unsealed is logged and skipped (`QualityPassFolders.sealed`);
    /// only a missing room folder throws (`CoreError.missingFile`). Call it off the main thread.
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, passes: [RawScanFolder],
                                   now: Date) throws -> QualityEvaluation {
        let started = ProcessInfo.processInfo.systemUptime
        let folder = CapturedRoomStore.rawFolder(package, room: record)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError.missingFile("raw room " + record.id.uuidString)
        }
        let inputs = QualitySealedInputs.load(room: folder, roomID: record.id, passes: passes)
        let room = cleanRoom(package: package, record: record, mesh: nil, findFurniture: true)
        let loaded = ProcessInfo.processInfo.systemUptime
        let mesh = MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: inputs.folders))
        let meshed = ProcessInfo.processInfo.systemUptime
        let result = evaluateRecords(roomID: record.id, room: room, mesh: mesh, poses: inputs.poses,
                                     keyframes: inputs.keyframes, log: inputs.room.log,
                                     inputHash: doneInputHash(seals: inputs.seals), now: now, faceLimit: maxEvaluationFaces)
        let finished = ProcessInfo.processInfo.systemUptime
        let timings = [("read", loaded - started), ("mesh", meshed - loaded), ("score", finished - meshed)]
        logSummary(label: "done check" + passLabel(inputs), result: result, meshTriangles: mesh.triangleCount, timings: timings)
        return result.evaluation
    }

    /// Input hash of the quick evaluation at Done: the room seal plus extra ["done"], so it never
    /// equals a `QualityStep` hash and the pipeline always replaces it.
    static func doneInputHash(seal: SealFile?) -> String {
        doneInputHash(seals: [seal])
    }

    /// InputHasher over the seals (nil entries skipped) plus extra ["done"].
    static func doneInputHash(seals: [SealFile?]) -> String {
        InputHasher.hash(seals: seals.compactMap { $0 }, editRevision: nil, extra: [doneHashExtra])
    }

    /// Log suffix naming the mesh passes read and skipped; empty for a room alone.
    static func passLabel(_ inputs: QualitySealedInputs) -> String {
        guard !inputs.passes.isEmpty || inputs.skippedPasses > 0 else { return "" }
        return " with \(inputs.passes.count) mesh passes (\(inputs.skippedPasses) skipped)"
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
