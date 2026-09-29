import Foundation
import Combine
import UIKit
import AVFoundation

/// The scan flow facade over any `ScanEngine` (D1, docs/MODULES.md 3.24, ARCHITECTURE 10.3):
/// preflight, camera permission, tips, project creation, the live scan, Done, the quality
/// check, Finish, Cancel and Discard, interruptions and time hints, and Demo Mode.
///
/// Ownership: the model is the only owner of the engine and its recorders. Engine events
/// arrive on main (`ScanEngine.onEvent`) and are handled here. The quality sheet is never
/// shown by this module: AppShell presents QualityUI over `RoomScanScreen` while `phase` is
/// `.checking` or `.quality`, calling `finish()` or `discardScan()`. Processing is never
/// enqueued here: AppShell does that in `onComplete`.
///
/// Files: this file holds the state and the user actions; `ScanFlowModel+Room.swift` the
/// engine, the saved room, the quality check and the cleanup; `ScanFlowModel+Presentation.swift`
/// alerts, timers and small screen helpers; `ScanFlowReducer.swift` the pure phase reducer.
@MainActor final class ScanFlowModel: ObservableObject {
    // MARK: Published state (contract, docs/MODULES.md 3.24)

    /// Where the flow is (only `apply(_:)` changes it, through `nextPhase(_:on:)`).
    @Published private(set) var phase: ScanFlowPhase = .preflight
    /// The latest live snapshot of the engine.
    @Published private(set) var snapshot = LiveScanSnapshot()
    /// The quality evaluation of the saved room (nil while checking).
    @Published private(set) var evaluation: QualityEvaluation?
    /// The preflight result, once the checks ran.
    @Published private(set) var preflight: PreflightReport?
    /// Engine `.paused`: the chrome shows Resume and Finish Now.
    @Published private(set) var isPaused = false
    /// The alert to show (a system alert while scanning, a notice card over the quality sheet).
    @Published var alert: ScanAlert?
    /// The Cancel confirmation ("Stop this scan?") is showing.
    @Published var showsCancelConfirmation = false
    /// The 5 minute time limit card is showing.
    @Published var showsTimeLimitSheet = false

    // MARK: Published extras for the scan screen (written by the model only)

    /// The engine's lifecycle state (the chrome shows "Getting ready" while `.starting`).
    @Published var engineState: ScanEngineState = .idle
    /// The tips page is showing (phase `.tips` and the tips of the mode were not seen).
    @Published var showsTips = false
    /// The camera prompt is up (Continue disabled).
    @Published var isRequestingPermission = false
    /// The 4 minute hint is showing.
    @Published var showsTimeHint = false
    /// "Photo saved to this spot" is showing.
    @Published var showsPhotoNote = false
    /// A confirmed discard is waiting for the engine to stop and delete the scan.
    @Published var isDiscarding = false
    /// True once the room was saved (sealed): alerts from then on are notices over the sheet.
    @Published var roomSaved = false

    // MARK: Configuration and results

    /// What is being scanned.
    let mode: ScanMode
    /// Demo Mode: `FakeScanEngine`, no camera, no ARKit.
    let isDemo: Bool
    /// The project created for this scan, once created.
    private(set) var projectID: UUID?
    /// The live room engine (nil in Demo Mode); RoomScanScreen hosts its view.
    private(set) var roomEngine: RoomScanEngine?
    /// Called once after Finish with the project id (AppShell enqueues processing and opens Results).
    var onComplete: ((UUID) -> Void)?
    /// Called when the flow ends without a project (cancel, discard, blocking preflight).
    var onDismiss: (() -> Void)?
    /// Live guidance: banner kind, VoiceOver announcements and warning haptics.
    let announcer: GuidanceAnnouncer

    // MARK: Internal state (used by the extensions in the other ScanFlowModel files)

