import Foundation

// Value types of the mesh-only scan driver (docs/MODULES.md 3.32): what one pass records and
// where it is sealed, what a finished pass produced, the standard recorder set, the lookup of
// sealed mesh-pass folders, the Diagnostics settings key and the module's log helper. Nothing
// here touches ARKit hardware, so the self-test builds every value off the main actor.

extension SettingsKey {
    /// Bool, absent means off. Diagnostics only: ARKit's scene-understanding wireframe in live views.
    static let liveMeshDebugView = "liveMeshDebugView"
}

/// What one mesh-only pass records and where it is sealed.
struct MeshScanTarget: Equatable, Sendable {
    /// Project the pass belongs to.
    var projectID: UUID
    /// The project's package.
    var package: ProjectPackage
    /// ARKit session (raw/sessions/<id>/, FrameLink.projectFrame).
    var sessionID: UUID
    /// InProgress scan id and sealed folder name; the object id for `.object`.
    var passID: UUID
    /// `.meshPass` or `.object`.
    var kind: RawScanKind
    /// Profile mode and scan.json mode: room, house or advancedSpace for `.meshPass`; object or
    /// advancedObject for `.object`. Never quickMeasure (D14).
    var mode: ScanMode
    /// The room a patch pass or fallback pass belongs to (scan.json `roomID`).
    var roomID: UUID?
    /// `package.rawMeshPassURL(session:pass:)` or `package.rawObjectURL(_:)`.
    var destination: URL
    /// Capture options of the pass (keyframe gate, distance).
    var settings: ScanSettings

    /// Creates a target; `MeshScanStats.validationProblem` checks that the fields agree.
    init(projectID: UUID, package: ProjectPackage, sessionID: UUID, passID: UUID, kind: RawScanKind,
         mode: ScanMode, roomID: UUID?, destination: URL, settings: ScanSettings) {
        self.projectID = projectID
        self.package = package
        self.sessionID = sessionID
        self.passID = passID
        self.kind = kind
        self.mode = mode
        self.roomID = roomID
        self.destination = destination
        self.settings = settings
    }

    /// A pass on a room's session (Show Missing Areas, two-pass fallback). Pass the room's own mode
    /// and settings, so a borrowed hub keeps its profile.
    static func patchPass(projectID: UUID, package: ProjectPackage, sessionID: UUID, roomID: UUID,
                          mode: ScanMode, settings: ScanSettings, passID: UUID = UUID()) -> MeshScanTarget {
        MeshScanTarget(projectID: projectID, package: package, sessionID: sessionID, passID: passID,
                       kind: .meshPass, mode: mode, roomID: roomID,
                       destination: package.rawMeshPassURL(session: sessionID, pass: passID), settings: settings)
    }

    /// A large object (kind .object, mode .object, passID = objectID).
    static func largeObject(projectID: UUID, package: ProjectPackage, sessionID: UUID, objectID: UUID,
                            settings: ScanSettings) -> MeshScanTarget {
        MeshScanTarget(projectID: projectID, package: package, sessionID: sessionID, passID: objectID,
                       kind: .object, mode: .object, roomID: nil,
                       destination: package.rawObjectURL(objectID), settings: settings)
    }

    /// A space scan without room finding (kind .meshPass, mode .advancedSpace, no room).
    static func spaceScan(projectID: UUID, package: ProjectPackage, sessionID: UUID, settings: ScanSettings,
                          passID: UUID = UUID()) -> MeshScanTarget {
        MeshScanTarget(projectID: projectID, package: package, sessionID: sessionID, passID: passID,
                       kind: .meshPass, mode: .advancedSpace, roomID: nil,
                       destination: package.rawMeshPassURL(session: sessionID, pass: passID), settings: settings)
    }

    /// The capture profile of the pass (an owned hub is created with it; recorders begin with it).
    var profile: ScanProfile { ScanProfile(mode: mode, settings: settings) }

    /// The package folder this kind, session and pass must be sealed into, or nil for a kind the
    /// mesh driver never records (`.room` belongs to RoomCapture).
    var expectedDestination: URL? {
        switch kind {
        case .meshPass: return package.rawMeshPassURL(session: sessionID, pass: passID)
        case .object: return package.rawObjectURL(passID)
        case .room: return nil
        }
    }

    /// `roomID` written into scan.json: an object scan carries its object id there (as
    /// ObjectCapture's does), so AppShell's recovery reads one field.
    var scanInfoRoomID: UUID? { kind == .object ? passID : roomID }
}

/// What a finished pass produced; `MeshScanEngine.lastResult` after `.roomFinished(roomID: passID)`.
struct MeshScanResult: Equatable, Sendable {
    /// The pass (the object id for a large object).
    var passID: UUID
    /// `.meshPass` or `.object`.
    var kind: RawScanKind
    /// The room of a patch or fallback pass.
    var roomID: UUID?
    /// The sealed folder inside the package.
    var sealedFolder: RawScanFolder
    /// roomlog.json of the pass (instructionSeconds empty, error nil unless a system stop).
    var log: RoomCaptureLog
    /// Keyframes written.
    var keyframeCount: Int
    /// Photos taken.
    var photoCount: Int
    /// Mesh faces recorded.
    var meshFaceCount: Int
    /// Coordinate frame of the pass (the session's shared frame).
    var frameLink: FrameLink
    /// When the pass was sealed.
    var capturedAt: Date
    /// The engine finished by itself (heat, storage, memory) and paused the session.
    var stoppedBySystem: Bool
}

