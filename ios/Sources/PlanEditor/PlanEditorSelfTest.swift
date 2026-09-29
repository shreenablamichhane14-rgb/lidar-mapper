import Foundation
import simd

/// Self-test of the plan editor mapping (docs/MODULES.md 3.37): every mapped action is applied to
/// the plan with `PlanModel.apply` and to the clean model with `CleanModel.applyingEdits` (a
/// one-entry `EditLog`). Deterministic, no files, no ARKit, well under 2 seconds. Returns one
/// line per failing check; empty when all pass. The pure texts, snapping and helpers are checked
/// in `PlanEditorSelfTest+Checks.swift`.
enum PlanEditorSelfTest {
    /// Fixture shorthand (also used by `PlanEditorSelfTest+Checks.swift`).
    typealias F = PlanEditorSelfTestFixtures

    /// Runs every check.
    static func run() -> [String] {
        var log = PlanEditorSelfTestLog()
        let clean = F.cleanModel()
        let plan = F.plan(clean)
        let context = F.context(plan, clean)
        checkWallMoves(&log, plan: plan, clean: clean, context: context)
        checkWallEdits(&log, plan: plan, clean: clean, context: context)
        checkOpenings(&log, plan: plan, clean: clean, context: context)
        checkRooms(&log, plan: plan, clean: clean, context: context)
        checkAnnotationsAndFixtures(&log, plan: plan, clean: clean, context: context)
        checkLogAndPairs(&log, plan: plan, clean: clean, context: context)
        checkSnapping(&log, plan: plan)
        checkHelpers(&log, plan: plan, clean: clean, context: context)
        checkPresentation(&log, plan: plan)
        return log.failures
    }

    /// The operation of an action, nil (logged as a failure) when it throws.
    static func op(_ action: PlanEditAction, _ context: PlanEditorContext, _ name: String,
                   _ log: inout PlanEditorSelfTestLog) -> EditOperation? {
        do {
            return try PlanEditorOps.operation(for: action, context: context)
        } catch {
            log.expect(name + " maps", false, "\(error)")
            return nil
        }
    }

    /// The action applied to both models, nil when it throws or either model refuses it.
    static func both(_ action: PlanEditAction, _ context: PlanEditorContext, _ clean: CleanModel, _ name: String,
                     _ log: inout PlanEditorSelfTestLog) -> (plan: PlanModel, clean: CleanModel, op: EditOperation)? {
        guard let entry = op(action, context, name, &log) else { return nil }
        guard let editedPlan = F.applied(entry, to: context.plan) else {
            log.expect(name + " plan applies", false)
            return nil
        }
        guard let editedClean = F.applied(entry, to: clean) else {
            log.expect(name + " clean applies", false)
            return nil
        }
        return (plan: editedPlan, clean: editedClean, op: entry)
    }

    // MARK: - Checks 1 to 3: joined walls and Move Wall

    /// Joined ends, the Move Wall batch, closed corners and the clean model following.
    private static func checkWallMoves(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                       context: PlanEditorContext) {
        guard let level = F.level(plan) else {
            log.expect("fixture level", false)
            return
        }
        let joined = PlanEditorOps.joined(F.w1, atStart: false, in: level)
        log.expect("1 joined W1 end is W2 start", joined.count == 1 && joined.first?.wall == F.w2 && joined.first?.atStart == true,
                   "\(joined.count) ends")
        let baseArea = F.planRoom(F.roomA, plan)?.area ?? 0
        guard let moved = both(.moveWall(F.w3, by: -0.3), context, clean, "2 moveWall W3", &log) else { return }
        log.expect("2 moveWall is one batch of 4", F.operationCount(moved.op) == 4 && isBatch(moved.op),
                   "\(F.operationCount(moved.op)) operations")
        log.near("2 room A area grows by 1.2", F.planRoom(F.roomA, moved.plan)?.area, baseArea + 1.2, tolerance: 1e-3)
        let w2b = F.planWall(F.w2, moved.plan)?.b.simd
        let w3a = F.planWall(F.w3, moved.plan)?.a.simd
        log.expect("2 corner W2 b = W3 a", w2b != nil && w2b == w3a, "\(String(describing: w2b)) \(String(describing: w3a))")
        let cleanBase = F.cleanRoom(F.roomA, clean)?.metrics.floorArea ?? 0
        log.near("3 clean floor area grows by 1.2", F.cleanRoom(F.roomA, moved.clean)?.metrics.floorArea, cleanBase + 1.2,
                 tolerance: 1e-3)
        let gap = F.worstStartGap(moved.plan, moved.clean)
        log.expect("3 plan a equals clean start", gap <= 1e-4, "gap \(gap)")
    }

