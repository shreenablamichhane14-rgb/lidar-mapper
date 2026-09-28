import SwiftUI

/// The sheet shown after New Scan: "What do you want to scan?" with Room, House / Building,
/// Object, Quick Measure and Advanced Scan (UX_COPY section 2). Modes outside `availableModes`
/// stay visible but disabled, with `Copy.HomeUI.comingLater` under their description (build 4
/// enables Room only). Tapping an enabled row calls `onPick`; the sheet never starts a scan
/// itself. Cancel calls `onCancel`.
///
/// Dynamic Type: system text styles; rows grow with the text. VoiceOver: each row reads its
/// title, then "Coming in a later version" when disabled, with the description as the hint.
struct ModePickerSheet: View {
    /// Modes this version can start.
    private let availableModes: Set<ScanMode>
    /// Called with the chosen mode.
    private let onPick: (ScanMode) -> Void
    /// Called when the user taps Cancel.
    private let onCancel: () -> Void

    /// Icon column width, following the title text size.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 36

    /// Creates the picker.
    init(availableModes: Set<ScanMode>, onPick: @escaping (ScanMode) -> Void, onCancel: @escaping () -> Void) {
        self.availableModes = availableModes
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// The title header, the five mode rows and a Cancel button in the navigation bar.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomePresentation.modeEntries(availableModes: availableModes)) { entry in
                        Button {
                            pick(entry)
                        } label: {
                            row(entry)
                        }
                        .disabled(!entry.isEnabled)
                        .accessibilityLabel(Text(entry.title))
                        .accessibilityValue(Text(entry.isEnabled ? "" : Copy.HomeUI.comingLater))
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
            let enabled = HomePresentation.modeEntries(availableModes: availableModes)
                .filter { $0.isEnabled }
                .map { $0.mode.rawValue }
                .joined(separator: ", ")
            LogStore.shared.write("home: scan type picker shown, enabled: \(enabled.isEmpty ? "none" : enabled)", category: "home")
        }
    }

    /// One mode row: icon, title, description and, when disabled, the "later version" note.
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
                if !entry.isEnabled {
                    Text(Copy.HomeUI.comingLater)
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
