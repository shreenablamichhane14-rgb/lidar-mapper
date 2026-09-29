import Foundation
import simd

/// Door swings, fixture poses, Reset to Scan, locked walls and log names of the plan editor
/// mapping (docs/MODULES.md 3.37). Pure and safe on any thread.
extension PlanEditorOps {
    /// Plan ends farther than this from the clean wall start lock a wall, meters.
    static let lockDistance: Float = 0.01

    /// Flip Door Swing cycle on (hingeAtStart, opensToNormalSide): (true, true) -> (true, false) ->
    /// (false, false) -> (false, true) -> (true, true); source `.user`. A nil swing starts from
    /// `PlanBuilder.defaultSwing(offset:width:wallLength:)`.
    static func nextSwing(_ swing: DoorSwing?, offset: Float, width: Float, wallLength: Float) -> DoorSwing {
        let current = swing ?? PlanBuilder.defaultSwing(offset: offset, width: width, wallLength: wallLength)
        let hinge: Bool
        let opens: Bool
        switch (current.hingeAtStart, current.opensToNormalSide) {
        case (true, true):
            hinge = true
            opens = false
        case (true, false):
            hinge = false
            opens = false
        case (false, false):
            hinge = false
            opens = true
        case (false, true):
            hinge = true
            opens = true
        }
        return DoorSwing(hingeAtStart: hinge, opensToNormalSide: opens, source: .user)
    }

    /// moveFixture's world pose: the clean object's transform turned about world +Y by (yaw - its plan
    /// yaw from `PlanBuilder.planPose(of:)`), its translation moved to `center` at its own height.
    /// A turn about +Y by an angle turns the plan counter-clockwise by the same angle
    /// (`PlanAxes`: plan y = -world z), so the plan pose of the result is (`center`, `yaw`).
    static func objectTransform(_ object: DetectedObject, center: Vec2, yaw: Float) -> Transform4 {
        let pose = PlanBuilder.planPose(of: object.transform)
        let delta = yaw - pose.yaw
        let c = cos(delta)
        let s = sin(delta)
        let turn = simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                           SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1)))
        var matrix = simd_mul(turn, object.transform.simd)
        let world = PlanAxes.toWorld(center.simd, y: object.transform.translation.y)
        matrix.columns.3 = SIMD4<Float>(world.x, world.y, world.z, 1)
        return Transform4(matrix)
    }

    /// True for operations Reset to Scan removes: every case except relabelObject, recategorizeObject,
    /// setScaleCorrection, setRoomAlignment and cropObject (label and category corrections, including
    /// Results' Change Category, are not floor plan geometry and survive a reset); a batch when any of
    /// its operations is.
    static func isPlanEdit(_ op: EditOperation) -> Bool {
        switch op {
        case .relabelObject, .recategorizeObject, .setScaleCorrection, .setRoomAlignment, .cropObject:
            return false
        case .renameRoom, .setHidden, .deleteElement, .moveObject, .moveWallEndpoint, .addWall, .addOpening,
             .setDoorSwing, .setWallThickness, .addAnnotation, .addDimension, .moveOpening, .resizeOpening,
             .mergeRooms, .splitRoom:
            return true
        case .batch(let operations):
            return operations.contains { isPlanEdit($0) }
        }
    }

    /// Walls present in both models whose plan `a` is more than 1 cm from the clean `start` in plan.
    static func lockedWalls(plan: PlanModel, clean: CleanModel?) -> Set<ElementID> {
        guard let clean else { return [] }
        var starts: [ElementID: SIMD2<Float>] = [:]
        for room in clean.rooms {
            for wall in room.walls {
                starts[wall.id] = PlanAxes.toPlan(wall.start.simd)
            }
        }
        var locked = Set<ElementID>()
        for level in plan.levels {
            for wall in level.walls {
                guard let start = starts[wall.id] else { continue }
                let distance = simd_distance(start, wall.a.simd)
                if !(distance <= lockDistance) { locked.insert(wall.id) }
            }
        }
        return locked
    }

    /// True when the clean model has no element an operation needs, because the operation only
    /// concerns the plan: deleting an annotation or a dimension (the clean model has neither and
    /// reports the deletion as orphaned; see the RoomModel change request in the PlanEditor
    /// report). Such an operation is validated against the plan alone.
    static func isPlanOnly(_ op: EditOperation, clean: CleanModel) -> Bool {
        guard case .deleteElement(let id) = op else { return false }
        for room in clean.rooms {
            if room.id == id || room.walls.contains(where: { $0.id == id }) { return false }
            if room.openings.contains(where: { $0.id == id }) || room.objects.contains(where: { $0.id == id }) {
                return false
            }
        }
        return true
    }

    /// Stable name of an operation kind for the log (a batch lists its operations' kinds).
    static func kindName(_ op: EditOperation) -> String {
        switch op {
        case .renameRoom: return "renameRoom"
        case .relabelObject: return "relabelObject"
        case .recategorizeObject: return "recategorizeObject"
        case .setHidden: return "setHidden"
        case .deleteElement: return "deleteElement"
        case .moveObject: return "moveObject"
        case .moveWallEndpoint: return "moveWallEndpoint"
        case .addWall: return "addWall"
        case .addOpening: return "addOpening"
        case .setDoorSwing: return "setDoorSwing"
        case .setWallThickness: return "setWallThickness"
        case .addAnnotation: return "addAnnotation"
        case .addDimension: return "addDimension"
        case .setScaleCorrection: return "setScaleCorrection"
        case .setRoomAlignment: return "setRoomAlignment"
        case .cropObject: return "cropObject"
        case .moveOpening: return "moveOpening"
        case .resizeOpening: return "resizeOpening"
        case .mergeRooms: return "mergeRooms"
        case .splitRoom: return "splitRoom"
        case .batch(let operations):
            return "batch[" + operations.map { kindName($0) }.joined(separator: ",") + "]"
        }
    }

    /// Stable name of an action for the log.
    static func actionName(_ action: PlanEditAction) -> String {
        switch action {
        case .moveWall: return "moveWall"
        case .moveWallEnd: return "moveWallEnd"
        case .setWallLength: return "setWallLength"
        case .setWallThickness: return "setWallThickness"
        case .addWall: return "addWall"
        case .deleteWall: return "deleteWall"
        case .addOpening: return "addOpening"
        case .moveOpening: return "moveOpening"
        case .resizeOpening: return "resizeOpening"
        case .flipDoorSwing: return "flipDoorSwing"
        case .renameRoom: return "renameRoom"
        case .mergeRooms: return "mergeRooms"
        case .splitRoom: return "splitRoom"
        case .addDimension: return "addDimension"
        case .setAnnotation: return "setAnnotation"
        case .moveFixture: return "moveFixture"
        case .deleteFixture: return "deleteFixture"
        case .recategorizeFixture: return "recategorizeFixture"
        case .deleteElement: return "deleteElement"
        }
    }

    /// One log line for a performed action: the action, the operation kinds and the element ids
    /// (first 8 characters of each).
    static func logLine(_ action: PlanEditAction, op: EditOperation) -> String {
        let ids = op.targets.map { String($0.uuid.uuidString.prefix(8)) }.joined(separator: ",")
        return "\(actionName(action)): \(kindName(op)) [\(ids)]"
    }
}
