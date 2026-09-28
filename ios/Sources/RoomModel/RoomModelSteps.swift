import Foundation
import RoomPlan

/// Rebuilds capturedroom.json from capturedroomdata.json when raw lacks it (RoomBuilder threw or
/// the app was killed after didEndWith). Catches `RoomBuilder` errors, logs them and completes
/// without output, so CleanModelStep and FloorPlanStep leave the room out (never fails the job).
/// Output: `derived/rooms/<id>/capturedroom.json`, written with a plain `JSONEncoder()`.
final class BuildRoomStep: ProcessingStep {
    /// Which step this is.
    let id: PipelineStepID = .buildRoom
    /// Peak memory budget, bytes (150 MB, no reduced variant).
    let memoryBudgetBytes: UInt64 = 150 * 1024 * 1024
    /// The room to rebuild.
    let room: RoomRecord

    /// A step for one room.
    init(room: RoomRecord) {
        self.room = room
    }

    /// Hash of the room's raw seal (the folder holds capturedroomdata.json) and the room id.
    func inputHash(_ ctx: StepContext) throws -> String {
        let folder = CapturedRoomStore.rawFolder(ctx.package, room: room)
        let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        let extra = ["buildRoom-rules=1", "room=\(room.id.uuidString)", seal == nil ? "seal=missing" : "seal=present"]
        return InputHasher.hash(seals: seal.map { [$0] } ?? [], editRevision: nil, extra: extra)
    }

    /// Runs `RoomBuilder(options: [.beautifyObjects])` on the raw room data. Missing or
    /// unreadable data and builder errors are logged and end the step without output; only
    /// cancellation and file write failures throw.
    func run(_ ctx: StepContext) async throws {
        try ctx.checkCancelled()
        let folder = CapturedRoomStore.rawFolder(ctx.package, room: room)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.capturedRoomURL.path) {
            log("raw capturedroom.json exists; nothing to rebuild")
            return
        }
        guard fm.fileExists(atPath: folder.capturedRoomDataURL.path) else {
            log("no capturedroomdata.json; room left out")
            return
        }
        let data: CapturedRoomData
        do {
            data = try CapturedRoomStore.decodeRoomPlanJSON(CapturedRoomData.self, from: folder.capturedRoomDataURL,
                                                            maxBytes: CapturedRoomStore.maxCapturedRoomDataBytes)
        } catch {
            log("capturedroomdata.json unreadable (\(error)); room left out")
            return
        }
        ctx.progress(0.1)
        let started = Date()
        let captured: CapturedRoom
        do {
            let builder = RoomBuilder(options: [.beautifyObjects])
            captured = try await builder.capturedRoom(from: data)
        } catch {
            log("RoomBuilder failed (\(error)); room left out")
            return
        }
        try ctx.checkCancelled()
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(captured)
        } catch {
            log("CapturedRoom could not be encoded (\(error)); room left out")
            return
        }
        try ProjectStore.ensureDirectory(ctx.package.derivedRoomURL(room.id), inside: ctx.package.root)
        try ProjectStore.writeData(encoded, to: CapturedRoomStore.rebuiltURL(ctx.package, roomID: room.id), createParents: false)
        ctx.progress(1)
        let seconds = Date().timeIntervalSince(started)
        log("rebuilt capturedroom.json in \(Int(seconds * 1000)) ms, \(captured.walls.count) walls")
    }

    /// Writes a log line for this room.
    private func log(_ message: String) {
        LogStore.shared.write("buildRoom \(room.id): \(message)", category: RoomOutline.logCategory)
    }
}

/// Builds derived/clean.json for every room with status captured or processed. A room with no
/// loadable CapturedRoom (RoomPlan failed) is left out of the model and logged; an empty model is
/// still written so FloorPlanStep and Results can report "no walls".
final class CleanModelStep: ProcessingStep {
    /// Which step this is.
    let id: PipelineStepID = .cleanModel
    /// Peak memory budget, bytes (200 MB, no reduced variant).
    let memoryBudgetBytes: UInt64 = 200 * 1024 * 1024
    /// Version of the builder rules, part of the input hash so a rule change rebuilds.
    static let rulesVersion = "cleanModel-rules=1"
    /// Supplies the consolidated measured mesh of a room.
    private let meshProvider: (ProjectPackage, UUID) -> MeshWithAttributes?

