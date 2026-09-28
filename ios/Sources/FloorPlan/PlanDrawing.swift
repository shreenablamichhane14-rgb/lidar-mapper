import Foundation
import simd

/// Layer toggles (SPEC "Provide toggles"). Persisted per viewer session only.
struct PlanToggles: Codable, Equatable, Sendable {
    /// Toggle flags; each removes only its own layers (see `hiddenLayers`).
    var furniture = true, measurements = true, roomNames = true, doorsWindows = true
    var fixtures = true, grid = false, scale = true

    /// Everything on except the grid.
    static let standard = PlanToggles()

    /// Layers removed by the toggles that are off.
    var hiddenLayers: Set<String> {
        var hidden = Set<String>()
        if !furniture { hidden.insert(PlanLayers.furniture) }
        if !measurements { hidden.insert(PlanLayers.dimensions) }
        if !roomNames { hidden.insert(PlanLayers.roomNames) }
        if !doorsWindows { hidden.formUnion([PlanLayers.doors, PlanLayers.doorSwingEstimated, PlanLayers.windows]) }
        if !fixtures { hidden.insert(PlanLayers.fixtures) }
        if !grid { hidden.insert(PlanLayers.grid) }
        if !scale { hidden.insert(PlanLayers.scaleBar) }
        return hidden
    }
}

/// What the user set on the result screen that exports must respect (SPEC HIDE FURNITURE,
/// TEST_PLAN EXP-05). Declared here so Results and ExportUI (both 4c) share it without
/// importing each other.
struct ExportViewState: Equatable, Sendable {
    /// The plan layer toggles of the Floor Plan tab.
    var planToggles: PlanToggles
    /// True while Hide Furniture is on.
    var hideFurniture: Bool

    /// PlanToggles.standard, hideFurniture false.
    static let standard = ExportViewState(planToggles: .standard, hideFurniture: false)

    /// The plan toggles with the furniture layer also off while Hide Furniture is on.
    var effectivePlanToggles: PlanToggles {
        var toggles = planToggles
        if hideFurniture { toggles.furniture = false }
        return toggles
    }
}

/// Layer names and colors used by every writer (screen, PNG, PDF, SVG, DXF).
enum PlanLayers {
    /// Wall faces (measured or user thickness), jambs.
    static let walls = "A-WALL", doors = "A-DOOR", windows = "A-GLAZ", roomNames = "A-FLOR-IDEN"
    /// Annotation, furniture and grid layers.
    static let dimensions = "A-ANNO-DIMS", furniture = "A-FURN", fixtures = "A-FIXT", notes = "A-ANNO-NOTE", grid = "A-GRID"
    /// Wall spans hidden behind objects, drawn dashed.
    static let occluded = "A-WALL-OCCL"
    /// Door leaf and swing arc whose `swing?.source` is `.estimated` or `.inferred`, drawn dashed.
    static let doorSwingEstimated = "A-DOOR-EST"
    /// Outer face of walls whose `thicknessSource` is `.estimated`, drawn dashed.
    static let wallsEstimated = "A-WALL-EST"
    /// Scale bar below the plan (`toggles.scale`).
    static let scaleBar = "A-ANNO-SCAL"

    /// Layer names in drawing order (first is drawn first, underneath).
    static let drawingOrder: [String] = [grid, furniture, fixtures, walls, wallsEstimated, occluded, doors,
                                         doorSwingEstimated, windows, roomNames, dimensions, notes, scaleBar]

    /// Every layer with its color, in drawing order.
    static func all() -> [Plan2D.Layer] {
        drawingOrder.map { Plan2D.Layer(name: $0, color: color(of: $0)) }
    }

