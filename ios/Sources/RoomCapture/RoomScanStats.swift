import Foundation
import ARKit
import RoomPlan

// Pure helpers of the Room scan engine (docs/MODULES.md 3.21). Nothing here touches a session,
// a file or a clock, so RoomCaptureSelfTest checks every rule without ARKit or RoomPlan running.
// Error mapping follows docs/ARCHITECTURE.md 4.2 (errors table); the finish order is the data
// in `finishSteps`, which the engine iterates, so the order cannot drift from the tested list.

/// Lifecycle signals the engine feeds to `RoomScanStats.next(_:on:)`.
enum RoomEngineSignal: Equatable, Sendable {
    /// `start()` or `startNextRoom(roomID:)` created the room folder.
    case start
    /// RoomPlan reported `captureSession(_:didStartWith:)`.
    case didStart
    /// `pause()` or an ARSession interruption.
    case pause
    /// The ARSession interruption ended (the engine stays paused until Resume).
    case interruptionEnded
    /// The user tapped Resume.
    case resume
    /// Done, Finish Now, an engine-initiated finish, or RoomPlan ending by itself.
    case finish
    /// The room folder was sealed.
    case sealed
    /// The capture failed before the seal.
    case failure
    /// `cancel()` or `discard()` completed their ordered stop.
    case cancel
}

/// One step of the finish sequence, in the order `RoomScanStats.finishSteps` lists them.
enum RoomFinishStep: String, CaseIterable, Sendable {
    /// The 11 steps of docs/MODULES.md 3.21, "Finish sequence", in that order.
    case writeRoomData, buildRoom, saveWorldMap, detachRecorders, finishRecorders, writeLogs,
         flushWriter, closeWriter, seal, pauseIfSystemStop, emitRoomFinished
}

/// A recorder the engine can pause without knowing its type (dependency inversion: the engine
/// never names a MeshRecord or Keyframes type). Keyframes' `KeyframeRecorder` already has a
/// matching `isPaused`; the conformance (`extension KeyframeRecorder: PausableScanRecorder {}`)
/// is declared by the module that imports both (ScanUI), so keyframes stop while paused.
protocol PausableScanRecorder: AnyObject {
    /// Any thread. While true the recorder takes no keyframes.
    var isPaused: Bool { get set }
}

/// Why a capture is being abandoned.
enum RoomAbandonKind: Equatable, Sendable {
    /// `cancel()`: ordered stop, raw stays in InProgress for recovery.
    case cancel
    /// `discard()`: ordered stop, then the InProgress folder is deleted.
    case discard
}

/// Live element counts of the room being scanned (from the latest `didUpdate`).
struct RoomLiveCounts: Equatable, Sendable {
    /// Walls, doors (closed or open), windows, openings and objects found so far.
    var walls = 0, doors = 0, windows = 0, openings = 0, objects = 0

    /// All zero.
    init() {}

    /// Copies the tuple `RoomScanStats.counts(_:)` returns.
    init(_ counts: (walls: Int, doors: Int, windows: Int, openings: Int, objects: Int)) {
        walls = counts.walls
        doors = counts.doors
        windows = counts.windows
        openings = counts.openings
        objects = counts.objects
    }
}

/// Remembers which walls, doors and windows RoomPlan already reported, so each new element
/// raises exactly one "detected" guidance event even though `didUpdate` repeats the whole room.
struct RoomDetectionTracker: Equatable, Sendable {
    /// Identifiers already seen, per kind.
    private(set) var seenWalls = Set<UUID>(), seenDoors = Set<UUID>(), seenWindows = Set<UUID>()
    /// New elements not yet handed to the guidance engine.
    private(set) var newWalls = 0, newDoors = 0, newWindows = 0

    /// Nothing seen yet.
    init() {}

    /// Counts the elements of `input` never seen before.
    mutating func observe(_ input: RoomInput) {
        for wall in input.walls {
            if seenWalls.insert(wall.identifier).inserted { newWalls += 1 }
        }
        for surface in input.openings {
            switch surface.kind {
            case .door, .openDoor:
                if seenDoors.insert(surface.identifier).inserted { newDoors += 1 }
            case .window:
                if seenWindows.insert(surface.identifier).inserted { newWindows += 1 }
            case .opening, .wall, .floor:
                break
            }
        }
    }

