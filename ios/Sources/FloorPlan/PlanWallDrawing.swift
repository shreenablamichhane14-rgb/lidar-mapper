import Foundation
import simd

/// Walls with their doors, windows and openings (docs/MODULES.md 3.16). A wall runs a->b with
/// the room on its left; its inner face is the a->b line and its body extends to the right
/// by the thickness. Outer faces are mitered where one wall's end meets the next wall's start.
enum PlanWallDrawing {
    /// A wall end within this distance of another wall's start is joined to it, meters.
    static let joinTolerance: Float = 0.05
    /// Window lines are spread over at least this depth when a wall has no thickness, meters.
    static let minimumSymbolThickness: Float = 0.08

    /// One straight wall in plan coordinates.
    private struct WallGeometry {
        let wall: PlanWall
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        /// Unit direction a->b.
        let u: SIMD2<Float>
        /// Unit normal toward the room (left of a->b) and away from it.
        let left: SIMD2<Float>
        let right: SIMD2<Float>
        let length: Float
        let thickness: Float

        /// Point on the inner face at distance `s` from a.
        func inner(_ s: Float) -> SIMD2<Float> { a + u * s }
        /// Point on the outer face at distance `s` along the wall.
        func outer(_ s: Float) -> SIMD2<Float> { a + u * s + right * thickness }
    }

    /// Where the outer face starts and ends along the wall and whether each end joins another wall.
    private struct OuterExtent {
        var start: Float
        var end: Float
        var joinedStart: Bool
        var joinedEnd: Bool
    }

    /// Draws every wall of the level and the openings hosted by it. Returns the wall hits
    /// (layer nil, always visible) and the opening hits with the layer their symbol is on.
    static func draw(level: PlanLevel, into sketch: inout PlanSketch) -> [(hit: PlanHit, layer: String?)] {
        var hits: [(hit: PlanHit, layer: String?)] = []
        let geometries = level.walls.map { geometry(of: $0) }
        for (i, wall) in level.walls.enumerated() {
            guard let g = geometries[i] else { continue }
            let openings = level.openings.filter { $0.wallID == wall.id }
            var curvedHit: PlanHit?
            if let arc = wall.arc {
                curvedHit = drawCurved(g, arc: arc, into: &sketch)
            }
            if let hit = curvedHit {
                hits.append((hit: hit, layer: nil))
            } else {
                let extent = outerExtent(i, geometries)
                drawStraight(g, openings: openings, extent: extent, into: &sketch)
                let body = g.thickness > 1e-4 ? [g.a, g.b, g.outer(g.length), g.outer(0)] : []
                hits.append((hit: PlanHit(element: wall.id, kind: .wall, segment: (g.a, g.b), polygon: body), layer: nil))
            }
            for opening in openings {
                if let entry = drawOpening(opening, on: g, into: &sketch) {
                    hits.append((hit: entry.hit, layer: entry.layer))
                }
            }
        }
        return hits
    }

    /// Plan geometry of a wall, nil when its endpoints are not finite or coincide.
    private static func geometry(of wall: PlanWall) -> WallGeometry? {
        let a = wall.a.simd
        let b = wall.b.simd
        guard PlanSketch.isFinite(a), PlanSketch.isFinite(b) else { return nil }
        let length = simd_distance(a, b)
        guard length > 1e-4 else { return nil }
        let u = (b - a) / length
        let left = SIMD2<Float>(-u.y, u.x)
        let thickness = wall.thickness.isFinite ? max(0, wall.thickness) : 0
        return WallGeometry(wall: wall, a: a, b: b, u: u, left: left, right: -left, length: length, thickness: thickness)
    }

