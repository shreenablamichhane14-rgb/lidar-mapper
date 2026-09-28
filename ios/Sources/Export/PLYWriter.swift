import Foundation
import simd

/// Stanford PLY, binary little endian 1.0 (default) or ASCII 1.0.
///
/// Vertex properties: `float x y z`, then `float nx ny nz` and `uchar red green blue
/// alpha` when present. Faces: `property list uchar uint vertex_indices` (uchar count,
/// uint32 indices). All meshes are merged into one vertex and face list with index
/// offsets. An optional attribute is written only when every exported mesh has it,
/// because PLY has one vertex layout per file. Units are meters, +Y up.
enum PLYWriter {
    /// Output encoding.
    enum Encoding {
        /// `format binary_little_endian 1.0` (compact, the usual choice).
        case binaryLittleEndian
        /// `format ascii 1.0` (human readable, about three times larger).
        case ascii
    }

    /// Which optional vertex properties a scene produces.
    struct Layout {
        /// Every mesh has normals.
        var normals: Bool
        /// Every mesh has vertex colors.
        var colors: Bool
        /// Total vertices after merging.
        var vertexCount: Int
        /// Total triangles after merging.
        var faceCount: Int

        /// Bytes per vertex in the binary encoding.
        var vertexStride: Int { 12 + (normals ? 12 : 0) + (colors ? 4 : 0) }
    }

    /// The layout the writer would use for `scene`.
    static func layout(for scene: ExportScene) -> Layout {
        let meshes = scene.exportableMeshes
        return Layout(normals: !meshes.isEmpty && meshes.allSatisfy { $0.normals != nil },
                      colors: !meshes.isEmpty && meshes.allSatisfy { $0.colors != nil },
                      vertexCount: meshes.reduce(0) { $0 + $1.positions.count },
                      faceCount: meshes.reduce(0) { $0 + $1.triangleCount })
    }

    /// The header text, including the final "end_header\n".
    static func header(for layout: Layout, encoding: Encoding, comment: String = "Mapper export, units meters, Y up") -> String {
        var lines = ["ply"]
        switch encoding {
        case .binaryLittleEndian: lines.append("format binary_little_endian 1.0")
        case .ascii: lines.append("format ascii 1.0")
        }
        lines.append("comment \(comment.replacingOccurrences(of: "\n", with: " "))")
        lines.append("element vertex \(layout.vertexCount)")
        lines.append(contentsOf: ["property float x", "property float y", "property float z"])
        if layout.normals {
            lines.append(contentsOf: ["property float nx", "property float ny", "property float nz"])
        }
        if layout.colors {
            lines.append(contentsOf: ["property uchar red", "property uchar green", "property uchar blue", "property uchar alpha"])
        }
        lines.append("element face \(layout.faceCount)")
        lines.append("property list uchar uint vertex_indices")
        lines.append("end_header")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Encodes the scene as PLY.
    static func data(for scene: ExportScene, encoding: Encoding = .binaryLittleEndian) throws -> Data {
        try scene.validate()
        let plyLayout = layout(for: scene)
        guard plyLayout.vertexCount <= Int(UInt32.max) else {
            throw ExportError.tooLarge(format: "PLY", detail: "more than 4 billion vertices")
        }
        let head = header(for: plyLayout, encoding: encoding)
        switch encoding {
        case .binaryLittleEndian:
            return binaryBody(scene: scene, layout: plyLayout, header: head)
        case .ascii:
            return Data((head + asciiBody(scene: scene, layout: plyLayout)).utf8)
        }
    }

    private static func binaryBody(scene: ExportScene, layout: Layout, header: String) -> Data {
        var out = ByteWriter(capacity: header.utf8.count + layout.vertexCount * layout.vertexStride + layout.faceCount * 13)
        out.appendString(header)
        let meshes = scene.exportableMeshes
        for mesh in meshes {
            for i in 0..<mesh.positions.count {
                let p = mesh.positions[i]
                out.appendFloat32(p.x)
                out.appendFloat32(p.y)
                out.appendFloat32(p.z)
                if layout.normals, let normals = mesh.normals {
                    out.appendFloat32(normals[i].x)
                    out.appendFloat32(normals[i].y)
                    out.appendFloat32(normals[i].z)
                }
                if layout.colors, let colors = mesh.colors {
                    out.appendUInt8(colors[i].x)
                    out.appendUInt8(colors[i].y)
                    out.appendUInt8(colors[i].z)
                    out.appendUInt8(colors[i].w)
                }
            }
        }
        var base: UInt32 = 0
        for mesh in meshes {
            var t = 0
            while t + 2 < mesh.indices.count {
                out.appendUInt8(3)
                out.appendUInt32(base + mesh.indices[t])
                out.appendUInt32(base + mesh.indices[t + 1])
                out.appendUInt32(base + mesh.indices[t + 2])
                t += 3
            }
            base += UInt32(mesh.positions.count)
        }
        return out.data
    }

    private static func asciiBody(scene: ExportScene, layout: Layout) -> String {
        var out = ""
        let meshes = scene.exportableMeshes
        for mesh in meshes {
            for i in 0..<mesh.positions.count {
                let p = mesh.positions[i]
                out += "\(ExportText.number(p.x)) \(ExportText.number(p.y)) \(ExportText.number(p.z))"
                if layout.normals, let normals = mesh.normals {
                    let n = normals[i]
                    out += " \(ExportText.number(n.x)) \(ExportText.number(n.y)) \(ExportText.number(n.z))"
                }
                if layout.colors, let colors = mesh.colors {
                    let c = colors[i]
                    out += " \(c.x) \(c.y) \(c.z) \(c.w)"
                }
                out += "\n"
            }
        }
        var base = 0
        for mesh in meshes {
            var t = 0
            while t + 2 < mesh.indices.count {
                out += "3 \(base + Int(mesh.indices[t])) \(base + Int(mesh.indices[t + 1])) \(base + Int(mesh.indices[t + 2]))\n"
                t += 3
            }
            base += mesh.positions.count
        }
        return out
    }
}
