import Foundation

// Value types of the object flow (docs/MODULES.md 3.42): the phases, the signals the pure
// reducer `ObjectFlowModel.nextPhase(_:on:)` reads, and the alerts with their buttons.

/// Where the object flow is.
enum ObjectFlowPhase: Equatable {
    /// The size chooser, the checks, the pre-permission screen, the tips, Object Capture and
    /// the manifest update after the photos were sealed.
    case chooser, preflight, permission, tips, capturing, saving
    /// Terminal: the object was saved in project `UUID`; the user chose Large; the flow failed
    /// (log text); the flow ended without an object.
    case done(UUID), largeChosen, failed(String), cancelled

    /// True for the four terminal phases.
    var isTerminal: Bool {
        switch self {
        case .done, .largeChosen, .failed, .cancelled: return true
        case .chooser, .preflight, .permission, .tips, .capturing, .saving: return false
        }
    }
}

/// What happened in the flow (input of the pure reducer).
enum ObjectFlowSignal: Equatable, Sendable {
    /// Size chooser choices.
    case choseSmallMedium, choseLarge
    /// Preflight results: passed (with or without the tips), blocked, camera never asked.
    case preflightPassed(showTips: Bool), preflightBlocked, permissionNeeded
    /// Camera answers on the pre-permission screen.
    case permissionGranted(showTips: Bool), permissionDenied
    /// Start Scan or Skip on the tips page.
    case tipsDone
    /// The photos were sealed; the manifest was updated for project `UUID`.
    case captureSealed, saved(UUID)
    /// The capture was cancelled or discarded before anything was sealed.
    case captureEnded
    /// Cancel on the chooser, the checks, the permission screen or the tips.
    case cancelled
    /// Anything that stops the flow with an alert (log text).
    case failed(String)
}

/// Buttons an object flow alert offers.
enum ObjectAlertAction: Equatable, Sendable {
    /// Dismiss (Copy.Errors.ok).
    case ok
    /// Open Mapper's page in Settings (Copy.Permissions.openSettings).
    case openSettings
}

/// One alert of the object flow: text from Copy plus its buttons.
struct ObjectAlert: Identifiable, Equatable {
    /// Stable identifier (the error or issue key), also used in logs.
    var id: String
    /// Alert title.
    var title: String
    /// Alert message.
    var body: String
    /// Buttons in display order.
    var actions: [ObjectAlertAction]

    /// Keeps title and body; `.ok` and `.openSettings` map one to one, `.finishNow` and `.resume`
    /// (capture-time actions that preflight alerts never carry) are dropped, `[.ok]` when none is left.
    static func from(_ alert: ScanAlert) -> ObjectAlert {
        var actions: [ObjectAlertAction] = []
        for action in alert.actions {
            switch action {
            case .ok: actions.append(.ok)
            case .openSettings: actions.append(.openSettings)
            case .finishNow, .resume: break
            }
        }
        if actions.isEmpty { actions = [.ok] }
        return ObjectAlert(id: alert.id, title: alert.title, body: alert.body, actions: actions)
    }

    /// `unsupported` -> Copy.Errors.objectUnsupported; `lowStorage` -> Copy.Errors.storageFullTitle
    /// and storageFullBody(_:) with the size text ScanUI's storage alert uses (3 GB needed);
    /// `deviceHot` -> Copy.ObjectUI.tooHotToStart; `deviceWarm` -> Copy.ScanUI.warmTitle, warmBody
    /// (the same id as ScanUI's warm warning, so the flow shows it once).
    static func preflight(_ issue: ObjectPreflightIssue) -> ObjectAlert {
        switch issue {
        case .unsupported:
            return ObjectAlert(id: "object.unsupported", title: Copy.Errors.objectUnsupported.title,
                               body: Copy.Errors.objectUnsupported.body, actions: [.ok])
        case .lowStorage:
            let size = ScanErrorCopy.sizeText(ProjectStore.objectCapturePreflightBytes)
            return ObjectAlert(id: "object.lowStorage", title: Copy.Errors.storageFullTitle,
                               body: Copy.Errors.storageFullBody(size), actions: [.ok])
        case .deviceHot:
            return ObjectAlert(id: "object.deviceHot", title: Copy.ObjectUI.tooHotToStart.title,
                               body: Copy.ObjectUI.tooHotToStart.body, actions: [.ok])
        case .deviceWarm:
            return ObjectAlert(id: warmWarningID, title: Copy.ScanUI.warmTitle, body: Copy.ScanUI.warmBody, actions: [.ok])
        }
    }

    /// ScanUI's blocking issue as an alert: `from(ScanErrorCopy.alert(for:))` of cameraDenied ->
    /// `.cameraDenied`, noLidar -> `.unsupportedDevice`, lowStorage(free) -> `.lowStorage(freeBytes:)`;
    /// nil for cameraUndetermined (the permission phase) and warnings.
    static func scanPreflight(_ issue: PreflightIssue) -> ObjectAlert? {
        switch issue {
        case .cameraDenied:
            return from(ScanErrorCopy.alert(for: MapperError.cameraDenied))
        case .noLidar:
            return from(ScanErrorCopy.alert(for: MapperError.unsupportedDevice))
        case .lowStorage(let free):
            return from(ScanErrorCopy.alert(for: MapperError.lowStorage(freeBytes: free)))
        case .cameraUndetermined, .storageWarning, .lowBattery, .deviceHot:
            return nil
        }
    }

    /// ScanUI's warning as an alert (`ScanErrorCopy.preflightAlert(for:)`): storage getting low,
    /// low battery, warm phone; nil for blocking issues.
    static func scanWarning(_ issue: PreflightIssue) -> ObjectAlert? {
        switch issue {
        case .storageWarning, .lowBattery, .deviceHot:
            return from(ScanErrorCopy.preflightAlert(for: issue))
        case .cameraDenied, .cameraUndetermined, .noLidar, .lowStorage:
            return nil
        }
    }

    /// The alert for an error thrown while starting a capture or writing the demo object:
    /// the Object Capture preflight errors of `ObjectScanModel.start()` read as `preflight`
    /// alerts (unsupported, storage, heat), everything else as ScanUI's alert for the error.
    static func startFailure(_ error: Error) -> ObjectAlert {
        guard let mapped = error as? MapperError else {
            return ObjectAlert(id: "object.startFailed", title: Copy.Errors.generic.title, body: Copy.Errors.generic.body,
                               actions: [.ok])
        }
        switch mapped {
        case .unsupportedDevice:
            return preflight(.unsupported)
        case .lowStorage(let free):
            return preflight(.lowStorage(free: free))
        case .deviceTooHot:
            return preflight(.deviceHot)
        default:
            return from(ScanErrorCopy.alert(for: mapped))
        }
    }

    /// Id shared by the warm warnings of ScanUI's and Object Capture's preflight.
    static let warmWarningID = "warning.warm"

    /// Warnings in order without repeating an id (both preflights report a warm phone).
    static func uniqueWarnings(_ alerts: [ObjectAlert]) -> [ObjectAlert] {
        var seen = Set<String>()
        var result: [ObjectAlert] = []
        for alert in alerts where !seen.contains(alert.id) {
            seen.insert(alert.id)
            result.append(alert)
        }
        return result
    }
}