    /// RGB color of a layer in 0...1 (black for unknown names).
    static func color(of layer: String) -> SIMD3<Float> {
        switch layer {
        case grid: return SIMD3<Float>(0.82, 0.84, 0.86)
        case furniture: return SIMD3<Float>(0.50, 0.38, 0.26)
        case fixtures: return SIMD3<Float>(0.22, 0.42, 0.36)
        case walls: return SIMD3<Float>(0.05, 0.05, 0.05)
        case wallsEstimated: return SIMD3<Float>(0.40, 0.40, 0.40)
        case occluded: return SIMD3<Float>(0.55, 0.55, 0.55)
        case doors: return SIMD3<Float>(0.05, 0.30, 0.60)
        case doorSwingEstimated: return SIMD3<Float>(0.40, 0.55, 0.75)
        case windows: return SIMD3<Float>(0.00, 0.52, 0.72)
        case roomNames: return SIMD3<Float>(0.15, 0.15, 0.15)
        case dimensions: return SIMD3<Float>(0.62, 0.12, 0.12)
        case notes: return SIMD3<Float>(0.30, 0.25, 0.45)
        case scaleBar: return SIMD3<Float>(0.10, 0.10, 0.10)
        default: return SIMD3<Float>(0, 0, 0)
        }
    }
}

/// What a plan hit refers to.
enum PlanHitKind: Equatable, Sendable { case wall, opening, fixture, room, dimension, annotation }

/// Hit-test metadata for one drawn element, in plan meters (canvas has no per-element hit
/// testing, RESEARCH 3.6).
struct PlanHit: Equatable, Sendable {
    /// The element and what it is.
    var element: ElementID; var kind: PlanHitKind
    /// Center line (walls, openings, dimensions), when the element has one.
    var segment: (SIMD2<Float>, SIMD2<Float>)?
    /// Outline (wall body, opening gap, fixture footprint, room outline, text box); a single
    /// point or two points are treated as a point or a segment.
    var polygon: [SIMD2<Float>]

    /// Distance from `point` to the element, meters: 0 inside a polygon of 3 or more points,
    /// else the distance to the nearest edge, segment or point. Infinity when it has no shape.
    func distance(to point: SIMD2<Float>) -> Float {
        var best = Float.infinity
        if let line = segment {
            best = min(best, Segment2D(a: line.0, b: line.1).distance(to: point))
        }
        switch polygon.count {
        case 0:
            break
        case 1:
            best = min(best, simd_distance(polygon[0], point))
        case 2:
            best = min(best, Segment2D(a: polygon[0], b: polygon[1]).distance(to: point))
        default:
            if Polygon2D(points: polygon).contains(point: point) { return 0 }
            for i in polygon.indices {
                let next = polygon[(i + 1) % polygon.count]
                best = min(best, Segment2D(a: polygon[i], b: next).distance(to: point))
            }
        }
        return best
    }

    /// Equal when element, kind, segment and polygon are equal.
    static func == (lhs: PlanHit, rhs: PlanHit) -> Bool {
        guard lhs.element == rhs.element, lhs.kind == rhs.kind, lhs.polygon == rhs.polygon else { return false }
        switch (lhs.segment, rhs.segment) {
        case (nil, nil): return true
        case let (l?, r?): return l.0 == r.0 && l.1 == r.1
        default: return false
        }
    }
}

/// A plan level drawn as Export's `Plan2D` plus the hit metadata of what was drawn.
struct PlanDrawingResult {
    /// The drawing every writer and the screen consume.
    var plan: Plan2D
    /// Hits of the visible elements.
    var hits: [PlanHit]
}

/// Turns a `PlanLevel` into a `Plan2D` with layers, symbols and formatted labels.
enum PlanDrawing {
    /// Dimension label height, meters.
    static let dimensionTextHeight: Double = 0.15
    /// Room title height and area line height, meters.
    static let roomTitleHeight: Float = 0.22, roomAreaHeight: Float = 0.16
    /// Annotation text height, meters.
    static let noteTextHeight: Float = 0.15

