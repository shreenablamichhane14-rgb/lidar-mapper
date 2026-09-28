import ARKit

/// Forwards every delegate call first to the delegate it replaced (synchronously, on the queue
/// the call arrived on) and then to the hub; it never changes `session.delegateQueue`.
/// Installed only when the once-per-second identity check finds `session.delegate !== hub`
/// and `SettingsKey.captureRelay` is on (absent means on; Diagnostics can turn it off if the
/// camera view goes black, the one reported failure of a late delegate swap, RESEARCH 3.2
/// disputed 1). The check logs both `session.delegate === hub` and
/// `session.delegateQueue === queue`, and re-asserts only the queue.
///
/// Ownership: the hub keeps the relay strongly (`ARSession.delegate` is weak) and the relay
/// keeps the hub weakly, so they form no cycle; the replaced delegate is kept strongly so it
/// stays alive while the relay feeds it. A plain NSObject, never `@MainActor`.
final class ARDelegateRelay: NSObject, ARSessionDelegate {
    /// The hub that receives every call second.
    private weak var hub: ARSessionHub?
    /// The delegate this relay replaced; receives every call first.
    private let previous: (any ARSessionDelegate)?

    /// Creates a relay in front of `hub` that keeps feeding `previous`.
    init(hub: ARSessionHub, previous: (any ARSessionDelegate)?) {
        self.hub = hub
        self.previous = previous
        super.init()
    }

    /// Name of the replaced delegate's class, for the log.
    var previousTypeName: String {
        guard let replaced = previous else { return "nil" }
        return String(describing: type(of: replaced))
    }

    // MARK: - ARSessionDelegate (signatures verbatim from RESEARCH 3.1)

    /// Forwards a new frame.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        previous?.session?(session, didUpdate: frame)
        hub?.session(session, didUpdate: frame)
    }

    /// Forwards added anchors.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        previous?.session?(session, didAdd: anchors)
        hub?.session(session, didAdd: anchors)
    }

    /// Forwards updated anchors.
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        previous?.session?(session, didUpdate: anchors)
        hub?.session(session, didUpdate: anchors)
    }

    /// Forwards removed anchors.
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        previous?.session?(session, didRemove: anchors)
        hub?.session(session, didRemove: anchors)
    }

    // MARK: - ARSessionObserver (signatures verbatim from RESEARCH 3.1)

    /// Forwards a tracking state change.
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        previous?.session?(session, cameraDidChangeTrackingState: camera)
        hub?.session(session, cameraDidChangeTrackingState: camera)
    }

    /// Forwards an interruption.
    func sessionWasInterrupted(_ session: ARSession) {
        previous?.sessionWasInterrupted?(session)
        hub?.sessionWasInterrupted(session)
    }

    /// Forwards the end of an interruption.
    func sessionInterruptionEnded(_ session: ARSession) {
        previous?.sessionInterruptionEnded?(session)
        hub?.sessionInterruptionEnded(session)
    }

    /// Asks both; the hub's answer (always true) wins, so relocalization is always attempted.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        let previousAnswer = previous?.sessionShouldAttemptRelocalization?(session)
        let hubAnswer = hub?.sessionShouldAttemptRelocalization(session) ?? true
        if let previousAnswer, previousAnswer != hubAnswer {
            CaptureCoreLog.once("relay.relocalization", "relay: replaced delegate answered relocalization \(previousAnswer), hub \(hubAnswer)")
        }
        return hubAnswer
    }

    /// Forwards a session failure.
    func session(_ session: ARSession, didFailWithError error: any Error) {
        previous?.session?(session, didFailWithError: error)
        hub?.session(session, didFailWithError: error)
    }
}

/// CaptureCore's settings key (Diagnostics writes it).
extension SettingsKey {
    /// Bool, absent means on: whether the hub installs `ARDelegateRelay` when another object
    /// replaced the session delegate. Diagnostics can turn it off.
    static let captureRelay = "captureRelay"

    /// Reads `captureRelay` (absent means on).
    static var captureRelayEnabled: Bool {
        (UserDefaults.standard.object(forKey: captureRelay) as? Bool) ?? true
    }
}
