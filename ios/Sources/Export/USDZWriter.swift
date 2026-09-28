import Foundation
import simd

/// USDZ: an uncompressed ZIP whose first entry is the root layer (here ASCII USD,
/// .usda) followed by its textures, with every file's data starting on a 64-byte
/// boundary, as the USDZ specification requires.
///
/// Layer: `metersPerUnit = 1`, `upAxis = "Y"`, default prim `/Root` (an Xform of kind
/// component). Each mesh is a Mesh prim with points, extent, faceVertexCounts,
/// faceVertexIndices, vertex-interpolated normals and `primvars:st`, and
/// `primvars:displayColor` (RGB, alpha dropped) when it has vertex colors. Materials
/// live under `/Root/Materials`: UsdPreviewSurface (metallic 0, roughness 0.9) with the
/// base color, or, when textured, a UsdUVTexture (sRGB, scaled by the base color) fed by
/// a UsdPrimvarReader_float2 reading "st". The structure was checked against Pixar's
/// usdz compliance checker including its ARKit rules.
enum USDZWriter {
    /// Required data alignment inside the package.
    static let alignment = 64
    /// Folder for textures inside the package.
    static let textureFolder = "textures"

    /// Builds the .usdz package. `layerName` is the root layer's file name.
    static func data(for scene: ExportScene, layerName: String = "model.usda", modified: Date = Date()) throws -> Data {
        try scene.validate()
        var archive = ZipWriter(alignment: alignment, modified: modified)
        let name = ExportText.fileName(layerName, fallback: "model", ext: "usda")
        try archive.add(name: name, data: Data(usdaText(for: scene).utf8))
        let textureNames = ExportText.textureFileNames(for: scene.materials)
        for (material, textureName) in zip(scene.materials, textureNames) {
            if let textureName = textureName, let jpeg = material.textureJPEG {
                try archive.add(name: "\(textureFolder)/\(textureName)", data: jpeg)
            }
        }
        return try archive.finish()
    }

    /// The root layer as USDA text. Meshes without triangles are skipped.
    static func usdaText(for scene: ExportScene) -> String {
        let meshes = scene.exportableMeshes
        let materialNames = ExportText.uniqueIdentifiers(scene.materials.map { $0.name }, fallback: "Material")
        // "Materials" is reserved for the material scope.
        let meshNames = Array(ExportText.uniqued(["Materials"] + meshes.enumerated().map {
            ExportText.identifier($0.element.name, fallback: "Mesh\($0.offset)")
        }).dropFirst())
        let textureNames = ExportText.textureFileNames(for: scene.materials)

        var out = "#usda 1.0\n(\n"
        out += "    customLayerData = {\n"
        out += "        string creator = \"Mapper\"\n"
        let keys = scene.metadata.keys.sorted()
        let keyNames = ExportText.uniqued(["creator"] + keys.map { ExportText.identifier($0, fallback: "key") }).dropFirst()
        for (key, keyName) in zip(keys, keyNames) {
            out += "        string \(keyName) = \(quoted(scene.metadata[key] ?? ""))\n"
        }
        out += "    }\n"
        out += "    defaultPrim = \"Root\"\n    metersPerUnit = 1\n    upAxis = \"Y\"\n)\n\n"
        out += "def Xform \"Root\" (\n    kind = \"component\"\n)\n{\n"

        if !scene.materials.isEmpty {
            out += "    def Scope \"Materials\"\n    {\n"
            for (i, material) in scene.materials.enumerated() {
                out += materialText(material, name: materialNames[i], texturePath: textureNames[i].map { "\(textureFolder)/\($0)" })
            }
            out += "    }\n"
        }

        for (mesh, name) in zip(meshes, meshNames) {
            let binding = mesh.materialIndex.flatMap { i -> String? in i >= 0 && i < materialNames.count ? materialNames[i] : nil }
            out += "\n"
            out += meshText(mesh, name: name, materialName: binding)
        }
        out += "}\n"
        return out
    }

