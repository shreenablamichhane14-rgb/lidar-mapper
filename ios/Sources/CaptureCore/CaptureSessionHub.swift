import ARKit
import UIKit

/// Summary the hub publishes at most 4 times a second on its queue.
struct HubStatus: Equatable, Sendable {
    /// Tracking summary of the latest frame.
    var tracking: TrackingSummary = .initializing
    /// Which streams are working (D16).
    var degraded: DegradedMode = .allGood
    /// Device thermal level.
    var thermal: ThermalLevel = .nominal
    /// Free-space state (D18).
    var storage: StorageState = .ok
    /// Free space at the last storage sample, bytes.
    var freeBytes: Int64 = 0
    /// `os_proc_available_memory()` at this tick, bytes.
    var availableMemory: UInt64 = 0
    /// True when the latest frame carried scene depth.
    var depthPresent = false
    /// Mesh anchors currently in the session.
    var meshAnchorCount = 0
    /// True between `sessionWasInterrupted` and `sessionInterruptionEnded`.
    var interrupted = false
    /// Ambient light, lumens (nil without a light estimate).
    var ambientIntensity: Float? = nil
    /// Camera rotation speed over the last status interval.
    var angularSpeed: Float = 0          // rad/s
    /// Camera translation speed over the last status interval.
    var linearSpeed: Float = 0           // m/s
    /// Distance to what the camera looks at.
    var centerDistance: Float? = nil     // m, median of the 5x5 center depth pixels
    /// Mean depth confidence of the frame.
    var depthConfidenceMean: Float? = nil // 0...1 (ARConfidenceLevel / 2)
    /// Time since the scan started.
    var elapsed: Double = 0              // seconds since markScanStart
    /// Memory state (D17).
    var memory: MemoryState = .ok        // from MemoryProbe, two consecutive ticks (see MemoryPolicy)

    /// Defaults: initializing, all good, nominal, ok, nothing measured yet.
    init() {}
}

/// Owns one ARSession and its serial delegate queue (ARCHITECTURE 4.1).
///
/// The hub is the only object that sets `session.delegate`; it fans every callback out to the
/// attached `ScanRecorder`s on `queue`, runs the depth and mesh watchdog, the thermal, storage
/// and memory monitors, the once-per-second delegate identity check (with `ARDelegateRelay`)
/// and the D22 diagnostics, and publishes `HubStatus` at most 4 times a second. It does no
/// file IO and knows nothing about RoomPlan or UI. A plain NSObject, never `@MainActor`.
///
/// Order for RoomPlan (RESEARCH 3.2 recommended 2): `install()` first, then `run()`, then
/// create `RoomCaptureView(frame:arSession: hub.session)`, then `markScanStart` from
/// `captureSession(_:didStartWith:)` on the hub queue. Lifecycle members are in
/// CaptureSessionHub+Lifecycle.swift, frame and status work in CaptureSessionHub+Frames.swift.
final class ARSessionHub: NSObject, ARSessionDelegate {
    /// `CaptureEvent.detail` (kind `.tracking`) when the session was interrupted.
    static let interruptedDetail = "session interrupted"
    /// `CaptureEvent.detail` (kind `.tracking`) when the interruption ended.
    static let interruptionEndedDetail = "session interruption ended"
    /// Prefix of `CaptureEvent.detail` (kind `.error`) when the session failed.
    static let sessionFailedPrefix = "session failed: "
    /// Shortest interval between two `onStatus` calls, seconds (4 Hz).
    static let statusInterval: TimeInterval = 0.25
    /// Interval of the identity check and housekeeping timer, seconds.
    static let checkInterval: TimeInterval = 1
    /// Interval of the periodic memory event, seconds.
    static let memoryEventInterval: TimeInterval = 30
    /// Most relays installed per hub (guards against a delegate tug of war).
    static let maxRelayInstalls = 3

    /// The app-owned session shared with RoomPlan and live views.
    let session: ARSession
    /// Serial queue "mapper.ar.delegate", QoS userInitiated; also the queue of every recorder call.
    let queue: DispatchQueue
    /// Tracking history. Hub queue only.
    let tracking = TrackingMonitor()
    /// Thermal level and policy. Thread-safe.
    let thermal = ThermalGovernor()
    /// Free-space watchdog. Thread-safe.
    let storage = StorageWatchdog()
    /// D22 diagnostics. Hub queue only.
    let diagnostics: CaptureDiagnostics
    /// Whether the device supports scene depth and the LiDAR mesh (the watchdog watches only
    /// supported streams).
    let expectsDepth: Bool, expectsMesh: Bool

