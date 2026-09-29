import Foundation
import simd
import RealityKit
// Photogrammetry types are imported with SwiftUI as well as RealityKit (rule 0.2.13).
import SwiftUI

/// Output mapping, the progress reducer, the capture diagnostics and the activity counters.
extension ObjectCaptureSelfTest {
    // MARK: Photogrammetry outputs

    /// `stage` for all six stages and `event` for the outputs the step reacts to.
    static func photogrammetryChecks(_ failures: inout [String]) {
        typealias Stage = PhotogrammetrySession.Output.ProcessingStage
        let stages: [(stage: Stage, want: PhotogrammetryStage)] = [
            (stage: .preProcessing, want: .preProcessing), (stage: .imageAlignment, want: .imageAlignment),
            (stage: .pointCloudGeneration, want: .pointCloudGeneration), (stage: .meshGeneration, want: .meshGeneration),
            (stage: .textureMapping, want: .textureMapping), (stage: .optimization, want: .optimization),
        ]
        for row in stages {
            let got = PhotogrammetryOutputs.stage(row.stage)
            check(&failures, "photogrammetry.stage.\(row.want.rawValue)", got == row.want,
                  "got \(String(describing: got))")
        }

        typealias Output = PhotogrammetrySession.Output
        let modelRequest = PhotogrammetrySession.Request.modelFile(url: URL(fileURLWithPath: "/nonexistent/model.usdz"))
        let simple: [(output: Output, want: PhotogrammetryEvent?, name: String)] = [
            (output: .inputComplete, want: .inputComplete, name: "inputComplete"),
            (output: .processingComplete, want: .completed, name: "processingComplete"),
            (output: .processingCancelled, want: .cancelled, name: "processingCancelled"),
            (output: .automaticDownsampling, want: .downsampled, name: "automaticDownsampling"),
            (output: .stitchingIncomplete, want: .stitchingIncomplete, name: "stitchingIncomplete"),
            (output: .invalidSample(id: 3, reason: "selftest"), want: .invalidSample, name: "invalidSample"),
            (output: .skippedSample(id: 4), want: .skippedSample, name: "skippedSample"),
            (output: .requestProgress(.bounds, fractionComplete: 0.4), want: nil, name: "boundsProgress"),
            (output: .requestProgress(modelRequest, fractionComplete: 0.4), want: .progress(0.4), name: "modelProgress"),
        ]
        for row in simple {
            let got = PhotogrammetryOutputs.event(row.output)
            check(&failures, "photogrammetry.event.\(row.name)", got == row.want, "got \(String(describing: got))")
        }

        let box = BoundingBox(min: SIMD3<Float>(-0.1, 0, -0.2), max: SIMD3<Float>(0.3, 0.25, 0.2))
        let bounds = PhotogrammetryOutputs.event(.requestComplete(.bounds, .bounds(box)))
        let written = PhotogrammetryOutputs.event(.requestComplete(modelRequest, .modelFile(URL(fileURLWithPath: "/nonexistent/m.usdz"))))
        let boundsOK: Bool = bounds == PhotogrammetryEvent.boundsReceived
        let writtenOK: Bool = written == PhotogrammetryEvent.modelWritten
        check(&failures, "photogrammetry.event.requestComplete", boundsOK && writtenOK,
              "bounds \(String(describing: bounds)), model \(String(describing: written))")
        let failed = PhotogrammetryOutputs.event(.requestError(modelRequest, NSError(domain: "mapper.selftest", code: 3)))
        var isFailure = false
        if case .requestFailed = failed { isFailure = true }
        check(&failures, "photogrammetry.event.requestError", isFailure, "got \(String(describing: failed))")
        check(&failures, "photogrammetry.isModelRequest",
              PhotogrammetryOutputs.isModelRequest(modelRequest) && !PhotogrammetryOutputs.isModelRequest(.bounds),
              "request kind wrong")
    }

