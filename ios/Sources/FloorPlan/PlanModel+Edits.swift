import Foundation
import simd

/// Edit replay on the plan (D3). Operations reference elements by `ElementID`; an operation
/// whose target is missing returns false and leaves the plan unchanged (orphaned), and an
/// operation meant for another model returns true unchanged.
extension PlanModel: EditApplicable {
    /// Room outline vertices closer than this to a moved wall end move with it, meters.
    static let outlineFollowTolerance: Float = 0.02

    /// Applies one operation. Plan operations: renameRoom, setHidden (fixtures), deleteElement,
    /// moveWallEndpoint, addWall, addOpening, setDoorSwing, setWallThickness, addAnnotation,
    /// addDimension, recategorizeObject (fixture category) and moveObject (fixture center and
    /// yaw from the transform). After a wall end moves, the wall's generated dimension follows
    /// its endpoints and room outline corners at the old end move too (area recomputed).
    mutating func apply(_ op: EditOperation) -> Bool {
        switch op {
        case .renameRoom(let room, let name):
            return updateRoom(room) { $0.name = name }
        case .recategorizeObject(let object, let category):
            return updateFixture(object) {
                $0.category = category
                $0.isMovable = category.isMovable
            }
        case .setHidden(let element, let hidden):
            if updateFixture(element, { $0.isHidden = hidden }) { return true }
            return contains(element)
        case .deleteElement(let element):
            return delete(element)
        case .moveObject(let object, let transform):
            let pose = PlanBuilder.planPose(of: transform)
            return updateFixture(object) {
                $0.center = Vec2(pose.center)
                $0.yaw = pose.yaw
            }
        case .moveWallEndpoint(let wall, let atStart, let point):
            return moveWallEndpoint(wall, atStart: atStart, to: point)
        case .addWall(let wall, let level):
            return addWall(wall, level: level)
        case .addOpening(let opening, let level):
            guard let li = levelIndex(level),
                  levels[li].walls.contains(where: { $0.id == opening.wallID }) else { return false }
            levels[li].openings.removeAll { $0.id == opening.id }
            levels[li].openings.append(opening)
            return true
        case .setDoorSwing(let door, let swing):
            return updateOpening(door) { $0.swing = swing }
        case .setWallThickness(let wall, let thickness):
            guard thickness.isFinite else { return contains(wall) }
            return updateWall(wall) {
                $0.thickness = max(0, thickness)
                $0.thicknessSource = .user
            }
        case .addAnnotation(let annotation, let level):
            guard let li = levelIndex(level) else { return false }
            levels[li].annotations.removeAll { $0.id == annotation.id }
            levels[li].annotations.append(annotation)
            return true
        case .addDimension(let dimension, let level):
            guard let li = levelIndex(level) else { return false }
            levels[li].dimensions.removeAll { $0.id == dimension.id }
            levels[li].dimensions.append(dimension)
            return true
        case .relabelObject, .setScaleCorrection, .setRoomAlignment, .cropObject:
            return true
        case .moveOpening, .resizeOpening, .mergeRooms, .splitRoom, .batch:
            // CR-1 stubs (pre-5a Core commit): no behavior until the FloorPlan revision (3.37c).
            return true
        }
    }

    /// Index of the level with floor index `id`.
    private func levelIndex(_ id: Int) -> Int? {
        levels.firstIndex { $0.id == id }
    }

    /// True when any element of any level has this identifier.
    func contains(_ element: ElementID) -> Bool {
        for level in levels {
            if level.rooms.contains(where: { $0.id == element })
                || level.walls.contains(where: { $0.id == element })
                || level.openings.contains(where: { $0.id == element })
                || level.fixtures.contains(where: { $0.id == element })
                || level.annotations.contains(where: { $0.id == element })
                || level.dimensions.contains(where: { $0.id == element }) {
                return true
            }
        }
        return false
    }

    /// Applies `change` to the room with this id; false when there is none.
    private mutating func updateRoom(_ id: ElementID, _ change: (inout PlanRoom) -> Void) -> Bool {
        for li in levels.indices {
            if let ri = levels[li].rooms.firstIndex(where: { $0.id == id }) {
                change(&levels[li].rooms[ri])
                return true
            }
        }
        return false
    }

    /// Applies `change` to the fixture with this id; false when there is none.
    private mutating func updateFixture(_ id: ElementID, _ change: (inout PlanFixture) -> Void) -> Bool {
        for li in levels.indices {
            if let fi = levels[li].fixtures.firstIndex(where: { $0.id == id }) {
                change(&levels[li].fixtures[fi])
                return true
            }
        }
        return false
    }

    /// Applies `change` to the wall with this id; false when there is none.
    private mutating func updateWall(_ id: ElementID, _ change: (inout PlanWall) -> Void) -> Bool {
        for li in levels.indices {
            if let wi = levels[li].walls.firstIndex(where: { $0.id == id }) {
                change(&levels[li].walls[wi])
                return true
            }
        }
        return false
    }

    /// Applies `change` to the opening with this id; false when there is none.
    private mutating func updateOpening(_ id: ElementID, _ change: (inout PlanOpening) -> Void) -> Bool {
        for li in levels.indices {
            if let oi = levels[li].openings.firstIndex(where: { $0.id == id }) {
                change(&levels[li].openings[oi])
                return true
            }
        }
        return false
    }

