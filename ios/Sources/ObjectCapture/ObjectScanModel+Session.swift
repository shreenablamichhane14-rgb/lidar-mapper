import Foundation
import RealityKit
// `ObjectCaptureSession` lives in the RealityKit + SwiftUI cross-import overlay (rule 0.2.13).
import SwiftUI

// The capture model's update Tasks, its log (`objectlog.json`) and the off-main work of sealing
// and discarding (docs/MODULES.md 3.33 "Capture flow"; REUSE 2.1 and 2.5).

/// Contents of `objectlog.json`: capture diagnostics and the device's runtime limits.
struct ObjectCaptureLog: Codable, Equatable, Sendable {
    /// File name inside the scan folder.
    static let fileName = "objectlog.json"
    /// The object, the capture's wall-clock start and its length in seconds.
    var objectID: UUID
    var startedAt: Date
    var seconds: Double
    /// Photos the session took.
    var shotCount: Int
    /// `ObjectCaptureSession.maximumNumberOfInputImages` read after `start`.
    var maximumNumberOfInputImages: Int
    /// `PhotogrammetrySession.limits` (device-specific, RESEARCH 3.3 disputed 4).
    var photogrammetryMaxImages: Int
    var photogrammetryMaxImageDimension: Int
    /// Laps reached (1...3) and flips made.
    var passes: Int
    var flips: Int
    /// Seconds each feedback case was present, keyed by `ObjectCaptureSignals.name(of:)`.
    var feedbackSeconds: [String: Double]
    /// Seconds tracking was not normal, and `startDetecting()` calls that found nothing.
    var trackingLimitedSeconds: Double
    var detectionFailures: Int
    /// Last stage name and the failure, when any (logs only).
    var finalStage: String
    var failure: String?
    /// Device state (`ThermalLevel` raw values, bytes) and the OS version string.
    var thermalAtStart: String
    var thermalAtEnd: String
    var freeBytesAtStart: Int64
    var availableMemoryAtStart: UInt64
    var osVersion: String
}

/// What the capture model accumulates for `objectlog.json`. Pure (the caller passes the clock),
/// so the self-test checks the timing arithmetic.
struct ObjectScanDiagnostics: Equatable, Sendable {
    /// Wall-clock start and monotonic start, seconds.
    var startedAt = Date(timeIntervalSince1970: 0)
    var startUptime: Double = 0
    /// Device state at start.
    var thermalAtStart = ThermalLevel.nominal.rawValue
    var freeBytesAtStart: Int64 = 0
    var availableMemoryAtStart: UInt64 = 0
    /// Runtime limits (never constants).
    var maximumNumberOfInputImages = 0
    var photogrammetryMaxImages = 0
    var photogrammetryMaxImageDimension = 0
    /// Flips made and `startDetecting()` calls that found nothing.
    var flips = 0
    var detectionFailures = 0
    /// Closed feedback time per name, and the start of each open one.
    var feedbackSeconds: [String: Double] = [:]
    var feedbackSince: [String: Double] = [:]
    /// Closed limited-tracking time, and the start of the open interval.
    var trackingLimitedSeconds: Double = 0
    var limitedSince: Double?

    /// Creates empty diagnostics.
    init() {}

    /// Records the start state.
    mutating func begin(startedAt: Date, uptime: Double, thermal: ProcessInfo.ThermalState, freeBytes: Int64,
                        availableMemory: UInt64, photogrammetryLimits: (images: Int, dimension: Int)) {
        self.startedAt = startedAt
        startUptime = uptime
        thermalAtStart = ThermalLevel(thermal).rawValue
        freeBytesAtStart = freeBytes
        availableMemoryAtStart = availableMemory
        photogrammetryMaxImages = photogrammetryLimits.images
        photogrammetryMaxImageDimension = photogrammetryLimits.dimension
    }

    /// The feedback now present: closes the intervals of names that went away and opens new ones.
    mutating func noteFeedback(_ names: Set<String>, now: Double) {
        let openIntervals = feedbackSince
        for (name, since) in openIntervals where !names.contains(name) {
            feedbackSeconds[name, default: 0] += Swift.max(0, now - since)
            feedbackSince[name] = nil
        }
        for name in names where feedbackSince[name] == nil {
            feedbackSince[name] = now
        }
    }

