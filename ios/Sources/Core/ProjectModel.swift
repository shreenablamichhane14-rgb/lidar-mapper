import Foundation

/// Contents of `project.json`: everything the library and the pipeline need to know about
/// a project without opening raw or derived files.
struct ProjectManifest: Codable, Equatable, Identifiable, Sendable {
    /// Schema version this build writes.
    static let currentSchema = 1
    /// Pipeline version this build writes; bumping it makes every derived product stale.
    static let currentPipelineVersion = 1

    /// Schema version of the file (`currentSchema` when written by this build).
    var schemaVersion: Int
    /// Project identifier (also the package folder name).
    var id: UUID
    /// Name shown in the library.
    var name: String
    /// What was scanned.
    var kind: ScanMode
    /// Creation time.
    var createdAt: Date
    /// Last change to the manifest, edits or derived products.
    var modifiedAt: Date
    /// True when archived (hidden from the main list).
    var isArchived: Bool
    /// Pipeline version that produced the derived products.
    var pipelineVersion: Int
    /// ARKit sessions used by this project.
    var sessions: [CaptureSessionRef]
    /// Rooms (Room and House modes).
    var rooms: [RoomRecord]
    /// Scanned objects (Object modes).
    var objects: [ObjectRecord]
    /// Floors (House mode); one default floor otherwise.
    var floors: [FloorRecord]
    /// Overall state shown in the library.
    var status: ProjectStatus
    /// True while an Object Capture reconstruction must resume on relaunch (D17).
    var reconstructionPending: Bool
    /// Capture options chosen for this project.
    var settings: ScanSettings

    /// A new, empty project of `kind` created at `now`.
    static func new(kind: ScanMode, name: String, now: Date) -> ProjectManifest {
        ProjectManifest(schemaVersion: currentSchema, id: UUID(), name: name, kind: kind,
                        createdAt: now, modifiedAt: now, isArchived: false,
                        pipelineVersion: currentPipelineVersion, sessions: [], rooms: [], objects: [],
                        floors: [FloorRecord(id: 0, name: "", elevation: 0)], status: .capturing,
                        reconstructionPending: false, settings: ScanSettings.defaults(for: kind))
    }
}

/// What a project scans. Raw values are persisted.
enum ScanMode: String, Codable, CaseIterable, Sendable {
    case room, house, object, quickMeasure, advancedSpace, advancedObject
}

/// Overall project state. Raw values are persisted. `.capturing` is valid only while a scan
/// is on screen: the scan flow moves the project to `.needsProcessing` in the same update
/// that appends a finished room, and at launch AppShell's `RecoveryService` reconciles any
/// project left in `.capturing` (adds sealed rooms and enqueues it, or deletes it when it
/// has no rooms and no recoverable scan).
enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case capturing, needsProcessing, processing, ready, needsAttention
}

/// One ARKit session of a project.
struct CaptureSessionRef: Codable, Equatable, Identifiable, Sendable {
    /// Session identifier (folder `raw/sessions/<id>`).
    var id: UUID
    /// When the session started.
    var startedAt: Date
    /// Coordinate frame relation to the project (D9).
    var frameLink: FrameLink
    /// World map file name inside the session folder, when one was saved.
    var worldMapFile: String?
}

/// One scanned room.
struct RoomRecord: Codable, Equatable, Identifiable, Sendable {
    /// Room identifier (folder `raw/sessions/<s>/rooms/<id>`).
    var id: UUID
    /// User-visible room name (empty means "use the default from Copy").
    var name: String
    /// Session the room was captured in.
    var sessionID: UUID
    /// Index into `ProjectManifest.floors`.
    var floorIndex: Int
    /// Capture and processing state.
    var status: RoomStatus
    /// `CapturedRoom.identifier` of the capture-time RoomPlan result.
    var capturedRoomID: UUID?
    /// Quality scores once evaluated.
    var quality: QualitySummary?
    /// True when a mesh and photo pass (patch or two-pass fallback) exists.
    var hasMeshPass: Bool
    /// Number of keyframes recorded.
    var keyframeCount: Int
    /// When capture finished.
    var capturedAt: Date
    /// Coordinate frame of this room's capture (D9).
    var frameLink: FrameLink
}

/// State of a room or object. Raw values are persisted.
enum RoomStatus: String, Codable, CaseIterable, Sendable {
    case capturing, captured, needsRescan, processed, failed
}

/// One scanned object.
struct ObjectRecord: Codable, Equatable, Identifiable, Sendable {
    /// Object identifier (folder `raw/objects/<id>`).
    var id: UUID
    /// User-visible name.
    var name: String
    /// Size class chosen before capture (D4).
    var size: ObjectSize
    /// Capture and processing state.
    var status: RoomStatus
    /// Number of Object Capture images (small/medium) or keyframes (large).
    var imageCount: Int
    /// Model file name inside the derived object folder, when built.
    var modelFile: String?
}

