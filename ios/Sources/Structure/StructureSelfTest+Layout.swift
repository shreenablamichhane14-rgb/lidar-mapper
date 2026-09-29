import Foundation
import simd

// StructureSelfTest, second part: the placement plan and parking, shared walls and doorways,
// snapping, user alignments and digests, the structure files in a temporary package, the merge
// decision, placement matrices and footprints.

extension StructureSelfTest {
    /// The report of one room in a plan.
    static func report(_ plan: StructurePlacementPlan, _ id: UUID) -> RoomPlacementReport? {
        plan.reports.first { $0.roomID == id }
    }

    /// The record of one room in a plan.
    static func record(_ plan: StructurePlacementPlan, _ id: UUID) -> RoomAlignmentRecord? {
        plan.records.first { $0.roomID == id }
    }

    /// Where a record puts a plan point (a far-away point without a record).
    static func placed(_ point: SIMD2<Float>, _ record: RoomAlignmentRecord?) -> SIMD2<Float> {
        guard let record else { return SIMD2<Float>(repeating: 999) }
        return StructureAlignment.planTransform(point, by: record)
    }

    /// True when a matrix is present and equals `expected` column by column.
    static func same(_ matrix: simd_float4x4?, _ expected: simd_float4x4) -> Bool {
        guard let m = matrix else { return false }
        let first = m.columns.0 == expected.columns.0 && m.columns.1 == expected.columns.1
        let second = m.columns.2 == expected.columns.2 && m.columns.3 == expected.columns.3
        return first && second
    }

    // MARK: Placement plan