    /// (package, room id) -> consolidated measured mesh, nil when absent. The step passes `ctx.package`.
    init(meshProvider: @escaping (ProjectPackage, UUID) -> MeshWithAttributes?) {
        self.meshProvider = meshProvider
    }

    /// Rooms the clean model includes: status captured or processed, manifest order.
    static func eligibleRooms(_ manifest: ProjectManifest) -> [RoomRecord] {
        manifest.rooms.filter { $0.status == .captured || $0.status == .processed }
    }

    /// Room seals, room ids, names and floors, `findFurniture`, the rules version, and each
    /// room's current `buildRoom` and `consolidateMesh` stamp hashes ("-" when absent). The edit
    /// revision is not included: the base model ignores edits.
    func inputHash(_ ctx: StepContext) throws -> String {
        let index = try? ProjectStore.readJSON(DerivedIndex.self, from: ctx.package.derivedIndexURL)
        var seals: [SealFile] = []
        var extra = [CleanModelStep.rulesVersion, "findFurniture=\(ctx.manifest.settings.findFurniture)"]
        for room in CleanModelStep.eligibleRooms(ctx.manifest) {
            let folder = CapturedRoomStore.rawFolder(ctx.package, room: room)
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL) {
                seals.append(seal)
            } else {
                extra.append("seal-missing=\(room.id.uuidString)")
            }
            let built = index?.stamp(step: .buildRoom, subject: room.id)?.inputHash ?? "-"
            let mesh = index?.stamp(step: .consolidateMesh, subject: room.id)?.inputHash ?? "-"
            extra.append("room=\(room.id.uuidString)|floor=\(room.floorIndex)|name=\(room.name)|buildRoom=\(built)|consolidateMesh=\(mesh)")
        }
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// Builds each room one at a time (so only one consolidated mesh is in memory) and writes
    /// the model with its stamp. Rooms whose CapturedRoom cannot be loaded are left out.
    func run(_ ctx: StepContext) async throws {
        let records = CleanModelStep.eligibleRooms(ctx.manifest)
        var options = CleanBuildOptions()
        options.findFurniture = ctx.manifest.settings.findFurniture
        var rooms: [CleanRoom] = []
        for (i, record) in records.enumerated() {
            try ctx.checkCancelled()
            let input: RoomInput
            do {
                input = try CapturedRoomStore.loadInput(ctx.package, room: record)
            } catch {
                LogStore.shared.write("cleanModel: room \(record.id) left out, no CapturedRoom (\(error))",
                                      category: RoomOutline.logCategory)
                continue
            }
            let mesh = meshProvider(ctx.package, record.id)
            if mesh == nil {
                LogStore.shared.write("cleanModel: room \(record.id) has no consolidated mesh; heights from RoomPlan",
                                      category: RoomOutline.logCategory)
            }
            let room = CleanModelBuilder.buildRoom(input, recordID: record.id, name: record.name, floorIndex: record.floorIndex,
                                                   mesh: mesh, options: options)
            rooms.append(room)
            let done = Double(i + 1) / Double(Swift.max(1, records.count))
            ctx.progress(done * 0.9)
        }
        try ctx.checkCancelled()
        let hash = (try? inputHash(ctx)) ?? "-"
        let stamp = DerivedStamp(step: .cleanModel, subject: nil, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                 inputHash: hash, createdAt: Date())
        try CleanModelStore.save(CleanModel(rooms: rooms, sourceIsStructure: false, stamp: stamp), to: ctx.package)
        ctx.progress(1)
        LogStore.shared.write("cleanModel: wrote \(rooms.count) of \(records.count) rooms", category: RoomOutline.logCategory)
    }
}
