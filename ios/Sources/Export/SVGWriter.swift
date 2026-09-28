import Foundation
import simd

/// SVG for a `Plan2D`.
///
/// The plan is scaled by `pixelsPerMeter`, Y is flipped so plan-up is screen-up, and a
/// `margin` in pixels surrounds the content; the viewBox starts at 0,0 and fits
/// everything (text included, estimated). One `<g>` per layer carries the layer's
/// stroke color. Text uses the entity height as font size and is rotated with a
/// transform. Dimensions are extension lines, a dimension line, 45 degree ticks and a
/// centered label. All text and attribute values are XML escaped.
enum SVGWriter {
    /// Drawing parameters.
    struct Options {
        /// Scale from plan meters to SVG user units (pixels).
        var pixelsPerMeter: Double
        /// Empty border around the content, in pixels.
        var margin: Double
        /// Stroke width in pixels.
        var strokeWidth: Double
        /// CSS font family for text.
        var fontFamily: String

        /// 100 px per meter, 20 px margin, 1.5 px strokes, sans-serif.
        init(pixelsPerMeter: Double = 100, margin: Double = 20, strokeWidth: Double = 1.5, fontFamily: String = "Helvetica, Arial, sans-serif") {
            self.pixelsPerMeter = pixelsPerMeter
            self.margin = margin
            self.strokeWidth = strokeWidth
            self.fontFamily = fontFamily
        }
    }

    /// The SVG document as text.
    static func text(for plan: Plan2D, options: Options = Options()) throws -> String {
        guard !plan.entities.isEmpty, let bounds = plan.bounds() else { throw ExportError.emptyPlan }
        let scale = options.pixelsPerMeter > 0 && options.pixelsPerMeter.isFinite ? options.pixelsPerMeter : 100
        let margin = max(0, options.margin.isFinite ? options.margin : 0)
        let width = (bounds.max.x - bounds.min.x) * scale + 2 * margin
        let height = (bounds.max.y - bounds.min.y) * scale + 2 * margin

        func toScreen(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2<Double>((p.x - bounds.min.x) * scale + margin, (bounds.max.y - p.y) * scale + margin)
        }
        func n(_ value: Double) -> String { ExportText.number(value, places: 3) }
        func lineElement(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> String {
            let p = toScreen(a)
            let q = toScreen(b)
            return "<line x1=\"\(n(p.x))\" y1=\"\(n(p.y))\" x2=\"\(n(q.x))\" y2=\"\(n(q.y))\"/>"
        }
        func textElement(_ string: String, at anchor: SIMD2<Double>, height: Double, rotation: Double, centered: Bool, color: String) -> String {
            let p = toScreen(anchor)
            var out = "<text x=\"\(n(p.x))\" y=\"\(n(p.y))\" font-size=\"\(n(max(height, 0) * scale))\" fill=\"\(color)\" stroke=\"none\""
            if centered { out += " text-anchor=\"middle\"" }
            // Plan angles are counter-clockwise with Y up; SVG rotates clockwise with Y down.
            let degrees = -rotation * 180 / Double.pi
            if abs(degrees) > 1e-9 { out += " transform=\"rotate(\(n(degrees)) \(n(p.x)) \(n(p.y)))\"" }
            return out + ">\(escape(string))</text>"
        }

        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(n(width))\" height=\"\(n(height))\" viewBox=\"0 0 \(n(width)) \(n(height))\">\n"
        out += "<title>\(escape(plan.name))</title>\n"
        out += "<g font-family=\"\(escape(options.fontFamily))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        for layer in plan.resolvedLayers() {
            let entities = plan.entities.filter { $0.layer == layer.name }
            guard !entities.isEmpty else { continue }
            let color = hex(layer.color)
            out += "<g data-layer=\"\(escape(layer.name))\" stroke=\"\(color)\" stroke-width=\"\(n(options.strokeWidth))\" fill=\"none\">\n"
            for entity in entities {
                switch entity.geometry {
                case let .line(from, to):
                    out += lineElement(from, to) + "\n"
                case let .polyline(points, closed):
                    guard points.count >= 2 else { continue }
                    let list = points.map { (q: SIMD2<Double>) -> String in let p = toScreen(q); return "\(n(p.x)),\(n(p.y))" }.joined(separator: " ")
                    out += "<\(closed ? "polygon" : "polyline") points=\"\(list)\"/>\n"
                case let .circle(center, radius):
                    let c = toScreen(center)
                    out += "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(abs(radius) * scale))\"/>\n"
                case let .arc(center, radius, startAngle, endAngle):
                    let r = abs(radius)
                    let sweep = Plan2D.sweep(start: startAngle, end: endAngle)
                    if sweep >= 2 * Double.pi - 1e-9 {
                        let c = toScreen(center)
                        out += "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(r * scale))\"/>\n"
                        continue
                    }
                    let a = toScreen(center + r * SIMD2<Double>(cos(startAngle), sin(startAngle)))
                    let b = toScreen(center + r * SIMD2<Double>(cos(startAngle + sweep), sin(startAngle + sweep)))
                    // Counter-clockwise in plan space is clockwise on screen: sweep-flag 0.
                    let large = sweep > Double.pi ? 1 : 0
                    out += "<path d=\"M \(n(a.x)) \(n(a.y)) A \(n(r * scale)) \(n(r * scale)) 0 \(large) 0 \(n(b.x)) \(n(b.y))\"/>\n"
                case let .text(position, height, string, rotation):
                    out += textElement(string, at: position, height: height, rotation: rotation, centered: false, color: color) + "\n"
                case let .dimension(from, to, offset, label):
                    guard let layout = plan.dimensionLayout(from: from, to: to, offset: offset) else { continue }
                    out += "<g class=\"dimension\">\n"
                    for s in [layout.extension1, layout.extension2, layout.dimensionLine] + layout.ticks {
                        out += lineElement(s.a, s.b) + "\n"
                    }
                    out += textElement(label, at: layout.textAnchor, height: layout.textHeight, rotation: layout.textAngle, centered: true, color: color) + "\n"
                    out += "</g>\n"
                }
            }
            out += "</g>\n"
        }
        out += "</g>\n</svg>\n"
        return out
    }

    /// The SVG document as UTF-8 bytes.
    static func data(for plan: Plan2D, options: Options = Options()) throws -> Data {
        Data(try text(for: plan, options: options).utf8)
    }

    /// "#rrggbb" for an RGB color in 0...1.
    static func hex(_ color: SIMD3<Float>) -> String {
        func byte(_ v: Float) -> Int { Int((min(max(v.isFinite ? v : 0, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.x), byte(color.y), byte(color.z))
    }

    /// Escapes &, <, >, " and ' and drops characters XML 1.0 does not allow.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let v = scalar.value
                let allowed = v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000
                if allowed { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