    /// Labels are formatted here with Units; hidden fixtures are skipped; occluded wall spans go to
    /// `PlanLayers.occluded` as dashed segments; door = gap + leaf line + quarter arc from the hinge;
    /// window = three parallel lines; opening = gap with a thin line; stairs = treads at 0.28 m.
    /// Honest estimates (SPEC "clearly distinguish estimated geometry", RESEARCH 3.6: RoomPlan has
    /// no hinge side and no thickness): the leaf and arc of a door whose swing is `.estimated` or
    /// `.inferred` are drawn dashed (short `.line` and `.arc` pieces) on `doorSwingEstimated`, a
    /// `.user` swing solid on `doors`; the inner face of a wall is solid on `walls`, its outer face
    /// dashed on `wallsEstimated` when `thicknessSource` is `.estimated`. `doorsWindows` toggles both
    /// door layers. `toggles.grid` draws 1 m lines (metric) or 1 ft lines (imperial) over the plan
    /// bounds on `grid`; `toggles.scale` draws a 4-segment scale bar with a Units-formatted end
    /// label below the plan on `scaleBar`. Every toggle removes only its own layers.
    ///
    /// The grid and the scale bar are placed from the bounds of all content before toggles are
    /// applied, so they do not move when other layers are switched. Hits of elements on hidden
    /// layers are left out.
    static func make(level: PlanLevel, toggles: PlanToggles, prefs: UnitPreferences,
                     roomTitles: [ElementID: String], name: String) -> PlanDrawingResult {
        var sketch = PlanSketch()
        var hits: [(hit: PlanHit, layer: String?)] = []

        for (index, room) in level.rooms.enumerated() {
            let outline = room.outline.map { $0.simd }
            let title = roomTitles[room.id] ?? RoomTitles.title(name: room.name, sectionLabel: nil, index: index)
            let area = AreaFormat.primary(Double(room.area), prefs: prefs)
            drawRoomTag(Copy.FloorPlan.roomTag(name: title, area: area), at: room.labelAt.simd, outline: outline, into: &sketch)
            hits.append((hit: PlanHit(element: room.id, kind: .room, segment: nil, polygon: outline), layer: nil))
        }

        for wallHit in PlanWallDrawing.draw(level: level, into: &sketch) {
            hits.append((hit: wallHit.hit, layer: wallHit.layer))
        }

        for fixture in level.fixtures where !fixture.isHidden {
            let layer = fixture.isMovable ? PlanLayers.furniture : PlanLayers.fixtures
            PlanSymbols.draw(fixture, layer: layer, walls: level.walls, into: &sketch)
            let footprint = PlanSymbols.footprint(fixture)
            hits.append((hit: PlanHit(element: fixture.id, kind: .fixture, segment: nil, polygon: footprint), layer: layer))
        }

        for dimension in level.dimensions {
            guard let hit = drawDimension(dimension, prefs: prefs, into: &sketch) else { continue }
            hits.append((hit: hit, layer: PlanLayers.dimensions))
        }

        for annotation in level.annotations {
            guard let hit = drawAnnotation(annotation, into: &sketch) else { continue }
            hits.append((hit: hit, layer: PlanLayers.notes))
        }

        let content = Plan2D(name: name, layers: PlanLayers.all(), entities: sketch.entities(in: PlanLayers.drawingOrder),
                             dimensionTextHeight: dimensionTextHeight)
        if let bounds = content.bounds() {
            drawGrid(bounds: bounds, prefs: prefs, into: &sketch)
            drawScaleBar(bounds: bounds, prefs: prefs, into: &sketch)
        }

        let hidden = toggles.hiddenLayers
        let visibleOrder = PlanLayers.drawingOrder.filter { !hidden.contains($0) }
        let layers = PlanLayers.all().filter { !hidden.contains($0.name) }
        let plan = Plan2D(name: name, layers: layers, entities: sketch.entities(in: visibleOrder),
                          dimensionTextHeight: dimensionTextHeight)
        let visibleHits = hits.filter { entry in entry.layer.map { !hidden.contains($0) } ?? true }.map { $0.hit }
        return PlanDrawingResult(plan: plan, hits: visibleHits)
    }

