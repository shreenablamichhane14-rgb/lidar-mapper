import Foundation
import simd

/// Demo Mode's synthetic object (docs/MODULES.md 3.42): a 0.40 x 0.30 x 0.25 m box with wood
/// colored sides and a blue top and bottom, written as a finished small or medium object so the
/// result screen, measurements and exports work without the camera or Object Capture. The
/// files come from the real writers: `USDZWriter` for the model, ObjectModel's store and
/// `ObjectDimensions.measure` for mesh.mchk and dims.json, `ProjectStore.sealRawFolder` for the
/// raw folder. Stateless; any thread (file IO, so call it off main).
enum ObjectDemo {
    /// Box width (x, the longer horizontal side), height (y, up) and depth (z), meters.
    static let size = SIMD3<Float>(0.40, 0.30, 0.25)
    /// Input hash written into the demo dims.json.
    static let inputHash = "objectui-demo"
    /// Linear RGBA of the four sides (wood) and of the top and bottom (blue).
    static let sideColor = SIMD4<Float>(0.80, 0.52, 0.25, 1)
    static let capColor = SIMD4<Float>(0.20, 0.45, 0.75, 1)
    /// Each box face as a cycle of corner numbers (bit 0 x, bit 1 y, bit 2 z); the winding is
    /// turned outward when the mesh is built.
    static let sideQuads: [[Int]] = [[0, 4, 6, 2], [1, 3, 7, 5], [0, 2, 3, 1], [4, 5, 7, 6]]
    static let capQuads: [[Int]] = [[0, 1, 5, 4], [2, 6, 7, 3]]

    /// A 0.40 x 0.30 x 0.25 m two-color box: raw/objects/<id>/ with a demo objectlog.json
    /// sealed by `ProjectStore.sealRawFolder`, `model.usdz` from `USDZWriter.data(for:)` at
    /// `PhotogrammetryStore.modelURL`, mesh.mchk and dims.json through ObjectModel; returns the
    /// record (status `.processed`, `modelFile` "model.usdz"). The caller sets the project `.ready`.
    /// Folders are created only inside the existing package, so a deleted project throws.
    static func makeDemoObject(package: ProjectPackage, objectID: UUID, now: Date) throws -> ObjectRecord {
        let started = ProcessInfo.processInfo.systemUptime
        try writeRawFolder(package: package, objectID: objectID, now: now)

        let modelData = try USDZWriter.data(for: modelScene(), layerName: "model.usda", modified: now)
        try ProjectStore.ensureDirectory(PhotogrammetryStore.folder(package, object: objectID), inside: package.root)
        try ProjectStore.writeData(modelData, to: PhotogrammetryStore.modelURL(package, object: objectID), createParents: false)

        let mesh = MeshWithAttributes(mesh: weldedMesh())
        guard let record = ObjectDimensions.measure(mesh, objectID: objectID, source: .smallMedium, scaleCorrection: 1,
                                                    inputHash: inputHash, now: now) else {
            throw MapperError.ioFailed("demo object could not be measured")
        }
        try ObjectModelStore.saveMesh(mesh, package: package, object: objectID)
        try ObjectModelStore.saveDimensions(record, to: package)

        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        ObjectPresentation.log("demo object \(objectID): \(mesh.triangleCount) triangles, model \(modelData.count) bytes, "
                               + "\(milliseconds) ms")
        return ObjectRecord(id: objectID, name: "", size: .smallMedium, status: .processed, imageCount: 0,
                            modelFile: PhotogrammetryStore.modelFileName)
    }

    // MARK: - Raw folder

    /// Creates `raw/objects/<id>/` inside the existing package, writes a demo `objectlog.json`
    /// and seals the folder.
    static func writeRawFolder(package: ProjectPackage, objectID: UUID, now: Date) throws {
        let folder = package.rawObjectURL(objectID)
        try ProjectStore.ensureDirectory(folder, inside: package.root)
        let logURL = folder.appendingPathComponent(ObjectCaptureLog.fileName, isDirectory: false)
        try ProjectStore.writeJSON(demoLog(objectID: objectID, now: now), to: logURL, createParents: false)
        try ProjectStore.sealRawFolder(folder, now: now)
    }

