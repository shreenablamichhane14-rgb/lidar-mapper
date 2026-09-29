import SwiftUI

/// Rows of one dimension group, in display order.
struct ResultRowSection: Identifiable, Equatable {
    /// The group (room, walls, doors, windows, objects).
    var group: DimensionGroup
    /// Its rows, in the order MeasureCore gives them.
    var rows: [DimensionRow]
    /// Stable identity (the group).
    var id: String { group.rawValue }

    /// Groups in `DimensionGroup` order, leaving out empty ones.
    static func sections(_ rows: [DimensionRow]) -> [ResultRowSection] {
        DimensionGroup.allCases.compactMap { group in
            let members = rows.filter { $0.group == group }
            return members.isEmpty ? nil : ResultRowSection(group: group, rows: members)
        }
    }

    /// True when row `index` starts a new element (its label differs from the row before), so
    /// the element name ("Wall 3") is shown above it. Room rows named like their group
    /// ("Room") never repeat the name.
    static func startsElement(_ rows: [DimensionRow], at index: Int, group: DimensionGroup) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let row = rows[index]
        if group == .room && row.label == group.title { return false }
        return index == 0 || rows[index - 1].label != row.label
    }
}

/// The room dimensions panel (SPEC MEASUREMENT SYSTEM and MEASUREMENT CONFIDENCE): a header that
/// shows or hides the list, Show All while a wall or opening filters it, the rows grouped with
/// every value followed by its confidence text (`MeasureDisplay`), the Walls group note, the
/// degraded-capture note and `Copy.Measure.disclaimer`.
struct ResultDimensionsPanel: View {
    /// Rows to list (already filtered by the selection).
    let rows: [DimensionRow]
    /// True while a selection filters the rows (shows Show All).
    let isFiltered: Bool
    /// Units of the values.
    let prefs: UnitPreferences
    /// Text shown when there are no rows.
    let emptyText: String
    /// Degraded-capture note, if any.
    let note: String?
    /// Whether the list is open.
    @Binding var isExpanded: Bool
    /// Clears the selection.
    let onShowAll: () -> Void
    /// Cap of the open list's height, from the screen (the list never pushes the content away).
    let maxListHeight: CGFloat
    /// Height of the open list, following the text size.
    @ScaledMetric(relativeTo: .body) private var listHeight: CGFloat = 240

    /// Creates the panel (explicit, because the private scaled metric would make the
    /// memberwise initializer private).
    init(rows: [DimensionRow], isFiltered: Bool, prefs: UnitPreferences, emptyText: String, note: String?,
         isExpanded: Binding<Bool>, maxListHeight: CGFloat = .infinity, onShowAll: @escaping () -> Void) {
        self.rows = rows
        self.isFiltered = isFiltered
        self.prefs = prefs
        self.emptyText = emptyText
        self.note = note
        self._isExpanded = isExpanded
        self.maxListHeight = maxListHeight
        self.onShowAll = onShowAll
    }

    /// Header plus the list when open.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                ScrollView {
                    list
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Swift.max(88, Swift.min(listHeight, maxListHeight)))
            }
        }
    }

    /// "Measurements" with a chevron, and Show All while filtered.
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(Copy.Results.dimensionsTitle)
                        .font(.headline)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.Results.dimensionsHint)
            Spacer(minLength: 8)
            if isFiltered {
                Button(Copy.Results.showAll, action: onShowAll)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }

    /// Groups, notes and the disclaimer.
    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rows.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(ResultRowSection.sections(rows)) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        ResultDimensionRowView(row: row, prefs: prefs,
                                               showsLabel: ResultRowSection.startsElement(section.rows, at: index,
                                                                                          group: section.group))
                    }
                    if let groupNote = section.group.note {
                        Text(groupNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(Copy.Measure.disclaimer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

/// One measurement: its name (and element name above the first row of an element), the value in
/// the user's units and its confidence text (accuracy, low confidence, "Not measured directly,
/// estimated" or "Estimated, not measured"), with the row's own low-confidence flag. A value that
/// was not measured directly also shows a dashed circle, so it reads differently without color.
/// VoiceOver reads the whole row with units spoken in full.
struct ResultDimensionRowView: View {
    /// The row.
    let row: DimensionRow
    /// Units of the value.
    let prefs: UnitPreferences
    /// Show the element name ("Wall 3") above the measurement name.
    let showsLabel: Bool
    /// Text size (accessibility sizes stack the value under the name).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Creates a row view (explicit, because the private environment property would make the
    /// memberwise initializer private).
    init(row: DimensionRow, prefs: UnitPreferences, showsLabel: Bool) {
        self.row = row
        self.prefs = prefs
        self.showsLabel = showsLabel
    }

    /// Name and value side by side, or stacked at accessibility sizes.
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    names
                    values(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    names
                    Spacer(minLength: 8)
                    values(alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText(prefs: prefs))
    }

    /// Element name (optional) and measurement name.
    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsLabel {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(row.title)
                .font(.subheadline)
        }
    }

    /// Value and confidence text.
    private func values(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(MeasureDisplay.valueText(row.value, kind: row.kind, prefs: prefs))
                .font(.body.weight(.semibold).monospacedDigit())
            if let accuracy = MeasureDisplay.accuracyText(row, prefs: prefs) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if row.isNotMeasured && !row.isLowConfidence {
                        Image(systemName: "circle.dashed")
                            .accessibilityHidden(true)
                    }
                    Text(accuracy)
                }
                .font(.caption)
                .foregroundStyle(row.isLowConfidence ? Color.orange : Color.secondary)
            }
        }
    }
}
