import SwiftUI
import QuickLook

/// While `ResultAvailability.showsProcessingView` is true the screen shows the processing view
/// instead of the tabs (D20): `Copy.Processing.title`, the current step's text (`stepText`), a
/// progress bar and `Copy.Processing.keepOpen`; then the tabs appear with chips for the steps still
/// running. A demo project, or a relaunched project whose job is not queued, shows the tabs at once,
/// each tab deciding from its files. `onRetry` shows as `Copy.Errors.tryAgain` when
/// `ResultAvailability.showsRetry` is true; tapping the title offers Rename (`Copy.Project.rename`,
/// `renameTitle`).
///
/// Layout for one-handed use: the content fills the screen, the tool buttons sit at its bottom
/// trailing corner, and the object card, the measurements, the view switcher and Export sit in
/// the bottom bar. AppShell pushes it in a NavigationStack and presents ExportUI from `onExport`.
struct ResultScreen: View {
    /// The screen model, owned by the screen.
    @StateObject private var model: ResultModel
    /// Opens the export sheet with the current view state (AppShell).
    private let onExport: (ExportViewState) -> Void
    /// Re-enqueues processing (AppShell's `ProcessingPlans.retry`).
    private let onRetry: () -> Void
    /// Rename alert state.
    @State private var isRenameShown = false
    @State private var renameText = ""
    @State private var renameFailed = false
    /// Whether the measurement list is open.
    @State private var isPanelExpanded = false

    /// Creates the screen for a project.
    init(projectID: UUID, onExport: @escaping (ExportViewState) -> Void, onRetry: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ResultModel(projectID: projectID))
        self.onExport = onExport
        self.onRetry = onRetry
    }

    /// The screen with its title menu, sheets and alerts.
    var body: some View {
        mainContent
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { titleMenu }
            .task { await model.load() }
            .onAppear { model.refreshUnits() }
            .onChange(of: model.tab) { _, newTab in
                Task { await model.show(newTab) }
            }
            .onChange(of: model.selectedElement) { _, element in
                if element != nil { isPanelExpanded = true }
            }
            .sheet(isPresented: $model.showsLegend) {
                ResultLegendSheet(onClose: { model.showsLegend = false })
                    .presentationDetents([.medium, .large])
            }
            .quickLookPreview($model.quickLookURL)
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
            .alert(Copy.Errors.generic.title, isPresented: $model.simpleModelFailed) {
                Button(Copy.Errors.ok, role: .cancel) {}
            } message: {
                Text(Copy.Errors.generic.body)
            }
    }

    // MARK: - Content

    /// Spinner, error, processing view or the tabs.
    @ViewBuilder private var mainContent: some View {
        if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loadFailed {
            failedView
        } else if model.showsProcessingView {
            ResultProcessingView(processing: model.processing)
        } else {
            tabsView
        }
    }

    /// Retry banner, the tab content and the bottom bar. The open measurement list takes at
    /// most `maxListFraction` of the screen and the content keeps `minContentHeight`, so large
    /// accessibility text sizes never collapse the model or plan.
    private var tabsView: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if model.showsRetry { retryBanner }
                ResultTabBody(model: model, onRetry: onRetry)
                    .frame(minHeight: ResultScreen.minContentHeight)
                bottomBar(maxListHeight: proxy.size.height * ResultScreen.maxListFraction)
            }
        }
    }

    /// Largest share of the screen height the open measurement list may take.
    static let maxListFraction: CGFloat = 0.35
    /// Smallest height of the 3D view or plan above the bottom bar, points.
    static let minContentHeight: CGFloat = 160

    /// Object card, measurements, view switcher and Export, on the system bar material.
    private func bottomBar(maxListHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            if let object = model.selectedObject {
                ResultObjectCard(object: object, rows: model.objectRows, prefs: model.prefs,
                                 onClose: { model.clearSelection() })
            }
            ResultDimensionsPanel(rows: model.visibleRows, isFiltered: model.selectedElement != nil, prefs: model.prefs,
                                  emptyText: dimensionsEmptyText, note: ResultAvailability.degradedNote(model.degraded),
                                  isExpanded: $isPanelExpanded, maxListHeight: maxListHeight,
                                  onShowAll: { model.clearSelection() })
            HStack(spacing: 12) {
                ResultTabPicker(model: model)
                Button {
                    onExport(model.exportViewState)
                } label: {
                    Label(Copy.Viewer.export, systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Copy.Viewer.export)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    /// Why the measurement list is empty: no walls, the clean model's chip, or not ready.
    private var dimensionsEmptyText: String {
        if model.degraded == .roomPlanFailed { return Copy.Results.noWalls }
        return ResultAvailability.chipText(model.tabState(.clean)) ?? Copy.Results.notReady
    }

    /// Retry: why, and Try Again.
    private var retryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(ResultAvailability.retryMessage(processing: model.processing, availability: model.availability))
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

    /// The project could not be read.
    private var failedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Copy.Errors.generic.title)
                .font(.headline)
            Text(Copy.Errors.generic.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .accessibilityHint(Copy.Results.titleHint)
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
            LogStore.shared.write("rename failed (\(error))", category: ResultLoader.logCategory)
            renameFailed = true
        }
    }
}

/// The processing view (D20) shown until the floor plan exists: title, current step with its
/// progress (or Waiting to start while queued), the heat pause, and Keep Mapper open.
struct ResultProcessingView: View {
    /// The project's processing state.
    let processing: ProjectProcessingState

    /// Centered title, progress and notes, read by VoiceOver as one element.
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(Copy.Processing.title)
                .font(.title2.weight(.bold))
            if processing.isRunning, let step = processing.currentStep {
                let percent = ResultAvailability.percent(step, processing) ?? 0
                ProgressView(value: Double(percent), total: 100)
                    .frame(maxWidth: 280)
                Text(Copy.Results.stepProgress(ResultAvailability.stepText(step), percent: percent))
                    .font(.headline)
            } else {
                ProgressView()
                Text(processing.isRunning ? Copy.Processing.stepShape : Copy.Results.waiting)
                    .font(.headline)
            }
            if processing.isPausedForHeat {
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
}
