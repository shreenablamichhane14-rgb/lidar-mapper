import SwiftUI
import UIKit

// The live minimap (docs/MODULES.md 3.38): a top-down map of CoverageLive's `MinimapSnapshot`
// in a fixed 120 pt square. Covered cells are green, partial yellow, missing red, empty cells
// let the dark translucent square show through (it reads as gray, not scanned). Walls are white
// lines, plan +y points up, and the camera is a small arrow pointing along its heading (CR-8).

/// Top-down map: `MinimapSnapshot` cells (covered green, partial yellow, missing red, empty transparent
/// over a dark translucent square that reads as gray, not scanned), walls as white lines, plan +y up,
/// the camera as a small arrow at `camera` pointing along `heading` (CR-8). Fixed 120 pt square.
struct CoverageMinimapView: View {
    /// The map to draw; nil shows the empty square.
    let snapshot: MinimapSnapshot?
    /// Covered share 0...1, read by VoiceOver as a rounded percent.
    let coverageFraction: Float

    /// Lowers the translucency of the backdrop when the user asked for less transparency.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Side of the square, points.
    static let side: CGFloat = 120
    /// Corner radius of the square, points.
    static let cornerRadius: CGFloat = 12

    /// A minimap of `snapshot` whose VoiceOver value is `coverageFraction` as a percent.
    init(snapshot: MinimapSnapshot?, coverageFraction: Float) {
        self.snapshot = snapshot
        self.coverageFraction = coverageFraction
    }

    /// The square: backdrop, the drawn map and a thin border; one VoiceOver element.
    var body: some View {
        let map = snapshot
        let shape = RoundedRectangle(cornerRadius: CoverageMinimapView.cornerRadius, style: .continuous)
        let backdrop: Double = reduceTransparency ? 0.85 : 0.55
        return Canvas { context, size in
            context.withCGContext { cg in
                CoverageMinimapDrawing.draw(map, in: cg, size: size, style: CoverageOverlayStyle.display)
            }
        }
        .frame(width: CoverageMinimapView.side, height: CoverageMinimapView.side)
        .background(shape.fill(Color.black.opacity(backdrop)))
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.CoverageOverlay.minimapLabel)
        .accessibilityValue(Copy.CoverageOverlay.minimapValue(CoverageMinimapLayout.percent(coverageFraction)))
    }
}

/// Pure layout of the minimap (tested).
enum CoverageMinimapLayout {
    /// Scale and offset that fit `width x height` cells into `size` points, centered. Scale 0 and
    /// the center of `size` when there is no cell or no room.
    static func fit(width: Int, height: Int, in size: CGSize) -> (scale: CGFloat, offset: CGPoint) {
        let center = CGPoint(x: max(size.width, 0) / 2, y: max(size.height, 0) / 2)
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return (scale: 0, offset: center) }
        let columns = CGFloat(width)
        let rows = CGFloat(height)
        let scale = min(size.width / columns, size.height / rows)
        let offsetX = (size.width - columns * scale) / 2
        let offsetY = (size.height - rows * scale) / 2
        return (scale: scale, offset: CGPoint(x: offsetX, y: offsetY))
    }

    /// The rectangle of cell (x, y); plan +y points up on screen, so row 0 is drawn at the bottom.
    static func cellRect(x: Int, y: Int, height: Int, scale: CGFloat, offset: CGPoint) -> CGRect {
        let row = CGFloat(height - 1 - y)
        return CGRect(x: offset.x + CGFloat(x) * scale, y: offset.y + row * scale, width: scale, height: scale)
    }

    /// Screen point of a plan position.
    static func point(_ plan: Vec2, origin: Vec2, cellSize: Float, height: Int, scale: CGFloat, offset: CGPoint) -> CGPoint {
        guard cellSize.isFinite, cellSize > 0 else { return offset }
        let column = CGFloat((plan.x - origin.x) / cellSize)
        let row = CGFloat((plan.y - origin.y) / cellSize)
        return CGPoint(x: offset.x + column * scale, y: offset.y + (CGFloat(height) - row) * scale)
    }

    /// nil for `.empty`, else the style color of covered, partial or missing.
    static func color(for cell: MinimapCell, style: CoverageOverlayStyle) -> SIMD4<Float>? {
        switch cell {
        case .empty: return nil
        case .covered: return style.color(for: .green)
        case .partial: return style.color(for: .yellow)
        case .missing: return style.color(for: .red)
        }
    }

    /// Rounded percent for VoiceOver (0...100; 0 when not finite).
    static func percent(_ fraction: Float) -> Int {
        guard fraction.isFinite else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * 100).rounded())
    }

    /// Unit screen direction of a plan heading (radians counter-clockwise from plan +x); screen y
    /// points down, so plan +y maps to screen -y.
    static func screenDirection(heading: Float) -> CGVector {
        guard heading.isFinite else { return CGVector(dx: 0, dy: -1) }
        return CGVector(dx: CGFloat(cos(heading)), dy: CGFloat(-sin(heading)))
    }
}