    /// True for a `.batch` entry.
    static func isBatch(_ op: EditOperation) -> Bool {
        if case .batch = op { return true }
        return false
    }

    // MARK: - Checks 4 to 11: length, refusals, thickness, orientation, add and delete

    /// Wall Length, refusals, thickness, `oriented`, Add Wall and Delete Wall.
    private static func checkWallEdits(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                       context: PlanEditorContext) {
        if let lengthened = both(.setWallLength(F.w1, length: 4.5), context, clean, "4 setWallLength", &log) {
            log.near("4 plan W1 is 4.5", F.length(F.planWall(F.w1, lengthened.plan)), 4.5)
            log.near("4 clean W1 is 4.5", F.length(F.cleanWall(F.w1, lengthened.clean)), 4.5)
            let w2 = F.planWall(F.w2, lengthened.plan)
            let direction = w2.map { simd_normalize($0.b.simd - $0.a.simd) }
            log.expect("4 W2 keeps its direction", direction.map { simd_distance($0, SIMD2<Float>(0, 1)) < 1e-4 } ?? false,
                       "\(String(describing: direction))")
        }
        log.throwsError("5 length 0.01 is out of range", .outOfRange) {
            _ = try PlanEditorOps.operations(for: .setWallLength(F.w1, length: 0.01), context: context)
        }
        log.throwsError("6 end past the other end is too short", .tooShort) {
            _ = try PlanEditorOps.operations(for: .moveWallEnd(F.w1, atStart: false, to: Vec2(x: -1, y: 0)), context: context)
        }
        var curvedPlan = plan
        _ = curvedPlan.updateWall(F.w1) { wall in
            wall.arc = WallArc(center: Vec3(x: 2, y: 0, z: 1), radius: 2.2, startAngle: 0.5, endAngle: 2.6)
        }
        log.throwsError("7 curved wall refused", .curvedWall) {
            _ = try PlanEditorOps.operations(for: .moveWall(F.w1, by: 0.1), context: F.context(curvedPlan, clean))
        }
        log.throwsError("7 locked wall refused", .lockedWall) {
            _ = try PlanEditorOps.operations(for: .moveWall(F.w1, by: 0.1), context: F.context(plan, clean, locked: [F.w1]))
        }
        if let thick = both(.setWallThickness(F.w1, thickness: 0.15), context, clean, "8 thickness", &log) {
            let planWall = F.planWall(F.w1, thick.plan)
            let cleanWall = F.cleanWall(F.w1, thick.clean)
            log.near("8 plan thickness 0.15", planWall?.thickness, 0.15)
            log.expect("8 plan thickness source user", planWall?.thicknessSource == .user)
            log.near("8 clean thickness 0.15", cleanWall?.thickness, 0.15)
            log.expect("8 clean thickness source user", cleanWall?.thicknessSource == .user)
        }
        if let level = F.level(plan) {
            let outside = PlanEditorOps.oriented(a: SIMD2<Float>(4, -0.03), b: SIMD2<Float>(0, -0.03), in: level)
            log.expect("9 wall along the outside is reversed", outside.a == SIMD2<Float>(0, -0.03) && outside.b == SIMD2<Float>(4, -0.03))
            let across = PlanEditorOps.oriented(a: SIMD2<Float>(0, 2.5), b: SIMD2<Float>(4, 2.5), in: level)
            log.expect("9 wall across the room is kept", across.a == SIMD2<Float>(0, 2.5) && across.b == SIMD2<Float>(4, 2.5))
        }
        let newWall = F.id(50)
        let add = PlanEditAction.addWall(newWall, a: Vec2(x: 0, y: 2.5), b: Vec2(x: 4, y: 2.5))
        if let added = both(add, context, clean, "10 addWall", &log) {
            let dimensionID = PlanBuilder.wallDimensionID(newWall)
            let hasDimension = F.level(added.plan)?.dimensions.contains { $0.id == dimensionID } ?? false
            log.expect("10 plan wall with a generated dimension", F.planWall(newWall, added.plan) != nil && hasDimension)
            let cleanWall = F.cleanWall(newWall, added.clean)
            let normal = cleanWall.map { PlanAxes.toPlan($0.normal.simd) }
            log.expect("10 clean normal is the left perpendicular",
                       normal.map { simd_distance($0, SIMD2<Float>(0, 1)) < 1e-4 } ?? false, "\(String(describing: normal))")
        }
        if let deleted = both(.deleteWall(F.w1), context, clean, "11 deleteWall", &log) {
            log.expect("11 plan W1 and its door gone", F.planWall(F.w1, deleted.plan) == nil && F.planOpening(F.door, deleted.plan) == nil)
            log.expect("11 clean W1 and its door gone",
                       F.cleanWall(F.w1, deleted.clean) == nil && F.cleanOpening(F.door, deleted.clean) == nil)
        }
    }