    /// The engine being driven (the room engine, or the fake engine in Demo Mode).
    var engine: ScanEngine?
    /// The Take Photo recorder of the room engine.
    var photoRecorder: PhotoRecorder?
    /// Optional Diagnostics recorder of every snapshot.
    var snapshotRecorder: SnapshotRecorder?
    /// Package, ARKit session and room of the capture.
    var projectPackage: ProjectPackage?, sessionID: UUID?, roomID: UUID?
    /// The room the engine saved, and whether its RoomRecord is in the manifest.
    var finishedRoomID: UUID?, roomRecorded = false
    /// The RoomRecord of the saved room (the quality check reads its folder).
    var savedRecord: RoomRecord?
    /// `begin()` ran; the flow ended through `endFlow` or `finish`.
    var hasBegun = false, hasEnded = false
    /// Preflight warnings still to show before the capture starts.
    var pendingWarnings: [PreflightIssue] = []
    /// What closing the current alert does next.
    var alertFollowUp: ScanAlertFollowUp = .stay
    /// Uptime when the last alert or dialog closed (the quality sheet waits a moment after it).
    var lastPresentationClosed: TimeInterval = -1_000
    /// Idle timer hold while the scan screen is visible.
    var idleToken: UUID?
    /// The 1 Hz ticker (paused prompt, hint timeout) and other short tasks.
    var ticker: Task<Void, Never>?, photoNoteTask: Task<Void, Never>?, discardTimeout: Task<Void, Never>?
    /// Uptime when the engine paused, and whether this pause already prompted.
    var pausedSince: TimeInterval?, pausedPrompted = false
    /// Timed cues already shown, and when the hint hides.
    var timeHintShown = false, timeLimitShown = false, timeHintHideAt: TimeInterval?
    /// First `.scanning` state seen (start haptic), and a discard waiting for `.idle`.
    var hasStartedScanning = false, awaitingDiscardIdle = false
    /// Mapper went to the background while scanning (the interrupted alert shows on return).
    var leftScreenWhileScanning = false

    /// Creates a flow for `mode`; nothing runs until `begin()`.
    init(mode: ScanMode, isDemo: Bool) {
        self.mode = mode
        self.isDemo = isDemo
        announcer = GuidanceAnnouncer()
    }

    // MARK: - Flow start

