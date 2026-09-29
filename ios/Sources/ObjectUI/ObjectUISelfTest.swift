import Foundation
import simd

/// ObjectUI self-test (docs/MODULES.md 3.42): the flow reducer, the alerts, the result
/// availability, the stage and time texts (this file), the size rows, the textured choice,
/// the viewer parts and the demo object (ObjectUISelfTest+Files.swift). Plain Swift,
/// deterministic, no camera, ARKit, Object Capture or network; temporary files only under
/// `FileManager.default.temporaryDirectory`, removed before returning. Nonisolated.
enum ObjectUISelfTest {
    /// Collects check results.
    final class Recorder {
        /// Failure lines, "name: detail".
        var failures: [String] = []
        /// Number of checks run so far.
        var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        /// Records a failure when `actual` is nil or farther than `tolerance` from `expected`.
        func near(_ name: String, _ actual: Float?, _ expected: Float, _ tolerance: Float) {
            count += 1
            guard let value = actual else {
                failures.append("\(name): expected \(expected), got nil")
                return
            }
            if !(abs(value - expected) <= tolerance) {
                failures.append("\(name): expected \(expected), got \(value)")
            }
        }

        /// Records an unexpected error.
        func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): threw \(error)")
        }
    }

    /// Runs every check; returns one line per failure, empty when all pass.
    static func run() -> [String] {
        let r = Recorder()
        flowCases(r)
        alertCases(r)
        availabilityCases(r)
        textCases(r)
        rowCases(r)
        texturedCases(r)
        partCases(r)
        demoCases(r)
        LogStore.shared.write("objectui self-test: \(r.count) checks, \(r.failures.count) failed",
                              category: ObjectPresentation.logCategory)
        return r.failures
    }

    // MARK: - Fixtures

    /// A fixed UUID whose last byte is `n`.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    /// A fixed date (no `Date()` in self-tests).
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// Files with dims.json and the given model and mesh flags.
    static func files(size: ObjectSize, model: Bool, mesh: Bool, dims: Bool, texture: Bool = false) -> ObjectResultFiles {
        var result = ObjectResultFiles()
        result.size = size
        result.hasModel = model
        result.hasMesh = mesh
        result.hasDimensions = dims
        result.hasTexture = texture
        return result
    }

    /// A running job on `step` with the runner's fraction.
    static func running(_ step: PipelineStepID, fraction: Double) -> ProjectProcessingState {
        var state = ProjectProcessingState()
        state.isRunning = true
        state.currentStep = step
        state.fraction = fraction
        return state
    }

    // MARK: - Flow

    /// `nextPhase`: the small path, skipped tips, Large, a blocked preflight, a denied
    /// permission, cancels, the end of a capture, failures and terminal phases.
    static func flowCases(_ r: Recorder) {
        let project = fixedID(1)
        let signals: [ObjectFlowSignal] = [.choseSmallMedium, .permissionNeeded, .permissionGranted(showTips: true),
                                           .tipsDone, .captureSealed, .saved(project)]
        var phase = ObjectFlowPhase.chooser
        var visited: [ObjectFlowPhase] = [phase]
        for signal in signals {
            phase = ObjectFlowModel.nextPhase(phase, on: signal)
            visited.append(phase)
        }
        let expected: [ObjectFlowPhase] = [.chooser, .preflight, .permission, .tips, .capturing, .saving, .done(project)]
        r.check("flow.smallPath", visited == expected, "\(visited)")
        let noTips: ObjectFlowPhase = ObjectFlowModel.nextPhase(.preflight, on: .preflightPassed(showTips: false))
        let withTips: ObjectFlowPhase = ObjectFlowModel.nextPhase(.preflight, on: .preflightPassed(showTips: true))
        let grantedNoTips: ObjectFlowPhase = ObjectFlowModel.nextPhase(.permission, on: .permissionGranted(showTips: false))
        let skipOK: Bool = noTips == ObjectFlowPhase.capturing && withTips == ObjectFlowPhase.tips
        r.check("flow.skipTips", skipOK && grantedNoTips == ObjectFlowPhase.capturing)
        let large: ObjectFlowPhase = ObjectFlowModel.nextPhase(.chooser, on: .choseLarge)
        let afterLarge: ObjectFlowPhase = ObjectFlowModel.nextPhase(large, on: .choseSmallMedium)
        r.check("flow.large", large == ObjectFlowPhase.largeChosen && afterLarge == ObjectFlowPhase.largeChosen)
        let blocked: ObjectFlowPhase = ObjectFlowModel.nextPhase(.preflight, on: .preflightBlocked)
        let deniedAtPreflight: ObjectFlowPhase = ObjectFlowModel.nextPhase(.preflight, on: .permissionDenied)
        r.check("flow.blockedPreflight", blocked == ObjectFlowPhase.cancelled && deniedAtPreflight == ObjectFlowPhase.cancelled)
        let denied: ObjectFlowPhase = ObjectFlowModel.nextPhase(.permission, on: .permissionDenied)
        r.check("flow.permissionDenied", denied == ObjectFlowPhase.cancelled)
        let cancellable: [ObjectFlowPhase] = [.chooser, .preflight, .permission, .tips]
        let allCancel: Bool = cancellable.allSatisfy { ObjectFlowModel.nextPhase($0, on: .cancelled) == ObjectFlowPhase.cancelled }
        let captureIgnores: Bool = ObjectFlowModel.nextPhase(.capturing, on: .cancelled) == ObjectFlowPhase.capturing
        r.check("flow.cancel", allCancel && captureIgnores)
        let ended: ObjectFlowPhase = ObjectFlowModel.nextPhase(.capturing, on: .captureEnded)
        r.check("flow.captureEnded", ended == ObjectFlowPhase.cancelled)
        let failedCapture: ObjectFlowPhase = ObjectFlowModel.nextPhase(.capturing, on: .failed("x"))
        let failedSaving: ObjectFlowPhase = ObjectFlowModel.nextPhase(.saving, on: .failed("y"))
        r.check("flow.failed", failedCapture == ObjectFlowPhase.failed("x") && failedSaving == ObjectFlowPhase.failed("y"))
        let done = ObjectFlowPhase.done(project)
        let doneStays: Bool = ObjectFlowModel.nextPhase(done, on: .failed("z")) == done
        let cancelledStays: Bool = ObjectFlowModel.nextPhase(.cancelled, on: .choseSmallMedium) == ObjectFlowPhase.cancelled
        r.check("flow.terminalIgnores", doneStays && cancelledStays)
        let chooserStays: Bool = ObjectFlowModel.nextPhase(.chooser, on: .tipsDone) == ObjectFlowPhase.chooser
        let tipsStay: Bool = ObjectFlowModel.nextPhase(.tips, on: .captureSealed) == ObjectFlowPhase.tips
        r.check("flow.unrelatedSignal", chooserStays && tipsStay)
    }

    // MARK: - Alerts

    /// Preflight alerts for every issue, ScanUI's issues, dropped capture actions, start failures.
    static func alertCases(_ r: Recorder) {
        let issues: [ObjectPreflightIssue] = [.unsupported, .lowStorage(free: 1_000_000_000), .deviceHot, .deviceWarm]
        let complete = issues.allSatisfy { issue in
            let alert = ObjectAlert.preflight(issue)
            return !alert.id.isEmpty && !alert.title.isEmpty && !alert.body.isEmpty && !alert.actions.isEmpty
        }
        r.check("alert.preflightEveryIssue", complete)
        let storage = ObjectAlert.preflight(.lowStorage(free: 1))
        let needed = ScanErrorCopy.sizeText(ProjectStore.objectCapturePreflightBytes)
        r.check("alert.preflightStorageSize", storage.body == Copy.Errors.storageFullBody(needed), storage.body)
        let hotTitle: String = ObjectAlert.preflight(.deviceHot).title
        let warmTitle: String = ObjectAlert.preflight(.deviceWarm).title
        r.check("alert.preflightHot", hotTitle == Copy.ObjectUI.tooHotToStart.title && warmTitle == Copy.ScanUI.warmTitle)

        let quiet: [PreflightIssue] = [.cameraUndetermined, .lowBattery(0.1), .storageWarning(free: 1), .deviceHot]
        r.check("alert.scanPreflightNil", quiet.allSatisfy { ObjectAlert.scanPreflight($0) == nil })
        let denied: ObjectAlert? = ObjectAlert.scanPreflight(.cameraDenied)
        let deniedActions: [ObjectAlertAction] = denied?.actions ?? []
        r.check("alert.cameraDeniedSettings", deniedActions.contains(.openSettings)
                && denied?.title == Copy.Permissions.cameraDeniedTitle)
        let lidarTitle: String? = ObjectAlert.scanPreflight(.noLidar)?.title
        let storageTitle: String? = ObjectAlert.scanPreflight(.lowStorage(free: 1))?.title
        r.check("alert.scanBlocking", lidarTitle == Copy.Errors.noLidar.title && storageTitle == Copy.Errors.storageFullTitle)
        let batteryTitle: String? = ObjectAlert.scanWarning(.lowBattery(0.1))?.title
        let noWarning: Bool = ObjectAlert.scanWarning(.noLidar) == nil
        r.check("alert.scanWarnings", batteryTitle == Copy.Errors.lowBattery.title && noWarning)

        let capture = ScanAlert(id: "t", title: "a", body: "b", actions: [.resume, .finishNow])
        let mixed = ScanAlert(id: "t", title: "a", body: "b", actions: [.openSettings, .finishNow, .ok])
        let captureActions: [ObjectAlertAction] = ObjectAlert.from(capture).actions
        let mixedActions: [ObjectAlertAction] = ObjectAlert.from(mixed).actions
        r.check("alert.fromDropsCaptureActions", captureActions == [ObjectAlertAction.ok]
                && mixedActions == [ObjectAlertAction.openSettings, ObjectAlertAction.ok])
        let unsupported: Bool = ObjectAlert.startFailure(MapperError.unsupportedDevice) == ObjectAlert.preflight(.unsupported)
        let hot: Bool = ObjectAlert.startFailure(MapperError.deviceTooHot) == ObjectAlert.preflight(.deviceHot)
        let genericTitle: String = ObjectAlert.startFailure(MapperError.objectCaptureFailed("x")).title
        r.check("alert.startFailure", unsupported && hot && genericTitle == Copy.Errors.generic.title)
        let warm = ObjectAlert.preflight(.deviceWarm)
        let scanWarm = ObjectAlert.scanWarning(.deviceHot)
        let unique = ObjectAlert.uniqueWarnings([warm] + (scanWarm.map { [$0] } ?? []))
        r.check("alert.warmShownOnce", unique.count == 1 && scanWarm?.id == warm.id)
    }

    // MARK: - Availability

    /// Processing with percent and time left while reconstructing, the waiting text, ready
    /// small and large, failed, noObject, and Retry.
    static func availabilityCases(_ r: Recorder) {
        let objectID = fixedID(2)
        let ready = files(size: .smallMedium, model: true, mesh: true, dims: true)
        var monitor = PhotogrammetryProgress(objectID: objectID)
        monitor.fraction = 0.42
        monitor.stage = .imageAlignment
        monitor.remainingSeconds = 150
        let reconstructing = ObjectPresentation.availability(files: ready, processing: running(.reconstructObject, fraction: 0.3),
                                                             status: .processing, progress: monitor)
        r.check("avail.reconstructingPercent", reconstructing == .processing(text: Copy.ObjectUI.stageAligning, percent: 42,
                                                                             remaining: Copy.ObjectUI.remainingMinutes(3)),
                "\(reconstructing)")
        let early = ObjectPresentation.availability(files: ObjectResultFiles(), processing: running(.reconstructObject, fraction: 0.1),
                                                    status: .needsProcessing, progress: nil)
        r.check("avail.beforeMonitor", early == .processing(text: Copy.ObjectUI.stagePreparing, percent: 10, remaining: nil),
                "\(early)")
        var queued = ProjectProcessingState()
        queued.isQueued = true
        let waiting = ObjectPresentation.availability(files: ObjectResultFiles(), processing: queued, status: .needsProcessing,
                                                      progress: nil)
        r.check("avail.waitingQueued", waiting == .processing(text: Copy.ObjectUI.waiting, percent: nil, remaining: nil))
        let measuring = ObjectPresentation.availability(files: ObjectResultFiles(), processing: running(.objectMetrics, fraction: 0.5),
                                                        status: .processing, progress: nil)
        r.check("avail.measuring", measuring == .processing(text: Copy.ObjectUI.stageMeasuring, percent: 50, remaining: nil))
        let idle = ProjectProcessingState()
        let readySmall = ObjectPresentation.availability(files: ready, processing: idle, status: .ready, progress: nil)
        r.check("avail.readySmall", readySmall == ObjectResultAvailability.ready, "\(readySmall)")
        let large = files(size: .large, model: false, mesh: true, dims: true)
        let readyLarge = ObjectPresentation.availability(files: large, processing: running(.thumbnail, fraction: 0),
                                                         status: .processing, progress: nil)
        r.check("avail.readyLargeMeshOnly", readyLarge == ObjectResultAvailability.ready, "\(readyLarge)")
        let failedReason = ObjectResultAvailability.failed(reason: Copy.Errors.processingFailed.body)
        let attention = ObjectPresentation.availability(files: ObjectResultFiles(), processing: idle, status: .needsAttention,
                                                        progress: nil)
        r.check("avail.failedNeedsAttention", attention == failedReason, "\(attention)")
        var stepFailed = ProjectProcessingState()
        stepFailed.failed[.objectMetrics] = "no model"
        let failedStep = ObjectPresentation.availability(files: ObjectResultFiles(), processing: stepFailed, status: .processing,
                                                         progress: nil)
        r.check("avail.failedStep", failedStep == failedReason, "\(failedStep)")
        var none = ready
        none.hasObject = false
        let noObject = ObjectPresentation.availability(files: none, processing: queued, status: .needsProcessing, progress: nil)
        r.check("avail.noObject", noObject == ObjectResultAvailability.noObject)
        let dimsOnly = files(size: .smallMedium, model: false, mesh: false, dims: true)
        let notReady = ObjectPresentation.availability(files: dimsOnly, processing: idle, status: .needsProcessing, progress: nil)
        r.check("avail.dimsOnlyNotReady", notReady != ObjectResultAvailability.ready)
        let retryAttention: Bool = ObjectPresentation.showsRetry(status: .needsAttention, processing: idle)
        let retryFailed: Bool = ObjectPresentation.showsRetry(status: .ready, processing: stepFailed)
        let noRetry: Bool = !ObjectPresentation.showsRetry(status: .ready, processing: idle)
        r.check("avail.retry", retryAttention && retryFailed && noRetry)
    }

    // MARK: - Text

    /// Stage texts for the six stages, time left, percent rounding and notes.
    static func textCases(_ r: Recorder) {
        let texts = PhotogrammetryStage.allCases.map { ObjectPresentation.stageText($0) }
        r.check("text.stagesDistinct", texts.count == 6 && Set(texts).count == 6 && texts.allSatisfy { !$0.isEmpty }, "\(texts)")
        let nilStage: String = ObjectPresentation.stageText(nil)
        let meshStage: String = ObjectPresentation.stageText(.meshGeneration)
        r.check("text.stageNil", nilStage == Copy.ObjectUI.stagePreparing && meshStage == Copy.Processing.stepShape)
        r.check("text.remaining30", ObjectPresentation.remainingText(seconds: 30) == Copy.ObjectUI.remainingSoon)
        r.check("text.remaining150", ObjectPresentation.remainingText(seconds: 150) == "About 3 min left",
                ObjectPresentation.remainingText(seconds: 150) ?? "nil")
        let noEstimate: String? = ObjectPresentation.remainingText(seconds: nil)
        let negative: String? = ObjectPresentation.remainingText(seconds: -1)
        let notFinite: String? = ObjectPresentation.remainingText(seconds: Double.nan)
        r.check("text.remainingNil", noEstimate == nil && negative == nil && notFinite == nil)
        let percents: [Int] = [0.29, Double.nan, 1.5, -1].map { ObjectPresentation.percent($0) }
        r.check("text.percent", percents == [29, 0, 100, 0], "\(percents)")
        let info = PhotogrammetryInfo(objectID: fixedID(3), imageCount: 40, boundsMin: nil, boundsMax: nil, seconds: 60,
                                      invalidSamples: 0, skippedSamples: 0, downsampled: true, stitchingIncomplete: true,
                                      maximumNumberOfInputImages: 200, maximumInputImageDimension: 4096,
                                      thermalAtStart: "nominal", thermalAtEnd: "fair", inputHash: "h", finishedAt: fixedDate)
        var quiet = info
        quiet.downsampled = false
        quiet.stitchingIncomplete = false
        let bothNotes: [String] = ObjectPresentation.notes(info: info)
        let quietEmpty: Bool = ObjectPresentation.notes(info: quiet).isEmpty && ObjectPresentation.notes(info: nil).isEmpty
        r.check("text.notes", bothNotes == [Copy.ObjectUI.downsampledNote, Copy.ObjectUI.stitchingNote] && quietEmpty)
    }
}
