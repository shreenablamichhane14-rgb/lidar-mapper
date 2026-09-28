import Foundation
import simd
import RoomPlan

/// Adapts Mapper's models to the Export writers' inputs (docs/MODULES.md 3.27): the clean model,
/// the consolidated raw mesh, the textured mesh and the floor plan. Pure functions plus file
/// reads inside the package; nonisolated, call them off main.
enum ExportAdapters {
    /// Metadata every 3D scene carries (writers put it where the format has a place for it).
    static let baseMetadata: [String: String] = ["generator": "Mapper", "units": "meters, +Y up"]

    /// Which consolidated mesh a raw export uses.
    enum RawSource: Equatable, Sendable {
        /// The full measured mesh (`mesh.mchk`).
        case full
        /// The simplified view mesh (`mesh_view.mchk`), for text formats above the limit.
        case view
    }

    /// Material name, mesh name prefix and color of a clean part kind.
    struct CleanStyle: Equatable {
        /// Material name (one material per kind; objects one per category).
        var material: String
        /// Mesh name prefix ("wall", "door", "furniture_sofa", "fixture_sink").
        var prefix: String
        /// RGBA base color in 0...1.
        var color: SIMD4<Float>
    }

    // MARK: - Clean model

    /// CleanMeshBuilder parts, one material per kind. `includeMovable` false (Hide Furniture on
    /// the result screen) drops movable objects unless `includeHidden` asks for hidden ones;
    /// occluded parts are never exported as surfaces, open passages stay open and the ceiling is
    /// left out (as on the result screen). Each part becomes its own flat-shaded mesh.
    static func cleanScene(_ model: CleanModel, includeHidden: Bool, includeMovable: Bool) -> ExportScene {
        let parts = CleanMeshBuilder.parts(for: model, includeCeiling: false, includeHidden: includeHidden)
        var materials: [ExportMaterial] = []
        var materialSlots: [String: Int] = [:]
        var meshes: [ExportMesh] = []
        var counters: [String: Int] = [:]
        for part in parts {
            guard let style = cleanStyle(part.kind, isMovable: part.isMovable) else { continue }
            if part.isMovable && !includeMovable && !includeHidden { continue }
            guard part.mesh.triangleCount > 0 else { continue }
            let slot: Int
            if let existing = materialSlots[style.material] {
                slot = existing
            } else {
                slot = materials.count
                materialSlots[style.material] = slot
                materials.append(ExportMaterial(name: style.material, baseColor: style.color))
            }
            let number = (counters[style.prefix] ?? 0) + 1
            counters[style.prefix] = number
            var mesh = flatMesh(part.mesh, name: "\(style.prefix)_\(number)")
            mesh.materialIndex = slot
            if mesh.triangleCount > 0 { meshes.append(mesh) }
        }
        return ExportScene(meshes: meshes, materials: materials, metadata: baseMetadata)
    }

    /// Style of a clean part kind; nil for kinds that are never exported as surfaces
    /// (occluded regions, open passages).
    static func cleanStyle(_ kind: CleanPartKind, isMovable: Bool) -> CleanStyle? {
        switch kind {
        case .wall: return CleanStyle(material: "wall", prefix: "wall", color: SIMD4<Float>(0.93, 0.93, 0.91, 1))
        case .floor: return CleanStyle(material: "floor", prefix: "floor", color: SIMD4<Float>(0.80, 0.76, 0.70, 1))
        case .ceiling: return CleanStyle(material: "ceiling", prefix: "ceiling", color: SIMD4<Float>(0.97, 0.97, 0.97, 1))
        case .door: return CleanStyle(material: "door", prefix: "door", color: SIMD4<Float>(0.55, 0.40, 0.28, 1))
        case .window: return CleanStyle(material: "window", prefix: "window", color: SIMD4<Float>(0.62, 0.80, 0.95, 0.5))
        case .opening, .occluded: return nil
        case .object(let category):
            let group = isMovable ? "furniture" : "fixture"
            let color = isMovable ? SIMD4<Float>(0.72, 0.60, 0.48, 1) : SIMD4<Float>(0.55, 0.70, 0.66, 1)
            let name = "\(group)_\(category.rawValue)"
            return CleanStyle(material: name, prefix: name, color: color)
        }
    }

