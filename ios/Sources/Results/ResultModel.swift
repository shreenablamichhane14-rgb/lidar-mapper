import Foundation
import Combine

/// Inputs of the plan drawing; the drawing is rebuilt only when they change.
struct ResultPlanInputs: Equatable, Sendable {
    /// Stamps of plan.json and the edit log.
    var planStamp: String
    /// Effective toggles (the Furniture layer follows Hide Furniture).
    var toggles: PlanToggles
    /// Units of the labels.
    var prefs: UnitPreferences
    /// Project name (the drawing's name).
    var name: String
    /// Room titles.
    var titles: [ElementID: String]
}

/// Main actor. State of the result screen (docs/MODULES.md 3.26, ARCHITECTURE 10.4): the tab,
/// display style, Hide Furniture, plan toggles, per-tab availability from the files on disk and
/// `ProcessingRunner.shared.states[projectID]`, the dimension rows, the selection and the
/// object card. Disk reads and content builds run in detached tasks (ResultModel+Loading.swift);
/// the model reloads on `.mapperManifestDidChange`, `.mapperEditsDidChange` and structural
/// runner changes, and rebuilds only content whose source files changed. Every write to a
/// `private(set)` property happens in this file.
@MainActor final class ResultModel: ObservableObject {
    @Published var tab: ResultTab = .clean
    /// Realistic and Raw Scan style; a change rebuilds the current tab's content.
    @Published var displayStyle: ViewerDisplayStyle = .textured {
        didSet { displayStyleChanged(from: oldValue) }
    }
    /// Hide Furniture: toggles the furniture and occluded layers (never rebuilds) and the plan's
    /// Furniture layer.
    @Published var hideFurniture: Bool = false {
        didSet { hideFurnitureChanged(from: oldValue) }
    }
    /// Floor Plan layer toggles; a change redraws the plan.
    @Published var planToggles: PlanToggles = .standard {
        didSet { if oldValue != planToggles { scheduleDrawing() } }
    }
    /// Per-tab availability, every dimension row of the project, the current plan drawing and
    /// the object whose card is open.
    @Published private(set) var availability: [ResultTab: TabAvailability] = [:]
    @Published private(set) var dimensionRows: [DimensionRow] = []
    @Published private(set) var planDrawing: PlanDrawingResult?
    @Published private(set) var selectedObject: DetectedObject?
    /// Selected wall, door, window or opening (3D Clean tap or Floor Plan tap); nil shows all rows.
    @Published private(set) var selectedElement: ElementID?
    /// MeasureCore objectRows of selectedObject.
    @Published private(set) var objectRows: [DimensionRow] = []
    /// Missing (unscanned) areas of every room, the legend sheet, the Quick Look file of the
    /// simple model and the project name.
    @Published private(set) var missingAreaCount: Int = 0
    @Published var showsLegend: Bool = false
    @Published var quickLookURL: URL?
    @Published private(set) var title: String = ""
    /// The 3D viewer shared by Realistic, 3D Clean and Raw Scan.
    let viewer: ViewerModel

    /// The project shown.
    let projectID: UUID
    /// What exists on disk (from the last snapshot).
    @Published private(set) var files = ResultFiles()
    /// The project's processing state (mirrors `ProcessingRunner.shared`).
    @Published private(set) var processing = ProjectProcessingState()
    /// Project status from the manifest.
    @Published private(set) var status: ProjectStatus = .ready
    /// Capture streams (roomlog.json, with the RoomPlan override).
    @Published private(set) var degraded: DegradedMode = .allGood
    /// Units of every number on the screen.
    @Published private(set) var prefs: UnitPreferences = .standard
    /// False until the first snapshot was read (the screen shows a spinner).
    @Published private(set) var hasLoaded = false
    /// True when the project could not be read at all.
    @Published private(set) var loadFailed = false
    /// True while RoomPlan's model is exported for Quick Look.
    @Published private(set) var isPreparingSimpleModel = false
    /// Set when the simple model could not be made (the screen shows an alert).
    @Published var simpleModelFailed = false
    /// True while a tab's content is built off main.
    @Published private(set) var isBuildingContent = false

