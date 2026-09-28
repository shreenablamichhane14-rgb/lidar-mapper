import Foundation
import simd

/// Derives the base `PlanModel` (representation D) from the clean model (docs/ARCHITECTURE.md
/// 5.7). Pure and deterministic: the same clean model always gives the same plan, including
/// the identifiers of generated dimensions, so edits that reference them survive a rebuild.
enum PlanBuilder {
    /// Offset of the per-wall interior dimension into the room, meters.
    static let wallDimensionOffset: Float = 0.3
    /// Gap between a room's outer wall face and its overall dimensions, meters.
    static let overallDimensionGap: Float = 0.6
    /// Rectangles thinner than this (half extent, meters) get no overall dimensions.
    static let minimumOverallHalfExtent: Float = 0.05

    /// One level per floor index. Walls a->b counter-clockwise around their room (room on the left,
    /// body drawn to the right by thickness); one interior dimension per wall (offset 0.3 m into the
    /// room); two overall dimensions per room from Rectangle2D.minimumArea; fixtures from objects.
    ///
    /// Levels are the union of `floors` and every `floorIndex` used by a room, sorted by index.
    /// A wall whose clean normal points to the right of start->end is reversed so the room is on
    /// its left; its opening offsets, occluded spans and door hinge ends are mirrored with it.
    /// Openings without a host wall cannot be placed and are left out.
    static func build(from model: CleanModel, floors: [FloorRecord]) -> PlanModel {
        var indices = Set(floors.map { $0.id })
        for room in model.rooms { indices.insert(room.floorIndex) }
        var levels: [PlanLevel] = []
        for index in indices.sorted() {
            let record = floors.first { $0.id == index }
            let rooms = model.rooms.filter { $0.floorIndex == index }
            let lowest = rooms.map { $0.floor.elevation }.min() ?? 0
            var level = PlanLevel(id: index, name: record?.name ?? "", elevation: record?.elevation ?? lowest,
                                  rooms: [], walls: [], openings: [], fixtures: [], annotations: [], dimensions: [])
            for room in rooms { add(room, to: &level) }
            levels.append(level)
        }
        return PlanModel(levels: levels, northAngle: 0, stamp: nil)
    }

    /// Adds one clean room (outline, walls, openings, fixtures and dimensions) to a level.
    private static func add(_ room: CleanRoom, to level: inout PlanLevel) {
        let outline = roomOutline(room)
        let labelPoint = interiorPoint(of: outline)
        let polygonArea = Polygon2D(points: outline).area
        let area = room.metrics.floorArea > 0 ? room.metrics.floorArea : polygonArea
        level.rooms.append(PlanRoom(id: room.id, name: room.name, outline: outline.map { Vec2($0) },
                                    labelAt: Vec2(labelPoint), area: area))

        var flipped: Set<ElementID> = []
        var lengths: [ElementID: Float] = [:]
        for wall in room.walls {
            var a = PlanAxes.toPlan(wall.start.simd)
            var b = PlanAxes.toPlan(wall.end.simd)
            let length = simd_distance(a, b)
            var spans = wall.occludedSpans
            if !roomIsOnLeft(a: a, b: b, wallNormal: wall.normal.simd, labelPoint: labelPoint) {
                swap(&a, &b)
                spans = mirrored(spans, length: length)
                flipped.insert(wall.id)
            }
            lengths[wall.id] = length
            level.walls.append(PlanWall(id: wall.id, a: Vec2(a), b: Vec2(b), thickness: max(0, wall.thickness),
                                        thicknessSource: wall.thicknessSource, arc: wall.arc,
                                        provenance: wall.provenance, occludedSpans: spans))
            if length > 0.01 {
                level.dimensions.append(PlanDimension(id: wallDimensionID(wall.id), a: Vec2(a), b: Vec2(b),
                                                      offset: wallDimensionOffset, isUser: false))
            }
        }

        for opening in room.openings {
            guard let wallID = opening.wallID, let length = lengths[wallID] else { continue }
            let width = min(max(opening.width, 0), length)
            var offset = min(max(opening.offsetAlongWall, 0), max(0, length - width))
            var swing = opening.swing
            if flipped.contains(wallID) {
                offset = max(0, length - offset - width)
                swing?.hingeAtStart.toggle()
            }
            let isDoor = opening.kind == .door || opening.kind == .openDoor
            if swing == nil && isDoor {
                swing = defaultSwing(offset: offset, width: width, wallLength: length)
            }
            level.openings.append(PlanOpening(id: opening.id, wallID: wallID, kind: opening.kind,
                                              offset: offset, width: width, swing: swing))
        }

        for object in room.objects {
            level.fixtures.append(fixture(from: object))
        }
        level.dimensions.append(contentsOf: overallDimensions(room: room, outline: outline))
    }

