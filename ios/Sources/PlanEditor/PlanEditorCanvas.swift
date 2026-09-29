import SwiftUI
import UIKit
import simd

/// Canvas: `PlanRenderer.draw` of `model.drawing` inside `GraphicsContext.withCGContext`, then
/// `PlanRenderer.drawHighlight` of every hit of the selection (and of the merge selection), handles,
/// pending points and the snap marker. Viewport: fitted to the plan bounds with the user's zoom and
/// pan (as `PlanCanvasView`). One DragGesture: a drag starting on the selection edits
/// (`beginDrag`), any other drag pans; MagnifyGesture zooms about its anchor; SpatialTapGesture calls
/// `tap(at:tolerance:)`. Accessible as `Copy.A11y.floorPlan` with the hint `Copy.PlanEditor.canvasHint`.
///
/// The fit follows `model.fitBounds`, which changes only on load, level change and Reset View,
/// so the plan does not jump under the finger while an edit changes its bounds.
struct PlanEditorCanvas: View {
    /// Tap tolerance in screen points.
    static let tapTolerancePoints: CGFloat = 12
    /// Margin around the fitted plan in points.
    static let fitMargin: CGFloat = 24
    /// Allowed zoom relative to the fitted view.
    static let zoomRange: ClosedRange<CGFloat> = 0.25...40

    /// What the one-finger drag is doing.
    private enum DragMode: Equatable {
        case idle, editing, panning
    }

    /// The editing session.
    @ObservedObject private var model: PlanEditorModel
    /// Light or dark appearance.
    @Environment(\.colorScheme) private var colorScheme
    /// Zoom and pan relative to the fitted view (screen transform p * zoom + offset).
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Last reported gesture values, so simultaneous pan and zoom apply as deltas.
    @State private var lastMagnification: CGFloat = 1
    @State private var lastTranslation: CGSize = .zero
    /// The running one-finger drag.
    @State private var dragMode: DragMode = .idle

    /// A canvas editing `model`.
    init(model: PlanEditorModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    /// The plan with highlights, handles, pending points and the snap marker, with the editing,
    /// pan, zoom and tap gestures.
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let viewport = currentViewport(in: size)
            let dark = colorScheme == .dark
            let plan = model.drawing?.plan
            let highlights = highlightedHits
            let handles = model.handles
            let pending = model.pendingPoints.map { $0.simd }
            let marker = model.snapMarker
            Canvas { context, _ in
                context.withCGContext { cg in
                    if let plan {
                        PlanRenderer.draw(plan, in: cg, viewport: viewport, lineWidth: 1, dark: dark)
                    }
                    for hit in highlights {
                        PlanRenderer.drawHighlight(hit, in: cg, viewport: viewport, lineWidth: 1)
                    }
                    PlanEditorCanvasDrawing.drawDots(handles, in: cg, viewport: viewport, fill: UIColor.systemBlue)
                    PlanEditorCanvasDrawing.drawDots(pending, in: cg, viewport: viewport, fill: UIColor.systemOrange)
                    if let marker {
                        PlanEditorCanvasDrawing.drawRing(marker, in: cg, viewport: viewport)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(editPanAndZoom(in: size))
            .simultaneousGesture(tapGesture(in: size))
        }
        .background(Color(uiColor: .systemBackground))
        .clipped()
        .onChange(of: model.levelIndex) { _, _ in resetZoom() }
        .onChange(of: model.viewResets) { _, _ in resetZoom() }
        .accessibilityElement()
        .accessibilityLabel(Copy.A11y.floorPlan)
        .accessibilityHint(Copy.PlanEditor.canvasHint)
        .accessibilityAction(named: Copy.Viewer.resetView) { resetView() }
    }

    /// Hits outlined in the accent color: every part of the selection, the merge target and the
    /// rooms tapped for Merge Rooms.
    private var highlightedHits: [PlanHit] {
        var ids = Set(model.mergeSelection)
        if let id = model.selection { ids.insert(id) }
        guard !ids.isEmpty else { return [] }
        return (model.drawing?.hits ?? []).filter { ids.contains($0.element) }
    }

    /// Back to the fitted view of the current plan (zoom 1, no pan, bounds fitted again).
    func resetView() {
        model.requestViewReset()
        resetZoom()
    }

    /// Zoom 1 and no pan, animated.
    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            zoom = 1
            offset = .zero
        }
        lastMagnification = 1
        lastTranslation = .zero
    }