/// Object size chooser (D4): small/medium uses Object Capture, large the LiDAR mesh driver.
enum ObjectSize: String, Codable, CaseIterable, Sendable {
    case smallMedium, large
}

/// One floor (level) of a house.
struct FloorRecord: Codable, Equatable, Identifiable, Sendable {
    /// Floor index, 0 = the first scanned floor.
    var id: Int
    /// User-visible name (empty means "use the default from Copy").
    var name: String
    /// Floor elevation in the structure frame, meters.
    var elevation: Float
}

/// Per-room quality scores, each 0...1, plus the number of missing areas.
struct QualitySummary: Codable, Equatable, Sendable {
    /// Area-weighted mean of walls, floor and ceiling (Copy "Shape").
    var shape: Double
    /// Observed fraction of expected wall samples, weighted by wall confidence.
    var walls: Double
    /// Observed fraction of the floor.
    var floor: Double
    /// Observed fraction of the ceiling.
    var ceiling: Double
    /// Fraction of observed cells that were also photographed.
    var texture: Double
    /// Number of missing-area clusters.
    var missingAreas: Int
    /// Verdict derived from the scores.
    var verdict: QualityVerdict

    /// Creates a summary; the verdict is computed with `QualityVerdict.from`.
    init(shape: Double, walls: Double, floor: Double, ceiling: Double, texture: Double, missingAreas: Int) {
        self.shape = shape
        self.walls = walls
        self.floor = floor
        self.ceiling = ceiling
        self.texture = texture
        self.missingAreas = missingAreas
        verdict = QualityVerdict.from(shape: shape, walls: walls, floor: floor, ceiling: ceiling, texture: texture)
    }
}

/// Overall scan verdict. Raw values are persisted.
enum QualityVerdict: String, Codable, CaseIterable, Sendable {
    case good, okay, poor

    /// Score every component must reach for `good`.
    static let goodThreshold = 0.9
    /// Score every component must reach for `okay`.
    static let okayThreshold = 0.7

    /// Good when all scores are at least 0.9, okay when all are at least 0.7, else poor
    /// (ship-first 4.6). Non-finite scores count as 0.
    static func from(shape: Double, walls: Double, floor: Double, ceiling: Double, texture: Double) -> QualityVerdict {
        let lowest = [shape, walls, floor, ceiling, texture].map { $0.isFinite ? $0 : 0 }.min() ?? 0
        if lowest >= goodThreshold { return .good }
        if lowest >= okayThreshold { return .okay }
        return .poor
    }
}

/// Capture options (ship-first 3.6, D6).
struct ScanSettings: Codable, Equatable, Sendable {
    /// Keyframe density and texture detail.
    var detail: DetailLevel
    /// On: normal keyframe gate. Off: a coarser gate at capture time (D6).
    var keepAllPhotos: Bool
    /// Run RoomPlan to find walls, doors and windows.
    var findRooms: Bool
    /// Keep detected furniture in the clean model.
    var findFurniture: Bool
    /// Depth window used for coverage and keyframes.
    var distance: ScanDistance

    /// Defaults for Room and House scans.
    static let room = ScanSettings(detail: .standard, keepAllPhotos: true, findRooms: true,
                                   findFurniture: true, distance: .normal)

    /// Defaults for a scan mode: object and mesh-only modes do not look for rooms.
    static func defaults(for mode: ScanMode) -> ScanSettings {
        var settings = room
        switch mode {
        case .room, .house, .quickMeasure:
            break
        case .advancedSpace:
            settings.findRooms = true
        case .object, .advancedObject:
            settings.findRooms = false
            settings.findFurniture = false
            settings.distance = .closeUp
        }
        return settings
    }

    /// Minimum camera travel or rotation between accepted keyframes: Standard 0.30 m or
    /// 15 degrees, High 0.20 m or 10 degrees, Maximum 0.12 m or 7 degrees; both values are
    /// multiplied by 1.5 when Keep all photos is off.
    var keyframeGate: (meters: Float, degrees: Float) {
        let base: (meters: Float, degrees: Float)
        switch detail {
        case .standard: base = (0.30, 15)
        case .high: base = (0.20, 10)
        case .maximum: base = (0.12, 7)
        }
        let factor: Float = keepAllPhotos ? 1 : 1.5
        return (base.meters * factor, base.degrees * factor)
    }

    /// Depth range in meters used for coverage and keyframe depth.
    var depthWindow: ClosedRange<Float> {
        switch distance {
        case .closeUp: return 0.3...2
        case .normal: return 0.3...4
        case .far: return 0.3...5
        }
    }
}

/// Detail level (Advanced options). Raw values are persisted.
enum DetailLevel: String, Codable, CaseIterable, Sendable {
    case standard, high, maximum
}

/// Scanning distance (Advanced options). Raw values are persisted.
enum ScanDistance: String, Codable, CaseIterable, Sendable {
    case closeUp, normal, far
}
