import Foundation
import Combine
import UIKit

/// Loading, reloading, tab content, the plan drawing and the simple model of `ResultModel`.
/// Every disk read and every mesh build runs in `Task.detached`; the main actor only applies
/// results (through the setters in ResultModel.swift for `private(set)` state).
extension ResultModel {
    // MARK: - Observers

    /// Subscribes to the runner state, manifest and edit changes of this project, and memory
    /// warnings. Called once from `init`.
    func observe() {
        let id = projectID
        ProcessingRunner.shared.$states
            .map { states in states[id] ?? ProjectProcessingState() }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    model.processingChanged(state)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .mapperManifestDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .mapperEditsDidChange))
            .filter { ($0.object as? UUID) == id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    model.scheduleReload()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    model.handleMemoryWarning()
                }
            }
            .store(in: &cancellables)
    }

    /// Drops the built content of the tabs not shown (the viewer releases hidden layers itself).
    func handleMemoryWarning() {
        let before = contentCache.count
        let current = tab
        contentCache = contentCache.filter { $0.key == current }
        if current != .clean { cleanBaseCache = nil }
        LogStore.shared.write("memory warning: dropped \(before - contentCache.count) cached views", category: ResultLoader.logCategory)
    }

    // MARK: - Snapshot

    /// Reads the manifest, PackageCheck.verify (off main, first load only; problems mark the
    /// project .needsAttention via ManifestWriter), the edited clean model and plan, quality
    /// evidence and missing areas, and the files; then redraws the plan when its inputs changed
    /// and shows the current tab. Calls during a read are coalesced into one more read.
    func load() async {
        if isReloading {
            reloadRequested = true
            return
        }
        isReloading = true
        refreshUnits()
        repeat {
            reloadRequested = false
            let verify = !didVerify
            didVerify = true
            let id = projectID
            let active = ResultAvailability.isActive(processing)
            let result = await Task.detached(priority: .userInitiated) { () -> ResultLoadSnapshot? in
                ResultLoader.readSnapshot(projectID: id, verify: verify, jobActive: active)
            }.value
            apply(result)
        } while reloadRequested
        isReloading = false
        await rebuildDrawingIfNeeded()
        await show(tab)
    }

    /// Starts a reload, or asks the running one to read again.
    func scheduleReload() {
        if isReloading {
            reloadRequested = true
            return
        }
        Task { await self.load() }
    }

    // MARK: - Tabs

    /// Builds the tab's ViewerContent off main, then viewer.load. Content that is already shown
    /// is not loaded again, and content built earlier for the same files and style is reused,
    /// so switching tabs never rebuilds unchanged content. Floor Plan needs no viewer content.
    /// Also called from the screen whenever `tab` changes (the switcher binds to `tab`).
    func show(_ newTab: ResultTab) async {
        if tab != newTab { tab = newTab }
        if lastShownTab != newTab {
            if let previous = lastShownTab {
                LogStore.shared.write("view \(previous.rawValue) -> \(newTab.rawValue)", category: ResultLoader.logCategory)
                userChoseTab = true
            }
            lastShownTab = newTab
            adjustSelection(forTab: newTab)
        }
        await loadViewerContent(for: newTab)
    }

    /// Loads `target`'s content into the viewer unless it is already there; builds it off main
    /// when no cached build matches. A build that finishes after the user moved on is cached
    /// and not shown.
    func loadViewerContent(for target: ResultTab) async {
        guard let request = contentRequest(for: target) else { return }
        if loadedKey == request.key {
            applyLayerVisibility()
            return
        }
        let content: ViewerContent
        if let cached = contentCache[target], cached.key == request.key {
            content = cached.content
        } else {
            guard !buildingKeys.contains(request.key) else { return }
            buildingKeys.insert(request.key)
            let baseKey = snapshot.map { cleanBaseKey($0.stamps) }
            contentBuild(started: true)
            let started = ProcessInfo.processInfo.systemUptime
            let built = await Task.detached(priority: .userInitiated) { () -> ResultBuiltContent in
                ResultLoader.buildContent(request)
            }.value
            contentBuild(started: false)
            buildingKeys.remove(request.key)
            contentCache[target] = (key: request.key, content: built.content)
            if target == .clean, let base = built.cleanBase, let baseKey {
                cleanBaseCache = (key: baseKey, parts: base)
            }
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let summary = "\(built.content.parts.count) parts, \(built.content.triangleCount) triangles in \(milliseconds) ms"
            LogStore.shared.write("built \(target.rawValue): \(summary)", category: ResultLoader.logCategory)
            guard tab == target, contentRequest(for: target)?.key == request.key else { return }
            content = built.content
        }
        guard loadedKey != request.key else { return }
        loadedKey = request.key
        applyLayerVisibility()
        await viewer.load(content)
    }

    /// What `target`'s viewer content is built from, with its key; nil for Floor Plan and for
    /// tabs that cannot show the viewer now.
    func contentRequest(for target: ResultTab) -> ResultContentRequest? {
        guard let snap = snapshot, showsViewer(target) else { return nil }
        let roomIDs = snap.manifest.rooms.map { $0.id }
        let stamps = snap.stamps
        switch target {
        case .floorPlan:
            return nil
        case .realistic:
            let style = effectiveStyle(for: .realistic)
            let key = "realistic|\(style.rawValue)|\(stamps.texture)|\(stamps.view)"
            return ResultContentRequest(tab: .realistic, key: key, style: style, package: snap.package, roomIDs: roomIDs,
                                        useTexture: style == .textured, clean: nil, selection: nil, cleanBase: nil,
                                        missingAreas: [])
        case .clean:
            guard let clean = snap.clean else { return nil }
            let baseKey = cleanBaseKey(stamps)
            let selection = selectedElement ?? selectedObject?.id
            let key = baseKey + "|\(stamps.quality)|sel=\(selection?.uuid.uuidString ?? "-")"
            let base = cleanBaseCache?.key == baseKey ? cleanBaseCache?.parts : nil
            return ResultContentRequest(tab: .clean, key: key, style: .solidColor, package: snap.package, roomIDs: roomIDs,
                                        useTexture: false, clean: clean, selection: selection, cleanBase: base,
                                        missingAreas: snap.missingAreas)
        case .raw:
            let style = effectiveStyle(for: .raw)
            let key = "raw|\(style.rawValue)|\(stamps.view)|\(stamps.inferred)|\(stamps.floaters)|\(stamps.quality)"
            return ResultContentRequest(tab: .raw, key: key, style: style, package: snap.package, roomIDs: roomIDs,
                                        useTexture: false, clean: nil, selection: nil, cleanBase: nil,
                                        missingAreas: snap.missingAreas)
        }
    }

    /// Key of the 3D Clean parts without selection and missing areas.
    func cleanBaseKey(_ stamps: ResultFileStamps) -> String {
        "clean|\(stamps.clean)|\(stamps.edits)"
    }

    // MARK: - Floor plan drawing

    /// Redraws the plan (off main) when the plan, the toggles, Hide Furniture, the units, the
    /// name or the room titles changed; nil when there is no plan level.
    func rebuildDrawingIfNeeded() async {
        guard let snap = snapshot, let plan = snap.plan, let level = plan.levels.first else {
            if planDrawing != nil { setPlanDrawing(nil) }
            drawingInputs = nil
            return
        }
        let inputs = ResultPlanInputs(planStamp: snap.stamps.plan + "|" + snap.stamps.edits,
                                      toggles: exportViewState.effectivePlanToggles, prefs: prefs,
                                      name: title, titles: snap.roomTitles)
        guard inputs != drawingInputs || planDrawing == nil else { return }
        drawingInputs = inputs
        drawingGeneration &+= 1
        let generation = drawingGeneration
        let drawing = await Task.detached(priority: .userInitiated) { () -> PlanDrawingResult in
            PlanDrawing.make(level: level, toggles: inputs.toggles, prefs: inputs.prefs, roomTitles: inputs.titles,
                             name: inputs.name)
        }.value
        guard generation == drawingGeneration else { return }
        setPlanDrawing(drawing)
    }

    /// Starts a plan redraw.
    func scheduleDrawing() {
        Task { await self.rebuildDrawingIfNeeded() }
    }

    // MARK: - Simple model

    /// CapturedRoom.export(to:metadataURL:modelProvider:exportOptions: [.mesh]) into exports/simple/
    /// (fixed name, replaced each time), sets quickLookURL; `simpleModelFailed` when it fails.
    func openSimpleModel() async {
        guard !isPreparingSimpleModel else { return }
        setPreparingSimpleModel(true)
        let id = projectID
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            ResultLoader.exportSimpleModel(projectID: id)
        }.value
        setPreparingSimpleModel(false)
        if let url {
            quickLookURL = url
        } else {
            simpleModelFailed = true
        }
    }
}