    /// Outer face extent of wall `i`: mitered with the wall whose start meets its end and the
    /// wall whose end meets its start (straight neighbours only).
    private static func outerExtent(_ i: Int, _ geometries: [WallGeometry?]) -> OuterExtent {
        guard let g = geometries[i] else { return OuterExtent(start: 0, end: 0, joinedStart: false, joinedEnd: false) }
        var extent = OuterExtent(start: 0, end: g.length, joinedStart: false, joinedEnd: false)
        for (j, candidate) in geometries.enumerated() where j != i {
            guard let other = candidate, other.wall.arc == nil else { continue }
            if !extent.joinedEnd, simd_distance(g.b, other.a) <= joinTolerance {
                extent.joinedEnd = true
                if let s = outerIntersection(g, other) { extent.end = s }
            }
            if !extent.joinedStart, simd_distance(g.a, other.b) <= joinTolerance {
                extent.joinedStart = true
                if let s = outerIntersection(g, other) { extent.start = s }
            }
        }
        if extent.end < extent.start { extent = OuterExtent(start: 0, end: g.length, joinedStart: extent.joinedStart, joinedEnd: extent.joinedEnd) }
        return extent
    }

    /// Distance along `g` where its outer face line meets the outer face line of `other`, or
    /// nil when they are nearly parallel or the miter would reach too far.
    private static func outerIntersection(_ g: WallGeometry, _ other: WallGeometry) -> Float? {
        let denominator = Segment2D.cross(g.u, other.u)
        guard abs(denominator) > 0.05 else { return nil }
        let p = g.a + g.right * g.thickness
        let q = other.a + other.right * other.thickness
        let s = Segment2D.cross(q - p, other.u) / denominator
        let reach = 4 * max(g.thickness, other.thickness) + 0.05
        guard s.isFinite, s >= -reach, s <= g.length + reach else { return nil }
        return s
    }

    /// Inner face (solid on `walls`, occluded spans dashed on `occluded`), outer face (dashed on
    /// `wallsEstimated` when the thickness is estimated), jambs at openings and caps at free ends.
    private static func drawStraight(_ g: WallGeometry, openings: [PlanOpening], extent: OuterExtent,
                                     into sketch: inout PlanSketch) {
        let gaps = gapIntervals(openings, length: g.length)
        for piece in subtract((0, g.length), gaps) {
            let hidden = clipped(g.wall.occludedSpans, to: piece)
            for solid in subtract(piece, hidden) {
                sketch.line(PlanLayers.walls, g.inner(solid.0), g.inner(solid.1))
            }
            for span in hidden {
                sketch.dashedLine(PlanLayers.occluded, g.inner(span.0), g.inner(span.1))
            }
        }
        guard g.thickness > 1e-4 else { return }
        let estimated = g.wall.thicknessSource == .estimated
        for piece in subtract((extent.start, extent.end), gaps) {
            stroke(g.outer(piece.0), g.outer(piece.1), estimated: estimated, into: &sketch)
        }
        for gap in gaps {
            for s in [gap.0, gap.1] where s > 1e-3 && s < g.length - 1e-3 {
                sketch.line(PlanLayers.walls, g.inner(s), g.outer(s))
            }
        }
        if !extent.joinedStart { stroke(g.inner(0), g.outer(0), estimated: estimated, into: &sketch) }
        if !extent.joinedEnd { stroke(g.inner(g.length), g.outer(g.length), estimated: estimated, into: &sketch) }
    }

    /// An outer-face segment: dashed on `wallsEstimated` when estimated, else solid on `walls`.
    private static func stroke(_ p: SIMD2<Float>, _ q: SIMD2<Float>, estimated: Bool, into sketch: inout PlanSketch) {
        if estimated {
            sketch.dashedLine(PlanLayers.wallsEstimated, p, q)
        } else {
            sketch.line(PlanLayers.walls, p, q)
        }
    }

