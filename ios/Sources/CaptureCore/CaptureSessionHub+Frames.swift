import ARKit
import simd

/// Per-callback work of `ARSessionHub` on its queue: frames, anchors, tracking, the watchdog,
/// the identity check, monitor changes, events and the throttled status.
extension ARSessionHub {
    /// Value copy of the per-frame facts the hub itself uses (never the ARFrame).
    struct FrameSample {
        /// `ARFrame.timestamp`.
        var timestamp: TimeInterval
        /// Camera to world.
        var transform: simd_float4x4
        /// Tracking state of the frame.
        var trackingState: ARCamera.TrackingState
        /// Whether the frame carried scene depth.
        var depthPresent: Bool
        /// Ambient light, lumens.
        var ambientIntensity: Float?
        /// Center distance and mean confidence, computed only when `hasDepthStats`.
        var centerDistance: Float?, depthConfidenceMean: Float?
        /// True when the depth statistics were computed for this sample.
        var hasDepthStats: Bool

        /// Copies the facts out of a frame; the depth statistics only when `depthStats`.
        init(frame: ARFrame, depthStats: Bool) {
            timestamp = frame.timestamp
            transform = frame.camera.transform
            trackingState = frame.camera.trackingState
            depthPresent = frame.sceneDepth != nil
            ambientIntensity = ARFrameReading.ambientIntensity(of: frame)
            hasDepthStats = depthStats
            if depthStats {
                centerDistance = ARFrameReading.centerDepth(of: frame)?.distance
                depthConfidenceMean = ARFrameReading.meanConfidence(of: frame)
            }
        }
    }

    /// Kinds of anchor callbacks.
    enum AnchorChange {
        /// `session(_:didAdd:)`, `session(_:didUpdate:)` and `session(_:didRemove:)`.
        case added, updated, removed
    }

    // MARK: - Frames

    /// Hub queue. Recorders, watchdog, diagnostics, `onFrame`, status; times the callback.
    func handleFrame(_ frame: ARFrame) {
        let started = DispatchTime.now().uptimeNanoseconds
        let sample = FrameSample(frame: frame, depthStats: statusIsDue)
        ingest(sample)
        diagnostics.logFirstFrame(frame)
        for recorder in recorders { recorder.hub(self, didUpdate: frame) }
        diagnostics.tick(frame: frame, meshAnchors: meshAnchorIDs.count, delegateIsHub: lastDelegateIsHub,
                         availableMemory: lastAvailableMemory ?? 0)
        onFrame?(frame)
        publishStatusIfDue(sample)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        if elapsed > slowestCallbackNanos { slowestCallbackNanos = elapsed }
    }

    /// Foreign queue. Copies the values the hub needs and hops them to the queue; recorders
    /// and `onFrame` never see this frame (the frame must not leave the callback).
    func handleForeignFrame(_ frame: ARFrame) {
        let sample = FrameSample(frame: frame, depthStats: true)
        noteForeignQueue("didUpdate frame")
        queue.async { [weak self] in
            guard let self else { return }
            self.ingest(sample)
            self.publishStatusIfDue(sample)
        }
    }

    /// Hub queue. Tracking history, last-frame facts and the watchdog.
    func ingest(_ sample: FrameSample) {
        lastFrameTimestamp = sample.timestamp
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        lastDepthPresent = sample.depthPresent
        tracking.update(sample.trackingState, timestamp: sample.timestamp)
        runWatchdog(sample)
    }

    /// Hub queue. Feeds the depth and mesh watchdog (only after `markScanStart`) and acts on
    /// its answer: a `.config` event and one re-apply, or a `.degraded` event.
    func runWatchdog(_ sample: FrameSample) {
        guard scanStartTimestamp != nil else { return }
        let depthPresent = expectsDepth ? sample.depthPresent : true
        let meshCount = expectsMesh ? meshAnchorIDs.count : 1
        let action = watchdog.observe(timestamp: sample.timestamp, depthPresent: depthPresent,
                                      meshAnchorCount: meshCount, trackingNormal: tracking.summary == .normal)
        switch action {
        case .none:
            break
        case .reapply(let reason):
            emit(.config, "watchdog: \(reason); re-applying the configuration")
            reapplyConfiguration(reason: reason)
        case .degrade(let mode):
            applyDegraded(mode)
        }
    }

    // MARK: - Anchors, tracking, interruptions

