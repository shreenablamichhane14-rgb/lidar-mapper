import ARKit
import Foundation
import simd

/// Live coverage recorder. ScanRecorder calls arrive on the hub queue and only copy values; all
/// grid work runs on the private serial queue "mapper.coverage.live" (QoS utility) with at most one
/// pass queued (a due frame that finds a pass in flight is skipped and counted). Published values
/// are lock-protected, so readers and hooks are safe on any thread and never compute.
///
/// Not actor-isolated: the hook closures below are formed in plain (nonisolated) members, so they
/// can run on the hub queue under the Swift 6.2 runtime isolation checks. The pass itself lives in
/// CoverageLiveRecorder+Work.swift; the state types in CoverageLiveState.swift.
final class CoverageLiveRecorder: ScanRecorder {
    /// Log category of every line this module writes.
    static let logCategory = "coverage"
    /// Observation seconds between two periodic log lines.
    static let logIntervalSeconds: Double = 30
    /// Least seconds between two thermal rate checks in the frame callback.
    static let rateCheckSeconds: Double = 1
    /// Most pass durations kept for the periodic median.
    static let maxPassTimes = 2000

    /// The tunables of this recorder.
    let options: CoverageLiveOptions
    /// The live mesh of the same capture (read through `index` and `currentChunks()` only).
    let meshSource: MeshStore
    /// Serial work queue "mapper.coverage.live", QoS utility: every grid operation runs here.
    let work: DispatchQueue
    /// Work-queue state; touched only inside blocks running on `work`.
    let state: CoverageLiveWorkState

    // MARK: Lock-protected group (read and written only while holding `lock`)

    /// Guards the group below.
    let lock = NSLock()
    /// True between `beginRecording` and `finishRecording`; the generation counts recordings.
    var recording = false
    var generation = 0
    /// A pass is queued or running.
    var passInFlight = false
    /// Frame time of the last queued (or skipped-busy) observation and of the last rate check.
    var lastQueuedTimestamp: Double?
    var lastRateCheck: Double?
    /// Integration rate in use, Hz, and whether it was logged in this recording.
    var currentHz: Double = 0
    var rateLogged = false
    /// Due frames skipped because a pass was in flight.
    var skippedBusy = 0
    /// Expected-surface inputs and a seed waiting for the next recording.
    var inputs = CoverageLiveInputs()
    var pendingSeed: CoverageLiveSeed?
    /// What readers and hooks copy.
    var published = CoverageLivePublished()
    /// Frame-callback timing of this recording.
    var timing = CoverageLiveCallbackTiming()

    /// A recorder reading the live mesh of `meshSource`. Nothing runs until `beginRecording`.
    init(meshSource: MeshStore, options: CoverageLiveOptions = CoverageLiveOptions()) {
        self.meshSource = meshSource
        self.options = options
        work = DispatchQueue(label: "mapper.coverage.live", qos: .utility)
        state = CoverageLiveWorkState(voxelSize: options.voxelSize)
    }

    // MARK: ScanRecorder (hub queue)

