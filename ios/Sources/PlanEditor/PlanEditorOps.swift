import Foundation
import simd

/// What a tap on the canvas does.
enum PlanEditTool: Equatable, Sendable {
    case select
    case addWall
    /// Add Door, Add Window, Add Opening: a tap on a wall places it there.
    case addOpening(OpeningKind)
    case addDimension
    /// Add Text, Add Symbol, Add Note: a tap sets the point, then a prompt asks for the text or symbol.
    case addAnnotation(AnnotationKind)
    /// Two taps draw the cut line across this room.
    case splitRoom(ElementID)
    /// Taps toggle the rooms to join into this one; Merge Rooms commits.
    case mergeRooms(into: ElementID)
}

/// One user edit. `PlanEditorOps` maps it to operations; ids of new elements are made by the model
/// (`ElementID()`) before the action exists, so an action always maps to the same operations.
enum PlanEditAction: Equatable, Sendable {
    /// Move Wall: slide along the wall's left normal (into its room is positive), meters. Walls joined at
    /// its ends end on the moved line (intersection with their own lines); an antiparallel paired wall
    /// (the next room's face of a shared wall) moves by the same translation.
    case moveWall(ElementID, by: Float)
    /// Drag one wall end: every wall end joined there moves to `to`.
    case moveWallEnd(ElementID, atStart: Bool, to: Vec2)
    /// Wall Length: keeps `a`, moves `b` along the wall. When a non-parallel wall is joined at `b`, that
    /// wall moves sideways instead (a `moveWall` of it), which puts `b` exactly `length` from `a` and
    /// keeps the room closed (PEDIT-02).
    case setWallLength(ElementID, length: Float)
    case setWallThickness(ElementID, thickness: Float)
    case addWall(ElementID, a: Vec2, b: Vec2)
    case deleteWall(ElementID)
    /// Centered `center` meters from the wall's `a`; width clamped to the wall.
    case addOpening(ElementID, kind: OpeningKind, wall: ElementID, center: Float, width: Float)
    /// Near edge `offset` meters from the wall's `a`, clamped so the opening stays on its wall.
    case moveOpening(ElementID, offset: Float)
    /// New width keeping the center; `height` (head minus sill) nil keeps both heights.
    case resizeOpening(ElementID, width: Float, height: Float?)
    case flipDoorSwing(ElementID)
    case renameRoom(ElementID, name: String)
    /// `rooms` are joined into `into` (which is not listed in `rooms`).
    case mergeRooms([ElementID], into: ElementID)
    /// The part of the room on the right of a -> b becomes `newRoom`.
    case splitRoom(ElementID, a: Vec2, b: Vec2, newRoom: ElementID)
    /// Add Measurement: a user dimension line offset `PlanEditorOps.userDimensionOffset` to the left.
    case addDimension(ElementID, a: Vec2, b: Vec2)
    /// Add Text, Add Symbol, Add Note, and moving or editing one: the same id replaces it.
    case setAnnotation(PlanAnnotation)
    case moveFixture(ElementID, center: Vec2, yaw: Float)
    case deleteFixture(ElementID)
    case recategorizeFixture(ElementID, ObjectCategory)
    /// Delete a door, window, opening, measurement (dimension) or annotation.
    case deleteElement(ElementID)
}

/// Why an action was refused (texts from `PlanEditorPresentation.message(for:prefs:)`).
enum PlanEditorError: Error, Equatable, Sendable {
    case notFound, tooShort, outOfRange, curvedWall, lockedWall, splitMissesRoom, nothingToMerge, notOnLevel
}

/// Inputs of the pure mapping.
struct PlanEditorContext {
    /// The edited plan and clean model (the clean model gives opening heights and object poses).
    var plan: PlanModel
    var clean: CleanModel?
    /// `PlanLevel.id` of the level being edited.
    var level: Int
    /// Walls whose plan `a` is not the clean `start` (data written before the RoomModel revision,
    /// 3.37b, until the upgrade pass rebuilds it, 3.43e); geometry edits refuse them.
    var lockedWalls: Set<ElementID>
}

