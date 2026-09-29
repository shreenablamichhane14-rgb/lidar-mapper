import Foundation
import simd

// The work-queue pass of CoverageLiveRecorder (docs/MODULES.md 3.31) and the hub-queue gate that
// decides when a frame queues one. One pass, on "mapper.coverage.live":
// 0. expected inputs, when changed: boundary (live room or given), exclusions, watched sets,
//    expected marks (applied first, so the states below already show the red marks);
// 1. anchor refresh (at most every `anchorRefreshSeconds`): changed or new MeshStore anchors
//    rebuilt; stale anchors keep their faces (RESEARCH 3.1 gotcha 15); new anchors past the face
//    cap are skipped;
// 2. integration of the positive-area faces of the anchors that may be visible (first-seen
//    order), plus the shell samples when the D16 shell fallback is on. The grid's per-face stats
//    are keyed by position in this per-pass list and are never read (RESEARCH 3.8 gotcha 7);
// 3. states from `state(atVoxel:)` of each face's voxel for the visible, refreshed and
//    expected-mark-affected anchors; a new revision only when geometry or a state changed;
// 4. view coverage over every second in-view face;
// 5. evaluation (at most every `evaluationSeconds`): fraction, missing areas (D19 filter), ages,
//    nearby list, completeness, minimap;
// 6. watched fractions, then one locked publish.

/// What the frame callback does with one frame.
enum CoverageLiveFrameGate {
    /// Not recording: nothing to do.
    case idle
    /// Recording, but the rate says no.
    case notDue
    /// The thermal rate must be read again first.
    case checkRate
    /// Queue a pass for this frame (when tracking is normal and no pass is in flight).
    case due
}

extension CoverageLiveRecorder {
    // MARK: Frame gate (hub queue; lock only)

    /// The gate of one frame: two comparisons under the lock unless the rate is due for a check.
    func frameGate(_ timestamp: Double) -> CoverageLiveFrameGate {
        locked { () -> CoverageLiveFrameGate in
            guard recording else { return .idle }
            guard let checked = lastRateCheck, timestamp >= checked,
                  timestamp - checked < CoverageLiveRecorder.rateCheckSeconds else { return .checkRate }
            return CoverageLiveFaces.isDue(timestamp: timestamp, last: queuedBefore(timestamp), hz: currentHz) ? .due : .notDue
        }
    }

    /// Stores the rate read from the thermal policy (logged when it changes) and tells whether
    /// the frame at `timestamp` is due at that rate.
    func applyRate(_ hz: Double, level: ThermalLevel, timestamp: Double) -> Bool {
        let result = locked { () -> (due: Bool, changed: Bool) in
            let changed = !rateLogged || hz != currentHz
            currentHz = hz
            rateLogged = true
            lastRateCheck = timestamp
            let due = CoverageLiveFaces.isDue(timestamp: timestamp, last: queuedBefore(timestamp), hz: hz)
            return (due: due, changed: changed)
        }
        if result.changed {
            CoverageLiveRecorder.log("rate \(CoverageLiveRecorder.formatted(hz)) Hz (thermal \(level.rawValue))")
        }
        return result.due
    }

    /// The last queued frame time, ignored when it lies after `timestamp` (a restarted timebase).
    /// Call with the lock held.
    func queuedBefore(_ timestamp: Double) -> Double? {
        guard let last = lastQueuedTimestamp, last <= timestamp else { return nil }
        return last
    }

    /// Queues one pass unless a pass is in flight (then the frame is counted as skipped).
    /// False while not recording or busy.
    @discardableResult
    func enqueue(_ observation: CoverageObservation) -> Bool {
        locked { () -> Bool in
            guard recording else { return false }
            lastQueuedTimestamp = observation.timestamp
            guard !passInFlight else {
                skippedBusy += 1
                return false
            }
            passInFlight = true
            let gen = generation
            work.async { [self] in runPass(observation, generation: gen) }
            return true
        }
    }

