import Foundation
import simd

// Disk reads and viewer part building of the object result (docs/MODULES.md 3.42), all
// nonisolated so they run off main in `Task.detached`.

/// What the object result screen read from disk for its project. Built off main by
/// `ObjectResultModel.readSnapshot(projectID:)`.
struct ObjectResultSnapshot: Sendable {
    /// The project's package, when it could be located.
    var package: ProjectPackage?
    /// The manifest, when it could be read.
    var manifest: ProjectManifest?
    /// The project's object (the first ObjectRecord; build 5 saves one per project).
    var record: ObjectRecord?
    /// What exists on disk.
    var files = ObjectResultFiles()
    /// dims.json.
    var dimensions: ObjectDimensionsRecord?
    /// reconstruction.json (small and medium).
    var info: PhotogrammetryInfo?
    /// The Object Capture model, when present.
    var modelURL: URL?
    /// Identifies the viewer content, so the viewer reloads only when the files changed.
    var contentKey = ""

    /// Nothing read yet.
    init() {}
}

/// Viewer content built off main from the object's files.
struct ObjectViewerBuild: Sendable {
    /// The untextured part, the box and (large objects) the textured parts.
    var content: ViewerContent
    /// mesh.mchk's geometry, the Object Capture model's pick mesh.
    var pickMesh: TriangleMesh?
    /// Textured parts added (large objects).
    var texturedPartCount: Int
    /// Problems for the log.
    var problems: [String]
}

extension ObjectResultModel {
    /// Reads the manifest, the object's files, dims.json and reconstruction.json. A missing
    /// project or a project without an object gives `files.hasObject == false` (logged).
    nonisolated static func readSnapshot(projectID: UUID) -> ObjectResultSnapshot {
        var snap = ObjectResultSnapshot()
        do {
            let package = try ProjectStore.package(for: projectID)
            snap.package = package
            snap.manifest = try ProjectStore.readManifest(package)
        } catch {
            ObjectPresentation.log("result \(projectID): project unreadable (\(StoreFiles.describe(error)))")
            snap.files.hasObject = false
            return snap
        }
        guard let package = snap.package, let manifest = snap.manifest, let record = manifest.objects.first else {
            snap.files.hasObject = false
            return snap
        }
        if manifest.objects.count > 1 {
            ObjectPresentation.log("result \(projectID): \(manifest.objects.count) objects, showing the first")
        }
        snap.record = record
        let objectID = record.id
        var files = ObjectResultFiles()
        files.size = record.size
        let model = record.size == .smallMedium ? PhotogrammetryStore.modelURLIfPresent(package, object: objectID) : nil
        files.hasModel = model != nil
        files.hasMesh = FileManager.default.fileExists(atPath: ObjectModelStore.meshURL(package, object: objectID).path)
        let dimensions = ObjectModelStore.loadDimensions(package, object: objectID)
        files.hasDimensions = dimensions != nil
        files.hasTexture = record.size == .large && TextureStore.exists(package, room: objectID)
        snap.files = files
        snap.modelURL = model
        snap.dimensions = dimensions
        snap.info = record.size == .smallMedium ? PhotogrammetryStore.loadInfo(package, object: objectID) : nil
        snap.contentKey = contentKey(files: files, dimensions: dimensions)
        return snap
    }

    /// Changes whenever the model, the mesh, the texture or dims.json changed.
    nonisolated static func contentKey(files: ObjectResultFiles, dimensions: ObjectDimensionsRecord?) -> String {
        let dims = dimensions.map { "\($0.inputHash)@\($0.measuredAt.timeIntervalSince1970)" } ?? "-"
        return "model \(files.hasModel), mesh \(files.hasMesh), texture \(files.hasTexture), dims \(dims)"
    }

    /// The untextured part (mesh.mchk), the box (dims.json) and, for a large object with a
    /// texture, its textured page parts inside the box. Problems are returned for the log.
    nonisolated static func buildContent(package: ProjectPackage, objectID: UUID, dimensions: ObjectDimensionsRecord?,
                                         largeTexture: Bool) -> ObjectViewerBuild {
        var parts: [ViewerPart] = []
        var pickMesh: TriangleMesh?
        var problems: [String] = []
        var texturedCount = 0
        do {
            if let mesh = try ObjectModelStore.loadMesh(package, object: objectID), mesh.triangleCount > 0 {
                parts.append(ObjectPresentation.untexturedPart(mesh))
                pickMesh = mesh.mesh
            }
        } catch {
            problems.append("mesh.mchk unreadable: \(error)")
        }
        let box = dimensions?.box.orientedBox
        if let box {
            parts.append(contentsOf: ObjectPresentation.boxParts(box))
        }
        if largeTexture, let box {
            do {
                if let textured = try TextureStore.load(package, room: objectID) {
                    let kept = ObjectPresentation.texturedParts(textured.pageParts(), inside: box)
                    for part in kept where part.page >= 0 && part.page < textured.pageURLs.count {
                        parts.append(ViewerContentBuilder.texturedPart(id: "object.texture.\(part.page)",
                                                                       positions: part.positions, indices: part.indices,
                                                                       cornerUVs: part.texcoords,
                                                                       textureURL: textured.pageURLs[part.page],
                                                                       layer: .realistic, pickTag: .rawMesh))
                        texturedCount += 1
                    }
                }
            } catch {
                problems.append("texture unreadable: \(error)")
            }
        }
        return ObjectViewerBuild(content: ViewerContent(parts: parts), pickMesh: pickMesh,
                                 texturedPartCount: texturedCount, problems: problems)
    }

    /// Log name of an availability case.
    nonisolated static func kindName(_ availability: ObjectResultAvailability) -> String {
        switch availability {
        case .processing: return "processing"
        case .ready: return "ready"
        case .failed: return "failed"
        case .noObject: return "noObject"
        }
    }
}
