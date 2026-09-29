import Foundation
import simd

// RoomModelSelfTest, build 5 revision (docs/MODULES.md 3.37b): the wall orientation invariant
// and the CR-1 operations (move and resize openings, merge and split rooms, batches).

extension RoomModelSelfTestFixtures {
    /// Wall ids of the 3 x 4 m side room east of the rectangle: 71 runs (5,0)-(8,0), 72
    /// (8,0)-(8,4), 73 (8,4)-(5,4), 74 (5,4)-(5,0).
    static let sideRoomWalls = [71, 72, 73, 74]
    /// Partition wall inside the rectangle, given from (3, 3.5) to (3, 1) (room on its right).
    static let partitionID = 31
    /// Door on the partition from plan y 2.5 to 3.3.
    static let partitionDoorID = 15

    /// The 3 x 4 m room next to the rectangle (plan x 5 to 8, y 0 to 4), no openings or objects.
    static func sideRoom() -> RoomInput {
        let p: [SIMD2<Float>] = [[5, 0], [8, 0], [8, 4], [5, 4]]
        var walls: [SurfaceInput] = []
        for i in 0..<p.count { walls.append(wall(sideRoomWalls[i], p[i], p[(i + 1) % p.count])) }
        return RoomInput(identifier: uuid(103), walls: walls, openings: [], floors: [floor(p, y: 0)], objects: [],
                         sections: [], story: 0)
    }

    /// The rectangle plus a stray partition whose left side faces away from the room center,
    /// with a door on it.
    static func withPartition() -> RoomInput {
        var input = rectangle()
        input.walls.append(wall(partitionID, [3, 3.5], [3, 1]))
        input.openings.append(opening(partitionDoorID, kind: .door, parent: partitionID, [3, 2.5], [3, 3.3],
                                      bottom: 0, top: 2.0))
        return input
    }

    /// The rectangle with its first input wall (wall 3) missing, so the loop does not close.
    static func openLoop() -> RoomInput {
        var input = rectangle()
        input.walls.removeFirst()
        return input
    }
}

extension RoomModelSelfTest {
    /// Build 5 checks: orientation, opening edits, room edits.
    static func b5Checks(_ c: inout Checker) {
        orientationChecks(&c)
        openingEditChecks(&c)
        mergeChecks(&c)
        splitChecks(&c)
        batchChecks(&c)
    }

    /// True when the wall's normal is the horizontal left perpendicular of start -> end in plan.
    static func hasLeftNormal(_ wall: CleanWall) -> Bool {
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let d = Segment2D(a: a, b: b).direction
        let left = SIMD2<Float>(-d.y, d.x)
        return near(PlanAxes.toPlan(wall.normal.simd), left, 1e-4) && abs(wall.normal.y) <= 1e-6
    }

    /// The rectangle (record 300, doors and sofa) next to the side room (record 301).
    static func twoRoomModel(sideFloor: Int = 0) -> CleanModel {
        CleanModelBuilder.buildModel([(input: F.rectangle(doors: true, sofa: true), record: F.record(300)),
                                      (input: F.sideRoom(), record: F.record(301, floorIndex: sideFloor))], meshes: [:])
    }

    // MARK: - Orientation

