import Foundation
import Combine
import simd

/// What the object result screen read from disk for its project. Built off main by
/// `ObjectResultModel.readSnapshot(projectID:)`.
struct ObjectResultSnapshot: Sendable {
    /// The project's package, when it could be located.
    var package: ProjectPackage?
    /// The manifest, when it could be read.
    var manifest: ProjectManifest?
    /// The project's object (the first ObjectRecord; build 5 saves one per project).
    var record: ObjectRecord?
    /// What exists on disk.
    var files = ObjectResultFiles()
    /// dims.json.
    var dimensions: ObjectDimensionsRecord?
    /// reconstruction.json (small and medium).
    var info: PhotogrammetryInfo?
    /// The Object Capture model, when present.
    var modelURL: URL?
    /// Identifies the viewer content, so the viewer reloads only when the files changed.
    var contentKey = ""

    /// Nothing read yet.
    init() {}
}

/// Viewer content built off main from the object's files.
struct ObjectViewerBuild: Sendable {
    /// The untextured part, the box and (large objects) the textured parts.
    var content: ViewerContent
    /// mesh.mchk's geometry, the Object Capture model's pick mesh.
    var pickMesh: TriangleMesh?
    /// Textured parts added (large objects).
    var texturedPartCount: Int
    /// Problems for the log.
    var problems: [String]
}

/// The object result (docs/MODULES.md 3.42). Decides only from files and the in-memory runner
/// state, never from stamps. Observes `ProcessingRunner.shared.states[projectID]`,
/// `PhotogrammetryMonitor.shared` and `.mapperManifestDidChange`; file reads and part building
/// run off main. While anything but `.ready` shows, the viewer holds no content (nothing else
/// holds GPU memory while photogrammetry runs).
@MainActor final class ObjectResultModel: ObservableObject {
    /// What the screen shows.
    @Published private(set) var availability: ObjectResultAvailability = .processing(text: Copy.ObjectUI.waiting,
                                                                                         percent: nil, remaining: nil)
    /// Width, height, depth, surface area and volume.
    @Published private(set) var rows: [ObjectDimensionRow] = []
    /// Reconstruction notes (downsampled photos, sides not joined).
    @Published private(set) var notes: [String] = []
    /// The project name.
    @Published private(set) var title = ""
    /// The textured model can be shown (small and medium: the model loaded; large: a texture).
    @Published private(set) var canShowTextured = false
    /// Textured (`.realistic`) or Solid Color (`.raw`).
    @Published var showsTextured = true
    /// Copy.Viewer.boundingBox (`.overlay`).
    @Published var showsBox = false
    /// True once the files were read the first time (the screen shows a spinner before).
    @Published private(set) var hasLoaded = false
    /// Retry is offered (status `.needsAttention` or a failed step).
    @Published private(set) var showsRetry = false
    /// The running job waits for the phone to cool down.
    @Published private(set) var isPausedForHeat = false
    /// Bumps when the model became ready while this screen showed the processing view
    /// (the screen's success haptic).
    @Published private(set) var finishedCount = 0
    /// The user's units.
    @Published private(set) var prefs: UnitPreferences = .standard

    /// The 3D viewer of the result.
    let viewer: ViewerModel
    /// The project shown.
    let projectID: UUID

    /// The latest disk snapshot.
    private var snapshot: ObjectResultSnapshot?
    /// The runner's state of the project.
    private var processing = ProjectProcessingState()
    /// The monitor's progress of the object.
    private var progress: PhotogrammetryProgress?
    /// Runner, monitor and manifest subscriptions.
    private var cancellables: Set<AnyCancellable> = []
    /// A disk refresh runs; another was requested meanwhile.
    private var refreshRunning = false, refreshQueued = false
    /// Content key of what the viewer shows or is loading; nil when empty.
    private var loadedKey: String?
    /// Content key whose textured model could not be shown.
    private var failedTexturedKey: String?
    /// The running viewer load.
    private var viewerTask: Task<Void, Never>?
    /// The viewer holds content (or a load is uploading it).
    private var viewerHoldsContent = false
    /// The processing view was shown since the last ready state.
    private var shownProcessing = false

    /// A model for one project; nothing is read until `load()`.
    init(projectID: UUID) {
        self.projectID = projectID
        viewer = ViewerModel()
    }

    // MARK: - Public API