    /// The tracking now: opens a limited interval, or closes it when tracking is normal again.
    mutating func noteTracking(normal: Bool, now: Double) {
        if normal {
            guard let since = limitedSince else { return }
            trackingLimitedSeconds += Swift.max(0, now - since)
            limitedSince = nil
        } else if limitedSince == nil {
            limitedSince = now
        }
    }

    /// The log at `uptime` (open intervals are closed on a copy).
    func makeLog(objectID: UUID, shots: Int, passes: Int, finalStage: String, failure: String?,
                 thermalAtEnd: ProcessInfo.ThermalState, osVersion: String, uptime: Double) -> ObjectCaptureLog {
        var closed = self
        closed.noteFeedback([], now: uptime)
        closed.noteTracking(normal: true, now: uptime)
        return ObjectCaptureLog(objectID: objectID, startedAt: startedAt, seconds: Swift.max(0, uptime - startUptime),
                                shotCount: shots, maximumNumberOfInputImages: maximumNumberOfInputImages,
                                photogrammetryMaxImages: photogrammetryMaxImages,
                                photogrammetryMaxImageDimension: photogrammetryMaxImageDimension,
                                passes: passes, flips: flips, feedbackSeconds: closed.feedbackSeconds,
                                trackingLimitedSeconds: closed.trackingLimitedSeconds,
                                detectionFailures: detectionFailures, finalStage: finalStage, failure: failure,
                                thermalAtStart: thermalAtStart, thermalAtEnd: ThermalLevel(thermalAtEnd).rawValue,
                                freeBytesAtStart: freeBytesAtStart, availableMemoryAtStart: availableMemoryAtStart,
                                osVersion: osVersion)
    }
}

extension ObjectScanModel {
    // MARK: Update tasks

    /// Starts one Task per update sequence of `session`. Each Task captures only its sequence and
    /// `[weak self]`, forwards every value to the matching handler on the main actor, and stops
    /// when the model is gone or `teardown()` cancels it.
    func attachListeners(to session: ObjectCaptureSession) {
        let states = session.stateUpdates
        let feedback = session.feedbackUpdates
        let tracking = session.cameraTrackingUpdates
        let passes = session.userCompletedScanPassUpdates
        let shots = session.numberOfShotsTakenUpdates
        let paused = session.isPausedUpdates
        updateTasks.append(Task { [weak self] in
            for await value in states {
                guard let self else { return }
                self.handleState(value)
            }
        })
        updateTasks.append(Task { [weak self] in
            for await value in feedback {
                guard let self else { return }
                self.handleFeedback(value)
            }
        })
        updateTasks.append(Task { [weak self] in
            for await value in tracking {
                guard let self else { return }
                self.handleTracking(value)
            }
        })
        updateTasks.append(Task { [weak self] in
            for await value in passes {
                guard let self else { return }
                self.handlePassCompleted(value)
            }
        })
        updateTasks.append(Task { [weak self] in
            for await value in shots {
                guard let self else { return }
                self.handleShots(value)
            }
        })
        updateTasks.append(Task { [weak self] in
            for await value in paused {
                guard let self else { return }
                self.handlePaused(value)
            }
        })
    }

    /// Logs the limits line (every scan: `maximumNumberOfInputImages`, `PhotogrammetrySession.limits`)
    /// and the session settings Mapper leaves on (auto capture, the session's haptics).
    func logStart(_ session: ObjectCaptureSession) {
        let object = target.objectID
        let limits = "maximumNumberOfInputImages \(session.maximumNumberOfInputImages), photogrammetry limits "
            + "\(diagnostics.photogrammetryMaxImages) images / \(diagnostics.photogrammetryMaxImageDimension) px"
        ObjectCaptureSignals.log("object \(object): limits: \(limits)")
        let settings = "autoCapture \(session.isAutoCaptureEnabled), sessionHaptics \(session.shouldPlayHaptics), overCapture off"
        let device = "thermal \(diagnostics.thermalAtStart), free \(diagnostics.freeBytesAtStart) bytes, "
            + "memory \(diagnostics.availableMemoryAtStart) bytes"
        ObjectCaptureSignals.log("object \(object): session started, \(settings), \(device)")
    }

    // MARK: Start helpers

