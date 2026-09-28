import Foundation
import simd

// Demo Mode's synthetic room (docs/MODULES.md 3.24, ARCHITECTURE 10.3, D1): a 4 x 5 m room,
// 2.5 m high, with a door, a window, a table and a sofa, written as a complete project so every
// result screen, export and measurement works without ARKit or the camera. The files come from
// the real builders (RoomModel, MeshModel, FloorPlan, Quality) fed with a hand-made RoomPlan-style
// `RoomInput`, a synthetic mesh chunk and a synthetic camera walk (DemoProjectGeometry.swift).

/// Writes the demo room of a Demo Mode scan. Stateless; runs off the main thread (file IO).
enum DemoProjectFactory {
    /// Log category.
    static let logCategory = "scanui"
    /// Room size in plan meters (x by y) and height.
    static let roomWidth: Float = 4, roomDepth: Float = 5, roomHeight: Float = 2.5
    /// Seconds the demo capture log reports (the synthetic replay: 120 snapshots, 0.25 s apart).
    static let demoSeconds: Double = 30

    /// Writes a synthetic 4 x 5 m room with a door, a window, a table and a sofa: a sealed raw
    /// folder (`ProjectStore.sealRawFolder`) with one synthetic mesh chunk and roomlog.json and no
    /// RoomPlan or keyframe files, derived clean.json, plan.json, mesh files and quality.json, and
    /// a plan thumbnail (best effort); returns the record (status `.processed`). The caller sets
    /// the project status `.ready`, so the demo project is never enqueued for processing.
    static func makeDemoRoom(package: ProjectPackage, sessionID: UUID, roomID: UUID, now: Date) throws -> (RoomRecord, QualityEvaluation) {
        let started = ProcessInfo.processInfo.systemUptime
        let shell = DemoProjectGeometry.shellMesh(width: roomWidth, depth: roomDepth, height: roomHeight, cell: 0.25)
        let log = RoomCaptureLog(seconds: demoSeconds, instructionSeconds: [:], error: nil, relocalizations: 0,
                                 limitedTrackingFraction: 0, degraded: .allGood)
        let seal = try writeRawRoom(package: package, sessionID: sessionID, roomID: roomID, shell: shell, log: log, now: now)

        let chunk = meshChunk(shell, anchorID: roomID)
        guard let consolidated = MeshConsolidator.consolidate([chunk], options: ConsolidationOptions(), isCancelled: { false })
        else {
            throw MapperError.ioFailed("demo mesh consolidation cancelled")
        }
        try MeshModelStore.save(consolidated, package: package, room: roomID)

        let input = roomInput()
        let room = CleanModelBuilder.buildRoom(input, recordID: roomID, name: "", floorIndex: 0,
                                               mesh: consolidated.measured, options: CleanBuildOptions())
        let clean = CleanModel(rooms: [room], sourceIsStructure: false, stamp: nil)
        try CleanModelStore.save(clean, to: package)
        let floors = [FloorRecord(id: 0, name: "", elevation: 0)]
        let plan = PlanBuilder.build(from: clean, floors: floors)
        try PlanModelStore.save(plan, to: package)

        let walk = DemoProjectGeometry.walk(center: SIMD2<Float>(roomWidth * 0.5, roomDepth * 0.5), eyeHeight: 1.4)
        let evaluation = QualityEvaluator.evaluate(roomID: roomID, room: room, mesh: shell,
                                                   poses: DemoProjectGeometry.poses(walk),
                                                   keyframes: DemoProjectGeometry.keyframes(walk), log: log,
                                                   inputHash: QualityEvaluator.doneInputHash(seal: seal), now: now)
        try QualityStore.save(evaluation, package: package)
        writeThumbnail(plan: plan, clean: clean, package: package)

        let record = RoomRecord(id: roomID, name: "", sessionID: sessionID, floorIndex: 0, status: .processed,
                                capturedRoomID: nil, quality: evaluation.summary, hasMeshPass: false, keyframeCount: 0,
                                capturedAt: now, frameLink: .projectFrame(sessionID: sessionID))
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        LogStore.shared.write("demo room \(roomID): \(shell.triangleCount) triangles, verdict "
                              + "\(evaluation.summary.verdict.rawValue), \(milliseconds) ms", category: logCategory)
        return (record, evaluation)
    }

