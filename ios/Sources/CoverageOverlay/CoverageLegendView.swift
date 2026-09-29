import SwiftUI

// The color legend of the live coverage (docs/MODULES.md 3.38, SPEC "LIVE SCANNING EXPERIENCE"):
// green scanned well, yellow partly scanned, red missing detail, gray not scanned yet. Room mode
// shows it over RoomCaptureView next to the minimap (ScanUI revision); mesh-only views show it
// with the colored overlay. Also the Show Colors / Hide Colors toggle for screens that host a
// CoverageOverlayRenderer.

/// Legend text of each coverage state (pure; tested).
enum CoverageLegendContent {
    /// `Copy.Scanning.legendGreen`, `legendYellow`, `legendRed` or `legendGray`.
    static func text(for state: CoverageState) -> String {
        switch state {
        case .green: return Copy.Scanning.legendGreen
        case .yellow: return Copy.Scanning.legendYellow
        case .red: return Copy.Scanning.legendRed
        case .gray: return Copy.Scanning.legendGray
        }
    }

    /// SwiftUI color of a state's swatch (the display style, nearly opaque).
    static func swatchColor(for state: CoverageState, style: CoverageOverlayStyle = .display) -> Color {
        let c = style.color(for: state)
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w))
    }
}

/// The four colors with `Copy.Scanning.legend*` texts under `Copy.Scanning.legendTitle`; one combined
/// VoiceOver element reading `Copy.A11y.coverageLegend`.
struct CoverageLegendView: View {
    /// Smaller type and swatches for a HUD corner; the regular form suits a card or sheet.
    let compact: Bool

    /// A legend, regular or compact.
    init(compact: Bool = false) {
        self.compact = compact
    }

    /// Title, then one swatch and text per state in `CoverageOverlayPacking.stateOrder`.
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(Copy.Scanning.legendTitle)
                .font(compact ? Font.caption.weight(.semibold) : Font.headline)
            ForEach(CoverageOverlayPacking.stateOrder, id: \.self) { state in
                HStack(spacing: compact ? 6 : 10) {
                    RoundedRectangle(cornerRadius: compact ? 2 : 3, style: .continuous)
                        .fill(CoverageLegendContent.swatchColor(for: state))
                        .overlay {
                            RoundedRectangle(cornerRadius: compact ? 2 : 3, style: .continuous)
                                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                        }
                        .frame(width: compact ? 10 : 14, height: compact ? 10 : 14)
                    Text(CoverageLegendContent.text(for: state))
                        .font(compact ? Font.caption2 : Font.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.coverageLegend)
    }
}

/// Show Colors / Hide Colors: toggles `isShowing`, which the host copies to
/// `CoverageOverlayRenderer.isVisible`.
struct CoverageColorsButton: View {
    /// Whether the colored overlay is shown.
    @Binding var isShowing: Bool

    /// A toggle bound to `isShowing`.
    init(isShowing: Binding<Bool>) {
        _isShowing = isShowing
    }

    /// "Hide Colors" while shown, "Show Colors" while hidden.
    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Label(isShowing ? Copy.CoverageOverlay.hideColors : Copy.CoverageOverlay.showColors,
                  systemImage: isShowing ? "eye.slash" : "eye")
        }
    }
}
