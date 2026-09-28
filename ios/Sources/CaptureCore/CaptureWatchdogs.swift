import Foundation
import os

// MARK: - Storage (D18)

/// Free-space state during capture (D18).
enum StorageState: String, Equatable, Sendable {
    /// Enough space: capture as usual.
    case ok
    /// Under `ProjectStore.stopKeyframesBelowBytes` (1 GB): no more keyframes.
    case stopKeyframes
    /// Under `ProjectStore.pauseCaptureBelowBytes` (300 MB): the engine finishes the room.
    case pause
}

/// 10 s free-space watchdog (D18). Thread-safe. Sampling runs on a private utility queue so
/// the volume query never stalls the hub queue; changes are reported on the caller's queue.
final class StorageWatchdog {
    /// Seconds between samples.
    private let interval: TimeInterval
    /// Reads free bytes (`ProjectStore.freeBytes()` in the app, a fake in the self-test).
    private let readFreeBytes: () -> Int64
    /// Queue the timer samples on.
    private let sampleQueue = DispatchQueue(label: "mapper.storage.watchdog", qos: .utility)
    /// Guards every mutable property below.
    private let lock = NSLock()
    /// Last state computed.
    private var currentState: StorageState = .ok
    /// Last free bytes read (0 before the first sample).
    private var currentFreeBytes: Int64 = 0
    /// Repeating timer while started.
    private var timer: DispatchSourceTimer?
    /// Where change callbacks go while started.
    private var callbackQueue: DispatchQueue?
    /// Change callback while started.
    private var onChange: ((StorageState) -> Void)?

    /// Creates a watchdog that samples every `interval` seconds once started.
    init(interval: TimeInterval = 10, freeBytes: @escaping () -> Int64 = { ProjectStore.freeBytes() }) {
        self.interval = max(1, interval)
        readFreeBytes = freeBytes
    }

    /// Cancels the timer if the owner never called `stop()`.
    deinit {
        timer?.cancel()
    }

    /// The last computed state (`.ok` before the first sample).
    var state: StorageState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// The last free-space reading, bytes.
    var freeBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return currentFreeBytes
    }

    /// Samples at once and then every `interval` seconds; `onChange` is called on `queue`
    /// after every change of state. Calling it again replaces the queue and callback.
    func start(on queue: DispatchQueue, onChange: @escaping (StorageState) -> Void) {
        lock.lock()
        callbackQueue = queue
        self.onChange = onChange
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: sampleQueue)
            source.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
            source.setEventHandler { [weak self] in
                _ = self?.sample()
            }
            // Resumed under the lock, so a concurrent stop() never cancels a suspended source.
            source.resume()
            timer = source
        }
        lock.unlock()
    }

    /// Stops sampling and drops the callback. Idempotent.
    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        callbackQueue = nil
        onChange = nil
        lock.unlock()
        source?.cancel()
    }

    /// Reads free space now, updates the state and reports a change to the callback (if
    /// started). Returns the new state. Called by the timer; callable directly in tests.
    @discardableResult
    func sample() -> StorageState {
        let bytes = readFreeBytes()
        let newState = StorageWatchdog.state(forFreeBytes: bytes)
        lock.lock()
        let changed = newState != currentState
        currentState = newState
        currentFreeBytes = bytes
        let queue = callbackQueue
        let callback = onChange
        lock.unlock()
        if bytes <= 0 {
            CaptureCoreLog.once("storage.zero", "storage watchdog read 0 free bytes (unreadable or full)")
        }
        if changed, let queue, let callback {
            queue.async { callback(newState) }
        }
        return newState
    }

    /// Below `ProjectStore.pauseCaptureBelowBytes` pause, below `stopKeyframesBelowBytes` stop keyframes.
    static func state(forFreeBytes bytes: Int64) -> StorageState {
        if bytes < ProjectStore.pauseCaptureBelowBytes { return .pause }
        if bytes < ProjectStore.stopKeyframesBelowBytes { return .stopKeyframes }
        return .ok
    }
}

// MARK: - Memory (D17)

/// Reads the process memory headroom.
enum MemoryProbe {
    /// `os_proc_available_memory()` as UInt64 (import os): bytes the app can still allocate
    /// before jetsam; 0 when already over the limit.
    static func availableBytes() -> UInt64 {
        UInt64(clamping: os_proc_available_memory())
    }
}

/// Memory state during capture, from `MemoryPolicy`.
enum MemoryState: String, Equatable, Sendable {
    /// Enough headroom.
    case ok
    /// Under 600 MB for two status ticks: keyframes stop.
    case low
    /// Under 400 MB for two status ticks, or a memory warning: the engine flushes and finishes.
    case critical
}

/// Capture memory floor (D17, RESEARCH 3.9 "pause capture on memory warnings"). Starting values,
/// tuned from open device question 6.
enum MemoryPolicy {
    /// `.low`: keyframes stop, tier 1 note logged.
    static let stopKeyframesBelowBytes: UInt64 = 600_000_000
    /// `.critical`: the engine flushes and finishes.
    static let finishBelowBytes: UInt64 = 400_000_000

