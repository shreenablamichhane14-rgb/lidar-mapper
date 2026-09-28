import Foundation
import simd

/// Files of a room's consolidated mesh under `derived/rooms/<r>/` (MODULES.md 3.1) and the
/// conversion between world meshes and Core's `.mchk` chunk record. Derived chunks use an
/// identity transform and the room id as anchor id; the format has no inferred flag, so the
/// inferred faces live only in `mesh_inferred.mchk`. Thread-safe (stateless, file IO only).
enum MeshModelStore {
    /// Measured mesh file name.
    static let measuredFileName = "mesh.mchk"
    /// Inferred (hole fill) mesh file name.
    static let inferredFileName = "mesh_inferred.mchk"
    /// View mesh file name.
    static let viewFileName = "mesh_view.mchk"
    /// Floaters mesh file name.
    static let floatersFileName = "mesh_floaters.mchk"
    /// Stats file name.
    static let statsFileName = "mesh_stats.json"
    /// Derived mesh files larger than this are refused (`CoreError.fileTooLarge`): a 1M face
    /// mesh is about 40 MB, and the cap protects against a damaged or planted file.
    static let maxMeshFileBytes: Int64 = 512 * 1024 * 1024
    /// `mesh_stats.json` larger than this is ignored.
    static let maxStatsBytes: Int64 = 1024 * 1024

    // MARK: - Paths

    /// `derived/rooms/<r>/mesh.mchk`.
    static func measuredURL(_ package: ProjectPackage, room: UUID) -> URL {
        file(package, room: room, name: measuredFileName)
    }

    /// `derived/rooms/<r>/mesh_inferred.mchk`.
    static func inferredURL(_ package: ProjectPackage, room: UUID) -> URL {
        file(package, room: room, name: inferredFileName)
    }

    /// `derived/rooms/<r>/mesh_view.mchk`.
    static func viewURL(_ package: ProjectPackage, room: UUID) -> URL {
        file(package, room: room, name: viewFileName)
    }

    /// `derived/rooms/<r>/mesh_floaters.mchk`.
    static func floatersURL(_ package: ProjectPackage, room: UUID) -> URL {
        file(package, room: room, name: floatersFileName)
    }

    /// `derived/rooms/<r>/mesh_stats.json`.
    static func statsURL(_ package: ProjectPackage, room: UUID) -> URL {
        file(package, room: room, name: statsFileName)
    }

    /// A file inside the room's derived folder.
    private static func file(_ package: ProjectPackage, room: UUID, name: String) -> URL {
        package.derivedRoomURL(room).appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Save and load

    /// Writes all five files atomically with `ProjectStore.writeData(createParents: false)`:
    /// measured, inferred, view, floaters (empty meshes are written too, so no stale file of an
    /// earlier run survives), then the stats. The room folder is created only while the package
    /// exists (`ProjectStore.ensureDirectory(_:inside:)`), so a late save after a delete throws.
    static func save(_ result: ConsolidationResult, package: ProjectPackage, room: UUID) throws {
        try ProjectStore.ensureDirectory(package.derivedRoomURL(room), inside: package.root)
        try write(result.measured, to: measuredURL(package, room: room), id: room)
        try write(result.inferred, to: inferredURL(package, room: room), id: room)
        try write(result.view, to: viewURL(package, room: room), id: room)
        try write(result.floaters, to: floatersURL(package, room: room), id: room)
        let stats = try ProjectStore.encoder.encode(result.stats)
        try ProjectStore.writeData(stats, to: statsURL(package, room: room), createParents: false)
    }

    /// The measured mesh, nil when the file does not exist; throws on a corrupt or oversized
    /// file. `isInferred` is nil.
    static func loadMeasured(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes? {
        try load(measuredURL(package, room: room))
    }

    /// The hole-fill faces with `isInferred` all true, nil when the file does not exist.
    static func loadInferred(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes? {
        guard var mesh = try load(inferredURL(package, room: room)) else { return nil }
        mesh.isInferred = [Bool](repeating: true, count: mesh.triangleCount)
        return mesh
    }

    /// Measured faces only: the result has `isInferred == nil` (the chunk format has no inferred
    /// flag); draw `loadInferred` next to it for the Inferred color.
    static func loadView(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes? {
        try load(viewURL(package, room: room))
    }

    /// The islands cleanup removed (Raw Scan only), nil when the file does not exist.
    static func loadFloaters(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes? {
        try load(floatersURL(package, room: room))
    }

    /// The stats, or nil when absent or unreadable (unreadable is logged).
    static func loadStats(_ package: ProjectPackage, room: UUID) -> MeshStats? {
        let url = statsURL(package, room: room)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(MeshStats.self, from: url, maxBytes: maxStatsBytes)
        } catch {
            LogStore.shared.write("mesh stats unreadable for room \(room.uuidString): \(error)",
                                  category: MeshConsolidator.logCategory)
            return nil
        }
    }

    // MARK: - Conversion

    /// World mesh <-> Core MeshChunk (identity transform, anchorID = room id, classes, normals).
    /// Normals are area-weighted vertex normals (`MeshCleanup.normals`); classes are stored
    /// only when there is one per face. Faces with an out-of-range index are dropped first.
    static func chunk(from mesh: MeshWithAttributes, id: UUID) -> MeshChunk {
        let source = mesh.isConsistent ? mesh : mesh.keepingFaces([Bool](repeating: true, count: mesh.triangleCount))
        let faces = source.triangleCount
        let indices = Array(source.mesh.indices.prefix(3 * faces))
        var classes: [UInt8] = []
        if let faceClass = source.faceClass, faceClass.count == faces { classes = faceClass }
        return MeshChunk(anchorID: id, transform: matrix_identity_float4x4, updateCount: 0,
                         positions: source.mesh.positions, normals: MeshCleanup.normals(source.mesh),
                         indices: indices, classes: classes)
    }

    /// Core MeshChunk -> world mesh: positions through the chunk transform (skipped for the
    /// identity transform of derived files), classes when there is one per face, no vertex
    /// colors and no inferred flags.
    static func mesh(from chunk: MeshChunk) -> MeshWithAttributes {
        let isIdentity = Transform4(chunk.transform) == Transform4.identity
        let triangles = chunk.toTriangleMesh(world: !isIdentity)
        let hasClasses = !chunk.classes.isEmpty && chunk.classes.count == chunk.faceCount
        return MeshWithAttributes(mesh: triangles, faceClass: hasClasses ? chunk.classes : nil)
    }

    // MARK: - File helpers

    /// Encodes and atomically writes one mesh; the parent folder must exist.
    private static func write(_ mesh: MeshWithAttributes, to url: URL, id: UUID) throws {
        let data = MeshChunkFile.encode(chunk(from: mesh, id: id))
        try ProjectStore.writeData(data, to: url, createParents: false)
    }

    /// Reads one derived mesh file: nil when absent, `CoreError.fileTooLarge` above
    /// `maxMeshFileBytes`, `CoreError.corruptFile` when malformed.
    private static func load(_ url: URL) throws -> MeshWithAttributes? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxMeshFileBytes else {
            throw CoreError.fileTooLarge(name: url.lastPathComponent, bytes: size)
        }
        let chunk = try MeshChunkFile.decode(try Data(contentsOf: url))
        return mesh(from: chunk)
    }
}
