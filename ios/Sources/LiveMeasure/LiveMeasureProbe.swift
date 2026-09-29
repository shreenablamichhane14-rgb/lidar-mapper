import Foundation
import ARKit
import simd

// Quick Measure's hub recorder (MODULES 3.36, ARCHITECTURE 4.6): it copies ARKit plane anchors
// and 10 Hz center depth samples out of the hub callbacks and records nothing to disk. It also
// owns the guidance pipeline of Quick Measure (Coverage's `GuidanceEngine` confined to the hub
// queue, tier 1 messages only) and forwards relocalization and session failures to main.
// A plain class, never main-actor isolated: every hub closure is formed here, outside any actor.

/// Which way a detected plane faces (`ARPlaneAnchor.alignment`).
enum LiveMeasurePlaneFacing: Equatable, Sendable {
    /// Floors, tables, seats and ceilings.
    case horizontal
    /// Walls, doors and windows.
    case vertical
}

/// What ARKit thinks a detected plane is (`ARPlaneAnchor.classification`).
enum LiveMeasurePlaneKind: Equatable, Sendable {
    /// ARKit plane classifications, plus `unknown` for `.none(_)` and future cases.
    case wall, floor, ceiling, table, seat, door, window, unknown
}

/// An `ARPlaneAnchor` copied on the hub queue (the anchor itself is never kept).
struct LiveMeasurePlane: Equatable, Sendable {
    /// `ARAnchor.identifier`.
    var id: UUID
    /// Anchor to world.
    var transform: simd_float4x4
    /// Anchor-local center of the extent.
    var center: SIMD3<Float>
    /// `planeExtent.width` (local x) and `planeExtent.height` (local z), meters.
    var width: Float
    var length: Float
    /// `planeExtent.rotationOnYAxis`, radians (applied by us, RESEARCH 3.1 gotcha 17).
    var rotationOnYAxis: Float
    /// Horizontal or vertical.
    var facing: LiveMeasurePlaneFacing
    /// ARKit's classification.
    var kind: LiveMeasurePlaneKind

    /// Field-wise equality (the transform is compared column by column).
    static func == (lhs: LiveMeasurePlane, rhs: LiveMeasurePlane) -> Bool {
        guard lhs.id == rhs.id, lhs.center == rhs.center else { return false }
        guard lhs.width == rhs.width, lhs.length == rhs.length else { return false }
        guard lhs.rotationOnYAxis == rhs.rotationOnYAxis else { return false }
        guard lhs.facing == rhs.facing, lhs.kind == rhs.kind else { return false }
        return LiveMeasureMatrix.equal(lhs.transform, rhs.transform)
    }
}

/// One center-of-view sample (10 Hz).
struct LiveMeasureDepthSample: Equatable, Sendable {
    /// `ARFrame.timestamp`, seconds.
    var timestamp: Double
    /// `ARFrameReading.centerDepth(of:)`: median depth of the 5 x 5 center pixels and their confidence 0...1.
    var distance: Float?
    var confidence: Float?
    /// True when the frame's tracking state was `.normal`.
    var trackingNormal: Bool
    /// `ARCamera.transform` of the frame.
    var cameraToWorld: simd_float4x4

    /// Field-wise equality (the transform is compared column by column).
    static func == (lhs: LiveMeasureDepthSample, rhs: LiveMeasureDepthSample) -> Bool {
        guard lhs.timestamp == rhs.timestamp, lhs.distance == rhs.distance else { return false }
        guard lhs.confidence == rhs.confidence, lhs.trackingNormal == rhs.trackingNormal else { return false }
        return LiveMeasureMatrix.equal(lhs.cameraToWorld, rhs.cameraToWorld)
    }
}

/// Small matrix helpers shared by the LiveMeasure value types. Pure.
enum LiveMeasureMatrix {
    /// True when all four columns are equal.
    static func equal(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        let first = a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1
        let second = a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
        return first && second
    }

    /// The translation of a rigid transform (its fourth column).
    static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// `m` applied to the point `p`.
    static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let moved = m * SIMD4<Float>(p, 1)
        return SIMD3<Float>(moved.x, moved.y, moved.z)
    }
}

/// Hub recorder of Quick Measure: copies plane anchors and 10 Hz center samples; records nothing.
/// Callbacks on the hub queue; readers lock-protected, any thread.
final class LiveMeasureProbe: ScanRecorder {
    /// Shortest time between two center samples, seconds.
    static let sampleInterval: TimeInterval = 0.1
    /// Samples kept, seconds.
    static let windowSeconds: Double = 5
    /// Most plane anchors kept (ARKit merges planes, so a room rarely has more than a few dozen).
    static let maxPlanes = 256

