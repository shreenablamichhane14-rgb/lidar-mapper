import Foundation
import ARKit
import RoomPlan

// The Room scan engine (docs/MODULES.md 3.21, ARCHITECTURE 4.2, D1, D15): Apple's
// RoomCaptureView on the app-owned ARSession of CaptureCore, recorders plugged in through
// `ScanRecorder`, per-room persistence and sealing. This file holds the public types, the stored
// state and the main-thread entry points; hub-queue handlers are in RoomScanEngine+Lifecycle.swift
// and the finish sequence in RoomScanPersistence.swift.
//
// Writers: the engine's `RawScanWriter` writes the RoomPlan, log, event and world map files;
// recorders receive only the folder (`ScanRecorder.beginRecording`) and write through their own
// `RawScanWriter` on the same serial io queue, so the engine's flush after every
// `finishRecording` completion orders all of them before the close and the seal.

/// Everything the engine needs to know about the room it captures.
struct RoomScanTarget: Equatable, Sendable {
    /// Project the room belongs to.
    var projectID: UUID
    /// The project's package (the sealed room lands in `package.rawRoomURL(session:room:)`).
    var package: ProjectPackage
    /// ARKit session of the capture (`raw/sessions/<id>/`, `FrameLink.projectFrame`).
    var sessionID: UUID
    /// The room being scanned.
    var roomID: UUID
    /// Scan mode (Room in build 4, House in build 5).
    var mode: ScanMode
    /// Capture options of the project.
    var settings: ScanSettings
}

/// What a finished room produced; `RoomScanEngine.lastResult` after `.roomFinished`.
struct RoomScanResult: Equatable, Sendable {
    /// The room.
    var roomID: UUID
    /// The sealed raw folder inside the package.
    var sealedFolder: RawScanFolder
    /// `CapturedRoom.identifier` of the RoomBuilder result, nil when RoomBuilder failed.
    var capturedRoomID: UUID?
    /// Contents of roomlog.json.
    var log: RoomCaptureLog
    /// Keyframes and photos recorded.
    var keyframeCount: Int
    /// Photos taken.
    var photoCount: Int
    /// Coordinate frame of the room (D9).
    var frameLink: FrameLink
    /// When the room was sealed.
    var capturedAt: Date
    /// True when the engine finished the room itself (heat, storage, memory): the ARSession was
    /// paused before `.roomFinished`, so build 5 hides Show Missing Areas for this room.
    var stoppedBySystem: Bool
}

/// Engine state confined to `hub.queue`: the engine's private copy of its phase and every
/// per-room value. Read and written only on the hub queue.
struct RoomEngineQueueState {
    /// Private phase copy used for every hub-queue decision.
    var phase: ScanEngineState = .idle
    /// The room being captured (copied from the target at each room start).
    var target: RoomScanTarget
    /// InProgress scan of the current room, its folder and its writer.
    var scanID: UUID?, folder: RawScanFolder?, writer: RawScanWriter?
    /// Increases for every room, so late timers of an earlier room do nothing.
    var roomSerial = 0
    /// Rooms sealed by this engine (session.json is written with the first).
    var roomsFinished = 0
    /// Hub events that arrived before the writer existed (bounded).
    var pendingEvents: [CaptureEvent] = []
    /// Latest `ARFrame.timestamp` and the scan start passed to `hub.markScanStart`.
    var latestFrameTimestamp: TimeInterval?, scanStartTimestamp: TimeInterval?
    /// True when RoomPlan started before any frame arrived (the next frame marks the start).
    var pendingScanStart = false
    /// True while RoomPlan's latest instruction is not `.normal`.
    var coaching = false
    /// Current instruction name, when it started (uptime) and the per-instruction seconds.
    var instructionName: String?, instructionSince: TimeInterval = 0
    /// Seconds spent in each instruction (RoomCaptureLog.instructionSeconds).
    var instructionSeconds: [String: Double] = [:]
    /// Live counts and detection bookkeeping from `didUpdate`.
    var counts = RoomLiveCounts(), detections = RoomDetectionTracker()
    /// Latest live room from `didUpdate` (for capturedroom-live.json).
    var latestRoom: CapturedRoom?
    /// Uptime of the last live room file write and of the last live room handler call.
    var lastLiveWrite: TimeInterval?, lastLiveHandler: TimeInterval?
    /// True from `didEndWith` on: no more live room files.
    var liveWritesStopped = false
    /// Guidance display rules (Coverage).
    var guidance = GuidanceEngine()
    /// Why the engine finishes the room itself, when it does.
    var systemStop: MapperError?
    /// A notice to send after `.roomFinished` when nothing more specific applies (session failure).
    var pendingNotice: MapperError?
    /// True once the finish sequence task was launched for the current room.
    var finishStarted = false
    /// Set by `cancel()` or `discard()`; the finish sequence checks it before sealing.
    var abandon: RoomAbandonKind?
    /// True once the writer's close was requested (no more writes are queued after it).
    var writerCloseRequested = false
    /// True once the current room was sealed.
    var sealed = false
    /// True while the memory state is `.low` (logged once per episode).
    var memoryLowLogged = false
    /// RoomPlan callback counts since the last rate log, and when that log was written.
    var updateCount = 0, instructionCount = 0, lastRateLog: TimeInterval?, rateLogs = 0