    /// Pure: .critical below 400 MB or after a memory warning, .low below 600 MB, each only when
    /// the previous sample agreed (two consecutive status ticks), else .ok.
    static func state(available: UInt64, previous: UInt64?, warning: Bool) -> MemoryState {
        if warning { return .critical }
        guard let previous else { return .ok }
        let agreed = min(severity(available), severity(previous))
        switch agreed {
        case 2: return .critical
        case 1: return .low
        default: return .ok
        }
    }

    /// 0 ok, 1 low, 2 critical for one sample on its own.
    private static func severity(_ bytes: UInt64) -> Int {
        if bytes < finishBelowBytes { return 2 }
        if bytes < stopKeyframesBelowBytes { return 1 }
        return 0
    }
}

// MARK: - Depth and mesh arrival (ship-first 3.1 step 6)

/// What the depth and mesh watchdog asks the hub to do.
enum WatchdogAction: Equatable, Sendable {
    /// Nothing to do.
    case none
    /// Re-run the configuration with no options (at most once per scan).
    case reapply(reason: String)
    /// A stream is still missing after the re-apply: record the degraded mode.
    case degrade(DegradedMode)
}

/// Depth and mesh arrival watchdog (ship-first 3.1 step 6), pure logic for testing.
struct CaptureWatchdogLogic: Equatable, Sendable {
    /// Seconds without scene depth before the re-apply.
    static let depthMissingSeconds: Double = 2
    /// Seconds of normal tracking without any mesh anchor before the re-apply.
    static let meshMissingSeconds: Double = 8
    /// Seconds after the re-apply before a stream still missing is declared stripped.
    static let degradeAfterReapplySeconds: Double = 2
    /// Longest gap between two frames counted toward the normal-tracking mesh timer, so an
    /// interruption does not fill the timer at once.
    static let maxCountedGap: Double = 1
    /// Tolerance for accumulated frame intervals.
    private static let epsilon: Double = 1e-6

    /// Timestamp of the previous observation.
    private var lastTimestamp: Double?
    /// When depth went missing, nil while depth arrives.
    private var depthMissingSince: Double?
    /// Normal-tracking seconds with no mesh anchor.
    private var normalSecondsWithoutMesh: Double = 0
    /// When the one re-apply was requested.
    private(set) var reappliedAt: Double?
    /// True once `.degrade(.depthStripped)` was returned.
    private(set) var depthDegraded = false
    /// True once `.degrade(.meshStripped)` was returned.
    private(set) var meshDegraded = false

    /// A fresh watchdog.
    init() {}

    /// Feed once per frame. Re-apply once when depth is missing for 2 s or no mesh anchor
    /// after 8 s of normal tracking; degrade (.depthStripped or .meshStripped) if still
    /// missing 2 s after that re-apply. Pass `depthPresent: true` (or a positive anchor count)
    /// for a stream the device does not support, so it is never watched.
    mutating func observe(timestamp: Double, depthPresent: Bool, meshAnchorCount: Int, trackingNormal: Bool) -> WatchdogAction {
        var delta: Double = 0
        if let last = lastTimestamp {
            delta = min(max(0, timestamp - last), CaptureWatchdogLogic.maxCountedGap)
        }
        lastTimestamp = timestamp

        if depthPresent {
            depthMissingSince = nil
        } else if depthMissingSince == nil {
            depthMissingSince = timestamp
        }
        if meshAnchorCount > 0 {
            normalSecondsWithoutMesh = 0
        } else if trackingNormal {
            normalSecondsWithoutMesh += delta
        }

        var depthDue = false
        if let since = depthMissingSince {
            depthDue = timestamp - since >= CaptureWatchdogLogic.depthMissingSeconds - CaptureWatchdogLogic.epsilon
        }
        let meshLimit = CaptureWatchdogLogic.meshMissingSeconds - CaptureWatchdogLogic.epsilon
        let meshDue = meshAnchorCount == 0 && normalSecondsWithoutMesh >= meshLimit

        if depthDue && !depthDegraded {
            if let action = escalate(timestamp: timestamp, mode: .depthStripped,
                                     reason: "no scene depth for 2 s") {
                return action
            }
        }
        if meshDue && !meshDegraded {
            if let action = escalate(timestamp: timestamp, mode: .meshStripped,
                                     reason: "no mesh anchor after 8 s of normal tracking") {
                return action
            }
        }
        return .none
    }

    /// Forgets everything (new room or pass).
    mutating func reset() {
        self = CaptureWatchdogLogic()
    }

    /// First due stream re-applies; after that a due stream degrades once 2 s have passed
    /// since the re-apply.
    private mutating func escalate(timestamp: Double, mode: DegradedMode, reason: String) -> WatchdogAction? {
        guard let reapplied = reappliedAt else {
            reappliedAt = timestamp
            return .reapply(reason: reason)
        }
        let wait = CaptureWatchdogLogic.degradeAfterReapplySeconds - CaptureWatchdogLogic.epsilon
        guard timestamp - reapplied >= wait else { return nil }
        if mode == .depthStripped { depthDegraded = true } else { meshDegraded = true }
        return .degrade(mode)
    }
}
