import SwiftUI

/// The wireless debug log switch (R18): session-only. `MapperApp` turns the setting off at
/// every launch and never starts the server itself; turning it on removes the old token first
/// so a new one is made; the listener stops when Mapper goes to the background. Main actor.
@MainActor enum AppWirelessDebug {
    /// True between `enable` and `disable` in this session, so the Settings toggle's own
    /// change callback after a background stop does not stop and log a second time.
    private static var isEnabled = false

    /// Launch: the setting never survives a relaunch (any thread; `UserDefaults` is thread-safe).
    nonisolated static func resetAtLaunch(_ defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: SettingsKey.wirelessDebug)
    }

    /// The user turned the toggle on: new token, setting on, listener started.
    static func enable(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SettingsKey.debugToken)
        defaults.set(true, forKey: SettingsKey.wirelessDebug)
        isEnabled = true
        DebugServer.shared.start()
        LogStore.shared.write("wireless debug turned on in Settings (new token)", category: AppRouter.logCategory)
    }

    /// The user turned the toggle off, or Mapper went to the background. The setting is always
    /// cleared; the listener is stopped and the change logged only once per session.
    static func disable(reason: String, _ defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: SettingsKey.wirelessDebug)
        guard isEnabled else { return }
        isEnabled = false
        DebugServer.shared.stop()
        LogStore.shared.write("wireless debug turned off: \(reason)", category: AppRouter.logCategory)
    }

    /// `scenePhase` became `.background`: stop the listener and clear the setting.
    static func appDidEnterBackground() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.wirelessDebug) else { return }
        disable(reason: "app in background")
    }
}

/// Settings (docs/MODULES.md 3.29, UX_COPY section 15): units, inch fractions, show both,
/// vibrate for warnings, keep scan photos, show all tips again, storage used, the wireless
/// debug log with its address, Share Log, Diagnostics and the version. Plain grouped list with
/// system text styles, so Dynamic Type, VoiceOver and dark mode come from the system.
struct SettingsScreen: View {
    /// Units shown everywhere (`UnitPreferences`, stored as JSON under "units").
    @State private var prefs = UnitPreferences.load()
    /// "Vibrate for warnings" (GuidanceUI's key, absent means on).
    @AppStorage(SettingsKey.guidanceHaptics) private var haptics = true
    /// "Keep scan photos" (ScanUI's key, absent means on).
    @AppStorage(SettingsKey.keepScanPhotos) private var keepPhotos = true
    /// The wireless debug log (session-only, see `AppWirelessDebug`).
    @AppStorage(SettingsKey.wirelessDebug) private var wirelessDebug = false
    /// Bytes used by the projects, nil while counting.
    @State private var storageBytes: Int64?
    /// True right after Show All Tips Again (shows a check mark).
    @State private var tipsReset = false
    /// The debug server address, read when the toggle turns on.
    @State private var debugAddress: String?

    /// Creates the screen.
    init() {}

    /// The settings list.
    var body: some View {
        List {
            unitsSection
            scanningSection
            storageSection
            troubleshootingSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Copy.Settings.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: prefs) { _, newValue in
            newValue.save()
            SettingsScreen.log("units \(newValue.system.rawValue), 1/\(newValue.fraction.rawValue), both \(newValue.showBoth)")
        }
        .onChange(of: wirelessDebug) { _, isOn in
            wirelessDebugChanged(isOn)
        }
        .task { await countStorage() }
        .onAppear {
            prefs = UnitPreferences.load()
            if wirelessDebug { debugAddress = DebugServer.shared.url }
        }
    }

    // MARK: - Sections

    /// Units, inch fractions and show both.
    private var unitsSection: some View {
        Section {
            Picker(Copy.Settings.units, selection: $prefs.system) {
                Text(Copy.Settings.unitsImperial).tag(UnitSystem.imperial)
                Text(Copy.Settings.unitsMetric).tag(UnitSystem.metric)
            }
            Picker(Copy.Settings.fractionPrecision, selection: $prefs.fraction) {
                Text(Copy.Settings.fractionEighth).tag(FractionDenominator.eighth)
                Text(Copy.Settings.fractionSixteenth).tag(FractionDenominator.sixteenth)
            }
            Toggle(Copy.AppShell.showBoth, isOn: $prefs.showBoth)
        } header: {
            Text(Copy.Settings.units)
        }
    }

    /// Vibrate for warnings, keep scan photos, show all tips again.
    private var scanningSection: some View {
        Section {
            Toggle(Copy.Settings.haptics, isOn: $haptics)
            Toggle(Copy.Settings.savePhotos, isOn: $keepPhotos)
            Button {
                resetTips()
            } label: {
                HStack {
                    Text(Copy.Settings.resetTips)
                    Spacer()
                    if tipsReset {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
        } header: {
            Text(Copy.Settings.scanningSection)
        }
    }

    /// "{size} used by Mapper".
    private var storageSection: some View {
        Section {
            if let bytes = storageBytes {
                Text(Copy.Settings.storageUsed(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
            } else {
                ProgressView()
            }
        } header: {
            Text(Copy.Settings.storageSection)
        }
    }

    /// Wireless debug log (with its address while on), Share Log and Diagnostics.
    private var troubleshootingSection: some View {
        Section {
            Toggle(Copy.Settings.wirelessDebug, isOn: $wirelessDebug)
            if wirelessDebug {
                if let address = debugAddress {
                    Text(address)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text(Copy.AppShell.wirelessDebugNoWiFi)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            AppShareLogLink()
            NavigationLink(value: AppRoute.diagnostics) {
                Text(Copy.AppShell.diagnosticsTitle)
            }
        } header: {
            Text(Copy.Settings.troubleshootingSection)
        } footer: {
            Text(wirelessDebug && debugAddress != nil ? Copy.AppShell.wirelessDebugAddress : Copy.Settings.wirelessDebugFooter)
        }
    }

    /// Privacy line and version.
    private var aboutSection: some View {
        Section {
            Text(Copy.Settings.privacy)
                .foregroundStyle(.secondary)
            Text(Copy.Settings.version(AppInfo.buildTag))
                .foregroundStyle(.secondary)
        } header: {
            Text(Copy.Settings.aboutSection)
        }
    }

    // MARK: - Actions

    /// The wireless debug toggle changed (or Mapper cleared it in the background): on starts a
    /// new session with a new token, off stops the listener.
    private func wirelessDebugChanged(_ isOn: Bool) {
        if isOn {
            AppWirelessDebug.enable()
            debugAddress = DebugServer.shared.url
        } else {
            AppWirelessDebug.disable(reason: "turned off in Settings")
            debugAddress = nil
        }
    }

    /// Clears every mode's "tips seen" flag.
    private func resetTips() {
        let defaults = UserDefaults.standard
        for mode in ScanMode.allCases {
            defaults.removeObject(forKey: SettingsKey.tipsSeen(mode))
        }
        tipsReset = true
        Haptics.success()
        SettingsScreen.log("tips reset")
    }

    /// Counts the bytes under Documents/Projects off main.
    private func countStorage() async {
        let bytes = await Task.detached(priority: .utility) { StorageUsage.projectsTotal() }.value
        storageBytes = bytes
    }

    /// Writes one line to the app log.
    static func log(_ message: String) {
        LogStore.shared.write("settings: " + message, category: AppRouter.logCategory)
    }
}
