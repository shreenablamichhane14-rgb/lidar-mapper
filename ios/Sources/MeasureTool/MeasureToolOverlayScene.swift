import SwiftUI
import simd

/// Screen geometry of the overlay for one camera position: built on main from the model (every
/// world point through `MeasureToolModel.screenPoint`), drawn by a SwiftUI `Canvas` without
/// touching the model. A line or label whose points project to nil (behind the camera) is skipped.
struct MeasureToolOverlayScene {
    /// A straight line on screen.
    struct StrokeItem {
        /// End points on screen.
        var from: CGPoint
        var to: CGPoint
        /// Thin dashed line (the horizontal part of a height).
        var dashed: Bool
        /// Part of the draft (cyan) rather than a saved measurement (yellow).
        var isDraft: Bool
    }

    /// A closed area on screen.
    struct FillItem {
        /// Corners on screen, in order.
        var points: [CGPoint]
        /// Part of the draft.
        var isDraft: Bool
    }

    /// The small arc of an angle at its corner.
    struct ArcItem {
        /// The corner on screen.
        var center: CGPoint
        /// Start and end angles, radians on screen.
        var start: Double
        var end: Double
        /// Part of the draft.
        var isDraft: Bool
    }

    /// One on-model label.
    struct LabelItem: Identifiable {
        /// The record id, or "draft".
        var id: String
        /// Label center on screen.
        var anchor: CGPoint
        /// Value line and accuracy line (the low-confidence text replaces the accuracy).
        var value: String
        var accuracy: String?
        /// The measurement's low-confidence flag.
        var isLowConfidence: Bool
        /// VoiceOver text.
        var accessibility: String
        /// Part of the draft.
        var isDraft: Bool
    }

    /// One draggable point.
    struct HandleItem: Identifiable {
        /// The point it moves.
        var handle: MeasureToolHandle
        /// Position on screen.
        var point: CGPoint
        /// VoiceOver name ("Distance 2, Point 1").
        var label: String
        /// Part of the draft.
        var isDraft: Bool
        /// Identity for `ForEach`: the handle.
        var id: MeasureToolHandle { handle }
    }

    /// What to draw, in draw order: fills, strokes, arcs; then labels and handles as views.
    var strokes: [StrokeItem] = []
    var fills: [FillItem] = []
    var arcs: [ArcItem] = []
    var labels: [LabelItem] = []
    var handles: [HandleItem] = []

    /// Radius of an angle's arc, points.
    static let arcRadius: CGFloat = 22
    /// Distance of an angle's label from its corner, points.
    static let angleLabelOffset: CGFloat = 40

    // MARK: - Building (main)

    /// The scene of every saved record and the draft. `cameraRevision` is taken so a camera change
    /// rebuilds it.
    @MainActor static func make(model: MeasureToolModel, cameraRevision: Int) -> MeasureToolOverlayScene {
        var scene = MeasureToolOverlayScene()
        var rowsByID: [UUID: MeasureToolRow] = [:]
        for row in model.rows where rowsByID[row.id] == nil { rowsByID[row.id] = row }
        let records = model.records
        for record in records {
            let points = record.points.map { $0.simd }
            let projected = points.map { model.screenPoint($0) }
            let row = rowsByID[record.id]
            scene.addShape(kind: record.kind, world: points, screen: projected, isDraft: false,
                           labelID: record.id.uuidString, row: row, model: model)
            guard !MeasureToolSnaps.isWallRecord(record, among: records) else { continue }
            let title = row?.title ?? MeasureToolPresentation.kindTitle(record.kind)
            for (i, p) in projected.enumerated() {
                guard let screen = p else { continue }
                let name = Copy.MeasureCore.rowName(element: title, measure: Copy.MeasureTool.pointLabel(i + 1))
                scene.handles.append(HandleItem(handle: .record(id: record.id, index: i), point: screen,
                                                label: name, isDraft: false))
            }
        }
        let draft = model.draft
        let draftWorld = draft.points.map { $0.position }
        let draftScreen = draftWorld.map { model.screenPoint($0) }
        scene.addShape(kind: draft.kind.measurementKind, world: draftWorld, screen: draftScreen, isDraft: true,
                       labelID: "draft", row: nil, model: model)
        for (i, p) in draftScreen.enumerated() {
            guard let screen = p else { continue }
            scene.handles.append(HandleItem(handle: .draft(index: i), point: screen,
                                            label: Copy.MeasureTool.pointLabel(i + 1), isDraft: true))
        }
        return scene
    }

