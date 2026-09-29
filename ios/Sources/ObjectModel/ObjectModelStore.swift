import Foundation
import simd

/// Files of one object under `derived/objects/<id>/` (MODULES.md 3.1): `dims.json`
/// (`ObjectDimensionsRecord`) and `mesh.mchk` (the untextured object mesh as a Core chunk with an
/// identity transform and the object id as anchor id), plus the crop edit of large objects.
/// Folders are created only while the package exists (`ensureDirectory(_:inside:)`) and every
/// write is atomic with `createParents: false`, so a late write after a delete throws instead of
/// recreating the project. Stateless and safe on any thread.
enum ObjectModelStore {
    /// Measurements file name.
    static let dimensionsFileName = "dims.json"
    /// Untextured mesh file name.
    static let meshFileName = "mesh.mchk"
    /// `dims.json` larger than this is refused, bytes.
    static let maxDimensionsBytes: Int64 = 1024 * 1024
    /// `mesh.mchk` larger than this is refused (`CoreError.fileTooLarge`), bytes. An Object
    /// Capture model is under 50k triangles (about 2 MB); a large object is a crop of one room.
    static let maxMeshFileBytes: Int64 = 256 * 1024 * 1024

    // MARK: - Paths

    /// `derived/objects/<id>/dims.json`.
    static func dimensionsURL(_ package: ProjectPackage, object: UUID) -> URL {
        package.derivedObjectURL(object).appendingPathComponent(dimensionsFileName, isDirectory: false)
    }

    /// `derived/objects/<id>/mesh.mchk`.
    static func meshURL(_ package: ProjectPackage, object: UUID) -> URL {
        package.derivedObjectURL(object).appendingPathComponent(meshFileName, isDirectory: false)
    }

    // MARK: - Measurements

    /// The saved measurements; nil when absent, unreadable or written for another object (the
    /// last two are logged).
    static func loadDimensions(_ package: ProjectPackage, object: UUID) -> ObjectDimensionsRecord? {
        let url = dimensionsURL(package, object: object)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let record = try ProjectStore.readJSON(ObjectDimensionsRecord.self, from: url, maxBytes: maxDimensionsBytes)
            guard record.objectID == object else {
                LogStore.shared.write("dims.json of object \(object.uuidString) names object \(record.objectID.uuidString); ignored",
                                      category: ObjectModelLoader.logCategory)
                return nil
            }
            return record
        } catch {
            LogStore.shared.write("dims.json of object \(object.uuidString) unreadable: \(error)",
                                  category: ObjectModelLoader.logCategory)
            return nil
        }
    }

    /// Writes `dims.json` of `record.objectID` atomically (folder created only inside an
    /// existing package).
    static func saveDimensions(_ record: ObjectDimensionsRecord, to package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedObjectURL(record.objectID), inside: package.root)
        try ProjectStore.writeJSON(record, to: dimensionsURL(package, object: record.objectID), createParents: false)
    }

    // MARK: - Mesh

    /// The untextured object mesh (MeshModel `MeshModelStore.mesh(from:)` of the decoded chunk);
    /// nil when the file does not exist; throws `CoreError.fileTooLarge` above
    /// `maxMeshFileBytes` and `CoreError.corruptFile` for a malformed file.
    static func loadMesh(_ package: ProjectPackage, object: UUID) throws -> MeshWithAttributes? {
        let url = meshURL(package, object: object)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxMeshFileBytes else {
            throw CoreError.fileTooLarge(name: url.lastPathComponent, bytes: size)
        }
        let chunk = try MeshChunkFile.decode(try Data(contentsOf: url))
        return MeshModelStore.mesh(from: chunk)
    }

    /// `MeshModelStore.chunk(from:id:)` then Core `MeshChunkFile.encode`, written atomically.
    static func saveMesh(_ mesh: MeshWithAttributes, package: ProjectPackage, object: UUID) throws {
        try ProjectStore.ensureDirectory(package.derivedObjectURL(object), inside: package.root)
        let data = MeshChunkFile.encode(MeshModelStore.chunk(from: mesh, id: object))
        try ProjectStore.writeData(data, to: meshURL(package, object: object), createParents: false)
    }

    // MARK: - Crop edit

    /// The box record of the last `cropObject(object:box:)` in `log.flattenedActive` (CR-1)
    /// whose `object.uuid == objectID`; nil when there is none. Undone operations (the redo
    /// tail) are not active, and a crop inside a `batch` counts.
    static func cropRecord(for objectID: UUID, in log: EditLog) -> OrientedBoxRecord? {
        for op in log.flattenedActive.reversed() {
            if case .cropObject(let object, let box) = op, object.uuid == objectID {
                return box
            }
        }
        return nil
    }

    /// The box of the last `cropObject(object:box:)` in `log.flattenedActive` (CR-1) whose `object.uuid == objectID`
    /// (`OrientedBoxRecord.orientedBox`); LargeObject writes it, ObjectCrop edits it in build 6.
    static func cropBox(for objectID: UUID, in log: EditLog) -> OrientedBox? {
        cropRecord(for: objectID, in: log)?.orientedBox
    }

    /// Stable text of that edit for input hashes ("-" when none): the 15 floats of the box
    /// record as exact bit patterns, so any change of the crop changes the text.
    static func cropDigest(for objectID: UUID, in log: EditLog) -> String {
        guard let box = cropRecord(for: objectID, in: log) else { return "-" }
        let vectors: [Vec3] = [box.center, box.axisX, box.axisY, box.axisZ, box.halfExtents]
        var parts: [String] = []
        parts.reserveCapacity(15)
        for v in vectors {
            parts.append(String(v.x.bitPattern, radix: 16))
            parts.append(String(v.y.bitPattern, radix: 16))
            parts.append(String(v.z.bitPattern, radix: 16))
        }
        return "crop:" + parts.joined(separator: ",")
    }
}
