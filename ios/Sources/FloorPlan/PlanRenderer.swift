import Foundation
import simd
import CoreGraphics
import UIKit

/// Screen and image mapping: plan meters (+Y up) to points (+Y down). This is the only place
/// where the y axis flips (RESEARCH 3.6 gotcha: mixing y-up and y-down mirrors the plan).
struct PlanViewport: Equatable, Sendable {
    /// Scale and the screen point of plan (0, 0).
    var pointsPerMeter: CGFloat; var origin: CGPoint      // screen point of plan (0, 0)

    /// Creates a viewport.
    init(pointsPerMeter: CGFloat, origin: CGPoint) {
        self.pointsPerMeter = pointsPerMeter
        self.origin = origin
    }

    /// Screen point of a plan point.
    func toScreen(_ p: SIMD2<Double>) -> CGPoint {
        let px: CGFloat = CGFloat(p.x)
        let py: CGFloat = CGFloat(p.y)
        let x: CGFloat = origin.x + px * pointsPerMeter
        let y: CGFloat = origin.y - py * pointsPerMeter
        return CGPoint(x: x, y: y)
    }

    /// Plan point of a screen point (inverse of `toScreen`).
    func toPlan(_ p: CGPoint) -> SIMD2<Double> {
        let k: CGFloat = pointsPerMeter != 0 && pointsPerMeter.isFinite ? pointsPerMeter : 1
        let x: CGFloat = (p.x - origin.x) / k
        let y: CGFloat = (origin.y - p.y) / k
        return SIMD2<Double>(Double(x), Double(y))
    }

    /// The same viewport scaled by `factor` about the screen point `anchor` (it stays fixed).
    func zoomed(by factor: CGFloat, about anchor: CGPoint) -> PlanViewport {
        guard factor.isFinite, factor > 0 else { return self }
        let x = anchor.x + (origin.x - anchor.x) * factor
        let y = anchor.y + (origin.y - anchor.y) * factor
        return PlanViewport(pointsPerMeter: pointsPerMeter * factor, origin: CGPoint(x: x, y: y))
    }

    /// The same viewport moved by a screen translation.
    func panned(by translation: CGSize) -> PlanViewport {
        PlanViewport(pointsPerMeter: pointsPerMeter, origin: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
    }

    /// Internal parameter names `lower` and `upper` keep `Swift.min` and `Swift.max` usable in the body.
    /// Fits the plan box into `size` minus `margin` on every side, centered; boxes smaller than
    /// 0.5 m are treated as 0.5 m so a single point does not zoom without limit.
    static func fitting(min lower: SIMD2<Double>, max upper: SIMD2<Double>, in size: CGSize, margin: CGFloat) -> PlanViewport {
        let finite = lower.x.isFinite && lower.y.isFinite && upper.x.isFinite && upper.y.isFinite
        let low = finite ? lower : SIMD2<Double>(0, 0)
        let high = finite ? upper : SIMD2<Double>(0, 0)
        let extentX = Swift.max(high.x - low.x, 0.5)
        let extentY = Swift.max(high.y - low.y, 0.5)
        let availableWidth = Swift.max(Double(size.width - 2 * margin), 1)
        let availableHeight = Swift.max(Double(size.height - 2 * margin), 1)
        var k = Swift.min(availableWidth / extentX, availableHeight / extentY)
        if !k.isFinite || k <= 0 { k = 1 }
        let centerX = (low.x + high.x) / 2
        let centerY = (low.y + high.y) / 2
        let originX = Double(size.width) / 2 - centerX * k
        let originY = Double(size.height) / 2 + centerY * k
        return PlanViewport(pointsPerMeter: CGFloat(k), origin: CGPoint(x: originX, y: originY))
    }
}

/// Draws a `Plan2D` with Core Graphics: the screen canvas, PNG export and the thumbnail all
/// use `draw`, on the same `Plan2D` the PDF, SVG and DXF writers get.
enum PlanRenderer {
    /// Largest image side in pixels.
    static let maxPixels = 8192
    /// Text never grows past this many line widths, points.
    static let maxFontPerLineWidth: CGFloat = 16