    /// Stray walls reversed with the left normal, on every fixture; arcs and openings follow.
    static func orientationChecks(_ c: inout Checker) {
        let stubRoom = build(F.withStub())
        let stub = stubRoom.walls.first { $0.id == wid(F.stubID) }
        let stubStart = stub.map { PlanAxes.toPlan($0.start.simd) } ?? .zero
        let stubEnd = stub.map { PlanAxes.toPlan($0.end.simd) } ?? .zero
        c.check("b5.strayReversed", near(stubStart, [4.76, 3.76], 1e-3) && near(stubEnd, [4.97, 3.97], 1e-3),
                "\(stubStart) -> \(stubEnd)")
        c.check("b5.strayLeftNormal", stub.map { hasLeftNormal($0) } ?? false)
        c.check("b5.strayFacesRoom", stub.map { normalPointsInside($0, stubRoom.floor.outline) } ?? false)

        let fixtures: [(name: String, input: RoomInput)] = [
            ("rectangle", F.rectangle(doors: true, window: true, orphanOpening: true)), ("lShape", F.lShape()),
            ("stub", F.withStub()), ("flipped", F.rectangle(flippedWall: 2)), ("curved", F.curved()),
            ("openLoop", F.openLoop()), ("partition", F.withPartition())
        ]
        for fixture in fixtures {
            let room = build(fixture.input)
            let allLeft = !room.walls.isEmpty && room.walls.allSatisfy { hasLeftNormal($0) }
            c.check("b5.leftNormal.\(fixture.name)", allLeft, "\(room.walls.count) walls")
        }

        let openRoom = build(F.openLoop())
        let westWall = openRoom.walls.first { $0.id == wid(4) }
        let westStart = westWall.map { PlanAxes.toPlan($0.start.simd) } ?? .zero
        let facing = openRoom.walls.allSatisfy { normalPointsInside($0, openRoom.floor.outline) }
        c.check("b5.openLoopReversedFacesRoom", near(westStart, [0, 4], 1e-3) && facing && openRoom.walls.count == 3,
                "west wall starts at \(westStart)")

        let arc = WallArc(center: Vec3(x: 2, y: 0, z: -4), radius: 2, startAngle: 0, endAngle: Float.pi)
        let segment = WallSegment(id: wid(55), start: [0, 4], end: [4, 4], baseY: 0, height: 2.5, confidence: .high,
                                  completedEdges: 4, arc: arc)
        let curved = CleanModelBuilder.cleanWall(segment, inLoop: false, reference: [2, 2], geometry: .measured,
                                                 options: CleanBuildOptions())
        let swapped = near(PlanAxes.toPlan(curved.start.simd), [4, 4], 1e-5) && near(PlanAxes.toPlan(curved.end.simd), [0, 4], 1e-5)
        c.check("b5.curvedStrayKeepsArc", swapped && curved.arc == arc)
        c.check("b5.curvedStrayLeftNormal", hasLeftNormal(curved) && near(PlanAxes.toPlan(curved.normal.simd), [0, -1], 1e-5))
        let loopWall = CleanModelBuilder.cleanWall(segment, inLoop: true, reference: [2, 2], geometry: .measured,
                                                   options: CleanBuildOptions())
        c.check("b5.loopWallNeverReversed", near(PlanAxes.toPlan(loopWall.start.simd), [0, 4], 1e-5) && hasLeftNormal(loopWall))

        let partitioned = build(F.withPartition())
        let partition = partitioned.walls.first { $0.id == wid(F.partitionID) }
        let partitionStart = partition.map { PlanAxes.toPlan($0.start.simd) } ?? .zero
        c.check("b5.partitionReversed", near(partitionStart, [3, 1], 1e-3), "\(partitionStart)")
        let door = partitioned.openings.first { $0.id == wid(F.partitionDoorID) }
        let offsetOK = near(door?.offsetAlongWall ?? -1, 1.5, 1e-3) && near(door?.width ?? -1, 0.8, 1e-3)
        c.check("b5.reversedWallOpeningOffset", door?.wallID == wid(F.partitionID) && offsetOK,
                "\(String(describing: door?.offsetAlongWall))")
    }

    // MARK: - Opening edits

