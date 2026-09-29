import Foundation
import ARKit
import simd

// The mesh-only scan driver (docs/MODULES.md 3.32, D1, D4, D16, D19): a `ScanEngine` over
// CaptureCore's `ARSessionHub` with the same recorders as a room scan, Mapper's own guidance,
// interruptions, system stops and a finish sequence that seals the pass. This file holds the
// public API, the stored state and the main-thread entry points; hub-queue handlers are in
// MeshScanEngine+Lifecycle.swift and the finish and abandon sequences in MeshScanFinish.swift.
//
// Queue discipline (as RoomCapture): `state` and `lastResult` are written on main only, in the
// same main hop that emits the matching event; `q` is touched only on `hub.queue`; only value
// copies cross queues. Hub closures are formed in nonisolated methods and capture `self` weakly.

/// Engine state confined to `hub.queue`: the private phase copy and every per-pass value.
struct MeshEngineQueueState {
    /// Private phase copy used for every hub-queue decision.
    var phase: ScanEngineState = .idle
    /// The InProgress folder of the pass and its writer (set when recording begins).
    var folder: RawScanFolder?, writer: RawScanWriter?
    /// Hub events that arrived before the writer existed (bounded).
    var pendingEvents: [CaptureEvent] = []
    /// Latest `ARFrame.timestamp`, the uptime it arrived at, and the timestamp of the last
    /// camera transform stored for `latestCameraTransform`.
    var latestFrameTimestamp: TimeInterval?, lastFrameUptime: TimeInterval?, lastCameraTimestamp: TimeInterval?
    /// The first frame after start (passed to `hub.markScanStart`).
    var scanStartTimestamp: TimeInterval?
    /// True once the configuration was re-applied for the current frame gap.
    var gapReapplyTried = false
    /// Guidance display rules (Coverage).
    var guidance = GuidanceEngine()
    /// Why the engine finishes the pass itself, when it does.
    var systemStop: MapperError?
    /// A notice sent after `.roomFinished` when no system stop applies (session failure).
    var pendingNotice: MapperError?
    /// True once the finish or abandon sequence was launched.
    var finishStarted = false
    /// Set by `cancel()` or `discard()`; the finish sequence checks it before sealing.
    var abandon: MeshAbandonKind?
    /// True once the writer's close was requested (no more writes are queued after it).
    var writerCloseRequested = false
    /// True once the pass was sealed; true once its InProgress folder was discarded.
    var sealed = false, discarded = false
    /// True while the memory state is `.low` (logged once per episode).
    var memoryLowLogged = false

    /// Nothing recorded yet.
    init() {}
}

/// The four hub closures a borrowed hub had when the pass started, given back by `teardown()`.
struct MeshLentHubClosures {
    /// `hub.onCaptureEvent` of the owner.
    var onCaptureEvent: ((CaptureEvent) -> Void)?
    /// `hub.onStatus` of the owner.
    var onStatus: ((HubStatus) -> Void)?
    /// `hub.onFrame` of the owner.
    var onFrame: ((ARFrame) -> Void)?
    /// `hub.onMemoryPressure` of the owner.
    var onMemoryPressure: (() -> Void)?
}

/// Mesh-only engine. Call the ScanEngine methods on main; work runs on hub.queue; events arrive on
/// main. `state` and `lastResult` are written on main only, in the same main hop that emits the
/// matching event; hub.queue keeps a private phase copy. Not `@MainActor` (only the listed members).
final class MeshScanEngine: ScanEngine {
    /// Log category of the module.
    static let logCategory = "meshscan"
    /// Seconds without a frame while scanning before the engine re-applies the configuration once.
    static let frameGapSeconds: Double = 1.5
    /// Seconds to wait for each recorder's `finishRecording`.
    static let recorderFinishTimeout: Double = 20
    /// Seconds between two stored camera transforms (at most 10 a second).
    static let cameraUpdateInterval: Double = 0.1
    /// Most hub events kept before the writer exists.
    static let maxPendingEvents = 500

