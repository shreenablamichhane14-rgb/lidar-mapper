import SwiftUI
import UIKit

/// The view switcher: a segmented control, or a menu picker at accessibility text sizes so the
/// four labels stay readable. It binds to `model.tab`; the screen reacts with `model.show`.
struct ResultTabPicker: View {
    /// The screen model.
    @ObservedObject var model: ResultModel
    /// Text size (accessibility sizes switch to a menu).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Creates the switcher (explicit, because the private environment property would make
    /// the memberwise initializer private).
    init(model: ResultModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    /// The picker.
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker(Copy.A11y.viewSwitcher, selection: $model.tab) { options }
                    .pickerStyle(.menu)
            } else {
                Picker(Copy.A11y.viewSwitcher, selection: $model.tab) { options }
                    .pickerStyle(.segmented)
            }
        }
        .accessibilityLabel(Copy.A11y.viewSwitcher)
        .accessibilityHint(Copy.A11y.viewSwitcherHint)
    }

    /// One option per tab.
    private var options: some View {
        ForEach(ResultTab.allCases) { option in
            Text(option.title)
                .accessibilityHint(option.accessibilityHint)
                .tag(option)
        }
    }
}

/// The content of the current tab: the 3D viewer, the floor plan canvas or a status card, with
/// the status chip and the missing-area count at the top and the tab's tool buttons at the
/// bottom trailing corner, within reach of the thumb.
struct ResultTabBody: View {
    /// The screen model.
    @ObservedObject var model: ResultModel
    /// Retry from a failed tab (AppShell re-enqueues the project).
    let onRetry: () -> Void

    /// Content with its overlays.
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                ResultChips(model: model)
                    .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                ResultToolButtons(model: model)
                    .padding(12)
            }
    }

    /// The viewer, the plan or the status card of the current tab.
    @ViewBuilder private var content: some View {
        let current = model.tab
        if current == .floorPlan {
            if model.tabState(.floorPlan).isReady, let drawing = model.planDrawing {
                PlanCanvasView(drawing: drawing, selection: .constant(model.selectedElement ?? model.selectedObject?.id),
                               onTap: { hit in model.selectPlanHit(hit) })
            } else if model.tabState(.floorPlan).isReady {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultStatusCard(model: model, target: .floorPlan, onRetry: onRetry)
            }
        } else if model.showsViewer(current) {
            ResultViewerPane(model: model, viewer: model.viewer)
        } else {
            ResultStatusCard(model: model, target: current, onRetry: onRetry)
        }
    }
}

/// The 3D viewer with a spinner while content is built or uploaded.
struct ResultViewerPane: View {
    /// The screen model (tap handling).
    @ObservedObject var model: ResultModel
    /// The viewer (loading state).
    @ObservedObject var viewer: ViewerModel

