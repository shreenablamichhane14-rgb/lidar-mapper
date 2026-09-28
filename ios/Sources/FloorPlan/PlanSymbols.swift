import Foundation
import simd

/// Collects `Plan2D` entities per layer for the plan drawing (internal helper). Input points
/// are plan meters as `SIMD2<Float>`; dashed lines and arcs become short `.line` and `.arc`
/// pieces so every writer shows them dashed without a line style.
struct PlanSketch {
    /// Dash and gap lengths of dashed pieces, meters.
    static let dashLength: Double = 0.10, dashGap: Double = 0.06
    /// Cap on the pieces of one dashed line or arc.
    static let maxDashes = 2000

    /// Entities per layer name, in insertion order.
    private var byLayer: [String: [Plan2D.Entity]] = [:]

    /// An empty sketch.
    init() {}

    /// Float plan point to the Double point `Plan2D` uses.
    static func d(_ p: SIMD2<Float>) -> SIMD2<Double> {
        SIMD2<Double>(Double(p.x), Double(p.y))
    }

    /// Number of dash pieces for `periods` dash periods: rounded up, at least 1, at most
    /// `maxDashes` (clamped before converting, so a huge or non-finite value never traps).
    static func pieceCount(_ periods: Double) -> Int {
        guard periods.isFinite else { return 1 }
        return Int(Swift.min(Double(maxDashes), Swift.max(1, periods.rounded(.up))))
    }

    /// True when both components are finite.
    static func isFinite(_ p: SIMD2<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite
    }

    /// Adds an entity on a layer.
    mutating func add(_ layer: String, _ geometry: Plan2D.Geometry) {
        byLayer[layer, default: []].append(Plan2D.Entity(layer: layer, geometry: geometry))
    }

    /// All entities of the given layers, layer by layer in that order.
    func entities(in order: [String]) -> [Plan2D.Entity] {
        var result: [Plan2D.Entity] = []
        for layer in order {
            result.append(contentsOf: byLayer[layer] ?? [])
        }
        return result
    }

    /// Number of entities on a layer.
    func count(in layer: String) -> Int {
        byLayer[layer]?.count ?? 0
    }

    /// A straight segment (skipped when degenerate or not finite).
    mutating func line(_ layer: String, _ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        guard PlanSketch.isFinite(a), PlanSketch.isFinite(b), simd_distance(a, b) > 1e-5 else { return }
        add(layer, .line(from: PlanSketch.d(a), to: PlanSketch.d(b)))
    }

    /// A dashed segment made of short `.line` pieces.
    mutating func dashedLine(_ layer: String, _ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        guard PlanSketch.isFinite(a), PlanSketch.isFinite(b) else { return }
        let from = PlanSketch.d(a)
        let to = PlanSketch.d(b)
        let length = simd_distance(from, to)
        guard length > 1e-5 else { return }
        let direction = (to - from) / length
        let period = PlanSketch.dashLength + PlanSketch.dashGap
        let count = PlanSketch.pieceCount(length / period)
        for i in 0..<count {
            let s = Double(i) * period
            let e = min(s + PlanSketch.dashLength, length)
            guard e - s > 1e-6 else { continue }
            add(layer, .line(from: from + direction * s, to: from + direction * e))
        }
    }

