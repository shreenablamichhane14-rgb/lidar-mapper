import ARKit

/// Live counters a recorder reports for LiveScanSnapshot. Each recorder fills only the
/// fields it owns (MeshStore the mesh fields, KeyframeRecorder the keyframe fields, and so
/// on); engines add the recorders' stats with `+`.
struct RecorderStats: Equatable, Sendable {
    /// Mesh anchors held and their total face count; keyframes accepted and skipped.
    var meshAnchors = 0, meshFaces = 0, keyframes = 0, skippedKeyframes = 0
    /// Photos taken, pose samples recorded and failed writes.
    var photos = 0, poseSamples = 0, writeFailures = 0

    /// All counters zero.
    init() {}

    /// Field-wise sum.
    static func + (lhs: RecorderStats, rhs: RecorderStats) -> RecorderStats {
        var sum = RecorderStats()
        sum.meshAnchors = lhs.meshAnchors + rhs.meshAnchors
        sum.meshFaces = lhs.meshFaces + rhs.meshFaces
        sum.keyframes = lhs.keyframes + rhs.keyframes
        sum.skippedKeyframes = lhs.skippedKeyframes + rhs.skippedKeyframes
        sum.photos = lhs.photos + rhs.photos
        sum.poseSamples = lhs.poseSamples + rhs.poseSamples
        sum.writeFailures = lhs.writeFailures + rhs.writeFailures
        return sum
    }
}

/// A raw-data recorder fed by ARSessionHub. Every method is called on `hub.queue`.
/// Implementations copy what they need inside the call and return quickly (target under 2 ms).
///
/// Engines (RoomCapture, LiveMeshView) drive recorders only through this protocol, so they
/// never import MeshRecord or Keyframes (dependency inversion, ARCHITECTURE 2.1 rule 5).
/// Never retain the `ARFrame`, an `ARAnchor` or any ARKit buffer beyond the call.
protocol ScanRecorder: AnyObject {
    /// Starts recording into a raw scan folder. `startTimestamp` is the ARFrame timebase time
    /// the scan started (the engine's `markScanStart` value).
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    /// A new camera frame. Copy what you need; the frame is released when this returns.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    /// Anchors added to the session (mesh anchors are `ARMeshAnchor`).
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor])
    /// Anchors updated by the session.
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor])
    /// Anchors removed by the session (they may come back with the same identifier).
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor])
    /// Stops recording, finishes all pending writes, then calls `completion` (any queue). Hub
    /// callbacks that still arrive after this call are ignored (engines detach recorders first).
    func finishRecording(completion: @escaping () -> Void)
    /// Writes buffered data now without finishing (memory pressure). Hub queue.
    func flushNow()
    /// Live counters, read on the hub queue.
    var stats: RecorderStats { get }
}

/// Default empty implementations of the four hub callbacks and of `flushNow()`.
extension ScanRecorder {
    /// Default: ignores frames.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {}
    /// Default: ignores added anchors.
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor]) {}
    /// Default: ignores updated anchors.
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor]) {}
    /// Default: ignores removed anchors.
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor]) {}
    /// Default: nothing is buffered, so there is nothing to flush.
    func flushNow() {}
}
