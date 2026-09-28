import Foundation
import simd

/// Collects ExportUI self-test results: one line per failing check ("name: detail").
struct ExportUISelfTestLog {
    /// Failing checks.
    private(set) var failures: [String] = []
    /// Number of checks run.
    private(set) var count = 0

    /// Records one check.
    mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        guard !condition else { return }
        let text = detail()
        failures.append(text.isEmpty ? name : "\(name): \(text)")
    }

    /// Records a failure for an unexpected error.
    mutating func fail(_ name: String, _ error: Error) {
        count += 1
        failures.append("\(name): \(ExportRunner.logDescription(error))")
    }
}

/// Hand-made models, meshes and a temporary package for `ExportUISelfTest` (fixed identifiers
/// and dates, no RoomPlan, files only under the temporary directory).
enum ExportUISelfTestFixtures {
    /// Room, wall, opening and object identifiers of the 4 x 5 m demo room.
    static let roomID = id(1)
    static let southWall = id(10), eastWall = id(11), northWall = id(12), westWall = id(13)
    static let door = id(20), window = id(21)
    static let sofa = id(30), sink = id(31), hiddenTable = id(32)
    /// Project identifier of the temporary package.
    static let projectID = uuid(900)
    /// A fixed moment (2026-09-28 12:00:00 UTC) for file names and stamps.
    static let date = Date(timeIntervalSince1970: 1_790_596_800)

    /// A fixed UUID whose last two bytes encode `n`.
    static func uuid(_ n: Int) -> UUID {
        let high = UInt8(truncatingIfNeeded: n >> 8)
        let low = UInt8(truncatingIfNeeded: n)
        return UUID(uuid: (0x45, 0x58, 0x50, 0x55, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
    }

    /// A fixed element identifier.
    static func id(_ n: Int) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A world pose at plan point `p` (box center 0.4 m above the floor), no rotation.
    static func pose(at p: SIMD2<Float>) -> Transform4 {
        let world = PlanAxes.toWorld(p, y: 0.4)
        let matrix = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                             SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(world.x, world.y, world.z, 1)))
        return Transform4(matrix)
    }

    /// A 2.5 m wall from plan point `a` to `b` with the room on its left.
    static func wall(_ wallID: ElementID, from a: SIMD2<Float>, to b: SIMD2<Float>,
                     occluded: [ClosedRange<Float>] = []) -> CleanWall {
        let d = simd_normalize(b - a)
        let left = SIMD2<Float>(-d.y, d.x)
        return CleanWall(id: wallID, start: Vec3(PlanAxes.toWorld(a, y: 0)), end: Vec3(PlanAxes.toWorld(b, y: 0)),
                         height: 2.5, normal: Vec3(PlanAxes.toWorld(left, y: 0)), thickness: 0.115,
                         thicknessSource: .estimated, arc: nil, confidence: .high, completedEdges: 4,
                         occludedSpans: occluded, provenance: .measured)
    }

    /// A 0.8 m tall object box at plan point `p`.
    static func object(_ objectID: ElementID, _ category: ObjectCategory, at p: SIMD2<Float>, width: Float, depth: Float,
                       hidden: Bool = false) -> DetectedObject {
        DetectedObject(id: objectID, category: category, label: "", transform: pose(at: p),
                       dimensions: Vec3(x: width, y: 0.8, z: depth), confidence: .high, isHidden: hidden,
                       provenance: .measured)
    }

