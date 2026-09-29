import SwiftUI
import simd

/// The five markings the legend explains (SPEC FURNITURE REMOVAL, TEST_PLAN FURN-02).
enum ResultLegendKind: String, CaseIterable, Identifiable {
    /// The markings in legend order.
    case measured, estimated, inferred, occluded, unscanned

    /// Stable identity.
    var id: String { rawValue }

    /// Label (`Copy.Measure`).
    var title: String {
        switch self {
        case .measured: return Copy.Measure.measured
        case .estimated: return Copy.Measure.estimated
        case .inferred: return Copy.Measure.inferred
        case .occluded: return Copy.Measure.occluded
        case .unscanned: return Copy.Measure.unscanned
        }
    }

    /// Explanation (`Copy.Measure`).
    var detail: String {
        switch self {
        case .measured: return Copy.Measure.measuredDetail
        case .estimated: return Copy.Measure.estimatedDetail
        case .inferred: return Copy.Measure.inferredDetail
        case .occluded: return Copy.Measure.occludedDetail
        case .unscanned: return Copy.Measure.unscannedDetail
        }
    }
}

/// The legend sheet (`Copy.Measure.legendTitle`): Measured, Estimated, Inferred, Occluded and
/// Unscanned with their detail lines and swatches matching the viewer and plan styles (solid,
/// dashed, the Inferred color, a gray hatch, a red square). Readable without color vision:
/// every swatch differs in pattern as well as color.
struct ResultLegendSheet: View {
    /// Closes the sheet.
    let onClose: () -> Void

    /// A list with one row per marking.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ResultLegendKind.allCases) { kind in
                        HStack(spacing: 14) {
                            ResultLegendSwatch(kind: kind)
                                .frame(width: 36, height: 36)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .font(.headline)
                                Text(kind.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(Copy.Measure.legendTitle)
                }
            }
            .navigationTitle(Copy.Results.legend)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.A11y.close, action: onClose)
                }
            }
        }
    }
}

/// A small sample of how a marking is drawn.
struct ResultLegendSwatch: View {
    /// The marking.
    let kind: ResultLegendKind

    /// Shape, fill and stroke of the marking.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        switch kind {
        case .measured:
            shape.fill(ResultLegendSwatch.color(ResultContentBuilder.wallColor))
                .overlay { shape.stroke(Color.primary, lineWidth: 2) }
        case .estimated:
            shape.fill(ResultLegendSwatch.color(ResultContentBuilder.wallColor))
                .overlay { shape.stroke(Color.primary, style: StrokeStyle(lineWidth: 2, dash: [4, 3])) }
        case .inferred:
            shape.fill(ResultLegendSwatch.color(MeshClassPalette.inferred))
                .overlay { shape.stroke(Color.primary.opacity(0.4), lineWidth: 1) }
        case .occluded:
            shape.fill(ResultLegendSwatch.color(ResultContentBuilder.occludedColor))
                .overlay { ResultHatchShape().stroke(Color.gray, lineWidth: 1.5).clipShape(shape) }
                .overlay { shape.stroke(Color.gray, lineWidth: 1) }
        case .unscanned:
            shape.fill(ResultLegendSwatch.color(ResultContentBuilder.missingColor))
                .overlay { shape.stroke(Color.red, lineWidth: 2) }
        }
    }

    /// A SwiftUI color from a linear RGBA vector of the viewer palette.
    static func color(_ rgba: SIMD4<Float>) -> Color {
        Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w))
    }
}

/// Diagonal hatch lines filling a rectangle (the Occluded swatch).
struct ResultHatchShape: Shape {
    /// Distance between lines in points.
    var spacing: CGFloat = 6

    /// Lines at 45 degrees across the whole rectangle.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = Swift.max(spacing, 2)
        var offset: CGFloat = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += step
        }
        return path
    }
}