    /// A dashed polyline: dash pieces follow the path across its corners with a continuous
    /// dash pattern (short `.line` pieces).
    mutating func dashedPolyline(_ layer: String, _ points: [SIMD2<Float>]) {
        guard points.count >= 2, points.allSatisfy({ PlanSketch.isFinite($0) }) else { return }
        let path = points.map { PlanSketch.d($0) }
        var cumulative: [Double] = [0]
        for i in 1..<path.count {
            cumulative.append(cumulative[i - 1] + simd_distance(path[i - 1], path[i]))
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 1e-5 else { return }
        let period = PlanSketch.dashLength + PlanSketch.dashGap
        let count = PlanSketch.pieceCount(total / period)
        var first = 0
        for k in 0..<count {
            let s0 = Double(k) * period
            let s1 = min(s0 + PlanSketch.dashLength, total)
            guard s1 - s0 > 1e-6 else { continue }
            while first < path.count - 2 && cumulative[first + 1] <= s0 { first += 1 }
            var j = first
            while j < path.count - 1 && cumulative[j] < s1 {
                let segmentStart = cumulative[j]
                let segmentEnd = cumulative[j + 1]
                let lower = max(s0, segmentStart)
                let upper = min(s1, segmentEnd)
                let span = segmentEnd - segmentStart
                if upper - lower > 1e-6 && span > 1e-9 {
                    let delta = path[j + 1] - path[j]
                    let p = path[j] + delta * ((lower - segmentStart) / span)
                    let q = path[j] + delta * ((upper - segmentStart) / span)
                    add(layer, .line(from: p, to: q))
                }
                j += 1
            }
        }
    }

    /// A counter-clockwise arc from `startAngle` to `endAngle` (radians from plan +x).
    mutating func arc(_ layer: String, center: SIMD2<Float>, radius: Float, startAngle: Double, endAngle: Double) {
        guard PlanSketch.isFinite(center), radius.isFinite, radius > 1e-5,
              startAngle.isFinite, endAngle.isFinite else { return }
        add(layer, .arc(center: PlanSketch.d(center), radius: Double(radius), startAngle: startAngle, endAngle: endAngle))
    }

    /// A dashed counter-clockwise arc made of short `.arc` pieces.
    mutating func dashedArc(_ layer: String, center: SIMD2<Float>, radius: Float, startAngle: Double, endAngle: Double) {
        guard PlanSketch.isFinite(center), radius.isFinite, radius > 1e-5,
              startAngle.isFinite, endAngle.isFinite else { return }
        let r = Double(radius)
        let arcLength = Plan2D.sweep(start: startAngle, end: endAngle) * r
        let period = PlanSketch.dashLength + PlanSketch.dashGap
        let count = PlanSketch.pieceCount(arcLength / period)
        for i in 0..<count {
            let s = Double(i) * period
            let e = min(s + PlanSketch.dashLength, arcLength)
            guard e - s > 1e-6 else { continue }
            add(layer, .arc(center: PlanSketch.d(center), radius: r, startAngle: startAngle + s / r, endAngle: startAngle + e / r))
        }
    }

    /// Connected segments (at least two finite points).
    mutating func polyline(_ layer: String, _ points: [SIMD2<Float>], closed: Bool) {
        guard points.count >= 2, points.allSatisfy({ PlanSketch.isFinite($0) }) else { return }
        add(layer, .polyline(points: points.map { PlanSketch.d($0) }, closed: closed))
    }

    /// A full circle.
    mutating func circle(_ layer: String, center: SIMD2<Float>, radius: Float) {
        guard PlanSketch.isFinite(center), radius.isFinite, radius > 1e-5 else { return }
        add(layer, .circle(center: PlanSketch.d(center), radius: Double(radius)))
    }

    /// Single-line text with its baseline starting at `at`.
    mutating func text(_ layer: String, _ string: String, at: SIMD2<Float>, height: Float, rotation: Double = 0) {
        guard !string.isEmpty, PlanSketch.isFinite(at), height.isFinite, height > 0 else { return }
        add(layer, .text(position: PlanSketch.d(at), height: Double(height), string: string, rotation: rotation))
    }

    /// Single-line text centered on `baselineCenter` (width estimated like `Plan2D.bounds`).
    mutating func centeredText(_ layer: String, _ string: String, baselineCenter: SIMD2<Float>, height: Float) {
        let width = Float(Plan2D.estimatedTextWidth(string, height: Double(height)))
        text(layer, string, at: baselineCenter - SIMD2<Float>(width / 2, 0), height: height)
    }
}

/// Furniture and fixture symbols (RESEARCH 3.6 recommended 6): the footprint rectangle plus
/// category details, oriented so the back of the object faces the nearest wall, and the
/// category name from `Copy.FloorPlan.categoryName` when it fits inside the footprint.
enum PlanSymbols {
    /// Stair tread depth, meters.
    static let treadDepth: Float = 0.28

