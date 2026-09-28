import Foundation
import simd

// Plain input types for the export writers. They are deliberately independent of
// ARKit and RoomPlan: the rest of the app adapts its data into these.
// 3D data: meters, +Y up, right handed, counter-clockwise front faces (ARKit convention).
// Texture coordinates: origin at the bottom-left of the image, V up (OBJ and USD
// convention); the GLB writer flips V because glTF puts the origin at the top-left.

/// A surface material shared by all 3D writers.
struct ExportMaterial {
    /// Material name; each writer sanitizes it for its format.
    var name: String
    /// RGBA base color in 0...1. Where a format supports it, it multiplies the texture,
    /// so textured materials normally use white.
    var baseColor: SIMD4<Float>
    /// Optional JPEG used as the base color texture.
    var textureJPEG: Data?
    /// Preferred texture file name such as "kitchen.jpg". Writers sanitize it, force a
    /// .jpg extension and keep names unique.
    var textureName: String

    /// Creates a material; the defaults give an untextured white material.
    init(name: String, baseColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1), textureJPEG: Data? = nil, textureName: String = "") {
        self.name = name
        self.baseColor = baseColor
        self.textureJPEG = textureJPEG
        self.textureName = textureName
    }

    /// True when the material carries non-empty texture bytes.
    var hasTexture: Bool { (textureJPEG?.isEmpty == false) }
}

/// An indexed triangle mesh. Optional attributes are per vertex and must have exactly
/// one entry per position.
struct ExportMesh {
    /// Mesh name; each writer sanitizes it for its format.
    var name: String
    /// Vertex positions in meters.
    var positions: [SIMD3<Float>]
    /// Optional unit normals, one per vertex.
    var normals: [SIMD3<Float>]?
    /// Optional texture coordinates, one per vertex, origin bottom-left.
    var texcoords: [SIMD2<Float>]?
    /// Optional RGBA vertex colors, one per vertex.
    var colors: [SIMD4<UInt8>]?
    /// Triangle list: three indices per triangle, counter-clockwise front faces.
    var indices: [UInt32]
    /// Index into `ExportScene.materials`, or nil for no material.
    var materialIndex: Int?

    /// Creates a mesh; optional attributes default to absent.
    init(name: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>]? = nil, texcoords: [SIMD2<Float>]? = nil,
         colors: [SIMD4<UInt8>]? = nil, indices: [UInt32], materialIndex: Int? = nil) {
        self.name = name
        self.positions = positions
        self.normals = normals
        self.texcoords = texcoords
        self.colors = colors
        self.indices = indices
        self.materialIndex = materialIndex
    }

    /// Number of triangles.
    var triangleCount: Int { indices.count / 3 }

    /// Throws when indices are not a multiple of three, an index is out of range, an
    /// attribute count differs from the position count, or a float is NaN or infinite.
    func validate() throws {
        if indices.count % 3 != 0 {
            throw ExportError.indexCountNotMultipleOfThree(mesh: name, count: indices.count)
        }
        let vertexCount = positions.count
        if let normals = normals, normals.count != vertexCount {
            throw ExportError.attributeCountMismatch(mesh: name, attribute: "normals", expected: vertexCount, actual: normals.count)
        }
        if let texcoords = texcoords, texcoords.count != vertexCount {
            throw ExportError.attributeCountMismatch(mesh: name, attribute: "texcoords", expected: vertexCount, actual: texcoords.count)
        }
        if let colors = colors, colors.count != vertexCount {
            throw ExportError.attributeCountMismatch(mesh: name, attribute: "colors", expected: vertexCount, actual: colors.count)
        }
        for index in indices where Int(index) >= vertexCount {
            throw ExportError.indexOutOfRange(mesh: name, index: Int(index), vertexCount: vertexCount)
        }
        for p in positions where !(p.x.isFinite && p.y.isFinite && p.z.isFinite) {
            throw ExportError.nonFiniteValue(mesh: name, attribute: "positions")
        }
        for n in normals ?? [] where !(n.x.isFinite && n.y.isFinite && n.z.isFinite) {
            throw ExportError.nonFiniteValue(mesh: name, attribute: "normals")
        }
        for t in texcoords ?? [] where !(t.x.isFinite && t.y.isFinite) {
            throw ExportError.nonFiniteValue(mesh: name, attribute: "texcoords")
        }
    }
}

/// Everything a 3D writer needs: meshes, the materials they reference, and free-form
/// metadata (written where the format has a place for it).
struct ExportScene {
    /// Meshes in output order.
    var meshes: [ExportMesh]
    /// Materials referenced by `ExportMesh.materialIndex`.
    var materials: [ExportMaterial]
    /// Free-form key/value metadata such as project name and app version.
    var metadata: [String: String]

    /// Creates a scene.
    init(meshes: [ExportMesh], materials: [ExportMaterial] = [], metadata: [String: String] = [:]) {
        self.meshes = meshes
        self.materials = materials
        self.metadata = metadata
    }

    /// Meshes that have at least one triangle; writers skip the others.
    var exportableMeshes: [ExportMesh] { meshes.filter { $0.triangleCount > 0 } }

    /// Validates every mesh and material reference; throws `emptyScene` when no mesh
    /// has a triangle.
    func validate() throws {
        for mesh in meshes {
            try mesh.validate()
            if let index = mesh.materialIndex, index < 0 || index >= materials.count {
                throw ExportError.invalidMaterialIndex(mesh: mesh.name, index: index, materialCount: materials.count)
            }
        }
        for material in materials {
            let c = material.baseColor
            if !(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite) {
                throw ExportError.nonFiniteValue(mesh: material.name, attribute: "baseColor")
            }
        }
        if exportableMeshes.isEmpty { throw ExportError.emptyScene }
    }

