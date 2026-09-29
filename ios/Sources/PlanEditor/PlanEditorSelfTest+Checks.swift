import Foundation
import simd

/// PlanEditor self-test checks 24 to 35 and extras: Reset to Scan, entries and undo, paired
/// walls, snapping, locked walls, swings, fixture poses and the texts.
extension PlanEditorSelfTest {
    // MARK: - Checks 24 to 27: reset filter, entries, undo, paired walls

    /// `isPlanEdit`, one entry per action, one Undo per action, the paired face.
    static func checkLogAndPairs(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                                 context: PlanEditorContext) {
        let move = EditOperation.moveWallEndpoint(wall: F.w1, atStart: true, to: Vec2.zero)
        let alignment = RoomAlignmentRecord(roomID: F.roomA.uuid, yaw: 0.1, translation: Vec3.zero, source: .user)
        let box = OrientedBoxRecord(OrientedBox(center: .zero, axes: matrix_identity_float3x3,
                                                halfExtents: SIMD3<Float>(repeating: 0.5)))
        log.expect("24 wall move is a plan edit", PlanEditorOps.isPlanEdit(move))
        log.expect("24 batch of wall moves is a plan edit", PlanEditorOps.isPlanEdit(.batch(operations: [move, move])))
        let kept: [EditOperation] = [
            .setScaleCorrection(room: F.roomA, factor: 1.02), .setRoomAlignment(alignment),
            .cropObject(object: F.sofa, box: box), .relabelObject(object: F.sofa, label: "Couch"),
            .recategorizeObject(object: F.sofa, category: .chair)
        ]
        for op in kept {
            log.expect("24 \(PlanEditorOps.kindName(op)) survives a reset", !PlanEditorOps.isPlanEdit(op))
        }
        let alignments = EditOperation.batch(operations: [.setRoomAlignment(alignment), .setRoomAlignment(alignment)])
        log.expect("24 batch of alignments survives a reset", !PlanEditorOps.isPlanEdit(alignments))

        let rename = op(.renameRoom(F.roomA, name: "Den"), context, "25 rename", &log)
        log.expect("25 rename is a single operation", rename.map { !isBatch($0) } ?? false)
        let moveWall = op(.moveWall(F.w3, by: -0.3), context, "25 moveWall", &log)
        log.expect("25 moveWall is a batch", moveWall.map { isBatch($0) } ?? false)

        if let entry = moveWall {
            var editLog = EditLog()
            editLog.append(entry)
            let moved = editLog.applied(to: plan).0
            editLog.undo()
            let undone = editLog.applied(to: plan).0
            log.expect("26 the move changed the plan", moved != plan)
            log.expect("26 one Undo gives back the base plan", undone == plan)
        }

        if let level = F.level(plan), let w2 = F.planWall(F.w2, plan) {
            log.expect("27 W2 pairs with B4", PlanEditorOps.pairedWall(of: w2, in: level)?.id == F.b4)
        }
        if let shared = both(.moveWall(F.w2, by: 0.3), context, clean, "27 moveWall W2", &log) {
            log.expect("27 eight operations with the paired wall", F.operationCount(shared.op) == 8,
                       "\(F.operationCount(shared.op)) operations")
            let w2x = F.planWall(F.w2, shared.plan)?.a.x
            let b4x = F.planWall(F.b4, shared.plan)?.a.x
            log.near("27 W2 moved to 3.7", w2x, 3.7)
            log.near("27 gap stays 0.12", b4x.flatMap { b in w2x.map { b - $0 } }, 0.12)
            log.near("27 room B grows", F.planRoom(F.roomB, shared.plan)?.area, 13.2, tolerance: 1e-3)
        }
    }

    // MARK: - Checks 28 and 29: snapping