    /// A fixture's local frame: `across` runs along its back, `forward` points from its back
    /// to its front; `point(x, y)` is in meters from the center (y = -halfDepth is the back).
    private struct SymbolFrame {
        var center: SIMD2<Float>
        var across: SIMD2<Float>
        var forward: SIMD2<Float>
        var halfWidth: Float
        var halfDepth: Float

        /// Plan point at local (x, y).
        func point(_ x: Float, _ y: Float) -> SIMD2<Float> {
            center + across * x + forward * y
        }

        /// Local axis-aligned rectangle as a closed ring.
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [SIMD2<Float>] {
            [point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1)]
        }

        /// Local ellipse as a closed ring of `segments` points.
        func ellipse(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, segments: Int = 20) -> [SIMD2<Float>] {
            (0..<segments).map { i in
                let angle = Float(i) / Float(segments) * 2 * Float.pi
                return point(cx + rx * cos(angle), cy + ry * sin(angle))
            }
        }
    }

    /// Footprint corners of a fixture, counter-clockwise, plan meters.
    static func footprint(_ fixture: PlanFixture) -> [SIMD2<Float>] {
        let c = fixture.center.simd
        let u = SIMD2<Float>(cos(fixture.yaw), sin(fixture.yaw))
        let v = SIMD2<Float>(-u.y, u.x)
        let hx = abs(fixture.size.x) / 2
        let hz = abs(fixture.size.y) / 2
        let ux: SIMD2<Float> = u * hx
        let vz: SIMD2<Float> = v * hz
        let low: SIMD2<Float> = c - vz
        let high: SIMD2<Float> = c + vz
        return [low - ux, low + ux, high + ux, high - ux]
    }

