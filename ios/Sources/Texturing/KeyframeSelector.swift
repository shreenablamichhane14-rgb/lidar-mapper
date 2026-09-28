import Foundation
import simd

/// Live-capture keyframe gate: decides whether a camera frame should become a texturing keyframe.
///
/// Feed every camera frame to `consider(cameraToWorld:timestamp:exposureOffset:)`. Checks run in
/// this order, and the first one that fails decides the result:
/// 1. Exposure: an exposure offset outside `minExposureOffset...maxExposureOffset` (EV), or
///    not finite, gives `.rejectExposure`. A nil offset passes.
/// 2. Too soon: less than `minInterval` seconds since the last accepted keyframe gives
///    `.rejectTooSoon`.
/// 3. Blur: the angular velocity between the previous considered frame and this one above
///    `maxAngularVelocity` (rad/s) gives `.rejectBlur`. Skipped for the very first frame and
///    when the time step is not positive.
/// 4. Too close: when both the translation and the rotation since the last keyframe are under
///    `maxTranslation` and `maxRotationDegrees`, the result is `.rejectTooClose`.
///
/// The first frame becomes a keyframe when it passes the exposure and blur checks. Every
/// considered frame (accepted or not) becomes the reference for the next angular velocity
/// estimate. This type uses plain inputs (no ARKit) so it can be tested with synthetic poses:
/// pass ARCamera.transform, ARFrame.timestamp and ARCamera.exposureOffset.
struct KeyframeSelector {
    /// Thresholds for the keyframe decision.
    struct Config {
        /// A new keyframe needs at least this much camera movement (meters) or enough rotation.
        var maxTranslation: Float = 0.15
        /// A new keyframe needs at least this much camera rotation (degrees) or enough movement.
        var maxRotationDegrees: Float = 12
        /// Frames rotating faster than this (radians per second) are rejected as blurred.
        var maxAngularVelocity: Float = 1.0
        /// Lowest acceptable exposure offset (EV).
        var minExposureOffset: Float = -2
        /// Highest acceptable exposure offset (EV).
        var maxExposureOffset: Float = 2
        /// Keyframe count above which `thinIfNeeded()` drops keyframes.
        var maxKeyframes: Int = 300
        /// Minimum time (seconds) between two accepted keyframes.
        var minInterval: Double = 0.1

        /// Default thresholds.
        init() {}
    }

    /// Outcome of considering one frame.
    enum Decision: Equatable {
        /// The frame was recorded as a keyframe.
        case accept
        /// The camera has not moved or rotated enough since the last keyframe.
        case rejectTooClose
        /// The camera rotated too fast; the image is likely motion blurred.
        case rejectBlur
        /// The exposure offset is outside the accepted range.
        case rejectExposure
        /// Too little time has passed since the last keyframe.
        case rejectTooSoon
    }

    /// Thresholds in use.
    let config: Config

    /// Camera-to-world poses of the accepted keyframes, in acceptance order.
    private(set) var keyframePoses: [simd_float4x4] = []

    /// Timestamps (seconds) of the accepted keyframes, parallel to `keyframePoses`.
    private(set) var keyframeTimestamps: [Double] = []

    /// Pose of the previous considered frame, used for the angular velocity estimate.
    private var previousPose: simd_float4x4? = nil

    /// Timestamp of the previous considered frame, used for the angular velocity estimate.
    private var previousTimestamp: Double? = nil

    /// Number of keyframes currently kept.
    var count: Int {
        return keyframeTimestamps.count
    }

    /// Creates a selector with the given thresholds.
    init(config: Config = Config()) {
        self.config = config
    }

    /// Forgets all keyframes and the previous frame.
    mutating func reset() {
        keyframePoses.removeAll()
        keyframeTimestamps.removeAll()
        previousPose = nil
        previousTimestamp = nil
    }

    /// Feed every frame (pose, timestamp, exposureOffset); returns the decision. On `.accept`
    /// the pose and timestamp are recorded as a new keyframe.
    mutating func consider(cameraToWorld: simd_float4x4, timestamp: Double, exposureOffset: Float?) -> Decision {
        let decision: Decision = evaluate(cameraToWorld: cameraToWorld, timestamp: timestamp,
                                          exposureOffset: exposureOffset)
        previousPose = cameraToWorld
        previousTimestamp = timestamp
        if decision == .accept {
            keyframePoses.append(cameraToWorld)
            keyframeTimestamps.append(timestamp)
        }
        return decision
    }