    /// An un-indexed copy of `mesh` (3 vertices per face) with face normals, so boxes and
    /// wall strips shade flat in every viewer. Faces with an out-of-range index are dropped.
    static func flatMesh(_ mesh: TriangleMesh, name: String) -> ExportMesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(3 * mesh.triangleCount)
        normals.reserveCapacity(3 * mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            guard let corners = mesh.triangle(t) else { continue }
            let normal = faceNormal(corners.0, corners.1, corners.2)
            positions.append(contentsOf: [corners.0, corners.1, corners.2])
            normals.append(contentsOf: [normal, normal, normal])
        }
        let indices = (0..<positions.count).map { UInt32(truncatingIfNeeded: $0) }
        return ExportMesh(name: name, positions: positions, normals: normals, indices: indices)
    }

    /// Unit normal of a counter-clockwise triangle; +Y for degenerate or non-finite triangles.
    static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let edge1: SIMD3<Float> = b - a
        let edge2: SIMD3<Float> = c - a
        let cross: SIMD3<Float> = simd_cross(edge1, edge2)
        let length = simd_length(cross)
        guard length.isFinite, length > 1e-12 else { return SIMD3<Float>(0, 1, 0) }
        return cross / length
    }

    // MARK: - Raw scan

    /// Full or view mesh for a measured triangle count: the view mesh only above the limit.
    static func rawSource(measuredTriangles: Int, maxTextTriangles: Int) -> RawSource {
        measuredTriangles > maxTextTriangles ? .view : .full
    }

    /// The room's consolidated scan with class colors: the full measured mesh up to
    /// `maxTextTriangles`, else the simplified view mesh; the inferred hole fills always follow
    /// as their own mesh (the Inferred distinction survives). The simplified variant carries
    /// Copy.ExportUI.simplifiedNote in its metadata. Throws `CoreError.missingFile` when the room
    /// has no consolidated mesh.
    static func rawScene(_ package: ProjectPackage, room: UUID, maxTextTriangles: Int) throws -> ExportScene {
        var source = RawSource.full
        var measured: MeshWithAttributes?
        if let stats = MeshModelStore.loadStats(package, room: room) {
            source = rawSource(measuredTriangles: stats.triangleCount, maxTextTriangles: maxTextTriangles)
        }
        if source == .full {
            measured = try MeshModelStore.loadMeasured(package, room: room)
            if let mesh = measured {
                source = rawSource(measuredTriangles: mesh.triangleCount, maxTextTriangles: maxTextTriangles)
            }
        }
        var body: MeshWithAttributes?
        switch source {
        case .full:
            body = measured
        case .view:
            measured = nil
            body = try MeshModelStore.loadView(package, room: room)
            if body == nil {
                LogStore.shared.write("export: room \(room.uuidString) has no view mesh, using the measured mesh",
                                      category: ExportRunner.logCategory)
                body = try MeshModelStore.loadMeasured(package, room: room)
            }
        }
        guard let mesh = body else { throw CoreError.missingFile(MeshModelStore.measuredFileName) }
        let inferred = try MeshModelStore.loadInferred(package, room: room)
        var scene = MeshExportAdapter.scene(measured: mesh, inferred: inferred, colorByClass: true)
        for (key, value) in baseMetadata { scene.metadata[key] = value }
        if source == .view { scene.metadata["note"] = Copy.ExportUI.simplifiedNote }
        return scene
    }

    // MARK: - Realistic

    /// pageParts, ExportMaterial(textureJPEG:) per page; texture coordinates stay bottom-left.
    static func texturedScene(_ mesh: TexturedMesh) throws -> ExportScene {
        try texturedScene(mesh, includeTextures: true)
    }

    /// As `texturedScene(_:)`; with `includeTextures` false the page images are left out and the
    /// materials are plain white (Include textures off). Throws when a page image cannot be read
    /// and `ExportError.emptyScene` when no face is textured.
    static func texturedScene(_ mesh: TexturedMesh, includeTextures: Bool) throws -> ExportScene {
        var meshes: [ExportMesh] = []
        var materials: [ExportMaterial] = []
        for part in mesh.pageParts() {
            guard part.page >= 0, part.page < mesh.pageURLs.count, !part.positions.isEmpty else { continue }
            let name = "page_\(part.page)"
            var jpeg: Data?
            if includeTextures {
                jpeg = try Data(contentsOf: mesh.pageURLs[part.page])
            }
            let slot = materials.count
            materials.append(ExportMaterial(name: name, textureJPEG: jpeg, textureName: includeTextures ? "\(name).jpg" : ""))
            var normals: [SIMD3<Float>] = []
            normals.reserveCapacity(part.positions.count)
            var corner = 0
            while corner + 2 < part.positions.count {
                let n = faceNormal(part.positions[corner], part.positions[corner + 1], part.positions[corner + 2])
                normals.append(contentsOf: [n, n, n])
                corner += 3
            }
            while normals.count < part.positions.count { normals.append(SIMD3<Float>(0, 1, 0)) }
            meshes.append(ExportMesh(name: "textured_\(name)", positions: part.positions, normals: normals,
                                     texcoords: part.texcoords, indices: part.indices, materialIndex: slot))
        }
        guard !meshes.isEmpty else { throw ExportError.emptyScene }
        var metadata = baseMetadata
        metadata["textureCoverage"] = ExportText.number(Double(mesh.coverage), places: 3)
        return ExportScene(meshes: meshes, materials: materials, metadata: metadata)
    }

    // MARK: - Several rooms

    /// One scene from several (one per room): meshes in order with "_room<n>" appended to their
    /// names when there is more than one scene, material indices shifted, metadata of the first
    /// scene first.
    static func merged(_ scenes: [ExportScene]) -> ExportScene {
        guard scenes.count > 1 else { return scenes.first ?? ExportScene(meshes: []) }
        var result = ExportScene(meshes: [], materials: [], metadata: [:])
        for (n, scene) in scenes.enumerated() {
            let offset = result.materials.count
            for material in scene.materials {
                var copy = material
                copy.name = "\(material.name)_room\(n + 1)"
                if !copy.textureName.isEmpty { copy.textureName = "room\(n + 1)_\(material.textureName)" }
                result.materials.append(copy)
            }
            for mesh in scene.meshes {
                var copy = mesh
                copy.name = "\(mesh.name)_room\(n + 1)"
                copy.materialIndex = mesh.materialIndex.map { $0 + offset }
                result.meshes.append(copy)
            }
            for (key, value) in scene.metadata where result.metadata[key] == nil {
                result.metadata[key] = value
            }
        }
        return result
    }

    // MARK: - Floor plan

    /// `PlanDrawing.make` with the result screen's toggles (TEST_PLAN EXP-05: every visible layer,
    /// no hidden one) for level 0 (or the first level) of the edited plan.
    static func planDrawing(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles) throws -> Plan2D {
        try planExport(package, prefs: prefs, toggles: toggles, includeHidden: false).plan
    }

    /// The edited plan's drawing and its north angle (PlanModel convention). `includeHidden`
    /// draws fixtures the user hid. Throws `CoreError.missingFile` without plan.json and
    /// `ExportError.emptyPlan` when the plan has no level.
    static func planExport(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles,
                           includeHidden: Bool) throws -> (plan: Plan2D, northAngle: Float) {
        let plan = try PlanModelStore.loadEdited(package).plan
        let clean = try? CleanModelStore.loadBase(package)
        let name = (try? ProjectStore.readManifest(package))?.name ?? ""
        let drawing = try planDrawing(plan: plan, clean: clean, name: name, prefs: prefs, toggles: toggles,
                                      includeHidden: includeHidden)
        return (drawing, plan.northAngle)
    }

    /// Pure form of the plan drawing: level 0 (or the first level), titles from `RoomTitles`.
    static func planDrawing(plan: PlanModel, clean: CleanModel?, name: String, prefs: UnitPreferences,
                            toggles: PlanToggles, includeHidden: Bool) throws -> Plan2D {
        guard var level = plan.levels.first(where: { $0.id == 0 }) ?? plan.levels.first else {
            throw ExportError.emptyPlan
        }
        if includeHidden {
            level.fixtures = level.fixtures.map { fixture in
                var copy = fixture
                copy.isHidden = false
                return copy
            }
        }
        let titles = RoomTitles.titles(for: plan, clean: clean)
        return PlanDrawing.make(level: level, toggles: toggles, prefs: prefs, roomTitles: titles, name: name).plan
    }

    /// The plan toggles an export draws with: the result screen's toggles with Hide Furniture
    /// applied (unless Include hidden objects is on), and dimensions off when Include
    /// measurements is off.
    static func planToggles(viewState: ExportViewState, settings: ExportSettings) -> PlanToggles {
        var toggles = settings.includeHidden ? viewState.planToggles : viewState.effectivePlanToggles
        if !settings.includeMeasurements { toggles.measurements = false }
        return toggles
    }

    /// The unit preferences of plan labels: the app's, with the system overridden when asked.
    static func planPrefs(_ prefs: UnitPreferences, settings: ExportSettings) -> UnitPreferences {
        var result = prefs
        if let system = settings.unitsOverride { result.system = system }
        return result
    }

    // MARK: - RoomPlan USDZ

    /// Writes RoomPlan's own USDZ of a room (walls with door and window cutouts, RESEARCH 3.2
    /// recommended 9) with `export(to:metadataURL:modelProvider:exportOptions: [.mesh])` and the
    /// `.plist` metadata next to it. False (logged) when the room has no final CapturedRoom (a
    /// provisional live file does not count), RoomPlan throws or writes nothing; the caller then
    /// falls back to `USDZWriter` with `cleanScene`.
    static func writeRoomPlanUSDZ(_ package: ProjectPackage, room: RoomRecord, to url: URL, metadataURL: URL) -> Bool {
        let fm = FileManager.default
        do {
            let loaded = try CapturedRoomStore.loadWithSource(package, room: room)
            guard loaded.source != .live else {
                LogStore.shared.write("export: room \(room.id.uuidString) has only a provisional room, using our writer",
                                      category: ExportRunner.logCategory)
                return false
            }
            try loaded.room.export(to: url, metadataURL: metadataURL, modelProvider: nil, exportOptions: [.mesh])
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                LogStore.shared.write("export: RoomPlan wrote an empty file, using our writer", category: ExportRunner.logCategory)
                try? fm.removeItem(at: url)
                return false
            }
            return true
        } catch {
            LogStore.shared.write("export: RoomPlan export failed (\(ExportRunner.logDescription(error))), using our writer",
                                  category: ExportRunner.logCategory)
            try? fm.removeItem(at: url)
            return false
        }
    }
}
