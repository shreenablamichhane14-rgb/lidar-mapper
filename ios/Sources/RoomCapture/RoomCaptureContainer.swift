import SwiftUI
import RoomPlan

/// SwiftUI host. makeUIView calls engine.makeCaptureView(); updateUIView does nothing. The
/// coordinator is the engine, because `dismantleUIView` is static and cannot read `self.engine`
/// (RESEARCH 3.10: `static func dismantleUIView(_ uiView: Self.UIViewType, coordinator: Self.Coordinator)`).
///
/// The view is created once and never recreated in `updateUIView` (a second RoomCaptureView on
/// the same session loses tracking, RESEARCH 3.2 disputed 3 and 3.10 gotcha 4).
struct RoomCaptureContainer: UIViewRepresentable {
    /// The engine that owns the view, the session and the recorders.
    let engine: RoomScanEngine

    /// Hosts `engine`'s capture view.
    init(engine: RoomScanEngine) {
        self.engine = engine
    }

    /// Returns the engine, so the static `dismantleUIView` can reach it.
    func makeCoordinator() -> RoomScanEngine {
        engine
    }

    /// The engine's one RoomCaptureView (hub installed and running first).
    func makeUIView(context: Context) -> RoomCaptureView {
        context.coordinator.makeCaptureView()
    }

    /// Nothing: RoomPlan is driven through the engine, never by SwiftUI updates.
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    /// Tears the engine down (idempotent): session paused, hub closures cleared, view released.
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: RoomScanEngine) {
        coordinator.teardown()
    }
}