    /// Runs the checks in order without changing any state.
    private func evaluate(cameraToWorld: simd_float4x4, timestamp: Double, exposureOffset: Float?) -> Decision {
        // 1. Exposure sanity.
        if let offset = exposureOffset {
            if !offset.isFinite || offset < config.minExposureOffset || offset > config.maxExposureOffset {
                return .rejectExposure
            }
        }

        // 2. Too soon after the last keyframe.
        if let lastTime = keyframeTimestamps.last {
            if timestamp - lastTime < config.minInterval {
                return .rejectTooSoon
            }
        }

        // 3. Motion blur from angular velocity against the previous considered frame.
        if let prevPose = previousPose, let prevTime = previousTimestamp {
            let dt: Double = timestamp - prevTime
            if dt > 0 {
                let angle: Float = KeyframeSelector.rotationAngle(prevPose, cameraToWorld)
                let velocity: Float = angle / Float(dt)
                if velocity > config.maxAngularVelocity {
                    return .rejectBlur
                }
            }
        }

        // 4. Too close to the last keyframe (both movement and rotation small).
        if let lastPose = keyframePoses.last {
            let translation: Float = KeyframeSelector.translationDistance(lastPose, cameraToWorld)
            let rotation: Float = KeyframeSelector.rotationAngle(lastPose, cameraToWorld)
            let maxRotation: Float = config.maxRotationDegrees * Float.pi / 180
            if translation < config.maxTranslation && rotation < maxRotation {
                return .rejectTooClose
            }
        }

        return .accept
    }

    /// When count exceeds maxKeyframes: drops the keyframe whose removal loses least and returns its
    /// index (before removal), or nil when nothing was dropped.
    ///
    /// The loss of a keyframe is the combined distance to its nearest other keyframe:
    /// translation / maxTranslation + rotation / maxRotation (both normalized by the thresholds).
    /// The first keyframe and the most recent one are never dropped. Ties go to the lowest index.
    /// Drops at most one keyframe per call; call repeatedly if needed.
    mutating func thinIfNeeded() -> Int? {
        let n: Int = keyframePoses.count
        guard n > config.maxKeyframes, n >= 3 else { return nil }
        var bestIndex: Int = -1
        var bestLoss: Float = Float.infinity
        for i in 1..<(n - 1) {
            let pose: simd_float4x4 = keyframePoses[i]
            var nearest: Float = Float.infinity
            for j in 0..<n where j != i {
                let d: Float = combinedDistance(pose, keyframePoses[j])
                if d < nearest {
                    nearest = d
                }
            }
            if nearest < bestLoss {
                bestLoss = nearest
                bestIndex = i
            }
        }
        guard bestIndex >= 1 else { return nil }
        keyframePoses.remove(at: bestIndex)
        keyframeTimestamps.remove(at: bestIndex)
        return bestIndex
    }

    /// Translation over maxTranslation plus rotation over maxRotation between two poses.
    private func combinedDistance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let maxTranslation: Float = max(config.maxTranslation, 1e-6)
        let maxRotation: Float = max(config.maxRotationDegrees * Float.pi / 180, 1e-6)
        let t: Float = KeyframeSelector.translationDistance(a, b) / maxTranslation
        let r: Float = KeyframeSelector.rotationAngle(a, b) / maxRotation
        return t + r
    }

    /// Distance in meters between the camera positions of two camera-to-world poses.
    static func translationDistance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let pa: SIMD3<Float> = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb: SIMD3<Float> = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb)
    }

    /// Angle in radians (0...pi) of the relative rotation between two poses, from their upper-left
    /// 3x3 blocks: acos(clamp((trace(R1^T R2) - 1) / 2, -1, 1)).
    /// trace(R1^T R2) is the sum of the dot products of matching columns.
    static func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let a0: SIMD3<Float> = SIMD3<Float>(a.columns.0.x, a.columns.0.y, a.columns.0.z)
        let a1: SIMD3<Float> = SIMD3<Float>(a.columns.1.x, a.columns.1.y, a.columns.1.z)
        let a2: SIMD3<Float> = SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        let b0: SIMD3<Float> = SIMD3<Float>(b.columns.0.x, b.columns.0.y, b.columns.0.z)
        let b1: SIMD3<Float> = SIMD3<Float>(b.columns.1.x, b.columns.1.y, b.columns.1.z)
        let b2: SIMD3<Float> = SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        let trace: Float = simd_dot(a0, b0) + simd_dot(a1, b1) + simd_dot(a2, b2)
        var c: Float = (trace - 1) / 2
        if !c.isFinite {
            c = 1
        }
        c = min(max(c, -1), 1)
        return acos(c)
    }
}
