import Foundation
import simd
import RoomPlan

/// House and multi-level outputs (docs/MODULES.md 3.43d): one plan drawing per floor, every
/// active room's raw and textured mesh placed with its alignment inside one triangle budget, and
/// the clean USDZ through RoomPlan's `CapturedStructure.export` when the automatic merge holds.
/// Superseded rooms (CR-7) are never exported. Pure functions plus reads inside the package;
/// nonisolated, call them off main.
enum ExportHouse {
    /// One floor's drawing: `level` is the 1-based floor number (`PlanLevel.id + 1`), `title` the
    /// floor's name.
    typealias LevelDrawing = (level: Int, title: String, plan: Plan2D)

    /// A room an export can place: its record, where it goes and its title.
    struct PlacedRoom {
        /// The active room.
        var record: RoomRecord
        /// `StructureStore.placementMatrices` entry of the room.
        var matrix: simd_float4x4
        /// The room's title (`RoomTitles`), unique within the export.
        var title: String
    }

    /// Whole-house triangle budget of the binary raw formats (PLY, STL, GLB), whose build 4 rule
    /// (always the full measured mesh) would hold every room's full mesh at once on a 6 GB phone.
    static let maxBinaryTriangles = 2_000_000

    /// The smallest per-room limit: a room is never simplified below this many triangles.
    static let minimumRoomTriangles = 50_000

    /// Per-room limit that keeps a house inside one budget: `max(50_000, total / rooms)`.
    static func perRoomLimit(total: Int, rooms: Int) -> Int {
        guard rooms > 0 else { return Swift.max(minimumRoomTriangles, total) }
        return Swift.max(minimumRoomTriangles, total / rooms)
    }

    // MARK: - Plans

    /// One drawing per plan level with rooms or walls, in level order, with the result screen's
    /// toggles (EXP-05) and the level's title (`PlanLevel.name`, else `Copy.House.floorLabel(id + 1)`).
    static func planDrawings(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles) throws
        -> [(level: Int, title: String, plan: Plan2D)] {
        try planExport(package, prefs: prefs, toggles: toggles, includeHidden: false).drawings
    }

    /// The edited plan's drawings and its north angle (PlanModel convention). `includeHidden`
    /// draws fixtures the user hid. Throws `CoreError.missingFile` without plan.json and
    /// `ExportError.emptyPlan` when no level has rooms or walls.
    static func planExport(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles,
                           includeHidden: Bool) throws -> (drawings: [LevelDrawing], northAngle: Float) {
        let plan = try PlanModelStore.loadEdited(package).plan
        let clean = try? CleanModelStore.loadBase(package)
        let name = (try? ProjectStore.readManifest(package))?.name ?? ""
        let drawings = try planDrawings(plan: plan, clean: clean, name: name, prefs: prefs, toggles: toggles,
                                        includeHidden: includeHidden)
        return (drawings, plan.northAngle)
    }

    /// Pure form of `planDrawings`: a single level keeps the project name as its plan name (as
    /// build 4), several levels get `Copy.ExportUI.levelPlanName(name, level:)` in the title block.
    static func planDrawings(plan: PlanModel, clean: CleanModel?, name: String, prefs: UnitPreferences,
                             toggles: PlanToggles, includeHidden: Bool) throws -> [LevelDrawing] {
        let levels = plan.levels.filter { !$0.rooms.isEmpty || !$0.walls.isEmpty }.sorted { $0.id < $1.id }
        guard !levels.isEmpty else { throw ExportError.emptyPlan }
        let titles = RoomTitles.titles(for: plan, clean: clean)
        var result: [LevelDrawing] = []
        for source in levels {
            var level = source
            if includeHidden {
                level.fixtures = level.fixtures.map { fixture in
                    var copy = fixture
                    copy.isHidden = false
                    return copy
                }
            }
            let title = levelTitle(level)
            let planName = levels.count == 1 ? name : Copy.ExportUI.levelPlanName(name, level: title)
            let drawing = PlanDrawing.make(level: level, toggles: toggles, prefs: prefs, roomTitles: titles, name: planName)
            result.append((level: level.id + 1, title: title, plan: drawing.plan))
        }
        return result
    }

    /// The level's own name, else "Floor n" (1-based).
    static func levelTitle(_ level: PlanLevel) -> String {
        let trimmed = level.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Copy.House.floorLabel(level.id + 1) : trimmed
    }

    // MARK: - Raw scan