    private static func materialText(_ material: ExportMaterial, name: String, texturePath: String?) -> String {
        let path = "/Root/Materials/\(name)"
        let c = material.baseColor
        var out = "        def Material \"\(name)\"\n        {\n"
        out += "            token outputs:surface.connect = <\(path)/Surface.outputs:surface>\n\n"
        out += "            def Shader \"Surface\"\n            {\n"
        out += "                uniform token info:id = \"UsdPreviewSurface\"\n"
        if texturePath != nil {
            out += "                color3f inputs:diffuseColor.connect = <\(path)/Texture.outputs:rgb>\n"
        } else {
            out += "                color3f inputs:diffuseColor = (\(unit(c.x)), \(unit(c.y)), \(unit(c.z)))\n"
        }
        out += "                float inputs:metallic = 0\n"
        out += "                float inputs:opacity = \(unit(c.w))\n"
        out += "                float inputs:roughness = 0.9\n"
        out += "                token outputs:surface\n            }\n"
        if let texturePath = texturePath {
            out += "\n            def Shader \"PrimvarReader\"\n            {\n"
            out += "                uniform token info:id = \"UsdPrimvarReader_float2\"\n"
            out += "                string inputs:varname = \"st\"\n"
            out += "                float2 outputs:result\n            }\n"
            out += "\n            def Shader \"Texture\"\n            {\n"
            out += "                uniform token info:id = \"UsdUVTexture\"\n"
            out += "                asset inputs:file = @\(texturePath)@\n"
            out += "                float4 inputs:scale = (\(unit(c.x)), \(unit(c.y)), \(unit(c.z)), 1)\n"
            out += "                token inputs:sourceColorSpace = \"sRGB\"\n"
            out += "                float2 inputs:st.connect = <\(path)/PrimvarReader.outputs:result>\n"
            out += "                token inputs:wrapS = \"repeat\"\n"
            out += "                token inputs:wrapT = \"repeat\"\n"
            out += "                float3 outputs:rgb\n            }\n"
        }
        out += "        }\n"
        return out
    }

    private static func meshText(_ mesh: ExportMesh, name: String, materialName: String?) -> String {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        var out = "    def Mesh \"\(name)\""
        out += materialName != nil ? " (\n        prepend apiSchemas = [\"MaterialBindingAPI\"]\n    )\n" : "\n"
        out += "    {\n"
        out += "        float3[] extent = [\(tuple(lo)), \(tuple(hi))]\n"
        out += "        int[] faceVertexCounts = [\(Array(repeating: "3", count: mesh.triangleCount).joined(separator: ", "))]\n"
        out += "        int[] faceVertexIndices = [\(mesh.indices.map { String($0) }.joined(separator: ", "))]\n"
        if let materialName = materialName {
            out += "        rel material:binding = </Root/Materials/\(materialName)>\n"
        }
        if let normals = mesh.normals {
            out += "        normal3f[] normals = [\(normals.map(tuple).joined(separator: ", "))] (\n"
            out += "            interpolation = \"vertex\"\n        )\n"
        }
        out += "        point3f[] points = [\(mesh.positions.map(tuple).joined(separator: ", "))]\n"
        if let colors = mesh.colors {
            let rgb = colors.map { c -> String in
                "(\(ExportText.number(Double(c.x) / 255, places: 4)), \(ExportText.number(Double(c.y) / 255, places: 4)), \(ExportText.number(Double(c.z) / 255, places: 4)))"
            }
            out += "        color3f[] primvars:displayColor = [\(rgb.joined(separator: ", "))] (\n"
            out += "            interpolation = \"vertex\"\n        )\n"
        }
        if let texcoords = mesh.texcoords {
            let st = texcoords.map { "(\(ExportText.number($0.x)), \(ExportText.number($0.y)))" }
            out += "        texCoord2f[] primvars:st = [\(st.joined(separator: ", "))] (\n"
            out += "            interpolation = \"vertex\"\n        )\n"
        }
        out += "        uniform token subdivisionScheme = \"none\"\n"
        out += "    }\n"
        return out
    }

    private static func tuple(_ v: SIMD3<Float>) -> String {
        "(\(ExportText.number(v.x)), \(ExportText.number(v.y)), \(ExportText.number(v.z)))"
    }

    private static func unit(_ value: Float) -> String {
        ExportText.number(Double(min(max(value, 0), 1)), places: 4)
    }

    /// USDA string literal with backslash escapes.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for ch in text {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}