    /// moveOpening and resizeOpening: clamping, center, heights, provenance, missing targets.
    static func openingEditChecks(_ c: inout Checker) {
        let base = editFixture()
        let door = wid(F.doorID)
        var moved = base
        let movedOK = moved.apply(.moveOpening(opening: door, offset: 4.8))
        let far = moved.rooms.first?.openings.first { $0.id == door }
        c.check("b5.moveOpeningClampsHigh", movedOK && near(far?.offsetAlongWall ?? -1, 4.1, 1e-4) && far?.provenance == .user,
                "\(String(describing: far?.offsetAlongWall))")
        _ = moved.apply(.moveOpening(opening: door, offset: -1))
        let low = moved.rooms.first?.openings.first { $0.id == door }
        c.check("b5.moveOpeningClampsLow", low?.offsetAlongWall == 0)
        var untouched = base
        let missing = ElementID(uuid: F.uuid(999))
        let missingMove = untouched.apply(.moveOpening(opening: missing, offset: 1))
        let missingResize = untouched.apply(.resizeOpening(opening: missing, width: 1, sillHeight: 0, headHeight: 2))
        c.check("b5.openingMissingFalse", !missingMove && !missingResize && untouched == base)

        var wallless = base
        if let index = wallless.rooms.first?.openings.firstIndex(where: { $0.id == door }) {
            wallless.rooms[0].openings[index].wallID = nil
        }
        let before = wallless
        c.check("b5.moveOpeningNoWallUnchanged", wallless.apply(.moveOpening(opening: door, offset: 2)) && wallless == before)

        var resized = base
        let resizeOK = resized.apply(.resizeOpening(opening: door, width: 1.2, sillHeight: 0.3, headHeight: 3.0))
        let big = resized.rooms.first?.openings.first { $0.id == door }
        c.check("b5.resizeKeepsCenter", resizeOK && near(big?.width ?? -1, 1.2, 1e-5) && near(big?.offsetAlongWall ?? -1, 0.85, 1e-4),
                "\(String(describing: big?.offsetAlongWall)) \(String(describing: big?.width))")
        c.check("b5.resizeDoorSillZero", big?.sillHeight == 0 && big?.provenance == .user)
        c.check("b5.resizeHeadCapped", near(big?.headHeight ?? -1, 2.5, 1e-5), "\(String(describing: big?.headHeight))")
        _ = resized.apply(.resizeOpening(opening: door, width: 1.0, sillHeight: 1.0, headHeight: 0.5))
        let inverted = resized.rooms.first?.openings.first { $0.id == door }
        let keptHeights = inverted?.sillHeight == 0 && near(inverted?.headHeight ?? -1, 2.5, 1e-5)
        c.check("b5.resizeIgnoresHeadBelowSill", keptHeights && near(inverted?.width ?? -1, 1.0, 1e-5))
        _ = resized.apply(.resizeOpening(opening: door, width: 0.01, sillHeight: 0, headHeight: 2))
        let tiny = resized.rooms.first?.openings.first { $0.id == door }
        c.check("b5.resizeMinimumWidth", near(tiny?.width ?? -1, 0.05, 1e-6), "\(String(describing: tiny?.width))")
        _ = resized.apply(.resizeOpening(opening: door, width: 9, sillHeight: 0, headHeight: 2))
        let wide = resized.rooms.first?.openings.first { $0.id == door }
        c.check("b5.resizeWallLength", near(wide?.width ?? -1, 5, 1e-4) && wide?.offsetAlongWall == 0)

        let windowed = CleanModelBuilder.buildModel([(input: F.rectangle(window: true), record: F.record(300))], meshes: [:])
        var windowModel = windowed
        let window = wid(F.windowID)
        _ = windowModel.apply(.resizeOpening(opening: window, width: 1.0, sillHeight: 0.8, headHeight: 2.0))
        let resizedWindow = windowModel.rooms.first?.openings.first { $0.id == window }
        c.check("b5.resizeWindowKeepsSill", near(resizedWindow?.sillHeight ?? -1, 0.8, 1e-5)
                && near(resizedWindow?.headHeight ?? -1, 2.0, 1e-5))
        let wallArea = windowModel.rooms.first?.metrics.wallArea ?? 0
        c.check("b5.resizeRefreshesMetrics", near(wallArea, 45 - 1.2, 1e-3), "\(wallArea)")
    }

    // MARK: - Merge

    /// mergeRooms: walls, outlines, metrics, mesh, missing and other-floor rooms, wall moves.
    static func mergeChecks(_ c: inout Checker) {
        let base = twoRoomModel()
        let target = ElementID(uuid: F.uuid(300))
        let side = ElementID(uuid: F.uuid(301))
        guard base.rooms.count == 2 else {
            c.check("b5.mergeFixture", false, "\(base.rooms.count) rooms")
            return
        }
        var merged = base
        let mergeOK = merged.apply(.mergeRooms(rooms: [side], into: target))
        let room = merged.rooms.first
        let wallIDs = Set(room?.walls.map { $0.id } ?? [])
        let expected = Set((F.rectangleWalls + F.sideRoomWalls).map { wid($0) })
        c.check("b5.mergeWalls", mergeOK && merged.rooms.count == 1 && wallIDs == expected, "\(wallIDs.count) walls")
        c.check("b5.mergeOneOutline", room?.floor.mergedOutlines?.count == 1)
        let m = room?.metrics ?? .zero
        c.check("b5.mergeArea", near(m.floorArea, 32, 1e-3), "\(m.floorArea)")
        c.check("b5.mergePerimeter", near(m.perimeter, 18 + 14, 1e-3), "\(m.perimeter)")
        c.check("b5.mergeLengthWidth", near(m.length, 8, 1e-3) && near(m.width, 4, 1e-3), "\(m.length) x \(m.width)")
        c.check("b5.mergeVolume", near(m.volume, 32 * 2.5, 1e-2), "\(m.volume)")
        let keeps = room?.id == target && room?.sectionLabel == "livingRoom" && room?.objects.count == 1
        c.check("b5.mergeKeepsTarget", keeps && room?.openings.count == 2)

        let parts = CleanMeshBuilder.parts(for: merged, includeCeiling: true, includeHidden: false)
        let floorArea = parts.filter { $0.kind == .floor }.reduce(Float(0)) { $0 + $1.mesh.surfaceArea }
        let ceilingArea = parts.filter { $0.kind == .ceiling }.reduce(Float(0)) { $0 + $1.mesh.surfaceArea }
        c.check("b5.mergeFloorMesh", near(floorArea, 32, 1e-3) && near(ceilingArea, 32, 1e-3), "\(floorArea) \(ceilingArea)")

        var untouched = base
        let missing = untouched.apply(.mergeRooms(rooms: [side, ElementID(uuid: F.uuid(999))], into: target))
        let missingInto = untouched.apply(.mergeRooms(rooms: [side], into: ElementID(uuid: F.uuid(998))))
        c.check("b5.mergeMissingFalse", !missing && !missingInto && untouched == base)

        var stacked = twoRoomModel(sideFloor: 1)
        let stackedBefore = stacked
        let stackedOK = stacked.apply(.mergeRooms(rooms: [side], into: target))
        c.check("b5.mergeOtherFloorSkipped", stackedOK && stacked == stackedBefore)

        var reshaped = merged
        let moveOK = reshaped.apply(.moveWallEndpoint(wall: wid(72), atStart: false, to: Vec2(x: 9, y: 4)))
        let outline = reshaped.rooms.first?.floor.mergedOutlines?.first ?? []
        let vertexMoved = outline.contains { near($0.simd, [9, 4], 1e-5) } && !outline.contains { near($0.simd, [8, 4], 1e-5) }
        let reshapedArea = reshaped.rooms.first?.metrics.floorArea ?? 0
        c.check("b5.mergedOutlineVertexFollows", moveOK && vertexMoved && near(reshapedArea, 34, 1e-3), "\(reshapedArea)")
    }