    /// End, wall, angle and grid snapping and the reference axis.
    static func checkSnapping(_ log: inout PlanEditorSelfTestLog, plan: PlanModel) {
        guard let level = F.level(plan) else { return }
        let targets = PlanEditorSnapping.targets(level: level, excluding: [])
        let radius = PlanEditorSnapping.endpointRadius
        let grid = PlanEditorSnapping.metricGrid
        let end = PlanEditorSnapping.snap(SIMD2<Float>(4, 0.03), anchor: nil, targets: targets, radius: radius,
                                          grid: grid, enabled: true)
        log.expect("28 3 cm from a wall end snaps to it", end.kind == .endpoint && end.point == SIMD2<Float>(4, 0), "\(end)")
        let wall = PlanEditorSnapping.snap(SIMD2<Float>(2, 0.03), anchor: nil, targets: targets, radius: radius,
                                           grid: grid, enabled: true)
        log.expect("28 3 cm from a wall snaps to the foot", wall.kind == .wall && simd_distance(wall.point, SIMD2<Float>(2, 0)) < 1e-5,
                   "\(wall)")
        let tilt: Float = 3 * Float.pi / 180
        let anchor = SIMD2<Float>(1, 1)
        let off = anchor + SIMD2<Float>(cos(tilt), sin(tilt)) * 1.5
        let angled = PlanEditorSnapping.snap(off, anchor: anchor, targets: targets, radius: radius, grid: grid, enabled: true)
        log.expect("28 3 degrees off the axis snaps to the angle",
                   angled.kind == .angle && simd_distance(angled.point, SIMD2<Float>(2.5, 1)) < 1e-4, "\(angled)")
        let free = SIMD2<Float>(1.23, 2.34)
        let metric = PlanEditorSnapping.snap(free, anchor: nil, targets: targets, radius: radius, grid: grid, enabled: true)
        log.expect("28 grid 0.1 m in the axis frame", metric.kind == .grid && simd_distance(metric.point, SIMD2<Float>(1.2, 2.3)) < 1e-4,
                   "\(metric)")
        let inch = PlanEditorSnapping.imperialGrid
        let imperial = PlanEditorSnapping.snap(free, anchor: nil, targets: targets, radius: radius, grid: inch, enabled: true)
        let expected = SIMD2<Float>(48 * inch, 92 * inch)
        log.expect("28 grid 1 inch in the axis frame", imperial.kind == .grid && simd_distance(imperial.point, expected) < 1e-4,
                   "\(imperial)")
        let off2 = PlanEditorSnapping.snap(free, anchor: anchor, targets: targets, radius: radius, grid: grid, enabled: false)
        log.expect("28 snapping off gives none", off2.kind == .none && off2.point == free)
        log.near("28 snapDistance rounds to the grid", PlanEditorSnapping.snapDistance(0.234, grid: grid, enabled: true), 0.2)
        let metricPrefs = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)
        log.near("28 metric grid step", PlanEditorSnapping.gridStep(metricPrefs), 0.1)
        log.near("28 imperial grid step", PlanEditorSnapping.gridStep(.standard), 0.0254)