    /// Records the frame-callback time; writes one line per recording after
    /// `CoverageLiveCallbackTiming.framesBeforeLog` frames once a due frame was timed.
    func noteCallback(nanos: UInt64, due: Bool) {
        let line = locked { () -> String? in
            guard !timing.logged else { return nil }
            timing.frames += 1
            if due {
                if timing.firstDueNanos == nil { timing.firstDueNanos = nanos }
            } else if nanos > timing.maxNotDueNanos {
                timing.maxNotDueNanos = nanos
            }
            guard timing.frames >= CoverageLiveCallbackTiming.framesBeforeLog, let first = timing.firstDueNanos else { return nil }
            timing.logged = true
            let dueMs = CoverageLiveRecorder.formatted(Double(first) / 1_000_000, digits: 3)
            let notDueMs = CoverageLiveRecorder.formatted(Double(timing.maxNotDueNanos) / 1_000_000, digits: 3)
            return "frame callback: first due \(dueMs) ms, slowest not due \(notDueMs) ms over \(timing.frames) frames"
        }
        if let line { CoverageLiveRecorder.log(line) }
    }

    // MARK: The pass (work queue)

    /// One pass for one observation (steps in the file header). Passes of an older recording are dropped.
    func runPass(_ observation: CoverageObservation, generation gen: Int) {
        defer { locked { () -> Void in passInFlight = false } }
        let s = state
        guard s.generation == gen else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let timestamp = observation.timestamp
        let elapsed = s.elapsed(at: timestamp)
        let changedKeys = applyInputsIfChanged()
        var refreshed = Set<UUID>()
        if CoverageLiveRecorder.intervalDue(last: s.lastAnchorRefresh, now: timestamp, interval: options.anchorRefreshSeconds) {
            refreshed = refreshAnchors()
            s.lastAnchorRefresh = timestamp
        }
        updateShellFallback(elapsed: elapsed)
        let visible = integrate(observation)
        let changed = updateStates(visible: visible, refreshed: refreshed, changedKeys: changedKeys)
        s.viewCoverage = viewCoverage(visible: visible, observation: observation)
        let evaluationDue = CoverageLiveRecorder.intervalDue(last: s.lastEvaluation, now: timestamp,
                                                             interval: options.evaluationSeconds)
        if s.forceEvaluation || evaluationDue {
            evaluate(observation: observation, elapsed: elapsed)
            s.lastEvaluation = timestamp
            s.forceEvaluation = false
        }
        s.watchedFractions = watchedFractionsNow()
        s.lastCamera = observation.cameraToWorld
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        s.lastPassMilliseconds = milliseconds
        if s.passTimes.count < CoverageLiveRecorder.maxPassTimes { s.passTimes.append(milliseconds) }
        publish(changed: changed, generation: gen)
        logPeriodically(timestamp: timestamp)
    }

    /// Step 0: applies the inputs when their version changed and returns the voxel keys whose
    /// expected mark changed (empty when nothing changed).
    func applyInputsIfChanged() -> Set<SIMD3<Int32>> {
        let s = state
        let applied = s.appliedInputsVersion
        guard let pending = locked({ () -> CoverageLiveInputs? in inputs.version != applied ? inputs : nil }) else { return [] }
        s.appliedInputsVersion = pending.version
        switch pending.expected {
        case .none:
            s.boundary = nil
            s.exclusions = []
            s.liveRoomMode = false
        case .liveRoom(let room):
            s.boundary = CoverageLiveBoundary.boundary(from: room)
            s.exclusions = CoverageLiveBoundary.exclusions(from: room, margin: options.exclusionMargin)
            s.liveRoomMode = true
        case .boundary(let boundary, let exclusions):
            s.boundary = boundary
            s.exclusions = exclusions
            s.liveRoomMode = false
        }
        s.watched = pending.watched
        let samples = s.boundary.map { ExpectedSurfaces.samples(for: $0) } ?? []
        s.shellFaces = samples.map { CoverageFace(centroid: $0.position, normal: $0.normal, area: $0.area, surface: $0.surface) }
        s.shellKeys = s.shellFaces.map { s.grid.key(for: $0.centroid) }
        var points = CoverageLiveBoundary.expectedPoints(samples, exclusions: s.exclusions)
        for key in s.watched.keys.sorted() { points.append(contentsOf: s.watched[key] ?? []) }
        var keys = Set<SIMD3<Int32>>()
        keys.reserveCapacity(points.count)
        for point in points { keys.insert(s.grid.key(for: point)) }
        let changed = keys.symmetricDifference(s.expectedKeys)
        s.grid.clearExpected()
        s.grid.markExpected(points)
        s.expectedKeys = keys
        return changed
    }