    /// A capture log that says what the folder is: no photos, stage "demo", no failure.
    static func demoLog(objectID: UUID, now: Date) -> ObjectCaptureLog {
        let nominal = ThermalLevel.nominal.rawValue
        return ObjectCaptureLog(objectID: objectID, startedAt: now, seconds: 0, shotCount: 0,
                                maximumNumberOfInputImages: 0, photogrammetryMaxImages: 0,
                                photogrammetryMaxImageDimension: 0, passes: 0, flips: 0, feedbackSeconds: [:],
                                trackingLimitedSeconds: 0, detectionFailures: 0, finalStage: "demo", failure: nil,
                                thermalAtStart: nominal, thermalAtEnd: nominal, freeBytesAtStart: 0,
                                availableMemoryAtStart: 0, osVersion: "demo")
    }

    // MARK: - Geometry

    /// The 8 box corners, centered on x and z with the bottom at y = 0: corner i takes the
    /// maximum along x when bit 0 is set, along y for bit 1 and along z for bit 2.
    static func corners() -> [SIMD3<Float>] {
        let halfX: Float = size.x * 0.5
        let top: Float = size.y
        let halfZ: Float = size.z * 0.5
        return (0..<8).map { i -> SIMD3<Float> in
            let x: Float = (i & 1) == 0 ? -halfX : halfX
            let y: Float = (i & 2) == 0 ? 0 : top
            let z: Float = (i & 4) == 0 ? -halfZ : halfZ
            return SIMD3<Float>(x, y, z)
        }
    }

    /// The center of the box.
    static var center: SIMD3<Float> {
        SIMD3<Float>(0, size.y * 0.5, 0)
    }

    /// A quad's corner order with the winding turned outward (counter-clockwise seen from outside).
    static func outwardOrder(_ quad: [Int], corners: [SIMD3<Float>]) -> [Int] {
        guard quad.count == 4 else { return quad }
        let a = corners[quad[0]], b = corners[quad[1]], c = corners[quad[2]], d = corners[quad[3]]
        let sumAB: SIMD3<Float> = a + b
        let sumCD: SIMD3<Float> = c + d
        let faceCenter: SIMD3<Float> = (sumAB + sumCD) * Float(0.25)
        let outward: SIMD3<Float> = faceCenter - center
        let normal: SIMD3<Float> = simd_cross(b - a, c - a)
        return simd_dot(normal, outward) >= 0 ? quad : [quad[0], quad[3], quad[2], quad[1]]
    }

    /// The closed box as one welded mesh: 8 vertices, 12 outward triangles (every edge shared
    /// by two triangles, so ObjectModel measures a volume).
    static func weldedMesh() -> TriangleMesh {
        let points = corners()
        var indices: [UInt32] = []
        indices.reserveCapacity(36)
        for quad in sideQuads + capQuads {
            let order = outwardOrder(quad, corners: points).map { UInt32($0) }
            indices.append(contentsOf: [order[0], order[1], order[2], order[0], order[2], order[3]])
        }
        return TriangleMesh(positions: points, indices: indices)
    }

    /// Flat-shaded quads as one export mesh: 4 own vertices per quad with the face normal.
    static func exportMesh(name: String, quads: [[Int]], materialIndex: Int) -> ExportMesh {
        let points = corners()
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for quad in quads {
            let order = outwardOrder(quad, corners: points)
            let a = points[order[0]], b = points[order[1]], c = points[order[2]]
            let cross: SIMD3<Float> = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let normal: SIMD3<Float> = length > 0 ? cross / length : SIMD3<Float>(0, 1, 0)
            let base = UInt32(positions.count)
            for corner in order {
                positions.append(points[corner])
                normals.append(normal)
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return ExportMesh(name: name, positions: positions, normals: normals, indices: indices, materialIndex: materialIndex)
    }

    /// The two-color model: sides with material 0, top and bottom with material 1.
    static func modelScene() -> ExportScene {
        let sides = exportMesh(name: "DemoSides", quads: sideQuads, materialIndex: 0)
        let caps = exportMesh(name: "DemoCaps", quads: capQuads, materialIndex: 1)
        let materials = [ExportMaterial(name: "demoSides", baseColor: sideColor),
                         ExportMaterial(name: "demoCaps", baseColor: capColor)]
        return ExportScene(meshes: [sides, caps], materials: materials, metadata: ["generator": "Mapper demo object"])
    }
}