        let angle: Float = Float.pi / 6
        let u = SIMD2<Float>(cos(angle), sin(angle))
        let v = SIMD2<Float>(-u.y, u.x)
        let corners = [SIMD2<Float>(0, 0), u * 3, u * 3 + v * 5, v * 5]
        var rotated = level
        rotated.walls = []
        for i in 0..<4 {
            rotated.walls.append(PlanWall(id: F.id(70 + i), a: Vec2(corners[i]), b: Vec2(corners[(i + 1) % 4]), thickness: 0.1,
                                          thicknessSource: .estimated, arc: nil, provenance: .measured, occludedSpans: []))
        }
        let axis = PlanEditorSnapping.referenceAxis(rotated)
        log.expect("29 axis of a room turned 30 degrees is its longest wall", simd_distance(axis, v) < 1e-4, "\(axis)")
    }

    // MARK: - Checks 30, 34, 35 and extras: helpers

    /// Locked walls, swings, fixture poses, plan-only deletions and refusals.
    static func checkHelpers(_ log: inout PlanEditorSelfTestLog, plan: PlanModel, clean: CleanModel,
                             context: PlanEditorContext) {
        log.expect("30 no locked walls for a consistent pair", PlanEditorOps.lockedWalls(plan: plan, clean: clean).isEmpty)
        var swapped = plan
        _ = swapped.updateWall(F.w1) { wall in
            let a = wall.a
            wall.a = wall.b
            wall.b = a
        }
        log.expect("30 swapped wall is locked", PlanEditorOps.lockedWalls(plan: swapped, clean: clean) == [F.w1])

        let estimated = PlanBuilder.defaultSwing(offset: 0.5, width: 0.81, wallLength: 4)
        let fromNil = PlanEditorOps.nextSwing(nil, offset: 0.5, width: 0.81, wallLength: 4)
        let fromDefault = PlanEditorOps.nextSwing(estimated, offset: 0.5, width: 0.81, wallLength: 4)
        log.expect("34 nil swing starts from the default", fromNil == fromDefault && fromNil.source == .user)
        var swing = fromNil
        for _ in 0..<4 { swing = PlanEditorOps.nextSwing(swing, offset: 0.5, width: 0.81, wallLength: 4) }
        log.expect("34 four steps close the cycle", swing == fromNil)

        if let sofa = PlanEditorOps.cleanObject(F.sofa, in: clean) {
            let transform = PlanEditorOps.objectTransform(sofa, center: Vec2(x: 1, y: 1), yaw: 0.5)
            var moved = sofa
            moved.transform = transform
            let before = sofa.orientedBox
            let after = moved.orientedBox
            log.expect("35 box size kept", simd_distance(before.halfExtents, after.halfExtents) < 1e-5)
            log.near("35 world y kept", transform.translation.y, F.sofaHeight)
            let pose = PlanBuilder.planPose(of: transform)
            log.expect("35 plan pose is the requested one",
                       simd_distance(pose.center, SIMD2<Float>(1, 1)) < 1e-4 && abs(pose.yaw - 0.5) < 1e-4, "\(pose)")
        } else {
            log.expect("35 sofa in the fixture", false)
        }

        let dimensionDelete = EditOperation.deleteElement(element: F.id(60))
        log.expect("extra deleting a dimension is plan only", PlanEditorOps.isPlanOnly(dimensionDelete, clean: clean))
        log.expect("extra deleting a wall is not plan only", !PlanEditorOps.isPlanOnly(.deleteElement(element: F.w1), clean: clean))
        log.throwsError("extra opening on a missing wall", .notFound) {
            let action = PlanEditAction.addOpening(F.id(54), kind: .window, wall: F.id(99), center: 1, width: 1)
            _ = try PlanEditorOps.operations(for: action, context: context)
        }
        log.throwsError("extra wall thickness out of range", .outOfRange) {
            _ = try PlanEditorOps.operations(for: .setWallThickness(F.w1, thickness: 3), context: context)
        }
        log.throwsError("extra short wall refused", .tooShort) {
            let action = PlanEditAction.addWall(F.id(55), a: Vec2(x: 1, y: 1), b: Vec2(x: 1.01, y: 1))
            _ = try PlanEditorOps.operations(for: action, context: context)
        }
        var twoLevels = plan
        let upstairs = PlanRoom(id: F.id(80), name: "", outline: [Vec2(x: 0, y: 0), Vec2(x: 3, y: 0), Vec2(x: 3, y: 3)],
                                labelAt: Vec2(x: 2, y: 1), area: 4.5)
        twoLevels.levels.append(PlanLevel(id: 1, name: "", elevation: 2.8, rooms: [upstairs], walls: [], openings: [],
                                          fixtures: [], annotations: [], dimensions: []))
        log.throwsError("extra rooms on two floors refused", .notOnLevel) {
            _ = try PlanEditorOps.operations(for: .mergeRooms([F.id(80)], into: F.roomA), context: F.context(twoLevels, clean))
        }
        if let entry = op(.moveWall(F.w3, by: -0.3), context, "extra log line", &log) {
            let line = PlanEditorOps.logLine(.moveWall(F.w3, by: -0.3), op: entry)
            log.expect("extra log line names the action and batch", line.hasPrefix("moveWall: batch["), line)
        }
    }

    // MARK: - Checks 31 to 33 and extras: texts

    /// Descriptions, messages, typed lengths, titles, hints and prompt ids.
    static func checkPresentation(_ log: inout PlanEditorSelfTestLog, plan: PlanModel) {
        let every = F.everyOperation()
        let texts = every.map { PlanEditorPresentation.describe($0) }
        log.expect("31 twenty operation cases", every.count == 20, "\(every.count)")
        log.expect("31 descriptions are non-empty", texts.allSatisfy { !$0.isEmpty })
        log.expect("31 descriptions are distinct", Set(texts).count == texts.count)
        if let first = every.first {
            let batch = EditOperation.batch(operations: [first, every[every.count - 1]])
            log.expect("31 a batch reads as its first operation", PlanEditorPresentation.describe(batch) == texts[0])
        }
        log.expect("31 an empty batch has a text", !PlanEditorPresentation.describe(.batch(operations: [])).isEmpty)

        let prefs = UnitPreferences.standard
        let errors: [PlanEditorError] = [.notFound, .tooShort, .outOfRange, .curvedWall, .lockedWall, .splitMissesRoom,
                                         .nothingToMerge, .notOnLevel]
        let messages = errors.map { PlanEditorPresentation.message(for: $0, prefs: prefs) }
        log.expect("32 every refusal has a message", messages.allSatisfy { !$0.isEmpty })
        let minimum = LengthFormat.primary(0.05, prefs: prefs)
        log.expect("32 too short names the minimum length",
                   PlanEditorPresentation.message(for: .tooShort, prefs: prefs).contains(minimum), minimum)

        let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)
        let range = PlanEditorOps.wallLengthRange
        log.near("33 3.8 m accepted", PlanEditorPresentation.parseLength("3.8 m", prefs: metric, range: range), 3.8)
        log.near("33 12' 6\" accepted", PlanEditorPresentation.parseLength("12' 6\"", prefs: prefs, range: range), 3.81)
        log.expect("33 abc rejected", PlanEditorPresentation.parseLength("abc", prefs: metric, range: range) == nil)
        log.expect("33 -2 m rejected", PlanEditorPresentation.parseLength("-2 m", prefs: metric, range: range) == nil)
        log.expect("33 200 m rejected", PlanEditorPresentation.parseLength("200 m", prefs: metric, range: range) == nil)
        log.expect("33 unreadable text explains itself",
                   PlanEditorPresentation.lengthProblem("abc", prefs: metric, range: range) == Copy.PlanEditor.invalidLength)

        let titles = PlanEditorCommand.allCases.map { PlanEditorPresentation.title($0, item: nil) }
        log.expect("extra every command has a title", titles.allSatisfy { !$0.isEmpty })
        let tools: [PlanEditTool] = [.select, .addWall, .addOpening(.door), .addDimension, .addAnnotation(.note),
                                     .splitRoom(F.roomA), .mergeRooms(into: F.roomA)]
        log.expect("extra every tool has a hint", tools.allSatisfy { PlanEditorPresentation.hint(for: $0, pending: 0) != nil })
        let prompts: [PlanEditorPrompt] = [
            .wallLength(F.w1, current: 4), .wallThickness(F.w1, current: 0.1), .openingSize(F.door, width: 0.81, height: nil),
            .renameRoom(F.roomA, current: ""), .annotation(kind: .text, at: Vec2.zero, editing: nil, current: ""),
            .category(F.sofa, current: .sofa), .resetConfirmation
        ]
        log.expect("extra prompt ids are distinct", Set(prompts.map { $0.id }).count == prompts.count)
        if let level = F.level(plan), let wall = F.planWall(F.w2, plan) {
            let title = PlanEditorPresentation.itemTitle(.wall(wall), level: level, roomTitles: [:])
            log.expect("extra second wall reads Wall 2", title == Copy.MeasureCore.wallTitle(2), title)
        }
        log.expect("extra eight symbols", PlanEditorPresentation.symbols.count == 8 && Set(PlanEditorPresentation.symbols).count == 8)
        let level = PlanLevel(id: 1, name: "", elevation: 0, rooms: [], walls: [], openings: [], fixtures: [], annotations: [],
                              dimensions: [])
        log.expect("extra unnamed level title", PlanEditorPresentation.levelTitle(level) == Copy.House.floorLabel(2))
    }
}