    /// Removes the element with this id. Deleting a wall also removes its openings and its
    /// generated dimension. False when nothing has this id.
    private mutating func delete(_ id: ElementID) -> Bool {
        for li in levels.indices {
            var level = levels[li]
            if level.walls.contains(where: { $0.id == id }) {
                level.walls.removeAll { $0.id == id }
                level.openings.removeAll { $0.wallID == id }
                let dimensionID = PlanBuilder.wallDimensionID(id)
                level.dimensions.removeAll { $0.id == dimensionID }
                levels[li] = level
                return true
            }
            let before = level.rooms.count + level.openings.count + level.fixtures.count
                + level.annotations.count + level.dimensions.count
            level.rooms.removeAll { $0.id == id }
            level.openings.removeAll { $0.id == id }
            level.fixtures.removeAll { $0.id == id }
            level.annotations.removeAll { $0.id == id }
            level.dimensions.removeAll { $0.id == id }
            let after = level.rooms.count + level.openings.count + level.fixtures.count
                + level.annotations.count + level.dimensions.count
            if after != before {
                levels[li] = level
                return true
            }
        }
        return false
    }

    /// Moves one end of a wall. The wall's generated dimension follows its endpoints, and room
    /// outline corners at the old end move with it (the room area is recomputed).
    private mutating func moveWallEndpoint(_ id: ElementID, atStart: Bool, to point: Vec2) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return contains(id) }
        for li in levels.indices {
            guard let wi = levels[li].walls.firstIndex(where: { $0.id == id }) else { continue }
            var level = levels[li]
            let old = atStart ? level.walls[wi].a : level.walls[wi].b
            if atStart {
                level.walls[wi].a = point
            } else {
                level.walls[wi].b = point
            }
            let wall = level.walls[wi]
            let dimensionID = PlanBuilder.wallDimensionID(id)
            if let di = level.dimensions.firstIndex(where: { $0.id == dimensionID }) {
                level.dimensions[di].a = wall.a
                level.dimensions[di].b = wall.b
            }
            let length = simd_distance(wall.a.simd, wall.b.simd)
            for oi in level.openings.indices where level.openings[oi].wallID == id {
                let width = min(level.openings[oi].width, length)
                level.openings[oi].width = width
                level.openings[oi].offset = min(max(level.openings[oi].offset, 0), max(0, length - width))
            }
            for ri in level.rooms.indices {
                var moved = false
                for pi in level.rooms[ri].outline.indices
                where simd_distance(level.rooms[ri].outline[pi].simd, old.simd) <= PlanModel.outlineFollowTolerance {
                    level.rooms[ri].outline[pi] = point
                    moved = true
                }
                if moved {
                    let outline = level.rooms[ri].outline.map { $0.simd }
                    level.rooms[ri].area = Polygon2D(points: outline).area
                    level.rooms[ri].labelAt = Vec2(PlanBuilder.interiorPoint(of: outline))
                }
            }
            levels[li] = level
            return true
        }
        return false
    }

    /// Adds a user wall (replacing one with the same id) and its generated dimension. False
    /// when the level does not exist.
    private mutating func addWall(_ wall: PlanWall, level: Int) -> Bool {
        guard let li = levelIndex(level) else { return false }
        levels[li].walls.removeAll { $0.id == wall.id }
        levels[li].walls.append(wall)
        let dimensionID = PlanBuilder.wallDimensionID(wall.id)
        levels[li].dimensions.removeAll { $0.id == dimensionID }
        if simd_distance(wall.a.simd, wall.b.simd) > 0.01 {
            levels[li].dimensions.append(PlanDimension(id: dimensionID, a: wall.a, b: wall.b,
                                                       offset: PlanBuilder.wallDimensionOffset, isUser: false))
        }
        return true
    }
}

/// Loads and saves `derived/plan.json` (the base plan, before edits) and replays the edit
/// log on it. Safe to call from any thread.
enum PlanModelStore {
    /// The base plan written by `FloorPlanStep`. Throws `CoreError.missingFile` when absent.
    static func loadBase(_ package: ProjectPackage) throws -> PlanModel {
        try ProjectStore.readJSON(PlanModel.self, from: package.planModelURL)
    }

    /// The base plan with the active operations of `edits/editlog.json` applied (a missing log
    /// means no edits), plus the operations that could not be applied (orphaned, D3).
    static func loadEdited(_ package: ProjectPackage) throws -> (plan: PlanModel, orphaned: [EditOperation]) {
        let base = try loadBase(package)
        let log = try editLog(package)
        let replayed = log.applied(to: base)
        return (plan: replayed.0, orphaned: replayed.orphaned)
    }

    /// The edit log of the package, or an empty log when the file does not exist.
    static func editLog(_ package: ProjectPackage) throws -> EditLog {
        guard FileManager.default.fileExists(atPath: package.editLogURL.path) else { return EditLog() }
        return try ProjectStore.readJSON(EditLog.self, from: package.editLogURL)
    }

    /// Writes `derived/plan.json` atomically. The derived folder is created only while the
    /// package exists, so a late write after a delete fails instead of recreating it (CR-6).
    static func save(_ plan: PlanModel, to package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedURL, inside: package.root)
        try ProjectStore.writeJSON(plan, to: package.planModelURL, createParents: false)
    }
}