    /// Draws every entity; text drawn in screen space so it does not scale with zoom beyond clamping.
    /// Font size is the entity height times `pointsPerMeter`, capped at 16 x `lineWidth`, and
    /// text under 2 points is skipped. Arcs are sampled through the viewport, so the viewport
    /// remains the only y flip. `dark` lightens the layer colors for a dark background; the
    /// caller paints the background.
    static func draw(_ plan: Plan2D, in ctx: CGContext, viewport: PlanViewport, lineWidth: CGFloat, dark: Bool) {
        guard viewport.pointsPerMeter.isFinite, viewport.pointsPerMeter > 0 else { return }
        var colors: [String: UIColor] = [:]
        for layer in plan.resolvedLayers() {
            colors[layer.name] = displayColor(layer, dark: dark)
        }
        let width = lineWidth.isFinite && lineWidth > 0 ? lineWidth : 1
        let maxFont = maxFontPerLineWidth * width
        let k = viewport.pointsPerMeter
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for entity in plan.entities {
            let color = colors[entity.layer] ?? (dark ? UIColor.white : UIColor.black)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width * weight(of: entity.layer))
            switch entity.geometry {
            case let .line(from, to):
                ctx.beginPath()
                ctx.move(to: viewport.toScreen(from))
                ctx.addLine(to: viewport.toScreen(to))
                ctx.strokePath()
            case let .polyline(points, closed):
                guard let first = points.first, points.count >= 2 else { continue }
                ctx.beginPath()
                ctx.move(to: viewport.toScreen(first))
                for p in points.dropFirst() { ctx.addLine(to: viewport.toScreen(p)) }
                if closed { ctx.closePath() }
                ctx.strokePath()
            case let .arc(center, radius, startAngle, endAngle):
                strokeArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle,
                          viewport: viewport, in: ctx)
            case let .circle(center, radius):
                let c = viewport.toScreen(center)
                let r: CGFloat = CGFloat(abs(radius)) * k
                guard r.isFinite, r > 0 else { continue }
                let box = CGRect(origin: CGPoint(x: c.x - r, y: c.y - r), size: CGSize(width: r * 2, height: r * 2))
                ctx.strokeEllipse(in: box)
            case let .text(position, height, string, rotation):
                drawText(string, at: viewport.toScreen(position), size: CGFloat(height) * k, maxSize: maxFont,
                         angle: rotation, centered: false, color: color, in: ctx)
            case let .dimension(from, to, offset, label):
                guard let layout = plan.dimensionLayout(from: from, to: to, offset: offset) else { continue }
                ctx.beginPath()
                for s in [layout.extension1, layout.extension2, layout.dimensionLine] + layout.ticks {
                    ctx.move(to: viewport.toScreen(s.a))
                    ctx.addLine(to: viewport.toScreen(s.b))
                }
                ctx.strokePath()
                drawText(label, at: viewport.toScreen(layout.textAnchor), size: CGFloat(layout.textHeight) * k,
                         maxSize: maxFont, angle: layout.textAngle, centered: true, color: color, in: ctx)
            }
        }
        ctx.restoreGState()
    }

    /// Outlines a selected element in the accent color (segment thick, polygon outlined).
    static func drawHighlight(_ hit: PlanHit, in ctx: CGContext, viewport: PlanViewport, lineWidth: CGFloat) {
        /// Screen point of a Float plan point.
        func screen(_ p: SIMD2<Float>) -> CGPoint { viewport.toScreen(SIMD2<Double>(Double(p.x), Double(p.y))) }
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(3 * lineWidth)
        if let segment = hit.segment {
            ctx.beginPath()
            ctx.move(to: screen(segment.0))
            ctx.addLine(to: screen(segment.1))
            ctx.strokePath()
        }
        if hit.polygon.count >= 2, let first = hit.polygon.first {
            ctx.setLineWidth(2 * lineWidth)
            ctx.beginPath()
            ctx.move(to: screen(first))
            for p in hit.polygon.dropFirst() { ctx.addLine(to: screen(p)) }
            ctx.closePath()
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// PNG of the whole plan, `pixelWidth` wide (at most 8192), white background, 4 percent
    /// margin; the height follows the plan's aspect. Nil for an empty plan. Safe off main.
    static func pngData(_ plan: Plan2D, pixelWidth: Int) -> Data? {
        guard plan.entities.isEmpty == false, let bounds = plan.bounds(), pixelWidth >= 16 else { return nil }
        let width = CGFloat(Swift.min(pixelWidth, maxPixels))
        let margin: CGFloat = (width * 0.04).rounded()
        let extentX: Double = Swift.max(bounds.max.x - bounds.min.x, 0.5)
        let extentY: Double = Swift.max(bounds.max.y - bounds.min.y, 0.5)
        let innerWidth = Double(width - 2 * margin)
        let margins = Double(2 * margin)
        let rawHeight: Double = innerWidth * extentY / extentX + margins
        let roundedHeight: Double = rawHeight.isFinite ? rawHeight.rounded(.up) : 16
        let clampedHeight: Double = Swift.min(Double(maxPixels), Swift.max(16, roundedHeight))
        let height = CGFloat(clampedHeight)
        let size = CGSize(width: width, height: height)
        let viewport = PlanViewport.fitting(min: bounds.min, max: bounds.max, in: size, margin: margin)
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat())
        let lineWidth = Swift.max(1, width / 1000)
        return renderer.pngData { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            PlanRenderer.draw(plan, in: context.cgContext, viewport: viewport, lineWidth: lineWidth, dark: false)
        }
    }

    /// Square JPEG thumbnail (quality 0.8) of the plan, `pixelSize` on a side (at most 8192),
    /// white background. Nil for an empty plan. Safe off main.
    static func jpegThumbnail(_ plan: Plan2D, pixelSize: Int) -> Data? {
        guard plan.entities.isEmpty == false, let bounds = plan.bounds(), pixelSize >= 16 else { return nil }
        let side = CGFloat(Swift.min(pixelSize, maxPixels))
        let size = CGSize(width: side, height: side)
        let viewport = PlanViewport.fitting(min: bounds.min, max: bounds.max, in: size, margin: (side * 0.05).rounded())
        let renderer = UIGraphicsImageRenderer(size: size, format: imageFormat())
        let lineWidth = Swift.max(0.75, side / 400)
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            PlanRenderer.draw(plan, in: context.cgContext, viewport: viewport, lineWidth: lineWidth, dark: false)
        }
    }

    /// Opaque renderer format at scale 1, so points equal pixels.
    private static func imageFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }

    /// Relative stroke weight of a layer (walls heaviest, grid lightest).
    static func weight(of layer: String) -> CGFloat {
        switch layer {
        case PlanLayers.walls: return 1.8
        case PlanLayers.wallsEstimated, PlanLayers.occluded: return 1.1
        case PlanLayers.doors, PlanLayers.doorSwingEstimated, PlanLayers.windows: return 0.9
        case PlanLayers.furniture, PlanLayers.fixtures, PlanLayers.notes, PlanLayers.scaleBar: return 0.8
        case PlanLayers.dimensions, PlanLayers.roomBoundaries: return 0.6
        case PlanLayers.grid: return 0.4
        default: return 1
        }
    }

    /// Layer color for the screen: as declared on light backgrounds, lightened on dark ones
    /// (the grid stays dim).
    static func displayColor(_ layer: Plan2D.Layer, dark: Bool) -> UIColor {
        var c = layer.color
        if dark {
            if layer.name == PlanLayers.grid {
                c = SIMD3<Float>(repeating: 0.28)
            } else {
                c = c + (SIMD3<Float>(repeating: 1) - c) * 0.72
            }
        }
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    /// A counter-clockwise plan arc sampled into screen segments through the viewport.
    private static func strokeArc(center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double,
                                  viewport: PlanViewport, in ctx: CGContext) {
        let r = abs(radius)
        guard r.isFinite, r > 0, startAngle.isFinite, endAngle.isFinite else { return }
        let sweep = Plan2D.sweep(start: startAngle, end: endAngle)
        let screenLength = sweep * r * Double(viewport.pointsPerMeter) / 3
        let clamped = screenLength.isFinite ? Swift.min(256, Swift.max(4, screenLength.rounded(.up))) : 4
        let segments = Int(clamped)
        ctx.beginPath()
        for i in 0...segments {
            let angle = startAngle + sweep * Double(i) / Double(segments)
            let p = viewport.toScreen(center + SIMD2<Double>(cos(angle), sin(angle)) * r)
            if i == 0 {
                ctx.move(to: p)
            } else {
                ctx.addLine(to: p)
            }
        }
        ctx.strokePath()
    }

    /// Single-line text with its baseline starting at (or centered on) `point`, rotated
    /// counter-clockwise by `angle` as seen on screen, drawn through UIKit into `ctx`.
    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat, maxSize: CGFloat, angle: Double,
                                 centered: Bool, color: UIColor, in ctx: CGContext) {
        let fontSize = Swift.min(size, maxSize)
        guard fontSize.isFinite, fontSize >= 2, point.x.isFinite, point.y.isFinite, angle.isFinite else { return }
        let font = UIFont.systemFont(ofSize: fontSize)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let width = text.size().width
        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: CGFloat(-angle))
        text.draw(at: CGPoint(x: centered ? -width / 2 : 0, y: -font.ascender))
        ctx.restoreGState()
        UIGraphicsPopContext()
    }
}
