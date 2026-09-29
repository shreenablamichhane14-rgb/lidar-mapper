import Foundation

/// What a project has on disk for the export sheet (docs/MODULES.md 3.27 and 3.43d). Reads small
/// files only; any thread, call it off main.
extension ExportCatalog {
    /// The rooms an export may contain: for a House the active rooms (`StructureEligibility
    /// .activeRooms`, CR-7 `supersededBy == nil`), for other kinds every room that was not
    /// superseded (build 4 rooms keep their order and status). A superseded room is never exported.
    static func exportRooms(_ manifest: ProjectManifest) -> [RoomRecord] {
        if manifest.kind == .house { return StructureEligibility.activeRooms(manifest) }
        return manifest.rooms.filter { $0.supersededBy == nil }
    }

    /// What a project has on disk: kind, texture, keyframes, clean model with rooms, plan levels
    /// with content, consolidated meshes, final CapturedRoom, active edits, the largest measured
    /// triangle count, and for build 5 kinds the House structure and textures, the object model
    /// and dimensions, and the saved measurement count. Decodes clean.json and plan.json.
    static func inputs(package: ProjectPackage, manifest: ProjectManifest) -> ExportInputs {
        let fm = FileManager.default
        var result = ExportInputs()
        result.kind = manifest.kind
        result.isProcessing = manifest.status == .processing || manifest.status == .needsProcessing
        let rooms = exportRooms(manifest)
        let placed = placedRoomIDs(package, manifest: manifest)
        var texturedCount = 0
        for room in rooms {
            if TextureStore.exists(package, room: room.id) {
                result.hasTexture = true
                texturedCount += 1
            }
            if room.keyframeCount > 0 { result.hasKeyframes = true }
            if fm.fileExists(atPath: MeshModelStore.measuredURL(package, room: room.id).path) {
                result.hasMesh = true
                let triangles = MeshModelStore.loadStats(package, room: room.id)?.triangleCount ?? 0
                result.meshTriangles = Swift.max(result.meshTriangles, triangles)
                if placed.contains(room.id) { result.roomTriangles.append(triangles) }
            }
            if CapturedRoomStore.hasFinalRoom(package, room: room) { result.hasCapturedRoom = true }
        }
        result.allRoomsTextured = !rooms.isEmpty && texturedCount == rooms.count
        if fm.fileExists(atPath: package.cleanModelURL.path) {
            result.hasClean = ((try? CleanModelStore.loadBase(package))?.rooms.isEmpty == false)
        }
        if fm.fileExists(atPath: package.planModelURL.path), let plan = try? PlanModelStore.loadBase(package) {
            let levels = plan.levels.filter { !$0.rooms.isEmpty || !$0.walls.isEmpty }
            result.hasPlan = !levels.isEmpty
            result.levelCount = levels.count
        }
        let log = EditStore.load(package)
        result.hasEdits = !log.active.isEmpty
        if manifest.kind == .house {
            result.structureExportable = ExportHouse.structureExportable(package, manifest: manifest, log: log)
        }
        if let object = ExportObject.firstObject(manifest) {
            result.hasObjectModel = ExportObject.hasModel(package, object: object)
            result.hasObjectDimensions = ObjectModelStore.loadDimensions(package, object: object.id) != nil
        }
        result.measurementCount = ExportObject.effectiveMeasurements(package).count
        return result
    }

    /// Rooms a House export can place (`StructureStore.placementMatrices` of the effective
    /// alignments); every export room for other kinds.
    private static func placedRoomIDs(_ package: ProjectPackage, manifest: ProjectManifest) -> Set<UUID> {
        guard manifest.kind == .house else { return Set(exportRooms(manifest).map { $0.id }) }
        let matrices = StructureStore.placementMatrices(manifest: manifest,
                                                        alignments: StructureStore.effectiveAlignments(package))
        return Set(matrices.keys)
    }

    /// `inputs(package:manifest:)` of a project id, nil when the project cannot be read. Any
    /// thread; call it off main.
    static func loadInputs(projectID: UUID) -> ExportInputs? {
        do {
            let package = try ProjectStore.package(for: projectID)
            let manifest = try ProjectStore.readManifest(package)
            return inputs(package: package, manifest: manifest)
        } catch {
            LogStore.shared.write("export: project \(projectID.uuidString) unreadable (\(ExportRunner.logDescription(error)))",
                                  category: ExportRunner.logCategory)
            return nil
        }
    }
}
