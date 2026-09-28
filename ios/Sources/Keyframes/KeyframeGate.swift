import Foundation
import simd

/// Why a keyframe candidate was not taken (per-minute log breakdown; raw values are log text).
enum KeyframeSkipReason: String, CaseIterable {
    /// Every `FrameCopier` buffer was in use (or the copy failed).
    case noBuffer
    /// Tracking was not `.normal`.
    case tracking
    /// Free storage fell under the keyframe floor (D18).
    case storage
    /// Available memory fell under the keyframe floor (D17).
    case memory
    /// The engine is paused (interruption, 3.21).
    case paused
    /// The thermal policy's keyframe interval scale asked for fewer keyframes.
    case thermal
}

/// The facts of one frame the gate decides on, copied from the ARFrame and the hub inside the
/// callback (plain values, so the self-test can drive the same code without ARKit).
struct KeyframeGateInput {
    /// Camera to world (`ARCamera.transform`).
    var pose: simd_float4x4
    /// `ARFrame.timestamp`, seconds.
    var timestamp: Double
    /// `ARCamera.exposureOffset`, EV.
    var exposureOffset: Float
    /// Free `FrameCopier` buffers (`count - inUse`).
    var buffersFree: Int
    /// Tracking of this frame.
    var tracking: TrackingSummary
    /// Storage state (`hub.storage.state`).
    var storage: StorageState
    /// Memory state (`hub.status.memory`).
    var memory: MemoryState
    /// `KeyframeRecorder.isPaused`.
    var paused: Bool
    /// `hub.thermal.policy.keyframeIntervalScale`.
    var thermalScale: Double
}

/// What the gate decided for one frame.
enum KeyframeGateOutcome: Equatable {
    /// Take the keyframe (the selector recorded the pose).
    case accept
    /// Not considered (the selector was not touched). `newViewpoint` is true when the pose was
    /// far enough from the last keyframe or the last counted skip to count as one lost keyframe.
    case skipped(KeyframeSkipReason, newViewpoint: Bool)
    /// Considered and rejected by `KeyframeSelector` (too close, blur, exposure, too soon).
    case rejected(KeyframeSelector.Decision)
}

/// The keyframe gate of `KeyframeRecorder` (D6, D7, review R15): Texturing's `KeyframeSelector`
/// behind the capture conditions. The selector is consulted only when a copier buffer is free,
/// tracking is normal, storage and memory are ok, the engine is not paused and the thermal
/// policy allows another keyframe, so a skipped viewpoint is never recorded as a keyframe pose
/// and is not rejected later as too close. Hub queue (a value type owned by the recorder).
struct KeyframeGate {
    /// The selector, configured from `ScanSettings.keyframeGate` and never thinned.
    private(set) var selector: KeyframeSelector
    /// Pose of the last skip counted as a lost viewpoint since the last keyframe.
    private var skipReference: simd_float4x4?
    /// The selector as it was before the last accept, for `revertLastAccept`.
    private var beforeLastAccept: KeyframeSelector?

    /// A gate for the given capture settings (`KeyframeRecorder.selectorConfig(for:)`).
    init(settings: ScanSettings) {
        selector = KeyframeSelector(config: KeyframeRecorder.selectorConfig(for: settings))
    }

    /// Keyframes accepted so far.
    var acceptedCount: Int { selector.count }

    /// Decides one frame: the capture conditions first (`KeyframeRecorder.skipReason`), then
    /// the thermal interval, then `KeyframeSelector.consider`.
    mutating func evaluate(_ input: KeyframeGateInput) -> KeyframeGateOutcome {
        var reason = KeyframeRecorder.skipReason(buffersFree: input.buffersFree, tracking: input.tracking,
                                                 storage: input.storage, memory: input.memory, paused: input.paused)
        if reason == nil {
            let since: Double? = selector.keyframeTimestamps.last.map { input.timestamp - $0 }
            if !KeyframeRecorder.thermalAllows(scale: input.thermalScale, secondsSinceLastKeyframe: since) {
                reason = .thermal
            }
        }
        if let reason {
            return .skipped(reason, newViewpoint: noteSkip(pose: input.pose))
        }
        let before = selector
        let decision = selector.consider(cameraToWorld: input.pose, timestamp: input.timestamp,
                                         exposureOffset: input.exposureOffset)
        guard decision == .accept else { return .rejected(decision) }
        beforeLastAccept = before
        skipReference = nil
        return .accept
    }

