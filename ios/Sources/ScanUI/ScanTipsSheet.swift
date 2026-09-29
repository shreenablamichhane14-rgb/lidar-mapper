import SwiftUI

/// Tips before the first scan of a mode (UX_COPY section 3): the numbered tips of
/// `Copy.Onboarding`, a "Don't show again" toggle (on by default, so the tips show once per
/// mode unless the user turns it off), Skip at the top and Start Scan at the bottom (one-hand
/// reach). Both Start Scan and Skip call `onStart` with the toggle. Shown inside the scan cover
/// by `RoomScanScreen`, which passes `onCancel` for its Cancel button.
struct ScanTipsSheet: View {
    /// The mode whose tips show.
    let mode: ScanMode
    /// Start Scan or Skip, with the "Don't show again" value.
    let onStart: (_ dontShowAgain: Bool) -> Void
    /// Cancel (nil hides the button).
    let onCancel: (() -> Void)?

    /// The "Don't show again" toggle.
    @State private var dontShowAgain = true
    /// Scaled size of the tip number badges.
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 28

    /// Creates the tips page for `mode`.
    init(mode: ScanMode, onStart: @escaping (_ dontShowAgain: Bool) -> Void, onCancel: (() -> Void)? = nil) {
        self.mode = mode
        self.onStart = onStart
        self.onCancel = onCancel
    }

    /// Cancel and Skip, the scrolling tips, the toggle and Start Scan.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onCancel {
                    Button(Copy.Scanning.cancel, action: onCancel)
                }
                Spacer()
                Button(Copy.Onboarding.skip) {
                    onStart(dontShowAgain)
                }
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Copy.ScanUI.tipsTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.white)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(ScanTipsSheet.tips(for: mode).enumerated()), id: \.offset) { item in
                        tipRow(number: item.offset + 1, text: item.element)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            VStack(spacing: 14) {
                Toggle(Copy.Onboarding.dontShowAgain, isOn: $dontShowAgain)
                    .foregroundStyle(Color.white)
                Button {
                    onStart(dontShowAgain)
                } label: {
                    Text(Copy.Onboarding.start)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// One numbered tip; VoiceOver reads the tip text only (the number is order, not content).
    private func tipRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: String(number))
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.black)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(Color.white))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The tips of a mode from `Copy.Onboarding`.
    nonisolated static func tips(for mode: ScanMode) -> [String] {
        switch mode {
        case .room: return Copy.Onboarding.room
        case .house: return Copy.Onboarding.house
        case .object: return Copy.Onboarding.object
        case .quickMeasure: return Copy.Onboarding.quickMeasure
        case .advancedSpace, .advancedObject: return Copy.Onboarding.advanced
        }
    }
}