    /// Draws a fixture's symbol and label on `layer`.
    static func draw(_ fixture: PlanFixture, layer: String, walls: [PlanWall], into sketch: inout PlanSketch) {
        guard PlanSketch.isFinite(fixture.center.simd), PlanSketch.isFinite(fixture.size.simd),
              fixture.yaw.isFinite, fixture.size.x > 0.01, fixture.size.y > 0.01 else { return }
        let f = frame(for: fixture, walls: walls)
        let w = f.halfWidth
        let h = f.halfDepth
        sketch.polyline(layer, footprint(fixture), closed: true)
        var labeled = true
        switch fixture.category {
        case .bed:
            let pillowDepth = min(0.3, 0.2 * h * 2)
            if w > 0.6 {
                sketch.polyline(layer, f.rect(-w + 0.06, -h + 0.06, -0.04, -h + 0.06 + pillowDepth), closed: true)
                sketch.polyline(layer, f.rect(0.04, -h + 0.06, w - 0.06, -h + 0.06 + pillowDepth), closed: true)
            } else {
                sketch.polyline(layer, f.rect(-w + 0.06, -h + 0.06, w - 0.06, -h + 0.06 + pillowDepth), closed: true)
            }
            sketch.line(layer, f.point(-w, -h + 0.12 + pillowDepth), f.point(w, -h + 0.12 + pillowDepth))
        case .sofa, .chair:
            let back = min(0.2, 0.3 * h * 2)
            sketch.line(layer, f.point(-w, -h + back), f.point(w, -h + back))
            if fixture.category == .sofa {
                let arm = min(0.15, 0.2 * w)
                sketch.line(layer, f.point(-w + arm, -h + back), f.point(-w + arm, h))
                sketch.line(layer, f.point(w - arm, -h + back), f.point(w - arm, h))
            }
            labeled = fixture.category == .sofa
        case .toilet:
            let tank = 0.3 * h * 2
            sketch.polyline(layer, f.rect(-w * 0.85, -h, w * 0.85, -h + tank), closed: true)
            let bowlDepth = (h * 2 - tank) / 2
            sketch.polyline(layer, f.ellipse(0, -h + tank + bowlDepth, w * 0.75, bowlDepth * 0.92), closed: true)
            labeled = false
        case .sink:
            let inset = min(w, h) * 0.25
            sketch.polyline(layer, f.ellipse(0, inset * 0.3, w - inset, h - inset), closed: true)
            sketch.circle(layer, center: f.point(0, inset * 0.3), radius: min(0.025, min(w, h) * 0.2))
            sketch.line(layer, f.point(0, -h), f.point(0, -h + inset))
            labeled = false
        case .bathtub:
            let inset = min(w, h) * 0.18
            let chamfer = min(w, h) * 0.3
            let inner = [f.point(-w + inset + chamfer, -h + inset), f.point(w - inset - chamfer, -h + inset),
                         f.point(w - inset, -h + inset + chamfer), f.point(w - inset, h - inset - chamfer),
                         f.point(w - inset - chamfer, h - inset), f.point(-w + inset + chamfer, h - inset),
                         f.point(-w + inset, h - inset - chamfer), f.point(-w + inset, -h + inset + chamfer)]
            sketch.polyline(layer, inner, closed: true)
            sketch.circle(layer, center: f.point(w - inset - chamfer * 0.6, 0), radius: min(0.03, inset))
        case .stove:
            let r = min(w, h) * 0.28
            for x in [-w / 2, w / 2] {
                for y in [-h / 2, h / 2] {
                    sketch.circle(layer, center: f.point(x, y), radius: r)
                }
            }
            labeled = false
        case .oven, .refrigerator:
            let door = h * 2 * 0.12
            sketch.line(layer, f.point(-w, h - door), f.point(w, h - door))
        case .dishwasher, .other, .appliance:
            sketch.line(layer, f.point(-w, -h), f.point(w, h))
            sketch.line(layer, f.point(-w, h), f.point(w, -h))
        case .washerDryer:
            sketch.circle(layer, center: f.center, radius: min(w, h) * 0.7)
        case .fireplace:
            let mouth = [f.point(-w * 0.6, -h), f.point(w * 0.6, -h), f.point(w * 0.4, -h + h * 1.2), f.point(-w * 0.4, -h + h * 1.2)]
            sketch.polyline(layer, mouth, closed: true)
        case .stairs:
            drawStairs(f, layer: layer, into: &sketch)
            labeled = false
        case .television:
            sketch.line(layer, f.point(-w, h - min(0.03, h)), f.point(w, h - min(0.03, h)))
        case .storage, .cabinet:
            sketch.line(layer, f.point(-w, -h), f.point(w, h))
        case .shelf:
            sketch.line(layer, f.point(-w / 3, -h), f.point(-w / 3, h))
            sketch.line(layer, f.point(w / 3, -h), f.point(w / 3, h))
        case .table, .desk:
            break
        case .lamp:
            let r = min(w, h) * 0.8
            sketch.circle(layer, center: f.center, radius: r)
            sketch.line(layer, f.point(-r, 0), f.point(r, 0))
            sketch.line(layer, f.point(0, -r), f.point(0, r))
            labeled = false
        case .plant:
            sketch.circle(layer, center: f.center, radius: min(w, h) * 0.85)
            sketch.circle(layer, center: f.center, radius: min(w, h) * 0.35)
            labeled = false
        case .vehicle:
            sketch.line(layer, f.point(-w * 0.8, h * 0.4), f.point(w * 0.8, h * 0.4))
            sketch.line(layer, f.point(-w * 0.8, -h * 0.5), f.point(w * 0.8, -h * 0.5))
        }
        if labeled {
            drawLabel(Copy.FloorPlan.categoryName(fixture.category), fixture: fixture, layer: layer, into: &sketch)
        }
    }