/// Pure mapping from user actions to validated edit operations (docs/MODULES.md 3.37). Every
/// action becomes the operations of one log entry; the geometry helpers (joined walls, paired
/// walls, moved ends, orientation) are in `PlanEditorOps+Walls.swift`, the swing cycle, fixture
/// poses and log helpers in `PlanEditorOps+Helpers.swift`.
enum PlanEditorOps {
    /// Wall ends closer than this are one corner (FloorPlan's `PlanModel.outlineFollowTolerance`).
    static let jointTolerance: Float = 0.02
    /// Shortest wall an edit may leave, meters.
    static let minimumWallLength: Float = 0.05
    /// Typed ranges, meters.
    static let wallLengthRange: ClosedRange<Float> = 0.05...100
    static let thicknessRange: ClosedRange<Float> = 0.02...1.0
    static let openingWidthRange: ClosedRange<Float> = 0.2...6
    static let openingHeightRange: ClosedRange<Float> = 0.2...4
    /// Widths of new doors, windows and openings, meters.
    static let defaultDoorWidth: Float = 0.81, defaultWindowWidth: Float = 0.9, defaultOpeningWidth: Float = 0.9
    /// Offset of a user dimension line to the left of a -> b, meters.
    static let userDimensionOffset: Float = 0.3
    /// Joined walls within this angle of parallel continue the moved wall (their end is translated, not intersected).
    static let parallelLimitDegrees: Float = 10
    /// A paired wall is antiparallel within this angle, its line within its thickness plus this gap, and
    /// overlapping the moved wall by at least half of the shorter length.
    static let pairedAngleDegrees: Float = 5, pairedGapSlack: Float = 0.05
    /// Shortest user dimension, meters.
    static let minimumDimensionLength: Float = 0.05
    /// A split must leave at least this much of the room on each side, square meters (FloorPlan's
    /// `PlanModel.minimumSplitArea`).
    static let minimumSplitSide: Float = 0.01

