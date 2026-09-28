import Foundation
import ModelIO
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Cleans an Object Capture model: keeps the main object, drops floaters (reflections,
/// bits of the table or background), measures the true size, and writes clean exports.
/// The original USDZ from Apple's reconstruction is kept untouched as the raw result.
enum ObjectPolish {
    /// Result of polishing, with sizes in meters (gravity-aligned box: width, height, depth).
    struct Result {
        var width: Double
        var height: Double
        var depth: Double
        var keptTriangles: Int
        var removedTriangles: Int
        var files: [String]
    }

    /// Reads the model, keeps the largest connected piece by surface area, and writes
    /// object-clean.usdz, object-clean.glb, object.stl and object-obj.zip into `folder`.
    static func polish(modelURL: URL, folder: URL) -> Result? {
        guard var mesh = load(modelURL) else {
            LogStore.shared.write("polish: could not read \(modelURL.lastPathComponent)", category: "object")
            return nil
        }
        let before = mesh.indices.count / 3
        mesh = largestPiece(mesh)
        let after = mesh.indices.count / 3
        guard after > 0 else { return nil }

        var width = 0.0, height = 0.0, depth = 0.0
        if let box = OrientedBox.fit(mesh.positions, gravityAligned: true) {
            width = Double(box.halfExtents.x * 2)
            height = Double(box.halfExtents.y * 2)
            depth = Double(box.halfExtents.z * 2)
            if width < depth { swap(&width, &depth) }
        }

        let material = ExportMaterial(name: "object", textureJPEG: mesh.textureJPEG,
                                      textureName: mesh.textureJPEG == nil ? "" : "object_texture.jpg")
        let exportMesh = ExportMesh(name: "object", positions: mesh.positions, normals: nil,
                                    texcoords: mesh.texcoords, indices: mesh.indices, materialIndex: 0)
        let scene = ExportScene(meshes: [exportMesh], materials: [material], metadata: ["generator": "Mapper"])

        var files: [String] = []
        func attempt(_ name: String, _ make: () throws -> Data) {
            do {
                try make().write(to: folder.appendingPathComponent(name), options: .atomic)
                files.append(name)
            } catch {
                LogStore.shared.write("polish: \(name) failed: \(error.localizedDescription)", category: "object")
            }
        }
        attempt("object-clean.usdz") { try USDZWriter.data(for: scene) }
        attempt("object-clean.glb") { try GLBWriter.data(for: scene) }
        attempt("object.stl") { try STLWriter.binary(for: scene) }
        do {
            let staging = folder.appendingPathComponent("obj-staging", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let written = try OBJWriter.write(scene, to: staging, baseName: "object")
            var entries: [(name: String, data: Data)] = []
            for url in written {
                entries.append((name: url.lastPathComponent, data: try Data(contentsOf: url)))
            }
            let zip = try ZipWriter.archive(entries)
            try zip.write(to: folder.appendingPathComponent("object-obj.zip"), options: .atomic)
            try? FileManager.default.removeItem(at: staging)
            files.append("object-obj.zip")
        } catch {
            LogStore.shared.write("polish: OBJ zip failed: \(error.localizedDescription)", category: "object")
        }
        LogStore.shared.write("polish: kept \(after) of \(before) triangles, size \(width) x \(height) x \(depth) m, files \(files)", category: "object")
        return Result(width: width, height: height, depth: depth, keptTriangles: after,
                      removedTriangles: before - after, files: files)
    }

    // MARK: - Loading

    private struct MeshData {
        var positions: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>]? = []
        var indices: [UInt32] = []
        var textureJPEG: Data?
    }

    private static func load(_ url: URL) -> MeshData? {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { return nil }
        var data = MeshData()
        var image: CGImage?
        for mesh in meshes {
            guard let position = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let base = UInt32(data.positions.count)
            for i in 0..<mesh.vertexCount {
                let p = position.dataStart.advanced(by: i * position.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                data.positions.append(SIMD3<Float>(w.x, w.y, w.z))
                if let uv {
                    let t = uv.dataStart.advanced(by: i * uv.stride).assumingMemoryBound(to: Float.self)
                    data.texcoords?.append(SIMD2<Float>(t[0], t[1]))
                } else {
                    data.texcoords = nil
                }
            }
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for submesh in submeshes where submesh.geometryType == .triangles {
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
                for k in 0..<submesh.indexCount {
                    data.indices.append(base + pointer[k])
                }
                if image == nil,
                   let texture = submesh.material?.property(with: .baseColor)?.textureSamplerValue?.texture,
                   let cg = texture.imageFromTexture()?.takeUnretainedValue() {
                    image = cg
                }
            }
        }
        if let texcoords = data.texcoords, texcoords.count != data.positions.count { data.texcoords = nil }
        if let image { data.textureJPEG = jpeg(image) }
        return data.indices.isEmpty ? nil : data
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: - Largest piece

    /// Keeps the connected piece with the most surface area. Vertices are welded by
    /// position first, because texture seams split vertices that are really one point.
    private static func largestPiece(_ mesh: MeshData) -> MeshData {
        let triangleCount = mesh.indices.count / 3
        guard triangleCount > 0 else { return mesh }
        // weld by position (0.1 mm grid)
        var weldID = [Int](repeating: 0, count: mesh.positions.count)
        var table: [SIMD3<Int32>: Int] = [:]
        for (i, p) in mesh.positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
            if let id = table[key] {
                weldID[i] = id
            } else {
                weldID[i] = table.count
                table[key] = table.count
            }
        }
        var parent = Array(0..<table.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for t in 0..<triangleCount {
            let a = find(weldID[Int(mesh.indices[3 * t])])
            let b = find(weldID[Int(mesh.indices[3 * t + 1])])
            let c = find(weldID[Int(mesh.indices[3 * t + 2])])
            if a != b { parent[a] = b }
            let b2 = find(b)
            if c != b2 { parent[c] = b2 }
        }
        var area: [Int: Float] = [:]
        var faceRoot = [Int](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            let i0 = Int(mesh.indices[3 * t]), i1 = Int(mesh.indices[3 * t + 1]), i2 = Int(mesh.indices[3 * t + 2])
            let root = find(weldID[i0])
            faceRoot[t] = root
            let e1 = mesh.positions[i1] - mesh.positions[i0]
            let e2 = mesh.positions[i2] - mesh.positions[i0]
            area[root, default: 0] += simd_length(simd_cross(e1, e2)) * 0.5
        }
        guard let keep = area.max(by: { $0.value < $1.value })?.key else { return mesh }

        var remap = [Int](repeating: -1, count: mesh.positions.count)
        var result = MeshData(positions: [], texcoords: mesh.texcoords == nil ? nil : [], indices: [], textureJPEG: mesh.textureJPEG)
        for t in 0..<triangleCount where faceRoot[t] == keep {
            for k in 0..<3 {
                let old = Int(mesh.indices[3 * t + k])
                if remap[old] < 0 {
                    remap[old] = result.positions.count
                    result.positions.append(mesh.positions[old])
                    if let uv = mesh.texcoords { result.texcoords?.append(uv[old]) }
                }
                result.indices.append(UInt32(remap[old]))
            }
        }
        return result
    }
}