    /// Step 1: rebuilds the anchors whose MeshStore version changed and adds new ones (up to the
    /// face cap). Returns the rebuilt anchor ids.
    func refreshAnchors() -> Set<UUID> {
        let s = state
        var wanted = Set<UUID>()
        for (id, entry) in meshSource.index where !entry.isEvicted {
            if let known = s.anchors[id], known.value.updateCount == entry.updateCount { continue }
            wanted.insert(id)
        }
        guard !wanted.isEmpty else { return [] }
        var rebuilt = Set<UUID>()
        for chunk in meshSource.currentChunks() where wanted.contains(chunk.anchorID) {
            let id = chunk.anchorID
            let previousFaces = s.anchors[id]?.value.faces.count
            if previousFaces == nil, s.trackedFaces + chunk.faceCount > options.maxTrackedFaces {
                if !s.faceCapLogged {
                    s.faceCapLogged = true
                    CoverageLiveRecorder.log("face cap \(options.maxTrackedFaces) reached at \(s.trackedFaces) faces; "
                                             + "new anchors are left out")
                }
                continue
            }
            let anchor = makeAnchor(chunk)
            s.trackedFaces += anchor.value.faces.count - (previousFaces ?? 0)
            if previousFaces == nil { s.order.append(id) }
            s.anchors[id] = anchor
            rebuilt.insert(id)
        }
        return rebuilt
    }

    /// Faces, keys and bounds of one chunk version (states are computed in step 3).
    func makeAnchor(_ chunk: MeshChunk) -> CoverageLiveAnchorState {
        let world = chunk.worldPositions
        let faces = CoverageLiveFaces.faces(of: chunk, world: world)
        let keys = CoverageLiveFaces.keys(faces, grid: state.grid)
        let bounds = CoverageLiveFaces.worldBounds(world)
        let states = [CoverageState](repeating: .gray, count: faces.count)
        let value = CoverageAnchorFaces(anchorID: chunk.anchorID, updateCount: chunk.updateCount, transform: chunk.transform,
                                        localPositions: chunk.positions, localNormals: chunk.normals, indices: chunk.indices,
                                        faces: faces, states: states, boundsMin: bounds.min, boundsMax: bounds.max, revision: 0)
        return CoverageLiveAnchorState(value: value, perFaceKey: keys.perFace, uniqueKeys: keys.unique)
    }

    /// Turns the D16 shell fallback on while an expected room exists, no mesh face is tracked and
    /// `shellFallbackSeconds` passed; off otherwise (logged on every change).
    func updateShellFallback(elapsed: Double) {
        let s = state
        let on = s.boundary != nil && s.trackedFaces == 0 && !s.shellFaces.isEmpty && elapsed >= options.shellFallbackSeconds
        guard on != s.usesShellFallback else { return }
        s.usesShellFallback = on
        if on {
            CoverageLiveRecorder.log("shell fallback on after \(Int(elapsed)) s without mesh faces: "
                                     + "\(s.shellFaces.count) expected samples stand in (D16)")
        } else {
            CoverageLiveRecorder.log("shell fallback off (\(s.trackedFaces) mesh faces)")
        }
    }

    /// Step 2: integrates the observation; returns the anchors that may be visible.
    func integrate(_ observation: CoverageObservation) -> [UUID] {
        let s = state
        var visible: [UUID] = []
        var faces: [CoverageFace] = []
        for id in s.order {
            guard let anchor = s.anchors[id] else { continue }
            let value = anchor.value
            guard CoverageLiveFaces.mayBeVisible(boundsMin: value.boundsMin, boundsMax: value.boundsMax,
                                                 observation: observation) else { continue }
            visible.append(id)
            for face in value.faces where face.area > 0 { faces.append(face) }
        }
        if s.usesShellFallback { faces.append(contentsOf: s.shellFaces) }
        s.grid.integrate(observation: observation, faces: faces)
        s.integrations += 1
        s.lastIntegratedFaces = faces.count
        return visible
    }

    /// Step 3: new states for the visible, refreshed and expected-mark-affected anchors (all of
    /// them after a seed); returns the anchors that got a new revision.
    func updateStates(visible: [UUID], refreshed: Set<UUID>, changedKeys: Set<SIMD3<Int32>>) -> [CoverageAnchorFaces] {
        let s = state
        let all = s.forceAllStates
        s.forceAllStates = false
        let visibleSet = Set(visible)
        var changed: [CoverageAnchorFaces] = []
        for id in s.order {
            guard var anchor = s.anchors[id] else { continue }
            let geometryChanged = refreshed.contains(id)
            var needed = all || geometryChanged || visibleSet.contains(id)
            if !needed, !changedKeys.isEmpty, !changedKeys.isDisjoint(with: anchor.uniqueKeys) { needed = true }
            guard needed else { continue }
            let states = computeStates(anchor)
            guard geometryChanged || states != anchor.value.states else { continue }
            anchor.value.states = states
            anchor.value.revision = s.nextRevision()
            s.anchors[id] = anchor
            changed.append(anchor.value)
        }
        return changed
    }

