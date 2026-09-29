import SwiftUI

/// The measurement list, also the main content of Results' Quick Measure screen (3.43b): rows with
/// value and accuracy, swipe to delete, a rename alert, Delete All with confirmation when `onDeleteAll`
/// is set, a Done button when `onClose` is set (sheet use), `Copy.Measure.disclaimer` as the footer,
/// `Copy.Empty.noMeasurements` when empty. It has no navigation container of its own: the host
/// supplies the title (a sheet wraps it in a `NavigationStack`).
struct MeasureToolList: View {
    /// Rows in display order.
    let rows: [MeasureToolRow]
    /// Renames a measurement (id, new name).
    let onRename: (UUID, String) -> Void
    /// Deletes a measurement.
    let onDelete: (UUID) -> Void
    /// Deletes every measurement after confirmation; nil hides Delete All.
    let onDeleteAll: (() -> Void)?
    /// Closes the sheet; nil hides Done.
    let onClose: (() -> Void)?

    /// The row being renamed.
    @State private var renameTarget: MeasureToolRow?
    /// Text of the rename field.
    @State private var renameText = ""
    /// True while the rename alert is shown.
    @State private var isRenaming = false
    /// True while the Delete All confirmation is shown.
    @State private var confirmsDeleteAll = false

    /// A list of `rows` with the given actions.
    init(rows: [MeasureToolRow], onRename: @escaping (UUID, String) -> Void, onDelete: @escaping (UUID) -> Void,
         onDeleteAll: (() -> Void)?, onClose: (() -> Void)?) {
        self.rows = rows
        self.onRename = onRename
        self.onDelete = onDelete
        self.onDeleteAll = onDeleteAll
        self.onClose = onClose
    }

    /// The rows, or the empty state.
    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if let close = onClose {
                        Button(Copy.Scanning.done) { close() }
                    }
                }
            }
            .alert(Copy.MeasureTool.renameTitle, isPresented: $isRenaming, presenting: renameTarget) { target in
                TextField(Copy.MeasureTool.namePlaceholder, text: $renameText)
                    .textInputAutocapitalization(.sentences)
                Button(Copy.Errors.ok) { onRename(target.id, renameText) }
                Button(Copy.Project.cancel, role: .cancel) {}
            }
            .confirmationDialog(Copy.MeasureTool.deleteAllTitle, isPresented: $confirmsDeleteAll,
                                titleVisibility: .visible) {
                Button(Copy.MeasureTool.deleteAll, role: .destructive) { onDeleteAll?() }
                Button(Copy.Project.cancel, role: .cancel) {}
            } message: {
                Text(Copy.MeasureTool.deleteAllBody)
            }
    }

    /// The list, or the empty state with the disclaimer.
    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "ruler")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Copy.Empty.noMeasurements.title)
                    .font(.headline)
                Text(Copy.Empty.noMeasurements.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(Copy.Measure.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(rows) { row in
                        MeasureToolRowView(row: row)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDelete(row.id)
                                } label: {
                                    Label(Copy.Project.delete, systemImage: "trash")
                                }
                                Button {
                                    beginRename(row)
                                } label: {
                                    Label(Copy.Project.rename, systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                Button {
                                    beginRename(row)
                                } label: {
                                    Label(Copy.Project.rename, systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    onDelete(row.id)
                                } label: {
                                    Label(Copy.Project.delete, systemImage: "trash")
                                }
                            }
                            .accessibilityAction(named: Copy.Project.rename) { beginRename(row) }
                            .accessibilityAction(named: Copy.Project.delete) { onDelete(row.id) }
                    }
                } footer: {
                    Text(Copy.Measure.disclaimer)
                }
                if onDeleteAll != nil {
                    Section {
                        Button(Copy.MeasureTool.deleteAll, role: .destructive) {
                            confirmsDeleteAll = true
                        }
                    }
                }
            }
        }
    }

    /// Shows the rename alert filled with the current title.
    private func beginRename(_ row: MeasureToolRow) {
        renameText = row.title
        renameTarget = row
        isRenaming = true
    }
}

/// One measurement: title, value and accuracy (orange with a warning icon when low confidence, a
/// dashed circle when not measured directly), read by VoiceOver as one phrase.
struct MeasureToolRowView: View {
    /// The row.
    let row: MeasureToolRow
    /// Text size (accessibility sizes stack the value under the title).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Creates a row view (explicit, because the private environment property would make the
    /// memberwise initializer private).
    init(row: MeasureToolRow) {
        self.row = row
    }

    /// Title and value side by side, or stacked at accessibility sizes.
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.subheadline)
                    values(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title).font(.subheadline)
                    Spacer(minLength: 8)
                    values(alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibility)
    }

    /// Value and accuracy text.
    private func values(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(row.valueText)
                .font(.body.weight(.semibold).monospacedDigit())
            if let accuracy = row.accuracyText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if row.isLowConfidence {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                    } else if row.isNotMeasured {
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
