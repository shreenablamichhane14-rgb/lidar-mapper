import SwiftUI

// Small building blocks of the scan screen HUD (docs/MODULES.md 3.24): cards, pills, the
// large one-hand buttons, the notice card shown over the quality sheet, the progress line and
// the Demo Mode backdrop. All text comes from Copy through the callers; everything is drawn
// for the forced dark HUD and clamped to .xxxLarge Dynamic Type by `ScanChrome`.

/// A rounded dark card for HUD messages (paused, saving, time limit, notices).
struct ScanHUDCard<Content: View>: View {
    /// The card's content.
    let content: Content

    /// Wraps `content` in the card.
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// Padded content on a translucent rounded rectangle, at most 460 points wide.
    var body: some View {
        content
            .foregroundStyle(Color.white)
            .padding(18)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.74))
            )
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 3)
    }
}

/// A translucent pill with one short line of text (hints, timer, counts, demo banner).
struct ScanHUDPill: View {
    /// The text.
    let text: String
    /// Monospaced digits (the timer).
    var monospaced = false

    /// Bold white text on a dark capsule.
    var body: some View {
        Text(text)
            .font(monospaced ? Font.subheadline.weight(.semibold).monospacedDigit() : Font.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.6)))
    }
}

/// A large HUD button reachable with one thumb: prominent (Done, Resume) or plain (Cancel).
struct ScanHUDButton: View {
    /// Visual weight.
    enum Weight: Equatable {
        /// Filled accent button for the main action.
        case primary
        /// Bordered button for secondary actions.
        case secondary
    }

    /// Button title (Copy).
    let title: String
    /// Optional SF Symbol shown above the title.
    let systemImage: String?
    /// Visual weight.
    let weight: Weight
    /// Tap action.
    let action: () -> Void

    /// Scaled minimum height of the tap target.
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 54

    /// Creates a button.
    init(title: String, systemImage: String? = nil, weight: Weight = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.weight = weight
        self.action = action
    }

    /// The styled button.
    var body: some View {
        if weight == .primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// The plain button with its label.
    private var button: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 88, minHeight: minHeight)
        }
        .controlSize(.large)
        .tint(weight == .primary ? Color.accentColor : Color.white)
    }
}

/// A spinner with a status line ("Saving your scan...").
struct ScanProgressLine: View {
    /// The status text.
    let text: String

    /// Spinner and text side by side, read as one element.
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.white)
            Text(text)
                .font(.headline)
                .foregroundStyle(Color.white)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An alert shown as a card at the top of the scan screen while the quality sheet is up (a
/// system alert cannot be presented under the sheet): title, message and its buttons.
struct ScanNoticeCard: View {
    /// The alert.
    let notice: ScanAlert
    /// Called with the tapped action.
    let onAction: (ScanAlertAction) -> Void

    /// Title, message and buttons in a card.
    var body: some View {
        ScanHUDCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(notice.body)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    ForEach(notice.actions, id: \.self) { action in
                        Button(ScanErrorCopy.title(for: action)) {
                            onAction(action)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The Demo Mode stand-in for the camera: a dark backdrop with a slowly turning box and the
/// scan's progress, so the flow can be tried with no camera and no ARKit.
struct DemoScanBackdrop: View {
    /// The latest synthetic snapshot.
    let snapshot: LiveScanSnapshot

    /// Scaled size of the box symbol.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 120

    /// Creates the backdrop for `snapshot`.
    init(snapshot: LiveScanSnapshot) {
        self.snapshot = snapshot
    }

    /// Gradient, turning box and a progress bar of the synthetic coverage.
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: symbolSize, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .rotationEffect(Angle(degrees: turnDegrees))
                    .animation(.linear(duration: 0.25), value: snapshot.elapsed)
                ProgressView(value: coverage)
                    .tint(Color.green)
                    .frame(width: 180)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.scanView)
    }

    /// Rotation of the box: 6 degrees per second of replay.
    private var turnDegrees: Double {
        snapshot.elapsed.isFinite ? snapshot.elapsed * 6 : 0
    }

    /// Synthetic coverage, 0...1.
    private var coverage: Double {
        let value = Double(snapshot.coverageFraction)
        return value.isFinite ? Swift.min(Swift.max(value, 0), 1) : 0
    }
}
