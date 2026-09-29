import Foundation
import Combine
import RealityKit
// `ObjectCaptureSession` lives in the RealityKit + SwiftUI cross-import overlay (rule 0.2.13).
import SwiftUI

/// Main actor. Owns at most one `ObjectCaptureSession` (RESEARCH 3.3; REUSE 2.5). Stored Tasks
/// iterate `stateUpdates`, `feedbackUpdates`, `cameraTrackingUpdates`,
/// `userCompletedScanPassUpdates`, `numberOfShotsTakenUpdates` and `isPausedUpdates` with
/// `for await`, capturing `[weak self]`; `teardown()` cancels them. The listeners, the log and
/// the sealing work are in `ObjectScanModel+Session.swift`; every published change is made here.
/// The model never writes the manifest (ObjectUI does).
@MainActor final class ObjectScanModel: ObservableObject {
    @Published private(set) var phase: ObjectScanPhase = .idle
    @Published private(set) var stage: ObjectCaptureStage = .initializing
    @Published private(set) var onboarding: ObjectOnboardingState = .firstSegment
    @Published private(set) var shotCount = 0
    /// `maximumNumberOfInputImages`, never a constant (RESEARCH 3.3 recommended 1).
    @Published private(set) var shotLimit = 0
    @Published private(set) var trackingNormal = true
    @Published private(set) var isPaused = false
    /// `.overCapturing` present: the shot counter turns red.
    @Published private(set) var overCapturing = false
    @Published private(set) var flipRecommended = true
    /// `startDetecting()` returned false: the hint `Copy.ObjectCapture.notFoundHint` shows.
    @Published private(set) var detectionFailed = false
    /// Done tapped with fewer than `minimumImages` shots.
    @Published var showsTooFewPhotos = false
    /// True while the lap review sheet is shown (it pauses the session).
    @Published private(set) var reviewPresented = false

    /// The scan's project, package and object id.
    let target: ObjectScanTarget
    /// Guidance banner source: `GuidanceSignals.guidance(for:)` of the live feedback, presented
    /// through an announcer whose defaults have `SettingsKey.guidanceHaptics` false, so VoiceOver
    /// still speaks but Mapper adds no haptics during capture (the session plays its own).
    let announcer: GuidanceAnnouncer
    /// The live session (for `ObjectCaptureView`); nil before `start` and after completion.
    private(set) var session: ObjectCaptureSession?
    /// Main. Called once after sealing.
    var onComplete: ((ObjectScanResult) -> Void)?
    /// Main. Called once after a cancel or a discard (the InProgress folder is gone).
    var onEnded: (() -> Void)?
    /// UserDefaults suite of the quiet announcer.
    nonisolated static let quietGuidanceSuite = "mapper.objectCapture.guidance"
    /// Seconds a cancel waits for `.failed(.cancelled)` before discarding anyway.
    nonisolated static let cancelTimeoutSeconds: Double = 5

    /// The update Tasks (ObjectScanModel+Session.swift adds them; `teardown` cancels them).
    var updateTasks: [Task<Void, Never>] = []
    /// Capture diagnostics for `objectlog.json` (ObjectScanModel+Session.swift).
    var diagnostics = ObjectScanDiagnostics()
    /// The scan's InProgress folder, once created.
    private(set) var folder: RawScanFolder?
    /// The folder's only writer (objectlog.json), closed before sealing or discarding.
    private var writer: RawScanWriter?
    /// Holds the `ObjectCaptureActivity` capture count while a session exists.
    private let sessionToken = ObjectCaptureSessionToken()
    /// True once `.objectNotFlippable` was reported.
    private var sawNotFlippable = false
    /// Open overlays (sheets, alerts, background) that asked for a pause.
    private var overlayPauses = 0
    /// True while the session is paused by `pauseForOverlay`.
    private var pausedByOverlay = false
    /// True while the review sheet holds one overlay pause.
    private var reviewHoldsPause = false
    /// True after the user confirmed Discard while a session was live.
    private var cancelRequested = false
    /// True once the discard sequence started.
    private var discardStarted = false
    /// True while the log is written and the folder sealed.
    private var finalizing = false