    /// A curved wall sampled along its arc (RoomModel's `WallArc`: plan angles, the covered
    /// side contains the middle angle, the radius blends from |a - center| to |b - center| so
    /// the samples meet the corners, as in RoomModel's outline). Nil when the arc is unusable
    /// (the caller then draws the wall straight). Openings are drawn on the chord and occluded
    /// spans are not marked on curved walls.
    private static func drawCurved(_ g: WallGeometry, arc: WallArc, into sketch: inout PlanSketch) -> PlanHit? {
        let c = PlanAxes.toPlan(arc.center.simd)
        guard PlanSketch.isFinite(c), arc.radius.isFinite, arc.radius > 1e-3,
              arc.startAngle.isFinite, arc.endAngle.isFinite else { return nil }
        let radiusA = simd_distance(g.a, c)
        let radiusB = simd_distance(g.b, c)
        guard radiusA > 1e-3, radiusB > 1e-3 else { return nil }
        let alpha = atan2(g.a.y - c.y, g.a.x - c.x)
        let beta = atan2(g.b.y - c.y, g.b.x - c.x)
        let middle = (arc.startAngle + arc.endAngle) * 0.5
        let counterClockwise = positiveAngle(beta - alpha)
        let sweep: Float = positiveAngle(middle - alpha) <= counterClockwise
            ? counterClockwise : -(2 * Float.pi - counterClockwise)
        guard abs(sweep) > 1e-4 else { return nil }
        // Travelling counter-clockwise the room (left) is toward the center, so the body grows
        // outward; travelling clockwise it grows toward the center.
        let outward: Float = sweep > 0 ? 1 : -1
        let rawSteps = (abs(sweep) / (5 * Float.pi / 180)).rounded(.up)
        let steps = Int(min(72, max(2, rawSteps)))
        var inner: [SIMD2<Float>] = []
        var outer: [SIMD2<Float>] = []
        for i in 0...steps {
            let f = Float(i) / Float(steps)
            let angle = alpha + sweep * f
            let radius = radiusA + (radiusB - radiusA) * f
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let onArc: SIMD2<Float> = c + direction * radius
            inner.append(i == 0 ? g.a : (i == steps ? g.b : onArc))
            outer.append(c + direction * max(0, radius + outward * g.thickness))
        }
        sketch.polyline(PlanLayers.walls, inner, closed: false)
        let estimated = g.wall.thicknessSource == .estimated
        if g.thickness > 1e-4 {
            if estimated {
                sketch.dashedPolyline(PlanLayers.wallsEstimated, outer)
            } else {
                sketch.polyline(PlanLayers.walls, outer, closed: false)
            }
            if let firstInner = inner.first, let firstOuter = outer.first, let lastInner = inner.last, let lastOuter = outer.last {
                stroke(firstInner, firstOuter, estimated: estimated, into: &sketch)
                stroke(lastInner, lastOuter, estimated: estimated, into: &sketch)
            }
        }
        let band = inner + Array(outer.reversed())
        return PlanHit(element: g.wall.id, kind: .wall, segment: nil, polygon: band)
    }

    /// An angle wrapped into 0 ..< 2 pi.
    private static func positiveAngle(_ angle: Float) -> Float {
        let twoPi = 2 * Float.pi
        let wrapped = angle.truncatingRemainder(dividingBy: twoPi)
        return wrapped < 0 ? wrapped + twoPi : wrapped
    }

    /// Sorted gap intervals (distance from a) of the openings hosted by a wall.
    private static func gapIntervals(_ openings: [PlanOpening], length: Float) -> [(Float, Float)] {
        var gaps: [(Float, Float)] = []
        for opening in openings {
            guard let placed = placement(opening, length: length) else { continue }
            gaps.append((placed.offset, placed.offset + placed.width))
        }
        return gaps.sorted { $0.0 < $1.0 }
    }

    /// Offset and width of an opening clamped to its wall, nil when it has no width.
    private static func placement(_ opening: PlanOpening, length: Float) -> (offset: Float, width: Float)? {
        guard opening.width.isFinite, opening.offset.isFinite else { return nil }
        let width = min(max(opening.width, 0), length)
        guard width > 1e-3 else { return nil }
        return (min(max(opening.offset, 0), max(0, length - width)), width)
    }

    /// `range` minus the cut intervals, as sorted pieces.
    private static func subtract(_ range: (Float, Float), _ cuts: [(Float, Float)]) -> [(Float, Float)] {
        var pieces: [(Float, Float)] = []
        var cursor = range.0
        for cut in cuts.sorted(by: { $0.0 < $1.0 }) {
            let lower = max(cut.0, range.0)
            let upper = min(cut.1, range.1)
            guard upper > lower else { continue }
            if lower > cursor + 1e-5 { pieces.append((cursor, lower)) }
            cursor = max(cursor, upper)
        }
        if range.1 > cursor + 1e-5 { pieces.append((cursor, range.1)) }
        return pieces
    }