    /// Manifest, files, dims.json, mesh, info; while processing the viewer is unloaded
    /// (nothing else holds GPU memory while photogrammetry runs); when ready, `viewer.load`
    /// of the untextured part and the box, then `viewer.loadModel` of the Object Capture
    /// model with the scale correction and the mesh as pick mesh.
    func load() async {
        prefs = UnitPreferences.load(from: .standard)
        observe()
        processing = ProcessingRunner.shared.state(for: projectID)
        await refresh()
    }

    /// Textured (true) or Solid Color: only toggles the `.realistic` and `.raw` layers.
    func setTextured(_ on: Bool) {
        showsTextured = on && canShowTextured
        applyVisibility()
    }

    /// Shows or hides the box layer.
    func setBoxVisible(_ on: Bool) {
        showsBox = on
        viewer.setVisible(.overlay, on)
    }

    /// Renames the project (`ProjectLibrary.rename`: trimmed, capped, an empty name is ignored).
    func rename(to name: String) throws {
        try ProjectLibrary.shared.rename(projectID, to: name)
        if let stored = ProjectLibrary.shared.manifest(for: projectID)?.name, stored != title {
            title = stored
        }
        log("project renamed")
    }

    /// Reads the unit preferences again (they may have changed in Settings) and rebuilds the rows.
    func refreshUnits() {
        let current = UnitPreferences.load(from: .standard)
        guard current != prefs else { return }
        prefs = current
        if let dimensions = snapshot?.dimensions {
            rows = ObjectPresentation.rows(for: dimensions, prefs: current)
        }
    }

    /// Reads the files again off main (coalesced) and updates everything.
    func refresh() async {
        guard !refreshRunning else {
            refreshQueued = true
            return
        }
        refreshRunning = true
        repeat {
            refreshQueued = false
            let id = projectID
            let snap = await Task.detached(priority: .userInitiated) {
                ObjectResultModel.readSnapshot(projectID: id)
            }.value
            apply(snap)
        } while refreshQueued
        refreshRunning = false
    }

    // MARK: - Disk (any thread)

    /// Reads the manifest, the object's files, dims.json and reconstruction.json. A missing
    /// project or a project without an object gives `files.hasObject == false` (logged).
    nonisolated static func readSnapshot(projectID: UUID) -> ObjectResultSnapshot {
        var snap = ObjectResultSnapshot()
        do {
            let package = try ProjectStore.package(for: projectID)
            snap.package = package
            snap.manifest = try ProjectStore.readManifest(package)
        } catch {
            ObjectPresentation.log("result \(projectID): project unreadable (\(StoreFiles.describe(error)))")
            snap.files.hasObject = false
            return snap
        }
        guard let package = snap.package, let manifest = snap.manifest, let record = manifest.objects.first else {
            snap.files.hasObject = false
            return snap
        }
        if manifest.objects.count > 1 {
            ObjectPresentation.log("result \(projectID): \(manifest.objects.count) objects, showing the first")
        }
        snap.record = record
        let objectID = record.id
        var files = ObjectResultFiles()
        files.size = record.size
        let model = record.size == .smallMedium ? PhotogrammetryStore.modelURLIfPresent(package, object: objectID) : nil
        files.hasModel = model != nil
        files.hasMesh = FileManager.default.fileExists(atPath: ObjectModelStore.meshURL(package, object: objectID).path)
        let dimensions = ObjectModelStore.loadDimensions(package, object: objectID)
        files.hasDimensions = dimensions != nil
        files.hasTexture = record.size == .large && TextureStore.exists(package, room: objectID)
        snap.files = files
        snap.modelURL = model
        snap.dimensions = dimensions
        snap.info = record.size == .smallMedium ? PhotogrammetryStore.loadInfo(package, object: objectID) : nil
        snap.contentKey = contentKey(files: files, dimensions: dimensions)
        return snap
    }

    /// Changes whenever the model, the mesh, the texture or dims.json changed.
    nonisolated static func contentKey(files: ObjectResultFiles, dimensions: ObjectDimensionsRecord?) -> String {
        let dims = dimensions.map { "\($0.inputHash)@\($0.measuredAt.timeIntervalSince1970)" } ?? "-"
        return "model \(files.hasModel), mesh \(files.hasMesh), texture \(files.hasTexture), dims \(dims)"
    }

