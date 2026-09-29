import Foundation
import RealityKit
// `ObjectCaptureSession` and its nested types live in the RealityKit + SwiftUI cross-import
// overlay, so every file naming them imports both (docs/MODULES.md rule 0.2.13).
import SwiftUI

// The capture value types, state, error and feedback mapping, the Object Capture preflight and
// the capture versus reconstruction counters (docs/MODULES.md 3.33; RESEARCH 3.3 gotchas 1, 3,
// 10 and 15).

/// Mapper's copy of `ObjectCaptureSession.CaptureState` without the error payload.
enum ObjectCaptureStage: String, Equatable, Sendable {
    case initializing, ready, detecting, capturing, finishing, completed, failed
}

/// Why a capture stopped (from `ObjectCaptureSession.Error`, RESEARCH 3.3).
enum ObjectScanFailure: Equatable, Sendable {
    case cancelled, directoryNotEmpty, insufficientStorage(requiredBytes: Int64), sensorFailed, trackingFailed
    /// Any other error; the payload is for the log only.
    case other(String)
}

/// What an object scan becomes: the project, its package and the object id.
struct ObjectScanTarget: Equatable, Sendable {
    /// The project the object belongs to.
    var projectID: UUID
    /// The project's package.
    var package: ProjectPackage
    /// The `ObjectRecord.id` the scan will become (also `InProgressScanInfo.roomID`, which
    /// carries the object id for `kind == .object`).
    var objectID: UUID
}

/// A sealed object scan.
struct ObjectScanResult: Equatable, Sendable {
    /// The object id.
    var objectID: UUID
    /// `raw/objects/<id>/` after sealing.
    var sealedFolder: URL
    /// Image files sealed under `Images/`.
    var imageCount: Int
    /// The `objectlog.json` written before sealing.
    var log: ObjectCaptureLog
}

/// Where the capture model is.
enum ObjectScanPhase: Equatable, Sendable {
    case idle, capturing, reviewing, finishing, sealing
    case done(ObjectScanResult)
    /// The session failed; `imageCount` photos are on disk (Use These Photos needs at least
    /// `ObjectScanFolders.minimumImages`).
    case failed(ObjectScanFailure, imageCount: Int)
    case cancelled
}

/// One preflight finding. `unsupported`, `lowStorage` and `deviceHot` block; `deviceWarm` warns.
enum ObjectPreflightIssue: Equatable, Sendable { case unsupported, lowStorage(free: Int64), deviceHot, deviceWarm }

/// Result of the Object Capture preflight: at most one blocking issue plus warnings.
struct ObjectPreflightReport: Equatable, Sendable {
    /// The issue that stops the scan, nil when it may start.
    var blocking: ObjectPreflightIssue?
    /// Issues shown before starting that do not stop it.
    var warnings: [ObjectPreflightIssue]
}

/// Object Capture preflight (D18; RESEARCH 3.3 gotcha 1). Camera permission, battery and LiDAR
/// are ScanUI's `ScanPreflight`.
enum ObjectCapturePreflight {
    /// Pure. Blocking: either API unsupported, free space below
    /// `ProjectStore.objectCapturePreflightBytes` (3 GB, D18), thermal `.critical`. Warning:
    /// thermal `.serious`.
    static func evaluate(captureSupported: Bool, photogrammetrySupported: Bool, freeBytes: Int64,
                         thermal: ThermalLevel) -> ObjectPreflightReport {
        var blocking: ObjectPreflightIssue?
        if !captureSupported || !photogrammetrySupported {
            blocking = .unsupported
        } else if freeBytes < ProjectStore.objectCapturePreflightBytes {
            blocking = .lowStorage(free: freeBytes)
        } else if thermal == .critical {
            blocking = .deviceHot
        }
        let warnings: [ObjectPreflightIssue] = thermal == .serious ? [.deviceWarm] : []
        return ObjectPreflightReport(blocking: blocking, warnings: warnings)
    }

    /// Reads `ObjectCaptureSession.isSupported` (main actor), `PhotogrammetrySession.isSupported`,
    /// `ProjectStore.freeBytes()` and the thermal state (RESEARCH 3.3 gotcha 1: check before
    /// creating a session). Logs the inputs and the result.
    @MainActor static func run() -> ObjectPreflightReport {
        let capture = ObjectCaptureSession.isSupported
        let photogrammetry = PhotogrammetrySession.isSupported
        let free = ProjectStore.freeBytes()
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let report = evaluate(captureSupported: capture, photogrammetrySupported: photogrammetry,
                              freeBytes: free, thermal: thermal)
        let blockingText: String
        if let blocking = report.blocking {
            blockingText = "\(blocking)"
        } else {
            blockingText = "none"
        }
        let inputs = "capture \(capture), photogrammetry \(photogrammetry), free \(free) bytes, thermal \(thermal.rawValue)"
        ObjectCaptureSignals.log("preflight: \(inputs), blocking \(blockingText), warnings \(report.warnings.count)")
        return report
    }
}