    /// One state per face from its voxel; gray for area-0 faces.
    func computeStates(_ anchor: CoverageLiveAnchorState) -> [CoverageState] {
        let faces = anchor.value.faces
        let keys = anchor.perFaceKey
        var out = [CoverageState](repeating: .gray, count: faces.count)
        let count = min(faces.count, keys.count)
        let grid = state.grid
        for t in 0..<count where faces[t].area > 0 {
            out[t] = grid.state(atVoxel: keys[t])
        }
        return out
    }

    /// Step 4: green share of the in-view area over every second face of the visible anchors (and
    /// of the shell samples in the fallback); nil when under 0.05 m^2 is in view.
    func viewCoverage(visible: [UUID], observation: CoverageObservation) -> Float? {
        let s = state
        var total: Float = 0
        var green: Float = 0
        for id in visible {
            guard let anchor = s.anchors[id] else { continue }
            let faces = anchor.value.faces
            let states = anchor.value.states
            let count = min(faces.count, states.count)
            var t = 0
            while t < count {
                let face = faces[t]
                if face.area > 0, CoverageLiveFaces.isInView(face, observation: observation) {
                    total += face.area
                    if states[t] == .green { green += face.area }
                }
                t += 2
            }
        }
        if s.usesShellFallback {
            let shell = s.shellFaces
            let keys = s.shellKeys
            let grid = s.grid
            let count = min(shell.count, keys.count)
            var i = 0
            while i < count {
                let face = shell[i]
                if face.area > 0, CoverageLiveFaces.isInView(face, observation: observation) {
                    total += face.area
                    if grid.state(atVoxel: keys[i]) == .green { green += face.area }
                }
                i += 2
            }
        }
        // Every second face was sampled, so both sums stand for about half the in-view area.
        return CoverageLiveMissing.fraction(green: green * 2, total: total * 2, minimumTotal: CoverageLiveMissing.minimumViewArea)
    }

    /// Step 6: well-observed fraction of every watched set.
    func watchedFractionsNow() -> [Int: Float] {
        let s = state
        var out: [Int: Float] = [:]
        for (key, points) in s.watched {
            out[key] = CoverageLiveMissing.wellObservedFraction(points, grid: s.grid, radius: options.watchedRadius)
        }
        return out
    }

    /// The single locked publish of a pass (skipped when a newer recording began meanwhile).
    func publish(changed: [CoverageAnchorFaces], generation gen: Int) {
        let s = state
        let summary = CoverageLiveSummary(integrations: s.integrations, skippedBusy: 0, anchors: s.anchors.count,
                                          trackedFaces: s.trackedFaces, coverageFraction: s.coverageFraction,
                                          viewCoverage: s.viewCoverage, missingCount: s.missing.count,
                                          hasExpectedRoom: s.boundary != nil, usesShellFallback: s.usesShellFallback,
                                          effectiveHz: 0, lastPassMilliseconds: s.lastPassMilliseconds)
        var minimap = s.minimap
        if var map = minimap, let camera = s.lastCamera {
            let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            map.camera = Vec2(PlanAxes.toPlan(position))
            map.heading = CoverageLiveMinimap.heading(cameraToWorld: camera)
            minimap = map
        }
        let order = s.order
        let revision = s.revisionCounter
        let missing = s.missing
        let nearby = s.nearby
        let complete = s.overallComplete
        let liveRoom = s.liveRoomMode
        let watched = s.watchedFractions
        let camera = s.lastCamera
        locked { () -> Void in
            guard generation == gen else { return }
            for anchor in changed { published.anchors[anchor.anchorID] = anchor }
            published.order = order
            published.revision = revision
            published.summary = summary
            published.missing = missing
            published.nearby = nearby
            published.overallComplete = complete
            published.liveRoomMode = liveRoom
            published.minimap = minimap
            published.watched = watched
            published.camera = camera
        }
    }
}
