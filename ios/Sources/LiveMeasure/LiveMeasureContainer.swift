import SwiftUI
import UIKit
import ARKit
import RealityKit

/// ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false) on `model.hub.session`,
/// `hub.install()` right after, coaching overlay (goal `.tracking`), then `model.attach(_:)`.
///
/// The hub stays the session's delegate (whoever assigns last wins, so `install()` follows the
/// view taking the session; the hub logs `session.delegate === hub`). Scene understanding stays
/// off (no occlusion, no debug wireframe). `dismantleUIView` removes the coaching overlay, tears
/// the model down (the hub is paused on every exit, PERF-14) and gives the departing view a
/// fresh idle `ARSession()` so it can never touch the hub's session again.
struct LiveMeasureContainer: UIViewRepresentable {
    /// The Quick Measure model that owns the hub.
    let model: LiveMeasureModel

    /// Creates the container for `model`.
    init(model: LiveMeasureModel) {
        self.model = model
    }

    /// Holds the model and the coaching overlay for `dismantleUIView`.
    func makeCoordinator() -> LiveMeasureCoordinator {
        LiveMeasureCoordinator(model: model)
    }

    /// Builds the AR view on the hub's session and attaches it to the model.
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = model.hub.session
        model.hub.install()
        arView.environment.sceneUnderstanding.options = []
        let coaching = ARCoachingOverlayView(frame: arView.bounds)
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.session = model.hub.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        arView.addSubview(coaching)
        context.coordinator.coaching = coaching
        model.attach(arView)
        return arView
    }

    /// Nothing to update: the model drives everything through its reticle loop.
    func updateUIView(_ uiView: ARView, context: Context) {}

    /// Removes the coaching overlay, tears the model down and hands the view an idle session.
    static func dismantleUIView(_ uiView: ARView, coordinator: LiveMeasureCoordinator) {
        coordinator.coaching?.removeFromSuperview()
        coordinator.coaching = nil
        coordinator.model.viewDismantled(uiView)
        uiView.session = ARSession()
        LiveMeasureLog.write("container dismantled, hub running \(coordinator.model.hub.isRunning)")
    }
}

/// Coordinator of `LiveMeasureContainer` (`dismantleUIView` is static and cannot read the container).
@MainActor final class LiveMeasureCoordinator {
    /// The model whose view this is.
    let model: LiveMeasureModel
    /// Apple's coaching overlay on top of the camera.
    var coaching: ARCoachingOverlayView?

    /// Creates a coordinator for `model`.
    init(model: LiveMeasureModel) {
        self.model = model
    }
}