/// Lock-protected counters, any thread, so an `ObjectCaptureSession` and a `PhotogrammetrySession`
/// never live at the same time (RESEARCH 3.3 gotcha 10): neither when a finished capture hands
/// over to the pipeline, nor when a new capture starts while `ProcessingRunner.suspendAll` is
/// still cancelling a reconstruction (it only flags the step, and `PhotogrammetrySession.cancel()`
/// is asynchronous, gotcha 9).
enum ObjectCaptureActivity {
    /// The counters and their lock.
    private final class Counters: @unchecked Sendable {
        /// Protects both counts.
        let lock = NSLock()
        /// Live capture sessions.
        var capture = 0
        /// Live reconstruction sessions.
        var reconstruction = 0
    }

    /// The process-wide counters.
    private static let counters = Counters()
    /// Poll interval of `waitForNoReconstruction`, seconds.
    static let pollSeconds: Double = 0.25

    /// Sessions ObjectScanModel holds: +1 right after `ObjectCaptureSession()`, -1 when `teardown`
    /// releases it.
    static var captureSessions: Int {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        return counters.capture
    }

    /// Sessions alive in PhotogrammetryStep: +1 right before `PhotogrammetrySession(input:configuration:)`,
    /// -1 after the output loop ended and the session reference was dropped (every exit path).
    static var reconstructionSessions: Int {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        return counters.reconstruction
    }

    /// Counts a new capture session; logs an overlap with a counted reconstruction.
    static func captureStarted() {
        let (capture, reconstruction) = change(capture: 1, reconstruction: 0)
        ObjectCaptureSignals.log("activity: capture started (captures \(capture), reconstructions \(reconstruction))"
                                 + (reconstruction > 0 ? " OVERLAP" : ""))
    }

    /// Counts a released capture session (never below zero).
    static func captureReleased() {
        let (capture, reconstruction) = change(capture: -1, reconstruction: 0)
        ObjectCaptureSignals.log("activity: capture released (captures \(capture), reconstructions \(reconstruction))")
    }

    /// Counts a new reconstruction session; logs an overlap with a counted capture.
    static func reconstructionStarted() {
        let (capture, reconstruction) = change(capture: 0, reconstruction: 1)
        ObjectCaptureSignals.log("activity: reconstruction started (captures \(capture), reconstructions \(reconstruction))"
                                 + (capture > 0 ? " OVERLAP" : ""))
    }

    /// Counts an ended reconstruction session (never below zero).
    static func reconstructionEnded() {
        let (capture, reconstruction) = change(capture: 0, reconstruction: -1)
        ObjectCaptureSignals.log("activity: reconstruction ended (captures \(capture), reconstructions \(reconstruction))")
    }