/// The standard recorders of a mesh-only pass. Creating them touches no hardware.
struct MeshScanRecorderSet {
    /// The LiDAR mesh recorder (MeshRecord).
    let mesh: MeshStore
    /// Texture keyframes (Keyframes).
    let keyframes: KeyframeRecorder
    /// The 10 Hz pose track (Keyframes).
    let poses: PoseTrackRecorder
    /// Take Photo pictures, when the screen offers the button.
    let photos: PhotoRecorder?
    /// Extra recorders (CoverageLiveRecorder, LargeObjectTracker), fed after the standard ones.
    var extra: [ScanRecorder]

    /// `mesh` is passed in so extras made first can read the same store
    /// (`CoverageLiveRecorder(meshSource: mesh)`).
    init(photos: Bool, mesh: MeshStore = MeshStore(), extra: [ScanRecorder] = []) {
        self.mesh = mesh
        keyframes = KeyframeRecorder()
        poses = PoseTrackRecorder()
        self.photos = photos ? PhotoRecorder() : nil
        self.extra = extra
    }

    /// mesh, keyframes, poses, photos (when present), then `extra`.
    var all: [ScanRecorder] {
        var list: [ScanRecorder] = [mesh, keyframes, poses]
        if let photos { list.append(photos) }
        list.append(contentsOf: extra)
        return list
    }
}

/// Finding a room's sealed mesh passes (AppShell's processing plans, MissingAreas, the Quality revision's callers).
enum MeshPassFolders {
    /// Sealed folders under raw/sessions/*/mesh-pass/ whose scan.json has kind `.meshPass` and this
    /// roomID, oldest `startedAt` first. Unreadable scan.json files are skipped and logged.
    static func forRoom(_ roomID: UUID, in package: ProjectPackage) -> [RawScanFolder] {
        sealedPasses(in: package).filter { $0.info.roomID == roomID }.map { $0.folder }
    }

    /// Sealed mesh-pass folders without a room (space scans), oldest first.
    static func spacePasses(in package: ProjectPackage) -> [RawScanFolder] {
        sealedPasses(in: package).filter { $0.info.roomID == nil }.map { $0.folder }
    }

    /// Every sealed mesh-pass folder of the package with its scan.json, oldest `startedAt` first
    /// (ties by folder name). Skipped and logged: folders without SEAL.json, an unreadable or
    /// oversized scan.json (`InProgressScanInfo.maxBytes`), a scan.json naming another scan, or
    /// one whose kind is not `.meshPass`.
    static func sealedPasses(in package: ProjectPackage) -> [(folder: RawScanFolder, info: InProgressScanInfo)] {
        var found: [(folder: RawScanFolder, info: InProgressScanInfo)] = []
        for entry in StorePackageOps.meshPassFolders(in: package) {
            let folder = RawScanFolder(url: entry.url)
            guard StoreFiles.exists(folder.sealURL) else {
                MeshScanLog.write("mesh pass \(entry.id) skipped: not sealed")
                continue
            }
            guard let info = RawScanReader(folder: folder).info() else {
                MeshScanLog.write("mesh pass \(entry.id) skipped: no readable scan.json")
                continue
            }
            guard info.scanID == entry.id else {
                MeshScanLog.write("mesh pass \(entry.id) skipped: scan.json names \(info.scanID)")
                continue
            }
            guard info.kind == .meshPass else {
                MeshScanLog.write("mesh pass \(entry.id) skipped: kind \(info.kind.rawValue)")
                continue
            }
            found.append((folder: folder, info: info))
        }
        return found.sorted { lhs, rhs in
            if lhs.info.startedAt != rhs.info.startedAt { return lhs.info.startedAt < rhs.info.startedAt }
            return lhs.folder.url.lastPathComponent < rhs.folder.url.lastPathComponent
        }
    }
}

/// Why a mesh-only capture is being abandoned.
enum MeshAbandonKind: String, Equatable, Sendable {
    /// `cancel()`: ordered stop, raw stays in InProgress for recovery.
    case cancel
    /// `discard()`: ordered stop, then the InProgress folder is deleted.
    case discard
}

/// Log lines of the LiveMeshView module (category `MeshScanEngine.logCategory`). Thread-safe.
enum MeshScanLog {
    /// Guards `loggedKeys`.
    private static let lock = NSLock()
    /// Keys already written by `once`.
    private static var loggedKeys = Set<String>()

    /// Writes one line.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: MeshScanEngine.logCategory)
    }

    /// Writes `message` the first time `key` is seen in this app run.
    static func once(_ key: String, _ message: String) {
        lock.lock()
        let isNew = loggedKeys.insert(key).inserted
        lock.unlock()
        if isNew { write(message) }
    }

    /// Thermal level, available memory and (unless `storage` is false, as on the hub queue,
    /// which does no disk work) free storage, for the start and finish lines.
    static func deviceLine(storage: Bool = true) -> String {
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue
        let memory = MemoryProbe.availableBytes() / 1_000_000
        var line = "thermal \(thermal), available memory \(memory) MB"
        if storage { line += ", free storage \(ProjectStore.freeBytes() / 1_000_000) MB" }
        return line
    }
}
