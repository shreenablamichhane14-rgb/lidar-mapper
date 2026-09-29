import Foundation
import simd

/// The CR-1 plan operations (docs/MODULES.md 3.37c): move and resize openings, merge and split
/// rooms, and batches. They follow the clean model's rules (RoomModel 3.37b: the same
/// `Polygon2D.clipped` calls, thresholds and replay rules), so one log entry changes both models
/// alike. Walls, openings and fixtures belong to the level in the plan, so merges and splits
/// change only room outlines, areas, labels and the rooms' generated overall dimensions.
extension PlanModel {
    /// Minimum width of a resized opening, meters.
    static let minimumOpeningWidth: Float = 0.05
    /// A split that leaves less than this on either side of the line changes nothing, square meters.
    static let minimumSplitArea: Float = 0.01
    /// Split line end points this close or closer count as one point, meters (RoomModel's
    /// `RoomEditLimits.coincidentPoints`, so both models refuse the same lines).
    static let splitPointTolerance: Float = 1e-6
    /// Pieces of a split with less area than this are rounding slivers and are dropped, square
    /// meters (RoomModel's `RoomEditLimits.sliverArea`, so both models keep the same pieces).
    static let splitSliverArea: Float = 1e-4
    /// Log category of plan edits.
    static let editLogCategory = "floorplan"

    // MARK: - Openings

    /// `moveOpening`: the near edge `offset` meters from the wall's `a` end, clamped to
    /// [0, wall length - width]. False when the opening is missing; true unchanged when its wall
    /// is not on its level or the offset is not finite (logged).
    mutating func moveOpening(_ id: ElementID, offset: Float) -> Bool {
        guard let site = openingSite(id) else { return false }
        guard let length = site.wallLength, offset.isFinite else {
            LogStore.shared.write("moveOpening ignored for \(id.uuid): no usable wall or offset \(offset)",
                                  category: PlanModel.editLogCategory)
            return true
        }
        var opening = levels[site.level].openings[site.index]
        let width = min(max(opening.width.isFinite ? opening.width : 0, 0), length)
        opening.offset = PlanModel.clampedOffset(offset, width: width, length: length)
        levels[site.level].openings[site.index] = opening
        return true
    }

    /// `resizeOpening`: the width clamped to [0.05, wall length] keeping the opening's center,
    /// then the offset clamped to the wall. Heights are ignored (the plan has none). False when
    /// the opening is missing; true unchanged when its wall is not on its level or the width is
    /// not finite (logged).
    mutating func resizeOpening(_ id: ElementID, width: Float) -> Bool {
        guard let site = openingSite(id) else { return false }
        guard let length = site.wallLength, width.isFinite else {
            LogStore.shared.write("resizeOpening ignored for \(id.uuid): no usable wall or width \(width)",
                                  category: PlanModel.editLogCategory)
            return true
        }
        var opening = levels[site.level].openings[site.index]
        let oldWidth: Float = opening.width.isFinite ? max(0, opening.width) : 0
        let center: Float = opening.offset + oldWidth / 2
        let newWidth = min(max(width, PlanModel.minimumOpeningWidth), length)
        opening.width = newWidth
        opening.offset = PlanModel.clampedOffset(center - newWidth / 2, width: newWidth, length: length)
        levels[site.level].openings[site.index] = opening
        return true
    }

    /// `offset` clamped to [0, max(0, length - width)]; 0 when it is not finite.
    static func clampedOffset(_ offset: Float, width: Float, length: Float) -> Float {
        guard offset.isFinite else { return 0 }
        return min(max(offset, 0), max(0, length - width))
    }

    /// Level and index of an opening, with the length of its wall on that level (nil when the
    /// wall is missing or its end points are not finite).
    private func openingSite(_ id: ElementID) -> (level: Int, index: Int, wallLength: Float?)? {
        for li in levels.indices {
            guard let oi = levels[li].openings.firstIndex(where: { $0.id == id }) else { continue }
            let wallID = levels[li].openings[oi].wallID
            var wallLength: Float?
            if let wall = levels[li].walls.first(where: { $0.id == wallID }) {
                let length = simd_distance(wall.a.simd, wall.b.simd)
                if length.isFinite { wallLength = length }
            }
            return (level: li, index: oi, wallLength: wallLength)
        }
        return nil
    }