    // MARK: Lock-protected state (any thread)

    /// Guards the lock-protected group.
    private let lock = NSLock()
    /// Copied plane anchors by identifier.
    private var planeTable: [UUID: LiveMeasurePlane] = [:]
    /// Center samples of the last `windowSeconds`, oldest first.
    private var samples: [LiveMeasureDepthSample] = []
    /// Backing stores of the main-queue callbacks.
    private var guidanceHandler: ((GuidanceKind?) -> Void)?
    private var relocalizationHandler: (() -> Void)?
    private var failureHandler: (() -> Void)?
    /// True from `install` until the first frame marked the scan start.
    private var needsScanStart = false

    // MARK: Hub-queue state

    /// Timestamp of the last center sample.
    private var lastSampleTimestamp: TimeInterval?
    /// Guidance state machine, confined to the hub queue.
    private var engine = GuidanceEngine()
    /// The last guidance delivered to main, and whether anything was delivered yet.
    private var lastGuidance: GuidanceKind?
    private var guidanceDelivered = false

    /// Creates an empty probe.
    init() {}

    // MARK: Callbacks to main

    /// Main-queue callbacks carrying values only.
    var onGuidance: ((GuidanceKind?) -> Void)? {
        get { locked { guidanceHandler } }
        set { locked { guidanceHandler = newValue } }
    }
    /// Main queue: a `.relocalization` capture event arrived.
    var onRelocalization: (() -> Void)? {
        get { locked { relocalizationHandler } }
        set { locked { relocalizationHandler = newValue } }
    }
    /// Main queue: the session failed (an `.error` event with `ARSessionHub.sessionFailedPrefix`).
    var onSessionFailed: (() -> Void)? {
        get { locked { failureHandler } }
        set { locked { failureHandler = newValue } }
    }

    // MARK: ScanRecorder (hub queue)