    // MARK: - Checks 12 to 15: openings

    /// Add, move, resize and flip.
    private static func checkOpenings(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                      context: PlanEditorContext) {
        let newDoor = F.id(51)
        let add = PlanEditAction.addOpening(newDoor, kind: .door, wall: F.w1, center: 2.0, width: 0.81)
        if let added = both(add, context, clean, "12 addOpening", &log) {
            let planDoor = F.planOpening(newDoor, added.plan)
            let cleanDoor = F.cleanOpening(newDoor, added.clean)
            log.near("12 plan offset 1.595", planDoor?.offset, 1.595)
            log.near("12 clean offset 1.595", cleanDoor?.offsetAlongWall, 1.595)
            let planSwing: DoorSwing? = planDoor?.swing
            let cleanSwing: DoorSwing? = cleanDoor?.swing
            let sameSwing = planSwing != nil && planSwing == cleanSwing
            log.expect("12 same estimated swing", sameSwing && planSwing?.source == Provenance.estimated)
        }
        if let moved = both(.moveOpening(F.door, offset: 3.9), context, clean, "13 moveOpening", &log) {
            log.near("13 plan offset clamps to 3.19", F.planOpening(F.door, moved.plan)?.offset, 3.19)
            log.near("13 clean offset clamps to 3.19", F.cleanOpening(F.door, moved.clean)?.offsetAlongWall, 3.19)
        }
        if let resized = both(.resizeOpening(F.door, width: 0.9, height: nil), context, clean, "14 resizeOpening", &log) {
            log.near("14 plan keeps the center", F.planOpening(F.door, resized.plan)?.offset, 0.5 - 0.045)
            log.near("14 clean keeps the center", F.cleanOpening(F.door, resized.clean)?.offsetAlongWall, 0.5 - 0.045)
        }
        if let taller = both(.resizeOpening(F.door, width: 0.9, height: 2.1), context, clean, "14 resize height", &log) {
            let door = F.cleanOpening(F.door, taller.clean)
            log.near("14 clean head 2.1", door?.headHeight, 2.1)
            log.near("14 clean sill 0", door?.sillHeight, 0)
        }
        var currentPlan = plan
        var currentClean = clean
        let first = F.planOpening(F.door, plan)?.swing
        var allUser = true
        for step in 1...4 {
            guard let flipped = both(.flipDoorSwing(F.door), F.context(currentPlan, currentClean), currentClean,
                                     "15 flip \(step)", &log) else { break }
            currentPlan = flipped.plan
            currentClean = flipped.clean
            let planSource: Provenance? = F.planOpening(F.door, currentPlan)?.swing?.source
            let cleanSource: Provenance? = F.cleanOpening(F.door, currentClean)?.swing?.source
            allUser = allUser && planSource == .user && cleanSource == .user
        }
        let last = F.planOpening(F.door, currentPlan)?.swing
        let sameHinge = first != nil && first?.hingeAtStart == last?.hingeAtStart
        let sameSide = first?.opensToNormalSide == last?.opensToNormalSide
        log.expect("15 four flips cycle back", sameHinge && sameSide)
        log.expect("15 flipped swings are user swings", allUser)
    }