    /// `reduce` of progress, stage and counters; `boundsExtents`.
    static func reduceChecks(_ failures: inout [String]) {
        let id = fixedID(1)
        var progress = PhotogrammetryProgress(objectID: id)
        progress = PhotogrammetryOutputs.reduce(progress, .inputComplete)
        progress = PhotogrammetryOutputs.reduce(progress, .progress(0.5))
        progress = PhotogrammetryOutputs.reduce(progress, .progress(0.3))
        check(&failures, "reduce.progressMonotonic", progress.fraction == 0.5 && progress.inputComplete,
              "fraction \(progress.fraction)")
        progress = PhotogrammetryOutputs.reduce(progress, .progress(7))
        check(&failures, "reduce.progressClamped", progress.fraction == 1, "fraction \(progress.fraction)")

        var staged = PhotogrammetryProgress(objectID: id)
        staged = PhotogrammetryOutputs.reduce(staged, .stage(.meshGeneration, remaining: 90))
        staged = PhotogrammetryOutputs.reduce(staged, .stage(nil, remaining: nil))
        let stageKept: Bool = staged.stage == PhotogrammetryStage.meshGeneration
        let remainingKept: Bool = staged.remainingSeconds == 90.0
        check(&failures, "reduce.stageKept", stageKept && remainingKept,
              "stage \(String(describing: staged.stage)), remaining \(String(describing: staged.remainingSeconds))")

        var counted = PhotogrammetryProgress(objectID: id)
        for event in [PhotogrammetryEvent.invalidSample, .invalidSample, .skippedSample, .downsampled, .stitchingIncomplete] {
            counted = PhotogrammetryOutputs.reduce(counted, event)
        }
        let countersOK = counted.invalidSamples == 2 && counted.skippedSamples == 1
        check(&failures, "reduce.counters", countersOK && counted.downsampled && counted.stitchingIncomplete,
              "invalid \(counted.invalidSamples), skipped \(counted.skippedSamples)")
        let completed = PhotogrammetryOutputs.reduce(PhotogrammetryProgress(objectID: id), .completed)
        check(&failures, "reduce.completed", completed.fraction == 1, "fraction \(completed.fraction)")

        let info = sampleInfo(id)
        let extents = info.boundsExtents ?? SIMD3<Float>(repeating: 0)
        let expected = SIMD3<Float>(0.4, 0.25, 0.4)
        let error: Float = simd_length(extents - expected)
        check(&failures, "info.boundsExtents", error < 1e-5, "got \(extents)")
        var noBounds = info
        noBounds.boundsMax = nil
        check(&failures, "info.noBounds", noBounds.boundsExtents == nil, "extents without bounds")
    }

    /// A reconstruction info with a 0.4 x 0.25 x 0.4 m box and fixed values.
    static func sampleInfo(_ id: UUID) -> PhotogrammetryInfo {
        PhotogrammetryInfo(objectID: id, imageCount: 42, boundsMin: Vec3(x: -0.1, y: 0, z: -0.2),
                           boundsMax: Vec3(x: 0.3, y: 0.25, z: 0.2), seconds: 181.5, invalidSamples: 1,
                           skippedSamples: 2, downsampled: true, stitchingIncomplete: false,
                           maximumNumberOfInputImages: 300, maximumInputImageDimension: 4032,
                           thermalAtStart: "nominal", thermalAtEnd: "fair", inputHash: "0123456789abcdef",
                           finishedAt: fixedDate)
    }

    // MARK: Diagnostics

    /// Feedback and tracking durations and the log they produce.
    static func diagnosticsChecks(_ failures: inout [String]) {
        var diagnostics = ObjectScanDiagnostics()
        diagnostics.begin(startedAt: fixedDate, uptime: 100, thermal: .nominal, freeBytes: 5_000_000_000,
                          availableMemory: 2_000_000_000, photogrammetryLimits: (images: 300, dimension: 4032))
        diagnostics.noteFeedback(["movingTooFast"], now: 101)
        diagnostics.noteFeedback(["movingTooFast", "objectTooFar"], now: 102)
        diagnostics.noteFeedback(["objectTooFar"], now: 104)
        diagnostics.noteTracking(normal: false, now: 105)
        diagnostics.noteTracking(normal: false, now: 106)
        diagnostics.noteTracking(normal: true, now: 107)
        diagnostics.noteTracking(normal: false, now: 109)
        let log = diagnostics.makeLog(objectID: fixedID(2), shots: 55, passes: 2, finalStage: "completed", failure: nil,
                                      thermalAtEnd: .fair, osVersion: "selftest", uptime: 110)
        let fast = log.feedbackSeconds["movingTooFast"] ?? -1
        let far = log.feedbackSeconds["objectTooFar"] ?? -1
        check(&failures, "diagnostics.feedbackSeconds", fast == 3 && far == 8, "movingTooFast \(fast), objectTooFar \(far)")
        check(&failures, "diagnostics.trackingSeconds", log.trackingLimitedSeconds == 3,
              "got \(log.trackingLimitedSeconds)")
        let secondsOK: Bool = log.seconds == 10
        let limitsOK: Bool = log.photogrammetryMaxImages == 300 && log.shotCount == 55
        let thermalOK: Bool = log.thermalAtStart == "nominal" && log.thermalAtEnd == "fair"
        check(&failures, "diagnostics.log", secondsOK && limitsOK && thermalOK,
              "seconds \(log.seconds), thermal \(log.thermalAtStart) -> \(log.thermalAtEnd)")
        let stillLimited = diagnostics.limitedSince == 109
        let stillFar = diagnostics.feedbackSince["objectTooFar"] == 102
        check(&failures, "diagnostics.openIntervalsKept", stillLimited && stillFar, "makeLog changed the running diagnostics")
    }

