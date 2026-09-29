import SwiftUI

/// The export sheet (docs/ARCHITECTURE.md 10.5, UX_COPY section 14): formats grouped by
/// representation (`Copy.ExportUI.realisticSection`, `cleanSection`, `rawSection`, `planSection`,
/// `dataSection`) with their plain explanations and, when unavailable, the reason; the options
/// that apply to the chosen format; the Export button with "Preparing file..." and "Ready to
/// share"; and the share sheet with the finished file. Errors show `Copy.Errors.exportFailed`
/// with Try Again.
///
/// AppShell presents it with `.sheet(item:)` from the result screen and passes the result
/// screen's `ExportViewState` (Hide Furniture, plan toggles), which every export follows. The
/// sheet brings its own navigation bar with a Done button. Disk work runs off main
/// (`ExportCatalog.loadInputs`, `ExportRunner.run`).
struct ExportSheet: View {
    /// The project to export.
    let projectID: UUID
    /// What the result screen showed when Export was tapped.
    let viewState: ExportViewState

    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// What the project has on disk; nil while loading.
    @State private var inputs: ExportInputs?
    /// Id of the chosen option.
    @State private var selectedID: String?
    /// Options of the next export.
    @State private var settings = ExportSettings()
    /// True while an export runs.
    @State private var isPreparing = false
    /// Drives the share sheet.
    @State private var shareItem: ExportShareItem?
    /// The item the share sheet was opened with (its folder is removed when it closes).
    @State private var presentedItem: ExportShareItem?
    /// Drives the error alert.
    @State private var isErrorShown = false
    /// The running export, cancelled when the sheet goes away.
    @State private var exportTask: Task<Void, Never>?

    /// Creates the sheet for a project and the result screen's view state.
    init(projectID: UUID, viewState: ExportViewState) {
        self.projectID = projectID
        self.viewState = viewState
    }

