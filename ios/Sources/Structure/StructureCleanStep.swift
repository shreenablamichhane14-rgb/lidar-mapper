import Foundation
import simd

// The House clean model (docs/MODULES.md 3.30): every active room built by RoomModel in its own
// capture frame, moved into the structure frame by its effective placement (derived records
// plus the user's alignment edits), then floors by elevation, shared walls with measured
// thickness, estimated exterior walls and each connecting doorway kept once. Raw data never
// moves; the transform is applied here, at derivation time.

/// id .cleanModel for House projects (AppShell schedules it instead of RoomModel's
/// CleanModelStep); required; budget 250 MB. Same provider shape as CleanModelStep.
final class HouseCleanModelStep: ProcessingStep {
    /// Which step this is.
    let id: PipelineStepID = .cleanModel
    /// Peak memory budget, bytes (250 MB, no reduced variant).
    let memoryBudgetBytes: UInt64 = 250 * 1024 * 1024
    /// Version of the house rules, part of the input hash.
    static let rulesVersion = "houseClean-rules=1"
    /// A placement change smaller than this is not reported as a change, meters or radians.
    static let changeTolerance: Float = 1e-4
    /// Supplies the consolidated measured mesh of a room.
    private let meshProvider: (ProjectPackage, UUID) -> MeshWithAttributes?

    /// (package, room id) -> consolidated measured mesh, nil when absent. The step passes
    /// `ctx.package` and asks for one room at a time.
    init(meshProvider: @escaping (ProjectPackage, UUID) -> MeshWithAttributes?) {
        self.meshProvider = meshProvider
    }

    /// Where each room goes and how its placement was found.
    struct Placement: Equatable, Sendable {
        /// Effective record per room (user edits included).
        var effective: [UUID: RoomAlignmentRecord]
        /// Method per room (`.user` where a user edit overrides).
        var methods: [UUID: AlignmentMethod]
        /// Active rooms of the anchor frame group (their elevations are in the structure frame).
        var anchor: Set<UUID>
        /// True when any derived placement came from the StructureBuilder merge.
        var fromStructure: Bool
        /// True when alignment.json was missing and the fallback plan was used.
        var usedFallback: Bool
    }

