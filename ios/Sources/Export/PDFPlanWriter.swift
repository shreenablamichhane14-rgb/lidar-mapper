import Foundation
import simd
import UIKit

/// One-page vector PDF of a `Plan2D` at an architectural scale, with a title block
/// (project name, date, scale, north arrow, scale bar). Drawn with UIBezierPath and
/// NSAttributedString through UIGraphicsPDFRenderer, so lines and text stay vector.
enum PDFPlanWriter {
    /// Landscape paper size.
    enum Paper {
        /// US Letter landscape, 11 x 8.5 in.
        case usLetter
        /// A4 landscape, 297 x 210 mm.
        case a4

        /// Page size in points (1/72 in).
        var size: CGSize {
            switch self {
            case .usLetter: return CGSize(width: 792, height: 612)
            case .a4: return CGSize(width: 841.89, height: 595.28)
            }
        }
    }

    /// A drawing scale: 1 unit on paper = `ratio` units in reality.
    struct Scale: Equatable {
        /// Text for the title block, e.g. 1/4" = 1'-0".
        var label: String
        /// Reality divided by paper.
        var ratio: Double
        /// Whether the scale bar uses feet.
        var imperial: Bool

        /// 1/4" = 1'-0" (1:48).
        static let quarterInch = Scale(label: "1/4\" = 1'-0\"", ratio: 48, imperial: true)
        /// 1/8" = 1'-0" (1:96).
        static let eighthInch = Scale(label: "1/8\" = 1'-0\"", ratio: 96, imperial: true)
        /// 1/16" = 1'-0" (1:192), for large plans in feet.
        static let sixteenthInch = Scale(label: "1/16\" = 1'-0\"", ratio: 192, imperial: true)
        /// 1:50.
        static let oneToFifty = Scale(label: "1:50", ratio: 50, imperial: false)
        /// 1:100.
        static let oneToHundred = Scale(label: "1:100", ratio: 100, imperial: false)

        /// PDF points per plan meter.
        var pointsPerMeter: Double { 72 / 0.0254 / ratio }
    }

    /// Page and title block settings.
    struct Options {
        /// Paper size (landscape).
        var paper: Paper
        /// Date shown in the title block.
        var date: Date
        /// Direction of north in plan coordinates (radians, counter-clockwise from +X);
        /// pi/2 means plan-up is north.
        var northAngle: Double
        /// Stroke width in points.
        var lineWidth: CGFloat
        /// Title block caption before the scale.
        var scaleCaption: String
        /// Units of the drawing scale and scale bar: true for metric (1:50, 1:100), false for
        /// feet (1/4", 1/8", 1/16" = 1'-0"), nil to follow the paper (Letter imperial, A4 metric).
        /// Exports pass the unit setting, so a metric user never gets a feet scale.
        var metric: Bool?

        /// Letter, today, north up, 0.6 pt lines, scale units from the paper.
        init(paper: Paper = .usLetter, date: Date = Date(), northAngle: Double = Double.pi / 2,
             lineWidth: CGFloat = 0.6, scaleCaption: String = "Scale", metric: Bool? = nil) {
            self.paper = paper
            self.date = date
            self.northAngle = northAngle
            self.lineWidth = lineWidth
            self.scaleCaption = scaleCaption
            self.metric = metric
        }
    }

    /// Page margin in points.
    static let margin: CGFloat = 36
    /// Title block height in points.
    static let titleBlockHeight: CGFloat = 64

    /// Scales tried in order: imperial first on Letter, metric first on A4.
    static func candidateScales(for paper: Paper) -> [Scale] {
        switch paper {
        case .usLetter: return [.quarterInch, .eighthInch, .oneToFifty, .oneToHundred]
        case .a4: return [.oneToFifty, .oneToHundred, .quarterInch, .eighthInch]
        }
    }

    /// Scales tried in order for a unit choice, whatever the paper: metric 1:50 and 1:100, feet
    /// 1/4", 1/8" and 1/16" = 1'-0"; nil follows the paper (`candidateScales(for:)`).
    static func candidateScales(for paper: Paper, metric: Bool?) -> [Scale] {
        guard let metric else { return candidateScales(for: paper) }
        return metric ? [.oneToFifty, .oneToHundred] : [.quarterInch, .eighthInch, .sixteenthInch]
    }

