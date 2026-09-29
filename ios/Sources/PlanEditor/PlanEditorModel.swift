import Foundation
import Combine
import simd

/// Files read when the editor opens (off main).
struct PlanEditorLoadResult: Sendable {
    /// The base plan (`derived/plan.json`); nil when it is missing or unreadable.
    var plan: PlanModel?
    /// The base clean model (`derived/clean.json`), when readable.
    var clean: CleanModel?
    /// The edit log (empty when absent or unreadable).
    var log: EditLog
    /// Unit preferences.
    var prefs: UnitPreferences
    /// Why the plan could not be read, for the log.
    var failure: String?
}

/// Main actor. One editing session of one project (docs/MODULES.md 3.37): the bases, the local
/// mirror of the edit log, the edited plan and clean model, the tool and selection, and the
/// ordered writes. Every user action becomes one log entry (`PlanEditorOps.operation`), applied
/// locally at once and written through `EditStore` on a private serial queue, so writes land in
/// order and main never blocks on disk. Input handling is in `PlanEditorModel+Input.swift` and
/// `PlanEditorModel+Drag.swift`.
@MainActor final class PlanEditorModel: ObservableObject {
    /// Layers shown while editing: `PlanToggles.standard` with the grid on.
    static let toggles: PlanToggles = {
        var toggles = PlanToggles.standard
        toggles.grid = true
        return toggles
    }()
    /// Log category of the editor.
    nonisolated static let logCategory = "planeditor"

    /// The edited plan (the drag preview while a drag runs) and the edited clean model.
    @Published private(set) var plan: PlanModel
    @Published private(set) var clean: CleanModel?
    /// Index of the edited level in `plan.levels`.
    @Published private(set) var levelIndex: Int
    /// The drawing of the edited level (of the preview while a drag runs).
    @Published private(set) var drawing: PlanDrawingResult?
    /// The selected element.
    @Published var selection: ElementID?
    /// What a tap does.
    @Published private(set) var tool: PlanEditTool
    /// First points of Add Wall, Add Measurement and Split Room.
    @Published private(set) var pendingPoints: [Vec2]
    /// Rooms tapped while Merge Rooms is the tool.
    @Published private(set) var mergeSelection: [ElementID]
    /// What the last drawn or dragged point snapped to (nil when nothing snapped).
    @Published private(set) var snapKind: PlanSnapKind?
    /// Where it snapped (the snap marker), when the snap was to a point.
    @Published private(set) var snapMarker: SIMD2<Float>?
    /// Snapping toggle (More menu).
    @Published var snappingEnabled: Bool
    /// Undo and Redo availability.
    @Published private(set) var canUndo: Bool
    @Published private(set) var canRedo: Bool
    /// Load state; a missing plan sets `loadFailed`.
    @Published private(set) var isLoaded: Bool
    @Published private(set) var loadFailed: Bool
    /// Unit preferences for labels and typed lengths.
    @Published private(set) var prefs: UnitPreferences
    /// The sheet or alert to show.
    @Published var prompt: PlanEditorPrompt?
    /// A refused action or a failed write; shown in an alert, then cleared.
    @Published var message: String?
    /// Why the text of the open prompt was rejected (the sheet stays open and shows it).
    @Published var promptError: String?
    /// A short note shown in the hint line (a tap that missed a wall, a refused drag).
    @Published var notice: String?
    /// Plan bounds the canvas fits to; changed only on load, level change and `refit()`, so the
    /// view does not jump while editing.
    @Published private(set) var fitBounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
    /// Increases on every Reset View request; the canvas resets its zoom and pan on a change.
    @Published private(set) var viewResets: Int

    /// The project being edited.
    let projectID: UUID