    /// A model for one scan; nothing starts until `start()`.
    init(target: ObjectScanTarget) {
        self.target = target
        announcer = GuidanceAnnouncer(defaults: ObjectScanModel.quietGuidanceDefaults())
    }

    // MARK: Start

    /// Main. `ObjectCapturePreflight.run()` (throws `.unsupportedDevice`, `.lowStorage(freeBytes:)`
    /// or `.deviceTooHot` for its three blocking issues), `InProgressScans.create` with
    /// `InProgressScanInfo(scanID: objectID, projectID:, sessionID: nil, roomID: objectID, kind: .object,
    /// mode: .object, startedAt:)`, `ObjectScanFolders.prepare`, then `ObjectCaptureSession()`
    /// (`ObjectCaptureActivity.captureStarted()`) and `start(imagesDirectory:configuration:)` with
    /// `checkpointDirectory` set and `isOverCaptureEnabled = false`. Logs the limits. Throws
    /// before creating a session when a check fails (also `MapperError.objectCaptureFailed` while
    /// a reconstruction is still counted) and removes the folder it made. A second call is ignored.
    func start() throws {
        guard phase == .idle, session == nil, folder == nil else {
            ObjectCaptureSignals.log("object \(target.objectID): start ignored in phase \(phase)")
            return
        }
        let report = ObjectCapturePreflight.run()
        if let issue = report.blocking, let error = ObjectCaptureSignals.startError(for: issue) {
            throw error
        }
        guard ObjectCaptureActivity.reconstructionSessions == 0 else {
            ObjectCaptureSignals.log("object \(target.objectID): start refused, a reconstruction is still counted")
            throw MapperError.objectCaptureFailed("a reconstruction is still running")
        }
        let paths = try ObjectScanModel.makeScanFolder(for: target)
        folder = paths.folder
        writer = RawScanWriter(folder: paths.folder)
        beginDiagnostics()
        let newSession = ObjectCaptureSession()
        sessionToken.acquire()
        session = newSession
        attachListeners(to: newSession)
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = paths.checkpoint
        configuration.isOverCaptureEnabled = false
        newSession.start(imagesDirectory: paths.images, configuration: configuration)
        shotLimit = newSession.maximumNumberOfInputImages
        diagnostics.maximumNumberOfInputImages = shotLimit
        phase = .capturing
        handleState(newSession.state)
        handleTracking(newSession.cameraTracking)
        handlePaused(newSession.isPaused)
        logStart(newSession)
    }

    // MARK: Controls

    /// `.ready`: `startDetecting()`; a false result sets `detectionFailed` and counts a failure.
    func continueTapped() {
        guard let session, stage == .ready else { return }
        let found = session.startDetecting()
        detectionFailed = !found
        if !found {
            diagnostics.detectionFailures += 1
            ObjectCaptureSignals.log("object \(target.objectID): startDetecting found no object (\(diagnostics.detectionFailures))")
        }
    }

    /// `.detecting`: `resetDetection()` (back to `.ready`).
    func resetBox() {
        guard let session, stage == .detecting else { return }
        session.resetDetection()
    }

    /// `.detecting`: `startCapturing()`.
    func startCapture() {
        guard let session, stage == .detecting else { return }
        session.startCapturing()
        ObjectCaptureSignals.log("object \(target.objectID): capturing, lap \(ObjectOnboarding.pass(of: onboarding))")
    }