    /// Every active room's measured mesh (full, or the view mesh plus the inferred mesh above the
    /// room's limit, as build 4), placed with `StructureStore.placementMatrices` (rooms without an
    /// entry are left out, logged); one ExportMesh per room, named by its room title, with class
    /// colors and the Inferred color on hole fills. `maxTextTriangles` is the whole-house budget:
    /// `ExportCatalog.textTriangleLimit` for OBJ and USDZ, `maxBinaryTriangles` for the binary
    /// formats, split with `perRoomLimit`. Rooms are read one at a time; each room's
    /// intermediates are released before the next.
    static func rawScene(_ package: ProjectPackage, manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord],
                         maxTextTriangles: Int) throws -> ExportScene {
        try rawScene(package, manifest: manifest, alignments: alignments, maxTextTriangles: maxTextTriangles,
                     step: { _, _ in })
    }

    /// As `rawScene(_:manifest:alignments:maxTextTriangles:)`; `step(n, count)` runs before room
    /// `n` of `count` (the runner checks cancellation and reports progress there).
    static func rawScene(_ package: ProjectPackage, manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord],
                         maxTextTriangles: Int, step: (Int, Int) throws -> Void) throws -> ExportScene {
        let fm = FileManager.default
        let rooms = placedRooms(package, manifest: manifest, alignments: alignments).filter { room in
            fm.fileExists(atPath: MeshModelStore.measuredURL(package, room: room.record.id).path)
        }
        guard !rooms.isEmpty else { throw CoreError.missingFile(MeshModelStore.measuredFileName) }
        let limit = perRoomLimit(total: maxTextTriangles, rooms: rooms.count)
        var meshes: [ExportMesh] = []
        var simplified = false
        for (n, room) in rooms.enumerated() {
            try step(n, rooms.count)
            guard let part = try roomRawMesh(package, room: room.record.id, limit: limit, name: room.title) else { continue }
            if part.simplified { simplified = true }
            meshes.append(transformedMesh(part.mesh, by: room.matrix))
        }
        guard !meshes.isEmpty else { throw CoreError.missingFile(MeshModelStore.measuredFileName) }
        var scene = ExportScene(meshes: meshes, materials: [], metadata: ExportAdapters.baseMetadata)
        scene.metadata["rooms"] = String(meshes.count)
        if simplified { scene.metadata["note"] = Copy.ExportUI.simplifiedNote }
        return scene
    }

    /// One room's raw mesh inside `limit`: the full measured mesh, or the view mesh above the
    /// limit (the measured mesh when the view mesh is missing), joined with the inferred mesh.
    /// Nil when the room has no mesh or no triangle survives.
    static func roomRawMesh(_ package: ProjectPackage, room: UUID, limit: Int,
                            name: String) throws -> (mesh: ExportMesh, simplified: Bool)? {
        var useView = false
        if let stats = MeshModelStore.loadStats(package, room: room) {
            useView = ExportAdapters.rawSource(measuredTriangles: stats.triangleCount, maxTextTriangles: limit) == .view
        }
        var body: MeshWithAttributes?
        if !useView {
            body = try MeshModelStore.loadMeasured(package, room: room)
            if let measured = body, measured.triangleCount > limit {
                body = nil
                useView = true
            }
        }
        if useView {
            body = try MeshModelStore.loadView(package, room: room)
            if body == nil {
                LogStore.shared.write("export: room \(room.uuidString) has no view mesh, using the measured mesh",
                                      category: ExportRunner.logCategory)
                useView = false
                body = try MeshModelStore.loadMeasured(package, room: room)
            }
        }
        guard let mesh = body else { return nil }
        let inferred = try MeshModelStore.loadInferred(package, room: room)
        let joined = joinedWithInferred(mesh, inferred: inferred)
        let exportMesh = MeshExportAdapter.exportMesh(joined, name: name, colorByClass: true)
        guard exportMesh.triangleCount > 0 else { return nil }
        return (exportMesh, useView)
    }

    /// `body` followed by the faces of `inferred`, every inferred face flagged `isInferred` (the
    /// Inferred color in class-colored exports). Vertex colors are dropped; face classes of the
    /// inferred faces are unclassified. Out-of-range inferred indices stay out of range, so the
    /// export adapter drops those faces.
    static func joinedWithInferred(_ body: MeshWithAttributes, inferred: MeshWithAttributes?) -> MeshWithAttributes {
        guard let inferred, inferred.triangleCount > 0 else { return body }
        let bodyFaces = body.triangleCount
        let inferredFaces = inferred.triangleCount
        let bodyVertices = body.mesh.positions.count
        let inferredVertices = inferred.mesh.positions.count
        var positions = body.mesh.positions
        positions.append(contentsOf: inferred.mesh.positions)
        var indices = Array(body.mesh.indices.prefix(3 * bodyFaces))
        indices.reserveCapacity(3 * (bodyFaces + inferredFaces))
        let offset = UInt32(truncatingIfNeeded: bodyVertices)
        for index in inferred.mesh.indices.prefix(3 * inferredFaces) {
            indices.append(Int(index) < inferredVertices ? index &+ offset : UInt32.max)
        }
        var classes = padded(body.faceClass, count: bodyFaces, fill: MeshWithAttributes.unclassified)
        classes.append(contentsOf: [UInt8](repeating: MeshWithAttributes.unclassified, count: inferredFaces))
        var flags = padded(body.isInferred, count: bodyFaces, fill: false)
        flags.append(contentsOf: [Bool](repeating: true, count: inferredFaces))
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices), faceClass: classes,
                                  vertexColor: nil, isInferred: flags)
    }

    /// `values` cut or filled with `fill` to exactly `count` entries.
    static func padded<T>(_ values: [T]?, count: Int, fill: T) -> [T] {
        var result = Array((values ?? []).prefix(count))
        if result.count < count { result.append(contentsOf: [T](repeating: fill, count: count - result.count)) }
        return result
    }

    // MARK: - Realistic

    /// Every active room's `ExportAdapters.texturedScene` placed like `rawScene`, materials concatenated.
    static func texturedScene(_ package: ProjectPackage, manifest: ProjectManifest,
                              alignments: [UUID: RoomAlignmentRecord]) throws -> ExportScene {
        try texturedScene(package, manifest: manifest, alignments: alignments, includeTextures: true, step: { _, _ in })
    }

    /// As `texturedScene(_:manifest:alignments:)`; `includeTextures` false leaves the images out
    /// (Include textures off) and `step(n, count)` runs before room `n` of `count`. Rooms without
    /// a texture are left out (logged); throws `ExportError.emptyScene` when none has one.
    static func texturedScene(_ package: ProjectPackage, manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord],
                              includeTextures: Bool, step: (Int, Int) throws -> Void) throws -> ExportScene {
        let rooms = placedRooms(package, manifest: manifest, alignments: alignments)
        var scenes: [ExportScene] = []
        for (n, room) in rooms.enumerated() {
            try step(n, rooms.count)
            guard let mesh = try TextureStore.load(package, room: room.record.id) else {
                LogStore.shared.write("export: room \(room.record.id.uuidString) has no texture, left out",
                                      category: ExportRunner.logCategory)
                continue
            }
            let scene = try ExportAdapters.texturedScene(mesh, includeTextures: includeTextures)
            scenes.append(transformed(scene, by: room.matrix))
        }
        guard !scenes.isEmpty else { throw ExportError.emptyScene }
        return ExportAdapters.merged(scenes)
    }

    // MARK: - Placement

    /// A scene moved by a rigid transform: positions by the matrix, normals by its rotation, texcoords kept.
    static func transformed(_ scene: ExportScene, by matrix: simd_float4x4) -> ExportScene {
        var result = scene
        result.meshes = scene.meshes.map { transformedMesh($0, by: matrix) }
        return result
    }

    /// One mesh moved by a rigid transform (identity returns the mesh unchanged); normals are
    /// rotated and renormalized, colors and texture coordinates kept.
    static func transformedMesh(_ mesh: ExportMesh, by matrix: simd_float4x4) -> ExportMesh {
        if isIdentity(matrix) { return mesh }
        let c0: SIMD4<Float> = matrix.columns.0
        let c1: SIMD4<Float> = matrix.columns.1
        let c2: SIMD4<Float> = matrix.columns.2
        let rotation = simd_float3x3(columns: (SIMD3<Float>(c0.x, c0.y, c0.z), SIMD3<Float>(c1.x, c1.y, c1.z),
                                              SIMD3<Float>(c2.x, c2.y, c2.z)))
        var copy = mesh
        copy.positions = mesh.positions.map { p -> SIMD3<Float> in
            let moved: SIMD4<Float> = matrix * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD3<Float>(moved.x, moved.y, moved.z)
        }
        if let normals = mesh.normals {
            copy.normals = normals.map { n -> SIMD3<Float> in
                let turned: SIMD3<Float> = rotation * n
                let length = simd_length(turned)
                return length.isFinite && length > 1e-12 ? turned / length : n
            }
        }
        return copy
    }

    /// True for the exact identity matrix.
    static func isIdentity(_ matrix: simd_float4x4) -> Bool {
        let first: Bool = matrix.columns.0 == SIMD4<Float>(1, 0, 0, 0) && matrix.columns.1 == SIMD4<Float>(0, 1, 0, 0)
        let second: Bool = matrix.columns.2 == SIMD4<Float>(0, 0, 1, 0) && matrix.columns.3 == SIMD4<Float>(0, 0, 0, 1)
        return first && second
    }

    /// The active rooms with a placement, in manifest order, with unique titles. Rooms without a
    /// placement (another frame group waiting for AlignRoomsStep) are left out and logged.
    static func placedRooms(_ package: ProjectPackage, manifest: ProjectManifest,
                            alignments: [UUID: RoomAlignmentRecord]) -> [PlacedRoom] {
        let matrices = StructureStore.placementMatrices(manifest: manifest, alignments: alignments)
        let active = StructureEligibility.activeRooms(manifest)
        let titles = roomTitles(package, rooms: active)
        var result: [PlacedRoom] = []
        for (n, record) in active.enumerated() {
            guard let matrix = matrices[record.id] else {
                LogStore.shared.write("export: room \(record.id.uuidString) has no placement yet, left out",
                                      category: ExportRunner.logCategory)
                continue
            }
            let title = n < titles.count ? titles[n] : Copy.FloorPlan.defaultRoomTitle(n + 1)
            result.append(PlacedRoom(record: record, matrix: matrix, title: title))
        }
        let unique = ExportText.uniqued(result.map { $0.title })
        for index in result.indices where index < unique.count { result[index].title = unique[index] }
        return result
    }

    /// Titles of `rooms` in order: the edited clean model's title of the room with the same
    /// record id (renames and section labels), else the record's name or "Room n".
    static func roomTitles(_ package: ProjectPackage, rooms: [RoomRecord]) -> [String] {
        let model = (try? CleanModelStore.loadEdited(package))?.model
        var byRecord: [UUID: String] = [:]
        if let model {
            let titles = RoomTitles.titles(for: model)
            for room in model.rooms where byRecord[room.recordID] == nil {
                if let title = titles[room.id] { byRecord[room.recordID] = title }
            }
        }
        return rooms.enumerated().map { n, record in
            byRecord[record.id] ?? RoomTitles.title(name: record.name, sectionLabel: nil, index: n)
        }
    }

    // MARK: - Clean USDZ

    /// House: a merged structure (merge.json outcome `merged` over exactly the active rooms,
    /// structure.json present) and no active edit, so RoomPlan's own export shows the house as
    /// the result screen does.
    static func structureExportable(_ package: ProjectPackage, manifest: ProjectManifest, log: EditLog) -> Bool {
        guard manifest.kind == .house, log.active.isEmpty else { return false }
        guard let merge = StructureStore.loadMerge(package), merge.outcome == .merged else { return false }
        let active = Set(StructureEligibility.activeRooms(manifest).map { $0.id })
        guard !active.isEmpty, Set(merge.mergedRooms) == active else { return false }
        return FileManager.default.fileExists(atPath: package.capturedStructureURL.path)
    }

    /// Clean USDZ of a House: `CapturedStructure.export(to:metadataURL:modelProvider:exportOptions: [.mesh])`
    /// into `folder` (with a `.plist` metadata URL next to it, never shared) when `structureExportable`,
    /// else nil (the caller writes `USDZWriter` of `ExportAdapters.cleanScene` of the edited model).
    /// A structure that cannot be read, a RoomPlan error or an empty file is logged and gives nil.
    static func structureUSDZ(_ package: ProjectPackage, into folder: URL, fileName: String) throws -> URL? {
        let manifest = try ProjectStore.readManifest(package)
        guard structureExportable(package, manifest: manifest, log: EditStore.load(package)) else { return nil }
        let fm = FileManager.default
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        let metadata = folder.appendingPathComponent(ExportCatalog.stem(of: fileName) + "_metadata.plist", isDirectory: false)
        do {
            guard let structure = try StructureStore.loadStructure(package) else { return nil }
            try structure.export(to: url, metadataURL: metadata, modelProvider: nil, exportOptions: [.mesh])
            guard ExportRunner.fileSize(url) > 0 else {
                LogStore.shared.write("export: RoomPlan wrote an empty house file, using our writer", category: ExportRunner.logCategory)
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: metadata)
                return nil
            }
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
            return url
        } catch {
            LogStore.shared.write("export: RoomPlan house export failed (\(ExportRunner.logDescription(error))), using our writer",
                                  category: ExportRunner.logCategory)
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: metadata)
            return nil
        }
    }
}