    // MARK: Activity and quiet guidance

    /// Counters up and down, idempotent tokens, the reconstruction wait, the quiet announcer.
    static func activityChecks(_ failures: inout [String]) {
        let baseCapture = ObjectCaptureActivity.captureSessions
        let token = ObjectCaptureSessionToken()
        token.acquire()
        token.acquire()
        let held = ObjectCaptureActivity.captureSessions
        let releasedFirst = token.release()
        let releasedSecond = token.release()
        let after = ObjectCaptureActivity.captureSessions
        let countsOK = held == baseCapture + 1 && after == baseCapture
        check(&failures, "activity.captureToken", countsOK && releasedFirst && !releasedSecond,
              "base \(baseCapture), held \(held), after \(after)")

        let baseReconstruction = ObjectCaptureActivity.reconstructionSessions
        ObjectCaptureActivity.reconstructionStarted()
        let counted = ObjectCaptureActivity.reconstructionSessions
        let busy: Bool? = baseReconstruction == 0 ? waitSynchronously(timeout: 0.5) : false
        ObjectCaptureActivity.reconstructionEnded()
        let uncounted = ObjectCaptureActivity.reconstructionSessions
        let reconstructionOK = counted == baseReconstruction + 1 && uncounted == baseReconstruction
        check(&failures, "activity.reconstructionCount", reconstructionOK,
              "base \(baseReconstruction), counted \(counted), after \(uncounted)")
        if baseReconstruction == 0 {
            let idle = waitSynchronously(timeout: 0.5)
            check(&failures, "activity.waitWhileCounted", busy == false, "got \(String(describing: busy))")
            check(&failures, "activity.waitWhenIdle", idle == true, "got \(String(describing: idle))")
        } else {
            ObjectCaptureSignals.log("self-test: a real reconstruction is counted; wait checks skipped")
        }

        let defaults = ObjectScanModel.quietGuidanceDefaults()
        let haptics = defaults.object(forKey: SettingsKey.guidanceHaptics) as? Bool
        check(&failures, "quietAnnouncer.hapticsOff", haptics == false, "got \(String(describing: haptics))")
        let pausable = [ObjectCaptureStage.ready, .detecting, .capturing].allSatisfy { ObjectScanModel.canPause($0) }
        check(&failures, "model.canPause", pausable && !ObjectScanModel.canPause(.finishing), "pause rule wrong")
    }

    /// Runs `waitForNoReconstruction(timeout:)` on a detached task and blocks until it returns
    /// (at most `timeout + 2` seconds); nil when it did not return in time.
    private static func waitSynchronously(timeout: Double) -> Bool? {
        let box = SelfTestResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let idle = await ObjectCaptureActivity.waitForNoReconstruction(timeout: timeout)
            box.set(idle)
            done.signal()
        }
        let limit: Double = timeout + 2
        let deadline: DispatchTime = DispatchTime.now() + limit
        _ = done.wait(timeout: deadline)
        return box.value
    }

    // MARK: Fixtures

    /// A fixed UUID whose last byte is `n`.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x0C, 0x0A, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    /// A fixed date with whole seconds (ISO 8601 round trips exactly).
    static let fixedDate = Date(timeIntervalSince1970: 1_758_000_000)
}

/// Lock-protected result slot for `waitSynchronously`.
private final class SelfTestResultBox: @unchecked Sendable {
    /// Protects `stored`.
    private let lock = NSLock()
    /// The result, once set.
    private var stored: Bool?

    /// Stores the result.
    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    /// The result, nil until set.
    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
