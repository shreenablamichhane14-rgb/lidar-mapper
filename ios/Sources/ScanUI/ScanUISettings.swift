import Foundation

// Settings keys owned by ScanUI (docs/MODULES.md 3.24) and small readers for them. AppShell's
// Settings and Diagnostics screens write the same keys (Demo Mode, Keep scan photos, Record
// scan snapshots, Show tips again).

extension SettingsKey {
    /// Bool. Diagnostics > Demo Mode: New Scan uses `FakeScanEngine` and no camera.
    static let demoMode = "demoMode"
    /// Bool, absent means on (`ScanSettings.keepAllPhotos`). Settings > Keep scan photos.
    static let keepScanPhotos = "keepScanPhotos"
    /// Bool. Diagnostics > Record Scan Snapshots (`SnapshotRecorder`).
    static let recordSnapshots = "recordSnapshots"

    /// Bool per mode, "tipsSeen.<mode>": true once the tips were shown with Don't show again on.
    static func tipsSeen(_ mode: ScanMode) -> String {
        "tipsSeen." + mode.rawValue
    }
}

/// Reads and writes the ScanUI settings in a `UserDefaults` store. Stateless, any thread
/// (`UserDefaults` is thread-safe).
enum ScanUISettings {
    /// True when Demo Mode is on.
    static func isDemoMode(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SettingsKey.demoMode)
    }

    /// Keep all photos: the stored value, or true when it was never set.
    static func keepAllPhotos(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKey.keepScanPhotos) as? Bool ?? true
    }

    /// True when snapshot recording is on (Diagnostics).
    static func recordsSnapshots(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SettingsKey.recordSnapshots)
    }

    /// True when the tips of `mode` should be skipped.
    static func tipsSeen(_ mode: ScanMode, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SettingsKey.tipsSeen(mode))
    }

    /// Marks the tips of `mode` as seen.
    static func markTipsSeen(_ mode: ScanMode, _ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: SettingsKey.tipsSeen(mode))
    }

    /// The capture settings of a new project: the mode's defaults with Keep all photos from
    /// the user's setting.
    static func scanSettings(for mode: ScanMode, _ defaults: UserDefaults = .standard) -> ScanSettings {
        var settings = ScanSettings.defaults(for: mode)
        settings.keepAllPhotos = keepAllPhotos(defaults)
        return settings
    }
}
