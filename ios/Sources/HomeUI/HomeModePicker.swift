import SwiftUI

/// The sheet shown after New Scan: "What do you want to scan?" with Room, House / Building,
/// Object, Quick Measure and Advanced Scan (UX_COPY section 2). Modes outside `availableModes`
/// stay visible but disabled, with their note under the description: the reason AppShell passed
/// in `unavailableReasons` (for example "Object scanning isn't available"), else
/// `Copy.HomeUI.comingLater`. Build 5 enables House, Object and Quick Measure on capable devices;
/// the sheet never decides availability itself. Tapping an enabled row calls `onPick`; the sheet
/// never starts a scan itself. Cancel calls `onCancel`.
///
/// Dynamic Type: system text styles; rows grow with the text. VoiceOver: each row reads its
/// title, then its note when disabled, with the description as the hint.
struct ModePickerSheet: View {
    /// Modes this device and version can start (AppShell decides).
    private let availableModes: Set<ScanMode>
    /// Why a disabled mode cannot start, shown under its row (text from `Copy`, set by AppShell).
    private let unavailableReasons: [ScanMode: String]
    /// Called with the chosen mode.
    private let onPick: (ScanMode) -> Void
    /// Called when the user taps Cancel.
    private let onCancel: () -> Void

    /// Icon column width, following the title text size.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 36

    /// Creates the picker. `unavailableReasons` defaults to none, so the build 4 call form still
    /// works and every disabled row reads `Copy.HomeUI.comingLater`.
    init(availableModes: Set<ScanMode>, unavailableReasons: [ScanMode: String] = [:],
         onPick: @escaping (ScanMode) -> Void, onCancel: @escaping () -> Void) {
        self.availableModes = availableModes
        self.unavailableReasons = unavailableReasons
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// The five rows for the current modes and reasons.
    private var entries: [HomeModeEntry] {
        HomePresentation.modeEntries(availableModes: availableModes, unavailableReasons: unavailableReasons)
    }

    /// The title header, the five mode rows and a Cancel button in the navigation bar.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entries) { entry in
                        Button {
                            pick(entry)
                        } label: {
                            row(entry)
                        }
                        .disabled(!entry.isEnabled)
                        .accessibilityLabel(Text(entry.title))
                        .accessibilityValue(Text(HomePresentation.modeAccessibilityValue(entry)))
                        .accessibilityHint(Text(entry.detail))
                    }
                } header: {
                    Text(Copy.Modes.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Modes.cancel) {
                        LogStore.shared.write("home: mode picker cancelled", category: "home")
                        onCancel()
                    }
                }
            }
        }
        .onAppear {
            logShown()
        }
    }

    /// Logs the enabled modes and, for the disabled ones, whether a reason was shown (TEST_PLAN
    /// MODE-02). Mode names only, never user data.
    private func logShown() {
        let current = entries
        let enabled = current.filter { $0.isEnabled }.map { $0.mode.rawValue }.joined(separator: ", ")
        let disabled = current.filter { !$0.isEnabled }.map { entry -> String in
            let hasReason = entry.note != nil && entry.note != Copy.HomeUI.comingLater
            return entry.mode.rawValue + (hasReason ? " (reason)" : " (later)")
        }.joined(separator: ", ")
        let enabledText = enabled.isEmpty ? "none" : enabled
        let disabledText = disabled.isEmpty ? "none" : disabled
        LogStore.shared.write("home: scan type picker shown, enabled: \(enabledText); disabled: \(disabledText)",
                              category: "home")
    }

    /// One mode row: icon, title, description and, when disabled, its note (the reason, or
    /// "Coming in a later version").
    private func row(_ entry: HomeModeEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.title2)
                .foregroundStyle(entry.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(entry.isEnabled ? Color.primary : Color.secondary)
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let note = entry.note {
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Reports an enabled mode; disabled rows never reach here (`.disabled`), but the guard
    /// keeps the rule if the row modifiers change.
    private func pick(_ entry: HomeModeEntry) {
        guard entry.isEnabled else { return }
        LogStore.shared.write("home: scan type picked: \(entry.mode.rawValue)", category: "home")
        onPick(entry.mode)
    }
}
