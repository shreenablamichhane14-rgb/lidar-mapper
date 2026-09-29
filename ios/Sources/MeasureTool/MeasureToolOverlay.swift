import SwiftUI
import simd

/// Lines, area fills and labels (value and accuracy) of the draft and every saved record, and drag
/// handles (44 pt circles, VoiceOver `Copy.MeasureTool.pointLabel(n)` with `pointHint`). Observes the
/// model and `model.viewer` and redraws on `cameraRevision`. The line and label layer has
/// `.allowsHitTesting(false)`; only the handles take touches, so orbit, pan and tap reach the viewer.
/// Place it over the `ViewerContainer` in the same frame: positions come from `ViewerModel.project`,
/// which works in the viewer's own points.
struct MeasureToolOverlay: View {
    /// The measuring state.
    @ObservedObject var model: MeasureToolModel
    /// The viewer, observed for `cameraRevision`.
    @ObservedObject var viewer: ViewerModel

    /// Name of the overlay's coordinate space (drag locations are read in it).
    static let space = "mapper.measuretool.overlay"
    /// The overlay's coordinate space as a typed value, so exactly one `DragGesture` initializer
    /// (the iOS 17 `some CoordinateSpaceProtocol` one) and `coordinateSpace(_:)` match it.
    static var overlaySpace: NamedCoordinateSpace { .named(space) }

    /// An overlay for `model` (and its viewer).
    init(model: MeasureToolModel) {
        self._model = ObservedObject(wrappedValue: model)
        self._viewer = ObservedObject(wrappedValue: model.viewer)
    }

    /// Canvas, labels and handles.
    var body: some View {
        let scene = MeasureToolOverlayScene.make(model: model, cameraRevision: viewer.cameraRevision)
        ZStack {
            Canvas { context, _ in
                MeasureToolOverlayScene.draw(scene, in: &context)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ForEach(scene.labels) { item in
                MeasureToolOverlayTag(item: item)
                    .position(item.anchor)
            }
            .allowsHitTesting(false)
            ForEach(scene.handles) { item in
                MeasureToolHandleView(item: item, model: model)
            }
        }
        .coordinateSpace(MeasureToolOverlay.overlaySpace)
    }
}

/// One on-model label: value over accuracy (or the low-confidence text), readable on any background.
struct MeasureToolOverlayTag: View {
    /// What to show.
    let item: MeasureToolOverlayScene.LabelItem

    /// Two lines on a dark rounded background.
    var body: some View {
        VStack(spacing: 1) {
            Text(item.value)
                .font(.caption.weight(.semibold).monospacedDigit())
            if let accuracy = item.accuracy {
                HStack(spacing: 3) {
                    if item.isLowConfidence {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                    }
                    Text(accuracy)
                }
                .font(.caption2)
                .foregroundStyle(item.isLowConfidence ? Color.orange : Color.white.opacity(0.85))
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(item.isDraft ? 0.8 : 0.65), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibility)
    }
}

/// A 44 pt draggable point. A drag re-places the point under the finger (keeping where it was
/// grabbed); a touch that does not move is a tap on the model at that point.
struct MeasureToolHandleView: View {
    /// The handle and its screen position.
    let item: MeasureToolOverlayScene.HandleItem
    /// The measuring state (not observed: the overlay redraws).
    let model: MeasureToolModel
    /// True once the finger moved past the tap slop.
    @State private var moved = false
    /// Finger position minus the point's position when the drag started.
    @State private var grab = CGSize.zero

    /// Movement below this is a tap on the handle, points.
    static let tapSlop: CGFloat = 3
    /// Touch target size, points (Apple's minimum).
    static let touchSize: CGFloat = 44

    /// Creates the handle view.
    init(item: MeasureToolOverlayScene.HandleItem, model: MeasureToolModel) {
        self.item = item
        self.model = model
    }

    /// The dot inside a 44 pt touch target.
    var body: some View {
        Circle()
            .fill(item.isDraft ? Color.cyan : Color.yellow)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
            .frame(width: MeasureToolHandleView.touchSize, height: MeasureToolHandleView.touchSize)
            .contentShape(Circle())
            .gesture(dragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.label)
            .accessibilityHint(Copy.MeasureTool.pointHint)
            .position(item.point)
    }

    /// Drag in the overlay's coordinate space, with `minimumDistance: 0` so a touch that does not
    /// move still reaches `onEnded`.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: MeasureToolOverlay.overlaySpace)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !moved {
                    guard (dx * dx + dy * dy).squareRoot() >= MeasureToolHandleView.tapSlop else { return }
                    moved = true
                    grab = CGSize(width: value.startLocation.x - item.point.x, height: value.startLocation.y - item.point.y)
                }
                let target = CGPoint(x: value.location.x - grab.width, y: value.location.y - grab.height)
                model.drag(item.handle, to: target)
            }
            .onEnded { _ in
                if moved {
                    model.endDrag(item.handle)
                } else {
                    model.tapHandle(item.handle)
                }
                moved = false
                grab = .zero
            }
    }
}