    /// Returns the new counts since the previous call and resets them to zero.
    mutating func take() -> (walls: Int, doors: Int, windows: Int) {
        let taken = (walls: newWalls, doors: newDoors, windows: newWindows)
        newWalls = 0
        newDoors = 0
        newWindows = 0
        return taken
    }
}

/// Pure helpers (tested).
enum RoomScanStats {
    /// Maps a RoomPlan, RoomBuilder, session or Mapper error to the `MapperError` the screens
    /// show (ARCHITECTURE 4.2 errors table). A `MapperError` passes through unchanged.
    static func mapError(_ error: any Error) -> MapperError {
        if let mapped = error as? MapperError { return mapped }
        if let capture = error as? RoomCaptureSession.CaptureError { return mapCaptureError(capture) }
        if error is CancellationError { return .cancelled }
        return .roomPlanFailed(describe(error))
    }

    /// `CaptureError` to `MapperError`: heat, scene size and tracking have their own alerts;
    /// every RoomPlan-internal failure is `.roomPlanFailed` with the case name for the log.
    static func mapCaptureError(_ error: RoomCaptureSession.CaptureError) -> MapperError {
        switch error {
        case .deviceTooHot: return .deviceTooHot
        case .exceedSceneSizeLimit: return .sceneTooLarge
        case .worldTrackingFailure: return .trackingFailed
        case .deviceNotSupported: return .roomPlanFailed("deviceNotSupported")
        case .invalidARConfiguration: return .roomPlanFailed("invalidARConfiguration")
        case .internalError: return .roomPlanFailed("internalError")
        @unknown default: return .roomPlanFailed("unknown capture error")
        }
    }

    /// True when RoomBuilder should run on the room data that ended with `error`: no error,
    /// a scene that grew too large (keep the partial room), heat, a tracking failure, or an AR
    /// configuration problem (the data describes what was captured, ARCHITECTURE 4.2). False
    /// for RoomPlan-internal failures (device not supported, internal, unknown errors).
    static func shouldBuildRoom(after error: (any Error)?) -> Bool {
        guard let error else { return true }
        guard let capture = error as? RoomCaptureSession.CaptureError else { return false }
        switch capture {
        case .exceedSceneSizeLimit, .deviceTooHot, .worldTrackingFailure, .invalidARConfiguration:
            return true
        case .deviceNotSupported, .internalError:
            return false
        @unknown default:
            return false
        }
    }

    /// The degraded mode stored in roomlog.json: `.roomPlanFailed` when there is no room data
    /// or RoomBuilder is not run for the error, else the hub's mode (D16).
    static func degradedMode(hub: DegradedMode, hasRoomData: Bool, error: (any Error)?) -> DegradedMode {
        guard hasRoomData, shouldBuildRoom(after: error) else { return .roomPlanFailed }
        return hub
    }

    /// The one `.failed` event sent after `.roomFinished`, if any: the system stop reason first,
    /// then the RoomPlan error, then an earlier session failure, then "no room data".
    static func notice(systemStop: MapperError?, error: (any Error)?, pending: MapperError?, hasRoomData: Bool) -> MapperError? {
        if let systemStop { return systemStop }
        if let error { return mapError(error) }
        if let pending { return pending }
        return hasRoomData ? nil : .roomPlanFailed("no room data")
    }

    /// The notice actually sent after the seal: a `.roomPlanFailed` notice ("Walls couldn't be
    /// found") is dropped when RoomBuilder still produced the room (for example after
    /// `invalidARConfiguration`, ARCHITECTURE 4.2), because the room then has walls and a plan.
    static func finalNotice(_ notice: MapperError?, roomBuilt: Bool) -> MapperError? {
        guard roomBuilt, case .roomPlanFailed? = notice else { return notice }
        return nil
    }