    // State shared with ResultModel+Loading.swift (internal because extensions in other files
    // cannot see private members; nothing outside the Results module uses it).

    /// The last snapshot read from disk.
    var snapshot: ResultLoadSnapshot?
    /// True once PackageCheck ran for this screen.
    var didVerify = false
    /// True while a snapshot read runs; `reloadRequested` asks for one more.
    var isReloading = false
    var reloadRequested = false
    /// True once the user switched tabs (the initial tab is then never changed for them).
    var userChoseTab = false
    /// True once the initial tab was picked.
    var initialTabChosen = false
    /// Content key currently loaded in the viewer.
    var loadedKey: String?
    /// Built content per tab with its key (dropped on a memory warning, except the current tab).
    var contentCache: [ResultTab: (key: String, content: ViewerContent)] = [:]
    /// 3D Clean parts without selection, for cheap highlight rebuilds.
    var cleanBaseCache: (key: String, parts: [ViewerPart])?
    /// Content builds running now, and the keys being built (a second request for the same
    /// key waits for the first instead of building twice).
    var buildsInFlight = 0
    var buildingKeys: Set<String> = []
    /// The tab `show` last handled (selection and logging follow tab changes).
    var lastShownTab: ResultTab?
    /// Inputs of the current plan drawing and the generation of the latest drawing request.
    var drawingInputs: ResultPlanInputs?
    var drawingGeneration = 0
    /// Notification and runner subscriptions.
    var cancellables: Set<AnyCancellable> = []

    /// Creates the model for a project; call `load()` when the screen appears.
    init(projectID: UUID) {
        self.projectID = projectID
        self.viewer = ViewerModel()
        processing = ProcessingRunner.shared.state(for: projectID)
        observe()
    }

    // MARK: - Derived state

    /// The availability of `tab` (not ready until computed).
    func tabState(_ tab: ResultTab) -> TabAvailability {
        availability[tab] ?? .unavailable(reason: Copy.Results.notReady)
    }

    /// True while the processing view replaces the tabs (D20).
    var showsProcessingView: Bool {
        hasLoaded && ResultAvailability.showsProcessingView(files: files, processing: processing)
    }

    /// True when Retry shows.
    var showsRetry: Bool {
        ResultAvailability.showsRetry(status: status, processing: processing)
    }

    /// True when `target` draws the 3D viewer now: Realistic whenever a textured or view mesh
    /// exists (gray with a chip until color is added), 3D Clean and Raw Scan when ready.
    func showsViewer(_ target: ResultTab) -> Bool {
        switch target {
        case .realistic: return files.hasTexture || files.hasMeshView
        case .clean, .raw: return tabState(target).isReady
        case .floorPlan: return false
        }
    }

    /// True when Realistic offers RoomPlan's own model in Quick Look.
    var offersSimpleModel: Bool {
        files.hasCapturedRoom && !files.hasTexture && !files.isDemo
    }

    /// The style `target` really draws.
    func effectiveStyle(for target: ResultTab) -> ViewerDisplayStyle {
        ResultAvailability.effectiveStyle(displayStyle, tab: target, hasTexture: files.hasTexture)
    }

    /// Visible rows: all rows, or only rows whose `element == selectedElement`.
    var visibleRows: [DimensionRow] {
        ResultContentBuilder.filterRows(dimensionRows, selection: selectedElement)
    }

    /// Current view state for exports (plan toggles and Hide Furniture).
    var exportViewState: ExportViewState {
        ExportViewState(planToggles: planToggles, hideFurniture: hideFurniture)
    }

    // MARK: - Selection

    /// `.element(id)` of a wall or opening part: selectedElement (plus a highlight copy of the part
    /// on `.overlay`); of an object box: selectedObject and objectRows; nil or raw mesh: clears both.
    func handleTap(_ hit: ViewerHit?) {
        guard let tag = hit?.pickTag, case .element(let id) = tag else {
            clearSelection()
            return
        }
        select(id)
    }

    /// Floor Plan tab: walls and openings drive selectedElement; a furniture or fixture symbol
    /// opens its object card; anything else clears the selection.
    func selectPlanHit(_ hit: PlanHit?) {
        guard let hit else {
            clearSelection()
            return
        }
        switch hit.kind {
        case .wall, .opening, .fixture:
            select(hit.element)
        case .room, .dimension, .annotation:
            clearSelection()
        }
    }