    // MARK: - Raw folder

    /// Creates `raw/sessions/<s>/rooms/<r>/` inside the existing package (never the package
    /// itself), writes the mesh chunk and roomlog.json, then seals the folder.
    static func writeRawRoom(package: ProjectPackage, sessionID: UUID, roomID: UUID, shell: MeshWithAttributes,
                             log: RoomCaptureLog, now: Date) throws -> SealFile {
        let folder = RawScanFolder(url: package.rawRoomURL(session: sessionID, room: roomID))
        try ProjectStore.ensureDirectory(folder.meshURL, inside: package.root)
        let chunkData = MeshChunkFile.encode(meshChunk(shell, anchorID: roomID))
        try ProjectStore.writeData(chunkData, to: folder.meshChunkURL(anchor: roomID), createParents: false)
        try ProjectStore.writeData(try ProjectStore.encoder.encode(log), to: folder.roomLogURL, createParents: false)
        return try ProjectStore.sealRawFolder(folder.url, now: now)
    }

    /// The shell as one anchor chunk at the identity transform, with per-vertex normals and
    /// per-face classes (1 wall, 2 floor, 3 ceiling).
    static func meshChunk(_ shell: MeshWithAttributes, anchorID: UUID) -> MeshChunk {
        MeshChunk(anchorID: anchorID, transform: matrix_identity_float4x4, updateCount: 1,
                  positions: shell.mesh.positions, normals: MeshCleanup.normals(shell.mesh),
                  indices: shell.mesh.indices, classes: shell.faceClass ?? [])
    }

    // MARK: - Room