    /// Any queue. On the hub queue: updates the mesh anchor identifiers and fans out to
    /// recorders. Elsewhere: only the identifiers hop over (the anchors must not leave the call).
    func handleAnchors(_ anchors: [ARAnchor], change: AnchorChange) {
        let meshIDs = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard isOnQueue else {
            noteForeignQueue("anchors \(change)")
            queue.async { [weak self] in self?.recordMeshIDs(meshIDs, change: change) }
            return
        }
        recordMeshIDs(meshIDs, change: change)
        for recorder in recorders {
            switch change {
            case .added: recorder.hub(self, didAdd: anchors)
            case .updated: recorder.hub(self, didUpdate: anchors)
            case .removed: recorder.hub(self, didRemove: anchors)
            }
        }
    }

    /// Hub queue. Keeps `meshAnchorIDs` current.
    func recordMeshIDs(_ ids: [UUID], change: AnchorChange) {
        switch change {
        case .added, .updated: meshAnchorIDs.formUnion(ids)
        case .removed: meshAnchorIDs.subtract(ids)
        }
    }

    /// Hub queue. A `.tracking` event per change and a `.relocalization` event when
    /// relocalizing starts.
    func handleTrackingChange(_ summary: TrackingSummary) {
        guard summary != lastReportedTracking else { return }
        lastReportedTracking = summary
        emit(.tracking, summary.rawValue)
        if summary == .relocalizing { emit(.relocalization, "relocalizing") }
        requestStatusPublish()
    }

    /// Hub queue. Interruption start or end: flag, event and status.
    func handleInterruption(started: Bool) {
        interrupted = started
        emit(.tracking, started ? ARSessionHub.interruptedDetail : ARSessionHub.interruptionEndedDetail)
        requestStatusPublish()
    }

    // MARK: - Once-per-second checks

    /// Hub queue, every second while running: delegate and delegate-queue identity (re-asserts
    /// the queue, installs `ARDelegateRelay` when another object took the delegate and
    /// `SettingsKey.captureRelay` is on), a status when frames stopped, the 30 s memory event
    /// and the slowest frame callback.
    func runChecks() {
        checkDelegateIdentity()
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFrameUptime, now - last > 0.5 { requestStatusPublish() }
        if now - lastMemoryEventUptime >= ARSessionHub.memoryEventInterval {
            lastMemoryEventUptime = now
            let available = MemoryProbe.availableBytes()
            emit(.memory, "available \(available / 1_000_000) MB, state \(statusValue.memory.rawValue)")
        }
        if slowestCallbackNanos > 8_000_000 {
            CaptureCoreLog.write("slowest frame callback \(slowestCallbackNanos / 1_000_000) ms in the last second")
        }
        slowestCallbackNanos = 0
    }

    /// Hub queue. Logs `session.delegate === hub` and `session.delegateQueue === queue` (every
    /// second for 30 s, then on problems and every 30 s), re-asserts only the queue, and
    /// installs a relay when the delegate was replaced (a nil delegate is simply re-set).
    func checkDelegateIdentity() {
        identityChecks += 1
        let current = session.delegate
        let relay = currentRelay
        let delegateIsHub = current === self
        let relayActive = relay != nil && current === relay
        let queueIsHub = session.delegateQueue === queue
        lastDelegateIsHub = delegateIsHub
        let healthy = (delegateIsHub || relayActive) && queueIsHub
        if identityChecks <= 30 || identityChecks % 30 == 0 || !healthy {
            CaptureCoreLog.write("identity: delegate === hub \(delegateIsHub), relay \(relayActive), "
                                 + "delegateQueue === queue \(queueIsHub)")
        }
        if !queueIsHub {
            session.delegateQueue = queue
            emit(.config, "delegate queue was replaced; re-asserted")
        }
        guard !delegateIsHub, !relayActive else { return }
        guard let replacement = current else {
            session.delegate = self
            emit(.config, "session delegate was nil; hub re-set")
            return
        }
        let name = String(describing: type(of: replacement))
        guard SettingsKey.captureRelayEnabled else {
            CaptureCoreLog.once("relay.disabled", "delegate replaced by \(name); relay disabled in Diagnostics")
            return
        }
        guard relayInstalls < ARSessionHub.maxRelayInstalls else {
            CaptureCoreLog.once("relay.limit", "delegate replaced by \(name) again; relay limit reached")
            return
        }
        let newRelay = ARDelegateRelay(hub: self, previous: replacement)
        setRelay(newRelay)
        session.delegate = newRelay
        relayInstalls += 1
        emit(.config, "delegate replaced by \(name); relay installed (\(relayInstalls))")
    }

    // MARK: - Monitor changes (hub queue)

    /// Thermal level changed: `.thermal` event and a status.
    func handleThermalChange(_ level: ThermalLevel) {
        emit(.thermal, level.rawValue)
        requestStatusPublish()
    }

    /// Storage state changed: `.note` event and a status.
    func handleStorageChange(_ state: StorageState) {
        emit(.note, "storage \(state.rawValue), free \(storage.freeBytes / 1_000_000) MB")
        requestStatusPublish()
    }

