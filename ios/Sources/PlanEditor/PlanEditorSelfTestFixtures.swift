import Foundation
import simd

/// Collects PlanEditor self-test results: one line per failing check ("name: detail").
struct PlanEditorSelfTestLog {
    /// Failing checks.
    private(set) var failures: [String] = []
    /// Number of checks run.
    private(set) var count = 0

    /// Records one check.
    mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        guard !condition else { return }
        let text = detail()
        failures.append(text.isEmpty ? name : "\(name): \(text)")
    }

    /// Records a float comparison within `tolerance`.
    mutating func near(_ name: String, _ actual: Float?, _ expected: Float, tolerance: Float = 1e-4) {
        guard let actual else {
            expect(name, false, "no value")
            return
        }
        expect(name, abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)")
    }

    /// Records a check that `body` throws exactly `error`.
    mutating func throwsError(_ name: String, _ error: PlanEditorError, _ body: () throws -> Void) {
        do {
            try body()
            expect(name, false, "no error, expected \(error)")
        } catch let thrown as PlanEditorError {
            expect(name, thrown == error, "expected \(error), got \(thrown)")
        } catch {
            expect(name, false, "unexpected \(error)")
        }
    }
}

/// Hand-made models for `PlanEditorSelfTest` (deterministic identifiers, no RoomPlan): room A
/// (4 x 5 m, walls W1 to W4 counter-clockwise from the origin, a door on W1, a window on W2, a
/// sofa) and room B (3 x 4 m) east of A with a 0.12 m gap, so A's east wall W2 and B's west wall
/// B4 are the two faces of a shared wall.
enum PlanEditorSelfTestFixtures {
    /// Room identifiers.
    static let roomA = id(1), roomB = id(2)
    /// Walls of A (south, east, north, west) and of B (south, east, north, west).
    static let w1 = id(10), w2 = id(11), w3 = id(12), w4 = id(13)
    static let b1 = id(20), b2 = id(21), b3 = id(22), b4 = id(23)
    /// Door on W1, window on W2, sofa in A.
    static let door = id(30), window = id(31), sofa = id(40)
    /// Width of the door, meters.
    static let doorWidth: Float = 0.81
    /// The sofa's world height (box center y), meters.
    static let sofaHeight: Float = 0.4
    /// The one floor of the fixture.
    static let floors = [FloorRecord(id: 0, name: "", elevation: 0)]

    /// A fixed UUID whose last two bytes encode `n`.
    static func uuid(_ n: Int) -> UUID {
        let high = UInt8(truncatingIfNeeded: n >> 8)
        let low = UInt8(truncatingIfNeeded: n)
        return UUID(uuid: (0x50, 0x45, 0x44, 0x54, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
    }

    /// A fixed element identifier.
    static func id(_ n: Int) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A world transform at plan point `p`, height `y`, turned by `yaw` about +Y.
    static func pose(at p: SIMD2<Float>, yaw: Float, y: Float) -> Transform4 {
        let world = PlanAxes.toWorld(p, y: y)
        let c = cos(yaw)
        let s = sin(yaw)
        let matrix = simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                             SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(world.x, world.y, world.z, 1)))
        return Transform4(matrix)
    }

    /// A clean wall from plan point `a` to `b` with the left normal (the orientation invariant).
    static func wall(_ wallID: ElementID, from a: SIMD2<Float>, to b: SIMD2<Float>) -> CleanWall {
        let d = simd_normalize(b - a)
        let left = SIMD2<Float>(-d.y, d.x)
        return CleanWall(id: wallID, start: Vec3(PlanAxes.toWorld(a, y: 0)), end: Vec3(PlanAxes.toWorld(b, y: 0)),
                         height: 2.5, normal: Vec3(PlanAxes.toWorld(left, y: 0)), thickness: 0.115,
                         thicknessSource: .estimated, arc: nil, confidence: .high, completedEdges: 4,
                         occludedSpans: [], provenance: .measured)
    }