    /// Seals of the active rooms; per room id, floor, name, `supersededBy`, frame link,
    /// `buildRoom` and `consolidateMesh` stamp hashes; session links; the `alignRooms` stamp;
    /// `StructureStore.alignmentEditDigest(EditStore.load(package))` (only the alignment edits,
    /// never `EditLog.revision`); `findFurniture`; `rulesVersion`.
    func inputHash(_ ctx: StepContext) throws -> String {
        let package = ctx.package
        let index = try? ProjectStore.readJSON(DerivedIndex.self, from: package.derivedIndexURL)
        var seals: [SealFile] = []
        var extra = [HouseCleanModelStep.rulesVersion, "findFurniture=\(ctx.manifest.settings.findFurniture)"]
        for room in StructureEligibility.activeRooms(ctx.manifest) {
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: CapturedRoomStore.rawFolder(package, room: room).sealURL) {
                seals.append(seal)
            } else {
                extra.append("seal-missing=\(room.id.uuidString)")
            }
            let built = index?.stamp(step: .buildRoom, subject: room.id)?.inputHash ?? "-"
            let mesh = index?.stamp(step: .consolidateMesh, subject: room.id)?.inputHash ?? "-"
            let superseded = room.supersededBy?.uuidString ?? "-"
            let link = StructureEligibility.linkKey(room.frameLink)
            extra.append("room=\(room.id.uuidString)|floor=\(room.floorIndex)|name=\(room.name)|superseded=\(superseded)")
            extra.append("link=\(link)|buildRoom=\(built)|consolidateMesh=\(mesh)")
        }
        for session in ctx.manifest.sessions {
            extra.append("session=\(session.id.uuidString)|\(StructureEligibility.linkKey(session.frameLink))")
        }
        let aligned = index?.stamp(step: .alignRooms, subject: nil)?.inputHash ?? "-"
        extra.append("alignRooms=\(aligned)")
        extra.append("alignEdits=\(StructureStore.alignmentEditDigest(EditStore.load(package)))")
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// Builds each active room one at a time (one consolidated mesh in memory), places it,
    /// assigns floors, finds shared walls and doorways, writes clean.json (with its stamp) and
    /// then connections.json. Rooms without a loadable CapturedRoom or placement are left out and
    /// logged; only cancellation and failed writes throw.
    func run(_ ctx: StepContext) async throws {
        let package = ctx.package
        let manifest = ctx.manifest
        let records = StructureEligibility.activeRooms(manifest)
        var options = CleanBuildOptions()
        options.findFurniture = manifest.settings.findFurniture
        let edits = EditStore.load(package)
        var inputs = try loadInputs(ctx, records: records)
        let placement = HouseCleanModelStep.placements(package: package, manifest: manifest, records: records,
                                                       inputs: inputs, edits: edits)
        if placement.usedFallback { note("alignment.json missing; fallback placement plan without solves") }
        ctx.progress(0.1)

        var rooms: [CleanRoom] = []
        var applied: [RoomAlignmentRecord] = []
        for (i, record) in records.enumerated() {
            try ctx.checkCancelled()
            guard let input = inputs.removeValue(forKey: record.id) else { continue }
            guard let alignment = placement.effective[record.id] else {
                note("room \(record.id) left out: no placement yet (another frame, no outline)")
                continue
            }
            let built = buildRoom(ctx, input: input, record: record, options: options)
            rooms.append(StructureAlignment.apply(alignment, to: built))
            applied.append(alignment)
            let method = placement.methods[record.id]?.rawValue ?? "-"
            note("room \(record.id): placed by \(method), yaw \(alignment.yaw), translation \(alignment.translation.simd)")
            ctx.progress(0.1 + 0.7 * Double(i + 1) / Double(Swift.max(1, records.count)))
        }

        var userFloor: [UUID: Int] = [:]
        for record in records where userFloor[record.id] == nil { userFloor[record.id] = record.floorIndex }
        let floorInputs = rooms.map { room in
            FloorAssignmentInput(roomID: room.recordID, userFloor: userFloor[room.recordID] ?? room.floorIndex,
                                 elevation: placement.anchor.contains(room.recordID) ? room.floor.elevation : nil)
        }
        let floors = StructureFloors.assign(floorInputs)
        for i in rooms.indices {
            if let floor = floors[rooms[i].recordID] { rooms[i].floorIndex = floor }
        }

        var model = CleanModel(rooms: rooms, sourceIsStructure: placement.fromStructure, stamp: nil)
        let pairs = StructureWalls.sharedWalls(in: model)
        StructureWalls.applyThickness(pairs, exteriorThickness: options.exteriorThickness, to: &model)
        let links = StructureWalls.doorwayLinks(in: model, pairs: pairs)
        StructureWalls.applyDoorways(links, to: &model)
        try ctx.checkCancelled()

        let hash = (try? inputHash(ctx)) ?? "-"
        model.stamp = DerivedStamp(step: .cleanModel, subject: nil, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                   inputHash: hash, createdAt: Date())
        let previous = StructureStore.loadConnections(package)
        try CleanModelStore.save(model, to: package)
        let entries = model.rooms.map { FloorAssignmentEntry(roomID: $0.recordID, floorIndex: $0.floorIndex) }
        let connections = StructureConnections(sharedWalls: pairs, doorways: links, floors: entries, inputHash: hash,
                                               appliedAlignments: applied)
        try StructureStore.saveConnections(connections, to: package)
        ctx.progress(1)

        for id in HouseCleanModelStep.changedRooms(previous: previous?.appliedAlignments, current: applied) {
            note("room \(id): effective alignment changed since the previous build; edits that store absolute positions "
                 + "(moved objects, wall endpoints, added walls and openings, annotations, dimensions) stay where they were")
        }
        let floorCount = Set(entries.map { $0.floorIndex }).count
        note("wrote \(model.rooms.count) of \(records.count) rooms, \(pairs.count) shared walls, \(links.count) doorways, "
             + "\(floorCount) floors, from structure \(placement.fromStructure)")
    }