    /// The package, bases and the local mirror of the edit log (used by the input extensions).
    var package: ProjectPackage?
    var basePlan: PlanModel = .empty
    var baseClean: CleanModel?
    var log = EditLog()
    /// The edited plan without the drag preview.
    var editedPlan: PlanModel = .empty
    /// Walls geometry edits refuse (`PlanEditorOps.lockedWalls`).
    var lockedWalls: Set<ElementID> = []
    /// Room titles of the edited plan.
    var roomTitles: [ElementID: String] = [:]
    /// The running canvas drag.
    var activeDrag: PlanEditorDrag?
    /// Increases on every local change of the log; a disk reload started before a later local
    /// change is not adopted.
    private var localRevision = 0
    /// Serial queue of every edit write, so writes land in order (PERF-28).
    private let ioQueue = DispatchQueue(label: "mapper.planeditor.io", qos: .userInitiated)

    /// A model for one project; call `load()` before use.
    init(projectID: UUID) {
        self.projectID = projectID
        plan = .empty
        clean = nil
        levelIndex = 0
        drawing = nil
        selection = nil
        tool = .select
        pendingPoints = []
        mergeSelection = []
        snapKind = nil
        snapMarker = nil
        snappingEnabled = true
        canUndo = false
        canRedo = false
        isLoaded = false
        loadFailed = false
        prefs = .standard
        prompt = nil
        message = nil
        promptError = nil
        notice = nil
        fitBounds = nil
        viewResets = 0
    }

    // MARK: - Loading

    /// Off main: `PlanModelStore.loadBase`, `CleanModelStore.loadBase` (optional), `EditStore.load`,
    /// `UnitPreferences.load()`; keeps the bases and the log; edited plan = `log.applied(to: basePlan)`,
    /// edited clean = `baseClean.applyingEdits(log)`; `lockedWalls`. A missing plan sets `loadFailed`.
    func load() async {
        let found: ProjectPackage
        do {
            found = try ProjectLibrary.shared.package(for: projectID)
        } catch {
            record("load failed: no package (\(error))")
            loadFailed = true
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) { () -> PlanEditorLoadResult in
            PlanEditorModel.readFiles(found)
        }.value
        prefs = loaded.prefs
        guard let base = loaded.plan else {
            record("load failed: \(loaded.failure ?? "no plan")")
            loadFailed = true
            isLoaded = false
            return
        }
        package = found
        basePlan = base
        baseClean = loaded.clean
        log = loaded.log
        localRevision += 1
        recompute(refit: true)
        loadFailed = false
        isLoaded = true
        record("opened: \(base.levels.count) levels, \(log.active.count) active edits, "
               + "clean model \(loaded.clean == nil ? "missing" : "loaded"), \(lockedWalls.count) locked walls")
    }

    /// Reads the plan, the clean model, the log and the unit preferences. Safe off main.
    nonisolated static func readFiles(_ package: ProjectPackage) -> PlanEditorLoadResult {
        let prefs = UnitPreferences.load()
        let log = EditStore.load(package)
        var clean: CleanModel?
        do {
            clean = try CleanModelStore.loadBase(package)
        } catch {
            LogStore.shared.write("clean model not loaded: \(error)", category: logCategory)
        }
        do {
            let plan = try PlanModelStore.loadBase(package)
            return PlanEditorLoadResult(plan: plan, clean: clean, log: log, prefs: prefs, failure: nil)
        } catch {
            return PlanEditorLoadResult(plan: nil, clean: clean, log: log, prefs: prefs, failure: "\(error)")
        }
    }

    // MARK: - Editing

    /// Maps, validates (applies to copies of both models; a false from either refuses the action),
    /// appends to the local log, recomputes, and writes through `EditStore.append` on the write queue.
    func perform(_ action: PlanEditAction) throws {
        guard isLoaded else { throw PlanEditorError.notFound }
        let op: EditOperation
        do {
            op = try PlanEditorOps.operation(for: action, context: context())
        } catch let error as PlanEditorError {
            refuse(action, error)
            throw error
        }
        var planCopy = editedPlan
        var accepted = planCopy.apply(op)
        if accepted, let current = clean {
            var cleanCopy = current
            if !cleanCopy.apply(op) { accepted = PlanEditorOps.isPlanOnly(op, clean: current) }
        }
        guard accepted else {
            refuse(action, .notFound)
            throw PlanEditorError.notFound
        }
        log.append(op)
        localRevision += 1
        recompute()
        Haptics.tap()
        record(PlanEditorOps.logLine(action, op: op))
        enqueueWrite("append") { package in
            _ = try EditStore.append(op, to: package)
        }
    }

