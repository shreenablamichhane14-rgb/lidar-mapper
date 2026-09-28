import Foundation
import simd

/// A 2D floor plan for the DXF, SVG and PDF writers. Coordinates are meters with +Y
/// pointing plan-up; angles are radians counter-clockwise from +X. Labels arrive
/// already formatted (the Units module formats them), writers never format lengths.
struct Plan2D {
    /// A drawing layer. Entities refer to layers by name.
    struct Layer {
        /// Layer name, unique within the plan.
        var name: String
        /// RGB stroke and text color in 0...1.
        var color: SIMD3<Float>

        /// Creates a layer.
        init(name: String, color: SIMD3<Float>) {
            self.name = name
            self.color = color
        }
    }

    /// The drawable content of an entity.
    enum Geometry {
        /// Straight segment.
        case line(from: SIMD2<Double>, to: SIMD2<Double>)
        /// Connected segments; `closed` joins the last point back to the first.
        case polyline(points: [SIMD2<Double>], closed: Bool)
        /// Arc drawn counter-clockwise from `startAngle` to `endAngle`.
        case arc(center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double)
        /// Full circle.
        case circle(center: SIMD2<Double>, radius: Double)
        /// Single-line text; `position` is the left end of the baseline, `height` the
        /// capital height in meters, `rotation` the baseline angle.
        case text(position: SIMD2<Double>, height: Double, string: String, rotation: Double)
        /// Linear dimension between two points. `offset` moves the dimension line
        /// perpendicular to from->to, positive to the left. `label` is the final text.
        case dimension(from: SIMD2<Double>, to: SIMD2<Double>, offset: Double, label: String)
    }

    /// One drawable item on a layer.
    struct Entity {
        /// Name of the layer the entity belongs to.
        var layer: String
        /// What to draw.
        var geometry: Geometry

        /// Creates an entity.
        init(layer: String, geometry: Geometry) {
            self.layer = layer
            self.geometry = geometry
        }
    }

    /// A segment used by the dimension layout.
    struct Segment {
        /// Start point.
        var a: SIMD2<Double>
        /// End point.
        var b: SIMD2<Double>
    }

    /// Dimension drawn as plain lines plus centered text (shared by all 2D writers so
    /// DXF, SVG and PDF look the same).
    struct DimensionLayout {
        /// Extension line at the `from` point.
        var extension1: Segment
        /// Extension line at the `to` point.
        var extension2: Segment
        /// The dimension line itself.
        var dimensionLine: Segment
        /// 45 degree architectural tick marks at both ends.
        var ticks: [Segment]
        /// Center of the text baseline.
        var textAnchor: SIMD2<Double>
        /// Text baseline angle, kept readable (between -90 and +90 degrees).
        var textAngle: Double
        /// Text capital height in meters.
        var textHeight: Double
    }

    /// Plan title, used in the PDF title block and file metadata.
    var name: String
    /// Declared layers in drawing order.
    var layers: [Layer]
    /// Entities in drawing order.
    var entities: [Entity]
    /// Text height in meters used for dimension labels.
    var dimensionTextHeight: Double

    /// Creates a plan.
    init(name: String, layers: [Layer], entities: [Entity], dimensionTextHeight: Double = 0.12) {
        self.name = name
        self.layers = layers
        self.entities = entities
        self.dimensionTextHeight = dimensionTextHeight
    }

    /// Declared layers plus any layer that entities reference but that was not
    /// declared (black), without duplicates, in first-use order.
    func resolvedLayers() -> [Layer] {
        var result: [Layer] = []
        var seen = Set<String>()
        for layer in layers where !seen.contains(layer.name) {
            seen.insert(layer.name)
            result.append(layer)
        }
        for entity in entities where !seen.contains(entity.layer) {
            seen.insert(entity.layer)
            result.append(Layer(name: entity.layer, color: SIMD3<Float>(0, 0, 0)))
        }
        return result
    }

    /// Counter-clockwise sweep from `start` to `end`, in (0, 2 pi]. Equal angles mean a
    /// full turn.
    static func sweep(start: Double, end: Double) -> Double {
        let twoPi = 2 * Double.pi
        var s = (end - start).truncatingRemainder(dividingBy: twoPi)
        if s <= 1e-12 { s += twoPi }
        return s
    }

    /// Rough text width for layout and bounds (0.6 of the height per character).
    static func estimatedTextWidth(_ string: String, height: Double) -> Double {
        Double(string.count) * height * 0.6
    }

