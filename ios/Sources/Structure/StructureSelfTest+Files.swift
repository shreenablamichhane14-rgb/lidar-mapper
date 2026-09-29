import Foundation
import simd

// StructureSelfTest, third part: user alignments and digests, the structure files in a
// temporary package, the merge decision, placement matrices, footprints and the House clean
// model's change report. Temporary files live under FileManager.default.temporaryDirectory and
// are removed before returning.

extension StructureSelfTest {
    /// A `.setRoomAlignment` edit.
    static func alignEdit(_ room: UUID, yaw: Float, source: Provenance = .measured) -> EditOperation {
        .setRoomAlignment(RoomAlignmentRecord(roomID: room, yaw: yaw, translation: Vec3(x: yaw, y: 0, z: 1), source: source))
    }

    // MARK: Edits

    /// userAlignments, effectiveAlignments and alignmentEditDigest.
    static func editChecks(_ c: inout Checker) {
        let r1 = F.uuid(100)
        let r2 = F.uuid(101)
        let r3 = F.uuid(102)
        var log = EditLog()
        log.append(alignEdit(r1, yaw: 0.1))
        log.append(alignEdit(r1, yaw: 0.2))
        log.append(.batch(operations: [alignEdit(r2, yaw: 0.3), .renameRoom(room: ElementID(uuid: r2), name: "Hall")]))
        log.append(alignEdit(r3, yaw: 0.4))
        log.undo()
        let user = StructureStore.userAlignments(log)
        c.check("user.lastActivePerRoom", user[r1]?.yaw == 0.2 && user[r1]?.source == .user, "\(user)")
        c.check("user.foundInsideBatch", user[r2]?.yaw == 0.3 && user[r2]?.source == .user)
        c.check("user.ignoresUndone", user[r3] == nil && user.count == 2)

        let measured = [RoomAlignmentRecord(roomID: r1, yaw: 0.9, translation: .zero, source: .measured),
                        RoomAlignmentRecord(roomID: r3, yaw: 0.7, translation: .zero, source: .measured)]
        let effective = StructureStore.effectiveAlignments(measured: measured, log: log)
        let preferOK = effective[r1]?.yaw == 0.2 && effective[r1]?.source == .user
        let keepOK = effective[r3]?.yaw == 0.7 && effective[r3]?.source == .measured && effective[r2]?.yaw == 0.3
        c.check("effective.prefersUserRecord", preferOK && keepOK, "\(effective)")

        var digestLog = EditLog()
        let empty = StructureStore.alignmentEditDigest(digestLog)
        digestLog.append(alignEdit(r1, yaw: 0.1))
        let aligned = StructureStore.alignmentEditDigest(digestLog)
        digestLog.append(.renameRoom(room: ElementID(uuid: r1), name: "Kitchen"))
        let renamed = StructureStore.alignmentEditDigest(digestLog)
        c.check("digest.changesWithAlignmentEdit", empty == "-" && aligned != empty, aligned)
        c.check("digest.ignoresRename", renamed == aligned && digestLog.revision == 2)
    }

    // MARK: Files