    /// The viewer container.
    var body: some View {
        ViewerContainer(model: viewer, background: .black, onTap: { hit in model.handleTap(hit) })
            .overlay {
                if viewer.isLoading || model.isBuildingContent {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .background(Color.black)
    }
}

/// The honest state of a tab that cannot show its content: preparing with progress, a reason,
/// or a failure with Try Again; Realistic adds View Simple Model when RoomPlan's model exists.
struct ResultStatusCard: View {
    /// The screen model.
    @ObservedObject var model: ResultModel
    /// The tab the card stands in for.
    let target: ResultTab
    /// Retry from a failed tab.
    let onRetry: () -> Void

    /// Icon, progress, text and actions, centered.
    var body: some View {
        let state = model.tabState(target)
        VStack(spacing: 14) {
            icon(for: state)
            if case .preparing(_, let percent) = state {
                if let percent {
                    ProgressView(value: Double(percent), total: 100)
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                }
            }
            Text(ResultAvailability.chipText(state) ?? Copy.Results.notReady)
                .font(.headline)
                .multilineTextAlignment(.center)
            if case .failed = state, target == .realistic {
                Text(Copy.Errors.textureFailed.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if target == .realistic && model.offersSimpleModel {
                ResultSimpleModelButton(model: model)
            }
            if case .failed = state, model.showsRetry {
                Button(Copy.Errors.tryAgain, action: onRetry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// The large icon of a state.
    private func icon(for state: TabAvailability) -> some View {
        Image(systemName: ResultStatusCard.symbol(for: state))
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// Hourglass while preparing, a warning when failed, information otherwise.
    static func symbol(for state: TabAvailability) -> String {
        switch state {
        case .ready, .preparing: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .unavailable: return "info.circle"
        }
    }
}

/// View Simple Model: RoomPlan's own model in Quick Look, with its note.
struct ResultSimpleModelButton: View {
    /// The screen model.
    @ObservedObject var model: ResultModel

    /// The button, or a spinner with text while the model is prepared.
    var body: some View {
        VStack(spacing: 6) {
            if model.isPreparingSimpleModel {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(Copy.Results.simpleModelPreparing)
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    Task { await model.openSimpleModel() }
                } label: {
                    Label(Copy.Results.simpleModel, systemImage: "cube")
                }
                .buttonStyle(.borderedProminent)
            }
            Text(Copy.Results.simpleModelNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Chips over the content: the current tab's status while it is not ready (Realistic shows
/// its gray model underneath) and the missing-area count on 3D Clean and Raw Scan.
struct ResultChips: View {
    /// The screen model.
    @ObservedObject var model: ResultModel

    /// Up to two chips, stacked.
    var body: some View {
        let current = model.tab
        VStack(alignment: .leading, spacing: 6) {
            if model.showsViewer(current), let text = ResultAvailability.chipText(model.tabState(current)) {
                chip(text, systemImage: ResultStatusCard.symbol(for: model.tabState(current)))
                if current == .realistic && model.offersSimpleModel {
                    if model.isPreparingSimpleModel {
                        chip(Copy.Results.simpleModelPreparing, systemImage: "cube")
                    } else {
                        Button {
                            Task { await model.openSimpleModel() }
                        } label: {
                            chip(Copy.Results.simpleModel, systemImage: "cube")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if (current == .clean || current == .raw) && model.showsViewer(current) && model.missingAreaCount > 0 {
                Button {
                    model.showsLegend = true
                } label: {
                    chip(Copy.Results.missingAreasCount(model.missingAreaCount), systemImage: "square.dashed")
                }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.Results.legend)
            }
        }
    }

    /// One capsule chip.
    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// The tool buttons of the current tab: Display (Realistic, Raw Scan), Hide Furniture (3D Clean),
/// plan Layers (Floor Plan), Legend (3D Clean, Floor Plan, Raw Scan) and Reset View (3D tabs).
struct ResultToolButtons: View {
    /// The screen model.
    @ObservedObject var model: ResultModel
    /// Size of each round button, following the text size.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    /// Creates the buttons (explicit, because the private scaled metric would make the
    /// memberwise initializer private).
    init(model: ResultModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    /// A vertical column of round buttons.
    var body: some View {
        let current = model.tab
        let viewer = model.showsViewer(current)
        VStack(spacing: 10) {
            if viewer && (current == .realistic || current == .raw) { displayMenu(current) }
            if viewer && current == .clean {
                roundButton(model.hideFurniture ? Copy.Viewer.showFurniture : Copy.Viewer.hideFurniture,
                            systemImage: model.hideFurniture ? "sofa.fill" : "sofa") {
                    model.hideFurniture.toggle()
                }
            }
            if current == .floorPlan && model.planDrawing != nil { layersMenu }
            if (viewer && current != .realistic) || (current == .floorPlan && model.planDrawing != nil) {
                roundButton(Copy.Results.legend, systemImage: "list.bullet.rectangle") { model.showsLegend = true }
            }
            if viewer {
                roundButton(Copy.Viewer.resetView, systemImage: "arrow.counterclockwise") { model.viewer.resetView() }
            }
        }
    }

    /// The Display menu: the tab's styles with a check on the one drawn; Photo Realistic is
    /// disabled with `Copy.Results.photoRealisticLater`, Textured is disabled until color exists.
    private func displayMenu(_ current: ResultTab) -> some View {
        Menu {
            ForEach(ResultAvailability.menuStyles(for: current), id: \.self) { style in
                if style == .photoRealistic {
                    Button {} label: {
                        Text(style.title)
                        Text(Copy.Results.photoRealisticLater)
                    }
                    .disabled(true)
                } else if style == .textured && !model.files.hasTexture {
                    Button {} label: {
                        Text(style.title)
                        Text(ResultAvailability.chipText(model.tabState(.realistic)) ?? Copy.Results.noColor)
                    }
                    .disabled(true)
                } else {
                    Button {
                        model.displayStyle = style
                    } label: {
                        if model.effectiveStyle(for: current) == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            }
        } label: {
            roundLabel(Copy.Viewer.displayTitle, systemImage: "paintpalette")
        }
        .accessibilityLabel(Copy.Viewer.displayTitle)
    }

    /// Hide Furniture (shared with 3D Clean) and the floor plan layer toggles; the Furniture
    /// layer is off and disabled while Hide Furniture is on.
    private var layersMenu: some View {
        Menu {
            Toggle(Copy.Viewer.hideFurniture, isOn: $model.hideFurniture)
            Toggle(Copy.FloorPlan.toggleFurniture, isOn: $model.planToggles.furniture)
                .disabled(model.hideFurniture)
            Toggle(Copy.FloorPlan.toggleMeasurements, isOn: $model.planToggles.measurements)
            Toggle(Copy.FloorPlan.toggleRoomNames, isOn: $model.planToggles.roomNames)
            Toggle(Copy.FloorPlan.toggleDoorsWindows, isOn: $model.planToggles.doorsWindows)
            Toggle(Copy.FloorPlan.toggleFixtures, isOn: $model.planToggles.fixtures)
            Toggle(Copy.FloorPlan.toggleGrid, isOn: $model.planToggles.grid)
            Toggle(Copy.FloorPlan.toggleScale, isOn: $model.planToggles.scale)
        } label: {
            roundLabel(Copy.Results.layers, systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel(Copy.Results.layers)
    }

    /// A round icon button whose VoiceOver label is `title`.
    private func roundButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            roundLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// The round icon with a material background, at least 44 points.
    private func roundLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: side, height: side)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
    }
}
