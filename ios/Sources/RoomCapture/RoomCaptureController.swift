import Foundation
import RoomPlan

// RoomPlan delegate of the room engine (docs/MODULES.md 3.21, REUSE.md 1.1 steps 3 to 8).
// Every delegate signature below is copied verbatim from docs/RESEARCH.md 3.2 and 3.10: a
// near-miss label compiles as an unrelated method and RoomPlan then calls the default empty
// implementation instead (RESEARCH 3.2 gotcha 2). The callback thread is undocumented, so each
// method copies values (CapturedRoom and CapturedRoomData are Sendable structs; instructions are
// reduced to their log name and coaching flag here) and hops to the engine's hub queue.

/// Delegates of RoomCaptureSession and RoomCaptureView (NSCoding stubs required). Holds the
/// engine weakly (`weak var engine: RoomScanEngine?`), so engine, hub and controller form no cycle.
/// A plain NSObject, never `@MainActor` (D26).
final class RoomCaptureController: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate {
    /// The engine that receives every callback on its hub queue.
    weak var engine: RoomScanEngine?

    /// Creates a controller; the engine sets `engine` right after.
    override init() {
        super.init()
    }

    /// NSCoding stub required by RoomCaptureViewDelegate; this object is never archived.
    required init?(coder: NSCoder) {
        return nil
    }

    /// NSCoding stub required by RoomCaptureViewDelegate; nothing is encoded.
    func encode(with coder: NSCoder) {}

    // MARK: - RoomCaptureSessionDelegate (verbatim, RESEARCH 3.2)

    /// RoomPlan started: the engine marks the scan start and logs the configuration and the
    /// delegate identity (it never re-applies the configuration here).
    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        let coaching = configuration.isCoachingEnabled
        let onMain = Thread.isMainThread
        forward("didStartWith") { engine in engine.roomPlanDidStart(coachingEnabled: coaching, callbackOnMain: onMain) }
    }

    /// Added elements only (the full room arrives in `didUpdate`); logged once for diagnostics.
    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        noteThread("didAdd")
    }

    /// Changed elements only; logged once for diagnostics.
    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        noteThread("didChange")
    }

    /// Removed elements only; logged once for diagnostics.
    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        noteThread("didRemove")
    }

    /// The full live room: counts, detections, the live room file and the build 5 hook. Never
    /// the final room (RoomBuilder's output is, RESEARCH 3.2 gotcha 6).
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let liveRoom = room
        forward("didUpdate") { engine in engine.roomPlanDidUpdate(liveRoom) }
    }

    /// RoomPlan's coaching instruction: the engine keeps the coaching flag for the guidance
    /// filter and the seconds per instruction for roomlog.json.
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let name = GuidanceSignals.name(of: instruction)
        let coaching = GuidanceSignals.isCoaching(instruction)
        forward("didProvide") { engine in engine.roomPlanDidProvide(instructionName: name, coaching: coaching) }
    }

    /// Fires after every stop, synchronously on an undocumented thread: the values are copied
    /// and the engine runs the whole finish sequence in one task.
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        let roomData = data
        let endError = error
        forward("didEndWith") { engine in engine.roomPlanDidEnd(data: roomData, error: endError) }
    }

    // MARK: - RoomCaptureViewDelegate (verbatim, RESEARCH 3.10)

    /// Always false: Mapper runs RoomBuilder itself from `didEndWith` and shows its own quality
    /// sheet instead of Apple's preview (REUSE 4.1 step 10).
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        let text = error.map { RoomScanStats.describe($0) } ?? "none"
        RoomScanLog.write("captureView shouldPresent answered false, error \(text)")
        return false
    }

    /// Not expected after `shouldPresent` returned false; logged and ignored.
    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
        RoomScanLog.write("captureView didPresent called unexpectedly; result ignored")
    }

    // MARK: - Forwarding

    /// Logs the callback thread once, then runs `work` with the engine on its hub queue.
    private func forward(_ label: String, _ work: @escaping (RoomScanEngine) -> Void) {
        noteThread(label)
        guard let engine else {
            RoomScanLog.once("controller.orphan.\(label)", "RoomPlan \(label) arrived after the engine was released")
            return
        }
        engine.hub.queue.async { [weak engine] in
            guard let engine else { return }
            work(engine)
        }
    }

    /// Logs the thread of the first callback of each kind (REUSE 4.5 device checklist).
    private func noteThread(_ label: String) {
        RoomScanLog.once("controller.thread.\(label)", "RoomPlan \(label) first callback on main thread: \(Thread.isMainThread)")
    }
}