    /// Current lifecycle state (main only).
    private(set) var state: ScanEngineState = .idle
    /// Event callback, always invoked on the main queue.
    var onEvent: ((ScanEngineEvent) -> Void)?
    /// The session owner: created here, or borrowed from a running room engine.
    let hub: ARSessionHub
    /// What the pass records and where it is sealed.
    let target: MeshScanTarget
    /// Recorders fed by the hub (see `MeshScanRecorderSet`).
    let recorders: [ScanRecorder]
    /// True when this engine created the hub (it pauses it in teardown); false for a borrowed hub.
    let ownsHub: Bool
    /// Main. Valid after `.roomFinished`.
    private(set) var lastResult: MeshScanResult?
    /// Hub-queue state (see `MeshEngineQueueState`).
    var q = MeshEngineQueueState()

    // MARK: Main-thread state

    /// `start()` created the folder and connected the hub.
    private var started = false
    /// True once `teardown()` ran.
    private var tornDown = false
    /// The borrowed hub's closures saved at `start()` (nil for an owned hub or before start).
    private var lentClosures: MeshLentHubClosures?

    // MARK: Hooks (lock-protected, read on the hub queue)

    /// Guards the hook closures and the camera transform.
    private let hookLock = NSLock()
    /// Backing store of `guidanceAugmenter`.
    private var guidanceStorage: ((inout GuidanceInput) -> Void)?
    /// Backing store of `snapshotAugmenter`.
    private var snapshotStorage: ((inout LiveScanSnapshot) -> Void)?
    /// Backing store of `latestCameraTransform`.
    private var cameraStorage: simd_float4x4?

