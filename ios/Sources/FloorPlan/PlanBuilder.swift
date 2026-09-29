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
    /// (3.37c) Walls are copied with a = start and b = end; opening offsets and swings unchanged,
    /// so edits address the same wall end in the clean model and the plan (the `CleanWall`
    /// orientation invariant). A clean wall whose normal points to the right of start -> end
    /// (data older than the RoomModel revision) is kept as is and counted in one log line per
    /// build; it is not reversed. A room's merged outlines are copied, and its overall
    /// dimensions enclose every part. Openings without a host wall cannot be placed and are
    /// left out.
    static func build(from model: CleanModel, floors: [FloorRecord]) -> PlanModel {
        var indices = Set(floors.map { $0.id })
        for room in model.rooms { indices.insert(room.floorIndex) }
        var levels: [PlanLevel] = []
        var rightNormals = 0
        for index in indices.sorted() {
            let record = floors.first { $0.id == index }
            let rooms = model.rooms.filter { $0.floorIndex == index }
            let lowest = rooms.map { $0.floor.elevation }.min() ?? 0
            var level = PlanLevel(id: index, name: record?.name ?? "", elevation: record?.elevation ?? lowest,
                                  rooms: [], walls: [], openings: [], fixtures: [], annotations: [], dimensions: [])
            for room in rooms { rightNormals += add(room, to: &level) }
            levels.append(level)
        }
        if rightNormals > 0 {
            LogStore.shared.write("planBuilder: \(rightNormals) walls with the normal on the right kept as stored "
                                  + "(clean model older than cleanModel-rules=2)", category: "floorplan")
        }
        return PlanModel(levels: levels, northAngle: 0, stamp: nil)
    }

    /// Sum of the polygon areas of `outline` and every merged outline, square meters.
    static func totalArea(_ room: PlanRoom) -> Float {
        var total = Polygon2D(points: room.outline.map { $0.simd }).area
        for part in room.mergedOutlines ?? [] {
            total += Polygon2D(points: part.map { $0.simd }).area
        }
        return total
    }

    /// Every part of a plan room (`outline` first, then the merged outlines), plan meters.
    static func parts(of room: PlanRoom) -> [[SIMD2<Float>]] {
        var result = [room.outline.map { $0.simd }]
        for part in room.mergedOutlines ?? [] {
            result.append(part.map { $0.simd })
        }
        return result
    }

    /// Adds one clean room (outline, walls, openings, fixtures and dimensions) to a level.
    /// Returns the number of its walls whose normal points to the right of start -> end.
    private static func add(_ room: CleanRoom, to level: inout PlanLevel) -> Int {
        let outline = roomOutline(room)
        let labelPoint = interiorPoint(of: outline)
        let merged = mergedOutlines(room)
        var planRoom = PlanRoom(id: room.id, name: room.name, outline: outline.map { Vec2($0) },
                                labelAt: Vec2(labelPoint), area: 0)
        planRoom.mergedOutlines = merged.isEmpty ? nil : merged.map { part in part.map { Vec2($0) } }
        planRoom.area = room.metrics.floorArea > 0 ? room.metrics.floorArea : totalArea(planRoom)
        level.rooms.append(planRoom)

        var rightNormals = 0
        var lengths: [ElementID: Float] = [:]
        for wall in room.walls {
            let a = PlanAxes.toPlan(wall.start.simd)
            let b = PlanAxes.toPlan(wall.end.simd)
            let length = simd_distance(a, b)
            if normalPointsRight(a: a, b: b, wallNormal: wall.normal.simd) { rightNormals += 1 }
            lengths[wall.id] = length
            level.walls.append(PlanWall(id: wall.id, a: Vec2(a), b: Vec2(b), thickness: max(0, wall.thickness),
                                        thicknessSource: wall.thicknessSource, arc: wall.arc,
                                        provenance: wall.provenance, occludedSpans: wall.occludedSpans))
            if length > 0.01 {
                level.dimensions.append(PlanDimension(id: wallDimensionID(wall.id), a: Vec2(a), b: Vec2(b),
                                                      offset: wallDimensionOffset, isUser: false))
            }
        }

        for opening in room.openings {
            guard let wallID = opening.wallID, let length = lengths[wallID] else { continue }
            let width = min(max(opening.width, 0), length)
            let offset = min(max(opening.offsetAlongWall, 0), max(0, length - width))
            var swing = opening.swing
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
        let thickness = room.walls.map { max(0, $0.thickness) }.max() ?? 0
        let points = outline + merged.flatMap { $0 }
        level.dimensions.append(contentsOf: overallDimensions(roomID: room.id, points: points,
                                                              offset: overallOffset(thickness: thickness)))
        return rightNormals
    }

    /// The merged outlines of a clean room in plan coordinates, each counter-clockwise without
    /// a closing duplicate; parts with fewer than 3 points are left out.
    static func mergedOutlines(_ room: CleanRoom) -> [[SIMD2<Float>]] {
        var result: [[SIMD2<Float>]] = []
        for part in room.floor.mergedOutlines ?? [] {
            let ring = normalizedRing(part.map { $0.simd })
            if ring.count >= 3 { result.append(ring) }
        }
        return result
    }

    /// A ring without a closing duplicate, counter-clockwise.
    static func normalizedRing(_ input: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var points = input
        if points.count >= 2, let first = points.first, let last = points.last, simd_distance(first, last) < 1e-5 {
            points.removeLast()
        }
        if Polygon2D(points: points).signedArea < 0 { points.reverse() }
        return points
    }

    /// Offset of a room's overall dimensions: outside the room (negative, the room is on the
    /// left of both dimension lines) beyond its thickest wall.
    static func overallOffset(thickness: Float) -> Float {
        -((thickness.isFinite ? max(0, thickness) : 0) + overallDimensionGap)
    }

    /// Two overall dimensions along the sides of the minimum-area rectangle of `points` (every
    /// part of a room), with the stable identifiers of `roomID`; empty for a thin rectangle.
    static func overallDimensions(roomID: ElementID, points: [SIMD2<Float>], offset: Float) -> [PlanDimension] {
        guard let rect = Rectangle2D.minimumArea(enclosing: points),
              rect.halfExtents.x > minimumOverallHalfExtent, rect.halfExtents.y > minimumOverallHalfExtent
        else { return [] }
        let u = rect.axis
        let v = SIMD2<Float>(-u.y, u.x)
        let hx = rect.halfExtents.x
        let hy = rect.halfExtents.y
        // The room lies on the left of both sides below, so a negative offset is outside.
        let p0 = rect.center - u * hx - v * hy
        let p1 = rect.center + u * hx - v * hy
        let p2 = rect.center + u * hx + v * hy
        return [PlanDimension(id: overallDimensionID(roomID, 0), a: Vec2(p0), b: Vec2(p1), offset: offset, isUser: false),
                PlanDimension(id: overallDimensionID(roomID, 1), a: Vec2(p1), b: Vec2(p2), offset: offset, isUser: false)]
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

    /// True when the clean wall normal (into the room) points to the right of a->b, measurably
    /// (data older than the RoomModel revision 3.37b). Such walls are counted, never reversed.
    static func normalPointsRight(a: SIMD2<Float>, b: SIMD2<Float>, wallNormal: SIMD3<Float>) -> Bool {
        let d = b - a
        let left = SIMD2<Float>(-d.y, d.x)
        let byNormal = simd_dot(left, PlanAxes.toPlan(wallNormal))
        return byNormal < -1e-3 * simd_length(d)
    }

    /// True when the room is on the left of a->b: decided by the clean wall normal (into the
    /// room), or by the side of the room label point when the normal is unusable. Kept for
    /// callers; the builder no longer reverses walls (3.37c).
    static func roomIsOnLeft(a: SIMD2<Float>, b: SIMD2<Float>, wallNormal: SIMD3<Float>, labelPoint: SIMD2<Float>) -> Bool {
        let d = b - a
        let left = SIMD2<Float>(-d.y, d.x)
        let byNormal = simd_dot(left, PlanAxes.toPlan(wallNormal))
        if abs(byNormal) > 1e-3 * simd_length(d) { return byNormal > 0 }
        return simd_dot(left, labelPoint - (a + b) * 0.5) >= 0
    }

    /// Occluded spans measured from the other end of a wall of `length` (kept for callers; the
    /// builder no longer mirrors spans since 3.37c).
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