/// Core Graphics drawing of the minimap (any thread; the Canvas calls it on main).
enum CoverageMinimapDrawing {
    /// Empty margin inside the square, points.
    static let inset: CGFloat = 6
    /// Wall line width, points.
    static let wallWidth: CGFloat = 1.5
    /// Length of the camera arrow and its half width, points.
    static let arrowLength: CGFloat = 10
    static let arrowHalfWidth: CGFloat = 5
    /// Radius of the camera dot when the heading is unknown, points.
    static let dotRadius: CGFloat = 3.5

    /// Cells (batched per color, no antialiasing so neighbors meet without seams), walls and the
    /// camera marker of `snapshot`, fitted into `size` minus the inset. Nothing for nil or an empty grid.
    static func draw(_ snapshot: MinimapSnapshot?, in cg: CGContext, size: CGSize, style: CoverageOverlayStyle) {
        guard let map = snapshot, map.width > 0, map.height > 0 else { return }
        let inner = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        let fitted = CoverageMinimapLayout.fit(width: map.width, height: map.height, in: inner)
        guard fitted.scale > 0 else { return }
        let offset = CGPoint(x: fitted.offset.x + inset, y: fitted.offset.y + inset)
        cg.saveGState()
        cg.clip(to: CGRect(origin: .zero, size: size))
        drawCells(map, in: cg, scale: fitted.scale, offset: offset, style: style)
        drawWalls(map, in: cg, scale: fitted.scale, offset: offset)
        drawCamera(map, in: cg, scale: fitted.scale, offset: offset)
        cg.restoreGState()
    }

    /// One fill per color over the rectangles of its cells.
    static func drawCells(_ map: MinimapSnapshot, in cg: CGContext, scale: CGFloat, offset: CGPoint,
                          style: CoverageOverlayStyle) {
        var rects: [MinimapCell: [CGRect]] = [:]
        for y in 0..<map.height {
            for x in 0..<map.width {
                let cell = map.cell(x: x, y: y)
                guard cell != .empty else { continue }
                let rect = CoverageMinimapLayout.cellRect(x: x, y: y, height: map.height, scale: scale, offset: offset)
                rects[cell, default: []].append(rect)
            }
        }
        cg.setShouldAntialias(false)
        for cell in MinimapCell.allCases {
            guard let list = rects[cell], !list.isEmpty,
                  let color = CoverageMinimapLayout.color(for: cell, style: style) else { continue }
            cg.setFillColor(cgColor(color))
            cg.fill(list)
        }
        cg.setShouldAntialias(true)
    }

    /// White wall polylines.
    static func drawWalls(_ map: MinimapSnapshot, in cg: CGContext, scale: CGFloat, offset: CGPoint) {
        guard !map.walls.isEmpty else { return }
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(wallWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for polyline in map.walls where polyline.count >= 2 {
            cg.beginPath()
            for (i, vertex) in polyline.enumerated() {
                let p = CoverageMinimapLayout.point(vertex, origin: map.origin, cellSize: map.cellSize,
                                                    height: map.height, scale: scale, offset: offset)
                if i == 0 { cg.move(to: p) } else { cg.addLine(to: p) }
            }
            cg.strokePath()
        }
    }

    /// The "you are here" marker: an arrow along `heading`, or a dot when the heading is unknown.
    static func drawCamera(_ map: MinimapSnapshot, in cg: CGContext, scale: CGFloat, offset: CGPoint) {
        guard let camera = map.camera, camera.x.isFinite, camera.y.isFinite else { return }
        let tip = CoverageMinimapLayout.point(camera, origin: map.origin, cellSize: map.cellSize,
                                              height: map.height, scale: scale, offset: offset)
        cg.setFillColor(UIColor.white.cgColor)
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(1)
        guard let heading = map.heading, heading.isFinite else {
            let box = CGRect(x: tip.x - dotRadius, y: tip.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius)
            cg.addEllipse(in: box)
            cg.drawPath(using: .fillStroke)
            return
        }
        let d = CoverageMinimapLayout.screenDirection(heading: heading)
        let halfLength = arrowLength / 2
        let front = CGPoint(x: tip.x + d.dx * halfLength, y: tip.y + d.dy * halfLength)
        let backCenter = CGPoint(x: tip.x - d.dx * halfLength, y: tip.y - d.dy * halfLength)
        let side = CGVector(dx: -d.dy * arrowHalfWidth, dy: d.dx * arrowHalfWidth)
        cg.beginPath()
        cg.move(to: front)
        cg.addLine(to: CGPoint(x: backCenter.x + side.dx, y: backCenter.y + side.dy))
        cg.addLine(to: CGPoint(x: backCenter.x - side.dx, y: backCenter.y - side.dy))
        cg.closePath()
        cg.drawPath(using: .fillStroke)
    }

    /// Opaque-as-given `CGColor` of a 0...1 RGBA color.
    static func cgColor(_ c: SIMD4<Float>) -> CGColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)).cgColor
    }
}
