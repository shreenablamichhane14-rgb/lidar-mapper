import SwiftUI
import UIKit
import simd

/// SwiftUI Canvas via GraphicsContext.withCGContext; DragGesture pans, MagnifyGesture zooms
/// about its anchor, SpatialTapGesture hit-tests in model space (12 pt tolerance).
///
/// The plan starts fitted to the view; pan and zoom are kept relative to that fit, so a new
/// drawing of the same project keeps the user's view. A tap sets `selection` to the element
/// hit (nil for empty space) and then calls `onTap`, which may override the selection. The
/// selected element is outlined in the accent color. Text keeps a constant screen size
/// beyond the renderer's clamp (`PlanRenderer.draw`).
struct PlanCanvasView: View {
    /// Tap tolerance in screen points.
    static let tapTolerancePoints: CGFloat = 12
    /// Margin around the fitted plan in points.
    static let fitMargin: CGFloat = 24
    /// Allowed zoom relative to the fitted view.
    static let zoomRange: ClosedRange<CGFloat> = 0.25...40

    /// The drawing, the selected element and the tap callback.
    private let drawing: PlanDrawingResult
    @Binding private var selection: ElementID?
    private let onTap: ((PlanHit?) -> Void)?

    /// Light or dark appearance.
    @Environment(\.colorScheme) private var colorScheme
    /// Zoom and pan relative to the fitted view (screen transform p * zoom + offset).
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Last reported gesture values, so simultaneous pan and zoom apply as deltas.
    @State private var lastMagnification: CGFloat = 1
    @State private var lastTranslation: CGSize = .zero

    /// Creates a canvas for a drawing with a selection binding and an optional tap callback.
    init(drawing: PlanDrawingResult, selection: Binding<ElementID?>, onTap: ((PlanHit?) -> Void)? = nil) {
        self.drawing = drawing
        self._selection = selection
        self.onTap = onTap
    }

    /// Canvas filling the available space with pan, zoom and tap gestures.
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let viewport = currentViewport(in: size)
            let dark = colorScheme == .dark
            let plan = drawing.plan
            let highlight = selectedHit
            Canvas { context, _ in
                context.withCGContext { cg in
                    PlanRenderer.draw(plan, in: cg, viewport: viewport, lineWidth: 1, dark: dark)
                    if let hit = highlight {
                        PlanRenderer.drawHighlight(hit, in: cg, viewport: viewport, lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(panAndZoom(in: size))
            .simultaneousGesture(tapGesture(in: size))
        }
        .background(Color(uiColor: .systemBackground))
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(Copy.A11y.floorPlan)
        .accessibilityHint(Copy.A11y.floorPlanHint)
    }

    /// Hit of the selected element, when it is drawn.
    private var selectedHit: PlanHit? {
        guard let id = selection else { return nil }
        return drawing.hits.first { $0.element == id }
    }

    /// The viewport fitted to the plan bounds, before the user's pan and zoom.
    private func fittedViewport(in size: CGSize) -> PlanViewport {
        if let bounds = drawing.plan.bounds() {
            return PlanViewport.fitting(min: bounds.min, max: bounds.max, in: size, margin: PlanCanvasView.fitMargin)
        }
        return PlanViewport(pointsPerMeter: 50, origin: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// The fitted viewport with the user's zoom and pan applied.
    private func currentViewport(in size: CGSize) -> PlanViewport {
        fittedViewport(in: size).zoomed(by: zoom, about: .zero).panned(by: offset)
    }

    /// Pan (one finger drag) and pinch zoom about the pinch anchor, applied as deltas so both
    /// can run at once.
    private func panAndZoom(in size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation.width
                let dy = value.translation.height - lastTranslation.height
                offset = CGSize(width: offset.width + dx, height: offset.height + dy)
                lastTranslation = value.translation
            }
            .onEnded { _ in
                lastTranslation = .zero
            }
        let magnify = MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                let ratio = value.magnification / max(lastMagnification, 0.001)
                applyZoom(ratio, about: anchor)
                lastMagnification = value.magnification
            }
            .onEnded { _ in
                lastMagnification = 1
            }
        return drag.simultaneously(with: magnify)
    }

    /// Multiplies the zoom by `ratio` (clamped to `zoomRange`) keeping `anchor` fixed on screen.
    private func applyZoom(_ ratio: CGFloat, about anchor: CGPoint) {
        guard ratio.isFinite, ratio > 0 else { return }
        let range = PlanCanvasView.zoomRange
        let newZoom = min(max(zoom * ratio, range.lowerBound), range.upperBound)
        let k = newZoom / zoom
        guard k.isFinite, k > 0 else { return }
        offset = CGSize(width: (offset.width - anchor.x) * k + anchor.x,
                        height: (offset.height - anchor.y) * k + anchor.y)
        zoom = newZoom
    }

    /// Tap: model-space hit test with a 12 pt tolerance, then selection and `onTap`.
    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                let viewport = currentViewport(in: size)
                let p = viewport.toPlan(value.location)
                let tolerance = Float(PlanCanvasView.tapTolerancePoints / max(viewport.pointsPerMeter, 0.000001))
                let point = SIMD2<Float>(Float(p.x), Float(p.y))
                let hit = PlanDrawing.hitTest(drawing.hits, at: point, tolerance: tolerance)
                selection = hit?.element
                onTap?(hit)
            }
    }
}