    /// Room counts of a RoomInput: walls, doors (closed or open), windows, openings, objects.
    static func counts(_ input: RoomInput) -> (walls: Int, doors: Int, windows: Int, openings: Int, objects: Int) {
        let openings = input.openingCounts
        return (walls: input.walls.count, doors: openings.doors, windows: openings.windows,
                openings: openings.openings, objects: input.objects.count)
    }

    /// Adds elapsed time to the current instruction bucket. Negative, zero or non-finite
    /// deltas are ignored.
    static func accumulate(_ seconds: inout [String: Double], instruction: String, delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        seconds[instruction, default: 0] += delta
    }

    /// Room mode input: tracking, deviceHot (thermal serious or worse) and the new detection
    /// counts only. angularSpeed stays 0 and centerDistance, ambientIntensity and
    /// depthConfidenceMean stay nil, so moveSlower, tooClose, tooFar, moveCloser and
    /// lightingPoor never fire over RoomPlan's own coaching (RESEARCH 3.10 gotcha 6, 3.8 gotcha 23).
    static func guidanceInput(time: Double, status: HubStatus, newDoors: Int, newWindows: Int, newWalls: Int) -> GuidanceInput {
        var input = GuidanceInput(time: time)
        input.tracking = GuidanceSignals.tracking(status.tracking)
        input.deviceHot = status.thermal == .serious || status.thermal == .critical
        input.newDoors = max(0, newDoors)
        input.newWindows = max(0, newWindows)
        input.newWalls = max(0, newWalls)
        return input
    }

    /// The live snapshot for one status tick: counts from RoomPlan, streams and device state
    /// from the hub, recorder counters and the filtered guidance.
    static func snapshot(timestamp: Double, status: HubStatus, counts: RoomLiveCounts, recorders: RecorderStats,
                         guidance: GuidanceKind?) -> LiveScanSnapshot {
        var snapshot = LiveScanSnapshot()
        snapshot.timestamp = timestamp
        snapshot.elapsed = status.elapsed
        snapshot.tracking = status.tracking
        snapshot.degraded = status.degraded
        snapshot.guidanceRawValue = guidance?.rawValue
        snapshot.wallCount = counts.walls
        snapshot.doorCount = counts.doors
        snapshot.windowCount = counts.windows
        snapshot.openingCount = counts.openings
        snapshot.objectCount = counts.objects
        snapshot.meshFaceCount = recorders.meshFaces
        snapshot.keyframeCount = recorders.keyframes
        snapshot.photoCount = recorders.photos
        snapshot.thermal = status.thermal
        snapshot.freeBytes = status.freeBytes
        snapshot.availableMemory = status.availableMemory
        return snapshot
    }

    /// True while a room capture is live (RoomPlan may be running): starting, scanning, paused.
    static func isCapturing(_ state: ScanEngineState) -> Bool {
        state == .starting || state == .scanning || state == .paused
    }

    /// Engine state machine. Signals that do not apply to a state leave it unchanged; a failure
    /// after the seal leaves `.finished` (the room is sealed and `lastResult` stays valid; the
    /// `.failed` event is then a notice about how the room ended).
    static func next(_ state: ScanEngineState, on signal: RoomEngineSignal) -> ScanEngineState {
        switch signal {
        case .start:
            return state == .idle || state == .finished ? .starting : state
        case .didStart:
            return state == .starting ? .scanning : state
        case .pause:
            return state == .starting || state == .scanning ? .paused : state
        case .interruptionEnded:
            return state
        case .resume:
            return state == .paused ? .scanning : state
        case .finish:
            return isCapturing(state) ? .stopping : state
        case .sealed:
            return isCapturing(state) || state == .stopping ? .finished : state
        case .failure:
            return isCapturing(state) || state == .stopping ? .failed : state
        case .cancel:
            return .idle
        }
    }

    /// The finish sequence in order (tested as data, so the order cannot drift).
    static let finishSteps: [RoomFinishStep] = [
        .writeRoomData, .buildRoom, .saveWorldMap, .detachRecorders, .finishRecorders, .writeLogs,
        .flushWriter, .closeWriter, .seal, .pauseIfSystemStop, .emitRoomFinished,
    ]

