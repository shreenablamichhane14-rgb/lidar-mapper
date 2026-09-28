import Foundation
import ARKit
import RoomPlan
import RealityKit
// `ObjectCaptureSession` is declared in the RealityKit + SwiftUI cross-import overlay, so it is
// only visible to files that import both (CI run 36488207443: "cannot find type" without this).
import SwiftUI

// Adapters from Apple's live capture signals to Mapper's guidance types.
//
// Sources:
// - docs/MODULES.md 3.18 (contract), docs/ARCHITECTURE.md 4.1 "Guidance" (D15).
// - docs/RESEARCH.md: `ARCamera.TrackingState` (notAvailable, limited(Reason), normal; Reason
//   initializing, relocalizing, excessiveMotion, insufficientFeatures), the six
//   `RoomCaptureSession.Instruction` cases (not CaseIterable, not frozen), and the nine
//   `ObjectCaptureSession.Feedback` cases (no `outOfRange`; `objectNotDetected` is iOS 17.4,
//   below the iOS 18.0 deployment target).
// - Coverage `GuidanceTracking` doc comment: the adapter maps `.notAvailable` to `.initializing`.
//
// Every function here is pure and nonisolated: RoomCapture calls them on its hub queue and the
// self-test calls them off the main actor. Nested Apple enums are plain value types, so reading
// them needs no actor hop even when the enclosing session class is main-actor isolated.

/// Pure mappings from ARKit, RoomPlan and Object Capture signals to Coverage's `GuidanceTracking`
/// and Support's `GuidanceKind`. Deterministic, allocation free, callable from any queue.
enum GuidanceSignals {

    // MARK: Tracking

    /// Maps Mapper's recorded tracking summary to the guidance engine's tracking input.
    ///
    /// `.limited` (a limited state whose reason was not recorded) counts as low tracking quality
    /// (`.insufficientFeatures`, which the engine shows as "Tracking quality is low").
    /// `.notAvailable` maps to `.initializing`, as Coverage's `GuidanceTracking` documents, so the
    /// engine's initialization grace period applies before it warns.
    static func tracking(_ summary: TrackingSummary) -> GuidanceTracking {
        switch summary {
        case .normal: return .normal
        case .initializing: return .initializing
        case .excessiveMotion: return .excessiveMotion
        case .insufficientFeatures: return .insufficientFeatures
        case .relocalizing: return .relocalizing
        case .limited: return .insufficientFeatures
        case .notAvailable: return .initializing
        }
    }

    /// Maps ARKit's camera tracking state to the guidance engine's tracking input.
    ///
    /// `.notAvailable` maps to `.initializing` (Coverage contract). A limited reason added by a
    /// future SDK counts as low tracking quality (`.insufficientFeatures`).
    static func tracking(_ state: ARCamera.TrackingState) -> GuidanceTracking {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .initializing
        case .limited(let reason):
            return GuidanceSignals.tracking(reason: reason)
        @unknown default:
            return .insufficientFeatures
        }
    }

    /// Maps one ARKit limited-tracking reason. Unknown future reasons count as low quality.
    private static func tracking(reason: ARCamera.TrackingState.Reason) -> GuidanceTracking {
        switch reason {
        case .initializing: return .initializing
        case .relocalizing: return .relocalizing
        case .excessiveMotion: return .excessiveMotion
        case .insufficientFeatures: return .insufficientFeatures
        @unknown default: return .insufficientFeatures
        }
    }

    // MARK: RoomPlan coaching

    /// True for every Instruction except .normal (RoomPlan is coaching).
    ///
    /// An instruction added by a future SDK is treated as coaching: `RoomCaptureView` draws its
    /// own hint for it, so Mapper's banner stays quiet (RESEARCH 3.8 gotcha 23).
    static func isCoaching(_ instruction: RoomCaptureSession.Instruction) -> Bool {
        switch instruction {
        case .normal:
            return false
        case .moveCloseToWall, .moveAwayFromWall, .turnOnLight, .slowDown, .lowTexture:
            return true
        @unknown default:
            return true
        }
    }

    /// Stable log names ("normal", "moveCloseToWall", ...) for RoomCaptureLog.instructionSeconds.
    ///
    /// The names equal the Swift case names so logs read like the API. An instruction added by a
    /// future SDK is logged as "unknown".
    static func name(of instruction: RoomCaptureSession.Instruction) -> String {
        switch instruction {
        case .normal: return "normal"
        case .moveCloseToWall: return "moveCloseToWall"
        case .moveAwayFromWall: return "moveAwayFromWall"
        case .turnOnLight: return "turnOnLight"
        case .slowDown: return "slowDown"
        case .lowTexture: return "lowTexture"
        @unknown default: return GuidanceSignals.unknownInstructionName
        }
    }

    /// Log name used for an instruction this build does not know.
    static let unknownInstructionName = "unknown"

    // MARK: Object Capture feedback

    /// movingTooFast -> moveSlower, objectTooClose -> tooClose, objectTooFar -> tooFar,
    /// environmentTooDark and environmentLowLight -> lightingPoor, outOfFieldOfView -> objectKeepInView;
    /// others nil. Highest-priority mapped case wins.
    ///
    /// Priority is UX_COPY display rule 9 (lowest tier, then table order), taken from
    /// `GuidanceEngine.rank` so the banner and the engine never disagree. The result does not
    /// depend on the set's iteration order.
    static func guidance(for feedback: Set<ObjectCaptureSession.Feedback>) -> GuidanceKind? {
        var best: GuidanceKind?
        for item in feedback {
            guard let mapped = GuidanceSignals.kind(forFeedback: item) else { continue }
            if let current = best {
                if GuidanceEngine.rank(mapped) < GuidanceEngine.rank(current) { best = mapped }
            } else {
                best = mapped
            }
        }
        return best
    }

    /// Maps one Object Capture feedback case to a guidance kind, or nil when Mapper shows no
    /// banner for it (`objectNotDetected` and `objectNotFlippable` are handled by the object
    /// scan screen's own controls, `overCapturing` turns the shot counter red, ARCHITECTURE 4.3).
    static func kind(forFeedback item: ObjectCaptureSession.Feedback) -> GuidanceKind? {
        switch item {
        case .movingTooFast: return .moveSlower
        case .objectTooClose: return .tooClose
        case .objectTooFar: return .tooFar
        case .environmentTooDark, .environmentLowLight: return .lightingPoor
        case .outOfFieldOfView: return .objectKeepInView
        case .objectNotDetected, .objectNotFlippable, .overCapturing: return nil
        @unknown default: return nil
        }
    }
}