    /// Where each active room goes. With alignment.json: its records overridden by the user's
    /// alignment edits, and identity for an anchor-group room it does not list (it shares the
    /// structure frame). Without it: `StructureLayout.plan` with no solutions, overridden the same
    /// way.
    static func placements(package: ProjectPackage, manifest: ProjectManifest, records: [RoomRecord],
                           inputs: [UUID: RoomInput], edits: EditLog) -> Placement {
        let anchor = StructureEligibility.anchorRoomIDs(rooms: records, sessions: manifest.sessions)
        var methods: [UUID: AlignmentMethod] = [:]
        var effective: [UUID: RoomAlignmentRecord]
        let usedFallback: Bool
        if let measured = StructureStore.loadAlignmentsIfPresent(package) {
            for report in StructureStore.loadPlacements(package)?.rooms ?? [] { methods[report.roomID] = report.method }
            effective = StructureStore.effectiveAlignments(measured: measured, log: edits)
            for room in records where anchor.contains(room.id) && effective[room.id] == nil {
                effective[room.id] = StructureAlignment.identity(roomID: room.id, source: .measured)
                methods[room.id] = .sharedFrame
            }
            usedFallback = false
        } else {
            var footprints: [UUID: RoomFootprint] = [:]
            for room in records {
                guard let input = inputs[room.id], let footprint = RoomFootprint.from(input, roomID: room.id) else { continue }
                footprints[room.id] = footprint
            }
            let plan = StructureLayout.plan(rooms: records, sessions: manifest.sessions, footprints: footprints, solutions: [:])
            for report in plan.reports { methods[report.roomID] = report.method }
            effective = StructureStore.effectiveAlignments(measured: plan.records, log: edits)
            usedFallback = true
        }
        let fromStructure = methods.values.contains { $0 == .structureMerge || $0 == .groupMedian }
        for id in StructureStore.userAlignments(edits).keys { methods[id] = .user }
        return Placement(effective: effective, methods: methods, anchor: anchor, fromStructure: fromStructure,
                         usedFallback: usedFallback)
    }

    /// Rooms whose placement differs from the previous build's by more than `changeTolerance`
    /// (rooms new to this build are not changes), in `current` order. Pure.
    static func changedRooms(previous: [RoomAlignmentRecord]?, current: [RoomAlignmentRecord]) -> [UUID] {
        guard let previous else { return [] }
        var before: [UUID: RoomAlignmentRecord] = [:]
        for record in previous { before[record.roomID] = record }
        return current.compactMap { record -> UUID? in
            guard let old = before[record.roomID] else { return nil }
            let turn = abs(StructureAlignment.wrapped(record.yaw - old.yaw))
            let shift = simd_distance(record.translation.simd, old.translation.simd)
            return (turn > changeTolerance || shift > changeTolerance) ? record.roomID : nil
        }
    }

    /// Each room's RoomInput, leaving out rooms whose capture says RoomPlan failed and rooms
    /// with no loadable CapturedRoom (logged, as CleanModelStep does).
    private func loadInputs(_ ctx: StepContext, records: [RoomRecord]) throws -> [UUID: RoomInput] {
        var inputs: [UUID: RoomInput] = [:]
        for record in records {
            try ctx.checkCancelled()
            if CleanModelStep.roomPlanFailed(ctx.package, room: record) {
                note("room \(record.id) left out, RoomPlan failed during capture")
                continue
            }
            do {
                inputs[record.id] = try CapturedRoomStore.loadInput(ctx.package, room: record)
            } catch {
                note("room \(record.id) left out, no CapturedRoom (\(error))")
            }
        }
        return inputs
    }

    /// One room in its capture frame with its consolidated mesh, which is released on return.
    private func buildRoom(_ ctx: StepContext, input: RoomInput, record: RoomRecord, options: CleanBuildOptions) -> CleanRoom {
        let mesh = meshProvider(ctx.package, record.id)
        if mesh == nil { note("room \(record.id) has no consolidated mesh; heights from RoomPlan") }
        return CleanModelBuilder.buildRoom(input, recordID: record.id, name: record.name, floorIndex: record.floorIndex,
                                           mesh: mesh, options: options)
    }

    /// Writes a log line (category "structure").
    private func note(_ message: String) {
        LogStore.shared.write("houseClean: " + message, category: StructureStore.logCategory)
    }
}