    /// `plan`: sharedFrame identity, structureMerge, groupMedian, untrusted solves, parked rooms,
    /// a stacked copy and an unplaced room.
    static func layoutChecks(_ c: inout Checker) {
        let a = F.uuid(50)
        let other = F.uuid(51)
        let sessions = [F.session(a, link: .projectFrame(sessionID: a)), F.session(other, link: .unaligned)]
        let r1 = F.record(F.uuid(60), session: a, link: .projectFrame(sessionID: a))
        let r2 = F.record(F.uuid(61), session: a, link: .projectFrame(sessionID: a))
        let r3 = F.record(F.uuid(62), session: other, link: .unaligned)
        let r4 = F.record(F.uuid(63), session: other, link: .unaligned)
        let rooms = [r1, r2, r3, r4]
        let footprints: [UUID: RoomFootprint] = [
            r1.id: F.footprint(r1.id, SIMD2<Float>(0, 0), SIMD2<Float>(4, 4)),
            r2.id: F.footprint(r2.id, SIMD2<Float>(5, 0), SIMD2<Float>(8, 4)),
            r3.id: F.footprint(r3.id, SIMD2<Float>(0, 0), SIMD2<Float>(3, 3)),
            r4.id: F.footprint(r4.id, SIMD2<Float>(3.5, 0), SIMD2<Float>(5, 2))
        ]
        let plain = StructureLayout.plan(rooms: rooms, sessions: sessions, footprints: footprints, solutions: [:])
        let methodsShared = report(plain, r1.id)?.method == AlignmentMethod.sharedFrame
            && report(plain, r2.id)?.method == AlignmentMethod.sharedFrame
        let identityRecord = record(plain, r1.id) == StructureAlignment.identity(roomID: r1.id, source: .measured)
        c.check("plan.sharedFrameIdentity", methodsShared && identityRecord, "\(plain.reports)")
        let parked = record(plain, r3.id)
        let parkedPlace = parked?.source == Provenance.estimated && F.near(placed(SIMD2<Float>(0, 0), parked), SIMD2<Float>(9, 0), 1e-5)
        let parkedReport = report(plain, r3.id)
        let parkedFlag = parkedReport?.method == AlignmentMethod.parked && parkedReport?.needsManualAlignment == true
        c.check("plan.parkedRightOfBuilding", parkedPlace && parkedFlag, "\(String(describing: parked))")
        c.check("plan.parkedGroupKeepsLayout",
                F.near(placed(SIMD2<Float>(3.5, 0), record(plain, r4.id)), SIMD2<Float>(12.5, 0), 1e-5))
        c.check("plan.everyRoomPlaced", plain.unplaced.isEmpty && plain.records.count == 4 && plain.reports.count == 4)

        let solved = StructureLayout.plan(rooms: rooms, sessions: sessions, footprints: footprints,
                                          solutions: [r1.id: F.solution(yaw: 0.1, translation: SIMD3<Float>(0.5, 0, 0.2))])
        let solvedReport = report(solved, r1.id)
        c.check("plan.structureMerge", solvedReport?.method == AlignmentMethod.structureMerge && solvedReport?.matches == 4)
        let median = record(solved, r2.id)
        let medianMethod = report(solved, r2.id)?.method == AlignmentMethod.groupMedian
        let medianYaw = F.near(median?.yaw ?? 9, 0.1, 1e-6)
        let medianShift = F.near(median?.translation.simd ?? SIMD3<Float>.zero, SIMD3<Float>(0.5, 0, 0.2), 1e-6)
        c.check("plan.groupMedianForUnsolvedRoom", medianMethod && medianYaw && medianShift, "\(String(describing: median))")

        let loose = StructureLayout.plan(rooms: rooms, sessions: sessions, footprints: footprints,
                                         solutions: [r1.id: F.solution(yaw: 0.1, translation: .zero, rms: 0.2)])
        let looseReport = report(loose, r1.id)
        c.check("plan.untrustedSolveIgnored", looseReport?.method == AlignmentMethod.sharedFrame && looseReport?.rms == 0.2)

        var copies = footprints
        copies[r2.id] = F.footprint(r2.id, SIMD2<Float>(0, 0), SIMD2<Float>(4, 4))
        let stacked = StructureLayout.plan(rooms: [r1, r2], sessions: sessions, footprints: copies, solutions: [:])
        let copyReport = report(stacked, r2.id)
        let copyFlagged = copyReport?.stackedWith == r1.id && copyReport?.needsManualAlignment == true
        let firstClear = report(stacked, r1.id)?.stackedWith == nil
        c.check("plan.stackedCopyFlagged", copyFlagged && firstClear, "\(stacked.reports)")

        var withoutOutline = footprints
        withoutOutline[r4.id] = nil
        let partial = StructureLayout.plan(rooms: rooms, sessions: sessions, footprints: withoutOutline, solutions: [:])
        c.check("plan.otherFrameWithoutOutlineUnplaced", partial.unplaced == [r4.id] && record(partial, r4.id) == nil)
    }

    /// `parking` keeps groups apart and each group's layout, with and without a building.
    static func parkingChecks(_ c: inout Checker) {
        let first = [F.footprint(F.uuid(70), SIMD2<Float>(0, 0), SIMD2<Float>(2, 2))]
        let second = [F.footprint(F.uuid(71), SIMD2<Float>(0, 0), SIMD2<Float>(3, 3)),
                      F.footprint(F.uuid(72), SIMD2<Float>(4, 0), SIMD2<Float>(5, 1))]
        let building = [F.footprint(F.uuid(73), SIMD2<Float>(0, 0), SIMD2<Float>(4, 4))]
        let parked = StructureLayout.parking([first, second], placed: building)
        let firstLow = placed(SIMD2<Float>(0, 0), parked[F.uuid(70)])
        let firstHigh = placed(SIMD2<Float>(2, 2), parked[F.uuid(70)])
        let secondLow = placed(SIMD2<Float>(0, 0), parked[F.uuid(71)])
        let firstAtBuilding = F.near(firstLow, SIMD2<Float>(5, 0), 1e-5)
        let clearX: Float = firstHigh.x + StructureLayout.parkingGap - 1e-4
        c.check("parking.groupsNeverOverlap", firstAtBuilding && secondLow.x >= clearX, "\(firstLow) \(firstHigh) \(secondLow)")
        let layout = placed(SIMD2<Float>(4, 0), parked[F.uuid(72)]) - secondLow
        c.check("parking.keepsGroupLayout", F.near(layout, SIMD2<Float>(4, 0), 1e-5), "\(layout)")
        let alone = StructureLayout.parking([first, second], placed: [])
        let aloneFirst = placed(SIMD2<Float>(0, 0), alone[F.uuid(70)])
        let aloneSecond = placed(SIMD2<Float>(0, 0), alone[F.uuid(71)])
        let firstStays = F.near(aloneFirst, SIMD2<Float>(0, 0), 1e-6)
        let secondFollows = F.near(aloneSecond, SIMD2<Float>(3, 0), 1e-5)
        c.check("parking.firstGroupStaysWithoutBuilding", firstStays && secondFollows)
    }