    /// Polls every 0.25 s until `reconstructionSessions == 0` or `timeout` seconds passed; true when
    /// idle. AppShell awaits it before any capture cover starts its flow (3.43e). Returns at once
    /// when nothing is counted.
    static func waitForNoReconstruction(timeout: Double) async -> Bool {
        guard reconstructionSessions > 0 else { return true }
        let start = ProcessInfo.processInfo.systemUptime
        let nanoseconds = UInt64(pollSeconds * 1_000_000_000)
        while reconstructionSessions > 0 {
            let waited = ProcessInfo.processInfo.systemUptime - start
            if waited >= timeout {
                ObjectCaptureSignals.log("activity: reconstruction still counted after \(format(waited)) s, gave up")
                return false
            }
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        ObjectCaptureSignals.log("activity: waited \(format(ProcessInfo.processInfo.systemUptime - start)) s for a reconstruction to end")
        return true
    }

    /// Adds the deltas under the lock (clamping at zero) and returns the new counts.
    private static func change(capture: Int, reconstruction: Int) -> (Int, Int) {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        counters.capture = Swift.max(0, counters.capture + capture)
        counters.reconstruction = Swift.max(0, counters.reconstruction + reconstruction)
        return (counters.capture, counters.reconstruction)
    }

    /// Seconds with two decimals for the log.
    private static func format(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}

/// Holds one `ObjectCaptureActivity` capture count for `ObjectScanModel`: `acquire` and `release`
/// are idempotent and thread-safe, and a token released by deinit (a model dropped without
/// `teardown`) still gives its count back, so a reconstruction never waits for a session that
/// no longer exists.
final class ObjectCaptureSessionToken: @unchecked Sendable {
    /// Protects `held`.
    private let lock = NSLock()
    /// True while this token holds a count.
    private var held = false

    /// Creates a token that holds nothing.
    init() {}

    /// Counts a capture session unless this token already holds one.
    func acquire() {
        lock.lock()
        let first = !held
        held = true
        lock.unlock()
        if first { ObjectCaptureActivity.captureStarted() }
    }

    /// Gives the count back; true when this call released it.
    @discardableResult
    func release() -> Bool {
        lock.lock()
        let wasHeld = held
        held = false
        lock.unlock()
        if wasHeld { ObjectCaptureActivity.captureReleased() }
        return wasHeld
    }

    /// Releases a count still held when the owner goes away.
    deinit {
        if held { ObjectCaptureActivity.captureReleased() }
    }
}

/// Pure mappings, nonisolated (the self-test builds these enum values; no session is created).
enum ObjectCaptureSignals {
    /// Log category of the module.
    static let logCategory = "objectcapture"
    /// Log name of a feedback case this build does not know.
    static let unknownFeedbackName = "unknown"

    /// Writes one line to the app log under `logCategory`.
    static func log(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }

    /// Maps the session state; a state added by a future SDK counts as `.failed`.
    static func stage(_ state: ObjectCaptureSession.CaptureState) -> ObjectCaptureStage {
        switch state {
        case .initializing: return .initializing
        case .ready: return .ready
        case .detecting: return .detecting
        case .capturing: return .capturing
        case .finishing: return .finishing
        case .completed: return .completed
        case .failed: return .failed
        @unknown default: return .failed
        }
    }

    /// `ObjectCaptureSession.Error` cases one to one; anything else `.other(localizedDescription)`.
    static func failure(_ error: any Error) -> ObjectScanFailure {
        guard let captureError = error as? ObjectCaptureSession.Error else {
            return .other(error.localizedDescription)
        }
        switch captureError {
        case .cancelled: return .cancelled
        case .directoryNotEmpty: return .directoryNotEmpty
        case .insufficientStorage(let requiredBytes): return .insufficientStorage(requiredBytes: requiredBytes)
        case .sensorFailed: return .sensorFailed
        case .trackingFailed: return .trackingFailed
        @unknown default: return .other(captureError.localizedDescription)
        }
    }

    /// Stable log names ("movingTooFast", ...), distinct for the nine cases; "unknown" for a case
    /// added by a future SDK.
    static func name(of feedback: ObjectCaptureSession.Feedback) -> String {
        switch feedback {
        case .environmentLowLight: return "environmentLowLight"
        case .environmentTooDark: return "environmentTooDark"
        case .movingTooFast: return "movingTooFast"
        case .objectNotDetected: return "objectNotDetected"
        case .objectNotFlippable: return "objectNotFlippable"
        case .objectTooClose: return "objectTooClose"
        case .objectTooFar: return "objectTooFar"
        case .outOfFieldOfView: return "outOfFieldOfView"
        case .overCapturing: return "overCapturing"
        @unknown default: return unknownFeedbackName
        }
    }

    /// True only for `.normal`; Apple's coaching overlay shows for anything else (RESEARCH 3.10
    /// gotcha 14), so Mapper's controls hide.
    static func isNormal(_ tracking: ObjectCaptureSession.Tracking) -> Bool {
        switch tracking {
        case .normal: return true
        case .notAvailable, .limited: return false
        @unknown default: return false
        }
    }

    /// True when the set holds `.objectNotFlippable` (RESEARCH 3.3 gotcha 15).
    static func containsNotFlippable(_ feedback: Set<ObjectCaptureSession.Feedback>) -> Bool {
        feedback.contains(.objectNotFlippable)
    }

    /// True when the set holds `.overCapturing` (the shot counter turns red).
    static func containsOverCapturing(_ feedback: Set<ObjectCaptureSession.Feedback>) -> Bool {
        feedback.contains(.overCapturing)
    }

    /// The `MapperError` `ObjectScanModel.start()` throws for a blocking preflight issue
    /// (`deviceWarm` never blocks and maps to nil).
    static func startError(for issue: ObjectPreflightIssue) -> MapperError? {
        switch issue {
        case .unsupported: return .unsupportedDevice
        case .lowStorage(let free): return .lowStorage(freeBytes: free)
        case .deviceHot: return .deviceTooHot
        case .deviceWarm: return nil
        }
    }
}