    // MARK: - Rooms

    /// `mergeRooms`: false when `into` or any listed room is missing. Each listed room on the
    /// level of `into` gives its outline and merged outlines to `into.mergedOutlines` and is
    /// removed; rooms on another level are skipped (logged). `into` keeps its name and
    /// `labelAt`; its area becomes the total of its parts. The merged rooms' overall
    /// dimensions are removed and those of `into` enclose every part.
    mutating func mergeRooms(_ ids: [ElementID], into target: ElementID) -> Bool {
        guard let site = roomSite(target), ids.allSatisfy({ roomSite($0) != nil }) else { return false }
        var level = levels[site.level]
        var into = level.rooms[site.index]
        var parts = into.mergedOutlines ?? []
        var removed: [ElementID] = []
        var seen: Set<ElementID> = [target]
        for id in ids where seen.insert(id).inserted {
            guard let ri = level.rooms.firstIndex(where: { $0.id == id }) else {
                LogStore.shared.write("mergeRooms: room \(id.uuid) is on another level, skipped",
                                      category: PlanModel.editLogCategory)
                continue
            }
            let room = level.rooms[ri]
            if room.outline.count >= 3 { parts.append(room.outline) }
            for part in room.mergedOutlines ?? [] where part.count >= 3 {
                parts.append(part)
            }
            level.rooms.remove(at: ri)
            removed.append(id)
        }
        guard !removed.isEmpty, let ti = level.rooms.firstIndex(where: { $0.id == target }) else { return true }
        into.mergedOutlines = parts.isEmpty ? nil : parts
        into.area = PlanBuilder.totalArea(into)
        level.rooms[ti] = into
        let removedDimensions = Set(removed.flatMap { [PlanBuilder.overallDimensionID($0, 0), PlanBuilder.overallDimensionID($0, 1)] })
        level.dimensions.removeAll { removedDimensions.contains($0.id) }
        let offset = PlanModel.overallOffset(of: target, in: level) ?? PlanBuilder.overallOffset(thickness: 0)
        PlanModel.followOverallDimensions(of: into, in: &level, offset: offset, add: false)
        levels[site.level] = level
        return true
    }

    /// `splitRoom`: false when the room is missing. True unchanged when `newRoom` already exists
    /// (a replay), when `line` has fewer than two points or its first and last points coincide
    /// or are not finite, or when either side holds less than 0.01 square meters (logged).
    /// Every part is cut with `Polygon2D.clipped(leftOf: first, last)` for the kept room and
    /// `clipped(leftOf: last, first)` for the new one; a side's largest piece becomes its
    /// outline and the others its merged outlines. The new room (empty name, no RoomPlan
    /// identifier) goes right after the kept one; both get `labelAt` inside their outline and
    /// the total area, and overall dimensions follow when the split room had them.
    mutating func splitRoom(_ id: ElementID, line: [Vec2], newRoom: ElementID) -> Bool {
        guard let site = roomSite(id) else { return false }
        guard roomSite(newRoom) == nil else { return true }
        guard line.count >= 2, let first = line.first?.simd, let last = line.last?.simd,
              PlanSketch.isFinite(first), PlanSketch.isFinite(last),
              simd_distance(first, last) > PlanModel.splitPointTolerance else {
            LogStore.shared.write("splitRoom ignored for \(id.uuid): unusable line of \(line.count) points",
                                  category: PlanModel.editLogCategory)
            return true
        }
        var level = levels[site.level]
        var kept = level.rooms[site.index]
        let parts = PlanBuilder.parts(of: kept)
        let left = PlanModel.pieces(parts, leftOf: first, last)
        let right = PlanModel.pieces(parts, leftOf: last, first)
        let leftArea = PlanModel.area(of: left)
        let rightArea = PlanModel.area(of: right)
        guard leftArea >= PlanModel.minimumSplitArea, rightArea >= PlanModel.minimumSplitArea else {
            LogStore.shared.write("splitRoom ignored for \(id.uuid): sides of \(leftArea) and \(rightArea) m2",
                                  category: PlanModel.editLogCategory)
            return true
        }
        var created = PlanRoom(id: ElementID(uuid: newRoom.uuid, roomPlanID: nil), name: "", outline: [],
                               labelAt: Vec2.zero, area: 0)
        PlanModel.assign(left, to: &kept)
        PlanModel.assign(right, to: &created)
        level.rooms[site.index] = kept
        level.rooms.insert(created, at: site.index + 1)
        let offset = PlanModel.overallOffset(of: id, in: level)
        PlanModel.followOverallDimensions(of: kept, in: &level, offset: offset ?? 0, add: false)
        if let inherited = offset {
            PlanModel.followOverallDimensions(of: created, in: &level, offset: inherited, add: true)
        }
        levels[site.level] = level
        return true
    }