    /// "Show all" in the dimensions panel, a tap on empty space, or closing the object card.
    func clearSelection() {
        guard selectedElement != nil || selectedObject != nil else { return }
        selectedElement = nil
        selectedObject = nil
        objectRows = []
        selectionChanged()
    }

    /// Selects a wall or opening (filters the rows) or an object (opens the card).
    private func select(_ id: ElementID) {
        guard let clean = snapshot?.clean else {
            clearSelection()
            return
        }
        if let object = ResultContentBuilder.object(id, in: clean) {
            guard selectedObject?.id != id || selectedElement != nil else { return }
            selectedElement = nil
            selectedObject = object
            objectRows = RoomDimensions.objectRows(for: object, evidence: evidence(forObject: id, in: clean))
            LogStore.shared.write("object selected: \(object.category.copyKey)", category: ResultLoader.logCategory)
        } else if ResultContentBuilder.isWallOrOpening(id, in: clean) {
            guard selectedElement != id || selectedObject != nil else { return }
            selectedObject = nil
            objectRows = []
            selectedElement = id
            LogStore.shared.write("element selected: \(visibleRows.count) rows", category: ResultLoader.logCategory)
        } else {
            clearSelection()
            return
        }
        Haptics.selection()
        selectionChanged()
    }

    /// Evidence of the room that holds object `id`.
    private func evidence(forObject id: ElementID, in clean: CleanModel) -> RoomEvidence {
        guard let room = ResultContentBuilder.room(ofObject: id, in: clean) else { return .unknown }
        return snapshot?.evidence[room.recordID] ?? .unknown
    }

    /// Rebuilds the 3D Clean highlight when that tab is shown.
    private func selectionChanged() {
        guard tab == .clean else { return }
        Task { await self.loadViewerContent(for: .clean) }
    }

    /// A tab switch closes the object card; Realistic and Raw Scan cannot show a wall
    /// selection, so it is cleared there (3D Clean and Floor Plan share it).
    func adjustSelection(forTab newTab: ResultTab) {
        if selectedObject != nil {
            selectedObject = nil
            objectRows = []
        }
        if newTab == .realistic || newTab == .raw { selectedElement = nil }
    }

    /// Keeps the selection valid after a reload: drops elements that no longer exist and
    /// refreshes the selected object and its rows.
    private func reconcileSelection(with clean: CleanModel?) {
        if let id = selectedElement {
            var stillExists = false
            if let model = clean { stillExists = ResultContentBuilder.isWallOrOpening(id, in: model) }
            if !stillExists { selectedElement = nil }
        }
        guard let current = selectedObject else { return }
        if let model = clean, let fresh = ResultContentBuilder.object(current.id, in: model) {
            if fresh != current { selectedObject = fresh }
            let rows = RoomDimensions.objectRows(for: fresh, evidence: evidence(forObject: fresh.id, in: model))
            if rows != objectRows { objectRows = rows }
        } else {
            selectedObject = nil
            objectRows = []
        }
    }

    // MARK: - Applying loads

    /// Applies a snapshot read off main (nil: the project could not be read).
    func apply(_ result: ResultLoadSnapshot?) {
        guard let snap = result else {
            if snapshot == nil { loadFailed = true }
            hasLoaded = true
            return
        }
        loadFailed = false
        snapshot = snap
        if title != snap.manifest.name { title = snap.manifest.name }
        if status != snap.manifest.status { status = snap.manifest.status }
        if files != snap.files { files = snap.files }
        if degraded != snap.degraded { degraded = snap.degraded }
        if dimensionRows != snap.rows { dimensionRows = snap.rows }
        if missingAreaCount != snap.missingAreas.count { missingAreaCount = snap.missingAreas.count }
        recomputeAvailability()
        reconcileSelection(with: snap.clean)
        if !hasLoaded { hasLoaded = true }
        chooseInitialTabIfNeeded()
    }