    /// Occluded spans clipped to `piece`, sorted and merged.
    private static func clipped(_ spans: [ClosedRange<Float>], to piece: (Float, Float)) -> [(Float, Float)] {
        var parts: [(Float, Float)] = []
        for span in spans {
            let lower = max(span.lowerBound, piece.0)
            let upper = min(span.upperBound, piece.1)
            if upper - lower > 1e-4 { parts.append((lower, upper)) }
        }
        parts.sort { $0.0 < $1.0 }
        var merged: [(Float, Float)] = []
        for part in parts {
            if let last = merged.last, part.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, part.1)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    /// Door, window or opening symbol on its wall; returns its hit and the layer it is on.
    private static func drawOpening(_ opening: PlanOpening, on g: WallGeometry,
                                    into sketch: inout PlanSketch) -> (hit: PlanHit, layer: String)? {
        guard let placed = placement(opening, length: g.length) else { return nil }
        let o = placed.offset
        let width = placed.width
        let layer: String
        switch opening.kind {
        case .door, .openDoor:
            layer = drawDoor(opening, on: g, offset: o, width: width, into: &sketch)
        case .window:
            layer = PlanLayers.windows
            let depth = max(g.thickness, minimumSymbolThickness)
            for fraction in [Float(0), 0.5, 1] {
                let shift = g.right * (depth * fraction)
                sketch.line(layer, g.inner(o) + shift, g.inner(o + width) + shift)
            }
        case .opening:
            layer = PlanLayers.doors
            let shift = g.right * (g.thickness * 0.5)
            sketch.line(layer, g.inner(o) + shift, g.inner(o + width) + shift)
        }
        let gap = g.thickness > 1e-4 ? [g.inner(o), g.inner(o + width), g.outer(o + width), g.outer(o)] : []
        let hit = PlanHit(element: opening.id, kind: .opening, segment: (g.inner(o), g.inner(o + width)), polygon: gap)
        return (hit: hit, layer: layer)
    }

    /// Door leaf from the hinge (perpendicular to the wall, length = width) and the quarter arc
    /// to the other jamb. Solid on `doors` for a measured or user swing; dashed pieces on
    /// `doorSwingEstimated` for an estimated, inferred or missing swing. Returns the layer used.
    private static func drawDoor(_ opening: PlanOpening, on g: WallGeometry, offset o: Float, width: Float,
                                 into sketch: inout PlanSketch) -> String {
        let swing = opening.swing ?? PlanBuilder.defaultSwing(offset: o, width: width, wallLength: g.length)
        let estimated: Bool
        if let source = opening.swing?.source {
            estimated = source == .estimated || source == .inferred
        } else {
            estimated = true
        }
        let layer = estimated ? PlanLayers.doorSwingEstimated : PlanLayers.doors
        let base: SIMD2<Float> = swing.opensToNormalSide ? SIMD2<Float>(0, 0) : g.right * g.thickness
        let hinge = g.inner(swing.hingeAtStart ? o : o + width) + base
        let jamb = g.inner(swing.hingeAtStart ? o + width : o) + base
        let leafDirection = swing.opensToNormalSide ? g.left : g.right
        let leafEnd = hinge + leafDirection * width
        let leafAngle = Double(atan2(leafDirection.y, leafDirection.x))
        let toJamb = jamb - hinge
        let jambAngle = Double(atan2(toJamb.y, toJamb.x))
        let quarterFirst = Plan2D.sweep(start: leafAngle, end: jambAngle) <= Double.pi
        let start = quarterFirst ? leafAngle : jambAngle
        let end = quarterFirst ? jambAngle : leafAngle
        if estimated {
            sketch.dashedLine(layer, hinge, leafEnd)
            sketch.dashedArc(layer, center: hinge, radius: width, startAngle: start, endAngle: end)
        } else {
            sketch.line(layer, hinge, leafEnd)
            sketch.arc(layer, center: hinge, radius: width, startAngle: start, endAngle: end)
        }
        return layer
    }
}