    /// Hub queue hooks (lock-protected get and set): adjust the guidance input before
    /// `GuidanceEngine.update`, and each snapshot before it is posted. Callers pass closures formed
    /// outside any actor (`CoverageLiveRecorder.guidanceHook`, `snapshotHook`, or a nonisolated
    /// static helper), never a closure written inside a `@MainActor` method.
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)? {
        get { withHookLock { guidanceStorage } }
        set { withHookLock { guidanceStorage = newValue } }
    }
    /// Hub queue hook: adjusts each snapshot before it is posted to main (same rules).
    var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)? {
        get { withHookLock { snapshotStorage } }
        set { withHookLock { snapshotStorage = newValue } }
    }

    /// Latest camera to world (any thread; updated at most 10 times a second from frames).
    var latestCameraTransform: simd_float4x4? { withHookLock { cameraStorage } }

    /// Main actor (creates the hub when `hub` is nil). Nothing runs until `start()`.
    @MainActor init(target: MeshScanTarget, recorders: [ScanRecorder], hub: ARSessionHub? = nil) {
        self.target = target
        self.recorders = recorders
        if let hub {
            self.hub = hub
            ownsHub = false
        } else {
            self.hub = ARSessionHub(profile: target.profile)
            ownsHub = true
        }
        MeshScanLog.write("mesh engine init, pass \(target.passID), kind \(target.kind.rawValue), "
                          + "mode \(target.mode.rawValue), \(recorders.count) recorders, owned hub \(ownsHub)")
    }

    /// Logs "mesh engine deinit".
    deinit {
        MeshScanLog.write("mesh engine deinit")
    }

    // MARK: - ScanEngine (main)

    /// Main. Checks, folders, hub, recorders (order below). Throws before creating anything on disk
    /// when a check fails: `.ioFailed(problem)` for an invalid target, `.unsupportedDevice`,
    /// `.lowStorage(freeBytes:)` under `ProjectStore.refuseScanBelowBytes`.
    func start() throws {
        guard !started, !tornDown else {
            MeshScanLog.write("start ignored: already started or torn down")
            return
        }
        let freeBytes = ProjectStore.freeBytes()
        if let problem = MeshScanStats.startProblem(target, supportsMesh: ScanConfigurationFactory.supportsMesh,
                                                    freeBytes: freeBytes) {
            MeshScanLog.write("start refused: \(problem.copyKey) (\(problemDetail(problem)))")
            throw problem
        }
        let prepared = try prepareFolder()
        started = true
        connectHub()
        installHubClosures()
        MeshScanLog.write("mesh pass start \(target.passID): " + MeshScanLog.deviceLine())
        publish(state: .starting, events: [.stateChanged(.starting)])
        beginRecordingOnQueue(folder: prepared.folder, writer: prepared.writer)
    }

    /// Main. State `.paused`, keyframes paused (the session keeps running). Used for interruptions.
    func pause() {
        hub.queue.async { [weak self] in self?.applyPause(reason: "pause()") }
    }

    /// Main. Back to `.scanning`; after `sessionInterruptionEnded` the engine stays `.paused` until this call.
    func resume() {
        hub.queue.async { [weak self] in self?.applyResume() }
    }

    /// Main. `finish(attachments: [:])`.
    func finish() {
        finish(attachments: [:])
    }

    /// Main. The finish sequence; `attachments` are small extra files written into the folder
    /// root before the seal (names checked by `MeshScanStats.isSafeAttachmentName`), for example
    /// LargeObject's log. Unsafe names are dropped and logged.
    func finish(attachments: [String: Data]) {
        var checked: [String: Data] = [:]
        for (name, data) in attachments {
            if MeshScanStats.isSafeAttachmentName(name) {
                checked[name] = data
            } else {
                MeshScanLog.write("attachment refused: unsafe or reserved name (\(name.utf8.count) bytes)")
            }
        }
        // A let copy: the hub-queue closure must not capture a mutable local.
        let safe = checked
        hub.queue.async { [weak self] in
            self?.beginFinish(systemStop: nil, reason: "finish()", attachments: safe)
        }
    }

    /// Main. Ordered stop without sealing (recorders detached and finished, writer flushed and
    /// closed); raw stays in InProgress for recovery; then `.stateChanged(.idle)`.
    func cancel() {
        hub.queue.async { [weak self] in self?.beginAbandon(.cancel) }
    }

    /// Main. `cancel()`'s ordered stop, then `InProgressScans.discard(scanID:)` once the writer is
    /// closed, then `.stateChanged(.idle)`.
    func discard() {
        hub.queue.async { [weak self] in self?.beginAbandon(.discard) }
    }

    /// Main, idempotent, safe in any state: a capture still running gets `cancel()`'s ordered stop;
    /// recorders are detached; the four hub closures are restored to the ones saved at `start()` for
    /// a borrowed hub (nil for an owned hub); a borrowed hub gets `install()` again and keeps running,
    /// an owned hub is paused. Logs "mesh engine deinit" when released.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        hub.queue.async { [weak self] in
            guard let self else { return }
            if MeshScanStats.isCapturing(self.q.phase) && !self.q.finishStarted { self.beginAbandon(.cancel) }
        }
        for recorder in recorders { hub.detach(recorder) }
        if ownsHub {
            hub.onCaptureEvent = nil
            hub.onStatus = nil
            hub.onFrame = nil
            hub.onMemoryPressure = nil
        } else if let saved = lentClosures {
            hub.onCaptureEvent = saved.onCaptureEvent
            hub.onStatus = saved.onStatus
            hub.onFrame = saved.onFrame
            hub.onMemoryPressure = saved.onMemoryPressure
            lentClosures = nil
        }
        if MeshScanStats.pausesHubOnTeardown(ownsHub: ownsHub) {
            hub.pause()
            MeshScanLog.write("mesh engine teardown: owned hub paused, recorders detached, closures cleared")
        } else {
            hub.install()
            let delegateIsHub = hub.session.delegate === hub
            MeshScanLog.write("hub returned: running \(hub.isRunning), delegate === hub \(delegateIsHub), "
                              + "closures restored, recorders detached")
        }
    }

    // MARK: - Main-thread helpers

    /// A pass folder made by `prepareFolder`.
    struct PreparedPass {
        /// The InProgress folder.
        var folder: RawScanFolder
        /// Its writer (engine files: logs, events, attachments, session.json).
        var writer: RawScanWriter
    }

    /// Main. The session folder (where session.json goes), then the InProgress folder (kind and
    /// mode from the target) and the writer. IO failures remove what `InProgressScans.create` made
    /// and throw `.ioFailed`.
    func prepareFolder() throws -> PreparedPass {
        let package = target.package
        do {
            try ProjectStore.ensureDirectory(package.sessionURL(target.sessionID), inside: package.root)
        } catch {
            MeshScanLog.write("start refused: session folder (\(MeshScanStats.describe(error)))")
            throw MapperError.ioFailed("session folder: \(MeshScanStats.describe(error))")
        }
        let info = InProgressScanInfo(scanID: target.passID, projectID: target.projectID, sessionID: target.sessionID,
                                      roomID: target.scanInfoRoomID, kind: target.kind, mode: target.mode,
                                      startedAt: Date())
        let folder: RawScanFolder
        do {
            folder = try InProgressScans.create(info)
        } catch let error as MapperError {
            MeshScanLog.write("start refused: InProgress folder (\(error.copyKey))")
            throw error
        } catch {
            MeshScanLog.write("start refused: InProgress folder (\(MeshScanStats.describe(error)))")
            throw MapperError.ioFailed("InProgress folder: \(MeshScanStats.describe(error))")
        }
        return PreparedPass(folder: folder, writer: RawScanWriter(folder: folder))
    }

    /// Main. Owned hub: `install()`, `run()`. Borrowed hub: saves its four closures, `install()`,
    /// then re-applies the configuration when it runs (mesh and depth come back after RoomPlan;
    /// options stay [], so tracking, anchors and the world frame are kept), else `run()`. The
    /// profile of a borrowed hub is not changed.
    private func connectHub() {
        if ownsHub {
            hub.install()
            hub.run()
            MeshScanLog.write("owned hub run for pass \(target.passID)")
            return
        }
        lentClosures = MeshLentHubClosures(onCaptureEvent: hub.onCaptureEvent, onStatus: hub.onStatus,
                                           onFrame: hub.onFrame, onMemoryPressure: hub.onMemoryPressure)
        let wasRunning = hub.isRunning
        hub.install()
        if wasRunning {
            hub.reapplyConfiguration(reason: "mesh pass start")
        } else {
            hub.run()
        }
        let delegateIsHub = hub.session.delegate === hub
        MeshScanLog.write("hub lent to pass \(target.passID): running before \(wasRunning), "
                          + "\(wasRunning ? "configuration re-applied" : "run"), delegate === hub \(delegateIsHub)")
    }

    /// Sets the four hub closures with weak captures. Nonisolated on purpose: the hub calls them
    /// on its own queue, so they must never inherit main-actor isolation.
    private func installHubClosures() {
        hub.onStatus = { [weak self] status in self?.handleStatus(status) }
        hub.onCaptureEvent = { [weak self] event in self?.handleCaptureEvent(event) }
        hub.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        hub.onMemoryPressure = { [weak self] in self?.handleMemoryPressure() }
    }

    /// Log detail of a start problem (the validation text for `.ioFailed`).
    private func problemDetail(_ error: MapperError) -> String {
        switch error {
        case .ioFailed(let text): return text
        case .lowStorage(let bytes): return "\(bytes / 1_000_000) MB free"
        default: return "mesh supported \(ScanConfigurationFactory.supportsMesh)"
        }
    }

    // MARK: - Shared helpers (any thread)

    /// Sets `lastResult` and `state` (when given) and emits `events` in one main hop. The hop
    /// keeps the engine alive until it ran, so the last event of a torn-down pass still arrives.
    func publish(state newState: ScanEngineState?, events: [ScanEngineEvent], result: MeshScanResult? = nil) {
        DispatchQueue.main.async {
            if let result { self.lastResult = result }
            if let newState { self.state = newState }
            for event in events { self.onEvent?(event) }
        }
    }

    /// Hub queue. Stores the camera transform for `latestCameraTransform`.
    func storeCameraTransform(_ transform: simd_float4x4) {
        withHookLock { cameraStorage = transform }
    }

    /// Runs `body` while holding the hook lock.
    private func withHookLock<T>(_ body: () -> T) -> T {
        hookLock.lock()
        defer { hookLock.unlock() }
        return body()
    }
}