    /// State for a target.
    init(target: RoomScanTarget) {
        self.target = target
    }
}

/// Room engine. Call ScanEngine methods on main; work runs on hub.queue; events arrive on main.
/// `state` and `lastResult` are written only on main, inside the same `DispatchQueue.main.async`
/// that emits the matching event; hub.queue keeps a private phase copy for its own decisions.
final class RoomScanEngine: NSObject, ScanEngine {
    /// Current lifecycle state (main only).
    private(set) var state: ScanEngineState = .idle
    /// Event callback, always invoked on the main queue.
    var onEvent: ((ScanEngineEvent) -> Void)?
    /// The shared ARSession owner (CaptureCore).
    let hub: ARSessionHub
    /// Main. Valid after .roomFinished.
    private(set) var lastResult: RoomScanResult?

    /// Main only. The room being captured (changes in `startNextRoom`).
    private(set) var target: RoomScanTarget
    /// Recorders fed by the hub (MeshStore, KeyframeRecorder, PoseTrackRecorder, PhotoRecorder).
    let recorders: [ScanRecorder]
    /// RoomPlan delegate for both slots (both are weak, so the engine keeps it).
    let controller: RoomCaptureController
    /// Hub-queue state (see `RoomEngineQueueState`).
    var q: RoomEngineQueueState

    // MARK: Main-thread state

    /// The one RoomCaptureView of this engine (created once, released by `teardown`).
    private var captureView: RoomCaptureView?
    /// The view's `captureSession`, stored so the nonisolated methods never touch the view.
    private var captureSession: RoomCaptureSession?
    /// `start()` (or `startNextRoom`) was called for the current room.
    private var startRequested = false
    /// RoomPlan `run(configuration:)` and `stop(pauseARSession:)` were called for the current room.
    private var roomPlanRunRequested = false, roomPlanStopRequested = false
    /// True once `teardown()` ran.
    private var tornDown = false

    // MARK: Build 5 hooks (lock-protected, called on the hub queue)

    /// Guards the three hook closures.
    private let hookLock = NSLock()
    /// Backing stores of the hooks.
    private var liveRoomStorage: ((RoomInput) -> Void)?
    /// Backing store of `guidanceAugmenter`.
    private var guidanceStorage: ((inout GuidanceInput) -> Void)?
    /// Backing store of `snapshotAugmenter`.
    private var snapshotStorage: ((inout LiveScanSnapshot) -> Void)?

