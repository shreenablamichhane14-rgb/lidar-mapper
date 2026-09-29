import ARKit
import Foundation
import simd

// The large-object hub recorder (docs/MODULES.md 3.39): on the hub queue it only copies the
// camera pose at most 10 times a second; once a seed is set it schedules a 1 Hz pass on its own
// serial queue "mapper.largeobject" (QoS utility) that regrows the box from CoverageLive's faces,
// updates the sector coverage and decides the object message (`LargeObjectPass.run` in
// LargeObjectTrackerPass.swift). The last state stays readable after `finishRecording`, so the
// model can still write the crop edit when the engine stopped the pass by itself.
// The message reaches Coverage's GuidanceEngine through `extraConditions` (CR-9) in the engine's
// guidance hook. Every value shared between queues is guarded by one lock; readers are safe on
// any thread and never compute. Not actor-isolated: the hook closure is formed here, outside any
// actor, so it can run on the hub queue.

/// Tracker state for the model (any thread copy).
struct LargeObjectTrackerState: Equatable {
    /// The latest box.
    var box: OrientedBox?
    /// Floor height in use.
    var floorY: Float?
    /// Regions covered and required (0 of 0 before the first box).
    var covered: Int
    var required: Int
    /// The object message decided by the last pass.
    var guidance: GuidanceKind?
    /// Passes run for the current seed.
    var passes: Int

    /// Nothing tracked yet.
    static let initial = LargeObjectTrackerState(box: nil, floorY: nil, covered: 0, required: 0, guidance: nil, passes: 0)
}

/// Hub recorder plus a 1 Hz pass on its own serial queue "mapper.largeobject" (QoS utility).
final class LargeObjectTracker: ScanRecorder {
    /// Seconds between two copied camera poses.
    static let poseInterval: Double = 0.1
    /// Seconds between two passes.
    static let passInterval: Double = 1.0
    /// Longest time one pose stands for (frame gaps are not counted as viewing), seconds.
    static let maxPoseSeconds: Double = 0.25
    /// Most poses kept between two passes.
    static let maxBufferedPoses = 100
    /// Most pass durations kept for the summary line.
    static let maxPassTimes = 2000
    /// Passes slower than this are logged, milliseconds (target: under 50 ms for 300k tracked faces).
    static let slowPassMilliseconds: Double = 50
    /// A pass line is logged every this many passes.
    static let passLogInterval = 30
    /// A box change larger than this on any side is logged, meters.
    static let boxLogChange: Float = 0.05
    /// Tolerance of the interval checks, seconds (float rounding of frame times).
    static let dueTolerance: Double = 1e-4

    /// The live coverage of the same pass (faces and their states).
    let coverage: CoverageLiveRecorder
    /// Serial pass queue "mapper.largeobject", QoS utility.
    let queue: DispatchQueue

    // MARK: Lock-protected state

    /// Guards every property below.
    private let lock = NSLock()
    /// True between `beginRecording` and `finishRecording`.
    private var recording = false
    /// The seed, the floor found at the tap, and the camera position at the tap.
    private var seed: SIMD3<Float>?
    private var seedFloorY: Float?
    private var front: SIMD3<Float>?
    /// Increases with every seed change, so a pass started for an older seed is dropped.
    private var seedGeneration = 0
    /// Poses copied since the last pass.
    private var poses: [LargeObjectPose] = []
    /// Frame time of the last copied pose and of the last scheduled pass.
    private var lastPoseTimestamp: TimeInterval?
    private var lastPassTimestamp: TimeInterval?
    /// A pass is queued or running.
    private var passInFlight = false
    /// The latest copied camera transform.
    private var latestCamera: simd_float4x4?
    /// Sector coverage of the current seed.
    private var sectors: SectorCoverage?
    /// What `current()` returns.
    private var published = LargeObjectTrackerState.initial
    /// Pass durations of this recording, milliseconds.
    private var passTimes: [Double] = []
    /// The last logged box.
    private var loggedBox: OrientedBox?

    /// A tracker reading the faces of `coverage`. Nothing runs until `beginRecording`.
    init(coverage: CoverageLiveRecorder) {
        self.coverage = coverage
        queue = DispatchQueue(label: "mapper.largeobject", qos: .utility)
    }

    // MARK: - ScanRecorder (hub queue)