    /// Undoes the last action (one log entry) locally and on disk.
    func undo() throws {
        guard isLoaded else { throw PlanEditorError.notFound }
        guard log.undo() else { return }
        finishLocalChange("undo")
        enqueueWrite("undo") { package in
            _ = try EditStore.undo(package)
        }
    }

    /// Redoes the first undone action locally and on disk.
    func redo() throws {
        guard isLoaded else { throw PlanEditorError.notFound }
        guard log.redo() else { return }
        finishLocalChange("redo")
        enqueueWrite("redo") { package in
            _ = try EditStore.redo(package)
        }
    }

    /// After `.resetConfirmation`: `EditStore.reset(_:keeping: { !PlanEditorOps.isPlanEdit($0) })`.
    func resetToScan() throws {
        prompt = nil
        guard isLoaded else { throw PlanEditorError.notFound }
        guard log.reset(keeping: { !PlanEditorOps.isPlanEdit($0) }) else {
            record("reset: nothing to remove")
            return
        }
        selection = nil
        finishLocalChange("reset to scan")
        enqueueWrite("reset") { package in
            _ = try EditStore.reset(package, keeping: { !PlanEditorOps.isPlanEdit($0) })
        }
    }

    /// Shows a refused action and logs it.
    private func refuse(_ action: PlanEditAction, _ error: PlanEditorError) {
        message = PlanEditorPresentation.message(for: error, prefs: prefs)
        record("\(PlanEditorOps.actionName(action)) refused: \(error)")
    }

    /// Common end of undo, redo and reset: recompute, feedback and a log line.
    private func finishLocalChange(_ what: String) {
        localRevision += 1
        activeDrag = nil
        pendingPoints = []
        mergeSelection = []
        tool = .select
        recompute()
        Haptics.tap()
        record("\(what): \(log.cursor) active of \(log.operations.count), revision \(log.revision)")
    }

    // MARK: - Writes

    /// Runs one edit write on the serial write queue. A failed write shows
    /// `Copy.Errors.saveFailed.body` and reloads the log from disk (the disk log wins).
    private func enqueueWrite(_ label: String, _ body: @escaping @Sendable (ProjectPackage) throws -> Void) {
        guard let target = package else { return }
        ioQueue.async { [weak self] in
            do {
                try body(target)
            } catch {
                let detail = "\(error)"
                guard let model = self else { return }
                Task { @MainActor in model.writeFailed(label, detail: detail) }
            }
        }
    }

    /// A write failed: tell the user and reload the log from disk.
    private func writeFailed(_ label: String, detail: String) {
        record("write \(label) failed: \(detail)")
        message = Copy.Errors.saveFailed.body
        reloadLogFromDisk()
    }

    /// Reads the log on the write queue (after every pending write) and adopts it on main unless a
    /// local change happened meanwhile (then it reads again).
    func reloadLogFromDisk() {
        guard let target = package else { return }
        let requested = localRevision
        ioQueue.async { [weak self] in
            let disk = EditStore.load(target)
            guard let model = self else { return }
            Task { @MainActor in model.adoptDiskLog(disk, requested: requested) }
        }
    }

    /// Adopts a log read from disk.
    private func adoptDiskLog(_ disk: EditLog, requested: Int) {
        guard requested == localRevision else {
            reloadLogFromDisk()
            return
        }
        log = disk
        localRevision += 1
        activeDrag = nil
        recompute()
        record("log reloaded from disk: \(log.cursor) active, revision \(log.revision)")
    }

    // MARK: - Setters for the input extensions

    /// Sets the tool, its pending points and the merge selection (the published properties keep
    /// private setters; the input extensions live in other files).
    func setToolState(_ newTool: PlanEditTool, pending: [Vec2] = [], merge: [ElementID] = []) {
        tool = newTool
        pendingPoints = pending
        mergeSelection = merge
    }

