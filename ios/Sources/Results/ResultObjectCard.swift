import SwiftUI

/// The read-only object card of build 4 (SPEC AUTOMATIC OBJECT RECOGNITION: labels are shown
/// as guesses): "Mapper's guess: Sofa" with width, height and depth and their
/// confidence (MeasureCore `objectRows`). Change Category arrives in build 5, the full object
/// menu in build 7.
struct ResultObjectCard: View {
    /// The selected object.
    let object: DetectedObject
    /// Its width, height and depth rows.
    let rows: [DimensionRow]
    /// Units of the values.
    let prefs: UnitPreferences
    /// Closes the card (clears the selection).
    let onClose: () -> Void

    /// Guess, optional user label, the three sizes and a close button.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(Copy.Results.objectGuess(Copy.FloorPlan.categoryName(object.category)))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.A11y.close)
            }
            if !object.label.isEmpty {
                Text(object.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                ResultDimensionRowView(row: row, prefs: prefs, showsLabel: false)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