    // MARK: Walls and doorways

    /// Two rooms 0.12 m apart share one wall; 0.8 m apart they do not; thickness rules.
    static func wallChecks(_ c: inout Checker) {
        let idA = F.uuid(80)
        let idB = F.uuid(81)
        let roomA = F.cleanRoom(F.rectangle(80, SIMD2<Float>(0, 0), SIMD2<Float>(4, 5), wallBase: 200), record: idA)
        let roomB = F.cleanRoom(F.rectangle(81, SIMD2<Float>(4.12, 0), SIMD2<Float>(8, 5), wallBase: 210), record: idB)
        var model = CleanModel(rooms: [roomA, roomB], sourceIsStructure: true, stamp: nil)
        let pairs = StructureWalls.sharedWalls(in: model)
        let wallA = ElementID.derived(fromRoomPlan: F.uuid(202))
        let wallB = ElementID.derived(fromRoomPlan: F.uuid(214))
        c.check("walls.onePair", pairs.count == 1, "\(pairs)")
        c.check("walls.gapMeasured", F.near(pairs.first?.gap ?? 0, 0.12, 1e-4), "\(String(describing: pairs.first?.gap))")
        let namesOK = pairs.first.map { pair -> Bool in
            let walls = pair.wallA == wallA && pair.wallB == wallB
            return walls && pair.roomA == idA && pair.roomB == idB
        } ?? false
        c.check("walls.pairNamesBothFaces", namesOK)
        let exterior = CleanBuildOptions().exteriorThickness
        StructureWalls.applyThickness(pairs, exteriorThickness: exterior, to: &model)
        let thickA = model.rooms[0].walls.first { $0.id == wallA }
        let thickB = model.rooms[1].walls.first { $0.id == wallB }
        let measuredA = F.near(thickA?.thickness ?? 0, 0.12, 1e-4) && thickA?.thicknessSource == Provenance.measured
        let measuredB = F.near(thickB?.thickness ?? 0, 0.12, 1e-4) && thickB?.thicknessSource == Provenance.measured
        c.check("walls.pairedThicknessMeasured", measuredA && measuredB)
        let outside = model.rooms[0].walls.first { $0.id == ElementID.derived(fromRoomPlan: F.uuid(204)) }
        let outsideThick = F.near(outside?.thickness ?? 0, exterior, 1e-6)
        c.check("walls.exteriorEstimated", outsideThick && outside?.thicknessSource == Provenance.estimated)
        var single = CleanModel(rooms: [roomA], sourceIsStructure: false, stamp: nil)
        StructureWalls.applyThickness([], exteriorThickness: exterior, to: &single)
        let singleWalls = single.rooms[0].walls
        let defaultKept = singleWalls.allSatisfy { wall -> Bool in
            let thin = F.near(wall.thickness, 0.115, 1e-6)
            return thin && wall.thicknessSource == Provenance.estimated
        }
        c.check("walls.singleRoomFloorKeepsDefault", !singleWalls.isEmpty && defaultKept)
        let far = F.cleanRoom(F.rectangle(82, SIMD2<Float>(4.8, 0), SIMD2<Float>(8, 5), wallBase: 220), record: F.uuid(82))
        let apart = CleanModel(rooms: [roomA, far], sourceIsStructure: true, stamp: nil)
        c.check("walls.facesTooFarNoPair", StructureWalls.sharedWalls(in: apart).isEmpty)
    }