    /// Two overall dimensions along the sides of the room's minimum-area rectangle, drawn
    /// outside the room beyond its thickest wall.
    private static func overallDimensions(room: CleanRoom, outline: [SIMD2<Float>]) -> [PlanDimension] {
        guard let rect = Rectangle2D.minimumArea(enclosing: outline),
              rect.halfExtents.x > minimumOverallHalfExtent, rect.halfExtents.y > minimumOverallHalfExtent
        else { return [] }
        let u = rect.axis
        let v = SIMD2<Float>(-u.y, u.x)
        let hx = rect.halfExtents.x
        let hy = rect.halfExtents.y
        let thickness = room.walls.map { max(0, $0.thickness) }.max() ?? 0
        // The room lies on the left of both sides below, so a negative offset is outside.
        let offset = -(thickness + overallDimensionGap)
        let p0 = rect.center - u * hx - v * hy
        let p1 = rect.center + u * hx - v * hy
        let p2 = rect.center + u * hx + v * hy
        return [PlanDimension(id: overallDimensionID(room.id, 0), a: Vec2(p0), b: Vec2(p1), offset: offset, isUser: false),
                PlanDimension(id: overallDimensionID(room.id, 1), a: Vec2(p1), b: Vec2(p2), offset: offset, isUser: false)]
    }

    /// The room outline in plan coordinates, counter-clockwise, without a closing duplicate.
    /// Falls back to the wall start points when the floor outline has fewer than 3 points.
    static func roomOutline(_ room: CleanRoom) -> [SIMD2<Float>] {
        var points = room.floor.outline.map { $0.simd }
        if points.count < 3 {
            points = room.walls.map { PlanAxes.toPlan($0.start.simd) }
        }
        if points.count >= 2, let first = points.first, let last = points.last, simd_distance(first, last) < 1e-5 {
            points.removeLast()
        }
        if Polygon2D(points: points).signedArea < 0 { points.reverse() }
        return points
    }

    /// A point inside the outline for the room tag: the area centroid when it is inside,
    /// otherwise the middle of the widest horizontal chord through the centroid.
    static func interiorPoint(of outline: [SIMD2<Float>]) -> SIMD2<Float> {
        let polygon = Polygon2D(points: outline)
        let centroid = polygon.centroid
        guard outline.count >= 3, !polygon.contains(point: centroid) else { return centroid }
        let y = centroid.y
        var crossings: [Float] = []
        var j = outline.count - 1
        for i in 0..<outline.count {
            let p = outline[i]
            let q = outline[j]
            if (p.y > y) != (q.y > y) {
                let t = (y - q.y) / (p.y - q.y)
                crossings.append(q.x + t * (p.x - q.x))
            }
            j = i
        }
        crossings.sort()
        var best: SIMD2<Float>?
        var bestWidth: Float = 0
        var k = 0
        while k + 1 < crossings.count {
            let width = crossings[k + 1] - crossings[k]
            if width > bestWidth {
                bestWidth = width
                best = SIMD2<Float>((crossings[k] + crossings[k + 1]) * 0.5, y)
            }
            k += 2
        }
        return best ?? centroid
    }

    /// True when the room is on the left of a->b: decided by the clean wall normal (into the
    /// room), or by the side of the room label point when the normal is unusable.
    static func roomIsOnLeft(a: SIMD2<Float>, b: SIMD2<Float>, wallNormal: SIMD3<Float>, labelPoint: SIMD2<Float>) -> Bool {
        let d = b - a
        let left = SIMD2<Float>(-d.y, d.x)
        let byNormal = simd_dot(left, PlanAxes.toPlan(wallNormal))
        if abs(byNormal) > 1e-3 * simd_length(d) { return byNormal > 0 }
        return simd_dot(left, labelPoint - (a + b) * 0.5) >= 0
    }

    /// Occluded spans measured from the other end of a wall of `length`.
    static func mirrored(_ spans: [ClosedRange<Float>], length: Float) -> [ClosedRange<Float>] {
        var result: [ClosedRange<Float>] = []
        for span in spans.reversed() {
            let lower = max(0, length - span.upperBound)
            let upper = max(0, length - span.lowerBound)
            if lower <= upper { result.append(lower...upper) }
        }
        return result
    }

    /// Estimated swing for a door without one (RESEARCH 3.6 recommended 4): hinged at the end
    /// nearer a wall corner, opening into the room.
    static func defaultSwing(offset: Float, width: Float, wallLength: Float) -> DoorSwing {
        let toStart = offset
        let toEnd = wallLength - offset - width
        return DoorSwing(hingeAtStart: toStart <= toEnd, opensToNormalSide: true, source: .estimated)
    }

