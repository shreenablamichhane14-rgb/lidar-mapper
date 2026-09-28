import Foundation
import simd

/// glTF 2.0 binary (.glb).
///
/// Layout: 12-byte header (magic "glTF", version 2, total length), a JSON chunk padded
/// with spaces to 4 bytes, and one BIN chunk padded with zeros. One buffer holds every
/// bufferView, each starting on a 4-byte boundary. Per mesh: POSITION (with min/max),
/// optional NORMAL, TEXCOORD_0 (V flipped to glTF's top-left origin) and COLOR_0
/// (normalized unsigned byte VEC4), and uint32 indices. Materials are
/// pbrMetallicRoughness (metallic 0, roughness 1) with the base color as factor and the
/// JPEG, stored in its own bufferView, as base color texture. One node per mesh, one
/// scene. The JSON is built from dictionaries with JSONSerialization.
enum GLBWriter {
    /// "glTF" read as a little-endian UInt32.
    static let magic: UInt32 = 0x4654_6C67
    /// Container version.
    static let version: UInt32 = 2
    /// Chunk type "JSON".
    static let jsonChunkType: UInt32 = 0x4E4F_534A
    /// Chunk type "BIN\0".
    static let binChunkType: UInt32 = 0x004E_4942

    /// glTF enum values used here.
    enum Constant {
        static let float = 5126
        static let unsignedInt = 5125
        static let unsignedByte = 5121
        static let arrayBuffer = 34962
        static let elementArrayBuffer = 34963
        static let triangles = 4
        static let linear = 9729
        static let linearMipmapLinear = 9987
        static let repeatWrap = 10497
    }

