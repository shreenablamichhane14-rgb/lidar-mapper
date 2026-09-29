import SwiftUI
import UIKit

/// Processing view (Copy.Processing.title, stage text, progress bar, time left,
/// Copy.Processing.keepOpen) or the viewer with the Textured / Solid Color control, Show Box,
/// the size panel with confidence and Copy.Measure.disclaimer, notes, Export and Retry.
/// Observes ProcessingRunner.shared.states[projectID], PhotogrammetryMonitor.shared and
/// `.mapperManifestDidChange` (through its model); tapping the title offers Rename.
///
/// Layout for one-handed use: the model fills the top, the controls, the size panel and Export
/// sit at the bottom. AppShell pushes it inside a NavigationStack (the title and its Rename menu
/// are a principal toolbar item) and wires Export and Retry.
struct ObjectResultScreen: View {
    /// The screen model, owned by the screen.
    @StateObject private var model: ObjectResultModel
    /// Opens the export sheet (AppShell).
    private let onExport: () -> Void
    /// Re-enqueues processing (AppShell's `ProcessingPlans.retry`).
    private let onRetry: () -> Void
    /// Rename alert state.
    @State private var isRenameShown = false
    @State private var renameText = ""
    @State private var renameFailed = false

    /// Largest share of the screen height the bottom panel may take.
    static let maxPanelFraction: CGFloat = 0.5
    /// Smallest height of the 3D view, points.
    static let minViewerHeight: CGFloat = 180

    /// Creates the screen for a project.
    init(projectID: UUID, onExport: @escaping () -> Void, onRetry: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ObjectResultModel(projectID: projectID))
        self.onExport = onExport
        self.onRetry = onRetry
    }

    /// The screen with its title menu, haptic and alerts.
    var body: some View {
        mainContent
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { titleMenu }
            .task { await model.load() }
            .onAppear { model.refreshUnits() }
            .sensoryFeedback(.success, trigger: model.finishedCount)
            .alert(Copy.Project.renameTitle, isPresented: $isRenameShown) {
                TextField(Copy.HomeUI.namePlaceholder, text: $renameText)
                    .textInputAutocapitalization(.words)
                Button(Copy.Errors.ok) { commitRename() }
                Button(Copy.Project.cancel, role: .cancel) {}
            }
            .alert(Copy.Errors.saveFailed.title, isPresented: $renameFailed) {
                Button(Copy.Errors.ok, role: .cancel) {}
            } message: {
                Text(Copy.Errors.saveFailed.body)
            }
    }

    // MARK: - Content

    /// Spinner, processing view, the model, the failure or the empty state.
    @ViewBuilder private var mainContent: some View {
        if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.availability {
            case .processing(let text, let percent, let remaining):
                processingView(text: text, percent: percent, remaining: remaining)
            case .ready:
                readyView
            case .failed(let reason):
                messageView(title: Copy.Errors.processingFailed.title, detail: reason, symbol: "exclamationmark.triangle",
                            showsRetry: true)
            case .noObject:
                messageView(title: Copy.ObjectUI.noObject.title, detail: Copy.ObjectUI.noObject.body, symbol: "cube",
                            showsRetry: false)
            }
        }
    }

    /// Title, stage text, progress bar (or a spinner without a percent), time left, the heat
    /// pause and Keep Mapper open, read by VoiceOver as one element. No viewer content exists
    /// while this shows.
    private func processingView(text: String, percent: Int?, remaining: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(Copy.Processing.title)
                .font(.title2.weight(.bold))
            if let percent {
                ProgressView(value: Double(percent), total: 100)
                    .frame(maxWidth: 280)
                Text(text)
                    .font(.headline)
                Text(Copy.Quality.percent(percent))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(text)
                    .font(.headline)
            }
            if let remaining {
                Text(remaining)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.isPausedForHeat {
                Text(Copy.Errors.tooHot.title)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Text(Copy.Processing.keepOpen)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The failure (with Try Again) or the empty state.
    private func messageView(title: String, detail: String, symbol: String, showsRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if showsRetry {
                Button(action: onRetry) {
                    Text(Copy.Errors.tryAgain)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ready

    /// Retry banner, the model with Reset View, and the bottom panel.
    private var readyView: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if model.showsRetry { retryBanner }
                ZStack(alignment: .bottomTrailing) {
                    ViewerContainer(model: model.viewer, background: UIColor.systemBackground)
                    Button {
                        model.viewer.resetView()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Copy.Viewer.resetView)
                    .padding(12)
                }
                .frame(minHeight: ObjectResultScreen.minViewerHeight)
                ObjectResultPanel(model: model, maxHeight: proxy.size.height * ObjectResultScreen.maxPanelFraction,
                                  onExport: onExport)
            }
        }
    }

    /// Why Retry shows, and Try Again.
    private var retryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(Copy.Errors.processingFailed.title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(Copy.Errors.tryAgain, action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Title and rename

    /// The project name as a menu with Rename.
    @ToolbarContentBuilder private var titleMenu: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Button {
                    beginRename()
                } label: {
                    Label(Copy.Project.rename, systemImage: "pencil")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.primary)
            }
            .accessibilityLabel(model.title)
            .accessibilityHint(Copy.Project.renameTitle)
        }
    }

    /// Shows the rename alert with the current name.
    private func beginRename() {
        renameText = model.title
        isRenameShown = true
    }

    /// Renames through the model; a failure shows the save alert.
    private func commitRename() {
        do {
            try model.rename(to: renameText)
        } catch {
            ObjectPresentation.log("rename failed (\(error))")
            renameFailed = true
        }
    }
}

/// The bottom panel of a ready object: Textured / Solid Color, Show Box, the size rows with
/// their confidence, the disclaimer, the notes and Export.
private struct ObjectResultPanel: View {
    /// The screen model.
    @ObservedObject var model: ObjectResultModel
    /// Largest height of the scrolling part.
    let maxHeight: CGFloat
    /// Export (AppShell).
    let onExport: () -> Void

    /// Controls, the scrolling size panel and Export on the bar material.
    var body: some View {
        VStack(spacing: 10) {
            if model.canShowTextured {
                Picker(Copy.Viewer.displayTitle, selection: texturedBinding) {
                    Text(Copy.Viewer.textured).tag(true)
                    Text(Copy.Viewer.solidColor).tag(false)
                }
                .pickerStyle(.segmented)
            }
            Toggle(Copy.Viewer.boundingBox, isOn: boxBinding)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                sizePanel
            }
            .frame(maxHeight: Swift.max(120, maxHeight - 140))
            Button(action: onExport) {
                Label(Copy.Viewer.export, systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Textured on or off through the model (only toggles layers).
    private var texturedBinding: Binding<Bool> {
        Binding(get: { model.showsTextured }, set: { on in model.setTextured(on) })
    }

    /// Show Box through the model.
    private var boxBinding: Binding<Bool> {
        Binding(get: { model.showsBox }, set: { on in model.setBoxVisible(on) })
    }

    /// Size heading, the five rows, the disclaimer and the notes.
    private var sizePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.ObjectUI.sizeSection)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.rows) { row in
                rowView(row)
                Divider()
            }
            Text(Copy.Measure.disclaimer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One size row: name (and the Estimated note), value and its confidence; one VoiceOver
    /// element with MeasureDisplay's spoken text.
    private func rowView(_ row: ObjectDimensionRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline)
                if let note = row.note {
                    Text(note)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.valueText)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
                if let accuracy = row.accuracyText {
                    HStack(spacing: 4) {
                        if row.isLowConfidence {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                        }
                        Text(accuracy)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(row.isLowConfidence ? Color.orange : Color.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibility)
    }
}