    /// The list in a navigation stack, the Export bar, the share sheet and the error alert.
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Copy.Export.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.ExportUI.done) { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { exportBar }
        }
        .task { await loadInputs() }
        .sheet(item: $shareItem, onDismiss: { shareDismissed() }) { item in
            ActivityShareSheet(items: [item.fileURL], stagingFolder: item.stagingFolder) {
                shareItem = nil
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
        .alert(Copy.Errors.exportFailed.title, isPresented: $isErrorShown) {
            Button(Copy.Errors.tryAgain) { startExport() }
            Button(Copy.Errors.ok, role: .cancel) {}
        } message: {
            Text(Copy.Errors.exportFailed.body)
        }
        .onDisappear { exportTask?.cancel() }
    }

    // MARK: - Content

    /// The option list once the inputs are known, a spinner before.
    @ViewBuilder private var content: some View {
        if let inputs {
            optionList(inputs)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Subtitle, one section per representation, then the options of the chosen format.
    private func optionList(_ inputs: ExportInputs) -> some View {
        let options = ExportCatalog.options(for: inputs)
        return List {
            Section {
                Text(Copy.Export.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(ExportRepresentation.allCases) { representation in
                let group = options.filter { $0.representation == representation }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { option in
                            optionRow(option, inputs: inputs)
                        }
                    } header: {
                        Text(ExportCatalog.sectionTitle(representation))
                    }
                }
            }
            optionsSection
        }
        .listStyle(.insetGrouped)
    }

    /// One format: label, explanation, and the reason or the simplified note; a checkmark when chosen.
    private func optionRow(_ option: ExportOption, inputs: ExportInputs) -> some View {
        let text = ExportCatalog.label(for: option.format)
        let isSelected = option.id == selectedID
        let simplified = ExportCatalog.isSimplified(option, inputs: inputs)
        return Button {
            selectedID = option.id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text.label)
                        .font(.body)
                        .foregroundStyle(option.isAvailable ? Color.primary : Color.secondary)
                    Text(text.detail)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    rowNote(option, simplified: simplified)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable || isPreparing)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// The unavailability reason, or the simplified-mesh note for big raw text exports.
    @ViewBuilder private func rowNote(_ option: ExportOption, simplified: Bool) -> some View {
        if let reason = option.reason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Color.orange)
        } else if simplified {
            Text(Copy.ExportUI.simplifiedNote)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Options

    /// The options that apply to the chosen format, when there are any.
    @ViewBuilder private var optionsSection: some View {
        if let option = selectedOption, option.isAvailable, hasControls(for: option) {
            Section {
                optionControls(for: option)
            } header: {
                Text(Copy.ExportUI.optionsSection)
            }
        }
    }

    /// True when the format has at least one option.
    private func hasControls(for option: ExportOption) -> Bool {
        option.representation != .raw
    }

    /// Include textures (realistic), Include hidden objects (clean and plan), Include
    /// measurements (plan and data), Units (plan) and Paper Size (PDF).
    @ViewBuilder private func optionControls(for option: ExportOption) -> some View {
        let representation = option.representation
        if representation == .realistic {
            Toggle(Copy.Export.includeTextures, isOn: $settings.includeTextures)
        }
        if representation == .clean || representation == .floorPlan {
            Toggle(Copy.Export.includeHidden, isOn: $settings.includeHidden)
        }
        if representation == .floorPlan || representation == .data {
            Toggle(Copy.Export.includeMeasurements, isOn: $settings.includeMeasurements)
        }
        if representation == .floorPlan {
            unitsPicker(title: option.format == .dxf ? Copy.ExportUI.labelUnits : Copy.Export.units)
        }
        if option.format == .pdf {
            paperPicker
        }
    }

    /// Units of plan labels: the app setting, feet and inches, or metric. DXF calls it "Label
    /// units", because its drawing is always in millimeters.
    private func unitsPicker(title: String) -> some View {
        Picker(title, selection: $settings.unitsOverride) {
            Text(Copy.ExportUI.unitsApp).tag(UnitSystem?.none)
            Text(Copy.Settings.unitsImperial).tag(UnitSystem?.some(.imperial))
            Text(Copy.Settings.unitsMetric).tag(UnitSystem?.some(.metric))
        }
    }

    /// PDF paper size.
    private var paperPicker: some View {
        Picker(Copy.ExportUI.paper, selection: $settings.paper) {
            Text(Copy.ExportUI.letter).tag(PDFPlanWriter.Paper.usLetter)
            Text(Copy.ExportUI.a4).tag(PDFPlanWriter.Paper.a4)
        }
    }

    // MARK: - Export bar

    /// Status line and the Export button, pinned to the bottom.
    private var exportBar: some View {
        VStack(spacing: 10) {
            statusLine
            Button {
                startExport()
            } label: {
                Text(Copy.Export.button)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canExport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// "Preparing file..." with a spinner while exporting, "Ready to share" while sharing.
    @ViewBuilder private var statusLine: some View {
        if isPreparing {
            HStack(spacing: 8) {
                ProgressView()
                Text(Copy.Export.preparing)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if shareItem != nil {
            Text(Copy.Export.ready)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State

    /// The chosen option with its current availability.
    private var selectedOption: ExportOption? {
        guard let inputs, let selectedID else { return nil }
        return ExportCatalog.options(for: inputs).first { $0.id == selectedID }
    }

    /// True when the chosen option can be exported now.
    private var canExport: Bool {
        !isPreparing && selectedOption?.isAvailable == true
    }

    /// Reads what the project has (off main) and picks the first available option. The PDF
    /// paper starts at A4 when the app's units are metric (US Letter otherwise).
    private func loadInputs() async {
        guard inputs == nil else { return }
        settings.paper = ExportSettings.defaultPaper(for: UnitPreferences.load().system)
        let id = projectID
        let loaded = await Task.detached(priority: .userInitiated) {
            ExportCatalog.loadInputs(projectID: id)
        }.value
        let resolved = loaded ?? ExportInputs()
        inputs = resolved
        if selectedID == nil {
            selectedID = ExportCatalog.options(for: resolved).first { $0.isAvailable }?.id
        }
    }

    /// Runs the chosen export off main, then opens the share sheet; errors show the alert.
    private func startExport() {
        guard let option = selectedOption, option.isAvailable, !isPreparing else { return }
        isPreparing = true
        shareItem = nil
        let exportSettings = settings
        let state = viewState
        let id = projectID
        exportTask = Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try ProjectStore.package(for: id)
                }.value
                let prefs = UnitPreferences.load()
                let url = try await ExportRunner.run(option, settings: exportSettings, viewState: state, projectID: id,
                                                     package: package, prefs: prefs)
                isPreparing = false
                let folder = url.deletingLastPathComponent()
                if Task.isCancelled {
                    ExportRunner.removeStagingFolderLater(folder)
                    return
                }
                let item = ExportShareItem(fileURL: url, stagingFolder: folder)
                presentedItem = item
                shareItem = item
            } catch is CancellationError {
                isPreparing = false
            } catch {
                isPreparing = false
                isErrorShown = true
            }
        }
    }

    /// The share sheet closed: its staging folder goes (the activity handler may already have
    /// removed it; removal is idempotent).
    private func shareDismissed() {
        if let item = presentedItem {
            ExportRunner.removeStagingFolderLater(item.stagingFolder)
        }
        presentedItem = nil
        shareItem = nil
    }
}
