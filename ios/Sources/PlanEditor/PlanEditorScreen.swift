import SwiftUI
import UIKit

/// Full screen. Top: Done Editing, the level menu (more than one level), Undo, Redo, More (snapping
/// toggle, Reset to Scan, the Plan Items menu for VoiceOver). Middle: the canvas. Bottom: the hint or
/// snap line, the inspector of the selection or the add bar, `Copy.FloorPlan.editsSafe`. Prompts as
/// sheets (typed lengths, names, text, symbols, categories) and alerts (reset, messages).
///
/// The inspector and add bar sit at the bottom, within thumb reach, so editing works one-handed;
/// every command is a labeled button, and the Plan Items menu selects any element for VoiceOver.
struct PlanEditorScreen: View {
    /// The editing session.
    @StateObject private var model: PlanEditorModel
    /// Closes the editor (Done Editing).
    private let onDone: () -> Void

    /// An editor for one project; `onDone` closes it.
    init(projectID: UUID, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PlanEditorModel(projectID: projectID))
        self.onDone = onDone
    }

    /// Bars, canvas, inspector, sheets and alerts.
    var body: some View {
        VStack(spacing: 0) {
            topBar
                .alert(Copy.FloorPlan.resetTitle, isPresented: $model.isResetConfirmationShown) {
                    Button(Copy.FloorPlan.resetConfirm, role: .destructive) {
                        model.submit(.resetConfirmation, text: "")
                    }
                    Button(Copy.Project.cancel, role: .cancel) { model.prompt = nil }
                } message: {
                    Text(Copy.FloorPlan.resetBody)
                }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomPanel
        }
        .background(Color(uiColor: .systemBackground))
        .task { await model.load() }
        .sheet(item: $model.sheetPrompt) { prompt in
            PlanEditorPromptSheet(prompt: prompt, model: model)
        }
        .alert(model.message ?? "", isPresented: $model.isMessageShown) {
            Button(Copy.Errors.ok) { model.message = nil }
        }
    }

    // MARK: - Top bar

    /// Done Editing, the level menu, Undo, Redo and More.
    private var topBar: some View {
        HStack(spacing: 16) {
            Button(Copy.FloorPlan.doneEditing) { onDone() }
                .fontWeight(.semibold)
            Spacer(minLength: 8)
            if model.levelTitles.count > 1 { levelMenu }
            Button {
                try? model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityLabel(Copy.FloorPlan.undo)
            Button {
                try? model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .accessibilityLabel(Copy.FloorPlan.redo)
            moreMenu
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The level menu of a plan with several floors.
    private var levelMenu: some View {
        let titles = model.levelTitles
        let current = titles.indices.contains(model.levelIndex) ? titles[model.levelIndex] : ""
        return Menu {
            ForEach(Array(titles.enumerated()), id: \.offset) { entry in
                Button(entry.element) { model.selectLevel(entry.offset) }
            }
        } label: {
            Label(current, systemImage: "square.stack.3d.up")
        }
    }

    /// More: snapping toggle, Reset View, Plan Items (VoiceOver selection) and Reset to Scan.
    private var moreMenu: some View {
        Menu {
            Toggle(Copy.PlanEditor.snapping, isOn: $model.snappingEnabled)
            Button(Copy.Viewer.resetView) { model.requestViewReset() }
            Menu(Copy.PlanEditor.elements) {
                ForEach(model.itemList) { item in
                    Button(item.title) { model.selection = item.id }
                }
            }
            Button(Copy.FloorPlan.resetToScan, role: .destructive) {
                model.promptError = nil
                model.prompt = .resetConfirmation
            }
            .disabled(!model.isLoaded)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Copy.A11y.more)
    }

    // MARK: - Content

    /// The canvas, a progress view while loading, or the empty state without a plan.
    @ViewBuilder private var content: some View {
        if model.loadFailed {
            VStack(spacing: 8) {
                Text(Copy.Empty.noFloorPlan.title)
                    .font(.headline)
                Text(Copy.Empty.noFloorPlan.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        } else if !model.isLoaded {
            ProgressView()
        } else {
            PlanEditorCanvas(model: model)
        }
    }

    // MARK: - Bottom panel

    /// The hint or snap line, the tool bar, inspector or add bar, and the raw-safety note.
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let line = model.statusLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.tool == .select {
                inspector
            } else {
                toolBar
            }
            Text(Copy.FloorPlan.editsSafe)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!model.isLoaded)
    }

    /// Commit and cancel buttons of an active tool (Merge Rooms commits the tapped rooms).
    private var toolBar: some View {
        HStack(spacing: 12) {
            if case .mergeRooms = model.tool {
                Button(Copy.FloorPlan.mergeRooms) { model.commitMerge() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.mergeSelection.isEmpty)
            }
            Button(Copy.Project.cancel) { model.cancelTool() }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
    }

    /// The selection's title with its commands, or the add bar when nothing is selected.
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.selectedTitle {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.commands) { command in
                        commandButton(command)
                    }
                }
            }
        }
    }

    /// One inspector or add bar button; deletions are destructive.
    private func commandButton(_ command: PlanEditorCommand) -> some View {
        let title = PlanEditorPresentation.title(command, item: model.selectedItem)
        let destructive = PlanEditorScreen.isDestructive(command)
        let role: ButtonRole? = destructive ? ButtonRole.destructive : nil
        return Button(role: role) {
            model.run(command)
        } label: {
            Text(title)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
    }

    /// True for the delete commands.
    static func isDestructive(_ command: PlanEditorCommand) -> Bool {
        switch command {
        case .deleteWall, .deleteOpening, .deleteFixture, .deleteAnnotation, .deleteMeasurement: return true
        default: return false
        }
    }
}
