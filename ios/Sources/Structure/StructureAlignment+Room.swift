import Foundation
import simd

// Moving clean rooms by a placement record and the stacked-room overlap measure
// (docs/MODULES.md 3.30). Pure functions, nonisolated, deterministic, safe on any queue.

extension StructureAlignment {
    /// Largest number of grid cells `overlapRatio` visits; a finer grid is coarsened to fit.
    static let maximumOverlapCells = 1_000_000

    /// The room moved: wall start, end and normal, wall arc center (angles plus yaw), floor
    /// outline and elevation (plus translation.y), object transforms. Openings, spans,
    /// metrics, names and ids are unchanged (rigid move). The floor's `mergedOutlines` (CR-1)
    /// move with the outline.
    static func apply(_ record: RoomAlignmentRecord, to room: CleanRoom) -> CleanRoom {
        var moved = room
        for i in moved.walls.indices {
            var wall = moved.walls[i]
            wall.start = Vec3(transform(wall.start.simd, by: record))
            wall.end = Vec3(transform(wall.end.simd, by: record))
            wall.normal = Vec3(rotateWorld(wall.normal.simd, yaw: record.yaw))
            if var arc = wall.arc {
                arc.center = Vec3(transform(arc.center.simd, by: record))
                arc.startAngle += record.yaw
                arc.endAngle += record.yaw
                wall.arc = arc
            }
            moved.walls[i] = wall
        }
        moved.floor.outline = room.floor.outline.map { Vec2(planTransform($0.simd, by: record)) }
        if let merged = room.floor.mergedOutlines {
            moved.floor.mergedOutlines = merged.map { ring in ring.map { Vec2(planTransform($0.simd, by: record)) } }
        }
        moved.floor.elevation = room.floor.elevation + record.translation.y
        let placement = matrix(record)
        for i in moved.objects.indices {
            let pose = simd_mul(placement, moved.objects[i].transform.simd)
            moved.objects[i].transform = Transform4(pose)
        }
        return moved
    }

    /// Moves the room whose `recordID == record.roomID`; false when there is none.
    @discardableResult
    static func apply(_ record: RoomAlignmentRecord, to model: inout CleanModel) -> Bool {
        guard let index = model.rooms.firstIndex(where: { $0.recordID == record.roomID }) else { return false }
        model.rooms[index] = apply(record, to: model.rooms[index])
        return true
    }

    /// Stacked-room check: cells of a `cell` grid (plan meters) inside both polygons divided by
    /// the cells inside the smaller one (`Polygon2D.contains(point:)` at cell centers over the
    /// intersection of the bounding boxes). 1 for identical squares, 0 when disjoint.
    ///
    /// The grid is anchored at the smaller polygon's bounding box, so numerator and denominator
    /// count the same cell centers; 0 when either polygon has fewer than 3 points, no area or
    /// no cell center inside the smaller one.
    static func overlapRatio(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>], cell: Float = 0.05) -> Float {
        let first = Polygon2D(points: a)
        let second = Polygon2D(points: b)
        guard a.count >= 3, b.count >= 3, first.area > 1e-6, second.area > 1e-6,
              let boxA = first.boundingBox, let boxB = second.boundingBox else { return 0 }
        let overlapMin = simd_max(boxA.min, boxB.min)
        let overlapMax = simd_min(boxA.max, boxB.max)
        guard overlapMin.x < overlapMax.x, overlapMin.y < overlapMax.y else { return 0 }
        let smallerIsFirst = first.area <= second.area
        let smaller = smallerIsFirst ? first : second
        let larger = smallerIsFirst ? second : first
        let box = smallerIsFirst ? boxA : boxB
        let size = box.max - box.min
        var step = (cell.isFinite && cell > 0) ? cell : 0.05
        var columns = Swift.max(1, Int((size.x / step).rounded(.up)))
        var rows = Swift.max(1, Int((size.y / step).rounded(.up)))
        while columns * rows > maximumOverlapCells {
            step *= 2
            columns = Swift.max(1, Int((size.x / step).rounded(.up)))
            rows = Swift.max(1, Int((size.y / step).rounded(.up)))
        }
        var inSmaller = 0
        var inBoth = 0
        for row in 0..<rows {
            let y = box.min.y + (Float(row) + 0.5) * step
            for column in 0..<columns {
                let x = box.min.x + (Float(column) + 0.5) * step
                let p = SIMD2<Float>(x, y)
                guard smaller.contains(point: p) else { continue }
                inSmaller += 1
                let insideX = p.x >= overlapMin.x && p.x <= overlapMax.x
                let insideY = p.y >= overlapMin.y && p.y <= overlapMax.y
                if insideX && insideY && larger.contains(point: p) { inBoth += 1 }
            }
        }
        guard inSmaller > 0 else { return 0 }
        return Float(inBoth) / Float(inSmaller)
    }
}