    /// Resets the seed, box and sectors.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        locked { () -> Void in
            recording = true
            clearSeedState()
            seed = nil
            seedFloorY = nil
            front = nil
            lastPoseTimestamp = nil
            latestCamera = nil
            passTimes = []
        }
        LargeObjectLog.write("tracker began in \(folder.url.lastPathComponent), mode \(profile.mode.rawValue)")
    }

    /// Every 0.1 s copies the camera transform and tracking state; the pass (below) runs every second.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        let timestamp = frame.timestamp
        let due = locked { () -> Bool in
            guard recording else { return false }
            return LargeObjectTracker.isDue(timestamp, last: lastPoseTimestamp, interval: LargeObjectTracker.poseInterval)
        }
        guard due else { return }
        let camera = frame.camera
        let transform = camera.transform
        let normal = TrackingMonitor.summary(camera.trackingState) == .normal
        let schedule = locked { () -> Bool in
            guard recording else { return false }
            let seconds = lastPoseTimestamp.map { min(max(timestamp - $0, 0), LargeObjectTracker.maxPoseSeconds) }
                ?? LargeObjectTracker.poseInterval
            lastPoseTimestamp = timestamp
            latestCamera = transform
            guard seed != nil else { return false }
            poses.append(LargeObjectPose(cameraToWorld: transform, seconds: seconds, trackingNormal: normal))
            if poses.count > LargeObjectTracker.maxBufferedPoses {
                poses.removeFirst(poses.count - LargeObjectTracker.maxBufferedPoses)
            }
            guard !passInFlight,
                  LargeObjectTracker.isDue(timestamp, last: lastPassTimestamp, interval: LargeObjectTracker.passInterval)
            else { return false }
            passInFlight = true
            lastPassTimestamp = timestamp
            return true
        }
        if schedule {
            queue.async { [weak self] in self?.runPass() }
        }
    }

    /// Stops copying poses, waits for the pass in flight, logs the pass times, then calls
    /// `completion` on the tracker queue. The last box, sectors and message stay readable.
    func finishRecording(completion: @escaping () -> Void) {
        locked { () -> Void in
            recording = false
            poses = []
        }
        queue.async { [weak self] in
            self?.logSummary()
            completion()
        }
    }

    /// Always zero: the tracker records no raw data (its log is an attachment of the finish).
    var stats: RecorderStats { RecorderStats() }

    // MARK: - Seed (any thread)

    /// Any thread. A new seed (nil clears); `front` is the camera position at the tap. A pass for
    /// the new seed runs at the next frame.
    func setSeed(_ seed: SIMD3<Float>?, floorY: Float?, front: SIMD3<Float>?) {
        let valid = LargeObjectTracker.finitePoint(seed)
        let floor: Float? = valid == nil ? nil : LargeObjectTracker.finiteValue(floorY)
        let camera: SIMD3<Float>? = valid == nil ? nil : LargeObjectTracker.finitePoint(front)
        locked { () -> Void in
            clearSeedState()
            self.seed = valid
            self.seedFloorY = floor
            self.front = camera
        }
        if let point = valid {
            LargeObjectLog.write("seed set at \(LargeObjectTracker.text(point)), floor \(LargeObjectTracker.floorText(floor))")
        } else {
            LargeObjectLog.write("seed cleared")
        }
    }

    /// Clears everything that belongs to one seed (call with the lock held).
    private func clearSeedState() {
        seedGeneration += 1
        sectors = nil
        published = LargeObjectTrackerState.initial
        poses = []
        lastPassTimestamp = nil
        loggedBox = nil
    }

    // MARK: - Guidance (hub queue)

    /// Hub queue: `apply(decision:to:)` with the latest object message.
    func augment(_ input: inout GuidanceInput) {
        let decision = locked { published.guidance }
        LargeObjectTracker.apply(decision: decision, to: &input)
    }

    /// Pure: `extraConditions` = [decision] (empty for nil, CR-9); `viewCoverage` = nil and
    /// `nearbyMissing` = [] (object guidance replaces room coverage nags).
    static func apply(decision: GuidanceKind?, to input: inout GuidanceInput) {
        if let decision {
            input.extraConditions = [decision]
        } else {
            input.extraConditions = []
        }
        input.viewCoverage = nil
        input.nearbyMissing = []
    }

    /// The engine's guidance hook: `coverage.guidanceHook`, then `augment`. Formed here, outside any
    /// actor, and capturing both weakly (never form hub-queue closures in the `@MainActor` model).
    func guidanceHook(after coverage: CoverageLiveRecorder) -> (inout GuidanceInput) -> Void {
        let first = coverage.guidanceHook
        return { [weak self] (input: inout GuidanceInput) -> Void in
            first(&input)
            guard let self else { return }
            self.augment(&input)
        }
    }

    // MARK: - Readers (any thread)

    /// The latest published state.
    func current() -> LargeObjectTrackerState {
        locked { published }
    }

    /// Capture facts for largeobject.json (the latest seed, floor, box and sector values).
    func log() -> LargeObjectLog {
        locked { () -> LargeObjectLog in
            var value = LargeObjectLog.empty
            value.seed = seed.map { Vec3($0) }
            value.floorY = published.floorY ?? seedFloorY
            value.front = front.map { Vec3($0) }
            value.box = published.box.map { OrientedBoxRecord($0) }
            if let sectors {
                value.viewSeconds = sectors.viewSeconds
                value.faceScores = sectors.faceScores
                value.topRequired = sectors.topRequired
                value.covered = sectors.coveredCount
                value.required = sectors.requiredCount
            }
            return value
        }
    }

    // MARK: - Pass (tracker queue)

    /// One pass: copies the inputs under the lock, runs `LargeObjectPass.run` on the latest faces,
    /// publishes the result unless the seed changed meanwhile, and logs.
    private func runPass() {
        let copied = locked { () -> (input: LargeObjectPassInput, generation: Int)? in
            guard let current = seed else {
                passInFlight = false
                return nil
            }
            let input = LargeObjectPassInput(seed: current, seedFloorY: seedFloorY, front: front, sectors: sectors,
                                             lastFloorY: published.floorY, lastBox: published.box, poses: poses,
                                             lastCamera: latestCamera)
            poses = []
            return (input: input, generation: seedGeneration)
        }
        guard let copied else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let anchors = coverage.anchorFaces(changedSince: 0).anchors
        let output = LargeObjectPass.run(copied.input, anchors: anchors)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        let lines = locked { () -> [String] in
            passInFlight = false
            guard copied.generation == seedGeneration else { return [] }
            return publish(output, milliseconds: milliseconds, anchors: anchors.count)
        }
        for line in lines { LargeObjectLog.write(line) }
    }

    /// Stores a pass result and returns the log lines it deserves (call with the lock held).
    private func publish(_ output: LargeObjectPassOutput, milliseconds: Double, anchors: Int) -> [String] {
        sectors = output.sectors
        let passes = published.passes + 1
        published = LargeObjectTrackerState(box: output.box, floorY: output.floorY,
                                            covered: output.sectors?.coveredCount ?? 0,
                                            required: output.sectors?.requiredCount ?? 0,
                                            guidance: output.decision, passes: passes)
        if passTimes.count < LargeObjectTracker.maxPassTimes { passTimes.append(milliseconds) }
        var lines: [String] = []
        let timing = String(format: "%.1f", milliseconds)
        if passes == 1 || passes % LargeObjectTracker.passLogInterval == 0 || milliseconds > LargeObjectTracker.slowPassMilliseconds {
            lines.append("pass \(passes): \(timing) ms, \(anchors) anchors, \(output.sampleCount) samples, "
                         + "\(output.grownPoints) grown, \(output.scoredFaces) faces scored, "
                         + "\(published.covered) of \(published.required) covered, message \(output.decision?.rawValue ?? "none")")
        }
        if let box = output.box, LargeObjectTracker.changed(box, from: loggedBox) {
            loggedBox = box
            lines.append("box \(LargeObjectTracker.sizeText(box)) at \(LargeObjectTracker.text(box.center)), "
                         + "floor \(LargeObjectTracker.floorText(output.floorY))")
        }
        return lines
    }

    /// Logs the pass count, median and slowest pass time of the recording.
    private func logSummary() {
        let summary = locked { () -> (times: [Double], state: LargeObjectTrackerState) in (times: passTimes, state: published) }
        let sorted = summary.times.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let slowest = sorted.last ?? 0
        LargeObjectLog.write("tracker finished: \(sorted.count) passes, median \(String(format: "%.1f", median)) ms, "
                             + "slowest \(String(format: "%.1f", slowest)) ms, \(summary.state.covered) of "
                             + "\(summary.state.required) covered, box \(summary.state.box.map(LargeObjectTracker.sizeText) ?? "none")")
    }

    // MARK: - Helpers

    /// True when `timestamp - last >= interval` (always when `last` is nil).
    static func isDue(_ timestamp: TimeInterval, last: TimeInterval?, interval: Double) -> Bool {
        guard let last else { return true }
        return timestamp - last >= interval - dueTolerance || timestamp < last
    }

    /// True when a side of `box` differs from `previous` by more than `boxLogChange` (or there was none).
    static func changed(_ box: OrientedBox, from previous: OrientedBox?) -> Bool {
        guard let previous else { return true }
        let difference = simd_abs(box.halfExtents - previous.halfExtents) * 2
        let moved = simd_distance(box.center, previous.center)
        return difference.max() > boxLogChange || moved > boxLogChange
    }

    /// "w x h x d m" of a box, for the log (not user-facing).
    static func sizeText(_ box: OrientedBox) -> String {
        let size = box.halfExtents * 2
        return String(format: "%.2f x %.2f x %.2f m", size.x, size.y, size.z)
    }

    /// A floor height for the log ("unknown" for nil).
    static func floorText(_ value: Float?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f m", value)
    }

    /// The value when it is finite, else nil.
    static func finiteValue(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// The point when every component is finite, else nil.
    static func finitePoint(_ point: SIMD3<Float>?) -> SIMD3<Float>? {
        guard let point, LargeObjectSeed.isFinite(point) else { return nil }
        return point
    }

    /// "(x, y, z)" of a point with centimeter precision, for the log.
    static func text(_ p: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", p.x, p.y, p.z)
    }

    /// Runs `body` while holding the lock.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