    /// Review choices and Done go through `ObjectOnboarding.next` and run its command
    /// (`beginNewScanPass`, `beginNewScanPassAfterFlip` or `finish`). The review closes (and the
    /// session resumes) before a new lap starts.
    func choose(_ event: ObjectOnboardingEvent) {
        let step = ObjectOnboarding.next(onboarding, event)
        if step.state != onboarding {
            ObjectCaptureSignals.log("object \(target.objectID): onboarding \(onboarding) -> \(step.state) on \(event)")
            onboarding = step.state
        }
        switch step.command {
        case .none:
            break
        case .beginNewScanPass:
            reviewDismissed()
            guard let session, stage == .capturing else { return }
            session.beginNewScanPass()
        case .beginNewScanPassAfterFlip:
            reviewDismissed()
            detectionFailed = false
            guard let session, stage == .capturing else { return }
            session.beginNewScanPassAfterFlip()
            diagnostics.flips += 1
        case .finish:
            finish()
        }
    }

    /// Done button: `finish()` when `.capturing` and `canFinish(shots:)`, else `showsTooFewPhotos`.
    func finish() {
        guard let session, stage == .capturing else {
            ObjectCaptureSignals.log("object \(target.objectID): finish ignored in stage \(stage.rawValue)")
            return
        }
        let shots = session.numberOfShotsTaken
        if shots != shotCount { shotCount = shots }
        guard ObjectOnboarding.canFinish(shots: shots) else {
            showsTooFewPhotos = true
            ObjectCaptureSignals.log("object \(target.objectID): Done with only \(shots) photos")
            return
        }
        reviewDismissed()
        session.finish()
        phase = .finishing
        ObjectCaptureSignals.log("object \(target.objectID): finishing with \(shots) photos")
    }

    /// `pause()` for sheets, alerts and scene phase changes (RESEARCH 3.3 gotcha 5). Counted:
    /// the session pauses on the first open overlay.
    func pauseForOverlay() {
        overlayPauses += 1
        guard overlayPauses == 1, !pausedByOverlay, let session, ObjectScanModel.canPause(stage) else { return }
        session.pause()
        pausedByOverlay = true
    }

    /// `resume()` when the last overlay that paused closes.
    func resumeFromOverlay() {
        guard overlayPauses > 0 else { return }
        overlayPauses -= 1
        guard overlayPauses == 0, pausedByOverlay else { return }
        pausedByOverlay = false
        session?.resume()
    }

    /// Opens the review sheet again (its button over the camera after the sheet was closed).
    func reopenReview() {
        guard ObjectOnboarding.isReview(onboarding) else { return }
        openReview()
    }

    /// The review sheet closed (a choice, a swipe or `onDismiss`); idempotent.
    func reviewDismissed() {
        if reviewPresented { reviewPresented = false }
        if phase == .reviewing { phase = .capturing }
        guard reviewHoldsPause else { return }
        reviewHoldsPause = false
        resumeFromOverlay()
    }

    /// The user confirmed Discard: `cancel()`, wait for `.failed(.cancelled)` (at most
    /// `cancelTimeoutSeconds`), release the session, close the writer,
    /// `InProgressScans.discard(scanID:)`, phase `.cancelled`, `onEnded`. Ignored while sealing.
    func cancel() {
        switch phase {
        case .sealing, .done, .cancelled:
            ObjectCaptureSignals.log("object \(target.objectID): cancel ignored in phase \(phase)")
            return
        case .idle, .capturing, .reviewing, .finishing, .failed:
            break
        }
        guard !cancelRequested, !discardStarted else { return }
        guard let session, stage != .completed, stage != .failed else {
            finishDiscard()
            return
        }
        cancelRequested = true
        if reviewPresented { reviewPresented = false }
        session.cancel()
        ObjectCaptureSignals.log("object \(target.objectID): cancel requested in stage \(stage.rawValue)")
        let nanoseconds = UInt64(ObjectScanModel.cancelTimeoutSeconds * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.cancelTimedOut()
        }
    }

    /// After `.failed` with enough images: seal what exists (same path as completion).
    func useCapturedPhotos() {
        guard case .failed(let failure, let count) = phase, count >= ObjectScanFolders.minimumImages else { return }
        finalizeCapture(failure: failure)
    }