    /// Validated operations of one action; throws `PlanEditorError`.
    static func operations(for action: PlanEditAction, context: PlanEditorContext) throws -> [EditOperation] {
        guard let level = context.plan.levels.first(where: { $0.id == context.level }) else {
            throw PlanEditorError.notFound
        }
        switch action {
        case .moveWall(let id, let distance):
            let wall = try straightWall(id, in: level, context: context)
            guard distance.isFinite else { throw PlanEditorError.outOfRange }
            return try moveWallOperations(wall, by: distance, in: level, context: context)
        case .moveWallEnd(let id, let atStart, let point):
            let wall = try straightWall(id, in: level, context: context)
            return try moveWallEndOperations(wall, atStart: atStart, to: point.simd, in: level, context: context)
        case .setWallLength(let id, let length):
            guard length.isFinite, wallLengthRange.contains(length) else { throw PlanEditorError.outOfRange }
            let wall = try straightWall(id, in: level, context: context)
            return try wallLengthOperations(wall, length: length, in: level, context: context)
        case .setWallThickness(let id, let thickness):
            guard thickness.isFinite, thicknessRange.contains(thickness) else { throw PlanEditorError.outOfRange }
            guard level.walls.contains(where: { $0.id == id }) else { throw PlanEditorError.notFound }
            return [.setWallThickness(wall: id, thickness: thickness)]
        case .addWall(let id, let a, let b):
            return try addWallOperations(id, a: a.simd, b: b.simd, in: level)
        case .deleteWall(let id):
            guard level.walls.contains(where: { $0.id == id }) else { throw PlanEditorError.notFound }
            return [.deleteElement(element: id)]
        case .addOpening(let id, let kind, let wallID, let center, let width):
            return try addOpeningOperations(id, kind: kind, wall: wallID, center: center, width: width,
                                            in: level, context: context)
        case .moveOpening(let id, let offset):
            let site = try openingSite(id, in: level)
            guard offset.isFinite else { throw PlanEditorError.outOfRange }
            guard !context.lockedWalls.contains(site.wall.id) else { throw PlanEditorError.lockedWall }
            let upper = max(0, site.length - site.opening.width)
            return [.moveOpening(opening: id, offset: min(max(offset, 0), upper))]
        case .resizeOpening(let id, let width, let height):
            return try resizeOpeningOperations(id, width: width, height: height, in: level, context: context)
        case .flipDoorSwing(let id):
            let site = try openingSite(id, in: level)
            guard site.opening.kind == .door || site.opening.kind == .openDoor else { throw PlanEditorError.notFound }
            guard !context.lockedWalls.contains(site.wall.id) else { throw PlanEditorError.lockedWall }
            let swing = nextSwing(site.opening.swing, offset: site.opening.offset, width: site.opening.width,
                                  wallLength: site.length)
            return [.setDoorSwing(door: id, swing: swing)]
        case .renameRoom(let id, let name):
            guard level.rooms.contains(where: { $0.id == id }) else { throw PlanEditorError.notFound }
            return [.renameRoom(room: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))]
        case .mergeRooms(let rooms, let into):
            return try mergeOperations(rooms, into: into, in: level, context: context)
        case .splitRoom(let id, let a, let b, let newRoom):
            return try splitOperations(id, a: a.simd, b: b.simd, newRoom: newRoom, in: level)
        case .addDimension(let id, let a, let b):
            guard isFinite(a.simd), isFinite(b.simd) else { throw PlanEditorError.outOfRange }
            guard simd_distance(a.simd, b.simd) >= minimumDimensionLength else { throw PlanEditorError.tooShort }
            let dimension = PlanDimension(id: id, a: a, b: b, offset: userDimensionOffset, isUser: true)
            return [.addDimension(dimension: dimension, level: level.id)]
        case .setAnnotation(let annotation):
            guard isFinite(annotation.at.simd) else { throw PlanEditorError.outOfRange }
            return [.addAnnotation(annotation: annotation, level: level.id)]
        case .moveFixture(let id, let center, let yaw):
            guard isFinite(center.simd), yaw.isFinite else { throw PlanEditorError.outOfRange }
            guard level.fixtures.contains(where: { $0.id == id }),
                  let object = cleanObject(id, in: context.clean) else { throw PlanEditorError.notFound }
            return [.moveObject(object: id, transform: objectTransform(object, center: center, yaw: yaw))]
        case .deleteFixture(let id):
            guard level.fixtures.contains(where: { $0.id == id }) else { throw PlanEditorError.notFound }
            return [.deleteElement(element: id)]
        case .recategorizeFixture(let id, let category):
            guard level.fixtures.contains(where: { $0.id == id }) else { throw PlanEditorError.notFound }
            return [.recategorizeObject(object: id, category: category)]
        case .deleteElement(let id):
            guard isDeletable(id, in: level) else { throw PlanEditorError.notFound }
            return [.deleteElement(element: id)]
        }
    }

    /// One log entry: the single operation, or `.batch(operations:)` for several.
    static func operation(for action: PlanEditAction, context: PlanEditorContext) throws -> EditOperation {
        let ops = try operations(for: action, context: context)
        guard let first = ops.first else { throw PlanEditorError.notFound }
        return ops.count == 1 ? first : .batch(operations: ops)
    }

    // MARK: - Walls

    /// A straight wall of the level that geometry edits may change: missing `.notFound`, locked
    /// `.lockedWall`, curved `.curvedWall`.
    static func straightWall(_ id: ElementID, in level: PlanLevel, context: PlanEditorContext) throws -> PlanWall {
        guard let wall = level.walls.first(where: { $0.id == id }) else { throw PlanEditorError.notFound }
        guard !context.lockedWalls.contains(id) else { throw PlanEditorError.lockedWall }
        guard wall.arc == nil else { throw PlanEditorError.curvedWall }
        return wall
    }

    /// Add Wall: at least `minimumWallLength`, ordered by `oriented(a:b:in:)`, estimated interior
    /// thickness, provenance `.user`.
    private static func addWallOperations(_ id: ElementID, a: SIMD2<Float>, b: SIMD2<Float>,
                                          in level: PlanLevel) throws -> [EditOperation] {
        guard isFinite(a), isFinite(b) else { throw PlanEditorError.outOfRange }
        guard simd_distance(a, b) >= minimumWallLength else { throw PlanEditorError.tooShort }
        let ends = oriented(a: a, b: b, in: level)
        let wall = PlanWall(id: id, a: Vec2(ends.a), b: Vec2(ends.b), thickness: CleanBuildOptions().interiorThickness,
                            thicknessSource: .estimated, arc: nil, provenance: .user, occludedSpans: [])
        return [.addWall(wall: wall, level: level.id)]
    }

    // MARK: - Openings

    /// An opening of the level with its host wall and the wall's length.
    static func openingSite(_ id: ElementID, in level: PlanLevel) throws -> (opening: PlanOpening, wall: PlanWall, length: Float) {
        guard let opening = level.openings.first(where: { $0.id == id }),
              let wall = level.walls.first(where: { $0.id == opening.wallID }) else { throw PlanEditorError.notFound }
        let length = simd_distance(wall.a.simd, wall.b.simd)
        guard length.isFinite else { throw PlanEditorError.notFound }
        return (opening, wall, length)
    }

    /// Add Door, Window or Opening: a straight, unlocked wall of the level at least as long as the
    /// smallest opening; width clamped to the range and the wall; the near edge clamped to the
    /// wall; doors get `PlanBuilder.defaultSwing` so both models store the same swing.
    private static func addOpeningOperations(_ id: ElementID, kind: OpeningKind, wall wallID: ElementID, center: Float,
                                             width: Float, in level: PlanLevel,
                                             context: PlanEditorContext) throws -> [EditOperation] {
        let wall = try straightWall(wallID, in: level, context: context)
        guard center.isFinite, width.isFinite else { throw PlanEditorError.outOfRange }
        let length = simd_distance(wall.a.simd, wall.b.simd)
        guard length.isFinite, length >= openingWidthRange.lowerBound else { throw PlanEditorError.tooShort }
        let ranged = min(max(width, openingWidthRange.lowerBound), openingWidthRange.upperBound)
        let clampedWidth = min(ranged, length)
        let offset = min(max(center - clampedWidth / 2, 0), max(0, length - clampedWidth))
        let isDoor = kind == .door || kind == .openDoor
        let swing: DoorSwing? = isDoor ? PlanBuilder.defaultSwing(offset: offset, width: clampedWidth, wallLength: length) : nil
        let opening = PlanOpening(id: id, wallID: wallID, kind: kind, offset: offset, width: clampedWidth, swing: swing)
        return [.addOpening(opening: opening, level: level.id)]
    }

    /// Resize: width in `openingWidthRange`; sill and head from the edited clean opening (doors
    /// sill 0), with `height` when given (head = sill + height capped by the wall height, height in
    /// `openingHeightRange`); without a clean opening the defaults of `CleanModel.apply(.addOpening)`.
    private static func resizeOpeningOperations(_ id: ElementID, width: Float, height: Float?, in level: PlanLevel,
                                                context: PlanEditorContext) throws -> [EditOperation] {
        guard width.isFinite, openingWidthRange.contains(width) else { throw PlanEditorError.outOfRange }
        if let height {
            guard height.isFinite, openingHeightRange.contains(height) else { throw PlanEditorError.outOfRange }
        }
        let site = try openingSite(id, in: level)
        let isDoor = site.opening.kind == .door || site.opening.kind == .openDoor
        var heights = defaultHeights(site.opening.kind)
        var wallHeight: Float?
        if let clean = context.clean, let found = cleanOpening(id, in: clean) {
            heights = (found.opening.sillHeight, found.opening.headHeight)
            wallHeight = found.wallHeight
        }
        var sill: Float = isDoor ? 0 : heights.sill
        var head: Float = heights.head
        if let height {
            head = sill + height
            if let wallHeight, wallHeight.isFinite, wallHeight > 0 { head = min(head, wallHeight) }
        }
        if !sill.isFinite { sill = 0 }
        if !head.isFinite { head = defaultHeights(site.opening.kind).head }
        return [.resizeOpening(opening: id, width: width, sillHeight: sill, headHeight: head)]
    }

    /// Sill and head of a new opening in the clean model: door 0 to 2.03 m, window 0.9 to 2.1 m,
    /// opening 0 to 2.1 m (`CleanModel.apply(.addOpening)`).
    static func defaultHeights(_ kind: OpeningKind) -> (sill: Float, head: Float) {
        switch kind {
        case .door, .openDoor: return (0, 2.03)
        case .window: return (0.9, 2.1)
        case .opening: return (0, 2.1)
        }
    }

    /// The clean opening with this id and the height of its host wall (nil without one).
    static func cleanOpening(_ id: ElementID, in clean: CleanModel) -> (opening: CleanOpening, wallHeight: Float?)? {
        for room in clean.rooms {
            guard let opening = room.openings.first(where: { $0.id == id }) else { continue }
            var height: Float?
            if let wallID = opening.wallID {
                for host in clean.rooms {
                    if let wall = host.walls.first(where: { $0.id == wallID }) { height = wall.height }
                }
            }
            return (opening, height)
        }
        return nil
    }

    // MARK: - Rooms

    /// Merge: at least one room besides `into` (duplicates dropped), every room on the level.
    private static func mergeOperations(_ rooms: [ElementID], into: ElementID, in level: PlanLevel,
                                        context: PlanEditorContext) throws -> [EditOperation] {
        guard level.rooms.contains(where: { $0.id == into }) else { throw PlanEditorError.notFound }
        var seen: Set<ElementID> = [into]
        var joined: [ElementID] = []
        for id in rooms where seen.insert(id).inserted {
            joined.append(id)
        }
        guard !joined.isEmpty else { throw PlanEditorError.nothingToMerge }
        for id in joined where !level.rooms.contains(where: { $0.id == id }) {
            let elsewhere = context.plan.levels.contains { other in other.rooms.contains { $0.id == id } }
            throw elsewhere ? PlanEditorError.notOnLevel : PlanEditorError.notFound
        }
        return [.mergeRooms(rooms: joined, into: into)]
    }

    /// Split: both sides of the line hold at least `minimumSplitSide` of the room's parts, cut as
    /// FloorPlan cuts them (`PlanModel.pieces`, `Polygon2D.clipped(leftOf:_:)`).
    private static func splitOperations(_ id: ElementID, a: SIMD2<Float>, b: SIMD2<Float>, newRoom: ElementID,
                                        in level: PlanLevel) throws -> [EditOperation] {
        guard let room = level.rooms.first(where: { $0.id == id }) else { throw PlanEditorError.notFound }
        guard isFinite(a), isFinite(b), simd_distance(a, b) > 1e-4 else { throw PlanEditorError.splitMissesRoom }
        let parts = PlanBuilder.parts(of: room)
        let left = PlanModel.area(of: PlanModel.pieces(parts, leftOf: a, b))
        let right = PlanModel.area(of: PlanModel.pieces(parts, leftOf: b, a))
        guard left >= minimumSplitSide, right >= minimumSplitSide else { throw PlanEditorError.splitMissesRoom }
        return [.splitRoom(room: id, line: [Vec2(a), Vec2(b)], newRoom: newRoom)]
    }

    // MARK: - Lookups

    /// The clean object with this id.
    static func cleanObject(_ id: ElementID, in clean: CleanModel?) -> DetectedObject? {
        for room in clean?.rooms ?? [] {
            if let object = room.objects.first(where: { $0.id == id }) { return object }
        }
        return nil
    }

    /// True when a wall, opening, fixture, annotation or dimension of the level has this id
    /// (rooms are never deleted through edits; they are merged or split).
    static func isDeletable(_ id: ElementID, in level: PlanLevel) -> Bool {
        if level.walls.contains(where: { $0.id == id }) || level.openings.contains(where: { $0.id == id }) {
            return true
        }
        if level.fixtures.contains(where: { $0.id == id }) || level.annotations.contains(where: { $0.id == id }) {
            return true
        }
        return level.dimensions.contains { $0.id == id }
    }

    /// True when both components are finite.
    static func isFinite(_ p: SIMD2<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite
    }
}
