import SwiftUI

/// Bottom bar: segmented tool picker, hint, live value with accuracy (or Copy.Measure.lowConfidence),
/// snap tag, snapping toggle, Undo (`Copy.Measure.undoPoint`), Finish Area (area with 3 or more points),
/// the list button (`Copy.Results.dimensionsTitle`), and Done (`Copy.Scanning.done`, calls `onDone`).
/// Everything sits at the bottom, within reach of the thumb. It presents the measurement list
/// (`model.showsList`), the Delete All confirmation (`model.showsDeleteAllConfirmation`) and the
/// save error (`model.errorText`).
struct MeasureToolBar: View {
    /// The measuring state.
    @ObservedObject var model: MeasureToolModel
    /// Leaves measure mode.
    let onDone: () -> Void
    /// Text size (accessibility sizes use a menu picker and stacked buttons).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A bar for `model`; `onDone` ends measure mode.
    init(model: MeasureToolModel, onDone: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self.onDone = onDone
    }

    /// Status lines, the picker and the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Toggle(Copy.Measure.snapToggle, isOn: $model.snappingEnabled)
                .font(.subheadline)
            toolPicker
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $model.showsList) {
            listSheet
        }
        .confirmationDialog(Copy.MeasureTool.deleteAllTitle, isPresented: $model.showsDeleteAllConfirmation,
                            titleVisibility: .visible) {
            Button(Copy.MeasureTool.deleteAll, role: .destructive) { model.deleteAll() }
            Button(Copy.Project.cancel, role: .cancel) {}
        } message: {
            Text(Copy.MeasureTool.deleteAllBody)
        }
        .alert(Copy.Errors.saveFailed.title, isPresented: errorShown) {
            Button(Copy.Errors.ok, role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? Copy.Errors.saveFailed.body)
        }
    }

    /// Snap tag, hint, and the live value with its accuracy.
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snap = model.snapText {
                Text(snap)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
            Text(model.hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let value = model.draft.value {
                liveValue(value)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Value and accuracy of the draft (the low-confidence text replaces the accuracy).
    private func liveValue(_ value: MeasuredValue) -> some View {
        let kind = model.draft.kind.measurementKind
        let text = MeasureToolPresentation.label(value, kind: kind, prefs: model.prefs,
                                                 lowConfidence: model.draftIsLowConfidence)
        return VStack(alignment: .leading, spacing: 2) {
            Text(text.value)
                .font(.title3.weight(.semibold).monospacedDigit())
            if let accuracy = text.accuracy {
                HStack(spacing: 4) {
                    if model.draftIsLowConfidence {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                    }
                    Text(accuracy)
                }
                .font(.caption)
                .foregroundStyle(model.draftIsLowConfidence ? Color.orange : Color.secondary)
            }
        }
    }

    /// The five tools: segmented, or a menu at accessibility text sizes.
    @ViewBuilder private var toolPicker: some View {
        if typeSize.isAccessibilitySize {
            Picker(Copy.Measure.title, selection: $model.tool) { toolOptions }
                .pickerStyle(.menu)
        } else {
            Picker(Copy.Measure.title, selection: $model.tool) { toolOptions }
                .pickerStyle(.segmented)
        }
    }

    /// One option per tool.
    private var toolOptions: some View {
        ForEach(MeasureToolKind.allCases) { kind in
            Text(MeasureToolPresentation.title(of: kind))
                .tag(kind)
        }
    }

    /// Undo, Finish Area (area tool with 3 or more points), the list, Done.
    @ViewBuilder private var buttons: some View {
        Button(Copy.Measure.undoPoint) { model.undoPoint() }
            .buttonStyle(.bordered)
            .disabled(!model.canUndo)
        if model.tool == .area && model.draft.points.count >= 3 {
            Button(Copy.MeasureTool.finishArea) { model.finishArea() }
                .buttonStyle(.borderedProminent)
        }
        Button(Copy.Results.dimensionsTitle) { model.showsList = true }
            .buttonStyle(.bordered)
        Spacer(minLength: 0)
        Button(Copy.Scanning.done) { onDone() }
            .buttonStyle(.borderedProminent)
    }

    /// The measurement list with Rename, Delete and Delete All, in a sheet with Done.
    private var listSheet: some View {
        NavigationStack {
            MeasureToolList(rows: model.rows,
                            onRename: { id, name in model.rename(id, to: name) },
                            onDelete: { id in model.delete(id) },
                            onDeleteAll: { model.deleteAll() },
                            onClose: { model.showsList = false })
                .navigationTitle(Copy.Results.dimensionsTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .alert(Copy.Errors.saveFailed.title, isPresented: errorShown) {
            Button(Copy.Errors.ok, role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? Copy.Errors.saveFailed.body)
        }
    }

    /// True while a save error waits to be shown.
    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorText != nil }, set: { shown in
            if !shown { model.errorText = nil }
        })
    }
}