    /// A door on both sides of a shared wall is kept once; a door facing an opening is kept.
    static func doorwayChecks(_ c: inout Checker) {
        let idA = F.uuid(80)
        let idB = F.uuid(81)
        let doorA = F.door(250, parent: 202, SIMD2<Float>(4, 2), SIMD2<Float>(4, 2.9))
        let doorB = F.door(251, parent: 214, SIMD2<Float>(4.12, 2), SIMD2<Float>(4.12, 2.9))
        let roomA = F.cleanRoom(F.rectangle(80, SIMD2<Float>(0, 0), SIMD2<Float>(4, 5), wallBase: 200, openings: [doorA]),
                                record: idA)
        let roomB = F.cleanRoom(F.rectangle(81, SIMD2<Float>(4.12, 0), SIMD2<Float>(8, 5), wallBase: 210, openings: [doorB]),
                                record: idB)
        var model = CleanModel(rooms: [roomA, roomB], sourceIsStructure: true, stamp: nil)
        let links = StructureWalls.doorwayLinks(in: model, pairs: StructureWalls.sharedWalls(in: model))
        let idDoorA = ElementID.derived(fromRoomPlan: F.uuid(250))
        let idDoorB = ElementID.derived(fromRoomPlan: F.uuid(251))
        let linkOK = links.first.map { link -> Bool in
            let ids = link.kept == idDoorA && link.merged == idDoorB
            return ids && link.keptRoom == idA
        } ?? false
        c.check("doorway.oneLinkEarlierRoomKept", links.count == 1 && linkOK, "\(links)")
        let before = model.rooms[1].openings.first { $0.id == idDoorB }
        StructureWalls.applyDoorways(links, to: &model)
        let after = model.rooms[1].openings.first { $0.id == idDoorB }
        let kindOK = after?.kind == OpeningKind.opening && after?.swing == nil
        let hadSwing = before?.swing != nil
        let sizeOK = after?.offsetAlongWall == before?.offsetAlongWall && after?.width == before?.width
        let mergedOK = kindOK && hadSwing && sizeOK && after != nil
        c.check("doorway.laterDoorBecomesOpening", mergedOK)
        let keptDoor = model.rooms[0].openings.first(where: { $0.id == idDoorA })
        c.check("doorway.keptDoorUnchanged", keptDoor?.kind == OpeningKind.door)

        let openingA = F.door(252, parent: 202, SIMD2<Float>(4, 2), SIMD2<Float>(4, 2.9), kind: .opening)
        let plainA = F.cleanRoom(F.rectangle(80, SIMD2<Float>(0, 0), SIMD2<Float>(4, 5), wallBase: 200, openings: [openingA]),
                                 record: idA)
        let mixed = CleanModel(rooms: [plainA, roomB], sourceIsStructure: true, stamp: nil)
        let mixedLinks = StructureWalls.doorwayLinks(in: mixed, pairs: StructureWalls.sharedWalls(in: mixed))
        let idOpeningA = ElementID.derived(fromRoomPlan: F.uuid(252))
        let mixedOK = mixedLinks.first.map { link -> Bool in
            let ids = link.kept == idDoorB && link.merged == idOpeningA
            return ids && link.keptRoom == idB
        } ?? false
        c.check("doorway.doorKeptOverOpening", mixedLinks.count == 1 && mixedOK, "\(mixedLinks)")
    }

    // MARK: Snapping

