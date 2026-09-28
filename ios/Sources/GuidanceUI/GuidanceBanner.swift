import SwiftUI

// The live guidance banner (UX_COPY section 4, RESEARCH "Guidance banner rules"): one message
// at a time, bold white text on a translucent dark pill, top center, replaced rather than
// stacked, hidden when all is well. The text is always `GuidanceKind.message.text`, which reads
// `Copy.Guidance.all`. Timing (minimum time, gap, priority) belongs to `GuidanceEngine`; the
// banner shows whatever kind it is given. VoiceOver announcements and haptics are posted by
// `GuidanceAnnouncer`, never here.

/// Pill banner, top center: bold white text on a translucent dark capsule; animates in and out;
/// shows `kind.message.text`; hidden when nil. Clamped to .xxxLarge Dynamic Type.
///
/// Layout: the view fills the space it is given and pins the pill to the top center, so place
/// it as a full-size overlay (for example in a `ZStack` over the camera view). It never takes
/// touches (`allowsHitTesting(false)`), so the controls and camera view under it keep working.
/// Tier 1 messages (safety and tracking) carry a small warning symbol that VoiceOver skips.
struct GuidanceBanner: View {
    /// The message to show, or nil for no banner.
    let kind: GuidanceKind?

    /// Reduce Motion: fade only, no slide.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Transparency: a nearly opaque pill.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Increase Contrast: a darker pill.
    @Environment(\.colorSchemeContrast) private var contrast

    /// Creates a banner for `kind` (nil hides it).
    init(kind: GuidanceKind?) {
        self.kind = kind
    }

    /// Top-aligned container that animates the pill in, out and between messages.
    var body: some View {
        VStack(spacing: 0) {
            if let kind {
                pill(for: kind)
                    .id(kind)
                    .transition(pillTransition)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, GuidanceBanner.sideMargin)
        .padding(.top, GuidanceBanner.topMargin)
        .animation(pillAnimation, value: kind)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .allowsHitTesting(false)
    }

    // MARK: Pieces

    /// The pill for one message.
    private func pill(for kind: GuidanceKind) -> some View {
        let message = kind.message
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if message.tier == 1 {
                Image(systemName: GuidanceBanner.warningSymbol)
                    .foregroundStyle(Color.yellow)
                    .accessibilityHidden(true)
            }
            Text(message.text)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(GuidanceBanner.maxLines)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline.weight(.bold))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .combine)
    }

    /// Pill opacity after the accessibility display settings.
    private var backgroundOpacity: Double {
        if reduceTransparency { return 0.92 }
        if contrast == .increased { return 0.82 }
        return 0.62
    }

    /// Slide down and fade, or fade only with Reduce Motion.
    private var pillTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    /// Short spring, or a plain fade with Reduce Motion.
    private var pillAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return .spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: Constants

    /// Gap between the pill and the sides of the screen, in points.
    static let sideMargin: CGFloat = 16
    /// Gap between the top of the available area and the pill, in points.
    static let topMargin: CGFloat = 8
    /// Longest message wraps to at most this many lines at the largest allowed text size.
    static let maxLines = 3
    /// SF Symbol shown before tier 1 messages (an image name, not user-facing text).
    static let warningSymbol = "exclamationmark.triangle.fill"
}