    /// The viewport fitted to `model.fitBounds`, before the user's pan and zoom.
    private func fittedViewport(in size: CGSize) -> PlanViewport {
        if let bounds = model.fitBounds {
            return PlanViewport.fitting(min: bounds.min, max: bounds.max, in: size, margin: PlanEditorCanvas.fitMargin)
        }
        return PlanViewport(pointsPerMeter: 50, origin: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// The fitted viewport with the user's zoom and pan applied.
    private func currentViewport(in size: CGSize) -> PlanViewport {
        fittedViewport(in: size).zoomed(by: zoom, about: .zero).panned(by: offset)
    }

    /// Plan point of a screen point in the current viewport.
    private func planPoint(_ location: CGPoint, in size: CGSize) -> SIMD2<Float> {
        let p = currentViewport(in: size).toPlan(location)
        return SIMD2<Float>(Float(p.x), Float(p.y))
    }

    /// 12 points in plan meters at the current zoom.
    private func tolerance(in size: CGSize) -> Float {
        let k = currentViewport(in: size).pointsPerMeter
        return Float(PlanEditorCanvas.tapTolerancePoints / max(k, 0.000001))
    }

    /// One-finger drag (edit the selection when it starts on it, else pan) with pinch zoom about
    /// the pinch anchor, applied as deltas so both can run at once.
    private func editPanAndZoom(in size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                switch dragMode {
                case .idle:
                    let start = planPoint(value.startLocation, in: size)
                    if model.beginDrag(at: start, tolerance: tolerance(in: size)) {
                        dragMode = .editing
                        model.drag(to: planPoint(value.location, in: size), tolerance: tolerance(in: size))
                    } else {
                        dragMode = .panning
                        pan(to: value.translation)
                    }
                case .editing:
                    model.drag(to: planPoint(value.location, in: size), tolerance: tolerance(in: size))
                case .panning:
                    pan(to: value.translation)
                }
            }
            .onEnded { _ in
                if dragMode == .editing { model.endDrag() }
                dragMode = .idle
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

    /// Pans by the change of the drag translation since the last event.
    private func pan(to translation: CGSize) {
        let dx = translation.width - lastTranslation.width
        let dy = translation.height - lastTranslation.height
        offset = CGSize(width: offset.width + dx, height: offset.height + dy)
        lastTranslation = translation
    }

    /// Multiplies the zoom by `ratio` (clamped to `zoomRange`) keeping `anchor` fixed on screen.
    private func applyZoom(_ ratio: CGFloat, about anchor: CGPoint) {
        guard ratio.isFinite, ratio > 0 else { return }
        let range = PlanEditorCanvas.zoomRange
        let newZoom = min(max(zoom * ratio, range.lowerBound), range.upperBound)
        let k = newZoom / zoom
        guard k.isFinite, k > 0 else { return }
        offset = CGSize(width: (offset.width - anchor.x) * k + anchor.x,
                        height: (offset.height - anchor.y) * k + anchor.y)
        zoom = newZoom
    }

    /// Tap: the model's tap in plan meters with a 12 pt tolerance.
    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                model.tap(at: planPoint(value.location, in: size), tolerance: tolerance(in: size))
            }
    }
}

/// Core Graphics marks of the editing canvas drawn over the plan (safe off main, like
/// `PlanRenderer`).
enum PlanEditorCanvasDrawing {
    /// Radius of handle and pending point dots, points.
    static let dotRadius: CGFloat = 7
    /// Radius of the snap marker ring, points.
    static let snapRadius: CGFloat = 11

    /// Filled dots with a white rim at plan points.
    static func drawDots(_ points: [SIMD2<Float>], in ctx: CGContext, viewport: PlanViewport, fill: UIColor) {
        guard !points.isEmpty else { return }
        let r = dotRadius
        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        for point in points where PlanEditorOps.isFinite(point) {
            let c = viewport.toScreen(SIMD2<Double>(Double(point.x), Double(point.y)))
            let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.addEllipse(in: box)
            ctx.fillPath()
            ctx.addEllipse(in: box)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The snap marker: an orange ring around the snapped point.
    static func drawRing(_ point: SIMD2<Float>, in ctx: CGContext, viewport: PlanViewport) {
        guard PlanEditorOps.isFinite(point) else { return }
        let r = snapRadius
        let c = viewport.toScreen(SIMD2<Double>(Double(point.x), Double(point.y)))
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemOrange.cgColor)
        ctx.setLineWidth(2)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