    /// A fresh grid for this room or pass: everything is cleared except `options`. Writes nothing into `folder`.
    /// Expected surfaces, watched sets and a seed given while no recording ran are kept for this one
    /// (MissingAreas sets them before its pass starts); those of a finished recording are cleared.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        let wasRecording = locked { () -> Bool in
            let previous = recording
            recording = true
            generation += 1
            let gen = generation
            lastQueuedTimestamp = nil
            lastRateCheck = nil
            rateLogged = false
            skippedBusy = 0
            if !inputs.setWhileIdle { inputs.clear() }
            inputs.setWhileIdle = false
            let seed = pendingSeed
            pendingSeed = nil
            published = CoverageLivePublished(revision: published.revision)
            timing = CoverageLiveCallbackTiming()
            work.async { [self] in
                state.reset(generation: gen, startTimestamp: startTimestamp)
                if let seed { runSeed(seed, generation: gen) }
            }
            return previous
        }
        if wasRecording { CoverageLiveRecorder.log("begin while recording; the previous grid was dropped") }
        CoverageLiveRecorder.log("recording began in \(folder.url.lastPathComponent), mode \(profile.mode.rawValue), "
                                 + "cap \(options.maxHz) Hz, voxel \(options.voxelSize) m")
    }

    /// When due (rate below, tracking `.normal`, no pass in flight) copies one `CoverageObservation`
    /// (`camera.transform`, `camera.intrinsics`, `camera.imageResolution`, `ARFrameReading.meanConfidence(of:)`,
    /// `timestamp`) and queues one pass. A frame that is not due returns after two comparisons.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        let started = DispatchTime.now().uptimeNanoseconds
        let timestamp = frame.timestamp
        var gate = frameGate(timestamp)
        if gate == .checkRate {
            let level = hub.thermal.level
            let hz = CoverageLiveFaces.effectiveHz(maxHz: options.maxHz, policy: ThermalPolicy.forLevel(level))
            gate = applyRate(hz, level: level, timestamp: timestamp) ? .due : .notDue
        }
        switch gate {
        case .idle:
            return
        case .notDue, .checkRate:
            noteCallback(nanos: DispatchTime.now().uptimeNanoseconds &- started, due: false)
            return
        case .due:
            break
        }
        let camera = frame.camera
        guard TrackingMonitor.summary(camera.trackingState) == .normal else { return }
        let size = camera.imageResolution
        let observation = CoverageObservation(cameraToWorld: camera.transform, intrinsics: camera.intrinsics,
                                              imageResolution: SIMD2<Float>(Float(size.width), Float(size.height)),
                                              trackingNormal: true,
                                              depthConfidenceMean: ARFrameReading.meanConfidence(of: frame),
                                              timestamp: timestamp)
        enqueue(observation)
        noteCallback(nanos: DispatchTime.now().uptimeNanoseconds &- started, due: true)
    }

    /// Stops queuing, waits for the pass in flight, drops every per-anchor array (so `MeshStore.evict()`
    /// really frees memory, D17), keeps the last published values, then calls `completion` on the work queue.
    func finishRecording(completion: @escaping () -> Void) {
        locked { () -> Void in
            recording = false
            inputs.setWhileIdle = false
        }
        work.async { [self] in
            let anchors = state.anchors.count
            let faces = state.trackedFaces
            let passes = state.integrations
            let fraction = CoverageLiveRecorder.formatted(Double(state.coverageFraction))
            state.finish()
            locked { () -> Void in
                published.anchors = [:]
                published.order = []
            }
            CoverageLiveRecorder.log("recording finished: \(passes) passes, \(anchors) anchors and \(faces) faces "
                                     + "dropped, fraction \(fraction)")
            completion()
        }
    }

    /// Always zero: coverage records no raw data.
    var stats: RecorderStats { RecorderStats() }

    // MARK: Expected surfaces (any thread; applied at the next pass)

    /// The live RoomPlan room (RoomScanEngine.liveRoomHandler, at most 1 Hz). Turns on live-room
    /// mode (nearby missing areas and `overallComplete` for guidance). Ignored while no recording
    /// runs (a late live room must not become the next room's expectation).
    func setExpectedRoom(_ room: RoomInput) {
        locked { () -> Void in
            guard recording else { return }
            inputs.expected = .liveRoom(room)
            inputs.version += 1
        }
    }

    /// A boundary built elsewhere (a finished CleanRoom through `QualityInputs.boundary(for:)`), or nil
    /// to clear. Samples inside `exclusions` (window, door and opening boxes) are never expected.
    func setExpectedBoundary(_ boundary: CoverageRoomBoundary?, exclusions: [OrientedBox]) {
        locked { () -> Void in
            startStagingIfIdle()
            if let boundary {
                inputs.expected = .boundary(boundary, exclusions)
            } else {
                inputs.expected = .none
            }
            inputs.version += 1
            if !recording { inputs.setWhileIdle = true }
        }
    }

    /// Point sets to watch, keyed by the caller (MissingAreas: `MissingAreaRecord.id`). Their points are
    /// marked expected (they read red until observed) and their well-observed fraction is published
    /// after every pass. An empty dictionary clears them.
    func setWatchedAreas(_ areas: [Int: [SIMD3<Float>]]) {
        locked { () -> Void in
            startStagingIfIdle()
            inputs.watched = areas
            inputs.version += 1
            if !recording { inputs.setWhileIdle = true }
        }
    }

    /// Integrates earlier observations of the same place (a patch pass starting from the room pass)
    /// in order before any live pass, until `deadlineSeconds` of work-queue time; logs how many were used.
    /// A seed given while no recording runs waits for the next `beginRecording`.
    func seed(observations: [CoverageObservation], faces: [CoverageFace], deadlineSeconds: Double) {
        let seed = CoverageLiveSeed(observations: observations, faces: faces, deadlineSeconds: deadlineSeconds)
        let queued = locked { () -> Bool in
            guard recording else {
                pendingSeed = seed
                return false
            }
            let gen = generation
            work.async { [self] in runSeed(seed, generation: gen) }
            return true
        }
        if !queued { CoverageLiveRecorder.log("seed of \(observations.count) observations waits for the recording") }
    }

    // MARK: Engine hooks (hub queue; copy the latest published values)

    /// Sets `viewCoverage`; in live-room mode also `nearbyMissing` (options above) and `overallComplete`.
    func augment(_ input: inout GuidanceInput) {
        let values = locked { () -> (view: Float?, live: Bool, nearby: [MissingArea], complete: Bool) in
            (view: published.summary.viewCoverage, live: published.liveRoomMode, nearby: published.nearby,
             complete: published.overallComplete)
        }
        input.viewCoverage = values.view
        if values.live {
            input.nearbyMissing = values.nearby
            input.overallComplete = values.complete
        }
    }

    /// Sets `coverageFraction` and `minimap` (with `camera` and `heading`, CR-8).
    func augment(_ snapshot: inout LiveScanSnapshot) {
        let values = locked { () -> (fraction: Float, map: MinimapSnapshot?) in
            (fraction: published.summary.coverageFraction, map: published.minimap)
        }
        snapshot.coverageFraction = values.fraction
        if let map = values.map { snapshot.minimap = map }
    }

    /// Ready-made closures for `RoomScanEngine.liveRoomHandler`, `guidanceAugmenter` and
    /// `snapshotAugmenter` (and MeshScanEngine's two augmenters). They capture `self` weakly and are
    /// formed here, outside any actor: a closure formed inside a `@MainActor` method is main-actor
    /// isolated and must not be handed to a hub-queue hook (RoomCapture's `installHubClosures` rule).
    var liveRoomHook: (RoomInput) -> Void {
        return { [weak self] (room: RoomInput) -> Void in
            guard let self else { return }
            self.setExpectedRoom(room)
        }
    }
    /// See `liveRoomHook`.
    var guidanceHook: (inout GuidanceInput) -> Void {
        return { [weak self] (input: inout GuidanceInput) -> Void in
            guard let self else { return }
            self.augment(&input)
        }
    }
    /// See `liveRoomHook`.
    var snapshotHook: (inout LiveScanSnapshot) -> Void {
        return { [weak self] (snapshot: inout LiveScanSnapshot) -> Void in
            guard let self else { return }
            self.augment(&snapshot)
        }
    }

    // MARK: Readers (any thread)

    /// Anchors whose revision is greater than `revision`, and the newest revision (0 returns all).
    func anchorFaces(changedSince revision: UInt64) -> (revision: UInt64, anchors: [CoverageAnchorFaces]) {
        locked { () -> (revision: UInt64, anchors: [CoverageAnchorFaces]) in
            var list: [CoverageAnchorFaces] = []
            for id in published.order {
                guard let anchor = published.anchors[id], anchor.revision > revision else { continue }
                list.append(anchor)
            }
            return (revision: published.revision, anchors: list)
        }
    }

    /// Missing areas of the expected room after the exclusions, largest first.
    func currentMissingAreas() -> [MissingArea] {
        publishedValue(\.missing)
    }

    /// Well-observed fraction 0...1 per watched set (0 for a set no pass has looked at yet).
    func watchedFractions() -> [Int: Float] {
        locked { () -> [Int: Float] in
            var out = published.watched
            for key in inputs.watched.keys where out[key] == nil { out[key] = 0 }
            return out
        }
    }

    /// Diagnostics and simple UI values of the last pass.
    func summary() -> CoverageLiveSummary {
        locked { () -> CoverageLiveSummary in
            var value = published.summary
            value.skippedBusy = skippedBusy
            value.effectiveHz = currentHz
            return value
        }
    }

    /// Camera to world of the last integrated observation.
    func lastCameraTransform() -> simd_float4x4? {
        publishedValue(\.camera)
    }

    // MARK: Internal (self-test and the work extension)

    /// Queues one pass for `observation` like a due frame (no rate or tracking check here; the grid
    /// ignores observations whose `trackingNormal` is false). False while not recording or busy.
    @discardableResult
    func ingest(observation: CoverageObservation) -> Bool {
        enqueue(observation)
    }

    /// Blocks until every block queued on the work queue so far has run. Never call it on that queue.
    func waitForWork() {
        work.sync {}
    }

    /// State of the voxel containing `point` (self-test).
    func voxelState(at point: SIMD3<Float>) -> CoverageState {
        work.sync { state.grid.state(atVoxel: state.grid.key(for: point)) }
    }

    /// Anchors held on the work queue (self-test: zero after `finishRecording`).
    func workAnchorCount() -> Int {
        work.sync { state.anchors.count }
    }

    /// Faces handed to the last live integration (self-test: the shell fallback).
    func lastIntegratedFaceCount() -> Int {
        work.sync { state.lastIntegratedFaces }
    }

    /// Observations the last seed integrated.
    func seededObservationCount() -> Int {
        publishedValue(\.seeded)
    }

    /// Before the first input staged while no recording runs: drops the inputs a finished recording
    /// left behind, so only values staged since then reach the next `beginRecording`. Call with the
    /// lock held.
    func startStagingIfIdle() {
        guard !recording, !inputs.setWhileIdle else { return }
        inputs.clear()
    }

    /// Runs `body` while holding `lock`.
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// One published value, copied under the lock.
    func publishedValue<T>(_ path: KeyPath<CoverageLivePublished, T>) -> T {
        locked { published[keyPath: path] }
    }

    /// Writes one line in the "coverage" category.
    static func log(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }
}
