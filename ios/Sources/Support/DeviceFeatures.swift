import UIKit

/// Haptic cues during scanning. Built into iOS, no permission needed.
@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func firm() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Battery, heat and power state for the log: a hot phone or Low Power Mode
/// explains a slow or aborted scan without guessing.
@MainActor
enum DeviceState {
    static var summary: String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel < 0 ? "?" : "\(Int(device.batteryLevel * 100))%"
        let charging: String
        switch device.batteryState {
        case .charging: charging = "charging"
        case .full: charging = "full"
        case .unplugged: charging = "on battery"
        default: charging = "unknown"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? ", LOW POWER MODE" : ""
        return "battery \(level) \(charging), thermal \(thermal)\(lowPower)"
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}