    /// After `.failed`: discard as `cancel()` does.
    func discardAfterFailure() {
        guard case .failed = phase else { return }
        finishDiscard()
    }

    /// Idempotent: cancels the update tasks, releases the session (`ObjectCaptureActivity.captureReleased()`
    /// once). Called on every terminal phase.
    func teardown() {
        for task in updateTasks { task.cancel() }
        updateTasks.removeAll()
        announcer.reset()
        guard session != nil else { return }
        objectWillChange.send()
        session = nil
        overlayPauses = 0
        pausedByOverlay = false
        reviewHoldsPause = false
        sessionToken.release()
        ObjectCaptureSignals.log("object \(target.objectID): object session released")
    }

    // MARK: Session updates (called by the update Tasks)

    /// A new capture state: stage, the finishing phase, completion and failure.
    func handleState(_ state: ObjectCaptureSession.CaptureState) {
        let mapped = ObjectCaptureSignals.stage(state)
        if mapped != stage {
            ObjectCaptureSignals.log("object \(target.objectID): stage \(stage.rawValue) -> \(mapped.rawValue)")
            stage = mapped
        }
        if case .failed(let error) = state {
            handleFailure(error)
            return
        }
        switch mapped {
        case .detecting:
            if detectionFailed { detectionFailed = false }
        case .finishing:
            if phase == .capturing || phase == .reviewing { phase = .finishing }
        case .completed:
            handleCompleted()
        case .initializing, .ready, .capturing, .failed:
            break
        }
    }

    /// A new feedback set: log times, the red counter, the flip advice and the guidance banner.
    func handleFeedback(_ feedback: Set<ObjectCaptureSession.Feedback>) {
        let now = ObjectScanModel.uptime()
        var names = Set<String>()
        for item in feedback { names.insert(ObjectCaptureSignals.name(of: item)) }
        diagnostics.noteFeedback(names, now: now)
        let over = ObjectCaptureSignals.containsOverCapturing(feedback)
        if over != overCapturing { overCapturing = over }
        if ObjectCaptureSignals.containsNotFlippable(feedback) && !sawNotFlippable {
            sawNotFlippable = true
            flipRecommended = ObjectOnboarding.flipRecommended(sawNotFlippable: true)
            ObjectCaptureSignals.log("object \(target.objectID): object may not be flippable")
        }
        announcer.present(GuidanceSignals.guidance(for: feedback), now: now)
    }

    /// A new tracking state: hides Mapper's controls while Apple's coaching shows.
    func handleTracking(_ tracking: ObjectCaptureSession.Tracking) {
        let normal = ObjectCaptureSignals.isNormal(tracking)
        diagnostics.noteTracking(normal: normal, now: ObjectScanModel.uptime())
        if normal != trackingNormal { trackingNormal = normal }
    }

    /// `userCompletedScanPass` changed: a finished lap moves onboarding to its review.
    func handlePassCompleted(_ completed: Bool) {
        guard completed, stage == .capturing else { return }
        let step = ObjectOnboarding.next(onboarding, .passCompleted)
        guard step.state != onboarding else { return }
        ObjectCaptureSignals.log("object \(target.objectID): lap \(ObjectOnboarding.pass(of: onboarding)) done, \(shotCount) photos")
        onboarding = step.state
        openReview()
    }

    /// `numberOfShotsTaken` changed.
    func handleShots(_ count: Int) {
        if count != shotCount { shotCount = count }
    }

    /// `isPaused` changed.
    func handlePaused(_ paused: Bool) {
        if paused != isPaused { isPaused = paused }
    }

    // MARK: Private

    /// Shows the review sheet and holds one overlay pause for it.
    private func openReview() {
        guard session != nil, !reviewPresented else { return }
        reviewPresented = true
        if phase == .capturing { phase = .reviewing }
        guard !reviewHoldsPause else { return }
        reviewHoldsPause = true
        pauseForOverlay()
    }