    /// The material of `mesh`, or nil when it has none.
    func material(for mesh: ExportMesh) -> ExportMaterial? {
        guard let index = mesh.materialIndex, index >= 0, index < materials.count else { return nil }
        return materials[index]
    }
}

/// Errors thrown by the export writers.
enum ExportError: Error, LocalizedError {
    case indexCountNotMultipleOfThree(mesh: String, count: Int)
    case indexOutOfRange(mesh: String, index: Int, vertexCount: Int)
    case attributeCountMismatch(mesh: String, attribute: String, expected: Int, actual: Int)
    case invalidMaterialIndex(mesh: String, index: Int, materialCount: Int)
    case nonFiniteValue(mesh: String, attribute: String)
    case emptyScene
    case emptyPlan
    case tooLarge(format: String, detail: String)
    case invalidArchiveEntry(name: String, reason: String)
    case encodingFailed(format: String)
    case writeFailed(path: String, reason: String)

    /// Human readable description (for logs and error alerts).
    var errorDescription: String? {
        switch self {
        case let .indexCountNotMultipleOfThree(mesh, count):
            return "Mesh \"\(mesh)\" has \(count) indices, which is not a whole number of triangles."
        case let .indexOutOfRange(mesh, index, vertexCount):
            return "Mesh \"\(mesh)\" uses vertex \(index) but only has \(vertexCount) vertices."
        case let .attributeCountMismatch(mesh, attribute, expected, actual):
            return "Mesh \"\(mesh)\" has \(actual) \(attribute) for \(expected) vertices."
        case let .invalidMaterialIndex(mesh, index, materialCount):
            return "Mesh \"\(mesh)\" refers to material \(index) but the scene has \(materialCount) materials."
        case let .nonFiniteValue(mesh, attribute):
            return "\"\(mesh)\" has an invalid number (NaN or infinity) in \(attribute)."
        case .emptyScene:
            return "There is no geometry to export."
        case .emptyPlan:
            return "The floor plan is empty."
        case let .tooLarge(format, detail):
            return "The model is too large for \(format): \(detail)."
        case let .invalidArchiveEntry(name, reason):
            return "Cannot add \"\(name)\" to the archive: \(reason)."
        case let .encodingFailed(format):
            return "Could not encode the \(format) file."
        case let .writeFailed(path, reason):
            return "Could not write \(path): \(reason)."
        }
    }
}

/// Text helpers shared by the writers: locale-independent numbers and safe names.
enum ExportText {
    /// Fixed-point decimal with at most `places` fraction digits and trailing zeros
    /// removed ("1.5", "2", "-0.25"). Always uses "." and never exponents; non-finite
    /// values become "0".
    static func number(_ value: Double, places: Int = 6) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    /// Float overload of `number(_:places:)`.
    static func number(_ value: Float, places: Int = 6) -> String {
        number(Double(value), places: places)
    }

    /// ASCII identifier made of letters, digits and underscores that does not start
    /// with a digit (USD prim names, OBJ object and material names).
    static func identifier(_ raw: String, fallback: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let isLetter = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            let isDigit = v >= 48 && v <= 57
            result.append(isLetter || isDigit || v == 95 ? Character(scalar) : "_")
        }
        if result.isEmpty { result = fallback }
        if let first = result.unicodeScalars.first, first.value >= 48 && first.value <= 57 {
            result = "_" + result
        }
        return result
    }

    /// File name safe on every file system and inside zips: ASCII letters, digits,
    /// "-", "_" and "." only, with the given lowercase extension.
    static func fileName(_ raw: String, fallback: String, ext: String) -> String {
        var base = raw
        for suffix in [".\(ext)", ".jpeg", ".jpg"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        var cleaned = ""
        for scalar in base.unicodeScalars {
            let v = scalar.value
            let keep = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 45 || v == 95 || v == 46
            cleaned.append(keep ? Character(scalar) : "_")
        }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = fallback }
        return "\(cleaned).\(ext)"
    }

    /// Makes names unique (case-insensitively) by appending _2, _3 before any extension.
    static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            var candidate = name
            var counter = 2
            while seen.contains(candidate.lowercased()) {
                if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                    candidate = "\(name[..<dot])_\(counter)\(name[dot...])"
                } else {
                    candidate = "\(name)_\(counter)"
                }
                counter += 1
            }
            seen.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }

    /// Texture file name per material (nil when the material has no texture); unique
    /// and always ending in ".jpg".
    static func textureFileNames(for materials: [ExportMaterial]) -> [String?] {
        var raw: [String] = []
        var slots: [Int] = []
        for (i, material) in materials.enumerated() where material.hasTexture {
            let preferred = material.textureName.isEmpty ? material.name : material.textureName
            raw.append(fileName(preferred, fallback: "texture\(i)", ext: "jpg"))
            slots.append(i)
        }
        var result = [String?](repeating: nil, count: materials.count)
        for (slot, name) in zip(slots, uniqued(raw)) { result[slot] = name }
        return result
    }

    /// Unique identifiers for a list of display names (see `identifier`).
    static func uniqueIdentifiers(_ names: [String], fallback: String) -> [String] {
        uniqued(names.enumerated().map { identifier($0.element, fallback: "\(fallback)\($0.offset)") })
    }
}
