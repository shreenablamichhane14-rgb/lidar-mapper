import Foundation
import ARKit
import RealityKit
import SwiftUI
import UIKit

// The live camera of mesh-only scans (docs/MODULES.md 3.32, RESEARCH 3.5 and 3.10 "Raw mesh
// mode"): RealityKit's `ARView` in `.ar` mode on the hub's app-owned session, never running its
// own configuration, with Apple's coaching overlay (goal `.tracking`), a tap hook and an
// `onViewReady` hook where build 5b modules attach their RealityKit content (the coverage
// overlay, the large-object box). The scene-understanding wireframe is a Diagnostics toggle
// only, and occlusion stays off so the coverage overlay never z-fights (RESEARCH 3.5).

/// SwiftUI host of the live camera: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`,
/// then `arView.session = hub.session` and `hub.install()` at once (whoever assigns last wins; the hub
/// logs `session.delegate === hub`), `environment.sceneUnderstanding.options = []`, the debug
/// wireframe only when `SettingsKey.liveMeshDebugView` is on, `ARCoachingOverlayView` (session, goal
/// `.tracking`, activatesAutomatically) on top, a tap recognizer, then `onViewReady`.
/// `dismantleUIView` removes the recognizer and the coaching overlay, gives the ARView a fresh idle
/// `ARSession()` so the departing view can never pause or reconfigure the hub's session (a borrowed
/// hub must keep running for the room engine: the next room, a second tour), then calls
/// `hub.install()` again (as `HouseRelocalizationView`, 3.41). It never pauses the session.
struct LiveMeshContainer: UIViewRepresentable {
    /// The session owner whose session the view shows.
    let hub: ARSessionHub
    /// Whether Apple's coaching overlay is added.
    let showsCoaching: Bool
    /// Called once, after the view took the session (attach RealityKit content here).
    let onViewReady: (@MainActor (ARView) -> Void)?
    /// Called for every tap with the point in the ARView.
    let onTap: (@MainActor (CGPoint, ARView) -> Void)?

    /// Creates the container for `hub`.
    init(hub: ARSessionHub, showsCoaching: Bool = true, onViewReady: (@MainActor (ARView) -> Void)? = nil,
         onTap: (@MainActor (CGPoint, ARView) -> Void)? = nil) {
        self.hub = hub
        self.showsCoaching = showsCoaching
        self.onViewReady = onViewReady
        self.onTap = onTap
    }

    /// The coordinator keeps the hub (weakly), the tap target and the coaching overlay.
    func makeCoordinator() -> LiveMeshCoordinator {
        LiveMeshCoordinator(hub: hub, onTap: onTap)
    }

    /// Builds the ARView on the hub's session (see the type comment for the order).
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = hub.session
        hub.install()
        LiveMeshContainer.logIdentity("live mesh view took the session", hub: hub)
        arView.environment.sceneUnderstanding.options = []
        if LiveMeshContainer.debugViewEnabled {
            arView.debugOptions.insert(.showSceneUnderstanding)
            MeshScanLog.write("live mesh view: scanner debug view on (Diagnostics)")
        }
        let coordinator = context.coordinator
        if showsCoaching {
            let overlay = ARCoachingOverlayView(frame: .zero)
            overlay.session = hub.session
            overlay.goal = .tracking
            overlay.activatesAutomatically = true
            overlay.translatesAutoresizingMaskIntoConstraints = false
            arView.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: arView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
            ])
            coordinator.coachingOverlay = overlay
        }
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(LiveMeshCoordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        coordinator.tapRecognizer = tap
        coordinator.onTap = onTap
        onViewReady?(arView)
        return arView
    }

    /// Keeps the tap closure current. When SwiftUI reuses the view for another hub (a new pass in
    /// the same place of the view tree), the view and the coaching overlay move to the new hub's
    /// session and the new hub re-asserts its delegate; otherwise the session stays as it is.
    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        guard coordinator.hub !== hub else { return }
        uiView.session = hub.session
        hub.install()
        coordinator.coachingOverlay?.session = hub.session
        coordinator.hub = hub
        LiveMeshContainer.logIdentity("live mesh view moved to another hub", hub: hub)
    }

    /// Removes the recognizer and the coaching overlay, hands the view a fresh idle session and
    /// re-asserts the hub as the delegate of its own session. Never pauses the hub's session.
    static func dismantleUIView(_ uiView: ARView, coordinator: LiveMeshCoordinator) {
        if let tap = coordinator.tapRecognizer {
            uiView.removeGestureRecognizer(tap)
            coordinator.tapRecognizer = nil
        }
        if let overlay = coordinator.coachingOverlay {
            overlay.setActive(false, animated: false)
            overlay.session = nil
            overlay.removeFromSuperview()
            coordinator.coachingOverlay = nil
        }
        coordinator.onTap = nil
        uiView.session = ARSession()
        guard let hub = coordinator.hub else {
            MeshScanLog.write("live mesh view dismantled; the hub was already released")
            return
        }
        hub.install()
        LiveMeshContainer.logIdentity("live mesh view dismantled", hub: hub)
    }

    /// True when Diagnostics turned the scanner debug view on (absent means off).
    static var debugViewEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.liveMeshDebugView)
    }

    /// Logs the delegate identity and whether the hub's session runs.
    static func logIdentity(_ label: String, hub: ARSessionHub) {
        let delegateIsHub = hub.session.delegate === hub
        MeshScanLog.write("\(label): delegate === hub \(delegateIsHub), hub running \(hub.isRunning)")
    }
}

/// Coordinator of `LiveMeshContainer`: the tap target and the pieces `dismantleUIView` removes.
@MainActor final class LiveMeshCoordinator: NSObject {
    /// The tap hook (refreshed by `updateUIView`).
    var onTap: (@MainActor (CGPoint, ARView) -> Void)?
    /// The session owner (weak: the engine owns an owned hub; a room engine a borrowed one).
    weak var hub: ARSessionHub?
    /// The coaching overlay added on top of the ARView, if any.
    var coachingOverlay: ARCoachingOverlayView?
    /// The tap recognizer added to the ARView.
    var tapRecognizer: UITapGestureRecognizer?

    /// Creates a coordinator for `hub`.
    init(hub: ARSessionHub, onTap: (@MainActor (CGPoint, ARView) -> Void)?) {
        self.hub = hub
        self.onTap = onTap
        super.init()
    }

    /// Target of the UITapGestureRecognizer; passes `location(in:)` of the ARView.
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let arView = recognizer.view as? ARView else { return }
        let point = recognizer.location(in: arView)
        onTap?(point, arView)
    }
}