    // MARK: - Checks 16 to 19: rooms

    /// Rename, merge, split and their refusals.
    private static func checkRooms(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                   context: PlanEditorContext) {
        if let renamed = both(.renameRoom(F.roomA, name: " Dining "), context, clean, "16 rename", &log) {
            log.expect("16 both named Dining", F.planRoom(F.roomA, renamed.plan)?.name == "Dining"
                       && F.cleanRoom(F.roomA, renamed.clean)?.name == "Dining")
            if let cleared = both(.renameRoom(F.roomA, name: "  "), F.context(renamed.plan, renamed.clean), renamed.clean,
                                  "16 clear name", &log) {
                let titles = RoomTitles.titles(for: cleared.plan, clean: cleared.clean)
                log.expect("16 empty name restores the default title", titles[F.roomA] == Copy.FloorPlan.defaultRoomTitle(1),
                           "\(titles[F.roomA] ?? "nil")")
            }
        }
        if let merged = both(.mergeRooms([F.roomB], into: F.roomA), context, clean, "17 merge", &log) {
            let rooms = F.level(merged.plan)?.rooms ?? []
            log.expect("17 one plan room", rooms.count == 1, "\(rooms.count) rooms")
            log.near("17 plan area 32", rooms.first?.area, 32, tolerance: 1e-3)
            log.expect("17 one merged outline", rooms.first?.mergedOutlines?.count == 1)
            log.expect("17 one clean room with 8 walls", merged.clean.rooms.count == 1 && merged.clean.rooms.first?.walls.count == 8)
            log.near("17 clean floor area 32", merged.clean.rooms.first?.metrics.floorArea, 32, tolerance: 1e-3)
        }
        let newRoom = F.id(52)
        let split = PlanEditAction.splitRoom(F.roomA, a: Vec2(x: -1, y: 2), b: Vec2(x: 5, y: 2), newRoom: newRoom)
        if let cut = both(split, context, clean, "18 split", &log) {
            let kept = F.planRoom(F.roomA, cut.plan)
            let created = F.planRoom(newRoom, cut.plan)
            log.near("18 plan kept side 12", kept?.area, 12, tolerance: 1e-3)
            log.near("18 plan new side 8", created?.area, 8, tolerance: 1e-3)
            log.expect("18 new plan room has the id and no name", created != nil && created?.name == "")
            log.near("18 clean kept side 12", F.cleanRoom(F.roomA, cut.clean)?.metrics.floorArea, 12, tolerance: 1e-3)
            log.near("18 clean new side 8", F.cleanRoom(newRoom, cut.clean)?.metrics.floorArea, 8, tolerance: 1e-3)
        }
        log.throwsError("19 split line outside the room", .splitMissesRoom) {
            let missing = PlanEditAction.splitRoom(F.roomA, a: Vec2(x: 10, y: 10), b: Vec2(x: 12, y: 10), newRoom: F.id(53))
            _ = try PlanEditorOps.operations(for: missing, context: context)
        }
        log.throwsError("19 merge with nothing", .nothingToMerge) {
            _ = try PlanEditorOps.operations(for: .mergeRooms([], into: F.roomA), context: context)
        }
    }