    /// `batch`: the operations applied in order to a copy; the first one that returns false
    /// makes the batch return false with the plan unchanged, else the copy replaces the plan.
    mutating func applyBatch(_ operations: [EditOperation]) -> Bool {
        var copy = self
        for op in operations {
            guard copy.apply(op) else { return false }
        }
        self = copy
        return true
    }

    /// Level and index of a room.
    private func roomSite(_ id: ElementID) -> (level: Int, index: Int)? {
        for li in levels.indices {
            if let ri = levels[li].rooms.firstIndex(where: { $0.id == id }) { return (li, ri) }
        }
        return nil
    }

    // MARK: - Split helpers

    /// The pieces of `parts` on the left of the directed line a -> b (one ring per part that
    /// has area there), counter-clockwise; slivers are dropped.
    static func pieces(_ parts: [[SIMD2<Float>]], leftOf a: SIMD2<Float>, _ b: SIMD2<Float>) -> [[SIMD2<Float>]] {
        var result: [[SIMD2<Float>]] = []
        for part in parts {
            let clipped = Polygon2D(points: part).clipped(leftOf: a, b)
            guard clipped.points.count >= 3, clipped.area >= splitSliverArea else { continue }
            result.append(clipped.signedArea < 0 ? Array(clipped.points.reversed()) : clipped.points)
        }
        return result
    }

    /// Total polygon area of some rings, square meters.
    static func area(of rings: [[SIMD2<Float>]]) -> Float {
        rings.reduce(Float(0)) { $0 + Polygon2D(points: $1).area }
    }

    /// Gives a room the pieces of one side: the largest (the first of equals) becomes its
    /// outline, the others its merged outlines (nil when none); area is the total and the label
    /// point lies inside the outline.
    static func assign(_ pieces: [[SIMD2<Float>]], to room: inout PlanRoom) {
        let areas = pieces.map { Polygon2D(points: $0).area }
        guard let largest = areas.indices.max(by: { areas[$0] < areas[$1] }) else { return }
        var rest = pieces
        let main = rest.remove(at: largest)
        room.outline = main.map { Vec2($0) }
        room.mergedOutlines = rest.isEmpty ? nil : rest.map { piece in piece.map { Vec2($0) } }
        room.area = PlanBuilder.totalArea(room)
        room.labelAt = Vec2(PlanBuilder.interiorPoint(of: main))
    }

    // MARK: - Overall dimensions

    /// Offset of the first generated overall dimension of a room that exists on the level, nil
    /// when it has none (the user deleted them).
    static func overallOffset(of room: ElementID, in level: PlanLevel) -> Float? {
        for index in 0..<2 {
            let dimensionID = PlanBuilder.overallDimensionID(room, index)
            if let dimension = level.dimensions.first(where: { $0.id == dimensionID }) { return dimension.offset }
        }
        return nil
    }

    /// Recomputes a room's generated overall dimensions from every part: existing ones get the
    /// new end points (their offset is kept); with `add`, missing ones are added with `offset`.
    /// A dimension the user deleted is not recreated unless `add` is set (a split's new room).
    static func followOverallDimensions(of room: PlanRoom, in level: inout PlanLevel, offset: Float, add: Bool) {
        let points = PlanBuilder.parts(of: room).flatMap { $0 }
        for dimension in PlanBuilder.overallDimensions(roomID: room.id, points: points, offset: offset) {
            if let di = level.dimensions.firstIndex(where: { $0.id == dimension.id }) {
                level.dimensions[di].a = dimension.a
                level.dimensions[di].b = dimension.b
            } else if add {
                level.dimensions.append(dimension)
            }
        }
    }
}
