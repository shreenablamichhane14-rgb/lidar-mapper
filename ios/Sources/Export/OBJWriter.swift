import Foundation
import simd

/// Wavefront OBJ + MTL + JPEG textures.
///
/// - One `o` block per mesh; `v`, `vt`, `vn` indices are global and 1-based.
/// - Faces use `v`, `v/vt`, `v//vn` or `v/vt/vn` depending on the attributes the mesh has.
/// - Vertex colors use the widespread `v x y z r g b` extension (r g b in 0...1),
///   read by MeshLab, Blender, CloudCompare and others; alpha is not stored.
/// - Materials: `Kd` from the base color, `d` from its alpha, `map_Kd` for the texture.
/// - Units are meters, +Y up, which is what most OBJ importers assume.
enum OBJWriter {
    /// One file of an OBJ export, relative to the export folder.
    struct File {
        /// File name, e.g. "model.obj" or "kitchen.jpg".
        var name: String
        /// File contents.
        var data: Data
    }

    /// Builds all files (.obj first, then .mtl, then textures) without touching disk.
    static func files(for scene: ExportScene, baseName: String = "model") throws -> [File] {
        try scene.validate()
        let base = ExportText.fileName(baseName, fallback: "model", ext: "obj")
        let stem = String(base.dropLast(4))
        let mtlName = "\(stem).mtl"
        let textureNames = ExportText.textureFileNames(for: scene.materials)
        var files = [
            File(name: base, data: Data(objText(for: scene, mtlFileName: mtlName).utf8)),
            File(name: mtlName, data: Data(mtlText(for: scene, textureFileNames: textureNames).utf8)),
        ]
        for (material, name) in zip(scene.materials, textureNames) {
            if let name = name, let jpeg = material.textureJPEG {
                files.append(File(name: name, data: jpeg))
            }
        }
        return files
    }

    /// Writes the .obj, .mtl and textures into `folder` (created if needed) and returns
    /// the URLs written, .obj first.
    @discardableResult
    static func write(_ scene: ExportScene, to folder: URL, baseName: String = "model") throws -> [URL] {
        let output = try files(for: scene, baseName: baseName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(path: folder.lastPathComponent, reason: error.localizedDescription)
        }
        var urls: [URL] = []
        for file in output {
            let url = folder.appendingPathComponent(file.name)
            do {
                try file.data.write(to: url, options: .atomic)
            } catch {
                throw ExportError.writeFailed(path: file.name, reason: error.localizedDescription)
            }
            urls.append(url)
        }
        return urls
    }

    /// The same files packed into a ZIP (stored, no compression) for sharing.
    static func zipBundle(for scene: ExportScene, baseName: String = "model") throws -> Data {
        try ZipWriter.archive(files(for: scene, baseName: baseName).map { (name: $0.name, data: $0.data) })
    }

    /// Unique OBJ/MTL material names for the scene's materials.
    static func materialNames(for scene: ExportScene) -> [String] {
        ExportText.uniqueIdentifiers(scene.materials.map { $0.name }, fallback: "material")
    }

    /// The .obj text. Meshes without triangles are skipped.
    static func objText(for scene: ExportScene, mtlFileName: String) -> String {
        let mtlNames = materialNames(for: scene)
        let meshes = scene.exportableMeshes
        let objectNames = ExportText.uniqueIdentifiers(meshes.map { $0.name }, fallback: "mesh")
        var out = "# Mapper OBJ export\n# Units: meters, +Y up, right handed\n"
        out += "# Vertex colors, when present, use the extension: v x y z r g b (0...1)\n"
        if let project = scene.metadata["project"] { out += "# Project: \(singleLine(project))\n" }
        out += "mtllib \(mtlFileName)\n"
        var positionBase = 0
        var texcoordBase = 0
        var normalBase = 0
        for (mesh, objectName) in zip(meshes, objectNames) {
            out += "o \(objectName)\n"
            for (i, p) in mesh.positions.enumerated() {
                out += "v \(num(p.x)) \(num(p.y)) \(num(p.z))"
                if let colors = mesh.colors {
                    let c = colors[i]
                    out += " \(ExportText.number(Double(c.x) / 255, places: 4)) \(ExportText.number(Double(c.y) / 255, places: 4)) \(ExportText.number(Double(c.z) / 255, places: 4))"
                }
                out += "\n"
            }
            for t in mesh.texcoords ?? [] {
                out += "vt \(num(t.x)) \(num(t.y))\n"
            }
            for n in mesh.normals ?? [] {
                out += "vn \(ExportText.number(n.x, places: 5)) \(ExportText.number(n.y, places: 5)) \(ExportText.number(n.z, places: 5))\n"
            }
            if let index = mesh.materialIndex, index >= 0, index < mtlNames.count {
                out += "usemtl \(mtlNames[index])\n"
            }
            let hasUV = mesh.texcoords != nil
            let hasNormal = mesh.normals != nil
            var t = 0
            while t + 2 < mesh.indices.count {
                out += "f"
                for k in 0..<3 {
                    let i = Int(mesh.indices[t + k])
                    out += " " + faceVertex(v: positionBase + i + 1,
                                            vt: hasUV ? texcoordBase + i + 1 : nil,
                                            vn: hasNormal ? normalBase + i + 1 : nil)
                }
                out += "\n"
                t += 3
            }
            positionBase += mesh.positions.count
            texcoordBase += mesh.texcoords?.count ?? 0
            normalBase += mesh.normals?.count ?? 0
        }
        return out
    }

    /// The .mtl text; `textureFileNames` comes from `ExportText.textureFileNames`.
    static func mtlText(for scene: ExportScene, textureFileNames: [String?]) -> String {
        let names = materialNames(for: scene)
        var out = "# Mapper MTL export\n"
        for (i, material) in scene.materials.enumerated() {
            let c = material.baseColor
            out += "\nnewmtl \(names[i])\n"
            out += "Ka 0 0 0\n"
            out += "Kd \(num(c.x)) \(num(c.y)) \(num(c.z))\n"
            out += "Ks 0 0 0\n"
            out += "d \(num(c.w))\n"
            out += "illum 1\n"
            if i < textureFileNames.count, let texture = textureFileNames[i] {
                out += "map_Kd \(texture)\n"
            }
        }
        return out
    }

    /// One face corner in the form the available attributes allow.
    static func faceVertex(v: Int, vt: Int?, vn: Int?) -> String {
        switch (vt, vn) {
        case let (uv?, normal?): return "\(v)/\(uv)/\(normal)"
        case let (uv?, nil): return "\(v)/\(uv)"
        case let (nil, normal?): return "\(v)//\(normal)"
        case (nil, nil): return "\(v)"
        }
    }

    private static func num(_ value: Float) -> String {
        ExportText.number(value, places: 6)
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
