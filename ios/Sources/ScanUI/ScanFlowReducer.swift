import Foundation

// The scan flow state machine (docs/MODULES.md 3.24, ARCHITECTURE 10.3): phases, the signals
// that move between them and the pure reducer behind the table, plus the pure time rules of
// the scan screen (4 minute hint, 5 minute limit, 30 second paused prompt). Everything here is
// nonisolated so ScanUISelfTest checks it off the main actor.

/// Where the scan flow is.
enum ScanFlowPhase: Equatable, Sendable {
    /// Preflight checks run.
    case preflight
    /// The pre-permission screen before the camera prompt.
    case permission
    /// Tips before the first scan of the mode (skipped at once when already seen).
    case tips
    /// Scanning (the engine may be paused; see `ScanFlowModel.isPaused`).
    case capturing
    /// Done was tapped or the engine finishes the room itself; the room is being saved.
    case stopping
    /// The room is saved; the quality check runs (the quality sheet shows "Checking").
    case checking
    /// The quality sheet shows the evaluation.
    case quality
    /// Finish was tapped; the engine is being released.
    case finishing
    /// The flow ended with this project, which AppShell processes and opens.
    case done(UUID)
    /// The capture failed before the room was saved; the payload is a log key.
    case failed(String)
    /// The user cancelled or discarded, or a blocking preflight issue ended the flow.
    case cancelled

    /// True for done, failed and cancelled.
    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .preflight, .permission, .tips, .capturing, .stopping, .checking, .quality, .finishing: return false
        }
    }

    /// True while AppShell shows the quality sheet over the camera (checking, quality) and
    /// while it closes (finishing).
    var isSheetPhase: Bool {
        switch self {
        case .checking, .quality, .finishing: return true
        case .preflight, .permission, .tips, .capturing, .stopping, .done, .failed, .cancelled: return false
        }
    }

    /// True while the camera (or the demo backdrop) is on screen.
    var showsCapture: Bool {
        switch self {
        case .capturing, .stopping, .checking, .quality, .finishing: return true
        case .preflight, .permission, .tips, .done, .failed, .cancelled: return false
        }
    }
}

/// Inputs of the reducer: user actions, preflight results and engine events.
enum ScanFlowSignal: Equatable, Sendable {
    case preflightPassed, preflightBlocked, permissionNeeded, permissionGranted, permissionDenied, tipsDone,
         engineStarted, doneTapped, engineStopping, roomFinished(UUID), evaluated, finishTapped, cancelConfirmed,
         discarded, failed(String)
    /// The engine was released after Finish; the payload is the project id (finishing -> done).
    case completed(UUID)
}

/// A timed cue of the scan screen.
enum ScanTimeCue: Equatable, Sendable {
    /// The 4 minute hint (`Copy.ScanUI.timeHint`), shown once.
    case hint
    /// The 5 minute time limit card (`Copy.ScanUI.timeLimitTitle`), shown once.
    case limit
}

/// Time rules of the scan screen (ARCHITECTURE 4.2 "Timer"; Apple's scan-length advice).
enum ScanFlowTiming {
    /// Seconds of scanning before the time hint.
    static let timeHintSeconds: Double = 240
    /// Seconds of scanning before the time limit card (never an automatic stop).
    static let timeLimitSeconds: Double = 300
    /// Seconds paused before the Finish Now or Resume prompt.
    static let pausedPromptSeconds: Double = 30
    /// Seconds the time hint stays on screen.
    static let timeHintVisibleSeconds: Double = 8
    /// Seconds the "Photo saved" note stays on screen.
    static let photoNoteSeconds: Double = 2
    /// Longest wait for the engine's `.stateChanged(.idle)` after a discard, seconds.
    static let discardTimeoutSeconds: Double = 45
    /// Pause between closing an alert or dialog and presenting the quality sheet, seconds.
    static let presentationGapSeconds: Double = 0.5
}

extension ScanFlowModel {
    /// Pure phase reducer used by the model and the self-test. Terminal phases never change;
    /// a signal that does not apply to the current phase leaves it unchanged. A `.failed`
    /// after the room was saved (checking, quality, finishing) is only an alert, so the phase
    /// stays on the quality path.
    nonisolated static func nextPhase(_ phase: ScanFlowPhase, on signal: ScanFlowSignal) -> ScanFlowPhase {
        if phase.isTerminal { return phase }
        switch signal {
        case .preflightPassed:
            return phase == .preflight ? .tips : phase
        case .preflightBlocked:
            return phase == .preflight ? .cancelled : phase
        case .permissionNeeded:
            return phase == .preflight ? .permission : phase
        case .permissionGranted:
            return phase == .permission ? .tips : phase
        case .permissionDenied:
            return phase == .preflight || phase == .permission ? .cancelled : phase
        case .tipsDone, .engineStarted:
            return phase == .tips ? .capturing : phase
        case .doneTapped, .engineStopping:
            return phase == .capturing ? .stopping : phase
        case .roomFinished:
            return phase == .capturing || phase == .stopping ? .checking : phase
        case .evaluated:
            return phase == .checking ? .quality : phase
        case .finishTapped:
            return phase == .quality || phase == .checking ? .finishing : phase
        case .completed(let projectID):
            return phase == .finishing ? .done(projectID) : phase
        case .cancelConfirmed:
            return isBeforeRoomSaved(phase) ? .cancelled : phase
        case .discarded:
            return phase == .quality || phase == .checking ? .cancelled : phase
        case .failed(let reason):
            return isBeforeRoomSaved(phase) ? .failed(reason) : phase
        }
    }

    /// True for the phases before the room was saved: preflight, permission, tips, capturing
    /// and stopping.
    nonisolated static func isBeforeRoomSaved(_ phase: ScanFlowPhase) -> Bool {
        switch phase {
        case .preflight, .permission, .tips, .capturing, .stopping: return true
        case .checking, .quality, .finishing, .done, .failed, .cancelled: return false
        }
    }

    /// The timed cue due at `elapsed` seconds of scanning, or nil. The limit wins over the hint
    /// once both are due; each shows once.
    nonisolated static func timeCue(elapsed: Double, hintShown: Bool, limitShown: Bool) -> ScanTimeCue? {
        guard elapsed.isFinite else { return nil }
        if elapsed >= ScanFlowTiming.timeLimitSeconds && !limitShown { return .limit }
        if elapsed >= ScanFlowTiming.timeHintSeconds && elapsed < ScanFlowTiming.timeLimitSeconds && !hintShown { return .hint }
        return nil
    }

    /// True when the paused prompt should show: paused for at least 30 seconds and
    /// not yet prompted during this pause.
    nonisolated static func pausedPromptDue(pausedSeconds: Double, alreadyPrompted: Bool) -> Bool {
        guard pausedSeconds.isFinite, !alreadyPrompted else { return false }
        return pausedSeconds >= ScanFlowTiming.pausedPromptSeconds
    }

    /// Whole minutes and seconds of an elapsed time (negative and non-finite count as 0).
    nonisolated static func elapsedParts(_ seconds: Double) -> (minutes: Int, seconds: Int) {
        guard seconds.isFinite, seconds > 0 else { return (0, 0) }
        let total = Int(seconds.rounded(.down))
        return (total / 60, total % 60)
    }
}