    /// The untextured part (mesh.mchk), the box (dims.json) and, for a large object with a
    /// texture, its textured page parts inside the box. Problems are returned for the log.
    nonisolated static func buildContent(package: ProjectPackage, objectID: UUID, dimensions: ObjectDimensionsRecord?,
                                         largeTexture: Bool) -> ObjectViewerBuild {
        var parts: [ViewerPart] = []
        var pickMesh: TriangleMesh?
        var problems: [String] = []
        var texturedCount = 0
        do {
            if let mesh = try ObjectModelStore.loadMesh(package, object: objectID), mesh.triangleCount > 0 {
                parts.append(ObjectPresentation.untexturedPart(mesh))
                pickMesh = mesh.mesh
            }
        } catch {
            problems.append("mesh.mchk unreadable: \(error)")
        }
        let box = dimensions?.box.orientedBox
        if let box {
            parts.append(contentsOf: ObjectPresentation.boxParts(box))
        }
        if largeTexture, let box {
            do {
                if let textured = try TextureStore.load(package, room: objectID) {
                    let kept = ObjectPresentation.texturedParts(textured.pageParts(), inside: box)
                    for part in kept where part.page >= 0 && part.page < textured.pageURLs.count {
                        parts.append(ViewerContentBuilder.texturedPart(id: "object.texture.\(part.page)",
                                                                       positions: part.positions, indices: part.indices,
                                                                       cornerUVs: part.texcoords,
                                                                       textureURL: textured.pageURLs[part.page],
                                                                       layer: .realistic, pickTag: .rawMesh))
                        texturedCount += 1
                    }
                }
            } catch {
                problems.append("texture unreadable: \(error)")
            }
        }
        return ObjectViewerBuild(content: ViewerContent(parts: parts), pickMesh: pickMesh,
                                 texturedPartCount: texturedCount, problems: problems)
    }

    // MARK: - State

    /// Takes a new disk snapshot: title, rows, notes, the textured choice, then the availability.
    private func apply(_ snap: ObjectResultSnapshot) {
        snapshot = snap
        if let name = snap.manifest?.name, name != title { title = name }
        let newRows = snap.dimensions.map { ObjectPresentation.rows(for: $0, prefs: prefs) } ?? []
        if newRows != rows { rows = newRows }
        let newNotes = ObjectPresentation.notes(info: snap.info)
        if newNotes != notes { notes = newNotes }
        if let objectID = snap.record?.id {
            progress = PhotogrammetryMonitor.shared.progress[objectID]
        }
        updateTexturedChoice()
        if !hasLoaded {
            hasLoaded = true
            log("opened: object \(snap.record?.id.uuidString ?? "none"), size \(snap.files.size.rawValue), "
                + "model \(snap.files.hasModel), mesh \(snap.files.hasMesh), dims \(snap.files.hasDimensions)")
        }
        recompute()
    }

    /// Availability, Retry and the heat pause from the snapshot and the in-memory state; then
    /// the viewer follows.
    private func recompute() {
        guard let snap = snapshot else { return }
        let status = snap.manifest?.status ?? .needsProcessing
        let next = ObjectPresentation.availability(files: snap.files, processing: processing, status: status,
                                                   progress: progress)
        let retry = ObjectPresentation.showsRetry(status: status, processing: processing)
        if retry != showsRetry { showsRetry = retry }
        if processing.isPausedForHeat != isPausedForHeat { isPausedForHeat = processing.isPausedForHeat }
        if next != availability {
            if ObjectResultModel.kindName(next) != ObjectResultModel.kindName(availability) {
                log("shows \(ObjectResultModel.kindName(next))")
            }
            if next == .ready && shownProcessing { finishedCount += 1 }
            availability = next
        }
        if case .processing = next {
            shownProcessing = true
        } else if next == .ready {
            shownProcessing = false
        }
        syncViewer()
    }

    /// Textured is offered when the files allow it and the model did not fail to show; a
    /// change resets the choice to textured when available.
    private func updateTexturedChoice() {
        guard let snap = snapshot else { return }
        let available = ObjectPresentation.canShowTextured(files: snap.files) && failedTexturedKey != snap.contentKey
        guard available != canShowTextured else { return }
        canShowTextured = available
        showsTextured = available
        applyVisibility()
    }

    // MARK: - Viewer

    /// Loads the viewer for a ready object whose content changed, or empties it otherwise.
    private func syncViewer() {
        guard availability == .ready, let snap = snapshot else {
            releaseViewer()
            return
        }
        guard snap.contentKey != loadedKey else { return }
        loadedKey = snap.contentKey
        viewerTask?.cancel()
        viewerTask = Task { [weak self] in
            await self?.loadViewer(snap)
        }
    }

    /// Stops a load and removes all viewer content (GPU memory is freed for processing).
    private func releaseViewer() {
        viewerTask?.cancel()
        viewerTask = nil
        loadedKey = nil
        guard viewerHoldsContent else { return }
        viewerHoldsContent = false
        viewer.unload()
        log("viewer emptied while the object is not ready")
    }