    // MARK: - Split

    /// splitRoom: areas, walls, openings, objects, the new room, replays, misses, merged rooms.
    static func splitChecks(_ c: inout Checker) {
        var base = editFixture()
        guard base.rooms.count == 1 else {
            c.check("b5.splitFixture", false, "\(base.rooms.count) rooms")
            return
        }
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(4, 0.4, -2, 1)
        let chair = DetectedObject(id: ElementID(uuid: F.uuid(41)), category: .chair, label: "", transform: Transform4(pose),
                                   dimensions: Vec3(x: 0.5, y: 0.8, z: 0.5), confidence: .high, isHidden: false,
                                   provenance: .measured)
        base.rooms[0].objects.append(chair)
        let roomID = ElementID(uuid: F.uuid(300))
        let newID = ElementID(uuid: F.uuid(310), roomPlanID: F.uuid(311))
        let op = EditOperation.splitRoom(room: roomID, line: [Vec2(x: 3, y: -1), Vec2(x: 3, y: 5)], newRoom: newID)
        var split = base
        let splitOK = split.apply(op)
        guard splitOK, split.rooms.count == 2 else {
            c.check("b5.splitTwoRooms", false, "ok \(splitOK), \(split.rooms.count) rooms")
            return
        }
        let kept = split.rooms[0]
        let created = split.rooms[1]
        c.check("b5.splitAreas", near(kept.metrics.floorArea, 12, 1e-3) && near(created.metrics.floorArea, 8, 1e-3),
                "\(kept.metrics.floorArea) \(created.metrics.floorArea)")
        let keptWalls = Set(kept.walls.map { $0.id })
        c.check("b5.splitWalls", keptWalls == Set([wid(1), wid(3), wid(4)]) && created.walls.map { $0.id } == [wid(2)])
        let openingsOK = kept.openings.map { $0.id } == [wid(F.doorID)] && created.openings.map { $0.id } == [wid(F.endDoorID)]
        c.check("b5.splitOpeningsFollowWalls", openingsOK)
        let objectsOK = kept.objects.map { $0.id } == [wid(F.sofaID)] && created.objects.map { $0.id } == [chair.id]
        c.check("b5.splitObjectsFollowCenters", objectsOK)
        let identity = created.id == newID && created.id.roomPlanID == nil && created.recordID == kept.recordID
        c.check("b5.splitNewRoomIdentity", identity && created.name.isEmpty && created.sectionLabel == nil)
        let sameFloor = created.floorIndex == kept.floorIndex && created.floor.elevation == kept.floor.elevation
        c.check("b5.splitNewRoomFloor", sameFloor && created.ceiling == kept.ceiling && created.floor.mergedOutlines == nil)
        c.check("b5.splitKeepsName", kept.id == roomID && kept.sectionLabel == "livingRoom")

        var replay = split
        c.check("b5.splitReplayUnchanged", replay.apply(op) && replay == split)
        var missed = base
        let missOp = EditOperation.splitRoom(room: roomID, line: [Vec2(x: 10, y: -1), Vec2(x: 10, y: 5)], newRoom: newID)
        c.check("b5.splitLineMissesUnchanged", missed.apply(missOp) && missed == base)
        var degenerate = base
        let pointOp = EditOperation.splitRoom(room: roomID, line: [Vec2(x: 3, y: 1), Vec2(x: 3, y: 1)], newRoom: newID)
        c.check("b5.splitCoincidentUnchanged", degenerate.apply(pointOp) && degenerate == base)
        var orphan = base
        let orphanOp = EditOperation.splitRoom(room: ElementID(uuid: F.uuid(999)), line: [Vec2(x: 3, y: -1), Vec2(x: 3, y: 5)],
                                               newRoom: newID)
        c.check("b5.splitMissingRoomFalse", !orphan.apply(orphanOp) && orphan == base)

        var rejoined = twoRoomModel()
        _ = rejoined.apply(.mergeRooms(rooms: [ElementID(uuid: F.uuid(301))], into: roomID))
        let back = rejoined.apply(.splitRoom(room: roomID, line: [Vec2(x: 5, y: -1), Vec2(x: 5, y: 5)], newRoom: newID))
        let areas = rejoined.rooms.map { $0.metrics.floorArea }
        let areasOK = areas.count == 2 && near(areas[0], 20, 1e-3) && near(areas[1], 12, 1e-3)
        let noMerged = rejoined.rooms.allSatisfy { $0.floor.mergedOutlines == nil }
        c.check("b5.splitMergedRoomBack", back && areasOK && noMerged, "\(areas)")
    }