    /// Encodes the scene as a .glb file. `generator` goes into asset.generator; scene
    /// metadata goes into asset.extras.
    static func data(for scene: ExportScene, generator: String = "Mapper") throws -> Data {
        try scene.validate()
        var bin = ByteWriter()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func addView(_ bytes: Data, target: Int?, stride: Int?) -> Int {
            bin.align(to: 4)
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count]
            if let target = target { view["target"] = target }
            if let stride = stride { view["byteStride"] = stride }
            bin.appendData(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        func addAccessor(view: Int, componentType: Int, count: Int, type: String,
                         normalized: Bool = false, min: [Double]? = nil, max: [Double]? = nil) -> Int {
            var accessor: [String: Any] = ["bufferView": view, "byteOffset": 0, "componentType": componentType,
                                           "count": count, "type": type]
            if normalized { accessor["normalized"] = true }
            if let min = min { accessor["min"] = min }
            if let max = max { accessor["max"] = max }
            accessors.append(accessor)
            return accessors.count - 1
        }

        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        for (meshIndex, mesh) in scene.exportableMeshes.enumerated() {
            let count = mesh.positions.count
            var attributes: [String: Any] = [:]

            var positions = ByteWriter(capacity: count * 12)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for p in mesh.positions {
                positions.appendFloat32(p.x)
                positions.appendFloat32(p.y)
                positions.appendFloat32(p.z)
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            let positionView = addView(positions.data, target: Constant.arrayBuffer, stride: 12)
            attributes["POSITION"] = addAccessor(view: positionView, componentType: Constant.float, count: count, type: "VEC3",
                                                 min: [Double(lo.x), Double(lo.y), Double(lo.z)],
                                                 max: [Double(hi.x), Double(hi.y), Double(hi.z)])

            if let normals = mesh.normals {
                var w = ByteWriter(capacity: count * 12)
                for n in normals {
                    w.appendFloat32(n.x)
                    w.appendFloat32(n.y)
                    w.appendFloat32(n.z)
                }
                let view = addView(w.data, target: Constant.arrayBuffer, stride: 12)
                attributes["NORMAL"] = addAccessor(view: view, componentType: Constant.float, count: count, type: "VEC3")
            }
            if let texcoords = mesh.texcoords {
                var w = ByteWriter(capacity: count * 8)
                for t in texcoords {
                    w.appendFloat32(t.x)
                    w.appendFloat32(1 - t.y)
                }
                let view = addView(w.data, target: Constant.arrayBuffer, stride: 8)
                attributes["TEXCOORD_0"] = addAccessor(view: view, componentType: Constant.float, count: count, type: "VEC2")
            }
            if let colors = mesh.colors {
                var w = ByteWriter(capacity: count * 4)
                for c in colors {
                    w.appendUInt8(c.x)
                    w.appendUInt8(c.y)
                    w.appendUInt8(c.z)
                    w.appendUInt8(c.w)
                }
                let view = addView(w.data, target: Constant.arrayBuffer, stride: 4)
                attributes["COLOR_0"] = addAccessor(view: view, componentType: Constant.unsignedByte, count: count,
                                                    type: "VEC4", normalized: true)
            }

            var indices = ByteWriter(capacity: mesh.indices.count * 4)
            for index in mesh.indices { indices.appendUInt32(index) }
            let indexView = addView(indices.data, target: Constant.elementArrayBuffer, stride: nil)
            let indexAccessor = addAccessor(view: indexView, componentType: Constant.unsignedInt,
                                            count: mesh.indices.count, type: "SCALAR")

            var primitive: [String: Any] = ["attributes": attributes, "indices": indexAccessor, "mode": Constant.triangles]
            if let material = mesh.materialIndex, material >= 0, material < scene.materials.count {
                primitive["material"] = material
            }
            meshes.append(["name": mesh.name, "primitives": [primitive]])
            nodes.append(["name": mesh.name, "mesh": meshIndex])
        }

        var materials: [[String: Any]] = []
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        let textureNames = ExportText.textureFileNames(for: scene.materials)
        for (i, material) in scene.materials.enumerated() {
            let c = material.baseColor
            var pbr: [String: Any] = [
                "baseColorFactor": [clamp01(c.x), clamp01(c.y), clamp01(c.z), clamp01(c.w)],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0,
            ]
            if let jpeg = material.textureJPEG, !jpeg.isEmpty {
                let view = addView(jpeg, target: nil, stride: nil)
                images.append(["bufferView": view, "mimeType": "image/jpeg", "name": textureNames[i] ?? "texture\(i)"])
                textures.append(["sampler": 0, "source": images.count - 1])
                pbr["baseColorTexture"] = ["index": textures.count - 1]
            }
            var entry: [String: Any] = ["name": material.name, "pbrMetallicRoughness": pbr]
            if c.w < 1 { entry["alphaMode"] = "BLEND" }
            materials.append(entry)
        }

        bin.align(to: 4)
        guard bin.count < Int(UInt32.max) - 1024 else {
            throw ExportError.tooLarge(format: "GLB", detail: "more than 4 GB of binary data")
        }

        var asset: [String: Any] = ["version": "2.0", "generator": generator]
        if !scene.metadata.isEmpty { asset["extras"] = scene.metadata }
        var root: [String: Any] = [
            "asset": asset,
            "scene": 0,
            "scenes": [["name": "Scene", "nodes": Array(0..<nodes.count)] as [String: Any]],
            "nodes": nodes,
            "meshes": meshes,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
        ]
        if !materials.isEmpty { root["materials"] = materials }
        if !images.isEmpty {
            root["images"] = images
            root["textures"] = textures
            root["samplers"] = [["magFilter": Constant.linear, "minFilter": Constant.linearMipmapLinear,
                                 "wrapS": Constant.repeatWrap, "wrapT": Constant.repeatWrap]]
        }
        guard JSONSerialization.isValidJSONObject(root) else { throw ExportError.encodingFailed(format: "glTF JSON") }
        var json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw ExportError.encodingFailed(format: "glTF JSON")
        }
        json.append(contentsOf: [UInt8](repeating: 0x20, count: ByteWriter.padding(for: json.count, alignment: 4)))

        let total = 12 + 8 + json.count + 8 + bin.count
        guard total < Int(UInt32.max) else {
            throw ExportError.tooLarge(format: "GLB", detail: "the file would exceed 4 GB")
        }
        var out = ByteWriter(capacity: total)
        out.appendUInt32(magic)
        out.appendUInt32(version)
        out.appendUInt32(UInt32(total))
        out.appendUInt32(UInt32(json.count))
        out.appendUInt32(jsonChunkType)
        out.appendData(json)
        out.appendUInt32(UInt32(bin.count))
        out.appendUInt32(binChunkType)
        out.appendData(bin.data)
        return out.data
    }

    private static func clamp01(_ value: Float) -> Double {
        Double(min(max(value, 0), 1))
    }
}
