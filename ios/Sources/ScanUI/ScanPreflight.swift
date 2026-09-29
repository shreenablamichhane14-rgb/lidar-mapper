import Foundation
import UIKit
import AVFoundation
import RoomPlan

// Checks before a scan starts (docs/MODULES.md 3.24, ARCHITECTURE 4.2 and 12.3, D18):
// camera permission, LiDAR, free space, battery and heat. `evaluate` is the pure decision the
// self-test checks; `run` reads the real values on the main actor. Demo Mode never touches
// AVCaptureDevice or ARKit and only needs `demoMinimumFreeBytes` of storage.

/// Camera authorization as the scan flow sees it.
enum CameraPermission: Equatable, Sendable {
    /// The user allowed the camera.
    case authorized
    /// Denied or restricted: only Settings can change it.
    case denied
    /// Never asked: the permission phase asks.
    case undetermined
}

/// One preflight finding. The first four block a scan, the last three are warnings.
enum PreflightIssue: Equatable, Sendable {
    /// Camera access is off (alert with Open Settings).
    case cameraDenied
    /// Camera access was never asked (answered by the permission phase, not an alert).
    case cameraUndetermined
    /// The device has no LiDAR mesh or RoomPlan support.
    case noLidar
    /// Free space under the scan floor, bytes free.
    case lowStorage(free: Int64)
    /// Free space under the warning level, bytes free.
    case storageWarning(free: Int64)
    /// Battery level 0...1 under 20 percent (not charging).
    case lowBattery(Float)
    /// Thermal state serious or worse.
    case deviceHot
}

/// Result of the preflight checks.
struct PreflightReport: Equatable, Sendable {
    /// The issue that stops the scan, if any.
    var blocking: PreflightIssue?
    /// Issues worth telling the user before the scan, in display order.
    var warnings: [PreflightIssue]
}

/// Preflight checks of the scan flow.
enum ScanPreflight {
    /// Demo Mode needs only this much free space, bytes.
    static let demoMinimumFreeBytes: Int64 = 50_000_000
    /// Battery level under which a warning shows (not while charging).
    static let lowBatteryLevel: Float = 0.2
    /// Log category of the scan flow.
    static let logCategory = "scanui"

    /// Pure decision (tested). Blocking, in this order: no LiDAR, free space under
    /// `ProjectStore.refuseScanBelowBytes`, camera denied, camera undetermined (answered by the
    /// permission phase, not an alert; last, so every other check has passed when the phase
    /// asks). Warnings: thermal serious or worse, free space under `warnScanBelowBytes`,
    /// battery under 0.2. With `isDemo` the camera and LiDAR are ignored, the storage floor is
    /// `demoMinimumFreeBytes` and there is no storage warning (a demo writes a few MB).
    static func evaluate(cameraStatus: CameraPermission, lidarSupported: Bool, freeBytes: Int64, batteryLevel: Float?,
                         thermal: ThermalLevel, isDemo: Bool) -> PreflightReport {
        let floor = isDemo ? demoMinimumFreeBytes : ProjectStore.refuseScanBelowBytes
        var blocking: PreflightIssue?
        if !isDemo && !lidarSupported {
            blocking = .noLidar
        } else if freeBytes < floor {
            blocking = .lowStorage(free: freeBytes)
        } else if !isDemo && cameraStatus == .denied {
            blocking = .cameraDenied
        } else if !isDemo && cameraStatus == .undetermined {
            blocking = .cameraUndetermined
        }
        var warnings: [PreflightIssue] = []
        if thermal == .serious || thermal == .critical {
            warnings.append(.deviceHot)
        }
        if !isDemo && freeBytes >= floor && freeBytes < ProjectStore.warnScanBelowBytes {
            warnings.append(.storageWarning(free: freeBytes))
        }
        if let level = batteryLevel, level.isFinite, level >= 0, level < lowBatteryLevel {
            warnings.append(.lowBattery(level))
        }
        return PreflightReport(blocking: blocking, warnings: warnings)
    }

    /// Reads the real values without asking for camera access (the permission phase asks). In
    /// Demo Mode it never touches AVCaptureDevice or ARKit. Main actor; the free space is read
    /// off the main thread.
    @MainActor static func run(mode: ScanMode, isDemo: Bool) async -> PreflightReport {
        let camera: CameraPermission = isDemo ? .authorized : cameraPermission()
        let lidar: Bool = isDemo ? true : lidarSupported(for: mode)
        let free = await Task.detached(priority: .userInitiated) { ProjectStore.freeBytes() }.value
        let battery = batteryLevelForWarning()
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let report = evaluate(cameraStatus: camera, lidarSupported: lidar, freeBytes: free, batteryLevel: battery,
                              thermal: thermal, isDemo: isDemo)
        let batteryText = battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "charging or unknown"
        let blockingText = report.blocking.map { describe($0) } ?? "none"
        let warningText = report.warnings.isEmpty ? "none" : report.warnings.map { describe($0) }.joined(separator: " ")
        let parts: [String] = [
            "preflight mode \(mode.rawValue) demo \(isDemo): camera \(describe(camera))",
            "lidar \(lidar)", "free \(free / 1_000_000) MB", "battery \(batteryText)",
            "thermal \(thermal.rawValue); blocking \(blockingText); warnings \(warningText)",
        ]
        LogStore.shared.write(parts.joined(separator: ", "), category: logCategory)
        if report.blocking == .cameraDenied {
            LogStore.shared.write("camera permission denied", category: logCategory)
        }
        return report
    }

    /// The camera authorization without asking (`AVCaptureDevice.authorizationStatus(for: .video)`,
    /// not in RESEARCH, iOS 7). Restricted counts as denied; an unknown future state is treated
    /// as undetermined, so the permission phase asks and iOS answers.
    static func cameraPermission() -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// True when the device reconstructs a LiDAR mesh and, for modes that find rooms, runs
    /// RoomPlan (`ScanConfigurationFactory.supportsMesh`, `RoomCaptureSession.isSupported`).
    static func lidarSupported(for mode: ScanMode) -> Bool {
        guard ScanConfigurationFactory.supportsMesh else { return false }
        switch mode {
        case .room, .house, .advancedSpace:
            return RoomCaptureSession.isSupported
        case .object, .quickMeasure, .advancedObject:
            return true
        }
    }

    /// Battery level 0...1 for the low battery warning, or nil while charging, full or unknown.
    @MainActor static func batteryLevelForWarning() -> Float? {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        switch device.batteryState {
        case .charging, .full: return nil
        case .unplugged, .unknown: return level
        @unknown default: return level
        }
    }

    /// Log name of a camera permission.
    static func describe(_ permission: CameraPermission) -> String {
        switch permission {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        }
    }

    /// Log name of an issue (never UI text).
    static func describe(_ issue: PreflightIssue) -> String {
        switch issue {
        case .cameraDenied: return "cameraDenied"
        case .cameraUndetermined: return "cameraUndetermined"
        case .noLidar: return "noLidar"
        case .lowStorage(let free): return "lowStorage(\(free / 1_000_000) MB)"
        case .storageWarning(let free): return "storageWarning(\(free / 1_000_000) MB)"
        case .lowBattery(let level): return "lowBattery(\(Int((level * 100).rounded()))%)"
        case .deviceHot: return "deviceHot"
        }
    }
}