    /// Why the engine ends a room by itself, or nil: thermal .critical, storage .pause, memory
    /// .critical (checked in that order). The storage case carries 0 bytes; the engine fills in
    /// the latest reading.
    static func systemStopReason(thermal: ThermalLevel, storage: StorageState, memory: MemoryState) -> MapperError? {
        if thermal == .critical { return .deviceTooHot }
        if storage == .pause { return .lowStorage(freeBytes: 0) }
        if memory == .critical { return .lowMemory }
        return nil
    }

    /// True when a world map is worth saving: mapping is `.mapped` or `.extending`.
    static func shouldSaveWorldMap(_ status: ARFrame.WorldMappingStatus) -> Bool {
        switch status {
        case .mapped, .extending: return true
        case .notAvailable, .limited: return false
        @unknown default: return false
        }
    }

    /// Log name of a world mapping status.
    static func worldMappingName(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }

    /// True when at least `interval` seconds passed since `last` (throttles for the live room
    /// file, every 10 s, and the build 5 live room handler, 1 Hz).
    static func isDue(now: Double, last: Double?, interval: Double) -> Bool {
        guard let last else { return true }
        return now - last >= interval
    }

    /// Seconds of capture from the scan start and the latest frame (0 when either is unknown).
    static func elapsed(start: Double?, latest: Double?) -> Double {
        guard let start, let latest, latest.isFinite, start.isFinite else { return 0 }
        return max(0, latest - start)
    }

    /// Diagnostic text of an error for logs and `RoomCaptureLog.error` (never shown in the UI).
    /// Swift enum errors (RoomPlan, RoomBuilder, Mapper, Core, encoding) give their case;
    /// anything else only its domain and code, because Foundation errors carry full file paths
    /// (ARCHITECTURE 11.4).
    static func describe(_ error: any Error) -> String {
        if let capture = error as? RoomCaptureSession.CaptureError {
            return "CaptureError." + captureErrorName(capture)
        }
        if error is MapperError || error is CoreError { return "\(error)" }
        let nsError = error as NSError
        if Mirror(reflecting: error).displayStyle == .enum { return "\(nsError.domain).\(error)" }
        return "\(nsError.domain) \(nsError.code)"
    }

    /// Case name of a `CaptureError` for the log.
    static func captureErrorName(_ error: RoomCaptureSession.CaptureError) -> String {
        switch error {
        case .deviceNotSupported: return "deviceNotSupported"
        case .deviceTooHot: return "deviceTooHot"
        case .exceedSceneSizeLimit: return "exceedSceneSizeLimit"
        case .invalidARConfiguration: return "invalidARConfiguration"
        case .worldTrackingFailure: return "worldTrackingFailure"
        case .internalError: return "internalError"
        @unknown default: return "unknown"
        }
    }

    /// True when `error` is RoomPlan's `CaptureError.deviceTooHot` (the engine then treats the
    /// end of the room as a system stop and pauses the session after the seal).
    static func isDeviceTooHot(_ error: (any Error)?) -> Bool {
        guard let capture = error as? RoomCaptureSession.CaptureError else { return false }
        return capture == .deviceTooHot
    }
}

/// Build 5 (docs/MODULES.md 3.30c): whether `makeCaptureView` runs the hub.
extension RoomScanStats {
    /// Pure: `makeCaptureView` runs the hub only when it is not running yet. A hub that HouseUI
    /// already ran with a world map (relocalization, 3.30b) keeps that session, so the plain
    /// configuration never replaces the relocalized one.
    static func shouldRunHub(isRunning: Bool) -> Bool {
        !isRunning
    }
}

/// Log lines of the RoomCapture module (category "roomcapture"); `once` writes a key only the
/// first time in an app run (thread-safe), for per-callback facts such as callback threads.
enum RoomScanLog {
    /// Log category.
    static let category = "roomcapture"
    /// Guards `loggedKeys`.
    private static let lock = NSLock()
    /// Keys already written by `once`.
    private static var loggedKeys = Set<String>()

    /// Writes one line.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: category)
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