    /// Lines, fill, arc and label of one measurement (saved when `row` is given, else the draft).
    @MainActor private mutating func addShape(kind: MeasurementKind, world: [SIMD3<Float>], screen: [CGPoint?],
                                              isDraft: Bool, labelID: String, row: MeasureToolRow?,
                                              model: MeasureToolModel) {
        var anchor: CGPoint?
        switch kind {
        case .distance, .wallLength, .perimeter, .volume:
            addPolyline(screen, closed: false, isDraft: isDraft)
            if screen.count >= 2, let a = screen[0], let b = screen[1] {
                anchor = MeasureToolOverlayScene.middle(a, b)
            }
        case .height:
            anchor = addHeight(world: world, screen: screen, isDraft: isDraft, model: model)
        case .area:
            if world.count >= 3 {
                let all = screen.compactMap { $0 }
                if all.count == screen.count { fills.append(FillItem(points: all, isDraft: isDraft)) }
                addPolyline(screen, closed: true, isDraft: isDraft)
                anchor = model.screenPoint(MeasureMath.polygonCenter(world))
            } else {
                addPolyline(screen, closed: false, isDraft: isDraft)
            }
        case .angle:
            addPolyline(screen, closed: false, isDraft: isDraft)
            if screen.count >= 3, let a = screen[0], let b = screen[1], let c = screen[2] {
                anchor = addAngleArc(a, b, c, isDraft: isDraft)
            }
        }
        guard let at = anchor else { return }
        if let row {
            labels.append(LabelItem(id: labelID, anchor: at, value: row.valueText, accuracy: row.accuracyText,
                                    isLowConfidence: row.isLowConfidence, accessibility: row.accessibility,
                                    isDraft: false))
        } else if let value = model.draft.value {
            let flag = model.draftIsLowConfidence
            let text = MeasureToolPresentation.label(value, kind: kind, prefs: model.prefs, lowConfidence: flag)
            let spoken = MeasureDisplay.accessibilityText(label: MeasureToolPresentation.title(of: model.draft.kind),
                                                          value: value, kind: kind, prefs: model.prefs,
                                                          lowConfidence: flag)
            labels.append(LabelItem(id: labelID, anchor: at, value: text.value, accuracy: text.accuracy,
                                    isLowConfidence: flag, accessibility: spoken, isDraft: true))
        }
    }

    /// Consecutive segments between projected points (closing back to the first when `closed`).
    private mutating func addPolyline(_ screen: [CGPoint?], closed: Bool, isDraft: Bool) {
        let n = screen.count
        guard n >= 2 else { return }
        let last = closed && n >= 3 ? n : n - 1
        for i in 0..<last {
            guard let a = screen[i], let b = screen[(i + 1) % n] else { continue }
            strokes.append(StrokeItem(from: a, to: b, dashed: false, isDraft: isDraft))
        }
    }

    /// A height: from the lower point straight up to the upper point's height, then a thin dashed
    /// line to the upper point. Returns the label anchor (middle of the vertical part).
    @MainActor private mutating func addHeight(world: [SIMD3<Float>], screen: [CGPoint?], isDraft: Bool,
                                               model: MeasureToolModel) -> CGPoint? {
        guard world.count >= 2, screen.count >= 2 else { return nil }
        let lowerIndex = world[0].y <= world[1].y ? 0 : 1
        let lower = world[lowerIndex]
        let upper = world[1 - lowerIndex]
        let corner = SIMD3<Float>(lower.x, upper.y, lower.z)
        guard let a = screen[lowerIndex], let c = model.screenPoint(corner) else { return nil }
        strokes.append(StrokeItem(from: a, to: c, dashed: false, isDraft: isDraft))
        if let u = screen[1 - lowerIndex], simd_distance(corner, upper) > 0.001 {
            strokes.append(StrokeItem(from: c, to: u, dashed: true, isDraft: isDraft))
        }
        return MeasureToolOverlayScene.middle(a, c)
    }

    /// The arc at corner `b` between the arms to `a` and `c`; returns the label anchor on the bisector.
    private mutating func addAngleArc(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, isDraft: Bool) -> CGPoint {
        let ay: Double = Double(a.y - b.y)
        let ax: Double = Double(a.x - b.x)
        let cy: Double = Double(c.y - b.y)
        let cx: Double = Double(c.x - b.x)
        let angleA: Double = atan2(ay, ax)
        let angleC: Double = atan2(cy, cx)
        var delta: Double = angleC - angleA
        while delta > Double.pi { delta -= 2 * Double.pi }
        while delta < -Double.pi { delta += 2 * Double.pi }
        arcs.append(ArcItem(center: b, start: angleA, end: angleA + delta, isDraft: isDraft))
        let bisector: Double = angleA + delta / 2
        let offset: Double = Double(MeasureToolOverlayScene.angleLabelOffset)
        let x: Double = Double(b.x) + cos(bisector) * offset
        let y: Double = Double(b.y) + sin(bisector) * offset
        return CGPoint(x: x, y: y)
    }

    /// Midpoint of two screen points.
    static func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: - Drawing (any thread)

    /// Draws fills, then lines with a dark outline, then arcs. Saved measurements are yellow,
    /// the draft cyan.
    static func draw(_ scene: MeasureToolOverlayScene, in context: inout GraphicsContext) {
        for fill in scene.fills {
            var path = Path()
            path.addLines(fill.points)
            path.closeSubpath()
            context.fill(path, with: .color(color(fill.isDraft).opacity(0.22)))
        }
        for stroke in scene.strokes {
            var path = Path()
            path.move(to: stroke.from)
            path.addLine(to: stroke.to)
            let width: CGFloat = stroke.dashed ? 1.5 : 2.5
            let dash: [CGFloat] = stroke.dashed ? [5, 4] : []
            context.stroke(path, with: .color(Color.black.opacity(0.6)),
                           style: StrokeStyle(lineWidth: width + 2, lineCap: .round, dash: dash))
            context.stroke(path, with: .color(color(stroke.isDraft)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }
        for arc in scene.arcs {
            var path = Path()
            path.addArc(center: arc.center, radius: arcRadius, startAngle: .radians(arc.start),
                        endAngle: .radians(arc.end), clockwise: arc.end < arc.start)
            context.stroke(path, with: .color(color(arc.isDraft)), style: StrokeStyle(lineWidth: 2))
        }
    }

    /// Line color of saved measurements and of the draft.
    static func color(_ isDraft: Bool) -> Color {
        isDraft ? Color.cyan : Color.yellow
    }
}