    /// A clean room with walls along its counter-clockwise corners (ids in order) and metrics.
    static func room(_ roomID: ElementID, corners: [SIMD2<Float>], wallIDs: [ElementID], openings: [CleanOpening] = [],
                     objects: [DetectedObject] = []) -> CleanRoom {
        var walls: [CleanWall] = []
        for (i, wallID) in wallIDs.enumerated() where i < corners.count {
            walls.append(wall(wallID, from: corners[i], to: corners[(i + 1) % corners.count]))
        }
        var room = CleanRoom(id: roomID, recordID: roomID.uuid, name: "", sectionLabel: nil, floorIndex: 0, walls: walls,
                             openings: openings,
                             floor: CleanFloor(outline: corners.map { Vec2($0) }, elevation: 0, occludedArea: 0,
                                               provenance: .measured),
                             ceiling: CleanCeiling(height: 2.5, provenance: .measured), objects: objects, metrics: .zero)
        room.metrics = RoomMetricsCalculator.metrics(for: room)
        return room
    }

    /// Rooms A and B as a clean model.
    static func cleanModel() -> CleanModel {
        let cornersA = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)]
        let cornersB = [SIMD2<Float>(4.12, 0), SIMD2<Float>(7.12, 0), SIMD2<Float>(7.12, 4), SIMD2<Float>(4.12, 4)]
        let openings = [
            CleanOpening(id: door, wallID: w1, kind: .door, offsetAlongWall: 0.5, width: doorWidth, sillHeight: 0,
                         headHeight: 2.03, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .estimated),
                         provenance: .measured),
            CleanOpening(id: window, wallID: w2, kind: .window, offsetAlongWall: 1.5, width: 1.2, sillHeight: 0.9,
                         headHeight: 2.1, swing: nil, provenance: .measured)
        ]
        let sofaObject = DetectedObject(id: sofa, category: .sofa, label: "",
                                        transform: pose(at: SIMD2<Float>(2, 4.2), yaw: 0, y: sofaHeight),
                                        dimensions: Vec3(x: 2.0, y: 0.8, z: 0.9), confidence: .high, isHidden: false,
                                        provenance: .measured)
        let roomAModel = room(roomA, corners: cornersA, wallIDs: [w1, w2, w3, w4], openings: openings, objects: [sofaObject])
        let roomBModel = room(roomB, corners: cornersB, wallIDs: [b1, b2, b3, b4])
        return CleanModel(rooms: [roomAModel, roomBModel], sourceIsStructure: false, stamp: nil)
    }

    /// The plan FloorPlan builds from a clean model.
    static func plan(_ clean: CleanModel) -> PlanModel {
        PlanBuilder.build(from: clean, floors: floors)
    }

    /// A context over both models on level 0.
    static func context(_ plan: PlanModel, _ clean: CleanModel?, locked: Set<ElementID> = []) -> PlanEditorContext {
        PlanEditorContext(plan: plan, clean: clean, level: 0, lockedWalls: locked)
    }

    /// The plan with one operation applied, nil when the plan refuses it.
    static func applied(_ op: EditOperation, to plan: PlanModel) -> PlanModel? {
        var copy = plan
        return copy.apply(op) ? copy : nil
    }

    /// The clean model with a one-entry log applied (`applyingEdits`), nil when it is orphaned.
    static func applied(_ op: EditOperation, to clean: CleanModel) -> CleanModel? {
        var log = EditLog()
        log.append(op)
        let result = clean.applyingEdits(log)
        return result.orphaned.isEmpty ? result.model : nil
    }

    /// Level 0 of a plan.
    static func level(_ plan: PlanModel?) -> PlanLevel? {
        plan?.levels.first { $0.id == 0 }
    }

    /// A plan wall by id.
    static func planWall(_ wallID: ElementID, _ plan: PlanModel?) -> PlanWall? {
        level(plan)?.walls.first { $0.id == wallID }
    }

    /// A plan room by id.
    static func planRoom(_ roomID: ElementID, _ plan: PlanModel?) -> PlanRoom? {
        level(plan)?.rooms.first { $0.id == roomID }
    }

    /// A plan opening by id.
    static func planOpening(_ openingID: ElementID, _ plan: PlanModel?) -> PlanOpening? {
        level(plan)?.openings.first { $0.id == openingID }
    }

    /// A clean wall by id.
    static func cleanWall(_ wallID: ElementID, _ clean: CleanModel?) -> CleanWall? {
        for room in clean?.rooms ?? [] {
            if let found = room.walls.first(where: { $0.id == wallID }) { return found }
        }
        return nil
    }

    /// A clean room by id.
    static func cleanRoom(_ roomID: ElementID, _ clean: CleanModel?) -> CleanRoom? {
        clean?.rooms.first { $0.id == roomID }
    }

    /// A clean opening by id.
    static func cleanOpening(_ openingID: ElementID, _ clean: CleanModel?) -> CleanOpening? {
        for room in clean?.rooms ?? [] {
            if let found = room.openings.first(where: { $0.id == openingID }) { return found }
        }
        return nil
    }

    /// Plan length of a plan wall.
    static func length(_ wall: PlanWall?) -> Float? {
        guard let wall else { return nil }
        return simd_distance(wall.a.simd, wall.b.simd)
    }

    /// Plan length of a clean wall.
    static func length(_ wall: CleanWall?) -> Float? {
        guard let wall else { return nil }
        return simd_distance(PlanAxes.toPlan(wall.start.simd), PlanAxes.toPlan(wall.end.simd))
    }

    /// Number of operations in an entry (a batch counts its operations).
    static func operationCount(_ op: EditOperation) -> Int {
        if case .batch(let operations) = op { return operations.count }
        return 1
    }

    /// Largest distance between a plan wall's `a` and its clean `start` in plan, over every wall
    /// present in both models (infinity when a wall is missing from the clean model).
    static func worstStartGap(_ plan: PlanModel?, _ clean: CleanModel?) -> Float {
        var worst: Float = 0
        for wall in level(plan)?.walls ?? [] {
            guard let other = cleanWall(wall.id, clean) else { return .infinity }
            worst = max(worst, simd_distance(wall.a.simd, PlanAxes.toPlan(other.start.simd)))
        }
        return worst
    }

    /// One example of every `EditOperation` case except `.batch`, built by hand.
    static func everyOperation() -> [EditOperation] {
        let planWall = PlanWall(id: id(90), a: Vec2(x: 0, y: 0), b: Vec2(x: 1, y: 0), thickness: 0.1, thicknessSource: .user,
                                arc: nil, provenance: .user, occludedSpans: [])
        let opening = PlanOpening(id: id(91), wallID: w1, kind: .window, offset: 1, width: 1, swing: nil)
        let annotation = PlanAnnotation(id: id(92), kind: .note, at: Vec2(x: 1, y: 1), text: "Note", symbol: nil)
        let dimension = PlanDimension(id: id(93), a: Vec2(x: 0, y: 0), b: Vec2(x: 1, y: 0), offset: 0.3, isUser: true)
        let alignment = RoomAlignmentRecord(roomID: roomA.uuid, yaw: 0, translation: Vec3.zero, source: .user)
        let box = OrientedBoxRecord(OrientedBox(center: .zero, axes: matrix_identity_float3x3,
                                                halfExtents: SIMD3<Float>(repeating: 0.5)))
        let swing = DoorSwing(hingeAtStart: true, opensToNormalSide: false, source: .user)
        return [
            .renameRoom(room: roomA, name: "Den"), .relabelObject(object: sofa, label: "Couch"),
            .recategorizeObject(object: sofa, category: .chair), .setHidden(element: sofa, hidden: true),
            .deleteElement(element: sofa), .moveObject(object: sofa, transform: .identity),
            .moveWallEndpoint(wall: w1, atStart: true, to: Vec2.zero), .addWall(wall: planWall, level: 0),
            .addOpening(opening: opening, level: 0), .setDoorSwing(door: door, swing: swing),
            .setWallThickness(wall: w1, thickness: 0.2), .addAnnotation(annotation: annotation, level: 0),
            .addDimension(dimension: dimension, level: 0), .setScaleCorrection(room: roomA, factor: 1.01),
            .setRoomAlignment(alignment), .cropObject(object: sofa, box: box),
            .moveOpening(opening: door, offset: 1), .resizeOpening(opening: door, width: 0.9, sillHeight: 0, headHeight: 2.1),
            .mergeRooms(rooms: [roomB], into: roomA), .splitRoom(room: roomA, line: [Vec2.zero, Vec2(x: 1, y: 1)], newRoom: id(94))
        ]
    }
}
