import Foundation
import RealityKit
import SwiftUI
import UIKit

/// UIViewRepresentable around ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false).
/// One-finger drag orbits (yaw, pitch clamped to 5...85 degrees), two-finger drag pans, pinch dollies,
/// double tap frames all, single tap calls `onTap` with `model.hitTest`.
///
/// The container creates the `ARView` (no ARKit session is ever run) and attaches it to the
/// model, which owns the scene; dismantling detaches it. VoiceOver reads
/// `Copy.A11y.modelViewer` with `Copy.A11y.modelViewerHint`, allows direct touch and offers
/// Reset View (`Copy.Viewer.resetView`) as a custom action.
struct ViewerContainer: UIViewRepresentable {
    /// The model that owns the scene.
    let model: ViewerModel
    /// Background color (black for scans, the system background for objects).
    let backgroundColor: UIColor
    /// Called on a single tap with the hit, or nil when nothing pickable is under the finger.
    let onTap: ((ViewerHit?) -> Void)?

    /// Creates the container.
    init(model: ViewerModel, background: UIColor, onTap: ((ViewerHit?) -> Void)? = nil) {
        self.model = model
        self.backgroundColor = background
        self.onTap = onTap
    }

    /// Makes the gesture coordinator.
    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onTap: onTap)
    }

    /// Creates the host view, its `ARView` in `.nonAR` mode and the gesture recognizers.
    func makeUIView(context: Context) -> ViewerHostView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(backgroundColor)
        let host = ViewerHostView(arView: arView)
        let coordinator = context.coordinator
        coordinator.host = host
        coordinator.appliedBackground = backgroundColor
        coordinator.installGestures(on: arView)
        host.isAccessibilityElement = true
        host.accessibilityLabel = Copy.A11y.modelViewer
        host.accessibilityHint = Copy.A11y.modelViewerHint
        host.accessibilityTraits = .allowsDirectInteraction
        host.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: Copy.Viewer.resetView, target: coordinator,
                                        selector: #selector(Coordinator.performResetView(_:))),
        ]
        host.onLayout = { [weak coordinator] size in
            coordinator?.model.updateViewSize(size)
        }
        model.attach(arView)
        return host
    }

    /// Applies a new background, model or tap handler.
    func updateUIView(_ uiView: ViewerHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        if coordinator.model !== model {
            coordinator.model.detach(uiView.arView)
            coordinator.model = model
            model.attach(uiView.arView)
        }
        if coordinator.appliedBackground != backgroundColor {
            coordinator.appliedBackground = backgroundColor
            uiView.arView.environment.background = .color(backgroundColor)
        }
    }

    /// Detaches the scene from the view being removed.
    static func dismantleUIView(_ uiView: ViewerHostView, coordinator: Coordinator) {
        coordinator.model.detach(uiView.arView)
        uiView.onLayout = nil
    }

    /// Turns UIKit gestures into camera moves and taps into hits.
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The model the gestures drive.
        var model: ViewerModel
        /// Tap handler from the container.
        var onTap: ((ViewerHit?) -> Void)?
        /// Last applied background color.
        var appliedBackground: UIColor?
        /// The host view (for gesture coordinates).
        weak var host: ViewerHostView?
        /// Two-finger pan recognizer, recognized together with the pinch.
        private var twoFingerPan: UIPanGestureRecognizer?
        /// Pinch recognizer, recognized together with the two-finger pan.
        private var pinch: UIPinchGestureRecognizer?

        /// Creates a coordinator for `model`.
        init(model: ViewerModel, onTap: ((ViewerHit?) -> Void)?) {
            self.model = model
            self.onTap = onTap
            super.init()
        }

        /// Adds orbit, pan, pinch, double tap and single tap recognizers to `view`.
        func installGestures(on view: UIView) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            view.addGestureRecognizer(pan)
            twoFingerPan = pan

            let pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchRecognizer.delegate = self
            view.addGestureRecognizer(pinchRecognizer)
            pinch = pinchRecognizer

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.require(toFail: doubleTap)
            view.addGestureRecognizer(singleTap)
        }

        /// One-finger drag: orbit by the finger travel since the last callback.
        @objc func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            model.orbitCamera(by: delta)
        }

        /// Two-finger drag: pan by the finger travel since the last callback.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            model.panCamera(by: delta)
        }

        /// Pinch: dolly by the scale change since the last callback.
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let scale = recognizer.scale
            recognizer.scale = 1
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            model.dollyCamera(scale: scale)
        }

        /// Double tap: frame everything.
        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            model.frameAll()
        }

        /// Single tap: report the hit (or nil) to the tap handler.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let hit = model.hitTest(recognizer.location(in: view))
            onTap?(hit)
        }

        /// VoiceOver custom action: Reset View.
        @objc func performResetView(_ action: UIAccessibilityCustomAction) -> Bool {
            model.resetView()
            return true
        }

        /// Lets the two-finger pan and the pinch run at the same time.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = twoFingerPan, let pinchRecognizer = pinch else { return false }
            let panFirst = gestureRecognizer === pan && otherGestureRecognizer === pinchRecognizer
            let pinchFirst = gestureRecognizer === pinchRecognizer && otherGestureRecognizer === pan
            return panFirst || pinchFirst
        }
    }
}

/// Plain host view for the viewer's `ARView`: keeps it full size and reports size changes so
/// the model can re-frame and move labels.
final class ViewerHostView: UIView {
    /// The RealityKit view (non-AR camera mode).
    let arView: ARView
    /// Called after layout with the new size.
    var onLayout: ((CGSize) -> Void)?

    /// Wraps `arView`.
    init(arView: ARView) {
        self.arView = arView
        super.init(frame: .zero)
        arView.frame = bounds
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(arView)
    }

    /// Not used (the view is created in code only).
    required init?(coder: NSCoder) {
        return nil
    }

    /// Keeps the `ARView` filling the host and reports the size.
    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
        onLayout?(bounds.size)
    }
}