    /// Area available for the drawing on a page of `paper`.
    static func drawingArea(for paper: Paper) -> CGRect {
        let size = paper.size
        return CGRect(x: margin, y: margin, width: size.width - 2 * margin,
                      height: size.height - 2 * margin - titleBlockHeight - 8)
    }

    /// The first candidate scale (`candidateScales(for:metric:)`) at which a plan of `extent`
    /// meters fits `area`; when none fits, 1:N with N rounded up to a multiple of 50 (its scale
    /// bar in feet when `metric` is false).
    static func chooseScale(extent: SIMD2<Double>, area: CGSize, paper: Paper, metric: Bool? = nil) -> Scale {
        for scale in candidateScales(for: paper, metric: metric) {
            let k = scale.pointsPerMeter
            if extent.x * k <= Double(area.width) && extent.y * k <= Double(area.height) { return scale }
        }
        let needed = max(extent.x * 72 / 0.0254 / Double(area.width), extent.y * 72 / 0.0254 / Double(area.height))
        let ratio = max(150, (needed / 50).rounded(.up) * 50)
        return Scale(label: "1:\(Int(ratio))", ratio: ratio, imperial: metric == false)
    }

    /// Length of one of the four scale bar segments, meters: in feet 2 ft up to 1:48, 4 ft up
    /// to 1:96, then 8 ft per 1:192; in metric 1 m per 1:50.
    static func scaleBarSegmentMeters(_ scale: Scale) -> Double {
        guard scale.imperial else { return max(1, (scale.ratio / 50).rounded(.up)) }
        let feet: Double
        if scale.ratio <= 48 {
            feet = 2
        } else if scale.ratio <= 96 {
            feet = 4
        } else {
            feet = 8 * max(1, (scale.ratio / 192).rounded(.up))
        }
        return feet * LengthFormat.metersPerFoot
    }

    /// Renders the plan as PDF data (starts with "%PDF").
    static func data(for plan: Plan2D, options: Options = Options()) throws -> Data {
        guard !plan.entities.isEmpty, let bounds = plan.bounds() else { throw ExportError.emptyPlan }
        let pageSize = options.paper.size
        let area = drawingArea(for: options.paper)
        let extent = bounds.max - bounds.min
        let scale = chooseScale(extent: extent, area: area.size, paper: options.paper, metric: options.metric)
        let k = scale.pointsPerMeter
        let origin = CGPoint(x: Double(area.midX) - extent.x * k / 2, y: Double(area.midY) - extent.y * k / 2)
        func page(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: Double(origin.x) + (p.x - bounds.min.x) * k, y: Double(origin.y) + (bounds.max.y - p.y) * k)
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: plan.name, kCGPDFContextCreator as String: "Mapper"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        return renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            let layers = plan.resolvedLayers()
            var colors: [String: UIColor] = [:]
            for layer in layers {
                colors[layer.name] = UIColor(red: CGFloat(layer.color.x), green: CGFloat(layer.color.y),
                                             blue: CGFloat(layer.color.z), alpha: 1)
            }
            for entity in plan.entities {
                let color = colors[entity.layer] ?? .black
                let path = UIBezierPath()
                path.lineWidth = options.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                switch entity.geometry {
                case let .line(from, to):
                    path.move(to: page(from))
                    path.addLine(to: page(to))
                case let .polyline(points, closed):
                    guard let first = points.first, points.count >= 2 else { continue }
                    path.move(to: page(first))
                    for p in points.dropFirst() { path.addLine(to: page(p)) }
                    if closed { path.close() }
                case let .circle(center, radius):
                    let r = CGFloat(abs(radius) * k)
                    let c = page(center)
                    path.append(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
                case let .arc(center, radius, startAngle, endAngle):
                    let sweep = Plan2D.sweep(start: startAngle, end: endAngle)
                    // Y is flipped on the page: plan angle a becomes -a, counter-clockwise
                    // in the plan is clockwise == false in UIKit coordinates.
                    path.addArc(withCenter: page(center), radius: CGFloat(abs(radius) * k),
                                startAngle: CGFloat(-startAngle), endAngle: CGFloat(-(startAngle + sweep)), clockwise: false)
                case let .text(position, height, string, rotation):
                    drawText(string, at: page(position), size: CGFloat(height * k), angle: rotation,
                             centered: false, color: color, in: cg)
                    continue
                case let .dimension(from, to, offset, label):
                    guard let layout = plan.dimensionLayout(from: from, to: to, offset: offset) else { continue }
                    for s in [layout.extension1, layout.extension2, layout.dimensionLine] + layout.ticks {
                        path.move(to: page(s.a))
                        path.addLine(to: page(s.b))
                    }
                    drawText(label, at: page(layout.textAnchor), size: CGFloat(layout.textHeight * k),
                             angle: layout.textAngle, centered: true, color: color, in: cg)
                }
                color.setStroke()
                path.stroke()
            }
            drawTitleBlock(plan: plan, scale: scale, options: options, pageSize: pageSize, in: cg)
        }
    }