    /// Plan fixture of a detected object: footprint along the object's own x and z, yaw from
    /// its x axis.
    static func fixture(from object: DetectedObject) -> PlanFixture {
        let pose = planPose(of: object.transform)
        return PlanFixture(id: object.id, category: object.category, center: Vec2(pose.center),
                           size: Vec2(x: abs(object.dimensions.x), y: abs(object.dimensions.z)), yaw: pose.yaw,
                           isMovable: object.isMovable, isHidden: object.isHidden)
    }

    /// Plan center and yaw (radians counter-clockwise from plan +x) of a world pose.
    static func planPose(of transform: Transform4) -> (center: SIMD2<Float>, yaw: Float) {
        let m = transform.simd
        let axis = PlanAxes.toPlan(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let yaw: Float = simd_length(axis) > 1e-5 ? atan2(axis.y, axis.x) : 0
        return (PlanAxes.toPlan(transform.translation), yaw)
    }

    /// Stable identifier of the generated interior dimension of a wall.
    static func wallDimensionID(_ wall: ElementID) -> ElementID {
        mixed(wall.uuid, salt: 0x57)
    }

    /// Stable identifier of overall dimension `index` (0 or 1) of a room.
    static func overallDimensionID(_ room: ElementID, _ index: Int) -> ElementID {
        mixed(room.uuid, salt: UInt8(truncatingIfNeeded: 0x60 + index))
    }

    /// A deterministic identifier derived from `id` by mixing its bytes with a fixed mask.
    private static func mixed(_ id: UUID, salt: UInt8) -> ElementID {
        let mask: [UInt8] = [0x50, 0x4C, 0x41, 0x4E, 0x2D, 0x44, 0x49, 0x4D,
                             0x45, 0x4E, 0x53, 0x49, 0x4F, 0x4E, 0x2D, 0x31]
        var bytes = UUIDBytes.bytes(of: id)
        guard bytes.count == 16 else { return ElementID() }
        for i in 0..<16 { bytes[i] ^= mask[i] &+ salt }
        return ElementID(uuid: UUIDBytes.uuid(from: bytes) ?? UUID(), roomPlanID: nil)
    }
}

/// Room titles shown on the plan, in Results and in exports: the user name, else the
/// RoomPlan section label name, else "Room n". Names are never baked into the models.
enum RoomTitles {
    /// User name, else the RoomPlan section label name, else "Room n".
    /// `index` is the zero-based position of the room in its model; the default title counts
    /// from 1, so index 0 gives "Room 1".
    static func title(name: String, sectionLabel: String?, index: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let label = sectionLabel, let section = sectionName(label) { return section }
        return Copy.FloorPlan.defaultRoomTitle(max(0, index) + 1)
    }

    /// Display name of a RoomPlan section label raw value, nil for `unidentified` or unknown.
    static func sectionName(_ label: String) -> String? {
        switch label {
        case "livingRoom": return Copy.FloorPlan.sectionLivingRoom
        case "kitchen": return Copy.FloorPlan.sectionKitchen
        case "diningRoom": return Copy.FloorPlan.sectionDiningRoom
        case "bedroom": return Copy.FloorPlan.sectionBedroom
        case "bathroom": return Copy.FloorPlan.sectionBathroom
        default: return nil
        }
    }

    /// Titles of every room of a clean model, numbered by position in `model.rooms`.
    static func titles(for model: CleanModel) -> [ElementID: String] {
        var result: [ElementID: String] = [:]
        for (index, room) in model.rooms.enumerated() {
            result[room.id] = title(name: room.name, sectionLabel: room.sectionLabel, index: index)
        }
        return result
    }

    /// Titles of every room of a (possibly edited) plan: the plan room name wins (it carries
    /// renames), then the section label of the clean room with the same id; numbering follows
    /// the clean model order, else the plan order.
    static func titles(for plan: PlanModel, clean: CleanModel?) -> [ElementID: String] {
        var labels: [ElementID: String] = [:]
        var order: [ElementID: Int] = [:]
        for (index, room) in (clean?.rooms ?? []).enumerated() {
            if let label = room.sectionLabel { labels[room.id] = label }
            order[room.id] = index
        }
        var result: [ElementID: String] = [:]
        var running = 0
        for level in plan.levels {
            for room in level.rooms {
                result[room.id] = title(name: room.name, sectionLabel: labels[room.id], index: order[room.id] ?? running)
                running += 1
            }
        }
        return result
    }
}
