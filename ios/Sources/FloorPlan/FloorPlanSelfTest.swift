import Foundation
import simd

/// Plain-Swift checks for the FloorPlan module (no XCTest), run from Settings > Diagnostics
/// off the main thread. Deterministic, no ARKit, camera or network; temporary files only
/// under `FileManager.default.temporaryDirectory`, removed afterwards.
enum FloorPlanSelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var log = FloorPlanSelfTestLog()
        builderChecks(&log)
        editChecks(&log)
        storeChecks(&log)
        drawingChecks(&log)
        interactionChecks(&log)
        renderChecks(&log)
        return log.failures
    }

    /// The plan of the 4 x 5 fixture room.
    static func rectanglePlan() -> PlanModel {
        PlanBuilder.build(from: FloorPlanSelfTestFixtures.rectangleModel(), floors: FloorPlanSelfTestFixtures.floors)
    }

    /// PlanBuilder: levels, room, walls, dimensions, openings, fixtures, axes, flips, L shape.
    private static func builderChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let plan = rectanglePlan()
        log.expect("build.levelCount", plan.levels.count == 1, "got \(plan.levels.count)")
        guard let level = plan.levels.first else { return }
        log.expect("build.levelIndex", level.id == 0, "got \(level.id)")
        log.expect("build.roomCount", level.rooms.count == 1, "got \(level.rooms.count)")
        log.near("build.roomArea", level.rooms.first?.area ?? 0, 20, tolerance: 1e-3)
        log.expect("build.roomNameNotBaked", level.rooms.first?.name == "", "got \(level.rooms.first?.name ?? "nil")")
        log.expect("build.wallCount", level.walls.count == 4, "got \(level.walls.count)")

        let center = SIMD2<Float>(2, 2.5)
        let leftOK = level.walls.allSatisfy { wall in
            let d = wall.b.simd - wall.a.simd
            return Segment2D.cross(d, center - wall.a.simd) > 0
        }
        log.expect("build.wallsRoomOnLeft", leftOK)
        var loopArea: Float = 0
        for wall in level.walls { loopArea += Segment2D.cross(wall.a.simd, wall.b.simd) / 2 }
        log.near("build.wallsCounterClockwise", loopArea, 20, tolerance: 1e-3)

        let generated = level.dimensions.filter { !$0.isUser }
        let wallDims = generated.filter { $0.offset > 0 }
        log.expect("build.wallDimensionCount", wallDims.count == 4, "got \(wallDims.count)")
        let matched = level.walls.allSatisfy { wall in
            wallDims.contains { $0.id == PlanBuilder.wallDimensionID(wall.id) && $0.a == wall.a && $0.b == wall.b }
        }
        log.expect("build.wallDimensionsFollowWalls", matched)
        log.expect("build.wallDimensionOffset", wallDims.allSatisfy { abs($0.offset - 0.3) < 1e-6 })
        let overall = generated.filter { $0.offset < 0 }
        log.expect("build.overallDimensionCount", overall.count == 2, "got \(overall.count)")
        let overallLengths = overall.map { $0.length }.sorted()
        let shortSide: Float = overallLengths.first ?? 0
        let longSide: Float = overallLengths.last ?? 0
        let sidesOK = overallLengths.count == 2 && abs(shortSide - 4) < 0.001 && abs(longSide - 5) < 0.001
        log.expect("build.overallLengths", sidesOK, "got \(overallLengths)")

        let door = level.openings.first { $0.id == F.door }
        log.expect("build.doorOpening", door?.kind == .door && door?.wallID == F.southWall)
        log.near("build.doorOffset", door?.offset ?? -1, 1.0)
        log.near("build.doorWidth", door?.width ?? -1, 0.9)
        log.expect("build.doorSwing", door?.swing == DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .estimated))
        let window = level.openings.first { $0.id == F.window }
        let windowOnEastWall = window?.wallID == F.eastWall
        log.expect("build.windowOpening", window?.kind == .window && windowOnEastWall && window?.swing == nil)
        log.near("build.windowOffset", window?.offset ?? -1, 2.0)

        log.expect("build.fixtureCount", level.fixtures.count == 3, "got \(level.fixtures.count)")
        let sofa = level.fixtures.first { $0.id == F.sofa }
        log.expect("build.sofaMovable", sofa?.isMovable == true && sofa?.isHidden == false)
        log.near("build.sofaCenterX", sofa?.center.x ?? -1, 2)
        log.near("build.sofaCenterY", sofa?.center.y ?? -1, 4.4)
        log.near("build.sofaWidth", sofa?.size.x ?? -1, 2)
        let sink = level.fixtures.first { $0.id == F.sink }
        log.expect("build.sinkFixture", sink?.isMovable == false)
        let table = level.fixtures.first { $0.id == F.hiddenTable }
        log.expect("build.hiddenKept", table?.isHidden == true)

        let axis = PlanAxes.toPlan(SIMD3<Float>(1, 0, -3))
        log.expect("build.planAxesSign", axis.x == 1 && axis.y == 3, "got \(axis)")
        log.expect("build.planAxesInverse", PlanAxes.toWorld(SIMD2<Float>(1, 3), y: 0).z == -3)
        log.expect("build.deterministic", rectanglePlan() == plan)

        let flipped = PlanBuilder.build(from: F.flippedWallModel(), floors: F.floors)
        let south = flipped.levels.first?.walls.first { $0.id == F.southWall }
        log.expect("build.flippedWallReversed", south?.a == Vec2(x: 0, y: 0) && south?.b == Vec2(x: 4, y: 0),
                   "got \(String(describing: south?.a)) -> \(String(describing: south?.b))")
        let flippedDoor = flipped.levels.first?.openings.first { $0.id == F.door }
        log.near("build.flippedDoorOffset", flippedDoor?.offset ?? -1, 1.0)
        log.expect("build.flippedDoorHinge", flippedDoor?.swing?.hingeAtStart == false)
        let span = south?.occludedSpans.first
        let spanLower: Float = span?.lowerBound ?? -1
        let spanUpper: Float = span?.upperBound ?? -1
        let spanOK = abs(spanLower - 3) < 0.0001 && abs(spanUpper - 3.5) < 0.0001
        log.expect("build.flippedOccludedSpan", spanOK, "got \(String(describing: span))")

        let lShape = PlanBuilder.build(from: F.lShapedModel(), floors: F.floors)
        let lLevel = lShape.levels.first
        let lRoom = lLevel?.rooms.first
        log.near("build.lShapeArea", lRoom?.area ?? 0, 16, tolerance: 1e-3)
        let lOutline = Polygon2D(points: lRoom?.outline.map { $0.simd } ?? [])
        log.expect("build.lShapeLabelInside", lRoom.map { lOutline.contains(point: $0.labelAt.simd) } ?? false)
        let cleanLWalls = F.lShapedModel().rooms.first?.walls ?? []
        var notFlipped = !cleanLWalls.isEmpty
        for clean in cleanLWalls {
            let planWall = lLevel?.walls.first { $0.id == clean.id }
            if planWall?.a != PlanAxes.toPlan(clean.start) { notFlipped = false }
        }
        log.expect("build.lShapeWallsKeepDirection", notFlipped)

        var noSwing = F.rectangleModel()
        noSwing.rooms[0].openings[0].swing = nil
        let defaulted = PlanBuilder.build(from: noSwing, floors: F.floors).levels.first?.openings.first { $0.id == F.door }
        let defaultSwing = defaulted?.swing
        log.expect("build.defaultSwingEstimated", defaultSwing?.source == .estimated && defaultSwing?.hingeAtStart == true)

        let roundTrip = (try? ProjectStore.encoder.encode(plan)).flatMap { try? ProjectStore.decoder.decode(PlanModel.self, from: $0) }
        log.expect("build.codableRoundTrip", roundTrip == plan)
    }

    /// PlanModel.apply for every operation that concerns the plan, orphans and replay.
    private static func editChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let base = rectanglePlan()
        /// The fixture plan with one operation applied, and its result.
        func applied(_ op: EditOperation) -> (ok: Bool, plan: PlanModel) {
            var plan = base
            let ok = plan.apply(op)
            return (ok, plan)
        }
        /// The first level of a plan.
        func level(_ plan: PlanModel) -> PlanLevel? { plan.levels.first }

        let renamed = applied(.renameRoom(room: F.roomID, name: "Den"))
        log.expect("edit.rename", renamed.ok && level(renamed.plan)?.rooms.first?.name == "Den")

        let hidden = applied(.setHidden(element: F.sofa, hidden: true))
        let hiddenSofa = level(hidden.plan)?.fixtures.first { $0.id == F.sofa }
        log.expect("edit.hideFixture", hidden.ok && hiddenSofa?.isHidden == true)

        let deleted = applied(.deleteElement(element: F.eastWall))
        let deletedLevel = level(deleted.plan)
        let eastDimensionID = PlanBuilder.wallDimensionID(F.eastWall)
        let wallGone = deletedLevel?.walls.count == 3
        let windowGone = deletedLevel?.openings.contains { $0.id == F.window } == false
        let dimensionGone = deletedLevel?.dimensions.contains { $0.id == eastDimensionID } == false
        log.expect("edit.deleteWall", deleted.ok && wallGone && windowGone && dimensionGone)

        let moved = applied(.moveWallEndpoint(wall: F.southWall, atStart: false, to: Vec2(x: 4.5, y: 0)))
        let movedLevel = level(moved.plan)
        let movedWall = movedLevel?.walls.first { $0.id == F.southWall }
        log.expect("edit.moveEndpoint", moved.ok && movedWall?.b == Vec2(x: 4.5, y: 0))
        let movedDimension = movedLevel?.dimensions.first { $0.id == PlanBuilder.wallDimensionID(F.southWall) }
        log.expect("edit.moveEndpointMovesDimension", movedDimension?.b == Vec2(x: 4.5, y: 0))
        log.expect("edit.moveEndpointMovesOutline", (movedLevel?.rooms.first?.area ?? 0) > 20.5)

        let newWall = PlanWall(id: F.id(50), a: Vec2(x: 1, y: 1), b: Vec2(x: 1, y: 3), thickness: 0.1, thicknessSource: .user,
                               arc: nil, provenance: .user, occludedSpans: [])
        let added = applied(.addWall(wall: newWall, level: 0))
        let newWallDimensionID = PlanBuilder.wallDimensionID(newWall.id)
        let wallAdded = level(added.plan)?.walls.count == 5
        let dimensionAdded = level(added.plan)?.dimensions.contains { $0.id == newWallDimensionID } == true
        log.expect("edit.addWall", added.ok && wallAdded && dimensionAdded)
        log.expect("edit.addWallMissingLevel", applied(.addWall(wall: newWall, level: 7)).ok == false)

        let newOpening = PlanOpening(id: F.id(51), wallID: F.northWall, kind: .window, offset: 0.5, width: 1, swing: nil)
        let opened = applied(.addOpening(opening: newOpening, level: 0))
        log.expect("edit.addOpening", opened.ok && level(opened.plan)?.openings.contains(newOpening) == true)
        var strayOpening = newOpening
        strayOpening.wallID = F.id(998)
        log.expect("edit.addOpeningMissingWall", applied(.addOpening(opening: strayOpening, level: 0)).ok == false)

        let userSwing = DoorSwing(hingeAtStart: false, opensToNormalSide: false, source: .user)
        let swung = applied(.setDoorSwing(door: F.door, swing: userSwing))
        let swungDoor = level(swung.plan)?.openings.first { $0.id == F.door }
        log.expect("edit.swing", swung.ok && swungDoor?.swing == userSwing)

        let thick = applied(.setWallThickness(wall: F.northWall, thickness: 0.2))
        let thickWall = level(thick.plan)?.walls.first { $0.id == F.northWall }
        let userThickness = thickWall?.thicknessSource == .user
        log.expect("edit.thickness", thick.ok && thickWall?.thickness == 0.2 && userThickness)

        let note = PlanAnnotation(id: F.id(52), kind: .note, at: Vec2(x: 1, y: 1), text: "Note", symbol: nil)
        let annotated = applied(.addAnnotation(annotation: note, level: 0))
        log.expect("edit.annotation", annotated.ok && level(annotated.plan)?.annotations == [note])

        let userDimension = PlanDimension(id: F.id(53), a: Vec2(x: 0, y: 0), b: Vec2(x: 4, y: 5), offset: 0, isUser: true)
        let dimensioned = applied(.addDimension(dimension: userDimension, level: 0))
        log.expect("edit.dimension", dimensioned.ok && level(dimensioned.plan)?.dimensions.contains(userDimension) == true)

        let recategorized = applied(.recategorizeObject(object: F.sofa, category: .bathtub))
        let recategorizedFixture = level(recategorized.plan)?.fixtures.first { $0.id == F.sofa }
        let fixtureNow = recategorizedFixture?.isMovable == false
        log.expect("edit.recategorize", recategorized.ok && recategorizedFixture?.category == .bathtub && fixtureNow)

        let quarter = Float.pi / 2
        let relocated = applied(.moveObject(object: F.sofa, transform: F.pose(at: SIMD2<Float>(1, 1), yaw: quarter)))
        let relocatedFixture = level(relocated.plan)?.fixtures.first { $0.id == F.sofa }
        log.expect("edit.moveFixture", relocated.ok && relocatedFixture?.center == Vec2(x: 1, y: 1))
        log.near("edit.moveFixtureYaw", relocatedFixture?.yaw ?? 0, quarter)

        let orphan = applied(.renameRoom(room: F.id(999), name: "Nowhere"))
        log.expect("edit.orphanReturnsFalse", orphan.ok == false && orphan.plan == base)
        let otherModel = applied(.setScaleCorrection(room: F.roomID, factor: 1.1))
        log.expect("edit.otherModelUnchanged", otherModel.ok && otherModel.plan == base)
        let relabel = applied(.relabelObject(object: F.sofa, label: "Couch"))
        log.expect("edit.relabelUnchanged", relabel.ok && relabel.plan == base)

        var editLog = EditLog()
        editLog.append(.renameRoom(room: F.roomID, name: "Den"))
        editLog.append(.deleteElement(element: F.id(997)))
        let replayed = editLog.applied(to: base)
        log.expect("edit.replayOrphans", replayed.orphaned.count == 1 && replayed.0.levels.first?.rooms.first?.name == "Den")
    }

    /// PlanModelStore: save, load base, load edited (with and without an edit log), in a
    /// temporary package that is removed afterwards.
    private static func storeChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorPlanSelfTest." + ProjectPackage.fileExtension, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ProjectPackage(root: root)
        let plan = rectanglePlan()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try PlanModelStore.save(plan, to: package)
            let loaded = try PlanModelStore.loadBase(package)
            log.expect("store.loadBase", loaded == plan)
            let unedited = try PlanModelStore.loadEdited(package)
            log.expect("store.loadEditedWithoutLog", unedited.plan == plan && unedited.orphaned.isEmpty)
            var editLog = EditLog()
            editLog.append(.renameRoom(room: F.roomID, name: "Den"))
            editLog.append(.setHidden(element: F.id(996), hidden: true))
            try ProjectStore.writeJSON(editLog, to: package.editLogURL)
            let edited = try PlanModelStore.loadEdited(package)
            log.expect("store.loadEditedApplies", edited.plan.levels.first?.rooms.first?.name == "Den")
            log.expect("store.loadEditedOrphans", edited.orphaned.count == 1, "got \(edited.orphaned.count)")
        } catch {
            log.expect("store.roundTrip", false, "\(error)")
        }
        let missing = ProjectPackage(root: root.appendingPathComponent("missing", isDirectory: true))
        var refused = false
        do {
            try PlanModelStore.save(plan, to: missing)
        } catch {
            refused = true
        }
        log.expect("store.noGhostPackage", refused && !FileManager.default.fileExists(atPath: missing.root.path))
    }
}