    /// The demo room: 4 x 5 m, four walls (the north one with an occluded span), a door, a
    /// window, a sofa (furniture), a sink (fixture) and a hidden table (furniture).
    static func demoModel() -> CleanModel {
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)]
        let walls = [
            wall(southWall, from: corners[0], to: corners[1]),
            wall(eastWall, from: corners[1], to: corners[2]),
            wall(northWall, from: corners[2], to: corners[3], occluded: [1...2]),
            wall(westWall, from: corners[3], to: corners[0])
        ]
        let openings = [
            CleanOpening(id: door, wallID: southWall, kind: .door, offsetAlongWall: 1.0, width: 0.9, sillHeight: 0,
                         headHeight: 2.0, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .estimated),
                         provenance: .measured),
            CleanOpening(id: window, wallID: eastWall, kind: .window, offsetAlongWall: 2.0, width: 1.2, sillHeight: 0.9,
                         headHeight: 2.1, swing: nil, provenance: .measured)
        ]
        let objects = [
            object(sofa, .sofa, at: SIMD2<Float>(2, 4.4), width: 2.0, depth: 0.9),
            object(sink, .sink, at: SIMD2<Float>(3.5, 0.4), width: 0.6, depth: 0.5),
            object(hiddenTable, .table, at: SIMD2<Float>(2, 2.5), width: 1.2, depth: 0.8, hidden: true)
        ]
        let metrics = RoomMetrics(floorArea: 20, perimeter: 18, ceilingHeight: 2.5, ceilingProvenance: .measured,
                                  wallArea: 45, length: 5, width: 4, volume: 50, volumeProvenance: .measured)
        let room = CleanRoom(id: roomID, recordID: roomID.uuid, name: "", sectionLabel: "kitchen", floorIndex: 0,
                             walls: walls, openings: openings,
                             floor: CleanFloor(outline: corners.map { Vec2($0) }, elevation: 0, occludedArea: 1.8,
                                               provenance: .measured),
                             ceiling: CleanCeiling(height: 2.5, provenance: .measured), objects: objects, metrics: metrics)
        return CleanModel(rooms: [room], sourceIsStructure: false, stamp: nil)
    }

    /// The demo room's plan (one level).
    static func demoPlan() -> PlanModel {
        PlanBuilder.build(from: demoModel(), floors: [FloorRecord(id: 0, name: "", elevation: 0)])
    }

    /// Inputs of a fully processed demo project (everything available).
    static func demoInputs() -> ExportInputs {
        var inputs = ExportInputs()
        inputs.hasTexture = true
        inputs.hasKeyframes = true
        inputs.hasClean = true
        inputs.hasPlan = true
        inputs.hasMesh = true
        inputs.hasCapturedRoom = true
        inputs.meshTriangles = 1000
        return inputs
    }

    /// Entity count on a plan layer.
    static func count(_ plan: Plan2D, layer: String) -> Int {
        plan.entities.filter { $0.layer == layer }.count
    }

    // MARK: - Meshes

    /// A flat strip of `quads` unit quads on the floor (2 triangles each), classified as floor.
    static func strip(quads: Int, y: Float = 0) -> MeshWithAttributes {
        var positions: [SIMD3<Float>] = []
        for i in 0...quads {
            positions.append(SIMD3<Float>(Float(i), y, 0))
            positions.append(SIMD3<Float>(Float(i), y, -1))
        }
        var indices: [UInt32] = []
        for i in 0..<quads {
            let a = UInt32(2 * i)
            indices.append(contentsOf: [a, a + 2, a + 1, a + 1, a + 2, a + 3])
        }
        let faces = indices.count / 3
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices),
                                  faceClass: [UInt8](repeating: 2, count: faces))
    }

    /// Consolidation result: measured 8 triangles, view 2, inferred 1, no floaters.
    static func consolidation() -> ConsolidationResult {
        let measured = strip(quads: 4)
        let view = strip(quads: 1)
        let inferredMesh = TriangleMesh(positions: [SIMD3<Float>(0, 0, 2), SIMD3<Float>(1, 0, 2), SIMD3<Float>(0, 0, 1)],
                                        indices: [0, 1, 2])
        let inferred = MeshWithAttributes(mesh: inferredMesh, isInferred: [true])
        let stats = MeshStats(chunkCount: 1, triangleCount: measured.triangleCount, viewTriangleCount: view.triangleCount,
                              inferredTriangleCount: 1, classTriangleCounts: ["2": measured.triangleCount],
                              boundsMin: Vec3(x: 0, y: 0, z: -1), boundsMax: Vec3(x: 4, y: 0, z: 0))
        return ConsolidationResult(measured: measured, inferred: inferred, view: view,
                                   floaters: MeshWithAttributes(mesh: TriangleMesh()), stats: stats)
    }

    /// A 2-face textured quad on page 0 whose page file is `pageURL`.
    static func texturedQuad(pageURL: URL) -> TexturedMesh {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)]
        let texcoords = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1),
                         SIMD2<Float>(0, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)]
        return TexturedMesh(positions: positions, indices: [0, 1, 2, 0, 2, 3], texcoords: texcoords, faceAtlas: [0, 0],
                            pageURLs: [pageURL], coverage: 1)
    }

    /// The smallest JPEG-looking bytes (start and end markers); the writers never decode them.
    static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

    // MARK: - Temporary package

    /// A fresh folder for this self-test under the temporary directory.
    static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportUISelfTest-\(uuid(901).uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A package named "3rd floor" in `folder` with a manifest (one room), clean.json, plan.json
    /// and the consolidated mesh of `consolidation()`.
    static func makePackage(in folder: URL) throws -> (package: ProjectPackage, manifest: ProjectManifest) {
        let root = folder.appendingPathComponent("\(projectID.uuidString).\(ProjectPackage.fileExtension)", isDirectory: true)
        let package = ProjectPackage(root: root)
        for url in [package.rawURL, package.derivedURL, package.editsURL, package.exportsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var manifest = ProjectManifest.new(kind: .room, name: "3rd floor", now: date)
        manifest.id = projectID
        let session = uuid(902)
        manifest.rooms = [RoomRecord(id: roomID.uuid, name: "", sessionID: session, floorIndex: 0, status: .processed,
                                     capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 0,
                                     capturedAt: date, frameLink: .projectFrame(sessionID: session))]
        try ProjectStore.writeManifest(manifest, to: package)
        try CleanModelStore.save(demoModel(), to: package)
        try PlanModelStore.save(demoPlan(), to: package)
        try MeshModelStore.save(consolidation(), package: package, room: roomID.uuid)
        return (package, manifest)
    }
}