    // MARK: - Batches and versions

    /// batch: all operations, all or nothing, nesting, scale corrections in replay; rules version.
    static func batchChecks(_ c: inout Checker) {
        let base = editFixture()
        let roomID = ElementID(uuid: F.uuid(300))
        let door = wid(F.doorID)
        var batched = base
        let batchOK = batched.apply(.batch(operations: [.renameRoom(room: roomID, name: "Hall"),
                                                         .moveOpening(opening: door, offset: 2)]))
        let movedDoor = batched.rooms.first?.openings.first { $0.id == door }
        c.check("b5.batchAppliesAll", batchOK && batched.rooms.first?.name == "Hall" && movedDoor?.offsetAlongWall == 2)

        var failed = base
        let failedOK = failed.apply(.batch(operations: [.renameRoom(room: roomID, name: "Hall"),
                                                         .renameRoom(room: ElementID(uuid: F.uuid(999)), name: "x")]))
        c.check("b5.batchAllOrNothing", !failedOK && failed == base)

        var nested = base
        let inner = EditOperation.batch(operations: [.relabelObject(object: wid(F.sofaID), label: "Couch")])
        let nestedOK = nested.apply(.batch(operations: [inner, .renameRoom(room: roomID, name: "Den")]))
        c.check("b5.batchNested", nestedOK && nested.rooms.first?.objects.first?.label == "Couch" && nested.rooms.first?.name == "Den")

        var log = EditLog()
        log.append(.batch(operations: [.setScaleCorrection(room: roomID, factor: 1.1)]))
        let replayed = base.applyingEdits(log)
        let area = replayed.model.rooms.first?.metrics.floorArea ?? 0
        c.check("b5.batchScaleCorrection", near(area, 20 * 1.21, 1e-2) && replayed.orphaned.isEmpty, "\(area)")
        var orphanLog = EditLog()
        orphanLog.append(.batch(operations: [.renameRoom(room: ElementID(uuid: F.uuid(999)), name: "x")]))
        c.check("b5.batchOrphanedWhole", base.applyingEdits(orphanLog).orphaned.count == 1)

        var drawn = base
        let userWall = PlanWall(id: ElementID(uuid: F.uuid(520)), a: Vec2(x: 5, y: 3), b: Vec2(x: 5, y: 1), thickness: 0.1,
                                thicknessSource: .user, arc: nil, provenance: .user, occludedSpans: [])
        let drawnOK = drawn.apply(.addWall(wall: userWall, level: 0))
        let added = drawn.rooms.first?.walls.first { $0.id == userWall.id }
        let addedStart = added.map { PlanAxes.toPlan($0.start.simd) } ?? .zero
        let addedLeft = added.map { hasLeftNormal($0) } ?? false
        c.check("b5.addWallKeepsEndsLeftNormal", drawnOK && near(addedStart, [5, 3], 1e-5) && addedLeft, "\(addedStart)")

        c.check("b5.rulesVersion", CleanModelStep.rulesVersion == "cleanModel-rules=2", CleanModelStep.rulesVersion)
    }
}
