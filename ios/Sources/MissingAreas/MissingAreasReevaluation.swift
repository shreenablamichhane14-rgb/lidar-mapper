import Foundation
import simd

// The two off-main jobs of the Show Missing Areas tour (docs/MODULES.md 3.40): the Coverage
// inputs that seed the patch pass's live grid with what the room pass already saw, and the
// quality evaluation of the room plus its sealed mesh passes after Done (CR-10), stored with
// `QualityStore.save`. Both read sealed folders only and never write into the room's folder.

/// Seed inputs and the evaluation after the tour. Stateless; call both off the main thread.
enum MissingAreasReevaluation {
    /// Rate of the pose samples used as seed observations, Hz.
    static let seedHz: Double = 1
    /// Most mesh faces handed to the seed.
    static let seedFaceLimit = 100_000

    /// Off main. Room poses, keyframes and mesh as Coverage inputs for `CoverageLiveRecorder.seed`:
    /// `QualityRoomFiles.load`, `MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [room]))`,
    /// `QualityInputs.observations(poses:keyframes:hz: 1)`, `QualityInputs.oriented(_:toward:limit: 100_000).faces`.
    /// Sealed mesh passes of the same room (an earlier tour) join the room's records and mesh, room
    /// first, through `QualitySealedInputs` (the same reader `evaluateSealedRoom` uses). A missing
    /// room folder gives empty inputs (logged).
    static func seedInputs(package: ProjectPackage, record: RoomRecord) -> (observations: [CoverageObservation], faces: [CoverageFace]) {
        let started = ProcessInfo.processInfo.systemUptime
        let folder = CapturedRoomStore.rawFolder(package, room: record)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            MissingAreasLog.write("seed inputs: room \(record.id) has no raw folder; no seed")
            return (observations: [], faces: [])
        }
        let passes = MeshPassFolders.forRoom(record.id, in: package)
        let inputs = QualitySealedInputs.load(room: folder, roomID: record.id, passes: passes)
        let observations = QualityInputs.observations(poses: inputs.poses, keyframes: inputs.keyframes, hz: seedHz)
        let mesh = MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: inputs.folders))
        let viewpoints = QualityInputs.viewpoints(observations)
        let faces = QualityInputs.oriented(mesh, toward: viewpoints, limit: seedFaceLimit).faces
        let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        MissingAreasLog.write("seed inputs of room \(record.id): \(observations.count) observations, \(faces.count) faces "
                              + "from \(mesh.triangleCount) triangles, \(inputs.passes.count) earlier passes, \(milliseconds) ms")
        return (observations: observations, faces: faces)
    }

    /// Off main. `QualityEvaluator.evaluateSealedRoom(package:record:passes:now:)` (CR-10) with
    /// `MeshPassFolders.forRoom(record.id, in: package)`, then `QualityStore.save`. Returns the
    /// evaluation as stored (non-finite values replaced). Throws when the room folder is missing
    /// or quality.json cannot be written.
    static func run(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation {
        let started = ProcessInfo.processInfo.systemUptime
        let passes = MeshPassFolders.forRoom(record.id, in: package)
        let evaluation = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, passes: passes, now: now)
        let stored = evaluation.sanitizedForStorage()
        try QualityStore.save(stored, package: package)
        let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        MissingAreasLog.write("room \(record.id) evaluated again with \(passes.count) mesh passes: "
                              + "\(stored.missingAreas.count) missing areas, verdict \(stored.summary.verdict.rawValue), "
                              + "\(milliseconds) ms")
        return stored
    }
}

/// Log lines of the MissingAreas module (category `missingareas`). Thread-safe, never UI text.
enum MissingAreasLog {
    /// Log category of every line this module writes.
    static let category = "missingareas"

    /// Writes one line.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: category)
    }
}