    /// Replaces the pending points of the active tool.
    func setPending(_ points: [Vec2]) {
        pendingPoints = points
    }

    /// Replaces the rooms tapped for Merge Rooms.
    func setMergeSelection(_ rooms: [ElementID]) {
        mergeSelection = rooms
    }

    /// Publishes what the last point snapped to and where (nil for nothing).
    func setSnap(_ kind: PlanSnapKind?, at point: SIMD2<Float>?) {
        snapKind = kind
        snapMarker = kind == nil ? nil : point
    }

    /// Shows a drag preview of the plan and draws it.
    func showPreview(_ preview: PlanModel) {
        plan = preview
        redraw()
    }

    /// Ends a drag preview: the edited plan is shown again.
    func endPreview() {
        plan = editedPlan
        redraw()
    }

    // MARK: - State

    /// Rebuilds the edited models from the bases and the log, the locked walls, titles, undo
    /// state, the selection (dropped when gone) and the drawing.
    func recompute(refit: Bool = false) {
        editedPlan = log.applied(to: basePlan).0
        clean = baseClean.map { $0.applyingEdits(log).model }
        lockedWalls = PlanEditorOps.lockedWalls(plan: editedPlan, clean: clean)
        roomTitles = RoomTitles.titles(for: editedPlan, clean: clean)
        canUndo = log.canUndo
        canRedo = log.canRedo
        if levelIndex >= editedPlan.levels.count { levelIndex = max(0, editedPlan.levels.count - 1) }
        plan = editedPlan
        if let id = selection, let level = committedLevel, !PlanEditorModel.levelContains(level, id) {
            selection = nil
        }
        let roomIDs = Set((committedLevel?.rooms ?? []).map { $0.id })
        mergeSelection = mergeSelection.filter { roomIDs.contains($0) }
        redraw()
        if refit || fitBounds == nil { self.refit() }
    }

    /// Draws the shown plan's current level (the preview while dragging).
    func redraw() {
        guard plan.levels.indices.contains(levelIndex) else {
            drawing = nil
            return
        }
        let level = plan.levels[levelIndex]
        drawing = PlanDrawing.make(level: level, toggles: PlanEditorModel.toggles, prefs: prefs, roomTitles: roomTitles,
                                   name: PlanEditorPresentation.levelTitle(level))
    }

    /// Fits the canvas to the current drawing again.
    func refit() {
        fitBounds = drawing?.plan.bounds()
    }

    /// Reset View from the More menu: fits again and asks the canvas to drop its zoom and pan.
    func requestViewReset() {
        refit()
        viewResets += 1
    }

    /// Shows another level: clears the selection and the tool, redraws and refits.
    func selectLevel(_ index: Int) {
        guard editedPlan.levels.indices.contains(index), index != levelIndex else { return }
        levelIndex = index
        selection = nil
        activeDrag = nil
        tool = .select
        pendingPoints = []
        mergeSelection = []
        plan = editedPlan
        redraw()
        refit()
    }

    /// The committed (not previewed) edited level.
    var committedLevel: PlanLevel? {
        editedPlan.levels.indices.contains(levelIndex) ? editedPlan.levels[levelIndex] : nil
    }

    /// Inputs of the pure mapping for the current level.
    func context() -> PlanEditorContext {
        let levelID = committedLevel?.id ?? 0
        return PlanEditorContext(plan: editedPlan, clean: clean, level: levelID, lockedWalls: lockedWalls)
    }

    /// Level titles for the level menu.
    var levelTitles: [String] {
        editedPlan.levels.map { PlanEditorPresentation.levelTitle($0) }
    }

    /// True when any element of the level has this id.
    static func levelContains(_ level: PlanLevel, _ id: ElementID) -> Bool {
        if level.rooms.contains(where: { $0.id == id }) { return true }
        return PlanEditorOps.isDeletable(id, in: level)
    }

    /// Writes one line to the app log (category "planeditor").
    func record(_ line: String) {
        LogStore.shared.write(line, category: PlanEditorModel.logCategory)
    }
}
