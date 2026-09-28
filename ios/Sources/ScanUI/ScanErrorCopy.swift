import Foundation

// Alerts of the scan flow (docs/MODULES.md 3.24, review S7): every `MapperError` and every
// preflight issue mapped to its Copy title, body and buttons. The `MapperError` switch has no
// `default`, so a new Core case fails to compile until it has text here.

/// Buttons an alert offers; the view maps them to Copy and actions.
enum ScanAlertAction: Equatable, Hashable, Sendable {
    /// Dismiss (Copy.Errors.ok).
    case ok
    /// Open Mapper's page in Settings (Copy.Permissions.openSettings).
    case openSettings
    /// Finish the room with what was scanned (Copy.ScanUI.finishNow).
    case finishNow
    /// Resume the paused scan (Copy.Scanning.resume).
    case resume
}

/// One alert of the scan flow: text from Copy plus the buttons to offer.
struct ScanAlert: Identifiable, Equatable {
    /// Stable identifier (the error or issue key), also used in logs.
    var id: String
    /// Alert title.
    var title: String
    /// Alert message.
    var body: String
    /// Buttons, in display order.
    var actions: [ScanAlertAction]
}

/// Exhaustive MapperError to alert mapping (no default, so a new Core case fails to compile
/// until it has text): lowStorage -> Copy.Errors.storageFullTitle and storageFullBody; unsupportedDevice
/// -> noLidar; cameraDenied -> Copy.Permissions.cameraDeniedTitle and cameraDeniedBody with
/// [.openSettings, .ok]; trackingFailed -> Copy.Errors.trackingFailed with [.resume, .finishNow] while
/// capturing; deviceTooHot -> Copy.RoomCapture.tooHotFinished; lowMemory -> Copy.RoomCapture.lowMemory;
/// sceneTooLarge -> Copy.RoomCapture.sceneTooLarge; roomPlanFailed -> Copy.RoomCapture.roomPlanFailed;
/// every other case -> Copy.Errors.generic.
enum ScanErrorCopy {
    /// The alert for an error. Pure, any thread.
    static func alert(for error: MapperError) -> ScanAlert {
        let key = error.copyKey
        switch error {
        case .lowStorage:
            return ScanAlert(id: key, title: Copy.Errors.storageFullTitle,
                             body: Copy.Errors.storageFullBody(sizeText(ProjectStore.refuseScanBelowBytes)), actions: [.ok])
        case .unsupportedDevice:
            return ScanAlert(id: key, title: Copy.Errors.noLidar.title, body: Copy.Errors.noLidar.body, actions: [.ok])
        case .cameraDenied:
            return ScanAlert(id: key, title: Copy.Permissions.cameraDeniedTitle, body: Copy.Permissions.cameraDeniedBody,
                             actions: [.openSettings, .ok])
        case .trackingFailed:
            return ScanAlert(id: key, title: Copy.Errors.trackingFailed.title, body: Copy.Errors.trackingFailed.body,
                             actions: [.resume, .finishNow])
        case .deviceTooHot:
            return ScanAlert(id: key, title: Copy.RoomCapture.tooHotFinished.title,
                             body: Copy.RoomCapture.tooHotFinished.body, actions: [.ok])
        case .lowMemory:
            return ScanAlert(id: key, title: Copy.RoomCapture.lowMemory.title, body: Copy.RoomCapture.lowMemory.body,
                             actions: [.ok])
        case .sceneTooLarge:
            return ScanAlert(id: key, title: Copy.RoomCapture.sceneTooLarge.title,
                             body: Copy.RoomCapture.sceneTooLarge.body, actions: [.ok])
        case .roomPlanFailed:
            return ScanAlert(id: key, title: Copy.RoomCapture.roomPlanFailed.title,
                             body: Copy.RoomCapture.roomPlanFailed.body, actions: [.ok])
        case .objectCaptureFailed, .processingFailed, .outOfMemory, .corruptProject, .ioFailed, .cancelled:
            return ScanAlert(id: key, title: Copy.Errors.generic.title, body: Copy.Errors.generic.body, actions: [.ok])
        }
    }

    /// The alert for an error that arrived after the room was saved (heat, storage, memory,
    /// scene size, tracking, RoomPlan): the same text with only OK, because there is nothing
    /// left to resume or finish.
    static func notice(for error: MapperError) -> ScanAlert {
        var result = ScanErrorCopy.alert(for: error)
        result.actions = [.ok]
        return result
    }

    /// The alert for a preflight issue: blocking issues reuse the error text, warnings use
    /// Copy.ScanUI (storage, heat) and Copy.Errors.lowBattery. `cameraUndetermined` has no
    /// alert of its own (the permission screen answers it) and maps to the denied text.
    static func alert(for issue: PreflightIssue) -> ScanAlert {
        switch issue {
        case .cameraDenied, .cameraUndetermined:
            return alert(for: MapperError.cameraDenied)
        case .noLidar:
            return alert(for: MapperError.unsupportedDevice)
        case .lowStorage(let free):
            return alert(for: MapperError.lowStorage(freeBytes: free))
        case .storageWarning(let free):
            return ScanAlert(id: "warning.storage", title: Copy.ScanUI.storageWarningTitle,
                             body: Copy.ScanUI.storageWarningBody(sizeText(free)), actions: [.ok])
        case .lowBattery:
            return ScanAlert(id: "warning.battery", title: Copy.Errors.lowBattery.title, body: Copy.Errors.lowBattery.body,
                             actions: [.ok])
        case .deviceHot:
            return ScanAlert(id: "warning.warm", title: Copy.ScanUI.warmTitle, body: Copy.ScanUI.warmBody, actions: [.ok])
        }
    }

    /// The paused prompt after 30 seconds: Finish Now or Resume.
    static func pausedPrompt() -> ScanAlert {
        ScanAlert(id: "prompt.paused", title: Copy.ScanUI.pausedFinishPrompt, body: Copy.Scanning.paused,
                  actions: [.finishNow, .resume])
    }

    /// Button title of an action.
    static func title(for action: ScanAlertAction) -> String {
        switch action {
        case .ok: return Copy.Errors.ok
        case .openSettings: return Copy.Permissions.openSettings
        case .finishNow: return Copy.ScanUI.finishNow
        case .resume: return Copy.Scanning.resume
        }
    }

    /// A byte count as file-size text ("1.5 GB"); byte counts are not lengths, so they do not
    /// go through Units.
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: Swift.max(0, bytes), countStyle: .file)
    }
}
