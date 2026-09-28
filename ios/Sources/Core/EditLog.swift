import Foundation

/// One user edit (D3, D21). Operations reference elements by `ElementID` so they survive
/// re-derivation; plan-space values use `PlanAxes` coordinates.
enum EditOperation: Codable, Equatable, Sendable {
    /// Rename a room.
    case renameRoom(room: ElementID, name: String)
    /// Change an object's label.
    case relabelObject(object: ElementID, label: String)
    /// Change an object's category.
    case recategorizeObject(object: ElementID, category: ObjectCategory)
    /// Hide or show an element.
    case setHidden(element: ElementID, hidden: Bool)
    /// Delete an element from the clean model and the plan (raw is untouched).
    case deleteElement(element: ElementID)
    /// Move an object to a new world pose.
    case moveObject(object: ElementID, transform: Transform4)
    /// Move one end of a wall to a plan point.
    case moveWallEndpoint(wall: ElementID, atStart: Bool, to: Vec2)
    /// Add a user-drawn wall on a level.
    case addWall(wall: PlanWall, level: Int)
    /// Add a door, window or opening on a level.
    case addOpening(opening: PlanOpening, level: Int)
    /// Set a door's swing.
    case setDoorSwing(door: ElementID, swing: DoorSwing)
    /// Set a wall's thickness, meters.
    case setWallThickness(wall: ElementID, thickness: Float)
    /// Add an annotation on a level.
    case addAnnotation(annotation: PlanAnnotation, level: Int)
    /// Add a dimension line on a level.
    case addDimension(dimension: PlanDimension, level: Int)
    /// Scale a room's derived measurements by `factor` (reference length, D21).
    case setScaleCorrection(room: ElementID, factor: Float)
    /// Place a room manually in the structure frame (D9).
    case setRoomAlignment(RoomAlignmentRecord)
    /// Crop a large object's mesh to a box (D4).
    case cropObject(object: ElementID, box: OrientedBoxRecord)

    /// Elements this operation needs; when one is missing after re-derivation the
    /// operation is orphaned. Additions return the new element.
    var targets: [ElementID] {
        switch self {
        case .renameRoom(let id, _), .relabelObject(let id, _), .recategorizeObject(let id, _),
             .setHidden(let id, _), .deleteElement(let id), .moveObject(let id, _),
             .moveWallEndpoint(let id, _, _), .setDoorSwing(let id, _), .setWallThickness(let id, _),
             .setScaleCorrection(let id, _), .cropObject(let id, _):
            return [id]
        case .addWall(let wall, _):
            return [wall.id]
        case .addOpening(let opening, _):
            return [opening.id, opening.wallID]
        case .addAnnotation(let annotation, _):
            return [annotation.id]
        case .addDimension(let dimension, _):
            return [dimension.id]
        case .setRoomAlignment(let record):
            return [ElementID(uuid: record.roomID)]
        }
    }
}

/// Manual or computed rigid placement of a room in the structure frame (D9): rotate by
/// `yaw` about +Y, then translate.
struct RoomAlignmentRecord: Codable, Equatable, Sendable {
    /// Our `RoomRecord.id`.
    var roomID: UUID
    /// Rotation about world +Y, radians.
    var yaw: Float
    /// Translation, meters.
    var translation: Vec3
    /// `.measured` from the structure merge, `.user` when placed by hand.
    var source: Provenance
}

/// Contents of `edits/editlog.json`: the ordered edit operations plus an undo cursor.
/// Operations before `cursor` are active; those at and after it are the redo tail.
struct EditLog: Codable, Equatable, Sendable {
    /// All operations, including undone ones in the redo tail.
    private(set) var operations: [EditOperation]
    /// Number of active operations.
    private(set) var cursor: Int
    /// Increases on every change; part of the input hash of steps that read edits (D11).
    private(set) var revision: Int

    /// An empty log.
    init() {
        operations = []
        cursor = 0
        revision = 0
    }

    /// `cursor` clamped to the valid range (guards against a hand-edited file).
    private var safeCursor: Int { Swift.max(0, Swift.min(cursor, operations.count)) }

    /// The operations in effect, in order.
    var active: ArraySlice<EditOperation> { operations.prefix(safeCursor) }

    /// True when there is an operation to undo.
    var canUndo: Bool { safeCursor > 0 }

    /// True when there is an undone operation to redo.
    var canRedo: Bool { safeCursor < operations.count }

    /// Adds an operation after the active ones, discarding the redo tail.
    mutating func append(_ op: EditOperation) {
        operations.removeSubrange(safeCursor..<operations.count)
        operations.append(op)
        cursor = operations.count
        revision += 1
    }

    /// Deactivates the last active operation. Returns false when there is none.
    @discardableResult
    mutating func undo() -> Bool {
        guard canUndo else { return false }
        cursor = safeCursor - 1
        revision += 1
        return true
    }

    /// Reactivates the first undone operation. Returns false when there is none.
    @discardableResult
    mutating func redo() -> Bool {
        guard canRedo else { return false }
        cursor = safeCursor + 1
        revision += 1
        return true
    }
}

/// A model that edit operations can be applied to. CleanModel and PlanModel conform in
/// their own modules (RoomModel, FloorPlan); Core only defines the contract.
protocol EditApplicable {
    /// Applies one operation. Returns false only when a target is missing (orphaned), and
    /// then leaves the model unchanged. Operations that do not concern this model return
    /// true without changing it.
    mutating func apply(_ op: EditOperation) -> Bool
}

extension EditLog {
    /// Replays the active operations on a copy of `base`. Returns the edited model and the
    /// operations that could not be applied (listed to the user as orphaned, D3).
    func applied<T: EditApplicable>(to base: T) -> (T, orphaned: [EditOperation]) {
        var model = base
        var orphaned: [EditOperation] = []
        for op in active {
            if !model.apply(op) { orphaned.append(op) }
        }
        return (model, orphaned: orphaned)
    }
}