    /// Hub queue. Timeline events for events.jsonl.
    var onCaptureEvent: ((CaptureEvent) -> Void)? {
        get { locked { eventHandler } }
        set { locked { eventHandler = newValue } }
    }
    /// Hub queue, at most 4 Hz.
    var onStatus: ((HubStatus) -> Void)? {
        get { locked { statusHandler } }
        set { locked { statusHandler = newValue } }
    }
    /// Hub queue. Called for every frame after recorders (engines read counters here). Frames
    /// that arrive on a foreign queue are not forwarded.
    var onFrame: ((ARFrame) -> Void)? {
        get { locked { frameHandler } }
        set { locked { frameHandler = newValue } }
    }
    /// Hub queue. `UIApplication.didReceiveMemoryWarningNotification` (observed from init until
    /// `pause()`), forwarded once per warning.
    var onMemoryPressure: (() -> Void)? {
        get { locked { memoryHandler } }
        set { locked { memoryHandler = newValue } }
    }
    // Owners set these four closures with `[weak self]` captures and nil them in teardown;
    // the hub never keeps its owner alive. The hub logs a "hub deinit" line.

    /// Hub queue. The capture profile.
    var profile: ScanProfile { profileValue }
    /// Hub queue. Which streams work; reset by `markScanStart`.
    var degraded: DegradedMode { degradedValue }
    /// Hub queue. The latest published status.
    var status: HubStatus { statusValue }

    // MARK: Internal state (only for the ARSessionHub extension files; other modules must not
    // touch it). Lock-protected group: read and written only inside `locked`.

    /// Guards the lock-protected group.
    let lock = NSLock()
    /// Backing stores of the four handler closures.
    var eventHandler: ((CaptureEvent) -> Void)?, statusHandler: ((HubStatus) -> Void)?
    /// Backing stores of the four handler closures (continued).
    var frameHandler: ((ARFrame) -> Void)?, memoryHandler: (() -> Void)?
    /// Profile used to build configurations from any thread (`run`, `reapplyConfiguration`).
    var configurationProfile: ScanProfile
    /// True between `run` and `pause`.
    var running = false
    /// The installed relay (strong: the session's delegate slot is weak).
    var relayStorage: ARDelegateRelay?
    /// Identity check and housekeeping timer while running; memory warning observer token.
    var checkTimer: DispatchSourceTimer?, memoryObserver: NSObjectProtocol?
    /// Delegate callbacks that arrived off the hub queue.
    var foreignCallbacks = 0
    /// Marks `queue` so callbacks can tell whether they run on it.
    let queueKey = DispatchSpecificKey<UInt8>()

    // MARK: Internal state, hub-queue group: touched only on `queue`.

    /// Backing stores of `profile`, `degraded` and `status`.
    var profileValue: ScanProfile, degradedValue: DegradedMode = .allGood, statusValue = HubStatus()
    /// Attached recorders, in attach order.
    var recorders: [ScanRecorder] = []
    /// Depth and mesh arrival watchdog.
    var watchdog = CaptureWatchdogLogic()
    /// Identifiers of the mesh anchors currently in the session.
    var meshAnchorIDs = Set<UUID>()
    /// `markScanStart` timestamp (frame timebase); the watchdog runs only after it.
    var scanStartTimestamp: TimeInterval?
    /// Timestamp and `systemUptime` of the latest frame, and whether it had scene depth.
    var lastFrameTimestamp: TimeInterval?, lastFrameUptime: TimeInterval?, lastDepthPresent = false
    /// Tracking summary last reported as an event; interruption flag.
    var lastReportedTracking: TrackingSummary = .initializing, interrupted = false
    /// Latest identity check result, relays installed and checks run so far.
    var lastDelegateIsHub = true, relayInstalls = 0, identityChecks = 0
    /// Slowest frame callback since the last check, nanoseconds.
    var slowestCallbackNanos: UInt64 = 0
    /// `systemUptime` of the last periodic memory event and of the last status publish.
    var lastMemoryEventUptime: TimeInterval = 0, lastStatusPublish: TimeInterval = -1_000
    /// True while a deferred status publish is scheduled.
    var statusPublishScheduled = false
    /// Pose at the last status publish, for the speeds.
    var lastPose: (timestamp: TimeInterval, transform: simd_float4x4)?
    /// Available memory and memory state at the last status publish.
    var lastAvailableMemory: UInt64?, lastMemoryState: MemoryState = .ok
    /// True from a memory warning until the next status publish.
    var memoryWarningPending = false