    /// Preflight, then permission, tips or capture. Idempotent (RoomScanScreen also calls it
    /// when it appears).
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        log("scan flow begin, mode \(mode.rawValue), demo \(isDemo)")
        Task { [weak self] in
            guard let self else { return }
            let report = await ScanPreflight.run(mode: self.mode, isDemo: self.isDemo)
            self.preflightFinished(report)
        }
    }

    /// Applies the preflight result: a blocking issue ends the flow after its alert, an
    /// undetermined camera goes to the permission screen, otherwise the warnings and tips.
    func preflightFinished(_ report: PreflightReport) {
        guard phase == .preflight else { return }
        preflight = report
        pendingWarnings = report.warnings
        guard let blocking = report.blocking else {
            apply(.preflightPassed)
            continueToCapture()
            return
        }
        switch blocking {
        case .cameraUndetermined:
            apply(.permissionNeeded)
        case .cameraDenied:
            apply(.permissionDenied)
            present(ScanErrorCopy.preflightAlert(for: blocking), followUp: .endFlow)
        case .noLidar, .lowStorage, .storageWarning, .lowBattery, .deviceHot:
            apply(.preflightBlocked)
            present(ScanErrorCopy.preflightAlert(for: blocking), followUp: .endFlow)
        }
    }

    /// Phase `.tips`: shows the next preflight warning (closing it comes back here), then the
    /// tips page, or starts the capture at once when the tips of the mode were seen.
    func continueToCapture() {
        guard phase == .tips, !hasEnded else { return }
        if !pendingWarnings.isEmpty {
            let warning = pendingWarnings.removeFirst()
            present(ScanErrorCopy.preflightAlert(for: warning), followUp: .continueToCapture)
            return
        }
        if ScanUISettings.tipsSeen(mode) {
            startCapture()
        } else {
            showsTips = true
        }
    }

    /// Continue on the pre-permission screen: asks iOS for the camera
    /// (`AVCaptureDevice.requestAccess(for: .video)`, not in RESEARCH), then continues or shows
    /// the denied alert with Open Settings.
    func permissionContinue() async {
        guard phase == .permission, !isRequestingPermission else { return }
        isRequestingPermission = true
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        isRequestingPermission = false
        guard phase == .permission else { return }
        if granted {
            log("camera permission granted")
            apply(.permissionGranted)
            continueToCapture()
        } else {
            log("camera permission denied")
            apply(.permissionDenied)
            present(ScanErrorCopy.alert(for: MapperError.cameraDenied), followUp: .endFlow)
        }
    }

    /// Start Scan or Skip on the tips page; `dontShowAgain` marks the mode's tips as seen.
    func tipsFinished(dontShowAgain: Bool) {
        guard phase == .tips, !hasEnded else { return }
        if dontShowAgain { ScanUISettings.markTipsSeen(mode) }
        showsTips = false
        startCapture()
    }

    // MARK: - Scanning controls

    /// Done button: finish the room (the engine saves it), then the quality check.
    func done() {
        guard phase == .capturing else { return }
        showsTimeLimitSheet = false
        showsTimeHint = false
        showsCancelConfirmation = false
        leftScreenWhileScanning = false
        if ScanErrorCopy.isPauseAlert(alert) { alert = nil }
        apply(.doneTapped)
        announcer.reset()
        let seconds = ScanFlowModel.elapsedParts(snapshot.elapsed)
        log("done: finishing the room, \(snapshot.wallCount) walls, \(seconds.minutes) min \(seconds.seconds) s")
        engine?.finish()
    }

    /// Resume while paused (after an interruption the engine waits for this).
    func resume() {
        guard phase == .capturing, isPaused else { return }
        if ScanErrorCopy.isPauseAlert(alert) { alert = nil }
        log("resume tapped")
        engine?.resume()
    }

    /// Finish Now while paused or from an alert: same as `done()`.
    func finishNow() {
        done()
    }

    /// Finish or Finish Anyway on the quality sheet: releases the engine, ends the flow with
    /// the project (`onComplete`).
    func finish() {
        guard phase == .quality || phase == .checking, let id = projectID else { return }
        apply(.finishTapped)
        if !roomRecorded, let room = finishedRoomID { recordFinishedRoom(room) }
        alert = nil
        stopTimers()
        teardownEngine()
        snapshotRecorder?.close()
        releaseIdleToken()
        announcer.reset()
        apply(.completed(id))
        hasEnded = true
        log("finish: project \(id) handed over")
        onComplete?(id)
    }

    /// Discard on the quality sheet, after its confirmation: removes only the scan just saved
    /// (`ProjectLibrary.discardRoom`, which deletes the project when no room is left), then
    /// `onDismiss`.
    func discardScan() {
        guard phase == .quality || phase == .checking else { return }
        apply(.discarded)
        discardSavedRoom()
    }

    /// Cancel button. Before the capture there is nothing to lose, so the flow ends at once;
    /// while scanning or saving the confirmation asks first.
    func requestCancel() {
        switch phase {
        case .preflight, .permission, .tips:
            log("cancelled before the capture")
            apply(.cancelConfirmed)
            endFlow()
        case .capturing, .stopping:
            guard !isDiscarding else { return }
            showsCancelConfirmation = true
        case .checking, .quality, .finishing, .done, .failed, .cancelled:
            break
        }
    }

    /// Discard Scan in the Cancel confirmation: the engine stops, deletes the scan and reports
    /// `.stateChanged(.idle)`; then the empty project is deleted and the flow ends.
    func confirmCancel() {
        showsCancelConfirmation = false
        markPresentationClosed()
        guard !isDiscarding else { return }
        let savedWhileAsking = finishedRoomID != nil && (ScanFlowModel.isBeforeRoomSaved(phase) || phase == .checking
                                                         || phase == .quality)
        if savedWhileAsking {
            // The room was saved while the dialog was up: discard it like the sheet does.
            apply(ScanFlowModel.isBeforeRoomSaved(phase) ? .cancelConfirmed : .discarded)
            discardSavedRoom()
            return
        }
        switch phase {
        case .capturing, .stopping:
            apply(.cancelConfirmed)
            beginDiscard()
        case .preflight, .permission, .tips:
            requestCancel()
        case .checking, .quality:
            discardScan()
        case .finishing, .done, .failed, .cancelled:
            break
        }
    }

    /// Keep Scanning in the Cancel confirmation.
    func keepScanning() {
        showsCancelConfirmation = false
        markPresentationClosed()
    }

    /// Opens Mapper's page in Settings (`UIApplication.openSettingsURLString`, not in RESEARCH).
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        log("opening Settings")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Take Photo: the next frame with normal tracking is saved as a photo pinned to this spot.
    func takePhoto() {
        guard phase == .capturing, !isPaused else { return }
        Haptics.selection()
        if isDemo {
            showPhotoNote()
        } else if let recorder = photoRecorder {
            recorder.requestPhoto()
        }
    }

    // MARK: - State writers (the only places that change the contract's read-only state)

    /// Moves the phase through the pure reducer and logs real changes.
    func apply(_ signal: ScanFlowSignal) {
        let next = ScanFlowModel.nextPhase(phase, on: signal)
        guard next != phase else { return }
        log("phase \(phase) -> \(next)")
        phase = next
    }

    /// Stores the project, the engine and its recorders of a capture that is about to start.
    func adopt(projectID id: UUID, package: ProjectPackage, sessionID session: UUID, roomID room: UUID,
               parts: ScanEngineParts) {
        projectID = id
        projectPackage = package
        sessionID = session
        roomID = room
        engine = parts.engine
        roomEngine = parts.roomEngine
        photoRecorder = parts.photoRecorder
    }

    /// A new live snapshot: published while scanning or saving, recorded, fed to the guidance
    /// announcer (nothing while paused) and checked for the timed cues.
    func received(snapshot newSnapshot: LiveScanSnapshot) {
        guard phase == .capturing || phase == .stopping else { return }
        snapshot = newSnapshot
        snapshotRecorder?.record(newSnapshot)
        let guidance: GuidanceKind? = phase == .capturing && !isPaused ? newSnapshot.guidance : nil
        announcer.present(guidance, now: newSnapshot.timestamp)
        checkTimeCues(elapsed: newSnapshot.elapsed)
    }

    /// The engine's lifecycle state changed.
    func engineStateChanged(_ state: ScanEngineState) {
        engineState = state
        switch state {
        case .scanning:
            if isPaused {
                isPaused = false
                pausedSince = nil
                log("scanning again after a pause")
            }
            leftScreenWhileScanning = false
            if ScanErrorCopy.isPauseAlert(alert) { alert = nil }
            if !hasStartedScanning {
                hasStartedScanning = true
                Haptics.selection()
                log("scanning")
            }
        case .paused:
            guard !isPaused else { return }
            isPaused = true
            pausedSince = ProcessInfo.processInfo.systemUptime
            pausedPrompted = false
            announcer.present(nil, now: snapshot.timestamp)
            log("engine paused")
            if leftScreenWhileScanning && UIApplication.shared.applicationState == .active { appDidBecomeActive() }
        case .stopping:
            isPaused = false
            if phase == .capturing {
                log("the engine is finishing the room by itself")
                showsTimeLimitSheet = false
                showsTimeHint = false
                apply(.engineStopping)
            }
        case .idle:
            if awaitingDiscardIdle { completeDiscard() }
        case .starting, .finished, .failed:
            break
        }
    }

    /// The quality check finished (or its fallback): shows the evaluation on the sheet.
    func evaluationReady(_ result: QualityEvaluation) {
        guard phase == .checking else { return }
        evaluation = result
        apply(.evaluated)
    }
}