    // MARK: - Events and degraded mode (hub queue)

    /// Writes a capture event to the log and `onCaptureEvent`; `t` is seconds since
    /// `markScanStart` at the latest frame (0 before).
    func emit(_ kind: CaptureEventKind, _ detail: String) {
        var t: Double = 0
        if let start = scanStartTimestamp, let last = lastFrameTimestamp { t = max(0, last - start) }
        CaptureCoreLog.write("event \(kind.rawValue) t=\(String(format: "%.2f", t)): \(detail)")
        onCaptureEvent?(CaptureEvent(t: t, kind: kind, detail: detail))
    }

    /// Raises the degraded mode (meshStripped outranks depthStripped; never lowered until
    /// `markScanStart`), with a `.degraded` event.
    func applyDegraded(_ mode: DegradedMode) {
        guard ARSessionHub.rank(mode) > ARSessionHub.rank(degradedValue) else { return }
        degradedValue = mode
        emit(.degraded, mode.rawValue)
        requestStatusPublish()
    }

    /// Severity order of degraded modes.
    static func rank(_ mode: DegradedMode) -> Int {
        switch mode {
        case .allGood: return 0
        case .depthStripped: return 1
        case .meshStripped: return 2
        case .roomPlanFailed: return 3
        }
    }

    // MARK: - Status (hub queue, at most 4 Hz)

    /// True when a status publish is due (frames compute depth statistics only then).
    var statusIsDue: Bool {
        ProcessInfo.processInfo.systemUptime - lastStatusPublish >= ARSessionHub.statusInterval
    }

    /// Publishes a status built with this frame sample when 0.25 s passed since the last one.
    func publishStatusIfDue(_ sample: FrameSample) {
        guard statusIsDue else { return }
        publishStatus(sample, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Publishes now when allowed, else once at the end of the current 0.25 s interval.
    func requestStatusPublish() {
        let now = ProcessInfo.processInfo.systemUptime
        let wait = ARSessionHub.statusInterval - (now - lastStatusPublish)
        if wait <= 0 {
            publishStatus(nil, now: now)
            return
        }
        guard !statusPublishScheduled else { return }
        statusPublishScheduled = true
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.statusPublishScheduled = false
            if self.statusIsDue { self.publishStatus(nil, now: ProcessInfo.processInfo.systemUptime) }
        }
    }

    /// Builds the status from the monitors (and the frame sample when given), samples memory
    /// (`MemoryPolicy`, two consecutive ticks; `.memory` event on change), stores it and calls
    /// `onStatus`.
    func publishStatus(_ sample: FrameSample?, now: TimeInterval) {
        lastStatusPublish = now
        let available = MemoryProbe.availableBytes()
        let warned = memoryWarningPending
        let memoryState = MemoryPolicy.state(available: available, previous: lastAvailableMemory, warning: warned)
        memoryWarningPending = false
        lastAvailableMemory = available
        if memoryState != lastMemoryState {
            lastMemoryState = memoryState
            let cause = warned ? " after a memory warning" : ""
            emit(.memory, "memory \(memoryState.rawValue)\(cause), available \(available / 1_000_000) MB")
        }
        var next = statusValue
        next.tracking = tracking.summary
        next.degraded = degradedValue
        next.thermal = thermal.level
        next.storage = storage.state
        next.freeBytes = storage.freeBytes
        next.availableMemory = available
        next.memory = memoryState
        next.depthPresent = lastDepthPresent
        next.meshAnchorCount = meshAnchorIDs.count
        next.interrupted = interrupted
        if let start = scanStartTimestamp, let last = lastFrameTimestamp { next.elapsed = max(0, last - start) }
        if let sample {
            applyFrameFacts(sample, to: &next)
        }
        statusValue = next
        onStatus?(next)
    }

    /// Copies light, depth statistics and the speeds since the previous status into `status`.
    private func applyFrameFacts(_ sample: FrameSample, to status: inout HubStatus) {
        status.ambientIntensity = sample.ambientIntensity
        if sample.hasDepthStats {
            status.centerDistance = sample.centerDistance
            status.depthConfidenceMean = sample.depthConfidenceMean
        }
        if let previous = lastPose {
            let seconds = sample.timestamp - previous.timestamp
            if seconds > 0 && seconds < 2 {
                status.angularSpeed = ARFrameReading.angularSpeed(from: previous.transform, to: sample.transform,
                                                                  seconds: seconds)
                status.linearSpeed = ARFrameReading.linearSpeed(from: previous.transform, to: sample.transform,
                                                                seconds: seconds)
            }
        }
        lastPose = (sample.timestamp, sample.transform)
    }
}