    /// The RoomPlan-style room: walls counter-clockwise from plan (0, 0) along +x, a door on
    /// the first wall, a window on the third, a floor surface, a table in the middle, a sofa
    /// along the fourth wall and a living room section.
    static func roomInput() -> RoomInput {
        let corners: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(roomWidth, 0),
                                       SIMD2<Float>(roomWidth, roomDepth), SIMD2<Float>(0, roomDepth)]
        var walls: [SurfaceInput] = []
        for i in 0..<corners.count {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            walls.append(surface(id: 10 + i, kind: .wall, parent: nil, from: a, to: b, bottom: 0, top: roomHeight))
        }
        let door = surface(id: 20, kind: .door, parent: 10, from: SIMD2<Float>(1.0, 0), to: SIMD2<Float>(1.9, 0),
                           bottom: 0, top: 2.03)
        let window = surface(id: 21, kind: .window, parent: 12, from: SIMD2<Float>(2.8, roomDepth),
                             to: SIMD2<Float>(1.6, roomDepth), bottom: 0.9, top: 2.1)
        let table = object(id: 30, .table, center: SIMD2<Float>(2.2, 2.4), size: SIMD3<Float>(1.4, 0.75, 0.8))
        let sofa = object(id: 31, .sofa, center: SIMD2<Float>(0.5, 2.5), size: SIMD3<Float>(0.9, 0.85, 2.0))
        let middle = PlanAxes.toWorld(SIMD2<Float>(roomWidth * 0.5, roomDepth * 0.5), y: 0)
        let section = SectionInput(label: "livingRoom", center: Vec3(middle), story: 0)
        return RoomInput(identifier: demoUUID(1), walls: walls, openings: [door, window], floors: [floorSurface(corners)],
                         objects: [table, sofa], sections: [section], story: 0)
    }

    /// A wall, door or window from plan `a` to plan `b` between world heights `bottom` and
    /// `top`, in RoomPlan's frame (columns.0 along the surface, columns.1 up, center at mid-height).
    static func surface(id: Int, kind: SurfaceKind, parent: Int?, from a: SIMD2<Float>, to b: SIMD2<Float>,
                        bottom: Float, top: Float) -> SurfaceInput {
        let wa = PlanAxes.toWorld(a, y: 0)
        let wb = PlanAxes.toWorld(b, y: 0)
        let length = simd_distance(wa, wb)
        let along = length > 0 ? (wb - wa) / length : SIMD3<Float>(1, 0, 0)
        let up = SIMD3<Float>(0, 1, 0)
        let normal = simd_cross(along, up)
        let middle = (wa + wb) * 0.5
        let center = SIMD3<Float>(middle.x, (bottom + top) * 0.5, middle.z)
        let m = simd_float4x4(columns: (SIMD4<Float>(along, 0), SIMD4<Float>(up, 0), SIMD4<Float>(normal, 0),
                                        SIMD4<Float>(center, 1)))
        return SurfaceInput(identifier: demoUUID(id), parentIdentifier: parent.map { demoUUID($0) }, kind: kind,
                            transform: Transform4(m), dimensions: Vec3(x: length, y: top - bottom, z: 0),
                            confidence: .high, completedEdges: 4, curve: nil, polygonCorners: [], story: 0)
    }

    /// The floor surface: local frame with columns.2 = world up, corners as local (x, y) plan points.
    static func floorSurface(_ corners: [SIMD2<Float>]) -> SurfaceInput {
        let m = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, -1, 0),
                                        SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 0, 1)))
        return SurfaceInput(identifier: demoUUID(40), parentIdentifier: nil, kind: .floor, transform: Transform4(m),
                            dimensions: Vec3(x: roomWidth, y: roomDepth, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: corners.map { Vec3(x: $0.x, y: $0.y, z: 0) }, story: 0)
    }

    /// A gravity-aligned furniture box centered at plan `center`, standing on the floor.
    static func object(id: Int, _ category: ObjectCategory, center: SIMD2<Float>, size: SIMD3<Float>) -> ObjectInput {
        var m = matrix_identity_float4x4
        let world = PlanAxes.toWorld(center, y: size.y * 0.5)
        m.columns.3 = SIMD4<Float>(world, 1)
        return ObjectInput(identifier: demoUUID(id), parentIdentifier: nil, category: category, transform: Transform4(m),
                           dimensions: Vec3(size), confidence: .high, story: 0)
    }

    /// A fixed identifier from a small number (the demo room is deterministic).
    static func demoUUID(_ n: Int) -> UUID {
        let hi = UInt8(truncatingIfNeeded: n >> 8)
        let lo = UInt8(truncatingIfNeeded: n)
        return UUID(uuid: (0x44, 0x45, 0x4D, 0x4F, 0x52, 0x4F, 0x4F, 0x4D, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    // MARK: - Thumbnail

    /// Writes thumbnail.jpg from the plan like ThumbnailStep does (best effort, logged).
    static func writeThumbnail(plan: PlanModel, clean: CleanModel, package: ProjectPackage) {
        guard let level = plan.levels.first else { return }
        let name = (try? ProjectStore.readManifest(package))?.name ?? ""
        let titles = RoomTitles.titles(for: plan, clean: clean)
        let drawing = PlanDrawing.make(level: level, toggles: ThumbnailStep.toggles, prefs: UnitPreferences.load(),
                                       roomTitles: titles, name: name)
        guard let jpeg = PlanRenderer.jpegThumbnail(drawing.plan, pixelSize: ThumbnailStep.pixelSize) else { return }
        do {
            try ProjectStore.writeData(jpeg, to: package.thumbnailURL, createParents: false)
        } catch {
            LogStore.shared.write("demo thumbnail not written: \(StoreFiles.describe(error))", category: logCategory)
        }
    }
}