    /// Undoes the last accept when its image could not be copied: the selector goes back to
    /// its state before that frame and the pose counts as a skipped viewpoint (returned).
    mutating func revertLastAccept(pose: simd_float4x4) -> Bool {
        if let snapshot = beforeLastAccept {
            selector = snapshot
            beforeLastAccept = nil
        }
        return noteSkip(pose: pose)
    }

    /// True (and the pose becomes the new reference) when `pose` is a new viewpoint relative to
    /// the last counted skip, else the last keyframe; with neither every pose is new.
    private mutating func noteSkip(pose: simd_float4x4) -> Bool {
        let reference = skipReference ?? selector.keyframePoses.last
        guard KeyframeRecorder.isNewViewpoint(pose, reference: reference, config: selector.config) else { return false }
        skipReference = pose
        return true
    }
}

/// The pure gate helpers of `KeyframeRecorder` (selector thresholds, capture conditions,
/// thermal interval, viewpoint distance), shared by `KeyframeGate` and the self-test.
extension KeyframeRecorder {
    /// Minimum seconds between keyframes at thermal scale 1 when throttling applies; the
    /// thermal gate requires `thermalBaseInterval * scale` (1 s at `.serious`, ship-first 3.6).
    static let thermalBaseInterval: Double = 0.5
    /// Blur limit of the selector, radians per second.
    static let maxAngularVelocity: Float = 1.0

    /// Selector thresholds for capture settings: `maxTranslation` and `maxRotationDegrees` from
    /// `settings.keyframeGate` (Keep all photos off already scales them by 1.5, D6),
    /// `maxAngularVelocity` 1.0, exposure within plus or minus 2 EV, `maxKeyframes` Int.max
    /// (never thinned, D6).
    static func selectorConfig(for settings: ScanSettings) -> KeyframeSelector.Config {
        let gate = settings.keyframeGate
        var config = KeyframeSelector.Config()
        config.maxTranslation = gate.meters
        config.maxRotationDegrees = gate.degrees
        config.maxAngularVelocity = maxAngularVelocity
        config.minExposureOffset = -2
        config.maxExposureOffset = 2
        config.maxKeyframes = Int.max
        return config
    }

    /// Pure gate helper (review R15): true when the selector may be consulted, that is a copier
    /// buffer is free, tracking is `.normal`, storage and memory are `.ok` and not paused.
    static func shouldConsider(buffersFree: Int, tracking: TrackingSummary, storage: StorageState,
                               memory: MemoryState, paused: Bool) -> Bool {
        skipReason(buffersFree: buffersFree, tracking: tracking, storage: storage, memory: memory, paused: paused) == nil
    }

    /// The first condition that blocks a keyframe (paused, tracking, storage, memory, buffers),
    /// or nil when the selector may be consulted.
    static func skipReason(buffersFree: Int, tracking: TrackingSummary, storage: StorageState,
                           memory: MemoryState, paused: Bool) -> KeyframeSkipReason? {
        if paused { return .paused }
        if tracking != .normal { return .tracking }
        if storage != .ok { return .storage }
        if memory != .ok { return .memory }
        if buffersFree <= 0 { return .noBuffer }
        return nil
    }

    /// Thermal interval gate: always true at scale 1 or below; above it, true before the first
    /// keyframe or when at least `thermalBaseInterval * scale` seconds passed since the last.
    static func thermalAllows(scale: Double, secondsSinceLastKeyframe: Double?) -> Bool {
        guard scale.isFinite, scale > 1 else { return true }
        guard let seconds = secondsSinceLastKeyframe else { return true }
        return seconds >= thermalBaseInterval * scale
    }

    /// True when `pose` moved at least `maxTranslation` or turned at least `maxRotationDegrees`
    /// from `reference` (the selector's own distance measures), or when there is no reference.
    static func isNewViewpoint(_ pose: simd_float4x4, reference: simd_float4x4?,
                               config: KeyframeSelector.Config) -> Bool {
        guard let reference else { return true }
        let moved: Float = KeyframeSelector.translationDistance(reference, pose)
        let turned: Float = KeyframeSelector.rotationAngle(reference, pose)
        let maxRotation: Float = config.maxRotationDegrees * Float.pi / 180
        return moved >= config.maxTranslation || turned >= maxRotation
    }
}
