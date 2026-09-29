import SwiftUI

/// The size chooser (D4, docs/MODULES.md 3.42): "How big is it?" with two large choices,
/// Small or Medium (Object Capture) and Large (the LiDAR mesh driver), each with its detail
/// line. Cancel sits at the top; the choices sit in the lower half for one-handed reach. Each
/// choice is one VoiceOver button whose label is the title and whose hint is the detail line.
/// Designed for the dark object cover (white text).
struct ObjectSizeChooser: View {
    /// Called with the chosen size.
    private let onPick: (ObjectSize) -> Void
    /// Cancel: end the flow.
    private let onCancel: () -> Void

    /// Scaled size of the choice icons.
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 34

    /// Creates the chooser.
    init(onPick: @escaping (ObjectSize) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// Cancel, the heading and the two choices.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(Copy.Scanning.cancel, action: onCancel)
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 12)
                Spacer()
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 16)
            Text(Copy.ObjectUI.sizeTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                choice(title: Copy.ObjectUI.smallMedium, detail: Copy.ObjectUI.smallMediumDetail,
                       symbol: "cube.transparent", size: .smallMedium)
                choice(title: Copy.ObjectUI.large, detail: Copy.ObjectUI.largeDetail,
                       symbol: "refrigerator", size: .large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// One large choice card: icon, title and detail line.
    private func choice(title: String, detail: String, symbol: String, size: ObjectSize) -> some View {
        Button {
            onPick(size)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .regular))
                    .frame(width: iconSize * 1.4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.white)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
