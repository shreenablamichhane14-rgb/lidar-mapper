import SwiftUI
import UIKit

// The parts of the scan quality sheet's report (QualitySheet.swift): the summary card, the
// score rows with their bars, the missing areas row, the notes, and the tint colors and
// symbols. Internal only because they live in their own file; nothing outside QualityUI uses them.

/// Summary line, the five score rows, the missing areas row and the notes of one evaluation.
struct QualityReportContent: View {
    /// The evaluation shown.
    let evaluation: QualityEvaluation

    /// The report, top to bottom.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            QualitySummaryCard(verdict: QualityPresentation.displayVerdict(evaluation))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(QualityPresentation.rows(for: evaluation)) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        QualityValueLine(title: row.title, value: row.percentText, tint: row.tint)
                        QualityScoreBar(fraction: row.fraction, tint: row.tint)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(row.accessibility))
                }
            }
            QualityMissingLine(count: QualityPresentation.missingCount(evaluation))
            ForEach(QualityPresentation.notes(for: evaluation), id: \.self) { note in
                QualityNoteLine(text: note)
            }
        }
    }
}

/// The plain verdict sentence on a rounded card, with the verdict's symbol.
struct QualitySummaryCard: View {
    /// The verdict shown (`QualityPresentation.displayVerdict`).
    let verdict: QualityVerdict

    /// Symbol and sentence.
    var body: some View {
        let tint = QualityTint(verdict: verdict)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: QualitySheetStyle.symbol(for: tint))
                .foregroundStyle(QualitySheetStyle.color(for: tint))
                .accessibilityHidden(true)
            Text(QualityPresentation.summaryText(verdict))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The missing areas row: "Missing areas" and the count, read as "Missing areas, 3".
struct QualityMissingLine: View {
    /// Number of missing areas.
    let count: Int

    /// Title and count.
    var body: some View {
        QualityValueLine(title: Copy.Quality.missingAreas, value: QualityPresentation.missingText(count: count),
                         tint: QualityTint(missingAreas: count))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(QualityPresentation.missingAccessibility(count: count)))
    }
}

/// One title and value pair with the tint symbol: side by side normally, stacked at
/// accessibility text sizes so neither is squeezed.
struct QualityValueLine: View {
    /// Row title ("Walls").
    let title: String
    /// Value text ("94%", "3").
    let value: String
    /// Tint of the symbol.
    let tint: QualityTint
    /// Current text size.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Symbol, title and value.
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                valueText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleLine
                Spacer(minLength: 8)
                valueText
            }
        }
    }

    /// Tint symbol and title.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: QualitySheetStyle.symbol(for: tint))
                .foregroundStyle(QualitySheetStyle.color(for: tint))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
    }

    /// The value in semibold with even-width digits.
    private var valueText: some View {
        Text(value)
            .font(.body.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
    }
}

/// A score bar whose height follows the text size: a gray track and a tinted fill.
struct QualityScoreBar: View {
    /// Filled share, 0...1.
    let fraction: Double
    /// Tint of the fill.
    let tint: QualityTint
    /// Bar height, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 8

    /// Track and fill.
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(uiColor: .systemFill))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(QualitySheetStyle.color(for: tint))
                        .frame(width: proxy.size.width * CGFloat(fraction), height: proxy.size.height)
                }
            }
            .accessibilityHidden(true)
    }
}

/// One note (degraded capture or low light) with an info symbol.
struct QualityNoteLine: View {
    /// The note text from `Copy.Quality`.
    let text: String

    /// Symbol and text.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// Colors and symbols of the tints. System colors adapt to dark mode and Increase Contrast.
enum QualitySheetStyle {
    /// Green, orange or red.
    static func color(for tint: QualityTint) -> Color {
        switch tint {
        case .good: return .green
        case .okay: return .orange
        case .poor: return .red
        }
    }

    /// A different shape per tint, so the rows read without color.
    static func symbol(for tint: QualityTint) -> String {
        switch tint {
        case .good: return "checkmark.circle.fill"
        case .okay: return "exclamationmark.circle.fill"
        case .poor: return "exclamationmark.triangle.fill"
        }
    }
}