    /// Treads every `treadDepth` across the run, a direction arrow and the UP label.
    private static func drawStairs(_ f: SymbolFrame, layer: String, into sketch: inout PlanSketch) {
        let w = f.halfWidth
        let h = f.halfDepth
        let rawTreads = (h * 2 / treadDepth).rounded(.down)
        let treads = rawTreads.isFinite ? Int(min(60, max(0, rawTreads))) : 0
        if treads >= 1 {
            for i in 1...treads {
                let y = -h + Float(i) * treadDepth
                guard y < h - 0.01 else { break }
                sketch.line(layer, f.point(-w, y), f.point(w, y))
            }
        }
        let tail = f.point(0, -h + min(0.15, h * 0.3))
        let tip = f.point(0, h - min(0.1, h * 0.2))
        sketch.line(layer, tail, tip)
        let head = min(0.15, w * 0.5)
        let back: SIMD2<Float> = tip - f.forward * head
        let side: SIMD2<Float> = f.across * (head * 0.6)
        sketch.line(layer, tip, back + side)
        sketch.line(layer, tip, back - side)
        let labelHeight = max(0.08, min(0.14, w * 0.4))
        let labelAt: SIMD2<Float> = tail + f.across * (head + labelHeight * 1.4)
        sketch.centeredText(layer, Copy.FloorPlan.stairsUp, baselineCenter: labelAt, height: labelHeight)
    }

    /// The category name centered in the footprint when it fits across it.
    private static func drawLabel(_ name: String, fixture: PlanFixture, layer: String, into sketch: inout PlanSketch) {
        let corners = footprint(fixture)
        guard let box = Polygon2D(points: corners).boundingBox else { return }
        let width = box.max.x - box.min.x
        let depth = box.max.y - box.min.y
        let height = max(0.07, min(0.12, min(width, depth) * 0.25))
        let textWidth = Float(Plan2D.estimatedTextWidth(name, height: Double(height)))
        guard textWidth <= width * 0.9, height * 1.5 <= depth else { return }
        let center = fixture.center.simd
        sketch.centeredText(layer, name, baselineCenter: center - SIMD2<Float>(0, height / 2), height: height)
    }

    /// The fixture frame with its back toward the nearest wall. Beds consider only their
    /// short sides (headboard); stairs run along their longer side.
    private static func frame(for fixture: PlanFixture, walls: [PlanWall]) -> SymbolFrame {
        let c = fixture.center.simd
        let u = SIMD2<Float>(cos(fixture.yaw), sin(fixture.yaw))
        let v = SIMD2<Float>(-u.y, u.x)
        let hx = abs(fixture.size.x) / 2
        let hz = abs(fixture.size.y) / 2
        // Candidate backs: the side at -forward, with the matching across axis and half sizes.
        var options: [SymbolFrame] = [
            SymbolFrame(center: c, across: u, forward: v, halfWidth: hx, halfDepth: hz),
            SymbolFrame(center: c, across: -u, forward: -v, halfWidth: hx, halfDepth: hz),
            SymbolFrame(center: c, across: -v, forward: u, halfWidth: hz, halfDepth: hx),
            SymbolFrame(center: c, across: v, forward: -u, halfWidth: hz, halfDepth: hx)
        ]
        if fixture.category == .bed || fixture.category == .stairs {
            options = options.filter { $0.halfWidth <= $0.halfDepth }
            if options.isEmpty { options = [SymbolFrame(center: c, across: u, forward: v, halfWidth: hx, halfDepth: hz)] }
        }
        guard !walls.isEmpty else { return options[0] }
        var best = options[0]
        var bestDistance = Float.infinity
        for option in options {
            let backMid = option.center - option.forward * option.halfDepth
            var nearest = Float.infinity
            for wall in walls {
                nearest = min(nearest, Segment2D(a: wall.a.simd, b: wall.b.simd).distance(to: backMid))
            }
            if nearest < bestDistance - 1e-4 {
                bestDistance = nearest
                best = option
            }
        }
        return best
    }
}
