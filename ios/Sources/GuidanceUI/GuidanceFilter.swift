import Foundation

// Room mode coaching suppression (D15, RESEARCH section 2 ruling 1, 3.10 gotcha 6 and
// 3.8 gotcha 23): `RoomCaptureView` draws Apple's own coaching text and cannot hide it while
// instructions still arrive, so Mapper's banner must never put a second instruction on top of
// it. While RoomPlan coaches, only the tier 1 messages RoomPlan has no instruction for (heat and
// tracking) get through. The filter runs after `GuidanceEngine.update`, so the engine keeps
// owning every display rule; this type adds no timing of its own.

/// Room mode with RoomCaptureView: while RoomPlan coaches, only deviceHot, trackingLost and
/// trackingLow pass (RoomPlan has no instruction for heat or tracking); otherwise everything passes.
///
/// A plain value, safe on any queue (RoomCapture applies it on its hub queue every tick).
struct GuidanceFilter: Equatable, Sendable {
    /// Kinds that pass even while RoomPlan is coaching.
    static let alwaysAllowed: Set<GuidanceKind> = [.deviceHot, .trackingLost, .trackingLow]

    /// True while RoomPlan's latest `RoomCaptureSession.Instruction` is not `.normal`
    /// (`GuidanceSignals.isCoaching`).
    var roomPlanCoaching: Bool

    /// Creates a filter; the default passes everything (mesh-only and object scans).
    init(roomPlanCoaching: Bool = false) {
        self.roomPlanCoaching = roomPlanCoaching
    }

    /// Whether `kind` may be shown under the current coaching state.
    func allows(_ kind: GuidanceKind) -> Bool {
        !roomPlanCoaching || GuidanceFilter.alwaysAllowed.contains(kind)
    }

    /// Returns `output` unchanged when its message may be shown; otherwise no message and no
    /// haptic, so a suppressed message never buzzes the phone either.
    func filter(_ output: GuidanceOutput) -> GuidanceOutput {
        guard let kind = output.message else { return output }
        if allows(kind) { return output }
        return GuidanceOutput(message: nil, fireHaptic: false)
    }
}
