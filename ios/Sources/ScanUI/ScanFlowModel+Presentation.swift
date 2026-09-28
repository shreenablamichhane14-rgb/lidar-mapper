import Foundation
import UIKit

// Alerts, timed cues and small screen helpers of ScanFlowModel (docs/MODULES.md 3.24): what an
// alert button does, the 1 Hz ticker (paused prompt, hint timeout), the 4 and 5 minute cues,
// the "Photo saved" note, the idle timer hold, Demo Mode backgrounding, the default project
// name and the log helper. Main actor (extension of the model) unless marked nonisolated.

/// What closing the current alert does next.
enum ScanAlertFollowUp: Equatable, Sendable {
    /// Nothing more.
    case stay
    /// Show the next preflight warning, then the tips or the capture.
    case continueToCapture
    /// End the flow (`onDismiss`).
    case endFlow
}

extension ScanFlowModel {
    // MARK: - Alerts

    /// True when alerts show as a notice card over the quality sheet instead of a system alert
    /// (the room was saved, so AppShell's sheet is up or about to be).
    var showsAlertAsNotice: Bool {
        roomSaved || phase.isSheetPhase
    }

    /// True when `alert` should be presented as a system alert now.
    var showsSystemAlert: Bool {
        alert != nil && !showsAlertAsNotice
    }

    /// Binding target of the system alert (`$model.systemAlertPresented`): reads
    /// `showsSystemAlert`; writes are ignored, because every alert closes through its buttons
    /// (`alertAction`), which clear `alert`.
    var systemAlertPresented: Bool {
        get { showsSystemAlert }
        set { _ = newValue }
    }

    /// Shows an alert (replacing any other; an `.endFlow` follow-up is never dropped) and logs
    /// it. A notice over the sheet is also announced to VoiceOver.
    func present(_ newAlert: ScanAlert, followUp: ScanAlertFollowUp) {
        showsCancelConfirmation = false
        let keepsEnd = alertFollowUp == .endFlow || followUp == .endFlow
        alertFollowUp = keepsEnd ? .endFlow : followUp
        alert = newAlert
        log("alert \(newAlert.id)")
        if showsAlertAsNotice {
            UIAccessibility.post(notification: .announcement, argument: newAlert.title + "\n" + newAlert.body)
        }
    }

    /// An alert button was tapped: closes the alert, runs the action, then the follow-up.
    func alertAction(_ action: ScanAlertAction) {
        let followUp = alertFollowUp
        alert = nil
        alertFollowUp = .stay
        markPresentationClosed()
        log("alert action \(action)")
        switch action {
        case .ok:
            break
        case .openSettings:
            openSettings()
        case .finishNow:
            finishNow()
        case .resume:
            resume()
        }
        if followUp != .stay {
            afterPresentationGap(followUp)
        }
    }