    /// Parallel, doorway and wall-gap snaps, no snap, and alignment shapes.
    static func snapChecks(_ c: inout Checker) {
        let neighbor = F.alignBox(F.uuid(90), SIMD2<Float>(0, 0), SIMD2<Float>(4, 4), doors: [SIMD2<Float>(4, 2)])
        let farRoom = F.alignBox(F.uuid(91), SIMD2<Float>(10, 0), SIMD2<Float>(13, 3))
        let turned = StructureSnapping.snap(farRoom, rotation: 3 * Float.pi / 180, translation: .zero, others: [neighbor])
        c.check("snap.parallel", turned.snap == .parallel && abs(turned.delta.yaw) <= 1e-5, "\(turned)")

        let mover = F.alignBox(F.uuid(92), SIMD2<Float>(4.12, 0), SIMD2<Float>(7.12, 4), doors: [SIMD2<Float>(4.12, 2.3)])
        let door = StructureSnapping.snap(mover, rotation: 0, translation: .zero, others: [neighbor])
        let movedDoor = StructureAlignment.planTransform(SIMD2<Float>(4.12, 2.3), by: door.delta)
        c.check("snap.doorway", door.snap == .doorway && F.near(movedDoor, SIMD2<Float>(4.12, 2), 1e-4), "\(door) \(movedDoor)")

        let plainNeighbor = F.alignBox(F.uuid(90), SIMD2<Float>(0, 0), SIMD2<Float>(4, 4))
        let gapMover = F.alignBox(F.uuid(93), SIMD2<Float>(4.25, 0), SIMD2<Float>(7.25, 4))
        let gap = StructureSnapping.snap(gapMover, rotation: 0, translation: .zero, others: [plainNeighbor])
        let movedEdge = StructureAlignment.planTransform(SIMD2<Float>(4.25, 0), by: gap.delta)
        c.check("snap.wallGap", gap.snap == .wallGap && F.near(movedEdge, SIMD2<Float>(4.12, 0), 1e-4), "\(gap) \(movedEdge)")

        let unsnapped = StructureSnapping.snap(farRoom, rotation: 0.5, translation: SIMD2<Float>(1, 1), others: [])
        let pivot = farRoom.centroid
        let unsnappedPivot = StructureAlignment.planTransform(pivot, by: unsnapped.delta)
        let movedPivot: SIMD2<Float> = pivot + SIMD2<Float>(1, 1)
        let gestureYawKept = F.near(unsnapped.delta.yaw, 0.5, 1e-6)
        let gestureKept = gestureYawKept && F.near(unsnappedPivot, movedPivot, 1e-5)
        let noSnap = unsnapped.snap == AlignSnapKind.none && unsnapped.delta.source == Provenance.user
        c.check("snap.noneKeepsGesture", noSnap && gestureKept)

        let doorway = F.door(250, parent: 202, SIMD2<Float>(4, 2), SIMD2<Float>(4, 2.9))
        let room = F.cleanRoom(F.rectangle(80, SIMD2<Float>(0, 0), SIMD2<Float>(4, 5), wallBase: 200, openings: [doorway]),
                               record: F.uuid(80))
        let shape = AlignShape.from(room)
        let shapeCounts = shape.walls.count == 4 && shape.doors.count == 1 && shape.roomID == F.uuid(80)
        let doorCenter = F.near(shape.doors.first ?? SIMD2<Float>.zero, SIMD2<Float>(4, 2.45), 1e-4)
        let shapeCenter = F.near(shape.centroid, SIMD2<Float>(2, 2.5), 1e-4)
        c.check("alignShape.fromCleanRoom", shapeCounts && doorCenter && shapeCenter, "\(shape.doors) \(shape.centroid)")
        let shifted = shape.moved(by: StructureAlignment.translation(by: SIMD2<Float>(1, 0), roomID: F.uuid(80)))
        c.check("alignShape.moved", F.near(shifted.centroid, SIMD2<Float>(3, 2.5), 1e-4))
    }
}
