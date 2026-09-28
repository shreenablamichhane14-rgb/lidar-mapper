import Foundation

/// App-level failures shown to the user. Core holds no UI text. Screens map each case to
/// its Copy title and body with an exhaustive `switch` (ScanUI `ScanErrorCopy`, docs/MODULES.md
/// 3.24), so a new case is a compile error until it has text; `copyKey` is a stable name for
/// logs and diagnostics only.
enum MapperError: Error, Equatable, Sendable {
    /// Not enough free storage to start or continue (D18).
    case lowStorage(freeBytes: Int64)
    /// The device lacks LiDAR or a required framework feature.
    case unsupportedDevice
    /// Camera permission denied.
    case cameraDenied
    /// ARKit world tracking failed.
    case trackingFailed
    /// The device is too hot to continue.
    case deviceTooHot
    /// Available memory fell below the capture floor (or iOS sent a memory warning); the
    /// engine finished the room early to avoid being closed by the system.
    case lowMemory
    /// The scene exceeded RoomPlan's size limit.
    case sceneTooLarge
    /// RoomPlan failed; the payload is a diagnostic description for the log.
    case roomPlanFailed(String)
    /// Object Capture or photogrammetry failed; diagnostic description for the log.
    case objectCaptureFailed(String)
    /// A pipeline step failed; `reason` is for the log.
    case processingFailed(step: PipelineStepID, reason: String)
    /// A pipeline step did not have enough memory, even for its reduced variant.
    case outOfMemory(step: PipelineStepID)
    /// A project file could not be read; diagnostic description for the log.
    case corruptProject(String)
    /// A file operation failed; diagnostic description for the log.
    case ioFailed(String)
    /// The user cancelled.
    case cancelled

    /// Stable key for logs and diagnostics, for example "error.lowStorage".
    var copyKey: String {
        switch self {
        case .lowStorage: return "error.lowStorage"
        case .unsupportedDevice: return "error.unsupportedDevice"
        case .cameraDenied: return "error.cameraDenied"
        case .trackingFailed: return "error.trackingFailed"
        case .deviceTooHot: return "error.deviceTooHot"
        case .lowMemory: return "error.lowMemory"
        case .sceneTooLarge: return "error.sceneTooLarge"
        case .roomPlanFailed: return "error.roomPlanFailed"
        case .objectCaptureFailed: return "error.objectCaptureFailed"
        case .processingFailed: return "error.processingFailed"
        case .outOfMemory: return "error.outOfMemory"
        case .corruptProject: return "error.corruptProject"
        case .ioFailed: return "error.ioFailed"
        case .cancelled: return "error.cancelled"
        }
    }
}

/// Low-level file and format errors thrown by Core's readers.
enum CoreError: Error, Equatable, Sendable {
    /// A file is malformed or truncated; the payload says where.
    case corruptFile(String)
    /// A required file is absent; the payload is its path relative to the package.
    case missingFile(String)
    /// The manifest was written by a newer build with this schema version.
    case unsupportedSchema(Int)
    /// A file is larger than its read cap (CR-4); `name` is the file name, `bytes` its size.
    case fileTooLarge(name: String, bytes: Int64)
}