    /// Draws single-line text with its baseline starting (or centered) at `point`,
    /// rotated counter-clockwise by `angle` as seen on the page.
    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat, angle: Double,
                                 centered: Bool, color: UIColor, bold: Bool = false, in cg: CGContext) {
        let fontSize = max(size, 1)
        let font = bold ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let width = text.size().width
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y)
        cg.rotate(by: CGFloat(-angle))
        text.draw(at: CGPoint(x: centered ? -width / 2 : 0, y: -font.ascender))
        cg.restoreGState()
    }

    private static func drawTitleBlock(plan: Plan2D, scale: Scale, options: Options, pageSize: CGSize, in cg: CGContext) {
        let box = CGRect(x: margin, y: pageSize.height - margin - titleBlockHeight,
                         width: pageSize.width - 2 * margin, height: titleBlockHeight)
        UIColor.black.setStroke()
        let frame = UIBezierPath(rect: box)
        frame.lineWidth = 1
        frame.stroke()

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let left = box.minX + 10
        drawText(plan.name, at: CGPoint(x: left, y: box.minY + 22), size: 14, angle: 0, centered: false, color: .black, bold: true, in: cg)
        drawText(dateFormatter.string(from: options.date), at: CGPoint(x: left, y: box.minY + 40), size: 9, angle: 0,
                 centered: false, color: .darkGray, in: cg)
        drawText("\(options.scaleCaption) \(scale.label)", at: CGPoint(x: left, y: box.minY + 54), size: 9, angle: 0,
                 centered: false, color: .darkGray, in: cg)

        // Scale bar: four alternating segments.
        let segmentMeters = scaleBarSegmentMeters(scale)
        let segment = CGFloat(segmentMeters * scale.pointsPerMeter)
        let barOrigin = CGPoint(x: box.midX - 2 * segment, y: box.minY + 30)
        for i in 0..<4 {
            let rect = CGRect(x: barOrigin.x + CGFloat(i) * segment, y: barOrigin.y, width: segment, height: 6)
            let bar = UIBezierPath(rect: rect)
            bar.lineWidth = 0.5
            if i % 2 == 0 {
                UIColor.black.setFill()
                bar.fill()
            }
            bar.stroke()
        }
        let total = segmentMeters * 4
        let totalText = scale.imperial ? LengthFormat.feetInches(total, denominator: .eighth) : LengthFormat.metric(total)
        drawText("0", at: CGPoint(x: barOrigin.x, y: barOrigin.y + 18), size: 8, angle: 0, centered: true, color: .black, in: cg)
        drawText(totalText, at: CGPoint(x: barOrigin.x + 4 * segment, y: barOrigin.y + 18), size: 8, angle: 0,
                 centered: true, color: .black, in: cg)

        // North arrow: a filled triangle pointing north, with "N" beyond its tip.
        let center = CGPoint(x: box.maxX - 34, y: box.midY + 4)
        let direction = CGPoint(x: cos(options.northAngle), y: -sin(options.northAngle))
        let side = CGPoint(x: -direction.y, y: direction.x)
        let tip = CGPoint(x: center.x + direction.x * 14, y: center.y + direction.y * 14)
        let back = CGPoint(x: center.x - direction.x * 10, y: center.y - direction.y * 10)
        let arrow = UIBezierPath()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: back.x + side.x * 7, y: back.y + side.y * 7))
        arrow.addLine(to: CGPoint(x: back.x - side.x * 7, y: back.y - side.y * 7))
        arrow.close()
        UIColor.black.setFill()
        arrow.fill()
        let labelPoint = CGPoint(x: center.x + direction.x * 22, y: center.y + direction.y * 22 + 4)
        drawText("N", at: labelPoint, size: 10, angle: 0, centered: true, color: .black, bold: true, in: cg)
    }
}