    /// The nearest hit within `tolerance` meters of `point`. Rooms are chosen only when no
    /// other element is within tolerance (a tap inside a room near a wall picks the wall), and
    /// an opening wins over a wall it sits in when it is nearly as close.
    static func hitTest(_ hits: [PlanHit], at point: SIMD2<Float>, tolerance: Float) -> PlanHit? {
        let limit = max(0, tolerance.isFinite ? tolerance : 0)
        var candidates: [(hit: PlanHit, distance: Float)] = []
        var rooms: [(hit: PlanHit, distance: Float, area: Float)] = []
        for hit in hits {
            let d = hit.distance(to: point)
            guard d <= limit else { continue }
            if hit.kind == .room {
                rooms.append((hit: hit, distance: d, area: Polygon2D(points: hit.polygon).area))
            } else {
                candidates.append((hit: hit, distance: d))
            }
        }
        if let nearest = candidates.min(by: { $0.distance < $1.distance }) {
            guard nearest.hit.kind != .opening else { return nearest.hit }
            let slack = limit * 0.25 + 1e-4
            let openings = candidates.filter { $0.hit.kind == .opening && $0.distance <= nearest.distance + slack }
            return (openings.min(by: { $0.distance < $1.distance }) ?? nearest).hit
        }
        let room = rooms.min { lhs, rhs in
            lhs.distance != rhs.distance ? lhs.distance < rhs.distance : lhs.area < rhs.area
        }
        return room?.hit
    }

    /// Room title and area as centered single-line texts, shrunk to fit narrow rooms.
    private static func drawRoomTag(_ tag: String, at center: SIMD2<Float>, outline: [SIMD2<Float>], into sketch: inout PlanSketch) {
        let lines = tag.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        var heights = lines.indices.map { $0 == 0 ? roomTitleHeight : roomAreaHeight }
        if let box = Polygon2D(points: outline).boundingBox {
            let roomWidth = Double(box.max.x - box.min.x) * 0.9
            var widest = 0.0
            for (i, line) in lines.enumerated() {
                widest = max(widest, Plan2D.estimatedTextWidth(line, height: Double(heights[i])))
            }
            if widest > roomWidth, roomWidth > 0 {
                let factor = Float(max(0.4, roomWidth / widest))
                heights = heights.map { $0 * factor }
            }
        }
        let gap: Float = 0.06
        let total = heights.reduce(0, +) + gap * Float(lines.count - 1)
        var top = center.y + total / 2
        for (i, line) in lines.enumerated() {
            let baseline = SIMD2<Float>(center.x, top - heights[i])
            sketch.centeredText(PlanLayers.roomNames, line, baselineCenter: baseline, height: heights[i])
            top -= heights[i] + gap
        }
    }

    /// A dimension with its Units label, or nil when its length is zero or not finite.
    private static func drawDimension(_ dimension: PlanDimension, prefs: UnitPreferences, into sketch: inout PlanSketch) -> PlanHit? {
        let a = dimension.a.simd
        let b = dimension.b.simd
        let length = dimension.length
        guard length.isFinite, length > 0.005, dimension.offset.isFinite else { return nil }
        let label = LengthFormat.primary(Double(length), prefs: prefs)
        sketch.add(PlanLayers.dimensions, .dimension(from: PlanSketch.d(a), to: PlanSketch.d(b),
                                                    offset: Double(dimension.offset), label: label))
        let u = (b - a) / length
        let shift = SIMD2<Float>(-u.y, u.x) * dimension.offset
        return PlanHit(element: dimension.id, kind: .dimension, segment: (a + shift, b + shift), polygon: [])
    }

    /// A text, note or symbol annotation; nil when it has nothing to draw.
    private static func drawAnnotation(_ annotation: PlanAnnotation, into sketch: inout PlanSketch) -> PlanHit? {
        let at = annotation.at.simd
        guard at.x.isFinite, at.y.isFinite else { return nil }
        var lines = annotation.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var textStart = at
        let h = noteTextHeight
        switch annotation.kind {
        case .text:
            break
        case .note:
            let s: Float = 0.08
            let marker = [SIMD2<Float>(at.x, at.y), SIMD2<Float>(at.x + s, at.y),
                          SIMD2<Float>(at.x + s, at.y + s), SIMD2<Float>(at.x, at.y + s)]
            sketch.polyline(PlanLayers.notes, marker, closed: true)
            textStart = at + SIMD2<Float>(s + 0.06, 0)
        case .symbol:
            sketch.circle(PlanLayers.notes, center: at, radius: 0.1)
            if let symbol = annotation.symbol, !symbol.isEmpty { lines.insert(symbol, at: 0) }
            textStart = at + SIMD2<Float>(0.16, -h / 2)
        }
        var width: Float = 0.2
        for (i, line) in lines.enumerated() {
            let baseline = textStart - SIMD2<Float>(0, Float(i) * (h + 0.05))
            sketch.text(PlanLayers.notes, line, at: baseline, height: h)
            width = max(width, Float(Plan2D.estimatedTextWidth(line, height: Double(h))))
        }
        let lineCount = Float(max(0, lines.count - 1))
        let textDepth: Float = lineCount * (h + 0.05) + h * 0.3
        let bottom = textStart.y - textDepth
        let top = max(textStart.y + h, at.y + 0.1)
        let left = min(at.x - 0.1, textStart.x)
        let right = textStart.x + width
        let box = [SIMD2<Float>(left, bottom), SIMD2<Float>(right, bottom), SIMD2<Float>(right, top), SIMD2<Float>(left, top)]
        return PlanHit(element: annotation.id, kind: .annotation, segment: nil, polygon: box)
    }