    /// Picks the first ready tab (Realistic, 3D Clean, Floor Plan, Raw Scan) once, when the tabs
    /// first show, unless the user already chose one.
    private func chooseInitialTabIfNeeded() {
        guard !userChoseTab, !initialTabChosen, !showsProcessingView else { return }
        initialTabChosen = true
        let order: [ResultTab] = [.realistic, .clean, .floorPlan, .raw]
        if let best = order.first(where: { tabState($0).isReady }), best != tab {
            tab = best
        }
        LogStore.shared.write("opened on \(tab.rawValue)", category: ResultLoader.logCategory)
    }

    /// Recomputes every tab's availability from the files and the processing state.
    func recomputeAvailability() {
        var map: [ResultTab: TabAvailability] = [:]
        for candidate in ResultTab.allCases {
            map[candidate] = ResultAvailability.compute(candidate, files: files, processing: processing, degraded: degraded,
                                                        status: status)
        }
        if map != availability { availability = map }
    }

    /// New runner state: availability follows at once; steps that finished or failed, and jobs
    /// that start or end, reload the files.
    func processingChanged(_ state: ProjectProcessingState) {
        let old = processing
        guard old != state else { return }
        processing = state
        recomputeAvailability()
        let structural = old.completed != state.completed || old.failed != state.failed
        let lifecycle = old.isRunning != state.isRunning || old.isQueued != state.isQueued
        if structural || lifecycle { scheduleReload() }
    }

    /// Stores a finished plan drawing.
    func setPlanDrawing(_ drawing: PlanDrawingResult?) {
        planDrawing = drawing
    }

    /// Marks the Quick Look export as running or finished.
    func setPreparingSimpleModel(_ running: Bool) {
        isPreparingSimpleModel = running
    }

    /// Counts a content build that starts (`true`) or ends (`false`).
    func contentBuild(started: Bool) {
        buildsInFlight = Swift.max(0, buildsInFlight + (started ? 1 : -1))
        let building = buildsInFlight > 0
        if isBuildingContent != building { isBuildingContent = building }
    }

    // MARK: - Project

    /// ProjectLibrary.rename; title updates. An empty name leaves the project unchanged.
    func rename(to name: String) throws {
        try ProjectLibrary.shared.rename(projectID, to: name)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = String(trimmed.prefix(ProjectLibrary.maxNameLength))
        LogStore.shared.write("project renamed", category: ResultLoader.logCategory)
    }

    /// Reads the unit preferences again (on appear); redraws the plan when they changed.
    func refreshUnits() {
        let current = UnitPreferences.load()
        guard current != prefs else { return }
        prefs = current
        scheduleDrawing()
    }

    // MARK: - Style and furniture

    /// Rebuilds Realistic or Raw Scan in the new style.
    private func displayStyleChanged(from old: ViewerDisplayStyle) {
        guard old != displayStyle else { return }
        LogStore.shared.write("display style \(old.rawValue) -> \(displayStyle.rawValue)", category: ResultLoader.logCategory)
        let current = tab
        guard current == .realistic || current == .raw else { return }
        Task { await self.loadViewerContent(for: current) }
    }

    /// Shows or hides the furniture and occluded layers and redraws the plan.
    private func hideFurnitureChanged(from old: Bool) {
        guard old != hideFurniture else { return }
        applyLayerVisibility()
        scheduleDrawing()
        let movable = snapshot?.clean?.rooms.reduce(0) { sum, room in
            sum + room.objects.filter { $0.isMovable && !$0.isHidden }.count
        } ?? 0
        LogStore.shared.write("hide furniture \(hideFurniture ? "on" : "off"), \(movable) movable objects", category: ResultLoader.logCategory)
    }

    /// Furniture visible unless Hide Furniture is on; occluded regions only while it is on;
    /// every other layer visible.
    func applyLayerVisibility() {
        for layer in ViewerLayer.allCases {
            let visible: Bool
            switch layer {
            case .cleanFurniture: visible = !hideFurniture
            case .cleanOccluded: visible = hideFurniture
            case .realistic, .raw, .rawInferred, .cleanStructure, .cleanOpenings, .cleanFixtures, .overlay: visible = true
            }
            if viewer.isVisible(layer) != visible { viewer.setVisible(layer, visible) }
        }
    }
}
