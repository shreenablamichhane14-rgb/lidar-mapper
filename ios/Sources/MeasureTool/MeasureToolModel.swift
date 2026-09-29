import Foundation
import Combine
import CoreGraphics
import simd

/// Main actor. The measuring state of one project on one result screen: the tool, the draft,
/// the saved measurements and the snap context (docs/MODULES.md 3.35).
///
/// Loading and every file access run off main; saving goes through `EditStore` on one private
/// serial queue so writes land in order. Taps, drags, completion and undo live in
/// MeasureToolModel+Points.swift.
@MainActor final class MeasureToolModel: ObservableObject {
    /// Changing the tool clears the draft.
    @Published var tool: MeasureToolKind {
        didSet {
            if tool != oldValue { clearDraft() }
        }
    }
    /// Copy.Measure.snapToggle; on by default.
    @Published var snappingEnabled: Bool
    /// The measurement being placed.
    @Published var draft: MeasureToolDraft
    /// Saved measurements of the project (all sources), createdAt order.
    @Published var records: [MeasurementRecord]
    /// List rows of `records`, same order.
    @Published private(set) var rows: [MeasureToolRow]
    /// The hint for the next tap.
    @Published var hint: String
    /// Latest "Snapped to ..." text, cleared after 1.5 s.
    @Published var snapText: String?
    /// False until the first context is built.
    @Published private(set) var isReady: Bool
    /// Units of every value.
    @Published private(set) var prefs: UnitPreferences
    /// The measurement list sheet (MeasureToolBar presents it).
    @Published var showsList: Bool
    /// The Delete All confirmation for hosts that offer Delete All outside the list.
    @Published var showsDeleteAllConfirmation: Bool
    /// `Copy.Errors.saveFailed.body` after a failed write; the screen shows it and clears it.
    @Published var errorText: String?
    /// Low confidence of the draft's live value (areas from their sides, E3).
    @Published var draftIsLowConfidence: Bool

    /// Binding target of the save error alert (`$model.showsSaveError`): true while `errorText`
    /// is set; setting it to false clears `errorText`.
    var showsSaveError: Bool {
        get { errorText != nil }
        set { if !newValue { errorText = nil } }
    }

    /// The project measured.
    let projectID: UUID
    /// The viewer whose content is measured (hit tests and projections).
    let viewer: ViewerModel

    /// Serial queue of every measurements write, so writes land in order.
    private static let ioQueue = DispatchQueue(label: "mapper.measuretool.io", qos: .utility)
    /// Log category.
    nonisolated static let logCategory = "measure"
    /// How long a "Snapped to" tag stays, nanoseconds.
    nonisolated static let snapTextNanoseconds: UInt64 = 1_500_000_000

    /// The snap context in use.
    private(set) var context: MeasureToolContext = .empty
    /// The project's package, once resolved.
    private(set) var package: ProjectPackage?
    /// Hide Furniture: movable objects are not snap targets.
    private var excludesMovable = false
    /// The Hide Furniture flag the current context was built with.
    private var contextExcludesMovable = false
    /// Measurements completed in this session, newest last, for Undo (both records of a Wall tap
    /// form one entry; the draft is what Undo reopens).
    var completed: [MeasureToolCompletion] = []
    /// Saves not yet finished.
    private var pendingWrites = 0
    /// Bumped on every local change of `records`, so a reload never overwrites newer edits.
    var localRevision = 0
    /// Latest context request; older results are dropped.
    private var contextToken = 0
    /// Loads running (a Hide Furniture change waits for them).
    private var loadsInFlight = 0
    /// Modification dates of clean.json and editlog.json the context was built from.
    private var contextStamp = MeasureToolFileStamp(clean: nil, editLog: nil)
    /// Low-confidence flags of records by id, with the record they were computed for.
    private var flagCache: [UUID: (record: MeasurementRecord, flag: Bool)] = [:]
    /// Clears `snapText` when it fires; replaced by every new tag.
    var snapClearTask: Task<Void, Never>?
    /// Records being dragged, as they were before the drag.
    var dragOriginals: [UUID: MeasurementRecord] = [:]
    /// Feature under the finger during a drag (a haptic fires when it changes).
    var dragFeature: SnapSetFeature?
    /// The edits notification subscription.
    private var editsSubscription: AnyCancellable?

