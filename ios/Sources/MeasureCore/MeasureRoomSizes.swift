import Foundation
import simd

/// Room-level sizes for the dimension list. The numbers are RoomModel's `RoomMetrics`; when a
/// metric is missing (not finite or not positive) while the geometry to derive it exists, it
/// is derived here from the same geometry (wall loop, floor outline, wall heights), so a room
/// never shows 0 for a size it has. Length is always the longer side.
struct MeasureRoomSizes {
    /// Longer side of the minimum-area rectangle of the outline, meters.
    var length: Float
    /// Shorter side of that rectangle, meters.
    var width: Float
    /// Floor area, square meters.
    var floorArea: Float
    /// Perimeter of the wall loop, meters.
    var perimeter: Float
    /// Ceiling height, meters, and where it came from.
    var ceilingHeight: Float
    var ceilingProvenance: Provenance
    /// Total wall area minus openings, square meters.
    var wallArea: Float
    /// Floor area times ceiling height, cubic meters, and where it came from.
    var volume: Float
    var volumeProvenance: Provenance

    /// Sizes of `room`; `wallAreas` are the per-wall net areas (fallback for the total).
    init(room: CleanRoom, wallAreas: [Float]) {
        let metrics = room.metrics
        let outline = MeasureRoomSizes.outlinePoints(room)

        var longSide = metrics.length
        var shortSide = metrics.width
        if !(MeasureRoomSizes.isPositive(longSide) && MeasureRoomSizes.isPositive(shortSide)),
           outline.count >= 3, let rectangle = Rectangle2D.minimumArea(enclosing: outline) {
            let a: Float = 2 * rectangle.halfExtents.x
            let b: Float = 2 * rectangle.halfExtents.y
            longSide = max(a, b)
            shortSide = min(a, b)
        }
        if shortSide > longSide { swap(&longSide, &shortSide) }
        length = longSide
        width = shortSide

        let area: Float = MeasureRoomSizes.isPositive(metrics.floorArea)
            ? metrics.floorArea : Polygon2D(points: outline).area
        floorArea = area

        if MeasureRoomSizes.isPositive(metrics.perimeter) {
            perimeter = metrics.perimeter
        } else if !room.walls.isEmpty {
            var total: Float = 0
            for wall in room.walls { total += MeasureRoomSizes.wallLength(wall) }
            perimeter = total
        } else {
            perimeter = Polygon2D(points: outline).perimeter
        }

        var height = metrics.ceilingHeight
        var heightProvenance = metrics.ceilingProvenance
        if !MeasureRoomSizes.isPositive(height) {
            if MeasureRoomSizes.isPositive(room.ceiling.height) {
                height = room.ceiling.height
                heightProvenance = room.ceiling.provenance
            } else if let median = MeasureRoomSizes.medianWallHeight(room.walls) {
                height = median
                heightProvenance = .estimated
            }
        }
        ceilingHeight = height
        ceilingProvenance = heightProvenance

        if MeasureRoomSizes.isPositive(metrics.wallArea) {
            wallArea = metrics.wallArea
        } else {
            var total: Float = 0
            for net in wallAreas where net.isFinite { total += net }
            wallArea = total
        }

        if MeasureRoomSizes.isPositive(metrics.volume) {
            volume = metrics.volume
            volumeProvenance = metrics.volumeProvenance
        } else {
            volume = area * height
            volumeProvenance = heightProvenance
        }
    }

    // MARK: - Element sizes

    /// Length along a wall: the arc length for a valid curved wall (never shorter than the
    /// chord), otherwise the straight distance from start to end.
    static func wallLength(_ wall: CleanWall) -> Float {
        let chord = wall.length
        guard let arc = wall.arc else { return chord }
        let span = abs(arc.endAngle - arc.startAngle)
        let arcLength = arc.radius * span
        guard arc.radius.isFinite, arc.radius > 0, span.isFinite, span > 0, span <= 2 * Float.pi,
              arcLength.isFinite, arcLength >= chord * 0.999 else { return chord }
        return arcLength
    }

    /// Height of an opening: head minus sill, never negative.
    static func openingHeight(_ opening: CleanOpening) -> Float {
        let height = opening.headHeight - opening.sillHeight
        guard height.isFinite else { return height }
        return max(0, height)
    }

    /// Wall rectangle (`length` x height) minus the part of each of its openings that lies on
    /// the wall, never negative. Openings of other walls are ignored.
    static func wallArea(_ wall: CleanWall, length: Float, openings: [CleanOpening]) -> Float {
        guard length.isFinite, wall.height.isFinite else { return Float.nan }
        let spanLength = max(0, length)
        let spanHeight = max(0, wall.height)
        var area = spanLength * spanHeight
        for opening in openings where opening.wallID == wall.id {
            let left = max(0, opening.offsetAlongWall)
            let right = min(spanLength, opening.offsetAlongWall + opening.width)
            let bottom = max(0, opening.sillHeight)
            let top = min(spanHeight, opening.headHeight)
            let across: Float = right - left
            let up: Float = top - bottom
            guard across.isFinite, up.isFinite, across > 0, up > 0 else { continue }
            area -= across * up
        }
        return max(0, area)
    }

    // MARK: - Helpers

    /// The floor outline in plan coordinates, or the wall starts when the outline is missing.
    static func outlinePoints(_ room: CleanRoom) -> [SIMD2<Float>] {
        let outline = room.floor.outline.map { $0.simd }
        if outline.count >= 3 { return outline }
        return room.walls.map { PlanAxes.toPlan($0.start.simd) }
    }

    /// Median height of the walls with a finite positive height, or nil.
    static func medianWallHeight(_ walls: [CleanWall]) -> Float? {
        let heights = walls.map { $0.height }.filter { isPositive($0) }.sorted()
        guard !heights.isEmpty else { return nil }
        let middle = heights.count / 2
        if heights.count % 2 == 0 { return (heights[middle - 1] + heights[middle]) * 0.5 }
        return heights[middle]
    }

    /// True for a finite value above zero.
    static func isPositive(_ x: Float) -> Bool {
        x.isFinite && x > 0
    }
}
