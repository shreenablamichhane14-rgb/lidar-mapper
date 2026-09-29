import Foundation
import simd

/// Structure self-test (docs/MODULES.md 3.30): the placement solve and record algebra, moving
/// clean rooms, the overlap measure, frame groups and merge eligibility, floors, the placement
/// plan and parking, shared walls and doorways, snapping, user alignments and digests, the
/// structure files in a temporary package, the merge decision and placement matrices. Plain
/// Swift, deterministic, no ARKit, RoomPlan session, camera or network; files only under
/// `FileManager.default.temporaryDirectory`, removed afterwards.
enum StructureSelfTest {
    /// Fixture shorthand.
    typealias F = StructureSelfTestFixtures

    /// Collects failures and counts checks.
    struct Checker {
        /// Failure lines so far.
        private(set) var failures: [String] = []
        /// Number of checks run.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            guard !condition else { return }
            let text = detail()
            failures.append(text.isEmpty ? name : "\(name): \(text)")
        }
    }

    /// Runs every check; returns one "name: detail" line per failure, empty when all pass.
    static func run() -> [String] {
        var c = Checker()
        solveChecks(&c)
        transformChecks(&c)
        applyChecks(&c)
        overlapChecks(&c)
        frameChecks(&c)
        floorChecks(&c)
        layoutChecks(&c)
        parkingChecks(&c)
        wallChecks(&c)
        doorwayChecks(&c)
        snapChecks(&c)
        editChecks(&c)
        storeChecks(&c)
        stepRuleChecks(&c)
        return c.failures
    }

    // MARK: Solve and record algebra

    /// `solve` on a 4 x 5 m room moved by yaw 30 degrees and (1, 0.2, 2), with swapped ends,
    /// too few pairs, coincident midpoints and noise.
    static func solveChecks(_ c: inout Checker) {
        let truth = RoomAlignmentRecord(roomID: F.uuid(1), yaw: Float.pi / 6, translation: Vec3(x: 1, y: 0.2, z: 2),
                                        source: .measured)
        let pairs = F.rectanglePairs(size: SIMD2<Float>(4, 5), record: truth)
        let far = SIMD3<Float>(repeating: 99)
        let solved = StructureAlignment.solve(pairs)
        c.check("solve.yaw", F.near(solved?.yaw ?? 9, truth.yaw, 1e-3), "\(String(describing: solved?.yaw))")
        c.check("solve.translation", F.near(solved?.translation ?? far, truth.translation.simd, 1e-3),
                "\(String(describing: solved?.translation))")
        c.check("solve.trusted", solved?.isTrusted == true && solved?.matches == 4, "\(String(describing: solved))")

        var swapped = pairs
        for i in [0, 2] {
            let start = swapped[i].afterStart
            swapped[i].afterStart = swapped[i].afterEnd
            swapped[i].afterEnd = start
        }
        let fixed = StructureAlignment.solve(swapped)
        let swappedOK = F.near(fixed?.yaw ?? 9, truth.yaw, 1e-3) && F.near(fixed?.translation ?? far, truth.translation.simd, 1e-3)
        c.check("solve.swappedEnds", swappedOK && (fixed?.rms ?? 1) < 1e-3, "\(String(describing: fixed))")

        c.check("solve.onePairNil", StructureAlignment.solve([pairs[0]]) == nil)
        let cross = [
            AlignmentSegmentPair(beforeStart: SIMD2<Float>(-1, 0), beforeEnd: SIMD2<Float>(1, 0), beforeY: 1,
                                 afterStart: SIMD2<Float>(-1, 0), afterEnd: SIMD2<Float>(1, 0), afterY: 1),
            AlignmentSegmentPair(beforeStart: SIMD2<Float>(0, -1), beforeEnd: SIMD2<Float>(0, 1), beforeY: 1,
                                 afterStart: SIMD2<Float>(0, -1), afterEnd: SIMD2<Float>(0, 1), afterY: 1)
        ]
        c.check("solve.coincidentMidpointsNil", StructureAlignment.solve(cross) == nil)

        var noisy = pairs
        let offset = SIMD2<Float>(0.1, -0.1)
        for i in noisy.indices {
            let sign: Float = i % 2 == 0 ? 1 : -1
            noisy[i].afterStart += offset * sign
            noisy[i].afterEnd -= offset * sign
        }
        let rough = StructureAlignment.solve(noisy)
        c.check("solve.noiseUntrusted", (rough?.rms ?? 0) > StructureAlignment.maxTrustedRMS && rough?.isTrusted == false,
                "\(String(describing: rough?.rms))")
    }

    /// matrix, transform, planTransform, inverse, compose, rotation, translation and median.
    static func transformChecks(_ c: inout Checker) {
        let id = F.uuid(2)
        let quarter = RoomAlignmentRecord(roomID: id, yaw: Float.pi / 2, translation: .zero, source: .measured)
        let x = simd_mul(StructureAlignment.matrix(quarter), SIMD4<Float>(1, 0, 0, 1))
        c.check("matrix.yaw90", F.near(SIMD3<Float>(x.x, x.y, x.z), SIMD3<Float>(0, 0, -1), 1e-5), "\(x)")
        let planned = StructureAlignment.planTransform(SIMD2<Float>(1, 0), by: quarter)
        c.check("planTransform.yaw90", F.near(planned, SIMD2<Float>(0, 1), 1e-5), "\(planned)")

        let general = RoomAlignmentRecord(roomID: id, yaw: 0.7, translation: Vec3(x: 1, y: 0.5, z: -2), source: .measured)
        let p = SIMD3<Float>(2, 1, 3)
        let viaMatrix = simd_mul(StructureAlignment.matrix(general), SIMD4<Float>(p, 1))
        let direct = StructureAlignment.transform(p, by: general)
        c.check("transform.matchesMatrix", F.near(direct, SIMD3<Float>(viaMatrix.x, viaMatrix.y, viaMatrix.z), 1e-5))
        let planOfWorld = PlanAxes.toPlan(direct)
        c.check("planTransform.matchesWorld", F.near(StructureAlignment.planTransform(PlanAxes.toPlan(p), by: general), planOfWorld, 1e-5))

        let back = StructureAlignment.compose(StructureAlignment.inverse(general), after: general, source: .measured)
        c.check("inverse.composeIdentity", abs(back.yaw) <= 1e-5 && simd_length(back.translation.simd) <= 1e-5 && back.roomID == id,
                "\(back)")
        let pivot = SIMD2<Float>(3, -2)
        let turn = StructureAlignment.rotation(by: 0.8, about: pivot, roomID: id)
        c.check("rotation.keepsPivot", F.near(StructureAlignment.planTransform(pivot, by: turn), pivot, 1e-5) && turn.source == .user)
        let move = StructureAlignment.translation(by: SIMD2<Float>(1, 2), roomID: id)
        c.check("translation.plan", F.near(StructureAlignment.planTransform(.zero, by: move), SIMD2<Float>(1, 2), 1e-6)
                && move.translation.y == 0 && move.yaw == 0)

        let three = [F.solution(yaw: 0.3, translation: SIMD3<Float>(1, 0, 5)),
                     F.solution(yaw: 0.1, translation: SIMD3<Float>(3, 0.1, 4)),
                     F.solution(yaw: 0.2, translation: SIMD3<Float>(2, 0.2, 6))]
        let middle = StructureAlignment.median(three)
        let medianOK = F.near(middle?.yaw ?? 9, 0.2, 1e-6) && F.near(middle?.translation ?? SIMD3<Float>.zero, SIMD3<Float>(2, 0.1, 5), 1e-6)
        c.check("median.three", medianOK, "\(String(describing: middle))")
        c.check("median.emptyNil", StructureAlignment.median([]) == nil)
    }

    /// `apply` moves walls, normals, arcs, the floor and objects rigidly and keeps the rest.
    static func applyChecks(_ c: inout Checker) {
        let recordID = F.uuid(10)
        let door = F.door(150, parent: 101, SIMD2<Float>(1, 0), SIMD2<Float>(1.9, 0))
        var room = F.cleanRoom(F.rectangle(10, SIMD2<Float>(0, 0), SIMD2<Float>(4, 3), wallBase: 100, openings: [door]),
                               record: recordID)
        guard !room.walls.isEmpty else {
            c.check("apply.fixtureBuilt", false, "no walls")
            return
        }
        room.walls[0].arc = WallArc(center: Vec3(x: 2, y: 0, z: -1), radius: 1, startAngle: 0.2, endAngle: 1.2)
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(1, 0.4, -1, 1)
        room.objects = [DetectedObject(id: ElementID(uuid: F.uuid(160)), category: .table, label: "", transform: Transform4(pose),
                                       dimensions: Vec3(x: 1, y: 0.8, z: 1), confidence: .high, isHidden: false,
                                       provenance: .measured)]
        let record = RoomAlignmentRecord(roomID: recordID, yaw: Float.pi / 2, translation: Vec3(x: 1, y: 0.5, z: 2),
                                         source: .measured)
        let moved = StructureAlignment.apply(record, to: room)
        /// Closed form of yaw 90 degrees and translation (1, 0.5, 2): (x, y, z) -> (z + 1, y + 0.5, -x + 2).
        func expected(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(p.z + 1, p.y + 0.5, -p.x + 2) }

        let w0 = room.walls[0]
        let m0 = moved.walls[0]
        c.check("apply.wallEnds", F.near(m0.start.simd, expected(w0.start.simd), 1e-4) && F.near(m0.end.simd, expected(w0.end.simd), 1e-4))
        let n = w0.normal
        c.check("apply.normal", F.near(m0.normal.simd, SIMD3<Float>(n.z, n.y, -n.x), 1e-5), "\(m0.normal)")
        let arcOK = F.near(m0.arc?.center.simd ?? SIMD3<Float>.zero, expected(SIMD3<Float>(2, 0, -1)), 1e-4)
            && F.near(m0.arc?.startAngle ?? 0, 0.2 + Float.pi / 2, 1e-5) && F.near(m0.arc?.endAngle ?? 0, 1.2 + Float.pi / 2, 1e-5)
        c.check("apply.arc", arcOK, "\(String(describing: m0.arc))")
        let outlineOK = room.floor.outline.count == moved.floor.outline.count
            && zip(room.floor.outline, moved.floor.outline).allSatisfy { before, after in
                F.near(after.simd, SIMD2<Float>(1 - before.y, before.x - 2), 1e-4)
            }
        c.check("apply.floorOutline", outlineOK)
        c.check("apply.elevation", F.near(moved.floor.elevation, room.floor.elevation + 0.5, 1e-6))
        let objectOK = moved.objects.count == 1
            && F.near(moved.objects[0].transform.translation, expected(SIMD3<Float>(1, 0.4, -1)), 1e-4)
        c.check("apply.object", objectOK)
        let sameOpenings = moved.openings == room.openings && !room.openings.isEmpty
        let sameMetrics = moved.metrics == room.metrics && moved.ceiling == room.ceiling
        let sameNames = moved.id == room.id && moved.name == room.name
        c.check("apply.keepsOpeningsAndMetrics", sameOpenings && sameMetrics && sameNames)

        var model = CleanModel(rooms: [room], sourceIsStructure: false, stamp: nil)
        let unknown = RoomAlignmentRecord(roomID: F.uuid(999), yaw: 1, translation: .zero, source: .measured)
        c.check("apply.unknownRoomFalse", !StructureAlignment.apply(unknown, to: &model) && model.rooms[0] == room)
        c.check("apply.modelRoomMoves", StructureAlignment.apply(record, to: &model) && model.rooms[0] == moved)
    }

    /// `overlapRatio` for identical, disjoint, half-overlapping squares and an L-shape.
    static func overlapChecks(_ c: inout Checker) {
        let square = F.box(SIMD2<Float>(0, 0), SIMD2<Float>(2, 2))
        c.check("overlap.identical", F.near(StructureAlignment.overlapRatio(square, square), 1, 1e-6))
        c.check("overlap.disjoint", StructureAlignment.overlapRatio(square, F.box(SIMD2<Float>(5, 5), SIMD2<Float>(6, 6))) == 0)
        let half = StructureAlignment.overlapRatio(square, F.box(SIMD2<Float>(1, 0), SIMD2<Float>(3, 2)))
        c.check("overlap.half", F.near(half, 0.5, 0.02), "\(half)")
        let ell: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(2, 0), SIMD2<Float>(2, 1),
                                   SIMD2<Float>(1, 1), SIMD2<Float>(1, 2), SIMD2<Float>(0, 2)]
        let arm = StructureAlignment.overlapRatio(ell, F.box(SIMD2<Float>(0, 1), SIMD2<Float>(1, 2)))
        c.check("overlap.lShapeArm", F.near(arm, 1, 1e-6), "\(arm)")
        let notch = StructureAlignment.overlapRatio(ell, F.box(SIMD2<Float>(1, 1), SIMD2<Float>(2, 2)))
        c.check("overlap.lShapeNotch", notch < 0.02, "\(notch)")
    }

    // MARK: Frames and floors

    /// frameGroups, anchorGroup, mergeable, activeRooms and linkKey.
    static func frameChecks(_ c: inout Checker) {
        let a = F.uuid(20)
        let b = F.uuid(21)
        let unaligned = F.uuid(22)
        let sessions = [F.session(a, link: .projectFrame(sessionID: a)),
                        F.session(b, link: .relocalized(sessionID: b, from: a)),
                        F.session(unaligned, link: .unaligned)]
        let r1 = F.record(F.uuid(30), session: a, link: .projectFrame(sessionID: a))
        let r2 = F.record(F.uuid(31), session: b, link: .relocalized(sessionID: b, from: a))
        let r3 = F.record(F.uuid(32), session: unaligned, link: .unaligned)
        let r4 = F.record(F.uuid(33), session: unaligned, link: .unaligned)
        let r5 = F.record(F.uuid(34), session: a, link: .manual)
        let rooms = [r1, r2, r3, r4, r5]
        let groups = StructureEligibility.frameGroups(rooms: rooms, sessions: sessions)
        c.check("frames.relocalizedJoins", groups.first == StructureFrameGroup(sessions: [a, b], rooms: [r1.id, r2.id]),
                "\(groups)")
        c.check("frames.unalignedSessionTogether",
                groups.count == 3 && groups[1] == StructureFrameGroup(sessions: [unaligned], rooms: [r3.id, r4.id]))
        c.check("frames.manualRoomAlone", groups.count == 3 && groups[2] == StructureFrameGroup(sessions: [], rooms: [r5.id]))
        let tie = StructureEligibility.anchorGroup(groups, sessions: sessions)
        c.check("anchor.tieBySessionOrder", tie?.rooms == [r1.id, r2.id])
        let r6 = F.record(F.uuid(35), session: unaligned, link: .unaligned)
        let bigger = StructureEligibility.frameGroups(rooms: rooms + [r6], sessions: sessions)
        c.check("anchor.largestGroup", StructureEligibility.anchorGroup(bigger, sessions: sessions)?.rooms == [r3.id, r4.id, r6.id])
        c.check("anchor.noRoomsNil", StructureEligibility.anchorGroup([], sessions: sessions) == nil)

        let split = StructureEligibility.mergeable(rooms, sessions: sessions, isFinal: { $0.id != r2.id })
        c.check("mergeable.leavesOutProvisionalAndUnaligned",
                split.merge.map { $0.id } == [r1.id] && split.separate.map { $0.id } == [r2.id, r3.id, r4.id, r5.id])
        let unalignedAnchor = StructureEligibility.mergeable(rooms + [r6], sessions: sessions, isFinal: { _ in true })
        c.check("mergeable.neverUnalignedRooms", unalignedAnchor.merge.isEmpty)

        let superseded = F.record(F.uuid(36), session: a, link: .projectFrame(sessionID: a), superseded: r1.id)
        let capturing = F.record(F.uuid(37), session: a, link: .projectFrame(sessionID: a), status: .capturing)
        let rescan = F.record(F.uuid(38), session: a, link: .projectFrame(sessionID: a), status: .needsRescan)
        let manifest = F.manifest(.house, sessions: sessions, rooms: [r1, superseded, capturing, rescan])
        c.check("active.dropsSupersededAndCapturing", StructureEligibility.activeRooms(manifest).map { $0.id } == [r1.id, rescan.id])

        let keysOK = StructureEligibility.linkKey(.relocalized(sessionID: b, from: a)) == "reloc:\(b.uuidString):\(a.uuidString)"
            && StructureEligibility.linkKey(.projectFrame(sessionID: a)) == "project:\(a.uuidString)"
            && StructureEligibility.linkKey(.manual) == "manual" && StructureEligibility.linkKey(.unaligned) == "unaligned"
        c.check("linkKey.stable", keysOK)
    }

    /// StructureFloors.group and assign.
    static func floorChecks(_ c: inout Checker) {
        let e1 = F.uuid(40)
        let e2 = F.uuid(41)
        let e3 = F.uuid(42)
        let ranks = StructureFloors.group(elevations: [e1: 0, e2: 0.05, e3: 2.8])
        c.check("floors.groupTwoClusters", ranks[e1] == 0 && ranks[e2] == 0 && ranks[e3] == 1, "\(ranks)")
        let allZero = StructureFloors.assign([FloorAssignmentInput(roomID: e1, userFloor: 0, elevation: 0),
                                              FloorAssignmentInput(roomID: e2, userFloor: 0, elevation: 0),
                                              FloorAssignmentInput(roomID: e3, userFloor: 0, elevation: 2.8)])
        c.check("floors.upstairsGetsNewFloor", allZero[e1] == 0 && allZero[e2] == 0 && allZero[e3] == 1, "\(allZero)")
        let userSet = StructureFloors.assign([FloorAssignmentInput(roomID: e1, userFloor: 0, elevation: 0),
                                              FloorAssignmentInput(roomID: e2, userFloor: 0, elevation: 0),
                                              FloorAssignmentInput(roomID: e3, userFloor: 1, elevation: 2.8)])
        c.check("floors.keepsUserFloors", userSet == [e1: 0, e2: 0, e3: 1], "\(userSet)")
        let missing = StructureFloors.assign([FloorAssignmentInput(roomID: e1, userFloor: 0, elevation: 0),
                                              FloorAssignmentInput(roomID: e3, userFloor: 2, elevation: nil)])
        c.check("floors.noElevationKeepsUserFloor", missing[e3] == 2 && missing[e1] == 0, "\(missing)")
    }
}