    /// A model for `projectID`; call `load()` before use.
    init(projectID: UUID, viewer: ViewerModel) {
        self.projectID = projectID
        self.viewer = viewer
        self.tool = .distance
        self.snappingEnabled = true
        self.draft = .empty(.distance)
        self.records = []
        self.rows = []
        self.hint = MeasureToolPresentation.hint(.distance, placed: 0)
        self.snapText = nil
        self.isReady = false
        self.prefs = UnitPreferences.standard
        self.showsList = false
        self.showsDeleteAllConfirmation = false
        self.errorText = nil
        self.draftIsLowConfidence = false
    }

    // MARK: - Loading

    /// Off main: package, `CleanModelStore.loadEdited` (a failure leaves an empty context: points snap
    /// to the scan only, logged), `QualityStore.load(_:room:)` of every distinct `CleanRoom.recordID`
    /// (plus the manifest's rooms, so walls merged away from their room keep their evidence),
    /// `EditStore.loadMeasurements`, `UnitPreferences.load()`; then the context. Also subscribes to
    /// `.mapperEditsDidChange` for this project (plan edits move walls): the context is rebuilt when
    /// clean.json or the edit log changed, and the records are reloaded when no write of this model
    /// is pending.
    func load() async {
        let resolved: ProjectPackage
        do {
            resolved = try ProjectLibrary.shared.package(for: projectID)
        } catch {
            LogStore.shared.write("project \(projectID.uuidString): no package (\(error)); measuring the scan only",
                                  category: MeasureToolModel.logCategory)
            isReady = true
            return
        }
        package = resolved
        subscribeToEdits()
        await refresh(package: resolved, forceContext: true, reloadRecords: true, reloadPrefs: true)
    }

    /// Hide Furniture on the result screen: movable objects stop being snap targets (context rebuilt off main).
    func setExcludesMovableObjects(_ exclude: Bool) async {
        guard exclude != excludesMovable else { return }
        excludesMovable = exclude
        guard isReady, loadsInFlight == 0 else { return }
        await rebuildContext()
    }

    /// Rebuilds the context from the current model and evidence with the current Hide Furniture flag.
    private func rebuildContext() async {
        contextToken += 1
        let token = contextToken
        let model = context.model
        let evidence = context.roomEvidence
        let exclude = excludesMovable
        let built = await Task.detached(priority: .userInitiated) { () -> MeasureToolContext in
            MeasureToolSnaps.context(model: model, evidence: evidence, excludeMovable: exclude)
        }.value
        guard token == contextToken else { return }
        apply(context: built, excludesMovable: exclude)
    }

    /// Loads what changed off main and applies it. The context is rebuilt when `forceContext` or
    /// when clean.json or the edit log changed; the records are applied only while no save is
    /// pending and nothing changed locally since the load started.
    private func refresh(package: ProjectPackage, forceContext: Bool, reloadRecords: Bool, reloadPrefs: Bool) async {
        contextToken += 1
        let token = contextToken
        loadsInFlight += 1
        let request = MeasureToolLoadRequest(package: package, previousStamp: forceContext ? nil : contextStamp,
                                             excludeMovable: excludesMovable, records: reloadRecords, prefs: reloadPrefs)
        let revisionAtStart = localRevision
        let result = await Task.detached(priority: .userInitiated) { () -> MeasureToolLoadResult in
            MeasureToolLoader.load(request)
        }.value
        loadsInFlight -= 1
        if let prefs = result.prefs, prefs != self.prefs {
            self.prefs = prefs
            refreshRows()
        }
        if let loaded = result.records, pendingWrites == 0, localRevision == revisionAtStart {
            records = MeasureToolPresentation.createdOrder(loaded)
            let ids = Set(records.map { $0.id })
            completed = completed.filter { entry in entry.ids.contains { ids.contains($0) } }
            refreshRows()
        }
        if let built = result.context, token == contextToken {
            contextStamp = result.stamp
            apply(context: built, excludesMovable: result.excludeMovable)
        }
        if loadsInFlight == 0, contextExcludesMovable != excludesMovable {
            await rebuildContext()
        }
        if !isReady {
            isReady = true
            LogStore.shared.write("ready: \(context.model.rooms.count) rooms, \(context.snaps.corners.count) corners, "
                                  + "\(context.snaps.edges.count) edges, \(context.snaps.planes.count) planes, "
                                  + "\(records.count) measurements", category: MeasureToolModel.logCategory)
        }
    }

    /// Uses a new context built with the given Hide Furniture flag: the draft value, its flag and
    /// the row flags are recomputed.
    private func apply(context built: MeasureToolContext, excludesMovable exclude: Bool) {
        context = built
        contextExcludesMovable = exclude
        flagCache = [:]
        updateDraftValue()
        refreshRows()
    }