    /// Runs a follow-up once the alert that just closed has finished animating out, so the next
    /// alert, the capture or the cover's dismissal never overlaps it.
    func afterPresentationGap(_ followUp: ScanAlertFollowUp) {
        let delay = UInt64(presentationGapRemaining() * 1_000_000_000)
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            self?.runFollowUp(followUp)
        }
    }

    /// Runs a follow-up now.
    func runFollowUp(_ followUp: ScanAlertFollowUp) {
        switch followUp {
        case .stay:
            break
        case .continueToCapture:
            continueToCapture()
        case .endFlow:
            endFlow()
        }
    }

    /// Remembers when an alert or dialog closed (the quality sheet waits a moment after it).
    func markPresentationClosed() {
        lastPresentationClosed = ProcessInfo.processInfo.systemUptime
    }

    /// Seconds still to wait before presenting the quality sheet after the last alert or
    /// dialog closed (0 when none closed recently).
    func presentationGapRemaining() -> Double {
        let since = ProcessInfo.processInfo.systemUptime - lastPresentationClosed
        return Swift.max(0, ScanFlowTiming.presentationGapSeconds - since)
    }

    // MARK: - Timed cues

    /// Starts the 1 Hz ticker of the capture.
    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let model = self else { return }
                model.tick()
            }
        }
    }

    /// Stops the ticker and hides the time hint.
    func stopTimers() {
        ticker?.cancel()
        ticker = nil
        showsTimeHint = false
        timeHintHideAt = nil
    }

    /// One tick: hides the time hint after its time; after 30 seconds paused (with nothing
    /// else on screen) shows the Finish Now or Resume prompt once per pause.
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let hideAt = timeHintHideAt, now >= hideAt {
            showsTimeHint = false
            timeHintHideAt = nil
        }
        guard phase == .capturing, isPaused, let since = pausedSince else { return }
        guard alert == nil, !showsCancelConfirmation, !showsTimeLimitSheet else { return }
        guard ScanFlowModel.pausedPromptDue(pausedSeconds: now - since, alreadyPrompted: pausedPrompted) else { return }
        pausedPrompted = true
        Haptics.warning()
        present(ScanErrorCopy.pausedPrompt(), followUp: .stay)
    }

    /// Checks the 4 minute hint and the 5 minute limit against the scan time of a snapshot.
    func checkTimeCues(elapsed: Double) {
        guard phase == .capturing else { return }
        let cue = ScanFlowModel.timeCue(elapsed: elapsed, hintShown: timeHintShown, limitShown: timeLimitShown)
        switch cue {
        case .hint:
            timeHintShown = true
            showsTimeHint = true
            timeHintHideAt = ProcessInfo.processInfo.systemUptime + ScanFlowTiming.timeHintVisibleSeconds
            log("time hint at \(Int(elapsed)) s")
        case .limit:
            timeLimitShown = true
            timeHintShown = true
            showsTimeHint = false
            timeHintHideAt = nil
            showsTimeLimitSheet = true
            Haptics.warning()
            log("time limit card at \(Int(elapsed)) s")
        case nil:
            break
        }
    }

    /// Keep Scanning on the time limit card.
    func dismissTimeLimit() {
        showsTimeLimitSheet = false
    }

    // MARK: - Photos

    /// The photo recorder saved a photo (main).
    func photoSaved() {
        guard phase == .capturing || phase == .stopping else { return }
        showPhotoNote()
    }

    /// Shows "Photo saved to this spot" for a moment.
    func showPhotoNote() {
        showsPhotoNote = true
        photoNoteTask?.cancel()
        let delay = UInt64(ScanFlowTiming.photoNoteSeconds * 1_000_000_000)
        photoNoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.showsPhotoNote = false
        }
    }

    // MARK: - Screen lifecycle

    /// The scan screen appeared: hold the idle timer (Pipeline's `IdleTimerGuard`; this module
    /// never writes `isIdleTimerDisabled`).
    func scanScreenAppeared() {
        guard idleToken == nil, !hasEnded else { return }
        idleToken = IdleTimerGuard.acquire("scan screen")
    }

    /// The scan screen disappeared: give the idle timer hold back.
    func scanScreenDisappeared() {
        releaseIdleToken()
    }

    /// Releases the idle timer hold, when held.
    func releaseIdleToken() {
        guard let token = idleToken else { return }
        idleToken = nil
        IdleTimerGuard.release(token)
    }

    /// The app went to the background. The room engine pauses itself on the ARSession
    /// interruption; the Demo Mode engine is paused here so the paused chrome can be tried.
    func appDidEnterBackground() {
        guard isDemo, phase == .capturing, !isPaused, let current = engine else { return }
        log("demo engine paused for the background")
        current.pause()
    }

    // MARK: - Names and logs

    /// Default name of a new project of `mode` ("Room Sep 28"), with the date as a localized
    /// month and day.
    nonisolated static func defaultProjectName(mode: ScanMode, now: Date, locale: Locale = .current,
                                               timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let date = formatter.string(from: now)
        switch mode {
        case .room, .advancedSpace: return Copy.Home.defaultRoomName(date)
        case .house: return Copy.Home.defaultHouseName(date)
        case .object, .advancedObject: return Copy.Home.defaultObjectName(date)
        case .quickMeasure: return Copy.Home.defaultMeasureName(date)
        }
    }

    /// Writes one line to the app log (category "scanui").
    func log(_ message: String) {
        LogStore.shared.write(message, category: ScanPreflight.logCategory)
    }
}