    /// Round trips of merge.json, placements.json, connections.json and alignment.json, and the
    /// attempt.json guard, in a temporary package.
    static func storeChecks(_ c: inout Checker) {
        let fm = FileManager.default
        let name = "StructureSelfTest-" + F.uuid(1).uuidString + "." + ProjectPackage.fileExtension
        let root = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: root)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            c.check("store.tempPackage", false, "\(error)")
            return
        }
        let package = ProjectPackage(root: root)
        let r1 = F.uuid(110)
        let r2 = F.uuid(111)
        let alignment = RoomAlignmentRecord(roomID: r1, yaw: 0.25, translation: Vec3(x: 1, y: 0, z: -2), source: .measured)
        let merge = StructureMergeResult(outcome: .merged, mergedRooms: [r1, r2], separateRooms: [], provisionalRooms: [],
                                         detail: nil, seconds: 1.5, inputHash: "abc", finishedAt: F.date)
        let roomReport = RoomPlacementReport(roomID: r1, method: .structureMerge, matches: 4, rms: 0.01, stackedWith: nil,
                                         needsManualAlignment: false)
        let placements = StructurePlacements(rooms: [roomReport], unplaced: [r2], inputHash: "def", finishedAt: F.date)
        let pair = SharedWallPair(roomA: r1, wallA: ElementID(uuid: F.uuid(120)), roomB: r2, wallB: ElementID(uuid: F.uuid(121)),
                                  gap: 0.12, overlap: 3.5)
        let link = DoorwayLink(keptRoom: r1, kept: ElementID(uuid: F.uuid(122)), mergedRoom: r2,
                               merged: ElementID(uuid: F.uuid(123)), distance: 0.12)
        let connections = StructureConnections(sharedWalls: [pair], doorways: [link],
                                               floors: [FloorAssignmentEntry(roomID: r1, floorIndex: 0)], inputHash: "ghi",
                                               appliedAlignments: [alignment])
        c.check("store.emptyReport", StructureStore.loadReport(package) == StructureReport.empty)
        do {
            try StructureStore.saveMerge(merge, to: package)
            try StructureStore.savePlacements(placements, to: package)
            try StructureStore.saveConnections(connections, to: package)
            try StructureStore.saveAlignments([alignment], to: package)
        } catch {
            c.check("store.write", false, "\(error)")
            return
        }
        let loaded = StructureStore.loadReport(package)
        c.check("store.mergeRoundTrip", loaded.merge == merge, "\(String(describing: loaded.merge))")
        c.check("store.placementsRoundTrip", loaded.placements == placements && loaded.placement(for: r1) == roomReport)
        c.check("store.connectionsRoundTrip", loaded.connections == connections)
        c.check("store.alignmentRoundTrip", StructureStore.loadAlignments(package) == [alignment])
        c.check("store.effectiveFromPackage", StructureStore.effectiveAlignments(package)[r1] == alignment)
        c.check("store.noAttemptYet", !loaded.hasCrashedAttempt && !StructureStore.hasCrashedAttempt(package))

        let attempt = StructureAttempt(startedAt: F.date, roomIDs: [r1, r2], inputHash: "old")
        do {
            try StructureStore.writeAttempt(attempt, to: package)
        } catch {
            c.check("store.attemptWrite", false, "\(error)")
            return
        }
        let present = StructureStore.hasCrashedAttempt(package) && StructureStore.loadReport(package).hasCrashedAttempt
        c.check("store.attemptPresent", present && StructureStore.loadAttempt(package) == attempt)
        do {
            try StructureStore.clearCrashedAttempt(package)
        } catch {
            c.check("store.attemptClear", false, "\(error)")
            return
        }
        c.check("store.attemptCleared", !StructureStore.hasCrashedAttempt(package))
    }

    // MARK: Step rules

    /// The merge decision, placement matrices, footprints and the change report.
    static func stepRuleChecks(_ c: inout Checker) {
        let budget: UInt64 = 400 * 1024 * 1024
        let plenty: UInt64 = 2_000_000_000
        let leftover = StructureAttempt(startedAt: F.date, roomIDs: [F.uuid(1)], inputHash: "stored-hash")
        let crashed = MergeStructureStep.decision(isSupported: true, availableMemory: plenty, budget: budget, attempt: leftover,
                                                  attemptFileExists: true, currentHash: "different-hash", mergeableCount: 3)
        c.check("decision.crashedBeforeWhateverHash", crashed == .crashedBefore)
        let unsupported = MergeStructureStep.decision(isSupported: false, availableMemory: plenty, budget: budget, attempt: nil,
                                                      attemptFileExists: false, currentHash: "h", mergeableCount: 3)
        let reduced = MergeStructureStep.decision(isSupported: true, availableMemory: budget - 1, budget: budget, attempt: leftover,
                                                  attemptFileExists: true, currentHash: "h", mergeableCount: 3)
        let few = MergeStructureStep.decision(isSupported: true, availableMemory: plenty, budget: budget, attempt: nil,
                                              attemptFileExists: false, currentHash: "h", mergeableCount: 1)
        let go = MergeStructureStep.decision(isSupported: true, availableMemory: plenty, budget: budget, attempt: nil,
                                             attemptFileExists: false, currentHash: "h", mergeableCount: 2)
        c.check("decision.order", unsupported == .unsupported && reduced == .skippedReducedMemory && few == .tooFewRooms && go == nil)
        let step = MergeStructureStep()
        c.check("decision.budgets", step.memoryBudgetBytes == budget && step.reducedMemoryBudgetBytes == 60 * 1024 * 1024)

        let a = F.uuid(130)
        let other = F.uuid(131)
        let sessions = [F.session(a, link: .projectFrame(sessionID: a)), F.session(other, link: .unaligned)]
        let r1 = F.record(F.uuid(140), session: a, link: .projectFrame(sessionID: a))
        let r2 = F.record(F.uuid(141), session: a, link: .projectFrame(sessionID: a))
        let r3 = F.record(F.uuid(142), session: other, link: .unaligned)
        let placement = RoomAlignmentRecord(roomID: r1.id, yaw: 0.3, translation: Vec3(x: 1, y: 0, z: 2), source: .measured)
        let house = F.manifest(.house, sessions: sessions, rooms: [r1, r2, r3])
        let matrices = StructureStore.placementMatrices(manifest: house, alignments: [r1.id: placement])
        c.check("matrices.recordMatrix", same(matrices[r1.id], StructureAlignment.matrix(placement)))
        c.check("matrices.anchorRoomIdentity", same(matrices[r2.id], matrix_identity_float4x4))
        c.check("matrices.otherFrameSkipped", matrices[r3.id] == nil && matrices.count == 2)
        let single = F.manifest(.room, sessions: sessions, rooms: [r1, r2, r3])
        let roomMatrices = StructureStore.placementMatrices(manifest: single, alignments: [r1.id: placement])
        let identityOK = [r1.id, r2.id, r3.id].allSatisfy { same(roomMatrices[$0], matrix_identity_float4x4) }
        c.check("matrices.roomProjectIdentity", identityOK)

        let raised = F.rectangle(150, SIMD2<Float>(0, 0), SIMD2<Float>(3, 4), wallBase: 300, baseY: 2.8)
        let footprint = RoomFootprint.from(raised, roomID: F.uuid(150))
        let footprintOK = footprint?.outline.count == 4 && F.near(footprint?.floorElevation ?? 0, 2.8, 1e-5)
            && F.near(Polygon2D(points: footprint?.outline ?? []).area, 12, 1e-3)
        c.check("footprint.fromRoomInput", footprintOK, "\(String(describing: footprint))")
        let empty = RoomInput(identifier: F.uuid(151), walls: [], openings: [], floors: [], objects: [], sections: [], story: 0)
        c.check("footprint.noOutlineNil", RoomFootprint.from(empty, roomID: F.uuid(151)) == nil)

        let previous = [RoomAlignmentRecord(roomID: r1.id, yaw: 0, translation: .zero, source: .measured),
                        RoomAlignmentRecord(roomID: r2.id, yaw: 0, translation: .zero, source: .measured)]
        let current = [RoomAlignmentRecord(roomID: r1.id, yaw: 0.1, translation: .zero, source: .user),
                       RoomAlignmentRecord(roomID: r2.id, yaw: 0, translation: .zero, source: .measured),
                       RoomAlignmentRecord(roomID: r3.id, yaw: 0, translation: .zero, source: .estimated)]
        let changed = HouseCleanModelStep.changedRooms(previous: previous, current: current)
        c.check("clean.changedRoomsReported", changed == [r1.id] && HouseCleanModelStep.changedRooms(previous: nil, current: current).isEmpty)
        c.check("clean.rulesVersion", HouseCleanModelStep.rulesVersion == "houseClean-rules=1")
    }
}
