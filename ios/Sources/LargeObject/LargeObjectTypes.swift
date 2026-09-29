import Foundation
import simd

// Value types of the large-object flow (docs/MODULES.md 3.39): the capture target (the project
// exists before capture), the capture facts written as largeobject.json into the sealed folder,
// the flow phases and the module's log helper.

/// The object being captured; the project exists before capture.
struct LargeObjectTarget: Equatable, Sendable {
    /// The Object project.
    var projectID: UUID
    /// Its package.
    var package: ProjectPackage
    /// The ARKit session of the capture (raw/sessions/<id>/, FrameLink.projectFrame).
    var sessionID: UUID
    /// The object (folder raw/objects/<id>/, `ObjectRecord.id`, the crop edit's element).
    var objectID: UUID
    /// Capture options of the pass.
    var settings: ScanSettings

    /// `ScanSettings.defaults(for: .object)` with detail `.high` (0.20 m or 10 degree keyframe gate)
    /// and distance `.normal` (0.3 to 4 m, large objects are walked around at arm's length or more).
    static func defaultSettings() -> ScanSettings {
        var settings = ScanSettings.defaults(for: .object)
        settings.detail = .high
        settings.distance = .normal
        return settings
    }

    /// Main. Creates the Object project (`ProjectLibrary.shared.create(kind: .object, name:
    /// ScanFlowModel.defaultProjectName(mode: .object, now: now))`, as ObjectUI does), sets `settings`, appends `CaptureSessionRef(id:startedAt:frameLink:
    /// .projectFrame(sessionID:), worldMapFile: nil)` and returns the target. The caller ran
    /// `ScanPreflight.run(mode: .object, isDemo: false)` (async) first. A failed update deletes
    /// the new project again and rethrows.
    @MainActor static func makeNew(now: Date) throws -> LargeObjectTarget {
        let name = ScanFlowModel.defaultProjectName(mode: .object, now: now)
        let created = try ProjectLibrary.shared.create(kind: .object, name: name)
        let projectID = created.1.id
        let sessionID = UUID()
        let objectID = UUID()
        let settings = LargeObjectTarget.defaultSettings()
        let reference = CaptureSessionRef(id: sessionID, startedAt: now, frameLink: .projectFrame(sessionID: sessionID),
                                          worldMapFile: nil)
        do {
            try ProjectLibrary.shared.update(projectID) { manifest in
                manifest.settings = settings
                manifest.sessions.append(reference)
            }
        } catch {
            LargeObjectLog.write("new project \(projectID) not prepared: \(error); deleting it")
            try? ProjectLibrary.shared.delete(projectID)
            throw error
        }
        LargeObjectLog.write("new large object \(objectID) in project \(projectID), session \(sessionID)")
        return LargeObjectTarget(projectID: projectID, package: created.0, sessionID: sessionID, objectID: objectID,
                                 settings: settings)
    }

    /// The mesh-only pass of this object (kind .object, mode .object, pass id = object id).
    var meshTarget: MeshScanTarget {
        MeshScanTarget.largeObject(projectID: projectID, package: package, sessionID: sessionID, objectID: objectID,
                                   settings: settings)
    }
}

/// `largeobject.json` in the sealed folder: capture facts (the user-facing box is the edit).
/// The file is missing when the engine stopped the pass by itself (heat, storage, memory, a
/// session failure), because such a finish carries no attachments; readers treat a missing or
/// unreadable file as "no seed or box recorded" (`load(from:)` returns nil).
struct LargeObjectLog: Codable, Equatable, Sendable {
    /// File name at the root of `raw/objects/<o>/`.
    static let fileName = "largeobject.json"
    /// Largest file `load(from:)` reads, bytes.
    static let maxBytes: Int64 = 1_000_000

    /// The tapped seed, world meters.
    var seed: Vec3?
    /// Floor height under the object, meters.
    var floorY: Float?
    /// Camera position when the seed was set (the front of the sectors).
    var front: Vec3?
    /// The capture-time box.
    var box: OrientedBoxRecord?
    /// Seconds the camera viewed each region (8 sides, then top) and each region's face score.
    var viewSeconds: [Double]
    var faceScores: [Float?]
    /// Whether the top had to be captured.
    var topRequired: Bool
    /// Regions covered and required at the end of the capture.
    var covered: Int
    var required: Int

    /// Nothing recorded (no seed, no box).
    static let empty = LargeObjectLog(seed: nil, floorY: nil, front: nil, box: nil, viewSeconds: [], faceScores: [],
                                      topRequired: false, covered: 0, required: 0)

    /// A copy whose non-finite numbers are dropped (nil) or zeroed, so JSON encoding cannot fail.
    func sanitized() -> LargeObjectLog {
        var copy = self
        if let seed, !LargeObjectLog.isFinite(seed) { copy.seed = nil }
        if let front, !LargeObjectLog.isFinite(front) { copy.front = nil }
        if let floorY, !floorY.isFinite { copy.floorY = nil }
        if let box {
            let parts = [box.center, box.axisX, box.axisY, box.axisZ, box.halfExtents]
            if !parts.allSatisfy(LargeObjectLog.isFinite) { copy.box = nil }
        }
        copy.viewSeconds = viewSeconds.map { $0.isFinite ? $0 : 0 }
        copy.faceScores = faceScores.map { (score: Float?) -> Float? in
            guard let value = score, value.isFinite else { return nil }
            return value
        }
        return copy
    }

    /// The encoded file (`ProjectStore.encoder`), or nil when encoding fails (logged).
    func encoded() -> Data? {
        do {
            return try ProjectStore.encoder.encode(sanitized())
        } catch {
            LargeObjectLog.write("largeobject.json not encoded: \(error)")
            return nil
        }
    }

    /// The log of a sealed large-object folder, or nil when the file is missing (a pass the engine
    /// stopped by itself), too large or unreadable.
    static func load(from folder: RawScanFolder) -> LargeObjectLog? {
        guard let url = folder.resolve(fileName), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(LargeObjectLog.self, from: url, maxBytes: maxBytes)
        } catch {
            LargeObjectLog.write("largeobject.json unreadable in \(folder.url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// True when every component is finite.
    static func isFinite(_ v: Vec3) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }

    /// Log category of the LargeObject module.
    static let logCategory = "largeobject"

    /// Writes one line in the module's category. Thread-safe.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }
}

/// Phases of the large-object flow.
enum LargeObjectPhase: Equatable { case starting, aiming, locating, capturing, finishing, done(UUID), cancelled, failed(String) }
