import Foundation
import UIKit

// User actions of the live capture (docs/MODULES.md 3.41): Done, Resume, Finish Now, Take Photo,
// Cancel with its confirmation, Open Settings, the Show Missing Areas hand-off to AppShell and
// its return (`refreshEvaluation`), and the alerts of the flow. Main actor (extension of the model).

extension HouseFlowModel {
    // MARK: - Scanning controls

    /// Done button: finish the room (the engine saves it), then the quality check.
    func done() {
        guard phase == .capturing else { return }
        showsTimeLimitCard = false
        showsTimeHint = false
        showsNextRoomHint = false
        showsCancelConfirmation = false
        leftScreenWhileScanning = false
        if HouseFlowModel.isPauseAlert(alert) { alert = nil }
        apply(.doneTapped)
        roomEndedAt = ProcessInfo.processInfo.systemUptime
        announcer.reset()
        let parts = ScanFlowModel.elapsedParts(snapshot.elapsed)
        log("done: finishing room \(currentRoomID?.uuidString ?? "-"), \(snapshot.wallCount) walls, "
            + "\(parts.minutes) min \(parts.seconds) s")
        engine?.finish()
    }

    /// Resume while paused (after an interruption the engine waits for this).
    func resume() {
        guard phase == .capturing, isPaused else { return }
        if HouseFlowModel.isPauseAlert(alert) { alert = nil }
        log("resume tapped")
        engine?.resume()
    }

    /// Finish Now while paused or from an alert: same as `done()`.
    func finishNow() {
        done()
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

    // MARK: - Cancel

    /// Cancel button. Before a capture there is nothing to lose; while relocalizing the new
    /// session is dropped; while scanning or saving the confirmation asks first.
    func requestCancel() {
        switch phase {
        case .preflight, .permission, .tips:
            cancelBeforeCapture()
        case .relocalizing:
            cancelRelocalization()
        case .capturing, .stopping:
            guard !isDiscarding else { return }
            showsCancelConfirmation = true
        case .checking, .quality, .naming, .roomList, .finishing, .done, .failed, .cancelled:
            break
        }
    }

    /// Discard Scan in the Cancel confirmation: `engine.discard()` (only this room's InProgress
    /// data), then the room list, or the end of the flow when the house has no room.
    func confirmCancel() {
        showsCancelConfirmation = false
        markPresentationClosed()
        guard !isDiscarding, phase == .capturing || phase == .stopping else { return }
        beginDiscard()
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

    // MARK: - Missing areas tour (AppShell 5d)

    /// Show Missing Areas on the quality sheet: hides the sheet, then calls `onShowMissingAreas`.
    func showMissingAreas() {
        guard phase == .quality, canShowMissingAreas, let action = onShowMissingAreas else { return }
        setTourActive(true)
        log("missing areas tour for room \(finishedRoomID?.uuidString ?? "-")")
        action()
    }

    /// AppShell calls this when the missing-areas tour ends: a nil evaluation (tour cancelled, or the
    /// evaluation failed) keeps the current one; `stoppedBySystem` (the tour's
    /// `MissingAreasModel.stoppedBySystem`) hides Show Missing Areas for the rest of this room; a
    /// non-nil evaluation also re-applies `HouseManifestRules.status(after:)` to the room's record
    /// (a room the tour fixed leaves `.needsRescan`); clears `isTourActive`, so the quality sheet
    /// shows again with the numbers.
    func refreshEvaluation(_ evaluation: QualityEvaluation?, stoppedBySystem: Bool) {
        if stoppedBySystem {
            tourStoppedBySystem = true
            needsNewSession = true
        }
        if let updated = evaluation, updated.roomID == finishedRoomID {
            setEvaluation(updated)
            applyStatus(after: updated, room: updated.roomID)
        }
        log("missing areas tour ended: evaluation \(evaluation == nil ? "kept" : "updated"), system stop \(stoppedBySystem)")
        setTourActive(false)
    }

    // MARK: - Alerts

    /// Shows an alert (replacing any other; an `.endFlow` follow-up is never dropped) and logs
    /// it. A notice over a sheet is also announced to VoiceOver.
    func present(_ newAlert: HouseAlert, followUp: HouseAlertFollowUp) {
        showsCancelConfirmation = false
        let keepsEnd = alertFollowUp == .endFlow || followUp == .endFlow
        alertFollowUp = keepsEnd ? .endFlow : followUp
        alert = newAlert
        log("alert \(newAlert.id)")
        if presentedSheet != nil {
            UIAccessibility.post(notification: .announcement, argument: newAlert.title + "\n" + newAlert.body)
        }
    }

    /// An alert button was tapped: closes the alert, runs the action, then the follow-up.
    func alertAction(_ action: HouseAlertAction) {
        let followUp = alertFollowUp
        alert = nil
        alertFollowUp = .stay
        markPresentationClosed()
        log("alert action \(action)")
        switch action {
        case .ok, .cancel, .lineUp, .rescan, .joinAgain:
            break
        case .openSettings:
            openSettings()
        case .resume:
            resume()
        case .finishNow:
            finishNow()
        case .startFresh:
            startFresh()
        case .keepLooking:
            keepLooking()
        }
        guard followUp != .stay else { return }
        let delay = UInt64(presentationGapRemaining() * 1_000_000_000)
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            self?.runFollowUp(followUp)
        }
    }

    /// Runs a follow-up now.
    func runFollowUp(_ followUp: HouseAlertFollowUp) {
        switch followUp {
        case .stay: break
        case .continueChecks: continueChecks()
        case .endFlow: endFlow()
        }
    }

    /// True for the alerts that only make sense while paused (they close when the scan runs again).
    static func isPauseAlert(_ candidate: HouseAlert?) -> Bool {
        guard let id = candidate?.id else { return false }
        return id == ScanErrorCopy.pausedPromptID || id == ScanErrorCopy.interruptedID
    }
}
