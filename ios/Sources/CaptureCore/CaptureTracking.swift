import ARKit

/// Tracking history of one scan: the current summary, how many times tracking went into
/// relocalization, and the share of time tracking was not `.normal` (for
/// `RoomCaptureLog.limitedTrackingFraction`). Hub queue only.
final class TrackingMonitor {
    /// The latest tracking summary.
    private(set) var summary: TrackingSummary = .initializing
    /// Number of transitions into `.relocalizing` since the last reset.
    private(set) var relocalizations: Int = 0

    /// Timestamp of the previous sample, nil before the first one.
    private var lastTimestamp: TimeInterval?
    /// Seconds covered by samples since the last reset.
    private var totalSeconds: Double = 0
    /// Seconds spent in any state other than `.normal` since the last reset.
    private var limitedSeconds: Double = 0

    /// Creates an empty monitor (summary `.initializing`).
    init() {}

    /// 0...1 of time not .normal since reset (0 before two samples arrived).
    var limitedFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, limitedSeconds / totalSeconds))
    }

    /// Feeds the tracking state of one frame. Call once per frame with `ARFrame.timestamp`.
    func update(_ state: ARCamera.TrackingState, timestamp: TimeInterval) {
        record(TrackingMonitor.summary(state), timestamp: timestamp)
    }

    /// Pure core of `update(_:timestamp:)` that takes a summary, so it can be tested without
    /// ARKit values. The time since the previous sample counts toward the previous summary;
    /// gaps that go backwards or are not finite are ignored.
    func record(_ newSummary: TrackingSummary, timestamp: TimeInterval) {
        if let last = lastTimestamp {
            let delta = timestamp - last
            if delta > 0, delta.isFinite {
                totalSeconds += delta
                if summary != .normal { limitedSeconds += delta }
            }
        }
        if newSummary == .relocalizing && summary != .relocalizing {
            relocalizations += 1
        }
        summary = newSummary
        lastTimestamp = timestamp
    }

    /// Clears the history for a new room or pass (summary back to `.initializing`).
    func reset() {
        summary = .initializing
        relocalizations = 0
        lastTimestamp = nil
        totalSeconds = 0
        limitedSeconds = 0
    }

    /// The limited fraction of a sequence of (summary, timestamp) samples; a pure helper for
    /// tests and offline analysis.
    static func limitedFraction(of samples: [(summary: TrackingSummary, timestamp: TimeInterval)]) -> Double {
        let monitor = TrackingMonitor()
        for sample in samples { monitor.record(sample.summary, timestamp: sample.timestamp) }
        return monitor.limitedFraction
    }

    /// Maps ARKit's tracking state to Core's summary; unknown future reasons map to `.limited`.
    static func summary(_ state: ARCamera.TrackingState) -> TrackingSummary {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            case .relocalizing: return .relocalizing
            @unknown default: return .limited
            }
        @unknown default:
            return .limited
        }
    }

    /// PoseSample code: 0 not available, 1 limited, 2 normal.
    static func poseCode(_ state: ARCamera.TrackingState) -> UInt8 {
        switch state {
        case .normal: return 2
        case .limited: return 1
        case .notAvailable: return 0
        @unknown default: return 1
        }
    }

    /// The same code for a summary (used when only the summary was copied). Labeled so a
    /// literal such as `.normal` is never ambiguous with the ARKit overload.
    static func poseCode(summary: TrackingSummary) -> UInt8 {
        switch summary {
        case .normal: return 2
        case .notAvailable: return 0
        case .initializing, .excessiveMotion, .insufficientFeatures, .relocalizing, .limited: return 1
        }
    }
}