    /// Main actor (reads `UIDevice.current.model` for diagnostics). Starts observing memory
    /// warnings; call `install()` and `run()` next.
    @MainActor init(profile: ScanProfile) {
        session = ARSession()
        queue = DispatchQueue(label: "mapper.ar.delegate", qos: .userInitiated)
        diagnostics = CaptureDiagnostics()
        profileValue = profile
        configurationProfile = profile
        expectsDepth = ScanConfigurationFactory.supportsDepth
        expectsMesh = ScanConfigurationFactory.supportsMesh
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
        registerMemoryWarningObserver()
        CaptureCoreLog.write("hub init, mode \(profile.mode.rawValue), mesh \(expectsMesh), depth \(expectsDepth)")
    }

    deinit {
        checkTimer?.cancel()
        if let token = memoryObserver { NotificationCenter.default.removeObserver(token) }
        thermal.stop()
        storage.stop()
        CaptureCoreLog.write("hub deinit")
    }

    // MARK: - ARSessionDelegate (exact signatures from RESEARCH 3.1, hub queue)

    /// Checks the queue, then (on the hub queue) fans the frame out to recorders, feeds the
    /// watchdog, diagnostics and `onFrame`; on a foreign queue only value copies hop over.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isOnQueue else {
            handleForeignFrame(frame)
            return
        }
        handleFrame(frame)
    }

    /// Records mesh anchor identifiers and fans the anchors out to recorders.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        handleAnchors(anchors, change: .added)
    }

    /// Records mesh anchor identifiers and fans the anchors out to recorders.
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        handleAnchors(anchors, change: .updated)
    }

    /// Forgets the mesh anchor identifiers and fans the anchors out to recorders.
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        handleAnchors(anchors, change: .removed)
    }

    /// Logs tracking changes as `.tracking` (and `.relocalization`) events.
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let summary = TrackingMonitor.summary(camera.trackingState)
        runOnQueue("cameraDidChangeTrackingState") { [weak self] in self?.handleTrackingChange(summary) }
    }

    /// Marks the interruption (`.tracking` event with `interruptedDetail`).
    func sessionWasInterrupted(_ session: ARSession) {
        runOnQueue("sessionWasInterrupted") { [weak self] in self?.handleInterruption(started: true) }
    }

    /// Marks the end of the interruption (`.tracking` event with `interruptionEndedDetail`).
    func sessionInterruptionEnded(_ session: ARSession) {
        runOnQueue("sessionInterruptionEnded") { [weak self] in self?.handleInterruption(started: false) }
    }

    /// Always true: ARKit tries to relocalize after an interruption (RESEARCH 3.1 recommended 9).
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        CaptureCoreLog.write("relocalization requested; answering true")
        return true
    }

    /// Logs the failure as an `.error` event (`sessionFailedPrefix` plus the description).
    func session(_ session: ARSession, didFailWithError error: any Error) {
        let nsError = error as NSError
        let detail = ARSessionHub.sessionFailedPrefix + "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
        runOnQueue("didFailWithError") { [weak self] in self?.emit(.error, detail) }
    }

    // MARK: - Queue and lock helpers

    /// True when running on `queue`.
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == 1 }

    /// Runs `work` now when on `queue`, else asynchronously on it.
    func performOnQueue(_ work: @escaping () -> Void) {
        if isOnQueue { work() } else { queue.async(execute: work) }
    }

    /// Like `performOnQueue` for delegate callbacks: a callback off the hub queue is counted
    /// and logged (`noteForeignQueue`) before its value copies hop over.
    func runOnQueue(_ label: String, _ work: @escaping () -> Void) {
        if isOnQueue {
            work()
        } else {
            noteForeignQueue(label)
            queue.async(execute: work)
        }
    }

    /// Runs `body` while holding `lock`.
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
