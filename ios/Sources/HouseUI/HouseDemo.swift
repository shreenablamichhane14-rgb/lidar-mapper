import Foundation
import simd

// Demo Mode houses (docs/MODULES.md 3.41, D1): every demo room is ScanUI's synthetic 4 x 5 m
// room, so the house flow places each new one to the +x side of the rooms already on its floor
// with a 0.12 m wall gap, gives its elements identifiers of its own, and writes the combined
// clean model (with Structure's shared walls and thickness rules) and plan. No camera, ARKit or
// processing is involved: the demo project stays `.ready`. Stateless; file IO runs off main.

/// Demo Mode helpers of the house flow.
enum HouseDemo {
    /// Gap between two neighboring demo rooms' walls, meters (one shared wall of that thickness).
    static let sharedWallGap: Float = 0.12

    /// Translation that places `room` to the +x side of `placed` with a 0.12 m wall gap: the
    /// room's west edge goes `sharedWallGap` east of the east edge of `placed`, their south
    /// edges lined up (plan meters). Identity (no rotation, no move) when `placed` is empty.
    static func offset(for room: CleanRoom, after placed: [CleanRoom]) -> RoomAlignmentRecord {
        guard let existing = planBounds(placed), let own = planBounds([room]) else {
            return StructureAlignment.identity(roomID: room.recordID, source: .estimated)
        }
        let dx: Float = existing.upper.x + sharedWallGap - own.lower.x
        let dy: Float = existing.lower.y - own.lower.y
        return RoomAlignmentRecord(roomID: room.recordID, yaw: 0, translation: Vec3(x: dx, y: 0, z: -dy),
                                   source: .estimated)
    }

    /// Writes the demo house: `CleanModel` of the moved demo rooms with Structure's
    /// `sharedWalls` and `applyThickness` applied, `CleanModelStore.save`, then
    /// `PlanBuilder.build(from:floors:)` and `PlanModelStore.save`, then the plan thumbnail (best
    /// effort, ScanUI's demo writer). Call off the main thread.
    static func write(_ rooms: [CleanRoom], manifest: ProjectManifest, package: ProjectPackage) throws {
        var model = CleanModel(rooms: rooms, sourceIsStructure: false, stamp: nil)
        let pairs = StructureWalls.sharedWalls(in: model)
        StructureWalls.applyThickness(pairs, exteriorThickness: CleanBuildOptions().exteriorThickness, to: &model)
        try CleanModelStore.save(model, to: package)
        let plan = PlanBuilder.build(from: model, floors: manifest.floors)
        try PlanModelStore.save(plan, to: package)
        DemoProjectFactory.writeThumbnail(plan: plan, clean: model, package: package)
        LogStore.shared.write("demo house written: \(rooms.count) rooms, \(pairs.count) shared walls",
                              category: HouseRelocalization.logCategory)
    }

    /// The demo room moved into the house: fresh element identifiers (every demo room is built
    /// from the same synthetic input), its user name and floor, then `offset` after the rooms of
    /// `placed` on the same floor.
    static func placed(_ room: CleanRoom, name: String, floorIndex: Int, after placed: [CleanRoom]) -> CleanRoom {
        var fresh = reidentified(room)
        fresh.name = name
        fresh.floorIndex = floorIndex
        let neighbors = placed.filter { $0.floorIndex == floorIndex && $0.recordID != room.recordID }
        return StructureAlignment.apply(offset(for: fresh, after: neighbors), to: fresh)
    }

    /// The room with every element identifier (room, walls, openings and their wall links,
    /// objects) mixed with its record id, so two demo rooms never share an identifier.
    /// Deterministic; RoomPlan provenance ids are kept.
    static func reidentified(_ room: CleanRoom) -> CleanRoom {
        let key = UUIDBytes.bytes(of: room.recordID)
        /// The element id mixed with the record id.
        func remap(_ id: ElementID) -> ElementID {
            let bytes = UUIDBytes.bytes(of: id.uuid)
            var mixed = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { mixed[i] = bytes[i] ^ key[i] }
            return ElementID(uuid: UUIDBytes.uuid(from: mixed) ?? id.uuid, roomPlanID: id.roomPlanID)
        }
        var copy = room
        copy.id = remap(room.id)
        copy.walls = room.walls.map { wall -> CleanWall in
            var moved = wall
            moved.id = remap(wall.id)
            return moved
        }
        copy.openings = room.openings.map { opening -> CleanOpening in
            var moved = opening
            moved.id = remap(opening.id)
            if let wall = opening.wallID { moved.wallID = remap(wall) }
            return moved
        }
        copy.objects = room.objects.map { object -> DetectedObject in
            var moved = object
            moved.id = remap(object.id)
            return moved
        }
        return copy
    }

    /// Bounding box of the rooms' floor outlines and wall ends in plan meters; nil when empty.
    static func planBounds(_ rooms: [CleanRoom]) -> (lower: SIMD2<Float>, upper: SIMD2<Float>)? {
        var points: [SIMD2<Float>] = []
        for room in rooms {
            points.append(contentsOf: room.floor.outline.map { $0.simd })
            for wall in room.walls {
                points.append(PlanAxes.toPlan(wall.start.simd))
                points.append(PlanAxes.toPlan(wall.end.simd))
            }
        }
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard var lower = finite.first else { return nil }
        var upper = lower
        for point in finite {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        return (lower: lower, upper: upper)
    }
}