    /// Grid lines every 1 m (metric) or 1 ft (imperial), doubled until at most 200 lines per
    /// direction, over the content bounds expanded by one step.
    private static func drawGrid(bounds: (min: SIMD2<Double>, max: SIMD2<Double>), prefs: UnitPreferences,
                                 into sketch: inout PlanSketch) {
        var step = prefs.system == .metric ? 1.0 : LengthFormat.metersPerFoot
        let span = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
        guard span.isFinite else { return }
        while span / step > 200 { step *= 2 }
        let x0 = (bounds.min.x / step).rounded(.down) * step - step
        let y0 = (bounds.min.y / step).rounded(.down) * step - step
        let x1 = (bounds.max.x / step).rounded(.up) * step + step
        let y1 = (bounds.max.y / step).rounded(.up) * step + step
        let columns = Int(((x1 - x0) / step).rounded())
        let rows = Int(((y1 - y0) / step).rounded())
        for i in 0...max(0, columns) {
            let x = x0 + Double(i) * step
            sketch.add(PlanLayers.grid, .line(from: SIMD2<Double>(x, y0), to: SIMD2<Double>(x, y1)))
        }
        for j in 0...max(0, rows) {
            let y = y0 + Double(j) * step
            sketch.add(PlanLayers.grid, .line(from: SIMD2<Double>(x0, y), to: SIMD2<Double>(x1, y)))
        }
    }

    /// A 4-segment scale bar under the plan's lower left corner with the total length as a
    /// Units-formatted label: four outlined segments, a center line through segments 1 and 3
    /// so they read as alternating, and the end label.
    private static func drawScaleBar(bounds: (min: SIMD2<Double>, max: SIMD2<Double>), prefs: UnitPreferences,
                                     into sketch: inout PlanSketch) {
        let metric = prefs.system == .metric
        let unit = metric ? 1.0 : LengthFormat.metersPerFoot
        let steps: [Double] = metric ? [0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20, 50] : [0.5, 1, 2, 5, 10, 20, 50, 100, 200]
        let target = max((bounds.max.x - bounds.min.x) * 0.3, 0.4) / 4
        let chosen = steps.last(where: { $0 * unit <= target }) ?? steps[0]
        let segment = chosen * unit
        let height = 0.08
        let origin = SIMD2<Double>(bounds.min.x, bounds.min.y - 0.45 - height)
        for i in 0..<4 {
            let x0 = origin.x + Double(i) * segment
            let x1 = x0 + segment
            let corners = [SIMD2<Double>(x0, origin.y), SIMD2<Double>(x1, origin.y),
                           SIMD2<Double>(x1, origin.y + height), SIMD2<Double>(x0, origin.y + height)]
            sketch.add(PlanLayers.scaleBar, .polyline(points: corners, closed: true))
            if i % 2 == 0 {
                let mid = origin.y + height / 2
                sketch.add(PlanLayers.scaleBar, .line(from: SIMD2<Double>(x0, mid), to: SIMD2<Double>(x1, mid)))
            }
        }
        let label = LengthFormat.primary(segment * 4, prefs: prefs)
        let labelAt = SIMD2<Double>(origin.x + segment * 4 + 0.1, origin.y)
        sketch.add(PlanLayers.scaleBar, .text(position: labelAt, height: 0.14, string: label, rotation: 0))
    }
}