    /// `InProgressScans.create` with `InProgressScanInfo(scanID: objectID, projectID:, sessionID: nil,
    /// roomID: objectID, kind: .object, mode: .object, startedAt:)` (no ARKit session; the object id
    /// in `roomID` as for large objects), then `ObjectScanFolders.prepare`; a failing prepare
    /// removes the new folder before rethrowing.
    nonisolated static func makeScanFolder(for target: ObjectScanTarget) throws -> (folder: RawScanFolder, images: URL, checkpoint: URL) {
        let scanID = target.objectID
        let info = InProgressScanInfo(scanID: scanID, projectID: target.projectID, sessionID: nil, roomID: scanID,
                                      kind: .object, mode: .object, startedAt: Date())
        let created = try InProgressScans.create(info)
        do {
            let paths = try ObjectScanFolders.prepare(created)
            return (folder: created, images: paths.images, checkpoint: paths.checkpoint)
        } catch {
            do {
                try InProgressScans.discard(scanID: scanID)
            } catch {
                ObjectCaptureSignals.log("object \(scanID): removing the new folder failed (\(StoreFiles.describe(error)))")
            }
            throw error
        }
    }

    /// Records the start state (time, heat, free space, memory, photogrammetry limits).
    func beginDiagnostics() {
        diagnostics.begin(startedAt: Date(), uptime: ObjectScanModel.uptime(), thermal: ProcessInfo.processInfo.thermalState,
                          freeBytes: ProjectStore.freeBytes(), availableMemory: ProcessingGuards.availableMemory(),
                          photogrammetryLimits: PhotogrammetryStore.deviceLimits())
    }

    // MARK: Helpers

    /// Images currently in the scan's `Images/` folder (0 before `start`).
    func currentImageCount() -> Int {
        guard let folder else { return 0 }
        return ObjectScanFolders.imageCount(in: ObjectScanFolders.imagesURL(in: folder))
    }

    /// Stages in which `pause()` is meaningful.
    nonisolated static func canPause(_ stage: ObjectCaptureStage) -> Bool {
        stage == .ready || stage == .detecting || stage == .capturing
    }

    /// Monotonic seconds for durations and the announcer.
    nonisolated static func uptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: Quiet guidance

    /// The announcer's defaults: the `quietGuidanceSuite` suite with `SettingsKey.guidanceHaptics`
    /// registered as false (the registration domain is in memory; nothing is written), so the
    /// announcer speaks but never vibrates. Falls back to `.standard` (the user's setting) only
    /// when the suite cannot be opened (logged).
    nonisolated static func quietGuidanceDefaults() -> UserDefaults {
        guard let suite = UserDefaults(suiteName: quietGuidanceSuite) else {
            ObjectCaptureSignals.log("quiet guidance suite unavailable; using standard defaults")
            return .standard
        }
        suite.register(defaults: [SettingsKey.guidanceHaptics: false])
        return suite
    }

    // MARK: Off-main work

    /// Writes `objectlog.json` through the writer, `await writer.flush()`, `writer.close()` (and a
    /// flush so the close has run), then `ObjectScanFolders.seal` in `Task.detached`. Nothing is
    /// written into the folder after SEAL.json.
    nonisolated static func writeLogAndSeal(_ log: ObjectCaptureLog, folder: RawScanFolder, writer: RawScanWriter,
                                            target: ObjectScanTarget) async throws -> ObjectScanResult {
        let logURL = folder.url.appendingPathComponent(ObjectCaptureLog.fileName, isDirectory: false)
        let data = try ProjectStore.encoder.encode(log)
        writer.writeFile(data, to: logURL)
        await writer.flush()
        writer.close()
        await writer.flush()
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            throw MapperError.ioFailed("\(ObjectCaptureLog.fileName) was not written")
        }
        return try await Task.detached(priority: .userInitiated) { () throws -> ObjectScanResult in
            let images = ObjectScanFolders.imageCount(in: ObjectScanFolders.imagesURL(in: folder))
            try ObjectScanFolders.seal(folder, objectID: target.objectID, package: target.package)
            return ObjectScanResult(objectID: target.objectID, sealedFolder: target.package.rawObjectURL(target.objectID),
                                    imageCount: images, log: log)
        }.value
    }

    /// Closes the writer, waits for it, then removes the InProgress folder (nothing when the scan
    /// never made one, `writer == nil`). Failures are logged; the folder then stays for recovery.
    nonisolated static func discardFolder(scanID: UUID, writer: RawScanWriter?) async {
        guard let writer else { return }
        writer.close()
        await writer.flush()
        do {
            try InProgressScans.discard(scanID: scanID)
        } catch {
            ObjectCaptureSignals.log("object \(scanID): discard failed (\(StoreFiles.describe(error)))")
        }
    }
}