    /// Layout of a dimension, or nil when both points coincide.
    func dimensionLayout(from: SIMD2<Double>, to: SIMD2<Double>, offset: Double) -> DimensionLayout? {
        let delta = to - from
        let length = simd_length(delta)
        guard length > 1e-9, length.isFinite, offset.isFinite else { return nil }
        let h = dimensionTextHeight
        let u = delta / length
        let left = SIMD2<Double>(-u.y, u.x)
        let n = offset >= 0 ? left : -left
        let distance = abs(offset)
        let gap = h * 0.25
        let overshoot = h * 0.5
        let p1 = from + left * offset
        let p2 = to + left * offset
        let start = min(gap, distance)
        let ext1 = Segment(a: from + n * start, b: p1 + n * overshoot)
        let ext2 = Segment(a: to + n * start, b: p2 + n * overshoot)
        let slash = simd_normalize(u + left) * (h * 0.35)
        let ticks = [Segment(a: p1 - slash, b: p1 + slash), Segment(a: p2 - slash, b: p2 + slash)]
        var angle = atan2(u.y, u.x)
        if angle > Double.pi / 2 + 1e-9 {
            angle -= Double.pi
        } else if angle <= -Double.pi / 2 + 1e-9 {
            angle += Double.pi
        }
        let up = SIMD2<Double>(-sin(angle), cos(angle))
        let mid = (p1 + p2) / 2
        let anchor = simd_dot(n, up) >= 0 ? mid + n * gap : mid + n * (gap + h)
        return DimensionLayout(extension1: ext1, extension2: ext2, dimensionLine: Segment(a: p1, b: p2),
                               ticks: ticks, textAnchor: anchor, textAngle: angle, textHeight: h)
    }

    /// Axis-aligned bounds of everything drawn (text estimated), or nil for an empty plan.
    func bounds() -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        var lo = SIMD2<Double>(repeating: .infinity)
        var hi = SIMD2<Double>(repeating: -.infinity)
        func add(_ p: SIMD2<Double>) {
            guard p.x.isFinite && p.y.isFinite else { return }
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        func addText(_ anchor: SIMD2<Double>, width: Double, height: Double, angle: Double, centered: Bool) {
            let dir = SIMD2<Double>(cos(angle), sin(angle))
            let up = SIMD2<Double>(-dir.y, dir.x)
            let left = centered ? anchor - dir * (width / 2) : anchor
            let right = left + dir * width
            for p in [left, right, left + up * height, right + up * height, left - up * (height * 0.3), right - up * (height * 0.3)] {
                add(p)
            }
        }
        for entity in entities {
            switch entity.geometry {
            case let .line(from, to):
                add(from)
                add(to)
            case let .polyline(points, _):
                points.forEach(add)
            case let .circle(center, radius):
                add(center - SIMD2<Double>(repeating: abs(radius)))
                add(center + SIMD2<Double>(repeating: abs(radius)))
            case let .arc(center, radius, startAngle, endAngle):
                let r = abs(radius)
                let sweep = Plan2D.sweep(start: startAngle, end: endAngle)
                add(center + r * SIMD2<Double>(cos(startAngle), sin(startAngle)))
                add(center + r * SIMD2<Double>(cos(endAngle), sin(endAngle)))
                for quarter in 0..<4 {
                    let axis = Double(quarter) * Double.pi / 2
                    let delta = (axis - startAngle).truncatingRemainder(dividingBy: 2 * Double.pi)
                    let normalized = delta < 0 ? delta + 2 * Double.pi : delta
                    if normalized <= sweep { add(center + r * SIMD2<Double>(cos(axis), sin(axis))) }
                }
            case let .text(position, height, string, rotation):
                addText(position, width: Plan2D.estimatedTextWidth(string, height: height), height: height, angle: rotation, centered: false)
            case let .dimension(from, to, offset, label):
                add(from)
                add(to)
                if let layout = dimensionLayout(from: from, to: to, offset: offset) {
                    for s in [layout.extension1, layout.extension2, layout.dimensionLine] + layout.ticks {
                        add(s.a)
                        add(s.b)
                    }
                    addText(layout.textAnchor, width: Plan2D.estimatedTextWidth(label, height: layout.textHeight),
                            height: layout.textHeight, angle: layout.textAngle, centered: true)
                }
            }
        }
        guard lo.x.isFinite, hi.x.isFinite else { return nil }
        return (lo, hi)
    }
}