    // MARK: - Checks 20 to 23: measurements, annotations, fixtures

    /// Dimensions, annotations, fixture moves, categories and deletion.
    private static func checkAnnotationsAndFixtures(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                                    context: PlanEditorContext) {
        let dimensionID = F.id(60)
        let addDimension = PlanEditAction.addDimension(dimensionID, a: Vec2(x: 0, y: 1), b: Vec2(x: 2, y: 1))
        if let entry = op(addDimension, context, "20 addDimension", &log), let withDimension = F.applied(entry, to: plan) {
            let dimension = F.level(withDimension)?.dimensions.first { $0.id == dimensionID }
            log.expect("20 user dimension added", dimension?.isUser == true)
            let removed = op(.deleteElement(dimensionID), F.context(withDimension, clean), "20 delete dimension", &log)
                .flatMap { F.applied($0, to: withDimension) }
            log.expect("20 dimension deleted", removed != nil
                       && F.level(removed)?.dimensions.contains { $0.id == dimensionID } == false)
        }
        let textID = F.id(61)
        var current = plan
        let steps: [(String, PlanAnnotation)] = [
            ("21 text added", PlanAnnotation(id: textID, kind: .text, at: Vec2(x: 1, y: 1), text: "Tandoor here", symbol: nil)),
            ("21 moved text replaces", PlanAnnotation(id: textID, kind: .text, at: Vec2(x: 2, y: 2), text: "Tandoor here", symbol: nil)),
            ("21 new text replaces", PlanAnnotation(id: textID, kind: .text, at: Vec2(x: 2, y: 2), text: "Oven", symbol: nil))
        ]
        for (name, annotation) in steps {
            guard let entry = op(.setAnnotation(annotation), F.context(current, clean), name, &log),
                  let next = F.applied(entry, to: current) else { continue }
            current = next
            let list = F.level(current)?.annotations ?? []
            log.expect(name, list.count == 1 && list.first == annotation, "\(list.count) annotations")
        }
        let cleared = op(.deleteElement(textID), F.context(current, clean), "21 delete text", &log).flatMap { F.applied($0, to: current) }
        log.expect("21 text deleted", cleared != nil && F.level(cleared)?.annotations.isEmpty == true)
        if let moved = both(.moveFixture(F.sofa, center: Vec2(x: 1, y: 1), yaw: 0.5), context, clean, "22 moveFixture", &log) {
            let fixture = F.level(moved.plan)?.fixtures.first { $0.id == F.sofa }
            log.near("22 fixture x", fixture?.center.x, 1)
            log.near("22 fixture y", fixture?.center.y, 1)
            log.near("22 fixture yaw", fixture?.yaw, 0.5)
            let object = moved.clean.rooms.flatMap { $0.objects }.first { $0.id == F.sofa }
            log.near("22 clean height kept", object?.transform.translation.y, F.sofaHeight)
        }
        if let chair = both(.recategorizeFixture(F.sofa, .chair), context, clean, "23 recategorize", &log) {
            let fixture = F.level(chair.plan)?.fixtures.first { $0.id == F.sofa }
            let object = chair.clean.rooms.flatMap { $0.objects }.first { $0.id == F.sofa }
            log.expect("23 chair in both", fixture?.category == .chair && object?.category == .chair)
        }
        if let gone = both(.deleteFixture(F.sofa), context, clean, "23 deleteFixture", &log) {
            let inPlan = F.level(gone.plan)?.fixtures.contains { $0.id == F.sofa } ?? true
            let inClean = gone.clean.rooms.contains { room in room.objects.contains { $0.id == F.sofa } }
            log.expect("23 sofa deleted in both", !inPlan && !inClean)
        }
    }
}