    /// Unused (Quick Measure has no raw folder); resets the samples.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        locked { samples.removeAll() }
        lastSampleTimestamp = nil
    }

    /// Marks the scan start on the first frame after `install`, then keeps one center sample per
    /// `sampleInterval` (depth, confidence, tracking and camera pose, copied inside the call).
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        let timestamp = frame.timestamp
        let markStart = locked { () -> Bool in
            let due = needsScanStart
            needsScanStart = false
            return due
        }
        if markStart { hub.markScanStart(timestamp: timestamp) }
        if let last = lastSampleTimestamp, timestamp >= last, timestamp - last < LiveMeasureProbe.sampleInterval {
            return
        }
        lastSampleTimestamp = timestamp
        let depth = ARFrameReading.centerDepth(of: frame)
        let normal = TrackingMonitor.summary(frame.camera.trackingState) == .normal
        let sample = LiveMeasureDepthSample(timestamp: timestamp, distance: depth?.distance,
                                            confidence: depth?.confidence, trackingNormal: normal,
                                            cameraToWorld: frame.camera.transform)
        append(sample)
    }

    /// Copies added plane anchors.
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor]) {
        store(anchors)
    }

    /// Copies updated plane anchors.
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor]) {
        store(anchors)
    }

    /// Forgets removed plane anchors.
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARPlaneAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        locked { () -> Void in
            for id in ids { planeTable[id] = nil }
        }
    }

    /// Calls `completion` at once.
    func finishRecording(completion: @escaping () -> Void) {
        completion()
    }

    /// Quick Measure records nothing, so every counter stays zero.
    var stats: RecorderStats { RecorderStats() }

    // MARK: Readers (any thread)

    /// The copied planes, sorted by identifier so callers see a stable order.
    func planes() -> [LiveMeasurePlane] {
        let values = locked { Array(planeTable.values) }
        return values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The center samples of the last `windowSeconds`, oldest first.
    func recentSamples() -> [LiveMeasureDepthSample] {
        locked { samples }
    }

    // MARK: Hub hooks

    /// Installs the hub's `onStatus` (guidance through a `GuidanceEngine` confined to hub.queue, then
    /// `LiveMeasureSnapping.filterGuidance`, then `onGuidance` on main) and `onCaptureEvent`
    /// (`.relocalization` events to `onRelocalization` on main), both capturing `self` weakly. The
    /// probe is a plain class, so these closures are formed outside any actor; the `@MainActor` model
    /// never forms hub-queue closures itself. The first frame after install calls
    /// `hub.markScanStart(timestamp:)`.
    func install(on hub: ARSessionHub) {
        locked { needsScanStart = true }
        hub.queue.async { [weak self] in self?.resetGuidance() }
        hub.onStatus = { [weak self] status in self?.handleStatus(status) }
        hub.onCaptureEvent = { [weak self] event in self?.handleEvent(event) }
        LiveMeasureProbe.log("probe installed")
    }

    /// Clears the two hub closures. Idempotent.
    func uninstall(from hub: ARSessionHub) {
        hub.onStatus = nil
        hub.onCaptureEvent = nil
    }

    // MARK: Pure mappings

    /// Hub queue. The value copy of one plane anchor (ARKit).
    static func planeRecord(from anchor: ARPlaneAnchor) -> LiveMeasurePlane {
        let extent = anchor.planeExtent
        let facing: LiveMeasurePlaneFacing
        switch anchor.alignment {
        case .horizontal:
            facing = .horizontal
        case .vertical:
            facing = .vertical
        @unknown default:
            facing = abs(anchor.transform.columns.1.y) > 0.7 ? .horizontal : .vertical
        }
        return LiveMeasurePlane(id: anchor.identifier, transform: anchor.transform, center: anchor.center,
                                width: extent.width, length: extent.height, rotationOnYAxis: extent.rotationOnYAxis,
                                facing: facing, kind: kind(anchor.classification))
    }

    /// Pure mapping; `.none(_)` and unknown cases give `.unknown`.
    static func kind(_ classification: ARPlaneAnchor.Classification) -> LiveMeasurePlaneKind {
        switch classification {
        case .wall: return .wall
        case .floor: return .floor
        case .ceiling: return .ceiling
        case .table: return .table
        case .seat: return .seat
        case .door: return .door
        case .window: return .window
        case .none(_): return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: Private (hub queue)

    /// Stores the plane anchors among `anchors` (capped at `maxPlanes`).
    private func store(_ anchors: [ARAnchor]) {
        var records: [LiveMeasurePlane] = []
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            records.append(LiveMeasureProbe.planeRecord(from: plane))
        }
        guard !records.isEmpty else { return }
        locked { () -> Void in
            for record in records where planeTable[record.id] != nil || planeTable.count < LiveMeasureProbe.maxPlanes {
                planeTable[record.id] = record
            }
        }
    }

    /// Appends a sample and drops those older than `windowSeconds` before it.
    private func append(_ sample: LiveMeasureDepthSample) {
        locked { () -> Void in
            samples.append(sample)
            let oldest = sample.timestamp - LiveMeasureProbe.windowSeconds
            samples.removeAll { $0.timestamp < oldest || $0.timestamp > sample.timestamp }
        }
    }

    /// Clears the guidance state for a new session.
    private func resetGuidance() {
        engine.reset()
        lastGuidance = nil
        guidanceDelivered = false
    }

    /// Hub queue, at most 4 Hz: one guidance tick; a change is forwarded to main.
    private func handleStatus(_ status: HubStatus) {
        let input = LiveMeasureSnapping.guidanceInput(time: ProcessInfo.processInfo.systemUptime, status: status)
        let output = LiveMeasureSnapping.filterGuidance(engine.update(input))
        let kind = output.message
        if guidanceDelivered && kind == lastGuidance { return }
        guidanceDelivered = true
        lastGuidance = kind
        guard let handler = onGuidance else { return }
        DispatchQueue.main.async { handler(kind) }
    }

    /// Hub queue: relocalization and session failures go to main.
    private func handleEvent(_ event: CaptureEvent) {
        switch event.kind {
        case .relocalization:
            LiveMeasureProbe.log("relocalization event: \(event.detail)")
            guard let handler = onRelocalization else { return }
            DispatchQueue.main.async { handler() }
        case .error:
            guard event.detail.hasPrefix(ARSessionHub.sessionFailedPrefix) else { return }
            LiveMeasureProbe.log("session failure event: \(event.detail)")
            guard let handler = onSessionFailed else { return }
            DispatchQueue.main.async { handler() }
        default:
            break
        }
    }

    /// Runs `body` while holding `lock`.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// One line in the app log (category "livemeasure").
    static func log(_ message: String) {
        LogStore.shared.write(message, category: "livemeasure")
    }
}