    /// Builds the parts off main, loads them, then adds the Object Capture model (small and
    /// medium) scaled like mesh.mchk with the mesh as pick mesh. A model that cannot be shown
    /// turns Textured off (logged); the untextured mesh stays.
    private func loadViewer(_ snap: ObjectResultSnapshot) async {
        guard let package = snap.package, let record = snap.record else { return }
        let key = snap.contentKey
        let objectID = record.id
        let dimensions = snap.dimensions
        let largeTexture = record.size == .large && snap.files.hasTexture
        let built = await Task.detached(priority: .userInitiated) {
            ObjectResultModel.buildContent(package: package, objectID: objectID, dimensions: dimensions,
                                           largeTexture: largeTexture)
        }.value
        guard isCurrent(key) else { return }
        for problem in built.problems { log(problem) }
        if largeTexture && built.texturedPartCount == 0 {
            log("no textured faces inside the box; textured view off")
            markTexturedUnavailable(key)
        }
        let modelURL: URL? = record.size == .smallMedium ? snap.modelURL : nil
        applyVisibility(modelPending: modelURL != nil)
        viewerHoldsContent = true
        await viewer.load(built.content)
        guard isCurrent(key) else { return }
        guard let url = modelURL else { return }
        let transform = ObjectPresentation.scaleTransform(dimensions?.scaleCorrection ?? 1)
        do {
            _ = try await viewer.loadModel(url, layer: .realistic, transform: transform, pickMesh: built.pickMesh,
                                           pickTag: .rawMesh)
            guard isCurrent(key) else { return }
            applyVisibility()
        } catch ViewerModelError.superseded {
            return
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(key) else { return }
            log("model \(url.lastPathComponent) could not be shown (\(error)); textured view off")
            markTexturedUnavailable(key)
        }
    }

    /// True while `key` is still what the viewer should show.
    private func isCurrent(_ key: String) -> Bool {
        !Task.isCancelled && loadedKey == key && availability == .ready
    }

    /// Turns Textured off for this content.
    private func markTexturedUnavailable(_ key: String) {
        failedTexturedKey = key
        updateTexturedChoice()
        applyVisibility()
    }

    /// Layer visibility for the current choices. While the model file is still loading the
    /// untextured mesh stays visible, so the screen is never empty.
    private func applyVisibility(modelPending: Bool = false) {
        let textured = showsTextured && canShowTextured
        viewer.setVisible(.realistic, textured)
        viewer.setVisible(.raw, !textured || modelPending)
        viewer.setVisible(.overlay, showsBox)
    }

    // MARK: - Observation

    /// Subscribes once to the runner, the monitor and manifest changes of this project.
    private func observe() {
        guard cancellables.isEmpty else { return }
        let id = projectID
        ProcessingRunner.shared.$states
            .map { states in states[id] ?? ProjectProcessingState() }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.processingChanged(state)
                }
            }
            .store(in: &cancellables)
        PhotogrammetryMonitor.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] all in
                MainActor.assumeIsolated {
                    self?.progressChanged(all)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .mapperManifestDidChange)
            .filter { note in (note.object as? UUID) == id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
            .store(in: &cancellables)
    }

    /// New runner state: recompute now; read the files again when a step started, ended or failed.
    private func processingChanged(_ state: ProjectProcessingState) {
        let old = processing
        processing = state
        let completedChanged = old.completed != state.completed
        let failedChanged = old.failed != state.failed
        let runChanged = old.isRunning != state.isRunning || old.isQueued != state.isQueued
        let stepChanged = old.currentStep != state.currentStep
        recompute()
        if completedChanged || failedChanged || runChanged || stepChanged {
            scheduleRefresh()
        }
    }

    /// New monitor progress: recompute when this object's changed.
    private func progressChanged(_ all: [UUID: PhotogrammetryProgress]) {
        guard let objectID = snapshot?.record?.id else { return }
        let mine = all[objectID]
        guard mine != progress else { return }
        progress = mine
        recompute()
    }

    /// Starts a coalesced disk refresh.
    private func scheduleRefresh() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Helpers

    /// Log name of an availability case.
    nonisolated static func kindName(_ availability: ObjectResultAvailability) -> String {
        switch availability {
        case .processing: return "processing"
        case .ready: return "ready"
        case .failed: return "failed"
        case .noObject: return "noObject"
        }
    }

    /// Writes one line to the app log (category "objectui").
    private func log(_ message: String) {
        ObjectPresentation.log("result \(projectID.uuidString.prefix(8)): \(message)")
    }
}