    /// Hub queue hook for build 5 (CoverageLive, House): the live room, at most 1 Hz.
    var liveRoomHandler: ((RoomInput) -> Void)? {
        get { withHookLock { liveRoomStorage } }
        set { withHookLock { liveRoomStorage = newValue } }
    }
    /// Hub queue hook: adjusts the guidance input before `GuidanceEngine.update`.
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)? {
        get { withHookLock { guidanceStorage } }
        set { withHookLock { guidanceStorage = newValue } }
    }
    /// Hub queue hook: adjusts each snapshot before it is posted to main.
    var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)? {
        get { withHookLock { snapshotStorage } }
        set { withHookLock { snapshotStorage = newValue } }
    }

    /// Main actor (creates the hub, whose initializer reads UIDevice). Installs the hub closures
    /// with weak captures; nothing runs until `makeCaptureView()` and `start()`.
    @MainActor init(target: RoomScanTarget, recorders: [ScanRecorder]) {
        self.target = target
        self.recorders = recorders
        hub = ARSessionHub(profile: ScanProfile(mode: target.mode, settings: target.settings))
        controller = RoomCaptureController()
        q = RoomEngineQueueState(target: target)
        super.init()
        controller.engine = self
        installHubClosures()
        RoomScanLog.write("room engine init, room \(target.roomID), \(recorders.count) recorders")
    }

    /// Sets the four hub closures with weak captures. Nonisolated on purpose: closures formed
    /// inside the main-actor `init` would inherit main-actor isolation, yet the hub calls them
    /// on its own queue.
    private func installHubClosures() {
        hub.onStatus = { [weak self] status in self?.handleStatus(status) }
        hub.onCaptureEvent = { [weak self] event in self?.handleCaptureEvent(event) }
        hub.onFrame = { [weak self] frame in self?.handleFrameTimestamp(frame.timestamp) }
        hub.onMemoryPressure = { [weak self] in self?.handleMemoryPressure() }
    }

    /// Logs "room engine deinit". A view still held (teardown never ran) is released on main.
    deinit {
        if let view = captureView {
            DispatchQueue.main.async { withExtendedLifetime(view) {} }
        }
        RoomScanLog.write("room engine deinit")
    }

    // MARK: - View

    /// Main. Creates the view once (later calls return the same instance): hub.install(), then
    /// hub.run() only when the hub is not running yet (`RoomScanStats.shouldRunHub`, 3.30c: a
    /// session HouseUI relocalized with a world map keeps running with its delegate re-asserted),
    /// RoomCaptureView(frame: .zero, arSession: hub.session), captureSession.delegate = controller,
    /// delegate = controller, and stores `view.captureSession` in a private `RoomCaptureSession`
    /// property. The ScanEngine methods below are nonisolated, so they use that stored session and
    /// never touch the main-actor `RoomCaptureView`. Starts capture if start() was already called.
    @MainActor func makeCaptureView() -> RoomCaptureView {
        if let existing = captureView { return existing }
        guard !tornDown else {
            // A torn-down engine never touches its paused session again; SwiftUI still needs a
            // view, so it gets an inert one that is never run.
            RoomScanLog.write("makeCaptureView after teardown: inert view returned")
            return RoomCaptureView(frame: .zero)
        }
        hub.install()
        if RoomScanStats.shouldRunHub(isRunning: hub.isRunning) {
            hub.run()
            RoomScanLog.write("makeCaptureView: session not running, hub run")
        } else {
            RoomScanLog.write("makeCaptureView: session already running (relocalized), not run again")
        }
        let view = RoomCaptureView(frame: .zero, arSession: hub.session)
        if let session = view.captureSession {
            session.delegate = controller
            captureSession = session
        } else {
            RoomScanLog.write("RoomCaptureView has no captureSession; RoomPlan cannot run")
        }
        view.delegate = controller
        captureView = view
        RoomScanLog.write("RoomCaptureView created on the hub session; supported \(RoomCaptureSession.isSupported)")
        runRoomPlanIfReady()
        return view
    }

    // MARK: - ScanEngine (main)

    /// Main. Checks RoomCaptureSession.isSupported (else .unsupportedDevice) and free space (else
    /// .lowStorage); creates the InProgress folder (kind .room) and the package's session folder
    /// (`package.sessionURL(_:)` through `ProjectStore.ensureDirectory(_:inside: package.root)`, where
    /// session.json goes); attaches and begins recorders; when the view already exists, runs
    /// captureSession.run(configuration:) with isCoachingEnabled true. Throws before creating
    /// anything on disk when a check fails.
    func start() throws {
        guard !startRequested, !tornDown else {
            RoomScanLog.write("start ignored: already started or torn down")
            return
        }
        let prepared = try prepareRoom(roomID: target.roomID)
        startRequested = true
        RoomScanLog.write("room start \(target.roomID), scan \(prepared.scanID): " + RoomScanLog.deviceLine())
        publish(state: .starting, events: [.stateChanged(.starting)])
        beginRoomOnQueue(prepared, target: target)
        runRoomPlanIfReady()
    }

    /// Main. Marks paused (state only: RoomPlan has no pause and keeps scanning; KeyframeRecorder
    /// takes no keyframes while paused). Used for interruptions.
    func pause() {
        hub.queue.async { [weak self] in self?.applyPause(reason: "pause()") }
    }

    /// Main. The user tapped Resume (Copy.Scanning.resume): back to `.scanning`. After
    /// `sessionInterruptionEnded` the engine stays `.paused` until this call, so the user can walk
    /// back to where they stopped, as `Copy.Scanning.paused` says.
    func resume() {
        hub.queue.async { [weak self] in self?.applyResume() }
    }

    /// Main. captureSession.stop(pauseARSession: false); the finish sequence runs; then
    /// .roomFinished(roomID:) with `lastResult` set. The ARSession keeps running (D19) unless the
    /// engine finished the room itself.
    func finish() {
        hub.queue.async { [weak self] in self?.beginFinish(systemStop: nil, reason: "finish()") }
    }

    /// Main. Ordered stop without sealing (Core ScanEngine.cancel): stop RoomPlan, detach the
    /// recorders on hub.queue, `finishRecording` on each, `writer.flush`, `writer.close()`; raw data
    /// stays in InProgress for recovery; then `.stateChanged(.idle)`.
    func cancel() {
        hub.queue.async { [weak self] in self?.beginAbandon(.cancel) }
    }

    /// Main. The user confirmed Discard Scan while capturing: `cancel()`'s ordered stop, then
    /// `InProgressScans.discard(scanID:)` once the writer is closed, then `.stateChanged(.idle)`.
    /// ScanFlowModel deletes the project only after that event.
    func discard() {
        hub.queue.async { [weak self] in self?.beginAbandon(.discard) }
    }

    /// Main, idempotent, safe in any state: if a capture is still running it does `cancel()`'s
    /// ordered stop (raw stays in InProgress), then `hub.pause()`, detaches the recorders, nils the
    /// hub's onCaptureEvent, onStatus, onFrame and onMemoryPressure closures, and releases the view
    /// and the stored captureSession. ScanFlowModel calls it on every terminal phase (done, failed,
    /// cancelled) and `dismantleUIView` calls it too. Logs "room engine deinit" when released.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        hub.queue.async { [weak self] in
            guard let self else { return }
            if RoomScanStats.isCapturing(self.q.phase) { self.beginAbandon(.cancel) }
        }
        if roomPlanRunRequested && !roomPlanStopRequested, let session = captureSession {
            roomPlanStopRequested = true
            session.stop(pauseARSession: false)
        }
        hub.pause()
        for recorder in recorders { hub.detach(recorder) }
        hub.onCaptureEvent = nil
        hub.onStatus = nil
        hub.onFrame = nil
        hub.onMemoryPressure = nil
        captureSession = nil
        captureView = nil
        RoomScanLog.write("room engine teardown: session paused, recorders detached, hub closures cleared, view released")
    }

    /// Main (build 5 House): same view and session, new InProgress folder, recorders begin again.
    /// Valid after `.roomFinished`; throws the same errors as `start()`.
    func startNextRoom(roomID: UUID) throws {
        guard !tornDown, state == .finished, lastResult != nil else {
            throw MapperError.ioFailed("next room: the previous room is not finished")
        }
        var nextTarget = target
        nextTarget.roomID = roomID
        let prepared = try prepareRoom(roomID: roomID)
        target = nextTarget
        startRequested = true
        roomPlanRunRequested = false
        roomPlanStopRequested = false
        if !hub.isRunning { hub.run() }
        RoomScanLog.write("next room start \(roomID), scan \(prepared.scanID): " + RoomScanLog.deviceLine())
        publish(state: .starting, events: [.stateChanged(.starting)])
        beginRoomOnQueue(prepared, target: nextTarget)
        runRoomPlanIfReady()
    }

    // MARK: - Main-thread helpers

    /// A room folder made by `prepareRoom`.
    struct PreparedRoom {
        /// InProgress scan identifier.
        var scanID: UUID
        /// The InProgress folder.
        var folder: RawScanFolder
        /// Its writer.
        var writer: RawScanWriter
    }

    /// Main. Support and storage checks (nothing on disk yet), then the InProgress folder, the
    /// session folder and the writer. IO failures remove the folder just made and throw `.ioFailed`.
    func prepareRoom(roomID: UUID) throws -> PreparedRoom {
        guard RoomCaptureSession.isSupported else {
            RoomScanLog.write("start refused: RoomCaptureSession.isSupported is false")
            throw MapperError.unsupportedDevice
        }
        let freeBytes = ProjectStore.freeBytes()
        guard freeBytes >= ProjectStore.refuseScanBelowBytes else {
            RoomScanLog.write("start refused: \(freeBytes / 1_000_000) MB free")
            throw MapperError.lowStorage(freeBytes: freeBytes)
        }
        let scanID = UUID()
        let info = InProgressScanInfo(scanID: scanID, projectID: target.projectID, sessionID: target.sessionID,
                                      roomID: roomID, kind: .room, mode: target.mode, startedAt: Date())
        let folder: RawScanFolder
        do {
            folder = try InProgressScans.create(info)
        } catch let error as MapperError {
            throw error
        } catch {
            throw MapperError.ioFailed("InProgress folder: \(RoomScanStats.describe(error))")
        }
        do {
            try ProjectStore.ensureDirectory(target.package.sessionURL(target.sessionID), inside: target.package.root)
        } catch {
            try? InProgressScans.discard(scanID: scanID)
            throw MapperError.ioFailed("session folder: \(RoomScanStats.describe(error))")
        }
        return PreparedRoom(scanID: scanID, folder: folder, writer: RawScanWriter(folder: folder))
    }

    /// Main. Runs RoomPlan once both `start()` and `makeCaptureView()` happened (coaching on, D15).
    func runRoomPlanIfReady() {
        guard startRequested, !tornDown, !roomPlanRunRequested, let session = captureSession else { return }
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        roomPlanRunRequested = true
        roomPlanStopRequested = false
        session.run(configuration: configuration)
        RoomScanLog.write("RoomPlan run, coaching on")
    }

    /// Main. Stops the RoomPlan pass for a finish, keeping the ARSession running (explicit
    /// `false`, RESEARCH 3.2 recommended 6); without a running pass the finish goes on with no
    /// room data. A 15 s watchdog covers a `didEndWith` that never arrives.
    func stopRoomPlanForFinish(serial: Int) {
        guard roomPlanRunRequested, !roomPlanStopRequested, let session = captureSession else {
            RoomScanLog.write("finish without a running RoomPlan pass")
            hub.queue.async { [weak self] in self?.handleRoomEnded(data: nil, error: nil, source: "no RoomPlan pass") }
            return
        }
        roomPlanStopRequested = true
        session.stop(pauseARSession: false)
        hub.queue.asyncAfter(deadline: .now() + RoomScanEngine.endTimeoutSeconds) { [weak self] in
            self?.handleEndTimeout(serial: serial)
        }
    }

    /// Main. Stops the RoomPlan pass for a cancel or discard, when one is running.
    func stopRoomPlanForAbandon() {
        guard roomPlanRunRequested, !roomPlanStopRequested, let session = captureSession else { return }
        roomPlanStopRequested = true
        session.stop(pauseARSession: false)
    }

    /// Main. RoomPlan ended the pass by itself (an error in `didEndWith`), so it is not stopped again.
    func markRoomPlanEnded() {
        if roomPlanRunRequested { roomPlanStopRequested = true }
    }

    /// Seconds to wait for `didEndWith` after `stop(pauseARSession: false)`.
    static let endTimeoutSeconds: TimeInterval = 15

    /// Any thread. Sets `lastResult` and `state` (when given) and emits `events` in one main hop.
    func publish(state newState: ScanEngineState?, events: [ScanEngineEvent], result: RoomScanResult? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let result { self.lastResult = result }
            if let newState { self.state = newState }
            for event in events { self.onEvent?(event) }
        }
    }

    /// Runs `body` while holding the hook lock.
    private func withHookLock<T>(_ body: () -> T) -> T {
        hookLock.lock()
        defer { hookLock.unlock() }
        return body()
    }
}