    /// `.failed(error)`: the user's own cancel continues the discard; anything else releases the
    /// session and shows the failure with the photo count.
    private func handleFailure(_ error: any Error) {
        let failure = ObjectCaptureSignals.failure(error)
        if cancelRequested {
            ObjectCaptureSignals.log("object \(target.objectID): session ended after cancel (\(failure))")
            finishDiscard()
            return
        }
        if case .failed = phase { return }
        guard !finalizing, !discardStarted else { return }
        if reviewPresented { reviewPresented = false }
        teardown()
        let count = currentImageCount()
        phase = .failed(failure, imageCount: count)
        ObjectCaptureSignals.log("object \(target.objectID): session failed (\(failure)) with \(count) photos")
    }

    /// `.completed`: the session and its tasks are released first (RESEARCH 3.3 gotcha 10), then
    /// the log is written and the folder sealed. A cancel that raced the completion discards.
    private func handleCompleted() {
        if cancelRequested {
            finishDiscard()
            return
        }
        guard !finalizing, !discardStarted else { return }
        if let session {
            let shots = session.numberOfShotsTaken
            if shots != shotCount { shotCount = shots }
        }
        if reviewPresented { reviewPresented = false }
        teardown()
        finalizeCapture(failure: nil)
    }

    /// Writes `objectlog.json`, flushes and closes the writer, seals off main, then `.done` and
    /// `onComplete`; a failure shows `.failed(.other)` and keeps the folder for recovery.
    private func finalizeCapture(failure: ObjectScanFailure?) {
        guard !finalizing, !discardStarted, let folder, let writer else { return }
        finalizing = true
        phase = .sealing
        let captureLog = diagnostics.makeLog(objectID: target.objectID, shots: shotCount,
                                             passes: ObjectOnboarding.pass(of: onboarding), finalStage: stage.rawValue,
                                             failure: failure.map { "\($0)" },
                                             thermalAtEnd: ProcessInfo.processInfo.thermalState,
                                             osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                             uptime: ObjectScanModel.uptime())
        let target = self.target
        Task { [weak self] in
            do {
                let result = try await ObjectScanModel.writeLogAndSeal(captureLog, folder: folder, writer: writer, target: target)
                self?.sealSucceeded(result)
            } catch {
                self?.sealFailed(error)
            }
        }
    }

    /// The folder is sealed: `.done(result)` and `onComplete` once.
    private func sealSucceeded(_ result: ObjectScanResult) {
        phase = .done(result)
        ObjectCaptureSignals.log("object \(target.objectID): saved \(result.imageCount) photos")
        let callback = onComplete
        onComplete = nil
        callback?(result)
    }

    /// Sealing failed: the folder stays in InProgress; Use These Photos retries.
    private func sealFailed(_ error: any Error) {
        finalizing = false
        let detail = StoreFiles.describe(error)
        ObjectCaptureSignals.log("object \(target.objectID): sealing failed (\(detail))")
        phase = .failed(.other(detail), imageCount: currentImageCount())
    }

    /// The cancel did not end the session in time: discard anyway (logged).
    private func cancelTimedOut() {
        guard !discardStarted else { return }
        ObjectCaptureSignals.log("object \(target.objectID): no failed state \(ObjectScanModel.cancelTimeoutSeconds) s after cancel")
        finishDiscard()
    }

    /// Releases the session, closes the writer, removes the InProgress folder, then `.cancelled`
    /// and `onEnded` once.
    private func finishDiscard() {
        guard !discardStarted else { return }
        discardStarted = true
        if reviewPresented { reviewPresented = false }
        teardown()
        let scanID = target.objectID
        let writer = self.writer
        Task { [weak self] in
            await ObjectScanModel.discardFolder(scanID: scanID, writer: writer)
            self?.discardFinished()
        }
    }

    /// The folder is gone: `.cancelled` and `onEnded` once.
    private func discardFinished() {
        phase = .cancelled
        ObjectCaptureSignals.log("object \(target.objectID): scan discarded")
        let callback = onEnded
        onEnded = nil
        callback?()
    }
}