    /// Follows `.mapperEditsDidChange` for this project.
    private func subscribeToEdits() {
        guard editsSubscription == nil else { return }
        let id = projectID
        editsSubscription = NotificationCenter.default.publisher(for: .mapperEditsDidChange)
            .filter { ($0.object as? UUID) == id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    model.editsDidChange()
                }
            }
    }

    /// An edits file of this project changed (a plan edit, or a measurements write).
    private func editsDidChange() {
        guard let package else { return }
        let reload = pendingWrites == 0
        Task { [weak self] in
            await self?.refresh(package: package, forceContext: false, reloadRecords: reload, reloadPrefs: false)
        }
    }

    // MARK: - Saving

    /// Saves every record through `EditStore.saveMeasurements` on the private serial queue; a failure
    /// is logged, sets `errorText` and reloads the records from disk.
    func persist() {
        guard let package else {
            LogStore.shared.write("save skipped: no package", category: MeasureToolModel.logCategory)
            return
        }
        let snapshot = records
        pendingWrites += 1
        MeasureToolModel.ioQueue.async { [weak self] in
            var failure: String?
            do {
                try EditStore.saveMeasurements(snapshot, to: package)
            } catch {
                failure = "\(error)"
            }
            let message = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.didPersist(failure: message)
                }
            }
        }
    }

    /// Bookkeeping after a save; a failure shows `Copy.Errors.saveFailed` and reloads from disk.
    private func didPersist(failure: String?) {
        pendingWrites = max(0, pendingWrites - 1)
        guard let failure else { return }
        LogStore.shared.write("save failed: \(failure)", category: MeasureToolModel.logCategory)
        errorText = Copy.Errors.saveFailed.body
        guard let package else { return }
        localRevision += 1
        Task { [weak self] in
            await self?.refresh(package: package, forceContext: false, reloadRecords: true, reloadPrefs: false)
        }
    }

    // MARK: - Derived state

    /// Recomputes the rows (area flags from their sides with the current context, cached per record).
    func refreshRows() {
        var cache: [UUID: (record: MeasurementRecord, flag: Bool)] = [:]
        let current = context
        for record in records {
            if let hit = flagCache[record.id], hit.record == record {
                cache[record.id] = hit
            } else {
                cache[record.id] = (record, MeasureToolSnaps.isLowConfidence(record: record, context: current))
            }
        }
        flagCache = cache
        rows = MeasureToolPresentation.rows(records, prefs: prefs) { record in
            cache[record.id]?.flag ?? MeasureDisplay.isLowConfidence(record.result, kind: record.kind)
        }
    }

    /// The low-confidence flag of a saved record (as shown in its row).
    func isLowConfidence(_ record: MeasurementRecord) -> Bool {
        if let hit = flagCache[record.id], hit.record == record { return hit.flag }
        return MeasureToolSnaps.isLowConfidence(record: record, context: context)
    }

    /// Recomputes the draft's value, its flag and the hint.
    func updateDraftValue() {
        draft.value = MeasureToolSnaps.value(draft, context: context)
        draftIsLowConfidence = MeasureToolSnaps.isLowConfidence(draft: draft, context: context)
        hint = MeasureToolPresentation.hint(tool, placed: draft.points.count)
    }

    /// Marks a local change of `records` and refreshes the rows.
    func recordsChanged() {
        localRevision += 1
        refreshRows()
    }

    /// `viewer.project(world)`; the overlay calls it again whenever `viewer.cameraRevision` changes.
    func screenPoint(_ world: SIMD3<Float>) -> CGPoint? {
        viewer.project(world)
    }
}

/// One measurement completed in this session, for Undo.
struct MeasureToolCompletion {
    /// Its record ids (two for a Wall tap).
    var ids: [UUID]
    /// The draft Undo reopens.
    var draft: MeasureToolDraft
}

/// Modification dates of the files the context depends on (nil when absent).
struct MeasureToolFileStamp: Equatable, Sendable {
    /// derived/clean.json.
    var clean: Date?
    /// edits/editlog.json.
    var editLog: Date?

    /// The current dates of `package`'s clean.json and edit log.
    static func current(_ package: ProjectPackage) -> MeasureToolFileStamp {
        MeasureToolFileStamp(clean: modified(package.cleanModelURL), editLog: modified(package.editLogURL))
    }

    /// A file's modification date, or nil when it is absent or unreadable.
    private static func modified(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
